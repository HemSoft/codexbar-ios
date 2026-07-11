import SwiftUI

@main
struct CodexBarIOSApp: App {
    @StateObject private var refreshService: UsageRefreshService
    @StateObject private var configurationStore: ProviderConfigurationStore
    @StateObject private var historyStore: UsageHistoryStore
    @StateObject private var appUpdateController = AppUpdateController()
    #if DEBUG
    private let screenshotConfiguration = AppStoreScreenshotConfiguration.current
    @State private var debugProviderSettingsProviderID = DebugLaunchRoute.providerSettingsProviderID
    #endif

    init() {
        #if DEBUG
        if let screenshotConfiguration {
            let configurationStore = ProviderConfigurationStore.appStoreScreenshotDemo()
            configurationStore.updateAppAppearance(screenshotConfiguration.appearance)
            if screenshotConfiguration.scene == .dashboardDark {
                configurationStore.updateDashboardCardOrder([
                    "app-store-screenshots.openrouter",
                    "app-store-screenshots.opencodzen",
                    "app-store-screenshots.cursor",
                    "app-store-screenshots.codex",
                    "app-store-screenshots.copilot",
                    "app-store-screenshots.claude",
                ])
            }
            if DebugUsageAlertMode.isEnabled {
                configurationStore.updateUsageAlertsEnabled(true)
                configurationStore.updateUsageAlertUsageThreshold(0.65)
                configurationStore.updateUsageAlertBalanceThreshold(15)
            }

            let results = AppStoreScreenshotFixtures.results(for: configurationStore)
            let historyStore = AppStoreScreenshotFixtures.historyStore(for: results)
            AppStoreScreenshotFixtures.seedWidgetPreview(
                results: results,
                configurationStore: configurationStore
            )
            _refreshService = StateObject(
                wrappedValue: UsageRefreshService(
                    providers: DemoUsageProvider.samples,
                    initialResults: results
                )
            )
            _configurationStore = StateObject(wrappedValue: configurationStore)
            _historyStore = StateObject(wrappedValue: historyStore)
            return
        }
        #endif

        _refreshService = StateObject(wrappedValue: UsageRefreshService.live())
        _configurationStore = StateObject(wrappedValue: ProviderConfigurationStore())
        _historyStore = StateObject(wrappedValue: UsageHistoryStore())
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .preferredColorScheme(configurationStore.appAppearance.colorScheme)
                .task {
                    #if DEBUG
                    if let screenshotConfiguration {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
                        AppStoreScreenshotFixtures.markReady(scene: screenshotConfiguration.scene)
                    } else {
                        OpenCodeZenBootstrapImporter.importIfNeeded(configurationStore: configurationStore)
                    }
                    #else
                    OpenCodeZenBootstrapImporter.importIfNeeded(configurationStore: configurationStore)
                    #endif
                }
        }
    }

    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        if let screenshotConfiguration {
            screenshotRootView(for: screenshotConfiguration.scene)
        } else if let providerID = debugProviderSettingsProviderID {
            NavigationStack {
                ProviderSettingsView(
                    configurationStore: configurationStore,
                    accountID: configurationStore.configuration(for: providerID).id,
                    onAccountRefresh: { configuration in
                        await refreshService.refresh(configuration: configuration)
                    }
                )
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Close") {
                            debugProviderSettingsProviderID = nil
                        }
                    }
                }
            }
        } else {
            mainContentView()
        }
        #else
        mainContentView()
        #endif
    }

    private func mainContentView(performsLifecycleWork: Bool = true) -> some View {
        ContentView(
            refreshService: refreshService,
            configurationStore: configurationStore,
            historyStore: historyStore,
            appUpdateController: appUpdateController,
            performsLifecycleWork: performsLifecycleWork
        )
    }

    #if DEBUG
    @ViewBuilder
    private func screenshotRootView(for scene: AppStoreScreenshotScene) -> some View {
        switch scene {
        case .dashboardOverview:
            mainContentView(performsLifecycleWork: false)
        case .dashboardDark:
            mainContentView(performsLifecycleWork: false)
        case .widgetBuilder:
            NavigationStack {
                WidgetBuilderView()
            }
        case .accounts:
            SettingsView(
                configurationStore: configurationStore,
                appUpdateController: appUpdateController,
                initialScrollTarget: .accounts
            )
        case .providerCopilot:
            NavigationStack {
                ProviderSettingsView(
                    configurationStore: configurationStore,
                    accountID: "app-store-screenshots.copilot"
                )
            }
        case .history:
            if let result = refreshService.results.first(where: { $0.providerID == .codex }) {
                ProviderUsageHistoryDetailView(
                    result: result,
                    series: historyStore.historySeries(for: result)
                )
            } else {
                ContentUnavailableView("No History", systemImage: "chart.xyaxis.line")
            }
        }
    }
    #endif
}

#if DEBUG
private enum DebugLaunchRoute {
    static var providerSettingsProviderID: ProviderID? {
        if
            let rawValue = ProcessInfo.processInfo.environment["CODEXBAR_DEBUG_PROVIDER_SETTINGS"],
            let providerID = ProviderID(rawValue: rawValue)
        {
            return providerID
        }

        if
            let rawValue = UserDefaults.standard.string(forKey: "debugProviderSettings"),
            let providerID = ProviderID(rawValue: rawValue)
        {
            return providerID
        }

        let arguments = ProcessInfo.processInfo.arguments
        guard
            let routeIndex = arguments.firstIndex(of: "--debug-provider-settings"),
            arguments.indices.contains(routeIndex + 1)
        else {
            return nil
        }

        return ProviderID(rawValue: arguments[routeIndex + 1])
    }
}

private enum DebugUsageAlertMode {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--debug-usage-alerts")
            || ProcessInfo.processInfo.environment["CODEXBAR_DEBUG_USAGE_ALERTS"] == "1"
    }
}
#endif
