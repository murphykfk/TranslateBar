import AppKit
import TranslateCore

/// Runs the input pipeline against a temporary TextEdit document or browser
/// page whose title contains `TranslateBar-Paragraph-Test`, with fixed
/// translations and no API calls. Each paragraph is translated and undone,
/// through accessibility selection and through the keyboard shortcut, then
/// the guards are checked. Browser fixtures place the caret themselves on
/// F7 (end of the middle paragraph), F8 (end of the last) and F9 (start of
/// the middle), because block editors misreport accessibility offsets.
@MainActor enum ParagraphSmokeTest {
    static let fixture = "TranslateBar-Paragraph-Test"
    private enum Spot { case middleEnd, lastEnd, middleStart }
    private static let cases: [(String, Spot, String, String)] = [
        ("middle", .middleEnd, "你好，世界", "Hello, world"), ("last", .lastEnd, "最后一段", "The last paragraph")
    ]

    static func run() async {
        var report: [String: Any] = ["success": false, "api_calls": 0, "trusted": AccessibleText.trusted]
        let bundle = argument("--app") ?? "com.apple.TextEdit"
        var enhanced: AXUIElement?
        defer {
            ParagraphText.allowsAccessibilitySelection = true
            if let enhanced { AXUIElementSetAttributeValue(enhanced, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        }
        do {
            guard ["com.apple.TextEdit", "com.apple.Safari", "com.google.Chrome"].contains(bundle),
                  let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { throw AppError.message("仅允许 TextEdit 或浏览器测试页。") }
            report["app"] = bundle
            app.activate()
            await OfficeText.pause(0.8)
            let pid = app.processIdentifier
            if bundle == "com.google.Chrome" {
                // Chrome exposes page contents only to assistive clients. Enable
                // that for this run so the fixture can be read back.
                enhanced = AXUIElementCreateApplication(pid)
                AXUIElementSetAttributeValue(enhanced!, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
            }
            for _ in 0..<30 where TextFocus.resolve(pid: pid, wakeAccessibility: true).flatMap(AccessibleText.textValue) == nil { await OfficeText.pause(0.1) }
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let window: AXUIElement = AccessibleText.attribute(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute),
                  (AccessibleText.attribute(window, kAXTitleAttribute) as String? ?? "").contains(fixture),
                  let focus = TextFocus.resolve(pid: pid),
                  let element = ([focus] + AccessibleText.inputCandidates(focus)).first(where: { AccessibleText.textValue($0) != nil }),
                  let original = AccessibleText.textValue(element) else { throw AppError.message("只允许前台标题含 \(fixture) 的临时文档。") }
            let text = original as NSString
            let originalRich = AccessibleText.attributedText(element, range: NSRange(location: 0, length: text.length))
            let place = { (spot: Spot) async -> Bool in await self.place(spot, in: element, pid: pid, browser: bundle != "com.apple.TextEdit") }
            var settings = AppSettings(); settings.spaceCount = 4
            for (mode, accessibility) in [("accessibility", true), ("keyboard", false)] {
                ParagraphText.allowsAccessibilitySelection = accessibility
                for (name, spot, source, translation) in cases {
                    let key = "\(mode)_\(name)"
                    report["stage"] = key
                    let range = text.range(of: source + "    ")
                    guard range.location != NSNotFound, await place(spot) else { throw AppError.message("测试文档内容不符。") }
                    ReplacementDiagnostics.beginCapture()
                    let snapshot = try await ParagraphText.capture(settings: settings)
                    guard snapshot.draft.source == source else { throw AppError.message("\(key)：取到的段落不符。") }
                    let undo = try await ParagraphText.replace(snapshot, with: translation)
                    let length = (translation as NSString).length
                    guard AccessibleText.textValue(element) == text.replacingCharacters(in: range, with: translation) else { throw AppError.message("\(key)：替换后全文不符。") }
                    report[key + "_style_kept"] = sameStyle(originalRich, range.location, AccessibleText.attributedText(element, range: NSRange(location: range.location, length: length)), 0)
                    try await ParagraphText.undo(undo)
                    guard AccessibleText.textValue(element) == original else { throw AppError.message("\(key)：撤销后全文不符。") }
                    report[key + "_style_restored"] = sameStyle(originalRich, range.location, AccessibleText.attributedText(element, range: range), 0)
                    report[key] = "ok"
                }
            }
            ParagraphText.allowsAccessibilitySelection = true
            report["stage"] = "guards"
            report["interaction_guard"] = try await rejected(element, original: original, settings: settings, place: place) { TextInteraction.changed() }
            report["moved_caret_guard"] = try await rejected(element, original: original, settings: settings, place: place) { _ = await place(.middleStart) }
            // Typing that the input monitor never saw: only the copied text can tell.
            report["edited_text_guard"] = try await rejected(element, original: original, settings: settings, place: place) {
                OfficeText.key(7, to: pid)
                await OfficeText.pause(0.1)
            }
            if AccessibleText.textValue(element) != original {
                OfficeText.key(51, to: pid)
                for _ in 0..<20 where AccessibleText.textValue(element) != original { await OfficeText.pause(0.05) }
            }
            report["edited_text_cleaned_up"] = AccessibleText.textValue(element) == original
            report["success"] = true
        } catch {
            report["error"] = error.localizedDescription
            report["diagnostics"] = ReplacementDiagnostics.current?.checks.map(\.stage) ?? []
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            if let path = argument("--report") { try? data.write(to: URL(fileURLWithPath: path)) }
            Swift.print(String(decoding: data, as: UTF8.self))
        }
    }

    /// Captures the middle paragraph, disturbs the editor, and expects the
    /// replacement to refuse without touching the text.
    private static func rejected(_ element: AXUIElement, original: String, settings: AppSettings,
                                 place: (Spot) async -> Bool, disturb: () async -> Void) async throws -> Bool {
        guard await place(.middleEnd) else { return false }
        let snapshot = try await ParagraphText.capture(settings: settings)
        await disturb()
        let disturbed = AccessibleText.textValue(element)
        do { _ = try await ParagraphText.replace(snapshot, with: "Must not be written"); return false }
        catch { return AccessibleText.textValue(element) == disturbed }
    }

    private static func place(_ spot: Spot, in element: AXUIElement, pid: pid_t, browser: Bool) async -> Bool {
        if browser {
            OfficeText.key(spot == .middleEnd ? 98 : spot == .lastEnd ? 100 : 101, to: pid)
            await OfficeText.pause(0.2)
            return true
        }
        guard let value = AccessibleText.textValue(element) else { return false }
        let range = (value as NSString).range(of: spot == .lastEnd ? "最后一段    " : "你好，世界    ")
        guard range.location != NSNotFound else { return false }
        var caret = CFRange(location: spot == .middleStart ? range.location : NSMaxRange(range), length: 0)
        guard let ax = AXValueCreate(.cfRange, &caret), AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, ax) == .success else { return false }
        await OfficeText.pause(0.1)
        return true
    }

    private static func sameStyle(_ lhs: NSAttributedString?, _ left: Int, _ rhs: NSAttributedString?, _ right: Int) -> Bool {
        guard let lhs, let rhs, left < lhs.length, right < rhs.length,
              let a = lhs.attribute(.font, at: left, effectiveRange: nil) as? NSFont,
              let b = rhs.attribute(.font, at: right, effectiveRange: nil) as? NSFont else { return false }
        let traits: NSFontDescriptor.SymbolicTraits = [.bold, .italic]
        return abs(a.pointSize - b.pointSize) < 0.1 && a.fontDescriptor.symbolicTraits.intersection(traits) == b.fontDescriptor.symbolicTraits.intersection(traits)
    }

    private static func argument(_ name: String) -> String? {
        CommandLine.arguments.firstIndex(of: name).flatMap { CommandLine.arguments.indices.contains($0 + 1) ? CommandLine.arguments[$0 + 1] : nil }
    }
}
