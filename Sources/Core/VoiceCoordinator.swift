import Foundation

/// Sends commands to the voice-gateway (mode changes / stop).
public protocol VoiceLink: AnyObject {
    func send(_ command: VoiceCommand)
}

/// Injects a user prompt into OpenClaw's main session.
public protocol PromptInjecting: AnyObject {
    func sendPrompt(_ text: String)
}

/// Whether the face is currently speaking a reply.
public protocol SpeakingSource: AnyObject {
    var isSpeaking: Bool { get }
}

/// Stops the face mid-reply (barge-in): drop pending speech + halt playback.
public protocol SpeechStopping: AnyObject {
    func stopSpeaking(now: TimeInterval)
}

/// Pure glue between voice events, the Director's speaking-state, and the
/// ConversationController. No audio, no networking — dependencies are protocols
/// so it is fully unit-testable. All timing is injected via `now`.
public final class VoiceCoordinator {
    private let controller: ConversationController
    private let link: VoiceLink
    private let injector: PromptInjecting
    private let speaking: SpeakingSource
    private let stopper: SpeechStopping
    private let bargeInEnabled: () -> Bool
    private var wasSpeaking = false

    public init(controller: ConversationController,
                link: VoiceLink,
                injector: PromptInjecting,
                speaking: SpeakingSource,
                stopper: SpeechStopping,
                bargeInEnabled: @escaping () -> Bool) {
        self.controller = controller
        self.link = link
        self.injector = injector
        self.speaking = speaking
        self.stopper = stopper
        self.bargeInEnabled = bargeInEnabled
    }

    /// Consume one gateway event. Call on the main queue.
    public func handle(_ event: VoiceEvent, now: TimeInterval) {
        switch event {
        case .ready, .listening:
            break   // mode resync lives in the client; `listening` is informational
        case .wake:
            execute(controller.wake(now: now), now: now)
        case .vad(let isSpeaking):
            // Fast-path barge-in: user speech onset while the face is speaking.
            guard isSpeaking, bargeInEnabled(), speaking.isSpeaking else { return }
            execute(controller.bargeInDetected(now: now), now: now)
        case .heard(let text):
            // Transcript-beats-onset safety net when state == .speaking — but only
            // when barge-in is enabled. With `voice.bargeIn: false` this must be a
            // coherent "never interrupt" mode, so a heard-while-speaking transcript
            // is dropped here (mirrors the `.vad` gate above) instead of being
            // routed through `controller.heard`, which would unconditionally
            // return `[.stopSpeaking, .inject]` and both interrupt playback and
            // advance the controller past `.speaking` (breaking the normal
            // replyFinished → follow-up transition) even with barge-in off.
            if controller.state == .speaking && !bargeInEnabled() { return }
            execute(controller.heard(text: text, now: now), now: now)
        case .error:
            break   // voice degrades silently; never wedge the face
        }
    }

    /// Periodic tick (main queue): detects speaking transitions + drives timeouts.
    public func tick(now: TimeInterval) {
        // Single sample of Director.isSpeaking per tick — stable across a
        // continuous TTS utterance, but display-only pacing (no TTS configured)
        // may flap true/false between sentences; known and cosmetic, since a
        // brief spurious replyStarted/replyFinished pair only nudges wake mode.
        let nowSpeaking = speaking.isSpeaking
        if nowSpeaking && !wasSpeaking {
            execute(controller.replyStarted(now: now), now: now)
        } else if !nowSpeaking && wasSpeaking {
            execute(controller.replyFinished(now: now), now: now)
        }
        wasSpeaking = nowSpeaking
        execute(controller.tick(now: now), now: now)
    }

    public func setFollowUpWindow(_ seconds: TimeInterval) {
        controller.setFollowUpWindow(seconds)
    }

    private func execute(_ commands: [ConversationCommand], now: TimeInterval) {
        for command in commands {
            switch command {
            case .setWakeMode(let mode):
                link.send(.mode(mode))
            case .inject(let text):
                injector.sendPrompt(text)
            case .stopSpeaking:
                // Stop the FACE only — the service keeps capturing so the
                // barge-in utterance still arrives as `heard`.
                stopper.stopSpeaking(now: now)
            }
        }
    }
}
