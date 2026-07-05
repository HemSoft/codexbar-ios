import Foundation

public struct DemoUsageProvider: UsageProvider {
    public let providerID: ProviderID
    public let bars: [UsageBar]
    public let creditsRemaining: Double?

    public init(providerID: ProviderID, bars: [UsageBar], creditsRemaining: Double? = nil) {
        self.providerID = providerID
        self.bars = bars
        self.creditsRemaining = creditsRemaining
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: providerID,
            title: configuration.displayName,
            subtitle: "Demo usage until provider auth is implemented",
            bars: bars,
            creditsRemaining: creditsRemaining,
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
                    UsageBar(label: "5-hour", used: 42, limit: 100),
                    UsageBar(label: "Weekly", used: 68, limit: 100)
                ]
            ),
            DemoUsageProvider(
                providerID: .copilot,
                bars: [
                    UsageBar(label: "Premium requests", used: 73, limit: 100)
                ]
            ),
            DemoUsageProvider(
                providerID: .openRouter,
                bars: [],
                creditsRemaining: 18.72
            ),
            DemoUsageProvider(
                providerID: .openCodeZen,
                bars: [],
                creditsRemaining: 12.48
            )
        ]
    }
}
