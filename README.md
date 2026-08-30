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

## Not done yet

- Linking `NodeMobile.xcframework` into the extension target and actually starting the Node engine (blocked on inspecting the framework's real API from its built headers, not guessing the symbol names)
- code-server's web bundle + a loopback-only server config baked into the extension's bundled JS
- File System Provider bridging iOS Files/iCloud into the editor
- `product.json` changes to bake in a fixed set of built-in extensions and drop the marketplace UI
