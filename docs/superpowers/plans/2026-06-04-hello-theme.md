# "hello" Theme & Launch-Time Theming Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a theme system with two built-in themes — `classic` (today's green/amber CRT look, pixel-identical) and `hello` (off-white on dark gray with a hard drop shadow, the new default) — selectable via `look.theme` in config.json or a `--theme` launch flag.

**Architecture:** Themes are complete look presets in Core (`Theme.swift`). The config `look` block becomes a partial overlay (all fields optional); `ResolvedLook.resolve(look, themeOverride:)` merges theme + overlay once at startup and throws on unknown theme names. The renderer consumes a `ResolvedLook` (background clear color, font, shader params, optional `ShadowSpec`); `ScenePass` double-draws face and glyph quads when a shadow is present.

**Tech Stack:** Swift 5.10 (do NOT bump the language mode), Metal, XcodeGen, XCTest. Build/test only via `make test` / `make build` (SourceKit editor diagnostics are unreliable here — Makefile is the source of truth). `*.xcodeproj` is generated; edit `project.yml` never the project file (no project.yml change is needed — new files under `Sources/` and `Tests/` are picked up by the existing target globs).

**Spec:** `docs/superpowers/specs/2026-06-04-hello-theme-design.md`

**Invariants (from spec — violating these fails review):**
- `FaceGeometry.swift` untouched; `testLockedGeometry` stays green.
- `FaceAnimation` and `Director` phase logic untouched (only where tints come *from* changes).
- `Sources/Rendering/Shaders.metal` untouched.
- `classic` resolves to today's exact values.

---

## File Map

| File | Action | Responsibility |
|---|---|---|
| `Sources/Core/Theme.swift` | Create | `Theme` presets, `ShadowSpec`, `ResolvedLook` + resolution, `ThemeError` |
| `Sources/Core/Config.swift` | Modify | `ShaderOverlay` (new), `LookConfig` → all-optional overlay |
| `Sources/Core/Director.swift` | Modify | `init` takes `ResolvedLook` for tints |
| `Sources/Rendering/ZielRenderer.swift` | Modify | `init` takes `ResolvedLook`; themed clear color; thread view size to glyph draws |
| `Sources/Rendering/ScenePass.swift` | Modify | shadow double-draw for face + glyph quads |
| `App/main.swift` | Modify | `--theme` flag in `RunOptions` |
| `App/AppDelegate.swift` | Modify | resolve look at startup (exit on bad theme), watcher re-resolve, `--state idle` |
| `config.example.json` | Modify | `look` block → `{"theme": "hello"}` |
| `Tests/ThemeTests.swift` | Create | preset pins + resolution behavior |
| `Tests/ConfigTests.swift` | Modify | overlay decode semantics |
| `Tests/DirectorTests.swift` | Modify | helper passes a resolved `classic` look |
| `README.md` | Modify | Themes section + refreshed screenshots |

---

### Task 1: Theme presets and ShadowSpec (Core, additive)

Pure addition — nothing existing changes, the tree stays green throughout.

**Files:**
- Create: `Sources/Core/Theme.swift`
- Create: `Tests/ThemeTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `Tests/ThemeTests.swift`:

```swift
import XCTest

final class ThemeTests: XCTestCase {

    // Pins the "don't lose the old look" guarantee: classic must be today's
    // exact values. If this test changes, that guarantee is being broken.
    func testClassicPinsTodaysLook() {
        let t = Theme.classic
        XCTAssertEqual(t.idleTint, "#41ff6a")
        XCTAssertEqual(t.thinkingTint, "#ffb000")
        XCTAssertEqual(t.speakingTint, "#e6edf5")
        XCTAssertEqual(t.fontName, "Menlo-Bold")
        XCTAssertEqual(t.background, "#030303")
        XCTAssertNil(t.shadowColor)
        XCTAssertEqual(t.shadowOffsetX, 0)
        XCTAssertEqual(t.shadowOffsetY, 0)
        // Shader: pin literals (not ShaderConfig()) so default drift can't hide here.
        XCTAssertEqual(t.shader.scanlineIntensity, 0.35, accuracy: 0.0001)
        XCTAssertEqual(t.shader.scanlinePitch, 3, accuracy: 0.0001)
        XCTAssertEqual(t.shader.maskIntensity, 0.25, accuracy: 0.0001)
        XCTAssertEqual(t.shader.bloomStrength, 0.55, accuracy: 0.0001)
        XCTAssertEqual(t.shader.curvature, 0.12, accuracy: 0.0001)
        XCTAssertEqual(t.shader.vignette, 0.35, accuracy: 0.0001)
        XCTAssertEqual(t.shader.flicker, 0.03, accuracy: 0.0001)
        XCTAssertEqual(t.shader.noise, 0.04, accuracy: 0.0001)
        XCTAssertEqual(t.shader.persistence, 0.82, accuracy: 0.0001)
    }

    func testHelloValues() {
        let t = Theme.hello
        XCTAssertEqual(t.idleTint, "#8a877c")
        XCTAssertEqual(t.thinkingTint, "#c9c5b8")
        XCTAssertEqual(t.speakingTint, "#efeadd")
        XCTAssertEqual(t.fontName, "Menlo-Bold")
        XCTAssertEqual(t.background, "#26271f")
        XCTAssertEqual(t.shadowColor, "#0e0f0b")
        XCTAssertEqual(t.shadowOffsetX, 0.6, accuracy: 0.0001)
        XCTAssertEqual(t.shadowOffsetY, 0.75, accuracy: 0.0001)
        // Monochrome CRT: no RGB triads, softer bloom. Everything else = classic.
        XCTAssertEqual(t.shader.maskIntensity, 0.0, accuracy: 0.0001)
        XCTAssertEqual(t.shader.bloomStrength, 0.4, accuracy: 0.0001)
        XCTAssertEqual(t.shader.scanlineIntensity, Theme.classic.shader.scanlineIntensity)
        XCTAssertEqual(t.shader.persistence, Theme.classic.shader.persistence)
    }

    func testBuiltInsAndDefaultName() {
        XCTAssertEqual(Set(Theme.builtIns.keys), ["classic", "hello"])
        XCTAssertEqual(Theme.defaultName, "hello")
        XCTAssertEqual(Theme.builtIns["classic"], Theme.classic)
        XCTAssertEqual(Theme.builtIns["hello"], Theme.hello)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test 2>&1 | tail -20`
Expected: FAIL — compile error, `cannot find 'Theme' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/Core/Theme.swift`:

```swift
import Foundation

/// Hard offset drop shadow. Offsets are in face-grid pixels (the pixel-art
/// unit, `FaceTransform.gridPixel`) so the shadow scales with the display.
public struct ShadowSpec: Equatable {
    public let color: ColorRGB
    public let offsetX: Double
    public let offsetY: Double

    public init(color: ColorRGB, offsetX: Double, offsetY: Double) {
        self.color = color; self.offsetX = offsetX; self.offsetY = offsetY
    }
}

/// A complete, named preset for the app's look. Config `look` keys override
/// the active theme's values (see `ResolvedLook.resolve`).
public struct Theme: Equatable {
    public var idleTint: String
    public var thinkingTint: String
    public var speakingTint: String
    public var fontName: String
    public var background: String
    public var shadowColor: String?
    public var shadowOffsetX: Double
    public var shadowOffsetY: Double
    public var shader: ShaderConfig

    public static let defaultName = "hello"

    public static let builtIns: [String: Theme] = [
        "classic": .classic,
        "hello": .hello,
    ]

    /// Today's green/amber CRT look — must stay pixel-identical (see spec).
    public static let classic = Theme(
        idleTint: "#41ff6a", thinkingTint: "#ffb000", speakingTint: "#e6edf5",
        fontName: "Menlo-Bold", background: "#030303",
        shadowColor: nil, shadowOffsetX: 0, shadowOffsetY: 0,
        shader: ShaderConfig()
    )

    /// Original-Macintosh "hello." look: off-white on dark gray, hard drop
    /// shadow, monochrome CRT (no RGB triads). State is coded by brightness.
    public static let hello: Theme = {
        var shader = ShaderConfig()
        shader.maskIntensity = 0.0
        shader.bloomStrength = 0.4
        return Theme(
            idleTint: "#8a877c", thinkingTint: "#c9c5b8", speakingTint: "#efeadd",
            fontName: "Menlo-Bold", background: "#26271f",
            shadowColor: "#0e0f0b", shadowOffsetX: 0.6, shadowOffsetY: 0.75,
            shader: shader
        )
    }()
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `make test 2>&1 | tail -20`
Expected: PASS, including all pre-existing tests (especially `testLockedGeometry`).

- [ ] **Step 5: Commit**

```bash
git add Sources/Core/Theme.swift Tests/ThemeTests.swift
git commit -m "feat: built-in look themes — classic (current) and hello presets"
```

---

### Task 2: LookConfig becomes an overlay; ResolvedLook resolution

The config-semantics boundary. `LookConfig`/`ShaderConfig` consumers switch to a
resolved look in the same commit so the tree never breaks. This is the largest
task; every changed file is shown in full below.

**Files:**
- Modify: `Sources/Core/Config.swift` (LookConfig at lines 64–80; add ShaderOverlay after ShaderConfig which ends at line 62)
- Modify: `Sources/Core/Theme.swift` (append ResolvedLook + ThemeError)
- Modify: `Sources/Core/Director.swift:30-36` (init)
- Modify: `App/AppDelegate.swift` (applicationDidFinishLaunching at 19–106, watchConfig at 150–173)
- Modify: `Tests/ConfigTests.swift`, `Tests/ThemeTests.swift`, `Tests/DirectorTests.swift:4-6`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ThemeTests.swift` (inside the `ThemeTests` class):

```swift
    // MARK: - Resolution

    func testDefaultThemeIsHello() throws {
        let r = try ResolvedLook.resolve(LookConfig())
        XCTAssertEqual(r.idleTint, Theme.hello.idleTint)
        XCTAssertEqual(r.background, Theme.hello.background)
        XCTAssertEqual(r.shader.maskIntensity, 0.0, accuracy: 0.0001)
    }

    func testConfigSelectsTheme() throws {
        var look = LookConfig()
        look.theme = "classic"
        let r = try ResolvedLook.resolve(look)
        XCTAssertEqual(r.idleTint, "#41ff6a")
        XCTAssertEqual(r.shader.maskIntensity, 0.25, accuracy: 0.0001)
        XCTAssertNil(r.shadow)
    }

    func testCLIOverrideBeatsConfigTheme() throws {
        var look = LookConfig()
        look.theme = "hello"
        let r = try ResolvedLook.resolve(look, themeOverride: "classic")
        XCTAssertEqual(r.idleTint, "#41ff6a")
    }

    func testUnknownThemeThrows() {
        var look = LookConfig()
        look.theme = "vaporwave"
        XCTAssertThrowsError(try ResolvedLook.resolve(look)) { error in
            let msg = String(describing: error)
            XCTAssertTrue(msg.contains("vaporwave"), "names the bad theme: \(msg)")
            XCTAssertTrue(msg.contains("classic") && msg.contains("hello"),
                          "lists valid themes: \(msg)")
        }
        XCTAssertThrowsError(try ResolvedLook.resolve(LookConfig(), themeOverride: "nope"))
    }

    func testExplicitKeysBeatTheme() throws {
        var look = LookConfig()
        look.idleTint = "#123456"
        // Wins regardless of which theme is active or how it was chosen.
        XCTAssertEqual(try ResolvedLook.resolve(look).idleTint, "#123456")
        XCTAssertEqual(try ResolvedLook.resolve(look, themeOverride: "classic").idleTint, "#123456")
        // Untouched keys still come from the theme.
        XCTAssertEqual(try ResolvedLook.resolve(look).speakingTint, Theme.hello.speakingTint)
    }

    func testShaderOverlayPartialApply() throws {
        var look = LookConfig()
        var shader = ShaderOverlay()
        shader.bloomStrength = 0.9
        look.shader = shader
        let r = try ResolvedLook.resolve(look)  // hello base
        XCTAssertEqual(r.shader.bloomStrength, 0.9, accuracy: 0.0001)   // override wins
        XCTAssertEqual(r.shader.maskIntensity, 0.0, accuracy: 0.0001)   // theme survives
        XCTAssertEqual(r.shader.persistence, 0.82, accuracy: 0.0001)    // theme survives
    }

    func testShadowSpecDerivation() throws {
        var classic = LookConfig(); classic.theme = "classic"
        XCTAssertNil(try ResolvedLook.resolve(classic).shadow)

        let hello = try ResolvedLook.resolve(LookConfig()).shadow
        XCTAssertEqual(hello, ShadowSpec(color: ColorRGB(hex: "#0e0f0b"),
                                         offsetX: 0.6, offsetY: 0.75))

        // Zeroing both offsets disables the shadow even when a color is set.
        var flat = LookConfig()
        flat.shadowOffsetX = 0
        flat.shadowOffsetY = 0
        XCTAssertNil(try ResolvedLook.resolve(flat).shadow)
    }
```

Replace the **entire contents** of `Tests/ConfigTests.swift` with:

```swift
import XCTest

final class ConfigTests: XCTestCase {
    func testDefaults() {
        let c = ZielConfig()
        XCTAssertEqual(c.gateway.url, "ws://127.0.0.1:18789")
        XCTAssertEqual(c.pacing.baseMs, 280)
        XCTAssertEqual(c.behavior.dozeAfterSeconds, 600)
        // look is now a pure overlay: empty by default, values come from the theme.
        XCTAssertEqual(c.look, LookConfig())
        XCTAssertNil(c.look.theme)
        XCTAssertNil(c.look.idleTint)
        XCTAssertNil(c.look.shader)
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

    func testLookOverlayDecodesOnlyPresentKeys() throws {
        let json = #"{"look":{"theme":"classic","idleTint":"#ff0000","shader":{"scanlineIntensity":0.99}}}"#
        let c = try ZielConfig.decode(Data(json.utf8))
        XCTAssertEqual(c.look.theme, "classic")
        XCTAssertEqual(c.look.idleTint, "#ff0000")
        XCTAssertEqual(c.look.shader?.scanlineIntensity, 0.99)
        XCTAssertNil(c.look.shader?.persistence)    // absent key stays nil
        XCTAssertNil(c.look.thinkingTint)           // absent key stays nil
    }

    func testLookOverlayResolvesAgainstTheme() throws {
        let json = #"{"look":{"shader":{"scanlineIntensity":0.99}}}"#
        let c = try ZielConfig.decode(Data(json.utf8))
        let r = try ResolvedLook.resolve(c.look)    // default theme: hello
        XCTAssertEqual(r.shader.scanlineIntensity, 0.99, accuracy: 0.0001)
        XCTAssertEqual(r.shader.persistence, 0.82, accuracy: 0.0001)  // theme survives
        XCTAssertEqual(r.idleTint, "#8a877c")                          // theme survives
    }
}
```

In `Tests/DirectorTests.swift`, replace the `makeDirector` helper (lines 4–6):

```swift
    private func makeDirector() -> Director {
        // classic keeps the green/amber tint assertions below meaningful.
        var look = LookConfig()
        look.theme = "classic"
        return Director(config: ZielConfig(), look: try! ResolvedLook.resolve(look))
    }
```

(`testTintLerpsThroughWaking` at line 112 asserts `#41ff6a`/`#ffb000` — with the
classic look it keeps passing unchanged. Touch nothing else in this file.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `make test 2>&1 | tail -20`
Expected: FAIL — compile errors (`cannot find 'ResolvedLook' in scope`, `cannot find 'ShaderOverlay' in scope`, Director init signature).

- [ ] **Step 3: Rewrite LookConfig and add ShaderOverlay in `Sources/Core/Config.swift`**

Insert after the `ShaderConfig` struct (ends line 62), before `LookConfig`:

```swift
/// Partial shader override from config — only keys present in JSON are set.
/// Applied on top of the active theme's ShaderConfig.
public struct ShaderOverlay: Codable, Equatable {
    public var scanlineIntensity: Double?
    public var scanlinePitch: Double?
    public var maskIntensity: Double?
    public var bloomStrength: Double?
    public var curvature: Double?
    public var vignette: Double?
    public var flicker: Double?
    public var noise: Double?
    public var persistence: Double?

    public init() {}

    public func applied(to base: ShaderConfig) -> ShaderConfig {
        var s = base
        if let v = scanlineIntensity { s.scanlineIntensity = v }
        if let v = scanlinePitch { s.scanlinePitch = v }
        if let v = maskIntensity { s.maskIntensity = v }
        if let v = bloomStrength { s.bloomStrength = v }
        if let v = curvature { s.curvature = v }
        if let v = vignette { s.vignette = v }
        if let v = flicker { s.flicker = v }
        if let v = noise { s.noise = v }
        if let v = persistence { s.persistence = v }
        return s
    }
}
```

Replace the entire `LookConfig` struct (currently lines 64–80) with:

```swift
/// Partial look override from config. Values come from the theme named by
/// `theme` (default: Theme.defaultName); any key set here wins over the theme.
/// Synthesized Codable uses decodeIfPresent for optionals — absent keys stay nil.
public struct LookConfig: Codable, Equatable {
    public var theme: String?
    public var idleTint: String?
    public var thinkingTint: String?
    public var speakingTint: String?
    public var fontName: String?
    public var background: String?
    public var shadowColor: String?
    public var shadowOffsetX: Double?
    public var shadowOffsetY: Double?
    public var shader: ShaderOverlay?

    public init() {}
}
```

(Note: the old custom `init(from:)` is deleted — synthesized Codable does the
right thing for all-optional fields. `ShaderConfig` itself is unchanged.)

- [ ] **Step 4: Append ResolvedLook and ThemeError to `Sources/Core/Theme.swift`**

```swift
public enum ThemeError: Error, Equatable, CustomStringConvertible {
    case unknownTheme(name: String, valid: [String])

    public var description: String {
        switch self {
        case let .unknownTheme(name, valid):
            return "unknown theme '\(name)' — valid themes: \(valid.joined(separator: ", "))"
        }
    }
}

/// The look the app actually runs with: active theme + config overrides,
/// computed once at startup.
public struct ResolvedLook: Equatable {
    public var idleTint: String
    public var thinkingTint: String
    public var speakingTint: String
    public var fontName: String
    public var background: String
    public var shadowColor: String?
    public var shadowOffsetX: Double
    public var shadowOffsetY: Double
    public var shader: ShaderConfig

    /// nil when no shadow color, or when both offsets are zero.
    public var shadow: ShadowSpec? {
        guard let hex = shadowColor, shadowOffsetX != 0 || shadowOffsetY != 0 else { return nil }
        return ShadowSpec(color: ColorRGB(hex: hex), offsetX: shadowOffsetX, offsetY: shadowOffsetY)
    }

    public static func resolve(_ look: LookConfig, themeOverride: String? = nil) throws -> ResolvedLook {
        let name = themeOverride ?? look.theme ?? Theme.defaultName
        guard let theme = Theme.builtIns[name] else {
            throw ThemeError.unknownTheme(name: name, valid: Theme.builtIns.keys.sorted())
        }
        return ResolvedLook(
            idleTint: look.idleTint ?? theme.idleTint,
            thinkingTint: look.thinkingTint ?? theme.thinkingTint,
            speakingTint: look.speakingTint ?? theme.speakingTint,
            fontName: look.fontName ?? theme.fontName,
            background: look.background ?? theme.background,
            shadowColor: look.shadowColor ?? theme.shadowColor,
            shadowOffsetX: look.shadowOffsetX ?? theme.shadowOffsetX,
            shadowOffsetY: look.shadowOffsetY ?? theme.shadowOffsetY,
            shader: (look.shader ?? ShaderOverlay()).applied(to: theme.shader)
        )
    }
}
```

- [ ] **Step 5: Update `Director.init` (`Sources/Core/Director.swift:30-36`)**

Replace the constructor with:

```swift
    public init(config: ZielConfig, look: ResolvedLook) {
        self.pacer = WordPacer(config: config.pacing)
        self.behavior = config.behavior
        self.idleTint = ColorRGB(hex: look.idleTint)
        self.thinkingTint = ColorRGB(hex: look.thinkingTint)
        self.speakingTint = ColorRGB(hex: look.speakingTint)
    }
```

Nothing else in Director changes (phase logic, `tint(elapsed:progress:)`,
offline `idleTint.scaled(0.45)` all stay).

- [ ] **Step 6: Update `App/AppDelegate.swift`**

In `applicationDidFinishLaunching` (line 19), replace the first lines:

```swift
        let configURL = options.configPath.map { URL(fileURLWithPath: $0) } ?? ZielConfig.defaultURL
        config = ZielConfig.load(from: configURL)

        let director = Director(config: config)
```

with:

```swift
        let configURL = options.configPath.map { URL(fileURLWithPath: $0) } ?? ZielConfig.defaultURL
        config = ZielConfig.load(from: configURL)

        let look: ResolvedLook
        do {
            look = try ResolvedLook.resolve(config.look)
        } catch {
            fputs("error: \(error)\n", stderr)
            exit(1)
        }

        let director = Director(config: config, look: look)
```

In the same method, the renderer construction currently reads:

```swift
            fontName: config.look.fontName,
            shaderConfig: config.look.shader,
```

Replace those two argument lines with:

```swift
            fontName: look.fontName,
            shaderConfig: look.shader,
```

In `watchConfig` (line 150), the event handler currently reads:

```swift
            if let data = try? Data(contentsOf: url),
               let fresh = try? ZielConfig.decode(data) {
                self?.config = fresh
                renderer.crt.shaderConfig = fresh.look.shader
                director.updatePacing(fresh.pacing)
            }
```

Replace with (shader hot-reload now goes through resolution; a full theme
switch still requires relaunch — tints/background/shadow are start-time):

```swift
            if let data = try? Data(contentsOf: url),
               let fresh = try? ZielConfig.decode(data),
               let freshLook = try? ResolvedLook.resolve(fresh.look) {
                self?.config = fresh
                renderer.crt.shaderConfig = freshLook.shader
                director.updatePacing(fresh.pacing)
            }
```

- [ ] **Step 7: Run the full suite**

Run: `make test 2>&1 | tail -20`
Expected: PASS — all of ThemeTests, ConfigTests, DirectorTests (incl. `testTintLerpsThroughWaking`), FaceGeometryTests (`testLockedGeometry`), and the rest.

- [ ] **Step 8: Build the app target**

Run: `make build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 9: Commit**

```bash
git add Sources/Core/Config.swift Sources/Core/Theme.swift Sources/Core/Director.swift \
        App/AppDelegate.swift Tests/ConfigTests.swift Tests/ThemeTests.swift Tests/DirectorTests.swift
git commit -m "feat: config look block becomes theme overlay; ResolvedLook resolution"
```

---

### Task 3: `--theme` launch flag

**Files:**
- Modify: `App/main.swift` (`RunOptions`, lines 3–38)
- Modify: `App/AppDelegate.swift` (two `ResolvedLook.resolve` calls from Task 2)

- [ ] **Step 1: Add the flag to `RunOptions`**

In `App/main.swift`, add a field after `var debugState: String?`:

```swift
    var theme: String?
```

and a case in the `parse` switch, after the `--config` case (same error style):

```swift
            case "--theme":
                i += 1
                if i < args.count {
                    o.theme = args[i]
                } else {
                    fputs("error: --theme requires a theme name argument\n", stderr)
                    exit(1)
                }
```

- [ ] **Step 2: Wire it through `AppDelegate`**

In `applicationDidFinishLaunching`, change the resolve call from Task 2 to:

```swift
            look = try ResolvedLook.resolve(config.look, themeOverride: options.theme)
```

In `watchConfig`'s event handler, change the resolve to keep honoring the flag
across hot reloads:

```swift
               let freshLook = try? ResolvedLook.resolve(fresh.look, themeOverride: self?.options.theme)
```

(`self?.options.theme` flattens to `String?` via optional chaining — no
double-optional issue.)

- [ ] **Step 3: Build and verify the error path manually**

```bash
make build 2>&1 | tail -3
./build/Build/Products/Debug/Ziel\ van\ Sebastian.app/Contents/MacOS/Ziel\ van\ Sebastian --window --demo --theme vaporwave
```

Expected: process exits immediately, stderr shows
`error: unknown theme 'vaporwave' — valid themes: classic, hello`.

Then sanity-check the happy path (window opens with the green classic face, Ctrl-C to quit):

```bash
./build/Build/Products/Debug/Ziel\ van\ Sebastian.app/Contents/MacOS/Ziel\ van\ Sebastian --window --demo --theme classic
```

- [ ] **Step 4: Commit**

```bash
git add App/main.swift App/AppDelegate.swift
git commit -m "feat: --theme launch flag overrides config theme"
```

---

### Task 4: Renderer consumes ResolvedLook; themed background

**Files:**
- Modify: `Sources/Rendering/ZielRenderer.swift` (init lines 16–31, draw line ~49)
- Modify: `App/AppDelegate.swift` (renderer call site)

- [ ] **Step 1: Change `ZielRenderer.init` to take the resolved look**

Replace the `fontName`/`shaderConfig` parameters with one `look` parameter, and
store the background clear color. The init becomes:

```swift
    private let background: MTLClearColor

    init(device: MTLDevice, pixelFormat: MTLPixelFormat,
         look: ResolvedLook,
         clock: @escaping () -> TimeInterval,
         sceneProvider: @escaping (TimeInterval) -> SceneState) throws {
        self.device = device
        self.queue = device.makeCommandQueue()!
        let library = try device.makeDefaultLibrary(bundle: .main)
        self.scenePass = try ScenePass(device: device, library: library, pixelFormat: pixelFormat)
        self.glyphs = GlyphRasterizer(device: device, fontName: look.fontName)
        self.crt = try CRTPipeline(device: device, library: library,
                                   drawableFormat: pixelFormat, shaderConfig: look.shader)
        let bg = ColorRGB(hex: look.background)
        self.background = MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1)
        self.clock = clock
        self.sceneProvider = sceneProvider
        super.init()
    }
```

(Put the `background` property declaration next to the existing `clock`
property at the top of the class, not literally inside the init.)

- [ ] **Step 2: Use it in `draw(in:)`**

Replace the hardcoded clear (currently line ~49):

```swift
        sceneRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0.012, green: 0.012, blue: 0.012, alpha: 1)
```

with:

```swift
        sceneRPD.colorAttachments[0].clearColor = background
```

(The `CRTPipeline` intermediate-pass clears at `CRTPipeline.swift:111` and
`:130` stay black — phosphor/bloom buffers, per spec. The composite's
outside-barrel black at `Shaders.metal:140` also stays.)

- [ ] **Step 3: Update the call site in `App/AppDelegate.swift`**

The renderer construction arguments from Task 2:

```swift
            fontName: look.fontName,
            shaderConfig: look.shader,
```

become:

```swift
            look: look,
```

- [ ] **Step 4: Build, test, and look at it**

```bash
make test 2>&1 | tail -5     # expected: PASS (no Core changes, but keep the habit)
make run                     # demo loop
```

Expected visually: **hello theme** — dark warm-gray screen instead of black, dim
gray-white idle face, brighter off-whites while thinking/speaking, no RGB
fringes on white. No shadow yet (Task 5). Then:

```bash
./build/Build/Products/Debug/Ziel\ van\ Sebastian.app/Contents/MacOS/Ziel\ van\ Sebastian --window --demo --theme classic
```

Expected visually: pixel-identical to the pre-branch app (green idle, amber
thinking, black background, RGB grille).

- [ ] **Step 5: Commit**

```bash
git add Sources/Rendering/ZielRenderer.swift App/AppDelegate.swift
git commit -m "feat: renderer takes ResolvedLook; themed background clear color"
```

---

### Task 5: Hard drop shadow — double-draw in ScenePass

**Files:**
- Modify: `Sources/Rendering/ScenePass.swift` (init 13–31, drawFace 51–107, drawGlyphQuad 126–144)
- Modify: `Sources/Rendering/ZielRenderer.swift` (init from Task 4; `drawText` lines ~65–80)

- [ ] **Step 1: Store the shadow spec on `ScenePass`**

Change the init signature (line 13) to accept it, and add the property next to
the pipelines:

```swift
    private let shadow: ShadowSpec?

    init(device: MTLDevice, library: MTLLibrary, pixelFormat: MTLPixelFormat,
         shadow: ShadowSpec?) throws {
        self.device = device
        self.shadow = shadow
        // ... rest of the existing init body unchanged ...
```

- [ ] **Step 2: Add the shared offset helper (private, below `FaceTransform`)**

```swift
    /// Shadow offset in NDC for the current view size, plus the shadow color.
    /// Offsets are face-grid pixels; NDC spans 2.0 across the view; screen y
    /// grows down while NDC y grows up — hence the negated dy.
    private func shadowDeltaNDC(viewW: Double, viewH: Double) -> (dx: Float, dy: Float, color: ColorRGB)? {
        guard let s = shadow else { return nil }
        let gp = FaceTransform(viewW: viewW, viewH: viewH).gridPixel
        return (dx: Float(s.offsetX * gp / viewW * 2),
                dy: Float(-(s.offsetY * gp / viewH * 2)),
                color: s.color)
    }
```

- [ ] **Step 3: Double-draw in `drawFace`**

The method body currently ends with (after the `for rect in FaceGeometry.all` loop):

```swift
        var color: [Float] = [Float(tint.r), Float(tint.g), Float(tint.b), Float(alpha)]
        encoder.setRenderPipelineState(flatPipeline)
        encoder.setVertexBytes(verts, length: verts.count * MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentBytes(&color, length: 16, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count / 2)
```

Replace that ending with:

```swift
        encoder.setRenderPipelineState(flatPipeline)
        if let d = shadowDeltaNDC(viewW: viewW, viewH: viewH) {
            var shadowVerts = verts
            for i in stride(from: 0, to: shadowVerts.count, by: 2) {
                shadowVerts[i] += d.dx
                shadowVerts[i + 1] += d.dy
            }
            var shadowColor: [Float] = [Float(d.color.r), Float(d.color.g), Float(d.color.b), Float(alpha)]
            encoder.setVertexBytes(shadowVerts, length: shadowVerts.count * MemoryLayout<Float>.size, index: 0)
            encoder.setFragmentBytes(&shadowColor, length: 16, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: shadowVerts.count / 2)
        }
        var color: [Float] = [Float(tint.r), Float(tint.g), Float(tint.b), Float(alpha)]
        encoder.setVertexBytes(verts, length: verts.count * MemoryLayout<Float>.size, index: 0)
        encoder.setFragmentBytes(&color, length: 16, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count / 2)
```

Everything above the ending (vertex building, blink/breathe/wander math) is
untouched. `drawSweep` is untouched — the sweep is a light effect and casts no
shadow (spec).

- [ ] **Step 4: Double-draw in `drawGlyphQuad`**

Replace the whole method (lines 126–144) with a thin wrapper plus a private
emitter (the emitter body is the old method body with `rgba` instead of
tint/alpha):

```swift
    func drawGlyphQuad(encoder: MTLRenderCommandEncoder, texture: MTLTexture,
                       center: (x: Float, y: Float), half: (w: Float, h: Float),
                       tint: ColorRGB, alpha: Double,
                       viewW: Double, viewH: Double) {
        if let d = shadowDeltaNDC(viewW: viewW, viewH: viewH) {
            emitGlyphQuad(encoder: encoder, texture: texture,
                          center: (x: center.x + d.dx, y: center.y + d.dy), half: half,
                          rgba: [Float(d.color.r), Float(d.color.g), Float(d.color.b), Float(alpha)])
        }
        emitGlyphQuad(encoder: encoder, texture: texture, center: center, half: half,
                      rgba: [Float(tint.r), Float(tint.g), Float(tint.b), Float(alpha)])
    }

    private func emitGlyphQuad(encoder: MTLRenderCommandEncoder, texture: MTLTexture,
                               center: (x: Float, y: Float), half: (w: Float, h: Float),
                               rgba: [Float]) {
        // Texture v=0 is the TOP of the glyph (Metal texture origin top-left), while NDC y grows upward — hence v flipped relative to y.
        let v: [TexQuadVertex] = [
            .init(x: center.x - half.w, y: center.y - half.h, u: 0, v: 1),
            .init(x: center.x + half.w, y: center.y - half.h, u: 1, v: 1),
            .init(x: center.x - half.w, y: center.y + half.h, u: 0, v: 0),
            .init(x: center.x + half.w, y: center.y - half.h, u: 1, v: 1),
            .init(x: center.x + half.w, y: center.y + half.h, u: 1, v: 0),
            .init(x: center.x - half.w, y: center.y + half.h, u: 0, v: 0),
        ]
        var color = rgba
        encoder.setRenderPipelineState(texPipeline)
        encoder.setVertexBytes(v, length: v.count * MemoryLayout<TexQuadVertex>.stride, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.setFragmentBytes(&color, length: 16, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }
```

- [ ] **Step 5: Thread the wiring through `ZielRenderer`**

In the init (from Task 4), pass the shadow to ScenePass:

```swift
        self.scenePass = try ScenePass(device: device, library: library,
                                       pixelFormat: pixelFormat, shadow: look.shadow)
```

In `drawText`, the `drawGlyphQuad` call gains the view size:

```swift
        scenePass.drawGlyphQuad(encoder: encoder, texture: tex,
                                center: (x: cx, y: cy), half: (w: halfW, h: halfH),
                                tint: tint, alpha: alpha,
                                viewW: viewW, viewH: viewH)
```

- [ ] **Step 6: Build, test, and look at it**

```bash
make test 2>&1 | tail -5     # expected: PASS
make run
```

Expected visually in the demo: face, RSVP words, and hint text all cast a crisp
dark offset shadow toward lower-right (≈0.6/0.75 of one face-pixel); shadow
edges are hard, not blurred; the thinking sweep band has no shadow. Then verify
`classic` shows **no** shadow:

```bash
./build/Build/Products/Debug/Ziel\ van\ Sebastian.app/Contents/MacOS/Ziel\ van\ Sebastian --window --demo --theme classic
```

- [ ] **Step 7: Commit**

```bash
git add Sources/Rendering/ScenePass.swift Sources/Rendering/ZielRenderer.swift
git commit -m "feat: hard offset drop shadow — scene-pass double-draw, theme-conditional"
```

---

### Task 6: Example config + `--state idle` capture support

**Files:**
- Modify: `config.example.json` (`look` block)
- Modify: `App/AppDelegate.swift` (`applyDebugState`, lines ~114–128)

- [ ] **Step 1: Slim the example `look` block**

In `config.example.json`, replace the entire `"look": { ... }` object with:

```json
  "look": {
    "theme": "hello"
  },
```

(Per spec: the example must stop duplicating theme values — they'd silently pin
them as overrides. JSON allows no comments; override usage is documented in the
README in Task 7.)

- [ ] **Step 2: Add an explicit idle debug state**

In `applyDebugState`, add a case before `default:`:

```swift
        case "idle":
            break  // connectionUp (sent by the caller) already lands on idle
```

This makes `--state idle` stop printing the unknown-state warning — needed for
clean screenshot capture in Task 7.

- [ ] **Step 3: Verify**

```bash
make build 2>&1 | tail -3
python3 -c "import json; json.load(open('config.example.json'))" && echo "example json OK"
./build/Build/Products/Debug/Ziel\ van\ Sebastian.app/Contents/MacOS/Ziel\ van\ Sebastian --window --state idle
```

Expected: no `warning: unknown --state` on stderr; window shows the idle
hello-theme face (dim warm-gray on dark gray, with shadow).

- [ ] **Step 4: Commit**

```bash
git add config.example.json App/AppDelegate.swift
git commit -m "feat: example config selects theme; --state idle for captures"
```

---

### Task 7: README Themes section + refreshed screenshots

**Files:**
- Modify: `README.md`
- Replace: `docs/screenshots/idle.png`, `thinking.png`, `speaking.png`, `demo-crt.png`, `demo.gif`
- Create: `docs/screenshots/classic.png`

> **Human-in-the-loop:** screenshot/GIF capture is interactive (same manual flow
> as v1). The executor prepares the README text and the capture commands; the
> captures themselves need a human at the machine. Do NOT fake or placeholder
> the image files.

- [ ] **Step 1: Add the Themes section to `README.md`**

Insert after the existing screenshots table (after line 20), adapting heading
level to the surrounding document:

```markdown
## Themes

The look is a named theme, selected at launch. Built-ins:

| Theme | Style |
|---|---|
| `hello` (default) | Original-Macintosh "hello." — off-white on dark warm gray, hard offset drop shadow, monochrome CRT (no RGB triads). States read through brightness: dim idle, mid thinking, bright speaking. |
| `classic` | The original Ziel look — green idle / amber thinking / white speaking phosphor on black, RGB aperture grille. |

![Classic theme — green happy-Mac face](docs/screenshots/classic.png)

Select a theme in `config.json`:

​```json
"look": { "theme": "classic" }
​```

or at launch (overrides config): `--theme classic`.

Any other `look` key you set acts as an override on top of the active theme —
e.g. `"idleTint": "#ff00ff"` or `"shader": { "bloomStrength": 0.8 }` win over
the theme's values. Unknown theme names fail at startup listing the valid ones.
Switching themes requires a relaunch; the config watcher hot-reloads shader
parameters only.
```

(Remove the zero-width characters around the inner code fences when writing —
they're only here to keep this plan's markdown intact.)

Also update the captions/alt text of the existing four screenshots to mention
the hello theme (e.g. "Idle — dim off-white happy-Mac face (hello theme)").

- [ ] **Step 2: Recapture the five hello-theme assets (HUMAN)**

For each PNG, launch the state windowed, then capture interactively
(`screencapture -iW` — click the Ziel window):

```bash
make build
APP="./build/Build/Products/Debug/Ziel van Sebastian.app/Contents/MacOS/Ziel van Sebastian"
"$APP" --window --state idle &      sleep 2; screencapture -iW docs/screenshots/idle.png;      kill %1
"$APP" --window --state thinking &  sleep 2; screencapture -iW docs/screenshots/thinking.png;  kill %1
"$APP" --window --state speaking &  sleep 2; screencapture -iW docs/screenshots/speaking.png;  kill %1
"$APP" --window --demo &            sleep 8; screencapture -iW docs/screenshots/demo-crt.png;  kill %1
"$APP" --window --state idle --theme classic & sleep 2; screencapture -iW docs/screenshots/classic.png; kill %1
```

`demo.gif`: record the demo loop (`"$APP" --window --demo`) with QuickTime
screen recording (or the same tool used for v1) and convert to GIF, replacing
`docs/screenshots/demo.gif`.

- [ ] **Step 3: Verify the README renders and images exist**

```bash
ls -la docs/screenshots/   # six files, all freshly dated
grep -n "theme" README.md | head
```

- [ ] **Step 4: Commit**

```bash
git add README.md docs/screenshots/
git commit -m "docs: README themes section; hello-theme screenshots + classic preview"
```

---

## Post-implementation notes (not tasks)

- **User's real `config.json`** (Application Support, not in git): its `look`
  block still carries the old green/amber tints — after this lands they act as
  overrides and would pin the old colors on top of `hello`. Delete those keys
  (or the whole `look` block), or set `"theme": "classic"` deliberately.
- The appliance launch path needs no change: default theme is `hello`.
