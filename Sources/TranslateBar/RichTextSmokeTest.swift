import AppKit
import TranslateCore

@MainActor enum RichTextSmokeTest {
    static let source = "TranslateBar 格式测试：明天上午十点开会。"
    static let translation = "TranslateBar formatting test: the meeting is at ten tomorrow morning."
    static func run(model: AppModel) async {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var report: [String: Any] = ["success": false, "scope": "User-authorized current Apple Notes page, known temporary fixture text only; no API call. Original text restored after replacement."]
        model.monitor.stop()
        var pendingUndo: TextSnapshot?
        var simulatedRelease: Task<Void, Never>?
        defer { simulatedRelease?.cancel() }
        do {
            let cycles = CommandLine.arguments.contains("--repeat-notes") ? 20 : 1
            report["completed_cycles"] = 0
            report["synchronized_cycles"] = 0
            for cycle in 0..<cycles {
                report["cycle"] = cycle + 1
                let settings = model.settings
                let raw = try AccessibleText.input(settings: settings)
                report["source_bundle"] = NSRunningApplication(processIdentifier: raw.pid)?.bundleIdentifier ?? "unknown"
                report["direct_format_available"] = raw.richText != nil
                let paragraphTest = CommandLine.arguments.contains("--paragraph-only-test")
                let expectedSource = paragraphTest ? "刘德华" : source
                guard NSRunningApplication(processIdentifier: raw.pid)?.bundleIdentifier == "com.apple.Notes", raw.source.contains(expectedSource) else { throw RichTextReplacementError.unavailable }
                if cycles > 1 || paragraphTest { guard raw.fullValue?.hasPrefix("TranslateBar Notes Debug") == true else { throw AppError.message("重复测试仅允许专用测试便笺。") } }
                var snapshot = try await AccessibleText.formattingSnapshot(raw)
                guard NSRunningApplication(processIdentifier: snapshot.pid)?.bundleIdentifier == "com.apple.Notes",
                      snapshot.source.contains(expectedSource), let original = snapshot.richText else { throw RichTextReplacementError.unavailable }
                let before = profiles(original)
                report["before"] = before
                if CommandLine.arguments.contains("--simulate-trigger-caret") {
                    guard raw.fullValue?.hasPrefix("TranslateBar Notes Debug") == true, let full = snapshot.fullValue, full.hasSuffix("   ") else { throw AppError.message("需要专用备忘录测试页，且句末有三次空格。") }
                    let caretOnly = cycles > 1 && cycle % 2 == 1
                    let captured = caretOnly ? full : String(full.dropLast()), length = captured.utf16.count
                    let caret = caretOnly ? length - 1 : length
                    let range = NSRange(location: snapshot.range.location, length: snapshot.range.length - (caretOnly ? 0 : 1))
                    let fragment = (captured as NSString).substring(with: range)
                    snapshot = TextSnapshot(element: snapshot.element, pid: snapshot.pid, value: captured, range: range, source: fragment.trimmingCharacters(in: .whitespacesAndNewlines), fullValue: captured, allowTrailingSpaces: true, identity: snapshot.identity, selectionRange: NSRange(location: caret, length: 0), richText: original.attributedSubstring(from: NSRange(location: 0, length: range.length)), preservesRichText: true, triggerSpaceCount: 3, interactionRevision: snapshot.interactionRevision)
                    report["pending_trigger_space"] = true
                    report["caret_only_cycles"] = (report["caret_only_cycles"] as? Int ?? 0) + (caretOnly ? 1 : 0)
                }
                let target = paragraphTest ? "Andy Lau" : snapshot.source.replacingOccurrences(of: source, with: translation).replacingOccurrences(of: "母猪", with: "Sow")
                report["stage"] = "replace"
                if CommandLine.arguments.contains("--simulate-trigger-release") {
                    simulatedRelease = Task {
                        await OfficeText.pause(0.01)
                        guard !Task.isCancelled, let event = CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: false) else { return }
                        report["trigger_release_intercepted"] = TextInputGate.intercept(event)
                    }
                }
                let replaced = try await AccessibleText.replace(snapshot, with: target)
                if paragraphTest {
                    guard let before = raw.fullValue, let after = replaced.fullValue,
                          (before as NSString).substring(to: raw.range.location) == (after as NSString).substring(to: raw.range.location),
                          replaced.source.trimmingCharacters(in: .whitespacesAndNewlines) == "刘德华" else { throw AppError.message("前文或段落替换范围发生变化。") }
                    report["previous_paragraphs_unchanged"] = true
                }
                if ReplacementDiagnostics.current?.checks.contains(where: { $0.stage == "trigger_caret_synchronized" }) == true {
                    report["synchronized_cycles"] = (report["synchronized_cycles"] as? Int ?? 0) + 1
                }
                await simulatedRelease?.value
                simulatedRelease = nil
                pendingUndo = replaced
                report["stage"] = "verify_style"
                let undo = try await AccessibleText.formattingSnapshot(replaced)
                pendingUndo = undo
                guard let after = undo.richText else { throw RichTextReplacementError.unavailable }
                report["after"] = profiles(after)
                guard NSDictionary(dictionary: ["profiles": before]).isEqual(to: ["profiles": profiles(after)]) else { throw AppError.message("回填后的字号或粗细与原文不同。") }
                let restored = try await AccessibleText.formattingSnapshot(AccessibleText.replace(undo, with: undo.source))
                pendingUndo = nil
                guard restored.fullValue == raw.fullValue, let restoredRich = restored.richText,
                      NSDictionary(dictionary: ["profiles": before]).isEqual(to: ["profiles": profiles(restoredRich)]) else { throw AppError.message("测试原文或格式未完整恢复。") }
                report["source_and_style_restored"] = true
                report["stage"] = "complete"
                report["completed_cycles"] = cycle + 1
            }
            report["success"] = true
        } catch {
            report["success"] = false
            report["error"] = error.localizedDescription
            report["failure_check"] = ReplacementDiagnostics.latestFailure
            if let pendingUndo { report["recovery_attempted"] = true; _ = try? await AccessibleText.replace(pendingUndo, with: pendingUndo.source) }
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent(".build/rich-text-smoke-report.json"), options: .atomic)
            Swift.print(String(decoding: data, as: UTF8.self)); fflush(stdout)
        }
        NSApp.terminate(nil)
    }
    private static func profiles(_ text: NSAttributedString) -> [[String: Any]] {
        RichTextReplacement.paragraphs(text.string).filter { $0.content.length > 0 }.map { paragraph in
            let font = text.attribute(.font, at: paragraph.content.location, effectiveRange: nil) as? NSFont
            return ["size": font?.pointSize ?? -1, "bold": font?.fontDescriptor.symbolicTraits.contains(.bold) ?? false]
        }
    }
}
