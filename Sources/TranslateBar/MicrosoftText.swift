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

    static func prepareInput(_ context: ClipboardTextContext, document: MicrosoftTextRules.Document) async throws -> AXUIElement {
        try await TextInputGate.run(pid: context.pid) {
            try ClipboardText.validate(context)
            let role: String = AccessibleText.attribute(context.element, kAXRoleAttribute) ?? ""
            let enabled: Bool? = AccessibleText.attribute(context.element, kAXEnabledAttribute)
            let editable: Bool? = AccessibleText.attribute(context.element, "AXEditable")
            let modal: Bool = AccessibleText.attribute(context.window, kAXModalAttribute) ?? false
            ReplacementDiagnostics.note("\(document.diagnosticPrefix)_body_guard", ["role_supported": ["AXLayoutArea", "AXTextArea"].contains(role) ? 1 : 0,
                "enabled": enabled.map { $0 ? 1 : 0 } ?? -1, "editable": editable.map { $0 ? 1 : 0 } ?? -1, "modal": modal ? 1 : 0])
            guard MicrosoftTextRules.permitsBody(bundleID: NSRunningApplication(processIdentifier: context.pid)?.bundleIdentifier ?? "",
                role: role, secure: AccessibleText.isSecure(context.element), modal: modal) else {
                ReplacementDiagnostics.fail("\(document.diagnosticPrefix)_body_focus_unverified")
                throw AppError.message("未确认 \(document.name) 文字焦点，请点击文字内部后重试。原文未改动。")
            }
            guard let paste = command("paste:", pid: context.pid) else {
                ReplacementDiagnostics.fail("\(document.diagnosticPrefix)_paste_command_missing")
                throw AppError.message("未确认 \(document.name) 的粘贴能力，请将光标放回文字内部后重试，或使用划词翻译。")
            }
            // A disabled Paste command can also mean an empty clipboard. Use
            // the existing protected clipboard transaction to distinguish it.
            let transaction = TemporaryClipboard(text: "TranslateBar edit capability check")
            defer { transaction.restore() }
            await OfficeText.pause(0.04)
            try ClipboardText.validate(context)
            try TextInputGate.check()
            let pasteEnabled: Bool? = AccessibleText.attribute(paste, kAXEnabledAttribute)
            ReplacementDiagnostics.note("\(document.diagnosticPrefix)_paste_check", ["enabled": pasteEnabled.map { $0 ? 1 : 0 } ?? -1])
            guard pasteEnabled == true else {
                ReplacementDiagnostics.fail("\(document.diagnosticPrefix)_paste_unavailable")
                throw AppError.message("未确认 \(document.name) 当前“粘贴”命令可用，请点击可编辑文字内部后重试。原文未改动。")
            }
            if document == .powerPoint {
                let copyEnabled: Bool? = command("copy:", pid: context.pid).flatMap { AccessibleText.attribute($0, kAXEnabledAttribute) }
                let cutEnabled: Bool? = command("cut:", pid: context.pid).flatMap { AccessibleText.attribute($0, kAXEnabledAttribute) }
                ReplacementDiagnostics.note("powerpoint_initial_selection", ["copy_enabled": copyEnabled.map { $0 ? 1 : 0 } ?? -1,
                    "cut_enabled": cutEnabled.map { $0 ? 1 : 0 } ?? -1])
                guard MicrosoftTextRules.permitsInitialSelection(in: document, copyEnabled: copyEnabled, cutEnabled: cutEnabled) else {
                    ReplacementDiagnostics.fail("powerpoint_text_caret_unverified")
                    throw AppError.message("请双击进入 PowerPoint 文字内部，将光标放在句末后再连续空格；不要只选中文本框边框。原文未改动。")
                }
            }
            ReplacementDiagnostics.note("\(document.diagnosticPrefix)_edit_capability_verified")
            return paste
        }
    }

    static func validateSelectedInput(_ context: ClipboardTextContext) throws {
        let cut = command("cut:", pid: context.pid)
        let enabled: Bool? = cut.flatMap { AccessibleText.attribute($0, kAXEnabledAttribute) }
        let document = context.microsoftDocument ?? .word
        ReplacementDiagnostics.note("\(document.diagnosticPrefix)_selection_edit_check", ["command_available": cut != nil ? 1 : 0, "enabled": enabled.map { $0 ? 1 : 0 } ?? -1])
        guard enabled == true else {
            ReplacementDiagnostics.fail("\(document.diagnosticPrefix)_selection_not_editable")
            throw AppError.message("\(document.name) 当前文字选区不允许编辑，请检查文档保护状态。原文未改动。")
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
