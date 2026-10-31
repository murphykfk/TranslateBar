import AppKit
import TranslateCore

@MainActor enum CompatibilitySmokeTest {
    static let source = "明天上午十点开会，请带上笔记本。"
    static let target = "The meeting starts at ten tomorrow morning."
    static func run() async {
        var report: [String: Any] = ["success": false, "api_calls": 0]
        do {
            let app = NSWorkspace.shared.frontmostApplication!
            report["frontmost_bundle"] = app.bundleIdentifier ?? "none"
            let application = AXUIElementCreateApplication(app.processIdentifier)
            guard let window: AXUIElement = AccessibleText.attribute(application, kAXFocusedWindowAttribute),
                  let title: String = AccessibleText.attribute(window, kAXTitleAttribute), title.contains("TranslateBar Compatibility · "),
                  let bundle = app.bundleIdentifier, ["com.murphy.CompatibilityFixture", "com.google.Chrome", "com.apple.Safari"].contains(bundle) else { throw AppError.message("仅允许独立兼容测试窗口。") }
            let mode = title.components(separatedBy: " · ").last!.components(separatedBy: " — ").first!.components(separatedBy: " - Google Chrome").first!
            report["case"] = mode; report["bundle"] = bundle
            var settings = AppSettings(); settings.inputScope = mode == "multiline" ? .paragraph : .field
            if ["secure", "password", "readonly"].contains(mode) {
                var rejected = false
                do { _ = try AccessibleText.input(settings: settings) } catch { rejected = true }
                guard rejected else { throw AppError.message("只读或密码控件未被拒绝。") }
                report["noneditable_rejected"] = true
            } else {
                let (initialElement, _) = try AccessibleText.focused(settings: settings)
                let initialValue = AccessibleText.textValue(initialElement)
                let snapshot: TextSnapshot
                do { snapshot = try AccessibleText.input(settings: settings) }
                catch { snapshot = try await ClipboardText.input(settings: settings) }
                guard snapshot.source.contains(source) else { throw AppError.message("测试原文不匹配。") }
                report["capture"] = snapshot.clipboard == nil ? "accessibility" : "clipboard-line"
                report["preserves_rich_text"] = snapshot.preservesRichText
                report["captured_caret"] = snapshot.selectionRange.map { [$0.location, $0.length] } ?? []
                report["current_caret"] = AccessibleText.selectedRange(snapshot.element).map { [$0.location, $0.length] } ?? []
                report["current_value_matches"] = AccessibleText.textValue(snapshot.element) == snapshot.fullValue
                report["value_length"] = snapshot.fullValue.map { ($0 as NSString).length } ?? -1
                report["ax_character_count"] = (AccessibleText.attribute(snapshot.element, kAXNumberOfCharactersAttribute) as Int?) ?? -1
                if bundle == "com.murphy.CompatibilityFixture" {
                    let context = try ClipboardText.context(settings: settings)
                    let caret = AccessibleText.selectedRange(context.element)
                    let line = try await ClipboardText.prefix(context, collapse: true)
                    try await ClipboardText.verifyCaret(context, line: line.string)
                    guard AccessibleText.selectedRange(context.element) == caret else { throw AppError.message("光标校验改变了测试光标位置。") }
                    report["caret_capability_probe_verified"] = true
                    report["caret_restored_after_probe"] = true
                }
                let replacement = snapshot.source.replacingOccurrences(of: source, with: target)
                let undo = try await AccessibleText.replace(snapshot, with: replacement)
                report["replacement_verified"] = true
                if bundle == "com.google.Chrome" || bundle == "com.apple.Safari" {
                    let event = hasText("已收到 input 事件；包含英文：true", in: window)
                    report["web_input_event_received"] = event
                    guard event else { throw AppError.message("网页未收到 input 事件。") }
                }
                if let rich = try? await AccessibleText.formattingSnapshot(undo), let value = rich.richText {
                    let body = (value.string as NSString).range(of: target)
                    let font = body.location != NSNotFound ? value.attribute(.font, at: body.location, effectiveRange: nil) as? NSFont : nil
                    report["body_font_size"] = font?.pointSize ?? -1
                    if mode == "rich" { guard font?.pointSize == 13, let heading = value.attribute(.font, at: 0, effectiveRange: nil) as? NSFont, heading.pointSize == 22, heading.fontDescriptor.symbolicTraits.contains(.bold) else { throw AppError.message("测试标题或正文格式发生变化。") }; report["heading_style_preserved"] = true }
                }
                _ = try await AccessibleText.replace(undo, with: undo.source)
                let restored: TextSnapshot
                if snapshot.clipboard != nil { restored = try await ClipboardText.input(settings: settings) }
                else { restored = try AccessibleText.input(settings: settings) }
                guard restored.source == snapshot.source, snapshot.fullValue == nil || snapshot.fullValue == restored.fullValue else { throw AppError.message("撤销未恢复原文或周围段落。") }
                report["undo_and_surrounding_text_restored"] = true
                guard initialValue == AccessibleText.textValue(restored.element) else { throw AppError.message("测试前后完整正文发生变化。") }
                let element = restored.element
                let currentRange = AccessibleText.selectedRange(element)
                if let full = restored.fullValue {
                    var atStart = CFRange(location: 0, length: 0)
                    if let value = AXValueCreate(.cfRange, &atStart), AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success,
                       AccessibleText.selectedRange(element) == NSRange(location: 0, length: 0) {
                        do { _ = try await AccessibleText.replace(restored, with: "Must not overwrite"); throw AppError.message("光标移动保护未生效。") }
                        catch TextReplacementError.changed { report["caret_move_rejected"] = true }
                        guard AccessibleText.textValue(element) == full else { throw AppError.message("光标保护后内容变化。") }
                    }
                }
                let full = snapshot.clipboard?.text.string ?? AccessibleText.textValue(element) ?? ""
                let range = (full as NSString).range(of: source)
                guard range.location != NSNotFound else { throw TextReplacementError.invalidRange }
                if snapshot.clipboard != nil { OfficeText.key(123, flags: [.maskCommand, .maskShift], to: restored.pid) }
                else {
                    var selected = CFRange(location: range.location, length: range.length)
                    guard let value = AXValueCreate(.cfRange, &selected), AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success else { throw AppError.message("无法准备测试选区。") }
                }
                await OfficeText.pause(0.05)
                let selectedText = try await ClipboardText.selected(settings: settings)
                guard selectedText.source.trimmingCharacters(in: .whitespacesAndNewlines) == source else { throw AppError.message("通用复制取词结果不一致。") }
                report["clipboard_selection_verified"] = true
                if let selected = try? AccessibleText.selected(settings: settings) { report["accessibility_selection_verified"] = selected.source.trimmingCharacters(in: .whitespacesAndNewlines) == source }
                if let currentRange { var range = CFRange(location: currentRange.location, length: currentRange.length); if let value = AXValueCreate(.cfRange, &range) { _ = AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) } }
            }
            report["success"] = true
        } catch { report["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/compatibility")
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let name = "\(report["bundle"] as? String ?? "unknown")-\(report["case"] as? String ?? "unknown").json"
            try? data.write(to: root.appendingPathComponent(name))
            Swift.print(String(decoding: data, as: UTF8.self))
        }
    }
    private static func hasText(_ text: String, in window: AXUIElement) -> Bool {
        var queue = [window], index = 0
        while index < queue.count, index < 180 {
            let node = queue[index]; index += 1
            if (AccessibleText.attribute(node, kAXValueAttribute) as String? ?? "") == text || (AccessibleText.attribute(node, kAXTitleAttribute) as String? ?? "") == text { return true }
            if let children: [AXUIElement] = AccessibleText.attribute(node, kAXChildrenAttribute) { queue.append(contentsOf: children.prefix(30)) }
        }
        return false
    }
    static func gate() async {
        var report: [String: Any] = ["success": false, "api_calls": 0]
        let monitor = InputMonitor()
        do {
            let context = try ClipboardText.context(settings: AppSettings())
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.murphy.CompatibilityFixture", context.title == "TranslateBar Compatibility · single",
                  AccessibleText.textValue(context.element) == source + "    " else { throw AppError.message("需要聚焦独立测试窗口的 single 用例。") }
            let clipboard = TemporaryClipboard(text: "a")
            defer { clipboard.restore(); monitor.stop() }
            monitor.start()
            guard monitor.active else { throw AppError.message("测试键盘监听未启动。") }
            let injection = Task {
                await OfficeText.pause(0.02)
                for down in [true, false] {
                    let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .combinedSessionState), virtualKey: 9, keyDown: down)
                    event?.flags = .maskCommand
                    event?.setIntegerValueField(.eventSourceUserData, value: 0x544247415445)
                    event?.post(tap: .cgSessionEventTap)
                }
            }
            do { _ = try await ClipboardText.input(settings: AppSettings()); throw AppError.message("复制期间的输入未取消翻译。") }
            catch TextReplacementError.changed { report["capture_cancelled_before_api"] = true }
            await injection.value
            await OfficeText.pause(0.2)
            guard AccessibleText.textValue(context.element) == source + "    a" else { throw AppError.message("连续输入未在恢复光标后完整回放。") }
            report["queued_input_appended_after_original"] = true
            report["success"] = true
        } catch { report["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/compatibility/gate.json"))
            Swift.print(String(decoding: data, as: UTF8.self))
        }
    }
    static func flow(model: AppModel) async {
        var report: [String: Any] = ["success": false]
        let records = model.budget.book.records.count, cost = model.spent
        do {
            let context = try ClipboardText.context(settings: model.settings)
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.murphy.CompatibilityFixture", context.title == "TranslateBar Compatibility · opaque" else { throw AppError.message("需要独立测试窗口的 opaque 用例。") }
            let initial = try await ClipboardText.input(settings: model.settings)
            guard initial.source == source else { throw AppError.message("测试原文不匹配。") }
            model.translateInput(); try await wait(model)
            guard model.lastMessage.hasPrefix("已替换译文"), model.result.error == nil, !model.result.translation.isEmpty else { throw AppError.message(model.lastMessage) }
            report["input_replaced_via_general_fallback"] = true
            report["input_from_cache"] = model.result.fromCache
            if CommandLine.arguments.contains("--interaction-review") {
                guard model.inputFeedback.id == nil else { throw AppError.message("输入替换完成后过程提示未隐藏。") }
                report["input_feedback_hidden_after_replacement"] = true
            }
            OfficeText.key(123, flags: [.maskCommand, .maskShift], to: context.pid)
            await OfficeText.pause(0.05)
            model.translateSelection(); try await wait(model)
            guard model.result.error == nil, !model.result.translation.isEmpty else { throw AppError.message(model.lastMessage) }
            report["selection_translation_completed"] = true
            if CommandLine.arguments.contains("--interaction-review") {
                guard model.result.excludeApplication != nil else { throw AppError.message("划词浮窗未提供来源应用操作。") }
                report["selection_source_action_available"] = true
                try await Task.sleep(for: .seconds(5))
            }
            model.dismissSelectionResult()
            OfficeText.key(124, to: context.pid); await OfficeText.pause(0.05)
            model.handle(.undo); try await wait(model)
            if CommandLine.arguments.contains("--interaction-review") {
                guard model.inputFeedback.id == nil else { throw AppError.message("撤销完成后仍有提示。") }
                report["input_feedback_hidden_after_undo"] = true
            }
            let restored = try await ClipboardText.input(settings: model.settings)
            guard let before = initial.clipboard, let after = restored.clipboard, OfficeTextRules.samePrefix(before.text.string, after.text.string) else { throw AppError.message("通用流程未恢复原文。") }
            report["source_restored"] = true; report["success"] = true
        } catch { report["error"] = error.localizedDescription; model.dismissSelectionResult() }
        report["new_usage_records"] = model.budget.book.records.count - records
        report["added_cost_usd"] = model.spent - cost
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/compatibility/app-flow.json"))
            Swift.print(String(decoding: data, as: UTF8.self)); fflush(stdout)
        }
        NSApp.terminate(nil)
    }
    private static func wait(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(50)
        while model.translating {
            guard Date() < deadline else { throw AppError.message("兼容测试等待超时。") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
