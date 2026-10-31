import AppKit

enum RichTextReplacementError: LocalizedError {
    case unavailable, structureChanged, mixedStyles
    var errorDescription: String? {
        switch self {
        case .unavailable: return "无法可靠读取原文字格式，原文未改动，译文已保留。"
        case .structureChanged: return "译文段落结构发生变化，为保留备忘录格式，原文未改动。"
        case .mixedStyles: return "这一段含有混合字号或强调样式，暂未自动覆盖，译文已保留。"
        }
    }
}

/// Format is local data. The translation service still receives plain text and
/// uses its existing shared cache; no style metadata is sent to the API.
@MainActor enum RichTextReplacement {
    struct Paragraph {
        let range: NSRange
        let lineRange: NSRange
        let content: NSRange
        let leading: NSRange
        let trailing: NSRange
    }
    static func paragraphs(_ text: String) -> [Paragraph] {
        let string = text as NSString
        var result: [Paragraph] = []; var offset = 0
        while offset < string.length {
            var start = 0, end = 0, contentsEnd = 0
            string.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: offset, length: 0))
            guard end > offset else { break }
            let raw = string.substring(with: NSRange(location: start, length: contentsEnd - start)) as NSString
            var first = 0, last = raw.length
            let spaces = CharacterSet.whitespaces
            while first < last, let scalar = UnicodeScalar(raw.character(at: first)), spaces.contains(scalar) { first += 1 }
            while last > first, let scalar = UnicodeScalar(raw.character(at: last - 1)), spaces.contains(scalar) { last -= 1 }
            result.append(Paragraph(range: NSRange(location: start, length: end - start), lineRange: NSRange(location: start, length: contentsEnd - start), content: NSRange(location: start + first, length: last - first), leading: NSRange(location: start, length: first), trailing: NSRange(location: start + last, length: end - start - last)))
            offset = end
        }
        return result
    }
    static func translated(_ text: String, preserving original: NSAttributedString, removingTriggerSpaces: Bool, triggerSpaceCount: Int = 4, requireFont: Bool = true) throws -> NSAttributedString {
        let source = paragraphs(original.string)
        let targets = paragraphs(text).filter { $0.content.length > 0 }.map { (text as NSString).substring(with: $0.content) }
        guard source.filter({ $0.content.length > 0 }).count == targets.count else { throw RichTextReplacementError.structureChanged }
        let output = NSMutableAttributedString(string: "")
        var translatedIndex = 0
        for paragraph in source {
            guard paragraph.content.length > 0 else { output.append(original.attributedSubstring(from: paragraph.range)); continue }
            let replacement = targets[translatedIndex]; translatedIndex += 1
            output.append(original.attributedSubstring(from: paragraph.leading))
            let originalContent = original.attributedSubstring(from: paragraph.content)
            if originalContent.string == replacement { output.append(originalContent) }
            else {
                let attributes = originalContent.attributes(at: 0, effectiveRange: nil)
                if requireFont {
                guard let font = attributes[.font] as? NSFont else { throw RichTextReplacementError.unavailable }
                var uniform = true
                originalContent.enumerateAttribute(.font, in: NSRange(location: 0, length: originalContent.length)) { value, _, _ in
                    guard let other = value as? NSFont, abs(other.pointSize - font.pointSize) < 0.1,
                          other.fontDescriptor.symbolicTraits.intersection([.bold, .italic]) == font.fontDescriptor.symbolicTraits.intersection([.bold, .italic]) else { uniform = false; return }
                }
                guard uniform else { throw RichTextReplacementError.mixedStyles }
                }
                output.append(NSAttributedString(string: replacement, attributes: attributes))
            }
            var trailing = paragraph.trailing
            // Remove gesture spaces only at the end; preserve paragraph breaks
            // and the original blank lines instead of rebuilding the document.
            if removingTriggerSpaces, triggerSpaceCount > 0, NSMaxRange(trailing) == original.length, trailing.length >= triggerSpaceCount,
               (original.string as NSString).substring(with: NSRange(location: original.length - triggerSpaceCount, length: triggerSpaceCount)).unicodeScalars.allSatisfy({ $0.value == 32 || $0.value == 160 }) {
                trailing.length -= triggerSpaceCount
            }
            output.append(original.attributedSubstring(from: trailing))
        }
        return output
    }
    static func rtf(_ text: NSAttributedString) throws -> Data {
        try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }
    struct Edit {
        let range: NSRange
        let original: NSAttributedString
        let replacement: NSAttributedString
    }
    static func edits(original: NSAttributedString, replacement: NSAttributedString, offset: Int) throws -> [Edit] {
        let source = paragraphs(original.string), target = paragraphs(replacement.string)
        guard source.count == target.count else { throw RichTextReplacementError.structureChanged }
        return zip(source, target).compactMap { before, after in
            let old = original.attributedSubstring(from: before.lineRange)
            let new = replacement.attributedSubstring(from: after.lineRange)
            guard old.string != new.string else { return nil }
            return Edit(range: NSRange(location: offset + before.lineRange.location, length: before.lineRange.length), original: old, replacement: new)
        }.reversed()
    }
}
