import Foundation
import NetworkExtension

/// Owns the lifecycle of both packet-tunnel-provider processes:
/// NodeRuntimeExtension (runs code-server's server) and ExtensionHostRuntime
/// (runs the real Node extension host — see project.yml and
/// ExtensionHostTunnelProvider.swift for why this needs its own process
/// instead of being `cp.fork`'d the normal way).
///
/// We don't want an actual VPN — the packet-tunnel-provider extension point is
/// used only because it is the one Apple-sanctioned way to get a long-lived,
/// independently-launchable background process with a public start/stop API
/// (`NETunnelProviderManager`) and a public IPC channel
/// (`NETunnelProviderSession.sendProviderMessage`). Both extensions configure
/// a loopback-only "tunnel" that never actually routes traffic.
@MainActor
final class TunnelController: ObservableObject {
    static let shared = TunnelController()

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private var nodeRuntimeManager: NETunnelProviderManager?
    private var extensionHostManager: NETunnelProviderManager?
    private var launchRequestWatcher: DispatchSourceFileSystemObject?

    private init() {
        observeExtensionHostLaunchRequests()
    }

    deinit {
        launchRequestWatcher?.cancel()
    }

    func start() async {
        do {
            let manager = try await loadOrCreateManager(
                bundleIdentifier: "com.hecpdf.ipadvscode.noderuntime",
                description: "iPadVSCode Node Runtime"
            )
            nodeRuntimeManager = manager

            if manager.connection.status != .connected {
                try manager.connection.startVPNTunnel()
            }
            isRunning = true
        } catch {
            lastError = "\(error)"
            isRunning = false
        }
    }

    func stop() {
        nodeRuntimeManager?.connection.stopVPNTunnel()
        extensionHostManager?.connection.stopVPNTunnel()
        isRunning = false
    }

    /// Send a request to the Node runtime process and await its response.
    /// This is the IPC path for anything that doesn't go over the loopback
    /// HTTP server (e.g. lifecycle/health checks).
    func sendMessage(_ data: Data) async throws -> Data? {
        guard let session = nodeRuntimeManager?.connection as? NETunnelProviderSession else {
            throw TunnelError.notConnected
        }
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try session.sendProviderMessage(data) { response in
                    continuation.resume(returning: response)
                }
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Starts ExtensionHostRuntime. Called when the file watcher below sees
    /// NodeRuntimeExtension has written a fresh ExtensionHostLaunchRequest
    /// into the shared container and the exthost process needs to be
    /// (re)started to pick it up.
    private func startExtensionHost() async {
        do {
            let manager = try await loadOrCreateManager(
                bundleIdentifier: "com.hecpdf.ipadvscode.exthost",
                description: "iPadVSCode Extension Host"
            )
            extensionHostManager = manager
            // Always restart: ExtensionHostTunnelProvider reads the launch
            // request once, at startTunnel — an already-running instance
            // won't notice a newer request file on its own.
            manager.connection.stopVPNTunnel()
            try manager.connection.startVPNTunnel()
        } catch {
            lastError = "\(error)"
        }
    }

    /// Watches the shared App Group container for
    /// ExtensionHostLaunchRequest writes. This only runs while the app
    /// process itself is alive (foreground, or briefly backgrounded before
    /// iOS suspends it) — there is no dispatch-source equivalent that fires
    /// while fully suspended. NodeRuntimeExtension can't call back into a
    /// suspended app by any mechanism, Darwin notifications included, so
    /// this doesn't regress anything by not using those; it just also
    /// avoids needing a native (N-API) binding on the Node side purely to
    /// post one.
    private func observeExtensionHostLaunchRequests() {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: RuntimeConfig.appGroupIdentifier)
        else {
            return
        }

        let fd = open(containerURL.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            let requestURL = containerURL.appendingPathComponent(ExtensionHostLaunchRequest.fileName)
            guard FileManager.default.fileExists(atPath: requestURL.path) else { return }
            Task { @MainActor in
                await self?.startExtensionHost()
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        launchRequestWatcher = source
    }

    private func loadOrCreateManager(bundleIdentifier: String, description: String) async throws -> NETunnelProviderManager {
        let managers: [NETunnelProviderManager] = try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }

        if let existing = managers.first(where: {
            ($0.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == bundleIdentifier
        }) {
            return existing
        }

        let manager = NETunnelProviderManager()
        manager.localizedDescription = description

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = bundleIdentifier
        // No real remote endpoint — the provider never dials out.
        proto.serverAddress = "127.0.0.1"
        manager.protocolConfiguration = proto
        manager.isEnabled = true

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.saveToPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            manager.loadFromPreferences { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }

        return manager
    }
}

enum TunnelError: Error {
    case notConnected
}
