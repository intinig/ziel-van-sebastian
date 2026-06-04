import Foundation

/// The single place that understands OpenClaw's gateway frames.
/// Everything else speaks AgentEvent.
public enum OpenClawTranslator {
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
}
