import Foundation

public enum TextCompatibilityRules {
    public static func isTextRole(_ role: String) -> Bool {
        ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
    }
    public static func permitsLineFallback(role: String, editable: Bool?, enabled: Bool?, secure: Bool) -> Bool {
        !secure && editable != false && enabled != false && isTextRole(role)
    }
    public static func isSingleTextLine(_ text: String) -> Bool {
        !text.isEmpty && !text.contains(where: { $0.isNewline })
            && !text.unicodeScalars.contains(where: { $0.value < 0x20 || (0x7f...0x9f).contains($0.value) || $0.value == 0xfffc })
    }
    /// Keep indentation and non-gesture whitespace even without font metadata.
    public static func replacingLine(_ original: String, with translation: String, triggerSpaces: Int) throws -> String {
        guard isSingleTextLine(original), isSingleTextLine(translation) else { throw TextReplacementError.invalidRange }
        let source = original as NSString
        let trimmed = original.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { throw TextReplacementError.invalidRange }
        let leading = String(original.prefix(while: { $0.isWhitespace }))
        var trailing = String(original.reversed().prefix(while: { $0.isWhitespace }).reversed())
        if triggerSpaces > 0, trailing.utf16.count >= triggerSpaces,
           trailing.unicodeScalars.suffix(triggerSpaces).allSatisfy({ $0.value == 32 || $0.value == 160 }) {
            trailing = (trailing as NSString).substring(to: trailing.utf16.count - triggerSpaces)
        }
        guard leading.utf16.count + trailing.utf16.count <= source.length else { throw TextReplacementError.invalidRange }
        return leading + translation.trimmingCharacters(in: .whitespaces) + trailing
    }
}
