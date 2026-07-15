import Foundation
import os

/// Reconnecting loopback-WS client for the voice-gateway. Decodes VoiceEvents,
/// encodes VoiceCommands, and re-sends its last mode after each `ready` so the
/// service resyncs on (re)connect. Restartable: start() after stop() reconnects.
/// `onEvent` fires on an internal serial queue — the caller hops to its own queue.
public final class VoiceGatewayClient: NSObject, VoiceLink, URLSessionWebSocketDelegate {
    private let url: URL
    private let onEvent: (VoiceEvent) -> Void
    private let log = Logger(subsystem: "com.gintini.ZielVanSebastian", category: "voice-gateway-client")
    private let queue = DispatchQueue(label: "voice-gateway-client")
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var stopped = true
    private var attempts = 0
    private var lastMode: WakeMode = .armed

    public init(url: URL, onEvent: @escaping (VoiceEvent) -> Void) {
        self.url = url
        self.onEvent = onEvent
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public func start() {
        queue.async {
            guard self.stopped else { return }
            self.stopped = false
            self.attempts = 0
            self.open()
        }
    }

    public func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.task = nil
        }
    }

    public func send(_ command: VoiceCommand) {
        queue.async {
            if case .mode(let m) = command { self.lastMode = m }
            self.rawSend(command)
        }
    }

    // MARK: - internals (all on `queue`)

    private func rawSend(_ command: VoiceCommand) {
        guard let task = task else { return }
        let data = VoiceProtocol.encode(command)
        task.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
            if let error { self?.log.error("voice send failed: \(error.localizedDescription)") }
        }
    }

    private func open() {
        guard !stopped else { return }
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receiveLoop(t)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async { self.handleDrop() }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
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
                    if let event = VoiceProtocol.decodeEvent(data) {
                        if case .ready = event {
                            self.attempts = 0
                            self.rawSend(.mode(self.lastMode))   // mode resync after (re)connect
                        }
                        self.onEvent(event)
                    }
                    if self.task === t { self.receiveLoop(t) }
                }
            }
        }
    }

    private func handleDrop() {
        guard !stopped else { return }
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        attempts += 1
        let delay = min(30, pow(2, Double(min(attempts, 5)) - 1)) + Double.random(in: 0...0.5)
        log.info("voice-gateway reconnecting in \(delay, format: .fixed(precision: 1))s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.open() }
    }
}
