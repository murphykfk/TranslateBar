import XCTest
@testable import TranslateCore

final class BudgetTests: XCTestCase {
    func testSharedReservationsCannotOverspendAcrossFeatures() throws {
        var book = BudgetBook(); var config = BudgetConfiguration(); config.limit = 1; config.buffer = 0.1
        _ = try book.reserve(amount: 0.5, kind: .text, model: "test", configuration: config)
        _ = try book.reserve(amount: 0.35, kind: .audio, model: "test", configuration: config)
        XCTAssertThrowsError(try book.reserve(amount: 0.06, kind: .text, model: "test", configuration: config))
        XCTAssertEqual(book.spent(configuration: config), 0.85, accuracy: 1e-9)
    }
    func testSettlementReleasesUnusedReservation() throws {
        var book = BudgetBook(); let config = BudgetConfiguration()
        let id = try book.reserve(amount: 2, kind: .text, model: "test", configuration: config)
        try book.settle(id: id, amount: 0.02, input: 20, output: 30)
        XCTAssertEqual(book.spent(configuration: config), 0.02, accuracy: 1e-9)
        XCTAssertEqual(book.record(id: id)?.status, .settled)
    }
    func testInterruptedUsageSurvivesEncodingAndRecovery() throws {
        var book = BudgetBook(); let config = BudgetConfiguration()
        let id = try book.reserve(amount: 0.2, kind: .audio, model: "test", configuration: config)
        book = try JSONDecoder().decode(BudgetBook.self, from: JSONEncoder().encode(book))
        book.recoverInterruptedReservations()
        XCTAssertEqual(book.record(id: id)?.status, .uncertain)
        XCTAssertEqual(book.spent(configuration: config), 0.2, accuracy: 1e-9)
    }
    func testAudioSubBudgetAndTotalBothApply() throws {
        var book = BudgetBook(); var config = BudgetConfiguration(); config.audioLimitEnabled = true; config.audioLimit = 0.2
        _ = try book.reserve(amount: 0.18, kind: .audio, model: "test", configuration: config)
        XCTAssertThrowsError(try book.reserve(amount: 0.03, kind: .audio, model: "test", configuration: config))
        XCTAssertNoThrow(try book.reserve(amount: 0.03, kind: .text, model: "test", configuration: config))
    }
    func testDisabledBudgetStillRecordsAndReenableCountsIt() throws {
        var book = BudgetBook(); var config = BudgetConfiguration(); config.enabled = false
        _ = try book.reserve(amount: 15, kind: .text, model: "test", configuration: config)
        config.enabled = true
        XCTAssertThrowsError(try book.reserve(amount: 0.001, kind: .text, model: "test", configuration: config))
    }
    func testInvalidNumbersFailClosed() {
        for value in [Double.nan, .infinity, -1] {
            var book = BudgetBook()
            XCTAssertThrowsError(try book.reserve(amount: value, kind: .text, model: "test", configuration: BudgetConfiguration()))
        }
        var book = BudgetBook(); var config = BudgetConfiguration(); config.buffer = config.limit
        XCTAssertThrowsError(try book.reserve(amount: 0.001, kind: .text, model: "test", configuration: config))
    }
    func testDailyMonthlyAndLifetimeAccounting() throws {
        var book = BudgetBook(); var config = BudgetConfiguration(); config.enabled = false
        let formatter = ISO8601DateFormatter(); let yesterday = formatter.date(from: "2026-10-28T12:00:00Z")!; let today = formatter.date(from: "2026-10-29T12:00:00Z")!
        _ = try book.reserve(amount: 2, kind: .audio, model: "test", configuration: config, now: yesterday)
        config.period = .day; XCTAssertEqual(book.spent(configuration: config, now: today), 0)
        config.period = .month; XCTAssertEqual(book.spent(configuration: config, now: today), 2)
        config.period = .lifetime; XCTAssertEqual(book.spent(configuration: config, now: today), 2)
    }
    func testAudioExtensionChecksOutstandingTextReservations() throws {
        var book = BudgetBook(); var config = BudgetConfiguration(); config.limit = 0.6; config.buffer = 0.1
        let id = try book.reserve(amount: 0.2, kind: .audio, model: "test", configuration: config)
        _ = try book.reserve(amount: 0.25, kind: .text, model: "test", configuration: config)
        XCTAssertThrowsError(try book.extend(id: id, by: 0.1, configuration: config))
        XCTAssertEqual(book.record(id: id)?.amount ?? 0, 0.2, accuracy: 1e-9)
    }
    func testAudioCostAndFrameSizes() {
        XCTAssertEqual(PCMFrames.seconds(bytes: 9600), 0.2)
        XCTAssertEqual(PCMFrames.cost(bytes: 48_000 * 60), 0.034, accuracy: 1e-9)
        XCTAssertEqual(TextModel.nano.cost(input: 1000, cached: 500, output: 100), 0.000235, accuracy: 1e-9)
    }
}
