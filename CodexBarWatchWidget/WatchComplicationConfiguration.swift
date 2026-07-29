import AppIntents
import Foundation
import WidgetKit

struct WatchComplicationEntry: TimelineEntry {
    let date: Date
    let sample: WatchComplicationSample
    let configuration: WatchComplicationConfigurationIntent
}

struct WatchComplicationTimelineLoader {
    private let resolver: WatchComplicationResolver
    private let now: () -> Date
    private let loadSnapshot: () -> WatchDashboardSnapshot?

    init(
        resolver: WatchComplicationResolver = WatchComplicationResolver(),
        now: @escaping () -> Date = { Date() },
        loadSnapshot: @escaping () -> WatchDashboardSnapshot? = {
            WatchComplicationSnapshotStore().load()
        }
    ) {
        self.resolver = resolver
        self.now = now
        self.loadSnapshot = loadSnapshot
    }

    func entry(
        configuration: WatchComplicationConfigurationIntent,
        date: Date? = nil
    ) -> WatchComplicationEntry {
        let entryDate = date ?? now()
        return WatchComplicationEntry(
            date: entryDate,
            sample: resolver.resolve(
                snapshot: loadSnapshot(),
                selection: configuration.selection,
                at: entryDate
            ),
            configuration: configuration
        )
    }

    func timeline(
        configuration: WatchComplicationConfigurationIntent
    ) -> Timeline<WatchComplicationEntry> {
        let date = now()
        let snapshot = loadSnapshot()
        let entry = WatchComplicationEntry(
            date: date,
            sample: resolver.resolve(
                snapshot: snapshot,
                selection: configuration.selection,
                at: date
            ),
            configuration: configuration
        )
        let nextReload = resolver.nextReloadDate(
            snapshot: snapshot,
            selection: configuration.selection,
            now: date
        )
        return Timeline(entries: [entry], policy: .after(nextReload))
    }
}

struct WatchComplicationTimelineProvider: AppIntentTimelineProvider {
    private let loader = WatchComplicationTimelineLoader()

    func recommendations() -> [AppIntentRecommendation<WatchComplicationConfigurationIntent>] {
        []
    }

    func placeholder(in context: Context) -> WatchComplicationEntry {
        WatchComplicationEntry(
            date: Date(),
            sample: .preview,
            configuration: WatchComplicationConfigurationIntent()
        )
    }

    func snapshot(
        for configuration: WatchComplicationConfigurationIntent,
        in context: Context
    ) async -> WatchComplicationEntry {
        if context.isPreview {
            return WatchComplicationEntry(
                date: Date(),
                sample: .preview,
                configuration: configuration
            )
        }
        return loader.entry(configuration: configuration)
    }

    func timeline(
        for configuration: WatchComplicationConfigurationIntent,
        in context: Context
    ) async -> Timeline<WatchComplicationEntry> {
        loader.timeline(configuration: configuration)
    }
}

struct WatchComplicationConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "CodexBar Usage"
    static let description = IntentDescription(
        "Choose the provider account and usage metric shown by this complication."
    )

    @Parameter(title: "Provider Account")
    var account: WatchComplicationAccountEntity?

    @Parameter(title: "Metric")
    var metric: WatchComplicationMetricEntity?

    var selection: WatchComplicationSelection {
        WatchComplicationSelection(
            accountID: account?.id,
            metricID: metric.flatMap { selectedMetric in
                selectedMetric.accountID == account?.id || account == nil
                    ? selectedMetric.metricID
                    : nil
            }
        )
    }
}

struct WatchComplicationAccountEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Provider Account")
    static let defaultQuery = WatchComplicationAccountQuery()

    let id: String
    let providerName: String
    let accountLabel: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(providerName)",
            subtitle: "\(accountLabel)"
        )
    }
}

struct WatchComplicationAccountQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WatchComplicationAccountEntity] {
        accountEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [WatchComplicationAccountEntity] {
        accountEntities()
    }

    private func accountEntities() -> [WatchComplicationAccountEntity] {
        (WatchComplicationSnapshotStore().load()?.accounts ?? [])
            .filter { !$0.metrics.isEmpty }
            .map {
                WatchComplicationAccountEntity(
                    id: $0.id,
                    providerName: $0.providerName,
                    accountLabel: $0.accountLabel
                )
            }
    }
}

struct WatchComplicationMetricEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Usage Metric")
    static let defaultQuery = WatchComplicationMetricQuery()

    let id: String
    let accountID: String
    let metricID: String
    let providerName: String
    let metricLabel: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(metricLabel)",
            subtitle: "\(providerName)"
        )
    }
}

struct WatchComplicationMetricQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [WatchComplicationMetricEntity] {
        metricEntities().filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [WatchComplicationMetricEntity] {
        metricEntities()
    }

    private func metricEntities() -> [WatchComplicationMetricEntity] {
        (WatchComplicationSnapshotStore().load()?.accounts ?? []).flatMap { account in
            account.metrics.map { metric in
                WatchComplicationMetricEntity(
                    id: "\(account.id)::\(metric.id)",
                    accountID: account.id,
                    metricID: metric.id,
                    providerName: account.providerName,
                    metricLabel: metric.label
                )
            }
        }
    }
}

private extension WatchComplicationSample {
    static let preview = WatchComplicationSample(
        availability: .value,
        providerName: "Codex",
        accountLabel: "Primary",
        metricLabel: "5-hour limit",
        exactValue: "72%",
        usedFraction: 0.72,
        severity: .warning,
        resetText: "Resets in 2h",
        freshnessText: "Updated now",
        isStale: false
    )
}
