# Ziel van Sebastian — Speaking Waveform (Radial Halo + Water Ripple)

**Date:** 2026-07-01
**Status:** Approved

## What It Is

While Ziel speaks, the screen comes alive: the RSVP word sits inside a **radial halo** that breathes with loudness, and the whole phosphor surface **ripples like water** — continuous concentric waves whose intensity tracks the voice. Both are driven by the **real TTS amplitude**, config-gated, and default on. Idle/thinking/offline are unchanged.

Design was validated with an animated WebGL demo (Look C + ripple); the chosen defaults are ripple strength `0.10`, speed `2.0`.

## Why

Today the speaking state shows a single big word popping in and out. It reads as "text on a screen," not "something alive talking." A voice-reactive halo + water ripple gives the appliance presence during speech without touching the locked face geometry (the face isn't drawn while speaking anyway).

## Key Behavior: decoupled from word cadence

The RSVP words flash by **fast** and the audio is **continuous** — nothing like the demo's one-word-per-second cadence. So:

- The waveform is driven by a **continuous amplitude envelope** computed from the real PCM (smoothed RMS windows), not per-word spikes.
- The ripple's **motion is time-driven** — a continuous concentric flow that never resets on a word or sentence boundary. It "keeps moving without ever stopping" while speaking; its *intensity* rides the envelope.
- `level` is **smoothed with a short attack/release**, so the small fetch gaps between chained sentences don't snap it to zero mid-reply. It only settles to flat when speech actually ends.
- The fast RSVP word is an **independent layer** on top; it never resets the halo or ripple.

## Architecture / Data Flow

```
SpokenAudio.pcm ──(Core)──► AmplitudeEnvelope.from(pcm:sampleRate:) ─► envelope:[Float] @ envelopeRate
        │ (carried on SpokenAudio, computed once when the audio is parsed)
        ▼
SpeechCoordinator.play ─► Director.speechStarted(id:words:envelope:envelopeRate:startedAt:now:)
        ▼
Director.tick(now:)  ─► raw = envelope sampled at (now − startedAt), else 0
                        level = smooth(raw)   // attack/release, per-tick dt
        ▼
SceneState.level (0…1)
        ▼
ZielRenderer ─► ScenePass.drawHalo(level…)         // scene pass (gets CRT bloom)
            └─► CRT fragment shader ripple displacement(level, time, strength, speed)
```

No live audio tap: `level` stays a pure function of injected time + precomputed envelope, consistent with the "clock always injected" Core invariant.

## Components

### 1. Amplitude envelope (Core — `Sources/Core/`)

- New pure function, e.g. `AmplitudeEnvelope.from(pcm: Data, sampleRate: Double, rate: Double = 60) -> [Float]`: windowed RMS over the 16-bit LE PCM, one sample per `1/rate` seconds, soft-kneed and clamped to 0…1. Deterministic and unit-testable.
- `SpokenAudio` (in `SpeechTypes.swift`) gains `envelope: [Float]` and `envelopeRate: Double`. Computed once in `ElevenLabsTTS.parseResponse` (calls the Core function) so the App layer holds no envelope logic.

### 2. Level sampling + smoothing (Core — `Director`)

- `QueuedSentence` gains `envelope: [Float]` and `envelopeRate: Double`, set in `speechStarted`.
- `Director.speechStarted` signature extends to carry the envelope alongside `words`.
- `Director` holds `smoothedLevel: Double` and `lastLevelTick: TimeInterval`. In `tick(now:)`:
  - `raw` = envelope value at `(now − head.startedAt) * envelopeRate` (linear-interpolated), only when the playing head has an envelope; otherwise `0`.
  - `dt = now − lastLevelTick`; `tau = raw > smoothedLevel ? attack : release`; `smoothedLevel += (raw − smoothedLevel) * (1 − exp(−dt/tau))`.
  - Exposed as `SceneState.level`.
- `SceneState` gains `public let level: Double`. All constructors updated (incl. the offline fallback in `AppDelegate`’s `sceneProvider` and test fixtures → `level: 0`).

### 3. Rendering (App/Metal — `Sources/Rendering/`)

- **Halo (scene pass):** `ScenePass.drawHalo(encoder:viewW:viewH:level:tint:…)` draws concentric rings centered on the word; radius/brightness from `level`. Called from `ZielRenderer.drawScene`’s `.speaking` case (before the word so the word stays on top), gated by `waveform.enabled`.
- **Ripple (CRT post-process):** `Shaders.metal`’s CRT fragment shader gains a radial UV-displacement term applied before sampling the scene texture — matching the demo: `wave = sin(dist·k − time·speed)`, displacement `= dir · wave · strength · (0.15 + 0.85·level) · edgeFalloff`, plus a faint chromatic split for the "glassy" read. New uniforms: `rippleEnabled`, `rippleStrength`, `rippleSpeed`, `level`, `time`. Gated off when `!waveform.enabled`, `!ripple.enabled`, or `level ≈ 0`.
- `ZielRenderer.draw` passes `level`, `time`, and the waveform config into the CRT pass each frame.

### 4. Config (`Sources/Core/Config.swift`, `config.json`) — live-reloadable

```json
"waveform": {
  "enabled": true,
  "ripple": { "enabled": true, "strength": 0.10, "speed": 2.0 }
}
```

- New `WaveformConfig { enabled: Bool = true; ripple: RippleConfig }` and `RippleConfig { enabled: Bool = true; strength: Double = 0.10; speed: Double = 2.0 }`, `Codable` with `decodeIfPresent` defaults (mirrors `SpeechConfig`). Added to `ZielConfig` and `config.example.json`.
- `AppDelegate.watchConfig` pushes the fresh `waveform` config to the renderer on reload (like `crt.shaderConfig`/pacing/speech), so all four knobs (`enabled`, `ripple.enabled`, `strength`, `speed`) take effect without restart.

## Testing

- **Core, unit-tested:**
  - `AmplitudeEnvelope.from`: silence PCM → ~0; full-scale tone → high, ≤1; sample count matches `duration · rate`.
  - `Director` level: with a known envelope + `startedAt`, `tick(now)` yields the interpolated+smoothed level; level **eases toward 0** after `speechFinished` (release, not snap); advancing `now` fast across word boundaries keeps `level` continuous and independent of word changes (the cadence property above); `level == 0` when not speaking.
  - `WaveformConfig` decode: missing keys fall back to defaults (`enabled true`, `ripple.enabled true`, `strength 0.10`, `speed 2.0`); partial JSON respected.
- **Metal/AppKit, not unit-testable → build + on-device:** halo geometry, ripple shader, config live-reload of all four knobs, and that toggling `waveform.enabled` / `ripple.enabled` behaves. The WebGL demo already de-risked the look.
- `make test` (CoreTests) stays green.

## Out of Scope / Future

- Idle/thinking shimmer — the waveform is **speaking-state only**.
- Per-word ripple pulses / word-triggered wavefronts — motion is continuous by design.
- Voice input and the appliance channel (separate sub-projects B and C).
- Any change to the locked `FaceGeometry`.
