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
