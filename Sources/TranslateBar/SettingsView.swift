import AppKit
import SwiftUI
import TranslateCore

enum SettingsPage: String, CaseIterable, Identifiable {
    case general = "常规", languages = "语言", input = "输入翻译", selection = "划词翻译", audio = "实时译声", api = "模型与 API", budget = "费用与限额"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .general: return "gearshape"; case .languages: return "globe"; case .input: return "space"; case .selection: return "text.cursor"
        case .audio: return "waveform"; case .api: return "cpu"; case .budget: return "chart.pie"
        }
    }
    var detail: String {
        switch self {
        case .general: return "启动、权限与本地数据。"
        case .languages: return "分别设置写作、阅读和译声的目标语言。"
        case .input: return "只替换光标所在段落，其他段落保持原样。"
        case .selection: return "选中文字后显示译文，不修改原文。"
        case .audio: return "翻译所选应用正在播放的声音。"
        case .api: return "选择文字模型，连接你的 OpenAI 账户。"
        case .budget: return "所有 API 翻译共用本地预算。"
        }
    }
}

@MainActor struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var page: SettingsPage = .general
    @State private var newKey = ""
    @State private var showModels = false
    @State private var showInputAdvanced = false
    @State private var showAudioAdvanced = false
    @State private var confirmClearCache = false
    @State private var confirmRemoveKey = false
    @State private var showCustomTest = false
    @State private var showModelAdvanced = false
    @State private var showRates = false
    @State private var showPractice = false
    @State private var selectedInitialPage = false

    var body: some View {
        Group {
            if model.setup.isPresented {
                if model.setup.isPermissionRecovery { PermissionRecoveryView(model: model) }
                else { SetupGuideView(model: model) }
            }
            else { settingsContent }
        }.frame(minWidth: 880, minHeight: 650)
        .sheet(isPresented: Binding(get: { model.recordingPermission.isPresented }, set: { model.recordingPermission.isPresented = $0 })) { RecordingPermissionView(model: model) }
    }
    private var settingsContent: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("TranslateBar").font(.headline).padding(.horizontal, 18).padding(.top, 24).padding(.bottom, 16)
                List(selection: $page) {
                    Section("偏好设置") {
                        ForEach([SettingsPage.general, .languages, .input, .selection, .audio]) { item in sidebar(item) }
                    }
                    Section("连接与用量") {
                        ForEach([SettingsPage.api, .budget]) { item in sidebar(item) }
                    }
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 5) {
                    Label(model.readinessSummary, systemImage: model.textPermissionIssue != nil ? "exclamationmark.triangle" : model.settings.enabled ? "checkmark.circle" : "pause.circle")
                    Text("版本 \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版")").foregroundStyle(.tertiary)
                }.font(.caption).foregroundStyle(.secondary).padding(18)
            }.frame(width: 184).background(.regularMaterial)
            Divider()
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(page.rawValue).font(.title2.weight(.semibold))
                    Text(page.detail).font(.callout).foregroundStyle(.secondary)
                }.padding(.horizontal, 24).padding(.top, 22).padding(.bottom, 10)
                if let issue = model.textPermissionIssue {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(issue.title).font(.callout.weight(.medium))
                            Text("输入与划词翻译暂不可用，请恢复当前版本的权限。").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("恢复权限…") { model.showPermissionRecovery() }
                    }.padding(12).background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 24).padding(.bottom, 8)
                }
                Group {
                    switch page {
                    case .general: generalSettings
                    case .languages: languageSettings
                    case .input: inputSettings
                    case .selection: selectionSettings
                    case .audio: audioSettings
                    case .api: apiSettings
                    case .budget: budgetSettings
                    }
                }.id(page).frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: model.translating || model.audioConnecting ? "ellipsis.circle" : "info.circle")
                    Text(model.lastMessage).lineLimit(2).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Text("更改自动保存").foregroundStyle(.tertiary)
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 24).padding(.vertical, 11)
            }.background(Color(nsColor: .windowBackgroundColor))
        }.frame(minWidth: 880, minHeight: 650)
        .sheet(isPresented: $showModels) { AccountModelsView(model: model) }
        .sheet(isPresented: $showPractice) { TranslationPracticeView(model: model) }
        .onDisappear { newKey = "" }
        .onAppear { selectInitialPage() }
        .onChange(of: model.credentials.didLoad) { selectInitialPage() }
        .onChange(of: page) { selectedInitialPage = true }
        .onChange(of: newKey) { model.credentials.clearInputError() }
        .alert("移除本机保存的 API Key？", isPresented: $confirmRemoveKey) {
            Button("取消", role: .cancel) {}
            Button("移除密钥", role: .destructive) { model.removeKey() }
        } message: { Text("联网翻译会停止，之后可重新粘贴密钥。本地缓存和费用记录保留；OpenAI 平台上的密钥不会被撤销。") }
        .alert("清空本地翻译缓存？", isPresented: $confirmClearCache) {
            Button("取消", role: .cancel) {}
            Button("清空缓存", role: .destructive) { model.clearTranslationCache() }
        } message: { Text("会删除本机保存的 \(model.translationCache.count) 条原文与译文。调用记录和费用统计会保留。") }
    }
    private func selectInitialPage() {
        guard !selectedInitialPage, model.credentials.didLoad else { return }
        selectedInitialPage = true
        if !model.keyConfigured { page = .api }
    }
    private func sidebar(_ item: SettingsPage) -> some View { Label(item.rawValue, systemImage: item.icon).tag(item).padding(.vertical, 3) }
    private func note(_ text: String) -> some View { Text(text).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
    private var hasUnsavedKey: Bool { !newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private var generalSettings: some View {
        Form {
            Section {
                Toggle("启用 TranslateBar", isOn: $model.settings.enabled)
                Toggle("登录后自动启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLogin($0) }))
            } footer: { note("关闭总开关会暂停文字翻译与译声。关闭设置窗口后，应用仍在菜单栏运行。") }
            Section("运行状态") {
                HStack { LabeledContent("OpenAI 密钥", value: model.keyLoading ? "正在读取…" : model.credentials.requiresStorageRetry ? "需要解锁 / 重试" : model.keyConfigured ? "已保存到钥匙串" : "未配置"); Button(model.keyConfigured ? "管理…" : "配置…") { page = .api } }
                TextPermissionFields(model: model)
                HStack {
                    Text(model.setupReadiness.canFinish ? "文字翻译已准备好。" : "密钥与文字权限尚未全部就绪。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("翻译练习…") { showPractice = true }
                    Button("设置引导…") { model.showSetupGuide() }
                }
            }
            Section {
                Toggle("使用本地翻译缓存", isOn: $model.settings.cacheEnabled)
                HStack { Text("已保存 \(model.translationCache.count) 条译文").foregroundStyle(.secondary); Spacer(); Button("清空缓存…", role: .destructive) { confirmClearCache = true }.disabled(model.translationCache.count == 0 && model.translationCache.error == nil) }
                if let error = model.translationCache.error { Label(error, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
            } header: { Text("本地缓存") } footer: { note("输入与划词翻译共用，重启后保留。原文、目标语言、原文语言设置和模型一致时直接复用，不调用 API。关闭后保留已有缓存；清空会删除本机保存的原文和译文。译声不缓存。") }
            Section {
                Toggle("增强取词与回填兼容", isOn: $model.settings.enhancedCompatibility)
                note("优先使用系统文本接口；无法取词时临时复制选区并恢复剪贴板。Word 正文会额外检查可编辑状态及换行边界；其他兼容控件仅替换光标前当前行。不全选整个页面，密码框与排除的应用始终跳过。")
                Toggle("WPS 文字兼容模式", isOn: $model.settings.wpsCompatibilityEnabled)
                note("WPS 正文无法直接取词时，通过临时复制读取所选文字并恢复剪贴板。输入翻译只处理光标之前的当前段落，不整篇覆盖；正文的字号与粗细会保留。")
                HStack {
                    Text("遇到问题时可复制最近一次失败的状态记录，不含原文或 API Key。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("复制兼容性诊断") { model.copyCompatibilityDiagnostic() }.disabled(model.translating)
                }
            } header: { Text("应用兼容性") }
            Section {
                ExcludedApplicationsView(bundleIDs: $model.settings.excludedBundleIDs)
            } header: { Text("排除应用") } footer: { note("这些应用中的输入与划词翻译都会停用。密码输入框始终跳过。") }

        }.formStyle(.grouped)
    }

    private var languageSettings: some View {
        Form {
            Section {
                LanguagePicker(title: "原文语言", value: $model.settings.textSourceLanguage, allowAutomatic: true)
                Toggle("原文已是目标语言时跳过", isOn: $model.settings.skipSameLanguage)
            } header: { Text("文字语言识别") } footer: { note("默认自动识别，无需分别开启日语、法语等语种。短词和混合语言可能识别不准，可手动指定原文语言；不确定时仍交给模型翻译。语言设置不会自动发送文本，仍需空格或划词触发。") }
            languageRuleSection("输入翻译", target: $model.settings.inputLanguage, fallback: $model.settings.inputFallbackLanguage, mode: $model.settings.inputLanguageMode)
            languageRuleSection("划词翻译", target: $model.settings.readingLanguage, fallback: $model.settings.readingFallbackLanguage, mode: $model.settings.readingLanguageMode)
            Section {
                Picker("译声输出语言", selection: $model.settings.audioLanguage) {
                    ForEach(TranslationLanguage.audio) { language in Text(language.title).tag(language.id == "zh-Hans" ? "zh" : language.id) }
                }
                LabeledContent("原声语言", value: "由译声模型自动识别")
            } header: { Text("实时译声") } footer: { note("译声使用独立的语音模型与语言设置，始终输出所选语言，不使用文字的智能互译规则。这里列出当前应用已适配的 7 种输出语言。更改后需重新开始译声。") }
        }.formStyle(.grouped)
    }
    private func languageRuleSection(_ title: String, target: Binding<String>, fallback: Binding<String>, mode: Binding<TranslationLanguageMode>) -> some View {
        Section(title) {
            LanguageRuleFields(target: target, fallback: fallback, mode: mode, source: model.settings.textSourceLanguage, skipSame: model.settings.skipSameLanguage)
        }
    }
    private func languageSummary(input: Bool) -> some View {
        Group {
            if input {
                LanguageRuleFields(target: $model.settings.inputLanguage, fallback: $model.settings.inputFallbackLanguage, mode: $model.settings.inputLanguageMode, source: model.settings.textSourceLanguage, skipSame: model.settings.skipSameLanguage)
            } else {
                LanguageRuleFields(target: $model.settings.readingLanguage, fallback: $model.settings.readingFallbackLanguage, mode: $model.settings.readingLanguageMode, source: model.settings.textSourceLanguage, skipSame: model.settings.skipSameLanguage)
            }
            Button("原文识别与全部语言设置…") { page = .languages }.font(.caption)
        }
    }
    private var inputSettings: some View {
        Form {
            Section {
                Toggle("启用空格翻译", isOn: $model.settings.fourSpacesEnabled)
                Picker("连续按空格次数", selection: $model.settings.spaceCount) { Text("2 次 · 快速").tag(2); Text("3 次 · 适中").tag(3); Text("4 次 · 减少误触（默认）").tag(4) }.disabled(!model.settings.fourSpacesEnabled)
                LabeledContent("替换范围", value: "仅光标所在段落")
            } footer: { note("输入完成后，快速轻按 \(model.settings.spaceCount) 次空格，松开后翻译当前段落。回车上方的段落不参与翻译；自动换行仍属于同一段。空段落跳过。长按空格不会触发。") }
            Section("输出语言") { languageSummary(input: true) }
            Section("操作反馈与撤销") {
                Toggle("在输入框附近显示翻译过程提示", isOn: $model.settings.inputFeedbackEnabled)
                shortcut("撤销上次翻译替换", value: $model.settings.undoShortcut)
                Button("试一试输入与划词翻译…") { showPractice = true }
            }
            Section {
                DisclosureGroup("触发速度与兼容性", isExpanded: $showInputAdvanced) {
                    HStack { Text("相邻空格最长间隔"); Spacer(); Slider(value: $model.settings.spaceInterval, in: 0.15...0.6, step: 0.01).frame(maxWidth: 180); Text(String(format: "%.2f 秒", model.settings.spaceInterval)).monospacedDigit().frame(width: 65) }
                    note("两次空格之间超过该时间，计数重新开始。输入法选词完成后再触发。")
                    note("保留备忘录的段落字号与粗细。无法安全保留混合样式时，会显示译文而保留原文。翻译等待期间继续输入或切换焦点，也不会覆盖新内容。")
                }
            }
        }.formStyle(.grouped)
    }
    private var selectionSettings: some View {
        Form {
            Section {
                Toggle("启用划词翻译", isOn: $model.settings.selectionEnabled)
                Toggle("鼠标选中后自动翻译", isOn: $model.settings.automaticSelection).disabled(!model.settings.selectionEnabled)
                shortcut("手动翻译选中文字", value: $model.settings.selectionShortcut)
            } footer: { note(model.settings.automaticSelection ? "鼠标拖选文字并松开，即可查看译文；也可以按快捷键。再次点击其他位置、取消选择或切换应用后，浮窗自动消失。" : "选中文字后按快捷键查看译文。开启自动翻译后，鼠标松开即可触发。") }
            Section("输出语言") { languageSummary(input: false) }
            Section("兼容范围") {
                note("支持应用提供的可读取文字选区。不使用截图或 OCR；无法读取的选区会跳过。")
                note("与输入翻译共用本地缓存；自动划词在缓存未命中时会调用 API，并计入费用预算。")
                Button("管理缓存与排除应用…") { page = .general }
            }
        }.formStyle(.grouped)
    }

    private var audioSettings: some View {
        VStack(spacing: 0) {
            // Keep the session action visible even when advanced options scroll.
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(model.audioState, systemImage: model.audioRunning ? "waveform" : model.audioConnecting ? "ellipsis.circle" : "play.circle")
                            .font(.headline)
                        note(model.audioRunning ? "已运行 \(duration(model.audioSeconds)) · 停止后恢复原声" : "播放视频后开始 · $0.034 / 分钟")
                    }
                    Spacer()
                    Button(model.audioConnecting ? "取消连接" : model.audioRunning ? "停止译声" : "开始译声") { model.toggleAudio() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(!model.settings.enabled || !model.settings.audioEnabled || !model.keyConfigured || model.keyLoading)
                }
                if !model.keyConfigured { Button("配置 API Key…") { page = .api }.font(.caption) }
                else if !model.settings.enabled { note("总开关已暂停，请在常规中恢复。") }
                else if !model.settings.audioEnabled { note("请先开启下方的实时译声开关。") }
                if model.audioRunning { ProgressView(value: Double(model.audioLevel)).accessibilityLabel("音频输入电平") }
                if model.settings.showAudioLatency && (model.audioRunning || model.audioConnecting) {
                    AudioLatencyView(snapshot: model.audioLatency, connecting: model.audioConnecting, networkSeconds: model.audioRoundTripSeconds)
                }
            }.padding(.horizontal, 24).padding(.vertical, 16)
            Divider()
            Form {
                Section {
                    Toggle("启用实时译声", isOn: $model.settings.audioEnabled)
                    HStack {
                        Picker("声音来源", selection: $model.settings.audioSourceBundleID) {
                            if !model.audioSources.contains(where: { $0.id == model.settings.audioSourceBundleID }) { Text("未运行 · " + model.settings.audioSourceBundleID).tag(model.settings.audioSourceBundleID) }
                            ForEach(model.audioSources) { Text($0.name).tag($0.id) }
                        }.disabled(audioSessionActive)
                        Button { model.refreshSources() } label: { Image(systemName: "arrow.clockwise") }
                            .help("刷新正在运行的应用").accessibilityLabel("刷新音频来源").disabled(audioSessionActive)
                    }
                    AudioLanguagePicker(value: $model.settings.audioLanguage).disabled(audioSessionActive)
                    if audioSessionActive { note("停止译声后可更换来源、语言与原声设置。") }
                } footer: { note("原声语言自动识别，始终译为上方所选语言。仅接收所选应用音频，不接收画面或麦克风；请避免该应用的其他标签页同时发声。") }
                Section("播放与字幕") {
                    Toggle("译声期间静音原声", isOn: $model.settings.muteOriginal).disabled(audioSessionActive)
                    if model.originalMuteActive { Label("原声已静音", systemImage: "speaker.slash.fill").font(.caption).foregroundStyle(.secondary) }
                    HStack {
                        Text("译声音量"); Spacer()
                        Slider(value: $model.settings.audioVolume, in: 0...1).frame(maxWidth: 220).accessibilityLabel("译声音量")
                        Text("\(Int(model.settings.audioVolume * 100))%").monospacedDigit().frame(width: 40)
                    }
                    Toggle("显示悬浮字幕", isOn: $model.settings.subtitlesEnabled)
                    Picker("字幕字号", selection: $model.settings.subtitleFontSize) {
                        ForEach([16.0, 19.0, 23.0, 27.0], id: \.self) { Text("\(Int($0)) 磅").tag($0) }
                        if ![16.0, 19.0, 23.0, 27.0].contains(model.settings.subtitleFontSize) { Text("\(Int(model.settings.subtitleFontSize)) 磅").tag(model.settings.subtitleFontSize) }
                    }
                    Toggle("显示延迟数值", isOn: $model.settings.showAudioLatency)
                }
                if model.audioRunning || !model.subtitle.isEmpty && model.audioSeconds > 0 {
                    Section("当前译文") { Text(model.subtitle.isEmpty ? "正在聆听…" : model.subtitle).textSelection(.enabled) }
                }
                Section {
                    DisclosureGroup("快捷键、权限与自动停止", isExpanded: $showAudioAdvanced) {
                        shortcut("开始或停止译声", value: $model.settings.audioShortcut)
                        HStack {
                            LabeledContent("录屏与系统录音", value: model.recordingPermission.granted ? "已授权" : "首次开始时引导")
                            Button("查看权限…") { model.recordingPermission.isPresented = true }
                        }
                        Stepper("单次最多 \(Int(model.settings.maximumAudioMinutes)) 分钟", value: $model.settings.maximumAudioMinutes, in: 1...120, step: 1)
                        Picker("持续静音后停止", selection: $model.settings.silenceStopSeconds) { Text("不自动停止").tag(0.0); Text("15 秒").tag(15.0); Text("30 秒").tag(30.0); Text("60 秒").tag(60.0) }
                        Toggle("加速追赶（实验）", isOn: $model.settings.followVideo).disabled(audioSessionActive)
                        note("默认保留自然语速和句内停顿。实验追赶仅在积压时轻微加速；如声音不连贯请关闭。")
                    }
                }
            }.formStyle(.grouped)
        }
    }
    private var audioSessionActive: Bool { model.audioRunning || model.audioConnecting }

    private var apiSettings: some View {
        Form {
            Section {
                APIKeyEntryFields(model: model, draft: $newKey, remove: { confirmRemoveKey = true })
            } header: { Text("你的 OpenAI API Key") } footer: { note("密钥仅保存在这台 Mac 的钥匙串中，不随安装包分享。翻译请求直接发送到 OpenAI 官方 API；换电脑后需要重新粘贴。") }
            Section {
                Picker("文字翻译模型", selection: Binding(get: { model.settings.textModel.isKnown ? model.settings.textModel.rawValue : "custom" }, set: { model.settings.textModel = $0 == "custom" ? TextModel(id: "") : .named($0) })) {
                    ForEach(TextModel.allCases) { Text($0.title).tag($0.rawValue) }; Text("自定义模型…").tag("custom")
                }
                if !model.settings.textModel.isKnown {
                    TextField("模型 ID", text: Binding(get: { model.settings.textModel.rawValue }, set: { model.settings.textModel = .named($0) })).textFieldStyle(.roundedBorder)
                }
                HStack { note("输入与划词翻译共用此模型。"); Spacer(); Button("完整账户列表…") { showModels = true } }
                DisclosureGroup("输出长度", isExpanded: $showModelAdvanced) {
                    Picker("最大输出长度", selection: $model.settings.maxOutputTokens) { Text("2,048 tokens").tag(2048); Text("4,096 tokens（默认）").tag(4096); Text("8,192 tokens").tag(8192) }
                }
                if !model.settings.textModel.canTranslateText { Label("请填写文字模型 ID，不能选择音频或图像等专用模型。", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
            } header: { Text("文字模型") } footer: { note("nano 适合日常短句，mini 可用于较复杂的文本。账户列表包含其他用途的模型；自定义模型需支持 Responses API，实际可用性以连接测试为准。更换模型不会清空缓存。") }
            Section {
                HStack { note("使用当前文字模型和划词目标语言，测试会产生少量 API 费用并计入本地预算。"); Spacer(); Button(model.translating ? "测试中…" : "测试连接") { model.testTranslation() }.disabled(hasUnsavedKey || model.translating || model.keyLoading || !model.keyConfigured || !model.settings.enabled || !model.settings.textModel.canTranslateText || !model.settings.textModel.pricing.isValid) }
                if hasUnsavedKey { note("请先保存粘贴的密钥，再测试连接。") }
                if !model.settings.enabled { note("TranslateBar 已暂停，恢复总开关后可测试连接。") }
                if !model.testOutput.isEmpty { Text(model.testOutput).textSelection(.enabled) }
                DisclosureGroup("自定义测试文本", isExpanded: $showCustomTest) {
                    TextEditor(text: $model.testInput).font(.body).frame(height: 55).accessibilityLabel("连接测试文本")
                }
            } header: { Text("测试当前模型") }
            Section {
                if model.settings.textModel.isKnown {
                    DisclosureGroup("查看当前文字费率", isExpanded: $showRates) {
                    LabeledContent("输入 / 缓存输入 / 输出", value: "\(money(model.settings.textModel.inputRate, digits: 3)) / \(money(model.settings.textModel.cachedRate, digits: 3)) / \(money(model.settings.textModel.outputRate, digits: 3))")
                    note("内置标准费率，核对日期：2026-10-30。")
                    }
                } else {
                    amountField("输入", value: $model.settings.textModel.pricing.input, digits: 4)
                    amountField("缓存输入", value: $model.settings.textModel.pricing.cached, digits: 4)
                    amountField("输出", value: $model.settings.textModel.pricing.output, digits: 4)
                    if !model.settings.textModel.pricing.isValid { Label("填写费率后才能调用，以便预算正确预留和结算。", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                }
                Link("查看 OpenAI 官方价格", destination: URL(string: "https://developers.openai.com/api/docs/pricing")!)
            } header: { Text("文字费率 · 美元 / 百万 tokens") } footer: { note("自定义费率按标准文本调用填写。缓存输入填 0 时，按普通输入价格保守估算；已知价格可单独填写。") }
            Section {
                LabeledContent("实时译声模型", value: "gpt-realtime-translate")
                LabeledContent("语音费率", value: "$0.034 / 分钟")
            } footer: { note("译声使用专用接口，不能换成普通文字模型。此处固定显示当前已适配的语音模型。") }
        }.formStyle(.grouped)
    }

    private var budgetSettings: some View {
        Form {
            Section {
                Toggle("启用本地费用限额", isOn: $model.settings.budget.enabled)
                Picker("预算周期", selection: $model.settings.budget.period) { ForEach(BudgetPeriod.allCases) { Text($0.title).tag($0) } }
                amountField("总预算（美元）", value: $model.settings.budget.limit)
                amountField("提前停止预留（美元）", value: $model.settings.budget.buffer)
                Picker("费用提醒", selection: $model.settings.budget.warningFraction) { Text("达到 50%").tag(0.5); Text("达到 80%").tag(0.8); Text("达到 90%").tag(0.9) }
                if !model.settings.budget.isValid { Label("预算必须大于零，预留必须小于预算。当前会阻止新调用。", systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            } footer: { note("例如预算 $10、预留 $0.50，会在约 $9.50 时停止新调用。文字和译声共用总预算；关闭限额后仍记录用量，重新开启不会清零。") }
            Section {
                Toggle("另外限制译声费用", isOn: $model.settings.budget.audioLimitEnabled)
                amountField("译声额度（美元）", value: $model.settings.budget.audioLimit).disabled(!model.settings.budget.audioLimitEnabled)
            } footer: { note("译声额度包含在总预算内，两个上限同时生效。") }
            Section("当前周期用量") {
                LabeledContent("预估总费用", value: money(model.spent))
                LabeledContent("其中实时译声", value: money(model.audioSpent))
                LabeledContent("剩余可用（扣除预留）", value: model.settings.budget.enabled ? money(model.remaining) : "不限额")
                ProgressView(value: model.budgetProgress).tint(model.budgetWarning ? .orange : .accentColor)
                if model.budgetWarning { Label(model.budgetExhausted ? "预算已用尽，停止新调用。" : "费用已达到提醒阈值。", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.orange) }
                note("按所选模型费率估算，含在途请求预留。用量不明的失败请求会保留预留；本地缓存命中不计费。这里只统计本应用，不能代表同一密钥在其他软件中的费用或账户余额。官方账单以 OpenAI 平台为准。")
                Link("打开 OpenAI 用量与限额", destination: URL(string: "https://platform.openai.com/settings/organization/limits")!)
            }
            Section("最近调用 · 不保存原文") {
                if model.recentRecords.isEmpty { Text("还没有 API 调用记录。").foregroundStyle(.secondary) }
                ForEach(model.recentRecords) { record in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) { Text(record.kind == .audio ? "实时译声" : "文字翻译"); Text(record.date, style: .date).font(.caption).foregroundStyle(.secondary) }
                        Spacer(); Text(record.status == .settled ? "已结算" : record.status == .reserved ? "预留中" : "保守预留").font(.caption).foregroundStyle(.secondary)
                        Text(money(record.amount)).monospacedDigit().frame(width: 90, alignment: .trailing)
                    }
                }
            }
        }.formStyle(.grouped)
    }
    private func shortcut(_ title: String, value: Binding<TranslateCore.KeyboardShortcut>) -> some View {
        let checked = Binding<TranslateCore.KeyboardShortcut>(get: { value.wrappedValue }, set: { newValue in
            let others = [model.settings.selectionShortcut, model.settings.audioShortcut, model.settings.undoShortcut].filter { $0 != value.wrappedValue }
            if others.contains(where: { $0.matches(key: newValue.keyCode, flags: newValue.modifiers) }) { model.lastMessage = "此快捷键已被其他功能使用，请换一个组合。" }
            else { value.wrappedValue = newValue }
        })
        return HStack { Text(title); Spacer(); ShortcutRecorder(value: checked).frame(width: 145, height: 25).accessibilityElement(children: .contain).accessibilityLabel(title) }
    }
    private func amountField(_ title: String, value: Binding<Double>, digits: Int = 2) -> some View {
        HStack { Text(title); Spacer(); TextField(title, value: value, format: .number.precision(.fractionLength(0...digits))).labelsHidden().accessibilityLabel(title).frame(width: 110).textFieldStyle(.roundedBorder) }
    }
}

struct LanguagePicker: View {
    var title: String
    @Binding var value: String
    var allowAutomatic = false
    @State private var custom = false
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(title, selection: Binding(get: { value == "auto" || TranslationLanguage.find(value) != nil ? value : "custom" }, set: { next in
                if next == "custom" { custom = true; value = "" } else { custom = false; value = next }
            })) {
                if allowAutomatic { Text("自动识别（默认）").tag("auto") }
                ForEach(TranslationLanguage.all) { Text($0.title).tag($0.value) }
                Text("其他语言…").tag("custom")
            }
            if custom || (value != "auto" && TranslationLanguage.find(value) == nil) {
                TextField("填写语言名称，如 Icelandic", text: $value).textFieldStyle(.roundedBorder).accessibilityLabel(title + "自定义语言")
                if value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { Text("请填写语言名称。").font(.caption).foregroundStyle(.orange) }
            }
        }
    }
}

@MainActor private struct AccountModelsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var textOnly = true
    @State private var selectedID: String?
    private var filtered: [String] {
        model.availableModels.filter { (!textOnly || !TextModel.isSpecialized($0)) && (query.isEmpty || $0.localizedCaseInsensitiveContains(query)) }.sorted {
            let a = TextModel.named($0).isKnown, b = TextModel.named($1).isKnown
            return a == b ? $0.localizedStandardCompare($1) == .orderedAscending : a
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("账户模型").font(.title2.weight(.semibold)); Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
            Text("从当前 API Key 读取完整模型列表。专用模型仅供查看；其他模型仍需支持文字 Responses API，并通过连接测试。").font(.callout).foregroundStyle(.secondary)
            HStack { TextField("搜索模型 ID", text: $query).textFieldStyle(.roundedBorder).accessibilityLabel("搜索模型"); Button(model.modelsLoading ? "加载中…" : "刷新列表") { model.refreshModels() }.disabled(model.modelsLoading) }
            Toggle("仅显示文字候选", isOn: $textOnly)
            Text(model.modelListMessage).font(.caption).foregroundStyle(.secondary)
            List(filtered, id: \.self, selection: $selectedID) { id in
                HStack {
                    VStack(alignment: .leading, spacing: 3) { Text(id).font(.system(.body, design: .monospaced)); Text(TextModel.isSpecialized(id) ? "专用模型 · 不用于文字翻译" : TextModel.named(id).isKnown ? "常用文字模型 · 已配置费率" : "文字候选 · 兼容性待测试，需填写费率").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    if model.settings.textModel.rawValue == id { Text("当前模型").font(.caption).foregroundStyle(.secondary) }
                }.padding(.vertical, 4).tag(id)
            }.overlay { if filtered.isEmpty { Text(model.modelsLoading ? "正在加载…" : "没有匹配的模型").foregroundStyle(.secondary) } }
            HStack(alignment: .center) {
                Text("显示 \(filtered.count) / \(model.availableModels.count) 个。读取列表不进行模型推理。受限密钥无法读取列表时，可手动填写 ID。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("选用模型") { if let selectedID { model.settings.textModel = .named(selectedID); dismiss() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(selectedID == nil || selectedID == model.settings.textModel.rawValue || selectedID.map { !filtered.contains($0) || TextModel.isSpecialized($0) } == true)
            }
        }.padding(24).frame(width: 640, height: 560)
        .onAppear { if model.availableModels.isEmpty { model.refreshModels() } }
    }
}
