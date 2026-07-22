import Combine
import Foundation

struct CodexBankedResetRedemptionFeedback: Equatable, Sendable {
    let message: String
    let isSuccess: Bool
    let hidesAction: Bool

    init(message: String, isSuccess: Bool, hidesAction: Bool = false) {
        self.message = message
        self.isSuccess = isSuccess
        self.hidesAction = hidesAction
    }
}

@MainActor
final class DashboardOrchestrator: ObservableObject {
    @Published private(set) var autoRefreshSchedule: AutoRefreshSchedule?
    @Published private(set) var autoRefreshResetID = UUID()

    private let refreshService: UsageRefreshService
    private let configurationStore: ProviderConfigurationStore
    private let historyStore: UsageHistoryStore
    private let usageAlertNotifier: any UsageAlertNotifying
    private let appReviewPromptPolicy: AppReviewPromptPolicy
    private let widgetSnapshotCoordinator: WidgetSnapshotCoordinator
    private var lastSystemDateTimeRefresh: ContinuousClock.Instant?
    private var cancellables: Set<AnyCancellable> = []

    init(
        refreshService: UsageRefreshService,
        configurationStore: ProviderConfigurationStore,
        historyStore: UsageHistoryStore,
        usageAlertNotifier: any UsageAlertNotifying,
        appReviewPromptPolicy: AppReviewPromptPolicy,
        widgetSnapshotCoordinator: WidgetSnapshotCoordinator? = nil
    ) {
        self.refreshService = refreshService
        self.configurationStore = configurationStore
        self.historyStore = historyStore
        self.usageAlertNotifier = usageAlertNotifier
        self.appReviewPromptPolicy = appReviewPromptPolicy
        self.widgetSnapshotCoordinator = widgetSnapshotCoordinator ?? WidgetSnapshotCoordinator(
            refreshService: refreshService,
            configurationStore: configurationStore
        )

        configurationStore.$configurations.dropFirst().sink { [weak historyStore] configurations in
            historyStore?.removeSnapshotsForMissingAccounts(
                validAccountIDs: Set(configurations.map(\.id))
            )
        }.store(in: &cancellables)
    }

    var dashboardCardItems: [DashboardProviderCardItem] {
        DashboardProviderCardItem.items(
            configurations: configurationStore.configurations.filter(
                configurationStore.shouldDisplayOnDashboard
            ),
            results: displayedResults,
            refreshingAccountIDs: refreshService.refreshingAccountIDs,
            errorsByAccountID: refreshService.refreshErrorsByAccountID,
            orderingMode: configurationStore.dashboardOrderingMode,
            manualOrder: configurationStore.dashboardCardOrder
        )
    }

    var dashboardSections: [DashboardSection] {
        var sections: [DashboardSection] = []
        var sectionIndexes: [String: Int] = [:]
        let configurationsByAccountID = Dictionary(
            uniqueKeysWithValues: configurationStore.configurations.map { ($0.id, $0) }
        )
        let groupsByID = Dictionary(
            uniqueKeysWithValues: configurationStore.groups.map { ($0.id, $0) }
        )

        for (offset, item) in dashboardCardItems.enumerated() {
            let configuration = configurationsByAccountID[item.id]
            let groupID = configuration?.groupID ?? DashboardSection.ungroupedID
            let title = configuration?.groupID.flatMap { groupsByID[$0]?.name }
                ?? ProviderAccountGroup.ungroupedDisplayName

            if configurationStore.dashboardOrderingMode == .smart {
                if sections.indices.last.map({ sections[$0].groupID }) == groupID {
                    sections[sections.count - 1].items.append(item)
                } else {
                    sections.append(
                        DashboardSection(
                            id: "\(groupID).\(offset)",
                            groupID: groupID,
                            title: title,
                            items: [item]
                        )
                    )
                }
                continue
            }

            if let sectionIndex = sectionIndexes[groupID] {
                sections[sectionIndex].items.append(item)
            } else {
                sectionIndexes[groupID] = sections.count
                sections.append(DashboardSection(id: groupID, groupID: groupID, title: title, items: [item]))
            }
        }

        return sections
    }

    var currentUsageAlertsByAccountID: [String: [UsageAlertDetail]] {
        let evaluation = UsageAlertEvaluator.evaluate(
            results: refreshService.results,
            settings: configurationStore.usageAlertSettings,
            activeAlertIDs: configurationStore.usageAlertActiveIDs
        )
        return Dictionary(grouping: evaluation.activeAlerts, by: \.accountID)
    }

    var isManualDashboardOrdering: Bool {
        configurationStore.dashboardOrderingMode == .manual
    }

    func shouldShowGroupHeaders(for sections: [DashboardSection]) -> Bool {
        !configurationStore.groups.isEmpty && sections.contains { section in
            section.groupID != DashboardSection.ungroupedID || sections.count > 1
        }
    }

    func dashboardStatusText(for result: ProviderUsageResult) -> String {
        if let error = refreshService.refreshErrorsByAccountID[result.accountID] {
            return "Refresh failed - \(error)"
        }

        guard let configuration = configurationStore.configuration(accountID: result.accountID) else {
            return result.subtitle
        }

        if configurationStore.isConfigured(configuration),
           !result.subtitle.localizedCaseInsensitiveContains("not configured") {
            return result.subtitle
        }
        return configurationStore.statusText(for: configuration)
    }

    func moveCard(_ draggedID: String, to targetID: String) {
        guard isManualDashboardOrdering else {
            return
        }

        var orderedIDs = visibleDashboardOrder
        guard
            dashboardGroupID(for: draggedID) == dashboardGroupID(for: targetID),
            let sourceIndex = orderedIDs.firstIndex(of: draggedID),
            let targetIndex = orderedIDs.firstIndex(of: targetID),
            sourceIndex != targetIndex
        else {
            return
        }

        let movedID = orderedIDs.remove(at: sourceIndex)
        orderedIDs.insert(movedID, at: targetIndex)
        persistVisibleCardOrder(orderedIDs)
    }

    func finishCardDrag() {
        guard isManualDashboardOrdering else {
            return
        }
        persistVisibleCardOrder(visibleDashboardOrder)
    }

    func refreshAfterSettingsDismissed() async {
        configurationStore.refreshSecretAvailability()
        _ = await refreshNow()
    }

    func handleSystemDateTimeChange() async {
        let now = ContinuousClock.now
        if let lastSystemDateTimeRefresh,
           lastSystemDateTimeRefresh.duration(to: now) < .seconds(1) {
            return
        }
        lastSystemDateTimeRefresh = now
        _ = await refreshNow()
    }

    func initialRefresh() async {
        _ = await refreshNow()
    }

    @discardableResult
    func refreshNow(considerReviewPrompt: Bool = false) async -> Bool {
        await refreshService.refresh(configurations: configurationStore.configurations)
        await finishRefresh(
            results: refreshService.successfulRefreshResults,
            preserving: refreshService.incompleteRefreshAccountIDs
        )

        if configurationStore.autoRefreshInterval.seconds != nil {
            autoRefreshResetID = UUID()
        }

        return considerReviewPrompt && shouldRequestReviewAfterSuccessfulRefresh()
    }

    @discardableResult
    func refreshAccount(_ configuration: ProviderAccountConfiguration) async -> ProviderUsageResult? {
        let result = await refreshService.refresh(configuration: configuration)
        let successfulResults = result.map { $0.failureMessage == nil ? [$0] : [] } ?? []
        let preservedAccountIDs = Set(configurationStore.configurations.map(\.id))
            .subtracting(successfulResults.map(\.accountID))
        await finishRefresh(results: successfulResults, preserving: preservedAccountIDs)
        return result
    }

    func consumeCodexBankedReset(
        for configuration: ProviderAccountConfiguration,
        creditID: String?
    ) async -> CodexBankedResetRedemptionFeedback {
        do {
            let outcome = try await refreshService.consumeCodexBankedReset(
                for: configuration,
                creditID: creditID
            )
            let refreshed = await refreshAccount(configuration)
            let refreshSucceeded = refreshed?.failureMessage == nil

            switch outcome {
            case .reset, .alreadyRedeemed:
                return CodexBankedResetRedemptionFeedback(
                    message: refreshSucceeded
                        ? "Reset used. Current usage limits are refreshed."
                        : "Reset used, but current usage could not be refreshed. Try refreshing again.",
                    isSuccess: true
                )
            case .nothingToReset:
                return CodexBankedResetRedemptionFeedback(
                    message: "There is no applicable usage window to reset right now.",
                    isSuccess: false
                )
            case .noCredit:
                return CodexBankedResetRedemptionFeedback(
                    message: "No banked reset remains for this account.",
                    isSuccess: false,
                    hidesAction: true
                )
            }
        } catch {
            let hidesAction = (error as? CodexBankedResetConsumptionError) == .unsupported
            return CodexBankedResetRedemptionFeedback(
                message: (error as? LocalizedError)?.errorDescription
                    ?? "Could not use the reset. Try again.",
                isSuccess: false,
                hidesAction: hidesAction
            )
        }
    }

    func requestAlertAuthorization() async -> Bool {
        await usageAlertNotifier.requestAuthorization()
    }

    func runAutoRefreshLoop() async {
        guard let interval = configurationStore.autoRefreshInterval.seconds else {
            autoRefreshSchedule = nil
            return
        }

        while !Task.isCancelled {
            let start = Date()
            autoRefreshSchedule = AutoRefreshSchedule(
                start: start,
                end: start.addingTimeInterval(interval)
            )

            do {
                try await Task.sleep(for: .seconds(interval))
            } catch {
                return
            }

            await refreshService.refresh(configurations: configurationStore.configurations)
            await finishRefresh(
                results: refreshService.successfulRefreshResults,
                preserving: refreshService.incompleteRefreshAccountIDs
            )
        }
    }

    private var displayedResults: [ProviderUsageResult] {
        refreshService.results.filter { result in
            configurationStore.configuration(accountID: result.accountID)
                .map(configurationStore.shouldDisplayOnDashboard) ?? false
        }
    }

    private var visibleDashboardOrder: [String] {
        dashboardSections.flatMap(\.items).map(\.id)
    }

    private func dashboardGroupID(for accountID: String) -> String {
        configurationStore.configuration(accountID: accountID)?.groupID
            ?? DashboardSection.ungroupedID
    }

    private func persistVisibleCardOrder(_ orderedVisibleIDs: [String]) {
        let visibleIDs = Set(dashboardCardItems.map(\.id))
        let hiddenOrderedIDs = configurationStore.dashboardCardOrder.filter { !visibleIDs.contains($0) }
        configurationStore.updateDashboardCardOrder(orderedVisibleIDs + hiddenOrderedIDs)
    }

    private func finishRefresh(
        results: [ProviderUsageResult],
        preserving preservedAccountIDs: Set<String>
    ) async {
        historyStore.record(results: results)
        await processUsageAlerts(results: results, preserving: preservedAccountIDs)
    }

    private func shouldRequestReviewAfterSuccessfulRefresh() -> Bool {
        AppReviewPromptEligibility.hasSuccessfulUsage(
            lastRefreshError: refreshService.lastRefreshError,
            results: refreshService.results
        ) && appReviewPromptPolicy.registerSuccessfulRefresh()
    }

    private func processUsageAlerts(
        results: [ProviderUsageResult],
        preserving preservedAccountIDs: Set<String>
    ) async {
        let existingActiveAlertIDs = configurationStore.usageAlertActiveIDs
        let preservedActiveAlertIDs = configurationStore.usageAlertSettings.isEnabled
            ? UsageAlertEvaluator.activeAlertIDs(
                existingActiveAlertIDs,
                belongingTo: preservedAccountIDs,
                knownAccountIDs: Set(configurationStore.configurations.map(\.id))
            )
            : []
        let evaluation = UsageAlertEvaluator.evaluate(
            results: results,
            settings: configurationStore.usageAlertSettings,
            activeAlertIDs: existingActiveAlertIDs
        )

        var deliveredActiveAlertIDs = preservedActiveAlertIDs.union(evaluation.activeAlertIDs)
        for notification in evaluation.notifications {
            do {
                try await usageAlertNotifier.deliver(notification)
            } catch {
                deliveredActiveAlertIDs.remove(notification.id)
            }
        }
        configurationStore.updateUsageAlertActiveIDs(deliveredActiveAlertIDs)
    }
}

@MainActor
final class WidgetSnapshotCoordinator {
    typealias SnapshotPublisher = @MainActor ([ProviderUsageResult], ProviderConfigurationStore) -> Void
    typealias SettingsPublisher = @MainActor (ProviderConfigurationStore) -> Void

    private let refreshService: UsageRefreshService
    private let configurationStore: ProviderConfigurationStore
    private let publishSnapshot: SnapshotPublisher
    private let publishSettings: SettingsPublisher
    private var cancellables: Set<AnyCancellable> = []
    private var snapshotPublishTask: Task<Void, Never>?
    private var settingsPublishTask: Task<Void, Never>?

    init(
        refreshService: UsageRefreshService,
        configurationStore: ProviderConfigurationStore,
        publishSnapshot: @escaping SnapshotPublisher = { results, store in
            WidgetSnapshotPublisher.publish(results: results, configurationStore: store)
        },
        publishSettings: @escaping SettingsPublisher = { store in
            WidgetSnapshotPublisher.publishSettings(configurationStore: store)
        }
    ) {
        self.refreshService = refreshService
        self.configurationStore = configurationStore
        self.publishSnapshot = publishSnapshot
        self.publishSettings = publishSettings

        refreshService.$results.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)

        configurationStore.$configurations.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$dashboardCardOrder.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$dashboardOrderingMode.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$groups.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$widgetRefreshInterval.dropFirst().sink { [weak self] _ in
            self?.scheduleSettingsPublish()
        }.store(in: &cancellables)
    }

    func publishCurrentSnapshot() {
        publishSnapshot(refreshService.results, configurationStore)
    }

    private func scheduleSnapshotPublish() {
        snapshotPublishTask?.cancel()
        snapshotPublishTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled else { return }
            self?.publishCurrentSnapshot()
        }
    }

    private func scheduleSettingsPublish() {
        settingsPublishTask?.cancel()
        settingsPublishTask = Task { @MainActor [weak self] in
            guard !Task.isCancelled, let self else { return }
            self.publishSettings(self.configurationStore)
        }
    }
}

struct AutoRefreshSchedule: Equatable {
    let start: Date
    let end: Date

    func progress(at date: Date) -> Double {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else { return 1 }
        return min(max(date.timeIntervalSince(start) / duration, 0), 1)
    }

    func remainingSeconds(at date: Date) -> Int {
        max(0, Int(ceil(end.timeIntervalSince(date))))
    }

    func accessibilityDescription(at date: Date) -> String {
        "Next auto refresh in \(formatDuration(remainingSeconds(at: date)))."
    }

    private func formatDuration(_ seconds: Int) -> String {
        if seconds >= 3_600 {
            let hours = seconds / 3_600
            let minutes = (seconds % 3_600) / 60
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        if seconds >= 60 {
            let minutes = seconds / 60
            let remainingSeconds = seconds % 60
            return remainingSeconds > 0 ? "\(minutes)m \(remainingSeconds)s" : "\(minutes)m"
        }
        return "\(seconds)s"
    }
}

struct DashboardSection: Identifiable {
    static let ungroupedID = "__ungrouped"

    let id: String
    let groupID: String
    let title: String
    var items: [DashboardProviderCardItem]
}

struct DashboardProviderCardItem: Identifiable, Equatable {
    let configuration: ProviderAccountConfiguration
    let result: ProviderUsageResult?
    let isRefreshing: Bool
    let errorMessage: String?

    var id: String { configuration.id }

    static func items(
        configurations: [ProviderAccountConfiguration],
        results: [ProviderUsageResult],
        refreshingAccountIDs: Set<String>,
        errorsByAccountID: [String: String],
        orderingMode: DashboardOrderingMode,
        manualOrder: [String]
    ) -> [DashboardProviderCardItem] {
        let resultsByAccountID = Dictionary(uniqueKeysWithValues: results.map { ($0.accountID, $0) })
        let items = configurations.map { configuration in
            DashboardProviderCardItem(
                configuration: configuration,
                result: resultsByAccountID[configuration.id],
                isRefreshing: refreshingAccountIDs.contains(configuration.id),
                errorMessage: errorsByAccountID[configuration.id]
            )
        }
        let itemsByAccountID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        let orderingResults = items.map { item in
            item.result ?? ProviderUsageResult(
                accountID: item.id,
                providerID: item.configuration.providerID,
                title: item.configuration.displayName,
                subtitle: "Loading current usage",
                bars: [],
                fetchedAt: .distantPast
            )
        }

        return DashboardUsageSorter.orderedResults(
            orderingResults,
            mode: orderingMode,
            manualOrder: manualOrder
        ).compactMap { itemsByAccountID[$0.accountID] }
    }
}
