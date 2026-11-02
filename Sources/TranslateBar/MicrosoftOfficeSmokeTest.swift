import AppKit
import TranslateCore

/// Local integration checks, restricted to explicitly named synthetic Office
/// fixtures. These modes do not load credentials or call a translation API.
@MainActor enum MicrosoftOfficeSmokeTest {
    static let source = "明天上午十点开会，请带上笔记本。"
    static let target = "The meeting starts at ten tomorrow morning."

    static func run(inspectOnly: Bool, selectionOnly: Bool = false) async {
        var report: [String: Any] = ["success": false, "api_calls": 0]
        var pendingUndo: TextSnapshot?
        ReplacementDiagnostics.beginCapture()
        do {
            var settings = AppSettings()
            settings.spaceCount = 4
            let owner = try AccessibleText.activeApplication(settings: settings)
            let bundle = owner.bundleIdentifier ?? ""
            report["source_bundle"] = bundle
            guard ["com.microsoft.Word", "com.microsoft.Powerpoint", "com.microsoft.Excel"].contains(bundle) else {
                throw AppError.message("请聚焦专用 Office 测试文档。")
            }
            let application = AXUIElementCreateApplication(owner.processIdentifier)
            let window: AXUIElement? = AccessibleText.attribute(application, kAXFocusedWindowAttribute)
            let title: String = window.flatMap { AccessibleText.attribute($0, kAXTitleAttribute) } ?? ""
            guard title.hasPrefix("TranslateBar-MS-Test-") else { throw AppError.message("仅允许新建的 TranslateBar-MS-Test 临时文件。") }
            report["fixture_title"] = title
            let native = TextFocus.resolve(pid: owner.processIdentifier)
            if let native {
                report["native_role"] = AccessibleText.attribute(native, kAXRoleAttribute) as String? ?? ""
                report["native_caret"] = AccessibleText.selectedRange(native).map { [$0.location, $0.length] } ?? []
                report["native_value_length"] = AccessibleText.textValue(native)?.utf16.count ?? -1
                if let value = AccessibleText.textValue(native), value.contains(source) { report["native_value"] = value }
                let selected: String? = AccessibleText.attribute(native, kAXSelectedTextAttribute)
                report["native_selected_length"] = selected?.utf16.count ?? -1
            }
            if selectionOnly {
                let selected: TextSnapshot
                do { selected = try AccessibleText.selected(settings: settings) }
                catch { selected = try await ClipboardText.selected(settings: settings) }
                guard selected.source == source else { throw AppError.message("划词读取与固定测试文字不一致。") }
                report["selection_verified"] = true
            } else if inspectOnly {
                var context = try ClipboardText.context(settings: settings)
                if let document = MicrosoftTextRules.document(bundleID: bundle) {
                    context.microsoftDocument = document
                    context.documentPasteCommand = try await MicrosoftText.prepareInput(context, document: document)
                }
                try await TextInputGate.run(pid: context.pid) {
                    try ClipboardText.validate(context)
                    let flags: CGEventFlags = context.microsoftDocument.map {
                        MicrosoftTextRules.paragraphModifier(for: $0) == .command ? [.maskCommand, .maskShift] : [.maskAlternate, .maskShift]
                    } ?? [.maskCommand, .maskShift]
                    if context.microsoftDocument == .excel { OfficeText.key(115, flags: .maskShift, to: context.pid) }
                    else { OfficeText.key(context.microsoftDocument == nil ? 123 : 126, flags: flags, to: context.pid) }
                    defer { if (try? ClipboardText.validate(context)) != nil { OfficeText.key(124, to: context.pid) } }
                    await OfficeText.pause(0.06)
                    let board = NSPasteboard.general
                    let transaction = TemporaryClipboard(text: "TranslateBar synthetic Office clipboard probe")
                    defer { transaction.restore() }
                    OfficeText.key(8, flags: .maskCommand, to: context.pid)
                    await OfficeText.pause(0.12)
                    guard let plain = board.string(forType: .string), plain.contains(source) else { throw AppError.message("固定测试文字未复制成功。") }
                    report["clipboard_types"] = board.types?.map(\.rawValue) ?? []
                    if let raw = transaction.copiedRichText() {
                        report["raw_rich_text"] = raw.string
                        report["raw_rich_font"] = (raw.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? -1
                    }
                    let copied = transaction.takeCopiedRichText() ?? NSAttributedString(string: "")
                    guard copied.string.contains(source) else { throw AppError.message("选区不含固定测试原文，未继续。") }
                    report["copied_text"] = copied.string
                    report["copied_utf16_length"] = copied.length
                    report["copied_tail_scalars"] = copied.string.unicodeScalars.suffix(8).map(\.value)
                    report["copied_font"] = (copied.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize ?? -1
                    if let focused = TextFocus.resolve(pid: context.pid) {
                        report["selected_caret"] = AccessibleText.selectedRange(focused).map { [$0.location, $0.length] } ?? []
                        if let selected: String = AccessibleText.attribute(focused, kAXSelectedTextAttribute), selected.contains(source) {
                            report["native_selected_text"] = selected
                        }
                    }
                }
            } else {
                let snapshot: TextSnapshot
                do { snapshot = try AccessibleText.input(settings: settings) }
                catch { snapshot = try await ClipboardText.input(settings: settings) }
                report["captured_text"] = snapshot.source
                guard snapshot.source == source else { throw AppError.message("固定测试原文与实际取词范围不一致。") }
                let undo = try await AccessibleText.replace(snapshot, with: target)
                pendingUndo = undo
                report["replacement_verified"] = true
                report["after_font"] = undo.clipboard?.text.attribute(.font, at: 0, effectiveRange: nil).flatMap { ($0 as? NSFont)?.pointSize } ?? -1
                if let before = report["native_value"] as? String,
                   let focused = TextFocus.resolve(pid: owner.processIdentifier), let after = AccessibleText.textValue(focused) {
                    let expected = before.replacingOccurrences(of: "\u{a0}", with: " ").replacingOccurrences(of: source + String(repeating: " ", count: settings.spaceCount), with: target)
                    guard after.replacingOccurrences(of: "\u{a0}", with: " ") == expected else {
                        throw AppError.message("回填后周围文字与测试预期不一致。")
                    }
                    report["surrounding_text_verified"] = true
                }
                _ = try await AccessibleText.replace(undo, with: undo.source)
                pendingUndo = nil
                report["source_restored"] = true
                if let before = report["native_value"] as? String,
                   let focused = TextFocus.resolve(pid: owner.processIdentifier), let after = AccessibleText.textValue(focused) {
                    guard after.replacingOccurrences(of: "\u{a0}", with: " ") == before.replacingOccurrences(of: "\u{a0}", with: " ") else { throw AppError.message("撤销后的全文与原始测试文档不一致。") }
                    report["exact_restoration_verified"] = after == before
                    report["restoration_content_verified"] = true
                }
            }
            report["success"] = true
        } catch {
            report["error"] = error.localizedDescription
            report["failure"] = ReplacementDiagnostics.latestFailure ?? ""
            if let pendingUndo { report["recovered"] = (try? await AccessibleText.replace(pendingUndo, with: pendingUndo.source)) != nil }
        }
        await OfficeText.pause(0.15)
        report["checks"] = ReplacementDiagnostics.current?.checks.map { ["stage": $0.stage, "counts": $0.counts] as [String: Any] }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/office-live-reports")
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let bundle = report["source_bundle"] as? String ?? "unknown"
            let suffix = selectionOnly ? "selection" : (inspectOnly ? "read" : "replace")
            try? data.write(to: directory.appendingPathComponent("\(bundle)-\(suffix).json"), options: .atomic)
            Swift.print(String(decoding: data, as: UTF8.self))
        }
    }
}
