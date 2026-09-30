/// Data selected for a dashboard tile, before SwiftUI renders it.
/// Missing values and invalid indexes remain empty; reported values are never clamped.
enum ProviderMetricTileContent: Equatable, Sendable {
    case usageBar(UsageBar)
    case unavailableUsage(String)
    case creditsRemaining(value: Double, supportingDetail: String?)
    case monetary(ProviderMonetaryMetric, supportingDetail: String?)
    case empty

    static func resolve(
        metric: ProviderUsageMetric,
        result: ProviderUsageResult,
        isFullWidth: Bool
    ) -> Self {
        switch metric.kind {
        case let .usageBar(index):
            return resolveUsageBar(index: index, result: result)
        case let .unavailableUsage(reason):
            return .unavailableUsage(reason)
        case .creditsRemaining:
            return resolveCredits(result: result, isFullWidth: isFullWidth)
        case let .monetary(index):
            return resolveMonetary(index: index, result: result, isFullWidth: isFullWidth)
        }
    }

    private static func resolveUsageBar(index: Int, result: ProviderUsageResult) -> Self {
        guard result.bars.indices.contains(index) else { return .empty }
        return .usageBar(result.bars[index])
    }

    private static func resolveCredits(result: ProviderUsageResult, isFullWidth: Bool) -> Self {
        guard let value = result.creditsRemaining else { return .empty }
        let detail = isFullWidth
            ? (result.hasCurrentCredits ? "Current balance" : "Last known balance")
            : nil
        return .creditsRemaining(value: value, supportingDetail: detail)
    }

    private static func resolveMonetary(index: Int, result: ProviderUsageResult, isFullWidth: Bool) -> Self {
        guard result.monetaryMetrics.indices.contains(index) else { return .empty }
        let metric = result.monetaryMetrics[index]
        return .monetary(metric, supportingDetail: isFullWidth ? metric.detail : nil)
    }
}
