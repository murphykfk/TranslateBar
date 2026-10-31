import AppKit
import SwiftUI
import TranslateCore

struct ShortcutRecorder: NSViewRepresentable {
    @Binding var value: TranslateCore.KeyboardShortcut
    func makeNSView(context: Context) -> RecordingButton {
        let button = RecordingButton(); button.bezelStyle = .rounded; button.target = button; button.action = #selector(RecordingButton.begin)
        button.setAccessibilityLabel("录制快捷键")
        button.setAccessibilityElement(true)
        button.setAccessibilityRole(.button)
        button.onRecord = { shortcut in value = shortcut }
        return button
    }
    func updateNSView(_ button: RecordingButton, context: Context) { button.value = value; button.setAccessibilityValue(value.display); if !button.recording { button.title = value.display }; button.onRecord = { value = $0 } }
}

final class RecordingButton: NSButton {
    var value = TranslateCore.KeyboardShortcut(keyCode: 17, label: "T")
    var recording = false
    var onRecord: ((TranslateCore.KeyboardShortcut) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    @objc func begin() { recording = true; title = "按下组合键…"; window?.makeFirstResponder(self) }
    override func keyDown(with event: NSEvent) {
        guard recording else { super.keyDown(with: event); return }
        if event.keyCode == 53 { recording = false; title = value.display; return }
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard !flags.intersection([.command, .control, .option]).isEmpty, let key = event.charactersIgnoringModifiers?.uppercased(), key.count == 1,
              key.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { title = "请包含 ⌃ / ⌥ / ⌘"; return }
        let shortcut = TranslateCore.KeyboardShortcut(keyCode: event.keyCode, modifiers: UInt64(flags.rawValue), label: key)
        recording = false; title = shortcut.display; onRecord?(shortcut)
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool { if recording { keyDown(with: event); return true }; return super.performKeyEquivalent(with: event) }
    override func resignFirstResponder() -> Bool { recording = false; title = value.display; return super.resignFirstResponder() }
}

@MainActor struct ResultView: View {
    @ObservedObject var state: ResultState
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label(state.title, systemImage: "character.bubble").font(.headline); Spacer(); if state.busy { ProgressView().controlSize(.small) } }
            if let error = state.error { Label(error, systemImage: "info.circle").font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            if state.error != nil, let hint = state.replacementHint { Text("回填检查：" + hint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            ScrollView {
                VStack(alignment: .leading, spacing: 13) {
                    if !state.source.isEmpty { Text(state.source).font(.callout).foregroundStyle(.secondary).lineLimit(state.isSelection ? 2 : nil).textSelection(.enabled); Divider() }
                    Text(state.busy && state.translation.isEmpty ? "正在翻译…" : state.translation).font(.system(size: 16)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            HStack { Text(state.fromCache ? (state.isSelection ? "本地缓存 · 取消选中后自动隐藏" : "本地缓存 · 未调用 API") : (state.isSelection ? "取消选中后自动隐藏" : "TranslateBar")).font(.caption).foregroundStyle(.secondary); Spacer(); Button("复制译文") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(state.translation, forType: .string) }.disabled(state.translation.isEmpty) }
            if state.isSelection, let exclude = state.excludeApplication {
                HStack { Spacer(); Menu("更多") { Button("在\(state.sourceApplication)中停用文字翻译", action: exclude) }.menuStyle(.borderlessButton).fixedSize().font(.caption) }
            }
        }.padding(20).frame(minWidth: 340, minHeight: 220)
    }
}

@MainActor struct SubtitleView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("实时译声", systemImage: "waveform").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(duration(model.audioSeconds)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if model.settings.followVideo && model.audioPlaybackRate > 1.03 { Text(String(format: "追赶 · %.2f 倍速", model.audioPlaybackRate)).font(.caption).foregroundStyle(.teal) }
                Spacer()
                Menu {
                    ForEach([16.0, 19.0, 23.0, 27.0], id: \.self) { size in
                        Button("字幕 \(Int(size)) 磅" + (model.settings.subtitleFontSize == size ? " ✓" : "")) { model.settings.subtitleFontSize = size }
                    }
                } label: { Image(systemName: "textformat.size") }.help("字幕字号").accessibilityLabel("调整字幕字号")
                Button { model.settings.subtitlesEnabled = false } label: { Image(systemName: "minus") }.help("隐藏字幕").accessibilityLabel("隐藏字幕")
                Button("停止") { model.stopAudio() }.font(.caption)
            }.buttonStyle(.plain)
            if model.settings.showAudioLatency { AudioLatencyView(snapshot: model.audioLatency, connecting: model.audioConnecting, networkSeconds: model.audioRoundTripSeconds) }
            ScrollViewReader { proxy in
                ScrollView { Text(model.subtitle.isEmpty ? "正在聆听…" : model.subtitle).font(.system(size: model.settings.subtitleFontSize)).lineSpacing(5).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).id("subtitle") }
                    .onChange(of: model.subtitle) { proxy.scrollTo("subtitle", anchor: .bottom) }
            }
        }.padding(18).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16)).overlay(RoundedRectangle(cornerRadius: 16).stroke(.quaternary, lineWidth: 1)).padding(3)
    }
}

struct AudioLatencyView: View {
    var snapshot: AudioLatencySnapshot
    var connecting: Bool
    var networkSeconds: Double?
    var body: some View {
        HStack(spacing: 12) {
            Label(status, systemImage: "timer")
            if snapshot.receivedAudio { Text("播放排队 ≈\(seconds(snapshot.playbackQueueSeconds)) 秒") }
            if let networkSeconds { Text(String(format: "网络 %.0f 毫秒", networkSeconds * 1000)) }
        }
        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        .help("首段响应：首次检测到来源声音，到首个含声音的译声片段返回；不包含连接准备与播放排队。播放排队：本机待播时长估算。网络：WebSocket Ping/Pong 往返，每 5 秒更新，不包含模型理解和翻译时间。接口帧进度不能稳定对应视频时间，因此不据此显示每句话的总延迟。")
    }
    private var status: String {
        if connecting { return "延迟：连接中…" }
        if let value = snapshot.firstAudioSeconds { return "首段响应 \(seconds(value)) 秒" }
        if let waiting = snapshot.waitingForAudioSeconds { return "等待首段译声 \(seconds(waiting)) 秒" }
        return "延迟：等待声音…"
    }
    private func seconds(_ value: Double) -> String { String(format: "%.1f", value) }
}

func money(_ amount: Double, digits: Int = 4) -> String {
    if digits == 4 && amount > 0 && amount < 0.0001 { return "<$0.0001" }
    return String(format: "$%.*f", digits, amount)
}
func duration(_ seconds: Double) -> String { let value = max(0, Int(seconds)); return String(format: "%02d:%02d", value / 60, value % 60) }
