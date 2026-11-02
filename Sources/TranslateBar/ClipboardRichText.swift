import AppKit

/// Clipboard formats can encode the same paragraph break as CR, LF or CRLF.
/// Compare their contents canonically, then retain attributes with the exact
/// plain-text spelling. Never accept a difference in non-newline content.
@MainActor enum ClipboardRichText {
    static func canonical(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n|[\r\u{b}\u{c}\u{85}\u{2028}\u{2029}]", with: "\n", options: .regularExpression)
    }

    static func matching(_ plain: String, rich: NSAttributedString) -> NSAttributedString? {
        let result = NSMutableAttributedString(attributedString: rich)
        let breaks = try! NSRegularExpression(pattern: "\r\n|[\r\u{b}\u{c}\u{85}\u{2028}\u{2029}]")
        for match in breaks.matches(in: rich.string, range: NSRange(location: 0, length: rich.length)).reversed() {
            result.replaceCharacters(in: match.range, with: "\n")
        }
        let expected = canonical(plain)
        guard result.string == expected || result.string == expected + "\n" else { return nil }
        if result.length > expected.utf16.count {
            result.deleteCharacters(in: NSRange(location: expected.utf16.count, length: 1))
        }
        var removed = 0
        let edits = breaks.matches(in: plain, range: NSRange(location: 0, length: plain.utf16.count)).map { match -> (NSRange, String) in
            let range = NSRange(location: match.range.location - removed, length: 1)
            removed += match.range.length - 1
            return (range, (plain as NSString).substring(with: match.range))
        }
        for (range, spelling) in edits.reversed() { result.replaceCharacters(in: range, with: spelling) }
        return result.string == plain ? result : nil
    }
}
