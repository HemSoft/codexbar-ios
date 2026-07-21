import Foundation
import StoreKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    @ObservedObject var refreshService: UsageRefreshService
    @ObservedObject var configurationStore: ProviderConfigurationStore
    @ObservedObject var historyStore: UsageHistoryStore
    @ObservedObject var appUpdateController: AppUpdateController
    @StateObject private var orchestrator: DashboardOrchestrator
    private let performsLifecycleWork: Bool

    @Environment(\.requestReview) private var requestReview
    @State private var isShowingSettings = false
    @State private var selectedHistoryResult: ProviderUsageResult?
    @State private var draggedCardID: String?
    @State private var deepLinkNavigation = DashboardDeepLinkNavigationState()
    @State private var hasCompletedInitialRefresh = false

    init(
        refreshService: UsageRefreshService,
        configurationStore: ProviderConfigurationStore,
        historyStore: UsageHistoryStore,
        appUpdateController: AppUpdateController,
        usageAlertNotifier: (any UsageAlertNotifying)? = nil,
        appReviewPromptPolicy: AppReviewPromptPolicy = AppReviewPromptPolicy(),
        performsLifecycleWork: Bool = true
    ) {
        self.refreshService = refreshService
        self.configurationStore = configurationStore
        self.historyStore = historyStore
        self.appUpdateController = appUpdateController
        self.performsLifecycleWork = performsLifecycleWork
        self._orchestrator = StateObject(
            wrappedValue: DashboardOrchestrator(
                refreshService: refreshService,
                configurationStore: configurationStore,
                historyStore: historyStore,
                usageAlertNotifier: usageAlertNotifier ?? LocalUsageAlertNotifier.shared,
                appReviewPromptPolicy: appReviewPromptPolicy
            )
        )
    }

    var body: some View {
        let cardItems = orchestrator.dashboardCardItems
        let sections = orchestrator.dashboardSections
        let showGroupHeaders = orchestrator.shouldShowGroupHeaders(for: sections)
        let usageAlertsByAccountID = orchestrator.currentUsageAlertsByAccountID

        NavigationStack {
            ScrollViewReader { scrollProxy in
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

                                    if orchestrator.isManualDashboardOrdering {
                                        card
                                            .id(item.id)
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
                                            .id(item.id)
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
                .onOpenURL { url in
                    handleDeepLink(
                        url,
                        scrollProxy: scrollProxy,
                        availableAccountIDs: cardItems.map(\.id)
                    )
                }
                .onChange(of: cardItems.map(\.id)) { _, accountIDs in
                    scrollToPendingDeepLink(
                        scrollProxy: scrollProxy,
                        availableAccountIDs: accountIDs,
                        completesNavigation: false
                    )
                }
                .onChange(of: refreshService.isRefreshing) { _, isRefreshing in
                    guard !isRefreshing, deepLinkNavigation.waitsForRefresh else {
                        return
                    }
                    scrollToPendingDeepLink(
                        scrollProxy: scrollProxy,
                        availableAccountIDs: cardItems.map(\.id),
                        completesNavigation: true
                    )
                }
                .onChange(of: hasCompletedInitialRefresh) { _, hasCompletedInitialRefresh in
                    guard
                        hasCompletedInitialRefresh,
                        !refreshService.isRefreshing,
                        deepLinkNavigation.waitsForRefresh
                    else {
                        return
                    }
                    scrollToPendingDeepLink(
                        scrollProxy: scrollProxy,
                        availableAccountIDs: cardItems.map(\.id),
                        completesNavigation: true
                    )
                }
            }
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
                            if await orchestrator.refreshNow(considerReviewPrompt: true) {
                                requestReview()
                            }
                        }
                    } label: {
                        RefreshButtonLabel(
                            isRefreshing: refreshService.isRefreshing,
                            schedule: orchestrator.autoRefreshSchedule
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
        .sheet(isPresented: $isShowingSettings, onDismiss: {
            Task { await orchestrator.refreshAfterSettingsDismissed() }
        }) {
            SettingsView(
                configurationStore: configurationStore,
                appUpdateController: appUpdateController,
                onAccountsChanged: {
                    Task {
                        _ = await orchestrator.refreshNow()
                    }
                },
                onAccountRefresh: { configuration in
                    await orchestrator.refreshAccount(configuration)
                },
                onAlertAuthorizationRequest: {
                    await orchestrator.requestAlertAuthorization()
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
            await orchestrator.initialRefresh()
            hasCompletedInitialRefresh = true
        }
        .task(id: AutoRefreshTaskID(
            interval: configurationStore.autoRefreshInterval,
            resetID: orchestrator.autoRefreshResetID
        )) {
            guard performsLifecycleWork else {
                return
            }
            await orchestrator.runAutoRefreshLoop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            guard performsLifecycleWork else { return }
            Task { await orchestrator.handleSystemDateTimeChange() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
            guard performsLifecycleWork else { return }
            Task { await orchestrator.handleSystemDateTimeChange() }
        }
    }

    @ViewBuilder
    private func dashboardCard(
        for item: DashboardProviderCardItem,
        alerts: [UsageAlertDetail]
    ) -> some View {
        if let result = item.result {
            ProviderUsageCard(
                result: result,
                statusText: orchestrator.dashboardStatusText(for: result),
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
                        await orchestrator.refreshAccount(item.configuration)
                    }
                }
            )
        } else {
            ProviderUsagePlaceholderCard(
                configuration: item.configuration,
                errorMessage: item.errorMessage,
                onRetry: {
                    Task {
                        await orchestrator.refreshAccount(item.configuration)
                    }
                }
            )
        }
    }

    private func moveCard(_ draggedID: String, to targetID: String) {
        withAnimation(.snappy(duration: 0.18)) {
            orchestrator.moveCard(draggedID, to: targetID)
        }
    }

    private func finishCardDrag() {
        orchestrator.finishCardDrag()
        draggedCardID = nil
    }

    private func handleDeepLink(
        _ url: URL,
        scrollProxy: ScrollViewProxy,
        availableAccountIDs: [String]
    ) {
        guard let accountID = CodexBarDeepLink.providerAccountID(from: url) else {
            return
        }

        let expectsSettingsRefresh = isShowingSettings
        isShowingSettings = false
        selectedHistoryResult = nil
        deepLinkNavigation.begin(
            accountID: accountID,
            waitsForRefresh: refreshService.isRefreshing
                || expectsSettingsRefresh
                || (performsLifecycleWork && !hasCompletedInitialRefresh)
        )
        scrollToPendingDeepLink(
            scrollProxy: scrollProxy,
            availableAccountIDs: availableAccountIDs,
            completesNavigation: deepLinkNavigation.shouldFinishAfterInitialScroll
        )
    }

    private func scrollToPendingDeepLink(
        scrollProxy: ScrollViewProxy,
        availableAccountIDs: [String],
        completesNavigation: Bool
    ) {
        guard let accountID = deepLinkNavigation.accountID else {
            return
        }
        guard availableAccountIDs.contains(accountID) else {
            if completesNavigation {
                deepLinkNavigation.finish(accountID: accountID)
            }
            return
        }

        Task { @MainActor in
            await Task.yield()
            guard deepLinkNavigation.accountID == accountID else {
                return
            }

            withAnimation(.snappy(duration: 0.25)) {
                scrollProxy.scrollTo(accountID, anchor: .center)
            }
            if completesNavigation {
                deepLinkNavigation.finish(accountID: accountID)
            }
        }
    }

    private var refreshAccessibilityLabel: String {
        guard let schedule = orchestrator.autoRefreshSchedule else {
            return "Refresh usage"
        }
        return "Refresh usage. \(schedule.accessibilityDescription(at: Date()))"
    }
}

struct DashboardDeepLinkNavigationState: Equatable {
    private(set) var accountID: String?
    private(set) var waitsForRefresh = false

    var shouldFinishAfterInitialScroll: Bool {
        !waitsForRefresh
    }

    mutating func begin(accountID: String, waitsForRefresh: Bool) {
        self.accountID = accountID
        self.waitsForRefresh = waitsForRefresh
    }

    mutating func finish(accountID: String) {
        guard self.accountID == accountID else {
            return
        }
        self.accountID = nil
        waitsForRefresh = false
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
