import Foundation

/// Main-thread pipeline between the Director's sentence outbox and the
/// synthesizer: fetches pipeline in parallel, playback stays strictly ordered.
public final class SpeechCoordinator {
    public var volume: Double

    /// ElevenLabs caps concurrent requests per tier (free tier = 2). Fetching
    /// far ahead buys nothing anyway — playback is serial — so stay at the floor.
    private static let maxConcurrentFetches = 2

    /// If a clip runs past its own audio length by this margin without the synth
    /// reporting completion, assume the completion was lost — e.g. AVAudioEngine
    /// stopped mid-buffer on an audio route/config change, so `.dataPlayedBack`
    /// never fired — and advance anyway. Without this, one lost completion
    /// strands `playing` forever and the fetched-but-unplayed backlog grows
    /// until the process is OOM-killed.
    private static let playbackWatchdogGrace: TimeInterval = 2.0

    private let director: Director
    private let synth: SpeechSynthesizing
    private let now: () -> TimeInterval
    private var fetchQueue: [SpeechRequest] = []  // accepted, waiting for a fetch slot
    private var inFlightFetches = 0
    private var awaitingPlay: [Int] = []          // request ids in arrival order
    private var ready: [Int: SpokenAudio] = [:]   // fetched, not yet played
    private var playing: Int?
    private var playingStartedAt: TimeInterval?   // when the current clip began (watchdog)
    private var playingDeadline: TimeInterval = 0 // audio length + grace, relative to start
    private var previousRequestIDs: [String] = [] // best-effort continuity stitching
    private var generation = 0                    // cancelAll() invalidates callbacks
    private var consecutiveFailures = 0
    private var circuitOpen = false               // bad key/voice/network: stop hammering the API

    public init(director: Director, synth: SpeechSynthesizing,
                volume: Double, now: @escaping () -> TimeInterval) {
        self.director = director
        self.synth = synth
        self.volume = volume
        self.now = now
    }

    /// Called once per frame tick (main thread), after director.tick.
    public func pump() {
        serviceWatchdog()
        for req in director.takeSpeechRequests() {
            if circuitOpen {
                // Spec: invalid key/voice → log once (done when the circuit
                // opened), speech effectively disabled; instant pacer fallback.
                director.speechFailed(id: req.id, now: now())
                continue
            }
            awaitingPlay.append(req.id)
            fetchQueue.append(req)
        }
        startFetchesWithinCap()
        playNextIfReady()
    }

    /// Connection lost / reset: drop everything, silence the speaker.
    /// Also re-arms the failure circuit — a reconnect is a fresh start.
    public func cancelAll() {
        generation += 1
        fetchQueue.removeAll()
        inFlightFetches = 0
        awaitingPlay.removeAll()
        ready.removeAll()
        playing = nil
        playingStartedAt = nil
        consecutiveFailures = 0
        circuitOpen = false
        synth.stopPlayback()
    }

    /// Recover from a lost playback completion: if the current clip has run past
    /// its audio length + grace and the synth still hasn't reported it finished,
    /// treat it as done so the pipeline drains instead of stranding `playing`.
    private func serviceWatchdog() {
        guard let id = playing, let startedAt = playingStartedAt,
              now() - startedAt > playingDeadline else { return }
        NSLog("speech: playback watchdog fired for id %d — advancing past a lost completion", id)
        synth.stopPlayback()
        playing = nil
        playingStartedAt = nil
        director.speechFinished(id: id, now: now())
        playNextIfReady()
    }

    private func startFetchesWithinCap() {
        if circuitOpen {
            // A burst still queued behind the cap when the circuit opened:
            // fall back now so the display never waits on dead requests.
            for req in fetchQueue {
                awaitingPlay.removeAll { $0 == req.id }
                director.speechFailed(id: req.id, now: now())
            }
            fetchQueue.removeAll()
            return
        }
        while inFlightFetches < Self.maxConcurrentFetches, !fetchQueue.isEmpty {
            let req = fetchQueue.removeFirst()
            inFlightFetches += 1
            let gen = generation
            // Fetches already in flight won't carry ids resolved after they
            // launched — stitching is best-effort by design.
            synth.fetch(req, previousRequestIDs: previousRequestIDs) { [weak self] result in
                self?.fetchCompleted(id: req.id, generation: gen, result: result)
            }
        }
    }

    private func fetchCompleted(id: Int, generation gen: Int, result: Result<SpokenAudio, Error>) {
        guard gen == generation else { return }
        inFlightFetches -= 1
        switch result {
        case .success(let audio):
            consecutiveFailures = 0
            ready[id] = audio
            if let rid = audio.requestID {
                previousRequestIDs = Array((previousRequestIDs + [rid]).suffix(3))
            }
        case .failure:
            consecutiveFailures += 1
            if consecutiveFailures >= 3 && !circuitOpen {
                circuitOpen = true
                NSLog("speech: %d consecutive TTS failures — display-only until reconnect", consecutiveFailures)
            }
            awaitingPlay.removeAll { $0 == id }
            director.speechFailed(id: id, now: now())
        }
        startFetchesWithinCap()
        playNextIfReady()
    }

    private func playNextIfReady() {
        guard playing == nil,
              let head = awaitingPlay.first,
              let audio = ready[head] else { return }
        awaitingPlay.removeFirst()
        ready[head] = nil
        playing = head
        playingStartedAt = now()
        playingDeadline = Double(audio.pcm.count / 2) / audio.sampleRate + Self.playbackWatchdogGrace
        let gen = generation
        synth.play(audio, volume: volume,
            onStarted: { [weak self] in
                guard let self, gen == self.generation, self.playing == head else { return }
                self.director.speechStarted(id: head, words: audio.words,
                                            envelope: audio.envelope, envelopeRate: audio.envelopeRate,
                                            now: self.now())
            },
            onFinished: { [weak self] in
                guard let self, gen == self.generation, self.playing == head else { return }
                self.playing = nil
                self.playingStartedAt = nil
                self.director.speechFinished(id: head, now: self.now())
                self.playNextIfReady()
            })
    }
}
