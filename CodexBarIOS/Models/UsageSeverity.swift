import SwiftUI

public struct UsageSeverityThresholds: Equatable, Sendable {
    public let warning: Double
    public let critical: Double

    public static let minimumValue = 0.01
    public static let maximumValue = 1.0
    public static let minimumGap = 0.01
    public static let `default` = UsageSeverityThresholds(warning: 0.75, critical: 0.90)

    public init(warning: Double, critical: Double) {
        let normalizedWarning = min(
            max(warning, Self.minimumValue),
            Self.maximumValue - Self.minimumGap
        )
        self.warning = normalizedWarning
        self.critical = min(
            max(critical, normalizedWarning + Self.minimumGap),
            Self.maximumValue
        )
    }
}

public enum UsageSeverity: Int, Codable, Comparable, Sendable {
    case normal
    case warning
    case critical

    public init(
        fractionUsed: Double,
        thresholds: UsageSeverityThresholds = .default
    ) {
        if fractionUsed >= thresholds.critical {
            self = .critical
        } else if fractionUsed >= thresholds.warning {
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

private struct UsageSeverityThresholdsEnvironmentKey: EnvironmentKey {
    static let defaultValue = UsageSeverityThresholds.default
}

extension EnvironmentValues {
    var usageSeverityThresholds: UsageSeverityThresholds {
        get { self[UsageSeverityThresholdsEnvironmentKey.self] }
        set { self[UsageSeverityThresholdsEnvironmentKey.self] = newValue }
    }
}
