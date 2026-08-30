import Foundation

/// The loopback port code-server's HTTP server binds to, plus where the
/// workspace bookmark and multi-root `.code-workspace` file live.
enum RuntimeConfig {
    static let loopbackPort = 8482

    static var loopbackURL: URL {
        URL(string: "http://127.0.0.1:\(loopbackPort)/")!
    }

    /// Private per-app storage. Previously an App Group shared container
    /// (needed to hand data between the App and two NEPacketTunnelProvider
    /// extensions); now just this app's own Application Support directory,
    /// since code-server and the extension host both run in this single
    /// process — see NodeRuntimeController.swift and README.md.
    static var privateStorageURL: URL {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iPadVSCode", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
