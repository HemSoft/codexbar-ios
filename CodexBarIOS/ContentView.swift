import SwiftUI

struct ContentView: View {
    @ObservedObject var refreshService: UsageRefreshService
    @ObservedObject var configurationStore: ProviderConfigurationStore
    @State private var isShowingSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(displayedResults) { result in
                        ProviderUsageCard(
                            result: result,
                            statusText: dashboardStatusText(for: result)
                        )
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
                            await refreshService.refresh()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(refreshService.isRefreshing)
                    .accessibilityLabel("Refresh usage")
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
            SettingsView(configurationStore: configurationStore)
        }
        .task {
            await refreshService.refresh()
        }
    }

    private var displayedResults: [ProviderUsageResult] {
        refreshService.results.filter { configurationStore.isConfigured($0.providerID) }
    }

    private func dashboardStatusText(for result: ProviderUsageResult) -> String {
        if configurationStore.isConfigured(result.providerID) {
            if result.subtitle.localizedCaseInsensitiveContains("not configured") {
                return configurationStore.statusText(for: result.providerID)
            }

            return result.subtitle
        }

        return configurationStore.statusText(for: result.providerID)
    }

    private func refreshAfterSettingsDismissed() {
        configurationStore.refreshSecretAvailability()
        Task {
            await refreshService.refresh()
        }
    }
}

#Preview {
    ContentView(
        refreshService: .demo(),
        configurationStore: ProviderConfigurationStore()
    )
}
