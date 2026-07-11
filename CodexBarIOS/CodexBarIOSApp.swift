import SwiftUI

@main
struct CodexBarIOSApp: App {
    @StateObject private var refreshService: UsageRefreshService
    @StateObject private var configurationStore: ProviderConfigurationStore
    @StateObject private var historyStore = UsageHistoryStore()
    @StateObject private var appUpdateController = AppUpdateController()
    #if DEBUG
    @State private var debugProviderSettingsProviderID = DebugLaunchRoute.providerSettingsProviderID
    #endif

    init() {
        #if DEBUG
        if AppStoreScreenshotMode.isEnabled {
            let configurationStore = ProviderConfigurationStore.appStoreScreenshotDemo()
            if DebugUsageAlertMode.isEnabled {
                configurationStore.updateUsageAlertsEnabled(true)
                configurationStore.updateUsageAlertUsageThreshold(0.65)
                configurationStore.updateUsageAlertBalanceThreshold(15)
            }

            _refreshService = StateObject(wrappedValue: UsageRefreshService.demo())
            _configurationStore = StateObject(wrappedValue: configurationStore)
            return
        }
        #endif

        _refreshService = StateObject(wrappedValue: UsageRefreshService.live())
        _configurationStore = StateObject(wrappedValue: ProviderConfigurationStore())
    }

    var body: some Scene {
        WindowGroup {
            rootView
                .preferredColorScheme(configurationStore.appAppearance.colorScheme)
                .task {
                    OpenCodeZenBootstrapImporter.importIfNeeded(configurationStore: configurationStore)
                }
        }
    }

    @ViewBuilder
    private var rootView: some View {
        #if DEBUG
        if let providerID = debugProviderSettingsProviderID {
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
            mainContentView
        }
        #else
        mainContentView
        #endif
    }

    private var mainContentView: some View {
        ContentView(
            refreshService: refreshService,
            configurationStore: configurationStore,
            historyStore: historyStore,
            appUpdateController: appUpdateController
        )
    }
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

private enum AppStoreScreenshotMode {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--app-store-screenshots")
            || ProcessInfo.processInfo.environment["CODEXBAR_APP_STORE_SCREENSHOTS"] == "1"
    }
}

private enum DebugUsageAlertMode {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("--debug-usage-alerts")
            || ProcessInfo.processInfo.environment["CODEXBAR_DEBUG_USAGE_ALERTS"] == "1"
    }
}
#endif
