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
    @StateObject private var claudeAuthenticationController: DashboardClaudeAuthenticationController
    private let performsLifecycleWork: Bool

    @Environment(\.requestReview) private var requestReview
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var isShowingSettings = false
    @State private var selectedHistoryResult: ProviderUsageResult?
    @State private var accountConfigurationNavigation =
        DashboardAccountConfigurationNavigationState()
    @State private var draggedCardID: String?
    @State private var deepLinkNavigation = DashboardDeepLinkNavigationState()
    @State private var hasCompletedInitialRefresh = false
    @State private var settingsRefreshCompletionID = UUID()
    @State private var isConfirmingHistoryReset = false

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
        let orchestrator = DashboardOrchestrator(
            refreshService: refreshService,
            configurationStore: configurationStore,
            historyStore: historyStore,
            usageAlertNotifier: usageAlertNotifier ?? LocalUsageAlertNotifier.shared,
            appReviewPromptPolicy: appReviewPromptPolicy
        )
        self._orchestrator = StateObject(
            wrappedValue: orchestrator
        )
        self._claudeAuthenticationController = StateObject(
            wrappedValue: DashboardClaudeAuthenticationController(
                configurationStore: configurationStore,
                refreshAccount: { [weak orchestrator] configuration in
                    await orchestrator?.refreshAccount(configuration)
                }
            )
        )
    }

    var body: some View {
        let cardItems = orchestrator.dashboardCardItems
        let sections = orchestrator.dashboardSections
        let showGroupHeaders = orchestrator.shouldShowGroupHeaders(for: sections)
        let usageAlertsByAccountID = orchestrator.currentUsageAlertsByAccountID

        NavigationStack {
            GeometryReader { geometry in
                let gridColumns = DashboardCardGridLayout.columns(
                    containerWidth: geometry.size.width,
                    idiom: UIDevice.current.userInterfaceIdiom,
                    dynamicTypeSize: dynamicTypeSize
                )

                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if let historyError = historyStore.lastError {
                                VStack(alignment: .leading, spacing: 8) {
                                    Label(historyError, systemImage: "exclamationmark.triangle.fill")
                                        .font(.footnote)
                                        .foregroundStyle(.red)
                                        .accessibilityIdentifier("usage-history-persistence-error")

                                    if historyStore.requiresRecovery {
                                        Button("Reset History", role: .destructive) {
                                            isConfirmingHistoryReset = true
                                        }
                                        .buttonStyle(.bordered)
                                        .accessibilityIdentifier("reset-corrupted-usage-history")
                                    }
                                }
                            }

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

                                    LazyVGrid(
                                        columns: gridColumns,
                                        alignment: .leading,
                                        spacing: DashboardCardGridLayout.cardSpacing
                                    ) {
                                        ForEach(section.items) { item in
                                            let card = dashboardCard(
                                                for: item,
                                                alerts: usageAlertsByAccountID[item.id] ?? []
                                            )

                                            if orchestrator.isManualDashboardOrdering {
                                                card
                                                    .frame(
                                                        maxWidth: .infinity,
                                                        alignment: .topLeading
                                                    )
                                                    .id(item.id)
                                                    .onDrag {
                                                        draggedCardID = item.id
                                                        return NSItemProvider(
                                                            object: item.id as NSString
                                                        )
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
                                                    .modifier(
                                                        DashboardCardReorderActions(
                                                            canMoveEarlier:
                                                                section.items.first?.id != item.id,
                                                            canMoveLater:
                                                                section.items.last?.id != item.id,
                                                            moveEarlier: {
                                                                moveCard(
                                                                    item.id,
                                                                    within: section.items,
                                                                    offset: -1
                                                                )
                                                            },
                                                            moveLater: {
                                                                moveCard(
                                                                    item.id,
                                                                    within: section.items,
                                                                    offset: 1
                                                                )
                                                            }
                                                        )
                                                    )
                                            } else {
                                                card
                                                    .frame(
                                                        maxWidth: .infinity,
                                                        alignment: .topLeading
                                                    )
                                                    .id(item.id)
                                                    .accessibilityHint(
                                                        Text("Smart ordering is active.")
                                                    )
                                            }
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
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
                    .onChange(of: settingsRefreshCompletionID) { _, _ in
                        guard deepLinkNavigation.waitsForRefresh else {
                            return
                        }
                        scrollToPendingDeepLink(
                            scrollProxy: scrollProxy,
                            availableAccountIDs: cardItems.map(\.id),
                            completesNavigation: true
                        )
                    }
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
            Task {
                await orchestrator.refreshAfterSettingsDismissed()
                settingsRefreshCompletionID = UUID()
            }
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
        .sheet(
            item: accountConfigurationPresentation,
            onDismiss: {
                guard let accountID = accountConfigurationNavigation.finishDismissal() else {
                    return
                }
                Task {
                    await refreshAccount(accountID: accountID)
                }
            }
        ) { presentation in
            NavigationStack {
                ProviderSettingsView(
                    configurationStore: configurationStore,
                    accountID: presentation.accountID,
                    onCredentialsChanged: {
                        Task {
                            await refreshAccount(accountID: presentation.accountID)
                        }
                    },
                    onAccountRefresh: { configuration in
                        await orchestrator.refreshAccount(configuration)
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") {
                            accountConfigurationNavigation.clearPresentation()
                        }
                    }
                }
            }
        }
        .sheet(item: $selectedHistoryResult) { result in
            ProviderUsageHistoryDetailView(
                result: result,
                seriesOptions: historyStore.historySeriesOptions(for: result)
            )
        }
        .sheet(
            item: $claudeAuthenticationController.authURL,
            onDismiss: claudeAuthenticationController.cancelAuthentication
        ) { authURL in
            SafariAuthSheet(url: authURL.url)
        }
        .confirmationDialog(
            "Reset unreadable usage history?",
            isPresented: $isConfirmingHistoryReset,
            titleVisibility: .visible
        ) {
            Button("Reset History", role: .destructive) {
                historyStore.discardCorruptedHistory()
            }
        } message: {
            Text("This permanently discards the unreadable history so new usage can be recorded.")
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
        let authenticationState = claudeAuthenticationController.state(for: item.id)

        if let result = item.result {
            ProviderUsageCard(
                result: result,
                statusText: orchestrator.dashboardStatusText(for: result),
                history: historyStore.historySeries(for: result),
                alerts: alerts,
                isHistoryEnabled: item.configuration.showsHistory,
                isRefreshing: item.isRefreshing,
                refreshErrorMessage: item.errorMessage,
                recoveryAction: item.recoveryAction,
                isPerformingRecovery: authenticationState.isSigningIn,
                recoveryStatusMessage: authenticationState.statusMessage,
                recoveryErrorMessage: authenticationState.errorMessage,
                problemReportContext: problemReportContext(for: item),
                onShowHistory: {
                    selectedHistoryResult = result
                },
                onConfigureAccount: {
                    accountConfigurationNavigation.present(accountID: result.accountID)
                },
                onRetry: {
                    performRecovery(for: item)
                },
                retainedCodexResetAttempt: orchestrator.retainedCodexResetAttempt(
                    for: item.configuration
                ),
                onUseCodexReset: { creditID in
                    await orchestrator.consumeCodexBankedReset(
                        for: item.configuration,
                        creditID: creditID
                    )
                },
                isMetricVisible: { metricID in
                    configurationStore.isMetricVisible(
                        accountID: result.accountID,
                        metricID: metricID
                    )
                },
                onUpdateMetricVisibility: { metricID, isVisible in
                    configurationStore.updateMetricVisibility(
                        isVisible,
                        accountID: result.accountID,
                        metricID: metricID
                    )
                },
                watchVisibilityForMetric: { metricID in
                    configurationStore.watchVisibilityPolicy(
                        accountID: result.accountID,
                        metricID: metricID
                    )
                },
                onUpdateWatchVisibility: { metricID, policy in
                    configurationStore.updateWatchMetricVisibility(
                        policy,
                        accountID: result.accountID,
                        metricID: metricID
                    )
                },
                visualizationStyleForMetric: { metricID in
                    configurationStore.visualizationStyle(
                        accountID: result.accountID,
                        metricID: metricID
                    )
                },
                onUpdateVisualizationStyle: { metricID, style in
                    configurationStore.updateVisualizationStyle(
                        style,
                        accountID: result.accountID,
                        metricID: metricID
                    )
                },
                onApplyVisualizationStyleToAll: { style, metricIDs in
                    configurationStore.applyVisualizationStyle(
                        style,
                        accountID: result.accountID,
                        metricIDs: metricIDs
                    )
                },
                onResetVisualizationStyles: { metricIDs in
                    configurationStore.resetVisualizationStyles(
                        accountID: result.accountID,
                        metricIDs: metricIDs
                    )
                },
                metricOrder: configurationStore.metricLayouts[result.accountID]?.orderedMetricIDs ?? [],
                metricWidthForMetric: { metricID in
                    configurationStore.metricWidth(
                        accountID: result.accountID,
                        metricID: metricID
                    )
                },
                onUpdateMetricWidth: { metricID, width in
                    configurationStore.updateMetricWidth(
                        width,
                        accountID: result.accountID,
                        metricID: metricID
                    )
                },
                metricLayout: {
                    configurationStore.metricLayouts[result.accountID]
                        ?? AccountMetricLayout(orderedMetricIDs: result.availableMetrics.map(\.id))
                },
                isMetricNewlyDiscovered: { metricID in
                    configurationStore.isMetricNewlyDiscovered(
                        accountID: result.accountID,
                        metricID: metricID
                    )
                },
                onUpdateMetricOrder: { metricIDs in
                    configurationStore.updateMetricOrder(
                        metricIDs,
                        accountID: result.accountID
                    )
                },
                onReplaceMetricLayout: { layout in
                    configurationStore.replaceMetricLayout(
                        layout,
                        accountID: result.accountID
                    )
                },
                onResetMetricLayout: { metricIDs in
                    configurationStore.resetMetricLayout(
                        accountID: result.accountID,
                        availableMetricIDs: metricIDs
                    )
                },
                copyLayoutDestinations: {
                    orchestrator.dashboardCardItems.compactMap { destination in
                        guard
                            destination.id != result.accountID,
                            destination.configuration.providerID == result.providerID,
                            let destinationResult = destination.result,
                            !destinationResult.availableMetrics.isEmpty
                        else {
                            return nil
                        }
                        let metricIDs = destinationResult.availableMetrics.map(\.id)
                        return MetricLayoutCopyDestination(
                            id: destination.id,
                            title: destination.configuration.displayName,
                            availableMetricIDs: metricIDs,
                            hasCustomLayout: configurationStore.isMetricLayoutCustomized(
                                accountID: destination.id,
                                availableMetricIDs: metricIDs
                            )
                        )
                    }
                },
                onCopyMetricLayout: { destination in
                    configurationStore.copyMetricLayout(
                        from: result.accountID,
                        to: destination.id,
                        destinationAvailableMetricIDs: destination.availableMetricIDs
                    )
                },
                onMarkMetricsSeen: { metricIDs in
                    configurationStore.markMetricsSeen(
                        metricIDs,
                        accountID: result.accountID
                    )
                },
                historySeriesOptions: {
                    historyStore.historySeriesOptions(for: result)
                },
                onMetricsDiscovered: { metricIDs in
                    configurationStore.reconcileMetricLayout(
                        accountID: result.accountID,
                        availableMetricIDs: metricIDs
                    )
                }
            )
        } else {
            ProviderUsagePlaceholderCard(
                configuration: item.configuration,
                errorMessage: item.errorMessage,
                recoveryAction: item.recoveryAction,
                isPerformingRecovery: authenticationState.isSigningIn,
                recoveryStatusMessage: authenticationState.statusMessage,
                recoveryErrorMessage: authenticationState.errorMessage,
                problemReportContext: problemReportContext(for: item),
                onRetry: {
                    performRecovery(for: item)
                }
            )
        }
    }

    private func performRecovery(for item: DashboardProviderCardItem) {
        switch item.recoveryAction {
        case .retryRefresh:
            Task {
                await orchestrator.refreshAccount(item.configuration)
            }
        case .signIn, .reauthenticate:
            claudeAuthenticationController.startSignIn(for: item.configuration)
        }
    }

    private func problemReportContext(
        for item: DashboardProviderCardItem
    ) -> PrivacySafeDiagnosticContext? {
        guard let errorMessage = item.errorMessage else {
            return nil
        }
        return PrivacySafeDiagnosticContext(
            system: .current(installedVersion: appUpdateController.installedVersion),
            surface: .dashboard,
            providerID: item.configuration.providerID,
            technicalDetails: .providerRefreshFailure(
                configuration: item.configuration,
                isConfigured: configurationStore.isConfigured(item.configuration),
                isSecretPresent: configurationStore.hasSecret(for: item.configuration),
                userVisibleMessage: errorMessage,
                result: item.result
            )
        )
    }

    private var accountConfigurationPresentation:
        Binding<DashboardAccountConfigurationPresentation?>
    {
        Binding(
            get: {
                accountConfigurationNavigation.presentation
            },
            set: { presentation in
                if let presentation {
                    accountConfigurationNavigation.present(accountID: presentation.accountID)
                } else {
                    accountConfigurationNavigation.clearPresentation()
                }
            }
        )
    }

    private func refreshAccount(accountID: String) async {
        guard let configuration = configurationStore.configuration(accountID: accountID) else {
            return
        }
        await orchestrator.refreshAccount(configuration)
    }

    private func moveCard(_ draggedID: String, to targetID: String) {
        withAnimation(.snappy(duration: 0.18)) {
            orchestrator.moveCard(draggedID, to: targetID)
        }
    }

    private func moveCard(
        _ cardID: String,
        within items: [DashboardProviderCardItem],
        offset: Int
    ) {
        guard
            let sourceIndex = items.firstIndex(where: { $0.id == cardID }),
            items.indices.contains(sourceIndex + offset)
        else {
            return
        }

        moveCard(cardID, to: items[sourceIndex + offset].id)
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

struct DashboardAccountConfigurationPresentation: Identifiable, Equatable {
    let accountID: String

    var id: String {
        accountID
    }
}

struct DashboardAccountConfigurationNavigationState: Equatable {
    private(set) var presentation: DashboardAccountConfigurationPresentation?
    private var accountIDAwaitingDismissalRefresh: String?

    mutating func present(accountID: String) {
        presentation = DashboardAccountConfigurationPresentation(accountID: accountID)
        accountIDAwaitingDismissalRefresh = accountID
    }

    mutating func clearPresentation() {
        presentation = nil
    }

    mutating func finishDismissal() -> String? {
        defer {
            presentation = nil
            accountIDAwaitingDismissalRefresh = nil
        }
        return accountIDAwaitingDismissalRefresh
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

private struct DashboardCardReorderActions: ViewModifier {
    let canMoveEarlier: Bool
    let canMoveLater: Bool
    let moveEarlier: () -> Void
    let moveLater: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if canMoveEarlier, canMoveLater {
            content
                .accessibilityAction(named: Text("Move Earlier"), moveEarlier)
                .accessibilityAction(named: Text("Move Later"), moveLater)
        } else if canMoveEarlier {
            content
                .accessibilityAction(named: Text("Move Earlier"), moveEarlier)
        } else if canMoveLater {
            content
                .accessibilityAction(named: Text("Move Later"), moveLater)
        } else {
            content
        }
    }
}

struct DashboardCardGridLayout {
    static let cardSpacing: CGFloat = 14
    static let horizontalPadding: CGFloat = 32
    static let minimumReadableCardWidth: CGFloat = 340

    static func columnCount(
        containerWidth: CGFloat,
        idiom: UIUserInterfaceIdiom,
        dynamicTypeSize: DynamicTypeSize
    ) -> Int {
        guard idiom == .pad, !dynamicTypeSize.isAccessibilitySize else {
            return 1
        }

        let usableWidth = max(0, containerWidth - horizontalPadding)
        let requiredWidth = (minimumReadableCardWidth * 2) + cardSpacing
        return usableWidth >= requiredWidth ? 2 : 1
    }

    static func columns(
        containerWidth: CGFloat,
        idiom: UIUserInterfaceIdiom,
        dynamicTypeSize: DynamicTypeSize
    ) -> [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: cardSpacing, alignment: .top),
            count: columnCount(
                containerWidth: containerWidth,
                idiom: idiom,
                dynamicTypeSize: dynamicTypeSize
            )
        )
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
