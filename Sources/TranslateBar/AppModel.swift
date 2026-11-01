import AppKit
import Combine
import ServiceManagement
import TranslateCore

@MainActor final class ResultState: ObservableObject {
    @Published var title = "翻译"
    @Published var source = ""
    @Published var translation = ""
    @Published var busy = false
    @Published var error: String?
    @Published var replacementHint: String?
    @Published var isSelection = false
    @Published var fromCache = false
    @Published var sourceApplication = ""
    var excludeApplication: (() -> Void)?
    var selectionAnchor: NSRect?
}

@MainActor final class AppModel: ObservableObject {
    @Published var settings: AppSettings { didSet { settingsChanged(from: oldValue) } }
    let credentials = APIKeyController()
    let setup = SetupController()
    let recordingPermission = RecordingPermissionController()
    var keyConfigured: Bool { credentials.configured }
    var keyLoading: Bool { credentials.busy }
    var keyLocation: String { credentials.configured ? "本机钥匙串" : "未配置" }
    @Published var accessibilityGranted = AccessibleText.trusted
    @Published var keyboardActive = false
    @Published var audioSources: [AudioSource] = []
    @Published var audioState = "未开始"
    @Published var audioRunning = false
    @Published var audioConnecting = false
    @Published var originalMuteActive = false
    @Published var audioSeconds = 0.0
    @Published var audioLevel: Float = 0
    @Published var audioLatency = AudioLatencySnapshot()
    @Published var audioPlaybackRate = 1.0
    @Published var audioRoundTripSeconds: Double?
    @Published var subtitle = "开始译声后，译文会显示在这里。"
    @Published var lastMessage = "准备就绪"
    @Published var translating = false
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled
    @Published var testInput = "The meeting starts at ten tomorrow morning."
    @Published var testOutput = ""
    @Published var availableModels: [String] = []
    @Published var modelsLoading = false
    @Published var modelListMessage = "尚未从账户加载模型。"
    let budget: BudgetController
    let translationCache: TranslationCacheController
    private let textService: TextTranslationService
    let result = ResultState()
    let inputFeedback = InputFeedbackState()
    var showInputFeedback: (() -> Void)?
    var hideInputFeedback: (() -> Void)?
    var showResult: (() -> Void)?
    var hideResult: (() -> Void)?
    var resultContainsPoint: ((NSPoint) -> Bool)?
    var resultHasKeyboardFocus: (() -> Bool)?
    var onSelectionDismissal: ((String) -> Void)?
    var showSubtitle: (() -> Void)?
    var hideSubtitle: (() -> Void)?
    var statusChanged: (() -> Void)?
    var requestSettings: (() -> Void)?
    let monitor = InputMonitor()
    private var apiKey: String { credentials.value }
    private var keyGeneration: UUID { credentials.revision }
    private var modelsTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var translationTask: Task<Void, Never>?
    private var audioTask: Task<Void, Never>?
    private var sendTask: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var startupDeadline: Task<Void, Never>?
    private var latencyTimer: Task<Void, Never>?
    private var latencyTracker = AudioLatencyTracker()
    private let capture = ScreenAudioCapture()
    private let playback = AudioPlayback()
    private var realtime: RealtimeSession?
    private var audioToken = UUID()
    private var audioQueue: [Data] = []
    private var reservation: UUID?
    private var periodBytes = 0
    private var totalBytes = 0
    private var reservedAudio = 0.0
    private var startedAt = Date()
    private var lastLoudAudio = Date()
    private var lastCapturedAudio = Date()
    private var undoSnapshot: TextSnapshot?
    private var selectionLifetime = SelectionPopupLifetime()
    private var selectionWatcher: Task<Void, Never>?
    private var selectionSnapshot: TextSnapshot?
    private var pendingSelectionPID: pid_t?
    private let settingsURL = LocalFiles.directory.appendingPathComponent("settings.json")

    init() {
        let settingsFile = LocalFiles.directory.appendingPathComponent("settings.json")
        var settingsFailed = false
        if FileManager.default.fileExists(atPath: settingsFile.path) {
            do { settings = try LocalFiles.read(AppSettings.self, from: settingsFile) }
            catch { var fallback = AppSettings(); fallback.enabled = false; settings = fallback; settingsFailed = true }
        } else { settings = AppSettings() }
        budget = BudgetController()
        translationCache = TranslationCacheController()
        textService = TextTranslationService(cache: translationCache, budget: budget)
        if !settingsFailed { try? LocalFiles.write(settings, to: settingsURL) }
        credentials.onChange = { [weak self] in self?.credentialChanged() }
        credentials.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        setup.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        recordingPermission.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        Task { [weak self] in
            guard let self else { return }
            await self.credentials.load()
            if !settingsFailed { self.lastMessage = self.credentials.message }
            self.refreshPermissions()
        }
        if settingsFailed { lastMessage = "设置文件无法读取，已暂停全部功能。请检查设置后再启用。" }
        monitor.settings = { [weak self] in self?.settings ?? AppSettings() }
        monitor.onAction = { [weak self] action in self?.handle(action) }
        monitor.onPointerInteraction = { [weak self] point in self?.selectionPointerInteraction(at: point) }
        monitor.onDismissSelection = { [weak self] in self?.dismissSelectionResult() }
        monitor.hasResultKeyboardFocus = { [weak self] in self?.resultHasKeyboardFocus?() == true }
        budget.objectWillChange.sink { [weak self] in self?.objectWillChange.send(); self?.statusChanged?() }.store(in: &cancellables)
        translationCache.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cancellables)
        refreshPermissions(); refreshSources()
    }
    var spent: Double { budget.book.spent(configuration: settings.budget) }
    var audioSpent: Double { budget.book.spent(configuration: settings.budget, kind: .audio) }
    var remaining: Double { max(0, settings.budget.effectiveLimit - spent) }
    var recentRecords: [UsageRecord] { Array(budget.book.records.suffix(20).reversed()) }
    var budgetWarning: Bool { settings.budget.enabled && (budgetExhausted || spent >= settings.budget.limit * settings.budget.warningFraction) }
    var budgetExhausted: Bool { settings.budget.enabled && remaining <= 0.00001 }
    var budgetProgress: Double { settings.budget.limit > 0 ? min(1, spent / settings.budget.limit) : 0 }
    var setupReadiness: SetupReadiness {
        SetupReadiness(keyLoaded: credentials.didLoad && !keyLoading, keyConfigured: keyConfigured, accessibilityGranted: accessibilityGranted, keyboardActive: keyboardActive)
    }
    var textFeaturesEnabled: Bool { settings.enabled && (settings.fourSpacesEnabled || settings.selectionEnabled) }
    var textPermissionIssue: TextPermissionIssue? { textFeaturesEnabled ? setupReadiness.permissionIssue : nil }
    var readinessSummary: String {
        if !settings.enabled { return "已暂停" }
        if let issue = textPermissionIssue { return issue.title }
        if !credentials.didLoad || keyLoading { return "正在读取密钥" }
        if credentials.requiresStorageRetry { return "钥匙串需要确认" }
        if !keyConfigured { return "API Key 未配置" }
        return audioRunning ? "实时译声运行中" : "正在待命"
    }
    func showSetupGuide() {
        refreshPermissions()
        if textPermissionIssue != nil, keyConfigured { setup.presentPermissionRecovery() }
        else { setup.present(readiness: setupReadiness) }
    }
    func showPermissionRecovery() {
        refreshPermissions()
        setup.presentPermissionRecovery()
        requestSettings?()
    }
    func refreshModels() {
        guard !modelsLoading, !keyLoading else { return }
        guard keyConfigured else { modelListMessage = "请先配置 OpenAI API Key。"; return }
        modelsLoading = true; modelListMessage = "正在读取当前密钥可见的模型…"
        let key = apiKey, generation = keyGeneration
        modelsTask = Task {
            defer { if generation == keyGeneration { modelsLoading = false } }
            do {
                let models = try await OpenAIClient.listModels(key: key)
                guard generation == keyGeneration else { return }
                availableModels = models
                modelListMessage = "账户返回 \(models.count) 个模型；列表本身不说明文字接口兼容性。"
            } catch { if generation == keyGeneration, !(error is CancellationError) { modelListMessage = error.localizedDescription } }
        }
    }
    @discardableResult func saveKey(_ value: String) async -> Bool {
        let saved = await credentials.save(value)
        lastMessage = credentials.message
        return saved
    }
    func reloadKey() { Task { await credentials.load(allowInteraction: true); lastMessage = credentials.message } }
    func removeKey() { Task { _ = await credentials.remove(); lastMessage = credentials.message } }
    private func credentialChanged() {
        if credentials.didLoad {
            pendingSelectionPID = nil
            translationTask?.cancel(); dismissSelectionResult()
            if audioRunning || audioConnecting { stopAudio() }
        }
        modelsTask?.cancel(); modelsTask = nil; modelsLoading = false
        availableModels = []; modelListMessage = "密钥已更新，可重新读取账户模型。"
        testOutput = ""
    }
    func refreshPermissions() {
        let wasTextReady = accessibilityGranted && keyboardActive
        accessibilityGranted = AccessibleText.trusted
        if accessibilityGranted && settings.enabled { monitor.start() } else { monitor.stop() }
        keyboardActive = monitor.active
        recordingPermission.refresh()
        if wasTextReady && !setupReadiness.textReady {
            translationTask?.cancel(); dismissSelectionResult(); dismissInputFeedback()
        }
        if setup.presentAutomatically(readiness: setupReadiness, textFeaturesEnabled: textFeaturesEnabled) { requestSettings?() }
        statusChanged?()
    }
    func requestAccessibility() { AccessibleText.requestPermission(); refreshPermissions() }
    func requestKeyboard() { _ = CGRequestListenEventAccess(); refreshPermissions() }
    func requestRecordingPermission() {
        if recordingPermission.granted { openPrivacy("Privacy_ScreenCapture") }
        else if !recordingPermission.request() { openPrivacy("Privacy_ScreenCapture") }
    }
    func openPrivacy(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") { NSWorkspace.shared.open(url) }
    }
    func setLogin(_ value: Bool) {
        do {
            if value { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
            lastMessage = value ? "已请求开机启动，可在系统登录项中查看。" : "已关闭开机启动。"
        } catch { lastMessage = "无法更新登录项：\(error.localizedDescription)"; launchAtLogin = SMAppService.mainApp.status == .enabled }
    }
    func refreshSources() { audioSources = AudioHardware.sources() }
    func handle(_ action: InputMonitor.Action) {
        guard settings.enabled else { return }
        switch action {
        case .spaces: guard settings.fourSpacesEnabled else { return }; translateInput()
        case .selection: guard settings.selectionEnabled else { return }; translateSelection()
        case .automaticSelection: guard settings.selectionEnabled, settings.automaticSelection else { return }; translateSelection(quiet: true)
        case .audio: guard settings.audioEnabled else { return }; toggleAudio()
        case .undo:
            guard !translating else { lastMessage = "请等待当前翻译完成后再撤销。"; return }
            guard let snapshot = undoSnapshot else { lastMessage = "没有可以撤销的替换。"; return }
            translating = true
            translationTask = Task {
                defer { finishTextRequest() }
                do {
                    _ = try await AccessibleText.replace(snapshot, with: snapshot.source); undoSnapshot = nil; lastMessage = "已撤销上次替换。"
                    dismissInputFeedback()
                }
                catch { if !(error is CancellationError) { showError(error.localizedDescription) } }
            }
        }
    }
    func translateInput() {
        guard !translating else { return }
        captureText(input: true, quiet: false)
    }
    func translateSelection(quiet: Bool = false) {
        guard !translating else {
            if quiet { pendingSelectionPID = NSWorkspace.shared.frontmostApplication?.processIdentifier }
            return
        }
        captureText(input: false, quiet: quiet)
    }
    private func captureText(input: Bool, quiet: Bool) {
        translating = true
        if input { ReplacementDiagnostics.beginCapture() }
        let feedbackID = input && settings.inputFeedbackEnabled ? inputFeedback.begin(pid: NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0) : nil
        if feedbackID != nil { showInputFeedback?() }
        translationTask = Task {
            do {
                let snapshot: TextSnapshot
                do { snapshot = try input ? AccessibleText.input(settings: settings) : AccessibleText.selected(settings: settings) }
                catch {
                    if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == OfficeText.bundleID {
                        guard settings.wpsCompatibilityEnabled, !settings.excludes(OfficeText.bundleID) else { throw error }
                        lastMessage = input ? "正在读取 WPS 当前段落…" : "正在读取 WPS 选中文字…"
                        snapshot = try await input ? OfficeText.input(settings: settings) : OfficeText.selected(settings: settings)
                    } else {
                        guard settings.enhancedCompatibility else { throw error }
                        lastMessage = input ? "正在兼容读取当前行…" : "正在兼容读取选中文字…"
                        snapshot = try await input ? ClipboardText.input(settings: settings) : ClipboardText.selected(settings: settings)
                    }
                }
                try Task.checkCancellation()
                if let feedbackID, inputFeedback.id == feedbackID { inputFeedback.anchor = AccessibleText.selectionBounds(snapshot) }
                translating = false
                guard settings.enabled, input ? settings.fourSpacesEnabled : settings.selectionEnabled else { return }
                if !input, selectionLifetime.current != nil, let previous = selectionSnapshot, previous.pid == snapshot.pid, previous.source == snapshot.source { return }
                beginTranslation(snapshot.source, target: input ? settings.inputLanguage : settings.readingLanguage, snapshot: snapshot, replace: input, selection: !input, feedbackID: feedbackID)
            } catch {
                finishTextRequest()
                if !(error is CancellationError) {
                    if input {
                        ReplacementDiagnostics.fail("input_capture_failed")
                        ReplacementDiagnostics.finish(success: false)
                        lastMessage = error.localizedDescription
                        updateInputFeedback(feedbackID, message: error.localizedDescription, detail: "原文未改动 · 可尝试选中文字后翻译", phase: .failure)
                    } else if !quiet { showError(error.localizedDescription) }
                } else { dismissInputFeedback() }
            }
        }
    }
    func testTranslation() { beginTranslation(testInput, target: settings.readingLanguage, snapshot: nil, replace: false, test: true) }
    func translatePractice(_ text: String, input: Bool) async throws -> PracticeTranslation {
        guard settings.enabled else { throw AppError.message("TranslateBar 已暂停，请先恢复总开关。") }
        guard input ? settings.fourSpacesEnabled : settings.selectionEnabled else { throw AppError.message(input ? "输入翻译已关闭，请先开启。" : "划词翻译已关闭，请先开启。") }
        guard !keyLoading else { throw AppError.message("密钥正在处理，请稍后再试。") }
        let route = LanguageResolver.route(text: text, settings: settings, input: input)
        if route.skip { return PracticeTranslation(text: text, message: "原文已是目标语言，已跳过 · 未调用 API") }
        let generation = keyGeneration
        let response = try await textService.translate(text, target: route.target, model: settings.textModel, key: apiKey, maxOutput: settings.maxOutputTokens, configuration: settings.budget, useCache: settings.cacheEnabled, sourceLanguage: settings.textSourceLanguage)
        try Task.checkCancellation()
        guard settings.enabled, generation == keyGeneration else { throw CancellationError() }
        return PracticeTranslation(text: response.text, message: (input ? "已替换练习文本" : "译文显示在下方，原文未改动") + (response.fromCache ? " · 本地缓存，未调用 API" : " · 翻译完成"))
    }
    func clearTranslationCache() {
        do { try translationCache.clear(); lastMessage = "已清空本地翻译缓存。" }
        catch { lastMessage = error.localizedDescription }
    }
    func copyCompatibilityDiagnostic() {
        do {
            guard let text = try ReplacementDiagnostics.lastFailureJSON() else {
                lastMessage = "暂无兼容性诊断，请先在出现问题的应用中重现一次，再返回复制。"
                return
            }
            let board = NSPasteboard.general
            board.clearContents()
            guard board.setString(text, forType: .string) else { lastMessage = "诊断复制失败，请重试。"; return }
            lastMessage = "已复制最近一次失败的兼容性诊断，不含原文或 API Key。"
        } catch { lastMessage = "无法复制兼容性诊断，请重新触发一次失败后重试。" }
    }
    private func beginTranslation(_ text: String, target: String, snapshot: TextSnapshot?, replace: Bool, test: Bool = false, selection: Bool = false, feedbackID: UUID? = nil) {
        guard settings.enabled, !translating else { return }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            updateInputFeedback(feedbackID, message: "没有需要翻译的文本", phase: .information)
            return
        }
        guard text.utf8.count <= 60_000 else { showError("本次文本超过 60 KB，请分段翻译。"); return }
        let route = LanguageResolver.route(text: text, settings: settings, input: replace)
        if route.skip && !test {
            dismissSelectionResult()
            lastMessage = "原文已是\(TranslationLanguage.display(route.target))，已跳过 · 未调用 API"
            updateInputFeedback(feedbackID, message: "原文已是目标语言，已跳过", detail: "\(TranslationLanguage.display(route.target)) · 未调用 API", phase: .information)
            return
        }
        let target = route.target
        let sourceLanguage = settings.textSourceLanguage
        let model = settings.textModel; let key = keyLoading ? "" : apiKey; let maximum = settings.maxOutputTokens
        let configuration = settings.budget; let useCache = settings.cacheEnabled && !test
        translating = true; lastMessage = "正在翻译…"
        updateInputFeedback(feedbackID, message: "正在翻译为\(TranslationLanguage.display(target))…", detail: "继续输入或切换焦点时，不会覆盖新内容", phase: .working)
        if !replace { dismissInputFeedback() }
        dismissSelectionResult()
        if replace { hideResult?() }
        let popupID = selection ? snapshot.map { trackSelectionResult($0) } : nil
        result.isSelection = selection
        if !selection { result.selectionAnchor = nil }
        result.title = (replace ? "输入翻译" : "划词翻译") + " · " + TranslationLanguage.display(target); result.source = text; result.translation = ""; result.error = nil; result.replacementHint = nil; result.busy = true
        result.fromCache = false
        if !replace && !test { showResult?() }
        translationTask = Task {
            defer { finishTextRequest() }
            do {
                let response = try await textService.translate(text, target: target, model: model, key: key, maxOutput: maximum, configuration: configuration, useCache: useCache, sourceLanguage: sourceLanguage)
                try Task.checkCancellation()
                guard settings.enabled else { return }
                result.translation = response.text; result.fromCache = response.fromCache
                if test { testOutput = response.text }
                if replace, let snapshot {
                    do {
                        undoSnapshot = try await AccessibleText.replace(snapshot, with: response.text)
                        lastMessage = "已替换译文\(response.fromCache ? " · 本地缓存" : "") · \(settings.undoShortcut.display) 撤销"
                        dismissInputFeedback()
                        hideResult?()
                    }
                    catch { if !(error is CancellationError) { dismissInputFeedback(); lastMessage = error.localizedDescription; result.error = error.localizedDescription; result.replacementHint = ReplacementDiagnostics.failureHint; showResult?() } }
                } else { lastMessage = response.fromCache ? "已使用本地缓存 · 未调用 API" : "翻译完成" }
                if useCache && !response.fromCache && translationCache.error != nil { lastMessage += " · 缓存暂不可用" }
            } catch {
                if !(error is CancellationError) {
                    lastMessage = error.localizedDescription; result.error = error.localizedDescription
                    if test { testOutput = error.localizedDescription }
                    else if replace, feedbackID != nil { updateInputFeedback(feedbackID, message: error.localizedDescription, detail: "译文未替换，请稍后重试", phase: .failure) }
                    else if popupID.map({ selectionLifetime.accepts($0) }) ?? true { showResult?() }
                }
            }
        }
    }
    private func updateInputFeedback(_ id: UUID?, message: String, detail: String = "", phase: InputFeedbackPhase) {
        guard let id, settings.inputFeedbackEnabled, inputFeedback.update(id, message: message, detail: detail, phase: phase) else { return }
        showInputFeedback?()
    }
    func dismissInputFeedback() { inputFeedback.dismiss(); hideInputFeedback?() }
    private func finishTextRequest() {
        translating = false; result.busy = false
        if Task.isCancelled { dismissInputFeedback() }
        guard let pid = pendingSelectionPID else { return }
        pendingSelectionPID = nil
        Task { [weak self] in
            guard let self, self.settings.enabled, self.settings.selectionEnabled, self.settings.automaticSelection,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
            self.translateSelection(quiet: true)
        }
    }
    func trackSelectionResult(_ snapshot: TextSnapshot) -> UUID {
        selectionWatcher?.cancel()
        let id = selectionLifetime.begin(); selectionSnapshot = snapshot
        result.isSelection = true; result.selectionAnchor = AccessibleText.selectionBounds(snapshot)
        let app = NSRunningApplication(processIdentifier: snapshot.pid)
        result.sourceApplication = app?.localizedName ?? "此应用"
        result.excludeApplication = app?.bundleIdentifier.map { bundle in
            { [weak self] in self?.excludeApplication(bundle); self?.lastMessage = "已在\(app?.localizedName ?? bundle)中停用文字翻译，可在常规设置中恢复。" }
        }
        selectionWatcher = Task { [weak self] in
            var dismissal = SelectionDismissalPolicy()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, let self, self.selectionLifetime.accepts(id) else { return }
                // Preserve interaction with the translation itself, including Copy and scrolling.
                if self.resultHasKeyboardFocus?() == true || self.resultContainsPoint?(NSEvent.mouseLocation) == true { continue }
                let observation = AccessibleText.observeSelection(snapshot, settings: self.settings)
                if dismissal.shouldDismiss(observation, at: ProcessInfo.processInfo.systemUptime) { self.dismissSelectionResult(reason: "selection_\(observation)"); return }
            }
        }
        return id
    }
    func dismissSelectionResult(reason: String = "explicit") {
        pendingSelectionPID = nil
        guard selectionLifetime.current != nil else { return }
        onSelectionDismissal?(reason)
        selectionLifetime.dismiss(); selectionSnapshot = nil
        selectionWatcher?.cancel(); selectionWatcher = nil
        hideResult?()
    }
    func selectionPointerInteraction(at point: NSPoint) {
        if resultContainsPoint?(point) != true { pendingSelectionPID = nil; dismissSelectionResult(reason: "outside_pointer") }
    }
    func selectionApplicationActivated(_ pid: pid_t) {
        if inputFeedback.id != nil, pid != inputFeedback.pid { dismissInputFeedback() }
        if pendingSelectionPID != pid { pendingSelectionPID = nil }
        guard let snapshot = selectionSnapshot, pid != snapshot.pid else { return }
        if pid == ProcessInfo.processInfo.processIdentifier, resultContainsPoint?(NSEvent.mouseLocation) == true { return }
        dismissSelectionResult(reason: "application_changed")
    }
    func toggleAudio() { if audioRunning || audioConnecting { stopAudio() } else { startAudio() } }
    func startAudio() {
        guard settings.enabled, settings.audioEnabled, !audioRunning, !audioConnecting else { return }
        guard !keyLoading else { showError("密钥正在处理，请稍后开始译声。"); return }
        guard !apiKey.isEmpty else { showError("请先配置 API Key。"); return }
        guard !setup.isPresented else { lastMessage = "请先完成或关闭设置引导，再开始译声。"; requestSettings?(); return }
        refreshSources()
        guard let source = audioSources.first(where: { $0.id == settings.audioSourceBundleID }) else { showError("请先打开播放视频的浏览器，并在译声设置中选择来源。"); return }
        // A missing recording grant must never reserve budget or open an API connection.
        guard recordingPermission.prepareStart() else { requestSettings?(); return }
        let token = UUID(); audioToken = token
        latencyTracker = AudioLatencyTracker(); audioLatency = AudioLatencySnapshot()
        audioConnecting = true; audioState = "正在连接…"; subtitle = "正在连接实时翻译…"
        periodBytes = 0; totalBytes = 0; reservedAudio = 5.0 / 60 * PCMFrames.audioDollarsPerMinute
        do { reservation = try budget.reserve(reservedAudio, kind: .audio, model: "gpt-realtime-translate", configuration: settings.budget) }
        catch { audioConnecting = false; audioState = "未开始"; showError(error.localizedDescription); return }
        startupDeadline = Task {
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, audioToken == token, audioConnecting else { return }
            stopAudio(message: "系统音频启动超时，请检查录制权限后重试。")
        }
        audioTask = Task(priority: .userInitiated) {
            do {
                capture.onChunk = { [weak self] data, level in Task { @MainActor in self?.acceptAudio(data, level: level, token: token) } }
                capture.onFailure = { [weak self] error in Task { @MainActor in guard let self, self.audioToken == token else { return }; self.stopAudio(message: error.localizedDescription) } }
                let connection = RealtimeSession(); realtime = connection
                connection.onRoundTrip = { [weak self] seconds in
                    guard let self, self.audioToken == token else { return }
                    self.audioRoundTripSeconds = seconds
                }
                connection.onAudio = { [weak self] data, elapsed in
                    guard let self, self.audioToken == token, self.audioRunning else { return }
                    guard !data.isEmpty else { return }
                    self.latencyTracker.recordOutput(elapsedMilliseconds: elapsed, receivedAt: ProcessInfo.processInfo.systemUptime, hasSignal: AudioLatencyTracker.hasSignal(data))
                    do { try self.playback.enqueue(data); self.refreshAudioLatency() } catch { self.stopAudio(message: error.localizedDescription) }
                }
                connection.onTranscript = { [weak self] delta in
                    guard let self, self.audioToken == token, self.audioRunning else { return }
                    self.subtitle += delta
                    if self.subtitle.count > 4000 { self.subtitle = String(self.subtitle.suffix(2500)) }
                }
                connection.onFailure = { [weak self] error in
                    guard let self, self.audioToken == token else { return }; self.stopAudio(message: error.localizedDescription)
                }
                connection.onClosed = { [weak self] in
                    guard let self, self.audioToken == token, self.audioRunning else { return }
                    self.stopAudio(message: "实时翻译连接已结束。")
                }
                // Prepare the API and system capture in parallel. No input is
                // uploaded until capture/mute and the connection are both ready.
                let connectionTask = Task { try await connection.connect(key: apiKey, language: settings.audioLanguage) }
                defer { connectionTask.cancel() }
                try await capture.start(source: source, mute: settings.muteOriginal)
                try Task.checkCancellation()
                originalMuteActive = capture.muteProcessID != nil
                try await connectionTask.value
                try Task.checkCancellation()
                guard audioToken == token, settings.enabled, settings.audioEnabled else { throw CancellationError() }
                startupDeadline?.cancel()
                audioConnecting = false; audioRunning = true; audioState = "正在译声 · \(source.name)"; subtitle = ""
                startedAt = Date(); lastLoudAudio = Date(); lastCapturedAudio = Date(); audioSeconds = 0
                playback.volume = Float(settings.audioVolume)
                playback.followVideo = settings.followVideo
                latencyTimer = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(200))
                        guard !Task.isCancelled, let self, self.audioToken == token, self.audioRunning else { return }
                        self.refreshAudioLatency()
                    }
                }
                if settings.subtitlesEnabled { showSubtitle?() }
                lastMessage = "译声已开始，停止后将恢复原声。"; statusChanged?()
                watchdog = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(1))
                        guard !Task.isCancelled, audioToken == token, audioRunning else { return }
                        let elapsed = Date().timeIntervalSince(startedAt)
                        audioSeconds = elapsed
                        if elapsed >= settings.maximumAudioMinutes * 60 { stopAudio(message: "已达到单次译声时长上限。"); return }
                        if Date().timeIntervalSince(lastCapturedAudio) > 10 { stopAudio(message: "没有收到系统音频，请检查音频来源及系统录制权限。"); return }
                        if settings.silenceStopSeconds > 0 && Date().timeIntervalSince(lastLoudAudio) >= settings.silenceStopSeconds { stopAudio(message: "持续静音，译声已自动停止。"); return }
                        if settings.budget.enabled && spent > settings.budget.effectiveLimit + 1e-12 { stopAudio(message: BudgetError.exhausted.localizedDescription); return }
                    }
                }
            } catch {
                if audioToken == token { stopAudio(message: error is CancellationError ? nil : error.localizedDescription) }
            }
        }
    }
    private func acceptAudio(_ data: Data, level: Float, token: UUID) {
        guard audioToken == token, audioRunning, let id = reservation else { return }
        lastCapturedAudio = Date(); audioLevel = min(1, level * 8)
        if level > 0.001 { lastLoudAudio = Date() }
        do {
            if let record = budget.book.record(id: id), !settings.budget.period.contains(record.date, now: Date()) {
                try budget.settle(id, amount: PCMFrames.cost(bytes: periodBytes), seconds: PCMFrames.seconds(bytes: periodBytes))
                reservedAudio = 5 / 60 * PCMFrames.audioDollarsPerMinute
                reservation = try budget.reserve(reservedAudio, kind: .audio, model: "gpt-realtime-translate", configuration: settings.budget)
                periodBytes = 0
            }
            guard let activeID = reservation else { throw BudgetError.missingReservation }
            let nextCost = PCMFrames.cost(bytes: periodBytes + data.count)
            if nextCost > reservedAudio {
                let increase = 5 / 60 * PCMFrames.audioDollarsPerMinute
                try budget.extend(activeID, by: increase, configuration: settings.budget); reservedAudio += increase
            }
            guard audioQueue.count < 10 else { throw AppError.message("网络发送速度不足，译声已停止以避免积压。") }
            latencyTracker.recordInput(bytes: data.count, capturedAt: ProcessInfo.processInfo.systemUptime, hasSignal: level > 0.001)
            periodBytes += data.count; totalBytes += data.count; audioQueue.append(data)
            if sendTask == nil {
                sendTask = Task {
                    defer { if audioToken == token { sendTask = nil } }
                    do {
                        while !Task.isCancelled, audioToken == token, audioRunning, !audioQueue.isEmpty {
                            let chunk = audioQueue.removeFirst()
                            guard let realtime else { throw CancellationError() }
                            try await realtime.append(chunk)
                        }
                    } catch { if audioToken == token { stopAudio(message: error.localizedDescription) } }
                }
            }
        } catch { stopAudio(message: error.localizedDescription) }
    }
    func stopAudio(message: String? = nil) {
        let wasConnecting = audioConnecting
        audioToken = UUID(); audioTask?.cancel(); startupDeadline?.cancel(); watchdog?.cancel(); sendTask?.cancel(); sendTask = nil
        latencyTimer?.cancel(); latencyTimer = nil
        latencyTracker = AudioLatencyTracker(); audioLatency = AudioLatencySnapshot()
        audioPlaybackRate = 1
        audioRoundTripSeconds = nil
        audioRunning = false; audioConnecting = false; originalMuteActive = false; audioLevel = 0
        capture.stop(); playback.stop(); audioQueue.removeAll(); hideSubtitle?()
        let connection = realtime; realtime = nil
        connection?.onAudio = nil; connection?.onTranscript = nil; connection?.onFailure = nil; connection?.onClosed = nil
        connection?.onRoundTrip = nil
        if let connection { if wasConnecting { connection.cancel() } else { Task { await connection.finish() } } }
        if let id = reservation {
            do { try budget.settle(id, amount: PCMFrames.cost(bytes: periodBytes), seconds: PCMFrames.seconds(bytes: periodBytes)) }
            catch { budget.uncertain(id); lastMessage = error.localizedDescription }
        }
        reservation = nil; periodBytes = 0
        audioState = message ?? "已停止"; lastMessage = message ?? "译声已停止，原声已恢复。"; statusChanged?()
        if wasConnecting { subtitle = message ?? "译声已停止。" }
    }
    private func refreshAudioLatency() {
        playback.updateFollowRate(); audioPlaybackRate = playback.playbackRate
        audioLatency = latencyTracker.snapshot(now: ProcessInfo.processInfo.systemUptime, playbackQueueSeconds: playback.queuedSeconds)
    }
    func excludeApplication(_ bundleID: String) {
        guard !bundleID.isEmpty, bundleID != Bundle.main.bundleIdentifier, !settings.excludes(bundleID) else { return }
        settings.excludedBundleIDs = (settings.excludedBundleIDs.trimmingCharacters(in: .whitespacesAndNewlines) + "\n" + bundleID).trimmingCharacters(in: .newlines)
        dismissSelectionResult()
    }
    func shutdown() { dismissInputFeedback(); modelsTask?.cancel(); pendingSelectionPID = nil; dismissSelectionResult(); translationTask?.cancel(); stopAudio(); monitor.stop(); translationCache.flush() }
    private func showError(_ text: String) { dismissInputFeedback(); dismissSelectionResult(); result.isSelection = false; result.fromCache = false; result.selectionAnchor = nil; lastMessage = text; result.title = "翻译提示"; result.error = text; result.replacementHint = nil; result.busy = false; result.translation = ""; result.source = ""; showResult?() }
    private func settingsChanged(from old: AppSettings) {
        if !settings.enabled || !settings.inputFeedbackEnabled { dismissInputFeedback() }
        if old.excludedBundleIDs != settings.excludedBundleIDs { translationTask?.cancel(); dismissSelectionResult(); dismissInputFeedback() }
        do { try LocalFiles.write(settings, to: settingsURL) } catch { lastMessage = "设置保存失败：\(error.localizedDescription)" }
        if old.cacheEnabled != settings.cacheEnabled {
            translationCache.invalidatePendingWrites()
            lastMessage = settings.cacheEnabled ? "已开启本地翻译缓存。" : "已关闭缓存读写，已有译文保留，可随时清空。"
        }
        if !settings.enabled { translationTask?.cancel(); stopAudio(); monitor.stop(); lastMessage = "全部功能已暂停。" }
        else if !old.enabled { lastMessage = "翻译已启用。" }
        if !settings.enabled || !settings.selectionEnabled || (old.automaticSelection && !settings.automaticSelection) { dismissSelectionResult() }
        if old.budget != settings.budget && settings.budget.isValid && !budgetExhausted { lastMessage = "预算设置已更新。" }
        if (old.fourSpacesEnabled && !settings.fourSpacesEnabled) || (old.selectionEnabled && !settings.selectionEnabled) { translationTask?.cancel() }
        if old.wpsCompatibilityEnabled && !settings.wpsCompatibilityEnabled { translationTask?.cancel(); dismissSelectionResult() }
        if old.enhancedCompatibility && !settings.enhancedCompatibility { translationTask?.cancel(); dismissSelectionResult() }
        if settings.budget.enabled && (audioRunning || audioConnecting) && (!settings.budget.isValid || spent > settings.budget.effectiveLimit || (settings.budget.audioLimitEnabled && audioSpent > settings.budget.audioLimit)) { stopAudio(message: "预算设置已收紧，译声已停止。") }
        if !settings.audioEnabled || old.audioLanguage != settings.audioLanguage || old.audioSourceBundleID != settings.audioSourceBundleID || old.muteOriginal != settings.muteOriginal || old.followVideo != settings.followVideo {
            if audioRunning || audioConnecting { stopAudio(message: "设置已更新，请重新开始译声。") }
        }
        playback.volume = Float(settings.audioVolume)
        playback.followVideo = settings.followVideo
        if audioRunning { if settings.subtitlesEnabled { showSubtitle?() } else { hideSubtitle?() } }
        refreshPermissions(); statusChanged?()
    }
}
