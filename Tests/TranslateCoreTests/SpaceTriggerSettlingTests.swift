import XCTest
@testable import TranslateCore

final class SpaceTriggerSettlingTests: XCTestCase {
    func testTriggerWaitsForReleaseAndKeyboardQuietPeriod() {
        var state = SpaceTriggerSettling(); state.begin(at: 1)
        XCTAssertFalse(state.ready(at: 1.5))
        state.observe(space: true, keyDown: false, at: 1.6)
        XCTAssertFalse(state.ready(at: 1.7))
        XCTAssertTrue(state.ready(at: 1.73))
    }
    func testLateSpaceEventReschedulesCaptureInsteadOfInvalidatingIt() {
        var state = SpaceTriggerSettling(); state.begin(at: 1)
        state.observe(space: true, keyDown: false, at: 1.02)
        state.observe(space: true, keyDown: true, at: 1.09)
        XCTAssertFalse(state.ready(at: 1.15))
        state.observe(space: true, keyDown: false, at: 1.12)
        XCTAssertFalse(state.ready(at: 1.2))
        XCTAssertTrue(state.ready(at: 1.25))
    }
    func testNewTextNavigationAndModifiedKeysCancelBeforeCapture() {
        for modified in [false, true] {
            var state = SpaceTriggerSettling(); state.begin(at: 1)
            state.observe(space: modified, keyDown: true, modifiers: modified, at: 1.04)
            XCTAssertFalse(state.pending); XCTAssertFalse(state.ready(at: 2))
        }
    }
    func testHoldRepeatAndExplicitCancellationNeverLeaveAStaleTrigger() {
        var state = SpaceTriggerSettling(); state.begin(at: 1)
        state.observe(space: true, keyDown: true, repeatKey: true, at: 1.5)
        state.observe(space: true, keyDown: false, at: 1.6)
        XCTAssertFalse(state.pending); XCTAssertFalse(state.ready(at: 2))
        state.begin(at: 3); state.cancel()
        XCTAssertFalse(state.ready(at: 4))
    }
    func testMissingReleaseTimesOutAndNewRequestStartsCleanly() {
        var state = SpaceTriggerSettling(); state.begin(at: 1)
        XCTAssertFalse(state.expired(at: 2.9)); XCTAssertTrue(state.expired(at: 3))
        state.cancel(); state.begin(at: 4)
        state.observe(space: true, keyDown: false, at: 4.01)
        XCTAssertTrue(state.ready(at: 4.14)); XCTAssertFalse(state.expired(at: 4.14))
    }
}
