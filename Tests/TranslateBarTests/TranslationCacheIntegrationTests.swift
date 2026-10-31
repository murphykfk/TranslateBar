import XCTest
import TranslateCore
@testable import TranslateBar

@MainActor private final class PendingTranslationGate {
    let started: XCTestExpectation
    var continuation: CheckedContinuation<Void, Never>?
    init(_ started: XCTestExpectation) { self.started = started }
    func wait() async {
        await withCheckedContinuation { continuation in self.continuation = continuation; started.fulfill() }
    }
    func open() { continuation?.resume(); continuation = nil }
}

final class TranslationCacheIntegrationTests: XCTestCase {
    private func directory() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("TranslateBarCacheTests-\(UUID().uuidString)") }
    private static func response(_ text: String = "elephant", completed: Bool = true) -> TextTranslation {
        TextTranslation(text: text, inputTokens: 20, cachedTokens: 0, outputTokens: 5, completed: completed)
    }
    @MainActor func testSharedCacheSurvivesRestartWithoutKeyOrBudgetCharge() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("translations.json")
        let cache = TranslationCacheController(url: url)
        let budget = BudgetController(url: root.appendingPathComponent("usage.json"))
        var calls = 0
        let service = TextTranslationService(cache: cache, budget: budget) { _, _, _, _, _, _ in calls += 1; return Self.response() }
        let inputResult = try await service.translate("大象    ", target: "English", model: .nano, key: "test", maxOutput: 64, configuration: BudgetConfiguration(), useCache: true)
        XCTAssertFalse(inputResult.fromCache)
        let reloaded = TranslationCacheController(url: url)
        let restarted = TextTranslationService(cache: reloaded, budget: budget) { _, _, _, _, _, _ in calls += 1; return Self.response() }
        var exhausted = BudgetConfiguration(); exhausted.limit = 0.0000001; exhausted.buffer = 0
        let selectionResult = try await restarted.translate("大象", target: "English", model: .nano, key: "", maxOutput: 4096, configuration: exhausted, useCache: true)
        XCTAssertTrue(selectionResult.fromCache)
        XCTAssertEqual(selectionResult.text, inputResult.text)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(budget.book.records.count, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    @MainActor func testDisabledCacheBypassesReadsAndWrites() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = TranslationCacheController(url: root.appendingPathComponent("translations.json"))
        let budget = BudgetController(url: root.appendingPathComponent("usage.json"))
        var calls = 0
        let service = TextTranslationService(cache: cache, budget: budget) { _, _, _, _, _, _ in calls += 1; return Self.response("elephant-\(calls)") }
        for useCache in [true, false, false] {
            let result = try await service.translate("大象", target: "English", model: .nano, key: "test", maxOutput: 64, configuration: BudgetConfiguration(), useCache: useCache)
            XCTAssertFalse(result.fromCache)
        }
        let reused = try await service.translate("大象", target: "English", model: .nano, key: "", maxOutput: 64, configuration: BudgetConfiguration(), useCache: true)
        XCTAssertEqual(reused.text, "elephant-1")
        XCTAssertEqual(calls, 3)
        XCTAssertEqual(cache.count, 1)
    }
    @MainActor func testClearPersistsAndLeavesUsageHistoryIntact() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("translations.json")
        let cache = TranslationCacheController(url: url)
        let budget = BudgetController(url: root.appendingPathComponent("usage.json"))
        var calls = 0
        let service = TextTranslationService(cache: cache, budget: budget) { _, _, _, _, _, _ in calls += 1; return Self.response() }
        _ = try await service.translate("大象", target: "English", model: .nano, key: "test", maxOutput: 64, configuration: BudgetConfiguration(), useCache: true)
        try cache.clear()
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(TranslationCacheController(url: url).count, 0)
        XCTAssertEqual(budget.book.records.count, 1)
        _ = try await service.translate("大象", target: "English", model: .nano, key: "test", maxOutput: 64, configuration: BudgetConfiguration(), useCache: true)
        XCTAssertEqual(calls, 2)
    }
    @MainActor func testClearDuringRequestPreventsLateCacheRepopulation() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("translations.json")
        let cache = TranslationCacheController(url: url)
        let budget = BudgetController(url: root.appendingPathComponent("usage.json"))
        let gate = PendingTranslationGate(expectation(description: "request started"))
        let service = TextTranslationService(cache: cache, budget: budget) { _, _, _, _, _, _ in await gate.wait(); return Self.response() }
        let request = Task { try await service.translate("大象", target: "English", model: .nano, key: "test", maxOutput: 64, configuration: BudgetConfiguration(), useCache: true) }
        await fulfillment(of: [gate.started], timeout: 2)
        guard gate.continuation != nil else { request.cancel(); XCTFail("Request did not start"); return }
        try cache.clear(); gate.open()
        _ = try await request.value
        XCTAssertEqual(cache.count, 0)
        XCTAssertEqual(TranslationCacheController(url: url).count, 0)
    }
    @MainActor func testTurningCacheOffAndOnRejectsOldPendingWrite() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = TranslationCacheController(url: root.appendingPathComponent("translations.json"))
        let budget = BudgetController(url: root.appendingPathComponent("usage.json"))
        let gate = PendingTranslationGate(expectation(description: "request started"))
        let service = TextTranslationService(cache: cache, budget: budget) { _, _, _, _, _, _ in await gate.wait(); return Self.response() }
        let request = Task { try await service.translate("大象", target: "English", model: .nano, key: "test", maxOutput: 64, configuration: BudgetConfiguration(), useCache: true) }
        await fulfillment(of: [gate.started], timeout: 2)
        guard gate.continuation != nil else { request.cancel(); XCTFail("Request did not start"); return }
        cache.invalidatePendingWrites(); cache.invalidatePendingWrites(); gate.open()
        _ = try await request.value
        XCTAssertEqual(cache.count, 0)
    }
    @MainActor func testIncompleteResponseIsNotCached() async throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        let cache = TranslationCacheController(url: root.appendingPathComponent("translations.json"))
        let budget = BudgetController(url: root.appendingPathComponent("usage.json"))
        var calls = 0
        let service = TextTranslationService(cache: cache, budget: budget) { _, _, _, _, _, _ in calls += 1; return Self.response(completed: calls > 1) }
        do {
            _ = try await service.translate("大象", target: "English", model: .nano, key: "test", maxOutput: 64, configuration: BudgetConfiguration(), useCache: true)
            XCTFail("Incomplete output should fail")
        } catch { XCTAssertEqual(cache.count, 0) }
        let result = try await service.translate("大象", target: "English", model: .nano, key: "test", maxOutput: 64, configuration: BudgetConfiguration(), useCache: true)
        XCTAssertFalse(result.fromCache)
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(cache.count, 1)
    }
    @MainActor func testCorruptCacheIsPreservedUntilExplicitClear() throws {
        let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("translations.json")
        try Data("corrupt cache".utf8).write(to: url)
        let cache = TranslationCacheController(url: url)
        XCTAssertNotNil(cache.error)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "corrupt cache")
        try cache.clear()
        XCTAssertNil(TranslationCacheController(url: url).error)
        XCTAssertEqual(TranslationCacheController(url: url).count, 0)
    }
}
