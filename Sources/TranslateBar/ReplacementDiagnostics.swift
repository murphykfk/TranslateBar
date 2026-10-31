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
    static func begin(_ snapshot: TextSnapshot) {
        current = Report(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development", richText: snapshot.preservesRichText)
        note("captured", ["length": snapshot.fullValue?.utf16.count ?? -1, "caret": snapshot.selectionRange?.location ?? -1, "selection": snapshot.selectionRange?.length ?? -1])
    }
    static func note(_ stage: String, _ counts: [String: Int] = [:]) {
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
        case "capture_caret": return "光标位置与读取时不同"
        case "copy_range", "paste_range": return "编辑器尚未确认待替换选区"
        case "copy_content", "paste_content", "source_content": return "编辑器返回的正文与读取时不同"
        case "queued_input": return "回填期间检测到新按键"
        default: return nil
        }
    }
}
