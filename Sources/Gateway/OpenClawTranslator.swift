import Foundation

// The single place that understands OpenClaw's gateway frames.
// Everything else speaks AgentEvent.

/// Mutable state threaded through stateful translation calls.
/// One instance per GatewayClient connection; reset on every reconnect.
public struct TranslationContext: Equatable {
    /// The session key used by the main agent session (already covered by `agent` events).
    /// Defaults to the canonical value; updated from the hello-ok payload on connect.
    public var mainSessionKey: String
    /// Maps channel sessionKey → active runId for in-flight channel runs.
    public var activeChannelRuns: [String: String]

    public init(mainSessionKey: String = "agent:main:main") {
        self.mainSessionKey = mainSessionKey
        self.activeChannelRuns = [:]
    }
}

public enum OpenClawTranslator {

    // MARK: - Agent-stream translation (stateless, unchanged)

    public static func translate(_ data: Data) -> [AgentEvent] {
        guard
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            obj["type"] as? String == "event",
            obj["event"] as? String == "agent",
            let payload = obj["payload"] as? [String: Any],
            let runId = payload["runId"] as? String, !runId.isEmpty,
            let stream = payload["stream"] as? String
        else { return [] }

        // NSNumber bridging means a JSON 1/true both read as Bool true here —
        // desirable (heartbeats dropped either way); don't "fix" to JSONDecoder.
        if (payload["isHeartbeat"] as? Bool) == true { return [] }

        let sessionKey = payload["sessionKey"] as? String
        let session = (sessionKey?.isEmpty == false) ? sessionKey! : runId
        let body = payload["data"] as? [String: Any] ?? [:]

        switch stream {
        case "lifecycle":
            switch body["phase"] as? String {
            case "start":
                return [.runStarted(run: runId, session: session)]
            case "end", "error":
                return [.runEnded(run: runId, session: session)]
            default:
                return []
            }
        case "tool":
            guard body["phase"] as? String == "start",
                  let name = body["name"] as? String else { return [] }
            return [.toolStarted(run: runId, session: session, tool: name)]
        case "assistant":
            guard let delta = body["delta"] as? String, !delta.isEmpty else { return [] }
            return [.textDelta(run: runId, session: session, text: delta)]
        default:
            return []
        }
    }

    // MARK: - Channel-session translation (stateful)

    /// Translate a raw WS frame, updating context for channel-session correlation.
    public static func translate(_ data: Data, context: inout TranslationContext) -> [AgentEvent] {
        guard
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            obj["type"] as? String == "event",
            let eventName = obj["event"] as? String
        else { return [] }

        switch eventName {
        case "agent":
            // Re-route through the stateless path — no context changes needed.
            return translate(data)

        case "sessions.changed":
            return handleSessionsChanged(obj, context: &context)

        case "session.message":
            return handleSessionMessage(obj, context: &context)

        default:
            return []
        }
    }

    // MARK: - Private helpers

    private static func handleSessionsChanged(
        _ obj: [String: Any],
        context: inout TranslationContext
    ) -> [AgentEvent] {
        guard
            let payload = obj["payload"] as? [String: Any],
            let sessionKey = payload["sessionKey"] as? String, !sessionKey.isEmpty,
            let runId = payload["runId"] as? String, !runId.isEmpty,
            let phase = payload["phase"] as? String
        else { return [] }

        // Main session is already covered by agent events — avoid duplicates.
        if sessionKey == context.mainSessionKey { return [] }

        switch phase {
        case "start":
            context.activeChannelRuns[sessionKey] = runId
            return [.runStarted(run: runId, session: sessionKey)]
        case "end", "error":
            context.activeChannelRuns.removeValue(forKey: sessionKey)
            return [.runEnded(run: runId, session: sessionKey)]
        default:
            return []
        }
    }

    private static func handleSessionMessage(
        _ obj: [String: Any],
        context: inout TranslationContext
    ) -> [AgentEvent] {
        guard
            let payload = obj["payload"] as? [String: Any],
            let sessionKey = payload["sessionKey"] as? String, !sessionKey.isEmpty,
            let message = payload["message"] as? [String: Any]
        else { return [] }

        // Main session is already covered by agent events — avoid duplicates.
        if sessionKey == context.mainSessionKey { return [] }

        // Only assistant messages carry text worth displaying.
        guard message["role"] as? String == "assistant" else { return [] }

        // Extract text: array of content blocks → join "text" blocks; plain string fallback.
        let text: String
        if let blocks = message["content"] as? [[String: Any]] {
            let pieces = blocks.compactMap { block -> String? in
                guard block["type"] as? String == "text",
                      let t = block["text"] as? String else { return nil }
                return t
            }
            text = pieces.joined(separator: "\n")
        } else if let plain = message["content"] as? String {
            text = plain
        } else {
            text = ""
        }

        guard !text.isEmpty else { return [] }

        if let runId = context.activeChannelRuns[sessionKey] {
            // Active run exists — emit just the delta; sessions.changed(end) closes it.
            return [.textDelta(run: runId, session: sessionKey, text: text)]
        } else {
            // No active run (message arrived without a preceding sessions.changed) —
            // synthesise a self-contained run keyed by messageId.
            let messageId = (payload["messageId"] as? String) ?? sessionKey
            let run = messageId.isEmpty ? sessionKey : messageId
            return [
                .runStarted(run: run, session: sessionKey),
                .textDelta(run: run, session: sessionKey, text: text),
                .runEnded(run: run, session: sessionKey),
            ]
        }
    }
}
