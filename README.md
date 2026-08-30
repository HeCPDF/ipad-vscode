# iPadVSCode

Native iPadOS shell for the real, unmodified VSCode editor (not a web/limited-extension edition), built on top of:

- **[code-server](https://github.com/HeCPDF/code-server)** — the actual editor (full VSCode + Node backend), running headless, patched (see below) to run on iOS.
- **[nodejs-mobile](https://github.com/HeCPDF/nodejs-mobile)** — embeds the Node.js runtime as a library (`NodeMobile.xcframework`), no subprocess spawning required.
- Two `NEPacketTunnelProvider` app extensions — not a real VPN. This is the one Apple-sanctioned extension point that gives a sideloaded app a long-lived, independently-launchable background *process* with a public start API and a public IPC channel:
  - **NodeRuntimeExtension** runs code-server's server.
  - **ExtensionHostRuntime** runs VSCode's real Node extension host, in its own process, because iOS won't let NodeRuntimeExtension `fork()` it directly (see "Extension host" below).
- `WKWebView` in the main app, pointed at `http://127.0.0.1:8482` once NodeRuntimeExtension is up, serving the code-server web UI.
- A real folder picker (`UIDocumentPickerViewController` + security-scoped bookmark) for choosing the workspace — not limited to a sandboxed placeholder directory.

This is a **sideload-only** project: it deliberately uses a network-extension entitlement for a non-VPN purpose (to get independently-launchable background processes), which App Store review would reject.

## Status

There are two distinct verification tiers in CI (`.github/workflows/build.yml`), and it matters which one a given claim rests on:

1. **Compiles** — unsigned build against `generic/platform=iOS`, no Apple Developer account needed. Everything in this project reaches this tier.
2. **Simulator smoke test** — the Simulator needs no code signing, so CI actually boots one, installs the built app, launches it, and captures a screenshot + log as artifacts. This is real runtime evidence that the app launches and SwiftUI renders without crashing — not nothing. But it is **not** evidence that NodeRuntimeExtension/ExtensionHostRuntime work: Apple's Network Extension framework has long-standing, well-known Simulator support gaps, so the two `NEPacketTunnelProvider` extensions activating is not expected to be exercised by this test, screenshot or no screenshot.

Neither tier is "verified working on the actual target (a real, sideloaded iPad)." That requires a real device and a Mac to sign/deploy with, which this pipeline does not have. Where this doc says something "should" work, that means: read from the exact pinned source, patch verified to apply and type-check for real, protocol reasoned through — not observed running.

## Layout

- `Sources/App` — main app: SwiftUI + WKWebView, `TunnelController` (drives both extensions via `NETunnelProviderManager`, watches for exthost launch requests), folder picker in `ContentView.swift`
- `Sources/NodeRuntimeExtension` — runs code-server (`PacketTunnelProvider.swift`); resources include the fetched-and-trimmed code-server build (folder reference, not committed to git)
- `Sources/ExtensionHostRuntime` — runs the real Node extension host (`ExtensionHostTunnelProvider.swift`)
- `Sources/Shared` — code compiled into every target: `RuntimeConfig` (loopback port, App Group id), `ExtensionHostLaunchRequest` (the NodeRuntimeExtension → ExtensionHostRuntime hand-off contract), `WorkspaceSelection` (security-scoped bookmark storage)
- `project.yml` — [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec; the `.xcodeproj` is generated in CI, not committed
- `scripts/trim-code-server.sh` — removes only `node-pty` from the fetched code-server build (the one genuine iOS sandbox hard-wall — see below), nothing else

## Extension host: real Node exthost via a second process

This project targets the **real, unmodified Node extension host** — not vscode.dev/github.dev's browser Web Worker extension host. Full feature set is the goal; things get cut only where iOS genuinely leaves no option, not for convenience.

**The problem**: `cp.fork()` (`vscode/src/vs/server/node/extensionHostConnection.ts`) is how every other platform starts the extension host. iOS denies `fork`/`posix_spawn` to third-party processes outright, at the sandbox-profile level — unrelated to JIT or signing, no known workaround short of a full jailbreak (out of scope; this is a sideload-only project).

**The fix**: the exthost protocol doesn't actually require a literal parent/child relationship. On POSIX, when `_canSendSocket` is false, the only thing that happens is a plain `net.Server` listens on a Unix-domain-socket path (`createRandomIPCHandle()`), and whatever process connects to it is treated as the extension host. So:
- `code-server/patches/ios-exthost-no-fork.diff` forces `_canSendSocket` off whenever `IPADVSCODE_NO_FORK` is set, and replaces `cp.fork()` with writing the launch parameters (`bootstrapForkPath`/`args`/`env`) to a JSON file in the shared App Group container instead of forking.
- **ExtensionHostRuntime**, launched by iOS (not by us) when the app calls `startVPNTunnel()` on its `NETunnelProviderManager`, reads that file and execs `bootstrap-fork.js` itself via `node_start()`, connecting to the same socket.
- Both processes get `TMPDIR` pointed at the shared container so `createRandomIPCHandle()`'s socket path resolves for both sides.
- The app can't be signaled by an extension directly (extensions can't call back into the containing app), so `TunnelController` watches the shared container with a `DispatchSource` for the launch-request file and starts ExtensionHostRuntime when it appears.

**Verified**: the patch applies cleanly with `patch -p1` against the exact pinned vscode commit code-server builds (`08d4889f9ec4a1685d257b9b95de036c8e1ce1e5`), and — after one round-trip fixing a real `error TS2531: Object is possibly 'null'` (wrapping the `cp.fork` assignment in a conditional broke TypeScript's control-flow narrowing for a later unguarded use of the same field, three call sites down) — it now passes the actual `tsc` type-check in code-server's own CI build, not just a hand-check.

**Not verified / known gaps**:
- Nothing has run on a device. The socket hand-off should work per the protocol read from source; that's the extent of the confidence level.
- iOS gives no reliable way to wake a fully suspended app. If the user has backgrounded the app when NodeRuntimeExtension needs the exthost (re)started, the file-watch hand-off may simply not fire.
- `acceptReconnection()`'s fd-passing branch and `shortenReconnectionGraceTimeIfNecessary()` assume a real `ChildProcess` handle, which this path doesn't have (documented in the patch itself) — reconnect-after-drop for the exthost specifically is unaddressed.

## The one real feature cut: no integrated terminal

`node-pty` needs a real kernel pty (`posix_openpt` / `/dev/ptmx`). iOS denies that device-node access to third-party sandboxed processes outright, the same way it denies `fork()` — this is a different sandbox rule than the extension-host one above, and the multi-process trick that routes around `fork()` does **not** unlock it (getting another *process* isn't the same as getting a real pty device). No workaround identified short of a full jailbreak. Everything else — Copilot, other bundled extensions, `argon2`, the marketplace — is intentionally left in, not trimmed for convenience; see `scripts/trim-code-server.sh`.

## Not done yet

- Running any of this on an actual device or simulator (this pipeline has no way to do that)
- File System Provider bridging so the *rest* of code-server's file access (not just the workspace root, which the folder picker now handles) can reach iOS Files/iCloud
- A real iOS cross-compile for `@vscode/sqlite3` / `@parcel/watcher` / `@vscode/spdlog` (their bundled `.node` files are linux-x64 and won't load on iOS as-is; kept in the bundle rather than deleted, since deleting isn't a fix) — until then, storage/watcher features they back will not work at runtime
- The suspended-app wake-up gap above
- `product.json` / built-in-extensions decisions have not been revisited since the "full feature set" decision — currently just using code-server's defaults
