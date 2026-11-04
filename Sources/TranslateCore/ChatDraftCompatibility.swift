import Foundation

public enum ChatDraftCompatibility {
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
}
