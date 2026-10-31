import XCTest
@testable import TranslateCore

final class WordTextRulesTests: XCTestCase {
    func testWordDocumentKeepsTheSameScopeAfterAXReflow() {
        XCTAssertTrue(WordTextRules.usesDocumentFallback(bundleID: "com.microsoft.Word", role: "AXLayoutArea"))
        XCTAssertTrue(WordTextRules.usesDocumentFallback(bundleID: "com.microsoft.Word", role: "AXTextArea"))
        XCTAssertFalse(WordTextRules.usesDocumentFallback(bundleID: "com.microsoft.Word", role: "AXTextField"))
        XCTAssertFalse(WordTextRules.usesDocumentFallback(bundleID: "com.apple.TextEdit", role: "AXTextArea"))
    }
    func testWordCanvasRequiresEnabledPasteWithoutWritableAXText() {
        for role in ["AXLayoutArea", "AXTextArea"] {
            XCTAssertTrue(WordTextRules.permitsInput(bundleID: "com.microsoft.Word", role: role, enabled: true, explicitlyEditable: nil, pasteEnabled: true, secure: false, modal: false))
        }
        for role in ["AXWindow", "AXGroup", "AXButton", "AXComboBox", "AXTextField", "AXToolbar", "AXStaticText"] {
            XCTAssertFalse(WordTextRules.permitsInput(bundleID: "com.microsoft.Word", role: role, enabled: true, explicitlyEditable: true, pasteEnabled: true, secure: false, modal: false))
        }
        XCTAssertFalse(WordTextRules.permitsInput(bundleID: "com.microsoft.Excel", role: "AXLayoutArea", enabled: true, explicitlyEditable: true, pasteEnabled: true, secure: false, modal: false))
    }
    func testReadonlyDisabledUnknownProtectedAndModalContextsStayBlocked() {
        for enabled: Bool? in [false, nil] {
            XCTAssertFalse(WordTextRules.permitsInput(bundleID: "com.microsoft.Word", role: "AXLayoutArea", enabled: enabled, explicitlyEditable: nil, pasteEnabled: true, secure: false, modal: false))
        }
        for paste: Bool? in [false, nil] {
            XCTAssertFalse(WordTextRules.permitsInput(bundleID: "com.microsoft.Word", role: "AXLayoutArea", enabled: true, explicitlyEditable: nil, pasteEnabled: paste, secure: false, modal: false))
        }
        XCTAssertFalse(WordTextRules.permitsInput(bundleID: "com.microsoft.Word", role: "AXLayoutArea", enabled: true, explicitlyEditable: false, pasteEnabled: true, secure: false, modal: false))
        XCTAssertFalse(WordTextRules.permitsInput(bundleID: "com.microsoft.Word", role: "AXLayoutArea", enabled: true, explicitlyEditable: nil, pasteEnabled: true, secure: true, modal: false))
        XCTAssertFalse(WordTextRules.permitsInput(bundleID: "com.microsoft.Word", role: "AXLayoutArea", enabled: true, explicitlyEditable: nil, pasteEnabled: true, secure: false, modal: true))
    }
    func testSingleParagraphIncludingWrappedTextNeedsNoCharacterStepping() throws {
        let text = String(repeating: "正文", count: 600) + "   "
        let selection = try WordTextRules.prefixSelection(in: text)
        XCTAssertEqual(selection.range, NSRange(location: 0, length: text.utf16.count))
        XCTAssertEqual(selection.adjustment, .none)
    }
    func testManualLineBreakCaseKeepsOnlyTheCurrentInput() throws {
        let text = "\u{b}上一行应保持不变\u{b}明天上午十点开会   "
        let selection = try WordTextRules.prefixSelection(in: text)
        XCTAssertEqual((text as NSString).substring(with: selection.range), "明天上午十点开会   ")
        let first = try WordTextRules.prefixSelection(in: "\u{b}明天上午十点开会   ")
        XCTAssertEqual(first.range.location, 1)
        XCTAssertEqual(first.adjustment, .moveStartRight(1))
    }
    func testEveryHardAndSoftBreakSeparatesPreviousContent() throws {
        for newline in ["\n", "\r", "\r\n", "\u{b}", "\u{c}", "\u{85}", "\u{2028}", "\u{2029}"] {
            let text = "上一段不修改" + newline + "当前段落    "
            let selection = try WordTextRules.prefixSelection(in: text)
            XCTAssertEqual((text as NSString).substring(with: selection.range), "当前段落    ")
            XCTAssertFalse(TextCompatibilityRules.isSingleTextLine(text))
        }
    }
    func testUnicodeRangesAndBoundedSelectionPlans() throws {
        let text = "👨‍👩‍👧‍👦e\u{301}\u{b}当前段落   "
        let selected = try WordTextRules.prefixSelection(in: text)
        XCTAssertEqual((text as NSString).substring(with: selected.range), "当前段落   ")
        XCTAssertEqual(selected.adjustment, .moveStartRight(3))
        let short = "短句   "
        let fromCaret = try WordTextRules.prefixSelection(in: String(repeating: "旧", count: 400) + "\u{b}" + short)
        XCTAssertEqual(fromCaret.adjustment, .selectFromCaretLeft(short.count))
        XCTAssertThrowsError(try WordTextRules.prefixSelection(in: String(repeating: "旧", count: 300) + "\u{b}" + String(repeating: "新", count: 300)))
    }
    func testEmptyTrailingParagraphTablesAndOversizeSelectionsAreRejected() {
        for text in ["", "   ", "上一段\u{b}   ", "表格\t单元格   ", "单元格\u{7}内容   ", "字段\u{13}内容   ", "嵌入\u{fffc}对象   ", String(repeating: "大", count: 21_000)] {
            XCTAssertThrowsError(try WordTextRules.prefixSelection(in: text))
        }
    }
}
