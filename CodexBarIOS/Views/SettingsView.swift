import SwiftUI

struct SettingsView: View {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    var onAccountsChanged: @MainActor () -> Void = {}
    var onAccountRefresh: @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult? = { _ in nil }
    var onAlertAuthorizationRequest: @MainActor () async -> Bool = { false }

    @Environment(\.dismiss) private var dismiss
    @State private var isConfirmingReset = false
    @State private var alertPermissionMessage: String?
    @State private var newGroupName = ""
    @State private var groupNameDrafts: [String: String] = [:]
    @FocusState private var focusedGroupID: String?

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
                    Toggle("Usage Alerts", isOn: usageAlertsEnabledBinding)

                    Stepper(value: usageAlertUsagePercentBinding, in: 50...100, step: 5) {
                        Text("Usage at \(Int((configurationStore.usageAlertSettings.usageThreshold * 100).rounded()))%")
                    }
                    .disabled(!configurationStore.usageAlertSettings.isEnabled)

                    Stepper(value: usageAlertBalanceBinding, in: 1...100, step: 1) {
                        Text("Balance below \(formattedBalanceThreshold)")
                    }
                    .disabled(!configurationStore.usageAlertSettings.isEnabled)

                    Toggle("Warning and Critical Alerts", isOn: usageAlertSeverityBinding)
                        .disabled(!configurationStore.usageAlertSettings.isEnabled)

                    if let alertPermissionMessage {
                        Text(alertPermissionMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Alerts")
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
                    if configurationStore.groups.isEmpty {
                        Text("No groups")
                            .foregroundStyle(.secondary)
                    }

                    ForEach(configurationStore.groups) { group in
                        TextField(
                            "Group name",
                            text: groupNameBinding(for: group)
                        )
                        .textInputAutocapitalization(.words)
                        .focused($focusedGroupID, equals: group.id)
                        .onSubmit {
                            commitGroupName(for: group.id)
                        }
                    }
                    .onDelete(perform: deleteGroups)

                    HStack {
                        TextField("New group", text: $newGroupName)
                            .textInputAutocapitalization(.words)

                        Button {
                            addGroup()
                        } label: {
                            Image(systemName: "plus.circle.fill")
                        }
                        .disabled(newGroupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityLabel("Add group")
                    }
                } header: {
                    Text("Groups")
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
                                isConfigured: configurationStore.isConfigured(configuration),
                                groupName: configurationStore.group(for: configuration.groupID)?.name
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
                        if commitFocusedGroupName() {
                            dismiss()
                        }
                    }
                }
            }
            .interactiveDismissDisabled(!groupNameDrafts.isEmpty)
            .onChange(of: focusedGroupID) { oldValue, newValue in
                if let oldValue, oldValue != newValue {
                    commitGroupName(for: oldValue)
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

    private var usageAlertsEnabledBinding: Binding<Bool> {
        Binding(
            get: { configurationStore.usageAlertSettings.isEnabled },
            set: { isEnabled in
                if isEnabled {
                    Task {
                        let granted = await onAlertAuthorizationRequest()
                        configurationStore.updateUsageAlertsEnabled(granted)
                        alertPermissionMessage = granted ? nil : "Notifications are disabled for CodexBar."
                    }
                } else {
                    configurationStore.updateUsageAlertsEnabled(false)
                    alertPermissionMessage = nil
                }
            }
        )
    }

    private var usageAlertUsagePercentBinding: Binding<Double> {
        Binding(
            get: { configurationStore.usageAlertSettings.usageThreshold * 100 },
            set: { configurationStore.updateUsageAlertUsageThreshold($0 / 100) }
        )
    }

    private var usageAlertBalanceBinding: Binding<Double> {
        Binding(
            get: { configurationStore.usageAlertSettings.balanceThreshold },
            set: { configurationStore.updateUsageAlertBalanceThreshold($0) }
        )
    }

    private var usageAlertSeverityBinding: Binding<Bool> {
        Binding(
            get: { configurationStore.usageAlertSettings.includesSeverityAlerts },
            set: { configurationStore.updateUsageAlertIncludesSeverityAlerts($0) }
        )
    }

    private var formattedBalanceThreshold: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        return formatter.string(from: NSNumber(value: configurationStore.usageAlertSettings.balanceThreshold))
            ?? "$\(Int(configurationStore.usageAlertSettings.balanceThreshold.rounded()))"
    }

    private func deleteAccounts(at offsets: IndexSet) {
        let accounts = configurationStore.configurations
        for index in offsets {
            configurationStore.removeAccount(accounts[index])
        }
        onAccountsChanged()
    }

    private func addGroup() {
        guard configurationStore.addGroup(named: newGroupName) != nil else {
            return
        }

        newGroupName = ""
    }

    private func deleteGroups(at offsets: IndexSet) {
        let groups = configurationStore.groups
        for index in offsets {
            configurationStore.removeGroup(groups[index])
            groupNameDrafts[groups[index].id] = nil
        }
    }

    private func groupNameBinding(for group: ProviderAccountGroup) -> Binding<String> {
        Binding(
            get: {
                groupNameDrafts[group.id]
                    ?? configurationStore.group(for: group.id)?.name
                    ?? group.name
            },
            set: { name in
                groupNameDrafts[group.id] = name
            }
        )
    }

    private func commitFocusedGroupName() -> Bool {
        guard let focusedGroupID else {
            return true
        }

        return commitGroupName(for: focusedGroupID)
    }

    @discardableResult
    private func commitGroupName(for groupID: String) -> Bool {
        guard
            let group = configurationStore.group(for: groupID),
            let draftName = groupNameDrafts[groupID]
        else {
            return true
        }

        let normalizedName = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalizedName != group.name else {
            groupNameDrafts[groupID] = nil
            return true
        }

        var updated = group
        updated.name = draftName
        if configurationStore.updateGroup(updated) {
            groupNameDrafts[groupID] = nil
            return true
        }

        return false
    }
}

private struct ProviderSettingsRow: View {
    let configuration: ProviderAccountConfiguration
    let isConfigured: Bool
    let groupName: String?

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
                if let groupName {
                    Text(groupName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
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
