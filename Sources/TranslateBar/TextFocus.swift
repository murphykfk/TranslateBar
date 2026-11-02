import AppKit
import ApplicationServices
import TranslateCore

@MainActor enum TextFocus {
    private static var requestedManualAccessibility = Set<pid_t>()
    private static let containers: Set<String> = ["AXApplication", "AXWindow", "AXGroup", "AXUnknown"]

    static func resolve(pid: pid_t, wakeAccessibility: Bool = false) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        let direct: AXUIElement? = AccessibleText.attribute(application, kAXFocusedUIElementAttribute)
        ReplacementDiagnostics.note("focus_application", ["available": direct != nil ? 1 : 0])
        // Excel keeps focus on the sheet canvas during in-cell editing. Its
        // formula editor mirrors that same caret only while Enter and Cancel
        // are active. Never infer text focus from a selected grid cell alone.
        if let direct, let role: String = AccessibleText.attribute(direct, kAXRoleAttribute), ["AXLayoutArea", "AXTextArea"].contains(role),
           NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.microsoft.Excel",
           let editor = MicrosoftText.excelEditingElement(pid: pid),
           role == "AXLayoutArea" || (AccessibleText.textValue(direct) == AccessibleText.textValue(editor)
                && AccessibleText.selectedRange(direct) == AccessibleText.selectedRange(editor)) { return editor }
        if let direct, belongs(direct, to: pid), !isContainer(direct) { return direct }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.15)
        let global: AXUIElement? = AccessibleText.attribute(system, kAXFocusedUIElementAttribute)
        ReplacementDiagnostics.note("focus_system", ["available": global != nil ? 1 : 0])
        if let global, belongs(global, to: pid), !isContainer(global) { return global }

        // WeChat's opaque renderer does not expose the missing editor through
        // these flags. Keep that path to the bounded window/clipboard checks;
        // do not try to activate its renderer or walk conversation contents.
        if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.tencent.xinWeChat" {
            if let direct, belongs(direct, to: pid) { return direct }
            if let global, belongs(global, to: pid) { return global }
            return nil
        }

        // Electron documents this flag for external accessibility clients. Do
        // not enable AXEnhancedUserInterface/VoiceOver semantics globally.
        if wakeAccessibility, requestedManualAccessibility.insert(pid).inserted {
            _ = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
            if let refreshed: AXUIElement = AccessibleText.attribute(application, kAXFocusedUIElementAttribute),
               belongs(refreshed, to: pid), !isContainer(refreshed) { return refreshed }
        }

        if let window: AXUIElement = AccessibleText.attribute(application, kAXFocusedWindowAttribute) {
            if let focused: AXUIElement = AccessibleText.attribute(window, kAXFocusedUIElementAttribute),
               belongs(focused, to: pid), !isContainer(focused) { return focused }
            if let focused = focusedDescendant(window, pid: pid) { return focused }
        }
        if let direct, belongs(direct, to: pid) { return direct }
        if let global, belongs(global, to: pid) { return global }
        return nil
    }

    static func isContainer(_ element: AXUIElement) -> Bool {
        let role: String = AccessibleText.attribute(element, kAXRoleAttribute) ?? "AXUnknown"
        return containers.contains(role)
    }

    private static func belongs(_ element: AXUIElement, to pid: pid_t) -> Bool {
        var owner: pid_t = 0
        return AXUIElementGetPid(element, &owner) == .success && owner == pid
    }

    static func hasCollapsedWindowTree(_ window: AXUIElement) -> Bool {
        var queue = [window], visited: [AXUIElement] = [], index = 0
        let deadline = Date().addingTimeInterval(0.12)
        while index < queue.count, index < 32, Date() < deadline {
            let node = queue[index]; index += 1
            if visited.contains(where: { CFEqual($0, node) }) { continue }
            visited.append(node)
            AXUIElementSetMessagingTimeout(node, 0.06)
            let role: String = AccessibleText.attribute(node, kAXRoleAttribute) ?? ""
            let subrole: String = AccessibleText.attribute(node, kAXSubroleAttribute) ?? ""
            guard (AccessibleText.attribute(node, "AXProtectedContent") as Bool?) != true,
                  ChatDraftCompatibility.isWindowDecoration(role: role, subrole: subrole) else { return false }
            // A failed read is not evidence of an empty, opaque tree.
            guard let children = children(of: node), children.count <= 24 else { return false }
            queue.append(contentsOf: children)
        }
        return index == queue.count
    }

    private static func focusedDescendant(_ window: AXUIElement, pid: pid_t) -> AXUIElement? {
        var queue = [window], visited: [AXUIElement] = [], candidates: [AXUIElement] = []
        var index = 0
        let deadline = Date().addingTimeInterval(0.12)
        while index < queue.count, index < 64, Date() < deadline {
            let node = queue[index]; index += 1
            guard !visited.contains(where: { CFEqual($0, node) }), belongs(node, to: pid) else { continue }
            visited.append(node)
            AXUIElementSetMessagingTimeout(node, 0.06)
            if !isContainer(node), (AccessibleText.attribute(node, kAXFocusedAttribute) as Bool?) == true {
                candidates.append(node)
                if candidates.count > 1 { return nil }
            }
            guard let children = children(of: node), children.count <= 24 else { return nil }
            queue.append(contentsOf: children)
        }
        // Never infer focus merely from the presence of a text field. A
        // truncated search cannot establish that the focused control is unique.
        guard index == queue.count, candidates.count == 1 else { return nil }
        return candidates.first
    }

    private static func children(of element: AXUIElement) -> [AXUIElement]? {
        var raw: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
        switch status {
        case .success:
            guard let raw else { return [] }
            return raw as? [AXUIElement]
        case .attributeUnsupported, .noValue: return []
        default: return nil
        }
    }
}
