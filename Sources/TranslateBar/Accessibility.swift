import AppKit
import ApplicationServices
import Carbon
import TranslateCore

struct TextSnapshot {
    let element: AXUIElement
    let pid: pid_t
    let value: String
    let range: NSRange
    let source: String
    let fullValue: String?
    var allowTrailingSpaces = false
    var identity: TextElementIdentity?
    var selectionRange: NSRange?
    var richText: NSAttributedString?
    var preservesRichText = false
    var richRestoration: NSAttributedString?
    var triggerSpaceCount = 4
    var office: OfficeSnapshot?
    var clipboard: ClipboardTextSnapshot?
    var interactionRevision: UInt64?
    var prefersPaste = false
}

struct TextElementIdentity {
    let identifier: String
    let role: String
    let window: AXUIElement
}

@MainActor enum AccessibleText {
    static var trusted: Bool { AXIsProcessTrusted() }
    static func requestPermission() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }
    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
    static func activeApplication(settings: AppSettings, allowOwnApp: Bool = false) throws -> NSRunningApplication {
        guard trusted else { throw AppError.message("请先在系统设置中授予 TranslateBar 辅助功能权限。") }
        guard !IsSecureEventInputEnabled() else { throw AppError.message("当前处于安全输入模式，已跳过。") }
        guard let app = NSWorkspace.shared.frontmostApplication,
              allowOwnApp || app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !settings.excludes(app.bundleIdentifier ?? "") else { throw AppError.message("当前应用不支持或已被排除。") }
        return app
    }
    static func focused(settings: AppSettings, allowOwnApp: Bool = false) throws -> (AXUIElement, pid_t) {
        let app = try activeApplication(settings: settings, allowOwnApp: allowOwnApp)
        guard let element = TextFocus.resolve(pid: app.processIdentifier, wakeAccessibility: settings.enhancedCompatibility) else { throw AppError.message("当前控件未提供可访问文本，已跳过。") }
        guard !isSecure(element) else { throw AppError.message("密码输入框不参与翻译。") }
        return (element, app.processIdentifier)
    }
    static func isSecure(_ element: AXUIElement) -> Bool {
        var node = element
        for _ in 0..<6 {
            let subrole: String = attribute(node, kAXSubroleAttribute) ?? ""
            let protected: Bool = attribute(node, "AXProtectedContent") ?? false
            if subrole == kAXSecureTextFieldSubrole || protected { return true }
            guard let parent: AXUIElement = attribute(node, kAXParentAttribute), !CFEqual(parent, node) else { break }
            node = parent
        }
        return false
    }
    static func textValue(_ element: AXUIElement) -> String? {
        // Character ranges must use the same text representation as AX offsets.
        // Web editors may expose a differently normalized AXValue string.
        if let count: Int = attribute(element, kAXNumberOfCharactersAttribute), count >= 0, count <= 60_000 {
            var range = CFRange(location: 0, length: count)
            if let parameter = AXValueCreate(.cfRange, &range) {
                var result: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, parameter, &result) == .success,
                   let text = result as? String, (text as NSString).length == count { return text }
            }
        }
        if let value: String = attribute(element, kAXValueAttribute) { return value }
        return (attribute(element, kAXValueAttribute) as NSAttributedString?)?.string
    }
    static func inputCandidates(_ element: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = [], node = element
        for _ in 0..<6 {
            let role: String = attribute(node, kAXRoleAttribute) ?? ""
            if TextCompatibilityRules.isTextRole(role) { result.append(node) }
            if role == "AXWebArea" || role == kAXWindowRole { break }
            guard let parent: AXUIElement = attribute(node, kAXParentAttribute), !CFEqual(parent, node) else { break }
            node = parent
        }
        return result
    }
    static func canEdit(_ element: AXUIElement) -> Bool {
        if let editable: Bool = attribute(element, "AXEditable") { return editable }
        var value = DarwinBoolean(false), selected = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &value)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selected)
        return value.boolValue || selected.boolValue
    }
    private static func isWebControl(_ element: AXUIElement) -> Bool {
        var node = element
        for _ in 0..<16 {
            let role: String = attribute(node, kAXRoleAttribute) ?? ""
            if role == "AXWebArea" { return true }
            if role == kAXWindowRole { break }
            guard let parent: AXUIElement = attribute(node, kAXParentAttribute), !CFEqual(parent, node) else { break }
            node = parent
        }
        return false
    }
    static func selected(settings: AppSettings) throws -> TextSnapshot {
        let (element, pid) = try focused(settings: settings)
        for candidate in selectionCandidates(element: element, pid: pid) {
            guard case let .text(selected) = readSelection(candidate), !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var full = textValue(candidate)
            let selectedRange = selectedRange(candidate)
            let range = selectedRange ?? NSRange(location: 0, length: (selected as NSString).length)
            if let value = full, range.location > (value as NSString).length || range.length > (value as NSString).length - range.location || (value as NSString).substring(with: range) != selected { full = nil }
            return TextSnapshot(element: candidate, pid: pid, value: selected, range: range, source: selected, fullValue: full, identity: identity(candidate), selectionRange: selectedRange)
        }
        throw AppError.message("没有读取到选中文字。请拖动选中后重试，或按快捷键翻译；不支持取词的控件会跳过。")
    }
    private static func selectionCandidates(element: AXUIElement, pid: pid_t) -> [AXUIElement] {
        var candidates = [element]
        var ancestor = element
        for _ in 0..<12 {
            guard let parent: AXUIElement = attribute(ancestor, kAXParentAttribute), !CFEqual(parent, ancestor) else { break }
            candidates.append(parent); ancestor = parent
        }
        // Browser selections may belong to the web area rather than the focused leaf.
        let app = AXUIElementCreateApplication(pid)
        if let window: AXUIElement = attribute(app, kAXFocusedWindowAttribute) {
            var queue = [window]; var index = 0
            let deadline = Date().addingTimeInterval(0.18)
            while index < queue.count, index < 60, Date() < deadline {
                let node = queue[index]; index += 1
                if let role: String = attribute(node, kAXRoleAttribute), role == "AXWebArea" { candidates.append(node); continue }
                if let children: [AXUIElement] = attribute(node, kAXChildrenAttribute) { queue.append(contentsOf: children.prefix(20)) }
            }
        }
        return candidates
    }
    private enum SelectionRead { case text(String), empty, unavailable }
    private static func readSelection(_ element: AXUIElement) -> SelectionRead {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value)
        let plain = value as? String
        if let plain, !plain.isEmpty { return .text(plain) }
        if let marker = selectedMarkerText(element) { return marker.isEmpty ? .empty : .text(marker) }
        // Unsupported, invalidated and timed-out nodes are not evidence that
        // the user cancelled the selection.
        return status == .success && plain != nil ? .empty : .unavailable
    }
    private static func selectedMarkerText(_ element: AXUIElement) -> String? {
        var marker: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXSelectedTextMarkerRange" as CFString, &marker) == .success, let marker else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, "AXStringForTextMarkerRange" as CFString, marker, &result) == .success else { return nil }
        if let string = result as? String { return string }
        return (result as? NSAttributedString)?.string
    }
    static func observeSelection(_ snapshot: TextSnapshot, settings: AppSettings) -> SelectionObservation {
        if let clipboard = snapshot.clipboard { return (try? ClipboardText.validate(clipboard.context)) != nil ? .matching : .contextChanged }
        if let office = snapshot.office { return (try? OfficeText.validate(office.context)) != nil ? .matching : .contextChanged }
        guard trusted, !IsSecureEventInputEnabled(), NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else { return .contextChanged }
        let original = readSelection(snapshot.element)
        if case let .text(text) = original, text == snapshot.source { return .matching }
        // Reacquire from the currently focused tree: comment nodes and their
        // character offsets may be rebuilt while the selected text stays put.
        guard let (element, pid) = try? focused(settings: settings), pid == snapshot.pid else { return .unavailable }
        var sawEmpty = false, sawDifferent = false
        for candidate in selectionCandidates(element: element, pid: pid) {
            switch readSelection(candidate) {
            case let .text(text):
                if text == snapshot.source { return .matching }
                sawDifferent = true
            case .empty: sawEmpty = true
            case .unavailable: break
            }
        }
        if sawDifferent { return .changed }
        if sawEmpty { return .cleared }
        return .unavailable
    }
    static func selectionBounds(_ snapshot: TextSnapshot) -> NSRect? {
        if let clipboard = snapshot.clipboard { return clipboard.anchor }
        if let office = snapshot.office { return office.anchor }
        var result: CFTypeRef?
        var marker: CFTypeRef?
        if AXUIElementCopyAttributeValue(snapshot.element, "AXSelectedTextMarkerRange" as CFString, &marker) == .success, let marker {
            _ = AXUIElementCopyParameterizedAttributeValue(snapshot.element, "AXBoundsForTextMarkerRange" as CFString, marker, &result)
        }
        if result == nil {
            var range = CFRange(location: snapshot.range.location, length: snapshot.range.length)
            if let value = AXValueCreate(.cfRange, &range) {
                _ = AXUIElementCopyParameterizedAttributeValue(snapshot.element, kAXBoundsForRangeParameterizedAttribute as CFString, value, &result)
            }
        }
        guard let result, CFGetTypeID(result) == AXValueGetTypeID() else { return nil }
        var bounds = CGRect.zero
        guard AXValueGetValue(result as! AXValue, .cgRect, &bounds), !bounds.isNull, !bounds.isInfinite,
              bounds.origin.x.isFinite, bounds.origin.y.isFinite, bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return nil }
        let top = NSScreen.screens.first?.frame.maxY ?? 0
        return NSRect(x: bounds.minX, y: top - bounds.maxY, width: bounds.width, height: bounds.height)
    }
    static func input(settings: AppSettings) throws -> TextSnapshot {
        let (focusedElement, pid) = try focused(settings: settings)
        guard let element = inputCandidates(focusedElement).first(where: { textValue($0) != nil && selectedRange($0) != nil }),
              let full = textValue(element), !full.isEmpty,
              let caret = selectedRange(element), caret.location <= (full as NSString).length else { throw AppError.message("当前输入框不支持读取文本，已跳过。") }
        guard !isSecure(element), (attribute(element, "AXEditable") as Bool?) != false,
              (attribute(element, kAXEnabledAttribute) as Bool?) != false else { throw AppError.message("当前控件不可编辑，已跳过。") }
        let role: String = attribute(element, kAXRoleAttribute) ?? ""
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
        // Office can expose AXTextArea only after its canvas is initialized.
        // Keep the same verified paragraph/soft-break scope in both states.
        if MicrosoftTextRules.usesDocumentFallback(bundleID: bundle, role: role) {
            throw AppError.message("Office 正文需要通过兼容路径回填，请开启“增强取词与回填兼容”。")
        }
        guard canEdit(element) else { throw AppError.message("当前控件不可编辑，已跳过。") }
        // Chromium block editors expose AXValue with paragraph separators that
        // do not consistently share offsets with AXSelectedTextRange. A local
        // keyboard-selected line is safer than indexing across their blocks.
        if isWebControl(element), role == "AXTextArea",
           let children: [AXUIElement] = attribute(element, kAXChildrenAttribute),
           children.contains(where: { ["AXHeading", "AXParagraph", "AXList", "AXTable"].contains(attribute($0, kAXRoleAttribute) as String? ?? "") }) {
            throw AppError.message("此网页编辑器使用结构化段落，改用当前行兼容模式。")
        }
        let string = full as NSString
        let range = try ParagraphInput.range(in: full, caret: caret)
        let source = string.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !source.isEmpty else { throw AppError.message("当前段落没有需要翻译的文本，已跳过。") }
        let rich = role == "AXTextArea" ? attributedText(element, range: range) : nil
        let hasFont = rich.map { $0.length > 0 && $0.attribute(.font, at: 0, effectiveRange: nil) is NSFont } ?? false
        let preserve = hasFont || ["com.apple.Notes", "com.apple.TextEdit", "com.murphy.TranslateBarFixture"].contains(bundle)
        return TextSnapshot(element: element, pid: pid, value: full, range: range, source: source, fullValue: full, allowTrailingSpaces: NSMaxRange(range) == string.length, identity: identity(element), selectionRange: caret, richText: rich, preservesRichText: preserve, triggerSpaceCount: settings.spaceCount, interactionRevision: TextInteraction.revision, prefersPaste: isWebControl(element))
    }
    static func attributedText(_ element: AXUIElement, range: NSRange) -> NSAttributedString? {
        var cfRange = CFRange(location: range.location, length: range.length)
        guard let parameter = AXValueCreate(.cfRange, &cfRange) else { return nil }
        var value: CFTypeRef?
        if AXUIElementCopyParameterizedAttributeValue(element, kAXRTFForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
           let data = value as? Data, data.count <= 4 * 1024 * 1024,
           let result = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) { return result }
        value = nil
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXAttributedStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
              let source = value as? NSAttributedString else { return nil }
        let normalized = NSMutableAttributedString(string: source.string)
        source.enumerateAttributes(in: NSRange(location: 0, length: source.length)) { attributes, span, _ in
            if let font = attributes[.font] as? NSFont { normalized.addAttribute(.font, value: font, range: span) }
            else if let info = attributes[NSAttributedString.Key(kAXFontTextAttribute.takeUnretainedValue() as String)] as? [String: Any],
                    let name = info[kAXFontNameKey.takeUnretainedValue() as String] as? String,
                    let size = info[kAXFontSizeKey.takeUnretainedValue() as String] as? NSNumber,
                    let font = NSFont(name: name, size: size.doubleValue) ?? NSFont(descriptor: NSFontDescriptor(fontAttributes: [.name: name]), size: size.doubleValue) {
                normalized.addAttribute(.font, value: font, range: span)
            }
        }
        return normalized
    }
    static func formattingSnapshot(_ snapshot: TextSnapshot) async throws -> TextSnapshot {
        guard let full = snapshot.fullValue else { throw RichTextReplacementError.unavailable }
        var updated = snapshot
        updated.richText = try await richTextForRange(snapshot, range: snapshot.range, expected: (full as NSString).substring(with: snapshot.range), current: full)
        return updated
    }
    private static func richTextForRange(_ snapshot: TextSnapshot, range: NSRange, expected: String, current: String) async throws -> NSAttributedString {
        let element = try target(snapshot)
        if let direct = attributedText(element, range: range), direct.string == expected { return direct }
        // Notes does not always expose RTF through accessibility. Copy only the
        // already verified source range, read its local RTF, then restore both
        // the user's clipboard and original caret before doing anything else.
        let caret = selectedRange(element)
        let clipboard = TemporaryClipboard(text: "TranslateBar formatting \(UUID().uuidString)")
        defer {
            clipboard.restore()
            if let caret, let destination = try? target(snapshot), let value = textValue(destination), value == current, selectedRange(destination) == range {
                var restored = CFRange(location: caret.location, length: caret.length)
                if let ax = AXValueCreate(.cfRange, &restored) { _ = AXUIElementSetAttributeValue(destination, kAXSelectedTextRangeAttribute as CFString, ax) }
            }
        }
        var selected = CFRange(location: range.location, length: range.length)
        guard let ax = AXValueCreate(.cfRange, &selected), AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, ax) == .success else { throw RichTextReplacementError.unavailable }
        await pause(0.04)
        let destination = try target(snapshot)
        guard let value = textValue(destination), value == current else { ReplacementDiagnostics.fail("copy_content"); throw TextReplacementError.changed }
        guard selectedRange(destination) == range else {
            ReplacementDiagnostics.fail("copy_range", ["wanted": range.location, "wanted_length": range.length, "actual": selectedRange(destination)?.location ?? -1, "actual_length": selectedRange(destination)?.length ?? -1])
            throw TextReplacementError.changed
        }
        sendCommandKey(8, to: snapshot.pid)
        for _ in 0..<12 {
            await pause(0.035)
            if clipboard.acceptCopiedText(expected) {
                guard let result = clipboard.copiedRichText() else { throw RichTextReplacementError.unavailable }
                if result.string == expected { return result }
                if result.string == expected + "\n" || result.string == expected + "\r\n" { return result.attributedSubstring(from: NSRange(location: 0, length: (expected as NSString).length)) }
                throw RichTextReplacementError.unavailable
            }
        }
        throw RichTextReplacementError.unavailable
    }
    static func selectedRange(_ element: AXUIElement) -> NSRange? {
        guard let ax: AXValue = attribute(element, kAXSelectedTextRangeAttribute) else { return nil }
        var range = CFRange()
        guard AXValueGetValue(ax, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }
    static func sendCommandKey(_ code: CGKeyCode, to pid: pid_t? = nil) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)
            event?.flags = .maskCommand; event?.setIntegerValueField(.eventSourceUserData, value: InputMonitor.syntheticTag)
            if let pid { event?.postToPid(pid) } else { event?.post(tap: .cgSessionEventTap) }
        }
    }
    private static func identity(_ element: AXUIElement) -> TextElementIdentity? {
        let identifier: String = attribute(element, "AXDOMIdentifier") ?? attribute(element, kAXIdentifierAttribute) ?? ""
        guard !identifier.isEmpty, let role: String = attribute(element, kAXRoleAttribute), let window: AXUIElement = attribute(element, kAXWindowAttribute) else { return nil }
        return TextElementIdentity(identifier: identifier, role: role, window: window)
    }
    private static func target(_ snapshot: TextSnapshot) throws -> AXUIElement {
        guard !IsSecureEventInputEnabled() else { throw AppError.message("当前处于安全输入模式，未回填。") }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == snapshot.pid else { throw AppError.message("焦点已经切换，译文保留在浮窗中。") }
        guard let current = TextFocus.resolve(pid: snapshot.pid) else { throw AppError.message("输入框焦点已经变化，未覆盖原文。") }
        if let revision = snapshot.interactionRevision, revision != TextInteraction.revision {
            ReplacementDiagnostics.fail("input_revision", ["delta": Int(min(TextInteraction.revision &- revision, 1_000_000))])
            ReplacementDiagnostics.note("recent_" + TextInteraction.lastKind.rawValue)
            throw TextReplacementError.changed
        }
        for candidate in [current] + inputCandidates(current) {
            guard !isSecure(candidate) else { throw AppError.message("密码输入框不参与翻译。") }
            if CFEqual(candidate, snapshot.element) { return candidate }
            if let expected = snapshot.identity, let actual = identity(candidate), expected.identifier == actual.identifier,
               expected.role == actual.role, CFEqual(expected.window, actual.window) { return candidate }
        }
        throw AppError.message("输入框焦点已经变化，未覆盖原文。")
    }
    // A posted paste must be consumed before its temporary clipboard contents are restored.
    private static func pause(_ seconds: Double) async {
        await withCheckedContinuation { continuation in DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { continuation.resume() } }
    }
    private static func waitForValue(_ snapshot: TextSnapshot, expected: String) async throws -> AXUIElement? {
        for _ in 0..<7 {
            let element = try target(snapshot)
            if let value = textValue(element), value == expected { return element }
            await pause(0.035)
        }
        return nil
    }
    static func replace(_ snapshot: TextSnapshot, with text: String) async throws -> TextSnapshot {
        ReplacementDiagnostics.begin(snapshot)
        do {
            let result = try await TextInputGate.run(pid: snapshot.pid) { try await protectedReplace(snapshot, with: text) }
            ReplacementDiagnostics.finish(success: true)
            return result
        } catch { ReplacementDiagnostics.finish(success: false); throw error }
    }
    private static func protectedReplace(_ snapshot: TextSnapshot, with text: String) async throws -> TextSnapshot {
        try Task.checkCancellation()
        try TextInputGate.check()
        if snapshot.clipboard != nil { return try await ClipboardText.replace(snapshot, with: text) }
        if snapshot.office != nil { return try await OfficeText.replace(snapshot, with: text) }
        let element = try target(snapshot)
        guard let full = snapshot.fullValue, let actual = textValue(element) else { throw AppError.message("当前输入框不能安全回填，译文已保留。") }
        if let caret = snapshot.selectionRange, selectedRange(element) != caret {
            let actualCaret = selectedRange(element)
            let synchronized = snapshot.allowTrailingSpaces && actualCaret.map {
                TriggerCaretSynchronization.permits(original: full, current: actual, captured: caret, actual: $0, replacementRange: snapshot.range, triggerSpaces: snapshot.triggerSpaceCount, interactionUnchanged: snapshot.interactionRevision == TextInteraction.revision)
            } == true
            guard synchronized else {
                ReplacementDiagnostics.fail("capture_caret", ["original_length": full.utf16.count, "actual_length": actual.utf16.count, "old_caret": caret.location, "old_selection": caret.length, "new_caret": actualCaret?.location ?? -1, "new_selection": actualCaret?.length ?? -1])
                throw TextReplacementError.changed
            }
            ReplacementDiagnostics.note("trigger_caret_synchronized", ["advance": (actualCaret?.location ?? caret.location) - caret.location])
        }
        if snapshot.preservesRichText { return try await replaceRichText(snapshot, element: element, current: actual, translation: text) }
        if snapshot.prefersPaste, (attribute(element, kAXRoleAttribute) as String?) == "AXTextArea" { return try await replaceRichText(snapshot, element: element, current: actual, translation: text, plain: true) }
        let plan = try TextReplacementPlan(original: full, range: snapshot.range, current: actual, replacement: text, allowTrailingSpaces: snapshot.allowTrailingSpaces)
        if actual == plan.updated { return undoSnapshot(snapshot, element: element, plan: plan, replacement: text) }
        var range = CFRange(location: plan.range.location, length: plan.range.length)
        var selectedWritable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &selectedWritable)
        if !snapshot.prefersPaste, selectedWritable.boolValue, let ax = AXValueCreate(.cfRange, &range), AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, ax) == .success,
           AXUIElementSetAttributeValue(element, kAXSelectedTextAttribute as CFString, text as CFString) == .success,
           let verified = try await waitForValue(snapshot, expected: plan.updated) {
            return undoSnapshot(snapshot, element: verified, plan: plan, replacement: text)
        }
        let current = try target(snapshot)
        guard let currentValue = textValue(current), currentValue == actual else { throw TextReplacementError.changed }
        var writable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(current, kAXValueAttribute as CFString, &writable)
        if !snapshot.prefersPaste, writable.boolValue, AXUIElementSetAttributeValue(current, kAXValueAttribute as CFString, plan.updated as CFString) == .success,
           let verified = try await waitForValue(snapshot, expected: plan.updated) {
            return undoSnapshot(snapshot, element: verified, plan: plan, replacement: text)
        }
        // Some web inputs expose text but do not implement AX writing. Paste into the
        // same verified field, then restore every clipboard format if nobody else changed it.
        let pasteTarget = try target(snapshot)
        guard let beforePaste = textValue(pasteTarget), beforePaste == actual else { throw TextReplacementError.changed }
        if let ax = AXValueCreate(.cfRange, &range) { _ = AXUIElementSetAttributeValue(pasteTarget, kAXSelectedTextRangeAttribute as CFString, ax) }
        await pause(0.05)
        if selectedRange(pasteTarget) != plan.range {
            guard plan.range.location == 0, plan.range.length == (actual as NSString).length else { throw AppError.message("此编辑器无法定位当前段落，请选中该段使用划词翻译。") }
            sendCommandKey(0, to: snapshot.pid); await pause(0.08)
        }
        let verifiedTarget = try target(snapshot)
        guard let verifiedValue = textValue(verifiedTarget), verifiedValue == actual else { throw TextReplacementError.changed }
        guard selectedRange(verifiedTarget) == plan.range else { throw AppError.message("此输入框无法选中待替换文字，原文未改动。") }
        try Task.checkCancellation()
        let clipboard = TemporaryClipboard(text: text)
        defer { clipboard.restore() }
        sendCommandKey(9, to: snapshot.pid)
        // Cancellation after posting must still allow the paste to finish before restoring.
        await pause(0.12)
        guard let verified = try await waitForValue(snapshot, expected: plan.updated) else { throw AppError.message("浏览器未完成回填，译文已保留。请保持光标在原输入框内重试。") }
        return undoSnapshot(snapshot, element: verified, plan: plan, replacement: text)
    }
    private static func replaceRichText(_ snapshot: TextSnapshot, element: AXUIElement, current: String, translation: String, plain: Bool = false) async throws -> TextSnapshot {
        guard let full = snapshot.fullValue else { throw RichTextReplacementError.unavailable }
        let preflight: TextReplacementPlan
        do { preflight = try TextReplacementPlan(original: full, range: snapshot.range, current: current, replacement: translation, allowTrailingSpaces: snapshot.allowTrailingSpaces) }
        catch { ReplacementDiagnostics.fail("source_content", ["original_length": full.utf16.count, "actual_length": current.utf16.count]); throw error }
        let original = plain ? NSAttributedString(string: preflight.originalText) : try await richTextForRange(snapshot, range: preflight.range, expected: preflight.originalText, current: current)
        let formatted: NSAttributedString
        if let restoration = snapshot.richRestoration, restoration.string == translation { formatted = restoration }
        else { formatted = try RichTextReplacement.translated(translation, preserving: original, removingTriggerSpaces: true, triggerSpaceCount: snapshot.triggerSpaceCount, requireFont: !plain) }
        let plan = try TextReplacementPlan(original: full, range: snapshot.range, current: current, replacement: formatted.string, allowTrailingSpaces: snapshot.allowTrailingSpaces)
        let edits = try RichTextReplacement.edits(original: original, replacement: formatted, offset: plan.range.location)
        var working = current
        var applied: [RichTextReplacement.Edit] = []
        do {
            for edit in edits {
                working = try await pasteRichFragment(snapshot, range: edit.range, replacement: edit.replacement, expected: working, plain: plain)
                applied.append(edit)
            }
        } catch {
            // Roll back only while the document still exactly matches our own
            // edits. New user text is never overwritten during recovery.
            if let destination = try? target(snapshot), let value = textValue(destination), value == working {
                for edit in applied.reversed() {
                    let range = NSRange(location: edit.range.location, length: edit.replacement.length)
                    guard let restored = try? await pasteRichFragment(snapshot, range: range, replacement: edit.original, expected: working, plain: plain) else { break }
                    working = restored
                }
            }
            throw error
        }
        guard working == plan.updated, let verified = try await waitForValue(snapshot, expected: plan.updated) else { throw AppError.message("编辑器未完成格式回填，译文已保留。") }
        var caret = CFRange(location: plan.range.location + formatted.length, length: 0)
        if let ax = AXValueCreate(.cfRange, &caret) { _ = AXUIElementSetAttributeValue(verified, kAXSelectedTextRangeAttribute as CFString, ax) }
        var undo = undoSnapshot(snapshot, element: verified, plan: plan, replacement: formatted.string)
        undo.preservesRichText = !plain
        undo.richText = attributedText(verified, range: undo.range)
        undo.richRestoration = original
        return undo
    }
    private static func pasteRichFragment(_ snapshot: TextSnapshot, range: NSRange, replacement: NSAttributedString, expected: String, plain: Bool = false) async throws -> String {
        let element = try target(snapshot)
        guard let value = textValue(element), value == expected else { ReplacementDiagnostics.fail("paste_content"); throw TextReplacementError.changed }
        var selected = CFRange(location: range.location, length: range.length)
        guard let ax = AXValueCreate(.cfRange, &selected), AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, ax) == .success else { throw RichTextReplacementError.unavailable }
        await pause(0.04)
        let destination = try target(snapshot)
        guard let current = textValue(destination), current == expected else { ReplacementDiagnostics.fail("paste_content"); throw TextReplacementError.changed }
        guard selectedRange(destination) == range else {
            ReplacementDiagnostics.fail("paste_range", ["wanted": range.location, "wanted_length": range.length, "actual": selectedRange(destination)?.location ?? -1, "actual_length": selectedRange(destination)?.length ?? -1])
            throw TextReplacementError.changed
        }
        let updated = (expected as NSString).replacingCharacters(in: range, with: replacement.string)
        let clipboard = TemporaryClipboard(text: replacement.string, rtf: plain ? nil : try RichTextReplacement.rtf(replacement))
        defer { clipboard.restore() }
        try Task.checkCancellation()
        try TextInputGate.check()
        sendCommandKey(9, to: snapshot.pid)
        await pause(0.12)
        guard try await waitForValue(snapshot, expected: updated) != nil else { throw AppError.message("编辑器未完成段落回填，译文已保留。") }
        return updated
    }
    private static func undoSnapshot(_ snapshot: TextSnapshot, element: AXUIElement, plan: TextReplacementPlan, replacement: String) -> TextSnapshot {
        TextSnapshot(element: element, pid: snapshot.pid, value: plan.updated, range: NSRange(location: plan.range.location, length: (replacement as NSString).length), source: plan.originalText, fullValue: plan.updated, identity: identity(element), selectionRange: selectedRange(element), interactionRevision: TextInteraction.revision, prefersPaste: snapshot.prefersPaste)
    }
}

@MainActor final class TemporaryClipboard {
    private let pasteboard: NSPasteboard
    private let saved: [[(NSPasteboard.PasteboardType, Data)]]
    private var changeCount: Int
    init(text: String, rtf: Data? = nil, pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        saved = ClipboardFormats.snapshot(pasteboard) ?? pasteboard.pasteboardItems?.map { original in original.types.compactMap { type in original.data(forType: type).map { (type, $0) } } } ?? []
        let item = NSPasteboardItem(); item.setString(text, forType: .string)
        if let rtf { item.setData(rtf, forType: .rtf) }
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        pasteboard.clearContents(); pasteboard.writeObjects([item]); changeCount = pasteboard.changeCount
    }
    func acceptCopiedText(_ expected: String) -> Bool {
        guard pasteboard.changeCount != changeCount, let copied = pasteboard.string(forType: .string),
              copied == expected || copied == expected + "\n" || copied == expected + "\r\n" else { return false }
        changeCount = pasteboard.changeCount
        return true
    }
    func copiedRichText() -> NSAttributedString? {
        for (type, format) in [(NSPasteboard.PasteboardType.rtf, NSAttributedString.DocumentType.rtf), (.rtfd, .rtfd),
                               (NSPasteboard.PasteboardType("com.trolltech.anymime.Rich Text Format"), .rtf),
                               (NSPasteboard.PasteboardType("com.trolltech.anymime.text--rtf"), .rtf)] {
            let data = type.rawValue.contains(" ") ? ClipboardFormats.data(type, from: pasteboard) : (pasteboard.data(forType: type) ?? ClipboardFormats.data(type, from: pasteboard))
            if let data, data.count <= 4 * 1024 * 1024,
               let text = try? NSAttributedString(data: data, options: [.documentType: format], documentAttributes: nil) { return text }
        }
        return nil
    }
    func takeCopiedRichText() -> NSAttributedString? {
        guard pasteboard.changeCount != changeCount else { return nil }
        changeCount = pasteboard.changeCount
        guard let plain = pasteboard.string(forType: .string), !plain.isEmpty else { return NSAttributedString(string: "") }
        guard let rich = copiedRichText() else { return NSAttributedString(string: plain) }
        let canonicalPlain = plain.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let canonicalRich = rich.string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        guard canonicalRich == canonicalPlain || canonicalRich == canonicalPlain + "\n" else { return NSAttributedString(string: plain) }
        // WPS exports one RTF paragraph terminator beyond a line-only selection.
        let result: NSAttributedString
        if rich.string == plain { result = rich }
        else if rich.string == plain + "\n" || rich.string == plain + "\r" || rich.string == plain + "\r\n" { result = rich.attributedSubstring(from: NSRange(location: 0, length: (plain as NSString).length)) }
        else { return NSAttributedString(string: plain) }
        return result
    }
    func copiedMetadata() -> [String: Any] {
        let plain = pasteboard.string(forType: .string) ?? ""
        let rich = copiedRichText()
        return ["changed": pasteboard.changeCount != changeCount, "types": pasteboard.types?.map(\.rawValue) ?? [], "plain_length": (plain as NSString).length, "rich_length": rich?.length ?? -1,
                "plain_tail": plain.unicodeScalars.suffix(4).map(\.value), "rich_tail": rich?.string.unicodeScalars.suffix(4).map(\.value) ?? []]
    }
    func restore() {
        guard pasteboard.changeCount == changeCount else { return }
        // Qt/WPS exports legacy flavor names containing spaces. NSPasteboardItem
        // rejects those names on write; the Pasteboard API preserves them verbatim.
        if saved.joined().contains(where: { $0.0.rawValue.contains(" ") }) {
            var board: Pasteboard?
            let name = pasteboard.name == NSPasteboard.Name.general ? kPasteboardClipboard : pasteboard.name.rawValue
            if PasteboardCreate(name as CFString, &board) == noErr, let board {
                PasteboardClear(board)
                for (index, item) in saved.enumerated() {
                    for (type, data) in item { PasteboardPutItemFlavor(board, UnsafeMutableRawPointer(bitPattern: index + 1)!, type.rawValue as CFString, data as CFData, []) }
                }
                return
            }
        }
        pasteboard.clearContents()
        let items = saved.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        if !items.isEmpty { pasteboard.writeObjects(items) }
    }
}

@MainActor final class InputMonitor {
    static let syntheticTag: Int64 = 0x5452414E53
    enum Action { case spaces, selection, automaticSelection, audio, undo }
    var onAction: ((Action) -> Void)?
    var onPointerInteraction: ((NSPoint) -> Void)?
    var onDismissSelection: (() -> Void)?
    var hasResultKeyboardFocus: (() -> Bool)?
    var settings: () -> AppSettings = { AppSettings() }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var mouseMonitor: Any?
    private var selectionTask: Task<Void, Never>?
    private var gesture = SpaceGesture()
    private var spaceSettling = SpaceTriggerSettling()
    private var spaceTask: Task<Void, Never>?
    private var mouseDownPoint: NSPoint?
    var active: Bool { tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    func start() {
        guard AccessibleText.trusted, !active else { return }
        if tap != nil { stop() }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue | 1 << CGEventType.keyUp.rawValue)
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<InputMonitor>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated { monitor.handle(type, event: event) }
        }, userInfo: pointer)
        if let tap {
            source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        if mouseMonitor == nil {
            mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
                // AppKit delivers event monitor handlers on the main thread.
                MainActor.assumeIsolated { self?.handleMouse(event) }
            }
        }
    }
    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }; mouseMonitor = nil
        selectionTask?.cancel(); gesture.reset(); mouseDownPoint = nil
        cancelPendingSpaces()
    }
    private func cancelPendingSpaces() { spaceTask?.cancel(); spaceTask = nil; spaceSettling.cancel(); gesture.reset() }
    private func awaitSettledSpaces(pid: pid_t?, count: Int) {
        spaceTask?.cancel()
        spaceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled, let self, self.spaceSettling.pending else { return }
                let config = self.settings(), now = ProcessInfo.processInfo.systemUptime
                guard config.enabled, config.fourSpacesEnabled, config.spaceCount == count,
                      self.hasResultKeyboardFocus?() != true,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                      !config.excludes(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""),
                      !IsSecureEventInputEnabled(), !self.spaceSettling.expired(at: now) else { self.cancelPendingSpaces(); return }
                if self.spaceSettling.ready(at: now) {
                    self.spaceSettling.cancel(); self.spaceTask = nil; self.gesture.reset()
                    self.onAction?(.spaces)
                    return
                }
            }
        }
    }
    private func handleMouse(_ event: NSEvent) {
        if event.type == .scrollWheel && abs(event.scrollingDeltaX) + abs(event.scrollingDeltaY) < 0.01 { return }
        cancelPendingSpaces()
        TextInteraction.changed(event.type == .scrollWheel ? .scroll : .pointer)
        let point = NSEvent.mouseLocation
        if event.type != .leftMouseUp {
            selectionTask?.cancel()
            onPointerInteraction?(point)
            mouseDownPoint = event.type == .leftMouseDown ? point : nil
            return
        }
        let start = mouseDownPoint; mouseDownPoint = nil
        guard settings().enabled, settings().selectionEnabled, settings().automaticSelection else { return }
        let dragged = start.map { hypot(point.x - $0.x, point.y - $0.y) >= 3 } ?? false
        guard dragged || event.clickCount >= 2 || event.modifierFlags.contains(.shift) else { return }
        let sourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        selectionTask?.cancel()
        selectionTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled, NSWorkspace.shared.frontmostApplication?.processIdentifier == sourcePID else { return }
            self?.onAction?(.automaticSelection)
        }
    }
    func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            cancelPendingSpaces(); return Unmanaged.passUnretained(event)
        }
        guard event.getIntegerValueField(.eventSourceUserData) != Self.syntheticTag else { return Unmanaged.passUnretained(event) }
        if TextInputGate.intercept(event) { return nil }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let modifiers = event.flags.rawValue & ((1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)) != 0
        if type == .keyUp {
            spaceSettling.observe(space: code == 49, keyDown: false, modifiers: modifiers, at: ProcessInfo.processInfo.systemUptime)
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier || hasResultKeyboardFocus?() == true { gesture.reset(); return Unmanaged.passUnretained(event) }
        let config = settings()
        guard config.enabled, !IsSecureEventInputEnabled(),
              !config.excludes(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "") else { gesture.reset(); return Unmanaged.passUnretained(event) }
        let flags = event.flags.rawValue
        let isCopy = code == 8 && event.flags.contains(.maskCommand)
        let isShortcut = config.selectionShortcut.matches(key: code, flags: flags) || config.audioShortcut.matches(key: code, flags: flags) || config.undoShortcut.matches(key: code, flags: flags)
        if !isCopy && !isShortcut {
            let kind: TextInteraction.Kind = code == 49 ? (event.getIntegerValueField(.keyboardEventAutorepeat) == 0 ? .space : .repeatingSpace)
                : modifiers ? .command : [UInt16(123), 124, 125, 126, 115, 119, 116, 121].contains(code) ? .navigation : .keyboard
            TextInteraction.changed(kind)
        }
        if code != 8 || !event.flags.contains(.maskCommand) {
            selectionTask?.cancel(); DispatchQueue.main.async { self.onDismissSelection?() }
        }
        if spaceSettling.pending {
            spaceSettling.observe(space: code == 49, keyDown: true, repeatKey: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, modifiers: modifiers, at: ProcessInfo.processInfo.systemUptime)
            if spaceSettling.pending { return Unmanaged.passUnretained(event) }
            cancelPendingSpaces()
        }
        let action: Action?
        if config.selectionEnabled && config.selectionShortcut.matches(key: code, flags: flags) { action = .selection }
        else if config.audioEnabled && config.audioShortcut.matches(key: code, flags: flags) { action = .audio }
        else if config.undoShortcut.matches(key: code, flags: flags) { action = .undo }
        else { action = nil }
        if let action {
            gesture.reset()
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { DispatchQueue.main.async { self.onAction?(action) } }
            return nil
        }
        let triggered = gesture.keyDown(isSpace: code == 49, isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, hasModifiers: flags & ((1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)) != 0, time: ProcessInfo.processInfo.systemUptime, interval: config.spaceInterval, requiredSpaces: config.spaceCount)
        if triggered && config.fourSpacesEnabled {
            let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
            spaceSettling.begin(at: ProcessInfo.processInfo.systemUptime)
            awaitSettledSpaces(pid: pid, count: config.spaceCount)
        }
        return Unmanaged.passUnretained(event)
    }
}
