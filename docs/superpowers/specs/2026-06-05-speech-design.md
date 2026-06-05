# Ziel van Sebastian — Speech (TTS) Design

**Date:** 2026-06-05
**Status:** Approved

## What It Is

Optional text-to-speech for the appliance: when enabled, the Mac mini's speaker reads OpenClaw's replies aloud while the RSVP display shows each word **exactly when it is heard**. Speech is config-gated and off by default; with it off (or on any failure), the face behaves exactly as today.

## Why direct ElevenLabs API (not sag)

The original idea was shelling out to [sag](https://github.com/steipete/sag/), a Go CLI wrapping ElevenLabs. Investigation during brainstorming found the raw API offers two things sag doesn't expose, and they change the product:

| Capability | Endpoint | What it gives us |
|---|---|---|
| Character-level timestamps | `POST /v1/text-to-speech/{voice_id}/stream/with-timestamps` | Streamed JSON chunks of base64 audio + per-character timing → word timings → true audio/display sync |
| Streaming text input | `WSS /v1/text-to-speech/{voice_id}/stream-input` | Feed text deltas as they arrive |

Decision: **HTTP `stream/with-timestamps`, one request per sentence.** True sync with moderate complexity; no subprocess, no external binary on the appliance. The WebSocket variant is the upgrade path if per-sentence latency ever disappoints. The official ElevenLabs Swift SDK was evaluated and rejected — it targets their conversational-agents product (LiveKit WebRTC, microphone-driven), not raw TTS.

## Data Flow

```
textDelta ─► Director.route ──(speech off)──► WordPacer (today's path, unchanged)
                    │
                    └─(speech on)──► SentenceChunker ─► SpeechCoordinator (App side)
                                                            │  POST /stream/with-timestamps
                                                            │  per sentence, queued in order
                                                            ▼
                                              audio chunks + char alignment
                                                            │
                                  AVAudioEngine playback ─► Mac mini speaker
                                                            │
                                  Director.speak(words: [WordTiming], startedAt: now)
                                                            ▼
                                       tick(now:) picks currentWord by elapsed time
```

- The face stays in `.thinking` until the first sentence's audio is ready, then enters `.speaking` in sync with the voice.
- Sentences pipeline: sentence N+1 generates while N plays; playback is strictly ordered.
- `previous_request_ids` stitching keeps voice continuity across per-sentence requests.
- Heartbeat runs are already dropped in the translator and never reach speech.
- Focus discipline is unchanged: only the focused run speaks, pending runs queue as today.

## Core Changes (platform-free, fully unit-tested)

- **`SentenceChunker`** — accumulates stripped deltas, emits complete sentences; `flush()` on `runEnded` emits any trailing fragment. Pure.
- **`AlignmentMapper`** — ElevenLabs character alignment → `[WordTiming(word, start, duration)]`. Pure.
- **`Director`** — gains a timed-word source alongside `WordPacer`: when a spoken sentence is delivered via `speak(words:startedAt:)`, `tick(now:)` selects `currentWord` from the timeline instead of the pacer. Remains a pure function of time — audio start arrives as a `now:` parameter like every other event. **Per-sentence fallback:** if TTS fails for a sentence, that sentence's text feeds the `WordPacer` and displays at reading pace; the next sentence tries speech again.
- **Core→App handoff stays pure:** the Director never holds a reference to the coordinator. It queues outbound sentences as plain data; the App-side `SpeechCoordinator` drains them on the frame tick and reports outcomes back as calls with `now:` (`speak(words:startedAt:)` on success, a fallback call on failure).

## New `Sources/Speech` Target

- **`ElevenLabsTTS`** — URLSession streaming request to `/v1/text-to-speech/{voice_id}/stream/with-timestamps`, parses the JSON chunk stream, base64-decodes PCM, schedules buffers on `AVAudioEngine`.
- **`SpeechCoordinator`** — owns the sentence queue, request pipelining, ordering, and fallback signaling to the Director.
- **Protocol seam** (`SpeechSynthesizing`) so coordinator logic tests against a fake — same pattern as the gateway/mock split.
- AVFoundation stays out of `Sources/Core` (which remains platform-free).

## Language & Voice

Replies can arrive in any language. The multilingual models auto-detect language from the text; `eleven_flash_v2_5` (our default) supports 32 languages and keeps the configured voice's character consistent across them — one voice reads everything.

Two design consequences:

- **Per-sentence requests weaken auto-detection** (a short sentence is little signal). The `previous_text` + `previous_request_ids` stitching already in the data flow also gives the model surrounding context, which mitigates this.
- **Optional language pin:** the API's `language_code` (ISO 639-1) enforces a language; flash v2.5 supports enforcement. Exposed as optional `languageCode` config for appliances that mostly speak one language. Unset (default) = auto-detect. Unsupported model/code combinations are an API error → caught at startup validation, logged, treated as unset.

Voice choice is taste: browse the [voice library](https://elevenlabs.io/app/voice-library), prefer voices tagged multilingual, put the ID in config. No hardcoded default; `config.example.json` documents the quickstart "George" (`JBFqnCBsd6RMkjVDRZzb`) as a known-working starter.

## Config

New optional `speech` section in `config.json` (gitignored, alongside the gateway token); `config.example.json` gains placeholders:

| Field | Default | Notes |
|---|---|---|
| `enabled` | `false` | Existing config watcher makes toggling live, no restart |
| `apiKey` | — | ElevenLabs API key; required when enabled |
| `voiceId` | — | Required when enabled; see Language & Voice |
| `modelId` | `eleven_flash_v2_5` | ~75 ms latency, half-price per character, 32 languages |
| `languageCode` | unset | Optional ISO 639-1 pin; unset = auto-detect per sentence |
| `speed` | `1.0` | Voice speed multiplier |
| `volume` | `1.0` | AVAudioEngine mixer volume, 0–1 |

## Error Handling

Audio must never block the face. Every failure degrades to today's display behavior:

- Missing/invalid key or voice → log once, speech disabled for the session.
- Per-sentence request failure or timeout (~10 s) → pacer fallback for that sentence only; subsequent sentences retry speech.
- Mid-stream audio error → stop playback, pacer fallback for remaining text of that sentence.

## Testing

- Core additions fully unit-tested with injected clocks: chunker edge cases (abbreviations, trailing fragments, markdown-stripped input), alignment mapping, Director speech-mode transitions and fallback paths.
- `SpeechCoordinator` tested against a fake `SpeechSynthesizing`.
- The URLSession/AVAudioEngine layer stays thin and is verified manually via `make run` with speech enabled.

## Out of Scope (v1)

- WebSocket `stream-input` integration (upgrade path).
- Speaking thinking-phase hint words or state announcements — replies only.
- Per-session/per-run voice selection; one configured voice.
