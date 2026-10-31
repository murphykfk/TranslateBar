import AppKit
import Security
import LocalAuthentication
import TranslateCore

enum LocalFiles {
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("TranslateBar", isDirectory: true)
    }
    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(type, from: Data(contentsOf: url))
    }
}

struct KeychainCredentialStorage: CredentialStorage {
    var service = "com.murphy.TranslateBar.openai.user-key"
    var account = "OPENAI_API_KEY"
    private var query: [String: Any] { [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account] }
    func load(allowInteraction: Bool = false) throws -> String? {
        var query = query
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowInteraction { let context = LAContext(); context.interactionNotAllowed = true; query[kSecUseAuthenticationContext as String] = context }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw AppError.message("无法读取钥匙串。请点击“解锁 / 重试”，按系统提示授权，或重新保存密钥。")
        }
        return key
    }
    func save(_ value: String) throws {
        let key = try APIKeyInput.normalized(value)
        let data = Data(key.utf8)
        let update = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var item = query; item[kSecValueData as String] = data; item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw AppError.message("无法把 API Key 保存到钥匙串，请检查系统授权后重试。") }
        } else if update != errSecSuccess { throw AppError.message("无法更新钥匙串中的 API Key。原有密钥已保留，请检查系统授权。") }
    }
    func remove() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AppError.message("无法移除钥匙串中的 API Key，请检查系统授权。") }
    }
}

enum KeyStore {
    static func read(allowInteraction: Bool = false) -> String? { try? KeychainCredentialStorage().load(allowInteraction: allowInteraction) }
    static func save(_ value: String) throws { try KeychainCredentialStorage().save(value) }
    // Explicit developer smoke tests and the one-time migration command only.
    static func environmentKey(in directory: URL) -> String? {
        guard let content = try? String(contentsOf: directory.appendingPathComponent(".env"), encoding: .utf8) else { return nil }
        for line in content.components(separatedBy: .newlines) {
            let cleaned = line.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "^export\\s+", with: "", options: .regularExpression)
            let parts = cleaned.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces) == "OPENAI_API_KEY" {
                let value = parts[1].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

@MainActor final class BudgetController: ObservableObject {
    @Published private(set) var book: BudgetBook
    private let url: URL
    private var storageError = false
    init(url: URL = LocalFiles.directory.appendingPathComponent("usage.json")) {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            do { book = try LocalFiles.read(BudgetBook.self, from: url) } catch { book = BudgetBook(); storageError = true }
        } else { book = BudgetBook() }
        book.recoverInterruptedReservations()
        if !storageError { do { try LocalFiles.write(book, to: url) } catch { storageError = true } }
    }
    private func transaction<T>(_ change: (inout BudgetBook) throws -> T) throws -> T {
        guard !storageError else { throw AppError.message("无法读取或保存费用记录，已阻止 API 调用。请检查应用支持目录。") }
        var updated = book
        let result = try change(&updated)
        try LocalFiles.write(updated, to: url)
        book = updated
        return result
    }
    func reserve(_ amount: Double, kind: UsageKind, model: String, configuration: BudgetConfiguration) throws -> UUID {
        try transaction { try $0.reserve(amount: amount, kind: kind, model: model, configuration: configuration) }
    }
    func extend(_ id: UUID, by amount: Double, configuration: BudgetConfiguration) throws {
        try transaction { try $0.extend(id: id, by: amount, configuration: configuration) }
    }
    func settle(_ id: UUID, amount: Double, input: Int? = nil, output: Int? = nil, seconds: Double? = nil) throws {
        try transaction { try $0.settle(id: id, amount: amount, input: input, output: output, seconds: seconds) }
    }
    func uncertain(_ id: UUID) { try? transaction { $0.markUncertain(id: id) } }
}
