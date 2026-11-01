import XCTest
@testable import TranslateCore

final class MicrosoftTextRulesTests: XCTestCase {
    func testPowerPointTextAndCanvasRouteThroughTheSameParagraphAdapter() {
        for role in ["AXLayoutArea", "AXTextArea"] {
            XCTAssertTrue(MicrosoftTextRules.usesDocumentFallback(bundleID: "com.microsoft.Powerpoint", role: role))
            XCTAssertTrue(MicrosoftTextRules.permitsBody(bundleID: "com.microsoft.Powerpoint", role: role, secure: false, modal: false))
        }
    }
    func testSlideThumbnailsShapesToolbarsAndOtherAppsDoNotBecomeEditableText() {
        for role in ["AXImage", "AXGroup", "AXCollection", "AXList", "AXWindow", "AXButton", "AXTextField", "AXToolbar", "AXUnknown"] {
            XCTAssertFalse(MicrosoftTextRules.usesDocumentFallback(bundleID: "com.microsoft.Powerpoint", role: role))
        }
        for bundle in ["com.microsoft.Excel", "com.apple.Keynote", "com.kingsoft.wpsoffice.mac", "com.microsoft.PowerPoint", ""] {
            XCTAssertNil(MicrosoftTextRules.document(bundleID: bundle))
            XCTAssertFalse(MicrosoftTextRules.usesDocumentFallback(bundleID: bundle, role: "AXLayoutArea"))
        }
    }
    func testModalAndProtectedPowerPointTextRemainBlocked() {
        XCTAssertFalse(MicrosoftTextRules.permitsBody(bundleID: "com.microsoft.Powerpoint", role: "AXTextArea", secure: true, modal: false))
        XCTAssertFalse(MicrosoftTextRules.permitsBody(bundleID: "com.microsoft.Powerpoint", role: "AXTextArea", secure: false, modal: true))
    }
    func testSelectedObjectsAndUnknownCommandStatesAreRejectedBeforeArrows() {
        for copy: Bool? in [true, false, nil] {
            for cut: Bool? in [true, false, nil] {
                let allowed = MicrosoftTextRules.permitsInitialSelection(in: .powerPoint, copyEnabled: copy, cutEnabled: cut)
                if copy == false && cut == false { XCTAssertTrue(allowed) }
                else { XCTAssertFalse(allowed) }
            }
        }
    }
    func testWordKeepsItsExistingCommandChecksAndParagraphShortcut() {
        XCTAssertEqual(MicrosoftTextRules.document(bundleID: WordTextRules.bundleID), .word)
        XCTAssertEqual(MicrosoftTextRules.paragraphModifier(for: .word), .command)
        for copy: Bool? in [true, false, nil] {
            XCTAssertTrue(MicrosoftTextRules.permitsInitialSelection(in: .word, copyEnabled: copy, cutEnabled: nil))
        }
        for role in ["AXTextArea", "AXLayoutArea", "AXGroup", "AXTextField"] {
            XCTAssertEqual(MicrosoftTextRules.permitsBody(bundleID: WordTextRules.bundleID, role: role, secure: false, modal: false),
                WordTextRules.permitsBody(bundleID: WordTextRules.bundleID, role: role, enabled: false, explicitlyEditable: nil, secure: false, modal: false))
        }
    }
    func testPowerPointDoesNotUseTheStartOfTextObjectShortcut() {
        XCTAssertEqual(MicrosoftTextRules.document(bundleID: "com.microsoft.Powerpoint"), .powerPoint)
        XCTAssertEqual(MicrosoftTextRules.paragraphModifier(for: .powerPoint), .option)
    }
    func testSharedScopePlanPreservesOtherParagraphsAndManualBreaks() throws {
        for separator in ["\r", "\n", "\r\n", "\u{b}", "\u{2028}", "\u{2029}"] {
            let original = "Previous bullet" + separator + "当前文本框段落   "
            let plan = try WordTextRules.prefixSelection(in: original)
            XCTAssertEqual((original as NSString).substring(with: plan.range), "当前文本框段落   ")
        }
        for original in ["单元格\t内容   ", "对象\u{fffc}内容   ", "前文\n   "] {
            XCTAssertThrowsError(try WordTextRules.prefixSelection(in: original))
        }
    }
}
