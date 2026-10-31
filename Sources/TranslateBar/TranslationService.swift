import Foundation
import TranslateCore

@MainActor final class TranslationCacheController: ObservableObject {
    @Published private(set) var count = 0
    @Published private(set) var error: String?
    private(set) var generation = UUID()
    private let url: URL
    private var book = TranslationCacheBook()
    private var loadFailed = false
    private var accessTimesChanged = false
    init(url: URL = LocalFiles.directory.appendingPathComponent("translations.json")) {
        self.url = url
        if FileManager.default.fileExists(atPath: url.path) {
            do {
                let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
                guard size <= 128 * 1_024 * 1_024 else { throw AppError.message("缓存文件过大。") }
                book = try LocalFiles.read(TranslationCacheBook.self, from: url)
                count = book.count
            } catch { loadFailed = true; self.error = "缓存文件无法读取，未使用其中的译文。可清空缓存后重建。" }
        }
    }
    func lookup(_ key: TranslationCacheKey) -> String? {
        guard !loadFailed, let value = book.lookup(key) else { return nil }
        accessTimesChanged = true
        return value
    }
    func invalidatePendingWrites() { generation = UUID() }
    @discardableResult func insert(_ value: String, for key: TranslationCacheKey, generation expected: UUID) -> Bool {
        guard expected == generation, !loadFailed else { return false }
        var updated = book
        guard updated.insert(value, for: key) else { return false }
        do {
            try LocalFiles.write(updated, to: url)
            book = updated; count = updated.count; error = nil; accessTimesChanged = false
            return true
        } catch { self.error = "缓存保存失败，本次译文仍可使用。请检查本机存储空间。"; return false }
    }
    func clear() throws {
        invalidatePendingWrites()
        let empty = TranslationCacheBook()
        do {
            try LocalFiles.write(empty, to: url)
            book = empty; count = 0; error = nil; loadFailed = false; accessTimesChanged = false
        } catch {
            let message = "缓存清空失败，请检查缓存目录的写入权限。"
            self.error = message
            throw AppError.message(message)
        }
    }
    func flush() {
        guard accessTimesChanged, !loadFailed else { return }
        do { try LocalFiles.write(book, to: url); accessTimesChanged = false }
        catch { self.error = "缓存访问时间保存失败，已保存的译文仍可使用。" }
    }
}

struct ResolvedTranslation {
    let text: String
    let fromCache: Bool
}

@MainActor final class TextTranslationService {
    typealias Client = @MainActor (String, String, TextModel, String, Int, String) async throws -> TextTranslation
    private let cache: TranslationCacheController
    private let budget: BudgetController
    private let client: Client
    init(cache: TranslationCacheController, budget: BudgetController, client: @escaping Client = { text, target, model, key, maximum, source in
        try await OpenAIClient.translate(text, target: target, model: model, key: key, maxOutput: maximum, sourceLanguage: source)
    }) {
        self.cache = cache; self.budget = budget; self.client = client
    }
    func translate(_ text: String, target: String, model: TextModel, key: String, maxOutput: Int, configuration: BudgetConfiguration, useCache: Bool, sourceLanguage: String = "auto") async throws -> ResolvedTranslation {
        try Task.checkCancellation()
        guard !target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, target.count <= 100,
              !sourceLanguage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, sourceLanguage.count <= 100 else { throw AppError.message("请先在“语言”设置中填写有效的原文与目标语言。") }
        let instructions = OpenAIClient.instructions(target: target, sourceLanguage: sourceLanguage)
        let cacheKey = TranslationCacheKey(text: text, target: target, model: model.rawValue, instructions: instructions)
        guard !cacheKey.text.isEmpty else { throw AppError.message("没有需要翻译的文本。") }
        guard cacheKey.text.utf8.count <= 60_000 else { throw AppError.message("本次文本超过 60 KB，请分段翻译。") }
        // Free, local results work without a key, network, or remaining API budget.
        if useCache, let cached = cache.lookup(cacheKey) { return ResolvedTranslation(text: cached, fromCache: true) }
        guard model.canTranslateText else { throw AppError.message("请在“模型与 API”中填写有效的文字模型 ID。音频、图像等专用模型不能用于文字翻译。") }
        guard model.pricing.isValid else { throw AppError.message("请先在“模型与 API”中填写此模型的输入、缓存输入和输出费率，才能正确执行费用限额。") }
        guard !key.isEmpty else { throw AppError.message("请先在 API 设置中保存密钥。") }
        let generation = cache.generation
        let id = try budget.reserve(model.reservation(text: cacheKey.text, instructions: instructions, maxOutput: maxOutput), kind: .text, model: model.rawValue, configuration: configuration)
        do {
            let response = try await client(cacheKey.text, target, model, key, maxOutput, sourceLanguage)
            if response.inputTokens > 0 || response.outputTokens > 0 {
                try budget.settle(id, amount: model.cost(input: response.inputTokens, cached: response.cachedTokens, output: response.outputTokens), input: response.inputTokens, output: response.outputTokens)
            } else { budget.uncertain(id) }
            try Task.checkCancellation()
            guard response.completed, !response.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError.message("译文未完整生成，请缩短文本或提高输出上限。原文保持不变。") }
            if useCache { cache.insert(response.text, for: cacheKey, generation: generation) }
            return ResolvedTranslation(text: response.text, fromCache: false)
        } catch {
            if budget.book.record(id: id)?.status == .reserved { budget.uncertain(id) }
            throw error
        }
    }
}
