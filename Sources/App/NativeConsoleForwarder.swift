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
            // WebKit/JavaScriptCore's Error.stack format is just call
            // frames (`func@url:line:col`, one per line) -- unlike V8,
            // it does NOT prefix the message/name as its own first line.
            // Preferring `.stack` alone (as this used to) silently
            // dropped the actual error text, confirmed for real: a
            // captured "unhandled promise rejection: initServices@...js:
            // 5342:131798" log line carried no message at all, just the
            // throwing frame. Always include `.message`/`.name`
            // explicitly now, stack trace appended for extra context
            // rather than in place of it.
            function errorToString(e) {
                if (!(e instanceof Error)) { return String(e); }
                var head = (e.name || 'Error') + ': ' + (e.message || '(no message)');
                return e.stack ? (head + '\n' + e.stack) : head;
            }
            function stringifyArgs(args) {
                return Array.prototype.map.call(args, function (a) {
                    if (a instanceof Error) { return errorToString(a); }
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
                var detail = event.error ? errorToString(event.error) : event.message;
                forward('error', 'uncaught exception: ' + detail + ' (' + event.filename + ':' + event.lineno + ':' + event.colno + ')');
            });
            window.addEventListener('unhandledrejection', function (event) {
                var reason = event.reason instanceof Error ? errorToString(event.reason) : event.reason;
                forward('error', 'unhandled promise rejection: ' + reason);
            });
            // CSP violations (workbench.html ships a real, fairly strict
            // Content-Security-Policy meta tag -- style-src/script-src
            // 'self', among others) are otherwise completely silent: no
            // console output, no thrown error, nothing the two handlers
            // above would ever see. Real evidence so far (a captured
            // screenshot showing the native workbench's own nav chrome
            // -- "Close" / "Native Workbench (Experimental)" -- but a
            // fully blank white body below it, despite zero JS errors of
            // any kind) is consistent with workbench.desktop.main.css
            // being CSP-blocked rather than genuinely absent, but that's
            // a hypothesis, not yet confirmed -- this listener is how to
            // find out for real instead of guessing.
            document.addEventListener('securitypolicyviolation', function (e) {
                forward('error', 'CSP violation: blocked "' + e.blockedURI + '" (directive: ' + e.violatedDirective + ')');
            });
            // A second real Simulator run (after the CSP-violation
            // listener above found nothing) still showed the same blank
            // white body with zero errors of any kind -- ruling out
            // both a thrown exception and a CSP block. The remaining
            // possibility this project's evidence-gathering couldn't
            // previously distinguish: a genuinely hung `await` (a
            // promise that never settles either way, e.g. on
            // ipcRenderer.invoke() -- always-reject per NativePlatformShim,
            // but only if something is actually awaiting its result
            // rather than fire-and-forgetting it) versus code that ran
            // to completion without ever mounting anything into
            // document.body. `forward('error', ...)` here (not `.info`,
            // to guarantee `log show`'s default Error/persisted-level
            // visibility, unlike the console.log passthrough above)
            // every 5s reports document.readyState and body.children.length
            // -- if this heartbeat itself stops appearing, that's a real
            // hang (script literally can't get back to the event loop);
            // if it keeps appearing with children=0, the bootstrap
            // finished without ever mounting the workbench UI.
            setInterval(function () {
                forward('error', '[heartbeat] readyState=' + document.readyState + ' body.children=' + (document.body ? document.body.children.length : 'null') + ' elapsed=' + Math.round(performance.now()) + 'ms');
            }, 5000);
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )
}
