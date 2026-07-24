import StoreKit
import SwiftUI

enum SettingsScrollTarget: Hashable {
    case accounts
}

struct SettingsView: View {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    @ObservedObject var appUpdateController: AppUpdateController
    var initialScrollTarget: SettingsScrollTarget? = nil
    var onAccountsChanged: @MainActor () -> Void = {}
    var onAccountRefresh: @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult? = { _ in nil }
    var onAlertAuthorizationRequest: @MainActor () async -> Bool = { false }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.requestReview) private var requestReview
    @State private var isConfirmingReset = false
    @State private var isConfirmingConfigurationReplacement = false
    @State private var alertPermissionMessage: String?
    @State private var newGroupName = ""
    @State private var groupNameDrafts: [String: String] = [:]
    @FocusState private var focusedGroupID: String?

    var body: some View {
        NavigationStack {
            settingsList
        }
    }

    private var settingsList: some View {
        ScrollViewReader { proxy in
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "gauge.with.dots.needle.50percent")
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .frame(width: 36, height: 36)
                            .accessibilityHidden(true)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("CodexBar")
                                .font(.headline)
                            Text(appUpdateController.installedVersion.displayText)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(
                        "CodexBar, \(appUpdateController.installedVersion.displayText)"
                    )

                    if let release = appUpdateController.availableRelease {
                        LabeledContent {
                            Text("Version \(release.version)")
                                .foregroundStyle(.secondary)
                        } label: {
                            Label("Update Available", systemImage: "arrow.down.app")
                        }

                        Link(destination: release.productURL) {
                            Label("Update", systemImage: "arrow.up.forward.app")
                        }
                    }

                    Button {
                        Task {
                            await appUpdateController.checkForUpdates(force: true)
                        }
                    } label: {
                        HStack {
                            Label("Check for Updates", systemImage: "arrow.clockwise")
                            Spacer()
                            if appUpdateController.isChecking {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                    }
                    .disabled(appUpdateController.isChecking)
                }

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
                    Picker("Ordering", selection: dashboardOrderingModeBinding) {
                        ForEach(DashboardOrderingMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Dashboard")
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

                    NavigationLink {
                        WidgetBuilderView()
                    } label: {
                        Label("Widget Builder", systemImage: "square.grid.2x2")
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
                            .onSubmit {
                                addGroup()
                            }

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
                    .disabled(configurationStore.isConfigurationRecoveryRequired)
                } header: {
                    Text("Accounts")
                }
                .id(SettingsScrollTarget.accounts)

                Section {
                    Link(destination: AppReviewLinks.writeReviewURL) {
                        Label("Rate CodexBar", systemImage: "star")
                    }

                    Link(destination: AppReviewLinks.supportURL) {
                        Label("Get Support", systemImage: "questionmark.circle")
                    }

                    #if DEBUG
                    if AppStoreScreenshotConfiguration.current == nil {
                        Button {
                            requestReview()
                        } label: {
                            Label("Test Rating Prompt", systemImage: "star.bubble")
                        }
                    }
                    #endif
                } header: {
                    Text("Support")
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

                        if configurationStore.isConfigurationRecoveryRequired {
                            Button("Replace Damaged Account List", role: .destructive) {
                                isConfirmingConfigurationReplacement = true
                            }
                        }
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
                    if configurationStore.resetAccounts() {
                        onAccountsChanged()
                    }
                }
            } message: {
                Text("This removes account entries and saved provider credentials from this device.")
            }
            .confirmationDialog(
                "Replace unreadable account data?",
                isPresented: $isConfirmingConfigurationReplacement,
                titleVisibility: .visible
            ) {
                Button("Replace Account Data", role: .destructive) {
                    if OpenCodeZenBootstrapImporter.replaceCorruptedConfigurationsAndImportIfNeeded(
                        configurationStore: configurationStore
                    ) {
                        onAccountsChanged()
                    }
                }
            } message: {
                Text(
                    "This replaces the damaged account list with an empty list so you can add accounts again. Saved Keychain credentials are not deleted."
                )
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
            .task(id: initialScrollTarget) {
                guard let initialScrollTarget else {
                    return
                }

                await Task.yield()
                proxy.scrollTo(initialScrollTarget, anchor: .top)
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

    private var dashboardOrderingModeBinding: Binding<DashboardOrderingMode> {
        Binding(
            get: { configurationStore.dashboardOrderingMode },
            set: { configurationStore.updateDashboardOrderingMode($0) }
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
        Self.balanceThresholdFormatter.string(
            from: NSNumber(value: configurationStore.usageAlertSettings.balanceThreshold)
        )
            ?? "$\(Int(configurationStore.usageAlertSettings.balanceThreshold.rounded()))"
    }

    private static let balanceThresholdFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        return formatter
    }()

    private func deleteAccounts(at offsets: IndexSet) {
        let accounts = configurationStore.configurations
        let accountsToRemove = offsets.map { accounts[$0] }
        if configurationStore.removeAccounts(accountsToRemove) {
            onAccountsChanged()
        }
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
        case .moonshot:
            "moon.stars"
        case .cursor:
            "cursorarrow"
        }
    }
}

#Preview {
    SettingsView(
        configurationStore: ProviderConfigurationStore(),
        appUpdateController: AppUpdateController()
    )
}
