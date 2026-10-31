import Foundation

public enum WordTextRules {
    public static let bundleID = "com.microsoft.Word"
    public static let maximumSelectionSteps = 256

    public static func usesDocumentFallback(bundleID: String, role: String) -> Bool {
        bundleID == self.bundleID && ["AXLayoutArea", "AXTextArea"].contains(role)
    }

    public static func permitsInput(bundleID: String, role: String, enabled: Bool?, explicitlyEditable: Bool?, pasteEnabled: Bool?, secure: Bool, modal: Bool) -> Bool {
        permitsBody(bundleID: bundleID, role: role, enabled: enabled, explicitlyEditable: explicitlyEditable, secure: secure, modal: modal)
            && pasteEnabled == true
    }

    public static func permitsBody(bundleID: String, role: String, enabled: Bool?, explicitlyEditable: Bool?, secure: Bool, modal: Bool) -> Bool {
        usesDocumentFallback(bundleID: bundleID, role: role)
            && enabled == true && explicitlyEditable != false && !secure && !modal
    }

    public enum SelectionAdjustment: Equatable {
        case none
        case moveStartRight(Int)
        case selectFromCaretLeft(Int)
    }

    public struct PrefixSelection {
        public let range: NSRange
        public let adjustment: SelectionAdjustment
    }

    /// Word's paragraph shortcut can span manual line breaks. Keep only text
    /// after the last break and verify the resulting clipboard selection.
    public static func prefixSelection(in text: String) throws -> PrefixSelection {
        guard !text.isEmpty, text.utf8.count <= 60_000 else { throw TextReplacementError.invalidRange }
        let start = text.lastIndex(where: { $0.isNewline }).map { text.index(after: $0) } ?? text.startIndex
        let suffix = String(text[start...])
        guard TextCompatibilityRules.isSingleTextLine(suffix), !suffix.trimmingCharacters(in: .whitespaces).isEmpty else { throw TextReplacementError.invalidRange }
        let range = NSRange(start..<text.endIndex, in: text)
        guard start != text.startIndex else { return PrefixSelection(range: range, adjustment: .none) }
        let skipped = text[..<start].count, kept = suffix.count
        guard min(skipped, kept) <= maximumSelectionSteps else { throw TextReplacementError.invalidRange }
        return PrefixSelection(range: range, adjustment: skipped <= kept ? .moveStartRight(skipped) : .selectFromCaretLeft(kept))
    }
}
