# Ziel van Sebastian — Voice Gateway (Hands-Free Two-Way Voice)

**Date:** 2026-07-01
**Status:** Approved

## What It Is

Ziel becomes conversational. You say "**Sebastian**, …", it hears you (local speech-to-text), the words are injected into OpenClaw as your prompt, and the agent's reply comes back through the **existing** display/speech path — the face speaks the answer. You can then **follow up without saying "Sebastian" again**, and you can **interrupt him mid-answer** (barge-in) just by talking.

This is the *input* half of the appliance, mirroring the OpenClaw gateway that already provides the *output* half. Speech-to-text runs **locally** (whisper.cpp) in its **own process** — the Voice Gateway.

## Why

Today Ziel is display-only: OpenClaw replies flow in and the face shows/speaks them. There is no way to talk *to* it. Voice input turns a passive display into a two-way appliance you can actually converse with — and because OpenClaw's agent already has tools (WhatsApp, etc.), "Sebastian, send me the answer on WhatsApp" just works: Ziel injects the raw sentence and the agent interprets the intent.

## Scope

**In v1:** wake word "Sebastian", local whisper STT, inject to OpenClaw main session, reply via existing path, follow-up window, **barge-in**, audio-device selection for echo cancellation, graceful degradation.

**Not in v1:** software acoustic echo cancellation (we rely on hardware/physics — see Audio & Echo), cancelling OpenClaw's in-flight generation on barge-in, non-English models, streaming partial transcripts, speaker identification.

## Requirements

1. **Wake word** "Sebastian" wakes it from cold idle.
2. **Follow-up** turns need no wake word for a short window after Sebastian finishes.
3. **Barge-in**: talking while Sebastian is speaking stops him immediately and starts a new turn.
4. **Tool actions**: the raw transcript goes to OpenClaw's main agent session; the agent interprets intent and uses its tools. Ziel does no NLU.
5. **Channel answers still surface**: because Ziel already `sessions.subscribe`s to all sessions, when the agent replies via a channel (e.g. WhatsApp) Ziel still receives and speaks it, with the existing main-session dedup.
6. **Never block the face**: like speech (TTS), voice is optional and every failure path degrades to the current display-only behavior. Off by default.

## Conversation State Machine (Core, clock injected)

Barge-in and follow-up are the same idea — "conversation is active → listen without the wake word" — differing only in whether Sebastian is currently speaking.

```
              wake word "Sebastian" detected
   ┌────────┐ ─────────────────────────────► ┌───────────────┐
   │  IDLE  │                                 │  LISTENING     │ VAD captures utterance
   │(armed, │ ◄───────────────────────────── │  (no wake word)│ ─► transcript ─► inject
   │ wake-  │   follow-up window elapsed       └───────┬───────┘
   │ word   │   with no speech                         │ reply arrives, face speaks
   │ only)  │                                          ▼
   └────────┘                                  ┌───────────────┐
        ▲                                      │  SPEAKING      │ mic stays live
        │  follow-up window elapsed (silent)   │  (barge-in     │
        └───────────────────────────────────  │   armed)       │
                                               └───────┬───────┘
                              user speaks (barge-in) ──┘   │ finishes speaking
                              → stop + drop pending        ▼
                              → back to LISTENING    ┌───────────────┐
                                                     │ FOLLOW-UP WIN │ VAD, no wake word
                                                     │ (N seconds)   │ speech → LISTENING
                                                     └───────────────┘  silence → IDLE
```

- **Cold IDLE** → only "Sebastian" triggers.
- **Conversation active** (LISTENING / SPEAKING / FOLLOW-UP) → user speech is captured with no wake word.
- **SPEAKING**: user speech = barge-in → app stops playback + `dropPendingSpeech`, the utterance becomes the next turn.
- **FOLLOW-UP**: `followUpWindowSeconds` of silence ends the conversation → IDLE.
- Conversation **context is free**: every turn injects into the same long-lived OpenClaw main session, so the agent already remembers prior turns. The wake word gates *listening*, not context.

The state machine lives in **Core** as a pure, unit-tested type (`ConversationController` or similar) with time injected (`now:`), consistent with the "clock always injected" invariant. It consumes voice events + Director speaking state and emits commands (arm wake-word / open listen / open follow-up) + "inject this transcript".

## Architecture / Data Flow

```
mic ─► [ Voice Gateway process ]                         [ App (coordinator + OpenClaw hub) ]
        AVAudioEngine input                               VoiceGatewayClient (new)
        ─► VAD segmentation                    events     ─► ConversationController (Core)
        ─► whisper.cpp STT           ───────────────────► ─► on "heard": GatewayClient.sendPrompt(text)  ──► OpenClaw main session
        ─► wake-word spotting ("Sebastian" prefix)         ◄─ commands (arm / listen / follow-up)
                                     ◄───────────────────  ─► tracks Director speaking → drives states + barge-in stop
                                        local WebSocket
                                        ws://127.0.0.1:18790

OpenClaw reply (main OR channel session) ─► existing GatewayClient ─► OpenClawTranslator ─► Director ─► face displays/speaks ✓  (unchanged)
```

- **App is the single OpenClaw connection and the conversation coordinator.** The Voice Gateway never talks to OpenClaw.
- **Voice ↔ App is a local WebSocket**, mirroring the existing gateway/mock pattern (Network.framework), so it is testable in-process with a mock.

## Components

### 1. Voice Gateway (new — `Sources/VoiceGatewayKit/` + `VoiceGateway/` CLI)

Mirrors `MockGatewayKit` + `MockGateway`: a library (in-process testable) wrapped by a CLI the appliance runs as a second local service. Owns all heavy audio/ML concerns so they stay out of the render process. Responsibilities:

- **Mic capture** via `AVAudioEngine` input node, resampled to 16 kHz mono PCM (whisper's input format).
- **VAD segmentation**: a lightweight voice-activity detector (WebRTC VAD; Silero-ONNX noted as a more robust alternative) gates capture into utterances — start on speech, end on trailing silence. Prevents running whisper on room noise.
- **STT**: whisper.cpp transcribes each finalized utterance. Model configurable (`base.en` default; `small.en` for more accuracy). Model file resolved from `voice.modelPath` (bundled or downloaded once).
- **Wake-word spotting**: reuse whisper — in IDLE, only utterances whose transcript begins with the wake word ("sebastian", case/punctuation-insensitive) count; the wake word is stripped and the remainder is the command (single-utterance "Sebastian, what's the weather" works). In conversation-active states, every utterance is a command (no wake word). This avoids a second ML dependency; a dedicated wake-word engine (openWakeWord custom model) is a noted optimization if idle CPU is too high.
- **Protocol** over the local WS:
  - Gateway → App events: `wake`, `listening`, `heard {text}`, `vad {speaking:bool}`, `error {message}`.
  - App → Gateway commands: `mode {armed | listen | followup | speaking}` (controls whether the wake word is required and whether the mic is armed for barge-in), plus `stop`.

### 2. App coordinator (`App/` + Core)

- **`VoiceGatewayClient`** (new, App or Gateway layer): connects to `ws://127.0.0.1:18790`, reconnecting like `GatewayClient`; surfaces events to the coordinator; sends mode commands.
- **`ConversationController`** (Core, pure): the state machine above. Inputs: voice events, Director speaking state, injected `now`. Outputs: gateway mode commands, follow-up-window timing, and "inject transcript T".
- **Injection**: on a final command transcript, the app calls a new `GatewayClient.sendPrompt(text:)` against OpenClaw's main session (see Input Path).
- **Barge-in**: when a `vad speaking` / `heard` event arrives while Director is `.speaking`, the coordinator calls `Director.dropPendingSpeech` + stops current playback (reusing the existing crash-fix machinery), then treats the utterance as the next turn.

### 3. Input Path into OpenClaw — **open risk + research step**

The verified protocol facts are all receive-side (`sessions.subscribe` → `agent`/`chat` events). Submitting a user prompt *into* the main session from a `ui`-mode client is **not yet verified**. Therefore:

- **First implementation task is a research spike**: confirm the OpenClaw gateway method for a `ui` client to submit a user message/prompt to the main session (e.g. a `session.prompt` / `chat.send`-style request), verified against the running gateway, and record the frame in this repo's protocol notes (as done for the other frames).
- **`OpenClawTranslator`** gains the outbound frame builder; **`GatewayClient`** gains `sendPrompt(text:)`. All OpenClaw knowledge stays in the translator (invariant).
- **Fallback if a `ui` client cannot inject**: document and choose among (a) a different OpenClaw input endpoint, or (b) a minimal local relay — decided during the spike, before building the rest. The rest of the design (Voice Gateway, state machine, barge-in) is independent of how injection lands.

### 4. Output Path — unchanged

Replies (main session, or channel sessions like WhatsApp when the agent routes there) arrive on the **existing** `GatewayClient` → `OpenClawTranslator` → `Director` → face. Ziel keeps `sessions.subscribe`-ing to all sessions with main-session dedup, so channel answers are still surfaced/spoken. **No output-side changes.**

### 5. Audio & Echo (barge-in)

Barge-in needs the mic live while Sebastian speaks *without* the mic triggering on his own voice. We do **not** implement software AEC. Instead:

- **Production**: Anker PowerConf S3 — mic + speaker in one USB unit with hardware echo cancellation. TTS output and mic input both route to it, so it cancels its own speaker from its own mic.
- **Interim testing**: AirPods — output is in-ear, so the mic hears almost none of Sebastian; barge-in *logic* is fully testable before the PowerConf arrives.
- Therefore **input and output must be selectable and set to the same device**. New config `voice.inputDevice` / `voice.outputDevice` (empty = system default). The Voice Gateway selects the input device; the app's TTS playback selects the output device.

### 6. Config (`Sources/Core/Config.swift`, `config.json`) — live-reloadable

```json
"voice": {
  "enabled": false,
  "wakeWord": "Sebastian",
  "gatewayURL": "ws://127.0.0.1:18790",
  "model": "base.en",
  "modelPath": "",
  "inputDevice": "",
  "outputDevice": "",
  "followUpWindowSeconds": 8,
  "bargeIn": true
}
```

- New `VoiceConfig`, `Codable` with `decodeIfPresent` defaults (mirrors `SpeechConfig`/`WaveformConfig`); added to `ZielConfig` and `config.example.json`.
- Off by default (`enabled: false`). When disabled, the app never connects to the Voice Gateway and behavior is exactly as today.

## Error Handling / Degradation (invariant)

Voice is optional and must **never** block the face:

- No mic / Voice Gateway down / connect fails → app logs and runs display-only; reconnect in the background like `GatewayClient`.
- whisper load/transcribe failure → the Voice Gateway reports `error`; the app stays in its current state; no crash.
- OpenClaw injection failure → surface a brief thinking/settle and return to IDLE; never wedge.
- `voice.enabled: false` → the Voice Gateway is not contacted at all.

## Testing

- **Core, unit-tested:**
  - `ConversationController`: IDLE requires wake word; wake → LISTENING; transcript → "inject" + enters SPEAKING on reply; barge-in during SPEAKING emits stop+drop and returns to LISTENING; FOLLOW-UP opens after speaking and times out to IDLE after `followUpWindowSeconds`; all with injected `now`.
  - Wake-word parsing: leading "Sebastian"/"sebastian,"/"Sebastian." stripped → command remainder; non-wake utterances ignored in IDLE, accepted in active states.
  - `VoiceConfig` decode: missing keys → defaults; partial JSON respected.
- **VoiceGatewayKit:** protocol framing (events/commands) via an in-process mock (MockGateway-style); VAD segmentation on fixture PCM; whisper wrapper on a fixed WAV fixture → expected text (integration test, may be `--ignored`/opt-in due to model size).
- **App/audio (not unit-testable) → on-device:** mic capture + device selection, end-to-end wake→ask→answer, follow-up, and **barge-in** (AirPods interim, PowerConf for open-air). Explicitly a manual on-device checklist.
- `make test` (CoreTests) stays green.

## Hardware Dependency

Microphone required. Confirmed empirically: the appliance is `Mac16,10` (M4 Mac mini, 2024) with **no built-in mic and no audio input device present**. Anker PowerConf S3 ordered (arriving in days). Interim development/testing uses AirPods. The feature can be built and unit-tested without the hardware; on-device runs wait for a capture device.

## Build Order (high level — the plan will detail)

1. **Research spike**: verify OpenClaw `ui`-client prompt injection; record the frame or pick the fallback. *(De-risks everything else.)*
2. `ConversationController` state machine in Core (TDD).
3. `VoiceGatewayKit` protocol + service skeleton with a mock STT + CLI.
4. whisper.cpp integration (STT on a fixture).
5. Mic capture + VAD + wake-word ("Sebastian" prefix).
6. App `VoiceGatewayClient` + coordinator wiring + `GatewayClient.sendPrompt`.
7. Follow-up window.
8. Barge-in (drop pending + stop), tested with AirPods.
9. Audio-device selection (input+output) for PowerConf AEC.
10. Config, degradation, README/docs.

## Out of Scope / Future

- **Software AEC** — rely on hardware (PowerConf) / physics (AirPods). Open-air barge-in without a hardware-AEC device would need it.
- **Cancelling OpenClaw's in-flight generation** on barge-in — v1 stops locally + drops pending; upstream cancel is an enhancement pending protocol support.
- Streaming partial transcripts; non-English models; multi-speaker / speaker ID.
- A dedicated wake-word engine (openWakeWord custom "Sebastian" model) — only if VAD+whisper idle CPU proves too high.
