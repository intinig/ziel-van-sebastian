# Voice Gateway Phase 2a Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The VoiceGateway service — a separate local process that hears "Sebastian, …" through the mic, transcribes it locally, and emits transcript events over a loopback WebSocket. End of 2a: a complete, testable voice service (whisper-prefix wake, no ONNX); Phase 3 wires it to the app.

**Architecture:** `VoiceGateway` CLI (new tool target) = AVAudioEngine capture → Silero VAD (built into whisper.cpp) → pure utterance segmenter (Core) → whisper.cpp STT → wake-word gate → events on `ws://127.0.0.1:18790`. Pure logic (protocol codec, wake parser, segmenter) lives in Core/VoiceGatewayKit and is CoreTests-hermetic; everything touching vendored whisper libs lives in `Sources/VoiceGatewaySTT` behind a separate opt-in test target.

**Tech Stack:** Swift 5.10 (macOS 15), whisper.cpp **v1.9.1** vendored as cmake-built static libs (Metal embedded), Network.framework WS server (MockGatewayKit pattern), AVAudioEngine + CoreAudio device selection, XcodeGen + xcodebuild, XCTest.

**Spec:** `docs/superpowers/specs/2026-07-01-voice-gateway-design.md` (incl. the 2026-07-02 addendum — spike results this plan is built on).

## Global Constraints

- **Swift language mode 5.10**, macOS deployment target **15.0** (`project.yml` — do not bump).
- **Core is platform-free and clock-injected** — no `Date()`; time enters as parameters. The segmenter counts *frames*, not seconds, precisely to stay clock-free.
- **Voice must never block the face** — the service degrades (logs + `error` events), never crashes the pipeline; the app is not touched in this phase.
- **`make test` (CoreTests) stays hermetic** — nothing in CoreTests may link vendored libs. Whisper-linked tests live only in the opt-in `VoiceGatewayTests` target (`make test-voice`).
- **`.xcodeproj` is generated (XcodeGen)** — edit `project.yml` only. **`Vendor/` is gitignored**; `scripts/vendor-whisper.sh` reproduces it.
- **Local WS has no auth by design** (loopback-only, single-user appliance — recorded in the spec addendum).
- Spike-verified facts to use verbatim: whisper.cpp pin **v1.9.1**; link recipe `-lwhisper -lggml -lggml-base -lggml-cpu -lggml-blas -lggml-metal -lc++` + frameworks `Metal MetalKit Accelerate Foundation`; VAD API `whisper_vad_init_from_file_with_params` / `whisper_vad_detect_speech_no_reset` / `whisper_vad_probs`; STT `whisper_init_from_file_with_params` + `whisper_full` (greedy, `no_timestamps`).

---

### Task 1: Vendoring + targets (`scripts/vendor-whisper.sh`, `project.yml`, Makefile)

**Files:**
- Create: `scripts/vendor-whisper.sh`, `scripts/fetch-voice-models.sh`, `VoiceGateway/main.swift` (minimal smoke main, replaced in Task 8), `Sources/VoiceGatewaySTT/.gitkeep`
- Modify: `project.yml`, `Makefile`, `.gitignore`

**Interfaces:**
- Produces: gitignored `Vendor/whisper/{lib,include}` (+ `include/module.modulemap` exposing C module `CWhisper`); targets `VoiceGateway` (tool) and `VoiceGatewayTests` (unit-test, opt-in); `make vendor`, `make test-voice`; models fetched to `~/Library/Application Support/Ziel van Sebastian/models/`.

- [ ] **Step 1: `scripts/vendor-whisper.sh`**

```bash
#!/bin/bash
# Builds whisper.cpp v1.9.1 as static libs (Metal embedded) into Vendor/whisper/.
# Vendor/ is gitignored; run once per checkout (make vendor).
set -euo pipefail
cd "$(dirname "$0")/.."
PIN=v1.9.1
BUILD=.vendor-build/whisper.cpp
if [ ! -d "$BUILD" ]; then
  mkdir -p .vendor-build
  git clone --depth 1 --branch "$PIN" https://github.com/ggml-org/whisper.cpp.git "$BUILD"
fi
cmake -S "$BUILD" -B "$BUILD/build" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
  -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON \
  -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF
cmake --build "$BUILD/build" -j "$(sysctl -n hw.ncpu)"
mkdir -p Vendor/whisper/lib Vendor/whisper/include
cp "$BUILD/build/src/libwhisper.a" Vendor/whisper/lib/
find "$BUILD/build/ggml" -name 'libggml*.a' -exec cp {} Vendor/whisper/lib/ \;
cp "$BUILD/include/whisper.h" "$BUILD"/ggml/include/ggml*.h Vendor/whisper/include/
cat > Vendor/whisper/include/module.modulemap <<'EOF'
module CWhisper {
    header "whisper.h"
    export *
}
EOF
echo "vendored: $(ls Vendor/whisper/lib)"
```

- [ ] **Step 2: `scripts/fetch-voice-models.sh`**

```bash
#!/bin/bash
# Downloads whisper + VAD models to the app-support models dir (idempotent).
set -euo pipefail
DIR="$HOME/Library/Application Support/Ziel van Sebastian/models"
mkdir -p "$DIR"
[ -f "$DIR/ggml-base.en.bin" ] || curl -L -o "$DIR/ggml-base.en.bin" \
  "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin"
[ -f "$DIR/ggml-silero-v5.1.2.bin" ] || curl -L -o "$DIR/ggml-silero-v5.1.2.bin" \
  "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin"
ls -lh "$DIR"
```
(If the silero URL 404s, take the URL from `models/download-vad-model.sh` in the pinned checkout under `.vendor-build/` — record the working one in this script.)

- [ ] **Step 3: `project.yml` — add targets + shared link settings**

Add to `targets:` (mirror `MockGateway`'s shape). `VOICE_LINK` settings shown inline on both targets:

```yaml
  VoiceGateway:
    type: tool
    platform: macOS
    sources:
      - VoiceGateway
      - Sources/Core
      - Sources/VoiceGatewayKit
      - Sources/VoiceGatewaySTT
    settings:
      base:
        PRODUCT_NAME: voice-gateway
        SWIFT_INCLUDE_PATHS: $(PROJECT_DIR)/Vendor/whisper/include
        LIBRARY_SEARCH_PATHS: $(PROJECT_DIR)/Vendor/whisper/lib
        OTHER_LDFLAGS: "-lwhisper -lggml -lggml-base -lggml-cpu -lggml-blas -lggml-metal -lc++ -framework Metal -framework MetalKit -framework Accelerate -framework AVFoundation -framework CoreAudio"
  VoiceGatewayTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - TestsVoice
      - Sources/Core
      - Sources/VoiceGatewayKit
      - Sources/VoiceGatewaySTT
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
        SWIFT_INCLUDE_PATHS: $(PROJECT_DIR)/Vendor/whisper/include
        LIBRARY_SEARCH_PATHS: $(PROJECT_DIR)/Vendor/whisper/lib
        OTHER_LDFLAGS: "-lwhisper -lggml -lggml-base -lggml-cpu -lggml-blas -lggml-metal -lc++ -framework Metal -framework MetalKit -framework Accelerate -framework AVFoundation -framework CoreAudio"
```

Also: add `- Sources/VoiceGatewayKit` to `CoreTests.sources` (it has no whisper linkage), and a scheme:

```yaml
  VoiceGatewayTests:
    build:
      targets:
        VoiceGateway: all
        VoiceGatewayTests: all
    test:
      targets:
        - VoiceGatewayTests
```

- [ ] **Step 4: Makefile + .gitignore**

Makefile additions (match existing style):
```makefile
vendor: ## Build whisper.cpp static libs into Vendor/ (one-time)
	[ -d Vendor/whisper/lib ] || ./scripts/vendor-whisper.sh

models: ## Fetch whisper + VAD models to Application Support
	./scripts/fetch-voice-models.sh

test-voice: vendor gen ## Opt-in voice tests (needs Vendor/ + models)
	xcodebuild -project ZielVanSebastian.xcodeproj -scheme VoiceGatewayTests -destination 'platform=macOS' test | tail -20
```
`.gitignore`: add `Vendor/` and `.vendor-build/`.

- [ ] **Step 5: minimal `VoiceGateway/main.swift` smoke (replaced in Task 8)**

```swift
import CWhisper
print("voice-gateway smoke:", String(cString: whisper_print_system_info()))
```

- [ ] **Step 6: Verify**

Run: `chmod +x scripts/*.sh && make vendor && make gen && xcodebuild -project ZielVanSebastian.xcodeproj -scheme ZielVanSebastian build 2>&1 | tail -3 && xcodebuild -project ZielVanSebastian.xcodeproj -scheme VoiceGatewayTests build 2>&1 | tail -3`
Expected: both BUILD SUCCEEDED. Then `make test` — CoreTests still green **without** Vendor/ being required (verify by the fact CoreTests target has no new settings).

- [ ] **Step 7: Commit**
```bash
git add scripts/vendor-whisper.sh scripts/fetch-voice-models.sh project.yml Makefile .gitignore VoiceGateway/main.swift Sources/VoiceGatewaySTT/.gitkeep
git commit -m "feat: VoiceGateway target + vendored whisper.cpp v1.9.1 toolchain"
```

---

### Task 2: `VoiceProtocol` codec + `vadModelPath` config (Core, TDD)

**Files:**
- Create: `Sources/Core/VoiceProtocol.swift`
- Modify: `Sources/Core/Config.swift` (add `vadModelPath` to `VoiceConfig`), `config.example.json`
- Test: `Tests/VoiceProtocolTests.swift`, `Tests/ConfigTests.swift`

**Interfaces:**
- Produces:
  - `enum VoiceEvent: Equatable { case ready(version: Int), wake, listening, vad(speaking: Bool), heard(text: String), error(message: String) }`
  - `enum VoiceCommand: Equatable { case mode(WakeMode), stop }`
  - `enum VoiceProtocol { static func encode(_ e: VoiceEvent) -> Data; static func decodeEvent(_ d: Data) -> VoiceEvent?; static func encode(_ c: VoiceCommand) -> Data; static func decodeCommand(_ d: Data) -> VoiceCommand? }`
  - `VoiceConfig.vadModelPath: String = ""`

- [ ] **Step 1: Failing tests** — `Tests/VoiceProtocolTests.swift`:

```swift
import XCTest

final class VoiceProtocolTests: XCTestCase {
    func testEventRoundTrips() {
        let events: [VoiceEvent] = [.ready(version: 1), .wake, .listening,
                                    .vad(speaking: true), .vad(speaking: false),
                                    .heard(text: "what's the weather"), .error(message: "mic denied")]
        for e in events {
            XCTAssertEqual(VoiceProtocol.decodeEvent(VoiceProtocol.encode(e)), e)
        }
    }
    func testCommandRoundTrips() {
        for c in [VoiceCommand.mode(.armed), .mode(.listen), .mode(.speaking), .mode(.followUp), .stop] {
            XCTAssertEqual(VoiceProtocol.decodeCommand(VoiceProtocol.encode(c)), c)
        }
    }
    func testWireFormatIsStable() {
        // Pin the wire format so both sides can evolve independently.
        let d = VoiceProtocol.encode(VoiceEvent.heard(text: "hi"))
        let obj = try! JSONSerialization.jsonObject(with: d) as! [String: Any]
        XCTAssertEqual(obj["event"] as? String, "heard")
        XCTAssertEqual(obj["text"] as? String, "hi")
        let c = VoiceProtocol.encode(VoiceCommand.mode(.followUp))
        let cobj = try! JSONSerialization.jsonObject(with: c) as! [String: Any]
        XCTAssertEqual(cobj["cmd"] as? String, "mode")
        XCTAssertEqual(cobj["mode"] as? String, "followup")
    }
    func testGarbageDecodesToNil() {
        XCTAssertNil(VoiceProtocol.decodeEvent(Data("junk".utf8)))
        XCTAssertNil(VoiceProtocol.decodeCommand(Data("{\"cmd\":\"nope\"}".utf8)))
    }
}
```
In `Tests/ConfigTests.swift`, extend `testVoiceDefaults` with `XCTAssertEqual(c.voice.vadModelPath, "")` and `testVoicePartialDecode` unchanged-default check.

- [ ] **Step 2: Run** `make test` — expected FAIL (`cannot find 'VoiceProtocol'`).

- [ ] **Step 3: Implement** `Sources/Core/VoiceProtocol.swift`:

```swift
import Foundation

public enum VoiceEvent: Equatable {
    case ready(version: Int)
    case wake
    case listening
    case vad(speaking: Bool)
    case heard(text: String)
    case error(message: String)
}

public enum VoiceCommand: Equatable {
    case mode(WakeMode)
    case stop
}

/// JSON wire codec for the loopback voice-gateway WebSocket. Both the service
/// and the app use exactly this; the wire format is pinned by tests.
public enum VoiceProtocol {
    static let modeNames: [(WakeMode, String)] = [
        (.armed, "armed"), (.listen, "listen"), (.speaking, "speaking"), (.followUp, "followup"),
    ]

    public static func encode(_ e: VoiceEvent) -> Data {
        let obj: [String: Any]
        switch e {
        case .ready(let v):   obj = ["event": "ready", "version": v]
        case .wake:           obj = ["event": "wake"]
        case .listening:      obj = ["event": "listening"]
        case .vad(let s):     obj = ["event": "vad", "speaking": s]
        case .heard(let t):   obj = ["event": "heard", "text": t]
        case .error(let m):   obj = ["event": "error", "message": m]
        }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    public static func decodeEvent(_ d: Data) -> VoiceEvent? {
        guard let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        switch obj["event"] as? String {
        case "ready":     return (obj["version"] as? Int).map { .ready(version: $0) }
        case "wake":      return .wake
        case "listening": return .listening
        case "vad":       return (obj["speaking"] as? Bool).map { .vad(speaking: $0) }
        case "heard":     return (obj["text"] as? String).map { .heard(text: $0) }
        case "error":     return (obj["message"] as? String).map { .error(message: $0) }
        default:          return nil
        }
    }

    public static func encode(_ c: VoiceCommand) -> Data {
        let obj: [String: Any]
        switch c {
        case .mode(let m): obj = ["cmd": "mode", "mode": modeNames.first { $0.0 == m }!.1]
        case .stop:        obj = ["cmd": "stop"]
        }
        return try! JSONSerialization.data(withJSONObject: obj)
    }

    public static func decodeCommand(_ d: Data) -> VoiceCommand? {
        guard let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        switch obj["cmd"] as? String {
        case "mode": return (obj["mode"] as? String).flatMap { n in modeNames.first { $0.1 == n }.map { .mode($0.0) } }
        case "stop": return .stop
        default:     return nil
        }
    }
}
```
Config: add `public var vadModelPath: String = ""` to `VoiceConfig` (+ `decodeIfPresent` line) and `"vadModelPath": ""` to `config.example.json`'s voice block.

- [ ] **Step 4: Run** `make test` — PASS. **Step 5: Commit** (`feat: VoiceProtocol wire codec + vadModelPath config`).

---

### Task 3: `WakeWordParser` (Core, TDD)

**Files:** Create `Sources/Core/WakeWordParser.swift`; Test `Tests/WakeWordParserTests.swift`.

**Interfaces:**
- Produces: `enum WakeWordParser { static func match(transcript: String, wakeWord: String) -> String? }` — returns the command remainder (possibly `""` for wake-only) when the transcript begins with the wake word, else `nil`.

- [ ] **Step 1: Failing tests**

```swift
import XCTest

final class WakeWordParserTests: XCTestCase {
    func testMatchesAndStrips() {
        XCTAssertEqual(WakeWordParser.match(transcript: "Sebastian, what's the weather?", wakeWord: "Sebastian"),
                       "what's the weather?")
        XCTAssertEqual(WakeWordParser.match(transcript: " sebastian.  turn it up ", wakeWord: "Sebastian"),
                       "turn it up")
        XCTAssertEqual(WakeWordParser.match(transcript: "SEBASTIAN", wakeWord: "Sebastian"), "")
        XCTAssertEqual(WakeWordParser.match(transcript: "Sebastián, hola", wakeWord: "Sebastian"), "hola")
    }
    func testRejectsNonWake() {
        XCTAssertNil(WakeWordParser.match(transcript: "hey there Sebastian", wakeWord: "Sebastian"))
        XCTAssertNil(WakeWordParser.match(transcript: "sebastians car", wakeWord: "Sebastian"))
        XCTAssertNil(WakeWordParser.match(transcript: "", wakeWord: "Sebastian"))
    }
}
```

- [ ] **Step 2: Run** `make test` — FAIL. **Step 3: Implement**

```swift
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
        return rest.trimmingCharacters(in: CharacterSet.punctuationCharacters
            .union(.whitespacesAndNewlines))
    }
}
```

- [ ] **Step 4: Run** `make test` — PASS. **Step 5: Commit** (`feat: WakeWordParser — leading wake-word match/strip`).

---

### Task 4: `UtteranceSegmenter` (Core, TDD)

Pure, frame-based state machine over per-frame speech probabilities. One `push` = one 512-sample (32 ms) frame. Buffers frames itself (incl. pre-roll) and emits the finished utterance's samples.

**Files:** Create `Sources/Core/UtteranceSegmenter.swift`; Test `Tests/UtteranceSegmenterTests.swift`.

**Interfaces:**
- Produces:
  - `struct SegmenterConfig { startThreshold: Float = 0.6; endThreshold: Float = 0.35; startFrames: Int = 3; hangoverFrames: Int = 25; maxFrames: Int = 940; preRollFrames: Int = 10 }`
  - `final class UtteranceSegmenter { init(config:); enum Event: Equatable { case started, utterance([Float]) }; func push(frame: [Float], prob: Float) -> Event?; func reset(); var isOpen: Bool }`

- [ ] **Step 1: Failing tests**

```swift
import XCTest

final class UtteranceSegmenterTests: XCTestCase {
    // Tiny 1-sample "frames" keep tests readable; the machine only counts frames.
    private func seg(_ c: SegmenterConfig = SegmenterConfig()) -> UtteranceSegmenter { UtteranceSegmenter(config: c) }
    private var cfg: SegmenterConfig {
        var c = SegmenterConfig(); c.startFrames = 2; c.hangoverFrames = 3; c.preRollFrames = 2; c.maxFrames = 10; return c
    }

    func testOpensAfterConsecutiveSpeechFramesWithPreRoll() {
        let s = seg(cfg)
        XCTAssertNil(s.push(frame: [1], prob: 0.1))   // pre-roll history
        XCTAssertNil(s.push(frame: [2], prob: 0.1))
        XCTAssertNil(s.push(frame: [3], prob: 0.9))   // 1st speech frame — not yet open
        XCTAssertEqual(s.push(frame: [4], prob: 0.9), .started)  // 2nd — opens
        XCTAssertTrue(s.isOpen)
    }

    func testClosesAfterHangoverAndEmitsSamplesIncludingPreRoll() {
        let s = seg(cfg)
        _ = s.push(frame: [1], prob: 0.1); _ = s.push(frame: [2], prob: 0.1)
        _ = s.push(frame: [3], prob: 0.9); _ = s.push(frame: [4], prob: 0.9)  // opens at [4]
        _ = s.push(frame: [5], prob: 0.9)
        XCTAssertNil(s.push(frame: [6], prob: 0.1))   // hangover 1
        XCTAssertNil(s.push(frame: [7], prob: 0.1))   // hangover 2
        guard case .utterance(let samples)? = s.push(frame: [8], prob: 0.1) else {  // hangover 3 → close
            return XCTFail("expected utterance")
        }
        XCTAssertEqual(samples, [1, 2, 3, 4, 5, 6, 7, 8])  // pre-roll [1,2] + speech + hangover
        XCTAssertFalse(s.isOpen)
    }

    func testSpeechInsideHangoverKeepsUtteranceOpen() {
        let s = seg(cfg)
        _ = s.push(frame: [1], prob: 0.9); _ = s.push(frame: [2], prob: 0.9)  // opens
        _ = s.push(frame: [3], prob: 0.1); _ = s.push(frame: [4], prob: 0.1)  // 2 silent
        XCTAssertNil(s.push(frame: [5], prob: 0.9))   // speech resets hangover
        XCTAssertTrue(s.isOpen)
    }

    func testHardCapCloses() {
        var c = cfg; c.maxFrames = 4
        let s = seg(c)
        _ = s.push(frame: [1], prob: 0.9); _ = s.push(frame: [2], prob: 0.9)  // open (2 frames so far)
        _ = s.push(frame: [3], prob: 0.9)
        guard case .utterance? = s.push(frame: [4], prob: 0.9) else { return XCTFail("expected cap close") }
        XCTAssertFalse(s.isOpen)
    }

    func testInterruptedStartRequiresConsecutive() {
        let s = seg(cfg)
        _ = s.push(frame: [1], prob: 0.9)             // 1 speech
        XCTAssertNil(s.push(frame: [2], prob: 0.1))   // broken streak
        XCTAssertNil(s.push(frame: [3], prob: 0.9))   // 1 again
        XCTAssertEqual(s.push(frame: [4], prob: 0.9), .started)
    }

    func testResetDropsEverything() {
        let s = seg(cfg)
        _ = s.push(frame: [1], prob: 0.9); _ = s.push(frame: [2], prob: 0.9)
        s.reset()
        XCTAssertFalse(s.isOpen)
        XCTAssertNil(s.push(frame: [9], prob: 0.1))
    }
}
```

- [ ] **Step 2: Run** `make test` — FAIL. **Step 3: Implement**

```swift
import Foundation

public struct SegmenterConfig: Equatable {
    public var startThreshold: Float = 0.6   // prob ≥ this counts as speech for opening
    public var endThreshold: Float = 0.35    // prob < this counts as silence for closing
    public var startFrames: Int = 3          // consecutive speech frames to open (~96 ms)
    public var hangoverFrames: Int = 25      // trailing silent frames to close (~800 ms)
    public var maxFrames: Int = 940          // hard cap (~30 s) so a stuck-open utterance can't grow unbounded
    public var preRollFrames: Int = 10       // frames of context kept before the opening frame (~320 ms)
    public init() {}
}

/// Pure utterance gate: pushes of (frame, speech-probability) in, utterances out.
/// Counts frames — no clocks — per the Core invariant.
public final class UtteranceSegmenter {
    public enum Event: Equatable { case started, utterance([Float]) }

    public private(set) var isOpen = false
    private let config: SegmenterConfig
    private var preRoll: [[Float]] = []
    private var current: [Float] = []
    private var frameCount = 0
    private var speechStreak = 0
    private var silenceStreak = 0

    public init(config: SegmenterConfig = SegmenterConfig()) { self.config = config }

    public func push(frame: [Float], prob: Float) -> Event? {
        if !isOpen {
            preRoll.append(frame)
            if preRoll.count > config.preRollFrames + config.startFrames { preRoll.removeFirst() }
            speechStreak = prob >= config.startThreshold ? speechStreak + 1 : 0
            if speechStreak >= config.startFrames {
                isOpen = true
                current = preRoll.flatMap { $0 }
                frameCount = preRoll.count
                preRoll = []
                speechStreak = 0
                silenceStreak = 0
                return .started
            }
            return nil
        }
        current += frame
        frameCount += 1
        silenceStreak = prob < config.endThreshold ? silenceStreak + 1 : 0
        if silenceStreak >= config.hangoverFrames || frameCount >= config.maxFrames {
            let samples = current
            resetInternal()
            return .utterance(samples)
        }
        return nil
    }

    public func reset() { resetInternal() }

    private func resetInternal() {
        isOpen = false
        preRoll = []; current = []
        frameCount = 0; speechStreak = 0; silenceStreak = 0
    }
}
```

- [ ] **Step 4: Run** `make test` — PASS (walk each test against the code first; the open-frame accounting in `testClosesAfterHangover…` is the subtle one). **Step 5: Commit** (`feat: UtteranceSegmenter — pure VAD-probability utterance gate`).

---

### Task 5: `VoiceGatewayServer` (VoiceGatewayKit — WS transport, CoreTests)

Pure transport: broadcasts `VoiceEvent`s to all connected clients, surfaces decoded `VoiceCommand`s. No audio, no whisper — tested inside CoreTests like MockGatewayKit.

**Files:** Create `Sources/VoiceGatewayKit/VoiceGatewayServer.swift`; Test `Tests/VoiceGatewayServerTests.swift`.

**Interfaces:**
- Produces: `final class VoiceGatewayServer { init(requestedPort: UInt16) throws; func start() throws; func stop(); var port: UInt16; var onCommand: ((VoiceCommand) -> Void)?; func broadcast(_ e: VoiceEvent) }` — sends `.ready(version: 1)` to each client on connect.

- [ ] **Step 1: Failing test** — connect with `URLSessionWebSocketTask` (same approach as `GatewayIntegrationTests`):

```swift
import XCTest

final class VoiceGatewayServerTests: XCTestCase {
    func testReadyBroadcastAndCommandRoundTrip() throws {
        let server = try VoiceGatewayServer(requestedPort: 0)
        try server.start()
        defer { server.stop() }

        var commands: [VoiceCommand] = []
        let gotCommand = expectation(description: "command")
        server.onCommand = { commands.append($0); gotCommand.fulfill() }

        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(server.port)")!)
        task.resume()

        // 1) ready arrives on connect
        let ready = expectation(description: "ready")
        task.receive { result in
            if case .success(.string(let s)) = result,
               VoiceProtocol.decodeEvent(Data(s.utf8)) == .ready(version: 1) { ready.fulfill() }
        }
        wait(for: [ready], timeout: 5)

        // 2) command in
        task.send(.string(String(decoding: VoiceProtocol.encode(VoiceCommand.mode(.listen)), as: UTF8.self))) { _ in }
        wait(for: [gotCommand], timeout: 5)
        XCTAssertEqual(commands, [.mode(.listen)])

        // 3) event broadcast reaches the client
        let heard = expectation(description: "heard")
        task.receive { result in
            if case .success(.string(let s)) = result,
               VoiceProtocol.decodeEvent(Data(s.utf8)) == .heard(text: "hi") { heard.fulfill() }
        }
        server.broadcast(.heard(text: "hi"))
        wait(for: [heard], timeout: 5)
        task.cancel(with: .goingAway, reason: nil)
    }
}
```

- [ ] **Step 2: Run** `make test` — FAIL. **Step 3: Implement** (mirrors `MockGatewayServer`'s listener/accept/receive-loop shape — same NWListener + `NWProtocolWebSocket.Options` with `autoReplyPing`, semaphore-bound `start()`, queue-confined `connections`, `prune` on cancel/fail; `send` uses a `.webSocket` text metadata context exactly as `MockGatewayServer.send` does):

```swift
import Foundation
import Network

/// Loopback WS server for the voice gateway: broadcasts VoiceEvents, receives
/// VoiceCommands. Pure transport — no audio or STT here. No auth by design
/// (loopback-only; see spec addendum).
public final class VoiceGatewayServer {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "voice-gateway-server")
    private var connections: [NWConnection] = []
    public private(set) var port: UInt16 = 0
    public var onCommand: ((VoiceCommand) -> Void)?

    public init(requestedPort: UInt16) throws {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        listener = try NWListener(using: params,
                                  on: requestedPort == 0 ? .any : NWEndpoint.Port(rawValue: requestedPort)!)
    }

    public func start() throws {
        let ready = DispatchSemaphore(value: 0)
        var startupError: Error?
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready: self?.port = self?.listener.port?.rawValue ?? 0; ready.signal()
            case .failed(let e): startupError = e; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut {
            throw NSError(domain: "VoiceGateway", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener never became ready"])
        }
        if let e = startupError { throw e }
    }

    public func stop() {
        listener.cancel()
        queue.sync { connections.forEach { $0.cancel() }; connections.removeAll() }
    }

    public func broadcast(_ e: VoiceEvent) {
        let data = VoiceProtocol.encode(e)
        queue.async { [weak self] in self?.connections.forEach { self?.send($0, data: data) } }
    }

    private func accept(_ conn: NWConnection) {
        connections.append(conn)
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            if case .cancelled = state { self?.prune(conn) }
            if case .failed = state { self?.prune(conn) }
        }
        conn.start(queue: queue)
        send(conn, data: VoiceProtocol.encode(VoiceEvent.ready(version: 1)))
        receiveLoop(conn)
    }

    private func prune(_ conn: NWConnection?) {
        guard let conn else { return }
        connections.removeAll { $0 === conn }
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receiveMessage { [weak self, weak conn] data, _, _, error in
            guard let self, let conn, error == nil else { return }
            if let data, let cmd = VoiceProtocol.decodeCommand(data) {
                self.onCommand?(cmd)
            }
            self.receiveLoop(conn)
        }
    }

    private func send(_ conn: NWConnection, data: Data) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "event", metadata: [meta])
        conn.send(content: data, contentContext: ctx, completion: .contentProcessed { _ in })
    }
}
```

- [ ] **Step 4: Run** `make test` — PASS (CoreTests picks up `Sources/VoiceGatewayKit` from Task 1's project.yml change). **Step 5: Commit** (`feat: VoiceGatewayServer — loopback WS event/command transport`).

---

### Task 6: `WhisperSTT` + `SileroVAD` wrappers (VoiceGatewaySTT; opt-in tests)

**Files:**
- Create: `Sources/VoiceGatewaySTT/WhisperSTT.swift`, `Sources/VoiceGatewaySTT/SileroVAD.swift`, `TestsVoice/WhisperSTTTests.swift`, `TestsVoice/Fixtures/sebastian-weather.wav` (generate: `say -o /tmp/f.aiff "Sebastian, what's the weather today?" && afconvert -f WAVE -d LEI16@16000 -c 1 /tmp/f.aiff TestsVoice/Fixtures/sebastian-weather.wav`)
- Modify: `project.yml` (`VoiceGatewayTests.sources` gains a resources ref for Fixtures — add `- path: TestsVoice` with `buildPhase: sources` default plus `Fixtures` via `type: folder` resource; simplest: list `TestsVoice/Fixtures` as a `resources` entry on the target)

**Interfaces:**
- Produces: `final class WhisperSTT { init(modelPath: String) throws; func transcribe(_ samples: [Float]) -> String }`; `final class SileroVAD { init(modelPath: String) throws; func speechProbability(frame512: [Float]) -> Float; func reset() }`

- [ ] **Step 1: Failing tests** (`TestsVoice/WhisperSTTTests.swift`; models resolved from Application Support, `XCTSkip` when absent so the target still runs on bare machines):

```swift
import XCTest

final class WhisperSTTTests: XCTestCase {
    private var modelsDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ziel van Sebastian/models")
    }
    private func fixtureSamples() throws -> [Float] {
        let url = Bundle(for: Self.self).url(forResource: "sebastian-weather", withExtension: "wav")!
        let wav = try Data(contentsOf: url)
        let pcm16 = wav.dropFirst(44).withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        return pcm16.map { Float($0) / 32768.0 }
    }

    func testTranscribesFixture() throws {
        let model = modelsDir.appendingPathComponent("ggml-base.en.bin").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: model), "run scripts/fetch-voice-models.sh")
        let stt = try WhisperSTT(modelPath: model)
        let text = stt.transcribe(try fixtureSamples()).lowercased()
        XCTAssertTrue(text.contains("sebastian"), "got: \(text)")
        XCTAssertTrue(text.contains("weather"), "got: \(text)")
    }

    func testVADSeparatesSpeechFromSilence() throws {
        let model = modelsDir.appendingPathComponent("ggml-silero-v5.1.2.bin").path
        try XCTSkipUnless(FileManager.default.fileExists(atPath: model), "run scripts/fetch-voice-models.sh")
        let vad = try SileroVAD(modelPath: model)
        let samples = try fixtureSamples()
        // Feed real audio frames; the last prob (mid-utterance) should read as speech.
        let silence = [Float](repeating: 0, count: 512)
        var speechProb: Float = 0
        for start in stride(from: 4096, to: 12288, by: 512) {   // warms the RNN state over real audio
            speechProb = vad.speechProbability(frame512: Array(samples[start..<start + 512]))
        }
        vad.reset()
        var silenceProb: Float = 1
        for _ in 0..<8 { silenceProb = vad.speechProbability(frame512: silence) }
        XCTAssertGreaterThan(speechProb, 0.5, "speech should score high")
        XCTAssertLessThan(silenceProb, 0.2, "silence should score low")
    }
}
```

- [ ] **Step 2: Run** `make test-voice` — FAIL (types missing). **Step 3: Implement**

`Sources/VoiceGatewaySTT/WhisperSTT.swift`:
```swift
import Foundation
import CWhisper

/// Thin wrapper over whisper.cpp full-transcription. One instance = one loaded
/// model (load ~70 ms for base.en; keep it alive for the process lifetime).
public final class WhisperSTT {
    private let ctx: OpaquePointer

    public init(modelPath: String) throws {
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            throw NSError(domain: "WhisperSTT", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "failed to load model at \(modelPath)"])
        }
        self.ctx = ctx
    }

    deinit { whisper_free(ctx) }

    public func transcribe(_ samples: [Float]) -> String {
        // whisper wants ≥~1 s of audio; pad short utterances with trailing silence.
        var padded = samples
        if padded.count < 16000 { padded += [Float](repeating: 0, count: 16000 - padded.count) }
        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_special = false
        params.print_realtime = false
        params.no_timestamps = true
        let rc = padded.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        guard rc == 0 else { return "" }
        var out = ""
        for i in 0..<whisper_full_n_segments(ctx) {
            out += String(cString: whisper_full_get_segment_text(ctx, i))
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

`Sources/VoiceGatewaySTT/SileroVAD.swift`:
```swift
import Foundation
import CWhisper

/// Streaming Silero VAD via whisper.cpp's VAD API. Feed consecutive 512-sample
/// (32 ms @ 16 kHz) frames; the internal RNN state carries across calls until reset().
public final class SileroVAD {
    private let ctx: OpaquePointer

    public init(modelPath: String) throws {
        var params = whisper_vad_default_context_params()
        params.use_gpu = false   // tiny model; CPU avoids GPU contention with STT
        guard let ctx = whisper_vad_init_from_file_with_params(modelPath, params) else {
            throw NSError(domain: "SileroVAD", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "failed to load VAD model at \(modelPath)"])
        }
        self.ctx = ctx
    }

    deinit { whisper_vad_free(ctx) }

    public func speechProbability(frame512: [Float]) -> Float {
        let ok = frame512.withUnsafeBufferPointer { buf in
            whisper_vad_detect_speech_no_reset(ctx, buf.baseAddress, Int32(buf.count))
        }
        guard ok, whisper_vad_n_probs(ctx) > 0 else { return 0 }
        // Last probability corresponds to the most recent frame.
        return whisper_vad_probs(ctx)[Int(whisper_vad_n_probs(ctx)) - 1]
    }

    public func reset() { whisper_vad_reset_state(ctx) }
}
```

- [ ] **Step 4: Run** `make models && make test-voice` — PASS (2 tests; also confirm `make test` untouched/green). If the VAD probability assertions fail, print the observed probs and adjust the warm-up window (the fixture's speech starts ~0.3 s in) — do not weaken thresholds below 0.5/0.2 without noting why in the test. **Step 5: Commit** (`feat: WhisperSTT + SileroVAD wrappers over vendored whisper.cpp`) — include the fixture WAV.

---

### Task 7: `AudioCapture` (VoiceGatewaySTT — mic → 16 kHz mono frames)

**Files:** Create `Sources/VoiceGatewaySTT/AudioCapture.swift`. No unit test (hardware); verified in Task 8's on-device checklist.

**Interfaces:**
- Produces: `final class AudioCapture { init(deviceName: String?, onFrame: @escaping ([Float]) -> Void); func start() throws; func stop() }` — `onFrame` delivers consecutive 512-sample 16 kHz mono Float32 frames on a private serial queue. Throws a descriptive error if mic permission is denied or the named device is missing.

- [ ] **Step 1: Implement**

```swift
import Foundation
import AVFoundation
import CoreAudio

/// Mic capture → 16 kHz mono Float32, chunked into 512-sample VAD frames.
/// Device selection is by name substring (matches `voice.inputDevice`); empty → system default.
public final class AudioCapture {
    private let engine = AVAudioEngine()
    private let onFrame: ([Float]) -> Void
    private let deviceName: String?
    private let queue = DispatchQueue(label: "voice-audio")
    private var residue: [Float] = []

    public init(deviceName: String?, onFrame: @escaping ([Float]) -> Void) {
        self.deviceName = (deviceName?.isEmpty ?? true) ? nil : deviceName
        self.onFrame = onFrame
    }

    public func start() throws {
        try requestMicAccessSync()
        if let name = deviceName {
            guard let dev = Self.findInputDevice(named: name) else {
                throw NSError(domain: "AudioCapture", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "no input device matching \"\(name)\""])
            }
            var deviceID = dev
            let unit = engine.inputNode.audioUnit!
            let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                           kAudioUnitScope_Global, 0, &deviceID,
                                           UInt32(MemoryLayout<AudioDeviceID>.size))
            guard err == noErr else {
                throw NSError(domain: "AudioCapture", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "failed to select device (\(err))"])
            }
        }
        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000,
                                   channels: 1, interleaved: false)!
        guard let converter = AVAudioConverter(from: native, to: target) else {
            throw NSError(domain: "AudioCapture", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "no converter \(native) → 16k mono"])
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: native) { [weak self] buffer, _ in
            guard let self else { return }
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * 16000 / native.sampleRate + 32)
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            guard let ch = out.floatChannelData, out.frameLength > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: ch[0], count: Int(out.frameLength)))
            self.queue.async { self.chunk(samples) }
        }
        try engine.start()
    }

    public func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        queue.sync { residue = [] }
    }

    private func chunk(_ samples: [Float]) {
        residue += samples
        while residue.count >= 512 {
            onFrame(Array(residue.prefix(512)))
            residue.removeFirst(512)
        }
    }

    private func requestMicAccessSync() throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return
        case .notDetermined:
            let sem = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { granted = $0; sem.signal() }
            sem.wait()
            if granted { return }
            fallthrough
        default:
            throw NSError(domain: "AudioCapture", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "microphone access denied — grant it in System Settings → Privacy & Security → Microphone"])
        }
    }

    /// Case-insensitive substring match over input-capable CoreAudio devices.
    static func findInputDevice(named name: String) -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr
        else { return nil }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr
        else { return nil }
        for id in ids {
            var inputAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                       mScope: kAudioDevicePropertyScopeInput,
                                                       mElement: kAudioObjectPropertyElementMain)
            var cfgSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &inputAddr, 0, nil, &cfgSize) == noErr, cfgSize > 0 else { continue }
            let buf = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(cfgSize))
            defer { buf.deallocate() }
            guard AudioObjectGetPropertyData(id, &inputAddr, 0, nil, &cfgSize, buf) == noErr,
                  UnsafeMutableAudioBufferListPointer(buf).reduce(0, { $0 + Int($1.mNumberChannels) }) > 0
            else { continue }
            var nameAddr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName,
                                                      mScope: kAudioObjectPropertyScopeGlobal,
                                                      mElement: kAudioObjectPropertyElementMain)
            var cfName: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            guard withUnsafeMutablePointer(to: &cfName, { ptr in
                AudioObjectGetPropertyData(id, &nameAddr, 0, nil, &nameSize, ptr)
            }) == noErr else { continue }
            if (cfName as String).localizedCaseInsensitiveContains(name) { return id }
        }
        return nil
    }
}
```

- [ ] **Step 2: Verify it compiles**: `make gen && xcodebuild -project ZielVanSebastian.xcodeproj -scheme VoiceGatewayTests build 2>&1 | tail -3` — BUILD SUCCEEDED. **Step 3: Commit** (`feat: AudioCapture — mic → 16 kHz mono frames with device selection`).

---

### Task 8: CLI wiring (`VoiceGateway/main.swift`) — the pipeline

**Files:**
- Replace: `VoiceGateway/main.swift`
- Create: `Sources/VoiceGatewayKit/VoicePipeline.swift` (mode/wake gating logic — **pure**, CoreTests-testable with injected closures), `Tests/VoicePipelineTests.swift`

**Interfaces:**
- Consumes: everything above.
- Produces: `final class VoicePipeline { init(wakeWord: String, transcribe: @escaping ([Float]) -> String, emit: @escaping (VoiceEvent) -> Void); var mode: WakeMode; func segmenterEvent(_ e: UtteranceSegmenter.Event); func handle(_ c: VoiceCommand, resetSegmenter: () -> Void) }`

- [ ] **Step 1: Failing tests** (`Tests/VoicePipelineTests.swift` — pure; fake transcribe):

```swift
import XCTest

final class VoicePipelineTests: XCTestCase {
    private func make(transcript: String) -> (VoicePipeline, () -> [VoiceEvent]) {
        var events: [VoiceEvent] = []
        let p = VoicePipeline(wakeWord: "Sebastian",
                              transcribe: { _ in transcript },
                              emit: { events.append($0) })
        return (p, { events })
    }

    func testArmedIgnoresNonWakeSpeech() {
        let (p, events) = make(transcript: "just chatting in the room")
        p.segmenterEvent(.started)
        p.segmenterEvent(.utterance([0.1]))
        XCTAssertEqual(events(), [.vad(speaking: true), .vad(speaking: false)])  // no heard/wake
    }

    func testArmedWakeWithCommandEmitsWakeAndHeard() {
        let (p, events) = make(transcript: "Sebastian, what's the weather")
        p.segmenterEvent(.utterance([0.1]))
        XCTAssertEqual(events(), [.vad(speaking: false), .wake, .heard(text: "what's the weather")])
    }

    func testArmedWakeOnlyEmitsWakeAndListening() {
        let (p, events) = make(transcript: "Sebastian")
        p.segmenterEvent(.utterance([0.1]))
        XCTAssertEqual(events(), [.vad(speaking: false), .wake, .listening])
    }

    func testListenModeForwardsEverythingAndStripsStrayWakeWord() {
        let (p, events) = make(transcript: "Sebastian turn it up")
        p.mode = .listen
        p.segmenterEvent(.utterance([0.1]))
        XCTAssertEqual(events(), [.vad(speaking: false), .heard(text: "turn it up")])
    }

    func testListenModeForwardsPlainSpeech() {
        let (p, events) = make(transcript: "and tomorrow?")
        p.mode = .followUp
        p.segmenterEvent(.utterance([0.1]))
        XCTAssertEqual(events(), [.vad(speaking: false), .heard(text: "and tomorrow?")])
    }

    func testEmptyTranscriptEmitsNothing() {
        let (p, events) = make(transcript: "  ")
        p.mode = .listen
        p.segmenterEvent(.utterance([0.1]))
        XCTAssertEqual(events(), [.vad(speaking: false)])
    }

    func testModeCommandUpdatesModeAndStopResets() {
        let (p, _) = make(transcript: "x")
        var didReset = false
        p.handle(.mode(.speaking), resetSegmenter: {})
        XCTAssertEqual(p.mode, .speaking)
        p.handle(.stop, resetSegmenter: { didReset = true })
        XCTAssertTrue(didReset)
    }
}
```

- [ ] **Step 2: Run** `make test` — FAIL. **Step 3: Implement** `Sources/VoiceGatewayKit/VoicePipeline.swift`:

```swift
import Foundation

/// Mode-aware glue between the segmenter and the wire: decides which utterances
/// become events. Pure — audio, STT, and the WS server are injected/adjacent.
public final class VoicePipeline {
    public var mode: WakeMode = .armed
    private let wakeWord: String
    private let transcribe: ([Float]) -> String
    private let emit: (VoiceEvent) -> Void

    public init(wakeWord: String,
                transcribe: @escaping ([Float]) -> String,
                emit: @escaping (VoiceEvent) -> Void) {
        self.wakeWord = wakeWord
        self.transcribe = transcribe
        self.emit = emit
    }

    public func segmenterEvent(_ e: UtteranceSegmenter.Event) {
        switch e {
        case .started:
            emit(.vad(speaking: true))
        case .utterance(let samples):
            emit(.vad(speaking: false))
            let text = transcribe(samples).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            switch mode {
            case .armed:
                guard let command = WakeWordParser.match(transcript: text, wakeWord: wakeWord) else { return }
                emit(.wake)
                emit(command.isEmpty ? .listening : .heard(text: command))
            case .listen, .followUp, .speaking:
                // Strip a stray leading wake word so "Sebastian, X" mid-conversation still means X.
                let command = WakeWordParser.match(transcript: text, wakeWord: wakeWord) ?? text
                guard !command.isEmpty else { return }
                emit(.heard(text: command))
            }
        }
    }

    public func handle(_ c: VoiceCommand, resetSegmenter: () -> Void) {
        switch c {
        case .mode(let m): mode = m
        case .stop: resetSegmenter()
        }
    }
}
```

- [ ] **Step 4: Run** `make test` — PASS. **Step 5: Replace `VoiceGateway/main.swift`** (composition only — no logic):

```swift
import Foundation
import CWhisper

// voice-gateway: mic → VAD → segmenter → whisper → events on ws://127.0.0.1:<port>
// Reads the same config.json as the app (voice section). See docs/voice-gateway.md.

let configURL = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
    ?? ZielConfig.defaultURL
let config = ZielConfig.load(from: configURL).voice
let modelsDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("Ziel van Sebastian/models")
let sttPath = config.modelPath.isEmpty
    ? modelsDir.appendingPathComponent("ggml-\(config.model).bin").path : config.modelPath
let vadPath = config.vadModelPath.isEmpty
    ? modelsDir.appendingPathComponent("ggml-silero-v5.1.2.bin").path : config.vadModelPath
let port = UInt16(URL(string: config.gatewayURL)?.port ?? 18790)

func log(_ s: String) { FileHandle.standardError.write(Data("[voice-gateway] \(s)\n".utf8)) }

do {
    let stt = try WhisperSTT(modelPath: sttPath)
    let vad = try SileroVAD(modelPath: vadPath)
    let server = try VoiceGatewayServer(requestedPort: port)
    let segmenter = UtteranceSegmenter()
    let voiceQueue = DispatchQueue(label: "voice-pipeline")

    let pipeline = VoicePipeline(
        wakeWord: config.wakeWord,
        transcribe: { stt.transcribe($0) },
        emit: { event in
            log("event: \(event)")
            server.broadcast(event)
        })

    server.onCommand = { cmd in
        voiceQueue.async {
            log("command: \(cmd)")
            pipeline.handle(cmd, resetSegmenter: { segmenter.reset(); vad.reset() })
        }
    }

    let capture = AudioCapture(deviceName: config.inputDevice) { frame in
        voiceQueue.async {
            let prob = vad.speechProbability(frame512: frame)
            if let e = segmenter.push(frame: frame, prob: prob) { pipeline.segmenterEvent(e) }
        }
    }

    try server.start()
    log("listening on ws://127.0.0.1:\(server.port), model=\(sttPath)")
    try capture.start()
    log("mic capture running (device: \(config.inputDevice.isEmpty ? "system default" : config.inputDevice))")
    dispatchMain()
} catch {
    log("fatal: \(error.localizedDescription)")
    exit(1)
}
```

- [ ] **Step 6: Build + dev-Mac E2E** (this machine has a mic): `make vendor gen && xcodebuild -project ZielVanSebastian.xcodeproj -scheme VoiceGatewayTests build | tail -2`, then run the built `voice-gateway` binary, say "Sebastian, hello there", and watch stderr for `event: wake` + `event: heard(...)`. Record the observed output in your report. **Step 7: Full suites**: `make test` and `make test-voice` — both green. **Step 8: Commit** (`feat: voice-gateway CLI — mic→VAD→whisper→events pipeline`).

---

### Task 9: Appliance ops + docs

**Files:**
- Create: `docs/voice-gateway.md` (service doc: models fetch, TCC first-run, launchd install, config keys)
- Create: `scripts/ziel.voice-gateway.plist.example` (launchd user-agent template: label `com.gintini.ziel.voice-gateway`, program = installed binary path, `RunAtLoad`, `KeepAlive`, stderr to `~/Library/Logs/ziel/voice-gateway.log`)
- Modify: `README.md` (short "Voice input (Phase 2a)" section linking the doc)

- [ ] **Step 1: Write `docs/voice-gateway.md`** covering: build (`make vendor && make build`), models (`make models`), run (`./build/Build/Products/Debug/voice-gateway [config.json]`), config keys (`voice.*` incl. `vadModelPath`), **TCC**: first launch must happen in a logged-in GUI session and will prompt for mic access — approve once; headless/ssh launches before that grant will fail with the AudioCapture error string; launchd install steps (`cp` plist → `~/Library/LaunchAgents`, `launchctl bootstrap gui/$(id -u) …`); troubleshooting (no device found → check `voice.inputDevice` substring; port busy → change `voice.gatewayURL`).
- [ ] **Step 2: plist example** with placeholder paths and a comment header saying it's a template (real deploy paths differ per machine; `scripts/deploy.sh` is gitignored and owner-maintained — add a note there manually).
- [ ] **Step 3: README section** (3–6 lines, mirrors the speech section's tone: optional, off by default, degrades gracefully).
- [ ] **Step 4: Verify** `make test` green; docs render (visual skim). **Step 5: Commit** (`docs: voice-gateway service — models, TCC, launchd, config`).

---

## On-device validation checklist (manual, after all tasks)

1. Dev Mac (built-in mic): cold start → say "Sebastian, what time is it" → `wake` + `heard` events on stderr and via a WS probe.
2. `mode listen` command over WS → plain speech (no wake word) emits `heard`.
3. `mode armed` → plain speech ignored; "Sebastian …" works.
4. Silence for a minute → no events (VAD idle, CPU near zero — check Activity Monitor; whisper must NOT run on noise).
5. Appliance with **AirPods** (before the PowerConf arrives — pair them to the Mac mini): fetch models, install launchd agent, first-run TCC grant, repeat 1–4 with `voice.inputDevice: "AirPods"`. AirPods' in-ear output also makes this the first barge-in-safe audio setup on the appliance.
6. Appliance with the **PowerConf S3** once it arrives: switch `voice.inputDevice` to `"PowerConf"` and repeat — this is the production configuration (hardware AEC, open-air).

## Explicitly NOT in 2a

- App-side wiring (`VoiceGatewayClient`, coordinator, barge-in execution, injection) — **Phase 3**.
- openWakeWord/ONNX (always-on dedicated wake engine) — **Phase 2b**, only if 2a idle CPU disappoints.
- Software AEC, upstream generation cancel, non-English models — per spec.
