import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var refreshService: UsageRefreshService
    @ObservedObject var configurationStore: ProviderConfigurationStore
    @ObservedObject var historyStore: UsageHistoryStore
    private let usageAlertNotifier: any UsageAlertNotifying

    @State private var isShowingSettings = false
    @State private var selectedHistoryResult: ProviderUsageResult?
    @State private var autoRefreshSchedule: AutoRefreshSchedule?
    @State private var autoRefreshResetID = UUID()
    @State private var draggedCardID: String?

    init(
        refreshService: UsageRefreshService,
        configurationStore: ProviderConfigurationStore,
        historyStore: UsageHistoryStore,
        usageAlertNotifier: any UsageAlertNotifying = LocalUsageAlertNotifier.shared
    ) {
        self.refreshService = refreshService
        self.configurationStore = configurationStore
        self.historyStore = historyStore
        self.usageAlertNotifier = usageAlertNotifier
    }

    var body: some View {
        let sections = dashboardSections
        let showGroupHeaders = shouldShowGroupHeaders(for: sections)
        let usageAlertsByAccountID = currentUsageAlertsByAccountID

        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(sections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            if showGroupHeaders {
                                Text(section.title)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .textCase(.uppercase)
                                    .padding(.horizontal, 4)
                            }

                            ForEach(section.results) { result in
                                let history = historyStore.historySeries(for: result)
                                let card = ProviderUsageCard(
                                    result: result,
                                    statusText: dashboardStatusText(for: result),
                                    history: history,
                                    alerts: usageAlertsByAccountID[result.accountID] ?? [],
                                    onShowHistory: {
                                        selectedHistoryResult = result
                                    }
                                )

                                if isManualDashboardOrdering {
                                    card
                                        .onDrag {
                                            draggedCardID = result.id
                                            return NSItemProvider(object: result.id as NSString)
                                        }
                                        .onDrop(
                                            of: [UTType.text],
                                            delegate: ProviderUsageCardDropDelegate(
                                                targetID: result.id,
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
                            await refreshNow()
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
                if displayedResults.isEmpty {
                    ContentUnavailableView(
                        "No Usage Data",
                        systemImage: "gauge.with.dots.needle.50percent",
                        description: Text("Configure providers in Settings to start tracking live usage.")
                    )
                }
            }
        }
        .sheet(isPresented: $isShowingSettings, onDismiss: refreshAfterSettingsDismissed) {
            SettingsView(
                configurationStore: configurationStore,
                onAccountsChanged: {
                    Task {
                        await refreshNow()
                    }
                },
                onAccountRefresh: { configuration in
                    let result = await refreshService.refresh(configuration: configuration)
                    recordUsageHistoryIfAvailable(result: result)
                    publishWidgetSnapshot()
                    await processUsageAlerts()
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
                series: historyStore.historySeries(for: result)
            )
        }
        .task {
            await refreshService.refresh(configurations: configurationStore.configurations)
            recordUsageHistoryIfAvailable()
            publishWidgetSnapshot()
            await processUsageAlerts()
        }
        .task(id: AutoRefreshTaskID(interval: configurationStore.autoRefreshInterval, resetID: autoRefreshResetID)) {
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
    }

    private var displayedResults: [ProviderUsageResult] {
        refreshService.results.filter { result in
            configurationStore.configuration(accountID: result.accountID)
                .map(configurationStore.shouldDisplayOnDashboard) ?? false
        }
    }

    private var orderedDisplayedResults: [ProviderUsageResult] {
        DashboardUsageSorter.orderedResults(
            displayedResults,
            mode: configurationStore.dashboardOrderingMode,
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

        for (offset, result) in orderedDisplayedResults.enumerated() {
            let configuration = configurationsByAccountID[result.accountID]
            let groupID = configuration?.groupID ?? DashboardSection.ungroupedID
            let title = configuration?.groupID.flatMap { groupsByID[$0]?.name }
                ?? ProviderAccountGroup.ungroupedDisplayName

            if configurationStore.dashboardOrderingMode == .smart {
                if sections.indices.last.map({ sections[$0].groupID }) == groupID {
                    sections[sections.count - 1].results.append(result)
                } else {
                    sections.append(
                        DashboardSection(
                            id: "\(groupID).\(offset)",
                            groupID: groupID,
                            title: title,
                            results: [result]
                        )
                    )
                }
                continue
            }

            if let sectionIndex = sectionIndexes[groupID] {
                sections[sectionIndex].results.append(result)
            } else {
                sectionIndexes[groupID] = sections.count
                sections.append(DashboardSection(id: groupID, groupID: groupID, title: title, results: [result]))
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
        dashboardSections.flatMap(\.results).map(\.id)
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

    private func refreshAfterSettingsDismissed() {
        configurationStore.refreshSecretAvailability()
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

        let visibleIDs = Set(displayedResults.map(\.id))
        let hiddenOrderedIDs = configurationStore.dashboardCardOrder.filter { !visibleIDs.contains($0) }
        configurationStore.updateDashboardCardOrder(orderedVisibleIDs + hiddenOrderedIDs)
    }

    private func publishWidgetSnapshot() {
        WidgetSnapshotPublisher.publish(
            results: refreshService.results,
            configurationStore: configurationStore
        )
    }

    private func recordUsageHistoryIfAvailable() {
        guard refreshService.lastRefreshError == nil else {
            return
        }

        historyStore.record(results: refreshService.results)
    }

    private func recordUsageHistoryIfAvailable(result: ProviderUsageResult?) {
        guard refreshService.lastRefreshError == nil, let result else {
            return
        }

        historyStore.record(results: [result])
    }

    private var refreshAccessibilityLabel: String {
        guard let autoRefreshSchedule else {
            return "Refresh usage"
        }

        return "Refresh usage. \(autoRefreshSchedule.accessibilityDescription(at: Date()))"
    }

    private func refreshNow() async {
        await refreshService.refresh(configurations: configurationStore.configurations)
        recordUsageHistoryIfAvailable()
        publishWidgetSnapshot()
        await processUsageAlerts()
        if configurationStore.autoRefreshInterval.seconds != nil {
            autoRefreshResetID = UUID()
        }
    }

    private func processUsageAlerts() async {
        guard refreshService.lastRefreshError == nil else {
            return
        }

        let evaluation = UsageAlertEvaluator.evaluate(
            results: refreshService.results,
            settings: configurationStore.usageAlertSettings,
            activeAlertIDs: configurationStore.usageAlertActiveIDs
        )

        var deliveredActiveAlertIDs = evaluation.activeAlertIDs

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
            recordUsageHistoryIfAvailable()
            publishWidgetSnapshot()
            await processUsageAlerts()
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
    var results: [ProviderUsageResult]
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
        historyStore: UsageHistoryStore()
    )
}
