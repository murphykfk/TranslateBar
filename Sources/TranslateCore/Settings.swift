import Foundation

public enum BudgetPeriod: String, Codable, CaseIterable, Identifiable {
    case lifetime, day, month
    public var id: String { rawValue }
    public var title: String {
        switch self { case .lifetime: return "累计"; case .day: return "每天"; case .month: return "每月" }
    }
    public func contains(_ date: Date, now: Date, calendar: Calendar = .current) -> Bool {
        switch self {
        case .lifetime: return true
        case .day: return calendar.isDate(date, inSameDayAs: now)
        case .month: return calendar.isDate(date, equalTo: now, toGranularity: .month)
        }
    }
}

public struct BudgetConfiguration: Codable, Equatable {
    public var enabled = true
    public var limit = 10.0
    public var period: BudgetPeriod = .month
    public var buffer = 0.50
    public var audioLimitEnabled = false
    public var audioLimit = 8.0
    public var warningFraction = 0.80
    public init() {}
    public var effectiveLimit: Double { max(0, limit - buffer) }
    public var isValid: Bool {
        limit.isFinite && limit > 0 && buffer.isFinite && buffer >= 0 && buffer < limit
        && audioLimit.isFinite && audioLimit > 0 && warningFraction > 0 && warningFraction <= 1
    }
}

public enum TranslationScope: String, Codable, CaseIterable, Identifiable {
    case field, paragraph
    public var id: String { rawValue }
    public var title: String { self == .field ? "整个输入框" : "光标所在段落" }
}

public struct KeyboardShortcut: Codable, Equatable {
    public var keyCode: UInt16
    public var modifiers: UInt64
    public var label: String
    public init(keyCode: UInt16, modifiers: UInt64 = (1 << 18) | (1 << 19), label: String) {
        self.keyCode = keyCode; self.modifiers = modifiers; self.label = label
    }
    public var display: String {
        var text = ""
        if modifiers & (1 << 18) != 0 { text += "⌃" }
        if modifiers & (1 << 19) != 0 { text += "⌥" }
        if modifiers & (1 << 17) != 0 { text += "⇧" }
        if modifiers & (1 << 20) != 0 { text += "⌘" }
        return text + label
    }
    public func matches(key: UInt16, flags: UInt64) -> Bool {
        let mask: UInt64 = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)
        return key == keyCode && flags & mask == modifiers & mask
    }
}

public struct AppSettings: Codable, Equatable {
    public var enabled = true
    public var fourSpacesEnabled = true
    public var inputFeedbackEnabled = true
    public var selectionEnabled = true
    public var audioEnabled = true
    public var automaticSelection = true
    public var spaceInterval = 0.32
    public var spaceCount = 4
    public var textSourceLanguage = "auto"
    public var inputLanguageMode: TranslationLanguageMode = .fixed
    public var readingLanguageMode: TranslationLanguageMode = .fixed
    public var inputFallbackLanguage = "简体中文"
    public var readingFallbackLanguage = "English"
    public var skipSameLanguage = true
    public var inputLanguage = "English"
    public var readingLanguage = "简体中文"
    public var audioLanguage = "zh"
    public var inputScope: TranslationScope = .paragraph
    public var textModel: TextModel = .nano
    public var maxOutputTokens = 4096
    public var excludedBundleIDs = "com.apple.Terminal\ncom.googlecode.iterm2\ncom.apple.keychainaccess"
    public var selectionShortcut = KeyboardShortcut(keyCode: 17, label: "T")
    public var audioShortcut = KeyboardShortcut(keyCode: 9, label: "V")
    public var undoShortcut = KeyboardShortcut(keyCode: 6, label: "Z")
    public var audioSourceBundleID = "com.apple.Safari"
    public var muteOriginal = true
    public var audioVolume = 1.0
    public var subtitlesEnabled = true
    public var subtitleFontSize = 19.0
    public var showAudioLatency = true
    public var followVideo = false
    public var audioQualityRevision = 1
    public var maximumAudioMinutes = 15.0
    public var silenceStopSeconds = 30.0
    public var cacheEnabled = true
    public var wpsCompatibilityEnabled = true
    public var enhancedCompatibility = true
    public var budget = BudgetConfiguration()
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case enabled, fourSpacesEnabled, inputFeedbackEnabled, selectionEnabled, audioEnabled, automaticSelection, spaceInterval
        case inputLanguage, readingLanguage, audioLanguage, inputScope, textModel, maxOutputTokens, excludedBundleIDs
        case spaceCount, textSourceLanguage, inputLanguageMode, readingLanguageMode, inputFallbackLanguage, readingFallbackLanguage, skipSameLanguage
        case selectionShortcut, audioShortcut, undoShortcut, audioSourceBundleID, muteOriginal, audioVolume
        case subtitlesEnabled, subtitleFontSize, showAudioLatency, followVideo, audioQualityRevision, maximumAudioMinutes, silenceStopSeconds, cacheEnabled, wpsCompatibilityEnabled, enhancedCompatibility, budget
    }
    public init(from decoder: Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? enabled
        fourSpacesEnabled = try values.decodeIfPresent(Bool.self, forKey: .fourSpacesEnabled) ?? fourSpacesEnabled
        inputFeedbackEnabled = try values.decodeIfPresent(Bool.self, forKey: .inputFeedbackEnabled) ?? inputFeedbackEnabled
        selectionEnabled = try values.decodeIfPresent(Bool.self, forKey: .selectionEnabled) ?? selectionEnabled
        audioEnabled = try values.decodeIfPresent(Bool.self, forKey: .audioEnabled) ?? audioEnabled
        automaticSelection = try values.decodeIfPresent(Bool.self, forKey: .automaticSelection) ?? automaticSelection
        spaceInterval = try values.decodeIfPresent(Double.self, forKey: .spaceInterval) ?? spaceInterval
        spaceCount = min(4, max(2, try values.decodeIfPresent(Int.self, forKey: .spaceCount) ?? 4))
        textSourceLanguage = try values.decodeIfPresent(String.self, forKey: .textSourceLanguage) ?? textSourceLanguage
        inputLanguageMode = try values.decodeIfPresent(TranslationLanguageMode.self, forKey: .inputLanguageMode) ?? inputLanguageMode
        readingLanguageMode = try values.decodeIfPresent(TranslationLanguageMode.self, forKey: .readingLanguageMode) ?? readingLanguageMode
        inputFallbackLanguage = try values.decodeIfPresent(String.self, forKey: .inputFallbackLanguage) ?? inputFallbackLanguage
        readingFallbackLanguage = try values.decodeIfPresent(String.self, forKey: .readingFallbackLanguage) ?? readingFallbackLanguage
        skipSameLanguage = try values.decodeIfPresent(Bool.self, forKey: .skipSameLanguage) ?? skipSameLanguage
        inputLanguage = try values.decodeIfPresent(String.self, forKey: .inputLanguage) ?? inputLanguage
        readingLanguage = try values.decodeIfPresent(String.self, forKey: .readingLanguage) ?? readingLanguage
        audioLanguage = try values.decodeIfPresent(String.self, forKey: .audioLanguage) ?? audioLanguage
        // Whole-field input translation is retired. Decode its old value for
        // compatibility, then migrate to the single supported paragraph scope.
        _ = try values.decodeIfPresent(TranslationScope.self, forKey: .inputScope)
        inputScope = .paragraph
        textModel = try values.decodeIfPresent(TextModel.self, forKey: .textModel) ?? textModel
        maxOutputTokens = try values.decodeIfPresent(Int.self, forKey: .maxOutputTokens) ?? maxOutputTokens
        excludedBundleIDs = try values.decodeIfPresent(String.self, forKey: .excludedBundleIDs) ?? excludedBundleIDs
        selectionShortcut = try values.decodeIfPresent(KeyboardShortcut.self, forKey: .selectionShortcut) ?? selectionShortcut
        audioShortcut = try values.decodeIfPresent(KeyboardShortcut.self, forKey: .audioShortcut) ?? audioShortcut
        undoShortcut = try values.decodeIfPresent(KeyboardShortcut.self, forKey: .undoShortcut) ?? undoShortcut
        audioSourceBundleID = try values.decodeIfPresent(String.self, forKey: .audioSourceBundleID) ?? audioSourceBundleID
        muteOriginal = try values.decodeIfPresent(Bool.self, forKey: .muteOriginal) ?? muteOriginal
        audioVolume = try values.decodeIfPresent(Double.self, forKey: .audioVolume) ?? audioVolume
        subtitlesEnabled = try values.decodeIfPresent(Bool.self, forKey: .subtitlesEnabled) ?? subtitlesEnabled
        let fontSize = try values.decodeIfPresent(Double.self, forKey: .subtitleFontSize) ?? subtitleFontSize
        subtitleFontSize = fontSize.isFinite ? min(30, max(15, fontSize)) : 19
        showAudioLatency = try values.decodeIfPresent(Bool.self, forKey: .showAudioLatency) ?? showAudioLatency
        followVideo = try values.decodeIfPresent(Bool.self, forKey: .followVideo) ?? followVideo
        // One-time quality correction for earlier aggressive defaults. A later
        // explicit choice of experimental catch-up is preserved on restart.
        if (try values.decodeIfPresent(Int.self, forKey: .audioQualityRevision) ?? 0) < 1 { followVideo = false }
        maximumAudioMinutes = try values.decodeIfPresent(Double.self, forKey: .maximumAudioMinutes) ?? maximumAudioMinutes
        silenceStopSeconds = try values.decodeIfPresent(Double.self, forKey: .silenceStopSeconds) ?? silenceStopSeconds
        cacheEnabled = try values.decodeIfPresent(Bool.self, forKey: .cacheEnabled) ?? cacheEnabled
        wpsCompatibilityEnabled = try values.decodeIfPresent(Bool.self, forKey: .wpsCompatibilityEnabled) ?? wpsCompatibilityEnabled
        enhancedCompatibility = try values.decodeIfPresent(Bool.self, forKey: .enhancedCompatibility) ?? enhancedCompatibility
        budget = try values.decodeIfPresent(BudgetConfiguration.self, forKey: .budget) ?? budget
    }
    public func excludes(_ bundleID: String) -> Bool {
        excludedBundleIDs.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == bundleID }
    }
}

public struct SpaceGesture {
    private var requiredCount = 4
    private var count = 0
    private var lastTime: Double = 0
    public init() {}
    public mutating func reset() { count = 0; lastTime = 0 }
    public mutating func keyDown(isSpace: Bool, isRepeat: Bool, hasModifiers: Bool, time: Double, interval: Double, requiredSpaces: Int = 4) -> Bool {
        let required = min(4, max(2, requiredSpaces))
        if requiredCount != required { reset(); requiredCount = required }
        guard isSpace, !isRepeat, !hasModifiers else { reset(); return false }
        count = count > 0 && time >= lastTime && time - lastTime <= interval ? count + 1 : 1
        lastTime = time
        if count == required { reset(); return true }
        return false
    }
}
