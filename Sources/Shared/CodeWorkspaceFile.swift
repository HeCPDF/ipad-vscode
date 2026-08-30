import Foundation

/// Writes/updates a `.code-workspace` file in this app's private storage
/// so multiple, independently-authorized Files/iCloud folders can be
/// opened together as a real VSCode multi-root workspace — not just the
/// single folder `?folder=` supports. Format confirmed from vscode source
/// (`IStoredWorkspace` in `vs/platform/workspaces/common/workspaces.ts`):
/// `{ folders: [{ path: string }, ...] }`. code-server opens it via
/// `?workspace=<path>` when the path's extension is `.code-workspace`
/// (`IS_WORKSPACE_FILE` in `src/node/routes/vscode.ts`).
enum CodeWorkspaceFile {
    static let fileName = "ipadvscode.code-workspace"

    struct StoredWorkspace: Codable {
        struct Folder: Codable {
            let path: String
        }
        var folders: [Folder]
    }

    /// Adds `folderPath` to the persisted folder list (no-op if already
    /// present) and returns the resulting `.code-workspace` file's path.
    static func addFolder(_ folderPath: String, in containerURL: URL) -> String? {
        let fileURL = containerURL.appendingPathComponent(fileName)

        var stored: StoredWorkspace
        if let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode(StoredWorkspace.self, from: data)
        {
            stored = decoded
        } else {
            stored = StoredWorkspace(folders: [])
        }

        if !stored.folders.contains(where: { $0.path == folderPath }) {
            stored.folders.append(.init(path: folderPath))
        }

        guard let data = try? JSONEncoder().encode(stored) else { return nil }
        guard (try? data.write(to: fileURL, options: .atomic)) != nil else { return nil }
        return fileURL.path
    }
}
