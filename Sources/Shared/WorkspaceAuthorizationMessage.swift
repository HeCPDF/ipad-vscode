import Foundation

/// Sent over `NETunnelProviderSession.sendProviderMessage` when the app
/// picks a new folder (via the native document picker) while
/// NodeRuntimeExtension is already running. The extension resolves the
/// bookmark, calls `startAccessingSecurityScopedResource()` in *its own*
/// process (the one that will actually do the file I/O — a security scope
/// started in the app doesn't carry over to the extension process), and
/// replies with the resolved absolute path so the app knows what to put in
/// code-server's `?folder=` query parameter
/// (`req.query.folder` in `code-server/src/node/routes/vscode.ts`).
struct WorkspaceAuthorizationRequest: Codable {
    let bookmarkData: Data
}

struct WorkspaceAuthorizationResponse: Codable {
    let resolvedPath: String?
    let errorDescription: String?
}
