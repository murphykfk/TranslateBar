import AppKit
import TranslateCore

/// Office canvases may lack writable AX text. Verify editing commands and
/// current paragraph text; never infer editability from a disabled canvas.
@MainActor enum MicrosoftText {
    static func excelEditingElement(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let window: AXUIElement = AccessibleText.attribute(app, kAXFocusedWindowAttribute),
              let children: [AXUIElement] = AccessibleText.attribute(window, kAXChildrenAttribute) else { return nil }
        func child(_ id: String) -> AXUIElement? {
            children.first { (AccessibleText.attribute($0, kAXIdentifierAttribute) as String?) == id }
        }
        guard let enter = child("EnterButton"), let cancel = child("CancelButton"),
              (AccessibleText.attribute(enter, kAXEnabledAttribute) as Bool?) == true,
              (AccessibleText.attribute(cancel, kAXEnabledAttribute) as Bool?) == true,
              let editor = child("XLFormulaEditor"),
              AccessibleText.selectedRange(editor) != nil, AccessibleText.textValue(editor) != nil else { return nil }
        return editor
    }
    static func bodyElement(_ focused: AXUIElement) -> AXUIElement? {
        let role: String = AccessibleText.attribute(focused, kAXRoleAttribute) ?? ""
        guard ["AXLayoutArea", "AXTextArea"].contains(role) else { return nil }
        if (AccessibleText.attribute(focused, kAXIdentifierAttribute) as String?) == "XLFormulaEditor" { return focused }
        var node = focused
        for _ in 0..<10 {
            let role: String = AccessibleText.attribute(node, kAXRoleAttribute) ?? ""
            if role == "AXLayoutArea" { return node }
            if role == kAXWindowRole { break }
            guard let parent: AXUIElement = AccessibleText.attribute(node, kAXParentAttribute), !CFEqual(parent, node) else { break }
            node = parent
        }
        return focused
    }




    private static func command(_ identifier: String, pid: pid_t) -> AXUIElement? {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.15)
        guard let bar: AXUIElement = AccessibleText.attribute(application, kAXMenuBarAttribute),
              let headings: [AXUIElement] = AccessibleText.attribute(bar, kAXChildrenAttribute), headings.count <= 24,
              let edit = headings.first(where: { (AccessibleText.attribute($0, kAXIdentifierAttribute) as String?) == "EditMenu_MenuItem" }),
              let children: [AXUIElement] = AccessibleText.attribute(edit, kAXChildrenAttribute), children.count <= 4 else { return nil }
        for menu in children {
            guard let commands: [AXUIElement] = AccessibleText.attribute(menu, kAXChildrenAttribute), commands.count <= 100 else { continue }
            if let command = commands.first(where: { (AccessibleText.attribute($0, kAXIdentifierAttribute) as String?) == identifier }) { return command }
        }
        return nil
    }
}
