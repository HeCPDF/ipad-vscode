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
/// anything that actually calls into a native IPC channel (`nativeHost`
/// etc. — none of which exist yet, see VSCodeFileSchemeHandler's doc
/// comment) will still fail at runtime. That gap is expected, not a bug
/// in this shim.
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
