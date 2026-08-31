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

    /// Where node-stdio.log lives. Deliberately under Documents rather than
    /// Application Support (unlike privateStorageURL above): a real-device
    /// sysdiagnose confirmed the whole host app dies (Node's uncaught-
    /// exception handler calling process.exit(), see
    /// NodeRuntimeController.redirectStderrToFile) well under a second after
    /// launch, before any UI can render -- so there's never a moment to show
    /// this log on-screen or offer a share sheet. Documents plus
    /// UIFileSharingEnabled/LSSupportsOpeningDocumentsInPlace (project.yml)
    /// makes it show up directly in the iPad's own Files app afterward,
    /// which is the only way to get it off the device at all when the only
    /// hardware available is the iPad itself -- no Mac/Xcode to pull the app
    /// container.
    static var diagnosticsURL: URL {
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Diagnostics", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
