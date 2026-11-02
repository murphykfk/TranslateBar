import XCTest
@testable import TranslateCore

final class PowerPointClipboardTests: XCTestCase {
    func testPowerPointPlainPastePreservesRepeatedSpacesWithoutAddingParagraphs() {
        let input = "    当前  段落    "
        let payload = MicrosoftTextRules.powerPointPasteText(input)
        XCTAssertEqual(payload.replacingOccurrences(of: "\u{a0}", with: " "), input)
        XCTAssertFalse(payload.contains("\n"))
        XCTAssertFalse(payload.hasSuffix(" "))
        XCTAssertEqual(MicrosoftTextRules.powerPointPasteText("正文\u{a0}\u{a0}\u{a0} "), "正文\u{a0}\u{a0}\u{a0}\u{a0}")
        XCTAssertEqual(MicrosoftTextRules.powerPointPasteText("A normal sentence."), "A normal sentence.")
    }
    func testParagraphShortcutDoesNotConsumeAFollowingParagraphMark() {
        let value = "上一段\r当前段落    \r下一段"
        let caret = NSRange(location: 12, length: 0)
        XCTAssertEqual(MicrosoftTextRules.powerPointPrefixRange(value: value, caret: caret,
            selection: NSRange(location: 4, length: 9), copied: "当前段落    \r"), NSRange(location: 4, length: 8))
        XCTAssertNil(MicrosoftTextRules.powerPointPrefixRange(value: value, caret: caret,
            selection: NSRange(location: 4, length: 9), copied: "其他段落    \r"))
    }
    func testVirtualEndMarkerAndExportedBreakAreNotUserText() {
        let value = "上一段\r当前段落    "
        XCTAssertEqual(MicrosoftTextRules.powerPointCopiedText(value: value, range: NSRange(location: 4, length: value.utf16.count - 3), copied: "当前段落    \r\n"), "当前段落    ")
        XCTAssertEqual(MicrosoftTextRules.powerPointCopiedText(value: value, range: NSRange(location: value.utf16.count - 1, length: 1), copied: " \r\n"), " ")
    }
    func testRealBreaksAndFollowingParagraphArePreserved() {
        let value = "上一段\r当前段落    \r后一段"
        XCTAssertEqual(MicrosoftTextRules.powerPointCopiedText(value: value, range: NSRange(location: 4, length: 8), copied: "当前段落    \r\n"), "当前段落    ")
        XCTAssertEqual(MicrosoftTextRules.powerPointCopiedText(value: value, range: NSRange(location: 4, length: 9), copied: "当前段落    \r\n"), "当前段落    \r")
    }
    func testMismatchedStaleAndInvalidRangesAreRejected() {
        let value = "👨‍👩‍👧‍👦正文    "
        XCTAssertNil(MicrosoftTextRules.powerPointCopiedText(value: value, range: NSRange(location: 0, length: value.utf16.count), copied: "不同正文\n"))
        for range in [NSRange(location: -1, length: 1), NSRange(location: 0, length: 0), NSRange(location: 0, length: value.utf16.count + 2), NSRange(location: 1, length: 1), NSRange(location: NSNotFound, length: 1)] {
            XCTAssertNil(MicrosoftTextRules.powerPointCopiedText(value: value, range: range, copied: value))
        }
    }
}
