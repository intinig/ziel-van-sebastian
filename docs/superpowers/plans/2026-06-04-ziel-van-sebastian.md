# Ziel van Sebastian Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS fullscreen CRT-styled agent face for a Mac mini + Wokyis M5 dock that idles as the happy-Mac face, shows amber thinking activity from OpenClaw, and streams replies one big word at a time.

**Architecture:** Pure-Metal two-pass renderer (scene → CRT post-process) driven by a platform-free `Director` state machine. A `GatewayClient` WebSocket connects to OpenClaw's gateway, translates `agent` events into typed `AgentEvent`s. All pure logic is unit-tested; the gateway path is integration-tested against an in-repo mock gateway server.

**Tech Stack:** Swift (language mode 5 on the Swift 6 toolchain — avoids strict-concurrency churn), AppKit + MetalKit, Core Text for glyphs, Network.framework for the mock gateway, XcodeGen + xcodebuild, XCTest.

**Spec:** `docs/superpowers/specs/2026-06-04-ziel-van-sebastian-design.md`

---

## Verified OpenClaw protocol facts (research 2026-06-04, openclaw/openclaw@main; device-auth facts re-verified against released 2026.6.1 dist on vm-claw)

Everything the GatewayClient and mock server implement, verified against source:

- **Endpoint:** `ws://127.0.0.1:18789/` (default port 18789, path `/`). Text frames, JSON payloads. First client frame MUST be the connect request.
- **Connect request** (token auth + device identity):
  ```json
  {"type":"req","id":"connect-1","method":"connect","params":{
    "minProtocol":3,"maxProtocol":4,
    "client":{"id":"gateway-client","version":"1.0.0","platform":"macos","mode":"ui"},
    "role":"operator","scopes":["operator.read"],
    "auth":{"token":"<token>"},
    "device":{"id":"<sha256-hex of raw pubkey>","publicKey":"<base64url raw 32B>",
              "signature":"<base64url Ed25519 sig>","signedAt":<epoch-ms>,"nonce":"<challenge nonce>"}}}
  ```
  `client.id` is a **closed enum** — `"gateway-client"` is the canonical id for external clients (`packages/gateway-protocol/src/client-info.ts`).
- **`client.mode` on released 2026.6.1:** `"ui"` is the correct mode for us. `"operator"` is rejected with INVALID_REQUEST. `"backend"` + `client.id:"gateway-client"` on loopback bypasses device pairing but is *reserved for OpenClaw-internal control-plane RPCs* — do not use it (it trips security review).
- **Scopes are durable per paired device.** A token-auth WS connect *without* a `device` block authenticates but gets `scopes` cleared to `[]` and never enters the pairing queue. With a `device` block: first connect creates a pending pairing request (`openclaw devices approve` once, keyed to the public key), then every reconnect with the same keypair gets the approved scopes.
- **Device auth signing (from `dist/device-identity-*.js`, 2026.6.1):**
  - Keypair: Ed25519. `deviceId` = SHA-256 hex of the raw 32-byte public key. `publicKey` field = base64url (no padding) of the raw key. `signature` = base64url (no padding) of the Ed25519 signature over the UTF-8 payload.
  - Payload (v3): `"v3|{deviceId}|{client.id}|{client.mode}|{role}|{scopes joined ','}|{signedAtMs}|{auth token}|{nonce}|{platform lowercased}|{deviceFamily lowercased or empty}"`.
  - The `token` component is the shared gateway token (`signatureToken = authToken ?? authBootstrapToken` in `client-*.js selectConnectAuth`).
  - OpenClaw stores identity at `~/.openclaw/identity/device.json` as `{version:1, deviceId, publicKeyPem, privateKeyPem, createdAtMs}`.
- **Challenge-first flow:** the gateway pushes `{"type":"event","event":"connect.challenge","payload":{"nonce":"…","ts":…}}` at socket open. The official client *waits* for it and uses its nonce in the device payload (closing the socket on a challenge timeout). Send `connect` only after the challenge when using device identity.
- **Subscription required for channel sessions** (verified empirically against gateway 2026.6.1, 2026-06-04): only the **main** session (`agent:main:main`) broadcasts `agent`/`chat` events automatically after hello-ok. Channel sessions (WhatsApp, iMessage, …) emit **no `agent`/`chat` events at all** — subscribed or not.
- **`sessions.subscribe`:** send `{"type":"req","id":"…","method":"sessions.subscribe","params":{}}` after hello-ok. Empty params = subscribe to **all** sessions (response: `{"subscribed":true}`). Per-key form `params: {"sessionKey": "…"}` also works but is unnecessary. Must be re-sent after every reconnect (subscription is per-connection).
- **Channel-session events** (arrive only after subscribing):
  - `sessions.changed`: `{"type":"event","event":"sessions.changed","payload":{"sessionKey","phase":"start"|"end","runId","ts","session":{…,"origin":{"surface":"whatsapp",…},"status",…}}}` — run lifecycle for channel sessions.
  - `session.message`: `{"type":"event","event":"session.message","payload":{"sessionKey","agentId","messageId","messageSeq","message":{…}}}` — complete (non-streamed) messages. `message.role == "user"` has **string** `content`; `message.role == "assistant"` has `content` as an **array of blocks** (`{"type":"thinking",…}` and `{"type":"text","text":"…"}`). `session.message` has **no `runId`** — correlate to the active run via `sessions.changed`'s `runId` for the same `sessionKey`.
  - There is **no streaming** for channel sessions: the assistant reply arrives as one complete `session.message` after generation finishes.
- **Main-session dedup:** once subscribed, the main session presumably also surfaces via `sessions.changed`/`session.message`; consumers must ignore session.* events for the main session key (from hello-ok `snapshot.health.sessionDefaults.mainSessionKey`, default `agent:main:main`) to avoid double-speaking replies that already streamed via `agent` events.
- **Prompt injection (send a user turn) — `chat.send`** (verified 2026-07-01 against gateway 2026.6.11 by reading OpenClaw's own client lib `dist/gateway-chat-*.js` and the method registry `dist/server-methods-*.js`): a client submits a user message with `{"type":"req","id":"…","method":"chat.send","params":{"sessionKey":"agent:main:main","message":"<text>"}}` (optional: `agentId`, `sessionId`, `thinking`, `deliver`, `timeoutMs`, `idempotencyKey`). Response `{"runId","status"}`; the agent's reply then streams back via the normal `agent`/`turn.*`/`session.message` events we already consume, so the display/speech path needs no change. `chat.inject` is a sibling. **SCOPE GOTCHA:** `chat.send` is a write op, but ziel's paired device (`clientId:"gateway-client"`) is currently granted **`operator.read` only** — so injection will be DENIED until the device is re-approved with a write scope (`operator.write`). Other operator devices on vm-claw carry `operator.write`.
- **`agent` event envelope:** `{"type":"event","event":"agent","payload":{"runId","seq","stream","ts","sessionKey"?,"sessionId"?,"isHeartbeat"?,"data":{...}}}`
- **Streams we consume** (others — `thinking`, `plan`, `item`, etc. — are ignored in v1):
  - `"lifecycle"`: `data.phase` = `"start"` | `"end"` | `"error"`
  - `"tool"`: `data.phase` = `"start"` with `data.name` (tool name), also `"update"`/`"result"` (ignored)
  - `"assistant"`: `data.delta` = incremental text chunk. (A cumulative `data.text` variant exists; we consume **delta only** to avoid duplication.)
- **`isHeartbeat: true`** marks background heartbeat runs — drop them entirely (the face must not wake every 30s).
- **Session identity:** `sessionKey` on the payload (fall back to `runId` when absent).
- We do NOT use `chat` events (throttled UI projection); the raw `agent` stream covers main-session runs only. Channel-session runs are covered by `sessions.changed`/`session.message`.

---

## File structure

```
project.yml                          # XcodeGen project definition
Makefile                             # gen/build/test/run shortcuts
config.example.json                  # committed template (real config never in git)
App/
  main.swift                         # arg parsing, app boot
  AppDelegate.swift                  # wiring: config, director, gateway, window
  DisplayManager.swift               # Wokyis targeting, fullscreen, cursor, sleep
  Info.plist
Sources/Core/                        # platform-free, fully unit-tested
  AgentEvent.swift                   # typed event enum
  FaceGeometry.swift                 # the locked 19×16 rect table
  SceneTypes.swift                   # Phase, ColorRGB, SceneState
  Config.swift                       # ZielConfig + all sub-configs + loader
  HintMapper.swift                   # tool name → hint word
  MarkdownStreamStripper.swift       # streaming markdown removal
  WordPacer.swift                    # RSVP queue + pacing rules
  Director.swift                     # the state machine
  FaceAnimation.swift                # pure time→animation functions
  DemoScript.swift                   # scripted AgentEvent sequence
Sources/Gateway/
  GatewayClient.swift                # WS connect/handshake/reconnect
  OpenClawTranslator.swift           # gateway frames → [AgentEvent]
Sources/MockGatewayKit/
  MockGatewayServer.swift            # NWListener WS server (library, test-importable)
  ScenarioLoader.swift               # scenario JSON → [MockStep]
Sources/Rendering/
  ZielRenderer.swift                 # MTKViewDelegate, pass orchestration
  ScenePass.swift                    # face rects, word quad, hint, sweep
  GlyphRasterizer.swift              # Core Text word → MTLTexture (LRU cache)
  CRTPipeline.swift                  # persistence/bloom/composite passes
  Shaders.metal                      # all shaders
MockGateway/
  main.swift                         # CLI wrapper around MockGatewayKit
  Scenarios/                         # *.json scenario files for manual runs
Tests/                               # XCTest (compiles Core+Gateway+MockGatewayKit directly)
  FaceGeometryTests.swift
  ConfigTests.swift
  HintMapperTests.swift
  MarkdownStripperTests.swift
  WordPacerTests.swift
  DirectorTests.swift
  TranslatorTests.swift
  GatewayIntegrationTests.swift
  FaceAnimationTests.swift
```

Targets: app `ZielVanSebastian` (App + Sources), tool `MockGateway` (MockGateway + MockGatewayKit), test bundle `CoreTests` (Tests + Sources/Core + Sources/Gateway + Sources/MockGatewayKit — no app host, no Metal).

---

### Task 1: Project scaffold

**Files:**
- Create: `project.yml`, `Makefile`, `App/main.swift`, `App/AppDelegate.swift`, `App/Info.plist`, `Tests/SmokeTests.swift`, `MockGateway/main.swift` (stub), `Sources/Core/.gitkeep` equivalent (first real file lands in Task 2 — create `Sources/Core/Placeholder.swift` and delete it in Task 2? No: XcodeGen tolerates empty groups only if path exists; instead point CoreTests at Tests only for now and add source dirs as they appear — see step 1 note)

- [ ] **Step 1: Install XcodeGen** (not present on this machine)

```bash
brew install xcodegen
```
Expected: `xcodegen` on PATH (`xcodegen --version` prints 2.x).

- [ ] **Step 2: Write `project.yml`**

Note: all source directories are listed from the start, so create every directory with its first file in this task (empty `.swift` files are fine placeholders for dirs that get real content later is NOT allowed — instead we create the real trivial files now: `Sources/Core/AgentEvent.swift` stub comes in Task 2, so here we list only dirs that exist this task and EXTEND project.yml in later tasks. To keep edits minimal, create all dirs now with one real file each as shown in steps below).

```yaml
name: ZielVanSebastian
options:
  bundleIdPrefix: com.gintini
  deploymentTarget:
    macOS: "15.0"
settings:
  base:
    SWIFT_VERSION: "5.10"
    CODE_SIGN_IDENTITY: "-"
    CODE_SIGNING_REQUIRED: "NO"
targets:
  ZielVanSebastian:
    type: application
    platform: macOS
    sources:
      - App
      - Sources
    settings:
      base:
        PRODUCT_NAME: Ziel van Sebastian
        PRODUCT_BUNDLE_IDENTIFIER: com.gintini.ZielVanSebastian
        INFOPLIST_FILE: App/Info.plist
  MockGateway:
    type: tool
    platform: macOS
    sources:
      - MockGateway
      - Sources/MockGatewayKit
    settings:
      base:
        PRODUCT_NAME: mock-gateway
  CoreTests:
    type: bundle.unit-test
    platform: macOS
    sources:
      - Tests
      - Sources/Core
      - Sources/Gateway
      - Sources/MockGatewayKit
schemes:
  ZielVanSebastian:
    build:
      targets:
        ZielVanSebastian: all
        MockGateway: all
    test:
      targets:
        - CoreTests
```

- [ ] **Step 3: Write `Makefile`**

```make
PROJECT = ZielVanSebastian
DD = build
APP = $(DD)/Build/Products/Debug/Ziel van Sebastian.app/Contents/MacOS/Ziel van Sebastian

gen:
	xcodegen generate

build: gen
	xcodebuild -project $(PROJECT).xcodeproj -scheme $(PROJECT) -configuration Debug \
	  -derivedDataPath $(DD) -destination 'platform=macOS' build

test: gen
	xcodebuild -project $(PROJECT).xcodeproj -scheme $(PROJECT) \
	  -derivedDataPath $(DD) -destination 'platform=macOS' test

run: build
	"./$(APP)" --window --demo

.PHONY: gen build test run
```

- [ ] **Step 4: Write `App/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>$(EXECUTABLE_NAME)</string>
	<key>CFBundleIdentifier</key><string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
	<key>CFBundleName</key><string>Ziel van Sebastian</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>0.1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>15.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsLocalNetworking</key><true/>
	</dict>
</dict>
</plist>
```

- [ ] **Step 5: Write `App/main.swift`**

```swift
import AppKit

struct RunOptions {
    var window = false
    var demo = false
    var configPath: String?
    var installLoginItem = false

    static func parse(_ args: [String]) -> RunOptions {
        var o = RunOptions()
        var i = 1
        while i < args.count {
            switch args[i] {
            case "--window": o.window = true
            case "--demo": o.demo = true
            case "--install-login-item": o.installLoginItem = true
            case "--config":
                i += 1
                if i < args.count { o.configPath = args[i] }
            case "--version":
                print("ziel-van-sebastian 0.1.0")
                exit(0)
            default: break
            }
            i += 1
        }
        return o
    }
}

let options = RunOptions.parse(CommandLine.arguments)
let app = NSApplication.shared
let delegate = AppDelegate(options: options)
app.delegate = delegate
app.setActivationPolicy(.regular)

// Minimal main menu so Cmd-Q works (the app has no other chrome).
let mainMenu = NSMenu()
let appMenuItem = NSMenuItem()
mainMenu.addItem(appMenuItem)
let appMenu = NSMenu()
appMenu.addItem(NSMenuItem(title: "Quit Ziel van Sebastian",
                           action: #selector(NSApplication.terminate(_:)),
                           keyEquivalent: "q"))
appMenuItem.submenu = appMenu
app.mainMenu = mainMenu

app.run()
```

- [ ] **Step 6: Write `App/AppDelegate.swift`** (minimal — fleshed out in Tasks 11/16/17)

```swift
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: RunOptions

    init(options: RunOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Window + renderer wiring arrives in Task 11.
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
```

- [ ] **Step 7: Write `MockGateway/main.swift`** (stub — real CLI in Task 9)

```swift
print("mock-gateway: scenarios arrive in Task 9")
```

- [ ] **Step 8: Write `Tests/SmokeTests.swift`**

```swift
import XCTest

final class SmokeTests: XCTestCase {
    func testTruth() {
        XCTAssertEqual(1 + 1, 2)
    }
}
```

- [ ] **Step 9: Create the source dirs referenced by project.yml** — `Sources/Core`, `Sources/Gateway`, `Sources/MockGatewayKit` must exist or xcodegen fails. Seed each with its first real file as empty-but-valid Swift:

`Sources/Core/AgentEvent.swift`, `Sources/Gateway/OpenClawTranslator.swift`, `Sources/MockGatewayKit/MockGatewayServer.swift` — each containing only `import Foundation` for now (filled in by their tasks).

- [ ] **Step 10: Generate, build, test**

```bash
make test 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **` (1 test, SmokeTests).

```bash
make build 2>&1 | tail -3 && "./build/Build/Products/Debug/Ziel van Sebastian.app/Contents/MacOS/Ziel van Sebastian" --version
```
Expected: `** BUILD SUCCEEDED **` then `ziel-van-sebastian 0.1.0`.

- [ ] **Step 11: Commit**

```bash
git add project.yml Makefile App Tests MockGateway Sources
git commit -m "chore: scaffold XcodeGen project with app, mock-gateway, and test targets"
```

---

### Task 2: Core types — AgentEvent, FaceGeometry, SceneTypes

**Files:**
- Modify: `Sources/Core/AgentEvent.swift`
- Create: `Sources/Core/FaceGeometry.swift`, `Sources/Core/SceneTypes.swift`
- Test: `Tests/FaceGeometryTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest

final class FaceGeometryTests: XCTestCase {
    func testAllRectsWithinGrid() {
        for r in FaceGeometry.all {
            XCTAssertGreaterThanOrEqual(r.x, 0)
            XCTAssertGreaterThanOrEqual(r.y, 0)
            XCTAssertLessThanOrEqual(r.x + r.w, FaceGeometry.gridWidth)
            XCTAssertLessThanOrEqual(r.y + r.h, FaceGeometry.gridHeight)
        }
    }

    func testLockedGeometry() {
        // Locked during brainstorming against the original icon. Do not "fix".
        XCTAssertEqual(FaceGeometry.all.count, 7)
        XCTAssertEqual(FaceGeometry.leftEye, FaceGeometry.PixelRect(x: 0, y: 0, w: 2, h: 5))
        XCTAssertEqual(FaceGeometry.noseBar, FaceGeometry.PixelRect(x: 9, y: 0, w: 2, h: 11))
        XCTAssertEqual(FaceGeometry.noseFoot, FaceGeometry.PixelRect(x: 6, y: 9, w: 3, h: 2))   // hooks LEFT
        XCTAssertEqual(FaceGeometry.smileBottom, FaceGeometry.PixelRect(x: 4, y: 14, w: 11, h: 2))
    }

    func testColorHexParsing() {
        let c = ColorRGB(hex: "#41ff6a")
        XCTAssertEqual(c.r, 0x41 / 255.0, accuracy: 0.001)
        XCTAssertEqual(c.g, 1.0, accuracy: 0.001)
        XCTAssertEqual(c.b, 0x6a / 255.0, accuracy: 0.001)
        let mid = ColorRGB.lerp(ColorRGB(r: 0, g: 0, b: 0), ColorRGB(r: 1, g: 1, b: 1), 0.5)
        XCTAssertEqual(mid.r, 0.5, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make test 2>&1 | tail -5
```
Expected: BUILD FAILED — `cannot find 'FaceGeometry' in scope`.

- [ ] **Step 3: Write `Sources/Core/FaceGeometry.swift`**

```swift
import Foundation

/// The happy-Mac face on its authentic pixel grid, locked during design.
/// Small 2×5 eyes, long J-nose starting at eye level hooking LEFT,
/// thin smile with stepped upturned corners. Uniform stroke weight.
public enum FaceGeometry {
    public struct PixelRect: Equatable {
        public let x, y, w, h: Int
        public init(x: Int, y: Int, w: Int, h: Int) {
            self.x = x; self.y = y; self.w = w; self.h = h
        }
    }

    public static let gridWidth = 19
    public static let gridHeight = 16

    public static let leftEye     = PixelRect(x: 0,  y: 0,  w: 2,  h: 5)
    public static let rightEye    = PixelRect(x: 17, y: 0,  w: 2,  h: 5)
    public static let noseBar     = PixelRect(x: 9,  y: 0,  w: 2,  h: 11)
    public static let noseFoot    = PixelRect(x: 6,  y: 9,  w: 3,  h: 2)
    public static let smileLeft   = PixelRect(x: 2,  y: 12, w: 2,  h: 2)
    public static let smileBottom = PixelRect(x: 4,  y: 14, w: 11, h: 2)
    public static let smileRight  = PixelRect(x: 15, y: 12, w: 2,  h: 2)

    public static let all: [PixelRect] = [leftEye, rightEye, noseBar, noseFoot, smileLeft, smileBottom, smileRight]
    public static let eyes: [PixelRect] = [leftEye, rightEye]
}
```

- [ ] **Step 4: Replace `Sources/Core/AgentEvent.swift`**

```swift
import Foundation

/// Agent-agnostic events. All OpenClaw protocol knowledge stays in the translator.
public enum AgentEvent: Equatable {
    case runStarted(run: String, session: String)
    case toolStarted(run: String, session: String, tool: String)
    case textDelta(run: String, session: String, text: String)
    case runEnded(run: String, session: String)
    case connectionUp
    case connectionDown(auth: Bool)   // auth=true → token rejected
}
```

- [ ] **Step 5: Write `Sources/Core/SceneTypes.swift`**

```swift
import Foundation

public struct ColorRGB: Equatable {
    public var r, g, b: Double
    public init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

    /// Parses "#rrggbb" (leading '#' optional). Invalid input → white.
    public init(hex: String) {
        var s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            self.init(r: 1, g: 1, b: 1); return
        }
        self.init(
            r: Double((v >> 16) & 0xff) / 255.0,
            g: Double((v >> 8) & 0xff) / 255.0,
            b: Double(v & 0xff) / 255.0
        )
        _ = s.removeFirst // silence unused-var style warnings in some toolchains
    }

    public static func lerp(_ a: ColorRGB, _ b: ColorRGB, _ t: Double) -> ColorRGB {
        let u = max(0, min(1, t))
        return ColorRGB(r: a.r + (b.r - a.r) * u, g: a.g + (b.g - a.g) * u, b: a.b + (b.b - a.b) * u)
    }

    public func scaled(_ f: Double) -> ColorRGB { ColorRGB(r: r * f, g: g * f, b: b * f) }
}

public enum Phase: Equatable {
    case idle
    case waking
    case thinking
    case speaking
    case settling
    case offline(auth: Bool)
}

/// Immutable per-frame snapshot the renderer consumes. Pure data.
public struct SceneState: Equatable {
    public var phase: Phase
    /// 0…1 within timed transitions (waking/settling); 1 elsewhere.
    public var phaseProgress: Double
    public var timeInPhase: TimeInterval
    /// Current RSVP word (speaking) — nil otherwise.
    public var word: String?
    /// Seconds the current word has been on screen (drives the pop-in).
    public var wordAge: TimeInterval
    /// Activity hint ("READING…") — populated only in waking/thinking.
    public var hint: String?
    public var dozing: Bool
    public var tint: ColorRGB

    public init(phase: Phase, phaseProgress: Double, timeInPhase: TimeInterval,
                word: String?, wordAge: TimeInterval, hint: String?,
                dozing: Bool, tint: ColorRGB) {
        self.phase = phase; self.phaseProgress = phaseProgress
        self.timeInPhase = timeInPhase; self.word = word; self.wordAge = wordAge
        self.hint = hint; self.dozing = dozing; self.tint = tint
    }
}
```

Note: remove the stray `_ = s.removeFirst` line if the compiler doesn't warn — it's defensive noise; the clean body is just the guard + init calls. Final code should not include it (kept here so the engineer knows it's deliberate to delete):

```swift
    public init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard s.count == 6, let v = UInt32(s, radix: 16) else {
            self.init(r: 1, g: 1, b: 1); return
        }
        self.init(
            r: Double((v >> 16) & 0xff) / 255.0,
            g: Double((v >> 8) & 0xff) / 255.0,
            b: Double(v & 0xff) / 255.0
        )
    }
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
make test 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add Sources/Core Tests/FaceGeometryTests.swift
git commit -m "feat: core types — AgentEvent, locked face geometry, scene state"
```

---

### Task 3: Config

**Files:**
- Create: `Sources/Core/Config.swift`
- Test: `Tests/ConfigTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest

final class ConfigTests: XCTestCase {
    func testDefaults() {
        let c = ZielConfig()
        XCTAssertEqual(c.gateway.url, "ws://127.0.0.1:18789")
        XCTAssertEqual(c.pacing.baseMs, 280)
        XCTAssertEqual(c.look.idleTint, "#41ff6a")
        XCTAssertEqual(c.behavior.dozeAfterSeconds, 600)
        XCTAssertEqual(c.look.shader.persistence, 0.82, accuracy: 0.001)
    }

    func testPartialJSONMergesWithDefaults() throws {
        let json = #"{"gateway":{"token":"sek"},"pacing":{"baseMs":200}}"#
        let c = try ZielConfig.decode(Data(json.utf8))
        XCTAssertEqual(c.gateway.token, "sek")
        XCTAssertEqual(c.gateway.url, "ws://127.0.0.1:18789")   // default survives
        XCTAssertEqual(c.pacing.baseMs, 200)
        XCTAssertEqual(c.pacing.perCharMs, 60)                  // default survives
    }

    func testMissingFileGivesDefaults() {
        let c = ZielConfig.load(from: URL(fileURLWithPath: "/nonexistent/nope.json"))
        XCTAssertEqual(c, ZielConfig())
    }

    func testInvalidJSONGivesDefaults() throws {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("ziel-bad-\(UUID().uuidString).json")
        try Data("not json{{{".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(ZielConfig.load(from: url), ZielConfig())
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make test 2>&1 | tail -5
```
Expected: BUILD FAILED — `cannot find 'ZielConfig' in scope`.

- [ ] **Step 3: Write `Sources/Core/Config.swift`**

Every struct decodes field-by-field with `decodeIfPresent` so partial configs merge with defaults.

```swift
import Foundation

public struct GatewayConfig: Codable, Equatable {
    public var url: String = "ws://127.0.0.1:18789"
    public var token: String = ""

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? url
        token = try c.decodeIfPresent(String.self, forKey: .token) ?? token
    }
}

public struct PacingConfig: Codable, Equatable {
    public var baseMs: Double = 280
    public var perCharMs: Double = 60
    public var charThreshold: Int = 6
    public var sentencePauseMs: Double = 320
    public var clausePauseMs: Double = 150
    public var catchupStart: Int = 10
    public var catchupFull: Int = 80
    public var minFactor: Double = 0.45

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        baseMs = try c.decodeIfPresent(Double.self, forKey: .baseMs) ?? baseMs
        perCharMs = try c.decodeIfPresent(Double.self, forKey: .perCharMs) ?? perCharMs
        charThreshold = try c.decodeIfPresent(Int.self, forKey: .charThreshold) ?? charThreshold
        sentencePauseMs = try c.decodeIfPresent(Double.self, forKey: .sentencePauseMs) ?? sentencePauseMs
        clausePauseMs = try c.decodeIfPresent(Double.self, forKey: .clausePauseMs) ?? clausePauseMs
        catchupStart = try c.decodeIfPresent(Int.self, forKey: .catchupStart) ?? catchupStart
        catchupFull = try c.decodeIfPresent(Int.self, forKey: .catchupFull) ?? catchupFull
        minFactor = try c.decodeIfPresent(Double.self, forKey: .minFactor) ?? minFactor
    }
}

public struct ShaderConfig: Codable, Equatable {
    public var scanlineIntensity: Double = 0.35
    public var maskIntensity: Double = 0.25
    public var bloomStrength: Double = 0.55
    public var curvature: Double = 0.12
    public var vignette: Double = 0.35
    public var flicker: Double = 0.03
    public var noise: Double = 0.04
    public var persistence: Double = 0.82

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        scanlineIntensity = try c.decodeIfPresent(Double.self, forKey: .scanlineIntensity) ?? scanlineIntensity
        maskIntensity = try c.decodeIfPresent(Double.self, forKey: .maskIntensity) ?? maskIntensity
        bloomStrength = try c.decodeIfPresent(Double.self, forKey: .bloomStrength) ?? bloomStrength
        curvature = try c.decodeIfPresent(Double.self, forKey: .curvature) ?? curvature
        vignette = try c.decodeIfPresent(Double.self, forKey: .vignette) ?? vignette
        flicker = try c.decodeIfPresent(Double.self, forKey: .flicker) ?? flicker
        noise = try c.decodeIfPresent(Double.self, forKey: .noise) ?? noise
        persistence = try c.decodeIfPresent(Double.self, forKey: .persistence) ?? persistence
    }
}

public struct LookConfig: Codable, Equatable {
    public var idleTint: String = "#41ff6a"
    public var thinkingTint: String = "#ffb000"
    public var speakingTint: String = "#e6edf5"
    public var fontName: String = "Menlo-Bold"
    public var shader: ShaderConfig = ShaderConfig()

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        idleTint = try c.decodeIfPresent(String.self, forKey: .idleTint) ?? idleTint
        thinkingTint = try c.decodeIfPresent(String.self, forKey: .thinkingTint) ?? thinkingTint
        speakingTint = try c.decodeIfPresent(String.self, forKey: .speakingTint) ?? speakingTint
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? fontName
        shader = try c.decodeIfPresent(ShaderConfig.self, forKey: .shader) ?? shader
    }
}

public struct BehaviorConfig: Codable, Equatable {
    public var wakingSeconds: Double = 0.8
    public var settlingSeconds: Double = 1.2
    public var dozeAfterSeconds: Double = 600
    public var hintHoldSeconds: Double = 2.5

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        wakingSeconds = try c.decodeIfPresent(Double.self, forKey: .wakingSeconds) ?? wakingSeconds
        settlingSeconds = try c.decodeIfPresent(Double.self, forKey: .settlingSeconds) ?? settlingSeconds
        dozeAfterSeconds = try c.decodeIfPresent(Double.self, forKey: .dozeAfterSeconds) ?? dozeAfterSeconds
        hintHoldSeconds = try c.decodeIfPresent(Double.self, forKey: .hintHoldSeconds) ?? hintHoldSeconds
    }
}

public struct DisplayConfig: Codable, Equatable {
    /// Case-insensitive substrings matched against NSScreen.localizedName.
    public var preferredNameContains: [String] = ["wokyis", "m5"]
    public var preventDisplaySleep: Bool = true

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preferredNameContains = try c.decodeIfPresent([String].self, forKey: .preferredNameContains) ?? preferredNameContains
        preventDisplaySleep = try c.decodeIfPresent(Bool.self, forKey: .preventDisplaySleep) ?? preventDisplaySleep
    }
}

public struct ZielConfig: Codable, Equatable {
    public var gateway: GatewayConfig = GatewayConfig()
    public var pacing: PacingConfig = PacingConfig()
    public var look: LookConfig = LookConfig()
    public var behavior: BehaviorConfig = BehaviorConfig()
    public var display: DisplayConfig = DisplayConfig()

    public init() {}
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gateway = try c.decodeIfPresent(GatewayConfig.self, forKey: .gateway) ?? gateway
        pacing = try c.decodeIfPresent(PacingConfig.self, forKey: .pacing) ?? pacing
        look = try c.decodeIfPresent(LookConfig.self, forKey: .look) ?? look
        behavior = try c.decodeIfPresent(BehaviorConfig.self, forKey: .behavior) ?? behavior
        display = try c.decodeIfPresent(DisplayConfig.self, forKey: .display) ?? display
    }

    public static func decode(_ data: Data) throws -> ZielConfig {
        try JSONDecoder().decode(ZielConfig.self, from: data)
    }

    /// Missing or invalid file → defaults (loudly, but never fatally).
    public static func load(from url: URL) -> ZielConfig {
        guard let data = try? Data(contentsOf: url) else { return ZielConfig() }
        return (try? decode(data)) ?? ZielConfig()
    }

    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ziel van Sebastian/config.json")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
make test 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Config.swift Tests/ConfigTests.swift
git commit -m "feat: config with per-field defaults merging and safe loader"
```

---

### Task 4: HintMapper

**Files:**
- Create: `Sources/Core/HintMapper.swift`
- Test: `Tests/HintMapperTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest

final class HintMapperTests: XCTestCase {
    func testKnownToolFamilies() {
        XCTAssertEqual(HintMapper.hint(forTool: "read"), "READING…")
        XCTAssertEqual(HintMapper.hint(forTool: "Read"), "READING…")
        XCTAssertEqual(HintMapper.hint(forTool: "web_fetch"), "READING…")
        XCTAssertEqual(HintMapper.hint(forTool: "web_search"), "SEARCHING…")
        XCTAssertEqual(HintMapper.hint(forTool: "grep"), "SEARCHING…")
        XCTAssertEqual(HintMapper.hint(forTool: "write"), "WRITING…")
        XCTAssertEqual(HintMapper.hint(forTool: "edit"), "WRITING…")
        XCTAssertEqual(HintMapper.hint(forTool: "exec"), "RUNNING…")
        XCTAssertEqual(HintMapper.hint(forTool: "bash"), "RUNNING…")
    }

    func testUnknownToolUppercased() {
        XCTAssertEqual(HintMapper.hint(forTool: "browser"), "BROWSER…")
    }

    func testLongUnknownToolTruncated() {
        XCTAssertEqual(HintMapper.hint(forTool: "sessions_spawn_subagent"), "SESSIONS_SPA…")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make test 2>&1 | tail -5
```
Expected: BUILD FAILED — `cannot find 'HintMapper' in scope`.

- [ ] **Step 3: Write `Sources/Core/HintMapper.swift`**

```swift
import Foundation

public enum HintMapper {
    public static func hint(forTool tool: String) -> String {
        let t = tool.lowercased()
        if t.contains("search") || t.contains("grep") || t.contains("find") || t.contains("glob") {
            return "SEARCHING…"
        }
        if t.contains("read") || t.contains("fetch") || t.contains("cat") || t.contains("get") {
            return "READING…"
        }
        if t.contains("write") || t.contains("edit") || t.contains("apply") || t.contains("patch") {
            return "WRITING…"
        }
        if t.contains("exec") || t.contains("bash") || t.contains("shell") || t.contains("run") {
            return "RUNNING…"
        }
        let name = tool.uppercased()
        return name.count > 12 ? name.prefix(12) + "…" : name + "…"
    }
}
```

Note the ordering: `search` is checked before `read` so `web_search` doesn't match the `get/read` family. The test pins this.

- [ ] **Step 4: Run tests to verify they pass**

```bash
make test 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/HintMapper.swift Tests/HintMapperTests.swift
git commit -m "feat: tool-name to hint-word mapping"
```

---

### Task 5: MarkdownStreamStripper

Streaming (chunk-safe) markdown removal. State survives across `feed` calls because deltas split tokens arbitrarily.

Rules (v1, documented simplifications):
- Backtick runs ≥3 toggle fence state; fence open emits `" [code] "`, fence content is dropped. Runs of 1–2 backticks are dropped (inline code keeps its content).
- `*`, `_`, `~` are always dropped outside fences.
- `#` runs at line start (plus one following space) are dropped.
- `[` and `]` are dropped; `](` switches to URL-drop state until `)`. (Cost: `array[0]` → `array0` — acceptable for prose.)

**Files:**
- Create: `Sources/Core/MarkdownStreamStripper.swift`
- Test: `Tests/MarkdownStripperTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest

final class MarkdownStripperTests: XCTestCase {
    private func strip(_ chunks: [String]) -> String {
        let s = MarkdownStreamStripper()
        var out = chunks.map { s.feed($0) }.joined()
        out += s.flush()
        return out
    }

    func testEmphasisStripped() {
        XCTAssertEqual(strip(["**bold** and *italic* and _under_"]), "bold and italic and under")
    }

    func testInlineCodeKeepsContent() {
        XCTAssertEqual(strip(["use `make test` here"]), "use make test here")
    }

    func testFenceCollapsesToCodeToken() {
        XCTAssertEqual(strip(["Look:\n```swift\nlet x = 1\n```\ndone"]), "Look:\n [code] \ndone")
    }

    func testFenceAcrossChunks() {
        XCTAssertEqual(strip(["``", "`\nhidden\n`", "``after"]), " [code] after")
    }

    func testHeadingMarkerStripped() {
        XCTAssertEqual(strip(["# Title\nbody"]), "Title\nbody")
    }

    func testLinkKeepsTextDropsUrl() {
        XCTAssertEqual(strip(["see [the docs](https://example.com/x) now"]), "see the docs now")
    }

    func testLinkSplitAcrossChunks() {
        XCTAssertEqual(strip(["see [do", "cs](https://e", ".com) now"]), "see docs now")
    }

    func testFlushClosesPendingBacktickRun() {
        XCTAssertEqual(strip(["text ``"]), "text ")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make test 2>&1 | tail -5
```
Expected: BUILD FAILED — `cannot find 'MarkdownStreamStripper' in scope`.

- [ ] **Step 3: Write `Sources/Core/MarkdownStreamStripper.swift`**

```swift
import Foundation

/// Character-level streaming markdown remover. Safe across arbitrary chunk
/// boundaries: backtick runs and link URLs may span feeds.
public final class MarkdownStreamStripper {
    private var inFence = false
    private var inURL = false           // between "](" and ")"
    private var backtickRun = 0
    private var atLineStart = true
    private var lastEmittedWasBracketClose = false

    public init() {}

    public func feed(_ chunk: String) -> String {
        var out = ""
        for ch in chunk {
            if ch == "`" {
                backtickRun += 1
                continue
            }
            if backtickRun > 0 {
                settleBacktickRun(into: &out)
            }
            if inFence {
                if ch == "\n" { atLineStart = true }
                continue
            }
            if inURL {
                if ch == ")" { inURL = false }
                continue
            }
            switch ch {
            case "*", "_", "~":
                continue
            case "[":
                lastEmittedWasBracketClose = false
                continue
            case "]":
                lastEmittedWasBracketClose = true
                continue
            case "(" where lastEmittedWasBracketClose:
                lastEmittedWasBracketClose = false
                inURL = true
                continue
            case "#" where atLineStart:
                continue
            case " " where atLineStart:
                // swallow the single space after heading #'s; harmless otherwise
                // (leading spaces at line start are not significant for RSVP)
                continue
            case "\n":
                atLineStart = true
                lastEmittedWasBracketClose = false
                out.append(ch)
                continue
            default:
                atLineStart = false
                lastEmittedWasBracketClose = false
                out.append(ch)
            }
        }
        return out
    }

    /// Call at end-of-message: resolves a trailing backtick run.
    public func flush() -> String {
        var out = ""
        if backtickRun > 0 { settleBacktickRun(into: &out) }
        return out
    }

    private func settleBacktickRun(into out: inout String) {
        if backtickRun >= 3 {
            inFence.toggle()
            if inFence { out += " [code] " }
        }
        backtickRun = 0
    }
}
```

- [ ] **Step 4: Run tests; iterate on edge cases until green**

```bash
make test 2>&1 | tail -8
```
Expected: `** TEST SUCCEEDED **`. (The `atLineStart`/space interaction is the likely first failure — the tests pin exact expected strings; adjust only the implementation, not the tests.)

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/MarkdownStreamStripper.swift Tests/MarkdownStripperTests.swift
git commit -m "feat: chunk-safe streaming markdown stripper"
```

---

### Task 6: WordPacer

**Files:**
- Create: `Sources/Core/WordPacer.swift`
- Test: `Tests/WordPacerTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest

final class WordPacerTests: XCTestCase {
    func testSplitsAcrossChunksAndFlushes() {
        let p = WordPacer(config: PacingConfig())
        p.feed("hel")
        XCTAssertNil(p.nextWord())              // "hel" might continue
        p.feed("lo world")
        XCTAssertEqual(p.nextWord()?.text, "hello")
        XCTAssertNil(p.nextWord())              // "world" might continue
        p.endOfText()
        XCTAssertEqual(p.nextWord()?.text, "world")
        XCTAssertNil(p.nextWord())
    }

    func testBaseHold() {
        let p = WordPacer(config: PacingConfig())
        p.feed("ok ")
        XCTAssertEqual(p.nextWord()!.holdMs, 280, accuracy: 0.5)
    }

    func testLongWordHold() {
        let p = WordPacer(config: PacingConfig())
        p.feed("extraordinary ")                 // 13 chars → 280 + 7*60
        XCTAssertEqual(p.nextWord()!.holdMs, 700, accuracy: 0.5)
    }

    func testSentencePause() {
        let p = WordPacer(config: PacingConfig())
        p.feed("done. ")
        // "done." = 5 chars ≤ threshold → 280 + 320
        XCTAssertEqual(p.nextWord()!.holdMs, 600, accuracy: 0.5)
    }

    func testClausePause() {
        let p = WordPacer(config: PacingConfig())
        p.feed("first, ")
        // "first," = 6 chars ≤ threshold → 280 + 150
        XCTAssertEqual(p.nextWord()!.holdMs, 430, accuracy: 0.5)
    }

    func testBacklogCatchup() {
        let p = WordPacer(config: PacingConfig())
        p.feed(String(repeating: "a ", count: 100))    // 100 one-char words
        // After popping one, backlog = 99 ≥ catchupFull(80) → factor = minFactor
        XCTAssertEqual(p.nextWord()!.holdMs, 280 * 0.45, accuracy: 0.5)
    }

    func testNoCatchupBelowStart() {
        let p = WordPacer(config: PacingConfig())
        p.feed("a b c ")                                // backlog after pop = 2 < 10
        XCTAssertEqual(p.nextWord()!.holdMs, 280, accuracy: 0.5)
    }

    func testWhitespaceOnlyChunksIgnored() {
        let p = WordPacer(config: PacingConfig())
        p.feed("   \n  ")
        p.endOfText()
        XCTAssertNil(p.nextWord())
        XCTAssertTrue(p.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make test 2>&1 | tail -5
```
Expected: BUILD FAILED — `cannot find 'WordPacer' in scope`.

- [ ] **Step 3: Write `Sources/Core/WordPacer.swift`**

```swift
import Foundation

public struct PacedWord: Equatable {
    public let text: String
    public let holdMs: Double
}

/// RSVP queue: stripped text in, paced words out. Holds a trailing partial
/// word until whitespace or endOfText proves it complete.
public final class WordPacer {
    public var config: PacingConfig
    private var queue: [String] = []
    private var partial = ""

    public init(config: PacingConfig) {
        self.config = config
    }

    public var backlog: Int { queue.count }
    public var isEmpty: Bool { queue.isEmpty && partial.isEmpty }

    public func feed(_ text: String) {
        for ch in text {
            if ch.isWhitespace {
                if !partial.isEmpty {
                    queue.append(partial)
                    partial = ""
                }
            } else {
                partial.append(ch)
            }
        }
    }

    public func endOfText() {
        if !partial.isEmpty {
            queue.append(partial)
            partial = ""
        }
    }

    public func nextWord() -> PacedWord? {
        guard !queue.isEmpty else { return nil }
        let word = queue.removeFirst()
        return PacedWord(text: word, holdMs: hold(for: word, backlog: queue.count))
    }

    public func reset() {
        queue.removeAll()
        partial = ""
    }

    private func hold(for word: String, backlog: Int) -> Double {
        var ms = config.baseMs
        let extra = word.count - config.charThreshold
        if extra > 0 { ms += Double(extra) * config.perCharMs }
        if let last = word.unicodeScalars.last {
            if ".!?…".unicodeScalars.contains(last) {
                ms += config.sentencePauseMs
            } else if ",;:".unicodeScalars.contains(last) {
                ms += config.clausePauseMs
            }
        }
        return ms * catchupFactor(backlog: backlog)
    }

    private func catchupFactor(backlog: Int) -> Double {
        if backlog <= config.catchupStart { return 1.0 }
        if backlog >= config.catchupFull { return config.minFactor }
        let t = Double(backlog - config.catchupStart) / Double(config.catchupFull - config.catchupStart)
        return 1.0 + (config.minFactor - 1.0) * t
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
make test 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/WordPacer.swift Tests/WordPacerTests.swift
git commit -m "feat: RSVP word pacer with punctuation holds and backlog catch-up"
```

---

### Task 7: Director

The state machine. Clock is always passed in (`now:`) — no Date() anywhere — so every test is deterministic.

**Files:**
- Create: `Sources/Core/Director.swift`
- Test: `Tests/DirectorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest

final class DirectorTests: XCTestCase {
    private func makeDirector() -> Director {
        Director(config: ZielConfig())
    }

    func testStartsOffline() {
        let d = makeDirector()
        XCTAssertEqual(d.tick(now: 0).phase, .offline(auth: false))
    }

    func testConnectionUpGoesIdle() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 1)
        XCTAssertEqual(d.tick(now: 1).phase, .idle)
    }

    func testRunStartedWakesThenThinks() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.runStarted(run: "r1", session: "main"), now: 10)
        XCTAssertEqual(d.tick(now: 10.1).phase, .waking)
        XCTAssertEqual(d.tick(now: 10.5).phaseProgress, 0.5 / 0.8, accuracy: 0.01)
        XCTAssertEqual(d.tick(now: 10.9).phase, .thinking)
    }

    func testToolHintShowsAndExpires() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.runStarted(run: "r1", session: "main"), now: 10)
        _ = d.tick(now: 11)   // → thinking
        d.handle(.toolStarted(run: "r1", session: "main", tool: "read"), now: 11)
        XCTAssertEqual(d.tick(now: 11.1).hint, "READING…")
        XCTAssertNil(d.tick(now: 14).hint)   // 11 + 2.5 hold < 14
    }

    func testTextStreamsAsWords() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.runStarted(run: "r1", session: "main"), now: 10)
        d.handle(.textDelta(run: "r1", session: "main", text: "hello world "), now: 10.2)
        let s = d.tick(now: 11)   // waking done → thinking → speaking pops word
        XCTAssertEqual(s.phase, .speaking)
        XCTAssertEqual(s.word, "hello")
        // base hold 280ms: still "hello" at 11.2, "world" at 11.3
        XCTAssertEqual(d.tick(now: 11.2).word, "hello")
        XCTAssertEqual(d.tick(now: 11.3).word, "world")
    }

    func testRunEndAndDrainSettlesToIdle() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.runStarted(run: "r1", session: "main"), now: 10)
        d.handle(.textDelta(run: "r1", session: "main", text: "done"), now: 10.2)
        d.handle(.runEnded(run: "r1", session: "main"), now: 10.4)   // flushes "done"
        let s = d.tick(now: 11)
        XCTAssertEqual(s.phase, .speaking)
        XCTAssertEqual(s.word, "done")
        let after = d.tick(now: 11.4)        // word hold elapsed, queue empty, run over
        XCTAssertEqual(after.phase, .settling)
        XCTAssertEqual(d.tick(now: 12.7).phase, .idle)   // 11.4 + 1.2 settling
    }

    func testSpeakingLocksFocusUntilDrained() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.runStarted(run: "a", session: "s1"), now: 10)
        d.handle(.runStarted(run: "b", session: "s2"), now: 10)
        d.handle(.textDelta(run: "a", session: "s1", text: "alpha "), now: 10.1)
        d.handle(.textDelta(run: "b", session: "s2", text: "beta "), now: 10.2)
        d.handle(.runEnded(run: "a", session: "s1"), now: 10.3)
        d.handle(.runEnded(run: "b", session: "s2"), now: 10.3)
        XCTAssertEqual(d.tick(now: 11).word, "alpha")     // a focused first
        XCTAssertEqual(d.tick(now: 11.3).word, "beta")    // then b's text, no interleave
        XCTAssertEqual(d.tick(now: 11.7).phase, .settling)
    }

    func testQueueDrainedRunActiveReturnsToThinking() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.runStarted(run: "r1", session: "main"), now: 10)
        d.handle(.textDelta(run: "r1", session: "main", text: "wait "), now: 10.1)
        XCTAssertEqual(d.tick(now: 11).word, "wait")
        XCTAssertEqual(d.tick(now: 11.4).phase, .thinking)   // drained, run not ended
    }

    func testImplicitRunFromTextDelta() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.textDelta(run: "ghost", session: "s", text: "boo "), now: 5)
        XCTAssertEqual(d.tick(now: 5.1).phase, .waking)
        XCTAssertEqual(d.tick(now: 6).word, "boo")
    }

    func testDozeAfterIdlePeriod() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 0)
        XCTAssertFalse(d.tick(now: 500).dozing)
        XCTAssertTrue(d.tick(now: 601).dozing)
    }

    func testOfflineStates() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 0)
        d.handle(.connectionDown(auth: true), now: 5)
        XCTAssertEqual(d.tick(now: 6).phase, .offline(auth: true))
        d.handle(.connectionUp, now: 7)
        XCTAssertEqual(d.tick(now: 7).phase, .idle)
    }

    func testTintLerpsThroughWaking() {
        let d = makeDirector()
        d.handle(.connectionUp, now: 0)
        let green = ColorRGB(hex: "#41ff6a")
        XCTAssertEqual(d.tick(now: 1).tint, green)
        d.handle(.runStarted(run: "r", session: "s"), now: 10)
        let mid = d.tick(now: 10.4).tint                     // halfway green→amber
        let expected = ColorRGB.lerp(green, ColorRGB(hex: "#ffb000"), 0.5)
        XCTAssertEqual(mid.r, expected.r, accuracy: 0.01)
        XCTAssertEqual(mid.g, expected.g, accuracy: 0.01)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make test 2>&1 | tail -5
```
Expected: BUILD FAILED — `cannot find 'Director' in scope`.

- [ ] **Step 3: Write `Sources/Core/Director.swift`**

```swift
import Foundation

/// The state machine: idle → waking → thinking ⇄ speaking → settling → idle.
/// Consumes AgentEvents, produces immutable SceneState snapshots.
/// All time is injected — never reads a clock itself.
public final class Director {
    private struct RunState {
        var session: String
        var stripper = MarkdownStreamStripper()
        var pending = ""          // stripped text not yet fed to the pacer
        var ended = false
        var lastActivity: TimeInterval
    }

    private var phase: Phase = .offline(auth: false)
    private var phaseStart: TimeInterval = 0
    private var runs: [String: RunState] = [:]
    private var focusedRun: String?
    private let pacer: WordPacer
    private var currentWord: PacedWord?
    private var wordStart: TimeInterval = 0
    private var hint: String?
    private var hintUntil: TimeInterval = 0
    private var lastActivity: TimeInterval = 0

    private var behavior: BehaviorConfig
    private let idleTint: ColorRGB
    private let thinkingTint: ColorRGB
    private let speakingTint: ColorRGB

    public init(config: ZielConfig) {
        self.pacer = WordPacer(config: config.pacing)
        self.behavior = config.behavior
        self.idleTint = ColorRGB(hex: config.look.idleTint)
        self.thinkingTint = ColorRGB(hex: config.look.thinkingTint)
        self.speakingTint = ColorRGB(hex: config.look.speakingTint)
    }

    /// Live config reload (pacing only; tints/timings need restart in v1).
    public func updatePacing(_ p: PacingConfig) {
        pacer.config = p
    }

    // MARK: - Events

    public func handle(_ event: AgentEvent, now: TimeInterval) {
        switch event {
        case .connectionUp:
            resetAll()
            go(.idle, now: now)
            lastActivity = now

        case .connectionDown(let auth):
            resetAll()
            go(.offline(auth: auth), now: now)

        case .runStarted(let run, let session):
            guard isOnline else { return }
            ensureRun(run, session: session, now: now)
            wakeIfIdle(now: now)

        case .toolStarted(let run, let session, let tool):
            guard isOnline else { return }
            ensureRun(run, session: session, now: now)
            hint = HintMapper.hint(forTool: tool)
            hintUntil = now + behavior.hintHoldSeconds
            wakeIfIdle(now: now)

        case .textDelta(let run, let session, let text):
            guard isOnline else { return }
            ensureRun(run, session: session, now: now)
            let stripped = runs[run]!.stripper.feed(text)
            route(stripped, from: run)
            wakeIfIdle(now: now)

        case .runEnded(let run, let session):
            guard isOnline else { return }
            ensureRun(run, session: session, now: now)
            let tail = runs[run]!.stripper.flush()
            route(tail, from: run)
            runs[run]!.ended = true
            if focusedRun == run { pacer.endOfText() }
        }
    }

    // MARK: - Frame tick

    public func tick(now: TimeInterval) -> SceneState {
        advance(now: now)
        let elapsed = now - phaseStart
        let progress = transitionProgress(elapsed: elapsed)
        return SceneState(
            phase: phase,
            phaseProgress: progress,
            timeInPhase: elapsed,
            word: phase == .speaking ? currentWord?.text : nil,
            wordAge: phase == .speaking ? now - wordStart : 0,
            hint: hintVisible(now: now) ? hint : nil,
            dozing: phase == .idle && (now - lastActivity) > behavior.dozeAfterSeconds,
            tint: tint(elapsed: elapsed, progress: progress)
        )
    }

    // MARK: - Internals

    private var isOnline: Bool {
        if case .offline = phase { return false }
        return true
    }

    private func resetAll() {
        runs.removeAll()
        focusedRun = nil
        pacer.reset()
        currentWord = nil
        hint = nil
    }

    private func go(_ p: Phase, now: TimeInterval) {
        phase = p
        phaseStart = now
    }

    private func ensureRun(_ run: String, session: String, now: TimeInterval) {
        if runs[run] == nil {
            runs[run] = RunState(session: session, lastActivity: now)
        } else {
            runs[run]!.lastActivity = now
        }
        lastActivity = now
    }

    private func wakeIfIdle(now: TimeInterval) {
        if phase == .idle || phase == .settling {
            go(.waking, now: now)
        }
    }

    private func route(_ stripped: String, from run: String) {
        guard !stripped.isEmpty else { return }
        if focusedRun == nil {
            focusedRun = run
        }
        if focusedRun == run {
            pacer.feed(stripped)
            if runs[run]?.ended == true { pacer.endOfText() }
        } else {
            runs[run]!.pending += stripped
        }
    }

    private func advance(now: TimeInterval) {
        switch phase {
        case .waking:
            if now - phaseStart >= behavior.wakingSeconds {
                go(.thinking, now: now)
                advance(now: now)   // may immediately start speaking
            }
        case .thinking:
            if startNextWord(now: now) {
                go(.speaking, now: now)
            }
        case .speaking:
            guard let word = currentWord else {
                if !startNextWord(now: now) { finishSpeaking(now: now) }
                return
            }
            if (now - wordStart) * 1000 >= word.holdMs {
                if !startNextWord(now: now) { finishSpeaking(now: now) }
            }
        case .settling:
            if now - phaseStart >= behavior.settlingSeconds {
                go(.idle, now: now)
            }
        case .idle, .offline:
            break
        }
    }

    private func startNextWord(now: TimeInterval) -> Bool {
        if let next = pacer.nextWord() {
            currentWord = next
            wordStart = now
            return true
        }
        return false
    }

    private func finishSpeaking(now: TimeInterval) {
        currentWord = nil
        guard let focused = focusedRun else {
            go(anyActiveRuns ? .thinking : .settling, now: now)
            return
        }
        let focusedDone = runs[focused]?.ended ?? true
        if focusedDone && pacer.isEmpty {
            runs.removeValue(forKey: focused)
            focusedRun = nil
            if adoptPendingRun(now: now) {
                go(.speaking, now: now)
                _ = startNextWord(now: now)
                if currentWord == nil { go(anyActiveRuns ? .thinking : .settling, now: now) }
            } else {
                go(anyActiveRuns ? .thinking : .settling, now: now)
            }
        } else {
            go(.thinking, now: now)   // run still active, waiting for more text
        }
    }

    /// Picks the most recently active run with pending text; feeds the pacer.
    private func adoptPendingRun(now: TimeInterval) -> Bool {
        let candidate = runs
            .filter { !$0.value.pending.isEmpty }
            .max { $0.value.lastActivity < $1.value.lastActivity }
        guard let (run, state) = candidate else { return false }
        focusedRun = run
        pacer.feed(state.pending)
        runs[run]!.pending = ""
        if state.ended { pacer.endOfText() }
        return true
    }

    private var anyActiveRuns: Bool {
        runs.contains { !$0.value.ended || !$0.value.pending.isEmpty }
    }

    private func hintVisible(now: TimeInterval) -> Bool {
        (phase == .waking || phase == .thinking) && now < hintUntil && hint != nil
    }

    private func transitionProgress(elapsed: TimeInterval) -> Double {
        switch phase {
        case .waking: return min(1, elapsed / behavior.wakingSeconds)
        case .settling: return min(1, elapsed / behavior.settlingSeconds)
        default: return 1
        }
    }

    private func tint(elapsed: TimeInterval, progress: Double) -> ColorRGB {
        switch phase {
        case .idle: return idleTint
        case .waking: return ColorRGB.lerp(idleTint, thinkingTint, progress)
        case .thinking: return thinkingTint
        case .speaking: return ColorRGB.lerp(thinkingTint, speakingTint, min(1, elapsed / 0.3))
        case .settling: return ColorRGB.lerp(speakingTint, idleTint, progress)
        case .offline: return idleTint.scaled(0.45)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
make test 2>&1 | tail -8
```
Expected: `** TEST SUCCEEDED **`. The focus-lock and settle-path tests are the subtle ones; if they fail, debug the implementation (`finishSpeaking` ordering), not the tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Director.swift Tests/DirectorTests.swift
git commit -m "feat: director state machine with focus locking and tint crossfades"
```

---

### Task 8: OpenClawTranslator

**Files:**
- Modify: `Sources/Gateway/OpenClawTranslator.swift`
- Test: `Tests/TranslatorTests.swift`

- [ ] **Step 1: Write the failing test** (frames verbatim from protocol research)

```swift
import XCTest

final class TranslatorTests: XCTestCase {
    private func translate(_ json: String) -> [AgentEvent] {
        OpenClawTranslator.translate(Data(json.utf8))
    }

    func testLifecycleStart() {
        let events = translate(#"{"type":"event","event":"agent","payload":{"runId":"r1","seq":0,"stream":"lifecycle","ts":1,"sessionKey":"main","data":{"phase":"start"}}}"#)
        XCTAssertEqual(events, [.runStarted(run: "r1", session: "main")])
    }

    func testLifecycleEndAndError() {
        XCTAssertEqual(
            translate(#"{"type":"event","event":"agent","payload":{"runId":"r1","seq":9,"stream":"lifecycle","ts":1,"sessionKey":"main","data":{"phase":"end"}}}"#),
            [.runEnded(run: "r1", session: "main")])
        XCTAssertEqual(
            translate(#"{"type":"event","event":"agent","payload":{"runId":"r1","seq":9,"stream":"lifecycle","ts":1,"sessionKey":"main","data":{"phase":"error"}}}"#),
            [.runEnded(run: "r1", session: "main")])
    }

    func testToolStartCarriesName() {
        let events = translate(#"{"type":"event","event":"agent","payload":{"runId":"r1","seq":2,"stream":"tool","ts":1,"sessionKey":"main","data":{"phase":"start","name":"read","toolCallId":"t1","args":{}}}}"#)
        XCTAssertEqual(events, [.toolStarted(run: "r1", session: "main", tool: "read")])
    }

    func testToolResultIgnored() {
        let events = translate(#"{"type":"event","event":"agent","payload":{"runId":"r1","seq":3,"stream":"tool","ts":1,"data":{"phase":"result","name":"read","toolCallId":"t1","isError":false,"result":"…"}}}"#)
        XCTAssertEqual(events, [])
    }

    func testAssistantDelta() {
        let events = translate(#"{"type":"event","event":"agent","payload":{"runId":"r1","seq":4,"stream":"assistant","ts":1,"sessionKey":"main","data":{"delta":"Hello "}}}"#)
        XCTAssertEqual(events, [.textDelta(run: "r1", session: "main", text: "Hello ")])
    }

    func testHeartbeatDropped() {
        let events = translate(#"{"type":"event","event":"agent","payload":{"runId":"hb","seq":0,"stream":"lifecycle","ts":1,"isHeartbeat":true,"data":{"phase":"start"}}}"#)
        XCTAssertEqual(events, [])
    }

    func testMissingSessionKeyFallsBackToRunId() {
        let events = translate(#"{"type":"event","event":"agent","payload":{"runId":"r9","seq":0,"stream":"lifecycle","ts":1,"data":{"phase":"start"}}}"#)
        XCTAssertEqual(events, [.runStarted(run: "r9", session: "r9")])
    }

    func testOtherStreamsAndEventsIgnored() {
        XCTAssertEqual(translate(#"{"type":"event","event":"agent","payload":{"runId":"r1","seq":5,"stream":"thinking","ts":1,"data":{"delta":"hmm"}}}"#), [])
        XCTAssertEqual(translate(#"{"type":"event","event":"chat","payload":{"runId":"r1","sessionKey":"main","seq":1,"state":"delta","deltaText":"x"}}"#), [])
        XCTAssertEqual(translate(#"{"type":"event","event":"connect.challenge","payload":{"nonce":"n"}}"#), [])
        XCTAssertEqual(translate(#"{"type":"res","id":"connect-1","ok":true,"payload":{}}"#), [])
    }

    func testGarbageNeverThrows() {
        XCTAssertEqual(translate("not json at all {{{"), [])
        XCTAssertEqual(translate(#"{"type":"event","event":"agent","payload":{"stream":"assistant"}}"#), [])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make test 2>&1 | tail -5
```
Expected: compile error — `OpenClawTranslator` has no `translate`.

- [ ] **Step 3: Replace `Sources/Gateway/OpenClawTranslator.swift`**

```swift
import Foundation

/// The single place that understands OpenClaw's gateway frames.
/// Everything else speaks AgentEvent.
public enum OpenClawTranslator {
    public static func translate(_ data: Data) -> [AgentEvent] {
        guard
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            obj["type"] as? String == "event",
            obj["event"] as? String == "agent",
            let payload = obj["payload"] as? [String: Any],
            let runId = payload["runId"] as? String,
            let stream = payload["stream"] as? String
        else { return [] }

        if (payload["isHeartbeat"] as? Bool) == true { return [] }

        let session = (payload["sessionKey"] as? String) ?? runId
        let body = payload["data"] as? [String: Any] ?? [:]

        switch stream {
        case "lifecycle":
            switch body["phase"] as? String {
            case "start":
                return [.runStarted(run: runId, session: session)]
            case "end", "error":
                return [.runEnded(run: runId, session: session)]
            default:
                return []
            }
        case "tool":
            guard body["phase"] as? String == "start",
                  let name = body["name"] as? String else { return [] }
            return [.toolStarted(run: runId, session: session, tool: name)]
        case "assistant":
            guard let delta = body["delta"] as? String, !delta.isEmpty else { return [] }
            return [.textDelta(run: runId, session: session, text: delta)]
        default:
            return []
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
make test 2>&1 | tail -5
```
Expected: `** TEST SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
git add Sources/Gateway/OpenClawTranslator.swift Tests/TranslatorTests.swift
git commit -m "feat: OpenClaw gateway frame translator"
```

---

### Task 9: Mock gateway server

A real WebSocket server (Network.framework) speaking the verified protocol: handshake check, then scripted frame playback. Library-shaped so XCTest uses it in-process; the CLI tool wraps it.

**Files:**
- Modify: `Sources/MockGatewayKit/MockGatewayServer.swift`
- Create: `Sources/MockGatewayKit/ScenarioLoader.swift`, `MockGateway/Scenarios/happy-path.json`, `MockGateway/Scenarios/interleaved.json`, `MockGateway/Scenarios/two-sessions.json`, `MockGateway/Scenarios/disconnect.json`, `MockGateway/Scenarios/malformed.json`
- Modify: `MockGateway/main.swift`

- [ ] **Step 1: Write `Sources/MockGatewayKit/ScenarioLoader.swift`**

```swift
import Foundation

public struct MockStep {
    public var delayMs: Int
    /// JSON frame to send (already serialized).
    public var frame: Data?
    /// Raw (possibly invalid) text to send verbatim.
    public var raw: String?
    /// Close the connection at this step.
    public var close: Bool

    public init(delayMs: Int, frame: Data? = nil, raw: String? = nil, close: Bool = false) {
        self.delayMs = delayMs; self.frame = frame; self.raw = raw; self.close = close
    }

    /// Convenience: build a step from a JSON-shaped dictionary.
    public static func send(_ obj: [String: Any], afterMs delay: Int) -> MockStep {
        MockStep(delayMs: delay, frame: try! JSONSerialization.data(withJSONObject: obj))
    }
}

public enum ScenarioLoader {
    /// File shape: {"steps":[{"delayMs":100,"send":{…}} | {"delayMs":0,"sendRaw":"…"} | {"delayMs":0,"close":true}]}
    public static func load(_ url: URL) throws -> [MockStep] {
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let steps = obj["steps"] as? [[String: Any]] else {
            throw NSError(domain: "ScenarioLoader", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "scenario must have a steps array"])
        }
        return try steps.map { s in
            let delay = s["delayMs"] as? Int ?? 0
            if let send = s["send"] as? [String: Any] {
                return MockStep(delayMs: delay, frame: try JSONSerialization.data(withJSONObject: send))
            }
            if let raw = s["sendRaw"] as? String {
                return MockStep(delayMs: delay, raw: raw)
            }
            if s["close"] as? Bool == true {
                return MockStep(delayMs: delay, close: true)
            }
            throw NSError(domain: "ScenarioLoader", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "step needs send, sendRaw, or close"])
        }
    }
}
```

- [ ] **Step 2: Replace `Sources/MockGatewayKit/MockGatewayServer.swift`**

```swift
import Foundation
import Network

/// Minimal OpenClaw-gateway-shaped WebSocket server for tests and demos.
/// Accepts one or more connections; each gets: connect handshake
/// (token-checked if expectToken is set), then the scripted steps.
public final class MockGatewayServer {
    private let listener: NWListener
    private let expectToken: String?
    private let steps: [MockStep]
    private let queue = DispatchQueue(label: "mock-gateway")
    private var connections: [NWConnection] = []

    /// Port 0 → ephemeral; read `port` after start() returns.
    public private(set) var port: UInt16 = 0

    public init(requestedPort: UInt16, expectToken: String? = nil, steps: [MockStep]) throws {
        self.expectToken = expectToken
        self.steps = steps
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        self.listener = try NWListener(
            using: params,
            on: requestedPort == 0 ? .any : NWEndpoint.Port(rawValue: requestedPort)!
        )
    }

    /// Starts listening; returns once the port is bound.
    public func start() throws {
        let ready = DispatchSemaphore(value: 0)
        var startupError: Error?
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = self?.listener.port?.rawValue ?? 0
                ready.signal()
            case .failed(let error):
                startupError = error
                ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        listener.start(queue: queue)
        if ready.wait(timeout: .now() + 5) == .timedOut {
            throw NSError(domain: "MockGateway", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener never became ready"])
        }
        if let e = startupError { throw e }
    }

    public func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
        connections.removeAll()
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        connections.append(conn)
        conn.start(queue: queue)
        receiveHandshake(conn)
    }

    private func receiveHandshake(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data else { return }
            guard
                let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                obj["type"] as? String == "req",
                obj["method"] as? String == "connect",
                let id = obj["id"] as? String
            else {
                conn.cancel()
                return
            }
            let params = obj["params"] as? [String: Any]
            let auth = params?["auth"] as? [String: Any]
            let token = auth?["token"] as? String

            if let expected = self.expectToken, token != expected {
                self.send(conn, obj: [
                    "type": "res", "id": id, "ok": false,
                    "error": ["code": "UNAUTHORIZED", "message": "bad token"],
                ])
                conn.cancel()
                return
            }
            self.send(conn, obj: [
                "type": "res", "id": id, "ok": true,
                "payload": ["type": "hello-ok", "protocol": 4],
            ])
            self.play(self.steps, on: conn)
            self.drainRequests(conn)
        }
    }

    /// Answer any post-connect requests generically so clients don't hang.
    private func drainRequests(_ conn: NWConnection) {
        conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, error == nil, let data else { return }
            if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               obj["type"] as? String == "req", let id = obj["id"] as? String {
                self.send(conn, obj: ["type": "res", "id": id, "ok": true, "payload": [:]])
            }
            self.drainRequests(conn)
        }
    }

    private func play(_ steps: [MockStep], on conn: NWConnection) {
        var when = DispatchTime.now()
        for step in steps {
            when = when + .milliseconds(step.delayMs)
            queue.asyncAfter(deadline: when) { [weak self] in
                if step.close {
                    conn.cancel()
                } else if let frame = step.frame {
                    self?.sendData(conn, frame)
                } else if let raw = step.raw {
                    self?.sendData(conn, Data(raw.utf8))
                }
            }
        }
    }

    private func send(_ conn: NWConnection, obj: [String: Any]) {
        sendData(conn, try! JSONSerialization.data(withJSONObject: obj))
    }

    private func sendData(_ conn: NWConnection, _ data: Data) {
        let meta = NWProtocolWebSocket.Metadata(opcode: .text)
        let ctx = NWConnection.ContentContext(identifier: "frame", metadata: [meta])
        conn.send(content: data, contentContext: ctx, completion: .idempotent)
    }
}

/// Shared frame builders so tests and scenario files agree on shapes.
public enum MockFrames {
    public static func lifecycle(_ phase: String, run: String, session: String, seq: Int) -> [String: Any] {
        agent(run: run, session: session, seq: seq, stream: "lifecycle", data: ["phase": phase])
    }
    public static func tool(name: String, run: String, session: String, seq: Int) -> [String: Any] {
        agent(run: run, session: session, seq: seq, stream: "tool",
              data: ["phase": "start", "name": name, "toolCallId": "t\(seq)", "args": [:]])
    }
    public static func delta(_ text: String, run: String, session: String, seq: Int) -> [String: Any] {
        agent(run: run, session: session, seq: seq, stream: "assistant", data: ["delta": text])
    }
    public static func agent(run: String, session: String, seq: Int,
                             stream: String, data: [String: Any]) -> [String: Any] {
        ["type": "event", "event": "agent",
         "payload": ["runId": run, "seq": seq, "stream": stream,
                     "ts": 0, "sessionKey": session, "data": data]]
    }
}
```

- [ ] **Step 3: Write the scenario JSON files**

`MockGateway/Scenarios/happy-path.json`:

```json
{
  "steps": [
    {"delayMs": 300, "send": {"type":"event","event":"agent","payload":{"runId":"r1","seq":0,"stream":"lifecycle","ts":0,"sessionKey":"main","data":{"phase":"start"}}}},
    {"delayMs": 800, "send": {"type":"event","event":"agent","payload":{"runId":"r1","seq":1,"stream":"tool","ts":0,"sessionKey":"main","data":{"phase":"start","name":"read","toolCallId":"t1","args":{}}}}},
    {"delayMs": 1500, "send": {"type":"event","event":"agent","payload":{"runId":"r1","seq":2,"stream":"tool","ts":0,"sessionKey":"main","data":{"phase":"start","name":"web_search","toolCallId":"t2","args":{}}}}},
    {"delayMs": 1500, "send": {"type":"event","event":"agent","payload":{"runId":"r1","seq":3,"stream":"assistant","ts":0,"sessionKey":"main","data":{"delta":"The build finished. "}}}},
    {"delayMs": 150, "send": {"type":"event","event":"agent","payload":{"runId":"r1","seq":4,"stream":"assistant","ts":0,"sessionKey":"main","data":{"delta":"All 142 tests pass. "}}}},
    {"delayMs": 150, "send": {"type":"event","event":"agent","payload":{"runId":"r1","seq":5,"stream":"assistant","ts":0,"sessionKey":"main","data":{"delta":"Deploy to staging went clean. "}}}},
    {"delayMs": 150, "send": {"type":"event","event":"agent","payload":{"runId":"r1","seq":6,"stream":"assistant","ts":0,"sessionKey":"main","data":{"delta":"Want me to tag the release?"}}}},
    {"delayMs": 500, "send": {"type":"event","event":"agent","payload":{"runId":"r1","seq":7,"stream":"lifecycle","ts":0,"sessionKey":"main","data":{"phase":"end"}}}}
  ]
}
```

`MockGateway/Scenarios/interleaved.json` (text → tool → more text, same run):

```json
{
  "steps": [
    {"delayMs": 300, "send": {"type":"event","event":"agent","payload":{"runId":"r1","seq":0,"stream":"lifecycle","ts":0,"sessionKey":"main","data":{"phase":"start"}}}},
    {"delayMs": 600, "send": {"type":"event","event":"agent","payload":{"runId":"r1","seq":1,"stream":"assistant","ts":0,"sessionKey":"main","data":{"delta":"Checking the logs now. "}}}},
    {"delayMs": 1200, "send": {"type":"event","event":"agent","payload":{"runId":"r1","seq":2,"stream":"tool","ts":0,"sessionKey":"main","data":{"phase":"start","name":"exec","toolCallId":"t1","args":{}}}}},
    {"delayMs": 2500, "send": {"type":"event","event":"agent","payload":{"runId":"r1","seq":3,"stream":"assistant","ts":0,"sessionKey":"main","data":{"delta":"Found it: one flaky test, rerun passed."}}}},
    {"delayMs": 400, "send": {"type":"event","event":"agent","payload":{"runId":"r1","seq":4,"stream":"lifecycle","ts":0,"sessionKey":"main","data":{"phase":"end"}}}}
  ]
}
```

`MockGateway/Scenarios/two-sessions.json` (concurrent runs, focus must not interleave):

```json
{
  "steps": [
    {"delayMs": 300, "send": {"type":"event","event":"agent","payload":{"runId":"a","seq":0,"stream":"lifecycle","ts":0,"sessionKey":"discord","data":{"phase":"start"}}}},
    {"delayMs": 100, "send": {"type":"event","event":"agent","payload":{"runId":"b","seq":0,"stream":"lifecycle","ts":0,"sessionKey":"telegram","data":{"phase":"start"}}}},
    {"delayMs": 300, "send": {"type":"event","event":"agent","payload":{"runId":"a","seq":1,"stream":"assistant","ts":0,"sessionKey":"discord","data":{"delta":"Alpha reply, first conversation. "}}}},
    {"delayMs": 100, "send": {"type":"event","event":"agent","payload":{"runId":"b","seq":1,"stream":"assistant","ts":0,"sessionKey":"telegram","data":{"delta":"Beta reply, second conversation. "}}}},
    {"delayMs": 200, "send": {"type":"event","event":"agent","payload":{"runId":"a","seq":2,"stream":"lifecycle","ts":0,"sessionKey":"discord","data":{"phase":"end"}}}},
    {"delayMs": 100, "send": {"type":"event","event":"agent","payload":{"runId":"b","seq":2,"stream":"lifecycle","ts":0,"sessionKey":"telegram","data":{"phase":"end"}}}}
  ]
}
```

`MockGateway/Scenarios/disconnect.json` (drops mid-stream):

```json
{
  "steps": [
    {"delayMs": 300, "send": {"type":"event","event":"agent","payload":{"runId":"r1","seq":0,"stream":"lifecycle","ts":0,"sessionKey":"main","data":{"phase":"start"}}}},
    {"delayMs": 600, "send": {"type":"event","event":"agent","payload":{"runId":"r1","seq":1,"stream":"assistant","ts":0,"sessionKey":"main","data":{"delta":"This sentence will be cut "}}}},
    {"delayMs": 400, "close": true}
  ]
}
```

`MockGateway/Scenarios/malformed.json` (garbage between valid frames — client must survive):

```json
{
  "steps": [
    {"delayMs": 300, "send": {"type":"event","event":"agent","payload":{"runId":"r1","seq":0,"stream":"lifecycle","ts":0,"sessionKey":"main","data":{"phase":"start"}}}},
    {"delayMs": 200, "sendRaw": "this is not json {{{"},
    {"delayMs": 200, "sendRaw": "{\"type\":\"event\",\"event\":\"agent\",\"payload\":{\"truncated\":"},
    {"delayMs": 200, "send": {"type":"event","event":"agent","payload":{"runId":"r1","seq":1,"stream":"assistant","ts":0,"sessionKey":"main","data":{"delta":"Still alive after garbage."}}}},
    {"delayMs": 300, "send": {"type":"event","event":"agent","payload":{"runId":"r1","seq":2,"stream":"lifecycle","ts":0,"sessionKey":"main","data":{"phase":"end"}}}}
  ]
}
```

- [ ] **Step 4: Replace `MockGateway/main.swift`**

(No `import MockGatewayKit` anywhere — the MockGatewayKit sources compile directly into this tool target per project.yml; the types are in the same module.)

```swift
import Foundation

func usage() -> Never {
    print("usage: mock-gateway --scenario <path.json> [--port N] [--expect-token T] [--loop]")
    exit(2)
}

var port: UInt16 = 18789
var scenarioPath: String?
var expectToken: String?
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--port": port = UInt16(args.removeFirst()) ?? 18789
    case "--scenario": scenarioPath = args.removeFirst()
    case "--expect-token": expectToken = args.removeFirst()
    default: usage()
    }
}
guard let scenarioPath else { usage() }

do {
    let steps = try ScenarioLoader.load(URL(fileURLWithPath: scenarioPath))
    let server = try MockGatewayServer(requestedPort: port, expectToken: expectToken, steps: steps)
    try server.start()
    print("mock-gateway listening on ws://127.0.0.1:\(server.port) — scenario: \(scenarioPath)")
    print("each new connection gets the handshake + scenario; Ctrl-C to stop")
    dispatchMain()
} catch {
    print("mock-gateway failed: \(error)")
    exit(1)
}
```

- [ ] **Step 5: Build and smoke-test manually**

```bash
make build 2>&1 | tail -3
./build/Build/Products/Debug/mock-gateway --scenario MockGateway/Scenarios/happy-path.json --port 18999 &
sleep 1 && kill %1
```
Expected: `mock-gateway listening on ws://127.0.0.1:18999 …`. (Full protocol exercise happens in Task 10's integration tests.)

- [ ] **Step 6: Commit**

```bash
git add Sources/MockGatewayKit MockGateway
git commit -m "feat: mock OpenClaw gateway server with scripted scenarios"
```

---

### Task 10: GatewayClient + integration tests

**Files:**
- Create: `Sources/Gateway/GatewayClient.swift`
- Test: `Tests/GatewayIntegrationTests.swift`

- [ ] **Step 1: Write the failing test** (runs against the in-process mock from Task 9)

```swift
import XCTest

final class GatewayIntegrationTests: XCTestCase {
    private final class Collector {
        var events: [AgentEvent] = []
        let lock = NSLock()
        func add(_ e: AgentEvent) { lock.lock(); events.append(e); lock.unlock() }
        func snapshot() -> [AgentEvent] { lock.lock(); defer { lock.unlock() }; return events }
    }

    private func happyPathSteps() -> [MockStep] {
        [
            .send(MockFrames.lifecycle("start", run: "r1", session: "main", seq: 0), afterMs: 50),
            .send(MockFrames.tool(name: "read", run: "r1", session: "main", seq: 1), afterMs: 50),
            .send(MockFrames.delta("Hello world. ", run: "r1", session: "main", seq: 2), afterMs: 50),
            .send(MockFrames.lifecycle("end", run: "r1", session: "main", seq: 3), afterMs: 50),
        ]
    }

    private func makeClient(port: UInt16, token: String = "tok",
                            collector: Collector) -> GatewayClient {
        GatewayClient(
            url: URL(string: "ws://127.0.0.1:\(port)")!,
            token: token,
            onEvent: { collector.add($0) }
        )
    }

    func testConnectHandshakeAndEventFlow() throws {
        let server = try MockGatewayServer(requestedPort: 0, expectToken: "tok", steps: happyPathSteps())
        try server.start()
        defer { server.stop() }

        let collector = Collector()
        let client = makeClient(port: server.port, collector: collector)
        client.start()
        defer { client.stop() }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && collector.snapshot().count < 5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let events = collector.snapshot()
        XCTAssertEqual(events.first, .connectionUp)
        XCTAssertTrue(events.contains(.runStarted(run: "r1", session: "main")))
        XCTAssertTrue(events.contains(.toolStarted(run: "r1", session: "main", tool: "read")))
        XCTAssertTrue(events.contains(.textDelta(run: "r1", session: "main", text: "Hello world. ")))
        XCTAssertTrue(events.contains(.runEnded(run: "r1", session: "main")))
    }

    func testBadTokenReportsAuthDown() throws {
        let server = try MockGatewayServer(requestedPort: 0, expectToken: "correct", steps: [])
        try server.start()
        defer { server.stop() }

        let collector = Collector()
        let client = makeClient(port: server.port, token: "wrong", collector: collector)
        client.start()
        defer { client.stop() }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && collector.snapshot().isEmpty {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertEqual(collector.snapshot().first, .connectionDown(auth: true))
    }

    func testServerDropReportsNetworkDown() throws {
        let steps: [MockStep] = [
            .send(MockFrames.lifecycle("start", run: "r1", session: "main", seq: 0), afterMs: 50),
            MockStep(delayMs: 100, close: true),
        ]
        let server = try MockGatewayServer(requestedPort: 0, steps: steps)
        try server.start()
        defer { server.stop() }

        let collector = Collector()
        let client = makeClient(port: server.port, collector: collector)
        client.start()
        defer { client.stop() }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && !collector.snapshot().contains(.connectionDown(auth: false)) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        let events = collector.snapshot()
        XCTAssertEqual(events.first, .connectionUp)
        XCTAssertTrue(events.contains(.connectionDown(auth: false)))
    }

    func testMalformedFramesAreSkipped() throws {
        let steps: [MockStep] = [
            MockStep(delayMs: 50, raw: "garbage {{{"),
            .send(MockFrames.delta("survived", run: "r1", session: "main", seq: 0), afterMs: 50),
        ]
        let server = try MockGatewayServer(requestedPort: 0, steps: steps)
        try server.start()
        defer { server.stop() }

        let collector = Collector()
        let client = makeClient(port: server.port, collector: collector)
        client.start()
        defer { client.stop() }

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && !collector.snapshot().contains(.textDelta(run: "r1", session: "main", text: "survived")) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(collector.snapshot().contains(.textDelta(run: "r1", session: "main", text: "survived")))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make test 2>&1 | tail -5
```
Expected: BUILD FAILED — `cannot find 'GatewayClient' in scope`.

- [ ] **Step 3: Write `Sources/Gateway/GatewayClient.swift`**

```swift
import Foundation
import os

/// Connects to the OpenClaw gateway, performs the connect handshake,
/// translates frames, reconnects with backoff. Emits AgentEvents on an
/// internal serial queue — the caller hops to its own queue if needed.
public final class GatewayClient: NSObject, URLSessionWebSocketDelegate {
    private let url: URL
    private let token: String
    private let onEvent: (AgentEvent) -> Void
    private let log = Logger(subsystem: "com.gintini.ZielVanSebastian", category: "gateway")
    private let queue = DispatchQueue(label: "gateway-client")

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var stopped = true
    private var attempts = 0
    private var handshakeComplete = false
    private static let connectId = "connect-1"

    public init(url: URL, token: String, onEvent: @escaping (AgentEvent) -> Void) {
        self.url = url
        self.token = token
        self.onEvent = onEvent
        super.init()
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    public func start() {
        queue.async {
            self.stopped = false
            self.open()
        }
    }

    public func stop() {
        queue.async {
            self.stopped = true
            self.task?.cancel(with: .normalClosure, reason: nil)
            self.task = nil
        }
    }

    // MARK: - Connection lifecycle (all on `queue`)

    private func open() {
        guard !stopped else { return }
        handshakeComplete = false
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receiveLoop(t)
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?) {
        queue.async { self.sendConnect() }
    }

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
                           reason: Data?) {
        queue.async { self.handleDrop() }
    }

    private func sendConnect() {
        let frame: [String: Any] = [
            "type": "req", "id": Self.connectId, "method": "connect",
            "params": [
                "minProtocol": 3, "maxProtocol": 4,
                "client": ["id": "gateway-client", "version": "1.0.0",
                           "platform": "macos", "mode": "operator"],
                "role": "operator",
                "scopes": ["operator.read"],
                "auth": ["token": token],
            ],
        ]
        let data = try! JSONSerialization.data(withJSONObject: frame)
        task?.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
            if let error {
                self?.log.error("connect send failed: \(error.localizedDescription)")
                self?.queue.async { self?.handleDrop() }
            }
        }
    }

    private func receiveLoop(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard self.task === t else { return }
                switch result {
                case .failure:
                    self.handleDrop()
                case .success(let message):
                    let data: Data
                    switch message {
                    case .string(let s): data = Data(s.utf8)
                    case .data(let d): data = d
                    @unknown default: data = Data()
                    }
                    self.handleFrame(data)
                    self.receiveLoop(t)
                }
            }
        }
    }

    private func handleFrame(_ data: Data) {
        if !handshakeComplete {
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return   // pre-handshake garbage / challenge events we don't parse
            }
            // Ignore connect.challenge and other events until our res arrives.
            guard obj["type"] as? String == "res",
                  obj["id"] as? String == Self.connectId else { return }
            if obj["ok"] as? Bool == true {
                handshakeComplete = true
                attempts = 0
                log.info("gateway handshake ok")
                onEvent(.connectionUp)
            } else {
                log.error("gateway rejected connect (auth)")
                onEvent(.connectionDown(auth: true))
                task?.cancel(with: .normalClosure, reason: nil)
                task = nil
                scheduleReconnect(authFailure: true)
            }
            return
        }
        for event in OpenClawTranslator.translate(data) {
            onEvent(event)
        }
    }

    private func handleDrop() {
        guard !stopped, task != nil else { return }
        task = nil
        if handshakeComplete {
            onEvent(.connectionDown(auth: false))
        } else {
            // Drop before handshake: connection refused etc. Still report once.
            onEvent(.connectionDown(auth: false))
        }
        scheduleReconnect(authFailure: false)
    }

    private func scheduleReconnect(authFailure: Bool) {
        guard !stopped else { return }
        let delay: TimeInterval
        if authFailure {
            delay = 60   // a bad token won't fix itself quickly
        } else {
            attempts += 1
            delay = min(60, pow(2, Double(min(attempts, 6)))) + Double.random(in: 0...1)
        }
        log.info("reconnecting in \(delay, format: .fixed(precision: 1))s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.open()
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
make test 2>&1 | tail -8
```
Expected: `** TEST SUCCEEDED **`. Flakiness watch: these tests poll with 5s deadlines; if a test is flaky, raise deadlines, never sleep-and-pray.

- [ ] **Step 5: Commit**

```bash
git add Sources/Gateway/GatewayClient.swift Tests/GatewayIntegrationTests.swift
git commit -m "feat: gateway WebSocket client with handshake, translate, reconnect"
```

---

### Task 11: Metal skeleton — window + static face

First pixels. App opens a window (`--window`) or a plain fullscreen-on-main-screen window (DisplayManager refines this in Task 16), renders the face rects in green on black via the scene pass. No shader effects yet.

**Files:**
- Create: `Sources/Rendering/ZielRenderer.swift`, `Sources/Rendering/ScenePass.swift`, `Sources/Rendering/Shaders.metal`
- Modify: `App/AppDelegate.swift`

- [ ] **Step 1: Write `Sources/Rendering/Shaders.metal`** (scene shaders only; CRT arrives in Task 15)

```metal
#include <metal_stdlib>
using namespace metal;

struct FlatVertexIn {
    float2 position;   // NDC
};

struct V2F {
    float4 position [[position]];
    float2 uv;
};

// --- Flat colored geometry (face rects, sweep band) ---

vertex V2F flat_vertex(const device float2 *verts [[buffer(0)]],
                       uint vid [[vertex_id]]) {
    V2F out;
    out.position = float4(verts[vid], 0, 1);
    out.uv = float2(0, 0);
    return out;
}

fragment float4 flat_fragment(V2F in [[stage_in]],
                              constant float4 &color [[buffer(0)]]) {
    return color;
}

// --- Textured quad (glyph textures; r8 alpha mask × tint) ---

struct TexQuadVertexIn {
    float2 position;   // NDC
    float2 uv;
};

vertex V2F texquad_vertex(const device TexQuadVertexIn *verts [[buffer(0)]],
                          uint vid [[vertex_id]]) {
    V2F out;
    out.position = float4(verts[vid].position, 0, 1);
    out.uv = verts[vid].uv;
    return out;
}

fragment float4 texquad_fragment(V2F in [[stage_in]],
                                 texture2d<float> glyph [[texture(0)]],
                                 constant float4 &tint [[buffer(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    float a = glyph.sample(s, in.uv).r;
    return float4(tint.rgb, tint.a * a);
}
```

- [ ] **Step 2: Write `Sources/Rendering/ScenePass.swift`**

```swift
import MetalKit

/// Renders SceneState content (face, sweep, word, hint) into the current
/// render encoder. Pure geometry assembly — no effects.
final class ScenePass {
    private let device: MTLDevice
    private let flatPipeline: MTLRenderPipelineState
    private let texPipeline: MTLRenderPipelineState

    struct TexQuadVertex {
        var x, y, u, v: Float
    }

    init(device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat) throws {
        self.device = device

        func makePipeline(vertex: String, fragment: String) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction = library.makeFunction(name: vertex)
            desc.fragmentFunction = library.makeFunction(name: fragment)
            desc.colorAttachments[0].pixelFormat = pixelFormat
            desc.colorAttachments[0].isBlendingEnabled = true
            desc.colorAttachments[0].rgbBlendOperation = .add
            desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: desc)
        }
        flatPipeline = try makePipeline(vertex: "flat_vertex", fragment: "flat_fragment")
        texPipeline = try makePipeline(vertex: "texquad_vertex", fragment: "texquad_fragment")
    }

    // MARK: - Face

    /// Face transform: grid units → NDC. Face spans 60% of view height,
    /// centered; pixel-snapped so the grid stays chunky and crisp.
    struct FaceTransform {
        let originX, originY, gridPixel: Double   // view points
        let viewW, viewH: Double

        init(viewW: Double, viewH: Double) {
            self.viewW = viewW
            self.viewH = viewH
            let gp = (viewH * 0.6 / Double(FaceGeometry.gridHeight)).rounded(.down)
            gridPixel = max(1, gp)
            originX = ((viewW - gridPixel * Double(FaceGeometry.gridWidth)) / 2).rounded()
            originY = ((viewH - gridPixel * Double(FaceGeometry.gridHeight)) / 2).rounded()
        }
    }

    /// offset/eyeOffset in grid units; scales are multipliers around centers.
    func drawFace(encoder: MTLRenderCommandEncoder,
                  viewW: Double, viewH: Double,
                  tint: ColorRGB, alpha: Double,
                  faceOffset: (dx: Double, dy: Double) = (0, 0),
                  breatheScale: Double = 1.0,
                  eyeBlinkScale: Double = 1.0,
                  eyeOffset: (dx: Double, dy: Double) = (0, 0)) {
        let t = FaceTransform(viewW: viewW, viewH: viewH)
        var verts: [Float] = []

        let faceCenterY = Double(FaceGeometry.gridHeight) / 2
        let faceCenterX = Double(FaceGeometry.gridWidth) / 2

        for rect in FaceGeometry.all {
            let isEye = FaceGeometry.eyes.contains(rect)
            var x0 = Double(rect.x)
            var y0 = Double(rect.y)
            var x1 = Double(rect.x + rect.w)
            var y1 = Double(rect.y + rect.h)

            if isEye {
                // Blink: squash vertically around the eye's own center.
                let cy = (y0 + y1) / 2
                y0 = cy + (y0 - cy) * eyeBlinkScale
                y1 = cy + (y1 - cy) * eyeBlinkScale
                x0 += eyeOffset.dx; x1 += eyeOffset.dx
                y0 += eyeOffset.dy; y1 += eyeOffset.dy
            }

            // Breathe: scale all geometry around the face center.
            func scaled(_ v: Double, around c: Double) -> Double { c + (v - c) * breatheScale }
            x0 = scaled(x0, around: faceCenterX); x1 = scaled(x1, around: faceCenterX)
            y0 = scaled(y0, around: faceCenterY); y1 = scaled(y1, around: faceCenterY)

            x0 += faceOffset.dx; x1 += faceOffset.dx
            y0 += faceOffset.dy; y1 += faceOffset.dy

            // Grid → view points → NDC. Grid y grows downward; NDC y grows upward.
            let px0 = t.originX + x0 * t.gridPixel
            let px1 = t.originX + x1 * t.gridPixel
            let py0 = t.originY + y0 * t.gridPixel
            let py1 = t.originY + y1 * t.gridPixel
            let nx0 = Float(px0 / viewW * 2 - 1)
            let nx1 = Float(px1 / viewW * 2 - 1)
            let ny0 = Float(1 - py0 / viewH * 2)
            let ny1 = Float(1 - py1 / viewH * 2)

            verts += [nx0, ny0, nx1, ny0, nx0, ny1,
                      nx1, ny0, nx1, ny1, nx0, ny1]
        }

        var color: [Float] = [Float(tint.r), Float(tint.g), Float(tint.b), Float(alpha)]
        encoder.setRenderPipelineState(flatPipeline)
        encoder.setVertexBytes(verts, length: verts.count * MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentBytes(&color, length: 16, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count / 2)
    }

    // MARK: - Sweep band (thinking state)

    /// y in 0…1 from top; draws a soft horizontal band.
    func drawSweep(encoder: MTLRenderCommandEncoder, y: Double,
                   tint: ColorRGB, intensity: Double) {
        let bandH: Float = 0.12   // NDC half-height ≈ 4% of screen
        let cy = Float(1 - y * 2)
        let verts: [Float] = [
            -1, cy - bandH, 1, cy - bandH, -1, cy + bandH,
            1, cy - bandH, 1, cy + bandH, -1, cy + bandH,
        ]
        var color: [Float] = [Float(tint.r), Float(tint.g), Float(tint.b), Float(intensity)]
        encoder.setRenderPipelineState(flatPipeline)
        encoder.setVertexBytes(verts, length: verts.count * MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentBytes(&color, length: 16, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    // MARK: - Textured quad (words, hints — used from Task 13)

    /// rect in NDC: (centerX, centerY, halfW, halfH).
    func drawGlyphQuad(encoder: MTLRenderCommandEncoder, texture: MTLTexture,
                       center: (x: Float, y: Float), half: (w: Float, h: Float),
                       tint: ColorRGB, alpha: Double) {
        let v: [TexQuadVertex] = [
            .init(x: center.x - half.w, y: center.y - half.h, u: 0, v: 1),
            .init(x: center.x + half.w, y: center.y - half.h, u: 1, v: 1),
            .init(x: center.x - half.w, y: center.y + half.h, u: 0, v: 0),
            .init(x: center.x + half.w, y: center.y - half.h, u: 1, v: 1),
            .init(x: center.x + half.w, y: center.y + half.h, u: 1, v: 0),
            .init(x: center.x - half.w, y: center.y + half.h, u: 0, v: 0),
        ]
        var color: [Float] = [Float(tint.r), Float(tint.g), Float(tint.b), Float(alpha)]
        encoder.setRenderPipelineState(texPipeline)
        encoder.setVertexBytes(v, length: v.count * MemoryLayout<TexQuadVertex>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&color, length: 16, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
}
```

- [ ] **Step 3: Write `Sources/Rendering/ZielRenderer.swift`**

```swift
import MetalKit

/// MTKViewDelegate orchestrating the frame: ask the Director for a scene
/// snapshot, draw it. Task 11 version: face only, straight to drawable.
/// Task 15 reroutes through the CRT pipeline.
final class ZielRenderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let scenePass: ScenePass
    /// Pulls the current scene; wired to Director.tick by the app.
    var sceneProvider: (TimeInterval) -> SceneState
    private let startTime = CACurrentMediaTime()

    init(device: MTLDevice, pixelFormat: MTLPixelFormat,
         sceneProvider: @escaping (TimeInterval) -> SceneState) throws {
        self.device = device
        self.queue = device.makeCommandQueue()!
        let library = try device.makeDefaultLibrary(bundle: .main)
        self.scenePass = try ScenePass(device: device, library: library, pixelFormat: pixelFormat)
        self.sceneProvider = sceneProvider
        super.init()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let rpd = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer() else { return }

        let now = CACurrentMediaTime() - startTime
        let scene = sceneProvider(now)
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0.012, green: 0.012, blue: 0.012, alpha: 1)

        if let encoder = cmd.makeRenderCommandEncoder(descriptor: rpd) {
            let w = Double(view.drawableSize.width)
            let h = Double(view.drawableSize.height)
            drawScene(scene, now: now, encoder: encoder, viewW: w, viewH: h)
            encoder.endEncoding()
        }
        cmd.present(drawable)
        cmd.commit()
    }

    /// Task 11: static face. Animations layer in over Tasks 12–13.
    func drawScene(_ scene: SceneState, now: TimeInterval,
                   encoder: MTLRenderCommandEncoder, viewW: Double, viewH: Double) {
        scenePass.drawFace(encoder: encoder, viewW: viewW, viewH: viewH,
                           tint: scene.tint, alpha: 1.0)
    }
}
```

- [ ] **Step 4: Update `App/AppDelegate.swift`** to open the window and drive a placeholder idle scene (gateway wiring comes in Task 17)

```swift
import AppKit
import MetalKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    let options: RunOptions
    var window: NSWindow?
    var renderer: ZielRenderer?
    var director: Director?
    var config = ZielConfig()

    init(options: RunOptions) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let configURL = options.configPath.map { URL(fileURLWithPath: $0) } ?? ZielConfig.defaultURL
        config = ZielConfig.load(from: configURL)

        let director = Director(config: config)
        self.director = director
        // Until the gateway is wired (Task 17), pretend we're connected so
        // the idle face shows.
        director.handle(.connectionUp, now: 0)

        let device = MTLCreateSystemDefaultDevice()!
        let mtkView = MTKView(frame: .zero, device: device)
        mtkView.preferredFramesPerSecond = 60
        mtkView.colorPixelFormat = .bgra8Unorm

        let renderer = try! ZielRenderer(
            device: device,
            pixelFormat: mtkView.colorPixelFormat,
            sceneProvider: { [weak director] now in
                director?.tick(now: now)
                    ?? SceneState(phase: .offline(auth: false), phaseProgress: 1, timeInPhase: 0,
                                  word: nil, wordAge: 0, hint: nil, dozing: false,
                                  tint: ColorRGB(r: 0.1, g: 0.3, b: 0.1))
            }
        )
        self.renderer = renderer
        mtkView.delegate = renderer

        let window: NSWindow
        if options.window {
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
            window.title = "Ziel van Sebastian"
            window.center()
        } else {
            // Plain fullscreen on main screen; DisplayManager (Task 16) takes over later.
            let screen = NSScreen.main!
            window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.level = .mainMenu + 1
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
        }
        window.contentView = mtkView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
```

- [ ] **Step 5: Build and look at it**

```bash
make build 2>&1 | tail -3
"./build/Build/Products/Debug/Ziel van Sebastian.app/Contents/MacOS/Ziel van Sebastian" --window
```
Expected: a window with the green happy-Mac face, correct geometry (small eyes, J-nose hooking left, stepped smile), centered on near-black. Quit with Cmd-Q.

- [ ] **Step 6: Verify tests still pass, commit**

```bash
make test 2>&1 | tail -3
git add Sources/Rendering App/AppDelegate.swift
git commit -m "feat: Metal scene pass rendering the static face in a window"
```

---

### Task 12: Face animations + state visuals

**Files:**
- Create: `Sources/Core/FaceAnimation.swift`
- Modify: `Sources/Rendering/ZielRenderer.swift` (drawScene)
- Test: `Tests/FaceAnimationTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
import XCTest

final class FaceAnimationTests: XCTestCase {
    func testBlinkMostlyOpenDipsClosed() {
        // Open (≈1.0) for the vast majority of the cycle…
        XCTAssertEqual(FaceAnimation.blinkScale(at: 1.0), 1.0, accuracy: 0.01)
        XCTAssertEqual(FaceAnimation.blinkScale(at: 4.0), 1.0, accuracy: 0.01)
        // …and nearly closed at the blink moment (cycle length 7s, blink at the end).
        let closed = FaceAnimation.blinkScale(at: 6.93)
        XCTAssertLessThan(closed, 0.3)
        // Never negative, never above 1.
        for t in stride(from: 0.0, to: 14.0, by: 0.05) {
            let v = FaceAnimation.blinkScale(at: t)
            XCTAssertGreaterThanOrEqual(v, 0.05)
            XCTAssertLessThanOrEqual(v, 1.0)
        }
    }

    func testWanderBounded() {
        for t in stride(from: 0.0, to: 32.0, by: 0.1) {
            let dx = FaceAnimation.wanderOffset(at: t)
            XCTAssertLessThanOrEqual(abs(dx), 1.5)   // grid units
        }
        XCTAssertEqual(FaceAnimation.wanderOffset(at: 0), 0, accuracy: 0.01)
    }

    func testBreatheGentle() {
        for t in stride(from: 0.0, to: 12.0, by: 0.1) {
            let s = FaceAnimation.breatheScale(at: t)
            XCTAssertGreaterThan(s, 0.97)
            XCTAssertLessThan(s, 1.03)
        }
    }

    func testSweepLoopsZeroToOne() {
        XCTAssertEqual(FaceAnimation.sweepY(at: 0), 0, accuracy: 0.01)
        XCTAssertEqual(FaceAnimation.sweepY(at: 1.4), 0.5, accuracy: 0.01)   // period 2.8
        XCTAssertEqual(FaceAnimation.sweepY(at: 2.8), 0, accuracy: 0.01)
    }

    func testEyesUpOffsetOnlyWhenThinking() {
        let off = FaceAnimation.eyesUpOffset(at: 2.5)
        XCTAssertLessThanOrEqual(off.dy, 0)          // up = negative grid y
        XCTAssertGreaterThanOrEqual(off.dy, -1.2)
    }

    func testZzAlphaCycles() {
        for t in stride(from: 0.0, to: 10.0, by: 0.1) {
            let a = FaceAnimation.zzAlpha(at: t)
            XCTAssertGreaterThanOrEqual(a, 0)
            XCTAssertLessThanOrEqual(a, 1)
        }
    }

    func testWakeBlinkIsADoubleBlink() {
        // Open at the edges of the transition…
        XCTAssertEqual(FaceAnimation.wakeBlinkScale(progress: 0), 1.0, accuracy: 0.05)
        XCTAssertEqual(FaceAnimation.wakeBlinkScale(progress: 1), 1.0, accuracy: 0.05)
        // …closed twice in the middle (two dips → double-blink).
        XCTAssertLessThan(FaceAnimation.wakeBlinkScale(progress: 0.25), 0.3)
        XCTAssertLessThan(FaceAnimation.wakeBlinkScale(progress: 0.75), 0.3)
        XCTAssertGreaterThan(FaceAnimation.wakeBlinkScale(progress: 0.5), 0.9)
        for p in stride(from: 0.0, through: 1.0, by: 0.02) {
            let v = FaceAnimation.wakeBlinkScale(progress: p)
            XCTAssertGreaterThanOrEqual(v, 0.05)
            XCTAssertLessThanOrEqual(v, 1.0)
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

```bash
make test 2>&1 | tail -5
```
Expected: BUILD FAILED — `cannot find 'FaceAnimation' in scope`.

- [ ] **Step 3: Write `Sources/Core/FaceAnimation.swift`**

```swift
import Foundation

/// Pure functions of time → animation parameters. The renderer evaluates
/// these every frame; no stored animation state anywhere.
public enum FaceAnimation {
    /// Eye openness 0.08…1.0. 7s cycle; a fast double-dip blink near the end.
    public static func blinkScale(at t: TimeInterval) -> Double {
        let cycle = t.truncatingRemainder(dividingBy: 7.0)
        let blinkWindow = 6.8...7.0
        guard blinkWindow.contains(cycle) else { return 1.0 }
        let u = (cycle - 6.8) / 0.2                  // 0…1 inside the blink
        let openness = abs(cos(u * .pi))             // dip to 0 mid-blink
        return max(0.08, openness)
    }

    /// Horizontal wander in grid units, ±1.4, slow drift. 0 at t=0.
    public static func wanderOffset(at t: TimeInterval) -> Double {
        1.4 * sin(t * 2 * .pi / 16.0) * sin(t * 2 * .pi / 7.3)
    }

    /// Whole-face breathing scale, ±2%.
    public static func breatheScale(at t: TimeInterval) -> Double {
        1.0 + 0.02 * sin(t * 2 * .pi / 6.0)
    }

    /// Scanline sweep position 0…1 (top→bottom), period 2.8s.
    public static func sweepY(at t: TimeInterval, period: Double = 2.8) -> Double {
        (t / period).truncatingRemainder(dividingBy: 1.0)
    }

    /// Thinking: eyes drift up-left and back, 5s cycle. Grid units.
    public static func eyesUpOffset(at t: TimeInterval) -> (dx: Double, dy: Double) {
        let u = (sin(t * 2 * .pi / 5.0 - .pi / 2) + 1) / 2   // 0…1…0
        return (dx: -0.6 * u, dy: -1.0 * u)
    }

    /// Doze z's pulse: slow fade in/out, 4s cycle.
    public static func zzAlpha(at t: TimeInterval) -> Double {
        max(0, sin(t * 2 * .pi / 4.0)) * 0.8
    }

    /// Waking transition: a quick double-blink as a function of phase
    /// progress 0…1. Two full open→closed→open cycles across the transition.
    public static func wakeBlinkScale(progress: Double) -> Double {
        let p = max(0, min(1, progress))
        return max(0.08, abs(cos(p * 2 * .pi)))
    }
}
```

- [ ] **Step 4: Wire animations into `ZielRenderer.drawScene`** (replace the Task 11 body)

```swift
    func drawScene(_ scene: SceneState, now: TimeInterval,
                   encoder: MTLRenderCommandEncoder, viewW: Double, viewH: Double) {
        switch scene.phase {
        case .idle, .waking, .offline:
            let dozing = scene.dozing
            let isOffline: Bool
            if case .offline = scene.phase { isOffline = true } else { isOffline = false }
            let blink: Double
            if dozing || isOffline {
                blink = 0.08
            } else if scene.phase == .waking {
                blink = FaceAnimation.wakeBlinkScale(progress: scene.phaseProgress)
            } else {
                blink = FaceAnimation.blinkScale(at: now)
            }
            let wander = (dozing || isOffline || scene.phase == .waking) ? 0 : FaceAnimation.wanderOffset(at: now)
            scenePass.drawFace(encoder: encoder, viewW: viewW, viewH: viewH,
                               tint: scene.tint, alpha: 1.0,
                               faceOffset: (dx: wander, dy: 0),
                               breatheScale: FaceAnimation.breatheScale(at: now),
                               eyeBlinkScale: blink)

        case .thinking:
            scenePass.drawSweep(encoder: encoder,
                                y: FaceAnimation.sweepY(at: now),
                                tint: scene.tint, intensity: 0.10)
            let up = FaceAnimation.eyesUpOffset(at: now)
            scenePass.drawFace(encoder: encoder, viewW: viewW, viewH: viewH,
                               tint: scene.tint, alpha: 1.0,
                               breatheScale: FaceAnimation.breatheScale(at: now),
                               eyeBlinkScale: FaceAnimation.blinkScale(at: now),
                               eyeOffset: up)

        case .speaking:
            // Word quad arrives in Task 13; nothing but tinted darkness for now.
            break

        case .settling:
            // Face fades back in over the settle.
            scenePass.drawFace(encoder: encoder, viewW: viewW, viewH: viewH,
                               tint: scene.tint, alpha: scene.phaseProgress,
                               breatheScale: FaceAnimation.breatheScale(at: now))
        }
    }
```

- [ ] **Step 5: Add a temporary `--state` debug flag** to eyeball each phase. In `App/main.swift` add to `RunOptions`:

```swift
    var debugState: String?
    // in the parse switch:
    case "--state":
        i += 1
        if i < args.count { o.debugState = args[i] }
```

And in `AppDelegate.applicationDidFinishLaunching`, after `director.handle(.connectionUp, now: 0)`:

```swift
        switch options.debugState {
        case "thinking":
            director.handle(.runStarted(run: "dbg", session: "dbg"), now: 0)
            director.handle(.toolStarted(run: "dbg", session: "dbg", tool: "read"), now: 0)
        case "offline":
            director.handle(.connectionDown(auth: false), now: 0)
        default:
            break
        }
```

- [ ] **Step 6: Build, eyeball each state**

```bash
make build 2>&1 | tail -3
"./build/Build/Products/Debug/Ziel van Sebastian.app/Contents/MacOS/Ziel van Sebastian" --window
"./build/Build/Products/Debug/Ziel van Sebastian.app/Contents/MacOS/Ziel van Sebastian" --window --state thinking
"./build/Build/Products/Debug/Ziel van Sebastian.app/Contents/MacOS/Ziel van Sebastian" --window --state offline
```
Expected: idle = green face breathing, blinking ~every 7s, drifting gently. Thinking = amber, eyes drift up-left, soft band sweeping down. Offline = dim green, eyes closed, static.

- [ ] **Step 7: Run tests, commit**

```bash
make test 2>&1 | tail -3
git add Sources/Core/FaceAnimation.swift Sources/Rendering/ZielRenderer.swift App/main.swift App/AppDelegate.swift Tests/FaceAnimationTests.swift
git commit -m "feat: time-pure face animations for idle, thinking, offline"
```

---

### Task 13: Glyph rendering — words, hints, z's

**Files:**
- Create: `Sources/Rendering/GlyphRasterizer.swift`
- Modify: `Sources/Rendering/ZielRenderer.swift`

- [ ] **Step 1: Write `Sources/Rendering/GlyphRasterizer.swift`**

```swift
import CoreText
import Metal

/// Rasterizes a word via Core Text into an r8Unorm alpha texture.
/// LRU-caches by string+pointSize bucket.
final class GlyphRasterizer {
    private let device: MTLDevice
    private let fontName: String
    private var cache: [String: MTLTexture] = [:]
    private var order: [String] = []
    private let capacity = 64

    init(device: MTLDevice, fontName: String) {
        self.device = device
        self.fontName = fontName
    }

    /// Renders at a fixed large point size; the quad scales to fit on screen.
    /// kern > 0 for letterspaced hints.
    func texture(for text: String, pointSize: CGFloat = 180, kern: CGFloat = 0) -> MTLTexture? {
        let key = "\(text)|\(pointSize)|\(kern)"
        if let hit = cache[key] {
            touch(key)
            return hit
        }

        let font = CTFontCreateWithName(fontName as CFString, pointSize, nil)
        var attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(gray: 1, alpha: 1),
        ]
        if kern > 0 { attrs[.kern] = kern }
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let line = CTLineCreateWithAttributedString(attributed)
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
        guard width > 0 else { return nil }

        let pad: CGFloat = 8
        let w = Int((width + pad * 2).rounded(.up))
        let h = Int((ascent + descent + pad * 2).rounded(.up))

        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: w,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.textPosition = CGPoint(x: pad, y: descent + pad)
        CTLineDraw(line, ctx)

        guard let data = ctx.data else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                    withBytes: data, bytesPerRow: w)

        cache[key] = tex
        order.append(key)
        if order.count > capacity {
            cache.removeValue(forKey: order.removeFirst())
        }
        return tex
    }

    private func touch(_ key: String) {
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
    }
}
```

- [ ] **Step 2: Add glyph drawing to `ZielRenderer`**

Add the rasterizer property and init it (font from config — pass `fontName` through the initializer):

```swift
    // properties
    let glyphs: GlyphRasterizer

    // in init, add parameter `fontName: String` and:
    self.glyphs = GlyphRasterizer(device: device, fontName: fontName)
```

Update `AppDelegate` to pass `fontName: config.look.fontName` at the `ZielRenderer(...)` call.

Add helpers to `ZielRenderer`:

```swift
    /// Draws `text` centered at (cx, cy) (NDC), scaled to fit the given
    /// fraction of the view, preserving the texture aspect.
    private func drawText(_ text: String, encoder: MTLRenderCommandEncoder,
                          viewW: Double, viewH: Double,
                          cx: Float, cy: Float, maxWFrac: Double, maxHFrac: Double,
                          tint: ColorRGB, alpha: Double, scale: Double = 1.0,
                          kern: CGFloat = 0) {
        guard let tex = glyphs.texture(for: text, kern: kern) else { return }
        let texW = Double(tex.width), texH = Double(tex.height)
        let maxW = viewW * maxWFrac, maxH = viewH * maxHFrac
        let fit = min(maxW / texW, maxH / texH) * scale
        let halfW = Float(texW * fit / viewW)        // NDC half-width = w/viewW (×2/2)
        let halfH = Float(texH * fit / viewH)
        scenePass.drawGlyphQuad(encoder: encoder, texture: tex,
                                center: (x: cx, y: cy), half: (w: halfW, h: halfH),
                                tint: tint, alpha: alpha)
    }
```

Then extend `drawScene`:

```swift
        case .speaking:
            if let word = scene.word {
                // Pop-in: 80ms scale 0.96→1.0, alpha 0.2→1.0.
                let pop = min(1.0, scene.wordAge / 0.08)
                let scale = 0.96 + 0.04 * pop
                let alpha = 0.2 + 0.8 * pop
                drawText(word.uppercased(), encoder: encoder, viewW: viewW, viewH: viewH,
                         cx: 0, cy: 0, maxWFrac: 0.85, maxHFrac: 0.5,
                         tint: scene.tint, alpha: alpha, scale: scale)
            }
```

In the `.thinking` case, after drawing the face, add the hint:

```swift
            if let hint = scene.hint {
                drawText(hint, encoder: encoder, viewW: viewW, viewH: viewH,
                         cx: 0, cy: -0.72, maxWFrac: 0.5, maxHFrac: 0.09,
                         tint: scene.tint, alpha: 0.9, kern: 6)
            }
```

In the `.idle` case, when `scene.dozing`, add the z's:

```swift
            if dozing {
                drawText("z z Z", encoder: encoder, viewW: viewW, viewH: viewH,
                         cx: 0.55, cy: 0.6, maxWFrac: 0.18, maxHFrac: 0.1,
                         tint: scene.tint, alpha: FaceAnimation.zzAlpha(at: now))
            }
```

In the same `.idle/.waking/.offline` branch, when offline, add the status hint (spec: dim `OFFLINE`, or `AUTH` when the token was rejected):

```swift
            if case .offline(let auth) = scene.phase {
                drawText(auth ? "AUTH" : "OFFLINE",
                         encoder: encoder, viewW: viewW, viewH: viewH,
                         cx: 0, cy: -0.72, maxWFrac: 0.4, maxHFrac: 0.08,
                         tint: scene.tint, alpha: 0.7, kern: 6)
            }
```

- [ ] **Step 3: Build, eyeball with the debug flag**

Add one more debug state in `AppDelegate` (same switch as Task 12):

```swift
        case "speaking":
            director.handle(.runStarted(run: "dbg", session: "dbg"), now: 0)
            director.handle(.textDelta(run: "dbg", session: "dbg",
                text: "The build finished. All 142 tests pass. Deploy went clean. Want me to tag the release? "), now: 0)
```

```bash
make build 2>&1 | tail -3
"./build/Build/Products/Debug/Ziel van Sebastian.app/Contents/MacOS/Ziel van Sebastian" --window --state speaking
"./build/Build/Products/Debug/Ziel van Sebastian.app/Contents/MacOS/Ziel van Sebastian" --window --state thinking
```
Expected: speaking = big white uppercase words, one at a time, subtle pop per word, longer holds on `finished.`/`pass.`; then settling (face fades back) then idle. Thinking = amber face + `READING…` letterspaced at the bottom, fading after ~2.5s.

- [ ] **Step 4: Run tests, commit**

```bash
make test 2>&1 | tail -3
git add Sources/Rendering App/AppDelegate.swift
git commit -m "feat: Core Text glyph rendering for RSVP words, hints, and doze z's"
```

---

### Task 14: Demo mode

**Files:**
- Create: `Sources/Core/DemoScript.swift`
- Modify: `App/AppDelegate.swift`

- [ ] **Step 1: Write `Sources/Core/DemoScript.swift`**

```swift
import Foundation

/// Scripted AgentEvent sequence for gateway-free development and demos.
/// Loops forever: idle → wake → think (tools) → speak → settle → pause.
public enum DemoScript {
    public static let loopPauseSeconds: TimeInterval = 6

    /// (delay-from-sequence-start, event)
    public static let sequence: [(at: TimeInterval, event: AgentEvent)] = [
        (0.0, .runStarted(run: "demo", session: "demo")),
        (1.0, .toolStarted(run: "demo", session: "demo", tool: "read")),
        (3.0, .toolStarted(run: "demo", session: "demo", tool: "web_search")),
        (5.0, .toolStarted(run: "demo", session: "demo", tool: "exec")),
        (7.0, .textDelta(run: "demo", session: "demo", text: "The build finished. ")),
        (7.2, .textDelta(run: "demo", session: "demo", text: "All 142 tests pass. ")),
        (7.4, .textDelta(run: "demo", session: "demo", text: "Deploy to staging went clean. ")),
        (7.6, .textDelta(run: "demo", session: "demo", text: "One warning in the logs, nothing serious. ")),
        (7.8, .textDelta(run: "demo", session: "demo", text: "Want me to tag the release?")),
        (8.2, .runEnded(run: "demo", session: "demo")),
    ]

    public static var totalLength: TimeInterval {
        (sequence.last?.at ?? 0) + loopPauseSeconds
    }
}
```

- [ ] **Step 2: Add the demo driver to `AppDelegate`**

```swift
    private var demoTimer: Timer?

    private func startDemo(director: Director, clock: @escaping () -> TimeInterval) {
        var cursor = 0
        var loopStart = clock()
        demoTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            let now = clock()
            let t = now - loopStart
            while cursor < DemoScript.sequence.count && DemoScript.sequence[cursor].at <= t {
                director.handle(DemoScript.sequence[cursor].event, now: now)
                cursor += 1
            }
            if cursor >= DemoScript.sequence.count && t >= DemoScript.totalLength {
                cursor = 0
                loopStart = now
            }
        }
    }
```

In `applicationDidFinishLaunching`, after the `director.handle(.connectionUp, now: 0)` line, define a shared clock and start demo when flagged. Use one monotonic clock everywhere — `CACurrentMediaTime()` minus a stored epoch — and pass the SAME clock into the renderer's sceneProvider (replace the renderer's internal `startTime` with this app-level epoch so Director and renderer agree on `now`):

```swift
        let epoch = CACurrentMediaTime()
        let clock: () -> TimeInterval = { CACurrentMediaTime() - epoch }
        // sceneProvider becomes: { _ in director.tick(now: clock()) } — one time source.
        if options.demo {
            startDemo(director: director, clock: clock)
        }
```

(Refactor note: `ZielRenderer.draw` currently computes `now` from its own startTime; change `sceneProvider: (TimeInterval) -> SceneState` to be called as `sceneProvider(clock())` by passing the clock into the renderer init, OR simpler — keep the signature, have AppDelegate's closure ignore the renderer-provided timestamp and use `clock()`. The renderer's `now` for FaceAnimation must then come from the scene: add `now` to drawScene from the same clock by passing the clock into ZielRenderer's init. Choose passing the clock into ZielRenderer's init: `init(device:pixelFormat:fontName:clock:sceneProvider:)`, using `clock()` in `draw`.)

- [ ] **Step 3: Run the full demo loop**

```bash
make run
```
Expected: the complete lifecycle on repeat — green idle face → double-take wake to amber → `READING…`/`SEARCHING…`/`RUNNING…` hints under the pondering face with sweep → white RSVP words with pacing → afterglow settle → green idle → (6s) → again.

- [ ] **Step 4: Run tests, commit**

```bash
make test 2>&1 | tail -3
git add Sources/Core/DemoScript.swift App/AppDelegate.swift Sources/Rendering/ZielRenderer.swift
git commit -m "feat: looping demo mode driving the full state lifecycle"
```

---

### Task 15: CRT shader pipeline

The signature look. Frame flow becomes: scene → `sceneTex` → persistence blend (ping-pong, afterglow) → bright-pass downsample → blur H → blur V → composite (curvature, scanlines, mask, vignette, flicker, noise) → drawable. All parameters live-reload from config.

**Files:**
- Create: `Sources/Rendering/CRTPipeline.swift`
- Modify: `Sources/Rendering/Shaders.metal`, `Sources/Rendering/ZielRenderer.swift`, `App/AppDelegate.swift`

- [ ] **Step 1: Append the CRT shaders to `Sources/Rendering/Shaders.metal`**

```metal
// ============================ CRT pipeline ============================

struct CRTParams {
    float scanlineIntensity;
    float maskIntensity;
    float bloomStrength;
    float curvature;
    float vignette;
    float flicker;
    float noise;
    float persistence;
    float time;
    float2 resolution;
};

// Fullscreen triangle — no vertex buffer needed.
vertex V2F fullscreen_vertex(uint vid [[vertex_id]]) {
    float2 pos[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    V2F out;
    out.position = float4(pos[vid], 0, 1);
    out.uv = pos[vid] * 0.5 + 0.5;
    out.uv.y = 1.0 - out.uv.y;
    return out;
}

// Phosphor persistence: new = max(scene, previous * decay).
fragment float4 persist_fragment(V2F in [[stage_in]],
                                 texture2d<float> scene [[texture(0)]],
                                 texture2d<float> previous [[texture(1)]],
                                 constant CRTParams &p [[buffer(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    float3 cur = scene.sample(s, in.uv).rgb;
    float3 prev = previous.sample(s, in.uv).rgb * p.persistence;
    return float4(max(cur, prev), 1);
}

// Bright pass (sampled at quarter res by the smaller target).
fragment float4 bright_fragment(V2F in [[stage_in]],
                                texture2d<float> src [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear);
    float3 c = src.sample(s, in.uv).rgb;
    float lum = dot(c, float3(0.299, 0.587, 0.114));
    return float4(c * smoothstep(0.35, 0.75, lum), 1);
}

constant float blurWeights[5] = { 0.227027, 0.194594, 0.121622, 0.054054, 0.016216 };

fragment float4 blur_h_fragment(V2F in [[stage_in]],
                                texture2d<float> src [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float texel = 1.0 / src.get_width();
    float3 acc = src.sample(s, in.uv).rgb * blurWeights[0];
    for (int i = 1; i < 5; i++) {
        acc += src.sample(s, in.uv + float2(texel * i, 0)).rgb * blurWeights[i];
        acc += src.sample(s, in.uv - float2(texel * i, 0)).rgb * blurWeights[i];
    }
    return float4(acc, 1);
}

fragment float4 blur_v_fragment(V2F in [[stage_in]],
                                texture2d<float> src [[texture(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float texel = 1.0 / src.get_height();
    float3 acc = src.sample(s, in.uv).rgb * blurWeights[0];
    for (int i = 1; i < 5; i++) {
        acc += src.sample(s, in.uv + float2(0, texel * i)).rgb * blurWeights[i];
        acc += src.sample(s, in.uv - float2(0, texel * i)).rgb * blurWeights[i];
    }
    return float4(acc, 1);
}

static float2 barrel(float2 uv, float k) {
    float2 c = uv - 0.5;
    float r2 = dot(c, c);
    return 0.5 + c * (1.0 + k * r2);
}

static float hash21(float2 p) {
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

fragment float4 composite_fragment(V2F in [[stage_in]],
                                   texture2d<float> phosphor [[texture(0)]],
                                   texture2d<float> bloom [[texture(1)]],
                                   constant CRTParams &p [[buffer(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    float2 uv = barrel(in.uv, p.curvature);
    // Outside the tube → black.
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        return float4(0, 0, 0, 1);
    }

    float3 color = phosphor.sample(s, uv).rgb;
    color += bloom.sample(s, uv).rgb * p.bloomStrength;

    // Scanlines: darken between lines (one scanline per ~3 output pixels).
    float line = sin(uv.y * p.resolution.y * 1.047);   // π/3
    color *= 1.0 - p.scanlineIntensity * (0.5 + 0.5 * line);

    // Aperture grille: RGB triads across x.
    int px = int(uv.x * p.resolution.x);
    float3 mask = float3(1.0 - p.maskIntensity);
    mask[px % 3] = 1.0;
    color *= mask;

    // Vignette.
    float2 d = uv - 0.5;
    color *= 1.0 - p.vignette * dot(d, d) * 2.5;

    // Flicker + noise.
    color *= 1.0 - p.flicker * (0.5 + 0.5 * sin(p.time * 120.0));
    color += (hash21(uv * p.resolution + p.time) - 0.5) * p.noise;

    return float4(max(color, 0.0), 1);
}
```

- [ ] **Step 2: Write `Sources/Rendering/CRTPipeline.swift`**

```swift
import MetalKit

/// Owns the offscreen textures and post-process passes:
/// sceneTex → persist (ping-pong) → bright → blurH → blurV → composite.
final class CRTPipeline {
    struct Params {
        var scanlineIntensity: Float
        var maskIntensity: Float
        var bloomStrength: Float
        var curvature: Float
        var vignette: Float
        var flicker: Float
        var noise: Float
        var persistence: Float
        var time: Float
        var resolution: SIMD2<Float>

        init(_ c: ShaderConfig, time: Float, resolution: SIMD2<Float>) {
            scanlineIntensity = Float(c.scanlineIntensity)
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

    /// Live-reloaded by the config watcher.
    var shaderConfig: ShaderConfig

    private let device: MTLDevice
    private let persistPipeline: MTLRenderPipelineState
    private let brightPipeline: MTLRenderPipelineState
    private let blurHPipeline: MTLRenderPipelineState
    private let blurVPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState

    private(set) var sceneTex: MTLTexture!
    private var phosphorA: MTLTexture!
    private var phosphorB: MTLTexture!
    private var bloomA: MTLTexture!
    private var bloomB: MTLTexture!
    private var pingIsA = true
    private var size: CGSize = .zero

    init(device: MTLDevice, library: MTLLibrary,
         drawableFormat: MTLPixelFormat, shaderConfig: ShaderConfig) throws {
        self.device = device
        self.shaderConfig = shaderConfig

        func pipeline(_ fragment: String, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: "fullscreen_vertex")
            d.fragmentFunction = library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = format
            return try device.makeRenderPipelineState(descriptor: d)
        }
        persistPipeline = try pipeline("persist_fragment", format: .bgra8Unorm)
        brightPipeline = try pipeline("bright_fragment", format: .bgra8Unorm)
        blurHPipeline = try pipeline("blur_h_fragment", format: .bgra8Unorm)
        blurVPipeline = try pipeline("blur_v_fragment", format: .bgra8Unorm)
        compositePipeline = try pipeline("composite_fragment", format: drawableFormat)
    }

    func resize(_ newSize: CGSize) {
        guard newSize != size, newSize.width > 0, newSize.height > 0 else { return }
        size = newSize
        func tex(_ w: Int, _ h: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: max(1, w), height: max(1, h), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        let w = Int(newSize.width), h = Int(newSize.height)
        sceneTex = tex(w, h)
        phosphorA = tex(w, h)
        phosphorB = tex(w, h)
        bloomA = tex(w / 4, h / 4)
        bloomB = tex(w / 4, h / 4)
    }

    /// Scene is already rendered into sceneTex. Runs all post passes and
    /// composites into the drawable's render pass.
    func run(cmd: MTLCommandBuffer, drawableRPD: MTLRenderPassDescriptor, time: Float) {
        let (prev, next) = pingIsA ? (phosphorA!, phosphorB!) : (phosphorB!, phosphorA!)
        pingIsA.toggle()
        var params = Params(shaderConfig, time: time,
                            resolution: SIMD2(Float(size.width), Float(size.height)))

        func pass(into target: MTLTexture, pipeline: MTLRenderPipelineState,
                  textures: [MTLTexture]) {
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = target
            rpd.colorAttachments[0].loadAction = .dontCare
            rpd.colorAttachments[0].storeAction = .store
            guard let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) else { return }
            enc.setRenderPipelineState(pipeline)
            for (i, t) in textures.enumerated() { enc.setFragmentTexture(t, index: i) }
            enc.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            enc.endEncoding()
        }

        pass(into: next, pipeline: persistPipeline, textures: [sceneTex, prev])
        pass(into: bloomA, pipeline: brightPipeline, textures: [next])
        pass(into: bloomB, pipeline: blurHPipeline, textures: [bloomA])
        pass(into: bloomA, pipeline: blurVPipeline, textures: [bloomB])

        guard let enc = cmd.makeRenderCommandEncoder(descriptor: drawableRPD) else { return }
        enc.setRenderPipelineState(compositePipeline)
        enc.setFragmentTexture(next, index: 0)
        enc.setFragmentTexture(bloomA, index: 1)
        enc.setFragmentBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }
}
```

**Layout caution:** the Metal `CRTParams` struct and Swift `Params` struct must match field-for-field (9 floats then float2; Swift's `SIMD2<Float>` aligns to 8 — add a padding `Float` in BOTH if the metal compiler reports a mismatch; verify by checking that visuals respond to each knob).

- [ ] **Step 3: Reroute `ZielRenderer.draw` through the pipeline**

```swift
    // new property, set in init (pass ShaderConfig through):
    let crt: CRTPipeline

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let drawableRPD = view.currentRenderPassDescriptor,
              let cmd = queue.makeCommandBuffer() else { return }

        crt.resize(view.drawableSize)

        let now = clock()
        let scene = sceneProvider(now)

        // Pass 1: scene into the offscreen texture.
        let sceneRPD = MTLRenderPassDescriptor()
        sceneRPD.colorAttachments[0].texture = crt.sceneTex
        sceneRPD.colorAttachments[0].loadAction = .clear
        sceneRPD.colorAttachments[0].storeAction = .store
        sceneRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0.012, green: 0.012, blue: 0.012, alpha: 1)
        if let enc = cmd.makeRenderCommandEncoder(descriptor: sceneRPD) {
            let w = Double(view.drawableSize.width)
            let h = Double(view.drawableSize.height)
            drawScene(scene, now: now, encoder: enc, viewW: w, viewH: h)
            enc.endEncoding()
        }

        // Passes 2–5: persistence, bloom, composite.
        crt.run(cmd: cmd, drawableRPD: drawableRPD, time: Float(now))

        cmd.present(drawable)
        cmd.commit()
    }
```

(The ScenePass pipelines render into `bgra8Unorm` — same format as before, no change needed.)

- [ ] **Step 4: Config live reload in `AppDelegate`**

```swift
    private var configWatcher: DispatchSourceFileSystemObject?

    private func watchConfig(at url: URL, renderer: ZielRenderer, director: Director) {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }   // no file yet; defaults in use
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        source.setEventHandler { [weak self] in
            // Keep last-good config when the file is mid-edit or invalid.
            if let data = try? Data(contentsOf: url),
               let fresh = try? ZielConfig.decode(data) {
                self?.config = fresh
                renderer.crt.shaderConfig = fresh.look.shader
                director.updatePacing(fresh.pacing)
            }
            // Editors often replace the file: re-arm the watcher.
            source.cancel()
            self?.watchConfig(at: url, renderer: renderer, director: director)
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configWatcher = source
    }
```

Call `watchConfig(at: configURL, renderer: renderer, director: director)` at the end of `applicationDidFinishLaunching`.

- [ ] **Step 5: Build, run the demo, tune by eye**

```bash
make run
```
Expected: the whole demo now looks like a tube — visible scanlines, soft bloom around glowing geometry, slight barrel curvature with black corners, gentle vignette and flicker, and **afterglow**: when an RSVP word swaps, the old word ghosts for a beat (persistence 0.82).

Then live-tuning check: create `~/Library/Application Support/Ziel van Sebastian/config.json` with `{"look":{"shader":{"scanlineIntensity":0.8}}}` while the app runs windowed with default config path — scanlines visibly deepen without restart.

- [ ] **Step 6: Run tests, commit**

```bash
make test 2>&1 | tail -3
git add Sources/Rendering App/AppDelegate.swift
git commit -m "feat: CRT post-process pipeline with persistence, bloom, and live-tunable params"
```

---

### Task 16: DisplayManager — the appliance behaviors

**Files:**
- Create: `App/DisplayManager.swift`
- Modify: `App/AppDelegate.swift`

- [ ] **Step 1: Write `App/DisplayManager.swift`**

```swift
import AppKit
import IOKit.pwr_mgt

/// Finds the Wokyis panel, owns the fullscreen window placement, hides the
/// cursor, blocks display sleep, and survives display reconfiguration.
final class DisplayManager {
    private let config: DisplayConfig
    private let window: NSWindow
    private var sleepAssertion: IOPMAssertionID = 0
    private var observer: NSObjectProtocol?

    init(window: NSWindow, config: DisplayConfig) {
        self.window = window
        self.config = config
    }

    func activate() {
        place()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.place()
        }
        if config.preventDisplaySleep {
            IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Ziel van Sebastian appliance display" as CFString,
                &sleepAssertion)
        }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if sleepAssertion != 0 { IOPMAssertionRelease(sleepAssertion) }
    }

    /// Preference: name match → smallest display → hide and wait.
    func targetScreen() -> NSScreen? {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return nil }
        let needles = config.preferredNameContains.map { $0.lowercased() }
        if let named = screens.first(where: { screen in
            let name = screen.localizedName.lowercased()
            return needles.contains { name.contains($0) }
        }) {
            return named
        }
        return screens.min { a, b in
            a.frame.width * a.frame.height < b.frame.width * b.frame.height
        }
    }

    private func place() {
        guard let screen = targetScreen() else {
            window.orderOut(nil)   // no displays at all; wait for the next change
            return
        }
        window.setFrame(screen.frame, display: true)
        window.makeKeyAndOrderFront(nil)
        NSCursor.setHiddenUntilMouseMoves(true)
        NSCursor.hide()
    }
}
```

- [ ] **Step 2: Use it from `AppDelegate`** — replace the non-`--window` branch:

```swift
        } else {
            window = NSWindow(contentRect: NSScreen.main?.frame ?? .zero,
                              styleMask: [.borderless],
                              backing: .buffered, defer: false)
            window.level = .mainMenu + 1
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            NSApp.presentationOptions = [.hideDock, .hideMenuBar]
            let dm = DisplayManager(window: window, config: config.display)
            self.displayManager = dm
            dm.activate()
        }
```

with the stored property `var displayManager: DisplayManager?`.

- [ ] **Step 3: Verify on the dev machine**

```bash
make build 2>&1 | tail -3
"./build/Build/Products/Debug/Ziel van Sebastian.app/Contents/MacOS/Ziel van Sebastian" --demo
```
Expected (no Wokyis attached): fullscreen on the smallest connected display, menu bar and Dock hidden, cursor hidden, demo loop running under the CRT shader. Cmd-Q quits and restores everything. If a second display is attached, the app picks the smaller one; unplugging/replugging a display moves the window correctly within a second.

- [ ] **Step 4: Run tests, commit**

```bash
make test 2>&1 | tail -3
git add App/DisplayManager.swift App/AppDelegate.swift
git commit -m "feat: display targeting, fullscreen appliance mode, sleep prevention"
```

---

### Task 17: Gateway wiring, login item, ship it

**Files:**
- Modify: `App/AppDelegate.swift`, `App/main.swift`
- Create: `config.example.json`, `README.md`

- [ ] **Step 1: Wire the GatewayClient in `AppDelegate`**

Replace the unconditional `director.handle(.connectionUp, now: 0)` from Task 11 — the real connection state must drive it now. Demo mode keeps the synthetic connectionUp.

```swift
    private var gateway: GatewayClient?

    // In applicationDidFinishLaunching, replacing the placeholder block:
        if options.demo {
            director.handle(.connectionUp, now: clock())
            startDemo(director: director, clock: clock)
        } else if options.debugState != nil {
            director.handle(.connectionUp, now: clock())
            applyDebugState(director: director, clock: clock)
        } else {
            let gateway = GatewayClient(
                url: URL(string: config.gateway.url)!,
                token: config.gateway.token,
                onEvent: { [weak director] event in
                    DispatchQueue.main.async {
                        director?.handle(event, now: clock())
                    }
                }
            )
            self.gateway = gateway
            gateway.start()
        }
```

(`applyDebugState` is the Task 12/13 debug switch, extracted into a method.)

- [ ] **Step 2: Login item support** in `App/main.swift`, before constructing NSApplication:

```swift
import ServiceManagement

if options.installLoginItem {
    do {
        try SMAppService.mainApp.register()
        print("registered as login item")
        exit(0)
    } catch {
        print("login item registration failed: \(error)")
        exit(1)
    }
}
```

- [ ] **Step 3: Write `config.example.json`**

```json
{
  "gateway": {
    "url": "ws://127.0.0.1:18789",
    "token": "PUT-YOUR-GATEWAY-TOKEN-HERE"
  },
  "pacing": {
    "baseMs": 280,
    "perCharMs": 60,
    "charThreshold": 6,
    "sentencePauseMs": 320,
    "clausePauseMs": 150,
    "catchupStart": 10,
    "catchupFull": 80,
    "minFactor": 0.45
  },
  "look": {
    "idleTint": "#41ff6a",
    "thinkingTint": "#ffb000",
    "speakingTint": "#e6edf5",
    "fontName": "Menlo-Bold",
    "shader": {
      "scanlineIntensity": 0.35,
      "maskIntensity": 0.25,
      "bloomStrength": 0.55,
      "curvature": 0.12,
      "vignette": 0.35,
      "flicker": 0.03,
      "noise": 0.04,
      "persistence": 0.82
    }
  },
  "behavior": {
    "wakingSeconds": 0.8,
    "settlingSeconds": 1.2,
    "dozeAfterSeconds": 600,
    "hintHoldSeconds": 2.5
  },
  "display": {
    "preferredNameContains": ["wokyis", "m5"],
    "preventDisplaySleep": true
  }
}
```

- [ ] **Step 4: Write `README.md`**

```markdown
# Ziel van Sebastian

A CRT soul for a Mac mini appliance. The Wokyis M5 dock looks like a 1984
Macintosh; this app completes it: the happy-Mac face idles on a simulated
phosphor tube, wakes amber when OpenClaw thinks, and speaks replies one big
glowing word at a time.

## Build

    brew install xcodegen
    make build          # builds the app + mock-gateway
    make test           # unit + integration tests
    make run            # windowed demo loop, no gateway needed

## Configure

    mkdir -p ~/Library/Application\ Support/Ziel\ van\ Sebastian
    cp config.example.json ~/Library/Application\ Support/Ziel\ van\ Sebastian/config.json
    # put your OpenClaw gateway token in it

Config is watched: shader knobs and pacing reload live while the app runs.

## Run against a mock gateway

    ./build/Build/Products/Debug/mock-gateway --scenario MockGateway/Scenarios/happy-path.json
    "./build/Build/Products/Debug/Ziel van Sebastian.app/Contents/MacOS/Ziel van Sebastian" --window

## Appliance install

    "…/Ziel van Sebastian" --install-login-item

## Flags

| Flag | Effect |
|---|---|
| `--window` | 960×540 window instead of claiming a display |
| `--demo` | looping scripted lifecycle, no gateway |
| `--state idle\|thinking\|speaking\|offline` | jump to a state for tuning |
| `--config <path>` | alternate config file |
| `--install-login-item` | register for launch at login |
```

- [ ] **Step 5: End-to-end check against the mock gateway**

```bash
make build 2>&1 | tail -3
./build/Build/Products/Debug/mock-gateway --scenario MockGateway/Scenarios/happy-path.json --port 18789 &
mkdir -p "$HOME/Library/Application Support/Ziel van Sebastian"
cp config.example.json "$HOME/Library/Application Support/Ziel van Sebastian/config.json"
"./build/Build/Products/Debug/Ziel van Sebastian.app/Contents/MacOS/Ziel van Sebastian" --window
kill %1
```
Expected: app starts on the OFFLINE face briefly, connects (mock accepts any token since `--expect-token` not passed), goes idle, then the happy-path scenario plays through the real gateway path: wake → `READING…` → `SEARCHING…` → RSVP reply → settle. Also verify `two-sessions.json` (no word interleave) and `disconnect.json` (OFFLINE face on drop, reconnect attempt visible in logs).

- [ ] **Step 6: Run all tests, commit**

```bash
make test 2>&1 | tail -3
git add App config.example.json README.md
git commit -m "feat: gateway wiring, login item, example config, README"
```

- [ ] **Step 7: Real-appliance checklist** (manual, on the Mac mini)

1. `make build`, copy the app to /Applications, run `--install-login-item`.
2. Put the real gateway token in config; confirm idle face on the Wokyis panel.
3. Talk to OpenClaw from any channel: face wakes within ~1s, hints match tools, reply streams readably.
4. Unplug/replug the second dock's display: app stays on (or returns to) the Wokyis panel.
5. Leave it running overnight; check memory in Activity Monitor is flat and the connection survived.

---

## Plan self-review notes

- **Spec coverage:** visual states incl. waking double-blink and OFFLINE/AUTH hint (Tasks 11–13), pacing rules incl. catch-up + markdown + `[code]` token (5–6), state machine incl. focus lock + implicit runs + doze + offline/AUTH (7), OpenClaw translation incl. heartbeat drop (8), mock gateway + all six scenario types (9: happy, interleaved, two-sessions, disconnect, malformed; auth via `--expect-token` flag exercised in test form in Task 10), reconnect/backoff (10), CRT shader with persistence + live reload keeping last-good config (15), display targeting/fallback/sleep (16), login item + Cmd-Q menu + config + README (17/1), `--demo`/`--window` (14/11).
- **Out-of-scope honored:** no audio, no touch, no Hermes adapter (seam = translator), no thinking-text streaming (hints only), no shader snapshot tests.
- **Type consistency:** `AgentEvent` cases carry `run:`/`session:` throughout; `PacedWord.holdMs` (ms) vs Director time (seconds) conversion happens exactly once (`(now - wordStart) * 1000 >= word.holdMs`); `ShaderConfig` field names match `CRTPipeline.Params` and the Metal `CRTParams` 1:1.
