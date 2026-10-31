import XCTest
@testable import TranslateCore

final class InputGateKeysTests: XCTestCase {
    func testReleaseOfTriggerPressedBeforeTransactionDoesNotCancelReplacement() {
        var keys = InputGateKeys()
        let heldEvents = [UInt16(49), 49, 56].filter { keys.shouldHold(keyCode: $0, isKeyDown: false) }
        XCTAssertTrue(heldEvents.isEmpty, "Releasing an existing space or modifier is not newly typed text.")
    }
    func testRealTypingKeepsBothPressAndReleaseForReplay() {
        var keys = InputGateKeys()
        let events: [(UInt16, Bool)] = [(49, false), (0, true), (0, false), (1, true), (1, false)]
        let queued = events.filter { keys.shouldHold(keyCode: $0.0, isKeyDown: $0.1) }
        XCTAssertEqual(queued.map(\.0), [0, 0, 1, 1])
        XCTAssertEqual(queued.map(\.1), [true, false, true, false])
    }
    func testHeldRepeatAndOverlappingKeysAreReplayedInFull() {
        var keys = InputGateKeys()
        for (code, down): (UInt16, Bool) in [(0, true), (1, true), (0, true), (0, false), (1, false)] {
            XCTAssertTrue(keys.shouldHold(keyCode: code, isKeyDown: down))
        }
        XCTAssertFalse(keys.shouldHold(keyCode: 0, isKeyDown: false))
    }
    func testNextTransactionDoesNotOwnEarlierUnreleasedKey() {
        var keys = InputGateKeys()
        XCTAssertTrue(keys.shouldHold(keyCode: 0, isKeyDown: true))
        keys = InputGateKeys()
        XCTAssertFalse(keys.shouldHold(keyCode: 0, isKeyDown: false))
        XCTAssertTrue(keys.shouldHold(keyCode: 49, isKeyDown: true), "An additional space pressed during replacement is still new input.")
    }
}
