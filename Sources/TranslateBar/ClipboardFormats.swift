import AppKit
import Carbon

/// Qt's legacy pasteboard flavor names are readable by Pasteboard APIs even
/// when NSPasteboardItem rejects them as non-UTI strings.
@MainActor enum ClipboardFormats {
    private static func handle(_ board: NSPasteboard) -> Pasteboard? {
        var reference: Pasteboard?
        let name = board.name == .general ? kPasteboardClipboard : board.name.rawValue
        guard PasteboardCreate(name as CFString, &reference) == noErr else { return nil }
        if let reference { PasteboardSynchronize(reference) }
        return reference
    }
    static func snapshot(_ board: NSPasteboard) -> [[(NSPasteboard.PasteboardType, Data)]]? {
        guard let reference = handle(board) else { return nil }
        var count: Int = 0
        guard PasteboardGetItemCount(reference, &count) == noErr else { return nil }
        if count == 0 { return board.pasteboardItems?.isEmpty == false ? nil : [] }
        var items: [[(NSPasteboard.PasteboardType, Data)]] = []
        for index in 1...Int(count) {
            var identifier: PasteboardItemID?
            guard PasteboardGetItemIdentifier(reference, index, &identifier) == noErr, let identifier else { return nil }
            var flavors: CFArray?
            guard PasteboardCopyItemFlavors(reference, identifier, &flavors) == noErr, let types = flavors as? [String] else { return nil }
            var values: [(NSPasteboard.PasteboardType, Data)] = []
            for type in types {
                var data: CFData?
                if PasteboardCopyItemFlavorData(reference, identifier, type as CFString, &data) == noErr, let data { values.append((.init(type), data as Data)) }
            }
            items.append(values)
        }
        return items
    }
    static func data(_ type: NSPasteboard.PasteboardType, from board: NSPasteboard, itemIndex: Int = 1) -> Data? {
        guard let reference = handle(board) else { return nil }
        var identifier: PasteboardItemID?
        guard PasteboardGetItemIdentifier(reference, itemIndex, &identifier) == noErr, let identifier else { return nil }
        var data: CFData?
        guard PasteboardCopyItemFlavorData(reference, identifier, type.rawValue as CFString, &data) == noErr else { return nil }
        return data as Data?
    }
}
