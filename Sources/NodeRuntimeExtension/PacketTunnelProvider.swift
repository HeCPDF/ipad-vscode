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
    /// Handles a newly-picked workspace folder: resolves its bookmark,
    /// authorizes access *in this process* (a security scope started in the
    /// app doesn't extend to us — this is a separate sandboxed process), and
    /// returns the resolved path for the app to navigate the WKWebView to
    /// (`?folder=<path>`). Any request that doesn't decode as
    /// WorkspaceAuthorizationRequest is echoed back unchanged, preserving
    /// room for future message types (LSP/DAP bridge, health checks, etc.).
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        guard let request = try? JSONDecoder().decode(WorkspaceAuthorizationRequest.self, from: messageData) else {
            completionHandler?(messageData)
            return
        }

        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: request.bookmarkData,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            respond(.init(resolvedPath: nil, errorDescription: "failed to resolve bookmark"), to: completionHandler)
            return
        }

        guard url.startAccessingSecurityScopedResource() else {
            respond(.init(resolvedPath: nil, errorDescription: "startAccessingSecurityScopedResource failed"), to: completionHandler)
            return
        }

        // Only one workspace is open at a time in this design — release the
        // previous one before taking the new one.
        accessedSecurityScopedWorkspace?.stopAccessingSecurityScopedResource()
        accessedSecurityScopedWorkspace = url

        respond(.init(resolvedPath: url.path, errorDescription: nil), to: completionHandler)
    }

    private func respond(_ response: WorkspaceAuthorizationResponse, to completionHandler: ((Data?) -> Void)?) {
        completionHandler?(try? JSONEncoder().encode(response))
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
    /// No workspace path is passed on the command line — code-server starts
    /// with no folder open (its own "Editor Evolved" welcome page, matching
    /// real VSCode/code-server behavior) or reopens whatever it last had
    /// open via its own settings, exactly like the desktop app. Opening a
    /// *new* folder from this app happens later via `handleAppMessage`
    /// above plus the app navigating the WKWebView to `?folder=<path>` —
    /// this app never gates the editor itself behind a folder being picked
    /// first, matching real VSCode.
    ///
    /// If a workspace bookmark already exists (a folder picked in a
    /// previous session), it's still resolved and authorized here at
    /// startup — not to pass on the command line, but so the security scope
    /// is already active in case code-server's own last-opened-folder
    /// mechanism tries to reopen it.
    ///
    /// Not yet verified at runtime (no device/simulator in this pipeline) —
    /// this is the entry point the real server SHOULD be started with per
    /// `src/node/cli.ts`, not something that has been observed to boot.
    private func startNodeRuntime() {
        let bundledEntry = Bundle.main.bundlePath + "/code-server/out/node/entry.js"
        let placeholderEntry = Bundle.main.path(forResource: "server", ofType: "js") ?? "server.js"
        let entryScript = FileManager.default.fileExists(atPath: bundledEntry) ? bundledEntry : placeholderEntry

        if let appGroupContainer = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: RuntimeConfig.appGroupIdentifier),
            let bookmarked = WorkspaceSelection.resolveBookmark(in: appGroupContainer)
        {
            if bookmarked.startAccessingSecurityScopedResource() {
                accessedSecurityScopedWorkspace = bookmarked
            } else {
                log.error("startAccessingSecurityScopedResource failed for the previously-picked workspace folder")
            }
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
