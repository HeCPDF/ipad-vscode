import Foundation
import SwiftUI

/// Commands declared in `.commands {}` (the App scene's menu bar / iPadOS 26
/// menu bar) live outside ContentView's local @State, so they need a shared
/// object to actually trigger UI state changes in the view hierarchy.
@MainActor
final class MenuBridge: ObservableObject {
    @Published var openFolderRequested = false
    /// Distinct from openFolderRequested: adds a folder to a multi-root
    /// `.code-workspace` alongside whatever's already open, instead of
    /// replacing it. See CodeWorkspaceFile.swift and ContentView's
    /// addFolderToWorkspaceRequested(_:).
    @Published var addFolderToWorkspaceRequested = false

    /// Set by a native menu-bar item's action (a mouse/trackpad/tap click on
    /// the item, not a real hardware keypress) and consumed by ContentView,
    /// which owns the WKWebView and simulates the matching vscode keybinding
    /// inside it via `SimulatedKeyCommand.dispatchScript` -- see that for
    /// exactly why this indirection exists (real hardware keypresses are
    /// deliberately NOT routed through here) and its "unverified" caveat.
    @Published var pendingKeyCommand: SimulatedKeyCommand?
}

/// A vscode keybinding to simulate inside the webview, matching the
/// KeyboardEvent fields vscode's own keybinding service reads. `key`/`code`
/// follow the DOM KeyboardEvent spec (e.g. key: "s", code: "KeyS"; key:
/// "F1", code: "F1" for function keys) -- see `dispatchScript` below.
struct SimulatedKeyCommand: Equatable {
    let key: String
    let code: String
    var metaKey = false
    var shiftKey = false
    var altKey = false
    var ctrlKey = false

    static func meta(_ key: String, code: String, shift: Bool = false) -> SimulatedKeyCommand {
        SimulatedKeyCommand(key: key, code: code, metaKey: true, shiftKey: shift)
    }

    static func ctrl(_ key: String, code: String, shift: Bool = false) -> SimulatedKeyCommand {
        SimulatedKeyCommand(key: key, code: code, shiftKey: shift, ctrlKey: true)
    }

    /// UNVERIFIED on a real device (nothing to test a WKWebView keyboard
    /// event against outside one -- see README.md's verification-tier
    /// caveats elsewhere in this project). vscode's keybinding service
    /// listens for real `keydown` DOM events, not any exposed
    /// "run this command by ID" JS API, so this dispatches a synthetic one
    /// with the same key/code/modifier fields a real keypress would carry.
    /// The real open question: whether vscode's listener checks
    /// `event.isTrusted` (`false` for anything JS-dispatched, `true` only
    /// for genuine hardware/OS input) and silently ignores this. If these
    /// native menu items turn out to do nothing when tapped, that's the
    /// first thing to check -- there is no library-level workaround short
    /// of vscode exposing a real command-execution API, which it doesn't.
    /// Dispatched on `window` (not `document.activeElement`), matching
    /// where vscode's own global keybinding listener attaches.
    var dispatchScript: String {
        let payload: [String: Any] = [
            "key": key,
            "code": code,
            "metaKey": metaKey,
            "shiftKey": shiftKey,
            "altKey": altKey,
            "ctrlKey": ctrlKey,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        return """
        (function() {
            var opts = \(json);
            opts.bubbles = true;
            opts.cancelable = true;
            window.dispatchEvent(new KeyboardEvent('keydown', opts));
            window.dispatchEvent(new KeyboardEvent('keyup', opts));
        })();
        """
    }
}
