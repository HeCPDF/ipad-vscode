import Foundation

/// Shared between the App and NodeRuntimeExtension targets: the loopback
/// port the Node runtime's HTTP server binds to, and the App Group used to
/// share a workspace directory between them.
enum RuntimeConfig {
    static let loopbackPort = 8482
    static let appGroupIdentifier = "group.com.hecpdf.ipadvscode"

    static var loopbackURL: URL {
        URL(string: "http://127.0.0.1:\(loopbackPort)/")!
    }
}
