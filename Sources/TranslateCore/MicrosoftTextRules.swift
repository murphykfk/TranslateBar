import Foundation

/// Document canvases use editing commands instead of their AXEnabled hint.
public enum MicrosoftTextRules {
    public enum Document: Int {
        case word = 1, powerPoint = 2
        public var name: String { self == .word ? "Word" : "PowerPoint" }
        public var diagnosticPrefix: String { self == .word ? "word" : "powerpoint" }
    }
    public enum ParagraphModifier { case command, option }

    public static func document(bundleID: String) -> Document? {
        switch bundleID {
        case WordTextRules.bundleID: return .word
        case "com.microsoft.Powerpoint": return .powerPoint
        default: return nil
        }
    }
    public static func usesDocumentFallback(bundleID: String, role: String) -> Bool {
        document(bundleID: bundleID) != nil && ["AXLayoutArea", "AXTextArea"].contains(role)
    }
    public static func permitsBody(bundleID: String, role: String, secure: Bool, modal: Bool) -> Bool {
        usesDocumentFallback(bundleID: bundleID, role: role) && !secure && !modal
    }
    public static func paragraphModifier(for document: Document) -> ParagraphModifier {
        // PowerPoint's Command-Up goes to the start of the entire text object.
        document == .word ? .command : .option
    }
    public static func permitsInitialSelection(in document: Document, copyEnabled: Bool?, cutEnabled: Bool?) -> Bool {
        // A selected shape also enables Paste and Cut. Reject that state before
        // sending arrows, which would resize/move an object instead of text.
        document == .word || (copyEnabled == false && cutEnabled == false)
    }
}
