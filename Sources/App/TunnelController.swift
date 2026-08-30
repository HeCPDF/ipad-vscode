import Foundation
import NetworkExtension

/// Owns the lifecycle of the NodeRuntimeExtension packet-tunnel-provider process.
///
/// We don't want an actual VPN — the packet-tunnel-provider extension point is
/// used only because it is the one Apple-sanctioned way to get a long-lived,
/// independently-launchable background process with a public start/stop API
/// (`NETunnelProviderManager`) and a public IPC channel
/// (`NETunnelProviderSession.sendProviderMessage`). The extension configures a
/// loopback-only "tunnel" that never actually routes traffic.
@MainActor
final class TunnelController: ObservableObject {
    static let shared = TunnelController()

    @Published private(set) var isRunning = false
    @Published private(set) var lastError: String?

    private var manager: NETunnelProviderManager?

    private init() {}

    func start() async {
        do {
            let manager = try await loadOrCreateManager()
            self.manager = manager

            if manager.connection.status == .connected {
                isRunning = true
                return
            }

            try manager.connection.startVPNTunnel()
            isRunning = true
        } catch {
            lastError = "\(error)"
            isRunning = false
        }
    }

    func stop() {
        manager?.connection.stopVPNTunnel()
        isRunning = false
    }

    /// Send a request to the Node runtime process and await its response.
    /// This is the IPC path for anything that doesn't go over the loopback
    /// HTTP server (e.g. lifecycle/health checks).
    func sendMessage(_ data: Data) async throws -> Data? {
        guard let session = manager?.connection as? NETunnelProviderSession else {
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

    private func loadOrCreateManager() async throws -> NETunnelProviderManager {
        let managers: [NETunnelProviderManager] = try await withCheckedThrowingContinuation { continuation in
            NETunnelProviderManager.loadAllFromPreferences { managers, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: managers ?? [])
                }
            }
        }

        if let existing = managers.first {
            return existing
        }

        let manager = NETunnelProviderManager()
        manager.localizedDescription = "iPadVSCode Node Runtime"

        let proto = NETunnelProviderProtocol()
        proto.providerBundleIdentifier = "com.hecpdf.ipadvscode.noderuntime"
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
