# Ziel van Sebastian — Design

**Date:** 2026-06-04
**Status:** Approved

## What It Is

A macOS fullscreen app that turns a Mac mini + Wokyis M5 dock into a living appliance face for an AI agent. The dock's 5" screen sits where a classic Macintosh CRT would — the app completes the homage: a happy-Mac face idles on a simulated CRT, wakes when the agent (OpenClaw) works, and speaks its replies one big glowing word at a time.

## Hardware & Context

- **Host:** Mac mini (M4), macOS 15+.
- **Screen:** Wokyis M5 dock, 5" IPS, 1280×720, no touch. Appears to macOS as a regular display.
- **Other displays come and go** (occasional second dock/monitor). The app must target the Wokyis panel specifically and survive display reconfiguration.
- **Agent:** OpenClaw running on the same machine. Mirror **all** sessions/channels — the appliance reflects total inner life.

## Visual Design (locked during brainstorming)

### Adaptive phosphor tint

One CRT, three moods:

| State | Phosphor |
|---|---|
| Idle | Green (P1, `#41ff6a`-ish) |
| Thinking | Amber (P3, `#ffb000`-ish) |
| Speaking | Paper white (`#e6edf5`-ish) |

Exact colors are config-tunable.

### The face

Authentic happy-Mac geometry on a 19×16 pixel grid, uniform stroke weight, rendered as chunky glowing rects:

| Feature | Rect (x, y, w, h) |
|---|---|
| Left eye | (0, 0, 2, 5) |
| Right eye | (17, 0, 2, 5) |
| Nose bar | (9, 0, 2, 11) |
| Nose foot (hooks left) | (6, 9, 3, 2) |
| Smile left corner | (2, 12, 2, 2) |
| Smile bottom | (4, 14, 11, 2) |
| Smile right corner | (15, 12, 2, 2) |

Validated against the original icon during brainstorming (small eyes, long J-nose starting at eye level hooking left, thin stepped smile).

### States & animations

- **Idle (green):** face breathes subtly, blinks every ~7s, occasionally wanders/looks around; after 10 min (configurable) dozes off with pixel "z z Z" rising.
- **Waking (~0.8s transition):** quick double-blink, tint cross-fades green→amber, scanline sweep starts.
- **Thinking (amber):** face stays, eyes shift up-left (pondering), a soft scanline sweep traverses the screen (~2.8s loop). **No thought-dots** — the sweep carries the motion. Below the face, activity hint words cycle from live tool events: `READING…`, `SEARCHING…`, `RUNNING…`, `WRITING…`, unknown tools → tool name uppercased + `…`; default `THINKING…`.
- **Speaking (white):** face fades out; reply streams **RSVP-style — one big word at a time, centered**, with a subtle pop per word. No scrolling, no tiny text, no paragraph layout ever.
- **Settling (~1.2s):** last word lingers in phosphor afterglow and fades; face returns.
- **Offline:** face with closed eyes, dim green, `OFFLINE` hint (`AUTH` hint when the gateway rejects the token).

### Word pacing (RSVP)

Streamed tokens arrive faster than reading speed, so a pacing queue sits between the gateway and the screen:

- Base hold: 280 ms/word (~215 WPM), configurable.
- +60 ms per character beyond 6 (long words).
- +320 ms after sentence-final punctuation; +150 ms after commas/semicolons.
- Backlog catch-up: as the queue grows, holds scale down smoothly to a floor of 0.45×.
- Overlong tokens (URLs, identifiers) shrink-to-fit rather than truncate.
- Markdown is stripped (bold/italic/headers; links → link text). Fenced code blocks collapse to a single `[code]` token.

### CRT shader

Full-screen Metal post-process pass — the emulator-shader architecture:

- Scanlines, phosphor mask (aperture-grille style), bloom (bright-pass + separable blur), barrel distortion, vignette, subtle flicker/noise.
- **Phosphor persistence:** previous frame fed back and blended with decay — real afterglow when words swap and on the settling animation.
- Every parameter is a uniform; every uniform lives in config with live reload, so tuning happens by editing a file while the app runs.

## Architecture

Swift 6, AppKit shell + `MTKView`, pure-Metal rendering (no Core Animation content, no SpriteKit). Project generated with XcodeGen (`project.yml` in repo), CLI-buildable via `xcodebuild`.

Frame flow: **scene pass** (face rects / word quad / hint label) → offscreen texture → **CRT pass** → drawable.

| Component | One job | Depends on |
|---|---|---|
| App / DisplayManager | Find Wokyis panel (by display name; fallback smallest/720p; configurable), borderless fullscreen window, handle display reconfiguration, hide cursor, hold sleep assertion | AppKit, CoreGraphics |
| GatewayClient | WebSocket to OpenClaw gateway (`URLSessionWebSocketTask`), token auth, subscribe to all sessions, reconnect w/ backoff, translate frames → `AgentEvent` | Foundation |
| Director | State machine; consumes `AgentEvent`s, owns transitions/timing, publishes immutable scene snapshot per frame | — |
| WordPacer | RSVP queue with the pacing rules above | Foundation |
| Renderer | Metal scene pass: face = colored rects on the pixel grid; words = Core Text–rasterized glyph textures on centered quads; hint labels | MetalKit, CoreText |
| CRTFilter | The post-process shader + persistence feedback texture | Metal |
| Config | JSON at `~/Library/Application Support/Ziel van Sebastian/config.json`, file-watched live reload | Foundation |

Face geometry is plain data (the rect table above), shared by idle and thinking renderers.

### AgentEvent abstraction

```swift
enum AgentEvent {
    case runStarted(session: String)
    case toolStarted(session: String, tool: String)
    case textDelta(session: String, text: String)
    case runEnded(session: String)
    case connectionUp
    case connectionDown
}
```

All OpenClaw protocol knowledge lives in one translator inside GatewayClient. A future Hermes (or other agent) adapter is a second translator; nothing else changes. The exact OpenClaw gateway message schema is verified against its docs/source during implementation planning.

### State machine

```
idle ──runStarted──▶ waking ──▶ thinking ◀──────────┐
 ▲                               │                  │ (queue drained,
 │                          first textDelta         │  run still active)
 │                               ▼                  │
 └──settling◀── runEnded ── speaking ───────────────┘
        (+ queue drained)
```

**Multi-session policy:** thinking reflects the most recent activity anywhere. Once a run's text is being spoken, the pacer locks to that run until its queue drains — no interleaving words from different conversations. Then the next active run takes focus.

## Error Handling

- **Gateway:** exponential backoff with jitter (1 s → 60 s cap). Malformed frames: log, skip, never crash. Auth failure → distinct `AUTH` offline state.
- **Displays:** Wokyis panel unplugged → window hides, waits for reconfiguration notifications, re-acquires. Fallback order configurable (Wokyis by name → smallest display → hide).
- **Renderer:** never blocks on network; reads Director's immutable snapshot. Drawable/pipeline failures rebuild and continue.
- **Sleep:** no-display-sleep assertion held while running (configurable).
- **Config:** invalid config falls back to last-good + defaults, logs loudly.

## Testing

- **Unit tests** (pure logic): WordPacer timing/backlog, Director transition table (event sequences → expected states), OpenClaw frame translator (canned gateway JSON → `AgentEvent`s), markdown stripper, config decode.
- **Mock OpenClaw gateway server:** a small in-repo WebSocket server (Swift executable target, Network.framework) that speaks the gateway protocol and replays scripted scenario files: happy path, interleaved tools/text, two concurrent sessions, disconnect mid-stream, auth failure, malformed frames. This exercises the real GatewayClient end-to-end without a real OpenClaw.
- **`--demo` mode:** replays a scripted `AgentEvent` sequence in-process (wake → tools → streaming reply → settle), no gateway at all — for developing visuals anywhere.
- **`--window` mode:** 16:9 window on a dev machine instead of claiming a display.
- Shader look is judged by eye using live-reload config knobs; no snapshot tests in v1.

## Operations

- Login item via `SMAppService`; `--install-login-item` flag.
- No UI chrome; Cmd-Q quits. Logging via `os.Logger`.
- Bundle: `Ziel van Sebastian.app`, bundle id `com.gintini.ZielVanSebastian`.
- Repo ships `config.example.json`; the real config (with gateway token) stays out of git.

## Out of Scope (v1)

- Touch/keyboard interaction on the appliance.
- Audio.
- Hermes or other agent adapters (the seam exists; the adapter doesn't).
- Showing full inner monologue / thinking text (hints only).
- Per-session filtering UI (config-only future option).
- Shader snapshot testing.

## Success Criteria

1. On the appliance, the app self-starts, finds the Wokyis panel, and idles with the green face.
2. Real OpenClaw activity wakes the face within ~1 s; tool activity shows correct hint words.
3. Replies stream as readable RSVP words with working backlog catch-up; long replies never scroll or shrink.
4. The CRT look (scanlines, mask, bloom, curvature, persistence) is visibly present and tunable live.
5. Survives all scripted mock-gateway scenarios and display unplug/replug without restart.
6. Runs for days unattended without leaking memory or losing the gateway connection permanently.
