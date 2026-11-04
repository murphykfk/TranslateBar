import Foundation

public enum TextReplacementError: LocalizedError {
    case changed, invalidRange
    public var errorDescription: String? {
        switch self {
        case .changed: return "翻译期间原文已变化，未覆盖新内容。"
        case .invalidRange: return "文本范围已变化，未覆盖原文。"
        }
    }
}
