import Foundation

public enum ChatDraftCompatibility {
    public static let discordBundleID = "com.hnc.Discord"

    /// A missing accessibility focus must never make an arbitrary window writable.
    public static func permitsMissingFocus(bundleID: String, windowTitle: String,
                                           activeWindow: Bool, standardControls: Bool,
                                           modal: Bool, secureInput: Bool) -> Bool {
        bundleID == "com.tencent.xinWeChat" && !windowTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && activeWindow && standardControls && !modal && !secureInput
    }

    public static func isWindowDecoration(role: String, subrole: String) -> Bool {
        if ["AXWindow", "AXGroup", "AXUnknown", "AXGrowArea"].contains(role) { return true }
        return role == "AXButton" && ["AXCloseButton", "AXMinimizeButton", "AXZoomButton", "AXFullScreenButton"].contains(subrole)
    }

    public static func containsTrigger(_ text: String, spaces: Int) -> Bool {
        guard (2...4).contains(spaces), TextCompatibilityRules.isSingleTextLine(text),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let suffix = text.unicodeScalars.suffix(spaces)
        return suffix.count == spaces && suffix.allSatisfy { $0.value == 32 || $0.value == 160 }
    }

    /// Copying the final selected character must agree with the copied line.
    /// A history row that copies a whole message cannot pass this editor probe.
    public static func matchesCaretProbe(line: String, selectedCharacter: String) -> Bool {
        TextCompatibilityRules.isSingleTextLine(line) && !selectedCharacter.isEmpty
            && selectedCharacter == String(line.suffix(1))
    }
}
