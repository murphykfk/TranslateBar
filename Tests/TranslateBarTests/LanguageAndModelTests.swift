import AppKit
import XCTest
import TranslateCore
@testable import TranslateBar

final class LanguageAndModelTests: XCTestCase {
    func testLanguageDetectionAndManualOverride() {
        XCTAssertEqual(LanguageResolver.sourceCode(text: "The meeting starts at ten tomorrow morning.", preference: "auto"), "en")
        XCTAssertEqual(LanguageResolver.sourceCode(text: "明天上午十点开会，请带上笔记本。", preference: "auto")?.prefix(2), "zh")
        XCTAssertNil(LanguageResolver.sourceCode(text: "OK", preference: "auto"))
        XCTAssertNil(LanguageResolver.sourceCode(text: "明天上午十点 meeting starts at ten tomorrow morning", preference: "auto"))
        XCTAssertEqual(LanguageResolver.sourceCode(text: "OK", preference: "日本語"), "ja")
    }
    func testCustomPayloadDoesNotSendUnsupportedReasoningOption() {
        let custom = OpenAIClient.textPayload("hello", target: "日本語", model: .named("gpt-4.1"), maxOutput: 64)
        XCTAssertNil(custom["reasoning"]); XCTAssertEqual(custom["store"] as? Bool, false)
        let builtIn = OpenAIClient.textPayload("hello", target: "日本語", model: .nano, maxOutput: 64)
        XCTAssertEqual((builtIn["reasoning"] as? [String: String])?["effort"], "none")
    }
    @MainActor func testUnpricedModelBlocksBeforeNetworkAndReservation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let budget = BudgetController(url: root.appendingPathComponent("usage.json"))
        var calls = 0
        let service = TextTranslationService(cache: TranslationCacheController(url: root.appendingPathComponent("cache.json")), budget: budget) { _, _, _, _, _, _ in calls += 1; return .init(text: "test", inputTokens: 1, cachedTokens: 0, outputTokens: 1, completed: true) }
        do { _ = try await service.translate("hello", target: "日本語", model: .named("gpt-4.1"), key: "test", maxOutput: 64, configuration: .init(), useCache: false); XCTFail("Should require model pricing") } catch {}
        XCTAssertEqual(calls, 0); XCTAssertTrue(budget.book.records.isEmpty)
    }
    @MainActor func testManualSourceSeparatesCacheAndUsesConfiguredModelRates() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let budget = BudgetController(url: root.appendingPathComponent("usage.json"))
        var sources: [String] = []
        let service = TextTranslationService(cache: TranslationCacheController(url: root.appendingPathComponent("cache.json")), budget: budget) { _, _, _, _, _, source in sources.append(source); return .init(text: "translated", inputTokens: 1000, cachedTokens: 500, outputTokens: 100, completed: true) }
        let custom = TextModel(id: "gpt-4.1", pricing: .init(input: 2, cached: 1, output: 8))
        _ = try await service.translate("gift", target: "简体中文", model: custom, key: "test", maxOutput: 128, configuration: .init(), useCache: true)
        _ = try await service.translate("gift", target: "简体中文", model: custom, key: "test", maxOutput: 128, configuration: .init(), useCache: true, sourceLanguage: "Deutsch")
        let cached = try await service.translate("gift", target: "简体中文", model: custom, key: "", maxOutput: 128, configuration: .init(), useCache: true, sourceLanguage: "Deutsch")
        XCTAssertTrue(cached.fromCache); XCTAssertEqual(sources, ["auto", "Deutsch"])
        XCTAssertEqual(budget.book.spent(configuration: .init()), 0.0046, accuracy: 1e-9)
    }
    @MainActor func testRichReplacementRemovesExactlyTheConfiguredGestureSpaces() throws {
        for count in 2...4 {
            let source = NSAttributedString(string: "原文" + String(repeating: " ", count: count), attributes: [.font: NSFont.systemFont(ofSize: 13)])
            let result = try RichTextReplacement.translated("Translation", preserving: source, removingTriggerSpaces: true, triggerSpaceCount: count)
            XCTAssertEqual(result.string, "Translation")
        }
    }
}
