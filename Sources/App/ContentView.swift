import SwiftUI
import WebKit

/// Loopback port the Node runtime extension's local HTTP server binds to.
/// Kept in one place because both the extension and this view need it.
enum RuntimeConfig {
    static let loopbackPort = 8482
    static var loopbackURL: URL {
        URL(string: "http://127.0.0.1:\(loopbackPort)/")!
    }
}

struct ContentView: View {
    @StateObject private var tunnel = TunnelController.shared
    @State private var webView = WKWebView()

    var body: some View {
        ZStack {
            EditorWebView(webView: webView)
                .ignoresSafeArea()

            if !tunnel.isRunning {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Starting Node runtime…")
                        .foregroundStyle(.secondary)
                    if let error = tunnel.lastError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }
                }
                .padding()
                .background(.regularMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .task {
            await tunnel.start()
            if tunnel.isRunning {
                webView.load(URLRequest(url: RuntimeConfig.loopbackURL))
            }
        }
    }
}

private struct EditorWebView: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView {
        webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

#Preview {
    ContentView()
}
