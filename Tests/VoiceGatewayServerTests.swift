import XCTest

final class VoiceGatewayServerTests: XCTestCase {
    func testReadyBroadcastAndCommandRoundTrip() throws {
        let server = try VoiceGatewayServer(requestedPort: 0)
        try server.start()
        defer { server.stop() }

        var commands: [VoiceCommand] = []
        let gotCommand = expectation(description: "command")
        server.onCommand = { commands.append($0); gotCommand.fulfill() }

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(server.port)")!)
        task.resume()

        // 1) ready arrives on connect
        let ready = expectation(description: "ready")
        task.receive { result in
            if case .success(.string(let s)) = result,
               VoiceProtocol.decodeEvent(Data(s.utf8)) == .ready(version: 1) { ready.fulfill() }
        }
        wait(for: [ready], timeout: 5)

        // 2) command in
        task.send(.string(String(decoding: VoiceProtocol.encode(VoiceCommand.mode(.listen)), as: UTF8.self))) { _ in }
        wait(for: [gotCommand], timeout: 5)
        XCTAssertEqual(commands, [.mode(.listen)])

        // 3) event broadcast reaches the client
        let heard = expectation(description: "heard")
        task.receive { result in
            if case .success(.string(let s)) = result,
               VoiceProtocol.decodeEvent(Data(s.utf8)) == .heard(text: "hi") { heard.fulfill() }
        }
        server.broadcast(.heard(text: "hi"))
        wait(for: [heard], timeout: 5)
        task.cancel(with: .goingAway, reason: nil)
    }
}
