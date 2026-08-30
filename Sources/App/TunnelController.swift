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

    private init() {
        observeExtensionHostLaunchRequests()
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

    /// Starts ExtensionHostRuntime. Called when NodeRuntimeExtension signals
    /// (via Darwin notification) that it has written an
    /// ExtensionHostLaunchRequest and needs the exthost process running.
    private func startExtensionHost() async {
        do {
            let manager = try await loadOrCreateManager(
                bundleIdentifier: "com.hecpdf.ipadvscode.exthost",
                description: "iPadVSCode Extension Host"
            )
            extensionHostManager = manager
            if manager.connection.status != .connected {
                try manager.connection.startVPNTunnel()
            }
        } catch {
            lastError = "\(error)"
        }
    }

    private func observeExtensionHostLaunchRequests() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        let observer = Unmanaged.passUnretained(self).toOpaque()
        CFNotificationCenterAddObserver(
            center,
            observer,
            { _, observer, _, _, _ in
                guard let observer else { return }
                let controller = Unmanaged<TunnelController>.fromOpaque(observer).takeUnretainedValue()
                Task { @MainActor in
                    await controller.startExtensionHost()
                }
            },
            exthostLaunchRequestNotificationName,
            nil,
            .deliverImmediately
        )
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
