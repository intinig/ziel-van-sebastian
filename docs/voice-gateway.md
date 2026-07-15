# voice-gateway

`voice-gateway` is a standalone CLI process, separate from the main app: it
listens to a microphone, gates on a wake word ("Sebastian, …"), transcribes
locally with whisper.cpp, and emits events over a loopback WebSocket. Phase 2a
ships the service itself, fully working end to end; nothing in the app
consumes its events yet — that wiring (`VoiceGatewayClient`, coordinator,
barge-in) is Phase 3. Building or running `voice-gateway` today has no effect
on the face.

Architecture and protocol details live in
`docs/superpowers/specs/2026-07-01-voice-gateway-design.md` and the Phase 2a
plan (`docs/superpowers/plans/2026-07-02-voice-gateway-phase2a.md`). This doc
is the operational reference: build it, get models, run it, configure it,
install it as a launchd agent, and fix the things that go wrong.

## Build

```
make vendor    # one-time: builds whisper.cpp v1.9.1 static libs into gitignored Vendor/
make gen       # regenerate ZielVanSebastian.xcodeproj (XcodeGen)
```

`voice-gateway` is **not** part of the main `ZielVanSebastian` scheme (i.e.
plain `make build` does not build it) — it links vendored whisper.cpp and
lives on its own `VoiceGatewayTests` scheme, which builds both the
`VoiceGateway` tool target and its opt-in test target:

```
xcodebuild -project ZielVanSebastian.xcodeproj -scheme VoiceGatewayTests \
  -configuration Debug -derivedDataPath build -destination 'platform=macOS' build
```

Binary lands at `build/Build/Products/Debug/voice-gateway`.

(`make test-voice` does a build via this same scheme as a side effect of
running the opt-in tests — see Testing below.)

## Models

```
make models                          # ./scripts/fetch-voice-models.sh (default: base.en)
./scripts/fetch-voice-models.sh base small   # fetch specific whisper.cpp models instead
```

Fetches into `~/Library/Application Support/Ziel van Sebastian/models/`:

- `ggml-<model>.bin` for each model name given (default `base.en` when none
  are given) — any whisper.cpp repo model suffix works (`base.en`, `base`,
  `small`, `small.en`, `medium`, ...); see
  https://huggingface.co/ggerganov/whisper.cpp for the full list
- `ggml-silero-v5.1.2.bin` — Silero VAD model, always fetched

The script is idempotent (skips files that already exist), so re-running it
after a partial/interrupted fetch is safe.

## Run

```
./build/Build/Products/Debug/voice-gateway [path/to/config.json]
```

With no argument it defaults to the app's own config file —
`~/Library/Application Support/Ziel van Sebastian/config.json` — and reads
its `voice` section. This is the same file the app uses, so a single
`config.json` configures both.

All logging goes to stderr, prefixed `[voice-gateway]`:

```
[voice-gateway] listening on ws://127.0.0.1:18790, model=/Users/you/Library/Application Support/Ziel van Sebastian/models/ggml-base.en.bin
[voice-gateway] mic capture running (device: system default)
[voice-gateway] event: vad(speaking: true)
[voice-gateway] event: vad(speaking: false)
[voice-gateway] event: wake
[voice-gateway] event: heard(text: "what's the weather")
```

**The process does not consult `voice.enabled`.** Starting `voice-gateway` is
what turns voice input on; stopping it turns it off. Whatever the app does
with `voice.enabled` is Phase 3's concern, not this service's — running the
binary always spins up the full mic → VAD → whisper → events pipeline.

## Config keys (`voice.*` in `config.json`)

| Key | Default | Used by voice-gateway today? | Notes |
|---|---|---|---|
| `wakeWord` | `"Sebastian"` | yes | Leading-word match against each transcript; case- and diacritic-insensitive, requires a word boundary (`"Sebastians car"` does not match). |
| `gatewayURL` | `"ws://127.0.0.1:18790"` | yes (port only) | Only the **port** is parsed out of this URL for the service's own WS listener; a missing/malformed port falls back to `18790`. The listener always binds loopback-only regardless of any host you put here — see Troubleshooting. |
| `model` | `"base.en"` | yes | Selects `ggml-<model>.bin` under the models directory when `modelPath` is empty. |
| `modelPath` | `""` (empty) | yes | Explicit path to a whisper ggml model, overriding `model` and the models-directory convention. |
| `vadModelPath` | `""` (empty) | yes | Explicit path to the Silero VAD ggml model; empty resolves to `ggml-silero-v5.1.2.bin` in the models directory. |
| `inputDevice` | `""` (empty) | yes | Case-insensitive **substring** match against CoreAudio input device names (e.g. `"PowerConf"` matches "Poly PowerConf S3 USB"). Empty means "system default input" — see the Bluetooth caveat below. |
| `languages` | `[]` (empty) | yes | Clamp whisper language auto-detection to this set, e.g. `["it", "en"]`; empty = detect among all languages. Unknown codes are ignored (logged once); English-only (`*.en`) models always ignore this (there's only one language to pick). |
| `enabled` | `false` | no | Reserved for Phase 3's app-side wiring; the standalone service ignores it entirely (see Run, above). |
| `outputDevice`, `wakeModelPath`, `wakeThreshold`, `followUpWindowSeconds`, `bargeIn` | — | no | Present in `VoiceConfig` for forward-compatibility with Phase 2b (openWakeWord) and Phase 3 (barge-in, app injection). This service reads none of them today. |

## Microphone permission (TCC)

The **first launch must happen in a logged-in GUI session** — a physical
console login or screen share, not a bare `ssh` session. macOS attributes the
microphone permission prompt to whatever launched the process, and only a
logged-in GUI session can display and answer that prompt.

If the process starts in an unattended/headless context while permission is
still `.notDetermined`, it blocks indefinitely inside
`AVCaptureDevice.requestAccess` waiting for a grant that has no way to arrive.
This is a known limitation of the current implementation and is documented
here rather than worked around in code (there is no request timeout). If a
freshly-installed `voice-gateway` appears to hang with no log output past
`mic capture running`, suspect exactly this — kill it and re-run once, by
hand, at the console.

Once granted, the permission persists across restarts — including launchd's
`RunAtLoad` relaunches — with no session required. Because this binary is ad
hoc–signed (no Developer ID; see `project.yml`'s `CODE_SIGN_IDENTITY: "-"`),
rebuilding it can occasionally cause macOS to treat it as a different app for
TCC purposes. If mic capture unexpectedly hangs again right after a rebuild
or redeploy, check **System Settings → Privacy & Security → Microphone** for
a stale or duplicate `voice-gateway` entry before assuming a code regression.

If permission was already denied, `voice-gateway` fails fast instead of
hanging — `AudioCapture.start()` throws and the process logs and exits:

```
[voice-gateway] fatal: microphone access denied — grant it in System Settings → Privacy & Security → Microphone
```

Fix: grant access in **System Settings → Privacy & Security → Microphone**
and restart the process (no need to reinstall).

## launchd install (appliance)

1. **Install the binary somewhere stable.** This repo doesn't prescribe a
   location — `scripts/deploy.sh` is gitignored and owner-maintained; add a
   step there to copy the built `voice-gateway` binary to wherever your
   deploy flow puts things, and note the resulting path.

2. **Run it once by hand, logged in at the console**, before handing it to
   launchd (see TCC above — a launchd-launched process cannot answer the
   mic-permission prompt). Launch it directly from Terminal, say the wake
   word once to confirm `event: wake` / `event: heard(...)` on stderr, then
   `Ctrl-C` it.

3. **Create the log directory** (launchd does not create parent directories
   for `Standard{Out,Error}Path`):

   ```
   mkdir -p ~/Library/Logs/ziel
   ```

4. **Copy and edit the plist template:**

   ```
   cp scripts/ziel.voice-gateway.plist.example \
     ~/Library/LaunchAgents/com.gintini.ziel.voice-gateway.plist
   ```

   Edit the copy: set `ProgramArguments` to the real, absolute path from step
   1, and the log paths to your real home directory (`~` is not expanded
   inside a plist).

5. **Load it:**

   ```
   launchctl bootstrap gui/$(id -u) \
     ~/Library/LaunchAgents/com.gintini.ziel.voice-gateway.plist
   ```

6. **Check it's alive and watch logs:**

   ```
   launchctl print gui/$(id -u)/com.gintini.ziel.voice-gateway
   tail -f ~/Library/Logs/ziel/voice-gateway.log
   ```

7. **After editing the plist or replacing the binary**, unload and reload:

   ```
   launchctl bootout gui/$(id -u)/com.gintini.ziel.voice-gateway
   launchctl bootstrap gui/$(id -u) \
     ~/Library/LaunchAgents/com.gintini.ziel.voice-gateway.plist
   ```

## Testing

- `make test` — hermetic CoreTests, 196 tests, no `Vendor/` or models needed.
  Nothing about voice-gateway docs or config should ever break this.
- `make test-voice` — 2 opt-in tests exercising the real whisper/VAD models;
  needs `make vendor` and `make models` to have been run first.

## Troubleshooting

**`fatal: no input device matching "<name>"`** — `voice.inputDevice` didn't
match any CoreAudio input device by case-insensitive substring. Check
**System Settings → Sound → Input** for the exact device name and use a
substring of it.

**Startup fails / port already in use** — another process (or a second
`voice-gateway`) is already bound to the configured port. `server.start()`
fails, the process logs a `[voice-gateway] fatal: …` line, and exits. Fix:
pick a different port by editing `voice.gatewayURL`'s port, e.g.
`ws://127.0.0.1:18791`. Note the WS listener is loopback-only by a
kernel-enforced bind (`NWParameters.requiredInterfaceType = .loopback`)
regardless of what host you write in `gatewayURL` — this is deliberate
(no-auth-by-design; see the spec addendum) and not something a port change
works around.

**Bluetooth default-input flakiness** — on a Mac with a paired Bluetooth
audio device (e.g. AirPods), macOS can silently re-assert it as the system
default input within a second or two of any new audio session, even after
you've explicitly selected something else. On the appliance this means
"system default" is not a safe choice: **always pin `voice.inputDevice`**
to a specific device by name substring — `"AirPods"` as an interim appliance
mic before the PowerConf arrives, `"PowerConf"` for the production
configuration (hardware AEC, open-air). If wake words silently stop
triggering despite the process running normally, suspect the default input
having rerouted out from under an unpinned config first.

**Mic access denied** — see Microphone permission (TCC) above.

**High CPU at idle** — should not happen; VAD gates whisper, so silence
means near-zero CPU. If it doesn't, verify `voice.inputDevice` is actually
picking up the intended mic and not a noisy/open channel that's keeping the
VAD tripped (check Activity Monitor and confirm silence in the room
correlates with no `event: vad(speaking: true)` in the log).
