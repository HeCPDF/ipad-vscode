import NetworkExtension
import NodeMobile
import os

/// This is not a real VPN. `com.apple.developer.networking.networkextension`
/// (packet-tunnel-provider) is the one Apple-sanctioned extension point that
/// gives us a long-lived, independently-launchable background *process* with
/// a public start API (`NETunnelProviderManager.connection.startVPNTunnel()`)
/// and a public bidirectional IPC channel
/// (`NETunnelProviderSession.sendProviderMessage`). We configure a loopback
/// "tunnel" that never routes real traffic, and use the process purely as a
/// host for the embedded Node runtime that serves the editor UI over
/// 127.0.0.1.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: "com.hecpdf.ipadvscode.noderuntime", category: "tunnel")
    private var accessedSecurityScopedWorkspace: URL?

    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        log.info("startTunnel")

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.ipv4Settings = NEIPv4Settings(addresses: ["127.0.0.1"], subnetMasks: ["255.255.255.255"])
        settings.ipv4Settings?.includedRoutes = []
        settings.mtu = 1500

        setTunnelNetworkSettings(settings) { [weak self] error in
            if let error {
                self?.log.error("setTunnelNetworkSettings failed: \(String(describing: error))")
                completionHandler(error)
                return
            }

            self?.log.info("tunnel settings applied; starting node runtime")
            self?.startNodeRuntime()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.info("stopTunnel: \(String(describing: reason))")
        accessedSecurityScopedWorkspace?.stopAccessingSecurityScopedResource()
        accessedSecurityScopedWorkspace = nil
        completionHandler()
    }

    /// IPC entry point for `NETunnelProviderSession.sendProviderMessage`.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Placeholder echo until the real request routing to the Node
        // runtime (LSP/DAP bridge, health checks, etc.) is wired up.
        completionHandler?(messageData)
    }

    /// `node_start` runs Node's event loop and does not return in normal
    /// operation, so it must never be called on the main thread.
    ///
    /// This launches code-server's real, unmodified entry point (the only
    /// thing scripts/trim-code-server.sh removes is node-pty, which needs a
    /// real kernel pty that iOS denies outright — see that script for why
    /// this is a hard wall, not a convenience cut) rather than the toy
    /// placeholder server. `--auth none` is a local default, not a feature
    /// removal: this process is unreachable from outside the device (the
    /// tunnel's network settings are loopback-only, nothing forwards the
    /// port externally), so there is no one to authenticate against.
    ///
    /// Not yet verified at runtime (no device/simulator in this pipeline) —
    /// this is the entry point the real server SHOULD be started with per
    /// `src/node/cli.ts`, not something that has been observed to boot.
    private func startNodeRuntime() {
        let bundledEntry = Bundle.main.bundlePath + "/code-server/out/node/entry.js"
        let placeholderEntry = Bundle.main.path(forResource: "server", ofType: "js") ?? "server.js"
        let entryScript = FileManager.default.fileExists(atPath: bundledEntry) ? bundledEntry : placeholderEntry

        let appGroupContainer = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: RuntimeConfig.appGroupIdentifier)

        // The user's chosen folder (via UIDocumentPickerViewController in the
        // App) can live outside our sandbox entirely — Files/iCloud Drive —
        // so it's stored as a security-scoped bookmark, not a plain path.
        // Falls back to a folder inside our own App Group container (no
        // bookmark needed there) if nothing has been picked yet.
        let workspaceRoot: URL
        let needsSecurityScope: Bool
        if let appGroupContainer, let bookmarked = WorkspaceSelection.resolveBookmark(in: appGroupContainer) {
            workspaceRoot = bookmarked
            needsSecurityScope = true
        } else if let appGroupContainer {
            let fallback = appGroupContainer.appendingPathComponent("workspace", isDirectory: true)
            try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
            workspaceRoot = fallback
            needsSecurityScope = false
        } else {
            log.error("no App Group container — cannot resolve a workspace root")
            return
        }

        if needsSecurityScope {
            guard workspaceRoot.startAccessingSecurityScopedResource() else {
                log.error("startAccessingSecurityScopedResource failed for the picked workspace folder")
                return
            }
            // node_start() blocks running the event loop for the lifetime of
            // this process, so the matching stop call belongs in
            // stopTunnel(), not here — see the property below.
            accessedSecurityScopedWorkspace = workspaceRoot
        }

        var arguments = [
            "node",
            "--max-old-space-size=256",
            entryScript,
        ]
        if entryScript == bundledEntry {
            arguments += [
                "--auth", "none",
                "--bind-addr", "127.0.0.1:\(RuntimeConfig.loopbackPort)",
                "--disable-telemetry",
                "--disable-update-check",
            ]
            arguments.append(workspaceRoot.path)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            if entryScript == bundledEntry, let containerURL = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: RuntimeConfig.appGroupIdentifier)
            {
                // Picked up by the ios-exthost-no-fork.diff patch in
                // extensionHostConnection.ts: routes the extension host
                // launch through ExtensionHostRuntime instead of cp.fork(),
                // and TMPDIR must match what that second process sets so
                // createRandomIPCHandle()'s socket path resolves for both.
                setenv("IPADVSCODE_NO_FORK", "1", 1)
                setenv("IPADVSCODE_SHARED_CONTAINER", containerURL.path, 1)
                setenv("TMPDIR", containerURL.path, 1)
            }
            var cArgs = arguments.map { strdup($0) }
            defer { cArgs.forEach { free($0) } }
            cArgs.withUnsafeMutableBufferPointer { buffer in
                _ = node_start(Int32(buffer.count), buffer.baseAddress)
            }
        }
    }
}
