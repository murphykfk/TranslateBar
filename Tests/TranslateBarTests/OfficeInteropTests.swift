import AppKit
import Carbon
import XCTest
import TranslateCore
@testable import TranslateBar

final class OfficeInteropTests: XCTestCase {
    @MainActor private func legacyBoard(_ board: NSPasteboard, items: [[(String, Data)]]) throws {
        var reference: Pasteboard?
        XCTAssertEqual(PasteboardCreate(board.name.rawValue as CFString, &reference), noErr)
        let handle = try XCTUnwrap(reference)
        XCTAssertEqual(PasteboardClear(handle), noErr)
        for (index, item) in items.enumerated() {
            for (type, data) in item { XCTAssertEqual(PasteboardPutItemFlavor(handle, UnsafeMutableRawPointer(bitPattern: index + 1)!, type as CFString, data as CFData, []), noErr) }
        }
    }
    @MainActor func testLegacyQtFormatsAndMultipleItemsSurviveTemporaryCopy() throws {
        let board = NSPasteboard(name: .init("TranslateBarLegacy.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let legacy = "com.trolltech.anymime.Rich Text Format"
        let binary = Data([0, 255, 14, 65])
        try legacyBoard(board, items: [[(legacy, binary), (NSPasteboard.PasteboardType.string.rawValue, Data("original".utf8))], [(NSPasteboard.PasteboardType.string.rawValue, Data("second".utf8))]])
        let temporary = TemporaryClipboard(text: "temporary", pasteboard: board)
        temporary.restore()
        XCTAssertEqual(board.pasteboardItems?.count, 2)
        XCTAssertEqual(ClipboardFormats.data(.init(legacy), from: board), binary)
        XCTAssertEqual(board.pasteboardItems?.first?.string(forType: .string), "original")
        XCTAssertEqual(board.pasteboardItems?.last?.string(forType: .string), "second")
    }
    @MainActor func testQtRTFRemovesOnlyTheExportedExtraTerminator() throws {
        let board = NSPasteboard(name: .init("TranslateBarQtCopy.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let temporary = TemporaryClipboard(text: "sentinel", pasteboard: board)
        let rich = NSAttributedString(string: "Meeting\n", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        try legacyBoard(board, items: [[("com.trolltech.anymime.Rich Text Format", rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])), (NSPasteboard.PasteboardType.string.rawValue, Data("Meeting".utf8))]])
        let copied = try XCTUnwrap(temporary.takeCopiedRichText())
        XCTAssertEqual(copied.string, "Meeting")
        XCTAssertEqual((copied.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 13)
        temporary.restore()
        XCTAssertEqual(board.string(forType: .string), "original")
    }
    @MainActor func testLegacyRestorationStillPreservesANewerUserCopy() throws {
        let board = NSPasteboard(name: .init("TranslateBarQtConcurrent.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        try legacyBoard(board, items: [[("com.trolltech.anymime.Rich Text Format", Data([1, 2, 3]))]])
        let temporary = TemporaryClipboard(text: "sentinel", pasteboard: board)
        board.clearContents(); board.setString("new user copy", forType: .string)
        temporary.restore()
        XCTAssertEqual(board.string(forType: .string), "new user copy")
    }
    @MainActor func testNonbreakingTriggerSpacesAreRemovedWithoutChangingFont() throws {
        let original = NSAttributedString(string: "正文 \u{00a0} \u{00a0}", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let output = try RichTextReplacement.translated("Body", preserving: original, removingTriggerSpaces: true)
        XCTAssertEqual(output.string, "Body")
        XCTAssertEqual((output.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 13)
    }
}
