import Foundation

public struct ProviderUsageResult: Identifiable, Equatable, Sendable {
    public let providerID: ProviderID
    public let title: String
    public let subtitle: String
    public let bars: [UsageBar]
    public let fetchedAt: Date

    public init(providerID: ProviderID, title: String, subtitle: String, bars: [UsageBar], fetchedAt: Date) {
        self.providerID = providerID
        self.title = title
        self.subtitle = subtitle
        self.bars = bars
        self.fetchedAt = fetchedAt
    }

    public var id: ProviderID {
        providerID
    }

    public var highestSeverity: UsageSeverity {
        bars.map(\.severity).max() ?? .normal
    }
}
