# Voice Gateway Phase 3 (App Integration) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the `voice-gateway`'s `VoiceEvent`s into the ziel app so "Sebastian, …" injects into OpenClaw and the face speaks the reply, with follow-up and barge-in — degrading to display-only when voice is off or the gateway is down.

**Architecture:** A new reconnecting `VoiceGatewayClient` (Sources/Gateway) delivers `VoiceEvent`s to a pure, protocol-driven `VoiceCoordinator` (Sources/Core) that owns the existing `ConversationController`, feeds it voice events + Director speaking-state, and executes its commands (`.inject`→`GatewayClient.sendPrompt`, `.setWakeMode`→voice-gateway, `.stopSpeaking`→`Director.dropPendingSpeech`+`SpeechCoordinator.cancelAll`). The reply returns through the existing OpenClaw→Director→face path unchanged.

**Tech Stack:** Swift 5.10, `URLSessionWebSocketTask` (client), `AVAudioEngine` (TTS output device), XCTest. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-07-02-voice-gateway-phase3-design.md`

## Global Constraints

- **Swift language mode 5.10** — do not use newer-only syntax; no strict-concurrency annotations.
- **`make test` must stay hermetic and green** — it never links `Vendor/whisper`. All Phase 3 automated tests run under `make test` (the `CoreTests` target already compiles `Sources/Core`, `Sources/Gateway`, `Sources/Speech`, `Sources/VoiceGatewayKit`, `Sources/MockGatewayKit`, and `Tests/`). Do **not** add whisper-linked tests.
- **Voice is optional and must never block the face.** Off by default (`voice.enabled: false`). Every failure path (gateway down, decode failure, injection failure, `error` event) degrades to display-only; never crash, never wedge.
- **Loopback only** — the voice WS is `ws://127.0.0.1:18790`; the client connects only there. No auth by design.
- **Clock is always injected** — `VoiceCoordinator.handle`/`tick` take `now: TimeInterval`; no `Date()` in Core.
- **Never edit `*.xcodeproj`** — it is generated. If a new file needs a target, it lands in an existing source dir already globbed by the target; no `project.yml` change is required for these files (all live under `Sources/Core`, `Sources/Gateway`, `Sources/Speech`, `Sources/VoiceGatewayKit`, `App/`, `Tests/`).
- **Commit after every task** with the Claude co-author trailer:
  `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`

## File Structure

- **Create** `Sources/Core/VoiceCoordinator.swift` — the four seam protocols (`VoiceLink`, `PromptInjecting`, `SpeakingSource`, `SpeechStopping`) + `VoiceCoordinator` (pure glue: event→controller→action, speaking-transition detection). (Task 4)
- **Create** `Sources/Gateway/VoiceGatewayClient.swift` — reconnecting loopback-WS client; decodes `VoiceEvent`, encodes `VoiceCommand`; re-sends mode after `ready`; conforms to `VoiceLink`. (Task 5)
- **Create** `Sources/Speech/AudioOutputDevice.swift` — CoreAudio output-device-by-name lookup. (Task 6)
- **Modify** `Sources/VoiceGatewayKit/VoicePipeline.swift` — emit closing `vad(false)` when `.stop` resets an open segment (hook #4). (Task 1)
- **Modify** `Sources/Gateway/GatewayClient.swift:66-79` — gate `sendPrompt` on `handshakeComplete` (hook #2). (Task 2)
- **Modify** `Sources/Core/Director.swift` — add `public var isSpeaking` (hook: speaking-state source). (Task 3)
- **Modify** `Sources/Core/ConversationController.swift` — `followUpWindow` becomes settable + `setFollowUpWindow` (for live-reload). (Task 4)
- **Modify** `Sources/Speech/ElevenLabsTTS.swift` — `outputDeviceName` + select output device before `engine.start()`. (Task 6)
- **Modify** `App/AppDelegate.swift` — construct + wire the voice stack, tick timer, remove the dev trigger; `watchConfig` voice live-reload (hook #1). (Task 7)
- **Modify tests:** `Tests/VoicePipelineTests.swift`, `Tests/GatewayIntegrationTests.swift`, `Tests/DirectorTests.swift`; **Create** `Tests/VoiceCoordinatorTests.swift`, `Tests/VoiceGatewayClientTests.swift`, `Tests/AudioOutputDeviceTests.swift`.

**Task order & dependencies:** Tasks 1–3 are independent leaf changes (any order). Task 4 depends on nothing but is consumed by 5/7. Task 5 depends on nothing (tests against the real server). Task 6 is independent. Task 7 depends on 3, 4, 5, 6 (it wires them). Recommended order: 1, 2, 3, 4, 5, 6, 7.

---

### Task 1: Service emits closing `vad(false)` on `.stop` (deferred hook #4)

**Files:**
- Modify: `Sources/VoiceGatewayKit/VoicePipeline.swift`
- Test: `Tests/VoicePipelineTests.swift`

**Interfaces:**
- Consumes: `UtteranceSegmenter.Event` (`.started`, `.utterance([Float])`), `VoiceCommand` (`.mode`, `.stop`), `VoiceEvent`.
- Produces: unchanged public API; `handle(.stop, resetSegmenter:)` now emits `.vad(speaking:false)` first **iff** a segment is currently open.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/VoicePipelineTests.swift`:

```swift
    func testStopWhileSegmentOpenEmitsClosingVad() {
        let (p, events) = make(transcript: "x")
        p.segmenterEvent(.started)                 // opens a segment -> vad(true)
        p.handle(.stop, resetSegmenter: {})        // mid-segment stop must close it
        XCTAssertEqual(events(), [.vad(speaking: true), .vad(speaking: false)])
    }

    func testStopWithNoOpenSegmentEmitsNothing() {
        let (p, events) = make(transcript: "x")
        p.handle(.stop, resetSegmenter: {})
        XCTAssertEqual(events(), [])
    }

    func testUtteranceThenStopDoesNotDoubleClose() {
        let (p, events) = make(transcript: "")   // empty -> only vad(false) from utterance
        p.segmenterEvent(.started)
        p.segmenterEvent(.utterance([0.1]))        // closes the segment -> vad(false)
        p.handle(.stop, resetSegmenter: {})        // already closed -> no extra vad(false)
        XCTAssertEqual(events(), [.vad(speaking: true), .vad(speaking: false)])
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme ZielVanSebastian -only-testing:CoreTests/VoicePipelineTests 2>&1 | tail -20`
Expected: FAIL — `testStopWhileSegmentOpenEmitsClosingVad` gets `[.vad(true)]` (no closing event).

- [ ] **Step 3: Implement segment tracking**

In `Sources/VoiceGatewayKit/VoicePipeline.swift`, add the flag and update both methods:

```swift
public final class VoicePipeline {
    public var mode: WakeMode = .armed
    private var segmentOpen = false
    private let wakeWord: String
    private let transcribe: ([Float]) -> String
    private let emit: (VoiceEvent) -> Void
```

In `segmenterEvent`:

```swift
    public func segmenterEvent(_ e: UtteranceSegmenter.Event) {
        switch e {
        case .started:
            segmentOpen = true
            emit(.vad(speaking: true))
        case .utterance(let samples):
            segmentOpen = false
            emit(.vad(speaking: false))
            let text = transcribe(samples).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            switch mode {
            case .armed:
                guard let command = WakeWordParser.match(transcript: text, wakeWord: wakeWord) else { return }
                emit(.wake)
                emit(command.isEmpty ? .listening : .heard(text: command))
            case .listen, .followUp, .speaking:
                let command = WakeWordParser.match(transcript: text, wakeWord: wakeWord) ?? text
                guard !command.isEmpty else { return }
                emit(.heard(text: command))
            }
        }
    }
```

In `handle`:

```swift
    public func handle(_ c: VoiceCommand, resetSegmenter: () -> Void) {
        switch c {
        case .mode(let m): mode = m
        case .stop:
            if segmentOpen { emit(.vad(speaking: false)); segmentOpen = false }
            resetSegmenter()
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme ZielVanSebastian -only-testing:CoreTests/VoicePipelineTests 2>&1 | tail -20`
Expected: PASS (all VoicePipeline tests, including the pre-existing ones).

- [ ] **Step 5: Commit**

```bash
git add Sources/VoiceGatewayKit/VoicePipeline.swift Tests/VoicePipelineTests.swift
git commit -m "feat(voice): emit closing vad(false) when .stop resets an open segment

Closes Phase 3 deferred hook #4: the service kept the wire honest for any
client by balancing an open VAD segment on stop.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Gate `sendPrompt` on handshake completion (deferred hook #2)

**Files:**
- Modify: `Sources/Gateway/GatewayClient.swift:66-79`
- Test: `Tests/GatewayIntegrationTests.swift` (reuses the file's private `Collector`/`makeClient`)

**Interfaces:**
- Consumes: `MockGatewayServer(requestedPort:expectToken:requireDeviceAuth:steps:)`, `server.receivedFrames: [[String: Any]]`.
- Produces: `GatewayClient.sendPrompt(_:)` now drops (logs) when `handshakeComplete == false`, instead of sending with a default session key.

- [ ] **Step 1: Write the failing test**

Add to `Tests/GatewayIntegrationTests.swift`, inside the `// MARK: - Prompt injection` section:

```swift
    func testSendPromptDroppedBeforeHandshake() throws {
        // requireDeviceAuth + identity:nil => server rejects connect; handshake never completes.
        let server = try MockGatewayServer(requestedPort: 0, expectToken: "tok",
                                           requireDeviceAuth: true, steps: [])
        try server.start()
        defer { server.stop() }

        let collector = Collector()
        let client = makeClient(port: server.port, identity: nil, collector: collector)
        client.start()
        defer { client.stop() }

        // Fire prompts during the (doomed) handshake window.
        for _ in 0..<5 { client.sendPrompt("should-not-send") }

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && !collector.snapshot().contains(.connectionDown(auth: true)) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))

        XCTAssertFalse(server.receivedFrames.contains { $0["method"] as? String == "chat.send" },
                       "sendPrompt before handshake completes must be dropped, not sent with a default key")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme ZielVanSebastian -only-testing:CoreTests/GatewayIntegrationTests/testSendPromptDroppedBeforeHandshake 2>&1 | tail -20`
Expected: FAIL — the current `sendPrompt` (guards only `task != nil`) sends a `chat.send` frame while the socket is open pre-handshake.

- [ ] **Step 3: Add the handshake guard**

Replace `Sources/Gateway/GatewayClient.swift:66-79` with:

```swift
    public func sendPrompt(_ text: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let task = self.task, self.handshakeComplete else {
                self.log.error("sendPrompt dropped: gateway not connected/handshaked")
                return
            }
            let frame = OpenClawTranslator.promptFrame(
                text: text, id: "prompt-\(UUID().uuidString)",
                mainSessionKey: self.translationContext.mainSessionKey)
            guard let data = try? JSONSerialization.data(withJSONObject: frame) else { return }
            task.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
                if let error {
                    self?.log.error("sendPrompt failed: \(error.localizedDescription)")
                }
            }
        }
    }
```

(Design note: **drop**, not queue — a prompt injected during an OpenClaw reconnect is likely stale by the time the socket returns; dropping matches "injection failure → settle to idle, never wedge". The existing `testSendPromptDeliversFrame` proves the post-handshake happy path still works.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme ZielVanSebastian -only-testing:CoreTests/GatewayIntegrationTests 2>&1 | tail -20`
Expected: PASS — both `testSendPromptDroppedBeforeHandshake` and the pre-existing `testSendPromptDeliversFrame`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Gateway/GatewayClient.swift Tests/GatewayIntegrationTests.swift
git commit -m "fix(gateway): gate sendPrompt on handshakeComplete (drop pre-handshake)

Closes Phase 3 deferred hook #2: a coordinator-driven prompt sent between
socket-open and hello-ok can no longer use a default session key.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `Director.isSpeaking` accessor

**Files:**
- Modify: `Sources/Core/Director.swift`
- Test: `Tests/DirectorTests.swift`

**Interfaces:**
- Consumes: `Director.phase: Phase` (private), `Phase.speaking` (from `SceneTypes.swift`).
- Produces: `public var isSpeaking: Bool` on `Director` — `true` exactly when `phase == .speaking`. Consumed by the `SpeakingSource` conformance in Task 7.

- [ ] **Step 1: Write the failing test**

Add to `Tests/DirectorTests.swift` (a `Director` starts `.offline`; a run with a text delta drives it to `.speaking`):

```swift
    func testIsSpeakingReflectsPhase() {
        let cfg = ZielConfig()
        let look = try! ResolvedLook.resolve(cfg.look, themeOverride: nil)
        let d = Director(config: cfg, look: look)
        d.handle(.connectionUp, now: 0)
        XCTAssertFalse(d.isSpeaking)                                  // idle
        d.handle(.runStarted(run: "r", session: "s"), now: 0)
        d.handle(.textDelta(run: "r", session: "s", text: "Hello there. "), now: 0)
        _ = d.tick(now: 0.1)
        XCTAssertTrue(d.isSpeaking, "text delta must put the Director in .speaking")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme ZielVanSebastian -only-testing:CoreTests/DirectorTests/testIsSpeakingReflectsPhase 2>&1 | tail -20`
Expected: FAIL — `value of type 'Director' has no member 'isSpeaking'`.

- [ ] **Step 3: Add the accessor**

In `Sources/Core/Director.swift`, add a public computed property near the other public accessors (e.g. just after the `isOnline` property around line 219):

```swift
    /// True exactly while the face is speaking a reply. The voice coordinator
    /// samples this to drive replyStarted/replyFinished and to gate barge-in.
    public var isSpeaking: Bool { phase == .speaking }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme ZielVanSebastian -only-testing:CoreTests/DirectorTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Director.swift Tests/DirectorTests.swift
git commit -m "feat(core): Director.isSpeaking accessor for the voice coordinator

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `VoiceCoordinator` + seam protocols (Core)

**Files:**
- Create: `Sources/Core/VoiceCoordinator.swift`
- Modify: `Sources/Core/ConversationController.swift` (make `followUpWindow` settable)
- Create: `Tests/VoiceCoordinatorTests.swift`

**Interfaces:**
- Consumes: `ConversationController` (`wake`, `heard`, `bargeInDetected`, `replyStarted`, `replyFinished`, `tick` → `[ConversationCommand]`), `ConversationCommand` (`.setWakeMode(WakeMode)`, `.inject(String)`, `.stopSpeaking`), `VoiceEvent`, `VoiceCommand`, `WakeMode`.
- Produces:
  - `protocol VoiceLink: AnyObject { func send(_ command: VoiceCommand) }`
  - `protocol PromptInjecting: AnyObject { func sendPrompt(_ text: String) }`
  - `protocol SpeakingSource: AnyObject { var isSpeaking: Bool { get } }`
  - `protocol SpeechStopping: AnyObject { func stopSpeaking(now: TimeInterval) }`
  - `final class VoiceCoordinator` with `init(controller:link:injector:speaking:stopper:bargeInEnabled:)`, `func handle(_ event: VoiceEvent, now: TimeInterval)`, `func tick(now: TimeInterval)`, `func setFollowUpWindow(_ seconds: TimeInterval)`.
  - `ConversationController.setFollowUpWindow(_ seconds: TimeInterval)`.

- [ ] **Step 1: Make `ConversationController.followUpWindow` settable**

In `Sources/Core/ConversationController.swift`, change `private let followUpWindow: TimeInterval` to `private var followUpWindow: TimeInterval` and add this method inside the class (after `tick`):

```swift
    /// Live-reload of `voice.followUpWindowSeconds`; takes effect on the next tick.
    public func setFollowUpWindow(_ seconds: TimeInterval) { followUpWindow = seconds }
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/VoiceCoordinatorTests.swift`:

```swift
import XCTest

final class VoiceCoordinatorTests: XCTestCase {
    private final class FakeLink: VoiceLink {
        var sent: [VoiceCommand] = []
        func send(_ command: VoiceCommand) { sent.append(command) }
    }
    private final class FakeInjector: PromptInjecting {
        var prompts: [String] = []
        func sendPrompt(_ text: String) { prompts.append(text) }
    }
    private final class FakeSpeaking: SpeakingSource {
        var isSpeaking = false
    }
    private final class FakeStopper: SpeechStopping {
        var stops = 0
        func stopSpeaking(now: TimeInterval) { stops += 1 }
    }

    private func make(bargeIn: Bool = true, followUp: TimeInterval = 8)
        -> (VoiceCoordinator, FakeLink, FakeInjector, FakeSpeaking, FakeStopper) {
        let link = FakeLink(), inj = FakeInjector(), spk = FakeSpeaking(), stop = FakeStopper()
        let c = VoiceCoordinator(
            controller: ConversationController(followUpWindowSeconds: followUp,
                                               listenWindowSeconds: 10, replyTimeoutSeconds: 30),
            link: link, injector: inj, speaking: spk, stopper: stop,
            bargeInEnabled: { bargeIn })
        return (c, link, inj, spk, stop)
    }

    /// Drives the coordinator into the `.speaking` reply state and returns the fakes.
    private func intoSpeaking(bargeIn: Bool = true)
        -> (VoiceCoordinator, FakeLink, FakeInjector, FakeSpeaking, FakeStopper) {
        let (c, link, inj, spk, stop) = make(bargeIn: bargeIn)
        c.handle(.wake, now: 0)                 // -> listening, mode(.listen)
        c.handle(.heard(text: "question"), now: 1)   // -> awaitingReply, inject
        spk.isSpeaking = true
        c.tick(now: 2)                          // reply started -> speaking, mode(.speaking)
        link.sent.removeAll(); inj.prompts.removeAll(); stop.stops = 0
        return (c, link, inj, spk, stop)
    }

    func testWakeOpensListen() {
        let (c, link, _, _, _) = make()
        c.handle(.wake, now: 0)
        XCTAssertEqual(link.sent, [.mode(.listen)])
    }

    func testHeardInjectsAfterWake() {
        let (c, _, inj, _, _) = make()
        c.handle(.wake, now: 0)
        c.handle(.heard(text: "what's the weather"), now: 1)
        XCTAssertEqual(inj.prompts, ["what's the weather"])
    }

    func testReplyStartedThenFinishedDrivesModes() {
        let (c, link, _, spk, _) = make()
        c.handle(.wake, now: 0)
        c.handle(.heard(text: "q"), now: 1)
        spk.isSpeaking = true
        c.tick(now: 2)
        XCTAssertTrue(link.sent.contains(.mode(.speaking)))
        spk.isSpeaking = false
        c.tick(now: 3)
        XCTAssertTrue(link.sent.contains(.mode(.followUp)))
    }

    func testBargeInVadOnsetWhileSpeaking() {
        let (c, link, _, spk, stop) = intoSpeaking()
        spk.isSpeaking = true
        c.handle(.vad(speaking: true), now: 5)
        XCTAssertEqual(stop.stops, 1)
        XCTAssertTrue(link.sent.contains(.mode(.listen)))
    }

    func testBargeInDisabledIgnoresVadOnset() {
        let (c, _, _, spk, stop) = intoSpeaking(bargeIn: false)
        spk.isSpeaking = true
        c.handle(.vad(speaking: true), now: 5)
        XCTAssertEqual(stop.stops, 0)
    }

    func testHeardWhileSpeakingSafetyNet() {
        let (c, _, inj, _, stop) = intoSpeaking()
        c.handle(.heard(text: "actually stop"), now: 5)
        XCTAssertEqual(stop.stops, 1)
        XCTAssertEqual(inj.prompts, ["actually stop"])
    }

    func testVadOnsetIgnoredWhenNotSpeaking() {
        let (c, link, _, spk, stop) = make()
        spk.isSpeaking = false
        c.handle(.vad(speaking: true), now: 1)
        XCTAssertEqual(stop.stops, 0)
        XCTAssertTrue(link.sent.isEmpty)
    }

    func testNonVoiceReplyIsNoOp() {
        // Face speaks with no active conversation (e.g. a WhatsApp message surfaces).
        let (c, link, _, spk, _) = make()
        spk.isSpeaking = true
        c.tick(now: 1)                          // replyStarted guards non-idle -> []
        spk.isSpeaking = false
        c.tick(now: 2)                          // replyFinished guards .speaking -> []
        XCTAssertTrue(link.sent.isEmpty)
    }

    func testFollowUpTimesOutToArmed() {
        let (c, link, _, spk, _) = make(followUp: 8)
        c.handle(.wake, now: 0)
        c.handle(.heard(text: "q"), now: 1)
        spk.isSpeaking = true; c.tick(now: 2)   // speaking
        spk.isSpeaking = false; c.tick(now: 3)  // followUp opens at 3
        link.sent.removeAll()
        c.tick(now: 3 + 8 + 0.1)                // window elapsed
        XCTAssertEqual(link.sent, [.mode(.armed)])
    }

    func testSetFollowUpWindowAppliesLive() {
        let (c, link, _, spk, _) = make(followUp: 8)
        c.setFollowUpWindow(2)
        c.handle(.wake, now: 0)
        c.handle(.heard(text: "q"), now: 1)
        spk.isSpeaking = true; c.tick(now: 2)
        spk.isSpeaking = false; c.tick(now: 3)  // followUp opens at 3
        link.sent.removeAll()
        c.tick(now: 3 + 2 + 0.1)                // 2s window -> armed
        XCTAssertEqual(link.sent, [.mode(.armed)])
    }

    func testErrorEventDoesNotWedge() {
        let (c, link, inj, _, stop) = make()
        c.handle(.error(message: "whisper failed"), now: 0)
        XCTAssertTrue(link.sent.isEmpty)
        XCTAssertTrue(inj.prompts.isEmpty)
        XCTAssertEqual(stop.stops, 0)
    }
}
```

- [ ] **Step 3: Run tests to verify they fail**

Run: `xcodebuild test -scheme ZielVanSebastian -only-testing:CoreTests/VoiceCoordinatorTests 2>&1 | tail -20`
Expected: FAIL to compile — `VoiceCoordinator`/protocols don't exist yet.

- [ ] **Step 4: Implement `VoiceCoordinator`**

Create `Sources/Core/VoiceCoordinator.swift`:

```swift
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
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `xcodebuild test -scheme ZielVanSebastian -only-testing:CoreTests/VoiceCoordinatorTests 2>&1 | tail -20`
Expected: PASS (all cases).

- [ ] **Step 6: Run the full hermetic suite**

Run: `make test 2>&1 | tail -15`
Expected: all tests pass (no regressions in ConversationController from the `var` change).

- [ ] **Step 7: Commit**

```bash
git add Sources/Core/VoiceCoordinator.swift Sources/Core/ConversationController.swift Tests/VoiceCoordinatorTests.swift
git commit -m "feat(core): VoiceCoordinator — event->controller->action glue

Pure, protocol-driven (VoiceLink/PromptInjecting/SpeakingSource/SpeechStopping).
Barge-in = VAD-onset primary + heard safety-net (hook #3); speaking transitions
drive replyStarted/replyFinished; live follow-up window.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: `VoiceGatewayClient` (Gateway) + mode resync after `ready` (deferred hook #5)

**Files:**
- Create: `Sources/Gateway/VoiceGatewayClient.swift`
- Test: `Tests/VoiceGatewayClientTests.swift`

**Interfaces:**
- Consumes: `VoiceProtocol.decodeEvent(_:) -> VoiceEvent?`, `VoiceProtocol.encode(_ command: VoiceCommand) -> Data`, `VoiceGatewayServer` (real, loopback: `init(requestedPort:)`, `start()`, `stop()`, `port`, `onCommand`, `broadcast(_:)`), `WakeMode`, `VoiceCommand`, `VoiceEvent`.
- Produces: `final class VoiceGatewayClient: VoiceLink` with `init(url: URL, onEvent: @escaping (VoiceEvent) -> Void)`, `func start()`, `func stop()`, `func send(_ command: VoiceCommand)`. Restartable (start after stop reconnects). Re-sends its last `mode` after each `ready`. `onEvent` fires on an internal queue — callers hop to main.

- [ ] **Step 1: Write the failing tests**

Create `Tests/VoiceGatewayClientTests.swift`:

```swift
import XCTest

final class VoiceGatewayClientTests: XCTestCase {
    private func pump(_ predicate: () -> Bool, timeout: TimeInterval = 5) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !predicate() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }

    func testResendsLastModeAfterReady() throws {
        let server = try VoiceGatewayServer(requestedPort: 0)
        try server.start()
        defer { server.stop() }

        let lock = NSLock()
        var commands: [VoiceCommand] = []
        server.onCommand = { lock.lock(); commands.append($0); lock.unlock() }

        let client = VoiceGatewayClient(url: URL(string: "ws://127.0.0.1:\(server.port)")!,
                                        onEvent: { _ in })
        client.send(.mode(.followUp))   // set desired mode before connecting (no-op send)
        client.start()
        defer { client.stop() }

        // On connect the server broadcasts `ready`; the client must resync its mode.
        pump { lock.lock(); defer { lock.unlock() }; return commands.contains(.mode(.followUp)) }
        lock.lock(); let got = commands; lock.unlock()
        XCTAssertTrue(got.contains(.mode(.followUp)),
                      "client must re-send its last mode after ready; got \(got)")
    }

    func testDeliversBroadcastEvents() throws {
        let server = try VoiceGatewayServer(requestedPort: 0)
        try server.start()
        defer { server.stop() }

        let lock = NSLock()
        var events: [VoiceEvent] = []
        let client = VoiceGatewayClient(url: URL(string: "ws://127.0.0.1:\(server.port)")!,
                                        onEvent: { lock.lock(); events.append($0); lock.unlock() })
        client.start()
        defer { client.stop() }

        pump { lock.lock(); defer { lock.unlock() }; return events.contains(.ready(version: 1)) }
        server.broadcast(.heard(text: "hi there"))
        pump { lock.lock(); defer { lock.unlock() }; return events.contains(.heard(text: "hi there")) }
        lock.lock(); let got = events; lock.unlock()
        XCTAssertTrue(got.contains(.heard(text: "hi there")), "got \(got)")
    }

    func testStopThenStartReconnects() throws {
        let server = try VoiceGatewayServer(requestedPort: 0)
        try server.start()
        defer { server.stop() }

        let lock = NSLock()
        var readyCount = 0
        let client = VoiceGatewayClient(url: URL(string: "ws://127.0.0.1:\(server.port)")!,
                                        onEvent: { if case .ready = $0 { lock.lock(); readyCount += 1; lock.unlock() } })
        client.start()
        pump { lock.lock(); defer { lock.unlock() }; return readyCount >= 1 }
        client.stop()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        client.start()   // restartable
        defer { client.stop() }
        pump { lock.lock(); defer { lock.unlock() }; return readyCount >= 2 }
        lock.lock(); let count = readyCount; lock.unlock()
        XCTAssertGreaterThanOrEqual(count, 2, "start after stop must reconnect")
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `xcodebuild test -scheme ZielVanSebastian -only-testing:CoreTests/VoiceGatewayClientTests 2>&1 | tail -20`
Expected: FAIL to compile — `VoiceGatewayClient` doesn't exist.

- [ ] **Step 3: Implement `VoiceGatewayClient`**

Create `Sources/Gateway/VoiceGatewayClient.swift`:

```swift
import Foundation
import os

/// Reconnecting loopback-WS client for the voice-gateway. Decodes VoiceEvents,
/// encodes VoiceCommands, and re-sends its last mode after each `ready` so the
/// service resyncs on (re)connect. Restartable: start() after stop() reconnects.
/// `onEvent` fires on an internal serial queue — the caller hops to its own queue.
public final class VoiceGatewayClient: NSObject, VoiceLink, URLSessionWebSocketDelegate {
    private let url: URL
    private let onEvent: (VoiceEvent) -> Void
    private let log = Logger(subsystem: "com.gintini.ZielVanSebastian", category: "voice-gateway-client")
    private let queue = DispatchQueue(label: "voice-gateway-client")
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var stopped = true
    private var attempts = 0
    /// Whether the current connection's drop has already been handled — a
    /// receive failure and the `didCloseWith` delegate callback can both fire
    /// for one dropped connection; without this, both would schedule a
    /// reconnect and `open()` would create a second, orphaned socket.
    private var dropReported = false
    private var lastMode: WakeMode = .armed

    public init(url: URL, onEvent: @escaping (VoiceEvent) -> Void) {
        self.url = url
        self.onEvent = onEvent
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public func start() {
        queue.async {
            guard self.stopped else { return }
            self.stopped = false
            self.attempts = 0
            self.open()
        }
    }

    public func stop() {
        queue.async {
            guard !self.stopped else { return }
            self.stopped = true
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.task = nil
        }
    }

    public func send(_ command: VoiceCommand) {
        queue.async {
            if case .mode(let m) = command { self.lastMode = m }
            self.rawSend(command)
        }
    }

    // MARK: - internals (all on `queue`)

    private func rawSend(_ command: VoiceCommand) {
        guard let task = task else { return }
        let data = VoiceProtocol.encode(command)
        task.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
            if let error { self?.log.error("voice send failed: \(error.localizedDescription)") }
        }
    }

    private func open() {
        guard !stopped else { return }
        dropReported = false
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receiveLoop(t)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async { self.handleDrop() }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                if let current = self.task, current !== t { return }
                switch result {
                case .failure:
                    self.handleDrop()
                case .success(let message):
                    // A message can race stop(): task is nil'd synchronously but a
                    // receive already in flight still completes. Drop it rather than
                    // surface events after the app disabled voice.
                    guard !self.stopped else { return }
                    let data: Data
                    switch message {
                    case .string(let s): data = Data(s.utf8)
                    case .data(let d): data = d
                    @unknown default: data = Data()
                    }
                    if let event = VoiceProtocol.decodeEvent(data) {
                        if case .ready = event {
                            self.attempts = 0
                            self.rawSend(.mode(self.lastMode))   // mode resync after (re)connect
                        }
                        self.onEvent(event)
                    }
                    if self.task === t { self.receiveLoop(t) }
                }
            }
        }
    }

    private func handleDrop() {
        guard !stopped else { return }
        // Drop already reported (idempotent guard) — see `dropReported`.
        if dropReported { return }
        dropReported = true
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        attempts += 1
        let delay = min(30, pow(2, Double(min(attempts, 5)) - 1)) + Double.random(in: 0...0.5)
        log.info("voice-gateway reconnecting in \(delay, format: .fixed(precision: 1))s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in self?.open() }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `xcodebuild test -scheme ZielVanSebastian -only-testing:CoreTests/VoiceGatewayClientTests 2>&1 | tail -20`
Expected: PASS (all three).

- [ ] **Step 5: Commit**

```bash
git add Sources/Gateway/VoiceGatewayClient.swift Tests/VoiceGatewayClientTests.swift
git commit -m "feat(gateway): VoiceGatewayClient — reconnecting loopback WS + mode resync

Closes Phase 3 deferred hook #5: re-sends its last mode after every `ready`.
Restartable for live enable/disable. Conforms to VoiceLink.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: TTS output-device selection (`voice.outputDevice`)

**Files:**
- Create: `Sources/Speech/AudioOutputDevice.swift`
- Modify: `Sources/Speech/ElevenLabsTTS.swift`
- Create: `Tests/AudioOutputDeviceTests.swift`

**Interfaces:**
- Consumes: CoreAudio (`AudioObjectGetPropertyData`, `kAudioDevicePropertyStreamConfiguration` with output scope), `AVAudioEngine.outputNode.audioUnit`, `AudioUnitSetProperty(_, kAudioOutputUnitProperty_CurrentDevice, …)`.
- Produces:
  - `enum AudioOutputDevice { static func find(named name: String) -> AudioDeviceID? }` — case-insensitive substring match over **output-capable** devices; `nil` for empty/no-match.
  - `ElevenLabsTTS.outputDeviceName: String` (default `""`) — when non-empty, the matching device is selected on the engine's output node before `engine.start()`.

- [ ] **Step 1: Write the failing test**

Create `Tests/AudioOutputDeviceTests.swift` (only the environment-independent cases are asserted):

```swift
import XCTest

final class AudioOutputDeviceTests: XCTestCase {
    func testEmptyNameReturnsNil() {
        XCTAssertNil(AudioOutputDevice.find(named: ""))
    }

    func testNonsenseNameReturnsNil() {
        XCTAssertNil(AudioOutputDevice.find(named: "no-such-device-\(UUID().uuidString)"))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `xcodebuild test -scheme ZielVanSebastian -only-testing:CoreTests/AudioOutputDeviceTests 2>&1 | tail -20`
Expected: FAIL to compile — `AudioOutputDevice` doesn't exist.

- [ ] **Step 3: Implement the lookup**

Create `Sources/Speech/AudioOutputDevice.swift` (mirrors `AudioCapture.findInputDevice` but with output scope):

```swift
import Foundation
import CoreAudio

/// Case-insensitive substring match over output-capable CoreAudio devices.
/// Used to pin TTS playback to a specific device (e.g. the PowerConf) so mic
/// and speaker share one hardware unit for echo cancellation. `nil` = no match.
public enum AudioOutputDevice {
    public static func find(named name: String) -> AudioDeviceID? {
        guard !name.isEmpty else { return nil }
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
            var outAddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                     mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var cfgSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &outAddr, 0, nil, &cfgSize) == noErr, cfgSize > 0 else { continue }
            let buf = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(cfgSize))
            defer { buf.deallocate() }
            guard AudioObjectGetPropertyData(id, &outAddr, 0, nil, &cfgSize, buf) == noErr,
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

- [ ] **Step 4: Wire it into `ElevenLabsTTS`**

In `Sources/Speech/ElevenLabsTTS.swift`, add the property near the other stored properties (after `engineReady`), plus a tracker for the last device actually applied — `play()` runs once per sentence, so the selection must be gated on change or it re-invokes `AudioUnitSetProperty` on an already-running audio unit every sentence, which is exactly the engine-reconfiguration risk class described in this file's doc comment (lost in-flight buffer completions):

```swift
    private var engineReady = false
    private var configObserver: NSObjectProtocol?
    /// Device actually applied via AudioUnitSetProperty; nil means "not yet
    /// applied" (default device, or a pin still pending discovery). Guards
    /// against re-invoking AudioUnitSetProperty on every play() call — see
    /// the engine-reconfiguration risk class noted below. Reset whenever the
    /// graph is rebuilt so a real hardware/device change re-applies the pin.
    private var appliedDeviceID: AudioDeviceID?

    /// Non-empty pins TTS output to a named device (e.g. the PowerConf) so mic
    /// and speaker share one unit for hardware AEC. Set live from voice.outputDevice.
    public var outputDeviceName: String = ""
```

`outputDeviceName` is live-reloadable (a later task re-sets it from config watching), so gate on the *resolved* device (`AudioDeviceID`), not on first-start/`engineReady` — that would silently ignore later config changes.

Then in `play(...)`, select the device immediately before the `if !engine.isRunning` start block:

```swift
        // Only re-invoke AudioUnitSetProperty when the resolved target actually
        // changed. Setting it on every play() would re-trigger the engine's
        // configuration-change path (see init) — the same lost-completion risk
        // this file's comment warns about — for what is usually a no-op after
        // the first sentence. outputDeviceName is live-reloadable, so we gate
        // on the resolved device, not just "did we ever apply one".
        if !outputDeviceName.isEmpty,
           let dev = AudioOutputDevice.find(named: outputDeviceName),
           dev != appliedDeviceID,
           let unit = engine.outputNode.audioUnit {
            var deviceID = dev
            let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                           kAudioUnitScope_Global, 0, &deviceID,
                                           UInt32(MemoryLayout<AudioDeviceID>.size))
            if err == noErr {
                appliedDeviceID = dev
            } else {
                NSLog("speech: failed to select output device '%@' (%d)", outputDeviceName, err)
            }
        } else if outputDeviceName.isEmpty, appliedDeviceID != nil,
                  let unit = engine.outputNode.audioUnit {
            // voice.outputDevice was live-reloaded back to "" — the audio unit is
            // still pinned to the old device (nothing else reverts it), so
            // explicitly reselect the system default output. Same no-verify-
            // in-tests boundary as the pin above (manual verification only).
            if let defaultDevice = AudioOutputDevice.systemDefaultOutput() {
                var deviceID = defaultDevice
                let err = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                               kAudioUnitScope_Global, 0, &deviceID,
                                               UInt32(MemoryLayout<AudioDeviceID>.size))
                if err == noErr {
                    appliedDeviceID = nil
                } else {
                    NSLog("speech: failed to revert output device to system default (%d)", err)
                    // Leave appliedDeviceID set so this retries on the next play().
                }
            } else {
                NSLog("speech: failed to query system default output device")
                // Leave appliedDeviceID set so this retries on the next play().
            }
        }
        if !engine.isRunning {
```

`AudioOutputDevice.systemDefaultOutput()` (added alongside `find(named:)` in `AudioOutputDevice.swift`) queries `kAudioHardwarePropertyDefaultOutputDevice` on the system object via `AudioObjectGetPropertyData`, returning `nil` on failure (caller degrades gracefully — playback is never blocked on this).

Also reset the tracker in the existing `AVAudioEngineConfigurationChange` observer (constructor, added in an earlier task), alongside where it resets `engineReady = false` on graph teardown — the device pin may not survive a hardware reconfiguration (dock/output swap), so forget it there too and let the next `play()` re-apply:

```swift
            if self.engineReady {
                self.engine.disconnectNodeOutput(self.player)
                self.engine.detach(self.player)
                self.engineReady = false
                self.appliedDeviceID = nil
            }
```

Add the imports needed at the top of `ElevenLabsTTS.swift` if not already present: `import CoreAudio` (for `AudioUnitSetProperty`/`AudioDeviceID`; `AudioUnit` comes via AVFoundation but the property constants need CoreAudio/AudioToolbox — add `import AudioToolbox` as well if the build complains).

- [ ] **Step 5: Run tests + build**

Run: `xcodebuild test -scheme ZielVanSebastian -only-testing:CoreTests/AudioOutputDeviceTests 2>&1 | tail -20`
Expected: PASS.
Run: `make build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` (confirms `ElevenLabsTTS` still compiles with the new selection code).

- [ ] **Step 6: Commit**

```bash
git add Sources/Speech/AudioOutputDevice.swift Sources/Speech/ElevenLabsTTS.swift Tests/AudioOutputDeviceTests.swift
git commit -m "feat(speech): select TTS output device by name (voice.outputDevice)

Enables mic+speaker on one hardware unit (PowerConf) for echo cancellation.
Acoustic validation deferred to the PowerConf S3.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: App wiring — construct + connect the voice stack, tick timer, live-reload, remove dev trigger

**Files:**
- Modify: `App/AppDelegate.swift` (launch wiring `:60-96`, config watcher `:231-257`, teardown `:187-191`, properties `:3-15`)

**Interfaces:**
- Consumes everything above: `VoiceGatewayClient`, `VoiceCoordinator` + protocols, `ConversationController`, `Director.isSpeaking`, `GatewayClient.sendPrompt`, `ElevenLabsTTS.outputDeviceName`, `SpeechCoordinator.cancelAll`, `Director.dropPendingSpeech(now:)`.
- Produces: no new public API. Adds `extension GatewayClient: PromptInjecting {}`, `extension Director: SpeakingSource {}`, a private `AppSpeechStopper: SpeechStopping`, and stored properties `voiceClient`, `voiceCoordinator`, `voiceTick`, `tts`.

> **Note on testing:** `AppDelegate` is not unit-tested (AppKit + audio), consistent with the project's manual on-device convention. The units it wires are all covered by Tasks 1–6. Verification here is: `make test` stays green, `make build` succeeds, and the manual checklist in Step 8.

- [ ] **Step 1: Add conformances + the stopper adapter**

At the bottom of `App/AppDelegate.swift` (file scope), add:

```swift
// GatewayClient already exposes `sendPrompt(_:)`.
extension GatewayClient: PromptInjecting {}
// Director already exposes `isSpeaking`.
extension Director: SpeakingSource {}

/// Barge-in stop: abandon the Director's focused run (even mid-stream) and clear queued TTS audio.
final class AppSpeechStopper: SpeechStopping {
    private weak var director: Director?
    private weak var speech: SpeechCoordinator?
    init(director: Director?, speech: SpeechCoordinator?) {
        self.director = director
        self.speech = speech
    }
    func stopSpeaking(now: TimeInterval) {
        director?.abandonFocusedRun(now: now)
        speech?.cancelAll()
    }
}
```

> **Post-Phase-3 update (PR #6 review):** `stopSpeaking` originally called `Director.dropPendingSpeech(now:)`, which only clears backlog while leaving `focusedRun` set — fine for the swipe-away/swipe-back Space case (the *other* `dropPendingSpeech` call site, in the occlusion observer, still uses it), but wrong for barge-in: if the interrupted run was still streaming, its next delta resumed speaking the old reply instead of yielding to the newly injected run. Fixed by adding `Director.abandonFocusedRun(now:)` (clears via `dropPendingSpeech`, then marks the old run `abandoned` and nils `focusedRun`); `route(_:from:)` now drops text from an `abandoned` run instead of buffering it in `pending`, and the run is evicted on its own `runEnded`. See `Tests/DirectorTests.swift` (`testBargeInMustAbandonStillStreamingFocusedRun`, `testAbandonedRunEvictedOnItsRunEnded`).

- [ ] **Step 2: Add stored properties**

In the `AppDelegate` property block (`:3-15`), add:

```swift
    private var voiceClient: VoiceGatewayClient?
    private var voiceCoordinator: VoiceCoordinator?
    private var voiceTick: Timer?
    private var tts: ElevenLabsTTS?
```

- [ ] **Step 3: Keep a handle to the TTS + apply output device**

Replace the speech-construction block (`:45-52`) so the concrete TTS is retained and the output device is applied:

```swift
        let voiceId = config.speech.voiceId
        let urlSafeVoiceId = !voiceId.isEmpty
            && voiceId.unicodeScalars.allSatisfy { CharacterSet.urlPathAllowed.contains($0) }
            && !voiceId.contains("/")
        if !config.speech.apiKey.isEmpty && urlSafeVoiceId {
            let tts = ElevenLabsTTS(config: config.speech)
            tts.outputDeviceName = config.voice.outputDevice
            self.tts = tts
            speech = SpeechCoordinator(director: director, synth: tts,
                                       volume: config.speech.volume, now: clock)
        } else if config.speech.enabled {
            NSLog("speech.enabled is true but apiKey/voiceId missing or voiceId malformed — speech disabled (restart after fixing config)")
        }
```

- [ ] **Step 4: Remove the dev trigger and build the voice stack**

In the real-gateway `else` branch, delete the dev-trigger lines (`:71-77` and the `devPromptSent` block at `:86-90`), simplifying the `onEvent` closure. Then, immediately after `gateway.start()` (`:95`), add the voice-stack construction:

```swift
            let gateway = GatewayClient(
                url: url,
                token: config.gateway.token,
                identity: identity,
                onEvent: { [weak director, weak self] event in
                    DispatchQueue.main.async {
                        if case .connectionDown = event { self?.speech?.cancelAll() }
                        director?.handle(event, now: clock())
                    }
                }
            )
            self.gateway = gateway
            gateway.start()

            // --- Voice stack (Phase 3) ---
            // Always constructed (cheap, inert); only *connected* when enabled, so
            // the "never contact the gateway when disabled" invariant holds.
            let voiceURL = URL(string: config.voice.gatewayURL)
                ?? URL(string: VoiceConfig().gatewayURL)!
            let controller = ConversationController(
                followUpWindowSeconds: config.voice.followUpWindowSeconds)
            let stopper = AppSpeechStopper(director: director, speech: self.speech)
            let voiceClient = VoiceGatewayClient(url: voiceURL, onEvent: { [weak self] event in
                DispatchQueue.main.async {
                    self?.voiceCoordinator?.handle(event, now: clock())
                }
            })
            let coordinator = VoiceCoordinator(
                controller: controller, link: voiceClient, injector: gateway,
                speaking: director, stopper: stopper,
                bargeInEnabled: { [weak self] in self?.config.voice.bargeIn ?? false })
            self.voiceClient = voiceClient
            self.voiceCoordinator = coordinator
            let tick = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { _ in
                coordinator.tick(now: clock())
            }
            tick.tolerance = 0.05
            self.voiceTick = tick
            if config.voice.enabled { voiceClient.start() }
```

- [ ] **Step 5: Live-reload voice config in `watchConfig`**

In `watchConfig`'s event handler (`:239-250`), after the existing `self?.speech?.volume = ...` line, add voice handling:

```swift
                // Voice (Phase 3): bargeIn is read live via the coordinator's
                // closure (self.config is now fresh). Apply the rest live.
                self?.voiceCoordinator?.setFollowUpWindow(fresh.voice.followUpWindowSeconds)
                self?.tts?.outputDeviceName = fresh.voice.outputDevice
                if fresh.voice.enabled { self?.voiceClient?.start() }
                else { self?.voiceClient?.stop() }
```

- [ ] **Step 6: Tear down on terminate**

In `applicationWillTerminate` (`:187-191`), add before the end:

```swift
        voiceTick?.invalidate()
        voiceClient?.stop()
```

- [ ] **Step 7: Build + hermetic suite**

Run: `make build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`.
Run: `make test 2>&1 | tail -15`
Expected: all tests pass. Confirm no reference to `ZIEL_VOICE_DEV_PROMPT` remains:
Run: `grep -rn "ZIEL_VOICE_DEV_PROMPT" App Sources docs || echo "dev trigger removed"`
Expected: only the historical mention in the Phase 1/2 plan docs (not in `App/` or `Sources/`).

- [ ] **Step 8: Manual on-device verification (checklist — record results in the commit body)**

With `voice.enabled: true` and the `voice-gateway` running on the appliance (mic granted; PowerConf or interim rig):
- **Cold wake→ask→answer:** say "Sebastian, what time is it?" → face thinks → speaks the reply.
- **Follow-up:** within the window, ask a follow-up with no wake word → answered.
- **Follow-up timeout:** stay silent past `followUpWindowSeconds` → returns to idle (wake word required again).
- **Degradation — voice off:** set `voice.enabled: false`, save → app keeps running display-only; no connection attempts to `:18790` (`grep` the log).
- **Degradation — gateway down:** stop the `voice-gateway` service → app stays up, face unaffected, client retries in the background.
- **Deferred:** open-air barge-in (mic must not trip on Sebastian's own voice) — validate when the PowerConf S3 arrives.

- [ ] **Step 9: Commit**

```bash
git add App/AppDelegate.swift
git commit -m "feat(app): wire the voice stack end-to-end (Phase 3)

VoiceGatewayClient + VoiceCoordinator constructed at launch, connected when
voice.enabled; tick timer drives timeouts + speaking transitions; voice config
live-reload (enabled/bargeIn/followUp/outputDevice, hook #1); dev trigger removed.

Manual on-device: <fill in checklist results>

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage (each spec section → task):**
- Connect-only `VoiceGatewayClient` → Task 5. `VoiceCoordinator` + 4 protocols → Task 4. App wiring/tick/speaking-state → Task 7.
- Data flow (event→controller→action; non-voice-reply no-op) → Task 4 (`testNonVoiceReplyIsNoOp`), Task 7.
- Barge-in VAD-onset + `heard` safety-net → Task 4 (`testBargeInVadOnsetWhileSpeaking`, `testHeardWhileSpeakingSafetyNet`). VAD-state on stop → Task 1.
- Deferred hooks: #1 live-reload → Task 7; #2 handshake gate → Task 2; #3 barge-in reconciliation → Task 4; #4 VAD-state on stop → Task 1; #5 mode resync → Task 5.
- Config live-reload + device selection + degradation + dev-trigger removal → Tasks 6 & 7.
- Testing: Core/coordinator + handshake-gate + pipeline + client-resync all under `make test`; output-device + on-device deferred/manual → Tasks 6 & 7.
- What waits for hardware (open-air barge-in) → Task 7 Step 8 (explicitly deferred).

**Placeholder scan:** none — every code step shows full code; the only "fill in" is the human's manual-checklist results in the Task 7 commit body.

**Type consistency:** `VoiceLink.send(_:)`, `PromptInjecting.sendPrompt(_:)`, `SpeakingSource.isSpeaking`, `SpeechStopping.stopSpeaking(now:)` are used identically in Tasks 4, 5, 7. `ConversationController.setFollowUpWindow(_:)` defined in Task 4, called in Tasks 4 & 7. `Director.isSpeaking` defined in Task 3, used in Tasks 4 (fake), 7 (conformance). `VoiceGatewayClient(url:onEvent:)`/`start`/`stop`/`send` consistent Tasks 5 & 7. `ElevenLabsTTS.outputDeviceName` defined Task 6, set Task 7. `AudioOutputDevice.find(named:)` defined + used Task 6.
