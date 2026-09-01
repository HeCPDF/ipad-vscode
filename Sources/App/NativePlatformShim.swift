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
        })();
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: false
    )
}
