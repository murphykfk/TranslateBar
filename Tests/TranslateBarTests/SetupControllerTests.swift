import XCTest
@testable import TranslateBar

final class SetupControllerTests: XCTestCase {
    private func readiness(loaded: Bool = true, key: Bool = true, accessibility: Bool = true, keyboard: Bool = true) -> SetupReadiness {
        SetupReadiness(keyLoaded: loaded, keyConfigured: key, accessibilityGranted: accessibility, keyboardActive: keyboard)
    }
    @MainActor private func withDefaults(_ body: (UserDefaults) -> Void) {
        let name = "TranslateBarSetupTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        body(defaults)
    }
    @MainActor func testNewInstallationWaitsForKeychainThenStartsAtFirstMissingStep() {
        withDefaults { defaults in
            let setup = SetupController(defaults: defaults)
            setup.presentAutomatically(readiness: readiness(loaded: false, key: false, accessibility: false, keyboard: false))
            XCTAssertFalse(setup.isPresented)
            setup.presentAutomatically(readiness: readiness(key: false, accessibility: false, keyboard: false))
            XCTAssertTrue(setup.isPresented)
            XCTAssertEqual(setup.step, .key)
            setup.step = .permissions
            setup.presentAutomatically(readiness: readiness())
            XCTAssertEqual(setup.step, .permissions, "Polling must not reset the user's current step.")
        }
    }
    @MainActor func testClosingUnfinishedNewSetupResumesAfterRestart() {
        withDefaults { defaults in
            _ = SetupController(defaults: defaults)
            defaults.set(true, forKey: "hasOpenedTranslateBar")
            let next = SetupController(defaults: defaults)
            next.presentAutomatically(readiness: readiness(accessibility: false, keyboard: false))
            XCTAssertTrue(next.isPresented)
            XCTAssertEqual(next.step, .permissions)
        }
    }
    @MainActor func testUpgradeDoesNotInterruptExistingUsersAndCanBeOpenedManually() {
        withDefaults { defaults in
            defaults.set(true, forKey: "hasOpenedTranslateBar")
            let setup = SetupController(defaults: defaults)
            setup.presentAutomatically(readiness: readiness(key: false))
            XCTAssertFalse(setup.isPresented)
            setup.present(readiness: readiness())
            XCTAssertTrue(setup.isPresented)
            XCTAssertEqual(setup.step, .ready)
        }
    }
    @MainActor func testDeferPersistsWithoutClaimingPermissionsAreReady() {
        withDefaults { defaults in
            let first = SetupController(defaults: defaults)
            first.present(readiness: readiness(key: false, accessibility: false, keyboard: false))
            first.deferSetup()
            let next = SetupController(defaults: defaults)
            next.presentAutomatically(readiness: readiness(key: false))
            XCTAssertFalse(next.isPresented)
            next.present(readiness: readiness(key: false))
            XCTAssertEqual(next.step, .key)
        }
    }
    @MainActor func testCompletionRechecksActualReadinessAndPersists() {
        withDefaults { defaults in
            let setup = SetupController(defaults: defaults)
            setup.present(readiness: readiness())
            XCTAssertFalse(setup.finish(readiness: readiness(keyboard: false)))
            XCTAssertTrue(setup.isPresented)
            XCTAssertEqual(setup.step, .permissions)
            XCTAssertFalse(setup.finish(readiness: readiness(loaded: false)))
            XCTAssertTrue(setup.finish(readiness: readiness()))
            XCTAssertFalse(setup.isPresented)
            let next = SetupController(defaults: defaults)
            next.presentAutomatically(readiness: readiness())
            XCTAssertFalse(next.isPresented)
        }
    }
    @MainActor func testCompletedInstallationRecoversMissingPermissionsOnEveryRestart() {
        withDefaults { defaults in
            let first = SetupController(defaults: defaults)
            XCTAssertTrue(first.finish(readiness: readiness()))
            for _ in 0..<3 {
                let upgraded = SetupController(defaults: defaults)
                XCTAssertTrue(upgraded.presentAutomatically(readiness: readiness(loaded: false, accessibility: false, keyboard: false)), "Permission recovery must not wait for Keychain interaction.")
                XCTAssertFalse(upgraded.presentAutomatically(readiness: readiness(accessibility: false, keyboard: false)))
                XCTAssertTrue(upgraded.isPermissionRecovery)
                XCTAssertEqual(upgraded.step, .permissions)
                upgraded.deferSetup()
                XCTAssertFalse(upgraded.presentAutomatically(readiness: readiness(accessibility: false, keyboard: false)), "Deferring must suppress repeated polling in this session.")
            }
            let restored = SetupController(defaults: defaults)
            XCTAssertFalse(restored.presentAutomatically(readiness: readiness()), "Recovery must not erase the completed setup status.")
        }
    }
    @MainActor func testLegacyInstallationOpensPermissionRecoveryWithoutRepeatingKeySetup() {
        withDefaults { defaults in
            defaults.set(true, forKey: "hasOpenedTranslateBar")
            let setup = SetupController(defaults: defaults)
            XCTAssertTrue(setup.presentAutomatically(readiness: readiness(accessibility: false, keyboard: false)))
            XCTAssertTrue(setup.isPermissionRecovery)
            XCTAssertEqual(setup.step, .permissions)
        }
    }
    @MainActor func testRecoveryRespectsPausedOrDisabledTextFeatures() {
        withDefaults { defaults in
            let setup = SetupController(defaults: defaults)
            XCTAssertTrue(setup.finish(readiness: readiness()))
            XCTAssertFalse(setup.presentAutomatically(readiness: readiness(keyboard: false), textFeaturesEnabled: false))
            XCTAssertFalse(setup.isPresented)
            XCTAssertTrue(setup.presentAutomatically(readiness: readiness(keyboard: false), textFeaturesEnabled: true))
            XCTAssertTrue(setup.isPermissionRecovery)
        }
    }
    @MainActor func testDeferredRecoveryRearmsOnlyAfterPermissionsBecomeHealthy() {
        withDefaults { defaults in
            let setup = SetupController(defaults: defaults)
            XCTAssertTrue(setup.finish(readiness: readiness()))
            XCTAssertTrue(setup.presentAutomatically(readiness: readiness(keyboard: false)))
            setup.deferSetup()
            for _ in 0..<5 {
                XCTAssertFalse(setup.presentAutomatically(readiness: readiness(keyboard: false)))
            }
            XCTAssertFalse(setup.presentAutomatically(readiness: readiness()))
            XCTAssertTrue(setup.presentAutomatically(readiness: readiness(accessibility: false, keyboard: false)))
        }
    }
    @MainActor func testRecoveryRequiresBothLivePermissionsBeforeCompletion() {
        withDefaults { defaults in
            let setup = SetupController(defaults: defaults)
            setup.presentPermissionRecovery()
            XCTAssertFalse(setup.finishRecovery(readiness: readiness(accessibility: false)))
            XCTAssertFalse(setup.finishRecovery(readiness: readiness(keyboard: false)))
            XCTAssertTrue(setup.isPresented)
            XCTAssertTrue(setup.finishRecovery(readiness: readiness()))
            XCTAssertFalse(setup.isPresented)
            XCTAssertFalse(setup.isPermissionRecovery)
        }
    }
    @MainActor func testManualRecoveryOnNewInstallCanCompleteAnOtherwiseReadySetup() {
        withDefaults { defaults in
            let setup = SetupController(defaults: defaults)
            setup.presentPermissionRecovery()
            XCTAssertTrue(setup.finishRecovery(readiness: readiness()))
            XCTAssertFalse(setup.presentAutomatically(readiness: readiness()))
            XCTAssertFalse(SetupController(defaults: defaults).needsAutomaticPresentation)
        }
    }
    @MainActor func testRecoveryPollingPreservesTheGuideAndDoesNotReopenAfterFinishing() {
        withDefaults { defaults in
            let setup = SetupController(defaults: defaults)
            XCTAssertTrue(setup.finish(readiness: readiness()))
            XCTAssertTrue(setup.presentAutomatically(readiness: readiness(keyboard: false)))
            XCTAssertFalse(setup.presentAutomatically(readiness: readiness()))
            XCTAssertTrue(setup.isPresented, "Leave the recovered state visible for the user to acknowledge.")
            XCTAssertTrue(setup.finishRecovery(readiness: readiness()))
            XCTAssertFalse(setup.presentAutomatically(readiness: readiness()))
        }
    }
    func testPermissionIssueUsesActualAccessibilityAndKeyboardState() {
        XCTAssertEqual(readiness(accessibility: false, keyboard: false).permissionIssue, .accessibility)
        XCTAssertEqual(readiness(keyboard: false).permissionIssue, .keyboard)
        XCTAssertNil(readiness().permissionIssue)
    }
    @MainActor func testAudioPermissionChecksNeverRequestAccessAutomatically() {
        var granted = false
        var requests = 0
        let permissions = RecordingPermissionController(preflight: { granted }, requestAccess: { requests += 1; return granted })
        XCTAssertFalse(permissions.granted)
        XCTAssertFalse(permissions.isPresented)
        permissions.refresh()
        XCTAssertFalse(permissions.prepareStart())
        XCTAssertTrue(permissions.isPresented)
        XCTAssertEqual(requests, 0)
        XCTAssertFalse(permissions.request())
        XCTAssertEqual(requests, 1)
        granted = true
        permissions.refresh()
        XCTAssertTrue(permissions.granted)
        permissions.isPresented = false
        XCTAssertTrue(permissions.prepareStart())
        XCTAssertFalse(permissions.isPresented)
        XCTAssertEqual(requests, 1)
        granted = false
        XCTAssertFalse(permissions.prepareStart(), "A revoked grant must be detected before connecting again.")
    }
}
