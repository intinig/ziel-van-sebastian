import Foundation

public struct PacedWord: Equatable {
    public let text: String
    public let holdMs: Double
}

/// RSVP queue: stripped text in, paced words out. Holds a trailing partial
/// word until whitespace or endOfText proves it complete.
public final class WordPacer {
    /// Replaced atomically by the Director on config reload; new values take effect
    /// on the next `nextWord()` call.
    public var config: PacingConfig
    private var queue: [String] = []
    private var partial = ""

    public init(config: PacingConfig) {
        self.config = config
    }

    public var backlog: Int { queue.count }
    public var isEmpty: Bool { queue.isEmpty && partial.isEmpty }

    public func feed(_ text: String) {
        for ch in text {
            if ch.isWhitespace {
                if !partial.isEmpty {
                    queue.append(partial)
                    partial = ""
                }
            } else {
                partial.append(ch)
            }
        }
    }

    public func endOfText() {
        if !partial.isEmpty {
            queue.append(partial)
            partial = ""
        }
    }

    /// Pops the next complete word. `holdMs` on the returned value is computed using
    /// the backlog *after* this pop, so `pacer.backlog` immediately following this call
    /// equals the depth that drove the catch-up factor.
    public func nextWord() -> PacedWord? {
        guard !queue.isEmpty else { return nil }
        let word = queue.removeFirst()
        return PacedWord(text: word, holdMs: hold(for: word, backlog: queue.count))
    }

    public func reset() {
        queue.removeAll()
        partial = ""
    }

    private func hold(for word: String, backlog: Int) -> Double {
        var ms = config.baseMs
        let extra = word.count - config.charThreshold
        if extra > 0 { ms += Double(extra) * config.perCharMs }
        if let last = word.unicodeScalars.last {
            if ".!?\u{2026}".unicodeScalars.contains(last) {
                ms += config.sentencePauseMs
            } else if ",;:".unicodeScalars.contains(last) {
                ms += config.clausePauseMs
            }
        }
        return ms * catchupFactor(backlog: backlog)
    }

    private func catchupFactor(backlog: Int) -> Double {
        if backlog <= config.catchupStart { return 1.0 }
        if backlog >= config.catchupFull { return config.minFactor }
        let t = Double(backlog - config.catchupStart) / Double(config.catchupFull - config.catchupStart)
        return 1.0 + (config.minFactor - 1.0) * t
    }
}
