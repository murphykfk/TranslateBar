import AppKit
import Carbon
import TranslateCore

struct ClipboardTextContext {
    let element: AXUIElement
    let window: AXUIElement
    let pid: pid_t
    let title: String
    let revision: UInt64
    var windowOnlyFocus = false
}
struct ClipboardTextSnapshot {
    let context: ClipboardTextContext
    let text: NSAttributedString
    let anchor: NSRect
}

/// A capability-based fallback, independent of the name of the source app.
/// Never uses Select All or injects Return, Tab, Cut, or Delete.
@MainActor enum ClipboardText {
    static func context(settings: AppSettings) throws -> ClipboardTextContext {
        let owner = try AccessibleText.activeApplication(settings: settings)
        let pid = owner.processIdentifier
        let app = AXUIElementCreateApplication(pid)
        guard let window: AXUIElement = AccessibleText.attribute(app, kAXFocusedWindowAttribute),
              (AccessibleText.attribute(window, kAXRoleAttribute) as String?) == kAXWindowRole else {
            ReplacementDiagnostics.fail("clipboard_window_unavailable")
            throw AppError.message("当前窗口无法安全取词。")
        }
        let title: String = AccessibleText.attribute(window, kAXTitleAttribute) ?? ""
        let focused = TextFocus.resolve(pid: pid, wakeAccessibility: settings.enhancedCompatibility)
        if let focused, !TextFocus.isContainer(focused) || owner.bundleIdentifier != "com.tencent.xinWeChat" {
            guard !AccessibleText.isSecure(focused) else { throw AppError.message("密码输入框不参与翻译。") }
            let element = MicrosoftTextRules.document(bundleID: owner.bundleIdentifier ?? "") != nil ? MicrosoftText.bodyElement(focused) ?? focused : focused
            let role: String = AccessibleText.attribute(element, kAXRoleAttribute) ?? ""
            ReplacementDiagnostics.note("clipboard_focus", ["document": MicrosoftTextRules.document(bundleID: owner.bundleIdentifier ?? "")?.rawValue ?? 0,
                "text_role": TextCompatibilityRules.isTextRole(role) ? 1 : 0, "layout_role": role == "AXLayoutArea" ? 1 : 0,
                "editable": AccessibleText.canEdit(element) ? 1 : 0,
                "enabled": (AccessibleText.attribute(element, kAXEnabledAttribute) as Bool?).map { $0 ? 1 : 0 } ?? -1])
            return ClipboardTextContext(element: element, window: window, pid: pid, title: title, revision: TextInteraction.revision)
        }
        guard settings.enhancedCompatibility, permitsWindowOnly(owner: owner, window: window, title: title),
              focused.map({ !AccessibleText.isSecure($0) }) ?? true else { throw AppError.message("当前控件未提供可访问文本，已跳过。") }
        return ClipboardTextContext(element: window, window: window, pid: pid, title: title,
                                    revision: TextInteraction.revision, windowOnlyFocus: true)
    }
    private static func permitsWindowOnly(owner: NSRunningApplication, window: AXUIElement, title: String) -> Bool {
        guard owner.bundleIdentifier == "com.tencent.xinWeChat" else { return false }
        let minimize: AXUIElement? = AccessibleText.attribute(window, kAXMinimizeButtonAttribute)
        let close: AXUIElement? = AccessibleText.attribute(window, kAXCloseButtonAttribute)
        let main: Bool = AccessibleText.attribute(window, kAXMainAttribute) ?? false
        let modal: Bool = AccessibleText.attribute(window, kAXModalAttribute) ?? false
        let collapsed = TextFocus.hasCollapsedWindowTree(window)
        ReplacementDiagnostics.note("wechat_window_guard", ["main": main ? 1 : 0, "minimize": minimize != nil ? 1 : 0,
            "close": close != nil ? 1 : 0, "modal": modal ? 1 : 0, "collapsed": collapsed ? 1 : 0])
        return ChatDraftCompatibility.permitsMissingFocus(bundleID: owner.bundleIdentifier ?? "", windowTitle: title,
            activeWindow: NSWorkspace.shared.frontmostApplication?.processIdentifier == owner.processIdentifier,
            standardControls: minimize != nil && close != nil,
            modal: modal,
            secureInput: IsSecureEventInputEnabled()) && collapsed
    }
    static func validate(_ expected: ClipboardTextContext) throws {
        guard AccessibleText.trusted, !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == expected.pid,
              TextInteraction.revision == expected.revision else { throw TextReplacementError.changed }
        let app = AXUIElementCreateApplication(expected.pid)
        guard let window: AXUIElement = AccessibleText.attribute(app, kAXFocusedWindowAttribute), CFEqual(window, expected.window),
              (AccessibleText.attribute(window, kAXTitleAttribute) as String? ?? "") == expected.title else { throw TextReplacementError.changed }
        let focused = TextFocus.resolve(pid: expected.pid)
        let element = MicrosoftTextRules.document(bundleID: NSRunningApplication(processIdentifier: expected.pid)?.bundleIdentifier ?? "") != nil
            ? focused.map { MicrosoftText.bodyElement($0) ?? $0 } : focused
        if expected.windowOnlyFocus {
            guard let owner = NSRunningApplication(processIdentifier: expected.pid),
                  permitsWindowOnly(owner: owner, window: window, title: expected.title) else { throw TextReplacementError.changed }
            if let element {
                guard !AccessibleText.isSecure(element) else { throw TextReplacementError.changed }
                let role: String = AccessibleText.attribute(element, kAXRoleAttribute) ?? "AXUnknown"
                guard TextFocus.isContainer(element) || (TextCompatibilityRules.isTextRole(role) && AccessibleText.canEdit(element)) else { throw TextReplacementError.changed }
            }
        } else {
            guard let element, CFEqual(element, expected.element), !AccessibleText.isSecure(element) else { throw TextReplacementError.changed }
        }
    }
    static func copy(_ context: ClipboardTextContext) async throws -> NSAttributedString {
        try validate(context)
        let transaction = TemporaryClipboard(text: "TranslateBar copy \(UUID().uuidString)")
        defer { transaction.restore() }
        OfficeText.key(8, flags: .maskCommand, to: context.pid)
        for _ in 0..<15 {
            await OfficeText.pause(0.035)
            try validate(context)
            try Task.checkCancellation()
            if let text = transaction.takeCopiedRichText() {
                guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.string.utf8.count <= 60_000 else {
                    ReplacementDiagnostics.fail("clipboard_copy_empty_or_oversized")
                    throw AppError.message("未复制到有效文字，或选区超过 60 KB。")
                }
                // PowerPoint exports a paragraph terminator even for a partial
                // text selection. Its AX range can also include a virtual final
                // marker one character beyond AXValue. Trim only after matching
                // the actual text selection; genuine selected breaks remain.
                if NSRunningApplication(processIdentifier: context.pid)?.bundleIdentifier == "com.microsoft.Powerpoint",
                   let focused = TextFocus.resolve(pid: context.pid),
                   let value = AccessibleText.textValue(focused), let range = AccessibleText.selectedRange(focused),
                   let expected = MicrosoftTextRules.powerPointCopiedText(value: value, range: range, copied: text.string),
                   let matched = ClipboardRichText.matching(expected, rich: text) {
                    return matched
                }
                return text
            }
        }
        ReplacementDiagnostics.fail("clipboard_copy_unavailable")
        throw AppError.message("此控件未提供可复制文字；图片和扫描件不参与翻译。")
    }
    private static func snapshot(_ context: ClipboardTextContext, text: NSAttributedString) -> TextSnapshot {
        let point = NSEvent.mouseLocation
        let state = ClipboardTextSnapshot(context: context, text: text, anchor: NSRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16))
        return TextSnapshot(element: context.element, pid: context.pid, value: text.string, range: NSRange(location: 0, length: text.length), source: text.string, fullValue: nil, clipboard: state)
    }
    static func selected(settings: AppSettings) async throws -> TextSnapshot {
        let context = try context(settings: settings)
        let role: String = AccessibleText.attribute(context.element, kAXRoleAttribute) ?? ""
        guard !["AXButton", "AXMenuItem", "AXToolbar", "AXSlider", "AXScrollBar", "AXImage", "AXBrowser"].contains(role) else { throw AppError.message("当前焦点不在可取词的正文中。") }
        return snapshot(context, text: try await copy(context))
    }
}
