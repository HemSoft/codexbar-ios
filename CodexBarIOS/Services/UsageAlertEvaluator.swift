import Foundation

public enum UsageAlertKind: String, Equatable, Sendable {
    // Retained so callers can still render details created by older app code.
    case usage
    case balance
    case severity
}

public struct UsageAlertDetail: Identifiable, Equatable, Sendable {
    public let id: String
    public let accountID: String
    public let kind: UsageAlertKind
    public let title: String
    public let message: String
    public let severity: UsageSeverity

    public init(
        id: String,
        accountID: String,
        kind: UsageAlertKind,
        title: String,
        message: String,
        severity: UsageSeverity
    ) {
        self.id = id
        self.accountID = accountID
        self.kind = kind
        self.title = title
        self.message = message
        self.severity = severity
    }
}

public struct UsageAlertNotification: Equatable, Sendable {
    public let id: String
    public let accountID: String
    public let kind: UsageAlertKind
    public let title: String
    public let body: String
}

public struct UsageAlertEvaluation: Equatable, Sendable {
    public let notifications: [UsageAlertNotification]
    public let activeAlertIDs: Set<String>
    public let activeAlerts: [UsageAlertDetail]
}

public enum UsageAlertEvaluator {
    static func activeAlertIDs(
        _ activeAlertIDs: Set<String>,
        belongingTo preservedAccountIDs: Set<String>,
        knownAccountIDs: Set<String>
    ) -> Set<String> {
        let accountIDsBySpecificity = knownAccountIDs.sorted { lhs, rhs in
            lhs.count == rhs.count ? lhs < rhs : lhs.count > rhs.count
        }

        return activeAlertIDs.filter { alertID in
            guard let accountID = Self.accountID(
                for: alertID,
                knownAccountIDs: accountIDsBySpecificity
            ) else {
                return false
            }
            return preservedAccountIDs.contains(accountID)
        }
    }

    private static func accountID(
        for alertID: String,
        knownAccountIDs: [String]
    ) -> String? {
        knownAccountIDs.first { accountID in
            alertID == balanceAlertID(for: accountID)
                || severityAlertIDs(for: accountID).contains(alertID)
                || alertID == "severity.\(accountID)"
                || alertID.hasPrefix("usage.\(accountID).")
        }
    }

    public static func evaluate(
        results: [ProviderUsageResult],
        settings: UsageAlertSettings,
        activeAlertIDs: Set<String>,
        now: Date = Date()
    ) -> UsageAlertEvaluation {
        guard settings.isEnabled else {
            return UsageAlertEvaluation(notifications: [], activeAlertIDs: [], activeAlerts: [])
        }

        let thresholds = settings.severityThresholds
        var nextActiveAlertIDs = Set<String>()
        var activeAlerts: [UsageAlertDetail] = []
        var notifications: [UsageAlertNotification] = []

        for result in results {
            let accountSeverityIDs = severityAlertIDs(for: result.accountID)
            if result.preserveCachedBarsOnFailure || !result.hasFreshBars {
                nextActiveAlertIDs.formUnion(
                    activeAlertIDs.intersection(accountSeverityIDs)
                )
            }

            let balanceAlertID = balanceAlertID(for: result.accountID)
            if (result.preserveCachedCreditsOnFailure || !result.hasFreshCredits),
               activeAlertIDs.contains(balanceAlertID)
            {
                nextActiveAlertIDs.insert(balanceAlertID)
            }

            if let creditsRemaining = result.freshCreditsRemaining,
               creditsRemaining <= settings.balanceThreshold
            {
                nextActiveAlertIDs.insert(balanceAlertID)

                let detail = balanceAlertDetail(
                    id: balanceAlertID,
                    result: result,
                    creditsRemaining: creditsRemaining,
                    threshold: settings.balanceThreshold
                )
                activeAlerts.append(detail)

                if !activeAlertIDs.contains(balanceAlertID) {
                    notifications.append(
                        UsageAlertNotification(
                            id: balanceAlertID,
                            accountID: result.accountID,
                            kind: .balance,
                            title: "\(result.title) balance alert",
                            body: detail.notificationBody
                        )
                    )
                }
            }

            let alertBars = result.freshBars
            let highestSeverity = max(
                alertBars.map {
                    $0.effectiveSeverity(at: now, thresholds: thresholds)
                }.max() ?? .normal,
                result.hasReachedSpendLimit ? .critical : .normal
            )
            guard highestSeverity >= .warning else {
                continue
            }

            let warningAlertID = severityAlertID(
                for: result.accountID,
                severity: .warning
            )
            nextActiveAlertIDs.insert(warningAlertID)

            let currentAlertID: String
            if highestSeverity == .critical {
                currentAlertID = severityAlertID(
                    for: result.accountID,
                    severity: .critical
                )
                nextActiveAlertIDs.insert(currentAlertID)
            } else {
                currentAlertID = warningAlertID
            }

            let detail = severityAlertDetail(
                id: currentAlertID,
                result: result,
                bars: alertBars,
                severity: highestSeverity,
                thresholds: thresholds,
                now: now
            )
            activeAlerts.append(detail)

            if !activeAlertIDs.contains(currentAlertID) {
                notifications.append(
                    UsageAlertNotification(
                        id: currentAlertID,
                        accountID: result.accountID,
                        kind: .severity,
                        title: "\(result.title) \(highestSeverity.notificationName)",
                        body: detail.notificationBody
                    )
                )
            }
        }

        return UsageAlertEvaluation(
            notifications: notifications,
            activeAlertIDs: nextActiveAlertIDs,
            activeAlerts: activeAlerts
        )
    }

    private static func balanceAlertDetail(
        id: String,
        result: ProviderUsageResult,
        creditsRemaining: Double,
        threshold: Double
    ) -> UsageAlertDetail {
        UsageAlertDetail(
            id: id,
            accountID: result.accountID,
            kind: .balance,
            title: "Balance below \(formatCurrency(threshold))",
            message: "\(formatCurrency(creditsRemaining)) remaining for \(result.title).",
            severity: .warning
        )
    }

    private static func severityAlertDetail(
        id: String,
        result: ProviderUsageResult,
        bars: [UsageBar],
        severity: UsageSeverity,
        thresholds: UsageSeverityThresholds,
        now: Date
    ) -> UsageAlertDetail {
        let affectedBar = bars.first {
            $0.effectiveSeverity(at: now, thresholds: thresholds) == severity
        }
        let message: String

        if let affectedBar {
            if affectedBar.severity(using: thresholds) < severity,
               let projectedFraction = affectedBar.projectedFraction(at: now)
            {
                message = "\(affectedBar.label) is projected to reach \(formatPercent(projectedFraction))."
            } else {
                message = "\(affectedBar.label) is currently at \(affectedBar.usageText)."
            }
        } else if result.hasReachedSpendLimit {
            message = "The monthly usage-credit spend limit has been reached."
        } else {
            message = result.subtitle
        }

        return UsageAlertDetail(
            id: id,
            accountID: result.accountID,
            kind: .severity,
            title: "\(severity.displayName) status",
            message: message,
            severity: severity
        )
    }

    private static func balanceAlertID(for accountID: String) -> String {
        "balance.\(accountID)"
    }

    private static func severityAlertID(
        for accountID: String,
        severity: UsageSeverity
    ) -> String {
        "severity.\(severity.idComponent).\(accountID)"
    }

    private static func severityAlertIDs(for accountID: String) -> Set<String> {
        [
            severityAlertID(for: accountID, severity: .warning),
            severityAlertID(for: accountID, severity: .critical),
        ]
    }

    private static func formatPercent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private static func formatCurrency(_ value: Double) -> String {
        currencyFormatter.string(from: NSNumber(value: value)) ?? "$\(String(format: "%.2f", value))"
    }

    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}

private extension UsageAlertDetail {
    var notificationBody: String {
        "\(title). \(message)"
    }
}

private extension UsageSeverity {
    var displayName: String {
        switch self {
        case .normal:
            "Normal"
        case .warning:
            "Warning"
        case .critical:
            "Critical"
        }
    }

    var notificationName: String {
        switch self {
        case .normal:
            "status"
        case .warning:
            "Warning"
        case .critical:
            "Critical Alert"
        }
    }

    var idComponent: String {
        switch self {
        case .normal:
            "normal"
        case .warning:
            "warning"
        case .critical:
            "critical"
        }
    }
}
