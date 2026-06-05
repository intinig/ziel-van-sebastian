import Foundation

/// Character-level alignment as returned by ElevenLabs `with-timestamps` endpoints.
public struct ElevenLabsAlignment: Codable, Equatable {
    public let characters: [String]
    public let characterStartTimesSeconds: [Double]
    public let characterEndTimesSeconds: [Double]

    enum CodingKeys: String, CodingKey {
        case characters
        case characterStartTimesSeconds = "character_start_times_seconds"
        case characterEndTimesSeconds = "character_end_times_seconds"
    }

    public init(characters: [String],
                characterStartTimesSeconds: [Double],
                characterEndTimesSeconds: [Double]) {
        self.characters = characters
        self.characterStartTimesSeconds = characterStartTimesSeconds
        self.characterEndTimesSeconds = characterEndTimesSeconds
    }
}

public enum AlignmentMapper {
    /// Groups character timings into word timings (whitespace-delimited).
    public static func words(from a: ElevenLabsAlignment) -> [WordTiming] {
        var out: [WordTiming] = []
        var word = ""
        var start = 0.0
        var end = 0.0
        let n = min(a.characters.count,
                    a.characterStartTimesSeconds.count,
                    a.characterEndTimesSeconds.count)
        for k in 0..<n {
            let ch = a.characters[k]
            if ch.allSatisfy({ $0.isWhitespace }) {
                if !word.isEmpty {
                    out.append(WordTiming(text: word, start: start, end: end))
                    word = ""
                }
            } else {
                if word.isEmpty { start = a.characterStartTimesSeconds[k] }
                word += ch
                end = a.characterEndTimesSeconds[k]
            }
        }
        if !word.isEmpty { out.append(WordTiming(text: word, start: start, end: end)) }
        return out
    }
}
