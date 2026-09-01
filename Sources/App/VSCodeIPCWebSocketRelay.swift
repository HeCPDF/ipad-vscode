import Foundation

/// Connects `VSCodeIPCBridge`'s raw frame stream to the real backend:
/// code-server's own `/ipad-vscode-ipc` WebSocket route
/// (`code-server/src/node/routes/ipadVSCodeIpc.ts`), which hosts a real
/// `PortChannelServer` (`code-server/src/node/ipadVSCodeIpc.ts`) speaking
/// vscode's actual IPC wire protocol. This class only relays bytes; it has
/// no idea what's inside a `vscode:message` frame — same division of
/// responsibility as `VSCodeIPCBridge` on the WKWebView side.
///
/// Loopback-only, same origin code-server's HTTP server already serves
/// from (`RuntimeConfig.loopbackURL`/`RuntimeConfig.loopbackPort`) — this
/// reuses that already-running, already-verified-reachable server rather
/// than opening a second listener, matching this project's established
/// pattern of routing new native-facing endpoints through the one Node
/// process that's already up (see `ios-command-bridge.diff` for the
/// equivalent choice on the command-execution side).
@MainActor
final class VSCodeIPCWebSocketRelay: NSObject {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private weak var bridge: VSCodeIPCBridge?
    private var reconnectAttempts = 0
    private var manuallyDisconnected = false

    // Same retry budget as EditorWebView.Coordinator's initial-load retry
    // (ContentView.swift) -- both exist for the identical reason:
    // code-server's Node runtime has real startup work to do (parse args,
    // write config, build the Express app, call listen()) before this
    // route exists at all, and there's no readiness signal to wait on
    // instead. Bounded, not indefinite: a persistent failure past this
    // window is a real problem worth surfacing, not silently retrying
    // forever.
    private let maxReconnectAttempts = 40
    private let reconnectDelay: TimeInterval = 0.5

    /// `bridge.onFrame` is claimed exclusively by this relay once
    /// connected — there is only ever one real backend per bridge
    /// instance, matching `VSCodeIPCBridge.onFrame`'s own doc comment
    /// ("a plain callback, not multicast, on purpose").
    func connect(bridge: VSCodeIPCBridge) {
        self.bridge = bridge
        manuallyDisconnected = false
        bridge.onFrame = { [weak self] frame in
            self?.handleOutgoingFrame(frame)
        }
        openSocket()
    }

    func disconnect() {
        manuallyDisconnected = true
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func openSocket() {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = "127.0.0.1"
        components.port = RuntimeConfig.loopbackPort
        components.path = "/ipad-vscode-ipc/"
        guard let url = components.url else { return }

        let session = URLSession(configuration: .default)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()
        receiveLoop()
    }

    private func scheduleReconnect() {
        guard !manuallyDisconnected, reconnectAttempts < maxReconnectAttempts else { return }
        reconnectAttempts += 1
        session?.invalidateAndCancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + reconnectDelay) { [weak self] in
            self?.openSocket()
        }
    }

    /// A `VSCodeIPCBridge.Frame` sent up from the page (JS→native).
    /// `.hello`/`.disconnect` carry no payload of their own on the wire
    /// here — the WebSocket connection's own lifecycle (open/close) IS
    /// the hello/disconnect signal for `PortChannelServer` (it sends its
    /// `Initialize` response as soon as a connection is accepted, and
    /// tears down on close — see that class's constructor/`onClose`
    /// handling), so only `.message` needs forwarding as a real frame.
    private func handleOutgoingFrame(_ frame: VSCodeIPCBridge.Frame) {
        switch frame {
        case .hello:
            break
        case .message(let data):
            task?.send(.data(data)) { error in
                if let error {
                    // Best-effort: the far side (code-server's Node
                    // process) may be mid-restart or the socket may have
                    // dropped between frames. Nothing productive to do
                    // here beyond not crashing — the next frame attempt
                    // will surface the same failure again if it persists.
                    print("VSCodeIPCWebSocketRelay: send failed: \(error)")
                }
            }
        case .disconnect:
            disconnect()
        }
    }

    /// Native→page delivery: whatever `PortChannelServer` sends back over
    /// the WebSocket is handed to `VSCodeIPCBridge.send(_:)` verbatim,
    /// which relays it into the page as a `vscode:message` event via
    /// `evaluateJavaScript` — see that class's own doc comment.
    private func receiveLoop() {
        task?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let message):
                // A successful receive proves the handshake completed --
                // reset the retry budget so a later, unrelated drop (not
                // "server wasn't up yet") gets its own full retry window.
                self.reconnectAttempts = 0
                switch message {
                case .data(let data):
                    self.bridge?.send(data)
                case .string(let text):
                    // Out-of-band JSON pushes only (see
                    // IPCRawTransport.sendText's doc comment in
                    // code-server/src/node/ipadVSCodeIpc.ts) — the RPC
                    // wire protocol itself is binary-only, so a text
                    // frame is always one of these envelopes, never an
                    // RPC reply.
                    self.handleOutOfBandText(text)
                @unknown default:
                    break
                }
                self.receiveLoop()
            case .failure(let error):
                print("VSCodeIPCWebSocketRelay: receive failed (attempt \(self.reconnectAttempts + 1)/\(self.maxReconnectAttempts)): \(error)")
                self.scheduleReconnect()
            }
        }
    }

    /// Envelope shape: `{"kind": "menubarUpdate", "data": <IMenubarData>}`
    /// (see the `menubar` channel, code-server/src/node/routes/ipadVSCodeIpc.ts).
    /// `kind` exists so this dispatch can grow to other out-of-band push
    /// types later without a shape change here — currently `menubarUpdate`
    /// is the only one sent.
    private func handleOutOfBandText(_ text: String) {
        guard let envelope = text.data(using: .utf8),
            let json = try? JSONSerialization.jsonObject(with: envelope) as? [String: Any],
            let kind = json["kind"] as? String
        else {
            print("VSCodeIPCWebSocketRelay: unparseable out-of-band text frame: \(text)")
            return
        }
        switch kind {
        case "menubarUpdate":
            guard let data = json["data"],
                let dataJSON = try? JSONSerialization.data(withJSONObject: data)
            else { return }
            NativeMenubarStore.shared.ingest(rawMenubarDataJSON: dataJSON)
        default:
            print("VSCodeIPCWebSocketRelay: unknown out-of-band push kind '\(kind)'")
        }
    }
}
