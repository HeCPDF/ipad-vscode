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
    /// the item) and consumed by ContentView, which owns the WKWebView and
    /// runs `NativeMenuCommand.dispatchScript` in it. See that type's doc
    /// comment for the whole mechanism.
    @Published var pendingCommand: NativeMenuCommand?

    /// Presents NativeWorkbenchExperimentView — see that type's doc comment.
    /// Entirely separate from the code-server flow above; doesn't touch
    /// `pendingCommand`/the webview it dispatches into.
    @Published var nativeExperimentRequested = false
}

/// A real vscode command, invoked by ID through the trusted bridge
/// `code-server/patches/ios-command-bridge.diff` exposes on `mainWindow`
/// (`__ipadVSCodeExecuteCommand`), not by simulating the keybinding that
/// would normally trigger it. That patch's own header has the full
/// reasoning; short version: vscode's keybinding service listens for real
/// `keydown` DOM events and simulating one is both unverifiable (an
/// untrusted synthetic KeyboardEvent might just get filtered out) and
/// wrong the moment a user remaps the command's key in their own
/// keybindings.json. Calling `ICommandService.executeCommand(id)` directly
/// is a normal, fully-trusted function call — no synthetic input event
/// involved at all — and doesn't care what key (if any) the command is
/// bound to.
struct NativeMenuCommand: Equatable {
    let commandId: String

    static let save = NativeMenuCommand(commandId: "workbench.action.files.save")
    static let undo = NativeMenuCommand(commandId: "undo")
    static let redo = NativeMenuCommand(commandId: "redo")
    static let find = NativeMenuCommand(commandId: "actions.find")
    static let findInFiles = NativeMenuCommand(commandId: "workbench.action.findInFiles")
    static let commandPalette = NativeMenuCommand(commandId: "workbench.action.showCommands")
    static let explorer = NativeMenuCommand(commandId: "workbench.view.explorer")
    static let toggleSidebar = NativeMenuCommand(commandId: "workbench.action.toggleSidebarVisibility")
    static let toggleTerminal = NativeMenuCommand(commandId: "workbench.action.terminal.toggleTerminal")
    static let newTerminal = NativeMenuCommand(commandId: "workbench.action.terminal.new")
    static let goToFile = NativeMenuCommand(commandId: "workbench.action.quickOpen")

    /// `window.__ipadVSCodeExecuteCommand` only exists once
    /// `Workbench.startup()` has run (see the patch), which is well before
    /// a user could reach the native menu bar in practice, but the
    /// existence check keeps a click during that narrow startup window a
    /// silent no-op instead of a JS exception logged to nowhere the user
    /// can see.
    var dispatchScript: String {
        let json = (try? JSONSerialization.data(withJSONObject: [commandId]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        return """
        (function() {
            var args = \(json);
            if (typeof window.__ipadVSCodeExecuteCommand === 'function') {
                window.__ipadVSCodeExecuteCommand(args[0]);
            }
        })();
        """
    }
}
