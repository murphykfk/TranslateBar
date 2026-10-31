import AppKit
import AVFoundation

// Isolated, disposable UI and audio source for manual end-to-end tests.
final class FixtureDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var player: AVAudioPlayer?
    var audioLabel = NSTextField(labelWithString: "音频尚未开始")
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let applicationItem = NSMenuItem(); let applicationMenu = NSMenu(); applicationItem.submenu = applicationMenu
        applicationMenu.addItem(withTitle: "退出测试窗口", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"); menu.addItem(applicationItem)
        let editItem = NSMenuItem(); let editMenu = NSMenu(title: "编辑"); editItem.submenu = editMenu
        for (title, selector, key) in [("撤销", "undo:", "z"), ("剪切", "cut:", "x"), ("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] { editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key) }
        menu.addItem(editItem); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "TranslateBar 测试文本与音频"
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 620, height: 420))
        let label = NSTextField(labelWithString: "测试专用窗口 · 不涉及你的文档和消息")
        label.frame = NSRect(x: 20, y: 370, width: 570, height: 24); root.addSubview(label)
        let scroll = NSScrollView(frame: NSRect(x: 20, y: 90, width: 580, height: 270)); scroll.hasVerticalScroller = true
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 580, height: 270))
        text.isRichText = false; text.font = .systemFont(ofSize: 18); text.isAutomaticTextReplacementEnabled = false; text.isAutomaticSpellingCorrectionEnabled = false
        text.string = "The meeting starts at ten tomorrow morning."
        scroll.documentView = text; root.addSubview(scroll)
        let button = NSButton(title: "播放英文测试音频", target: self, action: #selector(play))
        button.frame = NSRect(x: 20, y: 30, width: 180, height: 32); root.addSubview(button)
        audioLabel.frame = NSRect(x: 215, y: 34, width: 360, height: 24); root.addSubview(audioLabel)
        window.contentView = root; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func play() {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "FixtureAudioPath") as? String else { return }
        do {
            player = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)); player?.numberOfLoops = 1
            audioLabel.stringValue = player?.play() == true ? "正在播放英文样本" : "播放启动失败"
        } catch { audioLabel.stringValue = "读取样本失败：\(error.localizedDescription)" }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let app = NSApplication.shared
let delegate = FixtureDelegate(); app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
