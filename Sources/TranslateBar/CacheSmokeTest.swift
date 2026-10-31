import Foundation
import TranslateCore

@MainActor enum CacheSmokeTest {
    static func run() async {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var report: [String: Any] = ["success": false, "date": ISO8601DateFormatter().string(from: Date())]
        do {
            let settingsURL = LocalFiles.directory.appendingPathComponent("settings.json")
            let settings = FileManager.default.fileExists(atPath: settingsURL.path) ? try LocalFiles.read(AppSettings.self, from: settingsURL) : AppSettings()
            guard settings.enabled, settings.cacheEnabled else { throw AppError.message("应用或缓存已关闭，未运行真实缓存测试。") }
            let projectKey = UserDefaults.standard.object(forKey: "useProjectKey") as? Bool ?? true
            let key = (projectKey ? KeyStore.environmentKey(in: root) : nil) ?? KeyStore.read()
            guard let key, !key.isEmpty else { throw AppError.message("未找到测试密钥。") }
            var configuration = settings.budget
            if !configuration.enabled { configuration.enabled = true; configuration.limit = 0.10; configuration.buffer = 0 }
            let budget = BudgetController(); let initialRecords = budget.book.records.count
            let cache = TranslationCacheController()
            let service = TextTranslationService(cache: cache, budget: budget)
            let text = "The elephant is walking slowly."
            let first = try await service.translate(text, target: "简体中文", model: settings.textModel, key: key, maxOutput: 128, configuration: configuration, useCache: true)
            let repeated = try await service.translate(text + "    ", target: "简体中文", model: settings.textModel, key: "", maxOutput: 4096, configuration: configuration, useCache: true)
            let reloaded = TranslationCacheController()
            let restarted = TextTranslationService(cache: reloaded, budget: budget)
            var exhausted = BudgetConfiguration(); exhausted.limit = 0.0000001; exhausted.buffer = 0
            let afterRestart = try await restarted.translate(text, target: "简体中文", model: settings.textModel, key: "", maxOutput: 4096, configuration: exhausted, useCache: true)
            let added = budget.book.records.count - initialRecords
            guard repeated.fromCache, afterRestart.fromCache, first.text == repeated.text, first.text == afterRestart.text,
                  added == (first.fromCache ? 0 : 1) else { throw AppError.message("缓存命中或调用次数验证失败。") }
            report["success"] = true
            report["translation"] = first.text
            report["initial_from_cache"] = first.fromCache
            report["repeated_from_cache"] = repeated.fromCache
            report["restart_from_cache"] = afterRestart.fromCache
            report["added_api_usage_records"] = added
            report["cache_entries"] = reloaded.count
            report["restart_hit_without_key_or_budget"] = true
            reloaded.flush()
        } catch { report["error"] = error.localizedDescription }
        if let json = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: root.appendingPathComponent(".build/cache-smoke-report.json"), options: .atomic)
            Swift.print(String(decoding: json, as: UTF8.self)); fflush(stdout)
        }
        exit(report["success"] as? Bool == true ? 0 : 1)
    }
}
