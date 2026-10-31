import AppKit
import XCTest
import TranslateCore
@testable import TranslateBar

final class SpaceTriggerIntegrationTests: XCTestCase {
    @MainActor private func send(_ monitor: InputMonitor, code: UInt16, down: Bool) throws {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down))
        event.flags = []
        _ = monitor.handle(down ? .keyDown : .keyUp, event: event)
    }
    @MainActor func testLateSpaceStaysInSameBurstAndTriggersOnceAfterRelease() async throws {
        let monitor = InputMonitor()
        let oldRevision = TextInteraction.revision, oldKind = TextInteraction.lastKind
        defer { monitor.stop(); TextInteraction.revision = oldRevision; TextInteraction.lastKind = oldKind }
        var config = AppSettings(); config.spaceCount = 3
        monitor.settings = { config }
        var triggers = 0
        monitor.onAction = { if case .spaces = $0 { triggers += 1 } }
        for _ in 0..<3 { try send(monitor, code: 49, down: true); try send(monitor, code: 49, down: false) }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(triggers, 0)
        try send(monitor, code: 49, down: true); try send(monitor, code: 49, down: false)
        try await Task.sleep(for: .milliseconds(90))
        XCTAssertEqual(triggers, 0)
        try await Task.sleep(for: .milliseconds(130))
        XCTAssertEqual(triggers, 1)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(triggers, 1)
    }
    @MainActor func testContinuingToTypeCancelsBeforeTranslationStarts() async throws {
        let monitor = InputMonitor()
        let oldRevision = TextInteraction.revision, oldKind = TextInteraction.lastKind
        defer { monitor.stop(); TextInteraction.revision = oldRevision; TextInteraction.lastKind = oldKind }
        var config = AppSettings(); config.spaceCount = 3
        monitor.settings = { config }
        var triggers = 0
        monitor.onAction = { if case .spaces = $0 { triggers += 1 } }
        for _ in 0..<3 { try send(monitor, code: 49, down: true); try send(monitor, code: 49, down: false) }
        try send(monitor, code: 0, down: true); try send(monitor, code: 0, down: false)
        try await Task.sleep(for: .milliseconds(220))
        XCTAssertEqual(triggers, 0)
    }
}
