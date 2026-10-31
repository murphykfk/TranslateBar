import CoreGraphics
import XCTest
@testable import TranslateCore

final class SelectionPopupTests: XCTestCase {
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let popup = CGSize(width: 420, height: 275)
    func testSelectionHasClearGapBelow() {
        let anchor = CGRect(x: 600, y: 550, width: 180, height: 24)
        let frame = SelectionPopupPlacement.frame(anchor: anchor, size: popup, visible: screen)
        XCTAssertLessThanOrEqual(frame.maxY, anchor.minY - 36)
        XCTAssertFalse(frame.intersects(anchor))
        XCTAssertTrue(screen.contains(frame))
    }
    func testBottomSelectionUsesSpaceAbove() {
        let anchor = CGRect(x: 600, y: 20, width: 150, height: 24)
        let frame = SelectionPopupPlacement.frame(anchor: anchor, size: popup, visible: screen)
        XCTAssertGreaterThanOrEqual(frame.minY, anchor.maxY + 36)
        XCTAssertTrue(screen.contains(frame))
    }
    func testTallSelectionUsesSideInsteadOfCoveringIt() {
        let anchor = CGRect(x: 200, y: 150, width: 100, height: 600)
        let frame = SelectionPopupPlacement.frame(anchor: anchor, size: popup, visible: screen)
        XCTAssertGreaterThanOrEqual(frame.minX, anchor.maxX + 36)
        XCTAssertFalse(frame.intersects(anchor))
    }
    func testScreenCornersAndSecondaryMonitorRemainVisible() {
        for screen in [screen, CGRect(x: -1920, y: -200, width: 1920, height: 1080), CGRect(x: 0, y: 900, width: 1280, height: 800)] {
            for point in [CGPoint(x: screen.minX, y: screen.minY), CGPoint(x: screen.maxX - 80, y: screen.maxY - 20)] {
                let anchor = CGRect(origin: point, size: CGSize(width: 80, height: 20))
                let frame = SelectionPopupPlacement.frame(anchor: anchor, size: popup, visible: screen)
                XCTAssertTrue(screen.contains(frame))
                XCTAssertFalse(frame.intersects(anchor))
            }
        }
    }
    func testFullScreenSelectionStillKeepsPopupOnScreen() {
        let frame = SelectionPopupPlacement.frame(anchor: screen, size: popup, visible: screen)
        XCTAssertTrue(screen.contains(frame))
        XCTAssertEqual(frame.size, popup)
    }
    func testLateResponseCannotReshowDismissedSelection() {
        var lifetime = SelectionPopupLifetime()
        let request = lifetime.begin()
        lifetime.dismiss() // User clicks outside before the network response arrives.
        XCTAssertFalse(lifetime.accepts(request))
    }
    func testNewSelectionRejectsPreviousPendingResult() {
        var lifetime = SelectionPopupLifetime()
        let oldRequest = lifetime.begin()
        let latestRequest = lifetime.begin()
        XCTAssertFalse(lifetime.accepts(oldRequest))
        XCTAssertTrue(lifetime.accepts(latestRequest))
    }
    func testTemporarilyUnreadableSelectionDoesNotClosePopup() {
        var policy = SelectionDismissalPolicy()
        XCTAssertFalse(policy.shouldDismiss(.matching, at: 0))
        XCTAssertFalse(policy.shouldDismiss(.unavailable, at: 0.2))
        XCTAssertFalse(policy.shouldDismiss(.unavailable, at: 3))
        XCTAssertFalse(policy.shouldDismiss(.matching, at: 3.2))
    }
    func testShortEmptySelectionDuringCommentRefreshRecovers() {
        var policy = SelectionDismissalPolicy()
        XCTAssertFalse(policy.shouldDismiss(.cleared, at: 1))
        XCTAssertFalse(policy.shouldDismiss(.matching, at: 1.2))
        XCTAssertFalse(policy.shouldDismiss(.cleared, at: 2))
        XCTAssertFalse(policy.shouldDismiss(.matching, at: 2.2))
    }
    func testConfirmedDeselectStillClosesAutomatically() {
        var policy = SelectionDismissalPolicy()
        XCTAssertFalse(policy.shouldDismiss(.cleared, at: 0))
        XCTAssertFalse(policy.shouldDismiss(.cleared, at: 0.2))
        XCTAssertTrue(policy.shouldDismiss(.cleared, at: 0.6))
    }
    func testUnreadableGapDoesNotCountAsConfirmedDeselect() {
        var policy = SelectionDismissalPolicy()
        XCTAssertFalse(policy.shouldDismiss(.cleared, at: 0))
        XCTAssertFalse(policy.shouldDismiss(.unavailable, at: 0.4))
        XCTAssertFalse(policy.shouldDismiss(.cleared, at: 1))
        XCTAssertFalse(policy.shouldDismiss(.matching, at: 1.2))
    }
    func testChangedSelectionMustRemainStableAndAppSwitchClosesImmediately() {
        var policy = SelectionDismissalPolicy()
        XCTAssertFalse(policy.shouldDismiss(.changed, at: 0))
        XCTAssertFalse(policy.shouldDismiss(.changed, at: 0.2))
        XCTAssertTrue(policy.shouldDismiss(.changed, at: 0.6))
        policy = SelectionDismissalPolicy()
        XCTAssertTrue(policy.shouldDismiss(.contextChanged, at: 0))
    }
    func testDifferentTransientStatesCannotCombineIntoFalseDismissal() {
        var policy = SelectionDismissalPolicy()
        XCTAssertFalse(policy.shouldDismiss(.cleared, at: 0))
        XCTAssertFalse(policy.shouldDismiss(.changed, at: 0.3))
        XCTAssertFalse(policy.shouldDismiss(.cleared, at: 0.6))
        XCTAssertFalse(policy.shouldDismiss(.matching, at: 0.8))
    }
}
