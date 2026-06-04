import Foundation

/// Agent-agnostic events. All OpenClaw protocol knowledge stays in the translator.
public enum AgentEvent: Equatable {
    case runStarted(run: String, session: String)
    case toolStarted(run: String, session: String, tool: String)
    case textDelta(run: String, session: String, text: String)
    case runEnded(run: String, session: String)
    case connectionUp
    case connectionDown(auth: Bool)   // auth=true → token rejected
}
