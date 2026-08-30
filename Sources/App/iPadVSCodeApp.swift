import SwiftUI

/// Targets the latest iPadOS only (see project.yml's deploymentTarget) so it
/// can lean on iPadOS 26's menu bar and windowing convergence with macOS
/// (WWDC 2025) rather than working around older, iPhone-shaped UIKit
/// defaults. `.commands {}` here is exactly the same SwiftUI API macOS apps
/// use for their menu bar — on iPadOS 26 it now also renders as a real menu
/// bar (swipe down from the top, or move a pointer there), not just as
/// keyboard-shortcut discoverability.
@main
struct iPadVSCodeApp: App {
    @StateObject private var menuBridge = MenuBridge()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(menuBridge)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Folder…") {
                    menuBridge.openFolderRequested = true
                }
                .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
