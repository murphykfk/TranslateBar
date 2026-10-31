/// A key release is part of this transaction only if its press was held here.
/// In particular, releasing the space that triggered translation is not new
/// typing and must not cancel a fast cached replacement.
public struct InputGateKeys {
    private var pressed = Set<UInt16>()
    public init() {}
    public mutating func shouldHold(keyCode: UInt16, isKeyDown: Bool) -> Bool {
        if isKeyDown { pressed.insert(keyCode); return true }
        return pressed.remove(keyCode) != nil
    }
}
