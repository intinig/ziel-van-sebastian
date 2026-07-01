# Speaking Waveform Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** During speech, draw a voice-reactive radial halo around the RSVP word and ripple the whole CRT surface like water, driven by the real TTS amplitude envelope.

**Architecture:** A pure Core function turns each sentence's PCM into a smoothed amplitude envelope carried on `SpokenAudio`. The `Director` samples it by the audio clock into a new `SceneState.level` (attack/release-smoothed, continuous, word-cadence-independent). The renderer draws halo rings in the scene pass and the CRT fragment shader applies a radial UV ripple — both config-gated.

**Tech Stack:** Swift 5.10, Metal (`ScenePass` flat pipeline, `Shaders.metal` CRT composite), XCTest (`CoreTests`).

## Global Constraints

- Swift language mode **5.10**.
- One module per build target — Core/Speech/Rendering compile together; **no cross-module `import`**.
- Core never reads a clock; `level` is a pure function of injected `now` + precomputed envelope.
- Waveform is **speaking-state only** — no idle/thinking shimmer, no per-word ripple pulses.
- **Do not touch `FaceGeometry`.**
- Config defaults: `waveform.enabled = true`, `waveform.ripple.enabled = true`, `strength = 0.10`, `speed = 2.0`; live-reloadable via the existing config watcher.
- The Swift `CRTPipeline.Params` struct MUST match the MSL `CRTParams` field-for-field (order + size); the `init` has an `assert(MemoryLayout<Params>.stride == …)` that must be updated when fields change.
- `*.xcodeproj` is generated — never edit it (no `project.yml` change is needed here).
- `make test` (CoreTests) stays green.

**Verification commands:**
- Single Core test: `xcodebuild -project ZielVanSebastian.xcodeproj -scheme ZielVanSebastian -destination 'platform=macOS' -only-testing:CoreTests/<Suite>/<test> test`
- Full suite: `make test`
- Compile app (Metal): `make build`

**Reference:** design spec `docs/superpowers/specs/2026-07-01-speaking-waveform-design.md`; visual demo was Look C + ripple, defaults strength 0.10 / speed 2.0.

## File Structure

- `Sources/Core/AmplitudeEnvelope.swift` — **new**; pure PCM→envelope (Task 1).
- `Sources/Speech/SpeechSynthesizing.swift` — `SpokenAudio` gains `envelope`/`envelopeRate` (Task 2).
- `Sources/Speech/ElevenLabsTTS.swift` — `parseResponse` computes the envelope (Task 2).
- `Sources/Core/SceneTypes.swift` — `SceneState` gains `level` (Task 3).
- `Sources/Core/Director.swift` — level sampling + smoothing; `speechStarted`/`QueuedSentence` carry envelope (Task 3).
- `Sources/Speech/SpeechCoordinator.swift` — passes the envelope to `speechStarted` (Task 3).
- `App/AppDelegate.swift` — fallback `SceneState(level:0)`; push `waveform` config to the renderer (Tasks 3, 5).
- `Sources/Core/Config.swift` + `config.example.json` — `WaveformConfig`/`RippleConfig` (Task 4).
- `Sources/Rendering/ScenePass.swift` — `drawHalo` (Task 5).
- `Sources/Rendering/CRTPipeline.swift` — `Params` ripple fields, `waveform` prop, `run(level:)` (Tasks 5, 6).
- `Sources/Rendering/ZielRenderer.swift` — draw halo; pass `level` to the CRT pass (Tasks 5, 6).
- `Sources/Rendering/Shaders.metal` — `CRTParams` ripple fields + `composite_fragment` displacement (Task 6).

---

### Task 1: AmplitudeEnvelope (Core)

**Files:**
- Create: `Sources/Core/AmplitudeEnvelope.swift`
- Test: `Tests/AmplitudeEnvelopeTests.swift`

**Interfaces:**
- Produces: `AmplitudeEnvelope.from(pcm: Data, sampleRate: Double, rate: Double = 60) -> [Float]` — windowed RMS of 16-bit LE mono PCM, normalized 0…1, `rate` samples/sec, ≥1 sample when PCM is non-empty.

- [ ] **Step 1: Write the failing tests**

Create `Tests/AmplitudeEnvelopeTests.swift`:

```swift
import XCTest

final class AmplitudeEnvelopeTests: XCTestCase {
    private func pcm(_ samples: [Int16]) -> Data {
        var d = Data(capacity: samples.count * 2)
        for s in samples {
            let u = UInt16(bitPattern: s)
            d.append(UInt8(u & 0xff)); d.append(UInt8(u >> 8))
        }
        return d
    }

    func testSilenceIsZero() {
        let env = AmplitudeEnvelope.from(pcm: pcm([Int16](repeating: 0, count: 2400)),
                                         sampleRate: 24000, rate: 60)
        XCTAssertFalse(env.isEmpty)
        XCTAssertEqual(env.max() ?? 1, 0, accuracy: 0.0001)
    }

    func testLoudToneIsHigh() {
        let env = AmplitudeEnvelope.from(pcm: pcm([Int16](repeating: 16000, count: 2400)),
                                         sampleRate: 24000, rate: 60)
        XCTAssertGreaterThan(env.max() ?? 0, 0.5)
        XCTAssertLessThanOrEqual(env.max() ?? 2, 1.0)
    }

    func testSampleCountIsCeilFramesOverWindow() {
        // 2400 frames @ 24000Hz, rate 60 → window 400 → 6 windows.
        let env = AmplitudeEnvelope.from(pcm: pcm([Int16](repeating: 100, count: 2400)),
                                         sampleRate: 24000, rate: 60)
        XCTAssertEqual(env.count, 6)
    }

    func testEmptyPCMIsEmpty() {
        XCTAssertTrue(AmplitudeEnvelope.from(pcm: Data(), sampleRate: 24000, rate: 60).isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -project ZielVanSebastian.xcodeproj -scheme ZielVanSebastian -destination 'platform=macOS' -only-testing:CoreTests/AmplitudeEnvelopeTests test`
Expected: FAIL to compile — `cannot find 'AmplitudeEnvelope' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/Core/AmplitudeEnvelope.swift`:

```swift
import Foundation

/// Windowed RMS of 16-bit little-endian mono PCM → normalized amplitude levels
/// (0…1), `rate` samples per second. Pure function: drives the speaking waveform
/// from the real voice, sampled later by the audio clock in the Director.
public enum AmplitudeEnvelope {
    public static func from(pcm: Data, sampleRate: Double, rate: Double = 60) -> [Float] {
        let frameCount = pcm.count / 2
        guard frameCount > 0, sampleRate > 0, rate > 0 else { return [] }
        let window = max(1, Int((sampleRate / rate).rounded()))
        let windowCount = (frameCount + window - 1) / window   // ceil, ≥1
        var out = [Float](); out.reserveCapacity(windowCount)
        pcm.withUnsafeBytes { raw in
            let s = raw.bindMemory(to: Int16.self)
            for w in 0..<windowCount {
                let start = w * window
                let end = min(start + window, frameCount)
                var sumSq = 0.0
                for i in start..<end {
                    let v = Double(Int16(littleEndian: s[i])) / 32768.0
                    sumSq += v * v
                }
                let rms = end > start ? (sumSq / Double(end - start)).squareRoot() : 0
                out.append(Float(min(1.0, rms * 3.5)))   // soft gain so speech reads lively
            }
        }
        return out
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild -project ZielVanSebastian.xcodeproj -scheme ZielVanSebastian -destination 'platform=macOS' -only-testing:CoreTests/AmplitudeEnvelopeTests test`
Expected: PASS (4 tests).

- [ ] **Step 5: Full suite**

Run: `make test` — Expected: `** TEST SUCCEEDED **`, 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/AmplitudeEnvelope.swift Tests/AmplitudeEnvelopeTests.swift
git commit -m "feat: AmplitudeEnvelope — windowed RMS of PCM for the speaking waveform

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `SpokenAudio` carries the envelope; `ElevenLabsTTS` computes it

**Files:**
- Modify: `Sources/Speech/SpeechSynthesizing.swift` (`SpokenAudio`)
- Modify: `Sources/Speech/ElevenLabsTTS.swift` (`parseResponse`)
- Test: `Tests/ElevenLabsTTSTests.swift`

**Interfaces:**
- Consumes: `AmplitudeEnvelope.from` (Task 1).
- Produces: `SpokenAudio.envelope: [Float]`, `SpokenAudio.envelopeRate: Double`; `init` gains `envelope: [Float] = []`, `envelopeRate: Double = 60` (defaults keep existing call sites compiling).

- [ ] **Step 1: Write the failing test**

In `Tests/ElevenLabsTTSTests.swift`, inside `testParseResponseExtractsWordsAndPCM()` (the test that already binds `let audio = try ElevenLabsTTS.parseResponse(...)`), add these two assertions right after `audio` is created:

```swift
        XCTAssertFalse(audio.envelope.isEmpty)   // envelope computed from the PCM
        XCTAssertEqual(audio.envelopeRate, 60)
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -project ZielVanSebastian.xcodeproj -scheme ZielVanSebastian -destination 'platform=macOS' -only-testing:CoreTests/ElevenLabsTTSTests/testParseResponseExtractsWordsAndPCM test`
Expected: FAIL to compile — `value of type 'SpokenAudio' has no member 'envelope'`.

- [ ] **Step 3: Implement**

In `Sources/Speech/SpeechSynthesizing.swift`, replace the `SpokenAudio` struct with:

```swift
/// Fully synthesized sentence: word timings + raw 16-bit little-endian mono PCM,
/// plus a normalized amplitude envelope for the speaking waveform.
public struct SpokenAudio {
    public let requestID: String?     // ElevenLabs request id, for continuity stitching
    public let words: [WordTiming]
    public let pcm: Data
    public let sampleRate: Double
    public let envelope: [Float]      // 0…1 levels at `envelopeRate` Hz
    public let envelopeRate: Double

    public init(requestID: String?, words: [WordTiming], pcm: Data, sampleRate: Double,
                envelope: [Float] = [], envelopeRate: Double = 60) {
        self.requestID = requestID
        self.words = words
        self.pcm = pcm
        self.sampleRate = sampleRate
        self.envelope = envelope
        self.envelopeRate = envelopeRate
    }
}
```

In `Sources/Speech/ElevenLabsTTS.swift`, `parseResponse` currently ends with:

```swift
        return SpokenAudio(requestID: requestID, words: words, pcm: pcm, sampleRate: sampleRate)
```

Replace that line with:

```swift
        let envelope = AmplitudeEnvelope.from(pcm: pcm, sampleRate: sampleRate, rate: 60)
        return SpokenAudio(requestID: requestID, words: words, pcm: pcm, sampleRate: sampleRate,
                           envelope: envelope, envelopeRate: 60)
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild -project ZielVanSebastian.xcodeproj -scheme ZielVanSebastian -destination 'platform=macOS' -only-testing:CoreTests/ElevenLabsTTSTests test`
Expected: PASS.

- [ ] **Step 5: Full suite**

Run: `make test` — Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/Speech/SpeechSynthesizing.swift Sources/Speech/ElevenLabsTTS.swift Tests/ElevenLabsTTSTests.swift
git commit -m "feat: SpokenAudio carries a PCM amplitude envelope

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `SceneState.level` — Director samples + smooths the envelope

**Files:**
- Modify: `Sources/Core/SceneTypes.swift` (`SceneState`)
- Modify: `Sources/Core/Director.swift` (`QueuedSentence`, `speechStarted`, `tick`, level state + helper)
- Modify: `Sources/Speech/SpeechCoordinator.swift` (pass envelope to `speechStarted`)
- Modify: `App/AppDelegate.swift` (fallback `SceneState(level: 0)`)
- Test: `Tests/DirectorSpeechTests.swift`

**Interfaces:**
- Consumes: `SpokenAudio.envelope`/`envelopeRate` (Task 2).
- Produces: `SceneState.level: Double` (0…1, smoothed speaking amplitude, 0 when not speaking). `Director.speechStarted(id:words:envelope:envelopeRate:now:)` — the new `envelope`/`envelopeRate` params default to `[]`/`60`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/DirectorSpeechTests.swift` (before the final closing brace; `makeSpeechDirector()` already exists):

```swift
    func testLevelZeroWhenNotSpeaking() {
        let d = makeSpeechDirector()
        d.handle(.connectionUp, now: 0)
        XCTAssertEqual(d.tick(now: 1).level, 0, accuracy: 0.0001)
    }

    func testLevelRisesWithEnvelopeThenReleasesAfterSpeech() {
        let d = makeSpeechDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r1", session: "main", text: "Talk. "), now: 1)
        let req = d.takeSpeechRequests()[0]
        _ = d.tick(now: 2)
        d.speechStarted(id: req.id, words: [WordTiming(text: "Talk.", start: 0, end: 2)],
                        envelope: [Float](repeating: 1.0, count: 120), envelopeRate: 60, now: 2.0)
        let a = d.tick(now: 2.02).level
        let b = d.tick(now: 2.10).level
        XCTAssertGreaterThan(b, a)                       // attack: rising toward the loud voice
        XCTAssertGreaterThan(d.tick(now: 2.5).level, 0.8)
        _ = d.tick(now: 2.95)
        d.speechFinished(id: req.id, now: 3.0)
        let c = d.tick(now: 3.02).level
        let e = d.tick(now: 3.20).level
        XCTAssertLessThan(e, c)                          // release: easing toward 0
        XCTAssertLessThan(e, 0.3)
    }

    func testLevelContinuousAcrossWordChanges() {
        let d = makeSpeechDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "r1", session: "main", text: "One two three. "), now: 1)
        let req = d.takeSpeechRequests()[0]
        _ = d.tick(now: 2)
        d.speechStarted(id: req.id, words: [
            WordTiming(text: "One", start: 0, end: 0.3),
            WordTiming(text: "two", start: 0.3, end: 0.6),
            WordTiming(text: "three.", start: 0.6, end: 1.0),
        ], envelope: [Float](repeating: 1.0, count: 90), envelopeRate: 60, now: 2.0)
        _ = d.tick(now: 2.4)
        let duringTwo = d.tick(now: 2.55).level
        let duringThree = d.tick(now: 2.75).level        // a word boundary was crossed
        XCTAssertGreaterThan(duringTwo, 0.7)
        XCTAssertGreaterThan(duringThree, 0.7)           // level did not dip on the word change
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -project ZielVanSebastian.xcodeproj -scheme ZielVanSebastian -destination 'platform=macOS' -only-testing:CoreTests/DirectorSpeechTests test`
Expected: FAIL to compile — `value of type 'SceneState' has no member 'level'` (and the extra `speechStarted` args).

- [ ] **Step 3a: Add `level` to `SceneState`**

In `Sources/Core/SceneTypes.swift`, `SceneState`: add the property after `tint` and thread it through `init`. The struct becomes:

```swift
public struct SceneState: Equatable {
    public let phase: Phase
    public let phaseProgress: Double
    public let timeInPhase: TimeInterval
    public let word: String?
    public let wordAge: TimeInterval
    public let hint: String?
    public let dozing: Bool
    public let tint: ColorRGB
    /// Smoothed speaking amplitude 0…1 (drives the waveform); 0 when not speaking.
    public let level: Double

    public init(phase: Phase, phaseProgress: Double, timeInPhase: TimeInterval,
                word: String?, wordAge: TimeInterval, hint: String?,
                dozing: Bool, tint: ColorRGB, level: Double) {
        self.phase = phase; self.phaseProgress = phaseProgress
        self.timeInPhase = timeInPhase; self.word = word; self.wordAge = wordAge
        self.hint = hint; self.dozing = dozing; self.tint = tint; self.level = level
    }
}
```

- [ ] **Step 3b: Director — carry envelope, sample + smooth level**

In `Sources/Core/Director.swift`:

1. In the `QueuedSentence` struct, add two stored properties (after `var startedAt: TimeInterval = 0`):

```swift
        var envelope: [Float] = []
        var envelopeRate: Double = 60
```

2. Add level state near the other speech-state vars (e.g. after `private var wordFromPacer = true`):

```swift
    private var smoothedLevel: Double = 0
    private var lastLevelTick: TimeInterval = 0
```

3. Replace `speechStarted` with the envelope-carrying version:

```swift
    /// Audio playback for sentence `id` began at `now`; `words` are timed
    /// relative to that instant and `envelope` gives its amplitude over time.
    public func speechStarted(id: Int, words: [WordTiming],
                              envelope: [Float] = [], envelopeRate: Double = 60,
                              now: TimeInterval) {
        guard let i = speechQueue.firstIndex(where: { $0.id == id }) else { return }
        speechQueue[i].status = .playing
        speechQueue[i].words = words
        speechQueue[i].startedAt = now
        speechQueue[i].envelope = envelope
        speechQueue[i].envelopeRate = envelopeRate
        lastActivity = now
    }
```

4. Add the sampling helper in the `// MARK: - Internals` section (e.g. next to `timelineForHead`):

```swift
    /// Continuous voice amplitude of the currently-playing sentence, sampled by
    /// the audio clock and linearly interpolated. 0 when nothing is playing —
    /// the halo/ripple then eases out via the release smoothing in tick().
    /// Independent of word cadence by construction.
    private func speakingLevel(now: TimeInterval) -> Double {
        guard let head = speechQueue.first, head.status == .playing,
              !head.envelope.isEmpty else { return 0 }
        let t = (now - head.startedAt) * head.envelopeRate
        if t <= 0 { return Double(head.envelope[0]) }
        let i = Int(t)
        if i >= head.envelope.count - 1 { return Double(head.envelope[head.envelope.count - 1]) }
        let frac = t - Double(i)
        return Double(head.envelope[i]) * (1 - frac) + Double(head.envelope[i + 1]) * frac
    }
```

5. In `tick(now:)`, after `advance(now: now)` and before building the `SceneState`, add the smoothing, then pass `level:` into the returned `SceneState`:

```swift
        let raw = speakingLevel(now: now)
        let dt = max(0, now - lastLevelTick)
        lastLevelTick = now
        let tau = raw > smoothedLevel ? 0.03 : 0.12   // fast attack, gentle release
        smoothedLevel += (raw - smoothedLevel) * (1 - exp(-dt / tau))
```

and in the `return SceneState(...)` add `level: smoothedLevel` as the final argument.

- [ ] **Step 3c: Coordinator passes the envelope**

In `Sources/Speech/SpeechCoordinator.swift`, `playNextIfReady()` calls `speechStarted` inside the `onStarted` closure. Replace that call:

```swift
                self.director.speechStarted(id: head, words: audio.words, now: self.now())
```

with:

```swift
                self.director.speechStarted(id: head, words: audio.words,
                                            envelope: audio.envelope, envelopeRate: audio.envelopeRate,
                                            now: self.now())
```

- [ ] **Step 3d: Fix the fallback `SceneState`**

In `App/AppDelegate.swift`, the `sceneProvider` fallback constructs a `SceneState`; add `level: 0` as its final argument:

```swift
                    ?? SceneState(phase: .offline(auth: false), phaseProgress: 1, timeInPhase: 0,
                                  word: nil, wordAge: 0, hint: nil, dozing: false,
                                  tint: ColorRGB(r: 0.1, g: 0.3, b: 0.1), level: 0)
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild -project ZielVanSebastian.xcodeproj -scheme ZielVanSebastian -destination 'platform=macOS' -only-testing:CoreTests/DirectorSpeechTests test`
Expected: PASS (existing + 3 new).

- [ ] **Step 5: Full suite**

Run: `make test` — Expected: 0 failures (existing `DirectorSpeechTests`/`SpeechCoordinatorTests` still green; their `speechStarted` calls use the defaulted envelope).

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/SceneTypes.swift Sources/Core/Director.swift Sources/Speech/SpeechCoordinator.swift App/AppDelegate.swift Tests/DirectorSpeechTests.swift
git commit -m "feat: SceneState.level — smoothed voice amplitude from the TTS envelope

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: `WaveformConfig` (config)

**Files:**
- Modify: `Sources/Core/Config.swift` (`WaveformConfig`, `RippleConfig`, `ZielConfig`)
- Modify: `config.example.json`
- Test: `Tests/ConfigTests.swift`

**Interfaces:**
- Produces: `ZielConfig.waveform: WaveformConfig`; `WaveformConfig { enabled: Bool; ripple: RippleConfig }`; `RippleConfig { enabled: Bool; strength: Double; speed: Double }`. Defaults: `enabled true`, `ripple.enabled true`, `strength 0.10`, `speed 2.0`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ConfigTests.swift` (before the final closing brace):

```swift
    func testWaveformDefaults() {
        let c = ZielConfig()
        XCTAssertTrue(c.waveform.enabled)
        XCTAssertTrue(c.waveform.ripple.enabled)
        XCTAssertEqual(c.waveform.ripple.strength, 0.10, accuracy: 1e-9)
        XCTAssertEqual(c.waveform.ripple.speed, 2.0, accuracy: 1e-9)
    }

    func testWaveformPartialDecodeKeepsDefaults() throws {
        let json = #"{"waveform":{"ripple":{"strength":0.4}}}"#
        let c = try ZielConfig.decode(Data(json.utf8))
        XCTAssertTrue(c.waveform.enabled)
        XCTAssertTrue(c.waveform.ripple.enabled)
        XCTAssertEqual(c.waveform.ripple.strength, 0.4, accuracy: 1e-9)
        XCTAssertEqual(c.waveform.ripple.speed, 2.0, accuracy: 1e-9)
    }

    func testWaveformDisableDecodes() throws {
        let c = try ZielConfig.decode(Data(#"{"waveform":{"enabled":false}}"#.utf8))
        XCTAssertFalse(c.waveform.enabled)
    }
```

- [ ] **Step 2: Run to verify it fails**

Run: `xcodebuild -project ZielVanSebastian.xcodeproj -scheme ZielVanSebastian -destination 'platform=macOS' -only-testing:CoreTests/ConfigTests test`
Expected: FAIL to compile — `value of type 'ZielConfig' has no member 'waveform'`.

- [ ] **Step 3: Implement**

In `Sources/Core/Config.swift`, add these two structs (near `SpeechConfig`):

```swift
public struct RippleConfig: Codable, Equatable {
    public var enabled: Bool = true
    public var strength: Double = 0.10
    public var speed: Double = 2.0
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        strength = try c.decodeIfPresent(Double.self, forKey: .strength) ?? strength
        speed = try c.decodeIfPresent(Double.self, forKey: .speed) ?? speed
    }
}

public struct WaveformConfig: Codable, Equatable {
    public var enabled: Bool = true
    public var ripple: RippleConfig = RippleConfig()
    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        ripple = try c.decodeIfPresent(RippleConfig.self, forKey: .ripple) ?? ripple
    }
}
```

In `ZielConfig`, add the stored property (after `speech`):

```swift
    public var waveform: WaveformConfig = WaveformConfig()
```

and in `ZielConfig.init(from:)`, after the `speech = …` line, add:

```swift
        waveform = try c.decodeIfPresent(WaveformConfig.self, forKey: .waveform) ?? waveform
```

In `config.example.json`, add a top-level section (sibling of `"speech"`):

```json
  "waveform": {
    "enabled": true,
    "ripple": { "enabled": true, "strength": 0.10, "speed": 2.0 }
  }
```

- [ ] **Step 4: Run to verify it passes**

Run: `xcodebuild -project ZielVanSebastian.xcodeproj -scheme ZielVanSebastian -destination 'platform=macOS' -only-testing:CoreTests/ConfigTests test`
Expected: PASS.

- [ ] **Step 5: Full suite**

Run: `make test` — Expected: 0 failures.

- [ ] **Step 6: Commit**

```bash
git add Sources/Core/Config.swift config.example.json Tests/ConfigTests.swift
git commit -m "feat: WaveformConfig — waveform/ripple on-off + strength/speed (defaults 0.10/2.0)

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Halo rendering

**Files:**
- Modify: `Sources/Rendering/CRTPipeline.swift` (add `waveform` property)
- Modify: `Sources/Rendering/ScenePass.swift` (`drawHalo`)
- Modify: `Sources/Rendering/ZielRenderer.swift` (`drawScene` `.speaking`)
- Modify: `App/AppDelegate.swift` (set + live-reload `renderer.crt.waveform`)

**Interfaces:**
- Consumes: `SceneState.level` (Task 3), `WaveformConfig` (Task 4).
- Produces: `ScenePass.drawHalo(encoder:viewW:viewH:level:tint:)`; `CRTPipeline.waveform: WaveformConfig` (read by the renderer to gate the halo and, in Task 6, the ripple).

No unit tests — Metal/AppKit. Gate: `make build` succeeds + on-device checklist.

- [ ] **Step 1: Add `waveform` to `CRTPipeline`**

In `Sources/Rendering/CRTPipeline.swift`, add a stored property just below `var shaderConfig: ShaderConfig`:

```swift
    /// Live-reloaded by the config watcher (halo + ripple gating).
    var waveform: WaveformConfig = WaveformConfig()
```

- [ ] **Step 2: Add `drawHalo` to `ScenePass`**

In `Sources/Rendering/ScenePass.swift`, add this method to the class (e.g. after `drawFace`). It builds circle geometry in view-pixel space (so rings stay round despite non-square NDC) and draws with the existing flat pipeline:

```swift
    /// Concentric phosphor rings centered in the view; radius/brightness driven
    /// by `level` (0…1). Drawn in the scene pass so CRT bloom picks it up.
    func drawHalo(encoder: MTLRenderCommandEncoder, viewW: Double, viewH: Double,
                  level: Double, tint: ColorRGB) {
        guard level > 0.001, viewW > 0, viewH > 0 else { return }
        let cx = viewW / 2, cy = viewH / 2, minDim = min(viewW, viewH)
        let segments = 96
        encoder.setRenderPipelineState(flatPipeline)
        for k in 0..<3 {
            let radius = minDim * 0.20 + Double(k) * minDim * 0.055 + level * minDim * 0.16
            let thickness = max(1.0, 2.4 - Double(k) * 0.5)
            let alpha = min(1.0, (0.5 - Double(k) * 0.13) * (0.4 + 0.6 * level))
            guard alpha > 0.001 else { continue }
            func ndc(_ ang: Double, _ r: Double) -> (Float, Float) {
                let px = cx + cos(ang) * r, py = cy + sin(ang) * r
                return (Float(px / viewW * 2 - 1), Float(1 - py / viewH * 2))
            }
            var verts: [Float] = []
            for i in 0..<segments {
                let a0 = Double(i) / Double(segments) * 2 * .pi
                let a1 = Double(i + 1) / Double(segments) * 2 * .pi
                let (ix0, iy0) = ndc(a0, radius - thickness / 2)
                let (ox0, oy0) = ndc(a0, radius + thickness / 2)
                let (ix1, iy1) = ndc(a1, radius - thickness / 2)
                let (ox1, oy1) = ndc(a1, radius + thickness / 2)
                verts += [ix0, iy0, ox0, oy0, ix1, iy1,
                          ox0, oy0, ox1, oy1, ix1, iy1]
            }
            var color: [Float] = [Float(tint.r), Float(tint.g), Float(tint.b), Float(alpha)]
            encoder.setVertexBytes(verts, length: verts.count * MemoryLayout<Float>.size, index: 0)
            encoder.setFragmentBytes(&color, length: 16, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count / 2)
        }
    }
```

- [ ] **Step 3: Draw the halo in `.speaking`**

In `Sources/Rendering/ZielRenderer.swift`, `drawScene`, the `.speaking` case currently starts with `if let word = scene.word {`. Insert the halo draw at the very top of the `.speaking` case, before that `if`:

```swift
        case .speaking:
            if crt.waveform.enabled {
                scenePass.drawHalo(encoder: encoder, viewW: viewW, viewH: viewH,
                                   level: scene.level, tint: scene.tint)
            }
            if let word = scene.word {
```

(Leave the rest of the `.speaking` body unchanged.)

- [ ] **Step 4: Wire the config into the renderer**

In `App/AppDelegate.swift`:

1. In `applicationDidFinishLaunching`, right after `self.renderer = renderer`, add:

```swift
        renderer.crt.waveform = config.waveform
```

2. In `watchConfig`’s event handler, next to the existing `renderer.crt.shaderConfig = freshLook.shader`, add:

```swift
                renderer.crt.waveform = fresh.waveform
```

- [ ] **Step 5: Build**

Run: `make build` — Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: On-device validation (record; not a merge blocker in CI)**

Deploy and confirm: during speech a halo of rings appears around the word and breathes with loudness; idle/thinking/offline unchanged; setting `waveform.enabled=false` in `config.json` removes the halo without restart.

- [ ] **Step 7: Commit**

```bash
git add Sources/Rendering/CRTPipeline.swift Sources/Rendering/ScenePass.swift Sources/Rendering/ZielRenderer.swift App/AppDelegate.swift
git commit -m "feat: radial halo around the speaking word, driven by SceneState.level

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Water-ripple distortion in the CRT shader

**Files:**
- Modify: `Sources/Rendering/Shaders.metal` (`CRTParams`, `composite_fragment`)
- Modify: `Sources/Rendering/CRTPipeline.swift` (`Params` ripple fields, stride assert, `run(level:)`)
- Modify: `Sources/Rendering/ZielRenderer.swift` (`draw` passes `level`)

**Interfaces:**
- Consumes: `SceneState.level` (Task 3), `CRTPipeline.waveform` (Task 5).
- Produces: `CRTPipeline.run(cmd:drawableRPD:time:level:)`.

No unit tests — Metal. Gate: `make build` + on-device.

- [ ] **Step 1: Update the MSL `CRTParams` struct**

In `Sources/Rendering/Shaders.metal`, replace the `CRTParams` struct (the `pad0`/`pad1` fields are removed; four ripple floats are added, keeping `float2 resolution` 8-byte aligned at offset 56):

```metal
struct CRTParams {
    float scanlineIntensity;
    float scanlinePitch;
    float maskIntensity;
    float bloomStrength;
    float curvature;
    float vignette;
    float flicker;
    float noise;
    float persistence;
    float time;
    float rippleStrength;
    float rippleSpeed;
    float rippleLevel;
    float rippleEnabled;
    float2 resolution;
};
```

- [ ] **Step 2: Add the ripple displacement in `composite_fragment`**

In `Sources/Rendering/Shaders.metal`, `composite_fragment`, the body currently reads (after the barrel + bounds check):

```metal
    float3 color = phosphor.sample(s, uv).rgb;
    color += bloom.sample(s, uv).rgb * p.bloomStrength;
```

Replace those two lines with:

```metal
    // Water ripple: radial UV displacement + faint chromatic split. Motion is
    // time-driven (never resets on words); intensity rides rippleLevel.
    float2 duv = float2(0.0);
    float2 dir = float2(0.0);
    float ca = 0.0;
    if (p.rippleEnabled > 0.5 && p.rippleLevel > 0.001) {
        float aspect = p.resolution.x / max(p.resolution.y, 1.0);
        float2 cc = uv - 0.5; cc.x *= aspect;
        float dist = length(cc);
        float wave = sin(dist * 42.0 - p.time * p.rippleSpeed);
        float fall = smoothstep(0.95, 0.0, dist);
        float amt = p.rippleStrength * (0.15 + 0.85 * p.rippleLevel) * fall;
        dir = dist > 1e-4 ? cc / dist : float2(0.0);
        dir.x /= aspect;
        duv = dir * wave * amt * 0.03;
        ca = amt * 0.006;
    }
    float3 color = float3(phosphor.sample(s, uv + duv + dir * ca).r,
                          phosphor.sample(s, uv + duv).g,
                          phosphor.sample(s, uv + duv - dir * ca).b);
    color += bloom.sample(s, uv + duv).rgb * p.bloomStrength;
```

(When the ripple is inactive, `duv`/`dir`/`ca` are zero, so the three samples fall on the same `uv` — identical to the previous behavior.)

- [ ] **Step 3: Update the Swift `Params` struct**

In `Sources/Rendering/CRTPipeline.swift`, replace the `Params` struct with (removes `pad0`/`pad1`, adds four ripple fields in the same order as MSL, `level`/config filled by `run`):

```swift
    /// MUST match the Metal CRTParams layout field-for-field.
    struct Params {
        var scanlineIntensity: Float
        var scanlinePitch: Float
        var maskIntensity: Float
        var bloomStrength: Float
        var curvature: Float
        var vignette: Float
        var flicker: Float
        var noise: Float
        var persistence: Float
        var time: Float
        var rippleStrength: Float = 0
        var rippleSpeed: Float = 0
        var rippleLevel: Float = 0
        var rippleEnabled: Float = 0
        var resolution: SIMD2<Float>

        init(_ c: ShaderConfig, time: Float, resolution: SIMD2<Float>) {
            scanlineIntensity = Float(c.scanlineIntensity)
            scanlinePitch = Float(c.scanlinePitch)
            maskIntensity = Float(c.maskIntensity)
            bloomStrength = Float(c.bloomStrength)
            curvature = Float(c.curvature)
            vignette = Float(c.vignette)
            flicker = Float(c.flicker)
            noise = Float(c.noise)
            persistence = Float(c.persistence)
            self.time = time
            self.resolution = resolution
        }
    }
```

- [ ] **Step 4: Update the stride assert**

In `CRTPipeline.init`, change:

```swift
        assert(MemoryLayout<Params>.stride == 56, "CRTParams layout drifted from Metal struct")
```

to:

```swift
        assert(MemoryLayout<Params>.stride == 64, "CRTParams layout drifted from Metal struct")
```

- [ ] **Step 5: Feed level + config into the params in `run`**

In `CRTPipeline.run`, change the signature:

```swift
    func run(cmd: MTLCommandBuffer, drawableRPD: MTLRenderPassDescriptor, time: Float) {
```

to:

```swift
    func run(cmd: MTLCommandBuffer, drawableRPD: MTLRenderPassDescriptor, time: Float, level: Float) {
```

and immediately after `var params = Params(...)` (the existing construction), add:

```swift
        params.rippleEnabled = (waveform.enabled && waveform.ripple.enabled) ? 1 : 0
        params.rippleStrength = Float(waveform.ripple.strength)
        params.rippleSpeed = Float(waveform.ripple.speed)
        params.rippleLevel = level
```

- [ ] **Step 6: Pass `level` from the renderer**

In `Sources/Rendering/ZielRenderer.swift`, `draw`, change:

```swift
        crt.run(cmd: cmd, drawableRPD: drawableRPD, time: Float(now))
```

to:

```swift
        crt.run(cmd: cmd, drawableRPD: drawableRPD, time: Float(now), level: Float(scene.level))
```

- [ ] **Step 7: Build**

Run: `make build` — Expected: `** BUILD SUCCEEDED **` (the `assert` compiles; if it trips at runtime the layout drifted — recheck field order/count).

- [ ] **Step 8: On-device validation (record; not a CI blocker)**

Deploy and confirm: during speech the whole surface ripples like water, subtle at the defaults (strength 0.10, speed 2.0), flowing continuously through the fast RSVP words and easing out when speech ends; `config.json` edits to `waveform.ripple.strength`/`speed` retune live; `waveform.ripple.enabled=false` stops the ripple but keeps the halo; `waveform.enabled=false` stops both.

- [ ] **Step 9: Commit**

```bash
git add Sources/Rendering/Shaders.metal Sources/Rendering/CRTPipeline.swift Sources/Rendering/ZielRenderer.swift
git commit -m "feat: water-ripple CRT displacement driven by the speaking level

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**
- Continuous envelope from real PCM (spec §"Key Behavior", §"Components 1") → Task 1 + Task 2. ✓
- Level sampling by audio clock + attack/release smoothing + word-cadence independence (spec §"Components 2") → Task 3 (`speakingLevel` + smoothing; `testLevelContinuousAcrossWordChanges`). ✓
- Halo in scene pass (spec §"Components 3") → Task 5. ✓
- Ripple as CRT-shader displacement (spec §"Components 3") → Task 6. ✓
- Config `waveform.enabled` / `ripple.enabled` / `strength 0.10` / `speed 2.0`, live-reloadable, default on (spec §"Components 4") → Task 4 (defaults/decoding) + Tasks 5–6 (renderer gating + live reload via `watchConfig`). ✓
- Testing split — Core unit-tested, Metal build+on-device (spec §"Testing") → Tasks 1–4 unit; 5–6 build+on-device. ✓
- Scope guards — speaking-state only (halo drawn only in `.speaking`; `level` 0 otherwise), face geometry untouched (halo is separate geometry). ✓

**Placeholder scan:** none — every code step has complete code; the two Metal tasks have exact struct + shader edits; on-device steps are explicit checklists (per the spec's testing approach).

**Type consistency:** `AmplitudeEnvelope.from(pcm:sampleRate:rate:)` (Task 1) called identically in Task 2. `SpokenAudio.envelope`/`envelopeRate` (Task 2) consumed by `SpeechCoordinator` (Task 3c) and `Director.speechStarted(id:words:envelope:envelopeRate:now:)` (Task 3b). `SceneState.level` (Task 3a) read in `ZielRenderer.drawScene` (Task 5) and passed to `crt.run(…level:)` (Task 6). `CRTPipeline.waveform: WaveformConfig` (Task 5) uses `WaveformConfig`/`RippleConfig` from Task 4 and is read in `run` (Task 6). MSL `CRTParams` (Task 6 Step 1) and Swift `Params` (Task 6 Step 3) declare the same 14 floats + `resolution` in the same order; stride assert updated to 64 (Step 4).
