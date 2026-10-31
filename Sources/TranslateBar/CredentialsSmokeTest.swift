import Foundation
import TranslateCore

@MainActor enum CredentialsSmokeTest {
    static func importLegacy() async {
        var report: [String: Any] = ["success": false, "imported": false]
        do {
            let storage = KeychainCredentialStorage()
            let projectSelected = UserDefaults.standard.object(forKey: "useProjectKey") as? Bool ?? true
            if projectSelected, let active = KeyStore.environmentKey(in: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)) {
                try storage.save(active)
                guard try storage.load() == APIKeyInput.normalized(active) else { throw AppError.message("迁移后钥匙串验证失败。") }
                report["imported"] = true
            } else { guard let stored = try storage.load(), !(try APIKeyInput.normalized(stored)).isEmpty else { throw AppError.message("没有旧密钥可迁移，请在设置中粘贴。") } }
            UserDefaults.standard.set(false, forKey: "useProjectKey")
            report["success"] = true
        } catch { report["error"] = error.localizedDescription }
        output(report)
    }
    static func run() async {
        var report: [String: Any] = ["success": false]
        do {
            let controller = APIKeyController(); await controller.load()
            guard controller.configured else { throw AppError.message(controller.message) }
            report["loaded_from_keychain"] = true
            let models = try await OpenAIClient.listModels(key: controller.value)
            guard !models.isEmpty else { throw AppError.message("模型列表为空。") }
            report["authenticated"] = true; report["model_count"] = models.count
            let restarted = APIKeyController(); await restarted.load()
            report["key_survives_reload"] = restarted.value == controller.value
            report["development_directory_absent"] = Bundle.main.object(forInfoDictionaryKey: "TranslateBarDevelopmentDirectory") == nil
            report["success"] = restarted.configured && restarted.value == controller.value
        } catch { report["error"] = error.localizedDescription }
        output(report)
    }
    private static func output(_ report: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) { Swift.print(String(decoding: data, as: UTF8.self)) }
    }
}
