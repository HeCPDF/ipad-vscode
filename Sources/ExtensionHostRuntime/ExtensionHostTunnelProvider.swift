import NetworkExtension
import NodeMobile
import os

/// Second packet-tunnel-provider process. Its only job is to run VS Code's
/// real, unmodified Node extension host (`bootstrap-fork.js --type=extensionHost`)
/// in a process that iOS itself launched — because our own processes cannot
/// call fork()/posix_spawn() to create it themselves, which is what
/// `extensionHostConnection.ts` does on every other platform via `cp.fork`.
///
/// Launch sequence (see NodeRuntimeExtension's PacketTunnelProvider and
/// TunnelController in the App target):
///   1. code-server's server process (running in NodeRuntimeExtension) hits
///      the patched `extensionHostConnection.ts`, which — instead of
///      `cp.fork` — writes a launch-request file into the shared App Group
///      container and posts a Darwin notification.
///   2. The app (must be foreground or recently backgrounded; iOS does not
///      guarantee waking a suspended app on a Darwin notification — this is
///      a real, unresolved reliability gap, not a solved problem) observes
///      the notification and calls `startVPNTunnel()` on *this* extension's
///      NETunnelProviderManager.
///   3. This class reads that same launch-request file and execs
///      bootstrap-fork.js with matching args/env, including TMPDIR pointed
///      at the shared container so `createRandomIPCHandle()`'s socket path
///      resolves to somewhere both processes can reach.
final class ExtensionHostTunnelProvider: NEPacketTunnelProvider {
    private let log = Logger(subsystem: "com.hecpdf.ipadvscode.exthost", category: "tunnel")

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
            self?.startExtensionHost()
            completionHandler(nil)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        log.info("stopTunnel: \(String(describing: reason))")
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        completionHandler?(messageData)
    }

    /// Reads the launch request NodeRuntimeExtension wrote into the shared
    /// App Group container and execs bootstrap-fork.js with matching
    /// args/env. See ExtensionHostLaunchRequest in Sources/Shared for the
    /// file format both sides agree on.
    private func startExtensionHost() {
        guard let containerURL = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: RuntimeConfig.appGroupIdentifier)
        else {
            log.error("no App Group container — cannot locate launch request or shared TMPDIR")
            return
        }

        // Both processes must resolve createRandomIPCHandle()'s socket path
        // to the same filesystem location, which only the shared container
        // guarantees across two separate extension sandboxes.
        setenv("TMPDIR", containerURL.path, 1)

        let requestURL = containerURL.appendingPathComponent(ExtensionHostLaunchRequest.fileName)
        guard
            let data = try? Data(contentsOf: requestURL),
            let request = try? JSONDecoder().decode(ExtensionHostLaunchRequest.self, from: data)
        else {
            log.info("no pending extension host launch request at \(requestURL.path, privacy: .public) — idling")
            return
        }

        var arguments = ["node", request.bootstrapForkPath]
        arguments += request.args

        DispatchQueue.global(qos: .userInitiated).async {
            for (key, value) in request.env {
                setenv(key, value, 1)
            }
            var cArgs = arguments.map { strdup($0) }
            defer { cArgs.forEach { free($0) } }
            cArgs.withUnsafeMutableBufferPointer { buffer in
                _ = node_start(Int32(buffer.count), buffer.baseAddress)
            }
        }
    }
}
