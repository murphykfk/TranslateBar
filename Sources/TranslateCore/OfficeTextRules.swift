import Foundation

public enum OfficeTextRules {
    /// WPS may turn trailing space runs into alternating space/NBSP when importing RTF.
    /// Keep the count and all non-padding text exact; never normalize internal spaces.
    public static func canonicalTrailingSpaces(_ text: String) -> String {
        let count = text.reversed().prefix { $0 == " " || $0 == "\u{00a0}" }.count
        return String(text.dropLast(count)) + String(repeating: " ", count: count)
    }
    public static func samePrefix(_ lhs: String, _ rhs: String) -> Bool { canonicalTrailingSpaces(lhs) == canonicalTrailingSpaces(rhs) }
}
