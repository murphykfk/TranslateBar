import Foundation

/// The only per-application data for input translation: the shortcut that
/// selects from the caret back to the start of its paragraph, for editors
/// that do not let accessibility set the selection. Every other step is the
/// same for all apps.
public enum ParagraphSelectionKey: String, Equatable, Sendable {
    /// Selects to the start of the line. It only ever moves the selection,
    /// whereas Option-Shift-Up moves lines in code editors and switches
    /// channels in Slack and Discord.
    case commandShiftLeft
    /// Paragraph selection in Word and WPS.
    case commandShiftUp
    /// Paragraph selection in PowerPoint, where Command-Shift-Up selects to
    /// the start of the text box.
    case optionShiftUp
    /// Excel's cell editor; Command-Left selects a word there.
    case shiftHome

    public static func forApplication(_ bundleID: String) -> ParagraphSelectionKey {
        overrides[bundleID] ?? .commandShiftLeft
    }

    static let overrides: [String: ParagraphSelectionKey] = [
        "com.microsoft.Word": .commandShiftUp,
        "com.kingsoft.wpsoffice.mac": .commandShiftUp,
        "com.microsoft.Powerpoint": .optionShiftUp,
        "com.microsoft.Excel": .shiftHome
    ]
}

public enum ParagraphDraftError: LocalizedError, Equatable {
    case empty, multipleParagraphs, embeddedObject, triggerMissing
    public var errorDescription: String? {
        switch self {
        case .empty: return "当前段落没有需要翻译的文本，已跳过。"
        case .multipleParagraphs: return "选区跨过了段落或包含换行，无法安全定位，原文未改动。"
        case .embeddedObject: return "当前段落包含图片或附件，原文未改动，请选中文字后使用划词翻译。"
        case .triggerMissing: return "未在光标前找到触发空格，原文未改动。"
        }
    }
}

/// The text copied from the paragraph start up to the caret, split into the
/// part to translate and the whitespace around it.
public struct ParagraphDraft: Equatable, Sendable {
    public let leading: String
    public let source: String
    /// Spaces the user typed before the trigger burst; the trigger itself is dropped.
    public let trailing: String

    public init(copied: String, triggerSpaces: Int) throws {
        let text = Self.canonical(copied)
        guard !text.contains(where: \.isNewline) else { throw ParagraphDraftError.multipleParagraphs }
        guard !text.unicodeScalars.contains(where: { $0.value == 0xfffc }) else { throw ParagraphDraftError.embeddedObject }
        guard !text.unicodeScalars.contains(where: { ($0.value < 0x20 && $0.value != 9) || (0x7f...0x9f).contains($0.value) }) else {
            throw ParagraphDraftError.multipleParagraphs
        }
        let spaces = text.unicodeScalars.reversed().prefix(while: { $0.value == 32 || $0.value == 160 }).count
        // An input method may consume the first press of the burst to commit
        // its candidate, which leaves one trigger space fewer in the text.
        let required = min(4, max(2, triggerSpaces))
        guard spaces >= required - 1 else { throw ParagraphDraftError.triggerMissing }
        let scalars = Array(text.unicodeScalars.dropLast(min(spaces, required)))
        let body = String(String.UnicodeScalarView(scalars))
        let source = body.trimmingCharacters(in: .whitespaces)
        guard !source.isEmpty else { throw ParagraphDraftError.empty }
        leading = String(body.prefix(while: { $0.isWhitespace }))
        trailing = String(body.reversed().prefix(while: { $0.isWhitespace }).reversed())
        self.source = source
    }

    /// The text that replaces the copied selection. Line breaks inside the
    /// translation would split the paragraph, so they become spaces.
    public func replacement(_ translation: String) -> String {
        let words = translation.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return leading + words.joined(separator: " ") + trailing
    }

    /// Clipboard exports may use CR or CRLF, append one paragraph mark after a
    /// partial selection, or write spaces as no-break spaces.
    public static func canonical(_ text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if result.hasSuffix("\n") { result.removeLast() }
        return result
    }

    /// From the last line break before the caret up to the caret, in UTF-16
    /// offsets, for editors that expose their text and caret.
    public static func prefixRange(in text: String, caret: Int) -> NSRange {
        let string = text as NSString
        let end = min(max(0, caret), string.length)
        var start = end
        while start > 0, ![0x0a, 0x0b, 0x0c, 0x0d, 0x85, 0x2028, 0x2029].contains(string.character(at: start - 1)) { start -= 1 }
        return NSRange(location: start, length: end - start)
    }

    public static func sameText(_ lhs: String, _ rhs: String) -> Bool {
        func normalized(_ text: String) -> String { canonical(text).replacingOccurrences(of: "\u{a0}", with: " ") }
        return normalized(lhs) == normalized(rhs)
    }

    /// Controls that never hold a text caret. Typing spaces there is not a
    /// request to translate, and selection shortcuts would act on the control.
    public static func permitsFocusRole(_ role: String) -> Bool {
        !["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXMenu", "AXMenuBar", "AXMenuItem",
          "AXSlider", "AXScrollBar", "AXImage", "AXList", "AXTable", "AXOutline", "AXRow", "AXColumn", "AXBrowser",
          "AXTabGroup", "AXToolbar", "AXSplitter", "AXDisclosureTriangle", "AXIncrementor", "AXColorWell"].contains(role)
    }
}
