import AppKit
import TranslateCore

@MainActor enum OfficeSmokeTest {
    static let source = "明天上午十点开会，请带上笔记本。"
    static let target = "The meeting starts at ten tomorrow morning."
    static func run() async {
        var report: [String: Any] = ["success": false, "api_calls": 0]
        var pendingUndo: TextSnapshot?
        let board = NSPasteboard.general
        let originalClipboard = signature(board)
        do {
            let context = try OfficeText.context()
            guard context.title.contains("TranslateBar-WPS-Test") else { throw AppError.message("只允许临时 WPS 测试文档。") }
            let snapshot = try await OfficeText.input(settings: AppSettings())
            guard snapshot.source == source, let state = snapshot.office, OfficeTextRules.samePrefix(state.raw, source + "    ") else { throw AppError.message("请在测试段落末尾保留四个空格并将光标放在句末。") }
            let undo = try await AccessibleText.replace(snapshot, with: target)
            pendingUndo = undo
            report["replacement_matches"] = undo.office?.raw == target
            let beforeFont = state.rich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            let afterFont = undo.office?.rich.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            report["before_size"] = beforeFont?.pointSize ?? -1
            report["after_size"] = afterFont?.pointSize ?? -1
            report["before_bold"] = beforeFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
            report["after_bold"] = afterFont?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
            _ = try await AccessibleText.replace(undo, with: undo.source)
            pendingUndo = nil
            let restored = try await OfficeText.input(settings: AppSettings())
            report["undo_restored"] = restored.office.map { OfficeTextRules.samePrefix($0.raw, state.raw) } ?? false
            TextInteraction.changed()
            do { _ = try await AccessibleText.replace(restored, with: "Should never be inserted"); throw AppError.message("活动变化保护未生效。") }
            catch TextReplacementError.changed { report["interaction_guard"] = true }
            let fresh = try await OfficeText.input(settings: AppSettings())
            guard let freshState = fresh.office else { throw TextReplacementError.invalidRange }
            let typed = TemporaryClipboard(text: "继续输入")
            OfficeText.key(9, flags: .maskCommand, to: fresh.pid)
            await OfficeText.pause(0.15)
            typed.restore()
            do { _ = try await AccessibleText.replace(fresh, with: "Should never be inserted"); throw AppError.message("继续输入保护未生效。") }
            catch TextReplacementError.changed { report["changed_text_guard"] = true }
            report["stage"] = "recover_fixture_after_conflict"
            let changed = try await OfficeText.prefix(freshState.context, collapse: false)
            report["conflict_actual_length"] = changed.length
            report["conflict_expected_length"] = (freshState.raw as NSString).length + 4
            let skeleton: (String) -> String = { String($0.filter { $0 != " " && $0 != "\u{00a0}" }) }
            guard skeleton(changed.string) == skeleton(freshState.raw + "继续输入") else { OfficeText.key(124, to: fresh.pid); throw TextReplacementError.changed }
            try await OfficeText.paste(freshState.rich, in: freshState.context)
            let recovered = try await OfficeText.prefix(freshState.context, collapse: true)
            report["fixture_restored_after_conflict"] = OfficeTextRules.samePrefix(recovered.string, freshState.raw)
            report["stage"] = "verify_document_and_clipboard"
            OfficeText.key(0, flags: .maskCommand, to: fresh.pid)
            await OfficeText.pause(0.05)
            let document = try await OfficeText.copiedSelection(freshState.context)
            let clipboardOwner = TemporaryClipboard(text: "TranslateBar clipboard fixture \(UUID().uuidString)")
            OfficeText.key(8, flags: .maskCommand, to: fresh.pid)
            await OfficeText.pause(0.10)
            let copiedPlain = board.string(forType: .string) ?? ""
            guard clipboardOwner.acceptCopiedText(copiedPlain), copiedPlain.contains(source) else { clipboardOwner.restore(); throw AppError.message("测试复制未完成。") }
            let legacySignature = signature(board)
            let temporary = TemporaryClipboard(text: "nested fixture copy")
            temporary.restore()
            report["wps_legacy_clipboard_formats_preserved"] = signature(board) == legacySignature
            _ = clipboardOwner.acceptCopiedText(copiedPlain)
            clipboardOwner.restore()
            OfficeText.key(124, to: fresh.pid)
            let expected = ["TranslateBar WPS compatibility test", source, source + "    ", "This document is a temporary local compatibility fixture."].joined(separator: "\n")
            let actual = document.string.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").trimmingCharacters(in: .newlines)
            report["surrounding_text_preserved"] = actual.components(separatedBy: "\n").map(OfficeTextRules.canonicalTrailingSpaces).joined(separator: "\n") == expected
            report["clipboard_restored"] = signature(board) == originalClipboard
            let checks = ["replacement_matches", "undo_restored", "interaction_guard", "changed_text_guard", "fixture_restored_after_conflict", "surrounding_text_preserved", "clipboard_restored", "wps_legacy_clipboard_formats_preserved"]
            guard checks.allSatisfy({ report[$0] as? Bool == true }), beforeFont?.pointSize == afterFont?.pointSize else { throw AppError.message("WPS 回填或恢复验证不一致。") }
            report["success"] = true
            report["stage"] = "complete"
        } catch {
            report["error"] = error.localizedDescription
            if let pendingUndo { _ = try? await AccessibleText.replace(pendingUndo, with: pendingUndo.source) }
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/wps-smoke-report.json"))
            Swift.print(String(decoding: data, as: UTF8.self))
        }
    }
    private static func signature(_ board: NSPasteboard) -> [[String: Data]] {
        ClipboardFormats.snapshot(board)?.map { item in Dictionary(uniqueKeysWithValues: item.map { ($0.0.rawValue, $0.1) }) } ?? []
    }
    static func flow(model: AppModel) async {
        var report: [String: Any] = ["success": false]
        let initialRecords = model.budget.book.records.count
        let initialCost = model.spent
        do {
            let context = try OfficeText.context()
            guard context.title.contains("TranslateBar-WPS-Test"), model.settings.wpsCompatibilityEnabled else { throw AppError.message("需要启用 WPS 兼容并聚焦临时测试文档。") }
            let initial = try await OfficeText.input(settings: model.settings)
            guard initial.source == source else { throw AppError.message("测试段落不匹配。") }
            model.translateInput()
            try await wait(model)
            guard model.lastMessage.hasPrefix("已替换译文"), !model.result.translation.isEmpty else { throw AppError.message(model.lastMessage) }
            report["input_translation_replaced"] = true
            report["input_from_cache"] = model.result.fromCache
            let translated = try await OfficeText.prefix(OfficeText.context(), collapse: true)
            let font = translated.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
            report["translated_font_size"] = font?.pointSize ?? -1
            report["translated_bold"] = font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false
            OfficeText.key(126, flags: [.maskCommand, .maskShift], to: initial.pid)
            await OfficeText.pause(0.05)
            model.translateSelection()
            try await wait(model)
            guard model.result.error == nil, !model.result.translation.isEmpty, model.result.translation != translated.string else { throw AppError.message(model.lastMessage) }
            report["selection_translation_completed"] = true
            report["selection_from_cache"] = model.result.fromCache
            model.dismissSelectionResult()
            OfficeText.key(124, to: initial.pid)
            await OfficeText.pause(0.05)
            model.handle(.undo)
            try await wait(model)
            let restored = try await OfficeText.input(settings: model.settings)
            guard let before = initial.office, let after = restored.office, OfficeTextRules.samePrefix(before.raw, after.raw) else { throw AppError.message("真实流程测试后原文未完整恢复。") }
            report["source_restored"] = true
            report["success"] = true
        } catch { report["error"] = error.localizedDescription; model.dismissSelectionResult() }
        report["new_usage_records"] = model.budget.book.records.count - initialRecords
        report["added_cost_usd"] = model.spent - initialCost
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/wps-flow-smoke-report.json"))
            Swift.print(String(decoding: data, as: UTF8.self)); fflush(stdout)
        }
        NSApp.terminate(nil)
    }
    private static func wait(_ model: AppModel) async throws {
        let deadline = Date().addingTimeInterval(50)
        while model.translating {
            guard Date() < deadline else { throw AppError.message("WPS 测试调用等待超时。") }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
