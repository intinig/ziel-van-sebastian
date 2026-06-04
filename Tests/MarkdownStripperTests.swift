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
