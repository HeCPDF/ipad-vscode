# iPadVSCode

Native iPadOS shell for a VSCode-like editor, built on top of:

- **[code-server](https://github.com/HeCPDF/code-server)** — the actual editor (VSCode web build + Node backend), running headless.
- **[nodejs-mobile](https://github.com/HeCPDF/nodejs-mobile)** — embeds the Node.js runtime as a library (`NodeMobile.xcframework`), no subprocess spawning required.
- A `NEPacketTunnelProvider` app extension — not a real VPN. It's the one Apple-sanctioned extension point that gives a sideloaded app a long-lived, independently-launchable background *process* with a public start API and a public IPC channel, which is what hosts the embedded Node runtime.
- `WKWebView` in the main app, pointed at `http://127.0.0.1:8482` once the extension's Node runtime is up, serving the code-server web UI.

This is a **sideload-only** project (see project history for why): it deliberately uses a network-extension entitlement for a non-VPN purpose, which App Store review would reject.

## Status

Early skeleton. Current milestone is **"compiles via CI"**, tracked in `.github/workflows/build.yml` (unsigned build against `generic/platform=iOS`, no Apple Developer account needed). Runtime behavior is not yet testable here — there's no signed build and no device farm — so correctness is verified by inspection and by getting the real dependencies (NodeMobile's actual header surface, code-server's actual asset layout) into the build rather than by guessing.

## Layout

- `Sources/App` — main app target (SwiftUI + WKWebView + `TunnelController` which drives the extension via `NETunnelProviderManager`)
- `Sources/NodeRuntimeExtension` — the packet-tunnel-provider extension (`PacketTunnelProvider.swift`)
- `project.yml` — [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec; the `.xcodeproj` is generated in CI, not committed
- `Resources` — static assets bundled into the app (placeholder for now)

## Status detail

`NodeMobile.xcframework` is linked and `node_start()` is called for real (confirmed API: a single C function, `int node_start(int argc, char *argv[])` — no Objective-C wrapper class).

CI now fetches the real code-server build, strips it with `scripts/trim-code-server.sh` (removes native `.node` modules that can't load on iOS regardless of CPU arch — different Mach-O platform tag and Node ABI than nodejs-mobile's libnode — and drops extensions like Copilot that bundle their own), and bundles the result as a folder reference into the extension. `PacketTunnelProvider` launches `code-server/out/node/entry.js --auth none --bind-addr 127.0.0.1:8482 <workspace>` if that bundle is present, falling back to the placeholder `server.js` otherwise.

**This has not run on a device or simulator** — there's no signed build and no test harness in this pipeline, so "should boot per `src/node/cli.ts`" is as far as verification goes right now. A confirmed architectural blocker independent of all this: code-server's Node extension host is spawned via `child_process.fork` (`vscode/src/vs/server/node/extensionHostConnection.ts`), and iOS sandboxes third-party processes out of `fork`/`posix_spawn` entirely — this has nothing to do with JIT or signing and can't be worked around the way those can. The planned fix is to only preset extensions with a web-worker build (the same mechanism vscode.dev/github.dev use) so the client never opens the connection that would trigger `cp.fork` in the first place — not yet implemented.

## Extension host: real Node exthost via a second process, not the web-worker one

Decision (superseding an earlier draft of this doc): this project targets the **real, unmodified Node extension host** — not vscode.dev/github.dev's browser Web Worker extension host. Full feature set is the goal; things get cut only where iOS genuinely leaves no option (see below), not for convenience.

`cp.fork()` (`vscode/src/vs/server/node/extensionHostConnection.ts`) can't run on iOS — third-party processes are denied `fork`/`posix_spawn` outright, unrelated to JIT/signing, no known workaround short of a full jailbreak (out of scope). But the exthost protocol itself doesn't require a literal fork: the parent and child only ever talk over a named pipe (a Unix domain socket on POSIX — `createRandomIPCHandle()` in `vscode/src/vs/base/parts/ipc/node/ipc.net.ts`), which any two processes that can see the same path can use.

So: a second extension target, **ExtensionHostRuntime**, also runs `NodeMobile`'s `node_start()`, but pointed at `bootstrap-fork.js --type=extensionHost` instead of code-server's server. iOS (not our code) launches it as an independent process, sidestepping the fork ban entirely. Both extensions get `TMPDIR` set to the shared App Group container so the socket path resolves for both sides. NodeRuntimeExtension → ExtensionHostRuntime hand-off is a JSON file (`ExtensionHostLaunchRequest`, in `Sources/Shared`) plus a Darwin notification that the app (the only thing that can call `startVPNTunnel()` on an extension) observes and acts on.

**Current state**: the `extensionHostConnection.ts` patch (`code-server/patches/ios-exthost-no-fork.diff`) is written, verified to apply cleanly (`patch -p1 --dry-run` against the exact pinned vscode commit code-server builds — `08d4889f9ec4a1685d257b9b95de036c8e1ce1e5`) and pushed to the code-server fork's patch series, gated entirely behind `IPADVSCODE_NO_FORK` so it changes nothing on other platforms. The Swift side (`ExtensionHostRuntime` target, `ExtensionHostTunnelProvider`, `ExtensionHostLaunchRequest`) is wired end to end: `PacketTunnelProvider` sets `IPADVSCODE_NO_FORK`/`IPADVSCODE_SHARED_CONTAINER`/`TMPDIR` before `node_start()`, matching what the patch reads.

**Not verified**: brace/paren balance was checked, but there's no `tsc` type-check in this pipeline yet (code-server's own `build:vscode` step will be the first real compile check, next CI run). And regardless of whether it type-checks, nothing here has run on a device — "the socket hand-off should work per the protocol read from source" is as far as verification goes.

**Not yet resolved**: `TunnelController` watches the shared container for the launch-request file with a `DispatchSource` while the app process is alive, which replaced an earlier Darwin-notification design — but neither approach solves the underlying problem, which is that iOS gives no reliable way to wake a fully suspended app when NodeRuntimeExtension needs the exthost (re)started. If the user has backgrounded the app, this hand-off may simply not fire.

**Also not addressed**: `acceptReconnection()`'s fd-passing branch and `shortenReconnectionGraceTimeIfNecessary()` assume a real `ChildProcess` handle, which this path doesn't have (documented in the patch itself) — reconnect-after-drop for the exthost specifically is a known gap.

## Not done yet

- The `extensionHostConnection.ts` patch itself (see above)
- File System Provider bridging iOS Files/iCloud into the editor
- `product.json` changes to bake in the fixed set of built-in extensions and drop the marketplace UI
- A real iOS cross-compile for `@vscode/sqlite3` / `@parcel/watcher` / `@vscode/spdlog` (their bundled `.node` files are linux-x64 and won't load on iOS as-is; kept in the bundle rather than deleted, since deleting isn't a fix — see trim-code-server.sh) — until then, storage/watcher features they back will not work at runtime
- Resolving the Darwin-notification-while-backgrounded gap above
