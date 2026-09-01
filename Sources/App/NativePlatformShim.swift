import WebKit

/// Fakes the one object real Electron's contextBridge exposes that
/// vscode's own platform detection actually checks. `platform.ts`
/// (`vs/base/common/platform.ts`) decides `isWeb`/`isNative` purely by
/// whether `globalThis.vscode.process` exists and looks like an object —
/// real desktop VS Code builds that object in
/// `src/vs/base/parts/sandbox/electron-browser/preload.ts` from
/// Electron's own `process` via `contextBridge.exposeInMainWorld('vscode',
/// ...)`. There is no Electron here, so this `WKUserScript` injects a
/// plain object with the same shape before the workbench bundle
/// evaluates. See README.md's "Architecture pivot" section for the
/// citations this is built from.
///
/// This is the smallest possible experiment for the hypothesis, not a
/// claim of functional completeness: flipping this flag makes
/// `isNative`-gated UI (context keys, menus) *appear* enabled, but
/// anything that actually calls into a named service over the real
/// `nativeHost` IPC channel (none of which exist yet, see
/// VSCodeFileSchemeHandler's doc comment) will still fail at runtime.
/// `window.vscode.context` (a locally-fabricated `ISandboxConfiguration`,
/// found missing via real Simulator evidence -- see its own comment
/// below) is the one exception so far: a preload-level bootstrap
/// dependency, not one of the ~31 service channels, so it's faked
/// synchronously here rather than routed through the real IPC transport.
enum NativePlatformShim {
    /// `platform: 'darwin'` is a deliberate approximation, not a real
    /// match — there's no canonical `process.platform` value for
    /// "iPadOS app pretending to be Electron." Chosen because this
    /// project already leans on macOS-convergent iPadOS 26 UX (native
    /// menu bar, `.command` keyboard shortcuts — see
    /// iPadVSCodeApp.swift), and vscode's own `isMacintosh`-gated code
    /// paths (title bar conventions, keyboard shortcut display, menu
    /// placement expectations) are the closest existing fit to what this
    /// app already presents. Not verified against how the rest of
    /// platform.ts's darwin-specific branches behave here — a
    /// device-test question like the rest of this experiment.
    static let userScript = WKUserScript(
        source: """
        (function() {
            if (window.vscode && window.vscode.process) { return; }

            // ---- requestIdleCallback polyfill ----
            // WebKit/Safari has never implemented requestIdleCallback --
            // real vscode's own electron-browser bootstrap
            // (workbench.ts's beforeImport callback) calls
            // window.requestIdleCallback(...) unconditionally, with no
            // feature-detection of its own (real Electron ships on
            // Chromium, which has had it since 2018). Found via real
            // Simulator evidence: an "unhandled promise rejection" whose
            // stack trace pointed at exactly this call
            // (workbench.js:408:887, confirmed by inspecting the actual
            // bundled output). Standard, spec-shaped setTimeout-based
            // fallback -- not vscode-specific, just filling a real
            // WebKit API gap the same way `File`/`crypto` were polyfilled
            // for Node 18 on the code-server side
            // (ios-node18-globals-polyfill.diff).
            if (typeof window.requestIdleCallback !== 'function') {
                window.requestIdleCallback = function (callback, options) {
                    var start = Date.now();
                    return setTimeout(function () {
                        callback({
                            didTimeout: false,
                            timeRemaining: function () { return Math.max(0, 50 - (Date.now() - start)); }
                        });
                    }, (options && options.timeout) || 1);
                };
                window.cancelIdleCallback = function (id) { clearTimeout(id); };
            }

            // ---- process shim (isWeb/isNative flag) ----
            window.vscode = {
                process: {
                    platform: 'darwin',
                    arch: 'arm64',
                    env: {},
                    // Hardcoded placeholder: this script runs in the
                    // WKWebView page context, which has no Node `process`
                    // global to read the real embedded nodejs-mobile
                    // version from (that's a separate process entirely —
                    // see NodeRuntimeController.swift). Not believed to be
                    // load-bearing for the isNative flag-flip experiment
                    // itself; revisit if some workbench code path turns
                    // out to actually branch on this value.
                    versions: { node: '22.0.0' },
                    type: 'renderer',
                    cwd: function () { return '/'; }
                }
            };

            // ---- ipcRenderer shim ----
            // Same method shape preload.ts's `globals.ipcRenderer` exposes
            // (send/invoke/on/once/removeListener) -- see that file, lines
            // 110-153 at the pinned commit -- so vscode's own
            // vs/base/parts/ipc/electron-browser/ipc.electron.ts (which
            // only ever calls send('vscode:hello'), send('vscode:message',
            // buf), send('vscode:disconnect'), and on('vscode:message', ...))
            // needs no changes to run against this shim.
            //
            // Real Electron structured-clones values across processes;
            // WKScriptMessageHandler's postMessage only accepts
            // JSON-safe values, so 'vscode:message' payloads are
            // base64-encoded here and decoded back to a Uint8Array on
            // delivery -- VSBuffer.wrap() (the caller in ipc.electron.ts)
            // accepts a Uint8Array directly, matching the browser-side
            // VSBuffer implementation.
            //
            // `invoke` has no native responder yet (see
            // VSCodeIPCBridge.swift's doc comment on where one would
            // attach) -- always rejects, deliberately, rather than
            // hanging forever silently.
            var vscodeIPCListeners = {};
            window.__ipadVSCodeIPCDeliver = function (base64) {
                var binary = atob(base64);
                var bytes = new Uint8Array(binary.length);
                for (var i = 0; i < binary.length; i++) { bytes[i] = binary.charCodeAt(i); }
                var fns = vscodeIPCListeners['vscode:message'] || [];
                fns.slice().forEach(function (fn) { fn({}, bytes); });
            };
            function ipadVSCodeBytesToBase64(bytes) {
                var arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
                var binary = '';
                for (var i = 0; i < arr.length; i++) { binary += String.fromCharCode(arr[i]); }
                return btoa(binary);
            }
            // ---- context shim (ISandboxConfiguration) ----
            // Real preload.ts (lines 227-244 at the pinned commit) exposes
            // window.vscode.context.{configuration,resolveConfiguration} --
            // the real implementation resolves this over a real IPC round
            // trip (ipcRenderer.invoke(a --vscode-window-config=<channel>
            // argv-supplied channel name)), which this project's
            // ipcRenderer.invoke shim always rejects (no invoke responder
            // exists yet -- see below). Found missing entirely via real
            // Simulator evidence: workbench.ts's resolveWindowConfiguration()
            // (vs/code/electron-browser/workbench/workbench.ts:420-428)
            // does `await preloadGlobals.context.resolveConfiguration()`,
            // which threw synchronously ("Cannot read properties of
            // undefined") when `context` didn't exist at all -- observed as
            // an "unhandled promise rejection" in NativeConsoleForwarder's
            // log, with workbench.ts's own orphaned 10-second timeout (never
            // cleared, since the throw happened before reaching
            // clearTimeout) firing independently right after.
            //
            // Rather than wiring this through the real invoke() RPC path
            // (a bigger lift -- see VSCodeIPCBridge.swift's doc comment on
            // where a request/response-correlated invoke responder would
            // attach), this fabricates a minimal but real-shaped
            // ISandboxConfiguration locally, the same "smallest possible
            // experiment" approach the process shim above already takes.
            // Only the base ISandboxConfiguration fields (sandboxTypes.ts,
            // confirmed from real source) are populated; nothing here has
            // been verified against what workbench code actually reads out
            // of `configuration` past this point -- the next thing to find
            // out from real Simulator evidence, not guessed ahead of it.
            var ipadVSCodeSandboxConfiguration = {
                windowId: 1,
                appRoot: '/',
                userEnv: {},
                product: {
                    nameShort: 'iPad VSCode',
                    nameLong: 'iPad VSCode',
                    applicationName: 'ipad-vscode',
                    dataFolderName: '.ipadvscode',
                    version: '1.0.0'
                },
                nls: { messages: [], language: undefined }
            };
            window.vscode.context = {
                configuration: function () { return ipadVSCodeSandboxConfiguration; },
                resolveConfiguration: function () { return Promise.resolve(ipadVSCodeSandboxConfiguration); }
            };

            window.vscode.ipcRenderer = {
                send: function (channel) {
                    var args = Array.prototype.slice.call(arguments, 1);
                    var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.vscodeIPCTransport;
                    if (!handler) { return; }
                    if (channel === 'vscode:hello') {
                        handler.postMessage({ kind: 'hello' });
                    } else if (channel === 'vscode:message') {
                        handler.postMessage({ kind: 'message', data: ipadVSCodeBytesToBase64(args[0]) });
                    } else if (channel === 'vscode:disconnect') {
                        handler.postMessage({ kind: 'disconnect' });
                    }
                    // Any other channel: no native responder exists yet
                    // (this shim only implements the raw transport three
                    // channels above, not a generic passthrough) --
                    // silently dropped rather than thrown, matching how a
                    // real but unhandled IPC send behaves (no listener,
                    // no error).
                },
                invoke: function (channel) {
                    return Promise.reject(new Error('ipcRenderer.invoke(\\'' + channel + '\\'): no native IPC server implemented yet -- see VSCodeIPCBridge.swift'));
                },
                on: function (channel, listener) {
                    (vscodeIPCListeners[channel] = vscodeIPCListeners[channel] || []).push(listener);
                    return this;
                },
                once: function (channel, listener) {
                    var self = this;
                    function wrapped() { self.removeListener(channel, wrapped); listener.apply(null, arguments); }
                    return this.on(channel, wrapped);
                },
                removeListener: function (channel, listener) {
                    var arr = vscodeIPCListeners[channel];
                    if (arr) { var i = arr.indexOf(listener); if (i >= 0) { arr.splice(i, 1); } }
                    return this;
                }
            };
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )
}
