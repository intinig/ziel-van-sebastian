import Foundation
import os

/// Connects to the OpenClaw gateway, performs the connect handshake,
/// translates frames, reconnects with backoff. Emits AgentEvents on an
/// internal serial queue — the caller hops to its own queue if needed.
/// One-shot: after stop() the client cannot be restarted — create a new instance.
public final class GatewayClient: NSObject, URLSessionWebSocketDelegate {
    private let url: URL
    private let token: String
    /// Persistent Ed25519 identity for device pairing. nil = legacy token-only
    /// connect (no device block; the gateway clears scopes — tests/probes only).
    private let identity: DeviceIdentity?
    private var challengeTimeout: DispatchWorkItem?
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
    private var translationContext = TranslationContext()
    private static let connectId = "connect-1"
    private static let subscribeId = "subscribe-1"

    public init(url: URL, token: String, identity: DeviceIdentity? = nil,
                onEvent: @escaping (AgentEvent) -> Void) {
        self.url = url
        self.token = token
        self.identity = identity
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
            self.challengeTimeout?.cancel()
            self.challengeTimeout = nil
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.task = nil
            // Break the URLSession→delegate retain cycle so the client deallocates.
            self.session.invalidateAndCancel()
        }
    }

    /// Injects a user prompt into the main OpenClaw session (`chat.send`).
    /// The agent's reply streams back via the already-consumed `agent` events —
    /// no output-side handling needed here. No-op if not currently connected.
    public func sendPrompt(_ text: String) {
        queue.async { [weak self] in
            guard let self, let task = self.task else { return }
            let frame = OpenClawTranslator.promptFrame(
                text: text, id: "prompt-\(UUID().uuidString)",
                mainSessionKey: self.translationContext.mainSessionKey)
            guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
            task.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
                if let error {
                    self?.log.error("sendPrompt failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Connection lifecycle (all on `queue`)

    private func open() {
        guard !stopped else { return }
        handshakeComplete = false
        authRejected = false
        dropReported = false
        translationContext = TranslationContext()
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receiveLoop(t)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?) {
        queue.async {
            if self.identity == nil {
                // Legacy token-only connect: no device block, no challenge needed.
                self.sendConnect(nonce: nil)
            } else {
                // Device auth signs the gateway's challenge nonce; wait for it.
                self.armChallengeTimeout()
            }
        }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                           reason: Data?) {
        queue.async { self.handleDrop() }
    }

    private func sendConnect(nonce: String?) {
        // "ui" is the released-2026.6.1 mode for external operator clients
        // ("operator" is rejected with INVALID_REQUEST; "backend" is reserved
        // for OpenClaw-internal control-plane RPCs). Scopes only survive for
        // paired devices, hence the signed device block below.
        let clientId = "gateway-client", mode = "ui", role = "operator"
        let scopes = ["operator.read", "operator.write"]  // write enables chat.send (voice prompt injection)
        var params: [String: Any] = [
            "minProtocol": 3, "maxProtocol": 4,
            "client": ["id": clientId, "version": "1.0.0",
                       "displayName": "Ziel van Sebastian",
                       "platform": "macos", "mode": mode],
            "role": role,
            "scopes": scopes,
            "auth": ["token": token],
        ]
        if let identity, let nonce {
            let signedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
            let payload = DeviceIdentity.buildPayloadV3(
                deviceId: identity.deviceId, clientId: clientId, clientMode: mode,
                role: role, scopes: scopes, signedAtMs: signedAtMs,
                token: token, nonce: nonce, platform: "macos", deviceFamily: nil)
            params["device"] = [
                "id": identity.deviceId,
                "publicKey": identity.publicKeyRawBase64Url,
                "signature": identity.sign(payload: payload),
                "signedAt": signedAtMs,
                "nonce": nonce,
            ]
        }
        let frame: [String: Any] = [
            "type": "req", "id": Self.connectId, "method": "connect", "params": params,
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

    private func sendSessionsSubscribe() {
        // Subscribe to all sessions so channel runs (WhatsApp, iMessage, etc.)
        // surface as sessions.changed / session.message events.
        // Empty params = subscribe to all sessions. Re-sent on every reconnect.
        let frame: [String: Any] = [
            "type": "req", "id": Self.subscribeId,
            "method": "sessions.subscribe", "params": [:] as [String: Any],
        ]
        // Literal dictionary — serialisation cannot fail.
        let data = try! JSONSerialization.data(withJSONObject: frame)
        task?.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
            if let error {
                // A send failure here is non-fatal: the drop handler will fire if
                // the socket is actually dead; otherwise we just won't see channels.
                self?.log.error("sessions.subscribe send failed: \(error.localizedDescription)")
            }
        }
    }

    private func armChallengeTimeout() {
        challengeTimeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, !self.handshakeComplete else { return }
            self.log.error("gateway connect.challenge timeout")
            self.handleDrop()
        }
        challengeTimeout = work
        queue.asyncAfter(deadline: .now() + 3, execute: work)
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
            if identity != nil,
               obj["type"] as? String == "event",
               obj["event"] as? String == "connect.challenge" {
                let payload = obj["payload"] as? [String: Any]
                let nonce = (payload?["nonce"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !nonce.isEmpty else {
                    log.error("gateway connect.challenge missing nonce")
                    handleDrop()
                    return
                }
                challengeTimeout?.cancel()
                challengeTimeout = nil
                sendConnect(nonce: nonce)
                return
            }
            // Ignore other events until our res arrives.
            guard obj["type"] as? String == "res",
                  obj["id"] as? String == Self.connectId else { return }
            if obj["ok"] as? Bool == true {
                handshakeComplete = true
                attempts = 0
                let payload = obj["payload"] as? [String: Any]
                let auth = payload?["auth"] as? [String: Any]
                let negotiatedScopes = (auth?["scopes"] as? [String]) ?? []
                log.info("gateway handshake ok (role=\(auth?["role"] as? String ?? "?"), scopes=\(negotiatedScopes))")
                // Pull mainSessionKey from snapshot so channel events for the main
                // session are not double-spoken (agent events already cover them).
                let snapshot = payload?["snapshot"] as? [String: Any]
                let health = snapshot?["health"] as? [String: Any]
                let sessionDefaults = health?["sessionDefaults"] as? [String: Any]
                if let key = sessionDefaults?["mainSessionKey"] as? String, !key.isEmpty {
                    translationContext.mainSessionKey = key
                }
                sendSessionsSubscribe()
                onEvent(.connectionUp)
            } else {
                let error = obj["error"] as? [String: Any]
                let message = error?["message"] as? String ?? "no detail"
                log.error("gateway rejected connect (\(error?["code"] as? String ?? "?"): \(message))")
                authRejected = true
                dropReported = true
                onEvent(.connectionDown(auth: true))
                task?.cancel(with: .normalClosure, reason: nil)
                task = nil
                scheduleReconnect(authFailure: true)
            }
            return
        }
        for event in OpenClawTranslator.translate(data, context: &translationContext) {
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
        challengeTimeout?.cancel()
        challengeTimeout = nil
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
