import XCTest
@testable import TranslateCore

final class TriggerCaretSynchronizationTests: XCTestCase {
    private func permits(_ before: String, _ after: String, old: Int? = nil, now: NSRange? = nil, count: Int = 3, unchanged: Bool = true, range: NSRange? = nil) -> Bool {
        TriggerCaretSynchronization.permits(original: before, current: after, captured: NSRange(location: old ?? before.utf16.count, length: 0), actual: now ?? NSRange(location: after.utf16.count, length: 0), replacementRange: range ?? NSRange(location: 0, length: before.utf16.count), triggerSpaces: count, interactionUnchanged: unchanged)
    }
    func testPendingLastTriggerSpaceCanSettleWithoutDiscardingCachedTranslation() {
        XCTAssertTrue(permits("母猪  ", "母猪   "))
        XCTAssertTrue(permits("\n\n母猪", "\n\n母猪   "))
        XCTAssertTrue(permits("🐘 母猪  ", "🐘 母猪   "))
    }
    func testCaretAttributeCanLagBehindAlreadySettledText() {
        XCTAssertTrue(permits("母猪   ", "母猪   ", old: 4))
        XCTAssertTrue(permits("母猪   ", "母猪   ", old: 2))
        XCTAssertTrue(permits("母猪 \u{00a0}", "母猪 \u{00a0} ", old: 3))
    }
    func testEveryConfiguredTriggerCountBoundsTheAdvance() {
        for count in 2...4 {
            XCTAssertTrue(permits("母猪", "母猪" + String(repeating: " ", count: count), count: count))
            XCTAssertFalse(permits("母猪", "母猪" + String(repeating: " ", count: count + 1), count: count))
        }
    }
    func testRealNewInputOrPointerActionAlwaysRejectsEvenWhitespaceOnly() {
        XCTAssertFalse(permits("母猪  ", "母猪   ", unchanged: false))
        XCTAssertFalse(permits("母猪   ", "母猪   ", old: 2, unchanged: false))
    }
    func testEditingWordsPunctuationNewlinesAndIndentationNeverQualifies() {
        for after in ["母猪a   ", "母猪。   ", "母猪\n   ", " 母猪   ", "公猪   ", "母猪\t  ", "母猪　 "] {
            XCTAssertFalse(permits("母猪  ", after))
        }
        XCTAssertFalse(permits("母猪   ", "母猪   ", old: 1))
    }
    func testSelectionParagraphTranslationAndNonTerminalCaretStayProtected() {
        XCTAssertFalse(permits("母猪  ", "母猪   ", now: NSRange(location: 2, length: 3)))
        XCTAssertFalse(permits("母猪  ", "母猪   ", now: NSRange(location: 3, length: 0)))
        XCTAssertFalse(permits("母猪  ", "母猪   ", range: NSRange(location: 0, length: 2)))
        XCTAssertFalse(permits("母猪   ", "母猪   ", old: 5))
        XCTAssertFalse(permits("母猪   ", "母猪  "))
    }
}
