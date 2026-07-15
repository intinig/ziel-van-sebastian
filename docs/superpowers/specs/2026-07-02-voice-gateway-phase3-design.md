# Ziel van Sebastian — Voice Gateway Phase 3: App Integration

**Date:** 2026-07-02
**Status:** Approved
**Depends on:** Phase 1 (PR #4 — `ConversationController`, `GatewayClient.sendPrompt`), Phase 2a (PR #5 — the `voice-gateway` CLI). Parent spec: `2026-07-01-voice-gateway-design.md`.

## What It Is

The final wiring that makes Ziel conversational. The `voice-gateway` process already turns speech into `VoiceEvent`s over a local WebSocket (validated on the appliance: "Sebastian, are you there?" → `wake` + `heard`). Phase 3 connects those events into the app so they drive `GatewayClient.sendPrompt` into OpenClaw, the reply comes back through the **existing** OpenClaw → Director → face path, and the conversation supports **follow-up** (no wake word for a window) and **barge-in** (talk over Sebastian to interrupt).

With `voice.enabled: true`: "Sebastian, …" → OpenClaw → the face speaks the answer; follow up without the wake word; interrupt mid-answer. With `voice.enabled: false` (default), behavior is exactly as today.

## Decisions (resolved in brainstorming)

1. **Connect-only process model.** The app connects to an independently-run `voice-gateway` (launchd agent on the appliance; manual/`make` target in dev), reconnecting like `GatewayClient`. The app never spawns or supervises it — mirrors how the app already treats OpenClaw, and keeps the two processes independently deployable/restartable.
2. **Build the full integration in one plan.** Barge-in is pure Core logic (already built) plus mock-testable wiring, and device selection is config plumbing — all buildable/unit-testable now. Only the **open-air barge-in acoustic validation** waits for the Anker PowerConf S3 (AirPods proved too flaky — see appliance-validation findings).
3. **Barge-in = VAD-onset primary + transcript safety-net.** Stop the instant VAD detects the user's voice, then inject the transcript when `heard` arrives; the `heard`-while-speaking path remains as a fallback for the transcript-beats-onset race. Both paths are tested.

## Current State (what already exists)

- **`ConversationController`** (`Sources/Core/`) — pure, clock-injected state machine. States `idle, listening, awaitingReply, speaking, followUp`; methods `wake/heard/bargeInDetected/replyStarted/replyFinished/tick`; emits `ConversationCommand` = `.setWakeMode(WakeMode)`, `.inject(String)`, `.stopSpeaking`; `WakeMode` = `armed, listen, speaking, followUp`. **Both barge-in paths already implemented** (`bargeInDetected` → `[.stopSpeaking, .setWakeMode(.listen)]`; `heard`-while-`.speaking` → `[.stopSpeaking, .inject]`).
- **`VoiceEvent`/`VoiceCommand`** (`Sources/Core/VoiceProtocol.swift`) — events ↑ `ready(version)`, `wake`, `listening`, `vad(speaking:)`, `heard(text:)`, `error(message:)`; commands ↓ `mode(WakeMode)`, `stop`.
- **`GatewayClient.sendPrompt(_:)`** (`Sources/Gateway/`) — builds `OpenClawTranslator.promptFrame` into the main session (with `idempotencyKey`). Currently guards only on `task != nil`.
- **`Director`** (`Sources/Core/`) — owns `phase` (idle/thinking/speaking/offline), `dropPendingSpeech(now:)`, discrete `speechStarted`/`finishSpeaking` transitions.
- **App** (`App/AppDelegate.swift`) — creates `GatewayClient`→`Director`; has the **Task-4 dev trigger** (`ZIEL_VOICE_DEV_PROMPT` fires `sendPrompt` on `.connectionUp`) to remove; `watchConfig` pushes `pacing/look/waveform/speech` but **not** `voice`.

## Architecture / Components

Two new types plus thin app wiring. The pure logic stays in Core and testable via protocols (matching the `SpeechSynthesizing` seam style).

### 1. `VoiceGatewayClient` (`Sources/Gateway/`, alongside `GatewayClient`)

Reconnecting local-WS client to `voice.gatewayURL` (`ws://127.0.0.1:18790`). Decodes `VoiceEvent`, encodes `VoiceCommand` via the existing Core `VoiceProtocol` codec. Reconnect/backoff like `GatewayClient`. On `ready`, **immediately sends its desired current `mode`** so the service resyncs after a reconnect (deferred hook #5). Connect-only — never spawns the gateway; a down/failed connection logs and retries in the background.

### 2. `VoiceCoordinator` (`Sources/Core/`, pure + protocol-driven)

Owns the `ConversationController`. Consumes `VoiceEvent`s and a speaking-state signal; executes `ConversationCommand`s. Dependencies are protocols so `CoreTests` can drive it with fakes (no networking, no Director):

- **`VoiceLink`** — `send(_ command: VoiceCommand)` + delivers `VoiceEvent`s to the coordinator. (→ `VoiceGatewayClient`)
- **`PromptInjecting`** — `sendPrompt(_ text: String)`. (→ `GatewayClient`)
- **`SpeakingSource`** — `var isSpeaking: Bool { get }`. (→ `Director` via a small public accessor derived from `phase`)
- **`SpeechStopping`** — `stopSpeaking(now: TimeInterval)` = `Director.dropPendingSpeech(now:)` + `SpeechCoordinator.cancelAll()`. (→ a small App adapter)

Command execution: `.inject(text)` → `PromptInjecting.sendPrompt`; `.setWakeMode(m)` → `VoiceLink.send(.mode(m))`; `.stopSpeaking` → `SpeechStopping.stopSpeaking(now:)`.

### 3. App wiring (`AppDelegate`)

When `voice.enabled`, construct `VoiceGatewayClient` + `VoiceCoordinator` + the small `SpeechStopping`/`SpeakingSource` adapters, and:

- Route `VoiceGatewayClient` events into the coordinator (on the main queue, like `GatewayClient`'s `onEvent`).
- Run a main-queue **tick timer** (reuse the existing timer idiom) that calls `ConversationController.tick(now:)` (follow-up / listen / reply timeouts) and samples `Director.isSpeaking` to detect speaking transitions.
- Remove the Task-4 dev trigger.

## Data Flow

```
voice-gateway ──VoiceEvent──► VoiceGatewayClient ──► VoiceCoordinator ──► ConversationController
                                                          │  commands: [.setWakeMode, .inject, .stopSpeaking]
                          ◄──VoiceCommand(mode/stop)──────┤
   .inject(text)  ─► PromptInjecting.sendPrompt ─► GatewayClient ─► OpenClaw main session
   .setWakeMode   ─► VoiceLink.send(.mode(m))    ─► voice-gateway
   .stopSpeaking  ─► SpeechStopping (dropPendingSpeech + cancelAll)

Director.isSpeaking transition (sampled on the coordinator's tick):
   not-speaking → speaking  ⇒ controller.replyStarted(now)   (→ mode .speaking)
   speaking → not-speaking  ⇒ controller.replyFinished(now)  (→ mode .followUp, starts follow-up window)
```

The reply flows OpenClaw → `Director` → face **unchanged**. The coordinator only *observes* speaking-state (to drive `replyStarted`/`replyFinished` and follow-up timing); it never drives the face except to stop it on barge-in.

**Non-voice replies are naturally ignored by the state machine.** When the face speaks something that wasn't a voice turn (e.g. a WhatsApp message surfacing while `idle`), the sampled speaking transition still calls `replyStarted`/`replyFinished`, but these guard on non-`idle` / `speaking` state and return `[]` — so a spoken reply outside a conversation never enters follow-up/barge-in. This is existing `ConversationController` behavior, not new logic; the coordinator relies on it.

## Barge-in & VAD-state on stop

- On `vad(speaking: true)` while `Director.isSpeaking` **and** `voice.bargeIn`: `controller.bargeInDetected(now)` → `[.stopSpeaking, .setWakeMode(.listen)]` — the face goes quiet instantly, state → `.listening`.
- The following `heard(text)` arrives in `.listening` → `.inject(text)`. If a `heard` beats the onset (race), the `.speaking→heard` path (`[.stopSpeaking, .inject]`) covers it. **Both paths get an explicit test** (deferred hook #3).
- **VAD-state balance on `stop`** (deferred hook #4): whenever the coordinator sends `.stop` / a mode change that resets the service segmenter, it self-clears its local VAD "speaking" flag so a stale onset can't linger. Test: stop-then-onset does not spuriously barge-in.
- Barge-in relies on **hardware AEC (PowerConf) or in-ear (AirPods)** so the mic doesn't hear Sebastian's own voice. Gated by `voice.bargeIn`.

## Deferred Hooks (all five closed)

1. **Config live-reload of `voice`** — `watchConfig` gains a `voice` push (see Config).
2. **`sendPrompt` handshake gate** — gate `GatewayClient.sendPrompt` on `handshakeComplete` (queue-then-flush on hello-ok, or drop) so a coordinator-driven prompt sent between socket-open and hello-ok cannot use a default session key.
3. **Barge-in entry reconciliation** — VAD-onset primary + `heard` safety-net (above); both tested.
4. **VAD-state balance on stop** — coordinator self-clears VAD state on `stop` (above).
5. **Mode resync on reconnect** — `VoiceGatewayClient` sends its current `mode` immediately after `ready`.

## Config, Device Selection, Degradation

- **Live-reload** (`watchConfig`): `voice.bargeIn` and `voice.followUpWindowSeconds` apply live; `voice.outputDevice` applies to subsequent TTS playback (may briefly interrupt an in-flight utterance if the audio engine must restart); toggling `voice.enabled` connects/disconnects the `VoiceGatewayClient` live. Restart-only (documented): `voice.gatewayURL`, `voice.model`, and `voice.inputDevice` (the *gateway's* concern, not the app's).
- **Device selection**: input device is already the gateway's (`voice.inputDevice`, Phase 2a). Phase 3 adds **output-device selection to TTS playback** (`voice.outputDevice`) — mirrors `AudioCapture`'s CoreAudio device pick — so TTS output and mic input can share the PowerConf for hardware echo cancellation.
- **Degradation** (invariant — voice never blocks the face): `voice.enabled: false` → the gateway is never contacted; behavior identical to today. Gateway down / connect fails → log + display-only + background reconnect. Injection failure → the face settles back toward idle; never wedge. The Task-4 dev trigger (`ZIEL_VOICE_DEV_PROMPT`) is removed.

## Testing

- **Core unit tests** (`make test`, hermetic):
  - `VoiceCoordinator` with fakes — full `VoiceEvent`→command mapping; wake→listen→inject; both barge-in paths (VAD-onset while speaking; `heard`-while-speaking race); VAD-state-on-stop (stop-then-onset ignored); speaking transition → `replyStarted`/`replyFinished`; follow-up/listen/reply timeouts via injected `now`; barge-in gated by `voice.bargeIn`.
  - `GatewayClient.sendPrompt` handshake-gate: a prompt before hello-ok is queued/dropped, not sent with a default session key.
  - `VoiceConfig` live-reload fields decode as expected.
- **VoiceGatewayKit** (`make test-voice` / in-process mock): `mode`-resync-after-`ready`.
- **On-device (manual checklist)**: wake→ask→answer (validatable now via the working wake path), follow-up window, config live-reload, degradation (gateway down → display-only). **Open-air barge-in acoustic validation waits for the PowerConf S3** — the logic ships and is unit-covered now; only the acoustic test is deferred.
- `make test` (CoreTests) stays green and hermetic.

## What Waits for Hardware

Only the **acoustic** validation of open-air barge-in (mic must not false-trigger on Sebastian's own voice) needs the PowerConf S3's hardware AEC. All Phase 3 code is built and unit-tested without it. AirPods are unsuitable for standing appliance use (Continuity contention + A2DP/HFP profile drift — documented in the voice-feature-status findings).

## Out of Scope (unchanged from parent spec)

- Software AEC; cancelling OpenClaw's in-flight generation on barge-in (v1 stops locally + drops pending); streaming partial transcripts; non-English models; speaker ID.
- openWakeWord/ONNX wake engine (Phase 2b, optional) — whisper-prefix wake remains the shipping detector.
- Stable code-signing for the `voice-gateway` binary (mic-TCC-grant persistence) — a separate ops follow-up, not a Phase 3 feature.
