import Foundation

public enum APIKeyInput {
    public enum InputError: LocalizedError {
        case empty, invalid
        public var errorDescription: String? {
            switch self {
            case .empty: return "请粘贴你的 OpenAI API Key。"
            case .invalid: return "请只粘贴 API Key，不要包含变量名、网址、空格或换行。"
            }
        }
    }
    public static func normalized(_ input: String) throws -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("bearer ") { value = String(value.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if value.count >= 2, let first = value.first, let last = value.last, first == last, first == "\"" || first == "'" { value = String(value.dropFirst().dropLast()) }
        guard !value.isEmpty else { throw InputError.empty }
        guard value.utf8.count <= 4096, !value.contains("="), !value.contains("://"),
              value.unicodeScalars.allSatisfy({ (33...126).contains($0.value) && ![34, 39, 92, 96].contains($0.value) }) else { throw InputError.invalid }
        // Key formats and lengths may change; authentication is checked by the API.
        return value
    }
}
