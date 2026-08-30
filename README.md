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

## Not done yet

- Forcing/verifying the web-worker extension host path so `cp.fork` is never reached (see blocker above) — this determines which extensions are even eligible for the "limited preset extensions" list
- File System Provider bridging iOS Files/iCloud into the editor
- `product.json` changes to bake in the fixed set of built-in extensions and drop the marketplace UI
- A real iOS cross-compile (or JS-side fallback) for `@vscode/sqlite3` (workspace/state storage) — currently stripped with no replacement, so storage-dependent features will not work at runtime as-is
