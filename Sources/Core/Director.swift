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

    // MARK: - Speech state

    private struct QueuedSentence {
        enum Status: Equatable { case requested, playing, failed }
        let id: Int
        let text: String
        var status: Status = .requested
        var words: [WordTiming] = []
        var startedAt: TimeInterval = 0
    }

    private var speechEnabled: Bool
    private var speechQueue: [QueuedSentence] = []
    private var outbox: [SpeechRequest] = []
    private var chunker = SentenceChunker()
    private var nextSpeechID = 0
    private var wordFromPacer = true

    /// Sentences queued, in flight, or playing — display must not wind down.
    private var speechBusy: Bool { !speechQueue.isEmpty || !outbox.isEmpty }

    public init(config: ZielConfig, look: ResolvedLook) {
        self.pacer = WordPacer(config: config.pacing)
        self.behavior = config.behavior
        self.idleTint = ColorRGB(hex: look.idleTint)
        self.thinkingTint = ColorRGB(hex: look.thinkingTint)
        self.speakingTint = ColorRGB(hex: look.speakingTint)
        self.speechEnabled = config.speech.enabled
    }

    /// Live config reload (pacing only; tints/timings need restart in v1).
    public func updatePacing(_ p: PacingConfig) {
        pacer.config = p
    }

    /// Live config reload: toggles the speech routing fork for future text.
    public func setSpeechEnabled(_ on: Bool) {
        speechEnabled = on
    }

    /// Drains queued sentences for the speech coordinator (called on frame tick).
    public func takeSpeechRequests() -> [SpeechRequest] {
        let out = outbox
        outbox.removeAll()
        return out
    }

    /// TTS for `id` failed — its text will display via the pacer when it
    /// reaches the queue head (full display behavior wired in advance()).
    public func speechFailed(id: Int, now: TimeInterval) {
        guard let i = speechQueue.firstIndex(where: { $0.id == id }) else { return }
        speechQueue[i].status = .failed
        lastActivity = now
    }

    /// Audio playback for sentence `id` began at `now`; `words` are timed
    /// relative to that instant.
    public func speechStarted(id: Int, words: [WordTiming], now: TimeInterval) {
        guard let i = speechQueue.firstIndex(where: { $0.id == id }) else { return }
        speechQueue[i].status = .playing
        speechQueue[i].words = words
        speechQueue[i].startedAt = now
        lastActivity = now
    }

    /// Audio playback for sentence `id` finished. If it wasn't the queue head
    /// (rare race behind a failed sentence), its words are skipped — the voice
    /// already said them.
    public func speechFinished(id: Int, now: TimeInterval) {
        speechQueue.removeAll { $0.id == id }
        lastActivity = now
    }

    /// Number of tracked runs — for tests and diagnostics only.
    public var runCount: Int { runs.count }

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
            if focusedRun == run {
                if speechEnabled {
                    if let tail = chunker.flush() { enqueueSpeech(tail) }
                } else {
                    pacer.endOfText()
                }
            } else if runs[run]!.pending.isEmpty {
                // Tool-only or empty-text run: nothing left to say — evict now
                // so days of background runs can't grow `runs` unboundedly.
                runs.removeValue(forKey: run)
            }
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
        speechQueue.removeAll()
        outbox.removeAll()
        chunker = SentenceChunker()
        wordFromPacer = true
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

    private func enqueueSpeech(_ sentence: String) {
        let text = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let id = nextSpeechID
        nextSpeechID += 1
        speechQueue.append(QueuedSentence(id: id, text: text))
        outbox.append(SpeechRequest(id: id, text: text))
    }

    private func route(_ stripped: String, from run: String) {
        guard !stripped.isEmpty else { return }
        if focusedRun == nil {
            focusedRun = run
        }
        if focusedRun == run {
            if speechEnabled {
                for s in chunker.feed(stripped) { enqueueSpeech(s) }
                // Late delta after runEnded (out-of-order frames): flush the tail.
                if runs[run]?.ended == true, let tail = chunker.flush() { enqueueSpeech(tail) }
            } else {
                pacer.feed(stripped)
                // Late delta after runEnded (out-of-order frames): re-seal the queue.
                if runs[run]?.ended == true { pacer.endOfText() }
            }
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
            processFailedSpeech()
            if startNextWord(now: now) {
                go(.speaking, now: now)
                return
            }
            // Enter speaking only once the voice is actually saying a word —
            // leading audio silence (words[0].start > 0) stays in thinking.
            if updateTimelineWord(now: now), currentWord != nil {
                go(.speaking, now: now)
                return
            }
            // The focused run may have died with nothing queued — release it so
            // pending runs can be adopted and the machine can wind down.
            if let focused = focusedRun, runs[focused]?.ended ?? true, pacer.isEmpty, !speechBusy {
                runs.removeValue(forKey: focused)
                focusedRun = nil
                if adoptPendingRun(now: now), startNextWord(now: now) {
                    go(.speaking, now: now)
                    return
                }
            }
            if !anyActiveRuns && !speechBusy {
                go(.settling, now: now)
            }
        case .speaking:
            processFailedSpeech()
            // A pacer word (speech off, or fallback text) holds for its duration.
            if wordFromPacer, let word = currentWord,
               (now - wordStart) * 1000 < word.holdMs {
                return
            }
            if startNextWord(now: now) { return }
            if updateTimelineWord(now: now) { return }
            if speechBusy { return }   // between sentences: hold the last word
            finishSpeaking(now: now)
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
            wordFromPacer = true
            return true
        }
        return false
    }

    /// Deliberately follows only the queue HEAD — relies on the coordinator
    /// starting playback strictly in queue order (Task 6 contract).
    private var timelineForHead: (startedAt: TimeInterval, words: [WordTiming])? {
        guard let head = speechQueue.first, head.status == .playing else { return nil }
        return (head.startedAt, head.words)
    }

    /// Failed sentences at the queue head display via the pacer, in order.
    private func processFailedSpeech() {
        while let head = speechQueue.first, head.status == .failed {
            speechQueue.removeFirst()
            pacer.feed(head.text)
            pacer.endOfText()
        }
    }

    /// Audio-clock word selection: picks the word whose start has passed.
    /// Returns true while a timeline is active (display follows the voice).
    private func updateTimelineWord(now: TimeInterval) -> Bool {
        guard let (startedAt, words) = timelineForHead, !words.isEmpty else { return false }
        let t = now - startedAt
        if let idx = words.lastIndex(where: { $0.start <= t }) {
            let w = words[idx]
            let start = startedAt + w.start
            if currentWord?.text != w.text || wordStart != start {
                currentWord = PacedWord(text: w.text, holdMs: (w.end - w.start) * 1000)
                wordStart = start
                wordFromPacer = false
            }
        }
        return true
    }

    private func finishSpeaking(now: TimeInterval) {
        currentWord = nil
        guard let focused = focusedRun else {
            go((anyActiveRuns || speechBusy) ? .thinking : .settling, now: now)
            return
        }
        let focusedDone = runs[focused]?.ended ?? true
        if focusedDone && pacer.isEmpty && !speechBusy {
            runs.removeValue(forKey: focused)
            focusedRun = nil
            if adoptPendingRun(now: now) {
                go(.speaking, now: now)
                _ = startNextWord(now: now)
                if currentWord == nil { go((anyActiveRuns || speechBusy) ? .thinking : .settling, now: now) }
            } else {
                go((anyActiveRuns || speechBusy) ? .thinking : .settling, now: now)
            }
        } else {
            go(.thinking, now: now)   // run still active, waiting for more text
        }
    }

    /// Picks the most recently active run with pending text; feeds the pacer
    /// (or, with speech on, the sentence chunker).
    private func adoptPendingRun(now: TimeInterval) -> Bool {
        let candidate = runs
            .filter { !$0.value.pending.isEmpty }
            .max { $0.value.lastActivity < $1.value.lastActivity }
        guard let (run, state) = candidate else { return false }
        focusedRun = run
        if speechEnabled {
            chunker = SentenceChunker()
            for s in chunker.feed(state.pending) { enqueueSpeech(s) }
            if state.ended, let tail = chunker.flush() { enqueueSpeech(tail) }
        } else {
            pacer.feed(state.pending)
            if state.ended { pacer.endOfText() }
        }
        runs[run]!.pending = ""
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
