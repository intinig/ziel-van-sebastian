import Foundation

/// Main-thread pipeline between the Director's sentence outbox and the
/// synthesizer: fetches pipeline in parallel, playback stays strictly ordered.
public final class SpeechCoordinator {
    public var volume: Double

    private let director: Director
    private let synth: SpeechSynthesizing
    private let now: () -> TimeInterval
    private var awaitingPlay: [Int] = []          // request ids in arrival order
    private var ready: [Int: SpokenAudio] = [:]   // fetched, not yet played
    private var playing: Int?
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
        for req in director.takeSpeechRequests() {
            if circuitOpen {
                // Spec: invalid key/voice → log once (done when the circuit
                // opened), speech effectively disabled; instant pacer fallback.
                director.speechFailed(id: req.id, now: now())
                continue
            }
            awaitingPlay.append(req.id)
            let gen = generation
            synth.fetch(req, previousRequestIDs: previousRequestIDs) { [weak self] result in
                self?.fetchCompleted(id: req.id, generation: gen, result: result)
            }
        }
        playNextIfReady()
    }

    /// Connection lost / reset: drop everything, silence the speaker.
    /// Also re-arms the failure circuit — a reconnect is a fresh start.
    public func cancelAll() {
        generation += 1
        awaitingPlay.removeAll()
        ready.removeAll()
        playing = nil
        consecutiveFailures = 0
        circuitOpen = false
        synth.stopPlayback()
    }

    private func fetchCompleted(id: Int, generation gen: Int, result: Result<SpokenAudio, Error>) {
        guard gen == generation else { return }
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
        playNextIfReady()
    }

    private func playNextIfReady() {
        guard playing == nil,
              let head = awaitingPlay.first,
              let audio = ready[head] else { return }
        awaitingPlay.removeFirst()
        ready[head] = nil
        playing = head
        let gen = generation
        synth.play(audio, volume: volume,
            onStarted: { [weak self] in
                guard let self = self, gen == self.generation else { return }
                self.director.speechStarted(id: head, words: audio.words, now: self.now())
            },
            onFinished: { [weak self] in
                guard let self = self, gen == self.generation else { return }
                self.playing = nil
                self.director.speechFinished(id: head, now: self.now())
                self.playNextIfReady()
            })
    }
}
