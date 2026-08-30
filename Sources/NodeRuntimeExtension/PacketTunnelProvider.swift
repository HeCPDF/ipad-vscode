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
///
/// NOTE: the actual Node runtime bring-up (NodeMobile.xcframework) is wired
/// in a follow-up pass, once the framework's real header/API surface has
/// been inspected — see TODO below. This first pass focuses on getting the
/// extension's plumbing (network settings, lifecycle, IPC) to compile.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: "com.hecpdf.ipadvscode.noderuntime", category: "tunnel")

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
        completionHandler()
    }

    /// IPC entry point for `NETunnelProviderSession.sendProviderMessage`.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        // Placeholder echo until the real request routing to the Node
        // runtime (LSP/DAP bridge, health checks, etc.) is wired up.
        completionHandler?(messageData)
    }

    /// `node_start` runs Node's event loop and does not return in normal
    /// operation, so it must never be called on the main thread. The entry
    /// script is a placeholder — code-server's actual bundled server entry
    /// point gets baked in as an extension resource in a later pass; until
    /// then this will fail at runtime with a "module not found" from Node,
    /// which is expected and does not affect compilation.
    private func startNodeRuntime() {
        let entryScript = Bundle.main.path(forResource: "server", ofType: "js") ?? "server.js"
        let arguments = ["node", "--max-old-space-size=256", entryScript]

        DispatchQueue.global(qos: .userInitiated).async {
            var cArgs = arguments.map { strdup($0) }
            defer { cArgs.forEach { free($0) } }
            cArgs.withUnsafeMutableBufferPointer { buffer in
                _ = node_start(Int32(buffer.count), buffer.baseAddress)
            }
        }
    }
}
