import Foundation

/// One bounded local report, containing counts and reason codes only. Never
/// accepts original text, translation, clipboard data, credentials or key codes.
@MainActor enum ReplacementDiagnostics {
    struct Check: Codable { var stage: String; var counts: [String: Int] }
    struct Report: Codable {
        var date = Date()
        var version: String
        var richText: Bool
        var checks: [Check] = []
        var failure: String?
        var succeeded = false
    }
    private(set) static var current: Report?
    static var latestFailure: String? { current?.failure }
    static func beginCapture() {
        current = Report(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development", richText: false)
        note("capture_begin")
    }
    static func note(_ stage: String, _ counts: [String: Int] = [:]) {
        if stage.hasPrefix("focus_"), current?.checks.contains(where: { $0.stage == stage && $0.counts == counts }) == true { return }
        guard current != nil, current!.checks.count < 32 else { return }
        current?.checks.append(Check(stage: stage, counts: counts))
    }
    static func fail(_ reason: String, _ counts: [String: Int] = [:]) {
        if current?.failure == nil { current?.failure = reason }
        note(reason, counts)
    }
    static func finish(success: Bool) {
        guard var report = current else { return }
        report.succeeded = success
        if !success && report.failure == nil { report.failure = "replacement_failed" }
        current = report
        if !success { try? LocalFiles.write(report, to: LocalFiles.directory.appendingPathComponent("replacement-diagnostic.json")) }
    }
    static func lastFailureJSON(from url: URL = LocalFiles.directory.appendingPathComponent("replacement-diagnostic.json")) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        guard size <= 64 * 1024 else { throw AppError.message("兼容性诊断文件过大，未复制。请重新触发一次失败后重试。") }
        // Decode the numeric report schema and encode it again. Never copy
        // arbitrary files or add document text, clipboard contents or keys.
        let report = try LocalFiles.read(Report.self, from: url)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }
    static var failureHint: String? {
        switch latestFailure {
        case "input_revision":
            switch TextInteraction.lastKind {
            case .space, .repeatingSpace: return "读取文本后又收到空格事件"
            case .navigation: return "读取文本后收到光标移动事件"
            case .command: return "读取文本后收到组合键事件"
            case .keyboard: return "读取文本后收到键盘事件"
            default: return "检测到新的键盘或鼠标操作"
            }
        case "paragraph_changed": return "当前段落与读取时不同"
        case "paragraph_window_changed", "paragraph_focus_changed", "paragraph_application_changed": return "焦点或窗口已经变化"
        case "paragraph_copy_unavailable": return "编辑器没有复制出选中的文字"
        case "queued_input": return "回填期间检测到新按键"
        default: return nil
        }
    }
}
