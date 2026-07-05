import Foundation
import WidgetKit

@MainActor
enum WidgetSnapshotPublisher {
    static func publish(
        results: [ProviderUsageResult],
        configurationStore: ProviderConfigurationStore
    ) {
        let now = Date()
        let displayable = orderedDisplayableResults(
            results: results,
            configurationStore: configurationStore
        )

        let snapshot = CodexBarWidgetSnapshot(
            generatedAt: now,
            results: displayable.map { result in
                CodexBarWidgetProviderSnapshot(
                    accountID: result.accountID,
                    providerID: result.providerID.rawValue,
                    title: result.title,
                    subtitle: statusText(for: result, configurationStore: configurationStore),
                    bars: result.bars.enumerated().map { index, bar in
                        let projectedFraction = bar.projectedFraction(at: now)
                        let projectedSeverity = bar.projectedSeverity(at: now)
                        return CodexBarWidgetUsageBarSnapshot(
                            id: stableBarID(accountID: result.accountID, bar: bar, index: index),
                            label: bar.label,
                            fractionUsed: bar.fractionUsed,
                            usageText: bar.usageText,
                            resetDescription: bar.resetDescription,
                            severity: CodexBarWidgetSeverity(bar.severity),
                            projectedFraction: projectedFraction,
                            projectionDescription: bar.projectionDescription(at: now),
                            projectedSeverity: projectedSeverity.map(CodexBarWidgetSeverity.init)
                        )
                    },
                    creditsRemaining: result.creditsRemaining,
                    fetchedAt: result.fetchedAt,
                    severity: CodexBarWidgetSeverity(result.highestSeverity(at: now))
                )
            }
        )

        WidgetSnapshotStore.saveSnapshot(snapshot)
        WidgetSnapshotStore.saveRefreshInterval(configurationStore.widgetRefreshInterval)
        WidgetCenter.shared.reloadTimelines(ofKind: CodexBarWidgetConstants.widgetKind)
    }

    static func publishSettings(configurationStore: ProviderConfigurationStore) {
        WidgetSnapshotStore.saveRefreshInterval(configurationStore.widgetRefreshInterval)
        WidgetCenter.shared.reloadTimelines(ofKind: CodexBarWidgetConstants.widgetKind)
    }

    private static func orderedDisplayableResults(
        results: [ProviderUsageResult],
        configurationStore: ProviderConfigurationStore
    ) -> [ProviderUsageResult] {
        let displayable = results.filter { result in
            configurationStore.configuration(accountID: result.accountID)
                .map(configurationStore.shouldDisplayOnDashboard) ?? false
        }
        let order = Dictionary(
            uniqueKeysWithValues: configurationStore.dashboardCardOrder.enumerated().map { index, accountID in
                (accountID, index)
            }
        )

        return displayable.enumerated()
            .sorted { lhs, rhs in
                let lhsOrder = order[lhs.element.id] ?? Int.max
                let rhsOrder = order[rhs.element.id] ?? Int.max
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }

                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private static func statusText(
        for result: ProviderUsageResult,
        configurationStore: ProviderConfigurationStore
    ) -> String {
        guard let configuration = configurationStore.configuration(accountID: result.accountID) else {
            return result.subtitle
        }

        if configurationStore.isConfigured(configuration) {
            if result.subtitle.localizedCaseInsensitiveContains("not configured") {
                return configurationStore.statusText(for: configuration)
            }

            return result.subtitle
        }

        return configurationStore.statusText(for: configuration)
    }

    private static func stableBarID(accountID: String, bar: UsageBar, index: Int) -> String {
        let normalizedLabel = bar.label
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")

        return "\(accountID).\(index).\(normalizedLabel)"
    }
}

private extension CodexBarWidgetSeverity {
    init(_ severity: UsageSeverity) {
        switch severity {
        case .normal:
            self = .normal
        case .warning:
            self = .warning
        case .critical:
            self = .critical
        }
    }
}
