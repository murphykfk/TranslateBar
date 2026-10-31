import AppKit
import SwiftUI
import TranslateCore

struct PermissionStatus: View {
    var ready: Bool
    var text: String
    var body: some View {
        Label {
            Text(text).foregroundStyle(.primary)
        } icon: {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ready ? Color.green : Color.secondary)
        }.font(.callout)
    }
}

@MainActor struct APIKeyEntryFields: View {
    @ObservedObject var model: AppModel
    @Binding var draft: String
    var remove: (() -> Void)? = nil
    var body: some View {
        LabeledContent("密钥状态", value: model.keyLoading ? "正在处理…" : model.keyConfigured ? "已保存到本机钥匙串" : "未配置")
        SecureField(model.keyConfigured ? "粘贴新的 OpenAI API Key 以更换" : "在这里粘贴你的 OpenAI API Key", text: $draft)
            .textFieldStyle(.roundedBorder).accessibilityLabel("OpenAI API Key")
        HStack {
            Button(model.keyLoading ? "正在处理…" : "保存密钥") {
                let submitted = draft
                Task { if await model.saveKey(submitted), draft == submitted { draft = "" } }
            }.disabled(model.keyLoading || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if model.credentials.requiresStorageRetry { Button("解锁 / 重试") { model.reloadKey() }.disabled(model.keyLoading) }
            Spacer()
            if model.keyConfigured, let remove { Button("移除密钥…", role: .destructive, action: remove).disabled(model.keyLoading) }
            Link("获取 API Key ↗", destination: URL(string: "https://platform.openai.com/api-keys")!)
        }
        Text(model.credentials.message).font(.caption)
            .foregroundStyle(model.credentials.error == nil ? Color.secondary : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

@MainActor struct TextPermissionFields: View {
    @ObservedObject var model: AppModel
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("辅助功能")
                Text("读取选中文字，定位输入框并回填译文。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            PermissionStatus(ready: model.accessibilityGranted, text: model.accessibilityGranted ? "已授权" : "待授权")
            Button(model.accessibilityGranted ? "查看…" : "前往授权…") { model.requestAccessibility(); model.openPrivacy("Privacy_Accessibility") }
        }
        HStack {
            VStack(alignment: .leading, spacing: 5) {
                Text("键盘监听")
                Text("识别连续空格和全局翻译快捷键。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            PermissionStatus(ready: model.keyboardActive, text: model.keyboardActive ? "运行中" : !model.settings.enabled ? "翻译已暂停" : !model.accessibilityGranted ? "等待辅助功能授权" : "未运行")
            if !model.keyboardActive {
                Button("启用监听") { model.requestKeyboard() }.disabled(!model.accessibilityGranted || !model.settings.enabled)
            }
        }
        if model.accessibilityGranted && !model.keyboardActive && model.settings.enabled {
            HStack {
                Text("若系统要求输入监控权限，请为 TranslateBar 开启。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("查看输入监控…") { model.openPrivacy("Privacy_ListenEvent") }
            }
        }
        if !model.settings.enabled {
            HStack {
                Text("总开关已暂停，启用后才能检查键盘监听。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("启用 TranslateBar") { model.settings.enabled = true }
            }
        }
    }
}

@MainActor struct SetupGuideView: View {
    @ObservedObject var model: AppModel
    @State private var draft = ""
    @State private var showPractice = false
    private var hasDraft: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var step: SetupStep { model.setup.step }
    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 58, height: 58).accessibilityHidden(true)
                Text("设置 TranslateBar").font(.title.weight(.semibold))
                Text("连接你的 OpenAI 账户，再开启跨应用翻译权限。")
                    .foregroundStyle(.secondary)
                HStack(spacing: 24) {
                    ForEach(SetupStep.allCases, id: \.rawValue) { item in
                        Label(item.title, systemImage: item.rawValue < step.rawValue ? "checkmark.circle.fill" : "\(item.rawValue + 1).circle\(item == step ? ".fill" : "")")
                            .foregroundStyle(item == step ? Color.accentColor : Color.secondary)
                            .accessibilityAddTraits(item == step ? .isSelected : [])
                    }
                }.font(.callout.weight(.medium)).padding(.top, 4)
            }.padding(.top, 28).padding(.bottom, 12)
            Form {
                switch step {
                case .key: keySection
                case .permissions: permissionSections
                case .ready: readySections
                }
            }.formStyle(.grouped).frame(maxWidth: 700).frame(maxWidth: .infinity)
            Divider()
            HStack {
                Button("稍后设置") { model.setup.deferSetup() }
                Spacer()
                if step != .key {
                    Button("上一步") { model.setup.step = step == .ready ? .permissions : .key }
                }
                Button(step == .ready ? "完成设置" : "继续") { advance() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(!canAdvance)
            }.padding(.horizontal, 30).padding(.vertical, 18)
        }.background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: draft) { model.credentials.clearInputError() }
        .onDisappear { draft = "" }
        .sheet(isPresented: $showPractice) { TranslationPracticeView(model: model) }
    }
    private var canAdvance: Bool {
        switch step {
        case .key: return model.credentials.didLoad && model.keyConfigured && !model.keyLoading && !hasDraft
        case .permissions: return model.setupReadiness.textReady
        case .ready: return model.setupReadiness.canFinish
        }
    }
    private func advance() {
        switch step {
        case .key: model.setup.step = .permissions
        case .permissions: model.setup.step = .ready
        case .ready: _ = model.setup.finish(readiness: model.setupReadiness)
        }
    }
    private var keySection: some View {
        Group {
            Section {
                APIKeyEntryFields(model: model, draft: $draft)
                if hasDraft && model.keyConfigured { Text("请先保存新密钥，或清空输入框后继续。").font(.caption).foregroundStyle(.secondary) }
            } header: { Text("1. 添加你的 API Key") } footer: {
                Text("密钥仅保存到这台 Mac 的钥匙串。保存密钥不会自动调用 API，也不代表接口已验证。")
            }
            Section {
                HStack {
                    Text("测试当前文字模型，会产生少量费用并计入本地预算。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(model.translating ? "测试中…" : "测试连接") { model.testTranslation() }
                        .disabled(hasDraft || model.translating || model.keyLoading || !model.keyConfigured || !model.settings.enabled || !model.settings.textModel.canTranslateText || !model.settings.textModel.pricing.isValid)
                }
                if !model.testOutput.isEmpty { Text(model.testOutput).textSelection(.enabled) }
                else if model.translating { ProgressView().controlSize(.small) }
                Text(model.lastMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } header: { Text("连接测试 · 可选") } footer: {
                Text("模型、目标语言和费用限额可以在完成引导后继续调整。")
            }
        }
    }
    private var permissionSections: some View {
        Group {
            Section {
                TextPermissionFields(model: model)
                HStack {
                    Text("返回应用后会自动检查，也可以手动刷新。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("重新检查") { model.refreshPermissions() }
                }
            } header: { Text("2. 开启文字翻译权限") } footer: {
                Text("在系统设置 → 隐私与安全性中找到 TranslateBar 并开启。监听已运行时，无需额外申请输入监控；如系统要求重新打开应用，请重启后继续。")
            }
            Section {
                Label("译声权限在首次使用时申请", systemImage: "waveform")
                Text("文字翻译不需要录制权限。开始译声时会说明“录屏与系统录音”的用途，再由你授权。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var readySections: some View {
        Group {
            Section {
                PermissionStatus(ready: model.keyConfigured, text: model.keyConfigured ? "API Key 已保存" : "API Key 未配置")
                PermissionStatus(ready: model.accessibilityGranted, text: model.accessibilityGranted ? "辅助功能已授权" : "辅助功能待授权")
                PermissionStatus(ready: model.keyboardActive, text: model.keyboardActive ? "键盘监听运行中" : "键盘监听未运行")
                if !model.setupReadiness.canFinish {
                    Button("返回检查未完成项") { model.setup.step = model.setupReadiness.firstStep }
                }
            } header: { Text("3. 检查运行状态") }
            Section {
                Label("输入后快速按 \(model.settings.spaceCount) 次空格，只替换光标所在段落。", systemImage: "space")
                Label(model.settings.automaticSelection ? "鼠标选中文字即可查看译文，也可按 \(model.settings.selectionShortcut.display)。" : "选中文字后按 \(model.settings.selectionShortcut.display) 查看译文。", systemImage: "text.cursor")
                Label("播放视频后，在“实时译声”选择声音来源并开始。", systemImage: "waveform")
            } header: { Text("开始使用") } footer: {
                Text("关闭窗口后，TranslateBar 继续在菜单栏运行。可随时在“常规”中重新打开设置引导。")
            }
            Section {
                Button("打开翻译练习…") { showPractice = true }
                Text("可选：在独立练习框中体验空格替换、选区翻译和撤销。使用当前模型与预算，缓存未命中时会调用 API。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

@MainActor struct RecordingPermissionView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("允许读取所选应用的声音", systemImage: "waveform.circle")
                .font(.title2.weight(.semibold))
            Text("实时译声需要 macOS 的“录屏与系统录音”权限。应用只接收所选来源的音频，不接收或上传画面，也不使用麦克风。")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                Text("1. 打开系统设置 → 隐私与安全性 → 录屏与系统录音。")
                Text("2. 为 TranslateBar 开启“录屏与系统录音”；当前实现仅开启“系统录音”仍不足以取音。")
                Text("3. 返回后检查状态；若系统要求重启应用，请重新打开后再开始。")
            }.font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                PermissionStatus(ready: model.recordingPermission.granted, text: model.recordingPermission.granted ? "系统录制权限已授权" : "等待系统授权")
                Spacer()
                Button("重新检查") { model.recordingPermission.refresh() }
            }
            Text("开始译声前不会连接语音 API 或发送音频。停止译声后会恢复原声。")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack {
                Button("取消") { model.recordingPermission.isPresented = false }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(model.recordingPermission.granted ? "查看系统权限…" : "前往授权…") { model.requestRecordingPermission() }
                Button("开始译声") {
                    model.recordingPermission.isPresented = false
                    model.startAudio()
                }.buttonStyle(.borderedProminent).disabled(!model.recordingPermission.granted)
            }
        }.padding(28).frame(width: 570)
    }
}
