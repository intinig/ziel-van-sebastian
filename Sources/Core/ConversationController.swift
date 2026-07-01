import Foundation

public enum WakeMode: Equatable {
    case armed      // idle: only the wake word triggers capture
    case listen     // conversation active, awaiting user speech (no wake word)
    case speaking   // Sebastian is talking; mic armed for barge-in
    case followUp   // short window after speaking; VAD, no wake word
}

public enum ConversationCommand: Equatable {
    case setWakeMode(WakeMode)
    case inject(String)   // send this text to OpenClaw
    case stopSpeaking     // barge-in: drop pending speech + stop playback
}

/// Pure conversation state machine. Clock injected; no audio or networking.
public final class ConversationController {
    public enum State: Equatable { case idle, listening, awaitingReply, speaking, followUp }

    public private(set) var state: State = .idle

    private let followUpWindow: TimeInterval
    private let listenWindow: TimeInterval
    private let replyTimeout: TimeInterval
    private var windowStart: TimeInterval = 0

    public init(followUpWindowSeconds: TimeInterval = 8,
                listenWindowSeconds: TimeInterval = 10,
                replyTimeoutSeconds: TimeInterval = 30) {
        self.followUpWindow = followUpWindowSeconds
        self.listenWindow = listenWindowSeconds
        self.replyTimeout = replyTimeoutSeconds
    }

    public func wake(now: TimeInterval) -> [ConversationCommand] {
        guard state == .idle else { return [] }
        state = .listening; windowStart = now
        return [.setWakeMode(.listen)]
    }

    public func heard(text: String, now: TimeInterval) -> [ConversationCommand] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch state {
        case .idle:
            return []
        case .speaking:
            state = .awaitingReply; windowStart = now
            return t.isEmpty ? [.stopSpeaking] : [.stopSpeaking, .inject(t)]
        case .listening, .followUp, .awaitingReply:
            guard !t.isEmpty else { return [] }
            state = .awaitingReply; windowStart = now
            return [.inject(t)]
        }
    }

    public func bargeInDetected(now: TimeInterval) -> [ConversationCommand] {
        guard state == .speaking else { return [] }
        state = .listening; windowStart = now
        return [.stopSpeaking, .setWakeMode(.listen)]
    }

    public func replyStarted(now: TimeInterval) -> [ConversationCommand] {
        guard state != .idle else { return [] }
        state = .speaking
        return [.setWakeMode(.speaking)]
    }

    public func replyFinished(now: TimeInterval) -> [ConversationCommand] {
        guard state == .speaking else { return [] }
        state = .followUp; windowStart = now
        return [.setWakeMode(.followUp)]
    }

    public func tick(now: TimeInterval) -> [ConversationCommand] {
        let elapsed = now - windowStart
        switch state {
        case .followUp where elapsed >= followUpWindow,
             .listening where elapsed >= listenWindow,
             .awaitingReply where elapsed >= replyTimeout:
            state = .idle
            return [.setWakeMode(.armed)]
        default:
            return []
        }
    }
}
