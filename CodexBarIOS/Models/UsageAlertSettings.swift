import Foundation

public struct UsageAlertSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public private(set) var warningThreshold: Double
    public private(set) var criticalThreshold: Double
    public var balanceThreshold: Double

    public init(
        isEnabled: Bool = false,
        warningThreshold: Double = Self.defaultWarningThreshold,
        criticalThreshold: Double = Self.defaultCriticalThreshold,
        balanceThreshold: Double = Self.defaultBalanceThreshold
    ) {
        let thresholds = UsageSeverityThresholds(
            warning: warningThreshold,
            critical: criticalThreshold
        )
        self.isEnabled = isEnabled
        self.warningThreshold = thresholds.warning
        self.criticalThreshold = thresholds.critical
        self.balanceThreshold = Self.normalizedBalanceThreshold(balanceThreshold)
    }

    public static let defaultWarningThreshold = UsageSeverityThresholds.default.warning
    public static let defaultCriticalThreshold = UsageSeverityThresholds.default.critical
    public static let defaultBalanceThreshold = 5.00
    public static let minimumThresholdGap = UsageSeverityThresholds.minimumGap

    public var severityThresholds: UsageSeverityThresholds {
        UsageSeverityThresholds(warning: warningThreshold, critical: criticalThreshold)
    }

    public mutating func updateWarningThreshold(_ value: Double) {
        let value = value.isFinite ? value : Self.defaultWarningThreshold
        warningThreshold = min(
            max(value, UsageSeverityThresholds.minimumValue),
            criticalThreshold - Self.minimumThresholdGap
        )
    }

    public mutating func updateCriticalThreshold(_ value: Double) {
        let value = value.isFinite ? value : Self.defaultCriticalThreshold
        criticalThreshold = max(
            min(value, UsageSeverityThresholds.maximumValue),
            warningThreshold + Self.minimumThresholdGap
        )
    }

    public static func normalizedBalanceThreshold(_ value: Double) -> Double {
        max(value, 0)
    }

    private enum CodingKeys: String, CodingKey {
        case isEnabled
        case warningThreshold
        case criticalThreshold
        case balanceThreshold
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false,
            warningThreshold: try container.decodeIfPresent(
                Double.self,
                forKey: .warningThreshold
            ) ?? Self.defaultWarningThreshold,
            criticalThreshold: try container.decodeIfPresent(
                Double.self,
                forKey: .criticalThreshold
            ) ?? Self.defaultCriticalThreshold,
            balanceThreshold: try container.decodeIfPresent(
                Double.self,
                forKey: .balanceThreshold
            ) ?? Self.defaultBalanceThreshold
        )
    }
}
