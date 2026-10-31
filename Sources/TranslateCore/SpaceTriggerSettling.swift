/// Wait for the triggering space to be released and the keyboard burst to
/// settle before capturing text. Continuing to type cancels before an API call.
public struct SpaceTriggerSettling {
    public private(set) var pending = false
    private var held = false
    private var lastActivity = 0.0
    private var started = 0.0
    public init() {}
    public mutating func begin(at time: Double) {
        pending = true; held = true; lastActivity = time; started = time
    }
    public mutating func cancel() { pending = false; held = false }
    public mutating func observe(space: Bool, keyDown: Bool, repeatKey: Bool = false, modifiers: Bool = false, at time: Double) {
        guard pending else { return }
        guard space, !repeatKey, !modifiers else { if keyDown { cancel() }; return }
        guard time >= lastActivity else { return }
        held = keyDown; lastActivity = time
    }
    public func ready(at time: Double) -> Bool { pending && !held && time >= lastActivity && time - lastActivity >= 0.12 }
    public func expired(at time: Double) -> Bool { pending && (time < started || time - started >= 2) }
}
