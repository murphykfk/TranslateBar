import Foundation
import Combine
import TranslateCore

protocol CredentialStorage: Sendable {
    func load(allowInteraction: Bool) throws -> String?
    func save(_ value: String) throws
    func remove() throws
}

@MainActor final class APIKeyController: ObservableObject {
    @Published private(set) var configured = false
    @Published private(set) var busy = false
    @Published private(set) var didLoad = false
    @Published private(set) var message = "粘贴你的 API Key 后，保存到本机钥匙串。"
    @Published private(set) var error: String?
    @Published private(set) var requiresStorageRetry = false
    private(set) var value = ""
    private(set) var revision = UUID()
    var onChange: (() -> Void)?
    private let storage: any CredentialStorage

    init(storage: any CredentialStorage = KeychainCredentialStorage()) { self.storage = storage }
    private func commit(_ key: String, message: String) {
        let changed = value != key
        value = key; configured = !key.isEmpty; self.message = message; error = nil; requiresStorageRetry = false
        if changed { revision = UUID(); onChange?() }
    }
    func load(allowInteraction: Bool = false) async {
        guard !busy else { return }
        busy = true; error = nil; requiresStorageRetry = false; message = "正在读取本机钥匙串…"
        defer { busy = false; didLoad = true }
        let storage = storage
        do {
            let loaded = try await Task.detached { try storage.load(allowInteraction: allowInteraction) }.value
            if let loaded { commit(try APIKeyInput.normalized(loaded), message: "已从本机钥匙串读取密钥。") }
            else { commit("", message: "尚未配置。请粘贴你的 OpenAI API Key。") }
        } catch { requiresStorageRetry = true; self.error = error.localizedDescription; message = error.localizedDescription }
    }
    @discardableResult func save(_ input: String) async -> Bool {
        guard !busy else { return false }
        let key: String
        do { key = try APIKeyInput.normalized(input) }
        catch { requiresStorageRetry = false; self.error = error.localizedDescription; message = error.localizedDescription; return false }
        busy = true; error = nil; requiresStorageRetry = false; message = "正在保存到本机钥匙串…"
        defer { busy = false; didLoad = true }
        let storage = storage
        do {
            try await Task.detached { try storage.save(key) }.value
            commit(key, message: "API Key 已保存。可点击“测试连接”确认能否调用。")
            return true
        } catch { requiresStorageRetry = true; self.error = error.localizedDescription; message = error.localizedDescription; return false }
    }
    @discardableResult func remove() async -> Bool {
        guard !busy else { return false }
        busy = true; error = nil; requiresStorageRetry = false; message = "正在移除本机密钥…"
        defer { busy = false; didLoad = true }
        let storage = storage
        do {
            try await Task.detached { try storage.remove() }.value
            commit("", message: "已移除本机密钥。粘贴新的 API Key 后即可重新连接。")
            return true
        } catch { requiresStorageRetry = true; self.error = error.localizedDescription; message = error.localizedDescription; return false }
    }
    func clearInputError() {
        guard error != nil, !requiresStorageRetry else { return }
        error = nil
        message = configured ? "API Key 已保存。可点击“测试连接”确认能否调用。" : "粘贴你的 API Key 后，保存到本机钥匙串。"
    }
}
