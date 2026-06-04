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
