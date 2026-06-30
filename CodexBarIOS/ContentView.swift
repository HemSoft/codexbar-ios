import SwiftUI

struct ContentView: View {
    @ObservedObject var refreshService: UsageRefreshService
    @ObservedObject var configurationStore: ProviderConfigurationStore
    @State private var isShowingSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(refreshService.results) { result in
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
                if refreshService.results.isEmpty {
                    ContentUnavailableView(
                        "No Usage Data",
                        systemImage: "gauge.with.dots.needle.50percent",
                        description: Text("Add providers to start tracking usage.")
                    )
                }
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            SettingsView(configurationStore: configurationStore)
        }
        .task {
            await refreshService.refresh()
        }
    }

    private func dashboardStatusText(for result: ProviderUsageResult) -> String {
        if result.providerID == .codex && configurationStore.isConfigured(.codex) {
            return result.subtitle
        }

        return configurationStore.statusText(for: result.providerID)
    }
}

#Preview {
    ContentView(
        refreshService: .demo(),
        configurationStore: ProviderConfigurationStore()
    )
}
