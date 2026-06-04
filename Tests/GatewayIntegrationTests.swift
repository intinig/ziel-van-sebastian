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

    // MARK: - Channel-session events (sessions.subscribe + channel frames)

    func testChannelSessionEndToEnd() throws {
        let sessionKey = "agent:main:whatsapp:direct:+353838112174"
        let runId = "whatsapp-run-1"

        // Build the WhatsApp scenario steps — all channel frames, no agent frames.
        let channelSteps: [MockStep] = [
            .send(MockFrames.sessionsChanged(sessionKey: sessionKey, phase: "start", runId: runId),
                  afterMs: 50),
            .send(MockFrames.sessionMessageUser(sessionKey: sessionKey, text: "Hey Seb"),
                  afterMs: 50),
            .send(MockFrames.sessionMessageAssistant(
                sessionKey: sessionKey, messageId: "msg-1",
                thinking: "The user greeted me.",
                text: "Hello Giovanni! Appliance relay working perfectly."),
                  afterMs: 50),
            .send(MockFrames.sessionsChanged(sessionKey: sessionKey, phase: "end", runId: runId),
                  afterMs: 50),
        ]

        let server = try MockGatewayServer(requestedPort: 0, expectToken: "tok",
                                           steps: channelSteps)
        try server.start()
        defer { server.stop() }

        let collector = Collector()
        let client = makeClient(port: server.port, collector: collector)
        client.start()
        defer { client.stop() }

        // Wait for runEnded — the last expected event.
        let expectedRunEnded = AgentEvent.runEnded(run: runId, session: sessionKey)
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && !collector.snapshot().contains(expectedRunEnded) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        // Give a brief window for any spurious extra events to arrive.
        RunLoop.current.run(until: Date().addingTimeInterval(0.15))
        let events = collector.snapshot()

        // Assert the mock received a sessions.subscribe request.
        XCTAssertTrue(server.didReceiveSubscribe,
                      "GatewayClient must send sessions.subscribe after handshake")

        // Assert events in order (strip connection-lifecycle events).
        let nonConnection = events.filter {
            if case .connectionUp = $0 { return false }
            if case .connectionDown = $0 { return false }
            return true
        }
        XCTAssertEqual(nonConnection, [
            .runStarted(run: runId, session: sessionKey),
            .textDelta(run: runId, session: sessionKey,
                       text: "Hello Giovanni! Appliance relay working perfectly."),
            .runEnded(run: runId, session: sessionKey),
        ])
        XCTAssertEqual(events.first, .connectionUp)
    }

    func testChannelFramesGatedUntilSubscribe() throws {
        // Channel frames played before the subscribe response is sent must NOT
        // reach the client. We achieve determinism by using a server that holds
        // the subscribe response until we explicitly release it, rather than
        // relying on timing.
        let sessionKey = "agent:main:whatsapp:direct:+353838112174"
        let runId = "gated-run-1"

        // These steps are delivered immediately after handshake — before subscribe.
        // They must be silently discarded because the connection hasn't subscribed yet.
        let preSubscribeSteps: [MockStep] = [
            .send(MockFrames.sessionsChanged(sessionKey: sessionKey, phase: "start", runId: runId),
                  afterMs: 10),
            .send(MockFrames.sessionsChanged(sessionKey: sessionKey, phase: "end", runId: runId),
                  afterMs: 20),
        ]

        let server = try MockGatewayServer(requestedPort: 0, expectToken: "tok",
                                           steps: preSubscribeSteps,
                                           holdSubscribeResponse: true)
        try server.start()
        defer { server.stop() }

        let collector = Collector()
        let client = makeClient(port: server.port, collector: collector)
        client.start()
        defer { client.stop() }

        // Wait for connectionUp and give time for the pre-subscribe frames to arrive.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && !collector.snapshot().contains(.connectionUp) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        // Let pre-subscribe frames travel over the wire and be processed.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))

        // No channel events may have arrived — they were sent before subscription.
        let earlyEvents = collector.snapshot().filter {
            switch $0 {
            case .runStarted, .runEnded, .textDelta, .toolStarted: return true
            default: return false
            }
        }
        XCTAssertTrue(earlyEvents.isEmpty,
                      "Channel frames before subscribe must be gated; got: \(earlyEvents)")
    }
}
