import SwiftUI

struct SettingsView: View {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    var onAccountsChanged: @MainActor () -> Void = {}
    var onAccountRefresh: @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult? = { _ in nil }

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingReset = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Color Scheme", selection: appearanceBinding) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.displayName).tag(appearance)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Appearance")
                }

                Section {
                    Picker("Refresh", selection: autoRefreshIntervalBinding) {
                        ForEach(AutoRefreshInterval.allCases) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }
                } header: {
                    Text("Auto Refresh")
                }

                Section {
                    Picker("Update Preference", selection: widgetRefreshIntervalBinding) {
                        ForEach(WidgetRefreshInterval.allCases) { interval in
                            Text(interval.displayName).tag(interval)
                        }
                    }

                    Text("Widgets use the latest app snapshot and ask iOS to reload on this cadence. iOS may adjust timing to preserve battery.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Widgets")
                }

                Section {
                    if configurationStore.configurations.isEmpty {
                        Text("No accounts")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(configurationStore.configurations) { configuration in
                        NavigationLink {
                            ProviderSettingsView(
                                configurationStore: configurationStore,
                                accountID: configuration.id,
                                onCredentialsChanged: onAccountsChanged,
                                onAccountRefresh: onAccountRefresh
                            )
                        } label: {
                            ProviderSettingsRow(
                                configuration: configuration,
                                isConfigured: configurationStore.isConfigured(configuration)
                            )
                        }
                    }
                    .onDelete(perform: deleteAccounts)

                    Menu {
                        ForEach(ProviderID.allCases) { providerID in
                            Button {
                                _ = configurationStore.addAccount(for: providerID)
                            } label: {
                                Label(providerID.displayName, systemImage: providerID.addAccountIconName)
                            }
                        }
                    } label: {
                        Label("Add Account", systemImage: "plus.circle")
                    }
                } header: {
                    Text("Accounts")
                }

                Section {
                    Button("Reset Accounts", role: .destructive) {
                        isConfirmingReset = true
                    }
                    .disabled(configurationStore.configurations.isEmpty)
                }

                if let lastError = configurationStore.lastError {
                    Section {
                        Text(lastError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog(
                "Reset all accounts?",
                isPresented: $isConfirmingReset,
                titleVisibility: .visible
            ) {
                Button("Reset Accounts", role: .destructive) {
                    configurationStore.resetAccounts()
                    onAccountsChanged()
                }
            } message: {
                Text("This removes account entries and saved provider credentials from this device.")
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var appearanceBinding: Binding<AppAppearance> {
        Binding(
            get: { configurationStore.appAppearance },
            set: { configurationStore.updateAppAppearance($0) }
        )
    }

    private var autoRefreshIntervalBinding: Binding<AutoRefreshInterval> {
        Binding(
            get: { configurationStore.autoRefreshInterval },
            set: { configurationStore.updateAutoRefreshInterval($0) }
        )
    }

    private var widgetRefreshIntervalBinding: Binding<WidgetRefreshInterval> {
        Binding(
            get: { configurationStore.widgetRefreshInterval },
            set: { configurationStore.updateWidgetRefreshInterval($0) }
        )
    }

    private func deleteAccounts(at offsets: IndexSet) {
        let accounts = configurationStore.configurations
        for index in offsets {
            configurationStore.removeAccount(accounts[index])
        }
        onAccountsChanged()
    }
}

private struct ProviderSettingsRow: View {
    let configuration: ProviderAccountConfiguration
    let isConfigured: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: statusIcon)
                .foregroundStyle(statusTint)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(configuration.displayName)
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusIcon: String {
        if !configuration.isEnabled {
            return "pause.circle"
        }

        return isConfigured ? "checkmark.circle.fill" : "exclamationmark.circle"
    }

    private var statusTint: Color {
        if !configuration.isEnabled {
            return .secondary
        }

        return isConfigured ? .green : .orange
    }

    private var statusText: String {
        if !configuration.isEnabled {
            return "Disabled"
        }

        let provider = configuration.providerID.displayName
        return isConfigured ? "\(provider) configured" : "\(provider) needs setup"
    }
}

private extension ProviderID {
    var addAccountIconName: String {
        switch self {
        case .codex:
            "sparkles"
        case .copilot:
            "chevron.left.forwardslash.chevron.right"
        case .claude:
            "text.bubble"
        case .openRouter:
            "network"
        case .openCodeZen:
            "dollarsign.circle"
        case .cursor:
            "cursorarrow"
        }
    }
}

#Preview {
    SettingsView(configurationStore: ProviderConfigurationStore())
}
