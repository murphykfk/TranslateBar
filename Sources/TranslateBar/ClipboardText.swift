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
    var microsoftDocument: MicrosoftTextRules.Document?
    var documentPasteCommand: AXUIElement?
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
            if expected.microsoftDocument == .excel {
                let editor = MicrosoftText.excelEditingElement(pid: expected.pid)
                let value = editor.flatMap { AccessibleText.textValue($0) }
                ReplacementDiagnostics.note("excel_edit_state", ["editor": editor == nil ? 0 : 1,
                    "same": editor.map { CFEqual(element, $0) ? 1 : 0 } ?? 0,
                    "text": value.map { MicrosoftTextRules.permitsExcelText($0) ? 1 : 0 } ?? -1])
                guard let editor, CFEqual(element, editor), let value, MicrosoftTextRules.permitsExcelText(value) else {
                    ReplacementDiagnostics.fail("excel_text_edit_unverified")
                    throw AppError.message("请进入 Excel 文本单元格的编辑状态后重试；公式不参与输入翻译。原文未改动。")
                }
            }
            if expected.documentPasteCommand != nil {
                // Paste can be disabled solely because the user's clipboard
                // is empty. Check its actual state after staging paste data.
                guard MicrosoftTextRules.permitsBody(bundleID: NSRunningApplication(processIdentifier: expected.pid)?.bundleIdentifier ?? "",
                    role: AccessibleText.attribute(element, kAXRoleAttribute) ?? "",
                    secure: AccessibleText.isSecure(element), modal: AccessibleText.attribute(window, kAXModalAttribute) ?? false) else { throw TextReplacementError.changed }
            }
        }
    }
    static func copy(_ context: ClipboardTextContext, allowingWhitespace: Bool = false) async throws -> NSAttributedString {
        try validate(context)
        let transaction = TemporaryClipboard(text: "TranslateBar copy \(UUID().uuidString)")
        defer { transaction.restore() }
        OfficeText.key(8, flags: .maskCommand, to: context.pid)
        for _ in 0..<15 {
            await OfficeText.pause(0.035)
            try validate(context)
            try Task.checkCancellation()
            if let text = transaction.takeCopiedRichText() {
                guard (allowingWhitespace ? !text.string.isEmpty : !text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), text.string.utf8.count <= 60_000 else {
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
    static func prefix(_ context: ClipboardTextContext, collapse: Bool) async throws -> NSAttributedString {
        try await TextInputGate.run(pid: context.pid) { try await protectedPrefix(context, collapse: collapse) }
    }
    private static func protectedPrefix(_ context: ClipboardTextContext, collapse: Bool) async throws -> NSAttributedString {
        try validate(context)
        let originalRange = context.microsoftDocument != nil
            ? TextFocus.resolve(pid: context.pid).flatMap { AccessibleText.selectedRange($0) }
            : AccessibleText.selectedRange(context.element)
        var selectionPending = true
        do {
            let copied = try await selectPrefix(context)
            try TextInputGate.check()
            if context.windowOnlyFocus || context.documentPasteCommand != nil {
                await restoreCaret(context, original: originalRange)
                selectionPending = false
                try await verifyCaret(context, line: copied.string)
                ReplacementDiagnostics.note(context.microsoftDocument.map { "\($0.diagnosticPrefix)_caret_verified" } ?? "wechat_caret_verified")
                if !collapse {
                    selectionPending = true
                    let selected = try await selectPrefix(context)
                    guard selected.string == copied.string else { throw TextReplacementError.changed }
                }
            }
            if collapse && selectionPending { await restoreCaret(context, original: originalRange) }
            return copied
        } catch {
            if selectionPending { await restoreCaret(context, original: originalRange) }
            throw error
        }
    }
    private static func selectPrefix(_ context: ClipboardTextContext) async throws -> NSAttributedString {
        let originalCaret = TextFocus.resolve(pid: context.pid).flatMap { AccessibleText.selectedRange($0) }
        let modifier: CGEventFlags = context.microsoftDocument.map {
            MicrosoftTextRules.paragraphModifier(for: $0) == .command ? .maskCommand : .maskAlternate
        } ?? .maskCommand
        if context.microsoftDocument == .excel {
            OfficeText.key(115, flags: .maskShift, to: context.pid) // Shift-Home; Command-Left selects a word in Excel.
        } else {
            OfficeText.key(context.documentPasteCommand == nil ? 123 : 126, flags: [modifier, .maskShift], to: context.pid)
        }
        await OfficeText.pause(0.04)
        var copied = try await copy(context)
        if context.microsoftDocument == .powerPoint {
            let selected = TextFocus.resolve(pid: context.pid).flatMap { AccessibleText.selectedRange($0) }
            ReplacementDiagnostics.note("powerpoint_selection_bounds", ["caret": originalCaret?.location ?? -1, "caret_selection": originalCaret?.length ?? -1,
                "start": selected?.location ?? -1, "length": selected?.length ?? -1, "copied": copied.length])
        }
        if context.microsoftDocument == .powerPoint, let originalCaret,
           let focused = TextFocus.resolve(pid: context.pid), let value = AccessibleText.textValue(focused),
           let selection = AccessibleText.selectedRange(focused),
           let range = MicrosoftTextRules.powerPointPrefixRange(value: value, caret: originalCaret, selection: selection, copied: copied.string) {
            let expected = (value as NSString).substring(with: range)
            if originalCaret.location < value.utf16.count {
                // With a following paragraph, the shortcut really includes its
                // mark. Rebuild a bounded text selection from the proven caret;
                // PowerPoint's AX range setter cannot reliably do this.
                guard expected.count <= WordTextRules.maximumSelectionSteps else {
                    ReplacementDiagnostics.fail("powerpoint_selection_limit")
                    throw AppError.message("PowerPoint 当前段落过长，无法安全定位，请改用划词翻译。原文未改动。")
                }
                OfficeText.key(124, to: context.pid)
                OfficeText.key(123, to: context.pid)
                for index in 0..<expected.count {
                    if index % 16 == 0 { try validate(context); try TextInputGate.check(); try Task.checkCancellation() }
                    OfficeText.key(123, flags: .maskShift, to: context.pid)
                    if index % 16 == 15 { await OfficeText.pause(0.01) }
                }
                await OfficeText.pause(0.04)
                copied = try await copy(context)
                guard AccessibleText.selectedRange(focused) == range else { throw TextReplacementError.changed }
            }
            guard let matched = ClipboardRichText.matching(expected, rich: copied) else { throw TextReplacementError.changed }
            copied = matched
        }
        if context.microsoftDocument == .word,
           let focused = TextFocus.resolve(pid: context.pid),
           let value = AccessibleText.textValue(focused), let range = AccessibleText.selectedRange(focused),
           let trimmedRange = MicrosoftTextRules.wordSelectionWithoutParagraphMark(value: value, range: range, copied: copied.string)
                ?? originalCaret.flatMap({ MicrosoftTextRules.powerPointPrefixRange(value: value, caret: $0, selection: range, copied: copied.string) }) {
            // Word's paragraph shortcut can select the next paragraph mark
            // while plain-text Copy omits it. Exclude that proven mark before
            // collapsing or pasting, so the next paragraph is never joined.
            var trimmed = CFRange(location: trimmedRange.location, length: trimmedRange.length)
            guard let parameter = AXValueCreate(.cfRange, &trimmed),
                  AXUIElementSetAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, parameter) == .success else { throw TextReplacementError.changed }
            await OfficeText.pause(0.04)
            let verified = try await copy(context)
            let expected = (value as NSString).substring(with: trimmedRange)
            guard let matched = ClipboardRichText.matching(expected, rich: verified),
                  AccessibleText.selectedRange(focused) == NSRange(location: trimmed.location, length: trimmed.length) else { throw TextReplacementError.changed }
            copied = matched
        }
        if let document = context.microsoftDocument {
            let selection: WordTextRules.PrefixSelection
            do { selection = try WordTextRules.prefixSelection(in: copied.string) }
            catch {
                ReplacementDiagnostics.fail("\(document.diagnosticPrefix)_paragraph_structure")
                throw AppError.message("\(document.name) 当前段落包含无法可靠定位的结构，请改用划词翻译。原文未改动。")
            }
            let expected = copied.attributedSubstring(from: selection.range)
            let key: CGKeyCode, count: Int
            switch selection.adjustment {
            case .none: key = 124; count = 0
            case .moveStartRight(let steps): key = 124; count = steps
            case .selectFromCaretLeft(let steps): OfficeText.key(124, to: context.pid); key = 123; count = steps
            }
            if count > 0 {
                for index in 0..<count {
                    if index % 16 == 0 { try validate(context) }
                    try TextInputGate.check(); try Task.checkCancellation()
                    OfficeText.key(key, flags: .maskShift, to: context.pid)
                    if index % 16 == 15 { await OfficeText.pause(0.01) }
                }
                await OfficeText.pause(0.04)
                copied = try await copy(context)
                guard copied.string == expected.string else { throw TextReplacementError.changed }
            }
            try MicrosoftText.validateSelectedInput(context)
            ReplacementDiagnostics.note("\(document.diagnosticPrefix)_prefix_verified", ["length": copied.length, "selection_steps": count])
        }
        guard TextCompatibilityRules.isSingleTextLine(copied.string) else { throw AppError.message("此编辑器无法安全定位当前段落，请使用划词翻译。") }
        return copied
    }
    static func verifyCaret(_ context: ClipboardTextContext, line: String) async throws {
        try await TextInputGate.run(pid: context.pid) {
            try validate(context)
            let original = context.microsoftDocument != nil
                ? TextFocus.resolve(pid: context.pid).flatMap { AccessibleText.selectedRange($0) }
                : AccessibleText.selectedRange(context.element)
            OfficeText.key(123, flags: .maskShift, to: context.pid)
            var character: NSAttributedString
            do {
                await OfficeText.pause(0.04)
                character = try await copy(context, allowingWhitespace: true)
                if context.microsoftDocument == .powerPoint, let original,
                   let focused = TextFocus.resolve(pid: context.pid), let value = AccessibleText.textValue(focused),
                   let selection = AccessibleText.selectedRange(focused),
                   let range = MicrosoftTextRules.powerPointPrefixRange(value: value, caret: original, selection: selection, copied: character.string),
                   let matched = ClipboardRichText.matching((value as NSString).substring(with: range), rich: character) { character = matched }
            } catch {
                await restoreCaret(context, original: original)
                throw error
            }
            await restoreCaret(context, original: original)
            guard ChatDraftCompatibility.matchesCaretProbe(line: line, selectedCharacter: character.string) else {
                ReplacementDiagnostics.fail("chat_caret_not_verified")
                throw AppError.message("未确认当前焦点位于文字输入区，原文未改动。")
            }
        }
    }
    private static func restoreCaret(_ context: ClipboardTextContext, original: NSRange?) async {
        guard (try? validate(context)) != nil else { return }
        if context.microsoftDocument == .powerPoint, let original, original.length == 0,
           let focused = TextFocus.resolve(pid: context.pid), let value = AccessibleText.textValue(focused),
           let selected = AccessibleText.selectedRange(focused), selected.length > 0,
           NSMaxRange(selected) == original.location + 1, original.location < value.utf16.count,
           let boundary = Range(NSRange(location: original.location, length: 1), in: value), value[boundary].allSatisfy(\.isNewline) {
            OfficeText.key(124, to: context.pid)
            OfficeText.key(123, to: context.pid)
            await OfficeText.pause(0.04)
            return
        }
        if let original, context.microsoftDocument != .powerPoint {
            var range = CFRange(location: original.location, length: original.length)
            let element = context.microsoftDocument != nil ? TextFocus.resolve(pid: context.pid) ?? context.element : context.element
            if let value = AXValueCreate(.cfRange, &range), AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success {
                await OfficeText.pause(0.04)
                return
            }
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
        var context = try context(settings: settings)
        let role: String = AccessibleText.attribute(context.element, kAXRoleAttribute) ?? ""
        let bundle = NSRunningApplication(processIdentifier: context.pid)?.bundleIdentifier ?? ""
        if let document = MicrosoftTextRules.document(bundleID: bundle), MicrosoftTextRules.usesDocumentFallback(bundleID: bundle, role: role) {
            guard settings.enhancedCompatibility else { throw AppError.message("请开启“增强取词与回填兼容”，以使用 \(document.name) 文字输入翻译。") }
            context.microsoftDocument = document
            context.documentPasteCommand = try await MicrosoftText.prepareInput(context, document: document)
        }
        guard context.windowOnlyFocus || context.documentPasteCommand != nil || TextCompatibilityRules.permitsLineFallback(role: role, editable: AccessibleText.canEdit(context.element), enabled: AccessibleText.attribute(context.element, kAXEnabledAttribute), secure: AccessibleText.isSecure(context.element)) else {
            ReplacementDiagnostics.fail("clipboard_edit_capability_unavailable")
            throw AppError.message("当前控件未提供安全的编辑能力，请改用划词翻译。")
        }
        let text = try await prefix(context, collapse: true)
        if context.windowOnlyFocus {
            guard ChatDraftCompatibility.containsTrigger(text.string, spaces: settings.spaceCount) else {
                ReplacementDiagnostics.fail("chat_trigger_not_verified")
                throw AppError.message("未确认微信输入草稿，请在聊天输入框完成文字后，按设置次数连续空格。原文未改动。")
            }
        }
        if let document = context.microsoftDocument {
            guard ChatDraftCompatibility.containsTrigger(text.string, spaces: settings.spaceCount) else {
                ReplacementDiagnostics.fail("\(document.diagnosticPrefix)_trigger_not_verified")
                throw AppError.message("未确认 \(document.name) 当前输入段落，请在句末按设置次数连续空格。原文未改动。")
            }
            // Excel's live text editor copies plain text only; plain-text paste
            // edits the cell contents while Excel retains its cell formatting.
            guard document == .excel || (text.length > 0 && text.attribute(.font, at: 0, effectiveRange: nil) is NSFont) else {
                ReplacementDiagnostics.fail("\(document.diagnosticPrefix)_font_unavailable")
                throw AppError.message("\(document.name) 未提供可核实的字号与粗细，原文未改动。请改用划词翻译。")
            }
        }
        // Reject mixed font/weight before using the translation service.
        if text.attribute(.font, at: 0, effectiveRange: nil) is NSFont {
            do { _ = try RichTextReplacement.translated("Local format check", preserving: text, removingTriggerSpaces: false) }
            catch {
                if let document = context.microsoftDocument {
                    ReplacementDiagnostics.fail("\(document.diagnosticPrefix)_mixed_format")
                    throw AppError.message("\(document.name) 当前段落的混合格式无法安全保留，原文未改动。请改用划词翻译。")
                }
                throw error
            }
        }
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
        let rawOutput: String
        if let original = snapshot.richRestoration, original.string == text { rawOutput = text }
        else { rawOutput = try TextCompatibilityRules.replacingLine(current.string, with: text, triggerSpaces: snapshot.triggerSpaceCount) }
        let output = context.microsoftDocument == .powerPoint ? MicrosoftTextRules.powerPointPasteText(rawOutput) : rawOutput
        guard context.microsoftDocument != .excel || MicrosoftTextRules.permitsExcelText(output) else {
            throw AppError.message("译文以公式符号开头，未写入 Excel，请使用划词翻译并手动确认。")
        }
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
                try await paste(context.microsoftDocument == .powerPoint ? MicrosoftTextRules.powerPointPasteText(current.string) : current.string, context: context)
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
        if context.documentPasteCommand != nil {
            guard try await MicrosoftText.enabledPaste(context, transaction: transaction, text: text) != nil else {
                if let document = context.microsoftDocument { ReplacementDiagnostics.fail("\(document.diagnosticPrefix)_replacement_paste_unavailable") }
                throw AppError.message("\(context.microsoftDocument?.name ?? "当前编辑器") 已不允许粘贴，原文未改动，译文已保留。")
            }
        }
        OfficeText.key(9, flags: .maskCommand, to: context.pid)
        await OfficeText.pause(0.15)
        try validate(context)
    }
}
