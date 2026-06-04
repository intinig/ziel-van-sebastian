import Foundation
import Network

/// Minimal OpenClaw-gateway-shaped WebSocket server for tests and demos.
/// Accepts one or more connections; each gets: connect handshake
/// (token-checked if expectToken is set), then the scripted steps.
public final class MockGatewayServer {
    private let listener: NWListener
    private let expectToken: String?
    private let steps: [MockStep]
    private let queue = DispatchQueue(label: "mock-gateway")
    private var connections: [NWConnection] = []

    /// Port 0 → ephemeral; read `port` after start() returns.
    public private(set) var port: UInt16 = 0

    public init(requestedPort: UInt16, expectToken: String? = nil, steps: [MockStep]) throws {
        self.expectToken = expectToken
        self.steps = steps
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
        receiveHandshake(conn)
    }

    private func prune(_ conn: NWConnection?) {
        guard let conn else { return }
        connections.removeAll { $0 === conn }
    }

    private func receiveHandshake(_ conn: NWConnection) {
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
                self.send(conn, obj: [
                    "type": "res", "id": id, "ok": false,
                    "error": ["code": "UNAUTHORIZED", "message": "bad token"],
                ])
                conn.cancel()
                return
            }
            self.send(conn, obj: [
                "type": "res", "id": id, "ok": true,
                "payload": ["type": "hello-ok", "protocol": 4],
            ])
            self.play(self.steps, on: conn)
            self.drainRequests(conn)
        }
    }

    /// Answer any post-connect requests generically so clients don't hang.
    private func drainRequests(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data else { return }
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               obj["type"] as? String == "req", let id = obj["id"] as? String {
                self.send(conn, obj: ["type": "res", "id": id, "ok": true, "payload": [:]])
            }
            self.drainRequests(conn)
        }
    }

    private func play(_ steps: [MockStep], on conn: NWConnection) {
        var when = DispatchTime.now()
        for step in steps {
            when = when + .milliseconds(step.delayMs)
            queue.asyncAfter(deadline: when) { [weak self] in
                if step.close {
                    conn.cancel()
                } else if let frame = step.frame {
                    self?.sendData(conn, frame)
                } else if let raw = step.raw {
                    self?.sendData(conn, Data(raw.utf8))
                }
            }
        }
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
}
