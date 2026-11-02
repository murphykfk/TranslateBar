import AppKit
import SwiftUI
import TranslateCore
import Carbon

@main struct TranslateBarMain {
    @MainActor static func main() async {
        if CommandLine.arguments.contains("--microsoft-office-selection-test") { await MicrosoftOfficeSmokeTest.run(inspectOnly: false, selectionOnly: true); return }
        if CommandLine.arguments.contains("--microsoft-office-read-test") { await MicrosoftOfficeSmokeTest.run(inspectOnly: true); return }
        if CommandLine.arguments.contains("--microsoft-office-smoke-test") { await MicrosoftOfficeSmokeTest.run(inspectOnly: false); return }
        if CommandLine.arguments.contains("--compatibility-smoke-test") { await CompatibilitySmokeTest.run(); return }
        if CommandLine.arguments.contains("--compatibility-gate-smoke-test") { await CompatibilitySmokeTest.gate(); return }
        if CommandLine.arguments.contains("--office-diagnostics") { OfficeText.diagnostics(); return }
        if CommandLine.arguments.contains("--office-read-smoke-test") { await OfficeText.readSmokeTest(); return }
        if CommandLine.arguments.contains("--office-smoke-test") { await OfficeSmokeTest.run(); return }
        if let index = CommandLine.arguments.firstIndex(of: "--mute-worker"), CommandLine.arguments.indices.contains(index + 1) {
            let bundles = CommandLine.arguments.firstIndex(of: "--bundle-ids").map { Array(CommandLine.arguments.dropFirst($0 + 1)) }
            MuteWorker.run(bundleID: CommandLine.arguments[index + 1], bundleIDs: bundles); return
        }
        if CommandLine.arguments.contains("--mute-smoke-test") { await MuteSmokeTest.run(); return }
        if CommandLine.arguments.contains("--playback-smoke-test") { await PlaybackSmokeTest.run(); return }
        if CommandLine.arguments.contains("--follow-smoke-test") { await FollowSmokeTest.run(); return }
        if CommandLine.arguments.contains("--audio-quality-smoke-test") { await AudioQualitySmokeTest.run(); return }
        if CommandLine.arguments.contains("--capture-smoke-test") { await CaptureSmokeTest.run(); return }
        if CommandLine.arguments.contains("--audio-diagnostics") {
            let sources = AudioHardware.sources().filter { $0.id.contains("TranslateBarFixture") || $0.id.hasPrefix("com.google.Chrome") }
            let rows = sources.map { ["bundle_id": $0.id, "process_count": $0.processes.count, "captured_bundles": $0.bundleIDs] as [String: Any] }
            if let data = try? JSONSerialization.data(withJSONObject: rows, options: .prettyPrinted) { Swift.print(String(decoding: data, as: UTF8.self)) }
            return
        }
        let lock: InstanceLock
        do { lock = try InstanceLock() }
        catch {
            let isAPITest = CommandLine.arguments.contains("--live-smoke-test") || CommandLine.arguments.contains("--cache-smoke-test")
            if !isAPITest { NSRunningApplication.runningApplications(withBundleIdentifier: "com.murphy.TranslateBar").first?.activate(options: []) }
            Swift.print("TranslateBar 已在运行，请先退出另一个实例。")
            if isAPITest { exit(1) }
            return
        }
        defer { withExtendedLifetime(lock) {} }
        if CommandLine.arguments.contains("--import-legacy-project-key") { await CredentialsSmokeTest.importLegacy(); return }
        if CommandLine.arguments.contains("--keychain-smoke-test") { await CredentialsSmokeTest.run(); return }
        if CommandLine.arguments.contains("--cache-smoke-test") { await CacheSmokeTest.run(); return }
        if CommandLine.arguments.contains("--live-smoke-test") {
            await LiveSmokeTest.run()
            return
        }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}

final class InstanceLock {
    private let descriptor: Int32
    init() throws {
        try FileManager.default.createDirectory(at: LocalFiles.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        descriptor = open(LocalFiles.directory.appendingPathComponent("instance.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw AppError.message("无法创建进程锁。") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); throw AppError.message("应用已在运行。") }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    private var model: AppModel!
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var resultPanel: NSPanel?
    private var subtitlePanel: NSPanel?
    private var inputFeedbackPanel: NSPanel?
    private var inputFeedbackTimer: Task<Void, Never>?
    private var permissionTimer: Timer?
    private var localInteractionMonitor: Any?
    private var activationObserver: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        createApplicationMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.setAccessibilityLabel("TranslateBar 翻译")
        let menu = NSMenu(); menu.delegate = self; statusItem.menu = menu
        model.showResult = { [weak self] in self?.presentResult() }
        model.hideResult = { [weak self] in self?.resultPanel?.orderOut(nil) }
        model.showInputFeedback = { [weak self] in self?.presentInputFeedback() }
        model.hideInputFeedback = { [weak self] in self?.inputFeedbackTimer?.cancel(); self?.inputFeedbackPanel?.orderOut(nil) }
        model.resultContainsPoint = { [weak self] point in
            guard let panel = self?.resultPanel, panel.isVisible else { return false }
            return panel.frame.contains(point)
        }
        model.resultHasKeyboardFocus = { [weak self] in self?.resultPanel?.isKeyWindow == true }
        model.showSubtitle = { [weak self] in self?.presentSubtitles() }
        model.hideSubtitle = { [weak self] in self?.subtitlePanel?.orderOut(nil) }
        model.statusChanged = { [weak self] in self?.updateStatus() }
        model.requestSettings = { [weak self] in self?.showSettings() }
        localInteractionMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]) { [weak self] event in
            MainActor.assumeIsolated {
                if event.type == .keyDown {
                    if event.keyCode == 53 { self?.model.dismissSelectionResult() }
                } else { self?.model.selectionPointerInteraction(at: NSEvent.mouseLocation) }
            }
            return event
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            MainActor.assumeIsolated { self?.model.selectionApplicationActivated(app.processIdentifier) }
        }
        updateStatus()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.model.refreshPermissions() }
        }
        let event = NSAppleEventManager.shared().currentAppleEvent
        let loginLaunch = event?.eventID == kAEOpenApplication && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if CommandLine.arguments.contains("--compatibility-flow-smoke-test") {
            Task { await CompatibilitySmokeTest.flow(model: model) }
        } else if CommandLine.arguments.contains("--office-flow-smoke-test") {
            Task { await OfficeSmokeTest.flow(model: model) }
        } else if CommandLine.arguments.contains("--selection-popup-smoke-test") {
            Task { await SelectionPopupSmokeTest.run(model: model) }
        } else if CommandLine.arguments.contains("--rich-text-smoke-test") {
            Task { await RichTextSmokeTest.run(model: model) }
        } else if !loginLaunch || model.setup.needsAutomaticPresentation || model.setup.isPresented || CommandLine.arguments.contains("--show-settings") { showSettings() }
        UserDefaults.standard.set(true, forKey: "hasOpenedTranslateBar")
    }
    func applicationWillTerminate(_ notification: Notification) {
        inputFeedbackTimer?.cancel()
        permissionTimer?.invalidate()
        if let localInteractionMonitor { NSEvent.removeMonitor(localInteractionMonitor) }
        if let activationObserver { NSWorkspace.shared.notificationCenter.removeObserver(activationObserver) }
        model?.shutdown()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func windowWillClose(_ notification: Notification) {
        if let panel = notification.object as? NSPanel, panel === resultPanel { model.dismissSelectionResult() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "TranslateBar · \(model.readinessSummary)", action: nil, keyEquivalent: ""); title.isEnabled = false; menu.addItem(title)
        if model.textPermissionIssue != nil {
            add(menu, "恢复输入与划词翻译…") { [weak self] in self?.model.showPermissionRecovery() }
        }
        let spend = NSMenuItem(title: "\(model.settings.budget.period.title)费用 \(money(model.spent))\(model.settings.budget.enabled ? " / " + money(model.settings.budget.limit, digits: 2) : "")", action: nil, keyEquivalent: ""); spend.isEnabled = false; menu.addItem(spend)
        menu.addItem(.separator())
        add(menu, "翻译并替换当前段落", enabled: model.settings.enabled && model.settings.fourSpacesEnabled && model.setupReadiness.textReady) { [weak self] in self?.model.translateInput() }
        add(menu, "翻译选中文字 · \(model.settings.selectionShortcut.display)", enabled: model.settings.enabled && model.settings.selectionEnabled && model.setupReadiness.textReady) { [weak self] in self?.model.translateSelection() }
        menu.addItem(.separator())
        add(menu, model.settings.enabled ? "暂停全部功能" : "恢复全部功能") { [weak self] in self?.model.settings.enabled.toggle() }
        add(menu, model.audioRunning || model.audioConnecting ? "停止实时译声" : "开始实时译声", enabled: model.settings.enabled && model.settings.audioEnabled) { [weak self] in self?.model.toggleAudio() }
        menu.addItem(.separator())
        for (name, keyPath) in [("\(model.settings.spaceCount) 次空格翻译", \AppSettings.fourSpacesEnabled), ("划词翻译", \AppSettings.selectionEnabled), ("实时译声", \AppSettings.audioEnabled)] {
            let item = ClosureMenuItem(title: name) { [weak self] in self?.model.settings[keyPath: keyPath].toggle() }
            item.state = model.settings[keyPath: keyPath] ? .on : .off; menu.addItem(item)
        }
        menu.addItem(.separator())
        add(menu, "设置…") { [weak self] in self?.showSettings() }
        add(menu, "退出 TranslateBar") { NSApp.terminate(nil) }
    }
    private func add(_ menu: NSMenu, _ title: String, enabled: Bool = true, action: @escaping () -> Void) { let item = ClosureMenuItem(title: title, handler: action); item.isEnabled = enabled; menu.addItem(item) }
    private func updateStatus() {
        let symbol = model.textPermissionIssue != nil ? "exclamationmark.triangle" : model.audioRunning ? "waveform.circle.fill" : !model.settings.enabled ? "pause.circle" : model.budgetWarning ? "exclamationmark.bubble" : "character.bubble"
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TranslateBar"); image?.isTemplate = true
        statusItem?.button?.image = image
        statusItem?.button?.toolTip = "TranslateBar · \(model.readinessSummary)\n\(model.lastMessage)"
    }
    private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 710), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.title = "TranslateBar 设置"; window.isReleasedWhenClosed = false; window.contentMinSize = NSSize(width: 880, height: 650)
            window.contentView = NSHostingView(rootView: SettingsView(model: model)); window.center(); settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true); settingsWindow?.makeKeyAndOrderFront(nil)
    }
    private func presentResult() {
        if resultPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 340), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.title = "TranslateBar"; panel.level = .floating; panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.contentView = NSHostingView(rootView: ResultView(state: model.result)); resultPanel = panel
        }
        if let panel = resultPanel {
            let mouse = NSEvent.mouseLocation; let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            if model.result.isSelection {
                let anchor = model.result.selectionAnchor ?? NSRect(x: mouse.x, y: mouse.y, width: 1, height: 1)
                let targetScreen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? screen
                let selectionVisible = targetScreen?.visibleFrame ?? visible
                let frame = SelectionPopupPlacement.frame(anchor: anchor, size: NSSize(width: 420, height: 275), visible: selectionVisible)
                panel.setFrame(frame, display: false)
            } else {
                panel.setContentSize(NSSize(width: 440, height: 340))
                panel.setFrameOrigin(NSPoint(x: min(max(visible.minX, mouse.x + 36), visible.maxX - panel.frame.width), y: max(visible.minY, min(mouse.y - panel.frame.height - 36, visible.maxY - panel.frame.height))))
            }
            panel.orderFrontRegardless()
        }
    }
    private func presentInputFeedback() {
        inputFeedbackTimer?.cancel()
        let state = model.inputFeedback
        guard let id = state.id, NSWorkspace.shared.frontmostApplication?.processIdentifier == state.pid else { model.dismissInputFeedback(); return }
        if inputFeedbackPanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 346, height: 98), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating; panel.hidesOnDeactivate = false; panel.isOpaque = false; panel.backgroundColor = .clear
            panel.ignoresMouseEvents = true; panel.hasShadow = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: InputFeedbackView(state: state)); inputFeedbackPanel = panel
        }
        if let panel = inputFeedbackPanel {
            let mouse = NSEvent.mouseLocation
            let anchor = state.anchor ?? NSRect(x: mouse.x, y: mouse.y, width: 1, height: 1)
            let screen = NSScreen.screens.first { $0.frame.contains(NSPoint(x: anchor.midX, y: anchor.midY)) } ?? NSScreen.main
            let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            panel.setFrame(SelectionPopupPlacement.frame(anchor: anchor, size: NSSize(width: 346, height: 108), visible: visible, gap: 18), display: false)
            panel.orderFrontRegardless()
        }
        if state.phase != .working {
            let seconds = state.phase == .failure ? 7.0 : 4.0
            inputFeedbackTimer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled, self?.model.inputFeedback.id == id else { return }
                self?.model.dismissInputFeedback()
            }
        }
    }
    private func presentSubtitles() {
        if subtitlePanel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 700, height: 190), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .floating; panel.hidesOnDeactivate = false; panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
            panel.isMovableByWindowBackground = true; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.contentView = NSHostingView(rootView: SubtitleView(model: model)); subtitlePanel = panel
        }
        if let panel = subtitlePanel {
            if !panel.isVisible, let frame = NSScreen.main?.visibleFrame { panel.setFrameOrigin(NSPoint(x: frame.midX - 350, y: frame.minY + 45)) }
            panel.orderFrontRegardless()
        }
    }
    private func createApplicationMenu() {
        let main = NSMenu()
        let app = NSMenuItem(); let appMenu = NSMenu(); app.submenu = appMenu
        appMenu.addItem(withTitle: "退出 TranslateBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); main.addItem(app)
        let edit = NSMenuItem(); let editMenu = NSMenu(title: "编辑"); edit.submenu = editMenu
        for (title, selector, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] { editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key) }
        main.addItem(edit); NSApp.mainMenu = main
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, handler: @escaping () -> Void) { self.handler = handler; super.init(title: title, action: #selector(invoke), keyEquivalent: ""); target = self }
    required init(coder: NSCoder) { fatalError("Use init(title:handler:)") }
    @objc private func invoke() { handler() }
}
