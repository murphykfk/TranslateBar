import AppKit
import Carbon
import TranslateCore

struct CopiedParagraph {
    let plain: String
    let rich: NSAttributedString?
    let attachments: Bool
}

struct ParagraphContext {
    let pid: pid_t
    let window: AXUIElement?
    /// Nil when the app does not report a focused element.
    let focus: AXUIElement?
    let key: ParagraphSelectionKey
    let revision: UInt64
}

struct ParagraphSnapshot {
    let context: ParagraphContext
    /// The paragraph from its start up to the caret, trigger spaces included.
    let copied: CopiedParagraph
    let draft: ParagraphDraft
    let anchor: NSRect?
}

struct ParagraphUndo {
    let context: ParagraphContext
    let current: CopiedParagraph
    let original: CopiedParagraph
    /// The editor did not give the pasted text the paragraph's font size or weight.
    let formatChanged: Bool
}

/// Input translation that works the same way in every editor: select from
/// the caret back to the start of its paragraph, copy, and after translating
/// select the same text again and paste the translation as plain text.
/// Pasted plain text takes the formatting at the selection, so a formatted
/// field keeps its format and a plain field stays plain.
///
/// The selection is set through accessibility when the editor exposes its
/// text and caret, and made with the editor's own shortcut otherwise. Either
/// way the copied text is the proof: it must end with the trigger spaces
/// before anything is written, and must read back as the translation after.
@MainActor enum ParagraphText {
    private struct Location {
        let window: AXUIElement?
        let focus: AXUIElement?
        /// The focus or an ancestor that exposes its text and caret.
        let text: AXUIElement?
    }
    private enum Method {
        case accessibility(AXUIElement, end: NSRange)
        case keyboard(AXUIElement?)
    }
    private struct Selection {
        let copied: CopiedParagraph
        let method: Method
    }
    private struct Style: Equatable {
        let size: CGFloat
        let traits: NSFontDescriptor.SymbolicTraits
    }
    /// Lets the smoke test exercise the keyboard path in an editor that also
    /// supports accessibility selection.
    static var allowsAccessibilitySelection = true

    static func capture(settings: AppSettings) async throws -> ParagraphSnapshot {
        let owner = try AccessibleText.activeApplication(settings: settings)
        let pid = owner.processIdentifier
        let location = locate(pid, wake: true)
        if let focus = location.focus {
            guard !AccessibleText.isSecure(focus) else { throw AppError.message("密码输入框不参与翻译。") }
            guard ParagraphDraft.permitsFocusRole(AccessibleText.attribute(focus, kAXRoleAttribute) ?? "") else {
                ReplacementDiagnostics.fail("paragraph_focus_role")
                throw AppError.message("当前焦点不在文字输入区，已跳过。")
            }
        }
        ReplacementDiagnostics.note("paragraph_context", ["window": location.window == nil ? 0 : 1,
            "focus": location.focus == nil ? 0 : 1, "text": location.text == nil ? 0 : 1])
        let context = ParagraphContext(pid: pid, window: location.window, focus: location.focus,
                                       key: .forApplication(owner.bundleIdentifier ?? ""), revision: TextInteraction.editRevision)
        let copied = try await TextInputGate.run(pid: pid) { try await select(context, keep: false, checkFocus: false).copied }
        do {
            guard !copied.attachments else { throw ParagraphDraftError.embeddedObject }
            let draft = try ParagraphDraft(copied: copied.plain, triggerSpaces: settings.spaceCount)
            return ParagraphSnapshot(context: context, copied: copied, draft: draft, anchor: anchor(pid))
        } catch let error as ParagraphDraftError {
            ReplacementDiagnostics.fail("paragraph_\(error)")
            throw error
        }
    }

    static func replace(_ snapshot: ParagraphSnapshot, with translation: String) async throws -> ParagraphUndo {
        ReplacementDiagnostics.note("paragraph_replace", ["rich": snapshot.copied.rich == nil ? 0 : 1])
        do {
            let written = try await write(snapshot.draft.replacement(translation), over: snapshot.copied, in: snapshot.context)
            let offset = snapshot.draft.leading.utf16.count
            let before = style(snapshot.copied.rich, at: offset), after = style(written.rich, at: offset)
            let formatChanged = before != nil && after != nil && before != after
            if formatChanged { ReplacementDiagnostics.note("paragraph_format_changed") }
            ReplacementDiagnostics.finish(success: true)
            return ParagraphUndo(context: refreshed(snapshot.context), current: written, original: snapshot.copied, formatChanged: formatChanged)
        } catch { ReplacementDiagnostics.finish(success: false); throw error }
    }

    static func undo(_ undo: ParagraphUndo) async throws {
        ReplacementDiagnostics.beginCapture()
        do {
            _ = try await write(undo.original.plain, over: undo.current, in: undo.context)
            ReplacementDiagnostics.finish(success: true)
        } catch { ReplacementDiagnostics.finish(success: false); throw error }
    }

    /// Replaces the paragraph prefix, which must still read `expected`, and
    /// returns what the editor holds there afterwards.
    private static func write(_ output: String, over expected: CopiedParagraph, in context: ParagraphContext) async throws -> CopiedParagraph {
        var pasted = false
        do {
            return try await TextInputGate.run(pid: context.pid) {
                let selection = try await select(context, keep: true, checkFocus: true)
                do {
                    guard ParagraphDraft.sameText(selection.copied.plain, expected.plain) else {
                        ReplacementDiagnostics.fail("paragraph_changed")
                        throw TextReplacementError.changed
                    }
                    try Task.checkCancellation()
                    try TextInputGate.check()
                    try await paste(output, context: context)
                    pasted = true
                } catch {
                    if !pasted { await dismiss(selection, context: context) }
                    throw error
                }
                let written = try await select(context, keep: false, checkFocus: false).copied
                guard ParagraphDraft.sameText(written.plain, output) else {
                    if ParagraphDraft.sameText(written.plain, expected.plain) {
                        ReplacementDiagnostics.fail("paragraph_paste_ignored")
                        throw AppError.message("此输入框没有接受粘贴，原文未改动。")
                    }
                    ReplacementDiagnostics.fail("paragraph_paste_unverified")
                    throw AppError.message("回填结果与译文不一致，请检查当前段落；可在该应用中撤销（⌘Z）。")
                }
                return written
            }
        } catch let error where pasted && !(error is AppError) {
            ReplacementDiagnostics.note("paragraph_unverified_after_paste")
            throw AppError.message("译文已写入，但未能读回核对；如有问题可在该应用中撤销（⌘Z）。")
        }
    }

    /// Selects from the start of the caret's paragraph up to the caret and
    /// copies it. Unless `keep` is set, the caret is put back afterwards.
    private static func select(_ context: ParagraphContext, keep: Bool, checkFocus: Bool) async throws -> Selection {
        let location = try validate(context, checkFocus: checkFocus)
        try TextInputGate.check()
        if allowsAccessibilitySelection, let text = location.text, !hasWebBlocks(text),
           let selection = try await selectWithAccessibility(text, context: context, keep: keep) { return selection }
        let caret = location.text.flatMap { AccessibleText.selectedRange($0) }
        sendSelectionKey(context.key, to: context.pid)
        await OfficeText.pause(0.05)
        do {
            if let text = location.text, let caret, let selected = AccessibleText.selectedRange(text), NSMaxRange(selected) != NSMaxRange(caret) {
                // The shortcut also took the paragraph mark after the caret;
                // pasting over it would join the next paragraph.
                ReplacementDiagnostics.fail("paragraph_selection_past_caret")
                throw AppError.message("此编辑器的段落选区越过了光标，无法安全定位，原文未改动。")
            }
            let copied = try await copy(context)
            try TextInputGate.check()
            let selection = Selection(copied: copied, method: .keyboard(location.text))
            if !keep { await dismiss(selection, context: context) }
            return selection
        } catch {
            await collapse(context, text: location.text)
            throw error
        }
    }

    /// Returns nil, with the caret where it was, when the editor cannot set
    /// the selection or its offsets do not match what it then selects.
    private static func selectWithAccessibility(_ element: AXUIElement, context: ParagraphContext, keep: Bool) async throws -> Selection? {
        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextRangeAttribute as CFString, &settable) == .success, settable.boolValue,
              let value = AccessibleText.textValue(element), let caret = AccessibleText.selectedRange(element), caret.length == 0 else { return nil }
        let range = ParagraphDraft.prefixRange(in: value, caret: caret.location)
        guard range.length > 0, set(range, on: element) else { return nil }
        await OfficeText.pause(0.04)
        guard AccessibleText.selectedRange(element) == range else {
            ReplacementDiagnostics.note("paragraph_accessibility_range_ignored")
            await restore(caret, on: element, context: context)
            return nil
        }
        let copied: CopiedParagraph
        do { copied = try await copy(context); try TextInputGate.check() }
        catch { await restore(caret, on: element, context: context); throw error }
        guard ParagraphDraft.sameText(copied.plain, (value as NSString).substring(with: range)) else {
            ReplacementDiagnostics.note("paragraph_accessibility_mismatch")
            await restore(caret, on: element, context: context)
            return nil
        }
        ReplacementDiagnostics.note("paragraph_accessibility_selection")
        let selection = Selection(copied: copied, method: .accessibility(element, end: caret))
        if !keep { await dismiss(selection, context: context) }
        return selection
    }

    /// Chromium's block editors report offsets that drift from the selection
    /// they make by one per block, and setting the caret back would move it.
    private static func hasWebBlocks(_ element: AXUIElement) -> Bool {
        guard ((AccessibleText.attribute(element, kAXChildrenAttribute) as [AXUIElement]?)?.count ?? 0) > 1 else { return false }
        var node = element
        for _ in 0..<16 {
            guard let parent: AXUIElement = AccessibleText.attribute(node, kAXParentAttribute), !CFEqual(parent, node) else { return false }
            if (AccessibleText.attribute(parent, kAXRoleAttribute) as String?) == "AXWebArea" { return true }
            node = parent
        }
        return false
    }

    private static func copy(_ context: ParagraphContext) async throws -> CopiedParagraph {
        let clipboard = TemporaryClipboard(text: "TranslateBar paragraph \(UUID().uuidString)")
        defer { clipboard.restore() }
        OfficeText.key(8, flags: .maskCommand, to: context.pid)
        for _ in 0..<15 {
            await OfficeText.pause(0.035)
            try check(context)
            guard let copied = clipboard.takeCopiedText() else { continue }
            guard !copied.plain.isEmpty else { break }
            guard copied.plain.utf8.count <= 60_000 else {
                ReplacementDiagnostics.fail("paragraph_oversized")
                throw AppError.message("当前段落超过 60 KB，请分段翻译。")
            }
            return CopiedParagraph(plain: copied.plain, rich: copied.rich, attachments: copied.attachments)
        }
        ReplacementDiagnostics.fail("paragraph_copy_unavailable")
        throw AppError.message("此输入框没有复制出文字，原文未改动。")
    }

    private static func paste(_ text: String, context: ParagraphContext) async throws {
        try check(context)
        let clipboard = TemporaryClipboard(text: text)
        defer { clipboard.restore() }
        OfficeText.key(9, flags: .maskCommand, to: context.pid)
        // The editor reads the pasteboard while handling the event.
        await OfficeText.pause(0.15)
    }

    private static func dismiss(_ selection: Selection, context: ParagraphContext) async {
        switch selection.method {
        case let .accessibility(element, end): await restore(end, on: element, context: context)
        case let .keyboard(text): await collapse(context, text: text)
        }
    }

    private static func restore(_ caret: NSRange, on element: AXUIElement, context: ParagraphContext) async {
        if set(caret, on: element) {
            await OfficeText.pause(0.03)
            if AccessibleText.selectedRange(element) == caret { return }
        }
        await collapse(context, text: element)
    }

    /// Never leaves a selection behind: the next keystroke would replace it.
    private static func collapse(_ context: ParagraphContext, text: AXUIElement?) async {
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == context.pid else { return }
        if let text, AccessibleText.selectedRange(text)?.length == 0 { return }
        OfficeText.key(124, to: context.pid)
        await OfficeText.pause(0.04)
    }

    private static func set(_ range: NSRange, on element: AXUIElement) -> Bool {
        var value = CFRange(location: range.location, length: range.length)
        guard let ax = AXValueCreate(.cfRange, &value) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, ax) == .success
    }

    private static func sendSelectionKey(_ key: ParagraphSelectionKey, to pid: pid_t) {
        switch key {
        case .commandShiftLeft: OfficeText.key(123, flags: [.maskCommand, .maskShift], to: pid)
        case .commandShiftUp: OfficeText.key(126, flags: [.maskCommand, .maskShift], to: pid)
        case .optionShiftUp: OfficeText.key(126, flags: [.maskAlternate, .maskShift], to: pid)
        case .shiftHome: OfficeText.key(115, flags: .maskShift, to: pid)
        }
    }

    private static func check(_ context: ParagraphContext) throws {
        guard AccessibleText.trusted, !IsSecureEventInputEnabled(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == context.pid else {
            ReplacementDiagnostics.fail("paragraph_application_changed")
            throw TextReplacementError.changed
        }
        guard TextInteraction.editRevision == context.revision else {
            ReplacementDiagnostics.fail("input_revision")
            ReplacementDiagnostics.note("recent_" + TextInteraction.lastKind.rawValue)
            throw TextReplacementError.changed
        }
    }

    private static func validate(_ context: ParagraphContext, checkFocus: Bool) throws -> Location {
        try check(context)
        let location = locate(context.pid)
        if let window = context.window {
            guard let current = location.window, CFEqual(current, window) else {
                ReplacementDiagnostics.fail("paragraph_window_changed")
                throw TextReplacementError.changed
            }
        }
        if checkFocus, let focus = context.focus, let current = location.focus, !same(focus, current) {
            ReplacementDiagnostics.fail("paragraph_focus_changed")
            throw TextReplacementError.changed
        }
        return location
    }

    private static func locate(_ pid: pid_t, wake: Bool = false) -> Location {
        let application = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(application, 0.2)
        let window: AXUIElement? = AccessibleText.attribute(application, kAXFocusedWindowAttribute)
        let focus = TextFocus.resolve(pid: pid, wakeAccessibility: wake)
        let text = focus.flatMap { focus in
            ([focus] + AccessibleText.inputCandidates(focus)).first { AccessibleText.textValue($0) != nil && AccessibleText.selectedRange($0) != nil }
        }
        return Location(window: window, focus: focus, text: text)
    }

    /// Web editors may rebuild the accessibility object of the same field.
    private static func same(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        if CFEqual(lhs, rhs) { return true }
        func identity(_ element: AXUIElement) -> String? {
            let identifier: String = AccessibleText.attribute(element, "AXDOMIdentifier") ?? AccessibleText.attribute(element, kAXIdentifierAttribute) ?? ""
            return identifier.isEmpty ? nil : identifier + "\u{1f}" + (AccessibleText.attribute(element, kAXRoleAttribute) ?? "")
        }
        guard let left = identity(lhs) else { return false }
        return left == identity(rhs)
    }

    private static func refreshed(_ context: ParagraphContext) -> ParagraphContext {
        let location = locate(context.pid)
        return ParagraphContext(pid: context.pid, window: location.window ?? context.window, focus: location.focus ?? context.focus,
                                key: context.key, revision: TextInteraction.editRevision)
    }

    private static func style(_ text: NSAttributedString?, at offset: Int) -> Style? {
        guard let text, offset < text.length, let font = text.attribute(.font, at: offset, effectiveRange: nil) as? NSFont else { return nil }
        return Style(size: (font.pointSize * 10).rounded() / 10, traits: font.fontDescriptor.symbolicTraits.intersection([.bold, .italic]))
    }

    private static func anchor(_ pid: pid_t) -> NSRect? {
        guard let text = locate(pid).text, let caret = AccessibleText.selectedRange(text), caret.location > 0 else { return nil }
        return AccessibleText.bounds(of: NSRange(location: caret.location - 1, length: 1), in: text)
    }
}
