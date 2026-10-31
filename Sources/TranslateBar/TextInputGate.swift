import AppKit
import TranslateCore

/// Hold physical typing only during a temporary select/copy/paste transaction,
/// then replay it after the original caret or replacement has been restored.
/// API/network waits are never inside this gate.
@MainActor enum TextInputGate {
    private static var pid: pid_t?
    private static var queued: [CGEvent] = []
    private static var keys = InputGateKeys()
    static func intercept(_ event: CGEvent) -> Bool {
        guard let pid, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              event.type == .keyDown || event.type == .keyUp,
              let copy = event.copy() else { return false }
        // The trigger key may still be held when a cache hit starts selecting
        // rich text. Its release adds no text; pass it through instead of
        // replaying it and treating it as a competing edit.
        guard keys.shouldHold(keyCode: UInt16(event.getIntegerValueField(.keyboardEventKeycode)), isKeyDown: event.type == .keyDown) else { return false }
        queued.append(copy)
        return true
    }
    static func check() throws { if !queued.isEmpty { ReplacementDiagnostics.fail("queued_input", ["events": queued.count]); throw TextReplacementError.changed } }
    static func run<T>(pid expected: pid_t, _ body: () async throws -> T) async throws -> T {
        if pid != nil { return try await body() }
        pid = expected; keys = InputGateKeys()
        defer {
            let events = queued
            queued = []; pid = nil; keys = InputGateKeys()
            if !events.isEmpty {
                TextInteraction.changed(.replay)
                for event in events {
                    event.setIntegerValueField(.eventSourceUserData, value: InputMonitor.syntheticTag)
                    event.post(tap: .cgSessionEventTap)
                }
            }
        }
        let result = try await body()
        try check()
        return result
    }
}
