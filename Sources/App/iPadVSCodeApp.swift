import SwiftUI

/// Targets the latest iPadOS only (see project.yml's deploymentTarget) so it
/// can lean on iPadOS 26's menu bar and windowing convergence with macOS
/// (WWDC 2025) rather than working around older, iPhone-shaped UIKit
/// defaults. `.commands {}` here is exactly the same SwiftUI API macOS apps
/// use for their menu bar — on iPadOS 26 it now also renders as a real menu
/// bar (swipe down from the top, or move a pointer there), not just as
/// keyboard-shortcut discoverability.
///
/// Multi-window support (`openWindow(id:)` below) is real, macOS-style
/// multi-window — meaningful when Stage Manager is on (each window can be
/// placed/resized independently, matching how VSCode itself lets you drag a
/// window out on macOS); with Stage Manager off there's nowhere for a
/// second freeform window to go, so the command is still reachable but
/// won't visibly do much beyond what classic multitasking already allows.
/// Not verified in either state — see README.md.
@main
struct iPadVSCodeApp: App {
    @StateObject private var menuBridge = MenuBridge()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(menuBridge)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                NewWindowButton()

                Button("Open Folder…") {
                    menuBridge.openFolderRequested = true
                }
                .keyboardShortcut("o", modifiers: .command)

                // Multi-root workspace support: adds another Files/iCloud
                // folder alongside whatever's already open (a
                // .code-workspace file, not a straight ?folder= replace —
                // see CodeWorkspaceFile.swift).
                Button("Add Folder to Workspace…") {
                    menuBridge.addFolderToWorkspaceRequested = true
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }

            // Everything below invokes a real vscode command by ID through
            // the trusted bridge code-server/patches/ios-command-bridge.diff
            // exposes on the webview's `window` — see
            // MenuBridge.NativeMenuCommand's doc comment for the whole
            // mechanism (a normal, fully-trusted function call, not a
            // simulated keypress).
            //
            // Given real `.keyboardShortcut(...)` modifiers, Electron-style:
            // confirmed on-device that leaving them unbound (the original
            // design here — see git history) doesn't just fall back to
            // vscode's own key handling, it makes the shortcut do *nothing*
            // at all. This matches how Electron VSCode actually works: the
            // OS-level menu accelerator (Cmd+S etc.) is what fires the
            // command, intercepted before the keystroke ever reaches the
            // renderer/webview — not passthrough. The real, accepted
            // tradeoff versus real Electron VSCode: these are hardcoded to
            // vscode's *default* keybinding for each command, not kept in
            // sync with the user's own keybindings.json the way Electron
            // VSCode's menu accelerators are (that would need a live
            // channel back from vscode's keybinding service into this
            // native layer, not attempted here) — so a user who has
            // remapped one of these commands' keys inside vscode will find
            // the native menu item still uses the original default key.
            CommandGroup(after: .saveItem) {
                Button("Save") {
                    menuBridge.pendingCommand = .save
                }
                .keyboardShortcut("s", modifiers: .command)
            }

            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    menuBridge.pendingCommand = .undo
                }
                .keyboardShortcut("z", modifiers: .command)
                Button("Redo") {
                    menuBridge.pendingCommand = .redo
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
            }

            CommandGroup(after: .textEditing) {
                Divider()
                Button("Find") {
                    menuBridge.pendingCommand = .find
                }
                .keyboardShortcut("f", modifiers: .command)
                Button("Find in Files…") {
                    menuBridge.pendingCommand = .findInFiles
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }

            CommandMenu("View") {
                Button("Command Palette…") {
                    menuBridge.pendingCommand = .commandPalette
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Explorer") {
                    menuBridge.pendingCommand = .explorer
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                Button("Toggle Sidebar") {
                    menuBridge.pendingCommand = .toggleSidebar
                }
                .keyboardShortcut("b", modifiers: .command)
                Button("Toggle Terminal") {
                    menuBridge.pendingCommand = .toggleTerminal
                }
                .keyboardShortcut("`", modifiers: .control)

                Divider()

                // Opens NativeWorkbenchExperimentView — an isolated screen
                // for testing the Electron-desktop-port hypothesis (see
                // README.md's "Architecture pivot" section), entirely
                // separate from the code-server flow every other item in
                // this menu talks to. No keyboard shortcut on purpose: this
                // is a debug/experiment entry point, not a normal command.
                Button("Experimental: Native Workbench…") {
                    menuBridge.nativeExperimentRequested = true
                }
            }

            CommandMenu("Go") {
                Button("Go to File…") {
                    menuBridge.pendingCommand = .goToFile
                }
                .keyboardShortcut("p", modifiers: .command)
            }

            CommandMenu("Terminal") {
                Button("New Terminal") {
                    menuBridge.pendingCommand = .newTerminal
                }
                .keyboardShortcut("`", modifiers: [.control, .shift])
            }
        }
    }
}

/// A dedicated view (rather than inlining `@Environment(\.openWindow)`
/// directly in the Commands builder) because `openWindow` is only readable
/// from a View's environment, not from `Scene.commands {}` directly.
private struct NewWindowButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Window") {
            openWindow(id: "main")
        }
        .keyboardShortcut("n", modifiers: .command)
    }
}
