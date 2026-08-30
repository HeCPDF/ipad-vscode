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
    /// addFolderToWorkspace(_:).
    @Published var addFolderToWorkspaceRequested = false
}
