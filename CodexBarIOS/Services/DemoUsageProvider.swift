import Foundation

public struct DemoUsageProvider: UsageProvider {
    public let providerID: ProviderID
    public let bars: [UsageBar]

    public init(providerID: ProviderID, bars: [UsageBar]) {
        self.providerID = providerID
        self.bars = bars
    }

    public func fetchUsage() async throws -> ProviderUsageResult {
        ProviderUsageResult(
            providerID: providerID,
            title: providerID.displayName,
            subtitle: "Demo usage until provider auth is implemented",
            bars: bars,
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
                bars: [
                    UsageBar(label: "Credits", used: 81, limit: 100)
                ]
            )
        ]
    }
}
