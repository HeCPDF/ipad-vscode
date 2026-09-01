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
            // Still deliberately NOT given `.keyboardShortcut(...)`
            // modifiers, even though the reliability concern that
            // originally motivated this is gone (this isn't simulated
            // input anymore): binding one here would make SwiftUI's menu
            // system intercept the real hardware keypress before it ever
            // reaches the webview, forcing it to always run this fixed
            // command — which is wrong the moment the user has remapped
            // that physical key to something else inside vscode itself.
            // Leaving it unbound means a real keypress keeps going through
            // vscode's own (possibly user-customized) keybinding
            // resolution untouched; only a mouse/trackpad/tap click on the
            // menu item — which has no keybinding to respect in the first
            // place — goes through this bridge.
            CommandGroup(after: .saveItem) {
                Button("Save") {
                    menuBridge.pendingCommand = .save
                }
            }

            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    menuBridge.pendingCommand = .undo
                }
                Button("Redo") {
                    menuBridge.pendingCommand = .redo
                }
            }

            CommandGroup(after: .textEditing) {
                Divider()
                Button("Find") {
                    menuBridge.pendingCommand = .find
                }
                Button("Find in Files…") {
                    menuBridge.pendingCommand = .findInFiles
                }
            }

            CommandMenu("View") {
                Button("Command Palette…") {
                    menuBridge.pendingCommand = .commandPalette
                }
                Button("Explorer") {
                    menuBridge.pendingCommand = .explorer
                }
                Button("Toggle Sidebar") {
                    menuBridge.pendingCommand = .toggleSidebar
                }
                Button("Toggle Terminal") {
                    menuBridge.pendingCommand = .toggleTerminal
                }
            }

            CommandMenu("Go") {
                Button("Go to File…") {
                    menuBridge.pendingCommand = .goToFile
                }
            }

            CommandMenu("Terminal") {
                Button("New Terminal") {
                    menuBridge.pendingCommand = .newTerminal
                }
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
