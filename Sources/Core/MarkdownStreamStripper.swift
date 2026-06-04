import Foundation

/// Character-level streaming markdown remover. Safe across arbitrary chunk
/// boundaries: backtick runs and link URLs may span feeds.
public final class MarkdownStreamStripper {
    private var inFence = false
    private var inURL = false           // between "](" and ")"
    private var backtickRun = 0
    private var atLineStart = true
    private var lastEmittedWasBracketClose = false

    public init() {}

    public func feed(_ chunk: String) -> String {
        var out = ""
        for ch in chunk {
            if ch == "`" {
                backtickRun += 1
                continue
            }
            if backtickRun > 0 {
                settleBacktickRun(into: &out)
            }
            if inFence {
                if ch == "\n" { atLineStart = true }
                continue
            }
            if inURL {
                if ch == ")" { inURL = false }
                continue
            }
            switch ch {
            case "*", "_", "~":
                continue
            case "[":
                lastEmittedWasBracketClose = false
                continue
            case "]":
                lastEmittedWasBracketClose = true
                continue
            case "(" where lastEmittedWasBracketClose:
                lastEmittedWasBracketClose = false
                inURL = true
                continue
            case "#" where atLineStart:
                continue
            case " " where atLineStart:
                // swallow the single space after heading #'s; harmless otherwise
                // (leading spaces at line start are not significant for RSVP)
                continue
            case "\n":
                atLineStart = true
                lastEmittedWasBracketClose = false
                out.append(ch)
                continue
            default:
                atLineStart = false
                lastEmittedWasBracketClose = false
                out.append(ch)
            }
        }
        return out
    }

    /// Call at end-of-message: resolves a trailing backtick run.
    public func flush() -> String {
        var out = ""
        if backtickRun > 0 { settleBacktickRun(into: &out) }
        return out
    }

    private func settleBacktickRun(into out: inout String) {
        if backtickRun >= 3 {
            inFence.toggle()
            if inFence { out += " [code] " }
        }
        backtickRun = 0
    }
}
