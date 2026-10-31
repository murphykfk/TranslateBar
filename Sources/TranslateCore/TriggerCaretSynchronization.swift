import Foundation

/// AX text and caret attributes may settle in separate updates after the last
/// trigger space. Accept only a collapsed caret advancing to the very end of
/// an unchanged body plus the bounded ASCII/NBSP trigger suffix.
public enum TriggerCaretSynchronization {
    public static func permits(original: String, current: String, captured: NSRange, actual: NSRange, replacementRange: NSRange, triggerSpaces: Int, interactionUnchanged: Bool) -> Bool {
        let before = original as NSString, after = current as NSString
        guard interactionUnchanged, (2...4).contains(triggerSpaces),
              captured.length == 0, actual.length == 0,
              replacementRange.location >= 0, replacementRange.length >= 0,
              replacementRange.location <= before.length, replacementRange.length == before.length - replacementRange.location,
              captured.location >= replacementRange.location,
              captured.location >= 0, captured.location <= before.length,
              actual.location == after.length, actual.location > captured.location,
              actual.location - captured.location <= triggerSpaces,
              after.length >= before.length, after.length - before.length <= triggerSpaces else { return false }
        func isSpace(_ code: unichar) -> Bool { code == 32 || code == 160 }
        // An ordinary caret move within a word or across a paragraph is never
        // a settling trigger, even if the new location happens to be the end.
        for offset in captured.location..<before.length { if !isSpace(before.character(at: offset)) { return false } }
        for offset in captured.location..<after.length { if !isSpace(after.character(at: offset)) { return false } }
        return before.substring(to: captured.location) == after.substring(to: captured.location)
    }
}
