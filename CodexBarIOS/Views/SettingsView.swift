import SwiftUI

struct SettingsView: View {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Appearance", selection: appearanceBinding) {
                        ForEach(AppAppearance.allCases) { appearance in
                            Text(appearance.displayName).tag(appearance)
                        }
                    }
                }

                Section {
                    ForEach(configurationStore.configurations) { configuration in
                        NavigationLink {
                            ProviderSettingsView(
                                configurationStore: configurationStore,
                                providerID: configuration.providerID
                            )
                        } label: {
                            ProviderSettingsRow(
                                configuration: configuration,
                                isConfigured: configurationStore.isConfigured(configuration.providerID)
                            )
                        }
                    }
                }

                if let lastError = configurationStore.lastError {
                    Section {
                        Text(lastError)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Settings")
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
                Text(configuration.providerID.displayName)
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

        return isConfigured ? "Configured" : "Needs account setup"
    }
}

#Preview {
    SettingsView(configurationStore: ProviderConfigurationStore())
}
