import SwiftUI
import WebKit

/// Isolated screen for testing the Electron-desktop-port hypothesis (see
/// README.md's "Architecture pivot" section) without touching the app's
/// real, on-device-verified code-server startup path in ContentView.swift
/// at all — its own fresh WKWebView, its own WKWebViewConfiguration
/// (VSCodeFileSchemeHandler + NativePlatformShim registered only here),
/// created when this sheet is presented and torn down when dismissed.
///
/// Reachable via the native menu bar ("View" > "Experimental: Native
/// Workbench" — iPadVSCodeApp.swift). Expected, per the research this
/// acts on, to render the real vscode desktop workbench shell (title
/// bar, activity bar, welcome page chrome) and then fail the moment
/// anything calls into one of the ~31 IPC channels (`nativeHost` etc.)
/// that don't exist yet — nothing here implements them. This view exists
/// to observe exactly what does and doesn't work on that first real
/// render, not to be a working editor.
struct NativeWorkbenchExperimentView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var webView: WKWebView?
    @State private var unavailableReason: String?

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
        }
        .task { setUpIfNeeded() }
    }

    private func setUpIfNeeded() {
        guard webView == nil, unavailableReason == nil else { return }
        guard let handler = VSCodeFileSchemeHandler.makeIfBundleAvailable() else {
            unavailableReason = "Sources/App/Resources/vscode-desktop isn't in this build's app bundle. Needs the CI fetch step from vscode-desktop-build-experiment.yml's artifact wired into build.yml first (not done yet), or an xcodebuild archive (not a plain build) locally — see project.yml's comment on resource-copy phases."
            return
        }

        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(handler, forURLScheme: VSCodeFileSchemeHandler.scheme)
        configuration.userContentController.addUserScript(NativePlatformShim.userScript)

        let newWebView = WKWebView(frame: .zero, configuration: configuration)
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
