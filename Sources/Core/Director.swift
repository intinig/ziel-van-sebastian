import Foundation

/// The state machine: idle → waking → thinking ⇄ speaking → settling → idle.
/// Consumes AgentEvents, produces immutable SceneState snapshots.
/// All time is injected — never reads a clock itself.
public final class Director {
    private struct RunState {
        var session: String
        var stripper = MarkdownStreamStripper()
        var pending = ""          // stripped text not yet fed to the pacer
        var ended = false
        var lastActivity: TimeInterval
    }

    private var phase: Phase = .offline(auth: false)
    private var phaseStart: TimeInterval = 0
    private var runs: [String: RunState] = [:]
    private var focusedRun: String?
    private let pacer: WordPacer
    private var currentWord: PacedWord?
    private var wordStart: TimeInterval = 0
    private var hint: String?
    private var hintUntil: TimeInterval = 0
    private var lastActivity: TimeInterval = 0

    private var behavior: BehaviorConfig
    private let idleTint: ColorRGB
    private let thinkingTint: ColorRGB
    private let speakingTint: ColorRGB

    public init(config: ZielConfig) {
        self.pacer = WordPacer(config: config.pacing)
        self.behavior = config.behavior
        self.idleTint = ColorRGB(hex: config.look.idleTint)
        self.thinkingTint = ColorRGB(hex: config.look.thinkingTint)
        self.speakingTint = ColorRGB(hex: config.look.speakingTint)
    }

    /// Live config reload (pacing only; tints/timings need restart in v1).
    public func updatePacing(_ p: PacingConfig) {
        pacer.config = p
    }

    // MARK: - Events

    public func handle(_ event: AgentEvent, now: TimeInterval) {
        switch event {
        case .connectionUp:
            resetAll()
            go(.idle, now: now)
            lastActivity = now

        case .connectionDown(let auth):
            resetAll()
            go(.offline(auth: auth), now: now)

        case .runStarted(let run, let session):
            guard isOnline else { return }
            ensureRun(run, session: session, now: now)
            wakeIfIdle(now: now)

        case .toolStarted(let run, let session, let tool):
            guard isOnline else { return }
            ensureRun(run, session: session, now: now)
            hint = HintMapper.hint(forTool: tool)
            hintUntil = now + behavior.hintHoldSeconds
            wakeIfIdle(now: now)

        case .textDelta(let run, let session, let text):
            guard isOnline else { return }
            ensureRun(run, session: session, now: now)
            let stripped = runs[run]!.stripper.feed(text)
            route(stripped, from: run)
            wakeIfIdle(now: now)

        case .runEnded(let run, let session):
            guard isOnline else { return }
            ensureRun(run, session: session, now: now)
            let tail = runs[run]!.stripper.flush()
            route(tail, from: run)
            runs[run]!.ended = true
            if focusedRun == run { pacer.endOfText() }
        }
    }

    // MARK: - Frame tick

    public func tick(now: TimeInterval) -> SceneState {
        advance(now: now)
        let elapsed = now - phaseStart
        let progress = transitionProgress(elapsed: elapsed)
        return SceneState(
            phase: phase,
            phaseProgress: progress,
            timeInPhase: elapsed,
            word: phase == .speaking ? currentWord?.text : nil,
            wordAge: phase == .speaking ? now - wordStart : 0,
            hint: hintVisible(now: now) ? hint : nil,
            dozing: phase == .idle && (now - lastActivity) > behavior.dozeAfterSeconds,
            tint: tint(elapsed: elapsed, progress: progress)
        )
    }

    // MARK: - Internals

    private var isOnline: Bool {
        if case .offline = phase { return false }
        return true
    }

    private func resetAll() {
        runs.removeAll()
        focusedRun = nil
        pacer.reset()
        currentWord = nil
        hint = nil
    }

    private func go(_ p: Phase, now: TimeInterval) {
        phase = p
        phaseStart = now
    }

    private func ensureRun(_ run: String, session: String, now: TimeInterval) {
        if runs[run] == nil {
            runs[run] = RunState(session: session, lastActivity: now)
        } else {
            runs[run]!.lastActivity = now
        }
        lastActivity = now
    }

    private func wakeIfIdle(now: TimeInterval) {
        if phase == .idle || phase == .settling {
            go(.waking, now: now)
        }
    }

    private func route(_ stripped: String, from run: String) {
        guard !stripped.isEmpty else { return }
        if focusedRun == nil {
            focusedRun = run
        }
        if focusedRun == run {
            pacer.feed(stripped)
            if runs[run]?.ended == true { pacer.endOfText() }
        } else {
            runs[run]!.pending += stripped
        }
    }

    private func advance(now: TimeInterval) {
        switch phase {
        case .waking:
            if now - phaseStart >= behavior.wakingSeconds {
                go(.thinking, now: now)
                advance(now: now)   // may immediately start speaking
            }
        case .thinking:
            if startNextWord(now: now) {
                go(.speaking, now: now)
            }
        case .speaking:
            guard let word = currentWord else {
                if !startNextWord(now: now) { finishSpeaking(now: now) }
                return
            }
            if (now - wordStart) * 1000 >= word.holdMs {
                if !startNextWord(now: now) { finishSpeaking(now: now) }
            }
        case .settling:
            if now - phaseStart >= behavior.settlingSeconds {
                go(.idle, now: now)
            }
        case .idle, .offline:
            break
        }
    }

    private func startNextWord(now: TimeInterval) -> Bool {
        if let next = pacer.nextWord() {
            currentWord = next
            wordStart = now
            return true
        }
        return false
    }

    private func finishSpeaking(now: TimeInterval) {
        currentWord = nil
        guard let focused = focusedRun else {
            go(anyActiveRuns ? .thinking : .settling, now: now)
            return
        }
        let focusedDone = runs[focused]?.ended ?? true
        if focusedDone && pacer.isEmpty {
            runs.removeValue(forKey: focused)
            focusedRun = nil
            if adoptPendingRun(now: now) {
                go(.speaking, now: now)
                _ = startNextWord(now: now)
                if currentWord == nil { go(anyActiveRuns ? .thinking : .settling, now: now) }
            } else {
                go(anyActiveRuns ? .thinking : .settling, now: now)
            }
        } else {
            go(.thinking, now: now)   // run still active, waiting for more text
        }
    }

    /// Picks the most recently active run with pending text; feeds the pacer.
    private func adoptPendingRun(now: TimeInterval) -> Bool {
        let candidate = runs
            .filter { !$0.value.pending.isEmpty }
            .max { $0.value.lastActivity < $1.value.lastActivity }
        guard let (run, state) = candidate else { return false }
        focusedRun = run
        pacer.feed(state.pending)
        runs[run]!.pending = ""
        if state.ended { pacer.endOfText() }
        return true
    }

    private var anyActiveRuns: Bool {
        runs.contains { !$0.value.ended || !$0.value.pending.isEmpty }
    }

    private func hintVisible(now: TimeInterval) -> Bool {
        (phase == .waking || phase == .thinking) && now < hintUntil && hint != nil
    }

    private func transitionProgress(elapsed: TimeInterval) -> Double {
        switch phase {
        case .waking: return min(1, elapsed / behavior.wakingSeconds)
        case .settling: return min(1, elapsed / behavior.settlingSeconds)
        default: return 1
        }
    }

    private func tint(elapsed: TimeInterval, progress: Double) -> ColorRGB {
        switch phase {
        case .idle: return idleTint
        case .waking: return ColorRGB.lerp(idleTint, thinkingTint, progress)
        case .thinking: return thinkingTint
        case .speaking: return ColorRGB.lerp(thinkingTint, speakingTint, min(1, elapsed / 0.3))
        case .settling: return ColorRGB.lerp(speakingTint, idleTint, progress)
        case .offline: return idleTint.scaled(0.45)
        }
    }
}
