import AppKit
import ApplicationServices
import Carbon
import TranslateCore

@MainActor enum TextInteraction {
    enum Kind: String { case keyboard, space, repeatingSpace, navigation, command, pointer, scroll, replay, other }
    static var revision: UInt64 = 0
    static var lastKind: Kind = .other
    static func changed(_ kind: Kind = .other) { revision &+= 1; lastKind = kind }
}

struct OfficeContext {
    let pid: pid_t
    let window: AXUIElement
    let title: String
    let revision: UInt64
}

struct OfficeSnapshot {
    let context: OfficeContext
    let raw: String
    let rich: NSAttributedString
    let anchor: NSRect
}

@MainActor enum OfficeText {
    static let bundleID = "com.kingsoft.wpsoffice.mac"
    static var lastCopyMetadata: [String: Any] = [:]
    private static var collectCopyMetadata = false
    static func context() throws -> OfficeContext {
        guard AccessibleText.trusted, !IsSecureEventInputEnabled(),
              let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundleID else { throw AppError.message("WPS 文档焦点已变化，已跳过。") }
        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.35)
        guard let window: AXUIElement = AccessibleText.attribute(application, kAXFocusedWindowAttribute),
              let role: String = AccessibleText.attribute(window, kAXRoleAttribute), role == kAXWindowRole,
              let title: String = AccessibleText.attribute(window, kAXTitleAttribute), !title.isEmpty else { throw AppError.message("请先将光标放到 WPS 文档正文。") }
        if let focused: AXUIElement = AccessibleText.attribute(application, kAXFocusedUIElementAttribute) {
            let role: String = AccessibleText.attribute(focused, kAXRoleAttribute) ?? ""
            let subrole: String = AccessibleText.attribute(focused, kAXSubroleAttribute) ?? ""
            guard subrole != kAXSecureTextFieldSubrole, ![kAXTextFieldRole, kAXComboBoxRole, kAXButtonRole, kAXMenuItemRole].contains(role) else { throw AppError.message("当前焦点在 WPS 工具栏或对话框，请回到文档正文。") }
        }
        return OfficeContext(pid: app.processIdentifier, window: window, title: title, revision: TextInteraction.revision)
    }
    static func validate(_ expected: OfficeContext) throws {
        let current = try context()
        guard current.pid == expected.pid, CFEqual(current.window, expected.window), current.title == expected.title,
              current.revision == expected.revision else { throw TextReplacementError.changed }
    }
    static func key(_ code: CGKeyCode, flags: CGEventFlags = [], to pid: pid_t) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            // Qt needs the function/numeric-pad bits to recognize bare arrows.
            event?.flags = (123...126).contains(code) ? flags.union([.maskSecondaryFn, .maskNumericPad]) : flags
            event?.setIntegerValueField(.eventSourceUserData, value: InputMonitor.syntheticTag)
            event?.postToPid(pid)
        }
    }
    static func pause(_ seconds: Double) async {
        await withCheckedContinuation { continuation in DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { continuation.resume() } }
    }
    static func copiedSelection(_ expected: OfficeContext, honorCancellation: Bool = true) async throws -> NSAttributedString {
        try validate(expected)
        let clipboard = TemporaryClipboard(text: "TranslateBar WPS \(UUID().uuidString)")
        defer { clipboard.restore() }
        key(8, flags: .maskCommand, to: expected.pid)
        for _ in 0..<20 {
            await pause(0.035)
            try validate(expected)
            if collectCopyMetadata { lastCopyMetadata = clipboard.copiedMetadata() }
            if let rich = clipboard.takeCopiedRichText() {
                if honorCancellation { try Task.checkCancellation() }
                guard !rich.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, rich.string.utf8.count <= 60_000 else { throw AppError.message("WPS 选区为空或超过 60 KB，请缩小范围。") }
                return rich
            }
        }
        throw AppError.message("WPS 没有提供可复制的文字，请确认选中了正文；图片和扫描件不参与翻译。")
    }
    static func prefix(_ expected: OfficeContext, collapse: Bool, honorCancellation: Bool = true) async throws -> NSAttributedString {
        try await TextInputGate.run(pid: expected.pid) { try await protectedPrefix(expected, collapse: collapse, honorCancellation: honorCancellation) }
    }
    private static func protectedPrefix(_ expected: OfficeContext, collapse: Bool, honorCancellation: Bool) async throws -> NSAttributedString {
        try validate(expected)
        key(126, flags: [.maskCommand, .maskShift], to: expected.pid)
        do {
            await pause(0.05)
            let rich = try await copiedSelection(expected, honorCancellation: honorCancellation)
            try TextInputGate.check()
            guard !rich.string.contains("\n"), !rich.string.contains("\r"), !rich.string.contains("\t"), !rich.string.contains("\u{fffc}") else { throw AppError.message("WPS 无法安全定位单个正文段落，未回填。请将光标放到段末，或改用划词翻译。") }
            if collapse { key(124, to: expected.pid); await pause(0.05); try validate(expected) }
            return rich
        } catch {
            if (try? validate(expected)) != nil { key(124, to: expected.pid); await pause(0.05) }
            throw error
        }
    }
    static func input(settings: AppSettings) async throws -> TextSnapshot {
        let expected = try context()
        let title = expected.title.lowercased()
        guard !title.contains("只读"), !title.contains("read-only"),
              title.hasSuffix(".docx") || title.hasSuffix(".doc") || title.hasSuffix(".rtf") || title.hasPrefix("文字文稿") else { throw AppError.message("WPS 输入兼容目前用于可编辑的文字文档；其他组件请使用划词翻译。") }
        let rich = try await prefix(expected, collapse: true)
        guard rich.length > 0, rich.attribute(.font, at: 0, effectiveRange: nil) is NSFont else { throw RichTextReplacementError.unavailable }
        // Validate the paragraph's font runs before spending API budget.
        _ = try RichTextReplacement.translated("TranslateBar local style check", preserving: rich, removingTriggerSpaces: false)
        try validate(expected)
        let mouse = NSEvent.mouseLocation
        let state = OfficeSnapshot(context: expected, raw: rich.string, rich: rich, anchor: NSRect(x: mouse.x - 8, y: mouse.y - 8, width: 16, height: 16))
        return TextSnapshot(element: expected.window, pid: expected.pid, value: rich.string, range: NSRange(location: 0, length: rich.length), source: rich.string.trimmingCharacters(in: .whitespacesAndNewlines), fullValue: nil, triggerSpaceCount: settings.spaceCount, office: state)
    }
    static func selected(settings: AppSettings) async throws -> TextSnapshot {
        let expected = try context()
        let rich = try await copiedSelection(expected)
        let mouse = NSEvent.mouseLocation
        let state = OfficeSnapshot(context: expected, raw: rich.string, rich: rich, anchor: NSRect(x: mouse.x - 8, y: mouse.y - 8, width: 16, height: 16))
        return TextSnapshot(element: expected.window, pid: expected.pid, value: rich.string, range: NSRange(location: 0, length: rich.length), source: rich.string, fullValue: nil, office: state)
    }
    static func replace(_ snapshot: TextSnapshot, with text: String) async throws -> TextSnapshot {
        try await TextInputGate.run(pid: snapshot.pid) { try await protectedReplace(snapshot, with: text) }
    }
    private static func protectedReplace(_ snapshot: TextSnapshot, with text: String) async throws -> TextSnapshot {
        guard let state = snapshot.office else { throw TextReplacementError.invalidRange }
        try validate(state.context)
        let current = try await prefix(state.context, collapse: false)
        var selectionOpen = true
        defer { if selectionOpen, (try? validate(state.context)) != nil { key(124, to: state.context.pid) } }
        guard OfficeTextRules.samePrefix(current.string, state.raw) else { throw TextReplacementError.changed }
        let formatted: NSAttributedString
        if let original = snapshot.richRestoration, original.string == text { formatted = original }
        else { formatted = try RichTextReplacement.translated(text, preserving: current, removingTriggerSpaces: true, triggerSpaceCount: snapshot.triggerSpaceCount) }
        try Task.checkCancellation()
        try TextInputGate.check()
        try validate(state.context)
        try await paste(formatted, in: state.context)
        selectionOpen = false
        let verified = try await prefix(state.context, collapse: true, honorCancellation: false)
        guard OfficeTextRules.samePrefix(verified.string, formatted.string) else { throw AppError.message("WPS 未完成回填，请检查当前段落；译文已保留。") }
        let oldFont = current.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let newFont = verified.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let styleMatches: Bool
        if let oldFont, let newFont { styleMatches = abs(oldFont.pointSize - newFont.pointSize) < 0.1 && oldFont.fontDescriptor.symbolicTraits.intersection([.bold, .italic]) == newFont.fontDescriptor.symbolicTraits.intersection([.bold, .italic]) }
        else { styleMatches = false }
        if !styleMatches {
            // The just-verified translated prefix is the only range eligible for recovery.
            let beforeRecovery = try await prefix(state.context, collapse: false, honorCancellation: false)
            guard OfficeTextRules.samePrefix(beforeRecovery.string, formatted.string) else { key(124, to: state.context.pid); throw TextReplacementError.changed }
            try await paste(current, in: state.context)
            _ = try await prefix(state.context, collapse: true, honorCancellation: false)
            throw AppError.message("WPS 未保留原字号或粗细，已恢复原文，译文保留在浮窗中。")
        }
        let undoState = OfficeSnapshot(context: state.context, raw: verified.string, rich: verified, anchor: state.anchor)
        return TextSnapshot(element: state.context.window, pid: state.context.pid, value: verified.string, range: NSRange(location: 0, length: verified.length), source: current.string, fullValue: nil, richRestoration: current, triggerSpaceCount: snapshot.triggerSpaceCount, office: undoState)
    }
    static func paste(_ rich: NSAttributedString, in context: OfficeContext) async throws {
        try validate(context)
        // WPS imports macOS RTF as a complete paragraph and appends a break.
        // Plain insertion inherits the uniformly validated selected text style.
        let clipboard = TemporaryClipboard(text: rich.string)
        defer { clipboard.restore() }
        key(9, flags: .maskCommand, to: context.pid)
        await pause(0.15)
        try validate(context)
    }
    static func diagnostics() {
        var report: [String: Any] = ["frontmost_is_wps": NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID]
        if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier == bundleID {
            let application = AXUIElementCreateApplication(app.processIdentifier)
            if let focused: AXUIElement = AccessibleText.attribute(application, kAXFocusedUIElementAttribute) {
                report["focused_role"] = AccessibleText.attribute(focused, kAXRoleAttribute) as String? ?? "unknown"
                var names: CFArray?
                AXUIElementCopyAttributeNames(focused, &names)
                report["focused_attributes"] = names as? [String] ?? []
            } else { report["focused_role"] = "unavailable" }
            if let window: AXUIElement = AccessibleText.attribute(application, kAXFocusedWindowAttribute) {
                report["fixture_window"] = (AccessibleText.attribute(window, kAXTitleAttribute) as String? ?? "").contains("TranslateBar-WPS-Test")
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { Swift.print(String(decoding: data, as: UTF8.self)) }
    }
    static func readSmokeTest() async {
        collectCopyMetadata = true
        defer { collectCopyMetadata = false; lastCopyMetadata = [:] }
        var report: [String: Any] = ["success": false]
        do {
            let expected = try context()
            guard expected.title.contains("TranslateBar-WPS-Test") else { throw AppError.message("仅允许已知临时测试文档。") }
            let text = try await copiedSelection(expected)
            report["known_fixture_selected"] = text.string.contains("The meeting starts at ten tomorrow morning.")
            report["characters"] = text.length
            report["ends_with_newline"] = text.string.hasSuffix("\n") || text.string.hasSuffix("\r")
            let font = text.length > 0 ? text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont : nil
            report["font_size"] = font?.pointSize ?? -1
            report["bold"] = font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
            report["success"] = report["known_fixture_selected"] as? Bool == true
        } catch { report["error"] = error.localizedDescription }
        report["copy_metadata"] = lastCopyMetadata
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/wps-read-smoke-report.json"))
            Swift.print(String(decoding: data, as: UTF8.self))
        }
    }
}
