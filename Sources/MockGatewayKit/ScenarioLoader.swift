import Foundation

public struct MockStep {
    public var delayMs: Int
    /// JSON frame to send (already serialized).
    public var frame: Data?
    /// Raw (possibly invalid) text to send verbatim.
    public var raw: String?
    /// Close the connection at this step.
    public var close: Bool

    public init(delayMs: Int, frame: Data? = nil, raw: String? = nil, close: Bool = false) {
        self.delayMs = delayMs; self.frame = frame; self.raw = raw; self.close = close
    }

    /// Convenience: build a step from a JSON-shaped dictionary.
    public static func send(_ obj: [String: Any], afterMs delay: Int) -> MockStep {
        // inputs are always literal dictionaries — serialisation cannot fail
        MockStep(delayMs: delay, frame: try! JSONSerialization.data(withJSONObject: obj))
    }
}

public enum ScenarioLoader {
    /// File shape: {"steps":[{"delayMs":100,"send":{…}} | {"delayMs":0,"sendRaw":"…"} | {"delayMs":0,"close":true}]}
    public static func load(_ url: URL) throws -> [MockStep] {
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = obj["steps"] as? [[String: Any]] else {
            throw NSError(domain: "ScenarioLoader", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "scenario must have a steps array"])
        }
        return try steps.map { s in
            let delay = s["delayMs"] as? Int ?? 0
            if let send = s["send"] as? [String: Any] {
                return MockStep(delayMs: delay, frame: try JSONSerialization.data(withJSONObject: send))
            }
            if let raw = s["sendRaw"] as? String {
                return MockStep(delayMs: delay, raw: raw)
            }
            if s["close"] as? Bool == true {
                return MockStep(delayMs: delay, close: true)
            }
            throw NSError(domain: "ScenarioLoader", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "step needs send, sendRaw, or close"])
        }
    }
}
