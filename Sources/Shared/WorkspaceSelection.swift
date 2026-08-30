import Foundation

/// Where the App persists the user's chosen workspace folder across
/// process restarts. Written as a security-scoped bookmark (not a raw
/// path) because the folder can live outside our sandbox (Files/iCloud
/// Drive) — only a resolved bookmark grants access across launches; a
/// plain path does not.
enum WorkspaceSelection {
    static let bookmarkFileName = "workspace-bookmark.data"

    /// Resolves the stored bookmark (if any) to a URL usable right now,
    /// re-persisting it if the system handed back a stale bookmark. Must be
    /// paired with `startAccessingSecurityScopedResource()` /
    /// `stopAccessingSecurityScopedResource()` around actual file access —
    /// callers are responsible for that (the app process's lifetime is the
    /// natural scope: start when NodeRuntimeController launches the Node
    /// runtime).
    static func resolveBookmark(in containerURL: URL) -> URL? {
        let bookmarkURL = containerURL.appendingPathComponent(bookmarkFileName)
        guard let data = try? Data(contentsOf: bookmarkURL) else { return nil }

        var isStale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }

        if isStale {
            store(url: resolved, in: containerURL)
        }
        return resolved
    }

    /// Called from the App after the user picks a folder via
    /// UIDocumentPickerViewController.
    @discardableResult
    static func store(url: URL, in containerURL: URL) -> Bool {
        guard let data = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return false
        }
        let bookmarkURL = containerURL.appendingPathComponent(bookmarkFileName)
        return (try? data.write(to: bookmarkURL, options: .atomic)) != nil
    }
}
