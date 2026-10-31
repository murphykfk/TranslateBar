import AppKit
import SwiftUI
import UniformTypeIdentifiers
import TranslateCore

struct LanguageRuleFields: View {
    @Binding var target: String
    @Binding var fallback: String
    @Binding var mode: TranslationLanguageMode
    var source: String
    var skipSame: Bool
    var body: some View {
        LanguagePicker(title: "目标语言", value: $target)
        Picker("翻译方向", selection: $mode) { ForEach(TranslationLanguageMode.allCases) { Text($0.title).tag($0) } }
        if mode == .smart {
            LanguagePicker(title: "原文已是目标语言时，译为", value: $fallback)
            if target == fallback { Label("智能互译需要两种不同语言。", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
        }
        Text(TranslationLanguageRoute.explanation(target: target, fallback: fallback, mode: mode, source: source, skipSame: skipSame))
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}

struct AudioLanguagePicker: View {
    @Binding var value: String
    var body: some View {
        Picker("译声目标语言", selection: $value) {
            ForEach(TranslationLanguage.audio) { Text($0.title).tag($0.id == "zh-Hans" ? "zh" : $0.id) }
            if !TranslationLanguage.audio.contains(where: { ($0.id == "zh-Hans" ? "zh" : $0.id) == value }) { Text(TranslationLanguage.display(value)).tag(value) }
        }
    }
}

@MainActor struct ExcludedApplicationsView: View {
    @Binding var bundleIDs: String
    @State private var showRunning = false
    @State private var showIdentifiers = false
    @State private var candidates: [NSRunningApplication] = []
    @State private var error: String?
    private var ids: [String] { Array(Set(bundleIDs.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted() }
    var body: some View {
        ForEach(ids, id: \.self) { id in
            HStack {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20).accessibilityHidden(true)
                    Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
                } else { Text(id).font(.callout) }
                Spacer()
                Button("恢复启用") { bundleIDs = ids.filter { $0 != id }.joined(separator: "\n") }.help("从排除列表移除此应用")
            }
        }
        if ids.isEmpty { Text("所有支持的应用均可使用文字翻译。").foregroundStyle(.secondary) }
        HStack {
            Button("添加运行中的应用…") {
                candidates = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier && $0.bundleIdentifier != nil && !ids.contains($0.bundleIdentifier!) }
                    .sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
                showRunning = true
            }
            Button("从应用程序选择…") { chooseApplication() }
        }
        if let error { Text(error).font(.caption).foregroundStyle(.orange) }
        DisclosureGroup("高级：编辑应用标识", isExpanded: $showIdentifiers) {
            TextEditor(text: $bundleIDs).font(.system(.caption, design: .monospaced)).frame(height: 85).accessibilityLabel("排除的应用 Bundle ID")
            Text("每行一个 Bundle ID。输入与划词翻译共同生效。").font(.caption).foregroundStyle(.secondary)
        }
        .sheet(isPresented: $showRunning) {
            VStack(alignment: .leading, spacing: 16) {
                HStack { Text("选择要停用文字翻译的应用").font(.headline); Spacer(); Button("完成") { showRunning = false }.keyboardShortcut(.cancelAction) }
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(candidates, id: \.processIdentifier) { app in
                            Button {
                                if let id = app.bundleIdentifier { add(id) }
                                showRunning = false
                            } label: {
                                HStack {
                                    if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 26, height: 26).accessibilityHidden(true) }
                                    Text(app.localizedName ?? app.bundleIdentifier ?? "应用")
                                    Spacer()
                                    Text("添加").foregroundStyle(Color.accentColor)
                                }.padding(.vertical, 9).padding(.horizontal, 8).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityLabel("添加 " + (app.localizedName ?? app.bundleIdentifier ?? "应用"))
                            Divider()
                        }
                    }
                }.overlay { if candidates.isEmpty { Text("没有其他可添加的运行中应用。").foregroundStyle(.secondary) } }
            }.padding(22).frame(width: 480, height: 360)
        }
    }
    private func add(_ id: String) { bundleIDs = Array(Set(ids + [id])).sorted().joined(separator: "\n"); error = nil }
    private func chooseApplication() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications"); panel.prompt = "添加应用"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let id = Bundle(url: url)?.bundleIdentifier, id != Bundle.main.bundleIdentifier else { error = "请选择其他具有应用标识的 Mac 应用。"; return }
        add(id)
    }
}
