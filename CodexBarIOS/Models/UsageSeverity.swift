import SwiftUI

public enum UsageSeverity: Int, Codable, Comparable, Sendable {
    case normal
    case warning
    case critical

    public init(fractionUsed: Double) {
        switch CodexBarWidgetSeverity(fractionUsed: fractionUsed) {
        case .normal:
            self = .normal
        case .warning:
            self = .warning
        case .critical:
            self = .critical
        }
    }

    public static func < (lhs: UsageSeverity, rhs: UsageSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var tint: Color {
        switch self {
        case .normal:
            CodexBarSeverityPalette.normal
        case .warning:
            CodexBarSeverityPalette.warning
        case .critical:
            CodexBarSeverityPalette.critical
        }
    }

    public var projectedTint: Color {
        switch self {
        case .normal:
            CodexBarSeverityPalette.projectedNormal
        case .warning:
            CodexBarSeverityPalette.projectedWarning
        case .critical:
            CodexBarSeverityPalette.projectedCritical
        }
    }
}
