import Foundation
import StoreKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var refreshService: UsageRefreshService
    @ObservedObject var configurationStore: ProviderConfigurationStore
    @ObservedObject var historyStore: UsageHistoryStore
    @ObservedObject var appUpdateController: AppUpdateController
    private let usageAlertNotifier: any UsageAlertNotifying
    private let appReviewPromptPolicy: AppReviewPromptPolicy
    private let performsLifecycleWork: Bool

    @Environment(\.requestReview) private var requestReview
    @State private var isShowingSettings = false
    @State private var selectedHistoryResult: ProviderUsageResult?
    @State private var autoRefreshSchedule: AutoRefreshSchedule?
    @State private var autoRefreshResetID = UUID()
    @State private var draggedCardID: String?
    @State private var lastSystemDateTimeRefresh: ContinuousClock.Instant?

    init(
        refreshService: UsageRefreshService,
        configurationStore: ProviderConfigurationStore,
        historyStore: UsageHistoryStore,
        appUpdateController: AppUpdateController,
        usageAlertNotifier: any UsageAlertNotifying = LocalUsageAlertNotifier.shared,
        appReviewPromptPolicy: AppReviewPromptPolicy = AppReviewPromptPolicy(),
        performsLifecycleWork: Bool = true
    ) {
        self.refreshService = refreshService
        self.configurationStore = configurationStore
        self.historyStore = historyStore
        self.appUpdateController = appUpdateController
        self.usageAlertNotifier = usageAlertNotifier
        self.appReviewPromptPolicy = appReviewPromptPolicy
        self.performsLifecycleWork = performsLifecycleWork
    }

    var body: some View {
        let cardItems = dashboardCardItems
        let sections = dashboardSections
        let showGroupHeaders = shouldShowGroupHeaders(for: sections)
        let usageAlertsByAccountID = currentUsageAlertsByAccountID

        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !cardItems.isEmpty,
                       let release = appUpdateController.dashboardRelease {
                        AppUpdateNotice(
                            release: release,
                            onDismiss: appUpdateController.dismissDashboardNotice
                        )
                    }

                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            if showGroupHeaders {
                                Text(section.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .padding(.horizontal, 4)
                            }

                            ForEach(section.items) { item in
                                let card = dashboardCard(
                                    for: item,
                                    alerts: usageAlertsByAccountID[item.id] ?? []
                                )

                                if isManualDashboardOrdering {
                                    card
                                        .onDrag {
                                            draggedCardID = item.id
                                            return NSItemProvider(object: item.id as NSString)
                                        }
                                        .onDrop(
                                            of: [UTType.text],
                                            delegate: ProviderUsageCardDropDelegate(
                                                targetID: item.id,
                                                draggedCardID: $draggedCardID,
                                                moveCard: moveCard,
                                                finishDrag: finishCardDrag
                                            )
                                        )
                                } else {
                                    card
                                        .accessibilityHint(
                                            Text("Smart ordering is active.")
                                        )
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("CodexBar")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isShowingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Open settings")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            await refreshNow(considerReviewPrompt: true)
                        }
                    } label: {
                        RefreshButtonLabel(
                            isRefreshing: refreshService.isRefreshing,
                            schedule: autoRefreshSchedule
                        )
                    }
                    .disabled(refreshService.isRefreshing)
                    .accessibilityLabel(refreshAccessibilityLabel)
                }
            }
            .overlay {
                if cardItems.isEmpty {
                    VStack(spacing: 16) {
                        if let release = appUpdateController.dashboardRelease {
                            AppUpdateNotice(
                                release: release,
                                onDismiss: appUpdateController.dismissDashboardNotice
                            )
                        }

                        ContentUnavailableView(
                            "No Usage Data",
                            systemImage: "gauge.with.dots.needle.50percent",
                            description: Text("Configure providers in Settings to start tracking live usage.")
                        )
                    }
                    .padding()
                }
            }
        }
        .sheet(isPresented: $isShowingSettings, onDismiss: refreshAfterSettingsDismissed) {
            SettingsView(
                configurationStore: configurationStore,
                appUpdateController: appUpdateController,
                onAccountsChanged: {
                    Task {
                        await refreshNow()
                    }
                },
                onAccountRefresh: { configuration in
                    let result = await refreshService.refresh(configuration: configuration)
                    let successfulResults = result.map { $0.failureMessage == nil ? [$0] : [] } ?? []
                    let preservedAccountIDs = Set(configurationStore.configurations.map(\.id))
                        .subtracting(successfulResults.map(\.accountID))
                    recordUsageHistoryIfAvailable(results: successfulResults)
                    publishWidgetSnapshot()
                    await processUsageAlerts(
                        results: successfulResults,
                        preserving: preservedAccountIDs
                    )
                    return result
                },
                onAlertAuthorizationRequest: {
                    await usageAlertNotifier.requestAuthorization()
                }
            )
        }
        .sheet(item: $selectedHistoryResult) { result in
            ProviderUsageHistoryDetailView(
                result: result,
                seriesOptions: historyStore.historySeriesOptions(for: result)
            )
        }
        .task {
            guard performsLifecycleWork else {
                return
            }
            await appUpdateController.checkForUpdates()
        }
        .task {
            guard performsLifecycleWork else {
                return
            }
            await refreshService.refresh(configurations: configurationStore.configurations)
            let successfulResults = refreshService.successfulRefreshResults
            recordUsageHistoryIfAvailable(results: successfulResults)
            publishWidgetSnapshot()
            await processUsageAlerts(
                results: successfulResults,
                preserving: refreshService.incompleteRefreshAccountIDs
            )
        }
        .task(id: AutoRefreshTaskID(interval: configurationStore.autoRefreshInterval, resetID: autoRefreshResetID)) {
            guard performsLifecycleWork else {
                return
            }
            await runAutoRefreshLoop()
        }
        .onChange(of: refreshService.results) { _, _ in
            publishWidgetSnapshot()
        }
        .onChange(of: configurationStore.configurations) { _, configurations in
            historyStore.removeSnapshotsForMissingAccounts(validAccountIDs: Set(configurations.map(\.id)))
        }
        .onChange(of: configurationStore.dashboardCardOrder) { _, _ in
            publishWidgetSnapshot()
        }
        .onChange(of: configurationStore.dashboardOrderingMode) { _, _ in
            publishWidgetSnapshot()
        }
        .onChange(of: configurationStore.groups) { _, _ in
            publishWidgetSnapshot()
        }
        .onChange(of: configurationStore.widgetRefreshInterval) { _, _ in
            WidgetSnapshotPublisher.publishSettings(configurationStore: configurationStore)
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            handleSystemDateTimeChange()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            handleSystemDateTimeChange()
        }
    }

    private var displayedResults: [ProviderUsageResult] {
        refreshService.results.filter { result in
            configurationStore.configuration(accountID: result.accountID)
                .map(configurationStore.shouldDisplayOnDashboard) ?? false
        }
    }

    private var dashboardCardItems: [DashboardProviderCardItem] {
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

    private var dashboardSections: [DashboardSection] {
        var sections: [DashboardSection] = []
        var sectionIndexes: [String: Int] = [:]
        let configurationsByAccountID = Dictionary(
            uniqueKeysWithValues: configurationStore.configurations.map { configuration in
                (configuration.id, configuration)
            }
        )
        let groupsByID = Dictionary(
            uniqueKeysWithValues: configurationStore.groups.map { group in
                (group.id, group)
            }
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

    private func shouldShowGroupHeaders(for sections: [DashboardSection]) -> Bool {
        !configurationStore.groups.isEmpty && sections.contains { section in
            section.groupID != DashboardSection.ungroupedID || sections.count > 1
        }
    }

    private var visibleDashboardOrder: [String] {
        dashboardSections.flatMap(\.items).map(\.id)
    }

    private var isManualDashboardOrdering: Bool {
        configurationStore.dashboardOrderingMode == .manual
    }

    private var currentUsageAlertsByAccountID: [String: [UsageAlertDetail]] {
        let evaluation = UsageAlertEvaluator.evaluate(
            results: refreshService.results,
            settings: configurationStore.usageAlertSettings,
            activeAlertIDs: configurationStore.usageAlertActiveIDs
        )

        return Dictionary(grouping: evaluation.activeAlerts, by: \.accountID)
    }

    private func dashboardStatusText(for result: ProviderUsageResult) -> String {
        if let error = refreshService.refreshErrorsByAccountID[result.accountID] {
            return "Refresh failed - \(error)"
        }

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

    @ViewBuilder
    private func dashboardCard(
        for item: DashboardProviderCardItem,
        alerts: [UsageAlertDetail]
    ) -> some View {
        if let result = item.result {
            ProviderUsageCard(
                result: result,
                statusText: dashboardStatusText(for: result),
                history: historyStore.historySeries(for: result),
                alerts: alerts,
                isHistoryEnabled: item.configuration.showsHistory,
                isRefreshing: item.isRefreshing,
                refreshErrorMessage: item.errorMessage,
                onShowHistory: {
                    selectedHistoryResult = result
                },
                onRetry: {
                    Task {
                        await refreshAccount(item.configuration)
                    }
                }
            )
        } else {
            ProviderUsagePlaceholderCard(
                configuration: item.configuration,
                errorMessage: item.errorMessage,
                onRetry: {
                    Task {
                        await refreshAccount(item.configuration)
                    }
                }
            )
        }
    }

    private func refreshAfterSettingsDismissed() {
        configurationStore.refreshSecretAvailability()
        Task {
            await refreshNow()
        }
    }

    private func handleSystemDateTimeChange() {
        guard performsLifecycleWork else {
            return
        }

        let now = ContinuousClock.now
        if let lastSystemDateTimeRefresh,
           lastSystemDateTimeRefresh.duration(to: now) < .seconds(1) {
            return
        }
        lastSystemDateTimeRefresh = now

        Task {
            await refreshNow()
        }
    }

    private func moveCard(_ draggedID: String, to targetID: String) {
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

        withAnimation(.snappy(duration: 0.18)) {
            orderedIDs.move(
                fromOffsets: IndexSet(integer: sourceIndex),
                toOffset: targetIndex > sourceIndex ? targetIndex + 1 : targetIndex
            )
            persistVisibleCardOrder(orderedIDs)
        }
    }

    private func dashboardGroupID(for accountID: String) -> String {
        configurationStore.configuration(accountID: accountID)?.groupID
            ?? DashboardSection.ungroupedID
    }

    private func finishCardDrag() {
        guard isManualDashboardOrdering else {
            draggedCardID = nil
            return
        }

        persistVisibleCardOrder(visibleDashboardOrder)
        draggedCardID = nil
    }

    private func persistVisibleCardOrder(_ orderedVisibleIDs: [String]) {
        guard isManualDashboardOrdering else {
            return
        }

        let visibleIDs = Set(dashboardCardItems.map(\.id))
        let hiddenOrderedIDs = configurationStore.dashboardCardOrder.filter { !visibleIDs.contains($0) }
        configurationStore.updateDashboardCardOrder(orderedVisibleIDs + hiddenOrderedIDs)
    }

    private func publishWidgetSnapshot() {
        WidgetSnapshotPublisher.publish(
            results: refreshService.results,
            configurationStore: configurationStore
        )
    }

    private func recordUsageHistoryIfAvailable(results: [ProviderUsageResult]) {
        historyStore.record(results: results)
    }

    private func refreshAccount(_ configuration: ProviderAccountConfiguration) async {
        let result = await refreshService.refresh(configuration: configuration)
        let successfulResults = result.map { $0.failureMessage == nil ? [$0] : [] } ?? []
        let preservedAccountIDs = Set(configurationStore.configurations.map(\.id))
            .subtracting(successfulResults.map(\.accountID))
        recordUsageHistoryIfAvailable(results: successfulResults)
        publishWidgetSnapshot()
        await processUsageAlerts(
            results: successfulResults,
            preserving: preservedAccountIDs
        )
    }

    private var refreshAccessibilityLabel: String {
        guard let autoRefreshSchedule else {
            return "Refresh usage"
        }

        return "Refresh usage. \(autoRefreshSchedule.accessibilityDescription(at: Date()))"
    }

    private func refreshNow(considerReviewPrompt: Bool = false) async {
        await refreshService.refresh(configurations: configurationStore.configurations)
        let successfulResults = refreshService.successfulRefreshResults
        recordUsageHistoryIfAvailable(results: successfulResults)
        publishWidgetSnapshot()
        await processUsageAlerts(
            results: successfulResults,
            preserving: refreshService.incompleteRefreshAccountIDs
        )
        if considerReviewPrompt {
            requestReviewAfterSuccessfulRefreshIfEligible()
        }
        if configurationStore.autoRefreshInterval.seconds != nil {
            autoRefreshResetID = UUID()
        }
    }

    private func requestReviewAfterSuccessfulRefreshIfEligible() {
        guard AppReviewPromptEligibility.hasSuccessfulUsage(
            lastRefreshError: refreshService.lastRefreshError,
            results: refreshService.results
        ) else {
            return
        }
        guard appReviewPromptPolicy.registerSuccessfulRefresh() else {
            return
        }

        requestReview()
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

    @MainActor
    private func runAutoRefreshLoop() async {
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
            let successfulResults = refreshService.successfulRefreshResults
            recordUsageHistoryIfAvailable(results: successfulResults)
            publishWidgetSnapshot()
            await processUsageAlerts(
                results: successfulResults,
                preserving: refreshService.incompleteRefreshAccountIDs
            )
        }
    }
}

private struct ProviderUsageCardDropDelegate: DropDelegate {
    let targetID: String
    @Binding var draggedCardID: String?
    let moveCard: (String, String) -> Void
    let finishDrag: () -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedCardID, draggedCardID != targetID else {
            return
        }

        moveCard(draggedCardID, targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        finishDrag()
        return true
    }
}

private struct AutoRefreshTaskID: Equatable {
    let interval: AutoRefreshInterval
    let resetID: UUID
}

private struct AutoRefreshSchedule: Equatable {
    let start: Date
    let end: Date

    func progress(at date: Date) -> Double {
        let duration = end.timeIntervalSince(start)
        guard duration > 0 else {
            return 1
        }

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

private struct DashboardSection: Identifiable {
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

    var id: String {
        configuration.id
    }

    static func items(
        configurations: [ProviderAccountConfiguration],
        results: [ProviderUsageResult],
        refreshingAccountIDs: Set<String>,
        errorsByAccountID: [String: String],
        orderingMode: DashboardOrderingMode,
        manualOrder: [String]
    ) -> [DashboardProviderCardItem] {
        let resultsByAccountID = Dictionary(
            uniqueKeysWithValues: results.map { ($0.accountID, $0) }
        )
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

private struct AppUpdateNotice: View {
    let release: AppStoreRelease
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.down.app.fill")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Version \(release.version) available")
                    .font(.subheadline.weight(.semibold))
                Text("A newer CodexBar release is on the App Store.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Link("Update", destination: release.productURL)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Dismiss version \(release.version) update notice")
            .help("Dismiss update notice")
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .contain)
    }
}

private struct RefreshButtonLabel: View {
    let isRefreshing: Bool
    let schedule: AutoRefreshSchedule?

    var body: some View {
        TimelineView(.periodic(from: Date(), by: 1)) { timeline in
            ZStack {
                if let schedule {
                    AutoRefreshRing(
                        progress: schedule.progress(at: timeline.date),
                        remainingSeconds: schedule.remainingSeconds(at: timeline.date)
                    )
                }

                if isRefreshing {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 17, weight: .semibold))
                }
            }
            .frame(width: 34, height: 34)
            .contentShape(Circle())
        }
    }
}

private struct AutoRefreshRing: View {
    let progress: Double
    let remainingSeconds: Int

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(.tertiarySystemFill), lineWidth: 3)

            Circle()
                .trim(from: 0, to: progress)
                .stroke(
                    tint,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.25), value: progress)
        }
        .accessibilityHidden(true)
    }

    private var tint: Color {
        switch progress {
        case ..<0.55:
            .green
        case ..<0.82:
            .orange
        default:
            .red
        }
    }
}

#Preview {
    ContentView(
        refreshService: .demo(),
        configurationStore: ProviderConfigurationStore(),
        historyStore: UsageHistoryStore(),
        appUpdateController: AppUpdateController()
    )
}
