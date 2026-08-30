import SwiftUI

/// Commands declared in `.commands {}` (the App scene's menu bar / iPadOS 26
/// menu bar) live outside ContentView's local @State, so they need a shared
/// object to actually trigger UI state changes in the view hierarchy.
@MainActor
final class MenuBridge: ObservableObject {
    @Published var openFolderRequested = false
}
