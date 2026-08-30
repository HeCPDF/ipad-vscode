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
