import Foundation

public struct TranslationCacheKey: Codable, Hashable {
    public let text: String
    public let target: String
    public let model: String
    public let instructions: String
    public init(text: String, target: String, model: String, instructions: String) {
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.target = target.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = model; self.instructions = instructions
    }
    fileprivate var valid: Bool { !text.isEmpty && !target.isEmpty && !model.isEmpty && !instructions.isEmpty }
}

public struct TranslationCacheEntry: Codable {
    public let key: TranslationCacheKey
    public let translation: String
    public let created: Date
    public var lastUsed: Date
    public var contentBytes: Int {
        key.text.utf8.count + key.target.utf8.count + key.model.utf8.count + key.instructions.utf8.count + translation.utf8.count
    }
}

public struct TranslationCacheBook: Codable {
    public static let defaultMaximumEntries = 2_000
    public static let defaultMaximumBytes = 16 * 1_024 * 1_024
    private var records: [TranslationCacheKey: TranslationCacheEntry] = [:]
    public let maximumEntries: Int
    public let maximumBytes: Int
    public var count: Int { records.count }
    public var contentBytes: Int { records.values.reduce(0) { $0 + $1.contentBytes } }
    public init(maximumEntries: Int = defaultMaximumEntries, maximumBytes: Int = defaultMaximumBytes) {
        self.maximumEntries = max(0, maximumEntries); self.maximumBytes = max(0, maximumBytes)
    }
    public mutating func lookup(_ key: TranslationCacheKey, now: Date = Date()) -> String? {
        guard var entry = records[key] else { return nil }
        entry.lastUsed = now; records[key] = entry
        return entry.translation
    }
    @discardableResult public mutating func insert(_ translation: String, for key: TranslationCacheKey, now: Date = Date()) -> Bool {
        guard key.valid, !translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, maximumEntries > 0 else { return false }
        let entry = TranslationCacheEntry(key: key, translation: translation, created: records[key]?.created ?? now, lastUsed: now)
        guard entry.contentBytes <= maximumBytes else { return false }
        records[key] = entry
        prune()
        return true
    }
    private mutating func prune() {
        var bytes = contentBytes
        guard records.count > maximumEntries || bytes > maximumBytes else { return }
        let oldest = records.values.sorted { $0.lastUsed == $1.lastUsed ? $0.created < $1.created : $0.lastUsed < $1.lastUsed }
        for entry in oldest {
            guard records.count > maximumEntries || bytes > maximumBytes else { break }
            records.removeValue(forKey: entry.key); bytes -= entry.contentBytes
        }
    }
    private enum CodingKeys: String, CodingKey { case version, entries }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard try container.decode(Int.self, forKey: .version) == 1 else {
            throw DecodingError.dataCorruptedError(forKey: .version, in: container, debugDescription: "Unsupported translation cache version")
        }
        self.init()
        for entry in try container.decode([TranslationCacheEntry].self, forKey: .entries) {
            guard entry.key.valid, !entry.translation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, entry.contentBytes <= maximumBytes else { continue }
            if let existing = records[entry.key], existing.lastUsed > entry.lastUsed { continue }
            records[entry.key] = entry
        }
        prune()
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .version)
        try container.encode(records.values.sorted { $0.lastUsed > $1.lastUsed }, forKey: .entries)
    }
}
