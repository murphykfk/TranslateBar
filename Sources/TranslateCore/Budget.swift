import Foundation

public enum UsageKind: String, Codable { case text, audio }
public enum UsageStatus: String, Codable { case reserved, settled, uncertain }
public struct UsageRecord: Codable, Identifiable {
    public var id: UUID
    public var date: Date
    public var kind: UsageKind
    public var model: String
    public var amount: Double
    public var status: UsageStatus
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var audioSeconds: Double?
}

public enum BudgetError: LocalizedError {
    case exhausted, audioExhausted, invalidConfiguration, invalidAmount, missingReservation
    public var errorDescription: String? {
        switch self {
        case .exhausted: return "已达到费用预算，翻译已暂停。请在费用设置中调整额度。"
        case .audioExhausted: return "已达到语音独立预算，译声已停止。"
        case .invalidConfiguration: return "预算设置无效：限额应大于零，安全预留应小于限额。"
        case .invalidAmount: return "无法核算请求费用，已阻止调用。"
        case .missingReservation: return "费用记录缺失，已阻止调用。"
        }
    }
}

public struct BudgetBook: Codable {
    public private(set) var records: [UsageRecord] = []
    public init() {}
    public func spent(configuration: BudgetConfiguration, kind: UsageKind? = nil, now: Date = Date()) -> Double {
        records.filter { configuration.period.contains($0.date, now: now) && (kind == nil || $0.kind == kind) }.reduce(0) { $0 + $1.amount }
    }
    public mutating func reserve(amount: Double, kind: UsageKind, model: String, configuration: BudgetConfiguration, now: Date = Date()) throws -> UUID {
        try check(additional: amount, kind: kind, configuration: configuration, now: now)
        let id = UUID()
        records.append(.init(id: id, date: now, kind: kind, model: model, amount: amount, status: .reserved))
        return id
    }
    public mutating func extend(id: UUID, by amount: Double, configuration: BudgetConfiguration, now: Date = Date()) throws {
        guard let index = records.firstIndex(where: { $0.id == id && $0.status == .reserved }) else { throw BudgetError.missingReservation }
        try check(additional: amount, kind: records[index].kind, configuration: configuration, now: now)
        records[index].amount += amount
    }
    public mutating func settle(id: UUID, amount: Double, input: Int? = nil, output: Int? = nil, seconds: Double? = nil) throws {
        guard amount.isFinite && amount >= 0 else { throw BudgetError.invalidAmount }
        guard let index = records.firstIndex(where: { $0.id == id }) else { throw BudgetError.missingReservation }
        records[index].amount = amount
        records[index].status = .settled
        records[index].inputTokens = input; records[index].outputTokens = output; records[index].audioSeconds = seconds
    }
    public mutating func markUncertain(id: UUID) {
        if let index = records.firstIndex(where: { $0.id == id }) { records[index].status = .uncertain }
    }
    public mutating func recoverInterruptedReservations() {
        for index in records.indices where records[index].status == .reserved { records[index].status = .uncertain }
    }
    public func record(id: UUID) -> UsageRecord? { records.first { $0.id == id } }
    private func check(additional: Double, kind: UsageKind, configuration: BudgetConfiguration, now: Date) throws {
        guard additional.isFinite && additional >= 0 else { throw BudgetError.invalidAmount }
        guard configuration.enabled else { return }
        guard configuration.isValid else { throw BudgetError.invalidConfiguration }
        guard spent(configuration: configuration, now: now) + additional <= configuration.effectiveLimit + 1e-12 else { throw BudgetError.exhausted }
        if kind == .audio && configuration.audioLimitEnabled && spent(configuration: configuration, kind: .audio, now: now) + additional > configuration.audioLimit + 1e-12 { throw BudgetError.audioExhausted }
    }
}

public enum PCMFrames {
    public static let sampleRate = 24_000
    public static let bytesPerSecond = 48_000
    public static let chunkBytes = 9_600
    public static let audioDollarsPerMinute = 0.034
    public static func seconds(bytes: Int) -> Double { Double(bytes) / Double(bytesPerSecond) }
    public static func cost(bytes: Int) -> Double { seconds(bytes: bytes) / 60 * audioDollarsPerMinute }
}
