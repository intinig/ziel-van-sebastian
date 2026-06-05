import Foundation

/// Accumulates streamed (already markdown-stripped) text and emits complete
/// sentences for per-sentence TTS requests. Pure — no clocks, no platform.
public struct SentenceChunker {
    private var buffer = ""

    private static let terminators: Set<Character> = [".", "!", "?", "…"]
    // closing quotes/brackets after a terminator — not apostrophes inside words
    private static let closers: Set<Character> = ["\"", "'", ")", "]", "\u{201D}", "\u{2019}"]
    // Lowercased, dots removed ("e.g." → "eg"). Single letters handled separately.
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "eg", "ie", "approx", "fig",
    ]

    public init() {}

    /// Feed a delta; returns any complete sentences (trimmed, non-empty).
    /// A fragment without a terminator stays buffered until more text arrives
    /// or `flush()` is called — streamed deltas routinely end mid-sentence.
    public mutating func feed(_ text: String) -> [String] {
        buffer += text
        var out: [String] = []
        while let cut = nextBoundary() {
            let sentence = String(buffer[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
            buffer.removeSubrange(..<cut)
            if !sentence.isEmpty { out.append(sentence) }
        }
        return out
    }

    /// End of run: returns the trailing fragment, if any, and resets.
    public mutating func flush() -> String? {
        let tail = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer = ""
        return tail.isEmpty ? nil : tail
    }

    private func nextBoundary() -> String.Index? {
        var i = buffer.startIndex
        while i < buffer.endIndex {
            let ch = buffer[i]
            if ch == "\n" {
                return buffer.index(after: i)
            }
            if Self.terminators.contains(ch) {
                var j = buffer.index(after: i)
                while j < buffer.endIndex, Self.closers.contains(buffer[j]) {
                    j = buffer.index(after: j)
                }
                // Boundary only when followed by whitespace already in the buffer:
                // a terminator at buffer end may be "3." of "3.14" still streaming.
                if j < buffer.endIndex, buffer[j].isWhitespace, !isAbbreviation(endingAt: i) {
                    return j
                }
            }
            i = buffer.index(after: i)
        }
        return nil
    }

    private func isAbbreviation(endingAt i: String.Index) -> Bool {
        guard buffer[i] == "." else { return false }
        var s = i
        while s > buffer.startIndex {
            let p = buffer.index(before: s)
            let c = buffer[p]
            if c.isLetter || c == "." { s = p } else { break }
        }
        let token = buffer[s..<i].lowercased().replacingOccurrences(of: ".", with: "")
        if token.count == 1 {
            // Contraction guard: "can't." walks back to just "t" — the
            // apostrophe before it means this is not an initial like "J."
            if s > buffer.startIndex {
                let preceding = buffer[buffer.index(before: s)]
                if preceding == "'" || preceding == "\u{2019}" { return false }
            }
            return true   // initials: "J."
        }
        return Self.abbreviations.contains(token)
    }
}
