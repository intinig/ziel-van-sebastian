# Fish Audio TTS Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add fish.audio as the default TTS provider (~3–7x cheaper than ElevenLabs) behind a provider abstraction, and batch queued sentences into single requests so prosody drift gets better rather than worse.

**Architecture:** `ElevenLabsTTS` is split into a provider-agnostic `AudioPlayback` (the AVAudioEngine graph) and a `TTSFetching` implementation per provider, composed by a thin `TTSService`. The fetch seam becomes batch-shaped: it takes several `SpeechRequest`s, synthesizes them as one generation, and splits the result back into per-sentence `SpokenAudio` using word timings — so `Director`'s per-sentence queue never learns batching exists.

**Tech Stack:** Swift 5.10 language mode, XCTest, XcodeGen-generated project, URLSession, AVAudioEngine. No new dependencies.

Spec: `docs/superpowers/specs/2026-07-30-fish-audio-tts-design.md`

## Global Constraints

- Swift language mode 5.10 — do not bump it.
- `*.xcodeproj` is generated and gitignored: edit `project.yml`, never the project file. **No `project.yml` change is needed in this plan** — `Sources` and `Tests` are directory-globbed already.
- All new logic in `Sources/Core` and `Sources/Speech` is covered by the `CoreTests` target. `make test` is the source of truth; SourceKit diagnostics in editors are stale and noisy here.
- Clock injection: no `Date()` in logic; time comes in via parameters.
- TTS is optional and must never block the face — every failure path degrades to display-only pacing.
- `SpeechSynthesizing` contract: **all callbacks must be invoked on the main thread.**
- Time-to-first-audio must not regress. The first sentence of a reply is always fetched alone.
- Real `config.json` never goes in git; `config.example.json` is the committed template.
- Run the full suite with `make test`. Run one test class with:
  `xcodebuild -project ZielVanSebastian.xcodeproj -scheme ZielVanSebastian -configuration Debug -derivedDataPath build -destination 'platform=macOS' -only-testing:CoreTests/<ClassName> test 2>&1 | tail -20`

---

# Phase 1 — Extraction and batching (still on ElevenLabs)

Phase 1 ends with a listening test against the drift that exists today, on the provider already in use. If batching does not audibly help, that is discovered before any fish work depends on it.

## Task 1: Token/timing reconciliation in Core

Providers normalize text: fish returns `"can't"` as `"cant"` and `"it's"` as `"its"`. `WordTiming.text` is what the face displays, so text must always come from our own tokens and only the timings from the provider. This function also guarantees exactly one `WordTiming` per token, which is what makes batch splitting in Task 2 exact.

**Files:**
- Modify: `Sources/Core/AlignmentMapper.swift` (append two static functions to the existing `AlignmentMapper` enum, which currently ends at line 49)
- Test: `Tests/AlignmentReconcileTests.swift` (create)

**Interfaces:**
- Consumes: `WordTiming` from `Sources/Core/SpeechTypes.swift` — `WordTiming(text: String, start: TimeInterval, end: TimeInterval)`, `Equatable`
- Produces:
  - `AlignmentMapper.tokens(_ text: String) -> [String]`
  - `AlignmentMapper.reconcile(_ timings: [WordTiming], displayTokens: [String]) -> [WordTiming]` — result count always equals `displayTokens.count`, or `[]` when reconciliation is impossible

- [ ] **Step 1: Write the failing tests**

Create `Tests/AlignmentReconcileTests.swift`:

```swift
import XCTest

final class AlignmentReconcileTests: XCTestCase {
    func testTokensSplitsOnWhitespace() {
        XCTAssertEqual(AlignmentMapper.tokens("  Hello   brave world \n"),
                       ["Hello", "brave", "world"])
        XCTAssertEqual(AlignmentMapper.tokens("   "), [])
    }

    func testEqualCountsKeepsOurTextAndProviderTimings() {
        // fish strips the apostrophe; the face must still display "can't".
        let timings = [WordTiming(text: "I", start: 0.0, end: 0.2),
                       WordTiming(text: "cant", start: 0.2, end: 0.6)]
        let out = AlignmentMapper.reconcile(timings, displayTokens: ["I", "can't"])
        XCTAssertEqual(out, [WordTiming(text: "I", start: 0.0, end: 0.2),
                             WordTiming(text: "can't", start: 0.2, end: 0.6)])
    }

    func testMismatchedCountsDistributeProportionallyByCharacterLength() {
        // One segment spanning 0…1s, two tokens of 1 and 3 characters.
        let timings = [WordTiming(text: "abbb", start: 0.0, end: 1.0)]
        let out = AlignmentMapper.reconcile(timings, displayTokens: ["a", "bbb"])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].text, "a")
        XCTAssertEqual(out[0].start, 0.0, accuracy: 0.0001)
        XCTAssertEqual(out[0].end, 0.25, accuracy: 0.0001)
        XCTAssertEqual(out[1].text, "bbb")
        XCTAssertEqual(out[1].start, 0.25, accuracy: 0.0001)
        XCTAssertEqual(out[1].end, 1.0, accuracy: 0.0001)
    }

    func testMismatchedCountsAlwaysReturnsOnePerToken() {
        let timings = [WordTiming(text: "one", start: 0.0, end: 0.5),
                       WordTiming(text: "two", start: 0.5, end: 1.0)]
        let out = AlignmentMapper.reconcile(timings, displayTokens: ["a", "b", "c", "d", "e"])
        XCTAssertEqual(out.count, 5)
        XCTAssertEqual(out.map(\.text), ["a", "b", "c", "d", "e"])
    }

    func testEmptyInputsYieldEmpty() {
        XCTAssertTrue(AlignmentMapper.reconcile([], displayTokens: []).isEmpty)
        // No timings at all: reconciliation is impossible, so the caller must
        // treat the response as malformed rather than invent a timeline.
        XCTAssertTrue(AlignmentMapper.reconcile([], displayTokens: ["a"]).isEmpty)
    }

    func testDegenerateSpanYieldsEmpty() {
        let timings = [WordTiming(text: "x", start: 1.0, end: 1.0)]
        XCTAssertTrue(AlignmentMapper.reconcile(timings, displayTokens: ["a", "b"]).isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project ZielVanSebastian.xcodeproj -scheme ZielVanSebastian -configuration Debug -derivedDataPath build -destination 'platform=macOS' -only-testing:CoreTests/AlignmentReconcileTests test 2>&1 | tail -20`

Expected: compile failure — `type 'AlignmentMapper' has no member 'tokens'` / `'reconcile'`.

- [ ] **Step 3: Implement**

Append inside the `AlignmentMapper` enum in `Sources/Core/AlignmentMapper.swift`, after the existing `words(from:)` function:

```swift
    /// Whitespace-delimited display tokens — the units the face shows one at a
    /// time, and the unit every provider's timings get mapped onto.
    public static func tokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Maps provider word timings onto our own display tokens.
    ///
    /// Providers normalize text — fish strips punctuation and apostrophes
    /// ("can't" → "cant") — and `WordTiming.text` is what the face displays, so
    /// text always comes from `displayTokens` and only timings come from
    /// `timings`. The result is always exactly one timing per token, which is
    /// what lets a batched response be split back at sentence boundaries.
    /// Returns [] when there is no usable timeline; callers treat that as a
    /// malformed response and fall back to display-only pacing.
    public static func reconcile(_ timings: [WordTiming],
                                 displayTokens: [String]) -> [WordTiming] {
        guard !displayTokens.isEmpty else { return [] }
        if timings.count == displayTokens.count {
            return zip(displayTokens, timings).map {
                WordTiming(text: $0.0, start: $0.1.start, end: $0.1.end)
            }
        }
        guard let first = timings.first, let last = timings.last,
              last.end > first.start else { return [] }
        NSLog("speech: alignment mismatch — %d segments vs %d tokens; distributing proportionally",
              timings.count, displayTokens.count)
        // Proportional rather than index-aligning the first N: one dropped
        // segment makes index alignment progressively wrong for the rest of the
        // sentence, whereas proportional is uniformly slightly off.
        let span = last.end - first.start
        let weights = displayTokens.map { Double(max(1, $0.count)) }
        let total = weights.reduce(0, +)
        var out: [WordTiming] = []
        out.reserveCapacity(displayTokens.count)
        var t = first.start
        for (token, w) in zip(displayTokens, weights) {
            let d = span * (w / total)
            out.append(WordTiming(text: token, start: t, end: t + d))
            t += d
        }
        return out
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the same `-only-testing:CoreTests/AlignmentReconcileTests` command.
Expected: PASS, 6 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/AlignmentMapper.swift Tests/AlignmentReconcileTests.swift
git commit -m "feat(speech): reconcile provider word timings onto our display tokens"
```

---

## Task 2: Split a batched SpokenAudio into per-sentence pieces

A batch is one generation covering several sentences — that is what buys continuity. Playback and `Director`'s queue are per sentence, so the batch has to come apart again.

**Files:**
- Create: `Sources/Speech/SpokenAudioSplitter.swift`
- Test: `Tests/SpokenAudioSplitterTests.swift` (create)

**Interfaces:**
- Consumes: `SpokenAudio` from `Sources/Speech/SpeechSynthesizing.swift` — `SpokenAudio(requestID: String?, words: [WordTiming], pcm: Data, sampleRate: Double, envelope: [Float] = [], envelopeRate: Double = 60)`; `AlignmentMapper.reconcile` from Task 1 guarantees `words.count` equals the total token count
- Produces: `SpokenAudioSplitter.split(_ audio: SpokenAudio, tokenCounts: [Int]) -> [SpokenAudio]` — returns `tokenCounts.count` pieces in order; returns `[audio]` unchanged if the counts do not add up

- [ ] **Step 1: Write the failing tests**

Create `Tests/SpokenAudioSplitterTests.swift`:

```swift
import XCTest

final class SpokenAudioSplitterTests: XCTestCase {
    /// 24 kHz, 1 second of silence = 24000 frames = 48000 bytes.
    private func batch() -> SpokenAudio {
        let words = [WordTiming(text: "One.", start: 0.0, end: 0.4),
                     WordTiming(text: "Two", start: 0.5, end: 0.7),
                     WordTiming(text: "three.", start: 0.7, end: 1.0)]
        let pcm = Data(count: 48_000)
        return SpokenAudio(requestID: "rid", words: words, pcm: pcm, sampleRate: 24_000,
                           envelope: [Float](repeating: 0.5, count: 60), envelopeRate: 60)
    }

    func testSingleSentenceIsIdentity() {
        let a = batch()
        let out = SpokenAudioSplitter.split(a, tokenCounts: [3])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].words, a.words)
        XCTAssertEqual(out[0].pcm, a.pcm)
    }

    func testMismatchedTokenCountsReturnsInputUnchanged() {
        let a = batch()
        let out = SpokenAudioSplitter.split(a, tokenCounts: [1, 1])   // 2 != 3 words
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].words, a.words)
    }

    func testSplitsWordsAtTokenBoundaries() {
        let out = SpokenAudioSplitter.split(batch(), tokenCounts: [1, 2])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].words.map(\.text), ["One."])
        XCTAssertEqual(out[1].words.map(\.text), ["Two", "three."])
    }

    func testRebasesEachPieceToZero() {
        let out = SpokenAudioSplitter.split(batch(), tokenCounts: [1, 2])
        XCTAssertEqual(out[1].words[0].start, 0.0, accuracy: 0.0001)
        XCTAssertEqual(out[1].words[0].end, 0.2, accuracy: 0.0001)
        XCTAssertEqual(out[1].words[1].start, 0.2, accuracy: 0.0001)
        XCTAssertEqual(out[1].words[1].end, 0.5, accuracy: 0.0001)
    }

    func testPCMIsCutAtTheNextSentenceStartAndIsLossless() {
        let a = batch()
        let out = SpokenAudioSplitter.split(a, tokenCounts: [1, 2])
        // "Two" starts at 0.5s → frame 12000 → byte 24000.
        XCTAssertEqual(out[0].pcm.count, 24_000)
        XCTAssertEqual(out[1].pcm.count, 24_000)
        XCTAssertEqual(out[0].pcm.count + out[1].pcm.count, a.pcm.count)
    }

    func testEnvelopeIsSlicedProportionally() {
        let out = SpokenAudioSplitter.split(batch(), tokenCounts: [1, 2])
        XCTAssertEqual(out[0].envelope.count, 30)   // 0.5s at 60 Hz
        XCTAssertEqual(out[1].envelope.count, 30)
        XCTAssertEqual(out[0].envelopeRate, 60)
    }

    func testRequestIDLandsOnFirstPieceOnly() {
        let out = SpokenAudioSplitter.split(batch(), tokenCounts: [1, 2])
        XCTAssertEqual(out[0].requestID, "rid")
        XCTAssertNil(out[1].requestID)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project ZielVanSebastian.xcodeproj -scheme ZielVanSebastian -configuration Debug -derivedDataPath build -destination 'platform=macOS' -only-testing:CoreTests/SpokenAudioSplitterTests test 2>&1 | tail -20`

Expected: compile failure — cannot find `SpokenAudioSplitter`.

- [ ] **Step 3: Implement**

Create `Sources/Speech/SpokenAudioSplitter.swift`:

```swift
import Foundation

/// Splits one batch-synthesized clip into per-sentence pieces.
///
/// Batching several sentences into one request is what buys prosody continuity —
/// a single generation instead of independent takes. Playback and the Director's
/// speech queue are per sentence, so the batch is cut apart again here: word
/// lists at the sentence token counts, PCM at the sample offset of the next
/// sentence's first word, and each piece's times rebased to zero because
/// `Director.speechStarted` stamps `startedAt` when that piece begins playing.
public enum SpokenAudioSplitter {
    public static func split(_ audio: SpokenAudio, tokenCounts: [Int]) -> [SpokenAudio] {
        // Defensive: only split when the token counts exactly account for the
        // word list (AlignmentMapper.reconcile guarantees this). Mis-pairing
        // audio with the wrong sentence would be worse than not splitting.
        guard tokenCounts.count > 1,
              tokenCounts.allSatisfy({ $0 > 0 }),
              tokenCounts.reduce(0, +) == audio.words.count else { return [audio] }

        let frames = audio.pcm.count / 2
        var out: [SpokenAudio] = []
        out.reserveCapacity(tokenCounts.count)
        var wordIndex = 0
        var startFrame = 0

        for (i, count) in tokenCounts.enumerated() {
            let words = Array(audio.words[wordIndex..<(wordIndex + count)])
            wordIndex += count
            let isLast = i == tokenCounts.count - 1
            let endFrame: Int
            if isLast || wordIndex >= audio.words.count {
                endFrame = frames
            } else {
                let boundary = Int(audio.words[wordIndex].start * audio.sampleRate)
                endFrame = min(frames, max(startFrame, boundary))
            }
            let base = words.first?.start ?? 0
            let rebased = words.map {
                WordTiming(text: $0.text, start: $0.start - base, end: $0.end - base)
            }
            out.append(SpokenAudio(
                requestID: i == 0 ? audio.requestID : nil,
                words: rebased,
                pcm: audio.pcm.subdata(in: (startFrame * 2)..<(endFrame * 2)),
                sampleRate: audio.sampleRate,
                envelope: sliceEnvelope(audio.envelope, rate: audio.envelopeRate,
                                        fromFrame: startFrame, toFrame: endFrame,
                                        sampleRate: audio.sampleRate),
                envelopeRate: audio.envelopeRate))
            startFrame = endFrame
        }
        return out
    }

    private static func sliceEnvelope(_ env: [Float], rate: Double,
                                      fromFrame: Int, toFrame: Int,
                                      sampleRate: Double) -> [Float] {
        guard !env.isEmpty, sampleRate > 0, rate > 0 else { return [] }
        let lo = min(env.count, max(0, Int(Double(fromFrame) / sampleRate * rate)))
        let hi = min(env.count, max(lo, Int(Double(toFrame) / sampleRate * rate)))
        return Array(env[lo..<hi])
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the same `-only-testing:CoreTests/SpokenAudioSplitterTests` command.
Expected: PASS, 7 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/Speech/SpokenAudioSplitter.swift Tests/SpokenAudioSplitterTests.swift
git commit -m "feat(speech): split batched audio back into per-sentence clips"
```

---

## Task 3: Extract playback, introduce the batch-shaped fetch seam

This is a refactor plus one signature change. The gate is the existing suite: playback behavior must be identical, so the AVAudioEngine code moves **verbatim**.

**Files:**
- Create: `Sources/Speech/AudioPlayback.swift`
- Create: `Sources/Speech/TTSFetching.swift`
- Create: `Sources/Speech/TTSService.swift`
- Rename: `Sources/Speech/ElevenLabsTTS.swift` → `Sources/Speech/ElevenLabsFetcher.swift` (use `git mv`)
- Modify: `Sources/Speech/SpeechSynthesizing.swift:26-33` (the protocol's `fetch`)
- Modify: `App/AppDelegate.swift:21` and `:51-53`
- Modify: `Tests/ElevenLabsTTSTests.swift` (type name; `parseResponse` gains `batch:`)
- Modify: `Tests/SpeechCoordinatorTests.swift:3-19` (`FakeSynth` signature) and the `.success(...)` call sites

**Interfaces:**
- Consumes: `AlignmentMapper.tokens`/`reconcile` (Task 1), `SpokenAudioSplitter.split` (Task 2), existing `AudioOutputDevice.find(named:)` and `AudioOutputDevice.systemDefaultOutput()`
- Produces:
  - `protocol TTSFetching: AnyObject { func fetch(_ batch: [SpeechRequest], previousRequestIDs: [String], completion: @escaping (Result<[SpokenAudio], Error>) -> Void) }`
  - `enum TTSError: Error { case httpStatus(Int); case malformedResponse }` (top-level, was nested in `ElevenLabsTTS`)
  - `final class AudioPlayback` with `var outputDeviceName: String`, `play(_:volume:onStarted:onFinished:)`, `stopPlayback()`
  - `final class TTSService: SpeechSynthesizing` with `init(fetcher: TTSFetching, player: AudioPlayback = AudioPlayback())` and `var outputDeviceName: String`
  - `final class ElevenLabsFetcher: TTSFetching` with `init(config: SpeechConfig, session: URLSession = .shared)`, `static func makeRequest(text:previousRequestIDs:config:) -> URLRequest`, `static func parseResponse(_ data: Data, requestID: String?, batch: [SpeechRequest]) throws -> [SpokenAudio]`

- [ ] **Step 1: Move the protocol to a batch-shaped fetch**

In `Sources/Speech/SpeechSynthesizing.swift`, replace the `fetch` requirement (lines 27-28):

```swift
public protocol SpeechSynthesizing: AnyObject {
    /// Synthesizes one or more sentences as a single generation. Returns exactly
    /// one clip per request, in order — batching is invisible to the Director.
    func fetch(_ batch: [SpeechRequest], previousRequestIDs: [String],
               completion: @escaping (Result<[SpokenAudio], Error>) -> Void)
    /// Only one playback at a time; `onFinished` fires when audio is done.
    func play(_ audio: SpokenAudio, volume: Double,
              onStarted: @escaping () -> Void, onFinished: @escaping () -> Void)
    func stopPlayback()
}
```

- [ ] **Step 2: Create the fetch seam**

Create `Sources/Speech/TTSFetching.swift`:

```swift
import Foundation

public enum TTSError: Error {
    case httpStatus(Int)
    case malformedResponse
}

/// The provider-specific half of speech: text in, timed audio out. Playback is
/// deliberately not here — it is shared across providers (see AudioPlayback).
/// Contract: `completion` must be invoked on the main thread.
public protocol TTSFetching: AnyObject {
    func fetch(_ batch: [SpeechRequest], previousRequestIDs: [String],
               completion: @escaping (Result<[SpokenAudio], Error>) -> Void)
}
```

- [ ] **Step 3: Move playback out verbatim**

Create `Sources/Speech/AudioPlayback.swift`. Move, without editing the bodies: the `sampleRate`-independent parts of `ElevenLabsTTS` — the `engine`, `player`, `engineReady`, `configObserver`, `appliedDeviceID`, and `outputDeviceName` properties with their comments (current lines 12-26), the `init` observer block (27-52, minus the `config`/`session` assignments), `deinit` (54-56), `play` (133-214), and `stopPlayback` (216-220).

```swift
import AVFoundation
import CoreAudio
import Foundation

/// Provider-agnostic playback: schedules 16-bit LE mono PCM on an AVAudioEngine
/// graph and pins output to a named device when asked. Shared by every TTS
/// provider — this is the fragile part of the speech stack (a lost playback
/// completion once grew the backlog until the process was OOM-killed), so it
/// exists exactly once.
public final class AudioPlayback {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var engineReady = false
    private var configObserver: NSObjectProtocol?
    /// Device actually applied via AudioUnitSetProperty; nil means "not yet
    /// applied" (default device, or a pin still pending discovery). Guards
    /// against re-invoking AudioUnitSetProperty on every play() call. Reset
    /// whenever the graph is rebuilt so a real hardware/device change re-applies.
    private var appliedDeviceID: AudioDeviceID?

    /// Non-empty pins TTS output to a named device (e.g. the PowerConf) so mic
    /// and speaker share one unit for hardware AEC. Set live from voice.outputDevice.
    public var outputDeviceName: String = ""

    public init() {
        // (paste the existing NotificationCenter observer block verbatim from
        // ElevenLabsTTS.init, lines 31-51 — comments included)
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    // (paste play(_:volume:onStarted:onFinished:) and stopPlayback() verbatim)
}
```

Then delete those members from the renamed fetcher.

- [ ] **Step 4: Create the composer**

Create `Sources/Speech/TTSService.swift`:

```swift
import Foundation

/// The `SpeechSynthesizing` the coordinator talks to: one provider fetcher plus
/// the shared player. Swapping providers swaps only the fetcher.
public final class TTSService: SpeechSynthesizing {
    private let fetcher: TTSFetching
    private let player: AudioPlayback

    /// Forwarded so AppDelegate's live config reload keeps working unchanged.
    public var outputDeviceName: String {
        get { player.outputDeviceName }
        set { player.outputDeviceName = newValue }
    }

    public init(fetcher: TTSFetching, player: AudioPlayback = AudioPlayback()) {
        self.fetcher = fetcher
        self.player = player
    }

    public func fetch(_ batch: [SpeechRequest], previousRequestIDs: [String],
                      completion: @escaping (Result<[SpokenAudio], Error>) -> Void) {
        fetcher.fetch(batch, previousRequestIDs: previousRequestIDs, completion: completion)
    }

    public func play(_ audio: SpokenAudio, volume: Double,
                     onStarted: @escaping () -> Void, onFinished: @escaping () -> Void) {
        player.play(audio, volume: volume, onStarted: onStarted, onFinished: onFinished)
    }

    public func stopPlayback() { player.stopPlayback() }
}
```

- [ ] **Step 5: Rename and reshape the ElevenLabs fetcher**

```bash
git mv Sources/Speech/ElevenLabsTTS.swift Sources/Speech/ElevenLabsFetcher.swift
```

In the renamed file: change the declaration to `public final class ElevenLabsFetcher: TTSFetching`, drop the nested `enum TTSError` (now top-level in `TTSFetching.swift`), keep `sampleRate`, `config`, `session`, and `ResponseBody`, keep `makeRequest` unchanged, and replace `parseResponse` and `fetch` with:

```swift
    static func parseResponse(_ data: Data, requestID: String?,
                              batch: [SpeechRequest]) throws -> [SpokenAudio] {
        guard let body = try? JSONDecoder().decode(ResponseBody.self, from: data),
              let pcm = Data(base64Encoded: body.audioBase64), !pcm.isEmpty,
              let alignment = body.alignment
        else { throw TTSError.malformedResponse }
        let tokenLists = batch.map { AlignmentMapper.tokens($0.text) }
        // Route through reconcile even though ElevenLabs' characters come from
        // our own text: it makes the word list exactly one entry per token,
        // which is what SpokenAudioSplitter needs to cut a batch apart.
        let words = AlignmentMapper.reconcile(AlignmentMapper.words(from: alignment),
                                              displayTokens: tokenLists.flatMap { $0 })
        guard !words.isEmpty else { throw TTSError.malformedResponse }
        let envelope = AmplitudeEnvelope.from(pcm: pcm, sampleRate: sampleRate, rate: 60)
        let whole = SpokenAudio(requestID: requestID, words: words, pcm: pcm,
                                sampleRate: sampleRate, envelope: envelope, envelopeRate: 60)
        return SpokenAudioSplitter.split(whole, tokenCounts: tokenLists.map(\.count))
    }

    public func fetch(_ batch: [SpeechRequest], previousRequestIDs: [String],
                      completion: @escaping (Result<[SpokenAudio], Error>) -> Void) {
        func finish(_ r: Result<[SpokenAudio], Error>) {
            DispatchQueue.main.async { completion(r) }
        }
        guard !batch.isEmpty else {
            finish(.failure(TTSError.malformedResponse))
            return
        }
        // One request covering several sentences is one generation, so prosody
        // carries across them — real continuity, unlike previous_request_ids.
        let text = batch.map(\.text).joined(separator: " ")
        let urlReq = Self.makeRequest(text: text, previousRequestIDs: previousRequestIDs,
                                      config: config)
        let task = session.dataTask(with: urlReq) { data, response, error in
            if let error {
                finish(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                finish(.failure(TTSError.malformedResponse))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                NSLog("speech: TTS request failed with HTTP %d", http.statusCode)
                finish(.failure(TTSError.httpStatus(http.statusCode)))
                return
            }
            do {
                let requestID = http.value(forHTTPHeaderField: "request-id")
                finish(.success(try Self.parseResponse(data ?? Data(), requestID: requestID,
                                                       batch: batch)))
            } catch {
                finish(.failure(error))
            }
        }
        task.resume()
    }
```

- [ ] **Step 6: Update the app wiring**

In `App/AppDelegate.swift`, change line 21 to `private var tts: TTSService?` and lines 51-53 to:

```swift
            let tts = TTSService(fetcher: ElevenLabsFetcher(config: config.speech))
            tts.outputDeviceName = config.voice.outputDevice
            self.tts = tts
```

Line 275 (`self?.tts?.outputDeviceName = fresh.voice.outputDevice`) needs no change.

- [ ] **Step 7: Update the existing tests**

In `Tests/ElevenLabsTTSTests.swift`: replace `ElevenLabsTTS` with `ElevenLabsFetcher` (3 call sites), and update the two `parseResponse` tests:

```swift
    func testParseResponseExtractsWordsAndPCM() throws {
        let pcm = Data([0x01, 0x00, 0x02, 0x00])
        let json = """
        {"audio_base64": "\(pcm.base64EncodedString())",
         "alignment": {"characters": ["H", "i"],
                       "character_start_times_seconds": [0.0, 0.1],
                       "character_end_times_seconds": [0.1, 0.2]}}
        """
        let clips = try ElevenLabsFetcher.parseResponse(
            Data(json.utf8), requestID: "rid", batch: [SpeechRequest(id: 1, text: "Hi")])
        XCTAssertEqual(clips.count, 1)
        let audio = clips[0]
        XCTAssertFalse(audio.envelope.isEmpty)
        XCTAssertEqual(audio.envelopeRate, 60)
        XCTAssertEqual(audio.requestID, "rid")
        XCTAssertEqual(audio.pcm, pcm)
        XCTAssertEqual(audio.words, [WordTiming(text: "Hi", start: 0.0, end: 0.2)])
        XCTAssertEqual(audio.sampleRate, 24_000)
    }

    func testParseResponseRejectsMissingAlignment() {
        let json = #"{"audio_base64": "AAA="}"#
        XCTAssertThrowsError(try ElevenLabsFetcher.parseResponse(
            Data(json.utf8), requestID: nil, batch: [SpeechRequest(id: 1, text: "Hi")]))
    }
```

In `Tests/SpeechCoordinatorTests.swift`, update `FakeSynth` (lines 3-19):

```swift
    private final class FakeSynth: SpeechSynthesizing {
        var fetches: [(batch: [SpeechRequest], prev: [String],
                       completion: (Result<[SpokenAudio], Error>) -> Void)] = []
        var played: [SpokenAudio] = []
        var playCallbacks: [(onStarted: () -> Void, onFinished: () -> Void)] = []
        var stopped = 0

        func fetch(_ batch: [SpeechRequest], previousRequestIDs: [String],
                   completion: @escaping (Result<[SpokenAudio], Error>) -> Void) {
            fetches.append((batch, previousRequestIDs, completion))
        }
        func play(_ audio: SpokenAudio, volume: Double,
                  onStarted: @escaping () -> Void, onFinished: @escaping () -> Void) {
            played.append(audio)
            playCallbacks.append((onStarted, onFinished))
        }
        func stopPlayback() { stopped += 1 }
    }
```

Then wrap every existing `.success(audio(...))` in the file as `.success([audio(...)])`. Leave the assertions alone — with batching the fetch *counts* in these tests are unchanged (see Task 4).

- [ ] **Step 8: Rename the test file to match**

```bash
git mv Tests/ElevenLabsTTSTests.swift Tests/ElevenLabsFetcherTests.swift
```

Also rename the class inside to `ElevenLabsFetcherTests`.

- [ ] **Step 9: Verify the playback move was verbatim**

The audio code must be *moved*, not rewritten — it is the part of the stack that
already caused one OOM crash, and no test covers the AVAudioEngine glue. Check
that `play`, `stopPlayback`, and the observer block are byte-identical to their
previous versions apart from indentation:

```bash
git show HEAD:Sources/Speech/ElevenLabsTTS.swift \
  | sed -n '/public func play/,/^    }$/p' > /tmp/play-before.swift
sed -n '/public func play/,/^    }$/p' Sources/Speech/AudioPlayback.swift > /tmp/play-after.swift
diff /tmp/play-before.swift /tmp/play-after.swift && echo "VERBATIM"
```

Expected: `VERBATIM`. Any diff other than whitespace means logic changed during
the move — revert that hunk and move it again.

- [ ] **Step 10: Run the full suite**

Run: `make test`
Expected: PASS. Same test count as before plus Tasks 1-2's new tests. Any playback behavior change here is a bug in the extraction — the bodies were supposed to move verbatim.

- [ ] **Step 11: Commit**

```bash
git add -A Sources/Speech App/AppDelegate.swift Tests
git commit -m "refactor(speech): split playback from provider fetch, batch-shaped seam"
```

---

## Task 4: Coalesce queued sentences in the coordinator

**Files:**
- Modify: `Sources/Speech/SpeechCoordinator.swift` — add `maxBatchSentences`, rewrite `startFetchesWithinCap` (89-110) and `fetchCompleted` (112-133), add `failBatch`
- Test: `Tests/SpeechCoordinatorBatchingTests.swift` (create)

**Interfaces:**
- Consumes: the batch-shaped `SpeechSynthesizing.fetch` from Task 3
- Produces: no new public API — behavior change only

- [ ] **Step 1: Write the failing tests**

Create `Tests/SpeechCoordinatorBatchingTests.swift`:

```swift
import XCTest

final class SpeechCoordinatorBatchingTests: XCTestCase {
    private final class FakeSynth: SpeechSynthesizing {
        var fetches: [(batch: [SpeechRequest], prev: [String],
                       completion: (Result<[SpokenAudio], Error>) -> Void)] = []
        var played: [SpokenAudio] = []
        var playCallbacks: [(onStarted: () -> Void, onFinished: () -> Void)] = []
        var stopped = 0

        func fetch(_ batch: [SpeechRequest], previousRequestIDs: [String],
                   completion: @escaping (Result<[SpokenAudio], Error>) -> Void) {
            fetches.append((batch, previousRequestIDs, completion))
        }
        func play(_ audio: SpokenAudio, volume: Double,
                  onStarted: @escaping () -> Void, onFinished: @escaping () -> Void) {
            played.append(audio)
            playCallbacks.append((onStarted, onFinished))
        }
        func stopPlayback() { stopped += 1 }
    }

    private func makeDirector() -> Director {
        var cfg = ZielConfig()
        cfg.speech.enabled = true
        var look = LookConfig()
        look.theme = "classic"
        return Director(config: cfg, look: try! ResolvedLook.resolve(look))
    }

    private func clip(_ text: String, rid: String? = nil) -> SpokenAudio {
        SpokenAudio(requestID: rid,
                    words: [WordTiming(text: text, start: 0, end: 0.4)],
                    pcm: Data(count: 4), sampleRate: 24_000)
    }

    /// Six sentences arrive at once. The first must go alone so
    /// time-to-first-audio does not regress; the rest coalesce up to the cap.
    func testFirstSentenceGoesAloneThenBatchesUpToCap() {
        let d = makeDirector()
        let synth = FakeSynth()
        let co = SpeechCoordinator(director: d, synth: synth, volume: 1, now: { 5 })
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r", session: "m",
                            text: "One. Two. Three. Four. Five. Six. "), now: 0.1)
        co.pump()
        XCTAssertEqual(synth.fetches.count, 2)          // concurrency cap is 2
        XCTAssertEqual(synth.fetches[0].batch.count, 1)
        XCTAssertEqual(synth.fetches[0].batch[0].text, "One.")
        XCTAssertEqual(synth.fetches[1].batch.count, 4) // maxBatchSentences
        XCTAssertEqual(synth.fetches[1].batch.map(\.text), ["Two.", "Three.", "Four.", "Five."])
    }

    func testBatchClipsArePairedToTheirRequestsInOrder() {
        let d = makeDirector()
        let synth = FakeSynth()
        let co = SpeechCoordinator(director: d, synth: synth, volume: 1, now: { 5 })
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r", session: "m", text: "One. Two. Three. "), now: 0.1)
        co.pump()
        synth.fetches[0].completion(.success([clip("One.")]))
        XCTAssertEqual(synth.played.count, 1)
        synth.playCallbacks[0].onFinished()
        synth.fetches[1].completion(.success([clip("Two."), clip("Three.")]))
        XCTAssertEqual(synth.played.count, 2)
        XCTAssertEqual(synth.played[1].words.first?.text, "Two.")
        synth.playCallbacks[1].onFinished()
        XCTAssertEqual(synth.played.count, 3)
        XCTAssertEqual(synth.played[2].words.first?.text, "Three.")
    }

    func testFailedBatchFailsEveryIdItCovered() {
        let d = makeDirector()
        let synth = FakeSynth()
        let co = SpeechCoordinator(director: d, synth: synth, volume: 1, now: { 5 })
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r", session: "m", text: "One. Two. Three. "), now: 0.1)
        co.pump()
        synth.fetches[1].completion(.failure(NSError(domain: "t", code: 1)))
        synth.fetches[0].completion(.success([clip("One.")]))
        XCTAssertEqual(synth.played.count, 1)
        synth.playCallbacks[0].onFinished()
        // Both batched sentences fell back to display-only pacing, so nothing
        // further is played.
        XCTAssertEqual(synth.played.count, 1)
    }

    /// A wrong clip count would mis-pair audio with sentences, so it is a failure.
    func testMismatchedClipCountIsTreatedAsFailure() {
        let d = makeDirector()
        let synth = FakeSynth()
        let co = SpeechCoordinator(director: d, synth: synth, volume: 1, now: { 5 })
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r", session: "m", text: "One. Two. Three. "), now: 0.1)
        co.pump()
        synth.fetches[1].completion(.success([clip("Two.")]))   // 1 clip for 2 requests
        synth.fetches[0].completion(.success([clip("One.")]))
        XCTAssertEqual(synth.played.count, 1)
        synth.playCallbacks[0].onFinished()
        XCTAssertEqual(synth.played.count, 1)
    }

    /// Three consecutive failed *batches* open the circuit — a batch is one call.
    func testThreeFailedBatchesOpenTheCircuit() {
        let d = makeDirector()
        let synth = FakeSynth()
        let co = SpeechCoordinator(director: d, synth: synth, volume: 1, now: { 5 })
        d.handle(.connectionUp, now: 0)
        for (i, t) in ["Alpha. ", "Bravo. ", "Charlie. "].enumerated() {
            d.handle(.textDelta(run: "r", session: "m", text: t), now: 0.1 + Double(i) * 0.1)
            co.pump()
            synth.fetches[i].completion(.failure(NSError(domain: "t", code: 1)))
        }
        let before = synth.fetches.count
        d.handle(.textDelta(run: "r", session: "m", text: "Delta. "), now: 1.0)
        co.pump()
        XCTAssertEqual(synth.fetches.count, before)   // circuit open: no new fetches
    }

    func testRequestIDFromBatchStitchesForwardOnce() {
        let d = makeDirector()
        let synth = FakeSynth()
        let co = SpeechCoordinator(director: d, synth: synth, volume: 1, now: { 5 })
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r", session: "m", text: "Hello. "), now: 0.1)
        co.pump()
        synth.fetches[0].completion(.success([clip("Hello.", rid: "x1")]))
        d.handle(.textDelta(run: "r", session: "m", text: "World. "), now: 0.2)
        co.pump()
        XCTAssertEqual(synth.fetches[1].prev, ["x1"])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild -project ZielVanSebastian.xcodeproj -scheme ZielVanSebastian -configuration Debug -derivedDataPath build -destination 'platform=macOS' -only-testing:CoreTests/SpeechCoordinatorBatchingTests test 2>&1 | tail -20`

Expected: FAIL — `testFirstSentenceGoesAloneThenBatchesUpToCap` sees `fetches[1].batch.count == 1`, because the coordinator still fetches one sentence per request.

- [ ] **Step 3: Implement batching**

In `Sources/Speech/SpeechCoordinator.swift`, add below `maxConcurrentFetches` (line 10):

```swift
    /// Sentences coalesced into one request. Batching is what buys prosody
    /// continuity — one request is one generation — but a bigger batch takes
    /// longer to synthesize, and if a batch outlasts the audio playing ahead of
    /// it, playback gaps mid-reply. Four is the starting bound on that.
    private static let maxBatchSentences = 4
```

Replace the `while` loop in `startFetchesWithinCap` (lines 100-109) with:

```swift
        while inFlightFetches < Self.maxConcurrentFetches, !fetchQueue.isEmpty {
            // The first audio of a reply goes alone: time-to-first-audio must
            // not regress, and the whole round trip already feels slow. Once
            // something is playing or fetched, coalesce — one request covering
            // several sentences is one generation, which is real continuity
            // rather than best-effort previous_request_ids stitching.
            let solo = playing == nil && ready.isEmpty && inFlightFetches == 0
            let take = solo ? 1 : min(Self.maxBatchSentences, fetchQueue.count)
            let batch = Array(fetchQueue.prefix(take))
            fetchQueue.removeFirst(take)
            inFlightFetches += 1
            let gen = generation
            let ids = batch.map(\.id)
            synth.fetch(batch, previousRequestIDs: previousRequestIDs) { [weak self] result in
                self?.fetchCompleted(ids: ids, generation: gen, result: result)
            }
        }
```

Replace `fetchCompleted` (lines 112-133) with:

```swift
    private func fetchCompleted(ids: [Int], generation gen: Int,
                                result: Result<[SpokenAudio], Error>) {
        guard gen == generation else { return }
        inFlightFetches -= 1
        switch result {
        case .success(let clips) where clips.count == ids.count:
            consecutiveFailures = 0
            for (id, audio) in zip(ids, clips) {
                ready[id] = audio
                if let rid = audio.requestID {
                    previousRequestIDs = Array((previousRequestIDs + [rid]).suffix(3))
                }
            }
        case .success(let clips):
            // Pairing the wrong clip to a sentence would make the face say one
            // thing and the voice another, so treat it as a failed batch.
            NSLog("speech: batch returned %d clips for %d sentences — failing the batch",
                  clips.count, ids.count)
            failBatch(ids)
        case .failure:
            failBatch(ids)
        }
        startFetchesWithinCap()
        playNextIfReady()
    }

    /// One batch is one API call, so it counts once against the circuit breaker
    /// even though it strands several sentences.
    private func failBatch(_ ids: [Int]) {
        consecutiveFailures += 1
        if consecutiveFailures >= 3 && !circuitOpen {
            circuitOpen = true
            NSLog("speech: %d consecutive TTS failures — display-only until reconnect",
                  consecutiveFailures)
        }
        for id in ids {
            awaitingPlay.removeAll { $0 == id }
            director.speechFailed(id: id, now: now())
        }
    }
```

- [ ] **Step 4: Run the new tests, then the full suite**

Run the `-only-testing:CoreTests/SpeechCoordinatorBatchingTests` command.
Expected: PASS, 6 tests.

Then `make test`.
Expected: PASS. The three pre-existing coordinator tests still hold — with two sentences queued, the solo-then-batch rule still produces two fetches.

- [ ] **Step 5: Listening check against today's drift**

Run: `make run`

This is the Phase 1 gate. Speak several multi-sentence replies through the demo loop and compare against the pre-batching build (`git stash` or a checkout of the previous commit). Listen for:
- less pitch/energy jump at sentence boundaries than before
- **no new mid-reply gaps** — if a batch fetch outlasts the audio ahead of it, lower `maxBatchSentences` to 2 and retest

Record what you heard in the commit message. If batching does not audibly help, stop and report before starting Phase 2 — the fish work assumes this improvement holds.

- [ ] **Step 6: Commit**

```bash
git add Sources/Speech/SpeechCoordinator.swift Tests/SpeechCoordinatorBatchingTests.swift
git commit -m "feat(speech): coalesce queued sentences into one generation"
```

---

# Phase 2 — The fish.audio provider

## Task 5: Reshape SpeechConfig into per-provider blocks

Default stays `elevenlabs` here so nothing changes behaviorally; Task 8 flips it.

**Files:**
- Modify: `Sources/Core/Config.swift:141-161` (replace `SpeechConfig`, add two nested config structs and the provider enum)
- Modify: `Sources/Speech/ElevenLabsFetcher.swift` (`makeRequest` reads `config.elevenlabs.*`)
- Modify: `Tests/ElevenLabsFetcherTests.swift` (config setup)
- Modify: `Tests/ConfigTests.swift` (the two speech tests at lines 57 and 68)
- Modify: `config.example.json`

**Interfaces:**
- Produces:
  - `enum SpeechProvider: String, Codable { case elevenlabs, fish }`
  - `struct ElevenLabsSpeechConfig: Codable, Equatable` — `apiKey`, `voiceId`, `modelId`, `languageCode: String?`
  - `struct FishSpeechConfig: Codable, Equatable` — `apiKey`, `referenceId`, `model`, `latency`, `temperature`
  - `SpeechConfig` — `enabled`, `provider`, `speed`, `volume`, `elevenlabs`, `fish`

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ConfigTests.swift`:

```swift
    func testSpeechConfigDecodesNestedProviderBlocks() throws {
        let json = """
        {"speech": {"enabled": true, "provider": "fish", "speed": 1.1, "volume": 0.8,
                    "elevenlabs": {"apiKey": "el-key", "voiceId": "v1"},
                    "fish": {"apiKey": "fish-key", "referenceId": "ref1",
                             "model": "s2.1-pro-free", "latency": "low",
                             "temperature": 0.4}}}
        """
        let cfg = try JSONDecoder().decode(ZielConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.speech.provider, .fish)
        XCTAssertEqual(cfg.speech.speed, 1.1)
        XCTAssertEqual(cfg.speech.volume, 0.8)
        XCTAssertEqual(cfg.speech.elevenlabs.apiKey, "el-key")
        XCTAssertEqual(cfg.speech.elevenlabs.voiceId, "v1")
        XCTAssertEqual(cfg.speech.elevenlabs.modelId, "eleven_flash_v2_5")  // default kept
        XCTAssertEqual(cfg.speech.fish.apiKey, "fish-key")
        XCTAssertEqual(cfg.speech.fish.referenceId, "ref1")
        XCTAssertEqual(cfg.speech.fish.model, "s2.1-pro-free")
        XCTAssertEqual(cfg.speech.fish.latency, "low")
        XCTAssertEqual(cfg.speech.fish.temperature, 0.4)
    }

    /// A typo in `provider` must not fail the whole config load — that would
    /// take the gateway token down with it.
    func testUnknownProviderFallsBackToDefault() throws {
        let json = #"{"speech": {"provider": "elevenlabz"}}"#
        let cfg = try JSONDecoder().decode(ZielConfig.self, from: Data(json.utf8))
        XCTAssertEqual(cfg.speech.provider, SpeechConfig().provider)
    }

```

Then replace the body of the existing `testSpeechConfigDefaults` (`Tests/ConfigTests.swift:57`) entirely — do **not** add a second defaults test:

```swift
    func testSpeechConfigDefaults() throws {
        let cfg = SpeechConfig()
        XCTAssertFalse(cfg.enabled)
        XCTAssertEqual(cfg.provider, .elevenlabs)   // Task 8 flips this to .fish
        XCTAssertEqual(cfg.speed, 1.0)
        XCTAssertEqual(cfg.volume, 1.0)
        XCTAssertEqual(cfg.elevenlabs.apiKey, "")
        XCTAssertEqual(cfg.elevenlabs.voiceId, "JBFqnCBsd6RMkjVDRZzb")
        XCTAssertEqual(cfg.elevenlabs.modelId, "eleven_flash_v2_5")
        XCTAssertNil(cfg.elevenlabs.languageCode)
        XCTAssertEqual(cfg.fish.apiKey, "")
        XCTAssertEqual(cfg.fish.referenceId, "")
        XCTAssertEqual(cfg.fish.model, "s2.1-pro")
        XCTAssertEqual(cfg.fish.latency, "balanced")
        XCTAssertEqual(cfg.fish.temperature, 0.6)
    }
```

And in the existing decode test at `Tests/ConfigTests.swift:68`, move the flat reads under the nested block: `cfg.speech.apiKey` becomes `cfg.speech.elevenlabs.apiKey`, `cfg.speech.voiceId` becomes `cfg.speech.elevenlabs.voiceId`, `cfg.speech.modelId` becomes `cfg.speech.elevenlabs.modelId`, and the JSON fixture it decodes must nest those three keys under `"elevenlabs"`.

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project ZielVanSebastian.xcodeproj -scheme ZielVanSebastian -configuration Debug -derivedDataPath build -destination 'platform=macOS' -only-testing:CoreTests/ConfigTests test 2>&1 | tail -20`

Expected: compile failure — `SpeechConfig` has no member `provider`/`elevenlabs`/`fish`.

- [ ] **Step 3: Implement the config types**

Replace `SpeechConfig` in `Sources/Core/Config.swift` (lines 141-161) with:

```swift
public enum SpeechProvider: String, Codable {
    case elevenlabs
    case fish
}

public struct ElevenLabsSpeechConfig: Codable, Equatable {
    public var apiKey: String = ""
    public var voiceId: String = "JBFqnCBsd6RMkjVDRZzb"
    public var modelId: String = "eleven_flash_v2_5"
    public var languageCode: String? = nil

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? apiKey
        voiceId = try c.decodeIfPresent(String.self, forKey: .voiceId) ?? voiceId
        modelId = try c.decodeIfPresent(String.self, forKey: .modelId) ?? modelId
        languageCode = try c.decodeIfPresent(String.self, forKey: .languageCode)
    }
}

public struct FishSpeechConfig: Codable, Equatable {
    public var apiKey: String = ""
    public var referenceId: String = ""
    /// s1 | s2-pro | s2.1-pro | s2.1-pro-free. Sent as an HTTP header, not a
    /// body field. s2.1-pro-free is $0 but its requests may be used to improve
    /// fish's models, so the default is the paid model.
    public var model: String = "s2.1-pro"
    /// low | normal | balanced
    public var latency: String = "balanced"
    /// Below fish's 0.7 default to reduce take-to-take variance between batches.
    public var temperature: Double = 0.6

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? apiKey
        referenceId = try c.decodeIfPresent(String.self, forKey: .referenceId) ?? referenceId
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? model
        latency = try c.decodeIfPresent(String.self, forKey: .latency) ?? latency
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? temperature
    }
}

public struct SpeechConfig: Codable, Equatable {
    public var enabled: Bool = false
    public var provider: SpeechProvider = .elevenlabs
    public var speed: Double = 1.0
    public var volume: Double = 1.0
    public var elevenlabs = ElevenLabsSpeechConfig()
    public var fish = FishSpeechConfig()

    enum CodingKeys: String, CodingKey {
        case enabled, provider, speed, volume, elevenlabs, fish
        // Pre-provider flat keys. Kept only so a stale config produces an
        // explanatory log line instead of speech silently going quiet.
        case apiKey, voiceId, modelId
    }

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? speed
        volume = try c.decodeIfPresent(Double.self, forKey: .volume) ?? volume
        elevenlabs = try c.decodeIfPresent(ElevenLabsSpeechConfig.self,
                                          forKey: .elevenlabs) ?? elevenlabs
        fish = try c.decodeIfPresent(FishSpeechConfig.self, forKey: .fish) ?? fish
        // Decoded as a String on purpose: a strict enum would throw on a typo
        // and fail the entire config load, gateway token included.
        if let raw = try c.decodeIfPresent(String.self, forKey: .provider) {
            if let p = SpeechProvider(rawValue: raw) {
                provider = p
            } else {
                NSLog("speech.provider '%@' is not recognized — using '%@'",
                      raw, provider.rawValue)
            }
        }
        if c.contains(.apiKey) || c.contains(.voiceId) || c.contains(.modelId) {
            NSLog("speech.apiKey/voiceId/modelId are pre-provider keys and are ignored — move them under speech.elevenlabs (see config.example.json)")
        }
    }
}
```

- [ ] **Step 4: Point the ElevenLabs fetcher at the nested block**

In `Sources/Speech/ElevenLabsFetcher.swift`, inside `makeRequest`, replace the four `config.<x>` reads:

```swift
        var comps = URLComponents(string: "https://api.elevenlabs.io/v1/text-to-speech/\(config.elevenlabs.voiceId)/with-timestamps")!
        ...
        req.setValue(config.elevenlabs.apiKey, forHTTPHeaderField: "xi-api-key")
        ...
        var body: [String: Any] = [
            "text": text,
            "model_id": config.elevenlabs.modelId,
            "voice_settings": ["speed": config.speed],
        ]
        if let lang = config.elevenlabs.languageCode { body["language_code"] = lang }
```

In `Tests/ElevenLabsFetcherTests.swift`, update both setups:

```swift
        var cfg = SpeechConfig()
        cfg.elevenlabs.apiKey = "key"
        cfg.elevenlabs.voiceId = "voice123"
        cfg.elevenlabs.languageCode = "it"
        cfg.speed = 1.2
```

and

```swift
        var cfg = SpeechConfig()
        cfg.elevenlabs.apiKey = "key"
        cfg.elevenlabs.voiceId = "v"
```

- [ ] **Step 5: Update AppDelegate's reads**

In `App/AppDelegate.swift`, lines 47-53 currently read `config.speech.voiceId` / `config.speech.apiKey`. Change to `config.speech.elevenlabs.voiceId` / `config.speech.elevenlabs.apiKey`. Provider selection comes in Task 8.

- [ ] **Step 6: Update config.example.json**

Replace the `speech` block:

```json
  "speech": {
    "enabled": false,
    "provider": "elevenlabs",
    "speed": 1.0,
    "volume": 1.0,
    "elevenlabs": {
      "apiKey": "PUT-YOUR-ELEVENLABS-API-KEY-HERE",
      "voiceId": "JBFqnCBsd6RMkjVDRZzb",
      "modelId": "eleven_flash_v2_5"
    },
    "fish": {
      "apiKey": "PUT-YOUR-FISH-AUDIO-API-KEY-HERE",
      "referenceId": "PUT-A-FISH-VOICE-REFERENCE-ID-HERE",
      "model": "s2.1-pro",
      "latency": "balanced",
      "temperature": 0.6
    }
  },
```

- [ ] **Step 7: Run the full suite**

Run: `make test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/Core/Config.swift Sources/Speech/ElevenLabsFetcher.swift App/AppDelegate.swift Tests/ConfigTests.swift Tests/ElevenLabsFetcherTests.swift config.example.json
git commit -m "feat(config): per-provider speech config blocks"
```

---

## Task 6: Fish request building

**Files:**
- Create: `Sources/Speech/FishAudioFetcher.swift`
- Test: `Tests/FishAudioFetcherTests.swift` (create)

**Interfaces:**
- Produces: `final class FishAudioFetcher` with `init(config: SpeechConfig, session: URLSession = .shared)`, `static let sampleRate = 24_000.0`, and `static func makeRequest(text: String, config: SpeechConfig) -> URLRequest`. The class deliberately does **not** conform to `TTSFetching` yet — Task 7 adds the conformance along with the `fetch` that satisfies it, so this task ships no stub that always fails.

- [ ] **Step 1: Write the failing test**

Create `Tests/FishAudioFetcherTests.swift`:

```swift
import XCTest

final class FishAudioFetcherTests: XCTestCase {
    private func config(speed: Double = 1.0) -> SpeechConfig {
        var cfg = SpeechConfig()
        cfg.provider = .fish
        cfg.speed = speed
        cfg.fish.apiKey = "fk"
        cfg.fish.referenceId = "ref123"
        cfg.fish.model = "s2.1-pro"
        cfg.fish.latency = "balanced"
        cfg.fish.temperature = 0.6
        return cfg
    }

    func testMakeRequestShape() throws {
        let req = FishAudioFetcher.makeRequest(text: "Ciao.", config: config())
        XCTAssertEqual(req.url?.absoluteString,
                       "https://api.fish.audio/v1/tts/stream/with-timestamp")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer fk")
        // fish takes the model as a header, not a body field.
        XCTAssertEqual(req.value(forHTTPHeaderField: "model"), "s2.1-pro")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
        XCTAssertEqual(body["text"] as? String, "Ciao.")
        XCTAssertEqual(body["reference_id"] as? String, "ref123")
        XCTAssertEqual(body["format"] as? String, "pcm")
        XCTAssertEqual(body["sample_rate"] as? Int, 24_000)
        XCTAssertEqual(body["latency"] as? String, "balanced")
        XCTAssertEqual(body["temperature"] as? Double, 0.6)
        XCTAssertNil(body["model"])
        let prosody = try XCTUnwrap(body["prosody"] as? [String: Any])
        XCTAssertEqual(prosody["speed"] as? Double, 1.0)
    }

    func testSpeedIsClampedToFishRange() throws {
        for (input, expected) in [(0.1, 0.5), (3.0, 2.0), (1.5, 1.5)] {
            let req = FishAudioFetcher.makeRequest(text: "x", config: config(speed: input))
            let body = try XCTUnwrap(
                JSONSerialization.jsonObject(with: XCTUnwrap(req.httpBody)) as? [String: Any])
            let prosody = try XCTUnwrap(body["prosody"] as? [String: Any])
            XCTAssertEqual(prosody["speed"] as? Double, expected)
        }
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `xcodebuild -project ZielVanSebastian.xcodeproj -scheme ZielVanSebastian -configuration Debug -derivedDataPath build -destination 'platform=macOS' -only-testing:CoreTests/FishAudioFetcherTests test 2>&1 | tail -20`

Expected: compile failure — cannot find `FishAudioFetcher`.

- [ ] **Step 3: Implement**

Create `Sources/Speech/FishAudioFetcher.swift`:

```swift
import Foundation

/// fish.audio TTS: one HTTP request per batch against the timestamped SSE
/// endpoint, ~3-7x cheaper than ElevenLabs. Request building and response
/// parsing are static and unit-tested; the network glue is verified by hand.
///
/// fish has no `previous_request_ids` equivalent, so cross-request continuity
/// does not exist here — continuity comes from batching several sentences into
/// one request (see SpeechCoordinator) and from holding every generation
/// parameter identical across calls.
/// Conformance to `TTSFetching` is added in Task 7, together with `fetch`.
public final class FishAudioFetcher {
    static let sampleRate = 24_000.0

    private let config: SpeechConfig
    private let session: URLSession

    public init(config: SpeechConfig, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    static func makeRequest(text: String, config: SpeechConfig) -> URLRequest {
        var req = URLRequest(
            url: URL(string: "https://api.fish.audio/v1/tts/stream/with-timestamp")!)
        req.httpMethod = "POST"
        // URLSession treats this as an idle-between-packets limit, so it is safe
        // for a streamed (SSE) response.
        req.timeoutInterval = 10
        req.setValue("Bearer \(config.fish.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(config.fish.model, forHTTPHeaderField: "model")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "text": text,
            "reference_id": config.fish.referenceId,
            "format": "pcm",
            "sample_rate": Int(sampleRate),
            "latency": config.fish.latency,
            "temperature": config.fish.temperature,
            "prosody": ["speed": min(2.0, max(0.5, config.speed))],
        ]
        req.httpBody = try! JSONSerialization.data(withJSONObject: body)
        return req
    }
}
```

- [ ] **Step 4: Run the tests**

Run the same `-only-testing:CoreTests/FishAudioFetcherTests` command.
Expected: PASS, 2 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/Speech/FishAudioFetcher.swift Tests/FishAudioFetcherTests.swift
git commit -m "feat(speech): fish.audio request building"
```

---

## Task 7: Fish SSE response parsing

The subtle part: each event carries a **cumulative snapshot** for its `chunk_seq`, and clients must *replace* the previous snapshot for that chunk rather than append to it.

**Files:**
- Modify: `Sources/Speech/FishAudioFetcher.swift` (add the event type, `events(in:)`, `parseResponse`, real `fetch`)
- Modify: `Tests/FishAudioFetcherTests.swift` (add parsing tests)

**Interfaces:**
- Consumes: `AlignmentMapper.tokens`/`reconcile` (Task 1), `SpokenAudioSplitter.split` (Task 2), `AmplitudeEnvelope.from(pcm:sampleRate:rate:)`
- Produces: `static func parseResponse(_ data: Data, batch: [SpeechRequest]) throws -> [SpokenAudio]`

- [ ] **Step 1: Write the failing tests**

Add to `Tests/FishAudioFetcherTests.swift`:

```swift
    /// Two 16-bit samples per chunk, base64'd the way fish sends them.
    private func sse(_ events: [String]) -> Data {
        Data(events.map { "data: \($0)" }.joined(separator: "\n\n").utf8)
    }

    private var chunkA: String { Data([0x01, 0x00, 0x02, 0x00]).base64EncodedString() }
    private var chunkB: String { Data([0x03, 0x00, 0x04, 0x00]).base64EncodedString() }

    func testParseResponseConcatenatesAudioAndMapsWords() throws {
        let body = sse([
            """
            {"audio_base64": "\(chunkA)", "chunk_seq": 0, "chunk_audio_offset_sec": 0.0,
             "content": "Hi there.",
             "alignment": {"audio_duration": 0.4,
                           "segments": [{"text": "Hi", "start": 0.0, "end": 0.2}]}}
            """,
            """
            {"audio_base64": "\(chunkB)", "chunk_seq": 0, "chunk_audio_offset_sec": 0.0,
             "content": "Hi there.",
             "alignment": {"audio_duration": 0.4,
                           "segments": [{"text": "Hi", "start": 0.0, "end": 0.2},
                                        {"text": "there", "start": 0.2, "end": 0.4}]}}
            """,
        ])
        let clips = try FishAudioFetcher.parseResponse(
            body, batch: [SpeechRequest(id: 1, text: "Hi there.")])
        XCTAssertEqual(clips.count, 1)
        // Audio from both events, in arrival order.
        XCTAssertEqual(clips[0].pcm, Data([0x01, 0x00, 0x02, 0x00, 0x03, 0x00, 0x04, 0x00]))
        // The later snapshot REPLACED the earlier one (2 segments, not 3).
        XCTAssertEqual(clips[0].words.count, 2)
        // Our punctuation survives: fish's segment text is stripped.
        XCTAssertEqual(clips[0].words.map(\.text), ["Hi", "there."])
        XCTAssertEqual(clips[0].sampleRate, 24_000)
        XCTAssertFalse(clips[0].envelope.isEmpty)
        XCTAssertNil(clips[0].requestID)   // fish has no request-stitching id
    }

    func testChunkOffsetsMakeTimesAbsolute() throws {
        let body = sse([
            """
            {"audio_base64": "\(chunkA)", "chunk_seq": 0, "chunk_audio_offset_sec": 0.0,
             "alignment": {"audio_duration": 0.2,
                           "segments": [{"text": "One", "start": 0.0, "end": 0.2}]}}
            """,
            """
            {"audio_base64": "\(chunkB)", "chunk_seq": 1, "chunk_audio_offset_sec": 0.5,
             "alignment": {"audio_duration": 0.2,
                           "segments": [{"text": "Two", "start": 0.0, "end": 0.2}]}}
            """,
        ])
        let clips = try FishAudioFetcher.parseResponse(
            body, batch: [SpeechRequest(id: 1, text: "One Two")])
        XCTAssertEqual(clips[0].words[1].start, 0.5, accuracy: 0.0001)
        XCTAssertEqual(clips[0].words[1].end, 0.7, accuracy: 0.0001)
    }

    func testBatchIsSplitIntoOneClipPerSentence() throws {
        let body = sse([
            """
            {"audio_base64": "\(Data(count: 48_000).base64EncodedString())",
             "chunk_seq": 0, "chunk_audio_offset_sec": 0.0,
             "alignment": {"audio_duration": 1.0,
                           "segments": [{"text": "One", "start": 0.0, "end": 0.4},
                                        {"text": "Two", "start": 0.5, "end": 1.0}]}}
            """,
        ])
        let clips = try FishAudioFetcher.parseResponse(body, batch: [
            SpeechRequest(id: 1, text: "One."),
            SpeechRequest(id: 2, text: "Two."),
        ])
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].words.map(\.text), ["One."])
        XCTAssertEqual(clips[1].words.map(\.text), ["Two."])
        XCTAssertEqual(clips[1].words[0].start, 0.0, accuracy: 0.0001)  // rebased
    }

    func testMultiLineDataPayloadsAreJoined() throws {
        let json = """
        {"audio_base64": "\(chunkA)", "chunk_seq": 0,
         "alignment": {"audio_duration": 0.2,
                       "segments": [{"text": "Hi", "start": 0.0, "end": 0.2}]}}
        """
        // One SSE event whose JSON is spread over several `data:` lines.
        let body = Data(json.split(separator: "\n")
            .map { "data: \($0)" }.joined(separator: "\n").utf8)
        let clips = try FishAudioFetcher.parseResponse(
            body, batch: [SpeechRequest(id: 1, text: "Hi")])
        XCTAssertEqual(clips[0].words.map(\.text), ["Hi"])
    }

    func testEmptyBodyThrows() {
        XCTAssertThrowsError(try FishAudioFetcher.parseResponse(
            Data(), batch: [SpeechRequest(id: 1, text: "Hi")]))
    }

    func testAudioWithoutAlignmentThrows() {
        let body = sse([#"{"audio_base64": "\#(chunkA)", "chunk_seq": 0}"#])
        XCTAssertThrowsError(try FishAudioFetcher.parseResponse(
            body, batch: [SpeechRequest(id: 1, text: "Hi")]))
    }

    func testGarbageEventsAreSkippedRatherThanFatal() throws {
        let body = sse([
            "not json at all",
            """
            {"audio_base64": "\(chunkA)", "chunk_seq": 0,
             "alignment": {"audio_duration": 0.2,
                           "segments": [{"text": "Hi", "start": 0.0, "end": 0.2}]}}
            """,
        ])
        let clips = try FishAudioFetcher.parseResponse(
            body, batch: [SpeechRequest(id: 1, text: "Hi")])
        XCTAssertEqual(clips[0].words.map(\.text), ["Hi"])
    }
```

- [ ] **Step 2: Run to verify failure**

Run the `-only-testing:CoreTests/FishAudioFetcherTests` command.
Expected: compile failure — no `parseResponse` on `FishAudioFetcher`.

- [ ] **Step 3: Implement parsing and the real fetch**

In `Sources/Speech/FishAudioFetcher.swift`, add above `makeRequest`:

```swift
    private struct TimestampEvent: Decodable {
        let audioBase64: String?
        let alignment: Alignment?
        let chunkSeq: Int?
        let chunkAudioOffsetSec: Double?

        struct Alignment: Decodable {
            let segments: [Segment]
            struct Segment: Decodable {
                let text: String
                let start: Double
                let end: Double
            }
        }

        enum CodingKeys: String, CodingKey {
            case audioBase64 = "audio_base64"
            case alignment
            case chunkSeq = "chunk_seq"
            case chunkAudioOffsetSec = "chunk_audio_offset_sec"
        }
    }

    /// Splits an SSE body into event payloads. Events are separated by a blank
    /// line; several `data:` lines within one event are joined with a newline,
    /// per the SSE spec.
    static func events(in body: Data) -> [Data] {
        guard let text = String(data: body, encoding: .utf8) else { return [] }
        var out: [Data] = []
        for block in text.components(separatedBy: "\n\n") {
            let payload = block
                .split(separator: "\n", omittingEmptySubsequences: true)
                .filter { $0.hasPrefix("data:") }
                .map { $0.dropFirst("data:".count).trimmingCharacters(in: .whitespaces) }
                .joined(separator: "\n")
            if !payload.isEmpty, payload != "[DONE]" { out.append(Data(payload.utf8)) }
        }
        return out
    }
```

and below `makeRequest`:

```swift
    static func parseResponse(_ data: Data, batch: [SpeechRequest]) throws -> [SpokenAudio] {
        var pcm = Data()
        // chunk_seq → the latest cumulative alignment snapshot for that chunk.
        var snapshots: [Int: (segments: [TimestampEvent.Alignment.Segment], offset: Double)] = [:]

        for raw in events(in: data) {
            guard let ev = try? JSONDecoder().decode(TimestampEvent.self, from: raw) else {
                continue   // a malformed event is not worth losing the whole reply over
            }
            if let b64 = ev.audioBase64, let chunk = Data(base64Encoded: b64) {
                pcm.append(chunk)
            }
            if let a = ev.alignment {
                // fish sends a cumulative snapshot per chunk: replace, never
                // append, or every word would be duplicated.
                snapshots[ev.chunkSeq ?? 0] = (a.segments, ev.chunkAudioOffsetSec ?? 0)
            }
        }
        guard !pcm.isEmpty else { throw TTSError.malformedResponse }

        var timings: [WordTiming] = []
        for key in snapshots.keys.sorted() {
            guard let snap = snapshots[key] else { continue }
            for seg in snap.segments {
                timings.append(WordTiming(text: seg.text,
                                          start: seg.start + snap.offset,
                                          end: seg.end + snap.offset))
            }
        }

        let tokenLists = batch.map { AlignmentMapper.tokens($0.text) }
        // fish's segment text is punctuation- and apostrophe-stripped, so only
        // its timings are used; the displayed text stays ours.
        let words = AlignmentMapper.reconcile(timings,
                                              displayTokens: tokenLists.flatMap { $0 })
        guard !words.isEmpty else { throw TTSError.malformedResponse }

        let envelope = AmplitudeEnvelope.from(pcm: pcm, sampleRate: sampleRate, rate: 60)
        let whole = SpokenAudio(requestID: nil, words: words, pcm: pcm,
                                sampleRate: sampleRate, envelope: envelope, envelopeRate: 60)
        return SpokenAudioSplitter.split(whole, tokenCounts: tokenLists.map(\.count))
    }
```

Then add the conformance — change the declaration to
`public final class FishAudioFetcher: TTSFetching` and delete the
"Conformance to `TTSFetching` is added in Task 7" comment — and add `fetch`:

```swift
    public func fetch(_ batch: [SpeechRequest], previousRequestIDs: [String],
                      completion: @escaping (Result<[SpokenAudio], Error>) -> Void) {
        func finish(_ r: Result<[SpokenAudio], Error>) {
            DispatchQueue.main.async { completion(r) }
        }
        guard !batch.isEmpty else {
            finish(.failure(TTSError.malformedResponse))
            return
        }
        // previousRequestIDs is deliberately unused: fish has no cross-request
        // conditioning. Continuity comes from the batch itself.
        let text = batch.map(\.text).joined(separator: " ")
        let task = session.dataTask(with: Self.makeRequest(text: text, config: config)) {
            data, response, error in
            if let error {
                finish(.failure(error))
                return
            }
            guard let http = response as? HTTPURLResponse else {
                finish(.failure(TTSError.malformedResponse))
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                if http.statusCode == 402 {
                    NSLog("speech: fish.audio returned 402 — the account is out of credit")
                } else {
                    NSLog("speech: fish.audio request failed with HTTP %d", http.statusCode)
                }
                finish(.failure(TTSError.httpStatus(http.statusCode)))
                return
            }
            do {
                finish(.success(try Self.parseResponse(data ?? Data(), batch: batch)))
            } catch {
                finish(.failure(error))
            }
        }
        task.resume()
    }
```

- [ ] **Step 4: Run the tests, then the full suite**

Run the `-only-testing:CoreTests/FishAudioFetcherTests` command.
Expected: PASS, 9 tests.

Then `make test`.
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Speech/FishAudioFetcher.swift Tests/FishAudioFetcherTests.swift
git commit -m "feat(speech): parse fish.audio timestamped SSE responses"
```

---

## Task 8: Select the provider, make fish the default, document

**Files:**
- Modify: `App/AppDelegate.swift:46-58` (provider-specific construction and validation)
- Modify: `Sources/Core/Config.swift` (`SpeechConfig.provider` default → `.fish`)
- Modify: `Tests/ConfigTests.swift` (`testSpeechConfigDefaults` expects `.fish`)
- Modify: `config.example.json` (`"provider": "fish"`)
- Modify: `README.md` (speech section)
- Modify: `CLAUDE.md` (the `Sources/Speech/` architecture line)

**Interfaces:**
- Consumes: `FishAudioFetcher` (Tasks 6-7), `ElevenLabsFetcher`, `TTSService`

- [ ] **Step 1: Flip the default and update the test**

In `Sources/Core/Config.swift`, change `public var provider: SpeechProvider = .elevenlabs` to `.fish`. In `Tests/ConfigTests.swift`, change the one line in `testSpeechConfigDefaults` from `XCTAssertEqual(cfg.provider, .elevenlabs)` to `XCTAssertEqual(cfg.provider, .fish)` and drop the trailing comment.

- [ ] **Step 2: Implement provider selection**

Replace lines 46-58 of `App/AppDelegate.swift` (the `voiceId`/`urlSafeVoiceId`/`if` block) with:

```swift
        let sp = config.speech
        let fetcher: TTSFetching?
        switch sp.provider {
        case .elevenlabs:
            // The voice id goes in the URL path, so it must be path-safe —
            // fish's referenceId travels in the JSON body and does not.
            let vid = sp.elevenlabs.voiceId
            let urlSafeVoiceId = !vid.isEmpty
                && vid.unicodeScalars.allSatisfy { CharacterSet.urlPathAllowed.contains($0) }
                && !vid.contains("/")
            if !sp.elevenlabs.apiKey.isEmpty && urlSafeVoiceId {
                fetcher = ElevenLabsFetcher(config: sp)
            } else {
                fetcher = nil
                if sp.enabled {
                    NSLog("speech.provider=elevenlabs but speech.elevenlabs.apiKey/voiceId is missing or the voiceId is malformed — speech disabled (restart after fixing config)")
                }
            }
        case .fish:
            if !sp.fish.apiKey.isEmpty && !sp.fish.referenceId.isEmpty {
                fetcher = FishAudioFetcher(config: sp)
            } else {
                fetcher = nil
                if sp.enabled {
                    NSLog("speech.provider=fish but speech.fish.apiKey/referenceId is missing — speech disabled (restart after fixing config)")
                }
            }
        }
        if let fetcher {
            let tts = TTSService(fetcher: fetcher)
            tts.outputDeviceName = config.voice.outputDevice
            self.tts = tts
            speech = SpeechCoordinator(director: director, synth: tts,
                                       volume: config.speech.volume, now: clock)
        }
```

- [ ] **Step 3: Update config.example.json**

Change `"provider": "elevenlabs"` to `"provider": "fish"`.

- [ ] **Step 4: Update the docs**

In `README.md`'s speech section, document: selecting a provider with `speech.provider`; that fish is the default; the fish setup steps (get an API key, pick a `reference_id` from the fish.audio voice library, paste both into `speech.fish`); `GET /model?self=true` for listing your own cloned voices; and this upgrade note:

> **Upgrading:** `speech` moved from flat keys to per-provider blocks and now defaults to `provider: "fish"`. An existing `config.json` with `speech.apiKey`/`speech.voiceId` will log that those keys are ignored and fall back to display-only pacing until you either add a `speech.fish` block or set `"provider": "elevenlabs"` and move the old keys under `speech.elevenlabs`.

Also note the tradeoff: fish is cheaper but has no cross-request prosody conditioning, so continuity relies on sentence batching.

In `CLAUDE.md`, replace the `Sources/Speech/` line with:

```markdown
- `Sources/Speech/` — `SpeechCoordinator` (ordered sentence pipeline, batches sentences into one generation) + `TTSService` = `TTSFetching` (`FishAudioFetcher` default, `ElevenLabsFetcher`) + shared `AudioPlayback`; seams: `SpeechSynthesizing`, `TTSFetching`
```

- [ ] **Step 5: Run the full suite and build the app**

Run: `make test`
Expected: PASS.

Run: `make build`
Expected: build succeeds (proves the AppDelegate rewiring compiles — it is outside the test target).

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/Config.swift App/AppDelegate.swift Tests/ConfigTests.swift config.example.json README.md CLAUDE.md
git commit -m "feat(speech): select TTS provider from config, default to fish.audio"
```

---

## Task 9: Live validation against the real API

No code unless a step fails. **Requires the fish.audio API key** — ask for it rather than guessing, and never write it into a tracked file.

**Files:**
- Modify (only if a step fails): `Sources/Speech/FishAudioFetcher.swift`
- Modify: `docs/superpowers/plans/2026-07-30-fish-audio-tts.md` (record findings inline)

- [ ] **Step 1: Confirm the PCM format**

fish documents neither bit depth, endianness, channel count, nor which `sample_rate` values are accepted. `AudioPlayback` assumes 16-bit LE mono, and a wrong assumption produces noise or a chipmunk voice rather than an error.

```bash
FISH_KEY='<ask the user>'
curl -sS -X POST https://api.fish.audio/v1/tts/stream/with-timestamp \
  -H "Authorization: Bearer $FISH_KEY" \
  -H 'model: s2.1-pro' \
  -H 'Content-Type: application/json' \
  --data '{"text":"Hello from Ziel, this is a test.","reference_id":"<voice id>","format":"pcm","sample_rate":24000,"latency":"balanced"}' \
  -o /tmp/fish.sse
head -c 400 /tmp/fish.sse
```

Extract and play the audio to verify the format:

```bash
python3 - <<'PY'
import base64, json, re
raw = open('/tmp/fish.sse', 'rb').read().decode('utf-8', 'replace')
pcm = b''
for line in raw.splitlines():
    if line.startswith('data:'):
        try: ev = json.loads(line[5:].strip())
        except Exception: continue
        if ev.get('audio_base64'): pcm += base64.b64decode(ev['audio_base64'])
print('pcm bytes:', len(pcm), 'implied seconds at 24k/16-bit mono:', len(pcm)/2/24000)
open('/tmp/fish.pcm','wb').write(pcm)
PY
afplay -d /tmp/fish.pcm 2>/dev/null || \
  ffplay -f s16le -ar 24000 -ac 1 -autoexit /tmp/fish.pcm
```

Expected: intelligible speech at normal pitch and speed. Chipmunk pitch means the sample rate differs; static means the bit depth or endianness differs. If either happens, fix `FishAudioFetcher.sampleRate` or the request's `format`, and re-run `make test`.

- [ ] **Step 2: Pick a voice**

Audition voices at `https://fish.audio` (the web library has playable samples; `GET /model` returns metadata only). Put the chosen 32-hex id in `config.json` under `speech.fish.referenceId`.

To list your own cloned voices:

```bash
curl -sS 'https://api.fish.audio/model?self=true&page_size=20' \
  -H "Authorization: Bearer $FISH_KEY" | python3 -m json.tool | head -40
```

Note the id field is `_id`, not `id`.

- [ ] **Step 3: Measure the segment/token mismatch rate**

Run the app with fish enabled and grep the log for the mismatch line from Task 1:

```bash
./build/Build/Products/Debug/Ziel\ van\ Sebastian.app/Contents/MacOS/Ziel\ van\ Sebastian --window --demo 2>&1 \
  | grep -c 'alignment mismatch'
```

Expected: rare or zero. Frequent mismatches mean the proportional fallback is doing real work and word highlighting will drift within sentences — that is the signal to add the normalized greedy matching the spec defers (normalize both sides to lowercase alphanumerics, then match in order). Record the observed rate here.

- [ ] **Step 4: Compare latency modes**

Time a request with `latency` set to `balanced` and then `low`, using the same text and voice:

```bash
for mode in balanced low; do
  echo -n "$mode: "
  curl -sS -o /dev/null -w '%{time_starttransfer}s total=%{time_total}s\n' \
    -X POST https://api.fish.audio/v1/tts/stream/with-timestamp \
    -H "Authorization: Bearer $FISH_KEY" -H 'model: s2.1-pro' \
    -H 'Content-Type: application/json' \
    --data "{\"text\":\"Hello from Ziel, this is a test.\",\"reference_id\":\"<voice id>\",\"format\":\"pcm\",\"sample_rate\":24000,\"latency\":\"$mode\"}"
done
```

Record both numbers. Change `speech.fish.latency`'s default only if `low` is meaningfully faster and still sounds good.

- [ ] **Step 5: End-to-end listening test**

Run: `make run`

Confirm, in order:
1. speech works at all on the fish path
2. drift at batch boundaries is no worse than the ElevenLabs baseline — this is the requirement the whole design exists to protect
3. no mid-reply gaps (if there are, lower `maxBatchSentences` to 2 and retest)
4. the face's displayed words match what the voice says, especially on sentences with apostrophes and punctuation

- [ ] **Step 6: Appliance run**

On the Mac mini with the PowerConf connected, confirm output-device pinning still works through `AudioPlayback` (`voice.outputDevice` set, mic and speaker on one unit for hardware AEC), and that a display-sleep/dock event still triggers the engine rebuild without stranding playback.

- [ ] **Step 7: Record findings and commit**

Write the measured PCM format, mismatch rate, and latency numbers into this task's steps above, then:

```bash
git add docs/superpowers/plans/2026-07-30-fish-audio-tts.md
git commit -m "docs: record fish.audio live validation findings"
```
