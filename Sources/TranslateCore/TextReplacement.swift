import Foundation

public enum TextReplacementError: LocalizedError {
    case changed, invalidRange
    public var errorDescription: String? {
        switch self {
        case .changed: return "翻译期间原文已变化，未覆盖新内容。"
        case .invalidRange: return "文本范围已变化，未覆盖原文。"
        }
    }
}

public struct TextReplacementPlan {
    public let range: NSRange
    public let updated: String
    public let originalText: String
    public init(original: String, range: NSRange, current: String, replacement: String, allowTrailingSpaces: Bool = false) throws {
        let length = (original as NSString).length
        guard range.location >= 0, range.length >= 0, range.location <= length, range.length <= length - range.location else { throw TextReplacementError.invalidRange }
        var target = range
        if original != current {
            // Only a range ending at the document tail may tolerate delayed
            // trigger spaces. Earlier paragraphs must remain byte-for-byte equal.
            // Added words, punctuation, newlines and changes elsewhere always cancel replacement.
            guard allowTrailingSpaces, NSMaxRange(range) == length, (current as NSString).length >= range.location,
                  Self.removingTrailingSpaces(original) == Self.removingTrailingSpaces(current) else { throw TextReplacementError.changed }
            target = NSRange(location: range.location, length: (current as NSString).length - range.location)
        }
        self.range = target
        originalText = (current as NSString).substring(with: target)
        updated = (current as NSString).replacingCharacters(in: target, with: replacement)
    }
    private static func removingTrailingSpaces(_ value: String) -> String {
        String(value.reversed().drop(while: { $0 == " " || $0 == "\u{00a0}" }).reversed())
    }
}
