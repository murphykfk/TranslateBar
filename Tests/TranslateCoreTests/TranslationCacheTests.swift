import XCTest
@testable import TranslateCore

final class TranslationCacheTests: XCTestCase {
    private func key(_ text: String, target: String = "English", model: String = "nano", instructions: String = "Translate only") -> TranslationCacheKey {
        TranslationCacheKey(text: text, target: target, model: model, instructions: instructions)
    }
    func testTriggerSpacesShareCacheWithoutMergingDifferentContent() {
        var cache = TranslationCacheBook()
        cache.insert("elephant", for: key(" 大象    \n"))
        XCTAssertEqual(cache.lookup(key("大象")), "elephant")
        XCTAssertNil(cache.lookup(key("大象。")))
        XCTAssertNil(cache.lookup(key("大 象")))
        cache.insert("猫", for: key("CAT"))
        XCTAssertNil(cache.lookup(key("cat")))
    }
    func testLanguageModelAndPromptChangesCannotReturnOldTranslations() {
        var cache = TranslationCacheBook()
        cache.insert("elephant", for: key("大象"))
        XCTAssertNil(cache.lookup(key("大象", target: "日本語")))
        XCTAssertNil(cache.lookup(key("大象", model: "mini")))
        XCTAssertNil(cache.lookup(key("大象", instructions: "Translate with a different style")))
    }
    func testLeastRecentlyUsedEntryIsEvicted() {
        var cache = TranslationCacheBook(maximumEntries: 2)
        cache.insert("a", for: key("甲"), now: Date(timeIntervalSince1970: 0))
        cache.insert("b", for: key("乙"), now: Date(timeIntervalSince1970: 1))
        _ = cache.lookup(key("甲"), now: Date(timeIntervalSince1970: 2))
        cache.insert("c", for: key("丙"), now: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(cache.count, 2)
        XCTAssertEqual(cache.lookup(key("甲")), "a")
        XCTAssertEqual(cache.lookup(key("丙")), "c")
        XCTAssertNil(cache.lookup(key("乙")))
    }
    func testInvalidOrOversizedEntriesDoNotReplaceValidData() {
        var cache = TranslationCacheBook(maximumBytes: 256)
        let input = key("大象")
        XCTAssertTrue(cache.insert("elephant", for: input))
        XCTAssertFalse(cache.insert(" \n", for: input))
        XCTAssertFalse(cache.insert(String(repeating: "🐘", count: 100), for: input))
        XCTAssertFalse(cache.insert("empty", for: key("  ")))
        XCTAssertEqual(cache.lookup(input), "elephant")
        XCTAssertLessThanOrEqual(cache.contentBytes, 256)
    }
    func testCacheEncodingRoundTripPreservesTranslation() throws {
        var cache = TranslationCacheBook()
        cache.insert("elephant", for: key("大象"))
        var restored = try JSONDecoder().decode(TranslationCacheBook.self, from: JSONEncoder().encode(cache))
        XCTAssertEqual(restored.lookup(key("大象")), "elephant")
    }
    func testOldSettingsEnableCacheWhilePreservingExistingPreferences() throws {
        var settings = AppSettings()
        settings.enabled = false; settings.fourSpacesEnabled = false; settings.selectionEnabled = false; settings.audioEnabled = false
        settings.automaticSelection = false; settings.spaceInterval = 0.51; settings.inputLanguage = "日本語"; settings.readingLanguage = "English"
        settings.audioLanguage = "en"; settings.inputScope = .paragraph; settings.textModel = .mini; settings.maxOutputTokens = 8192
        settings.excludedBundleIDs = "test.excluded"; settings.selectionShortcut = KeyboardShortcut(keyCode: 1, label: "S")
        settings.audioShortcut = KeyboardShortcut(keyCode: 2, label: "D"); settings.undoShortcut = KeyboardShortcut(keyCode: 3, label: "F")
        settings.audioSourceBundleID = "test.browser"; settings.muteOriginal = false; settings.audioVolume = 0.47; settings.subtitlesEnabled = false
        settings.maximumAudioMinutes = 8; settings.silenceStopSeconds = 60; settings.budget.limit = 7; settings.cacheEnabled = false
        let encoder = JSONEncoder()
        XCTAssertEqual(try JSONDecoder().decode(AppSettings.self, from: encoder.encode(settings)), settings)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(settings)) as? [String: Any])
        legacy.removeValue(forKey: "cacheEnabled")
        legacy["selectAllEnabled"] = true
        let restored = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        settings.cacheEnabled = true
        XCTAssertEqual(restored, settings)
    }
}
