import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ContentView: View {
    @EnvironmentObject private var menuBridge: MenuBridge
    @StateObject private var tunnel = TunnelController.shared
    @State private var webView = WKWebView()
    @State private var isPickingFolder = false
    @State private var hasWorkspace = WorkspaceSelection.resolveBookmark(
        in: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: RuntimeConfig.appGroupIdentifier) ?? URL(fileURLWithPath: "/")
    ) != nil

    var body: some View {
        ZStack {
            if hasWorkspace {
                EditorWebView(webView: webView)
                    .ignoresSafeArea()

                if !tunnel.isRunning {
                    startingOverlay
                }
            } else {
                openFolderPrompt
            }
        }
        .sheet(isPresented: $isPickingFolder) {
            FolderPicker { url in
                guard let containerURL = FileManager.default
                    .containerURL(forSecurityApplicationGroupIdentifier: RuntimeConfig.appGroupIdentifier)
                else { return }
                if WorkspaceSelection.store(url: url, in: containerURL) {
                    hasWorkspace = true
                }
            }
        }
        .task(id: hasWorkspace) {
            guard hasWorkspace else { return }
            await tunnel.start()
            if tunnel.isRunning {
                webView.load(URLRequest(url: RuntimeConfig.loopbackURL))
            }
        }
        .onChange(of: menuBridge.openFolderRequested) { _, requested in
            guard requested else { return }
            isPickingFolder = true
            menuBridge.openFolderRequested = false
        }
        .onAppear(perform: applyMinimumWindowSize)
    }

    /// iPadOS 26's windows are freely resizable by default (UIRequiresFullScreen
    /// is deprecated/ignored) — an editor is genuinely unusable below some
    /// width, the same way VSCode itself enforces a minimum window size on
    /// macOS. There's no SwiftUI-level API for this on iPadOS yet, so it's
    /// set directly on the underlying UIWindowScene.
    private func applyMinimumWindowSize() {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }
        scene.sizeRestrictions?.minimumSize = CGSize(width: 500, height: 400)
    }

    private var startingOverlay: some View {
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

    private var openFolderPrompt: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Open a folder to start editing")
                .font(.title3)
            Button("Open Folder…") {
                isPickingFolder = true
            }
            .buttonStyle(.borderedProminent)
        }
    }
}

/// Wraps UIDocumentPickerViewController in folder-picking mode. The
/// returned URL is security-scoped — WorkspaceSelection.store() bookmarks
/// it for NodeRuntimeExtension to resolve and access later.
private struct FolderPicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void

        init(onPick: @escaping (URL) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }
            onPick(url)
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
        .environmentObject(MenuBridge())
}
