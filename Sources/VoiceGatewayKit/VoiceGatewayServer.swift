import Foundation
import Network

/// Loopback WS server for the voice gateway: broadcasts VoiceEvents, receives
/// VoiceCommands. Pure transport — no audio or STT here. No auth by design
/// (loopback-only; see spec addendum).
public final class VoiceGatewayServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "voice-gateway-server")
    private var connections: [NWConnection] = []
    public private(set) var port: UInt16 = 0
    public var onCommand: ((VoiceCommand) -> Void)?

    public init(requestedPort: UInt16) throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback   // no-auth design is only valid because non-loopback connections are impossible (kernel-enforced)
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params,
                                  on: requestedPort == 0 ? .any : NWEndpoint.Port(rawValue: requestedPort)!)
    }

    public func start() throws {
        let ready = DispatchSemaphore(value: 0)
        var startupError: Error?
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.port = self?.listener.port?.rawValue ?? 0; ready.signal()
            case .failed(let e): startupError = e; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut {
            throw NSError(domain: "VoiceGateway", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener never became ready"])
        }
        if let e = startupError { throw e }
    }

    public func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() }; connections.removeAll() }
    }

    /// Test-support only: current active connection count.
    public var connectionCount: Int { queue.sync { connections.count } }

    public func broadcast(_ e: VoiceEvent) {
        let data = VoiceProtocol.encode(e)
        queue.async { [weak self] in self?.connections.forEach { self?.send($0, data: data) } }
    }

    private func accept(_ conn: NWConnection) {
        connections.append(conn)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            if case .cancelled = state { self?.prune(conn) }
            if case .failed = state { self?.prune(conn) }
        }
        conn.start(queue: queue)
        send(conn, data: VoiceProtocol.encode(VoiceEvent.ready(version: 1)))
        receiveLoop(conn)
    }

    private func prune(_ conn: NWConnection?) {
        guard let conn else { return }
        connections.removeAll { $0 === conn }
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, _, _, error in
            guard let self, let conn, error == nil else { return }
            guard let data else { conn.cancel(); return }   // graceful EOF → prune via .cancelled
            if let cmd = VoiceProtocol.decodeCommand(data) {
                self.onCommand?(cmd)
            }
            self.receiveLoop(conn)
        }
    }

    private func send(_ conn: NWConnection, data: Data) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "event", metadata: [meta])
        conn.send(content: data, contentContext: ctx, completion: .contentProcessed { _ in })
    }
}
