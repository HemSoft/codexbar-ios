import Foundation

struct WatchUsageSample: Equatable, Identifiable, Sendable {
    let id: String
    let providerName: String
    let accountLabel: String
    let metricLabel: String
    let exactValue: String
    let usedFraction: Double?
    let severity: WatchMetricSeverity
    let resetText: String?
    let visualizationStyle: WatchMetricVisualizationStyle
    let freshnessText: String

    var clampedUsedFraction: Double {
        min(max(usedFraction ?? 0, 0), 1)
    }

    var percentageText: String {
        usedFraction.map { "\(Int((min(max($0, 0), 1) * 100).rounded()))%" } ?? exactValue
    }

    var severityText: String? {
        switch severity {
        case .normal:
            nil
        case .warning:
            "Warning"
        case .critical:
            "Critical"
        }
    }

    var accessibilitySummary: String {
        [
            providerName,
            accountLabel,
            metricLabel,
            exactValue,
            severityText,
            resetText,
            freshnessText,
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
    }
}

struct WatchDashboardState: Equatable, Sendable {
    let title: String
    let statusText: String
    let samples: [WatchUsageSample]

    static let empty = WatchDashboardState(
        title: "CodexBar",
        statusText: "Open CodexBar on iPhone",
        samples: []
    )

    init(
        snapshot: WatchDashboardSnapshot?,
        now: Date,
        isPhoneReachable: Bool,
        decodingError: String?
    ) {
        title = "CodexBar"
        guard let snapshot else {
            statusText = decodingError ?? "Open CodexBar on iPhone"
            samples = []
            return
        }

        let displayedAccounts = snapshot.accounts.filter { !$0.metrics.isEmpty }
        let oldestDisplayedFetch = displayedAccounts.map(\.fetchedAt).min() ?? snapshot.generatedAt
        let freshnessText = Self.lastUpdatedText(oldestDisplayedFetch, now: now)
        if let decodingError {
            statusText = "\(decodingError). Showing \(freshnessText.lowercased())"
        } else if displayedAccounts.isEmpty {
            statusText = "No dashboard metrics on iPhone"
        } else if snapshot.isStale(dataDate: oldestDisplayedFetch, at: now) {
            statusText = "\(freshnessText) • Stale"
        } else if !isPhoneReachable {
            statusText = "\(freshnessText) • iPhone unavailable"
        } else {
            statusText = freshnessText
        }

        samples = snapshot.accounts.flatMap { account in
            let accountFreshnessText = Self.lastUpdatedText(account.fetchedAt, now: now)
            return account.metrics.map { metric in
                WatchUsageSample(
                    id: "\(account.id).\(metric.id)",
                    providerName: account.providerName,
                    accountLabel: account.accountLabel,
                    metricLabel: metric.label,
                    exactValue: metric.exactValue,
                    usedFraction: metric.usedFraction,
                    severity: metric.severity,
                    resetText: metric.resetText,
                    visualizationStyle: metric.visualizationStyle,
                    freshnessText: accountFreshnessText
                )
            }
        }
    }

    init(title: String, statusText: String, samples: [WatchUsageSample]) {
        self.title = title
        self.statusText = statusText
        self.samples = samples
    }

    private static func lastUpdatedText(_ generatedAt: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(generatedAt)))
        if seconds < 60 {
            return "Updated just now"
        }
        if seconds < 3_600 {
            return "Updated \(seconds / 60)m ago"
        }
        if seconds < 86_400 {
            return "Updated \(seconds / 3_600)h ago"
        }
        return "Updated \(seconds / 86_400)d ago"
    }

    static let sample = WatchDashboardState(
        title: "CodexBar",
        statusText: "Sample data",
        samples: [
            WatchUsageSample(
                id: "codex-primary",
                providerName: "Codex",
                accountLabel: "Primary",
                metricLabel: "5-hour limit",
                exactValue: "72%",
                usedFraction: 0.72,
                severity: .warning,
                resetText: "Resets in 2h",
                visualizationStyle: .circularRing,
                freshnessText: "Updated just now"
            ),
            WatchUsageSample(
                id: "copilot-work",
                providerName: "Copilot",
                accountLabel: "Work",
                metricLabel: "Premium requests",
                exactValue: "38%",
                usedFraction: 0.38,
                severity: .normal,
                resetText: nil,
                visualizationStyle: .segmentedBar,
                freshnessText: "Updated just now"
            ),
        ]
    )
}
