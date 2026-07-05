import Foundation
import WidgetKit

@MainActor
enum WidgetSnapshotPublisher {
    static func publish(
        results: [ProviderUsageResult],
        configurationStore: ProviderConfigurationStore,
        snapshotDefaults: UserDefaults? = WidgetSnapshotStore.userDefaults()
    ) {
        let now = Date()
        let displayable = orderedDisplayableResults(
            results: results,
            configurationStore: configurationStore
        )

        let snapshot = CodexBarWidgetSnapshot(
            generatedAt: now,
            results: displayable.map { result in
                let configuration = configurationStore.configuration(accountID: result.accountID)
                return CodexBarWidgetProviderSnapshot(
                    accountID: result.accountID,
                    providerID: result.providerID.rawValue,
                    title: result.title,
                    subtitle: statusText(for: result, configurationStore: configurationStore),
                    groupID: configuration?.groupID,
                    groupName: configurationStore.group(for: configuration?.groupID)?.name,
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

        WidgetSnapshotStore.saveSnapshot(snapshot, defaults: snapshotDefaults)
        WidgetSnapshotStore.saveRefreshInterval(configurationStore.widgetRefreshInterval, defaults: snapshotDefaults)
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

        return DashboardUsageSorter.orderedResults(
            displayable,
            mode: configurationStore.dashboardOrderingMode,
            manualOrder: configurationStore.dashboardCardOrder
        )
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
