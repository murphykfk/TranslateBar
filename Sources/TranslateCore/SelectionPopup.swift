import Foundation
import CoreGraphics

public enum SelectionPopupPlacement {
    public static func frame(anchor: CGRect, size: CGSize, visible: CGRect, gap: CGFloat = 36) -> CGRect {
        let area = visible.insetBy(dx: 8, dy: 8)
        let size = CGSize(width: min(size.width, area.width), height: min(size.height, area.height))
        func fit(_ x: CGFloat, _ y: CGFloat) -> CGRect {
            CGRect(x: min(max(x, area.minX), area.maxX - size.width), y: min(max(y, area.minY), area.maxY - size.height), width: size.width, height: size.height)
        }
        let x = anchor.midX - size.width / 2
        let y = anchor.midY - size.height / 2
        let candidates = [fit(x, anchor.minY - gap - size.height), fit(x, anchor.maxY + gap),
                          fit(anchor.maxX + gap, y), fit(anchor.minX - gap - size.width, y)]
        let exclusion = anchor.insetBy(dx: -gap + 0.1, dy: -gap + 0.1)
        if let clear = candidates.first(where: { !$0.intersects(exclusion) }) { return clear }
        // An unusually large selection can fill the screen. Minimize overlap in that case.
        let corners = [fit(area.minX, area.minY), fit(area.maxX, area.minY), fit(area.minX, area.maxY), fit(area.maxX, area.maxY)]
        return (candidates + corners).min { lhs, rhs in
            func overlap(_ rect: CGRect) -> CGFloat {
                let intersection = rect.intersection(exclusion)
                return intersection.isNull ? 0 : intersection.width * intersection.height
            }
            return overlap(lhs) < overlap(rhs)
        } ?? candidates[0]
    }
}

public struct SelectionPopupLifetime {
    public private(set) var current: UUID?
    public init() {}
    @discardableResult public mutating func begin() -> UUID { let id = UUID(); current = id; return id }
    public mutating func dismiss() { current = nil }
    public func accepts(_ id: UUID) -> Bool { current == id }
}

public enum SelectionObservation: Equatable {
    case matching, cleared, changed, unavailable, contextChanged
}

/// Accessibility trees can briefly disappear or expose an empty selection
/// during a web-page update. Only a stable, readable change proves dismissal.
public struct SelectionDismissalPolicy {
    private var pending: SelectionObservation?
    private var pendingSince = 0.0
    public init() {}
    public mutating func shouldDismiss(_ observation: SelectionObservation, at now: Double) -> Bool {
        switch observation {
        case .contextChanged: return true
        case .matching, .unavailable:
            pending = nil; return false
        case .cleared, .changed:
            if pending != observation || now < pendingSince { pending = observation; pendingSince = now; return false }
            return now - pendingSince >= 0.45
        }
    }
}
