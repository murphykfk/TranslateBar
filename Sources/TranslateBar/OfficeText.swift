import AppKit
import ApplicationServices
import Carbon
import TranslateCore

@MainActor enum TextInteraction {
    enum Kind: String { case keyboard, space, repeatingSpace, navigation, command, pointer, scroll, replay, other }
    static var revision: UInt64 = 0
    /// Ignores scrolling, which moves neither the caret nor the text.
    static var editRevision: UInt64 = 0
    static var lastKind: Kind = .other
    static func changed(_ kind: Kind = .other) { revision &+= 1; if kind != .scroll { editRevision &+= 1 }; lastKind = kind }
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
    static func selected(settings: AppSettings) async throws -> TextSnapshot {
        let expected = try context()
        let rich = try await copiedSelection(expected)
        let mouse = NSEvent.mouseLocation
        let state = OfficeSnapshot(context: expected, raw: rich.string, rich: rich, anchor: NSRect(x: mouse.x - 8, y: mouse.y - 8, width: 16, height: 16))
        return TextSnapshot(element: expected.window, pid: expected.pid, value: rich.string, range: NSRange(location: 0, length: rich.length), source: rich.string, fullValue: nil, office: state)
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
