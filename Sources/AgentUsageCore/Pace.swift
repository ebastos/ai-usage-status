import Foundation

public struct Pace: Equatable, Sendable {
    public var expectedPercent: Int
    public var aheadPercent: Int
    public var label: String

    public var expectedLabel: String { "Expected \(expectedPercent)% used" }
}

public enum PaceMath {
    /// Linear pace. `ahead` is expected minus used, after both are rounded to integers.
    /// A positive ahead means the window has more left than the clock would suggest.
    public static func make(usedPercent: Double, resetsAt: Date, window: TimeInterval, now: Date) -> Pace? {
        guard window > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        let elapsed = min(max(window - remaining, 0), window)
        let expected = Int((elapsed / window * 100).rounded())
        let used = Int(usedPercent.rounded())
        let ahead = expected - used
        let label: String
        if ahead > 0 {
            label = "\(ahead)% ahead of pace"
        } else if ahead < 0 {
            label = "\(abs(ahead))% behind pace"
        } else {
            label = "on pace"
        }
        return Pace(expectedPercent: expected, aheadPercent: ahead, label: label)
    }
}
