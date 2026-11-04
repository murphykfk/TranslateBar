import XCTest
@testable import TranslateCore

final class ParagraphDraftTests: XCTestCase {
    func testDropsTriggerSpacesAndKeepsSurroundingWhitespace() throws {
        let draft = try ParagraphDraft(copied: "  你好世界 " + "    ", triggerSpaces: 4)
        XCTAssertEqual(draft.source, "你好世界")
        XCTAssertEqual(draft.leading, "  ")
        XCTAssertEqual(draft.trailing, " ")
        XCTAssertEqual(draft.replacement("Hello world"), "  Hello world ")
    }

    func testAcceptsOneTriggerSpaceConsumedByInputMethod() throws {
        XCTAssertEqual(try ParagraphDraft(copied: "你好   ", triggerSpaces: 4).replacement("Hello"), "Hello")
        XCTAssertThrowsError(try ParagraphDraft(copied: "你好  ", triggerSpaces: 4)) { XCTAssertEqual($0 as? ParagraphDraftError, .triggerMissing) }
        XCTAssertThrowsError(try ParagraphDraft(copied: "你好", triggerSpaces: 2)) { XCTAssertEqual($0 as? ParagraphDraftError, .triggerMissing) }
    }

    func testWebEditorsMayWriteTriggerAsNoBreakSpaces() throws {
        XCTAssertEqual(try ParagraphDraft(copied: "你好\u{a0} \u{a0} ", triggerSpaces: 4).source, "你好")
    }

    func testTrailingParagraphMarkFromCopyIsNotPartOfTheSelection() throws {
        XCTAssertEqual(try ParagraphDraft(copied: "你好    \n", triggerSpaces: 4).replacement("Hello"), "Hello")
        XCTAssertEqual(try ParagraphDraft(copied: "你好    \r\n", triggerSpaces: 4).replacement("Hello"), "Hello")
    }

    func testRejectsSelectionsThatCrossLines() {
        for text in ["上一段\n你好    ", "第一行\u{2028}你好    ", "第一行\u{0b}你好    ", "上一段\r你好    "] {
            XCTAssertThrowsError(try ParagraphDraft(copied: text, triggerSpaces: 4)) { XCTAssertEqual($0 as? ParagraphDraftError, .multipleParagraphs, text) }
        }
    }

    func testRejectsEmbeddedObjectsAndEmptyParagraphs() {
        XCTAssertThrowsError(try ParagraphDraft(copied: "图\u{fffc}你好    ", triggerSpaces: 4)) { XCTAssertEqual($0 as? ParagraphDraftError, .embeddedObject) }
        XCTAssertThrowsError(try ParagraphDraft(copied: "  " + "    ", triggerSpaces: 4)) { XCTAssertEqual($0 as? ParagraphDraftError, .empty) }
    }

    func testTranslationLineBreaksDoNotSplitTheParagraph() throws {
        let draft = try ParagraphDraft(copied: "你好。再见。    ", triggerSpaces: 4)
        XCTAssertEqual(draft.replacement(" Hello.\n\nGoodbye. \n"), "Hello. Goodbye.")
    }

    func testPrefixRangeStartsAfterTheLastLineBreakBeforeTheCaret() {
        let text = "第一段\r\n🙂你好    \n后文"
        let caret = ("第一段\r\n🙂你好    " as NSString).length
        let range = ParagraphDraft.prefixRange(in: text, caret: caret)
        XCTAssertEqual((text as NSString).substring(with: range), "🙂你好    ")
        XCTAssertEqual(ParagraphDraft.prefixRange(in: "a\u{2028}b", caret: 99), NSRange(location: 2, length: 1))
        XCTAssertEqual(ParagraphDraft.prefixRange(in: "a\n", caret: 2).length, 0)
    }

    func testSameTextIgnoresExportDifferences() {
        XCTAssertTrue(ParagraphDraft.sameText("Hello\u{a0} ", "Hello  \n"))
        XCTAssertTrue(ParagraphDraft.sameText("你好\r\n", "你好"))
        XCTAssertFalse(ParagraphDraft.sameText("Hello", "Hello "))
        XCTAssertFalse(ParagraphDraft.sameText("你好\n\n", "你好"))
    }

    func testSelectionKeyDefaultsToLineStartAndListsDocumentEditors() {
        XCTAssertEqual(ParagraphSelectionKey.forApplication("com.tencent.xinWeChat"), .commandShiftLeft)
        XCTAssertEqual(ParagraphSelectionKey.forApplication("com.microsoft.VSCode"), .commandShiftLeft)
        XCTAssertEqual(ParagraphSelectionKey.forApplication(""), .commandShiftLeft)
        XCTAssertEqual(ParagraphSelectionKey.forApplication("com.microsoft.Word"), .commandShiftUp)
        XCTAssertEqual(ParagraphSelectionKey.forApplication("com.kingsoft.wpsoffice.mac"), .commandShiftUp)
        XCTAssertEqual(ParagraphSelectionKey.forApplication("com.microsoft.Powerpoint"), .optionShiftUp)
        XCTAssertEqual(ParagraphSelectionKey.forApplication("com.microsoft.Excel"), .shiftHome)
    }

    func testOnlyControlsWithoutCaretAreRejected() {
        for role in ["AXTextArea", "AXTextField", "AXLayoutArea", "AXGroup", "AXWebArea", "AXUnknown", ""] { XCTAssertTrue(ParagraphDraft.permitsFocusRole(role), role) }
        for role in ["AXButton", "AXList", "AXTable", "AXMenuItem", "AXImage"] { XCTAssertFalse(ParagraphDraft.permitsFocusRole(role), role) }
    }
}
