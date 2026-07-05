import Foundation

public struct UsageAlertNotification: Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
}

public struct UsageAlertEvaluation: Equatable, Sendable {
    public let notifications: [UsageAlertNotification]
    public let activeAlertIDs: Set<String>
}

public enum UsageAlertEvaluator {
    public static func evaluate(
        results: [ProviderUsageResult],
        settings: UsageAlertSettings,
        activeAlertIDs: Set<String>
    ) -> UsageAlertEvaluation {
        guard settings.isEnabled else {
            return UsageAlertEvaluation(notifications: [], activeAlertIDs: [])
        }

        var nextActiveAlertIDs = Set<String>()
        var notifications: [UsageAlertNotification] = []

        for result in results {
            for bar in result.bars where bar.fractionUsed >= settings.usageThreshold {
                let alertID = alertID(for: result, bar: bar)
                let hasAlreadyQueuedAlert = nextActiveAlertIDs.contains(alertID)
                nextActiveAlertIDs.insert(alertID)

                guard !activeAlertIDs.contains(alertID),
                      !hasAlreadyQueuedAlert
                else {
                    continue
                }

                notifications.append(
                    UsageAlertNotification(
                        id: alertID,
                        title: "\(result.title) \(bar.label)",
                        body: "\(bar.usageText) used. Threshold \(formatPercent(settings.usageThreshold)) reached."
                    )
                )
            }

            if let creditsRemaining = result.creditsRemaining,
               creditsRemaining <= settings.balanceThreshold
            {
                let alertID = "balance.\(result.accountID)"
                nextActiveAlertIDs.insert(alertID)

                if !activeAlertIDs.contains(alertID) {
                    notifications.append(
                        UsageAlertNotification(
                            id: alertID,
                            title: "\(result.title) Balance",
                            body: "\(formatCurrency(creditsRemaining)) remaining. Threshold \(formatCurrency(settings.balanceThreshold)) reached."
                        )
                    )
                }
            }

            if settings.includesSeverityAlerts,
               result.highestSeverity >= .warning
            {
                let alertID = "severity.\(result.accountID)"
                nextActiveAlertIDs.insert(alertID)

                if !activeAlertIDs.contains(alertID) {
                    notifications.append(
                        UsageAlertNotification(
                            id: alertID,
                            title: "\(result.title) \(result.highestSeverity.displayName)",
                            body: result.subtitle
                        )
                    )
                }
            }
        }

        return UsageAlertEvaluation(
            notifications: notifications,
            activeAlertIDs: nextActiveAlertIDs
        )
    }

    private static func alertID(for result: ProviderUsageResult, bar: UsageBar) -> String {
        "usage.\(result.accountID).\(stableUsageKey(for: bar))"
    }

    private static func stableUsageKey(for bar: UsageBar) -> String {
        let withoutParentheticalValues = bar.label
            .replacingOccurrences(of: #"\([^)]*\)"#, with: "", options: .regularExpression)
        let withoutRatios = withoutParentheticalValues
            .replacingOccurrences(
                of: #"\$?\d[\d,]*(?:\.\d+)?\s*/\s*\$?\d[\d,]*(?:\.\d+)?"#,
                with: "",
                options: .regularExpression
            )
        let withoutStandaloneNumbers = withoutRatios
            .replacingOccurrences(
                of: #"\$?\d[\d,]*(?:\.\d+)?"#,
                with: "",
                options: .regularExpression
            )

        let normalized = normalizedKeyComponent(withoutStandaloneNumbers)
        if !normalized.isEmpty {
            return normalized
        }

        return normalizedKeyComponent(bar.label)
    }

    private static func normalizedKeyComponent(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
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
}
