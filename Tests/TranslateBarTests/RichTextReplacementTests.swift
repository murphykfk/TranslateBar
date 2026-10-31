import AppKit
import XCTest
@testable import TranslateBar

final class RichTextReplacementTests: XCTestCase {
    @MainActor func testWebParagraphEditsKeepStructureWithoutImportingHTMLOrFonts() throws {
        let original = NSAttributedString(string: "Heading\n\n    正文    ")
        let formatted = try RichTextReplacement.translated("Heading\nBody", preserving: original, removingTriggerSpaces: true, requireFont: false)
        XCTAssertEqual(formatted.string, "Heading\n\n    Body")
        let edits = try RichTextReplacement.edits(original: original, replacement: formatted, offset: 0)
        XCTAssertEqual(edits.count, 1)
        XCTAssertEqual(edits.first?.original.string, "    正文    ")
        XCTAssertEqual(edits.first?.replacement.string, "    Body")
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
            let data = try RichTextReplacement.rtf(result)
            let decoded = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            XCTAssertEqual(decoded.string, result.string)
            XCTAssertEqual((decoded.attribute(.font, at: 17, effectiveRange: nil) as? NSFont)?.pointSize, 17)
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
    func testRichClipboardContainsRTFAndRestoresExistingFormats() async throws {
        try await MainActor.run {
            let board = NSPasteboard(name: .init("TranslateBarRichTest.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            board.setString("original clipboard", forType: .string)
            let styled = NSAttributedString(string: "Body", attributes: [.font: NSFont.systemFont(ofSize: 17)])
            let rtf = try RichTextReplacement.rtf(styled)
            let temporary = TemporaryClipboard(text: styled.string, rtf: rtf, pasteboard: board)
            XCTAssertEqual(board.data(forType: .rtf), rtf)
            temporary.restore()
            XCTAssertEqual(board.string(forType: .string), "original clipboard")
        }
    }
    func testEditsSkipUnchangedTitleAndNeverPasteParagraphSeparators() async throws {
        try await MainActor.run {
            let original = NSAttributedString(string: "Title\r\n\r\n正文一\n正文二    ", attributes: [.font: NSFont.systemFont(ofSize: 13)])
            let translated = try RichTextReplacement.translated("Title\nBody one\nBody two", preserving: original, removingTriggerSpaces: true)
            let edits = try RichTextReplacement.edits(original: original, replacement: translated, offset: 7)
            XCTAssertEqual(edits.count, 2)
            XCTAssertGreaterThan(edits[0].range.location, edits[1].range.location)
            var working = "prefix:" + original.string
            for edit in edits {
                XCTAssertFalse(edit.original.string.contains("\n"))
                XCTAssertFalse(edit.original.string.contains("\r"))
                XCTAssertFalse(edit.replacement.string.contains("\n"))
                working = (working as NSString).replacingCharacters(in: edit.range, with: edit.replacement.string)
            }
            XCTAssertEqual(working, "prefix:" + translated.string)
            for edit in edits.reversed() {
                working = (working as NSString).replacingCharacters(in: NSRange(location: edit.range.location, length: edit.replacement.length), with: edit.original.string)
            }
            XCTAssertEqual(working, "prefix:" + original.string)
        }
    }
    func testSourceCopyRestoresClipboardButPreservesANewerUserCopy() async throws {
        try await MainActor.run {
            let board = NSPasteboard(name: .init("TranslateBarCopyTest.\(UUID().uuidString)"))
            defer { board.releaseGlobally() }
            board.setString("original clipboard", forType: .string)
            let temporary = TemporaryClipboard(text: "sentinel", pasteboard: board)
            board.clearContents(); board.setString("source\n", forType: .string)
            XCTAssertTrue(temporary.acceptCopiedText("source"))
            temporary.restore()
            XCTAssertEqual(board.string(forType: .string), "original clipboard")
            let another = TemporaryClipboard(text: "sentinel", pasteboard: board)
            board.clearContents(); board.setString("new user copy", forType: .string)
            XCTAssertFalse(another.acceptCopiedText("source"))
            another.restore()
            XCTAssertEqual(board.string(forType: .string), "new user copy")
        }
    }
}
