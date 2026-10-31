import Foundation

public enum ParagraphInput {
    public static func range(in text: String, caret: NSRange) throws -> NSRange {
        let value = text as NSString
        guard caret.location >= 0, caret.length >= 0, caret.location <= value.length,
              caret.length <= value.length - caret.location else { throw TextReplacementError.invalidRange }
        // A caret immediately after Return belongs to the new empty paragraph,
        // never to the paragraph that was just completed.
        return value.paragraphRange(for: NSRange(location: caret.location, length: 0))
    }
}
