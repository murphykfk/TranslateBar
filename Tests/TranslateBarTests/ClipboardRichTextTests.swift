import AppKit
import XCTest
@testable import TranslateBar

@MainActor final class ClipboardRichTextTests: XCTestCase {
    func testPowerPointCRLFAndRTFLFKeepTheFont() {
        let rich = NSAttributedString(string: "正文    \n", attributes: [.font: NSFont.boldSystemFont(ofSize: 24)])
        let matched = ClipboardRichText.matching("正文    \r\n", rich: rich)
        XCTAssertEqual(matched?.string, "正文    \r\n")
        XCTAssertEqual((matched?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 24)
    }
    func testMixedBreaksPreserveStylesAndExactPlainText() {
        let rich = NSMutableAttributedString(string: "标题\r\n正文\r尾行\n", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        rich.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 20), range: NSRange(location: 0, length: 2))
        let matched = ClipboardRichText.matching("标题\r正文\r\n尾行", rich: rich)
        XCTAssertEqual(matched?.string, "标题\r正文\r\n尾行")
        XCTAssertEqual((matched?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize, 20)
        XCTAssertEqual((matched?.attribute(.font, at: 3, effectiveRange: nil) as? NSFont)?.pointSize, 13)
        XCTAssertNil(ClipboardRichText.matching("其他正文", rich: rich))
        XCTAssertNil(ClipboardRichText.matching("正文", rich: NSAttributedString(string: "正文\n\n")))
    }
    func testWordManualBreakHasDifferentPlainAndRTFRepresentations() {
        let rich = NSAttributedString(string: "上一行\u{2028}当前段落    \n", attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let plain = "上一行\r\n当前段落    \r\n"
        let copied = ClipboardRichText.matching(plain, rich: rich)
        XCTAssertEqual(copied?.string, plain)
        XCTAssertEqual((copied?.attribute(.font, at: 5, effectiveRange: nil) as? NSFont)?.pointSize, 13)
        let native = ClipboardRichText.matching("上一行\u{b}当前段落    ", rich: try! XCTUnwrap(copied))
        XCTAssertEqual(native?.string, "上一行\u{b}当前段落    ")
        XCTAssertEqual((native?.attribute(.font, at: 4, effectiveRange: nil) as? NSFont)?.pointSize, 13)
    }
}
