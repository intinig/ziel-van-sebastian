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
}
