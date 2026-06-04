import Foundation

/// Scripted AgentEvent sequence for gateway-free development and demos.
/// Loops forever: idle → wake → think (tools) → speak → settle → pause.
public enum DemoScript {
    public static let loopPauseSeconds: TimeInterval = 6

    /// (delay-from-sequence-start, event)
    public static let sequence: [(at: TimeInterval, event: AgentEvent)] = [
        (0.0, .runStarted(run: "demo", session: "demo")),
        (1.0, .toolStarted(run: "demo", session: "demo", tool: "read")),
        (3.0, .toolStarted(run: "demo", session: "demo", tool: "web_search")),
        (5.0, .toolStarted(run: "demo", session: "demo", tool: "exec")),
        (7.0, .textDelta(run: "demo", session: "demo", text: "The build finished. ")),
        (7.2, .textDelta(run: "demo", session: "demo", text: "All 142 tests pass. ")),
        (7.4, .textDelta(run: "demo", session: "demo", text: "Deploy to staging went clean. ")),
        (7.6, .textDelta(run: "demo", session: "demo", text: "One warning in the logs, nothing serious. ")),
        (7.8, .textDelta(run: "demo", session: "demo", text: "Want me to tag the release?")),
        (8.2, .runEnded(run: "demo", session: "demo")),
    ]

    public static var totalLength: TimeInterval {
        (sequence.last?.at ?? 0) + loopPauseSeconds
    }
}
