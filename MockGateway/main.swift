import Foundation

func usage() -> Never {
    print("usage: mock-gateway --scenario <path.json> [--port N] [--expect-token T]")
    exit(2)
}

var port: UInt16 = 18789
var scenarioPath: String?
var expectToken: String?
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--port":
        guard !args.isEmpty, let p = UInt16(args.removeFirst()) else { usage() }
        port = p
    case "--scenario":
        guard !args.isEmpty else { usage() }
        scenarioPath = args.removeFirst()
    case "--expect-token":
        guard !args.isEmpty else { usage() }
        expectToken = args.removeFirst()
    default: usage()
    }
}
guard let scenarioPath else { usage() }

do {
    let steps = try ScenarioLoader.load(URL(fileURLWithPath: scenarioPath))
    let server = try MockGatewayServer(requestedPort: port, expectToken: expectToken, steps: steps)
    try server.start()
    print("mock-gateway listening on ws://127.0.0.1:\(server.port) — scenario: \(scenarioPath)")
    print("each new connection gets the handshake + scenario; Ctrl-C to stop")
    dispatchMain()
} catch {
    print("mock-gateway failed: \(error)")
    exit(1)
}
