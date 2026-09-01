import WebKit
import os

/// The one piece of evidence-gathering infrastructure the native-workbench
/// experiment (`NativeWorkbenchExperimentView`) was missing: until this
/// file existed, nothing forwarded WKWebView's in-page JS console output or
/// uncaught errors anywhere this project's log-based verification
/// methodology could see (confirmed via `grep` across
/// `VSCodeIPCBridge.swift`/`NativePlatformShim.swift`/
/// `VSCodeFileSchemeHandler.swift` — zero `console`/`NSLog`/`os_log`/
/// `print(` matches before this file). WKWebView has no delegate callback
/// for JS console messages, so this overrides `console.*` and the two
/// uncaught-failure globals in-page (`WKUserScript`, `.atDocumentStart` so
/// it's active before the workbench bundle itself evaluates) and relays
/// each call up through a `WKScriptMessageHandler` to `os.Logger` —
/// `simulator-test.yml`'s existing
/// `log show --predicate 'subsystem CONTAINS "com.hecpdf.ipadvscode"'`
/// capture (already run for every CI Simulator iteration) picks these up
/// with no further CI changes needed, the same way `NodeRuntimeController`
/// and `AudioKeepAlive`'s `Logger` output already does.
final class NativeConsoleForwarder: NSObject, WKScriptMessageHandler {
    static let messageHandlerName = "ipadVSCodeConsoleForward"

    private let log = Logger(subsystem: "com.hecpdf.ipadvscode", category: "nativeworkbench-console")

    /// Registered alongside `VSCodeIPCBridge`/`NativePlatformShim` on the
    /// same `WKWebViewConfiguration` — see `NativeWorkbenchExperimentView`.
    func attach(to configuration: WKWebViewConfiguration) {
        configuration.userContentController.add(self, name: Self.messageHandlerName)
        configuration.userContentController.addUserScript(Self.userScript)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let level = body["level"] as? String,
              let text = body["text"] as? String
        else { return }

        switch level {
        case "error":
            log.error("\(text, privacy: .public)")
        case "warn":
            log.warning("\(text, privacy: .public)")
        default:
            log.info("\(text, privacy: .public)")
        }
    }

    static let userScript = WKUserScript(
        source: """
        (function() {
            function forward(level, text) {
                var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ipadVSCodeConsoleForward;
                if (!handler) { return; }
                try { handler.postMessage({ level: level, text: String(text) }); } catch (e) {}
            }
            function stringifyArgs(args) {
                return Array.prototype.map.call(args, function (a) {
                    if (a instanceof Error) { return a.stack || (a.name + ': ' + a.message); }
                    if (typeof a === 'object') { try { return JSON.stringify(a); } catch (e) { return String(a); } }
                    return String(a);
                }).join(' ');
            }
            ['log', 'info', 'warn', 'error', 'debug'].forEach(function (method) {
                var original = console[method] ? console[method].bind(console) : function () {};
                console[method] = function () {
                    forward(method === 'log' || method === 'debug' ? 'info' : method, stringifyArgs(arguments));
                    original.apply(console, arguments);
                };
            });
            window.addEventListener('error', function (event) {
                var detail = event.error ? (event.error.stack || event.error.message) : event.message;
                forward('error', 'uncaught exception: ' + detail + ' (' + event.filename + ':' + event.lineno + ':' + event.colno + ')');
            });
            window.addEventListener('unhandledrejection', function (event) {
                var reason = event.reason instanceof Error ? (event.reason.stack || event.reason.message) : event.reason;
                forward('error', 'unhandled promise rejection: ' + reason);
            });
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )
}
