import Foundation

public struct DemoUsageProvider: UsageProvider {
    public let providerID: ProviderID
    public let bars: [UsageBar]
    public let creditsRemaining: Double?
    public let monetaryMetrics: [ProviderMonetaryMetric]
    public let usageMessages: [String]
    public let subtitle: String

    public init(
        providerID: ProviderID,
        bars: [UsageBar],
        creditsRemaining: Double? = nil,
        monetaryMetrics: [ProviderMonetaryMetric] = [],
        usageMessages: [String] = [],
        subtitle: String = "Ready to refresh"
    ) {
        self.providerID = providerID
        self.bars = bars
        self.creditsRemaining = creditsRemaining
        self.monetaryMetrics = monetaryMetrics
        self.usageMessages = usageMessages
        self.subtitle = subtitle
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: providerID,
            title: configuration.displayName,
            subtitle: subtitle,
            bars: bars,
            creditsRemaining: creditsRemaining,
            monetaryMetrics: monetaryMetrics,
            usageMessages: usageMessages,
            fetchedAt: Date()
        )
    }
}

public extension DemoUsageProvider {
    static var samples: [DemoUsageProvider] {
        [
            DemoUsageProvider(
                providerID: .codex,
                bars: [
                    UsageBar(
                        stableKey: "window-18000",
                        label: "5-hour usage limit",
                        used: 42,
                        limit: 100,
                        resetDescription: "Resets in 2h 15m",
                        projectionDescriptionOverride: "Projected to stay under limit"
                    ),
                    UsageBar(
                        stableKey: "window-604800",
                        label: "Weekly usage limit",
                        used: 68,
                        limit: 100,
                        resetDescription: "Resets Monday at 12:00 AM"
                    )
                ],
                subtitle: "Personal account - live usage enabled"
            ),
            DemoUsageProvider(
                providerID: .copilot,
                bars: [
                    UsageBar(
                        stableKey: "premium-interactions",
                        label: "Premium requests",
                        used: 73,
                        limit: 100,
                        resetDescription: "Resets in 9 days"
                    )
                ],
                subtitle: "Engineering organization"
            ),
            DemoUsageProvider(
                providerID: .claude,
                bars: [
                    UsageBar(
                        stableKey: "session",
                        label: "5-hour usage limit",
                        used: 36,
                        limit: 100,
                        resetDescription: "Resets in 1h 40m"
                    ),
                    UsageBar(
                        stableKey: ClaudeUsageIdentity.allModelsWeeklyStableKey,
                        label: "All models weekly usage limit",
                        used: 58,
                        limit: 100,
                        resetDescription: "Resets Monday"
                    ),
                    UsageBar(
                        stableKey: "weekly-scoped-fable",
                        label: "Fable weekly usage limit",
                        used: 71,
                        limit: 100,
                        resetDescription: "Resets Monday"
                    )
                ],
                monetaryMetrics: [
                    ProviderMonetaryMetric(
                        kind: .spent,
                        label: "Usage credits spent",
                        minorUnits: 1250,
                        currencyCode: "USD",
                        decimalPlaces: 2,
                        detail: "Month to date"
                    ),
                    ProviderMonetaryMetric(
                        kind: .remainingHeadroom,
                        label: "Remaining spend headroom",
                        minorUnits: 3750,
                        currencyCode: "USD",
                        decimalPlaces: 2,
                        detail: "Not a prepaid balance"
                    ),
                ],
                usageMessages: ["Fable usage is capped within the all-model weekly allowance."],
                subtitle: "Browser session connected"
            ),
            DemoUsageProvider(
                providerID: .openRouter,
                bars: [],
                creditsRemaining: 18.72,
                subtitle: "API balance"
            ),
            DemoUsageProvider(
                providerID: .openCodeZen,
                bars: [],
                creditsRemaining: 12.48,
                subtitle: "Workspace balance"
            ),
            DemoUsageProvider(
                providerID: .moonshot,
                bars: [],
                creditsRemaining: 24.15,
                subtitle: "API balance"
            ),
            DemoUsageProvider(
                providerID: .cursor,
                bars: [
                    UsageBar(
                        stableKey: "total",
                        label: "Monthly included usage",
                        used: 51,
                        limit: 100,
                        resetDescription: "Resets Aug 1"
                    )
                ],
                subtitle: "Cursor account connected"
            )
        ]
    }
}
