import AppKit
import Carbon
import TranslateCore

struct ClipboardTextContext {
    let element: AXUIElement
    let window: AXUIElement
    let pid: pid_t
    let title: String
    let revision: UInt64
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
        let (element, pid) = try AccessibleText.focused(settings: settings)
        let app = AXUIElementCreateApplication(pid)
        guard let window: AXUIElement = AccessibleText.attribute(app, kAXFocusedWindowAttribute),
              (AccessibleText.attribute(window, kAXRoleAttribute) as String?) == kAXWindowRole else { throw AppError.message("当前窗口无法安全取词。") }
        return ClipboardTextContext(element: element, window: window, pid: pid, title: AccessibleText.attribute(window, kAXTitleAttribute) ?? "", revision: TextInteraction.revision)
    }
    static func validate(_ expected: ClipboardTextContext) throws {
        guard AccessibleText.trusted, !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == expected.pid,
              TextInteraction.revision == expected.revision else { throw TextReplacementError.changed }
        let app = AXUIElementCreateApplication(expected.pid)
        guard let window: AXUIElement = AccessibleText.attribute(app, kAXFocusedWindowAttribute), CFEqual(window, expected.window),
              (AccessibleText.attribute(window, kAXTitleAttribute) as String? ?? "") == expected.title,
              let element: AXUIElement = AccessibleText.attribute(app, kAXFocusedUIElementAttribute), CFEqual(element, expected.element), !AccessibleText.isSecure(element) else { throw TextReplacementError.changed }
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
                guard !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.string.utf8.count <= 60_000 else { throw AppError.message("未复制到有效文字，或选区超过 60 KB。") }
                return text
            }
        }
        throw AppError.message("此控件未提供可复制文字；图片和扫描件不参与翻译。")
    }
    static func prefix(_ context: ClipboardTextContext, collapse: Bool) async throws -> NSAttributedString {
        try await TextInputGate.run(pid: context.pid) { try await protectedPrefix(context, collapse: collapse) }
    }
    private static func protectedPrefix(_ context: ClipboardTextContext, collapse: Bool) async throws -> NSAttributedString {
        try validate(context)
        let originalRange = AccessibleText.selectedRange(context.element)
        OfficeText.key(123, flags: [.maskCommand, .maskShift], to: context.pid)
        do {
            await OfficeText.pause(0.04)
            let copied = try await copy(context)
            try TextInputGate.check()
            guard TextCompatibilityRules.isSingleTextLine(copied.string) else { throw AppError.message("此编辑器无法安全定位当前行，请使用划词翻译。") }
            if collapse { await restoreCaret(context, original: originalRange) }
            return copied
        } catch {
            await restoreCaret(context, original: originalRange)
            throw error
        }
    }
    private static func restoreCaret(_ context: ClipboardTextContext, original: NSRange?) async {
        guard (try? validate(context)) != nil else { return }
        if let original {
            var range = CFRange(location: original.location, length: original.length)
            if let value = AXValueCreate(.cfRange, &range), AXUIElementSetAttributeValue(context.element, kAXSelectedTextRangeAttribute as CFString, value) == .success { return }
        }
        OfficeText.key(124, to: context.pid)
        await OfficeText.pause(0.04)
    }
    private static func snapshot(_ context: ClipboardTextContext, text: NSAttributedString, settings: AppSettings, input: Bool) -> TextSnapshot {
        let point = NSEvent.mouseLocation
        let state = ClipboardTextSnapshot(context: context, text: text, anchor: NSRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16))
        return TextSnapshot(element: context.element, pid: context.pid, value: text.string, range: NSRange(location: 0, length: text.length), source: input ? text.string.trimmingCharacters(in: .whitespacesAndNewlines) : text.string, fullValue: nil, triggerSpaceCount: settings.spaceCount, clipboard: state)
    }
    static func selected(settings: AppSettings) async throws -> TextSnapshot {
        let context = try context(settings: settings)
        let role: String = AccessibleText.attribute(context.element, kAXRoleAttribute) ?? ""
        guard !["AXButton", "AXMenuItem", "AXToolbar", "AXSlider", "AXScrollBar", "AXImage", "AXBrowser"].contains(role) else { throw AppError.message("当前焦点不在可取词的正文中。") }
        return snapshot(context, text: try await copy(context), settings: settings, input: false)
    }
    static func input(settings: AppSettings) async throws -> TextSnapshot {
        let context = try context(settings: settings)
        let role: String = AccessibleText.attribute(context.element, kAXRoleAttribute) ?? ""
        guard TextCompatibilityRules.permitsLineFallback(role: role, editable: AccessibleText.canEdit(context.element), enabled: AccessibleText.attribute(context.element, kAXEnabledAttribute), secure: AccessibleText.isSecure(context.element)) else { throw AppError.message("当前控件未提供安全的编辑能力，请改用划词翻译。") }
        let text = try await prefix(context, collapse: true)
        // Reject mixed font/weight before using the translation service.
        if text.attribute(.font, at: 0, effectiveRange: nil) is NSFont { _ = try RichTextReplacement.translated("Local format check", preserving: text, removingTriggerSpaces: false) }
        return snapshot(context, text: text, settings: settings, input: true)
    }
    static func replace(_ snapshot: TextSnapshot, with text: String) async throws -> TextSnapshot {
        try await TextInputGate.run(pid: snapshot.pid) { try await protectedReplace(snapshot, with: text) }
    }
    private static func protectedReplace(_ snapshot: TextSnapshot, with text: String) async throws -> TextSnapshot {
        guard let state = snapshot.clipboard else { throw TextReplacementError.invalidRange }
        let context = state.context
        try validate(context)
        let current = try await prefix(context, collapse: false)
        var selected = true
        defer { if selected, (try? validate(context)) != nil { OfficeText.key(124, to: context.pid) } }
        guard OfficeTextRules.samePrefix(current.string, state.text.string) else { throw TextReplacementError.changed }
        let output: String
        if let original = snapshot.richRestoration, original.string == text { output = text }
        else { output = try TextCompatibilityRules.replacingLine(current.string, with: text, triggerSpaces: snapshot.triggerSpaceCount) }
        try Task.checkCancellation()
        try TextInputGate.check()
        try await paste(output, context: context)
        selected = false
        let verified = try await prefix(context, collapse: true)
        guard OfficeTextRules.samePrefix(verified.string, output) else { throw AppError.message("此编辑器未完成回填，译文已保留。") }
        if let old = current.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
            guard let new = verified.attribute(.font, at: 0, effectiveRange: nil) as? NSFont,
                  abs(old.pointSize - new.pointSize) < 0.1,
                  old.fontDescriptor.symbolicTraits.intersection([.bold, .italic]) == new.fontDescriptor.symbolicTraits.intersection([.bold, .italic]) else {
                let beforeRecovery = try await prefix(context, collapse: false)
                guard OfficeTextRules.samePrefix(beforeRecovery.string, output) else { OfficeText.key(124, to: context.pid); throw TextReplacementError.changed }
                try await paste(current.string, context: context)
                _ = try await prefix(context, collapse: true)
                throw AppError.message("此编辑器未保留文字样式，已恢复原文。")
            }
        }
        let undoState = ClipboardTextSnapshot(context: context, text: verified, anchor: state.anchor)
        return TextSnapshot(element: context.element, pid: context.pid, value: verified.string, range: NSRange(location: 0, length: verified.length), source: current.string, fullValue: nil, richRestoration: current, triggerSpaceCount: snapshot.triggerSpaceCount, clipboard: undoState)
    }
    private static func paste(_ text: String, context: ClipboardTextContext) async throws {
        try validate(context)
        let transaction = TemporaryClipboard(text: text)
        defer { transaction.restore() }
        OfficeText.key(9, flags: .maskCommand, to: context.pid)
        await OfficeText.pause(0.15)
        try validate(context)
    }
}
