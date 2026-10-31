import XCTest
@testable import TranslateCore

final class TextCompatibilityTests: XCTestCase {
    func testLineFallbackNeverSelectsDocumentsOrNoneditableControls() {
        for role in ["AXWebArea", "AXWindow", "AXGroup", "AXButton", "AXStaticText", "AXSplitGroup"] {
            XCTAssertFalse(TextCompatibilityRules.permitsLineFallback(role: role, editable: true, enabled: true, secure: false))
        }
        for role in ["AXTextArea", "AXTextField", "AXComboBox", "AXSearchField"] {
            XCTAssertTrue(TextCompatibilityRules.permitsLineFallback(role: role, editable: nil, enabled: true, secure: false))
            XCTAssertFalse(TextCompatibilityRules.permitsLineFallback(role: role, editable: false, enabled: true, secure: false))
            XCTAssertFalse(TextCompatibilityRules.permitsLineFallback(role: role, editable: true, enabled: false, secure: false))
            XCTAssertFalse(TextCompatibilityRules.permitsLineFallback(role: role, editable: true, enabled: true, secure: true))
        }
    }
    func testLineReplacementKeepsIndentationAndOnlyRemovesGestureSpaces() throws {
        XCTAssertEqual(try TextCompatibilityRules.replacingLine("    明天开会。      ", with: "Meeting tomorrow.", triggerSpaces: 4), "    Meeting tomorrow.  ")
        XCTAssertEqual(try TextCompatibilityRules.replacingLine("文本 \u{00a0} \u{00a0}", with: "Text", triggerSpaces: 4), "Text")
        XCTAssertEqual(try TextCompatibilityRules.replacingLine("文本  ", with: "Text", triggerSpaces: 4), "Text  ")
    }
    func testLineFallbackRejectsStructuralCharactersAndEmptyText() {
        for text in ["a\nb", "a\rb", "a\r\nb", "a\u{b}b", "a\u{c}b", "a\u{85}b", "a\tb", "a\u{0}b", "a\u{7}b", "a\u{13}b", "a\u{7f}b", "a\u{fffc}b", "a\u{2028}b", "a\u{2029}b", ""] {
            XCTAssertFalse(TextCompatibilityRules.isSingleTextLine(text))
            XCTAssertThrowsError(try TextCompatibilityRules.replacingLine("source", with: text, triggerSpaces: 4))
        }
    }
    func testCompatibilitySettingMigratesAndPersistsIndependentSwitches() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(old.enhancedCompatibility)
        var settings = old; settings.enhancedCompatibility = false; settings.wpsCompatibilityEnabled = true
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(restored.enhancedCompatibility)
        XCTAssertTrue(restored.wpsCompatibilityEnabled)
    }
}
