import Foundation

public struct DemoUsageProvider: UsageProvider {
    public let providerID: ProviderID
    public let plan: ProviderPlanDescriptor?
    public let bars: [UsageBar]
    public let creditsRemaining: Double?
    public let monetaryMetrics: [ProviderMonetaryMetric]
    public let usageMessages: [String]
    public let dashboardUsageMessages: [String]?
    public let cardInformationSections: [ProviderCardInformationSection]
    public let subtitle: String

    public init(
        providerID: ProviderID,
        plan: ProviderPlanDescriptor? = nil,
        bars: [UsageBar],
        creditsRemaining: Double? = nil,
        monetaryMetrics: [ProviderMonetaryMetric] = [],
        usageMessages: [String] = [],
        dashboardUsageMessages: [String]? = nil,
        cardInformationSections: [ProviderCardInformationSection] = [],
        subtitle: String = "Ready to refresh"
    ) {
        self.providerID = providerID
        self.plan = plan
        self.bars = bars
        self.creditsRemaining = creditsRemaining
        self.monetaryMetrics = monetaryMetrics
        self.usageMessages = usageMessages
        self.dashboardUsageMessages = dashboardUsageMessages
        self.cardInformationSections = cardInformationSections
        self.subtitle = subtitle
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: providerID,
            title: providerID == .openCodeZen
                ? configuration.openCodeDisplayName(
                    hasGoUsage: !bars.isEmpty,
                    hasZenBalance: creditsRemaining != nil
                )
                : configuration.displayName,
            plan: plan,
            subtitle: subtitle,
            bars: bars,
            creditsRemaining: creditsRemaining,
            monetaryMetrics: monetaryMetrics,
            usageMessages: usageMessages,
            dashboardUsageMessages: dashboardUsageMessages,
            cardInformationSections: cardInformationSections,
            fetchedAt: Date()
        )
    }
}

public extension DemoUsageProvider {
    static var samples: [DemoUsageProvider] {
        [
            DemoUsageProvider(
                providerID: .codex,
                plan: ProviderPlanDescriptor(
                    identifier: "codex.pro",
                    displayLabel: "PRO",
                    accessibilityLabel: "Pro"
                ),
                bars: [
                    UsageBar(
                        stableKey: "window-18000",
                        label: "5-hour usage limit",
                        used: 42,
                        limit: 100,
                        resetDescription: "Resets in 2h 15m",
                        projectionDescriptionOverride: "Projected to stay under limit",
                        projectionSignificanceOverride: .benign
                    ),
                    UsageBar(
                        stableKey: "window-604800",
                        label: "Weekly usage limit",
                        used: 68,
                        limit: 100,
                        resetDescription: "Resets Monday at 12:00 AM"
                    ),
                ],
                subtitle: "Personal account - live usage enabled"
            ),
            DemoUsageProvider(
                providerID: .copilot,
                plan: ProviderPlanDescriptor(
                    identifier: "copilot.business",
                    displayLabel: "BUSINESS",
                    accessibilityLabel: "Business"
                ),
                bars: [
                    UsageBar(
                        stableKey: "premium-interactions",
                        label: "Premium requests",
                        used: 73,
                        limit: 100,
                        resetDescription: "Resets in 9 days",
                        projectionDescriptionOverride: "Projected to stay under limit",
                        projectionSignificanceOverride: .benign
                    ),
                ],
                subtitle: "Engineering organization"
            ),
            DemoUsageProvider(
                providerID: .claude,
                plan: ProviderPlanDescriptor(
                    identifier: "claude.max20",
                    displayLabel: "MAX 20×",
                    accessibilityLabel: "Max 20x"
                ),
                bars: [
                    UsageBar(
                        stableKey: "session",
                        label: "Current session",
                        used: 36,
                        limit: 100,
                        resetDescription: "Resets in 1h 40m"
                    ),
                    UsageBar(
                        stableKey: ClaudeUsageIdentity.allModelsWeeklyStableKey,
                        label: "All models",
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
                    ),
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
                dashboardUsageMessages: [],
                cardInformationSections: [
                    ProviderCardInformationSection(
                        id: "claude.limit-details",
                        title: "Limit details",
                        items: [
                            ProviderCardInformationItem(
                                id: "claude.limit.weekly-scoped-fable",
                                label: "Fable weekly limit",
                                detail: "Counts toward the all-model weekly allowance"
                            ),
                        ]
                    ),
                    ProviderCardInformationSection(
                        id: "claude.account-details",
                        title: "Account details",
                        items: [
                            ProviderCardInformationItem(
                                id: "claude.usage-credits",
                                label: "Usage credits",
                                detail: "Enabled"
                            ),
                            ProviderCardInformationItem(
                                id: "claude.auto-reload",
                                label: "Auto-reload",
                                detail: "Off"
                            ),
                        ]
                    ),
                ],
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
                bars: [
                    UsageBar(
                        stableKey: "go.rolling-5-hour",
                        label: "5-hour usage limit",
                        used: 44,
                        limit: 100,
                        resetDescription: "Resets in 2h 10m",
                        projectionDescriptionOverride: "Projected to stay under limit",
                        projectionSignificanceOverride: .benign
                    ),
                    UsageBar(
                        stableKey: "go.weekly",
                        label: "Weekly usage limit",
                        used: 31,
                        limit: 100,
                        resetDescription: "Resets Monday"
                    ),
                    UsageBar(
                        stableKey: "go.monthly",
                        label: "Monthly usage limit",
                        used: 24,
                        limit: 100,
                        resetDescription: "Resets Aug 1"
                    ),
                ],
                creditsRemaining: 12.48,
                subtitle: "Go usage and Zen credit balance"
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
                        resetDescription: "Resets Aug 1",
                        projectionDescriptionOverride: "Projected to stay under limit",
                        projectionSignificanceOverride: .benign
                    ),
                ],
                cardInformationSections: [
                    ProviderCardInformationSection(
                        id: "cursor.included-usage",
                        title: "Included usage",
                        items: [
                            ProviderCardInformationItem(
                                id: "cursor.included-usage.auto",
                                label: "Auto",
                                detail: "34%"
                            ),
                            ProviderCardInformationItem(
                                id: "cursor.included-usage.api",
                                label: "API",
                                detail: "17%"
                            ),
                        ]
                    ),
                ],
                subtitle: "Cursor plan usage"
            ),
            DemoUsageProvider(
                providerID: .greptile,
                bars: [
                    UsageBar(
                        stableKey: GreptileUsageIdentity.completedReviewsStableKey,
                        label: "Completed reviews",
                        used: 84,
                        limit: 0,
                        fractionlessUsageText: "84"
                    ),
                ],
                usageMessages: [
                    "Greptile's API does not currently expose billing-credit usage.",
                ],
                cardInformationSections: [
                    ProviderCardInformationSection(
                        id: "greptile.review-statuses",
                        title: "Review statuses",
                        items: [
                            ProviderCardInformationItem(
                                id: "greptile.status.completed",
                                label: "Completed",
                                detail: "84"
                            ),
                            ProviderCardInformationItem(
                                id: "greptile.status.skipped",
                                label: "Skipped",
                                detail: "3"
                            ),
                        ]
                    ),
                ],
                subtitle: "All available review history"
            ),
        ]
    }
}
