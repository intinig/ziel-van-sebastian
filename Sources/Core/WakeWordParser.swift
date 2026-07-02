import Foundation

/// Matches a leading wake word in a whisper transcript, tolerant of case,
/// diacritics, punctuation, and surrounding whitespace.
public enum WakeWordParser {
    public static func match(transcript: String, wakeWord: String) -> String? {
        let fold: (String) -> String = {
            $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = fold(text), wake = fold(wakeWord)
        guard folded.hasPrefix(wake) else { return nil }
        let after = text.index(text.startIndex, offsetBy: wake.count)
        let rest = String(text[after...])
        // The wake word must end at a word boundary ("sebastians car" is not a wake).
        if let first = rest.first, first.isLetter || first.isNumber { return nil }
        let charSet = CharacterSet.punctuationCharacters.union(.whitespacesAndNewlines)
        return String(rest.drop { $0.unicodeScalars.allSatisfy { charSet.contains($0) } })
    }
}
