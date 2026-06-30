import SwiftUI

@main
struct CodexBarIOSApp: App {
    @StateObject private var refreshService = UsageRefreshService.live()
    @StateObject private var configurationStore = ProviderConfigurationStore()

    var body: some Scene {
        WindowGroup {
            ContentView(
                refreshService: refreshService,
                configurationStore: configurationStore
            )
            .preferredColorScheme(configurationStore.appAppearance.colorScheme)
        }
    }
}
