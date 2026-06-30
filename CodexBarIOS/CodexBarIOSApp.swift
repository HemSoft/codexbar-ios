import SwiftUI

@main
struct CodexBarIOSApp: App {
    @StateObject private var refreshService = UsageRefreshService.demo()
    @StateObject private var configurationStore = ProviderConfigurationStore()

    var body: some Scene {
        WindowGroup {
            ContentView(
                refreshService: refreshService,
                configurationStore: configurationStore
            )
        }
    }
}
