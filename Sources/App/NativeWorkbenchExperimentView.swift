import SwiftUI
import WebKit
import os

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
    @State private var nativeProbeTimer: Timer?
    private let log = Logger(subsystem: "com.hecpdf.ipadvscode", category: "nativeworkbench-console")

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
            .onDisappear {
                ipcRelay.disconnect()
                nativeProbeTimer?.invalidate()
            }
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

        // "/out/vs/..." -- not "/vs/...": real vscode's own
        // workbench.ts computes its dynamic-import base URL as
        // `<appRoot>/out/`, so everything (including this initial
        // document) needs to live under an `out/` segment to match --
        // see vscode-desktop-build-experiment.yml's staging-step comment
        // for the full evidence chain that found this.
        var components = URLComponents()
        components.scheme = VSCodeFileSchemeHandler.scheme
        components.host = VSCodeFileSchemeHandler.authority
        components.path = "/out/vs/code/electron-browser/workbench/workbench.html"
        if let url = components.url {
            newWebView.load(URLRequest(url: url))
        }

        // Independent of NativeConsoleForwarder's in-page setInterval
        // heartbeat, which never fired even once across a real ~80s+
        // Simulator window despite zero captured JS errors -- that's
        // consistent with the WKWebView's JS thread being genuinely
        // stuck (a synchronous hang would block a same-context timer
        // too), but it could also mean something broke in the
        // in-page->native messageHandler bridge specifically. Polling
        // from the *native* side via evaluateJavaScript is a
        // completely separate code path (WebKit's own synchronous
        // script-evaluation API, not reliant on the page's own timers
        // or its postMessage bridge still working) -- if this also
        // never gets a callback, or every callback errors/times out,
        // that's real confirmation of a true JS-thread-level lockup
        // rather than an in-page instrumentation gap.
        nativeProbeTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak newWebView] _ in
            guard let newWebView else { return }
            let start = Date()
            newWebView.evaluateJavaScript("document.readyState + '|' + (document.body ? document.body.children.length : 'null')") { result, error in
                let elapsed = Date().timeIntervalSince(start)
                if let error {
                    self.log.warning("[native-probe] evaluateJavaScript failed after \(elapsed, privacy: .public)s: \(String(describing: error), privacy: .public)")
                } else {
                    self.log.warning("[native-probe] evaluateJavaScript returned after \(elapsed, privacy: .public)s: \(String(describing: result), privacy: .public)")
                }
            }
        }
    }
}

private struct NativeExperimentWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        return webView
    }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator() }

    /// A scheme-handler-level failure to load workbench.html itself (a
    /// bad artifact layout, a missing file) happens before any page JS
    /// runs, so NativeConsoleForwarder -- which only intercepts JS already
    /// executing on the page -- can't see it. This is the only way that
    /// specific class of failure becomes visible in
    /// simulator-test.yml's log capture; without it, a 404'd main
    /// document just renders as a silent blank page with nothing recorded
    /// anywhere. (This exact gap is what let the vs/-prefix-stripped
    /// artifact bug go unnoticed until inspected by hand -- see
    /// vscode-desktop-build-experiment.yml's upload-step comment.)
    final class Coordinator: NSObject, WKNavigationDelegate {
        private let log = Logger(subsystem: "com.hecpdf.ipadvscode", category: "nativeworkbench-console")

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            log.error("native workbench provisional navigation failed: \(String(describing: error), privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            log.error("native workbench navigation failed: \(String(describing: error), privacy: .public)")
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // .warning (not .info): os.Logger's .info level isn't
            // persisted under log show's default filtering, and whether
            // this ever fires at all is itself diagnostic -- a
            // module-script <script type="module"> whose top-level code
            // never finishes executing (not just an unresolved promise
            // somewhere downstream, but the load event itself) would
            // delay or block didFinish exactly the way a real hang was
            // suspected to (see NativeConsoleForwarder's heartbeat,
            // which never fired even once across a real ~80s+ window).
            log.warning("native workbench navigation finished (workbench.html served, load event fired)")
        }
    }
}
