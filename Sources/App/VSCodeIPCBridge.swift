import WebKit

/// Native half of Electron's IPC transport
/// (`src/vs/base/parts/ipc/{electron-browser,electron-main}/ipc.electron.ts`),
/// reimplemented over `WKScriptMessageHandler` since there's no real
/// Electron `ipcRenderer`/`ipcMain` here. Carries exactly the same
/// three-frame wire contract real desktop VS Code uses — confirmed from
/// the real fetched source, not guessed:
///   - `vscode:hello` (renderer → main, sent once, no payload) — main's
///     `Server.getOnDidClientConnect()` uses this to key a new client by
///     WebContents id; here there's only ever one "client" (this webview),
///     so the id distinction doesn't apply.
///   - `vscode:message` (both directions, raw bytes — a `VSBuffer`'s
///     underlying `Uint8Array` on the browser/renderer side).
///   - `vscode:disconnect` (renderer → main).
///
/// This class only carries bytes end to end; it has no idea what's
/// inside them. The actual `IPCClient`/`IPCServer`/`ProxyChannel`
/// multiplexing and every one of the ~31 named service channels
/// (`nativeHost`, `workspaces`, etc. — see README.md's "Architecture
/// pivot" section) are meant to ride on top of this transport unmodified
/// once something on the native/Node side actually implements
/// `IPCServer` and replies — **not implemented yet**. `onFrame`/`send(_:)`
/// below are the seam where that backend attaches; right now nothing
/// subscribes, so every `ipcRenderer.invoke(...)` call from the page
/// will hang or reject (see `NativePlatformShim`'s JS shim). Tracked as
/// the next concrete step, not a hidden gap.
final class VSCodeIPCBridge: NSObject, WKScriptMessageHandler {
    static let messageHandlerName = "vscodeIPCTransport"

    enum Frame {
        case hello
        case message(Data)
        case disconnect
    }

    /// Fired for every raw frame the page sends up. Exactly one
    /// subscriber is expected (whatever eventually stands in for the
    /// main-process `IPCServer`) — this is a plain callback, not
    /// multicast, on purpose: unlike real Electron there is only ever
    /// one client webview per bridge instance, so there's nothing to
    /// route between.
    var onFrame: ((Frame) -> Void)?

    private weak var webView: WKWebView?

    /// Registers this as the `vscodeIPCTransport` message handler on the
    /// webview's own configuration. Must be called before the page that
    /// will call `window.webkit.messageHandlers.vscodeIPCTransport` loads
    /// — i.e. as part of setting up the same `WKWebViewConfiguration`
    /// `NativePlatformShim.userScript` and `VSCodeFileSchemeHandler` are
    /// registered on (see `NativeWorkbenchExperimentView`).
    func attach(to webView: WKWebView) {
        self.webView = webView
        webView.configuration.userContentController.add(self, name: Self.messageHandlerName)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "hello":
            onFrame?(.hello)
        case "message":
            guard let base64 = body["data"] as? String, let data = Data(base64Encoded: base64) else { return }
            onFrame?(.message(data))
        case "disconnect":
            onFrame?(.disconnect)
        default:
            break
        }
    }

    /// Native → page delivery of a `vscode:message` frame. There's no
    /// generic push channel from a `WKScriptMessageHandler` (JS→native
    /// only), so this goes back down through `evaluateJavaScript` calling
    /// the dispatch function `NativePlatformShim`'s `ipcRenderer` shim
    /// installs — the same trusted native→JS call pattern
    /// `ios-command-bridge.diff` already established for
    /// `__ipadVSCodeExecuteCommand`.
    func send(_ data: Data) {
        let base64 = data.base64EncodedString()
        webView?.evaluateJavaScript("window.__ipadVSCodeIPCDeliver && window.__ipadVSCodeIPCDeliver(\"\(base64)\");")
    }
}
