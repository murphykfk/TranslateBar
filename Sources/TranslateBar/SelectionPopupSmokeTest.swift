import AppKit
import TranslateCore

@MainActor enum SelectionPopupSmokeTest {
    static func run(model: AppModel) async {
        let text = "TranslateBar comment fixture: the meeting starts at ten tomorrow morning."
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var report: [String: Any] = ["success": false, "scope": "Real popup and accessibility watcher on the owned local comment fixture; no translation API call."]
        report["foreground_bundle"] = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "unknown"
        let originalHide = model.hideResult
        var hiddenAt: Double?
        let started = ProcessInfo.processInfo.systemUptime
        let fixtureStart = (try? LocalFiles.read([String: Double].self, from: root.appendingPathComponent(".build/selection-fixture-start.json")))?["startedAt"].map { Date(timeIntervalSince1970: $0 / 1000) }
        var dismissalReason: String?
        model.onSelectionDismissal = { dismissalReason = $0 }
        model.monitor.stop()
        model.hideResult = { hiddenAt = ProcessInfo.processInfo.systemUptime - started; originalHide?() }
        defer { model.hideResult = originalHide; model.onSelectionDismissal = nil }
        do {
            let snapshot = try AccessibleText.selected(settings: model.settings)
            guard let fixtureStart, Date().timeIntervalSince(fixtureStart) < 5 else { throw AppError.message("测试页计时已过期，请重新开始。") }
            guard snapshot.source == text else { throw AppError.message("请先在本机评论测试页选中专用句子。") }
            model.result.title = "划词翻译 · 本机验证"
            model.result.source = text
            model.result.translation = "测试译文：会议明天上午十点开始。（未调用 API）"
            model.result.busy = false; model.result.error = nil
            _ = model.trackSelectionResult(snapshot)
            model.showResult?()
            for _ in 0..<65 {
                try await Task.sleep(for: .milliseconds(200))
                if let hiddenAt {
                    report["hidden_after_seconds"] = hiddenAt
                    let fixtureElapsed = Date().timeIntervalSince(fixtureStart)
                    report["hidden_fixture_seconds"] = fixtureElapsed
                    report["dismissal_reason"] = dismissalReason ?? "unknown"
                    guard fixtureElapsed >= 10.5, dismissalReason == "selection_cleared" else { throw AppError.message("评论节点刷新期间浮窗提前隐藏。") }
                    report["survived_comment_refresh"] = true
                    report["confirmed_deselect_auto_hid"] = true
                    report["success"] = true
                    break
                }
            }
            guard report["success"] as? Bool == true else { throw AppError.message("取消选中后浮窗未自动隐藏。") }
        } catch { report["error"] = error.localizedDescription }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent(".build/selection-popup-smoke-report.json"), options: .atomic)
            Swift.print(String(decoding: data, as: UTF8.self)); fflush(stdout)
        }
        NSApp.terminate(nil)
    }
}
