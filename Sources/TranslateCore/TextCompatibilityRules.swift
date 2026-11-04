import Foundation

public enum TextCompatibilityRules {
    public static func isTextRole(_ role: String) -> Bool {
        ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
    }
}
