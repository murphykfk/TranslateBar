import Foundation

public enum MicrosoftTextRules {
    public enum Document: Int {
        case word = 1, powerPoint = 2, excel = 3
    }

    public static func document(bundleID: String) -> Document? {
        switch bundleID {
        case "com.microsoft.Word": return .word
        case "com.microsoft.Powerpoint": return .powerPoint
        case "com.microsoft.Excel": return .excel
        default: return nil
        }
    }

    public static func powerPointCopiedText(value: String, range: NSRange, copied: String) -> String? {
        let count = value.utf16.count
        guard range.location >= 0, range.length > 0, range.location < count,
              range.length <= count + 1 - range.location else { return nil }
        let actual = NSRange(location: range.location, length: min(range.length, count - range.location))
        guard Range(actual, in: value) != nil else { return nil }
        let expected = (value as NSString).substring(with: actual)
        func canonical(_ text: String) -> String {
            text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        }
        let plain = canonical(copied), selected = canonical(expected)
        guard plain == selected || plain == selected + "\n" else { return nil }
        return expected
    }
}
