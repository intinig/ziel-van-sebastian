# Ziel van Sebastian

macOS fullscreen Metal app: a CRT-styled happy-Mac face for a Mac mini + Wokyis M5 dock appliance. Idles green, thinks amber (with tool-activity hint words), speaks OpenClaw's replies white, one big RSVP word at a time, under a full CRT shader (scanlines, bloom, curvature, phosphor persistence).

## Workflow

- **Plan execution: subagent-driven development is our favorite approach** (`superpowers:subagent-driven-development` — fresh subagent per task, spec review then quality review between tasks). Prefer it over inline execution unless told otherwise.
- Design spec: `docs/superpowers/specs/2026-06-04-ziel-van-sebastian-design.md`
- Implementation plan: `docs/superpowers/plans/2026-06-04-ziel-van-sebastian.md` (includes verified OpenClaw gateway protocol facts — consult before touching GatewayClient/translator/mock)

## Build & test

```bash
brew install xcodegen     # one-time
make test                 # xcodegen + xcodebuild test (CoreTests)
make build                # builds app + mock-gateway
make run                  # windowed demo loop, no gateway needed
```

- `*.xcodeproj` is generated (XcodeGen) and gitignored — edit `project.yml`, never the project file.
- Swift language mode 5.10 on purpose (avoids strict-concurrency churn); don't bump without discussion.
- SourceKit diagnostics in editors can be stale/noisy here; `make test` is the source of truth.

## Architecture (one line each)

- `Sources/Core/` — platform-free logic, fully unit-tested, clock always injected (`now:` params, no `Date()`)
- `Sources/Gateway/` — `GatewayClient` (WS, reconnect) + `OpenClawTranslator` (the ONLY place that knows OpenClaw frames)
- `Sources/MockGatewayKit/` + `MockGateway/` — in-repo mock gateway server (library + CLI) for tests/demos
- `Sources/Rendering/` — Metal: scene pass → CRT post-process pipeline
- `Sources/Speech/` — `SpeechCoordinator` (ordered sentence pipeline) + `ElevenLabsTTS` (with-timestamps fetch, AVAudioEngine playback); seam: `SpeechSynthesizing`
- `App/` — AppKit shell, DisplayManager (Wokyis panel targeting)

## Invariants

- **Face geometry is locked** (`FaceGeometry.swift`, validated against the original happy-Mac icon during design). Never "fix" it; `testLockedGeometry` pins it.
- All animation is pure functions of time (`FaceAnimation`) — no stored animation state.
- Real config (`config.json`, contains the gateway token) NEVER goes in git; `config.example.json` is the committed template.
- Heartbeat runs (`isHeartbeat: true`) are dropped in the translator — the face must not wake every 30s.
- **Speech (TTS) is optional and must never block the face** — every failure path (missing key, HTTP error, bad audio) degrades to display-only pacing.
