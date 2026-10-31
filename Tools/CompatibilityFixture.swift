import AppKit

final class OpaqueTextView: NSTextView {
    override func accessibilityValue() -> String? { nil }
    override func accessibilityNumberOfCharacters() -> Int { 0 }
}
final class CompatibilityDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var editor: NSView?
    let source = "明天上午十点开会，请带上笔记本。    "
    let area = NSView(frame: NSRect(x: 20, y: 20, width: 720, height: 270))
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(); let editItem = NSMenuItem(); let edit = NSMenu(title: "编辑"); editItem.submenu = edit
        for (title, selector, key) in [("复制", "copy:", "c"), ("粘贴", "paste:", "v"), ("全选", "selectAll:", "a")] { edit.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key) }
        menu.addItem(editItem); NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 760, height: 420))
        let label = NSTextField(labelWithString: "TranslateBar 独立兼容测试 · 不连接 API，不发送消息")
        label.frame = NSRect(x: 20, y: 377, width: 720, height: 24); root.addSubview(label)
        for (index, mode) in ["single", "search", "multiline", "rich", "opaque", "readonly", "secure"].enumerated() {
            let button = NSButton(title: mode, target: self, action: #selector(choose(_:))); button.identifier = .init(mode)
            button.frame = NSRect(x: 20 + index * 103, y: 320, width: 100, height: 32); root.addSubview(button)
        }
        root.addSubview(area); window.contentView = root; window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        show("single")
    }
    @objc func choose(_ sender: NSButton) { show(sender.identifier!.rawValue) }
    func show(_ mode: String) {
        NSApp.activate(ignoringOtherApps: true)
        area.subviews.forEach { $0.removeFromSuperview() }; window.title = "TranslateBar Compatibility · " + mode
        if ["single", "search", "secure"].contains(mode) {
            let field: NSTextField = mode == "search" ? NSSearchField() : mode == "secure" ? NSSecureTextField() : NSTextField()
            field.frame = NSRect(x: 0, y: 180, width: 720, height: 36); field.font = .systemFont(ofSize: 16); field.stringValue = source
            field.identifier = .init("compat-field"); field.setAccessibilityLabel("兼容测试输入框")
            area.addSubview(field); editor = field; window.makeFirstResponder(field)
            if let text = window.fieldEditor(false, for: field) as? NSTextView { text.setSelectedRange(NSRange(location: (source as NSString).length, length: 0)) }
        } else {
            let scroll = NSScrollView(frame: area.bounds); scroll.hasVerticalScroller = true
            let text: NSTextView = mode == "opaque" ? OpaqueTextView(frame: area.bounds) : NSTextView(frame: area.bounds)
            text.identifier = .init("compat-text"); text.setAccessibilityLabel("兼容测试正文")
            text.isRichText = mode == "rich"; text.font = .systemFont(ofSize: 13); text.isAutomaticTextReplacementEnabled = false
            text.isAutomaticSpellingCorrectionEnabled = false; text.isAutomaticQuoteSubstitutionEnabled = false
            text.string = mode == "rich" ? "Protected heading\n" + source : mode == "multiline" ? "Keep this paragraph unchanged.\n" + source : source
            if mode == "rich" { text.textStorage?.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 22), range: NSRange(location: 0, length: 17)) }
            text.isEditable = mode != "readonly"; scroll.documentView = text; area.addSubview(scroll); editor = text
            window.makeFirstResponder(text); text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
let application = NSApplication.shared
let delegate = CompatibilityDelegate(); application.delegate = delegate; application.setActivationPolicy(.regular); application.run()
