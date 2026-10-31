import XCTest
@testable import TranslateCore

final class ChatDraftCompatibilityTests: XCTestCase {
    func testMissingFocusOnlyPermitsKnownActiveChatWindow() {
        func allows(_ bundle: String = "com.tencent.xinWeChat", _ title: String = "微信",
                    active: Bool = true, controls: Bool = true, modal: Bool = false, secure: Bool = false) -> Bool {
            ChatDraftCompatibility.permitsMissingFocus(bundleID: bundle, windowTitle: title,
                activeWindow: active, standardControls: controls, modal: modal, secureInput: secure)
        }
        XCTAssertTrue(allows())
        XCTAssertTrue(allows("com.tencent.xinWeChat", "WeChat"))
        XCTAssertFalse(allows("com.other.chat"))
        XCTAssertTrue(allows("com.tencent.xinWeChat", "文件传输助手"))
        XCTAssertFalse(allows("com.tencent.xinWeChat", ""))
        XCTAssertFalse(allows(active: false))
        XCTAssertFalse(allows(controls: false))
        XCTAssertFalse(allows(modal: true))
        XCTAssertFalse(allows(secure: true))
    }

    func testOnlyWindowDecorationsCanRepresentAnOpaqueWindow() {
        XCTAssertTrue(ChatDraftCompatibility.isWindowDecoration(role: "AXButton", subrole: "AXCloseButton"))
        XCTAssertTrue(ChatDraftCompatibility.isWindowDecoration(role: "AXGroup", subrole: ""))
        for role in ["AXTextField", "AXTextArea", "AXStaticText", "AXWebArea", "AXTable", "AXMenuItem"] {
            XCTAssertFalse(ChatDraftCompatibility.isWindowDecoration(role: role, subrole: ""), role)
        }
        XCTAssertFalse(ChatDraftCompatibility.isWindowDecoration(role: "AXButton", subrole: ""))
        XCTAssertFalse(ChatDraftCompatibility.isWindowDecoration(role: "AXButton", subrole: "Send"))
    }

    func testDraftMustContainTheConfiguredTriggerBeforeTranslation() {
        XCTAssertTrue(ChatDraftCompatibility.containsTrigger("测试草稿   ", spaces: 3))
        XCTAssertTrue(ChatDraftCompatibility.containsTrigger("Draft  ", spaces: 2))
        XCTAssertTrue(ChatDraftCompatibility.containsTrigger("Draft \u{00a0} \u{00a0}", spaces: 4))
        for text in ["历史消息", "草稿  ", "草稿。 ", "   ", "", "草稿\n下一段   ", "消息\t   ", "附件\u{fffc}   "] {
            XCTAssertFalse(ChatDraftCompatibility.containsTrigger(text, spaces: 3), text)
        }
        XCTAssertFalse(ChatDraftCompatibility.containsTrigger("Draft    ", spaces: 1))
        XCTAssertFalse(ChatDraftCompatibility.containsTrigger("Draft     ", spaces: 5))
    }

    func testCaretProbeRejectsCopyingWholeHistoryRowsAndUnrelatedSelections() {
        XCTAssertTrue(ChatDraftCompatibility.matchesCaretProbe(line: "Draft   ", selectedCharacter: " "))
        XCTAssertTrue(ChatDraftCompatibility.matchesCaretProbe(line: "中文", selectedCharacter: "文"))
        XCTAssertTrue(ChatDraftCompatibility.matchesCaretProbe(line: "Emoji 😀", selectedCharacter: "😀"))
        XCTAssertTrue(ChatDraftCompatibility.matchesCaretProbe(line: "Text\u{00a0}", selectedCharacter: "\u{00a0}"))
        XCTAssertFalse(ChatDraftCompatibility.matchesCaretProbe(line: "History message   ", selectedCharacter: "History message   "))
        XCTAssertFalse(ChatDraftCompatibility.matchesCaretProbe(line: "Draft   ", selectedCharacter: "Draft"))
        XCTAssertFalse(ChatDraftCompatibility.matchesCaretProbe(line: "Draft.", selectedCharacter: " "))
        XCTAssertFalse(ChatDraftCompatibility.matchesCaretProbe(line: "Draft.", selectedCharacter: ""))
        XCTAssertFalse(ChatDraftCompatibility.matchesCaretProbe(line: "", selectedCharacter: ""))
        XCTAssertFalse(ChatDraftCompatibility.matchesCaretProbe(line: "First\nSecond", selectedCharacter: "d"))
    }
}
