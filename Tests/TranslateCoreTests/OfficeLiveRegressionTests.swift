import XCTest
@testable import TranslateCore

final class OfficeLiveRegressionTests: XCTestCase {
    func testWordSelectedParagraphMarkIsExcludedOnlyWhenProven() {
        for newline in ["\n", "\r", "\r\n"] {
            let text = "上一段" + newline + "当前段落    " + newline + "下一段"
            let start = 3 + newline.utf16.count
            XCTAssertEqual(MicrosoftTextRules.wordSelectionWithoutParagraphMark(value: text,
                range: NSRange(location: start, length: 8 + newline.utf16.count), copied: "当前段落    "), NSRange(location: start, length: 8))
            XCTAssertNil(MicrosoftTextRules.wordSelectionWithoutParagraphMark(value: text,
                range: NSRange(location: start, length: 8), copied: "当前段落    "))
            XCTAssertNil(MicrosoftTextRules.wordSelectionWithoutParagraphMark(value: text,
                range: NSRange(location: start, length: 8 + newline.utf16.count), copied: "不同段落    "))
        }
    }
    func testExcelUsesOnlyTextEditorFallbackAndRejectsFormulaPrefixes() {
        XCTAssertEqual(MicrosoftTextRules.document(bundleID: "com.microsoft.Excel"), .excel)
        XCTAssertTrue(MicrosoftTextRules.usesDocumentFallback(bundleID: "com.microsoft.Excel", role: "AXTextArea"))
        for role in ["AXLayoutArea", "AXCell", "AXTable", "AXTextField", "AXComboBox"] {
            XCTAssertFalse(MicrosoftTextRules.usesDocumentFallback(bundleID: "com.microsoft.Excel", role: role))
        }
        for formula in ["=1+2", "  =SUM(A1:A3)", "+A1", "-1", "@SUM(A1:A3)", "   "] {
            XCTAssertFalse(MicrosoftTextRules.permitsExcelText(formula))
        }
        XCTAssertTrue(MicrosoftTextRules.permitsExcelText("明天上午十点开会    "))
    }
}
