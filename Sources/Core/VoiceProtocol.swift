import Foundation

public enum VoiceEvent: Equatable {
    case ready(version: Int)
    case wake
    case listening
    case vad(speaking: Bool)
    case heard(text: String)
    case error(message: String)
}

public enum VoiceCommand: Equatable {
    case mode(WakeMode)
    case stop
}

/// JSON wire codec for the loopback voice-gateway WebSocket. Both the service
/// and the app use exactly this; the wire format is pinned by tests.
public enum VoiceProtocol {
    static let modeNames: [(WakeMode, String)] = [
        (.armed, "armed"), (.listen, "listen"), (.speaking, "speaking"), (.followUp, "followup"),
    ]

    public static func encode(_ e: VoiceEvent) -> Data {
        let obj: [String: Any]
        switch e {
        case .ready(let v):   obj = ["event": "ready", "version": v]
        case .wake:           obj = ["event": "wake"]
        case .listening:      obj = ["event": "listening"]
        case .vad(let s):     obj = ["event": "vad", "speaking": s]
        case .heard(let t):   obj = ["event": "heard", "text": t]
        case .error(let m):   obj = ["event": "error", "message": m]
        }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    public static func decodeEvent(_ d: Data) -> VoiceEvent? {
        guard let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        switch obj["event"] as? String {
        case "ready":     return (obj["version"] as? Int).map { .ready(version: $0) }
        case "wake":      return .wake
        case "listening": return .listening
        case "vad":       return (obj["speaking"] as? Bool).map { .vad(speaking: $0) }
        case "heard":     return (obj["text"] as? String).map { .heard(text: $0) }
        case "error":     return (obj["message"] as? String).map { .error(message: $0) }
        default:          return nil
        }
    }

    public static func encode(_ c: VoiceCommand) -> Data {
        let obj: [String: Any]
        switch c {
        case .mode(let m):
            let name: String
            switch m {
            case .armed:    name = "armed"
            case .listen:   name = "listen"
            case .speaking: name = "speaking"
            case .followUp: name = "followup"
            }
            obj = ["cmd": "mode", "mode": name]
        case .stop:        obj = ["cmd": "stop"]
        }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    public static func decodeCommand(_ d: Data) -> VoiceCommand? {
        guard let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        switch obj["cmd"] as? String {
        case "mode": return (obj["mode"] as? String).flatMap { n in modeNames.first { $0.1 == n }.map { .mode($0.0) } }
        case "stop": return .stop
        default:     return nil
        }
    }
}
