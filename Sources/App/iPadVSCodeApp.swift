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

            // Everything below dispatches a simulated vscode keybinding
            // into the webview instead of doing anything itself — see
            // MenuBridge.SimulatedKeyCommand.dispatchScript for the whole
            // mechanism and its real "does vscode ignore untrusted
            // KeyboardEvents" open question, unverified on-device as of
            // this writing.
            //
            // Deliberately NOT given `.keyboardShortcut(...)` modifiers:
            // doing so would make SwiftUI's menu system intercept the real
            // hardware keypress before it ever reaches the webview, which
            // — for exactly these commands — already works today via plain
            // passthrough (WKWebView delivers real hardware key events to
            // the page as trusted DOM events, no native involvement
            // needed). Binding a shortcut here would trade a
            // known-working, trusted path for an unverified, untrusted
            // one. These menu items exist purely for mouse/trackpad/tap
            // discoverability — a real keypress skips this file entirely.
            CommandGroup(after: .saveItem) {
                Button("Save") {
                    menuBridge.pendingKeyCommand = .meta("s", code: "KeyS")
                }
            }

            CommandGroup(replacing: .undoRedo) {
                Button("Undo") {
                    menuBridge.pendingKeyCommand = .meta("z", code: "KeyZ")
                }
                Button("Redo") {
                    menuBridge.pendingKeyCommand = .meta("z", code: "KeyZ", shift: true)
                }
            }

            CommandGroup(after: .textEditing) {
                Divider()
                Button("Find") {
                    menuBridge.pendingKeyCommand = .meta("f", code: "KeyF")
                }
                Button("Find in Files…") {
                    menuBridge.pendingKeyCommand = .meta("f", code: "KeyF", shift: true)
                }
            }

            CommandMenu("View") {
                Button("Command Palette…") {
                    menuBridge.pendingKeyCommand = .meta("p", code: "KeyP", shift: true)
                }
                Button("Explorer") {
                    menuBridge.pendingKeyCommand = .meta("e", code: "KeyE", shift: true)
                }
                Button("Toggle Sidebar") {
                    menuBridge.pendingKeyCommand = .meta("b", code: "KeyB")
                }
                Button("Toggle Terminal") {
                    menuBridge.pendingKeyCommand = .ctrl("`", code: "Backquote")
                }
            }

            CommandMenu("Go") {
                Button("Go to File…") {
                    menuBridge.pendingKeyCommand = .meta("p", code: "KeyP")
                }
            }

            CommandMenu("Terminal") {
                Button("New Terminal") {
                    menuBridge.pendingKeyCommand = .ctrl("`", code: "Backquote", shift: true)
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
