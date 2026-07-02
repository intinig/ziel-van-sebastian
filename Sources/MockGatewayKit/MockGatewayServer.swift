import Foundation
import Network

/// Minimal OpenClaw-gateway-shaped WebSocket server for tests and demos.
/// Accepts one or more connections; each gets: connect handshake
/// (token-checked if expectToken is set), then the scripted steps.
public final class MockGatewayServer {
    private let listener: NWListener
    private let expectToken: String?
    private let requireDeviceAuth: Bool
    private let steps: [MockStep]
    private let queue = DispatchQueue(label: "mock-gateway")
    private var connections: [NWConnection] = []

    /// When true, the server never sends the sessions.subscribe response,
    /// proving that channel frames sent before subscription are gated.
    private let dropSubscribeResponse: Bool

    /// True once any client has sent a sessions.subscribe request.
    /// Serialized through `queue` so cross-thread reads have a happens-before edge.
    private var _didReceiveSubscribe = false
    public var didReceiveSubscribe: Bool { queue.sync { _didReceiveSubscribe } }

    /// All post-handshake client request frames received so far, in order.
    /// Serialized through `queue` so cross-thread reads have a happens-before edge.
    private var _receivedFrames: [[String: Any]] = []
    public var receivedFrames: [[String: Any]] { queue.sync { _receivedFrames } }

    /// Tracks which connections have successfully subscribed (by ObjectIdentifier).
    private var subscribedConnections: Set<ObjectIdentifier> = []

    /// Connections whose scenario playback has already been kicked off, so the
    /// deferred (subscribe-triggered) start can't double-fire.
    private var playbackStarted: Set<ObjectIdentifier> = []

    /// True if the scenario contains any channel-session frame, in which case
    /// playback is deferred until the connection subscribes (real gateways only
    /// stream sessions.changed / session.message to subscribers). Computed once.
    private lazy var scenarioHasChannelFrames: Bool =
        steps.contains { $0.frame.map(isChannelFrame) ?? false }

    /// Port 0 → ephemeral; read `port` after start() returns.
    public private(set) var port: UInt16 = 0

    public init(requestedPort: UInt16, expectToken: String? = nil,
                requireDeviceAuth: Bool = false, steps: [MockStep],
                dropSubscribeResponse: Bool = false) throws {
        self.expectToken = expectToken
        self.requireDeviceAuth = requireDeviceAuth
        self.steps = steps
        self.dropSubscribeResponse = dropSubscribeResponse
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        self.listener = try NWListener(
            using: params,
            on: requestedPort == 0 ? .any : NWEndpoint.Port(rawValue: requestedPort)!
        )
    }

    /// Starts listening; returns once the port is bound.
    public func start() throws {
        let ready = DispatchSemaphore(value: 0)
        var startupError: Error?
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.signal()
            case .failed(let error):
                startupError = error
                ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut {
            throw NSError(domain: "MockGateway", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener never became ready"])
        }
        if let e = startupError { throw e }
    }

    public func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        connections.append(conn)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            if case .cancelled = state { self?.prune(conn) }
            if case .failed = state { self?.prune(conn) }
        }
        conn.start(queue: queue)
        // Real gateway pushes a challenge at socket open; device-auth clients
        // must echo its nonce inside the signed payload.
        let nonce = UUID().uuidString
        send(conn, obj: [
            "type": "event", "event": "connect.challenge",
            "payload": ["nonce": nonce, "ts": 0],
        ])
        receiveHandshake(conn, nonce: nonce)
    }

    private func prune(_ conn: NWConnection?) {
        guard let conn else { return }
        let key = ObjectIdentifier(conn)
        subscribedConnections.remove(key)
        playbackStarted.remove(key)
        connections.removeAll { $0 === conn }
    }

    private func receiveHandshake(_ conn: NWConnection, nonce: String) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data else { return }
            guard
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                obj["type"] as? String == "req",
                obj["method"] as? String == "connect",
                let id = obj["id"] as? String
            else {
                conn.cancel()
                return
            }
            let params = obj["params"] as? [String: Any]
            let auth = params?["auth"] as? [String: Any]
            let token = auth?["token"] as? String

            if let expected = self.expectToken, token != expected {
                // Send the rejection frame, then cancel only after the send completes
                // so the client can observe the ok:false response before the close.
                self.sendThenClose(conn, obj: [
                    "type": "res", "id": id, "ok": false,
                    "error": ["code": "UNAUTHORIZED", "message": "bad token"],
                ])
                return
            }
            if self.requireDeviceAuth,
               let failure = DeviceAuthVerifier.verify(params: params ?? [:], expectedNonce: nonce) {
                self.sendThenClose(conn, obj: [
                    "type": "res", "id": id, "ok": false,
                    "error": ["code": "DEVICE_AUTH_FAILED", "message": failure],
                ])
                return
            }
            // Mirror the real gateway: device-verified clients keep their requested
            // scopes; device-less clients get scopes cleared.
            let role = params?["role"] as? String ?? "operator"
            let scopes = self.requireDeviceAuth ? (params?["scopes"] as? [String] ?? []) : []
            self.send(conn, obj: [
                "type": "res", "id": id, "ok": true,
                "payload": ["type": "hello-ok", "protocol": 4,
                            "auth": ["role": role, "scopes": scopes]],
            ])
            // Channel scenarios wait for sessions.subscribe (see drainRequests) so
            // the first channel frame provably arrives after the connection is
            // subscribed — no race against the subscribe round-trip. Pure
            // agent-stream scenarios keep their handshake-relative timeline.
            if !self.scenarioHasChannelFrames {
                self.startPlayback(on: conn)
            }
            self.drainRequests(conn)
        }
    }

    /// Answer any post-connect requests generically so clients don't hang.
    /// sessions.subscribe requests get a proper subscribed:true response and
    /// mark the connection as subscribed (enabling channel-session frame delivery).
    private func drainRequests(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data else { return }
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               obj["type"] as? String == "req", let id = obj["id"] as? String {
                // On `queue` (receiveMessage callbacks run there) — safe write.
                self._receivedFrames.append(obj)
                let method = obj["method"] as? String
                if method == "sessions.subscribe" {
                    // On `queue` (receiveMessage callbacks run there) — safe write.
                    self._didReceiveSubscribe = true
                    if !self.dropSubscribeResponse {
                        self.subscribedConnections.insert(ObjectIdentifier(conn))
                        self.send(conn, obj: [
                            "type": "res", "id": id, "ok": true,
                            "payload": ["subscribed": true],
                        ])
                        // Now that the connection is subscribed, start the deferred
                        // channel scenario. Anchoring the timeline here (not at
                        // handshake) means the first channel frame can never beat
                        // the subscribe round-trip — the gate always passes.
                        self.startPlayback(on: conn)
                    }
                    // dropSubscribeResponse == true: swallow the response entirely
                    // AND never start playback — channel frames stay unsubscribed
                    // and are never delivered (gating stays deterministic).
                } else {
                    self.send(conn, obj: ["type": "res", "id": id, "ok": true, "payload": [:]])
                }
            }
            self.drainRequests(conn)
        }
    }

    /// Kicks off scenario playback for `conn`, at most once per connection.
    /// Called at handshake for agent-stream scenarios, or at sessions.subscribe
    /// for channel scenarios (so the first channel frame lands post-subscribe).
    private func startPlayback(on conn: NWConnection) {
        let key = ObjectIdentifier(conn)
        guard !playbackStarted.contains(key) else { return }
        playbackStarted.insert(key)
        play(steps, on: conn)
    }

    private func play(_ steps: [MockStep], on conn: NWConnection) {
        var when = DispatchTime.now()
        for step in steps {
            when = when + .milliseconds(step.delayMs)
            queue.asyncAfter(deadline: when) { [weak self] in
                guard let self else { return }
                if step.close {
                    conn.cancel()
                } else if let frame = step.frame {
                    // Defence-in-depth gate: channel scenarios only start playback
                    // after subscribe (see startPlayback), so this normally passes;
                    // it still guards any frame whose connection lost its
                    // subscription mid-scenario.
                    if self.isChannelFrame(frame) &&
                       !self.subscribedConnections.contains(ObjectIdentifier(conn)) {
                        return  // drop — connection not yet subscribed
                    }
                    self.sendData(conn, frame)
                } else if let raw = step.raw {
                    self.sendData(conn, Data(raw.utf8))
                }
            }
        }
    }

    /// Returns true if `data` is a channel-session frame (`sessions.changed` or
    /// `session.message` event) that should be gated behind subscription.
    private func isChannelFrame(_ data: Data) -> Bool {
        guard
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            obj["type"] as? String == "event",
            let eventName = obj["event"] as? String
        else { return false }
        return eventName == "sessions.changed" || eventName == "session.message"
    }

    private func send(_ conn: NWConnection, obj: [String: Any]) {
        // inputs are always literal dictionaries — serialisation cannot fail
        sendData(conn, try! JSONSerialization.data(withJSONObject: obj))
    }

    private func sendData(_ conn: NWConnection, _ data: Data) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "frame", metadata: [meta])
        conn.send(content: data, contentContext: ctx, completion: .idempotent)
    }

    private func sendThenClose(_ conn: NWConnection, obj: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: obj)
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "frame", metadata: [meta])
        conn.send(content: data, contentContext: ctx, isComplete: true,
                  completion: .contentProcessed { [weak self] _ in
            self?.queue.async { conn.cancel() }
        })
    }
}

/// Shared frame builders so tests and scenario files agree on shapes.
public enum MockFrames {
    public static func lifecycle(_ phase: String, run: String, session: String, seq: Int) -> [String: Any] {
        agent(run: run, session: session, seq: seq, stream: "lifecycle", data: ["phase": phase])
    }
    public static func tool(name: String, run: String, session: String, seq: Int) -> [String: Any] {
        agent(run: run, session: session, seq: seq, stream: "tool",
              data: ["phase": "start", "name": name, "toolCallId": "t\(seq)", "args": [:]])
    }
    public static func delta(_ text: String, run: String, session: String, seq: Int) -> [String: Any] {
        agent(run: run, session: session, seq: seq, stream: "assistant", data: ["delta": text])
    }
    public static func agent(run: String, session: String, seq: Int,
                             stream: String, data: [String: Any]) -> [String: Any] {
        ["type": "event", "event": "agent",
         "payload": ["runId": run, "seq": seq, "stream": stream,
                     "ts": 0, "sessionKey": session, "data": data]]
    }

    // MARK: - Channel-session frames

    /// `sessions.changed` event: the gateway notifies that a channel run started or ended.
    public static func sessionsChanged(sessionKey: String, phase: String,
                                       runId: String) -> [String: Any] {
        ["type": "event", "event": "sessions.changed",
         "payload": ["sessionKey": sessionKey, "phase": phase,
                     "runId": runId, "ts": 0]]
    }

    /// `session.message` event with a user-role plain-string message.
    /// The client drops user messages, so this is useful for gating / ordering tests.
    public static func sessionMessageUser(sessionKey: String, text: String) -> [String: Any] {
        ["type": "event", "event": "session.message",
         "payload": [
             "sessionKey": sessionKey,
             "messageId": "user-msg",
             "message": ["role": "user", "content": text],
         ]]
    }

    /// `session.message` event with an assistant-role block-array message.
    /// Produces a thinking block (when non-nil) followed by a text block.
    public static func sessionMessageAssistant(sessionKey: String, messageId: String,
                                               thinking: String?,
                                               text: String) -> [String: Any] {
        var blocks: [[String: Any]] = []
        if let thinking {
            blocks.append(["type": "thinking", "thinking": thinking])
        }
        blocks.append(["type": "text", "text": text])
        return ["type": "event", "event": "session.message",
                "payload": [
                    "sessionKey": sessionKey,
                    "messageId": messageId,
                    "message": ["role": "assistant", "content": blocks],
                ]]
    }
}
