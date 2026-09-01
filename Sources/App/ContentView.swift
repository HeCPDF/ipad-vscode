import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Never gates the editor itself behind a folder being picked first —
/// code-server (like real VSCode/vscode-web) has its own "Editor Evolved"
/// welcome page and lets you edit untitled files with no folder open at
/// all. This view just loads the editor unconditionally once the Node
/// runtime is up; "Open Folder…" (menu bar or in-editor) authorizes a
/// folder at runtime and navigates to `?folder=<path>` — it doesn't gate
/// startup. See NodeRuntimeController.swift's authorizeWorkspace and
/// code-server's src/node/routes/vscode.ts (`req.query.folder`).
struct ContentView: View {
    @EnvironmentObject private var menuBridge: MenuBridge
    @StateObject private var tunnel = NodeRuntimeController.shared
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
        .onChange(of: menuBridge.pendingKeyCommand) { _, command in
            guard let command else { return }
            webView.evaluateJavaScript(command.dispatchScript)
            menuBridge.pendingKeyCommand = nil
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
        let containerURL = RuntimeConfig.privateStorageURL
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
/// NodeRuntimeController.authorizeWorkspace(), which starts accessing it
/// directly (same process, no cross-process hand-off needed anymore).
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

    /// WKWebView reserves a transparent strip under the status bar/notch for
    /// the safe-area inset (kept `.automatic`, not `.never` — vscode's own
    /// page has no safe-area awareness, so ignoring the inset would let its
    /// title bar/tabs render straight under the status bar/Dynamic Island
    /// instead of below it). Untouched, that strip paints WKWebView's
    /// *default* background (white) regardless of the page's own theme,
    /// producing a visible seam between real content and native chrome —
    /// exactly the "page color doesn't extend to the status bar" report.
    /// `underPageBackgroundColor` (iOS 15+) is WKWebView's own API for
    /// exactly this area; set to vscode's real Dark+ default here so
    /// there's no white flash before the page has even loaded once, then
    /// kept in sync with the page's *actual* rendered theme (light or
    /// dark, whichever the user has code-server set to) in
    /// `syncBackgroundColor(from:)` below, run after every navigation.
    func makeUIView(context: Context) -> WKWebView {
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = UIColor(red: 30 / 255, green: 30 / 255, blue: 30 / 255, alpha: 1)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// ContentView's `.task` calls `webView.load(loopbackURL)` as soon as
    /// `NodeRuntimeController.start()` returns — which, per that method's
    /// own comment, marks `isRunning` once the background thread running
    /// `node_start()` has merely been kicked off, not once code-server's
    /// HTTP server is actually accepting connections (there's no readiness
    /// signal to wait on; node_start() never returns). code-server has real
    /// startup work to do first (parse args, write its config file, build
    /// the Express app, register routes) before it calls `listen()`, so the
    /// very first load races the server and, without this, would very
    /// likely hit "Could not connect to server" with nothing retrying it.
    /// Retry only the initial connection-refused/not-listening-yet window,
    /// not every navigation failure -- once any load succeeds, later
    /// user-driven navigations (Open Folder, Add Folder to Workspace) are
    /// left alone so a real failure there surfaces normally instead of
    /// silently reloading the workspace root.
    final class Coordinator: NSObject, WKNavigationDelegate {
        private var retryCount = 0
        private let maxRetries = 40
        private let retryDelay: TimeInterval = 0.5
        private var didLoadSuccessfully = false

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            didLoadSuccessfully = true
            syncBackgroundColor(from: webView)
        }

        /// Reads the actually-rendered page background (whatever
        /// light/dark vscode theme the user has picked, not a guess) and
        /// mirrors it into `underPageBackgroundColor` — see
        /// `EditorWebView.makeUIView`'s doc comment for why this exists.
        /// `document.body`'s own computed background is what code-server's
        /// workbench actually paints (not `--vscode-editor-background`,
        /// which is only the *editor pane's* background and can differ
        /// from the surrounding chrome), and `getComputedStyle` always
        /// resolves to an `rgb()`/`rgba()` string regardless of how the
        /// page's CSS expressed the color, so this doesn't need its own
        /// CSS color-format parser beyond that one shape.
        private func syncBackgroundColor(from webView: WKWebView) {
            webView.evaluateJavaScript(
                "document.body ? getComputedStyle(document.body).backgroundColor : ''"
            ) { [weak webView] result, _ in
                guard let webView, let css = result as? String, let color = UIColor(cssRGB: css) else { return }
                webView.underPageBackgroundColor = color
            }
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            retryInitialLoad(in: webView, error: error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            retryInitialLoad(in: webView, error: error)
        }

        private func retryInitialLoad(in webView: WKWebView, error: Error) {
            guard !didLoadSuccessfully, retryCount < maxRetries else { return }
            let nsError = error as NSError
            guard nsError.domain == NSURLErrorDomain else { return }
            let retryableCodes: Set<Int> = [
                NSURLErrorCannotConnectToHost,
                NSURLErrorTimedOut,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorCannotFindHost,
            ]
            guard retryableCodes.contains(nsError.code) else { return }
            retryCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + retryDelay) { [weak webView] in
                guard let webView, self.didLoadSuccessfully == false else { return }
                webView.load(URLRequest(url: RuntimeConfig.loopbackURL))
            }
        }
    }
}

private extension UIColor {
    /// Parses a CSS `rgb(r, g, b)`/`rgba(r, g, b, a)` string, the only
    /// shape `getComputedStyle(...).backgroundColor` ever actually returns
    /// (the browser normalizes any CSS color syntax to this on read,
    /// regardless of how the stylesheet expressed it) — see
    /// `EditorWebView.Coordinator.syncBackgroundColor(from:)`.
    convenience init?(cssRGB string: String) {
        let digits = string
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "rgba() \t")) }
        guard digits.count >= 3,
            let r = Double(digits[0]), let g = Double(digits[1]), let b = Double(digits[2])
        else { return nil }
        let a = digits.count >= 4 ? (Double(digits[3]) ?? 1) : 1
        self.init(red: r / 255, green: g / 255, blue: b / 255, alpha: a)
    }
}

#Preview {
    ContentView()
        .environmentObject(MenuBridge())
}
