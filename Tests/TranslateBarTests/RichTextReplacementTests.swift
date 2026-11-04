import AppKit
import XCTest
@testable import TranslateBar

final class RichTextReplacementTests: XCTestCase {
    @MainActor func testWebParagraphsKeepStructureWithoutImportingHTMLOrFonts() throws {
        let original = NSAttributedString(string: "Heading\n\n    正文    ")
        let formatted = try RichTextReplacement.translated("Heading\nBody", preserving: original, removingTriggerSpaces: true, requireFont: false)
        XCTAssertEqual(formatted.string, "Heading\n\n    Body")
        XCTAssertThrowsError(try RichTextReplacement.translated("Collapsed document", preserving: original, removingTriggerSpaces: true, requireFont: false))
    }
    func testTitleAndBodyKeepTheirOwnFontAfterTranslation() async throws {
        try await MainActor.run {
            let source = NSMutableAttributedString(string: "会议安排\n明天十点开会。    ", attributes: [.font: NSFont.systemFont(ofSize: 17)])
            source.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 26), range: NSRange(location: 0, length: 4))
            let result = try RichTextReplacement.translated("Meeting schedule\nThe meeting is at ten tomorrow.", preserving: source, removingTriggerSpaces: true)
            XCTAssertEqual(result.string, "Meeting schedule\nThe meeting is at ten tomorrow.")
            let title = result.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
            let body = result.attribute(.font, at: 17, effectiveRange: nil) as! NSFont
            XCTAssertEqual(title.pointSize, 26)
            XCTAssertTrue(title.fontDescriptor.symbolicTraits.contains(.bold))
            XCTAssertEqual(body.pointSize, 17)
            XCTAssertFalse(body.fontDescriptor.symbolicTraits.contains(.bold))
        }
    }
    func testBlankLinesIndentationAndParagraphSpacingSurvive() async throws {
        try await MainActor.run {
            let style = NSMutableParagraphStyle(); style.headIndent = 24; style.paragraphSpacing = 9
            let source = NSAttributedString(string: "标题\n\n    正文一\n\n正文二\n", attributes: [.font: NSFont.systemFont(ofSize: 17), .paragraphStyle: style])
            let result = try RichTextReplacement.translated("Title\nBody one\nBody two", preserving: source, removingTriggerSpaces: false)
            XCTAssertEqual(result.string, "Title\n\n    Body one\n\nBody two\n")
            XCTAssertEqual((result.attribute(.paragraphStyle, at: 12, effectiveRange: nil) as? NSParagraphStyle)?.headIndent, 24)
            XCTAssertEqual((result.attribute(.paragraphStyle, at: 12, effectiveRange: nil) as? NSParagraphStyle)?.paragraphSpacing, 9)
        }
    }
    func testMixedEmphasisIsNotSilentlyFlattened() async throws {
        try await MainActor.run {
            let source = NSMutableAttributedString(string: "important meeting", attributes: [.font: NSFont.systemFont(ofSize: 17)])
            source.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 17), range: NSRange(location: 0, length: 9))
            XCTAssertThrowsError(try RichTextReplacement.translated("重要会议", preserving: source, removingTriggerSpaces: false))
        }
    }
    func testChangedParagraphCountFailsBeforeWriting() async throws {
        try await MainActor.run {
            let source = NSAttributedString(string: "Title\nBody", attributes: [.font: NSFont.systemFont(ofSize: 17)])
            XCTAssertThrowsError(try RichTextReplacement.translated("合并成一段", preserving: source, removingTriggerSpaces: false))
            XCTAssertEqual(source.string, "Title\nBody")
        }
    }
}
