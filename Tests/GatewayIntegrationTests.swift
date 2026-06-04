import XCTest

final class GatewayIntegrationTests: XCTestCase {
    private final class Collector {
        var events: [AgentEvent] = []
        let lock = NSLock()
        func add(_ e: AgentEvent) { lock.lock(); events.append(e); lock.unlock() }
        func snapshot() -> [AgentEvent] { lock.lock(); defer { lock.unlock() }; return events }
    }

    private func happyPathSteps() -> [MockStep] {
        [
            .send(MockFrames.lifecycle("start", run: "r1", session: "main", seq: 0), afterMs: 50),
            .send(MockFrames.tool(name: "read", run: "r1", session: "main", seq: 1), afterMs: 50),
            .send(MockFrames.delta("Hello world. ", run: "r1", session: "main", seq: 2), afterMs: 50),
            .send(MockFrames.lifecycle("end", run: "r1", session: "main", seq: 3), afterMs: 50),
        ]
    }

    private func makeClient(port: UInt16, token: String = "tok",
                            identity: DeviceIdentity? = nil,
                            collector: Collector) -> GatewayClient {
        GatewayClient(
            url: URL(string: "ws://127.0.0.1:\(port)")!,
            token: token,
            identity: identity,
            onEvent: { collector.add($0) }
        )
    }

    private func makeIdentity() throws -> DeviceIdentity {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ziel-gw-tests-\(UUID().uuidString)")
        return try DeviceIdentity.loadOrCreate(at: dir.appendingPathComponent("device-identity.json"))
    }

    func testConnectHandshakeAndEventFlow() throws {
        let server = try MockGatewayServer(requestedPort: 0, expectToken: "tok", steps: happyPathSteps())
        try server.start()
        defer { server.stop() }

        let collector = Collector()
        let client = makeClient(port: server.port, collector: collector)
        client.start()
        defer { client.stop() }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && collector.snapshot().count < 5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let events = collector.snapshot()
        XCTAssertEqual(events.first, .connectionUp)
        XCTAssertTrue(events.contains(.runStarted(run: "r1", session: "main")))
        XCTAssertTrue(events.contains(.toolStarted(run: "r1", session: "main", tool: "read")))
        XCTAssertTrue(events.contains(.textDelta(run: "r1", session: "main", text: "Hello world. ")))
        XCTAssertTrue(events.contains(.runEnded(run: "r1", session: "main")))
    }

    func testBadTokenReportsAuthDown() throws {
        let server = try MockGatewayServer(requestedPort: 0, expectToken: "correct", steps: [])
        try server.start()
        defer { server.stop() }

        let collector = Collector()
        let client = makeClient(port: server.port, token: "wrong", collector: collector)
        client.start()
        defer { client.stop() }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && collector.snapshot().isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(collector.snapshot().first, .connectionDown(auth: true))
    }

    func testServerDropReportsNetworkDown() throws {
        let steps: [MockStep] = [
            .send(MockFrames.lifecycle("start", run: "r1", session: "main", seq: 0), afterMs: 50),
            MockStep(delayMs: 100, close: true),
        ]
        let server = try MockGatewayServer(requestedPort: 0, steps: steps)
        try server.start()
        defer { server.stop() }

        let collector = Collector()
        let client = makeClient(port: server.port, collector: collector)
        client.start()
        defer { client.stop() }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && !collector.snapshot().contains(.connectionDown(auth: false)) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let events = collector.snapshot()
        XCTAssertEqual(events.first, .connectionUp)
        XCTAssertTrue(events.contains(.connectionDown(auth: false)))
    }

    func testMalformedFramesAreSkipped() throws {
        let steps: [MockStep] = [
            MockStep(delayMs: 50, raw: "garbage {{{"),
            .send(MockFrames.delta("survived", run: "r1", session: "main", seq: 0), afterMs: 50),
        ]
        let server = try MockGatewayServer(requestedPort: 0, steps: steps)
        try server.start()
        defer { server.stop() }

        let collector = Collector()
        let client = makeClient(port: server.port, collector: collector)
        client.start()
        defer { client.stop() }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && !collector.snapshot().contains(.textDelta(run: "r1", session: "main", text: "survived")) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(collector.snapshot().contains(.textDelta(run: "r1", session: "main", text: "survived")))
    }

    func testNoEventsAfterStop() throws {
        let server = try MockGatewayServer(requestedPort: 0, expectToken: "tok", steps: happyPathSteps())
        try server.start()
        defer { server.stop() }

        let collector = Collector()
        let client = makeClient(port: server.port, collector: collector)
        client.start()

        // Wait for the connection to come up, then stop immediately.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && collector.snapshot().isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        client.stop()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        let countAfterStop = collector.snapshot().count
        // Remaining scenario frames keep arriving at the socket for ~200ms;
        // none may surface as events.
        RunLoop.current.run(until: Date().addingTimeInterval(0.7))
        XCTAssertEqual(collector.snapshot().count, countAfterStop)
    }

    // MARK: - Device identity handshake (OpenClaw 2026.6.1 pairing flow)

    func testDeviceAuthHandshakeCompletesAgainstVerifyingServer() throws {
        let server = try MockGatewayServer(
            requestedPort: 0, expectToken: "tok", requireDeviceAuth: true,
            steps: happyPathSteps())
        try server.start()
        defer { server.stop() }

        let collector = Collector()
        let client = makeClient(port: server.port, identity: try makeIdentity(),
                                collector: collector)
        client.start()
        defer { client.stop() }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && collector.snapshot().count < 5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let events = collector.snapshot()
        XCTAssertEqual(events.first, .connectionUp,
                       "client must wait for connect.challenge and send a verifiable device block")
        XCTAssertTrue(events.contains(.runEnded(run: "r1", session: "main")))
    }

    func testMissingDeviceBlockIsRejectedByVerifyingServer() throws {
        let server = try MockGatewayServer(
            requestedPort: 0, expectToken: "tok", requireDeviceAuth: true, steps: [])
        try server.start()
        defer { server.stop() }

        let collector = Collector()
        let client = makeClient(port: server.port, identity: nil, collector: collector)
        client.start()
        defer { client.stop() }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && collector.snapshot().isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(collector.snapshot().first, .connectionDown(auth: true))
    }
}
