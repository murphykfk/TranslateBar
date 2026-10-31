import AppKit
import SwiftUI
import TranslateCore

struct PracticeTranslation { var text: String; var message: String }

@MainActor final class TranslationPracticeController: ObservableObject {
    typealias Translate = (String, Bool) async throws -> PracticeTranslation
    @Published var text = "明天上午十点开会，请带上笔记本。"
    @Published var selection = NSRange(location: 0, length: 0)
    @Published private(set) var result = ""
    @Published private(set) var message = "在练习框句末快速按空格，或选中文字后点击“翻译选区”。"
    @Published private(set) var busy = false
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var undo: (original: String, replacement: String, caret: NSRange)?
    var canUndo: Bool { undo?.replacement == text }
    func translate(input: Bool, triggerSpaces: Int = 3, client: @escaping Translate) {
        guard !busy else { return }
        let original = text
        let range: NSRange
        let source: String
        if input {
            guard let paragraph = try? ParagraphInput.range(in: text, caret: NSRange(location: min(selection.location, text.utf16.count), length: 0)) else { return }
            range = paragraph
            source = (text as NSString).substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        else {
            range = selection
            guard range.length > 0, range.location >= 0, range.location <= (text as NSString).length,
                  range.length <= (text as NSString).length - range.location else { message = "请先在练习框中选中文字。"; return }
            source = (text as NSString).substring(with: range)
        }
        guard !source.isEmpty else { message = "当前段落为空，已跳过。"; return }
        let id = UUID(); generation = id; busy = true; result = ""; message = "正在翻译…"
        task = Task {
            defer { if generation == id { busy = false } }
            do {
                let response = try await client(source, input)
                try Task.checkCancellation()
                guard generation == id else { return }
                result = response.text
                if input {
                    guard text == original else { message = "等待时练习文本已变化，译文显示在下方，没有覆盖新内容。"; return }
                    let fragment = (original as NSString).substring(with: range)
                    let formatted = try RichTextReplacement.translated(response.text, preserving: NSAttributedString(string: fragment), removingTriggerSpaces: true, triggerSpaceCount: triggerSpaces, requireFont: false).string
                    let updated = (original as NSString).replacingCharacters(in: range, with: formatted)
                    undo = (original, updated, selection)
                    text = updated; selection = NSRange(location: range.location + formatted.utf16.count, length: 0)
                }
                message = response.message
            } catch { if generation == id, !(error is CancellationError) { message = error.localizedDescription } }
        }
    }
    func undoReplacement() { guard let undo, text == undo.replacement else { return }; text = undo.original; selection = undo.caret; result = ""; self.undo = nil; message = "已恢复练习原文。" }
    func cancel() { generation = UUID(); task?.cancel(); task = nil; busy = false }
    func reset() { cancel(); text = "明天上午十点开会，请带上笔记本。"; selection = NSRange(location: 0, length: 0); result = ""; undo = nil; message = "练习已重置。" }
}

@MainActor struct TranslationPracticeView: View {
    @ObservedObject var model: AppModel
    @StateObject private var practice = TranslationPracticeController()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack { Text("翻译练习").font(.title2.weight(.semibold)); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("试一次输入替换，再选中文字查看译文。练习只处理下面的文本。").foregroundStyle(.secondary)
            PracticeEditor(text: $practice.text, selection: $practice.selection, count: model.settings.spaceCount, interval: model.settings.spaceInterval, undoShortcut: model.settings.undoShortcut,
                           trigger: { run(input: true) }, undo: { practice.undoReplacement() })
                .frame(height: 130).overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            HStack {
                Text("快速按 \(model.settings.spaceCount) 次空格").font(.callout)
                Spacer()
                Button("翻译选区") { run(input: false) }.disabled(practice.busy || practice.selection.length == 0)
                Button("翻译并替换") { run(input: true) }.disabled(practice.busy)
                Button("撤销替换") { practice.undoReplacement() }.disabled(!practice.canUndo || practice.busy)
            }
            HStack(alignment: .top) { if practice.busy { ProgressView().controlSize(.small) }; Text(practice.message).font(.callout).textSelection(.enabled) }
            if !practice.result.isEmpty { ScrollView { Text(practice.result).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }.frame(maxHeight: 95) }
            Divider()
            Text("输入：\(TranslationLanguageRoute.summary(target: model.settings.inputLanguage, fallback: model.settings.inputFallbackLanguage, mode: model.settings.inputLanguageMode))\n划词：\(TranslationLanguageRoute.summary(target: model.settings.readingLanguage, fallback: model.settings.readingFallbackLanguage, mode: model.settings.readingLanguageMode))")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text("使用当前模型、共享缓存和预算；缓存未命中时会调用 API。跨应用权限与兼容性仍需在实际应用验证。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(); Button("重置练习") { practice.reset() }
            }
        }.padding(24).frame(width: 660).frame(minHeight: 440)
        .onDisappear { practice.cancel() }
    }
    private func run(input: Bool) { practice.translate(input: input, triggerSpaces: model.settings.spaceCount) { text, input in try await model.translatePractice(text, input: input) } }
}

private struct PracticeEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    var count: Int
    var interval: Double
    var undoShortcut: TranslateCore.KeyboardShortcut
    var trigger: () -> Void
    var undo: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
        let editor = PracticeTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 130)); editor.isRichText = false; editor.font = .systemFont(ofSize: 15); editor.textContainerInset = NSSize(width: 10, height: 12)
        editor.isVerticallyResizable = true; editor.isHorizontallyResizable = false; editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true; editor.delegate = context.coordinator
        editor.setAccessibilityLabel("翻译练习文本"); scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let editor = scroll.documentView as? PracticeTextView else { return }
        context.coordinator.updating = true
        if editor.string != text {
            editor.string = text
            let target = selection.location <= text.utf16.count && selection.length <= text.utf16.count - selection.location ? selection : NSRange(location: text.utf16.count, length: 0)
            editor.setSelectedRange(target)
        }
        context.coordinator.updating = false
        editor.count = count; editor.interval = interval; editor.trigger = trigger; editor.undoShortcut = undoShortcut; editor.undoAction = undo
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PracticeEditor
        var updating = false
        init(_ parent: PracticeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) { guard !updating, let editor = notification.object as? NSTextView else { return }; parent.text = editor.string }
        func textViewDidChangeSelection(_ notification: Notification) { guard !updating, let editor = notification.object as? NSTextView else { return }; parent.selection = editor.selectedRange() }
    }
}

private final class PracticeTextView: NSTextView {
    var count = 4
    var interval = 0.32
    var trigger: (() -> Void)?
    var undoShortcut = TranslateCore.KeyboardShortcut(keyCode: 6, label: "Z")
    var undoAction: (() -> Void)?
    private var gesture = SpaceGesture()
    override func resignFirstResponder() -> Bool { gesture.reset(); return super.resignFirstResponder() }
    override func keyDown(with event: NSEvent) {
        if undoShortcut.matches(key: event.keyCode, flags: UInt64(event.modifierFlags.rawValue)) { gesture.reset(); undoAction?(); return }
        let marked = hasMarkedText()
        super.keyDown(with: event)
        guard !marked, !hasMarkedText() else { gesture.reset(); return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if gesture.keyDown(isSpace: event.keyCode == 49, isRepeat: event.isARepeat, hasModifiers: !flags.isEmpty, time: ProcessInfo.processInfo.systemUptime, interval: interval, requiredSpaces: count) { trigger?() }
    }
}
