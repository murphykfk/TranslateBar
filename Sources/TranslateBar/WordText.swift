import AppKit
import TranslateCore

/// Word's document canvas may be an AXLayoutArea without writable text
/// attributes. Require its own enabled Paste command, rather than assuming
/// that every layout area or every read-only text view can be edited.
@MainActor enum WordText {
    static func bodyElement(_ focused: AXUIElement) -> AXUIElement? {
        let role: String = AccessibleText.attribute(focused, kAXRoleAttribute) ?? ""
        guard ["AXLayoutArea", "AXTextArea"].contains(role) else { return nil }
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

    static func prepareInput(_ context: ClipboardTextContext) async throws -> AXUIElement {
        try await TextInputGate.run(pid: context.pid) {
            try ClipboardText.validate(context)
            let role: String = AccessibleText.attribute(context.element, kAXRoleAttribute) ?? ""
            let enabled: Bool? = AccessibleText.attribute(context.element, kAXEnabledAttribute)
            let editable: Bool? = AccessibleText.attribute(context.element, "AXEditable")
            let modal: Bool = AccessibleText.attribute(context.window, kAXModalAttribute) ?? false
            ReplacementDiagnostics.note("word_body_guard", ["role_supported": ["AXLayoutArea", "AXTextArea"].contains(role) ? 1 : 0,
                "enabled": enabled.map { $0 ? 1 : 0 } ?? -1, "editable": editable.map { $0 ? 1 : 0 } ?? -1, "modal": modal ? 1 : 0])
            guard WordTextRules.permitsBody(bundleID: NSRunningApplication(processIdentifier: context.pid)?.bundleIdentifier ?? "",
                role: role, enabled: enabled, explicitlyEditable: editable, secure: AccessibleText.isSecure(context.element), modal: modal) else {
                ReplacementDiagnostics.fail("word_body_focus_unverified")
                throw AppError.message("未确认 Word 正文焦点，请点击正文后重试。原文未改动。")
            }
            guard let paste = command("paste:", pid: context.pid) else {
                ReplacementDiagnostics.fail("word_paste_command_missing")
                throw AppError.message("未确认 Word 正文的粘贴能力，请将光标放回正文后重试，或使用划词翻译。")
            }
            // A disabled Paste command can also mean an empty clipboard. Use
            // the existing protected clipboard transaction to distinguish it.
            let transaction = TemporaryClipboard(text: "TranslateBar edit capability check")
            defer { transaction.restore() }
            await OfficeText.pause(0.04)
            try ClipboardText.validate(context)
            try TextInputGate.check()
            let pasteEnabled: Bool? = AccessibleText.attribute(paste, kAXEnabledAttribute)
            ReplacementDiagnostics.note("word_paste_check", ["enabled": pasteEnabled.map { $0 ? 1 : 0 } ?? -1])
            guard WordTextRules.permitsInput(bundleID: NSRunningApplication(processIdentifier: context.pid)?.bundleIdentifier ?? "",
                role: role, enabled: enabled, explicitlyEditable: editable,
                pasteEnabled: pasteEnabled,
                secure: AccessibleText.isSecure(context.element), modal: modal) else {
                ReplacementDiagnostics.fail("word_paste_unavailable")
                throw AppError.message("未确认 Word 当前“粘贴”命令可用，请点击可编辑正文后重试。原文未改动。")
            }
            ReplacementDiagnostics.note("word_edit_capability_verified")
            return paste
        }
    }

    static func validateSelectedInput(_ context: ClipboardTextContext) throws {
        let cut = command("cut:", pid: context.pid)
        let enabled: Bool? = cut.flatMap { AccessibleText.attribute($0, kAXEnabledAttribute) }
        ReplacementDiagnostics.note("word_selection_edit_check", ["command_available": cut != nil ? 1 : 0, "enabled": enabled.map { $0 ? 1 : 0 } ?? -1])
        guard enabled == true else {
            ReplacementDiagnostics.fail("word_selection_not_editable")
            throw AppError.message("Word 当前选区不允许编辑，请检查文档保护状态。原文未改动。")
        }
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
