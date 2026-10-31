import Foundation

public enum TranslationLanguageMode: String, Codable, CaseIterable, Identifiable {
    case fixed, smart
    public var id: String { rawValue }
    public var title: String { self == .fixed ? "固定目标语言" : "智能互译" }
}

public struct TranslationLanguage: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let value: String
    public init(_ id: String, _ title: String, _ value: String) { self.id = id; self.title = title; self.value = value }
    public static let all: [Self] = [
        .init("zh-Hans", "简体中文", "简体中文"), .init("zh-Hant", "繁体中文", "繁體中文"), .init("en", "英语 · English", "English"),
        .init("ja", "日语 · 日本語", "日本語"), .init("ko", "韩语 · 한국어", "한국어"), .init("fr", "法语 · Français", "Français"),
        .init("de", "德语 · Deutsch", "Deutsch"), .init("es", "西班牙语 · Español", "Español"), .init("pt", "葡萄牙语 · Português", "Português"),
        .init("it", "意大利语 · Italiano", "Italiano"), .init("ru", "俄语 · Русский", "Русский"), .init("ar", "阿拉伯语 · العربية", "العربية"),
        .init("hi", "印地语 · हिन्दी", "हिन्दी"), .init("th", "泰语 · ไทย", "ไทย"), .init("vi", "越南语 · Tiếng Việt", "Tiếng Việt"),
        .init("id", "印尼语 · Bahasa Indonesia", "Bahasa Indonesia"), .init("tr", "土耳其语 · Türkçe", "Türkçe"), .init("nl", "荷兰语 · Nederlands", "Nederlands"),
        .init("pl", "波兰语 · Polski", "Polski"), .init("uk", "乌克兰语 · Українська", "Українська"), .init("sv", "瑞典语 · Svenska", "Svenska"),
        .init("da", "丹麦语 · Dansk", "Dansk"), .init("fi", "芬兰语 · Suomi", "Suomi"), .init("nb", "挪威语 · Norsk", "Norsk"),
        .init("el", "希腊语 · Ελληνικά", "Ελληνικά"), .init("cs", "捷克语 · Čeština", "Čeština"), .init("he", "希伯来语 · עברית", "עברית"),
        .init("ms", "马来语 · Bahasa Melayu", "Bahasa Melayu"), .init("ro", "罗马尼亚语 · Română", "Română"), .init("hu", "匈牙利语 · Magyar", "Magyar")
    ]
    // The existing, exercised realtime output languages. Text has a wider list.
    public static let audio = all.filter { ["zh-Hans", "en", "ja", "ko", "fr", "de", "es"].contains($0.id) }
    public static func find(_ value: String) -> Self? { all.first { $0.value == value || $0.id == value || ($0.id == "zh-Hans" && value == "zh") } }
    public static func display(_ value: String) -> String { find(value)?.title ?? value }
    public static func family(_ value: String) -> String? {
        find(value)?.id.split(separator: "-").first.map(String.init)
    }
    public static func matches(sourceCode: String?, target: String) -> Bool {
        guard let sourceCode, let targetCode = find(target)?.id else { return false }
        if targetCode.hasPrefix("zh-") { return sourceCode == targetCode }
        return sourceCode.split(separator: "-").first == targetCode.split(separator: "-").first
    }
}

public struct TranslationLanguageRoute: Equatable {
    public let target: String
    public let skip: Bool
    public init(target: String, fallback: String, mode: TranslationLanguageMode, sourceCode: String?, skipSame: Bool) {
        let same = TranslationLanguage.matches(sourceCode: sourceCode, target: target)
        self.target = mode == .smart && same && !TranslationLanguage.matches(sourceCode: sourceCode, target: fallback) ? fallback : target
        skip = skipSame && TranslationLanguage.matches(sourceCode: sourceCode, target: self.target)
    }
    public static func summary(target: String, fallback: String, mode: TranslationLanguageMode) -> String {
        if mode == .fixed { return "所有识别到的语种 → \(TranslationLanguage.display(target))" }
        return "\(TranslationLanguage.display(target)) → \(TranslationLanguage.display(fallback))；其他语种 → \(TranslationLanguage.display(target))"
    }
    public static func explanation(target: String, fallback: String, mode: TranslationLanguageMode, source: String, skipSame: Bool) -> String {
        let output = TranslationLanguage.display(target)
        let origin = source == "auto" ? "自动识别原文" : "原文按\(TranslationLanguage.display(source))处理"
        if mode == .smart {
            return "\(origin)。原文是\(output)时译为\(TranslationLanguage.display(fallback))，其他语言译为\(output)。"
        }
        return "\(origin) → \(output)。" + (skipSame ? "原文已是目标语言时跳过，不调用 API。" : "原文已是目标语言时仍会调用翻译。")
    }
}
