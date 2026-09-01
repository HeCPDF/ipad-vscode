import Foundation
import WebKit

/// WKURLSchemeHandler for `vscode-file://vscode-app/...` — the custom
/// scheme real desktop VS Code's electron-browser workbench uses instead
/// of `file://` (`protocolMainService.ts` explicitly blocks `file://`:
/// "Block any file:// access"; the fixed authority `vscode-app` exists "so
/// that it can serve as origin for network and loading matters in
/// chromium" — `network.ts`). Serving the exact same scheme/authority
/// means vscode's own `uriToBrowserUri()` URI-rewriting (gated on
/// `platform.isNative`, which `NativePlatformShim` flips) needs no
/// modification at all — see README.md's "Architecture pivot" section for
/// the full source citations this is built from.
///
/// Backed by `Sources/App/Resources/vscode-desktop` — the electron-browser
/// bundle produced by `.github/workflows/vscode-desktop-build-experiment.yml`
/// (`out-vscode-min`, fetched into the app bundle the same way
/// `Sources/App/Resources/code-server` is — see build.yml), preserving
/// `out-vscode-min`'s own directory layout so the bundle's relative asset
/// references (`./workbench.js`, `../../../workbench/workbench.desktop.main.css`
/// etc.) resolve correctly against sibling scheme-handled requests without
/// any path rewriting on this end.
final class VSCodeFileSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "vscode-file"
    static let authority = "vscode-app"

    private let rootPath: String

    private init(rootPath: String) {
        self.rootPath = rootPath
        super.init()
    }

    /// A static factory rather than a failable `init?()`: Swift doesn't
    /// allow overriding NSObject's non-failable `init()` with a failable
    /// one (they have the same signature, so it counts as an override,
    /// and failable-overriding-non-failable is disallowed — a real
    /// compile error hit here, not a style choice).
    ///
    /// Returns nil if the bundled resource folder isn't present — e.g. a
    /// build that skipped the CI fetch step, or a plain `xcodebuild build`
    /// (not `archive`) invocation, which per project.yml's own comment
    /// doesn't reliably run resource-copy phases. Callers should treat
    /// that as "the native experiment isn't available in this build," not
    /// force-unwrap.
    static func makeIfBundleAvailable() -> VSCodeFileSchemeHandler? {
        let path = Bundle.main.bundlePath + "/vscode-desktop"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        return VSCodeFileSchemeHandler(rootPath: path)
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url, url.scheme == Self.scheme else {
            urlSchemeTask.didFailWithError(URLError(.unsupportedURL))
            return
        }

        // url.path is e.g. "/vs/code/electron-browser/workbench/workbench.html"
        // for "vscode-file://vscode-app/vs/code/electron-browser/workbench/workbench.html".
        let relativePath = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
        let resolvedURL = URL(fileURLWithPath: rootPath)
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        let rootURL = URL(fileURLWithPath: rootPath).standardizedFileURL

        // Path-traversal guard: a crafted "../../.." request must not be
        // able to read anything outside the bundled resource folder.
        guard resolvedURL.path.hasPrefix(rootURL.path + "/") || resolvedURL.path == rootURL.path else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        guard let data = try? Data(contentsOf: resolvedURL) else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let response = HTTPURLResponse(
            url: url,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": Self.mimeType(forPathExtension: resolvedURL.pathExtension),
                "Content-Length": String(data.count),
            ]
        )!
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    /// Requests are served synchronously from disk above (no background
    /// work started), so there's nothing to actually cancel here — still
    /// required to conform to WKURLSchemeHandler.
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private static let mimeTypesByExtension: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "mjs": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json; charset=utf-8",
        "map": "application/json; charset=utf-8",
        "ttf": "font/ttf",
        "woff": "font/woff",
        "woff2": "font/woff2",
        "svg": "image/svg+xml",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
    ]

    private static func mimeType(forPathExtension ext: String) -> String {
        mimeTypesByExtension[ext.lowercased()] ?? "application/octet-stream"
    }
}
