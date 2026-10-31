import XCTest
@testable import TranslateCore

final class GestureTests: XCTestCase {
    func testFourDistinctRapidSpacesTriggerOnce() {
        var gesture = SpaceGesture()
        let results = (0..<8).map { gesture.keyDown(isSpace: true, isRepeat: false, hasModifiers: false, time: Double($0) * 0.12, interval: 0.3) }
        XCTAssertEqual(results, [false, false, false, true, false, false, false, true])
    }
    func testLongPressAndModifiedSpacesDoNotTrigger() {
        var gesture = SpaceGesture()
        for index in 0..<10 { XCTAssertFalse(gesture.keyDown(isSpace: true, isRepeat: index > 0, hasModifiers: false, time: Double(index) * 0.05, interval: 0.3)) }
        for index in 0..<4 { XCTAssertFalse(gesture.keyDown(isSpace: true, isRepeat: false, hasModifiers: true, time: Double(index), interval: 0.3)) }
    }
    func testTypingAndSlowSpacesResetSequence() {
        var gesture = SpaceGesture()
        for index in 0..<3 { XCTAssertFalse(gesture.keyDown(isSpace: true, isRepeat: false, hasModifiers: false, time: Double(index) * 0.1, interval: 0.3)) }
        XCTAssertFalse(gesture.keyDown(isSpace: false, isRepeat: false, hasModifiers: false, time: 0.3, interval: 0.3))
        XCTAssertFalse(gesture.keyDown(isSpace: true, isRepeat: false, hasModifiers: false, time: 0.4, interval: 0.3))
        XCTAssertFalse(gesture.keyDown(isSpace: true, isRepeat: false, hasModifiers: false, time: 2, interval: 0.3))
    }
    func testShortcutsIgnoreCapsLockButRequireExactModifiers() {
        let shortcut = KeyboardShortcut(keyCode: 17, label: "T")
        XCTAssertTrue(shortcut.matches(key: 17, flags: shortcut.modifiers | (1 << 16)))
        XCTAssertFalse(shortcut.matches(key: 17, flags: shortcut.modifiers | (1 << 20)))
        XCTAssertFalse(shortcut.matches(key: 0, flags: shortcut.modifiers))
    }
}
