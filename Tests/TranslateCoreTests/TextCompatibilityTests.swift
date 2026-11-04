import XCTest
@testable import TranslateCore

final class TextCompatibilityTests: XCTestCase {
    func testCompatibilitySettingMigratesAndPersistsIndependentSwitches() throws {
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(old.enhancedCompatibility)
        var settings = old; settings.enhancedCompatibility = false; settings.wpsCompatibilityEnabled = true
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(restored.enhancedCompatibility)
        XCTAssertTrue(restored.wpsCompatibilityEnabled)
    }
}
