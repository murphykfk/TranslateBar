import Foundation

public struct ModelPricing: Codable, Equatable, Hashable {
    public var input: Double
    public var cached: Double
    public var output: Double
    public init(input: Double = 0, cached: Double = 0, output: Double = 0) { self.input = input; self.cached = cached; self.output = output }
    public var isValid: Bool { input.isFinite && cached.isFinite && output.isFinite && input > 0 && output > 0 && cached >= 0 && cached <= input }
}

public struct TextModel: Codable, Equatable, Hashable, Identifiable, CaseIterable {
    public var rawValue: String
    public var pricing: ModelPricing
    public var id: String { rawValue }
    public static let nano = TextModel(id: "gpt-5.4-nano", pricing: .init(input: 0.20, cached: 0.02, output: 1.25))
    public static let mini = TextModel(id: "gpt-5.4-mini", pricing: .init(input: 0.75, cached: 0.075, output: 4.50))
    public static let allCases = [nano, mini]
    public init(id: String, pricing: ModelPricing = .init()) { rawValue = id.trimmingCharacters(in: .whitespacesAndNewlines); self.pricing = pricing }
    public static func named(_ id: String) -> TextModel {
        allCases.first { $0.rawValue == id } ?? TextModel(id: id)
    }
    public var title: String {
        switch rawValue { case Self.nano.rawValue: return "GPT-5.4 nano · 经济、快速"; case Self.mini.rawValue: return "GPT-5.4 mini · 复杂文本"; default: return rawValue.isEmpty ? "自定义模型" : rawValue }
    }
    public var isKnown: Bool { Self.allCases.contains { $0.rawValue == rawValue } }
    public var isValidID: Bool { !rawValue.isEmpty && rawValue.utf8.count <= 200 && rawValue.range(of: "^[A-Za-z0-9][A-Za-z0-9._:/-]*$", options: .regularExpression) != nil }
    public var canTranslateText: Bool { isValidID && !Self.isSpecialized(rawValue) }
    public static func isSpecialized(_ id: String) -> Bool {
        let lower = id.lowercased()
        return ["realtime", "audio", "transcrib", "whisper", "tts", "embedding", "moderation", "dall-e", "image", "sora", "video", "search", "deep-research", "computer-use"].contains { lower.contains($0) }
    }
    public var inputRate: Double { pricing.input }
    public var cachedRate: Double { pricing.cached > 0 ? pricing.cached : pricing.input }
    public var outputRate: Double { pricing.output }
    public func cost(input: Int, cached: Int = 0, output: Int) -> Double {
        (Double(max(0, input - cached)) * inputRate + Double(max(0, min(cached, input))) * cachedRate + Double(max(0, output)) * outputRate) / 1_000_000
    }
    public func reservation(text: String, instructions: String, maxOutput: Int) -> Double {
        cost(input: text.utf8.count + instructions.utf8.count + 1024, output: maxOutput)
    }
    private enum CodingKeys: String, CodingKey { case id, pricing }
    public init(from decoder: Decoder) throws {
        if let id = try? decoder.singleValueContainer().decode(String.self) { self = Self.named(id); return }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        rawValue = try values.decode(String.self, forKey: .id)
        pricing = try values.decodeIfPresent(ModelPricing.self, forKey: .pricing) ?? Self.named(rawValue).pricing
    }
    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(rawValue, forKey: .id); try values.encode(pricing, forKey: .pricing)
    }
}
