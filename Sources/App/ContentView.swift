import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Never gates the editor itself behind a folder being picked first —
/// code-server (like real VSCode/vscode-web) has its own "Editor Evolved"
/// welcome page and lets you edit untitled files with no folder open at
/// all. This view just loads the editor unconditionally once the Node
/// runtime is up; "Open Folder…" (menu bar or in-editor) authorizes a
/// folder at runtime and navigates to `?folder=<path>` — it doesn't gate
/// startup. See PacketTunnelProvider.swift's handleAppMessage and
/// code-server's src/node/routes/vscode.ts (`req.query.folder`).
struct ContentView: View {
    @EnvironmentObject private var menuBridge: MenuBridge
    @StateObject private var tunnel = TunnelController.shared
    @State private var webView = WKWebView()
    @State private var isPickingFolder = false
    @State private var pickerMode: FolderPickerMode = .openAsPrimaryWorkspace
    @State private var folderPickerError: String?

    private enum FolderPickerMode {
        case openAsPrimaryWorkspace
        case addToWorkspace
    }

    var body: some View {
        ZStack {
            EditorWebView(webView: webView)
                .ignoresSafeArea()

            if !tunnel.isRunning {
                startingOverlay
            }
        }
        .sheet(isPresented: $isPickingFolder) {
            FolderPicker { url in
                switch pickerMode {
                case .openAsPrimaryWorkspace:
                    Task { await openFolder(url) }
                case .addToWorkspace:
                    Task { await addFolderToWorkspace(url) }
                }
            }
        }
        .task {
            await tunnel.start()
            if tunnel.isRunning {
                webView.load(URLRequest(url: RuntimeConfig.loopbackURL))
            }
        }
        .onChange(of: menuBridge.openFolderRequested) { _, requested in
            guard requested else { return }
            pickerMode = .openAsPrimaryWorkspace
            isPickingFolder = true
            menuBridge.openFolderRequested = false
        }
        .onChange(of: menuBridge.addFolderToWorkspaceRequested) { _, requested in
            guard requested else { return }
            pickerMode = .addToWorkspace
            isPickingFolder = true
            menuBridge.addFolderToWorkspaceRequested = false
        }
        .onAppear(perform: applyMinimumWindowSize)
        .alert(
            "Couldn't open folder",
            isPresented: Binding(
                get: { folderPickerError != nil },
                set: { if !$0 { folderPickerError = nil } }
            ),
            presenting: folderPickerError
        ) { _ in
            Button("OK") { folderPickerError = nil }
        } message: { message in
            Text(message)
        }
    }

    private func openFolder(_ url: URL) async {
        do {
            let resolvedPath = try await tunnel.authorizeWorkspace(url)
            var components = URLComponents(url: RuntimeConfig.loopbackURL, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "folder", value: resolvedPath)]
            guard let folderURL = components?.url else { return }
            webView.load(URLRequest(url: folderURL))
        } catch {
            folderPickerError = "\(error)"
        }
    }

    /// Multi-root workspace: authorizes the new folder the same way
    /// openFolder() does, but instead of replacing the current `?folder=`,
    /// appends it to a persisted `.code-workspace` file (CodeWorkspaceFile)
    /// and navigates to `?workspace=<that file's path>` — code-server opens
    /// any `.code-workspace`-extensioned path this way (confirmed from
    /// source: `IS_WORKSPACE_FILE` in code-server's
    /// src/node/routes/vscode.ts). If a folder was already open via
    /// `?folder=`, it's carried into the workspace file too so switching to
    /// multi-root doesn't drop it.
    private func addFolderToWorkspace(_ url: URL) async {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: RuntimeConfig.appGroupIdentifier)
        else {
            folderPickerError = "no App Group container"
            return
        }
        do {
            if let currentFolder = currentSingleFolderPath {
                _ = CodeWorkspaceFile.addFolder(currentFolder, in: containerURL)
            }
            let resolvedPath = try await tunnel.authorizeWorkspace(url)
            guard let workspaceFilePath = CodeWorkspaceFile.addFolder(resolvedPath, in: containerURL) else {
                folderPickerError = "failed to write .code-workspace file"
                return
            }
            var components = URLComponents(url: RuntimeConfig.loopbackURL, resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "workspace", value: workspaceFilePath)]
            guard let workspaceURL = components?.url else { return }
            webView.load(URLRequest(url: workspaceURL))
        } catch {
            folderPickerError = "\(error)"
        }
    }

    /// Best-effort read of the currently-displayed `?folder=` query value
    /// from the webview's own URL, so switching to multi-root doesn't
    /// silently drop whatever single folder was already open.
    private var currentSingleFolderPath: String? {
        guard let url = webView.url,
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        return components.queryItems?.first(where: { $0.name == "folder" })?.value
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

    /// iPadOS 26's windows are freely resizable by default (UIRequiresFullScreen
    /// is deprecated/ignored) — an editor is genuinely unusable below some
    /// width, the same way VSCode itself enforces a minimum window size on
    /// macOS. There's no SwiftUI-level API for this on iPadOS yet, so it's
    /// set directly on the underlying UIWindowScene.
    ///
    /// `sizeRestrictions` only governs the freeform/Stage-Manager-style
    /// resizable window path — classic Split View (Stage Manager off) uses
    /// system size classes it has always used and isn't gated by this API,
    /// so this shouldn't affect Split View placement. Not verified against
    /// an actual Stage-Manager-off device/simulator, though — no way to
    /// toggle that setting in this pipeline. The app's own layout
    /// (ZStack/VStack, no fixed-width assumptions) is written to reflow at
    /// any width regardless, which is the part that actually matters for
    /// working correctly in a narrow Split View pane.
    private func applyMinimumWindowSize() {
        guard let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene
        else { return }
        scene.sizeRestrictions?.minimumSize = CGSize(width: 500, height: 400)
    }
}

/// Wraps UIDocumentPickerViewController in folder-picking mode. The
/// returned URL is security-scoped — passed to
/// TunnelController.authorizeWorkspace(), which bookmarks it and has
/// NodeRuntimeExtension authorize access in its own process.
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
