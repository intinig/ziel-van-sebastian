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
