#if DEBUG
import Foundation

enum AppStoreScreenshotScene: String {
    case dashboardOverview = "dashboard-overview"
    case dashboardDark = "dashboard-dark"
    case widgetBuilder = "widget-builder"
    case accounts
    case providerCopilot = "provider-copilot"
    case history
}

struct AppStoreScreenshotConfiguration {
    static let readyFileName = "app-store-screenshot-ready"

    let scene: AppStoreScreenshotScene
    let appearance: AppAppearance

    static var current: AppStoreScreenshotConfiguration? {
        parse(
            arguments: ProcessInfo.processInfo.arguments,
            environment: ProcessInfo.processInfo.environment
        )
    }

    static func parse(
        arguments: [String],
        environment: [String: String] = [:]
    ) -> AppStoreScreenshotConfiguration? {
        guard arguments.contains("--app-store-screenshots")
            || environment["CODEXBAR_APP_STORE_SCREENSHOTS"] == "1"
        else {
            return nil
        }

        let scene = value(after: "--app-store-scene", in: arguments)
            .flatMap(AppStoreScreenshotScene.init(rawValue:))
            ?? .dashboardOverview
        let appearance = value(after: "--app-store-appearance", in: arguments)
            .flatMap(AppAppearance.init(rawValue:))
            ?? .light

        return AppStoreScreenshotConfiguration(scene: scene, appearance: appearance)
    }

    private static func value(after argument: String, in arguments: [String]) -> String? {
        guard
            let index = arguments.firstIndex(of: argument),
            arguments.indices.contains(index + 1)
        else {
            return nil
        }

        return arguments[index + 1]
    }
}

@MainActor
enum AppStoreScreenshotFixtures {
    static func results(for configurationStore: ProviderConfigurationStore) -> [ProviderUsageResult] {
        let samples = Dictionary(uniqueKeysWithValues: DemoUsageProvider.samples.map { ($0.providerID, $0) })
        let capturedAt = Date(timeIntervalSince1970: 1_783_680_000)

        return configurationStore.configurations.compactMap { configuration in
            guard let sample = samples[configuration.providerID] else {
                return nil
            }

            return ProviderUsageResult(
                accountID: configuration.id,
                providerID: sample.providerID,
                title: configuration.displayName,
                subtitle: sample.subtitle,
                bars: sample.bars,
                creditsRemaining: sample.creditsRemaining,
                fetchedAt: capturedAt
            )
        }
    }

    static func historyStore(for results: [ProviderUsageResult]) -> UsageHistoryStore {
        let suiteName = "com.hemsoft.CodexBarIOS.appStoreScreenshotHistory"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)

        let store = UsageHistoryStore(defaults: defaults)
        guard let result = results.first(where: { $0.providerID == .codex }) else {
            return store
        }

        let fractions = [0.22, 0.29, 0.35, 0.41, 0.48, 0.56, 0.63, 0.68]
        let latestDate = Date(timeIntervalSince1970: 1_783_680_000)
        for (index, fraction) in fractions.enumerated() {
            let capturedAt = latestDate.addingTimeInterval(TimeInterval(index - fractions.count + 1) * 24 * 60 * 60)
            let bars = result.bars.enumerated().map { barIndex, bar in
                let adjustedFraction = min(fraction + (barIndex == 0 ? 0 : 0.08), 0.92)
                return UsageBar(
                    label: bar.label,
                    used: bar.limit * adjustedFraction,
                    limit: bar.limit,
                    resetDescription: bar.resetDescription,
                    projectionDescriptionOverride: bar.projectionDescriptionOverride
                )
            }
            let historicalResult = ProviderUsageResult(
                accountID: result.accountID,
                providerID: result.providerID,
                title: result.title,
                subtitle: result.subtitle,
                bars: bars,
                fetchedAt: capturedAt
            )
            store.record(results: [historicalResult], now: latestDate)
        }

        return store
    }

    static func seedWidgetPreview(
        results: [ProviderUsageResult],
        configurationStore: ProviderConfigurationStore
    ) {
        guard let defaults = WidgetSnapshotStore.userDefaults() else {
            return
        }

        defaults.removePersistentDomain(forName: CodexBarWidgetConstants.appGroupIdentifier)
        WidgetSnapshotPublisher.publish(
            results: results,
            configurationStore: configurationStore,
            snapshotDefaults: defaults
        )
        WidgetSnapshotStore.saveBuilderConfiguration(
            CodexBarWidgetBuilderConfiguration(
                layout: .fourTiles,
                selectedTileIDs: [
                    "provider.app-store-screenshots.codex",
                    "provider.app-store-screenshots.copilot",
                    "provider.app-store-screenshots.openrouter",
                    "provider.app-store-screenshots.opencodzen",
                ],
                displayModes: [.fullBar, .compactPercent, .balanceOnly, .balanceOnly]
            ),
            defaults: defaults
        )
    }

    static func markReady(scene: AppStoreScreenshotScene) {
        guard let cachesDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first else {
            return
        }

        let readyFile = cachesDirectory.appendingPathComponent(
            AppStoreScreenshotConfiguration.readyFileName
        )
        try? Data(scene.rawValue.utf8).write(to: readyFile, options: .atomic)
    }
}
#endif
