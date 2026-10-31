import XCTest
@testable import TranslateCore

final class TextReplacementTests: XCTestCase {
    func testGoogleWholeFieldReplacementRemovesTriggerSpaces() throws {
        let input = "大象    "
        let plan = try TextReplacementPlan(original: input, range: NSRange(location: 0, length: (input as NSString).length), current: input, replacement: "elephant", allowTrailingSpaces: true)
        XCTAssertEqual(plan.updated, "elephant")
    }
    func testBrowserNormalizingTrailingTriggerSpacesDoesNotCancel() throws {
        let plan = try TextReplacementPlan(original: "大象   ", range: NSRange(location: 0, length: 5), current: "大象    ", replacement: "elephant", allowTrailingSpaces: true)
        XCTAssertEqual(plan.updated, "elephant")
        XCTAssertEqual(plan.originalText, "大象    ")
    }
    func testNewWordsPunctuationAndNewlinesAreProtected() {
        for current in ["大象的鼻子    ", "大象。", "大象\n", " 大象    "] {
            XCTAssertThrowsError(try TextReplacementPlan(original: "大象    ", range: NSRange(location: 0, length: 6), current: current, replacement: "elephant", allowTrailingSpaces: true))
        }
    }
    func testSelectionDoesNotIgnoreWhitespaceEdits() {
        XCTAssertThrowsError(try TextReplacementPlan(original: "大象", range: NSRange(location: 0, length: 2), current: "大象 ", replacement: "elephant"))
    }
    func testParagraphDoesNotTolerateChangesElsewhere() {
        XCTAssertThrowsError(try TextReplacementPlan(original: "大象\n猫", range: NSRange(location: 0, length: 2), current: "大象\n猫 ", replacement: "elephant", allowTrailingSpaces: true))
    }
    func testUTF16SelectionPreservesSurroundingText() throws {
        let plan = try TextReplacementPlan(original: "🐘 大象\n猫", range: NSRange(location: 3, length: 2), current: "🐘 大象\n猫", replacement: "elephant")
        XCTAssertEqual(plan.updated, "🐘 elephant\n猫")
        XCTAssertEqual(plan.originalText, "大象")
    }
    func testInvalidAndOverflowingRangesFailClosed() {
        for range in [NSRange(location: 4, length: 1), NSRange(location: 1, length: Int.max), NSRange(location: NSNotFound, length: 1)] {
            XCTAssertThrowsError(try TextReplacementPlan(original: "大象", range: range, current: "大象", replacement: "elephant"))
        }
    }
}
