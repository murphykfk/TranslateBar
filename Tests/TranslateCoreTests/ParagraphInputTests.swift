import XCTest
@testable import TranslateCore

final class ParagraphInputTests: XCTestCase {
    private func fragment(_ text: String, _ caret: Int) throws -> String { (text as NSString).substring(with: try ParagraphInput.range(in: text, caret: NSRange(location: caret, length: 0))) }
    func testOnlyTheNewParagraphIsRead() throws {
        let text = "Bear\n\n刘德华   "
        XCTAssertEqual(try fragment(text, text.utf16.count), "刘德华   ")
        let range = try ParagraphInput.range(in: text, caret: NSRange(location: text.utf16.count, length: 0))
        let plan = try TextReplacementPlan(original: text, range: range, current: text, replacement: "Andy Lau")
        XCTAssertEqual(plan.updated, "Bear\n\nAndy Lau")
    }
    func testReturnAtEndNeverFallsBackToPreviousParagraph() throws {
        XCTAssertEqual(try fragment("Bear\n", 5), "")
        XCTAssertEqual(try fragment("Bear\n   ", 8), "   ")
        XCTAssertEqual(try fragment("", 0), "")
    }
    func testMiddleParagraphAndUnicodeOffsetsKeepBothNeighbors() throws {
        let text = "Bear\n👋 刘德华   \nUnchanged"
        let caret = (text as NSString).range(of: "   ").location + 3
        let range = try ParagraphInput.range(in: text, caret: NSRange(location: caret, length: 0))
        XCTAssertEqual((text as NSString).substring(with: range), "👋 刘德华   \n")
        XCTAssertEqual(try TextReplacementPlan(original: text, range: range, current: text, replacement: "👋 Andy Lau\n").updated, "Bear\n👋 Andy Lau\nUnchanged")
    }
    func testCRLFAndVisualLengthDoNotExpandScope() throws {
        XCTAssertEqual(try fragment("Bear\r\n刘德华", 9), "刘德华")
        let long = "Bear\n" + String(repeating: "很长的同一个段落", count: 30)
        XCTAssertEqual(try fragment(long, long.utf16.count), String(repeating: "很长的同一个段落", count: 30))
    }
    func testLegacyWholeFieldPreferenceMigratesAndStaysParagraphAfterRestart() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"inputScope":"field","spaceCount":3}"#.utf8))
        XCTAssertEqual(settings.inputScope, .paragraph); XCTAssertEqual(settings.spaceCount, 3)
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).inputScope, .paragraph)
        XCTAssertEqual(AppSettings().inputScope, .paragraph)
    }
    func testDelayedTailSpaceNeverReplacesPreviousParagraph() throws {
        let original = "Bear\n\n刘德华  ", current = original + " "
        let range = try ParagraphInput.range(in: original, caret: NSRange(location: original.utf16.count, length: 0))
        XCTAssertTrue(TriggerCaretSynchronization.permits(original: original, current: current, captured: NSRange(location: original.utf16.count, length: 0), actual: NSRange(location: current.utf16.count, length: 0), replacementRange: range, triggerSpaces: 3, interactionUnchanged: true))
        let plan = try TextReplacementPlan(original: original, range: range, current: current, replacement: "Andy Lau", allowTrailingSpaces: true)
        XCTAssertEqual(plan.updated, "Bear\n\nAndy Lau")
        XCTAssertThrowsError(try TextReplacementPlan(original: original, range: range, current: "Changed\n\n刘德华   ", replacement: "Andy Lau", allowTrailingSpaces: true))
    }
}
