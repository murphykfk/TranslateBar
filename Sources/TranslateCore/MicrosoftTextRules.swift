import Foundation

/// Document canvases use editing commands instead of their AXEnabled hint.
public enum MicrosoftTextRules {
    public enum Document: Int {
        case word = 1, powerPoint = 2, excel = 3
        public var name: String { switch self { case .word: "Word"; case .powerPoint: "PowerPoint"; case .excel: "Excel" } }
        public var diagnosticPrefix: String { switch self { case .word: "word"; case .powerPoint: "powerpoint"; case .excel: "excel" } }
    }
    public enum ParagraphModifier { case command, option }

    public static func document(bundleID: String) -> Document? {
        switch bundleID {
        case WordTextRules.bundleID: return .word
        case "com.microsoft.Powerpoint": return .powerPoint
        case "com.microsoft.Excel": return .excel
        default: return nil
        }
    }
    public static func usesDocumentFallback(bundleID: String, role: String) -> Bool {
        if bundleID == "com.microsoft.Excel" { return role == "AXTextArea" }
        return document(bundleID: bundleID) != nil && ["AXLayoutArea", "AXTextArea"].contains(role)
    }
    public static func permitsBody(bundleID: String, role: String, secure: Bool, modal: Bool) -> Bool {
        usesDocumentFallback(bundleID: bundleID, role: role) && !secure && !modal
    }
    public static func paragraphModifier(for document: Document) -> ParagraphModifier {
        // PowerPoint's Command-Up goes to the start of the entire text object.
        document == .powerPoint ? .option : .command
    }
    public static func permitsInitialSelection(in document: Document, copyEnabled: Bool?, cutEnabled: Bool?) -> Bool {
        // A selected shape also enables Paste and Cut. Reject that state before
        // sending arrows, which would resize/move an object instead of text.
        document != .powerPoint || (copyEnabled == false && cutEnabled == false)
    }

    public static func permitsExcelText(_ text: String) -> Bool {
        guard let first = text.trimmingCharacters(in: .whitespacesAndNewlines).first else { return false }
        return !["=", "+", "-", "@"].contains(first)
    }

    public static func powerPointPasteText(_ text: String) -> String {
        let expression = try! NSRegularExpression(pattern: "[ \u{a0}]{2,}")
        let result = NSMutableString(string: text)
        for match in expression.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)).reversed() {
            result.replaceCharacters(in: match.range, with: String(repeating: "\u{a0}", count: match.range.length))
        }
        return result as String
    }

    public static func wordSelectionWithoutParagraphMark(value: String, range: NSRange, copied: String) -> NSRange? {
        guard range.location >= 0, range.length > 0, range.location <= value.utf16.count,
              range.length <= value.utf16.count - range.location, Range(range, in: value) != nil else { return nil }
        let selected = (value as NSString).substring(with: range)
        guard ["\n", "\r", "\r\n"].contains(where: { selected == copied + $0 }), !copied.isEmpty else { return nil }
        return NSRange(location: range.location, length: copied.utf16.count)
    }

    public static func powerPointPrefixRange(value: String, caret: NSRange, selection: NSRange, copied: String) -> NSRange? {
        guard caret.length == 0, caret.location <= value.utf16.count, selection.location >= 0,
              selection.location < caret.location, selection.length > 0,
              selection.length <= value.utf16.count + 1 - selection.location,
              NSMaxRange(selection) == caret.location + 1 else { return nil }
        let range = NSRange(location: selection.location, length: caret.location - selection.location)
        guard Range(range, in: value) != nil else { return nil }
        let expected = (value as NSString).substring(with: range)
        func canonical(_ text: String) -> String { text.replacingOccurrences(of: "\r\n|[\r\u{b}\u{c}\u{85}\u{2028}\u{2029}]", with: "\n", options: .regularExpression) }
        guard canonical(copied) == canonical(expected) || canonical(copied) == canonical(expected) + "\n" else { return nil }
        return range
    }

    public static func powerPointCopiedText(value: String, range: NSRange, copied: String) -> String? {
        let count = value.utf16.count
        guard range.location >= 0, range.length > 0, range.location < count,
              range.length <= count + 1 - range.location else { return nil }
        let actual = NSRange(location: range.location, length: min(range.length, count - range.location))
        guard Range(actual, in: value) != nil else { return nil }
        let expected = (value as NSString).substring(with: actual)
        func canonical(_ text: String) -> String {
            text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        let plain = canonical(copied), selected = canonical(expected)
        guard plain == selected || plain == selected + "\n" else { return nil }
        return expected
    }
}
