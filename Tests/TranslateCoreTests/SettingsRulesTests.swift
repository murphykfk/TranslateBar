import XCTest
@testable import TranslateCore

final class SettingsRulesTests: XCTestCase {
    func testOldSettingsRetainLanguagesModelAndBudget() throws {
        let data = Data(#"{"inputLanguage":"日本語","readingLanguage":"Français","textModel":"gpt-5.4-mini","budget":{"enabled":true,"limit":10,"period":"month","buffer":0.5,"audioLimitEnabled":true,"audioLimit":8,"warningFraction":0.8}}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings.inputLanguage, "日本語"); XCTAssertEqual(settings.readingLanguage, "Français")
        XCTAssertEqual(settings.textModel, .mini); XCTAssertEqual(settings.spaceCount, 4)
        XCTAssertEqual(settings.inputLanguageMode, .fixed); XCTAssertEqual(settings.readingLanguageMode, .fixed)
        XCTAssertEqual(settings.budget.limit, 10); XCTAssertTrue(settings.budget.audioLimitEnabled)
        XCTAssertTrue(settings.inputFeedbackEnabled); XCTAssertEqual(settings.subtitleFontSize, 19)
    }
    func testCustomModelAndLanguageRulesSurviveRestart() throws {
        var settings = AppSettings()
        settings.spaceCount = 2; settings.inputLanguageMode = .smart; settings.readingLanguageMode = .smart
        settings.inputFeedbackEnabled = false; settings.subtitleFontSize = 23
        settings.textSourceLanguage = "日本語"; settings.inputFallbackLanguage = "Français"; settings.skipSameLanguage = false
        settings.textModel = TextModel(id: "ft:gpt-4.1:example:translator", pricing: .init(input: 3, cached: 1, output: 8))
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)), settings)
    }
    func testSubtitleFontSizeIsBoundedWhenLoadingSettings() throws {
        for (input, expected) in [(3, 15.0), (200, 30.0), (23, 23.0)] {
            let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{\"subtitleFontSize\":\(input)}".utf8))
            XCTAssertEqual(settings.subtitleFontSize, expected)
        }
    }
    func testFixedRouteTranslatesAllForeignLanguagesToSameTarget() {
        for source in ["en", "ja", "fr", "de", "es", "ko"] {
            let route = TranslationLanguageRoute(target: "简体中文", fallback: "English", mode: .fixed, sourceCode: source, skipSame: true)
            XCTAssertEqual(route.target, "简体中文"); XCTAssertFalse(route.skip)
        }
    }
    func testSmartRouteUsesSecondaryOnlyForPrimaryLanguage() {
        XCTAssertEqual(TranslationLanguageRoute(target: "English", fallback: "简体中文", mode: .smart, sourceCode: "en-US", skipSame: true), .init(target: "简体中文", fallback: "English", mode: .fixed, sourceCode: "en", skipSame: true))
        for source in ["zh-Hans", "ja", "fr", nil] {
            XCTAssertEqual(TranslationLanguageRoute(target: "English", fallback: "简体中文", mode: .smart, sourceCode: source, skipSame: true).target, "English")
        }
    }
    func testSameLanguageCanBeSkippedOrForcedAndUnknownIsNeverSkipped() {
        XCTAssertTrue(TranslationLanguageRoute(target: "简体中文", fallback: "English", mode: .fixed, sourceCode: "zh-Hans", skipSame: true).skip)
        XCTAssertFalse(TranslationLanguageRoute(target: "简体中文", fallback: "English", mode: .fixed, sourceCode: "zh-Hant", skipSame: true).skip)
        XCTAssertFalse(TranslationLanguageRoute(target: "繁體中文", fallback: "English", mode: .fixed, sourceCode: "zh-Hans", skipSame: true).skip)
        XCTAssertFalse(TranslationLanguageRoute(target: "English", fallback: "简体中文", mode: .fixed, sourceCode: "en", skipSame: false).skip)
        XCTAssertFalse(TranslationLanguageRoute(target: "English", fallback: "简体中文", mode: .fixed, sourceCode: nil, skipSame: true).skip)
    }
    func testTwoThreeAndFourSpacesTriggerAtChosenCount() {
        for required in 2...4 {
            var gesture = SpaceGesture()
            let triggered = (0..<(required * 2)).map { gesture.keyDown(isSpace: true, isRepeat: false, hasModifiers: false, time: Double($0) * 0.1, interval: 0.3, requiredSpaces: required) }
            XCTAssertEqual(triggered.enumerated().filter { $0.element }.map(\.offset), [required - 1, required * 2 - 1])
        }
    }
    func testChangingTriggerCountResetsPartialSequence() {
        var gesture = SpaceGesture()
        for index in 0..<3 { XCTAssertFalse(gesture.keyDown(isSpace: true, isRepeat: false, hasModifiers: false, time: Double(index) * 0.1, interval: 0.3)) }
        XCTAssertFalse(gesture.keyDown(isSpace: true, isRepeat: false, hasModifiers: false, time: 0.3, interval: 0.3, requiredSpaces: 2))
        XCTAssertTrue(gesture.keyDown(isSpace: true, isRepeat: false, hasModifiers: false, time: 0.4, interval: 0.3, requiredSpaces: 2))
    }
    func testUnpricedModelsAreNotSilentlyChargedAtNanoRates() throws {
        let unknown = try JSONDecoder().decode(TextModel.self, from: Data(#""gpt-custom-translator""#.utf8))
        XCTAssertEqual(unknown.rawValue, "gpt-custom-translator"); XCTAssertFalse(unknown.pricing.isValid)
        XCTAssertTrue(TextModel.nano.pricing.isValid); XCTAssertFalse(ModelPricing(input: 1, cached: 2, output: 3).isValid)
        let custom = TextModel(id: "ft:gpt-4.1:example:test", pricing: .init(input: 2, cached: 1, output: 8))
        XCTAssertEqual(custom.cost(input: 1000, cached: 500, output: 100), 0.0023, accuracy: 1e-9)
        let conservative = TextModel(id: "custom", pricing: .init(input: 2, cached: 0, output: 8))
        XCTAssertEqual(conservative.cost(input: 1000, cached: 500, output: 100), 0.0028, accuracy: 1e-9)
    }
    func testSpecializedModelsCannotBeChosenForText() {
        for id in ["gpt-realtime-translate", "gpt-image-2", "text-embedding-3-large", "whisper-1", "tts-1", "sora-2"] { XCTAssertFalse(TextModel.named(id).canTranslateText) }
        XCTAssertTrue(TextModel.named("gpt-4.1").canTranslateText)
        XCTAssertFalse(TextModel.named("invalid model id").canTranslateText)
    }
}
