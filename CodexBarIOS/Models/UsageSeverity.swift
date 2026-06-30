import SwiftUI

public enum UsageSeverity: Int, Comparable, Sendable {
    case normal
    case warning
    case critical

    public init(fractionUsed: Double) {
        if fractionUsed >= 0.9 {
            self = .critical
        } else if fractionUsed >= 0.75 {
            self = .warning
        } else {
            self = .normal
        }
    }

    public static func < (lhs: UsageSeverity, rhs: UsageSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var tint: Color {
        switch self {
        case .normal:
            .green
        case .warning:
            .orange
        case .critical:
            .red
        }
    }
}
