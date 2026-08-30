import NetworkExtension
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

            // TODO(node-runtime): start the embedded Node engine here once
            // NodeMobile.xcframework's real API has been confirmed, e.g.
            //   NodeRunner.startEngine(withArguments: ["node", "server.js"])
            // and have server.js bind an HTTP server on
            // RuntimeConfig.loopbackPort so the app's WKWebView can load it.
            self?.log.info("tunnel settings applied; node runtime bring-up pending")
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
}
