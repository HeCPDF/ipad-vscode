import SwiftUI
import WebKit

/// Isolated screen for testing the Electron-desktop-port hypothesis (see
/// README.md's "Architecture pivot" section) without touching the app's
/// real, on-device-verified code-server startup path in ContentView.swift
/// at all — its own fresh WKWebView, its own WKWebViewConfiguration
/// (VSCodeFileSchemeHandler + NativePlatformShim + VSCodeIPCBridge
/// registered only here), created when this sheet is presented and torn
/// down when dismissed.
///
/// Reachable via the native menu bar ("View" > "Experimental: Native
/// Workbench" — iPadVSCodeApp.swift). Expected, per the research this
/// acts on, to render the real vscode desktop workbench shell (title
/// bar, activity bar, welcome page chrome) and then fail the moment
/// anything calls into one of the ~31 IPC channels (`nativeHost` etc.)
/// that don't exist yet — the raw byte transport (VSCodeIPCBridge) now
/// relays (via VSCodeIPCWebSocketRelay) into a real
/// IPCServer/ChannelServer-compatible backend
/// (code-server/src/node/ipadVSCodeIpc.ts, over a new WebSocket route on
/// the already-running code-server loopback server), but that backend so
/// far only registers one diagnostic channel (`ipadVSCodePing`) — every
/// real vscode channel the workbench itself calls (`nativeHost` etc.)
/// still gets a real, well-formed "Unknown channel" error back rather
/// than hanging, which is progress over rejecting locally, but still not
/// functional. This view exists to observe exactly what does and doesn't
/// work on that first real render, not to be a working editor.
struct NativeWorkbenchExperimentView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView?
    @State private var unavailableReason: String?
    // Held here (not just implicitly retained by the
    // WKUserContentController it's registered on) so its lifetime is
    // explicit.
    @State private var ipcBridge: VSCodeIPCBridge?
    // Relays ipcBridge's frames to/from code-server's real
    // /ipad-vscode-ipc WebSocket route — see that class's doc comment.
    @State private var ipcRelay = VSCodeIPCWebSocketRelay()
    // Forwards this webview's JS console output and uncaught errors into
    // os.Logger (see NativeConsoleForwarder's doc comment) -- the only way
    // to get real evidence of what the workbench bundle actually does on
    // first render, since WKWebView itself exposes no console delegate.
    private let consoleForwarder = NativeConsoleForwarder()

    var body: some View {
        NavigationStack {
            Group {
                if let webView {
                    NativeExperimentWebView(webView: webView)
                        .ignoresSafeArea()
                } else if let unavailableReason {
                    ContentUnavailableView(
                        "Native bundle not found",
                        systemImage: "exclamationmark.triangle",
                        description: Text(unavailableReason)
                    )
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Native Workbench (Experimental)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .onDisappear { ipcRelay.disconnect() }
        }
        .task { setUpIfNeeded() }
    }

    private func setUpIfNeeded() {
        guard webView == nil, unavailableReason == nil else { return }
        guard let handler = VSCodeFileSchemeHandler.makeIfBundleAvailable() else {
            unavailableReason = "Sources/App/Resources/vscode-desktop isn't in this build's app bundle. build.yml's \"Fetch vscode desktop bundle\" step is best-effort (continue-on-error) and only populates this from a successful vscode-desktop-build-experiment.yml run on main-yyjpt0 — if that workflow hasn't succeeded yet, or this is a local build, do an xcodebuild archive (not a plain build) locally after running that workflow yourself — see project.yml's comment on resource-copy phases."
            return
        }

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: VSCodeFileSchemeHandler.scheme)
        configuration.userContentController.addUserScript(NativePlatformShim.userScript)
        consoleForwarder.attach(to: configuration)

        let newWebView = WKWebView(frame: .zero, configuration: configuration)
        let bridge = VSCodeIPCBridge()
        bridge.attach(to: newWebView)
        ipcBridge = bridge
        ipcRelay.connect(bridge: bridge)
        webView = newWebView

        var components = URLComponents()
        components.scheme = VSCodeFileSchemeHandler.scheme
        components.host = VSCodeFileSchemeHandler.authority
        components.path = "/vs/code/electron-browser/workbench/workbench.html"
        if let url = components.url {
            newWebView.load(URLRequest(url: url))
        }
    }
}

private struct NativeExperimentWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
