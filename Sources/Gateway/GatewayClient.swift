import Foundation
import os

/// Connects to the OpenClaw gateway, performs the connect handshake,
/// translates frames, reconnects with backoff. Emits AgentEvents on an
/// internal serial queue — the caller hops to its own queue if needed.
/// One-shot: after stop() the client cannot be restarted — create a new instance.
public final class GatewayClient: NSObject, URLSessionWebSocketDelegate {
    private let url: URL
    private let token: String
    private let onEvent: (AgentEvent) -> Void
    private let log = Logger(subsystem: "com.gintini.ZielVanSebastian", category: "gateway")
    private let queue = DispatchQueue(label: "gateway-client")

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var stopped = true
    private var attempts = 0
    private var handshakeComplete = false
    /// Set when the server sent ok:false — suppresses the racing network-drop event.
    private var authRejected = false
    /// Whether the current connection's drop has already been reported to the caller.
    private var dropReported = false
    private static let connectId = "connect-1"

    public init(url: URL, token: String, onEvent: @escaping (AgentEvent) -> Void) {
        self.url = url
        self.token = token
        self.onEvent = onEvent
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public func start() {
        queue.async {
            self.stopped = false
            self.open()
        }
    }

    public func stop() {
        queue.async {
            self.stopped = true
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.task = nil
            // Break the URLSession→delegate retain cycle so the client deallocates.
            self.session.invalidateAndCancel()
        }
    }

    // MARK: - Connection lifecycle (all on `queue`)

    private func open() {
        guard !stopped else { return }
        handshakeComplete = false
        authRejected = false
        dropReported = false
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receiveLoop(t)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?) {
        queue.async { self.sendConnect() }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                           reason: Data?) {
        queue.async { self.handleDrop() }
    }

    private func sendConnect() {
        let frame: [String: Any] = [
            "type": "req", "id": Self.connectId, "method": "connect",
            "params": [
                "minProtocol": 3, "maxProtocol": 4,
                "client": ["id": "gateway-client", "version": "1.0.0",
                           // "ui" verified against OpenClaw 2026.6.1 — the
                           // released mode enum differs from main-branch docs
                           // ("operator" is rejected with INVALID_REQUEST).
                           "platform": "macos", "mode": "ui"],
                "role": "operator",
                "scopes": ["operator.read"],
                "auth": ["token": token],
            ],
        ]
        // Literal dictionary — serialisation cannot fail.
        let data = try! JSONSerialization.data(withJSONObject: frame)
        task?.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
            if let error {
                self?.log.error("connect send failed: \(error.localizedDescription)")
                self?.queue.async { self?.handleDrop() }
            }
        }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                // Skip stale callbacks only when a NEW connection is already up.
                // If task is nil (connection torn down but no reconnect yet), we
                // still want to process any frame that raced with handleDrop, so
                // that an ok:false rejection isn't silently swallowed.
                if let current = self.task, current !== t { return }
                switch result {
                case .failure:
                    self.handleDrop()
                case .success(let message):
                    let data: Data
                    switch message {
                    case .string(let s): data = Data(s.utf8)
                    case .data(let d): data = d
                    @unknown default: data = Data()
                    }
                    self.handleFrame(data)
                    // Only continue the loop if this task is still current.
                    if self.task === t {
                        self.receiveLoop(t)
                    }
                }
            }
        }
    }

    private func handleFrame(_ data: Data) {
        guard !stopped else { return }
        if !handshakeComplete {
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return   // pre-handshake garbage / frames we don't parse
            }
            // Ignore connect.challenge and other events until our res arrives.
            guard obj["type"] as? String == "res",
                  obj["id"] as? String == Self.connectId else { return }
            if obj["ok"] as? Bool == true {
                handshakeComplete = true
                attempts = 0
                log.info("gateway handshake ok")
                onEvent(.connectionUp)
            } else {
                log.error("gateway rejected connect (auth)")
                authRejected = true
                dropReported = true
                onEvent(.connectionDown(auth: true))
                task?.cancel(with: .normalClosure, reason: nil)
                task = nil
                scheduleReconnect(authFailure: true)
            }
            return
        }
        for event in OpenClawTranslator.translate(data) {
            onEvent(event)
        }
    }

    private func handleDrop() {
        guard !stopped else { return }
        // Auth rejection already reported (handleFrame got there first).
        if authRejected { return }
        // Drop already reported (idempotent guard).
        if dropReported { return }
        dropReported = true
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil

        if !handshakeComplete {
            // The rejection frame may race behind this drop notification on the
            // serial queue. Yield once so any pending handleFrame(ok:false) block
            // can run and set authRejected = true before we emit the event.
            queue.async { [weak self] in
                guard let self, !self.stopped else { return }
                if !self.authRejected {
                    self.onEvent(.connectionDown(auth: false))
                    self.scheduleReconnect(authFailure: false)
                }
            }
            return
        }
        onEvent(.connectionDown(auth: false))
        scheduleReconnect(authFailure: false)
    }

    private func scheduleReconnect(authFailure: Bool) {
        guard !stopped else { return }
        let delay: TimeInterval
        if authFailure {
            delay = 60   // a bad token won't fix itself quickly
        } else {
            attempts += 1
            // First retry = 2^0 = 1s, then 2,4,8...60 (attempts incremented above).
            delay = min(60, pow(2, Double(min(attempts, 6)) - 1)) + Double.random(in: 0...1)
        }
        log.info("reconnecting in \(delay, format: .fixed(precision: 1))s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.open()
        }
    }
}
