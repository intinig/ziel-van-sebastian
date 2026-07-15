import XCTest

final class VoiceGatewayClientTests: XCTestCase {
    private func pump(_ predicate: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !predicate() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func testResendsLastModeAfterReady() throws {
        let server = try VoiceGatewayServer(requestedPort: 0)
        try server.start()
        defer { server.stop() }

        let lock = NSLock()
        var commands: [VoiceCommand] = []
        server.onCommand = { lock.lock(); commands.append($0); lock.unlock() }

        let client = VoiceGatewayClient(url: URL(string: "ws://127.0.0.1:\(server.port)")!,
                                        onEvent: { _ in })
        client.send(.mode(.followUp))   // set desired mode before connecting (no-op send)
        client.start()
        defer { client.stop() }

        // On connect the server broadcasts `ready`; the client must resync its mode.
        pump { lock.lock(); defer { lock.unlock() }; return commands.contains(.mode(.followUp)) }
        lock.lock(); let got = commands; lock.unlock()
        XCTAssertTrue(got.contains(.mode(.followUp)),
                      "client must re-send its last mode after ready; got \(got)")
    }

    func testDeliversBroadcastEvents() throws {
        let server = try VoiceGatewayServer(requestedPort: 0)
        try server.start()
        defer { server.stop() }

        let lock = NSLock()
        var events: [VoiceEvent] = []
        let client = VoiceGatewayClient(url: URL(string: "ws://127.0.0.1:\(server.port)")!,
                                        onEvent: { lock.lock(); events.append($0); lock.unlock() })
        client.start()
        defer { client.stop() }

        pump { lock.lock(); defer { lock.unlock() }; return events.contains(.ready(version: 1)) }
        server.broadcast(.heard(text: "hi there"))
        pump { lock.lock(); defer { lock.unlock() }; return events.contains(.heard(text: "hi there")) }
        lock.lock(); let got = events; lock.unlock()
        XCTAssertTrue(got.contains(.heard(text: "hi there")), "got \(got)")
    }

    func testStopThenStartReconnects() throws {
        let server = try VoiceGatewayServer(requestedPort: 0)
        try server.start()
        defer { server.stop() }

        let lock = NSLock()
        var readyCount = 0
        let client = VoiceGatewayClient(url: URL(string: "ws://127.0.0.1:\(server.port)")!,
                                        onEvent: { if case .ready = $0 { lock.lock(); readyCount += 1; lock.unlock() } })
        client.start()
        pump { lock.lock(); defer { lock.unlock() }; return readyCount >= 1 }
        client.stop()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        client.start()   // restartable
        defer { client.stop() }
        pump { lock.lock(); defer { lock.unlock() }; return readyCount >= 2 }
        lock.lock(); let count = readyCount; lock.unlock()
        XCTAssertGreaterThanOrEqual(count, 2, "start after stop must reconnect")
    }
}
