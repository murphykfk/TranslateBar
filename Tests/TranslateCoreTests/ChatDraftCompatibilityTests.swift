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


}
