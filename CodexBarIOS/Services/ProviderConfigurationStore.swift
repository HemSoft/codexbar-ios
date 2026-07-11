import Foundation

@MainActor
public final class ProviderConfigurationStore: ObservableObject {
    @Published public private(set) var configurations: [ProviderAccountConfiguration]
    @Published public private(set) var groups: [ProviderAccountGroup]
    @Published public private(set) var secretAvailability: [String: Bool]
    @Published public private(set) var appAppearance: AppAppearance
    @Published public private(set) var autoRefreshInterval: AutoRefreshInterval
    @Published public private(set) var widgetRefreshInterval: WidgetRefreshInterval
    @Published public private(set) var dashboardOrderingMode: DashboardOrderingMode
    @Published public private(set) var dashboardCardOrder: [String]
    @Published public private(set) var usageAlertSettings: UsageAlertSettings
    @Published public private(set) var usageAlertActiveIDs: Set<String>
    @Published public private(set) var lastError: String?

    private let defaults: UserDefaults
    private let secretStore: SecretStore
    private let configurationsKey = DefaultsKey.configurations
    private let groupsKey = DefaultsKey.groups
    private let appAppearanceKey = DefaultsKey.appAppearance
    private let autoRefreshIntervalKey = DefaultsKey.autoRefreshInterval
    private let widgetRefreshIntervalKey = DefaultsKey.widgetRefreshInterval
    private let dashboardOrderingModeKey = DefaultsKey.dashboardOrderingMode
    private let dashboardCardOrderKey = DefaultsKey.dashboardCardOrder
    private let usageAlertSettingsKey = DefaultsKey.usageAlertSettings
    private let usageAlertActiveIDsKey = DefaultsKey.usageAlertActiveIDs

    public init(
        defaults: UserDefaults = .standard,
        secretStore: SecretStore = KeychainService()
    ) {
        let loadedGroups = Self.loadGroups(from: defaults)
        self.defaults = defaults
        self.secretStore = secretStore
        self.groups = loadedGroups
        self.configurations = Self.loadConfigurations(
            from: defaults,
            validGroupIDs: Set(loadedGroups.map(\.id))
        )
        self.secretAvailability = [:]
        self.appAppearance = Self.loadAppAppearance(from: defaults)
        self.autoRefreshInterval = Self.loadAutoRefreshInterval(from: defaults)
        self.widgetRefreshInterval = Self.loadWidgetRefreshInterval(from: defaults)
        self.dashboardOrderingMode = Self.loadDashboardOrderingMode(from: defaults)
        self.dashboardCardOrder = Self.loadDashboardCardOrder(from: defaults)
        self.usageAlertSettings = Self.loadUsageAlertSettings(from: defaults)
        self.usageAlertActiveIDs = Self.loadUsageAlertActiveIDs(from: defaults)
        sortConfigurations()
        refreshSecretAvailability()
    }

    public func configuration(for providerID: ProviderID) -> ProviderAccountConfiguration {
        configurations.first { $0.providerID == providerID }
            ?? .defaultConfiguration(for: providerID)
    }

    public func configuration(accountID: String) -> ProviderAccountConfiguration? {
        configurations.first { $0.id == accountID }
    }

    public func configurations(for providerID: ProviderID) -> [ProviderAccountConfiguration] {
        configurations.filter { $0.providerID == providerID }
    }

    public func group(for groupID: String?) -> ProviderAccountGroup? {
        guard let groupID else {
            return nil
        }

        return groups.first { $0.id == groupID }
    }

    public func groupName(for groupID: String?) -> String {
        group(for: groupID)?.name ?? ProviderAccountGroup.ungroupedDisplayName
    }

    @discardableResult
    public func addGroup(named name: String) -> ProviderAccountGroup? {
        let normalizedName = Self.normalizedGroupName(name)
        guard !normalizedName.isEmpty else {
            lastError = "Group names cannot be empty."
            return nil
        }

        guard isGroupNameUnique(normalizedName) else {
            lastError = "Group names must be unique."
            return nil
        }

        let group = ProviderAccountGroup(name: normalizedName)
        groups.append(group)
        sortGroups()
        saveGroups()
        return group
    }

    @discardableResult
    public func updateGroup(_ group: ProviderAccountGroup) -> Bool {
        let normalizedName = Self.normalizedGroupName(group.name)
        guard !normalizedName.isEmpty else {
            lastError = "Group names cannot be empty."
            return false
        }

        guard isGroupNameUnique(normalizedName, excluding: group.id) else {
            lastError = "Group names must be unique."
            return false
        }

        guard let index = groups.firstIndex(where: { $0.id == group.id }) else {
            lastError = "Group no longer exists."
            return false
        }

        groups[index].name = normalizedName
        sortGroups()
        sortConfigurations()
        saveGroups()
        saveConfigurations()
        return true
    }

    public func removeGroup(_ group: ProviderAccountGroup) {
        groups.removeAll { $0.id == group.id }
        configurations = configurations.map { configuration in
            var updated = configuration
            if updated.groupID == group.id {
                updated.groupID = nil
            }
            return updated
        }
        sortGroups()
        sortConfigurations()
        saveGroups()
        saveConfigurations()
    }

    @discardableResult
    public func addAccount(for providerID: ProviderID) -> ProviderAccountConfiguration {
        addAccount(for: providerID, copilotScope: .personal)
    }

    @discardableResult
    public func addAccount(for providerID: ProviderID, copilotScope: CopilotAccountScope) -> ProviderAccountConfiguration {
        var configuration = ProviderAccountConfiguration
            .defaultConfiguration(for: providerID)
            .withNewAccountID()
        if providerID == .copilot {
            configuration.copilotAccountScope = copilotScope
        }
        configuration.accountLabel = suggestedAccountLabel(for: providerID)
        configurations.append(configuration)
        sortConfigurations()
        saveConfigurations()
        refreshSecretAvailability()
        return configuration
    }

    @discardableResult
    public func update(_ configuration: ProviderAccountConfiguration) -> Bool {
        let normalized = Self.normalizedConfiguration(
            configuration,
            validGroupIDs: Set(groups.map(\.id))
        )
        guard isAccountNameUnique(normalized) else {
            lastError = "Account names must be unique."
            return false
        }

        if let index = configurations.firstIndex(where: { $0.id == normalized.id }) {
            configurations[index] = normalized
        } else {
            configurations.append(normalized)
        }

        sortConfigurations()
        saveConfigurations()
        return true
    }

    public func removeAccount(_ configuration: ProviderAccountConfiguration) {
        configurations.removeAll { $0.id == configuration.id }
        do {
            try secretStore.deleteSecret(account: keychainAccount(for: configuration))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        sortConfigurations()
        saveConfigurations()
        refreshSecretAvailability()
    }

    public func resetAccounts() {
        let accountsToDelete = Set(
            configurations.map { keychainAccount(for: $0) }
                + ProviderID.allCases.map { keychainAccount(for: $0) }
        )

        do {
            for account in accountsToDelete {
                try secretStore.deleteSecret(account: account)
            }

            configurations = []
            groups = []
            secretAvailability = [:]
            dashboardCardOrder = []
            usageAlertActiveIDs = []
            defaults.removeObject(forKey: configurationsKey)
            defaults.removeObject(forKey: groupsKey)
            defaults.removeObject(forKey: dashboardCardOrderKey)
            defaults.removeObject(forKey: usageAlertActiveIDsKey)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            refreshSecretAvailability()
        }
    }

    public func updateAppAppearance(_ appearance: AppAppearance) {
        appAppearance = appearance
        defaults.set(appearance.rawValue, forKey: appAppearanceKey)
    }

    public func updateAutoRefreshInterval(_ interval: AutoRefreshInterval) {
        autoRefreshInterval = interval
        defaults.set(interval.rawValue, forKey: autoRefreshIntervalKey)
    }

    public func updateWidgetRefreshInterval(_ interval: WidgetRefreshInterval) {
        widgetRefreshInterval = interval
        defaults.set(interval.rawValue, forKey: widgetRefreshIntervalKey)
        WidgetSnapshotStore.saveRefreshInterval(interval)
    }

    public func updateDashboardOrderingMode(_ mode: DashboardOrderingMode) {
        dashboardOrderingMode = mode
        defaults.set(mode.rawValue, forKey: dashboardOrderingModeKey)
    }

    public func updateDashboardCardOrder(_ accountIDs: [String]) {
        var seenAccountIDs = Set<String>()
        dashboardCardOrder = accountIDs.filter { seenAccountIDs.insert($0).inserted }
        defaults.set(dashboardCardOrder, forKey: dashboardCardOrderKey)
    }

    public func updateUsageAlertSettings(_ settings: UsageAlertSettings) {
        let previousSettings = usageAlertSettings
        usageAlertSettings = settings
        saveUsageAlertSettings()

        if settings != previousSettings {
            updateUsageAlertActiveIDs([])
        }
    }

    public func updateUsageAlertsEnabled(_ isEnabled: Bool) {
        var settings = usageAlertSettings
        settings.isEnabled = isEnabled
        updateUsageAlertSettings(settings)
    }

    public func updateUsageAlertUsageThreshold(_ threshold: Double) {
        var settings = usageAlertSettings
        settings.usageThreshold = UsageAlertSettings.normalizedUsageThreshold(threshold)
        updateUsageAlertSettings(settings)
    }

    public func updateUsageAlertBalanceThreshold(_ threshold: Double) {
        var settings = usageAlertSettings
        settings.balanceThreshold = UsageAlertSettings.normalizedBalanceThreshold(threshold)
        updateUsageAlertSettings(settings)
    }

    public func updateUsageAlertIncludesSeverityAlerts(_ includesSeverityAlerts: Bool) {
        var settings = usageAlertSettings
        settings.includesSeverityAlerts = includesSeverityAlerts
        updateUsageAlertSettings(settings)
    }

    public func updateUsageAlertActiveIDs(_ activeIDs: Set<String>) {
        usageAlertActiveIDs = activeIDs
        defaults.set(Array(activeIDs).sorted(), forKey: usageAlertActiveIDsKey)
    }

    public func saveSecret(_ secret: String, for providerID: ProviderID) {
        saveSecret(secret, for: configuration(for: providerID))
    }

    public func saveSecret(_ secret: String, for configuration: ProviderAccountConfiguration) {
        do {
            if secret.isEmpty {
                try secretStore.deleteSecret(account: keychainAccount(for: configuration))
            } else {
                try secretStore.saveSecret(secret, account: keychainAccount(for: configuration))
            }

            lastError = nil
            refreshSecretAvailability()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func hasSecret(for providerID: ProviderID) -> Bool {
        hasSecret(for: configuration(for: providerID))
    }

    public func hasSecret(for configuration: ProviderAccountConfiguration) -> Bool {
        secretAvailability[configuration.id] ?? false
    }

    public func isConfigured(_ providerID: ProviderID) -> Bool {
        configurations(for: providerID).contains { isConfigured($0) }
    }

    public func isConfigured(_ configuration: ProviderAccountConfiguration) -> Bool {
        guard configurations.contains(where: { $0.id == configuration.id }) else {
            return false
        }

        return isConfigurationReady(configuration)
    }

    public func shouldDisplayOnDashboard(_ configuration: ProviderAccountConfiguration) -> Bool {
        guard configuration.isEnabled, configurations.contains(where: { $0.id == configuration.id }) else {
            return false
        }

        if isConfigurationReady(configuration) {
            return true
        }

        if configuration.providerID == .openCodeZen {
            return hasSecret(for: configuration)
                || !configuration.openCodeWorkspaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        return false
    }

    private func isConfigurationReady(_ configuration: ProviderAccountConfiguration) -> Bool {
        guard configuration.isEnabled else {
            return false
        }

        if configuration.providerID == .copilot {
            let organization = configuration.githubOrganization.trimmingCharacters(in: .whitespacesAndNewlines)
            return hasSecret(for: configuration)
                && (configuration.copilotAccountScope == .personal || !organization.isEmpty)
        }

        if configuration.providerID == .openCodeZen {
            return hasSecret(for: configuration)
                && !configuration.openCodeWorkspaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        if configuration.requiresSecret
            || configuration.providerID == .codex
            || configuration.providerID == .claude
            || configuration.providerID == .cursor
        {
            return hasSecret(for: configuration)
        }

        return !configuration.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func statusText(for providerID: ProviderID) -> String {
        let configuration = configuration(for: providerID)
        return statusText(for: configuration)
    }

    public func statusText(for configuration: ProviderAccountConfiguration) -> String {
        if !configuration.isEnabled {
            return "Disabled"
        }

        if isConfigurationReady(configuration) {
            let label = configuration.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if configuration.providerID == .codex
                || configuration.providerID == .copilot
                || configuration.providerID == .claude
                || configuration.providerID == .cursor
            {
                return label.isEmpty ? "Configured - live usage enabled" : "\(label) - live usage enabled"
            }

            return label.isEmpty ? "Configured" : label
        }

        if configuration.providerID == .codex {
            return "Not configured - sign in with ChatGPT"
        }

        if configuration.providerID == .copilot {
            if configuration.copilotAccountScope == .organization
                && configuration.githubOrganization.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return "Not configured - enter organization"
            }

            return "Not configured - sign in with GitHub"
        }

        if configuration.providerID == .claude {
            return "Not configured - sign in with Claude"
        }

        if configuration.providerID == .cursor {
            return "Not configured - sign in with Cursor"
        }

        if configuration.providerID == .openCodeZen {
            if configuration.openCodeWorkspaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "Not configured - enter OpenCode workspace ID"
            }

            return "Not configured - enter OpenCode dashboard auth value"
        }

        return "Not configured"
    }

    public func refreshSecretAvailability() {
        var availability: [String: Bool] = [:]
        for configuration in configurations {
            let account = keychainAccount(for: configuration)
            availability[configuration.id] = ((try? secretStore.readSecret(account: account)) ?? nil) != nil
        }

        secretAvailability = availability
    }

    private func saveConfigurations() {
        do {
            let data = try JSONEncoder().encode(configurations)
            defaults.set(data, forKey: configurationsKey)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func saveGroups() {
        do {
            let data = try JSONEncoder().encode(groups)
            defaults.set(data, forKey: groupsKey)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func saveUsageAlertSettings() {
        do {
            let data = try JSONEncoder().encode(usageAlertSettings)
            defaults.set(data, forKey: usageAlertSettingsKey)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    public nonisolated static func keychainAccount(for providerID: ProviderID) -> String {
        "provider.\(providerID.rawValue).credential"
    }

    public nonisolated static func keychainAccount(for configuration: ProviderAccountConfiguration) -> String {
        if configuration.id == configuration.providerID.rawValue {
            return keychainAccount(for: configuration.providerID)
        }

        return "providerAccount.\(configuration.id).credential"
    }

    private func keychainAccount(for providerID: ProviderID) -> String {
        Self.keychainAccount(for: providerID)
    }

    private func keychainAccount(for configuration: ProviderAccountConfiguration) -> String {
        Self.keychainAccount(for: configuration)
    }

    private enum DefaultsKey {
        static let configurations = "providerConfigurations"
        static let groups = "providerAccountGroups"
        static let appAppearance = "appAppearance"
        static let autoRefreshInterval = "autoRefreshInterval"
        static let widgetRefreshInterval = "widgetRefreshInterval"
        static let dashboardOrderingMode = "dashboardOrderingMode"
        static let dashboardCardOrder = "dashboardCardOrder"
        static let usageAlertSettings = "usageAlertSettings"
        static let usageAlertActiveIDs = "usageAlertActiveIDs"
    }

    private static func loadConfigurations(
        from defaults: UserDefaults,
        validGroupIDs: Set<String>? = nil
    ) -> [ProviderAccountConfiguration] {
        guard
            let data = defaults.data(forKey: DefaultsKey.configurations),
            let decoded = try? JSONDecoder().decode([ProviderAccountConfiguration].self, from: data)
        else {
            return []
        }

        return decoded
            .map { normalizedConfiguration($0, validGroupIDs: validGroupIDs) }
            .sorted { configurationSort($0, $1) }
    }

    private static func loadGroups(from defaults: UserDefaults) -> [ProviderAccountGroup] {
        guard
            let data = defaults.data(forKey: DefaultsKey.groups),
            let decoded = try? JSONDecoder().decode([ProviderAccountGroup].self, from: data)
        else {
            return []
        }

        var seenIDs = Set<String>()
        var seenNames = Set<String>()
        return decoded.compactMap { group in
            let name = normalizedGroupName(group.name)
            let nameKey = name.lowercased()
            guard !name.isEmpty,
                  seenIDs.insert(group.id).inserted,
                  seenNames.insert(nameKey).inserted
            else {
                return nil
            }

            return ProviderAccountGroup(id: group.id, name: name)
        }
        .sorted(by: groupSort)
    }

    private static func loadAppAppearance(from defaults: UserDefaults) -> AppAppearance {
        guard
            let rawValue = defaults.string(forKey: DefaultsKey.appAppearance),
            let appearance = AppAppearance(rawValue: rawValue)
        else {
            return .system
        }

        return appearance
    }

    private static func loadAutoRefreshInterval(from defaults: UserDefaults) -> AutoRefreshInterval {
        guard
            defaults.object(forKey: DefaultsKey.autoRefreshInterval) != nil,
            let interval = AutoRefreshInterval(rawValue: defaults.integer(forKey: DefaultsKey.autoRefreshInterval))
        else {
            return .off
        }

        return interval
    }

    private static func loadWidgetRefreshInterval(from defaults: UserDefaults) -> WidgetRefreshInterval {
        guard
            defaults.object(forKey: DefaultsKey.widgetRefreshInterval) != nil,
            let interval = WidgetRefreshInterval(rawValue: defaults.integer(forKey: DefaultsKey.widgetRefreshInterval))
        else {
            return WidgetSnapshotStore.loadRefreshInterval()
        }

        WidgetSnapshotStore.saveRefreshInterval(interval)
        return interval
    }

    private static func loadDashboardOrderingMode(from defaults: UserDefaults) -> DashboardOrderingMode {
        guard
            let rawValue = defaults.string(forKey: DefaultsKey.dashboardOrderingMode),
            let mode = DashboardOrderingMode(rawValue: rawValue)
        else {
            return .manual
        }

        return mode
    }

    private static func loadDashboardCardOrder(from defaults: UserDefaults) -> [String] {
        var seenAccountIDs = Set<String>()
        return (defaults.stringArray(forKey: DefaultsKey.dashboardCardOrder) ?? [])
            .filter { seenAccountIDs.insert($0).inserted }
    }

    private static func loadUsageAlertSettings(from defaults: UserDefaults) -> UsageAlertSettings {
        guard
            let data = defaults.data(forKey: DefaultsKey.usageAlertSettings),
            let decoded = try? JSONDecoder().decode(UsageAlertSettings.self, from: data)
        else {
            return UsageAlertSettings()
        }

        return UsageAlertSettings(
            isEnabled: decoded.isEnabled,
            usageThreshold: decoded.usageThreshold,
            balanceThreshold: decoded.balanceThreshold,
            includesSeverityAlerts: decoded.includesSeverityAlerts
        )
    }

    private static func loadUsageAlertActiveIDs(from defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: DefaultsKey.usageAlertActiveIDs) ?? [])
    }

    private static func normalizedConfiguration(
        _ configuration: ProviderAccountConfiguration,
        validGroupIDs: Set<String>? = nil
    ) -> ProviderAccountConfiguration {
        var normalized = configuration
        if let validGroupIDs, let groupID = normalized.groupID, !validGroupIDs.contains(groupID) {
            normalized.groupID = nil
        }

        switch configuration.providerID {
        case .codex:
            normalized.authMethod = .browserSession
        case .cursor:
            normalized.authMethod = .browserSession
        case .copilot, .claude, .openRouter, .openCodeZen:
            break
        }
        return normalized
    }

    private func sortConfigurations() {
        let groupNames = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0.name) })
        configurations.sort {
            Self.configurationSort($0, $1, groupNames: groupNames)
        }
    }

    private func sortGroups() {
        groups.sort(by: Self.groupSort)
    }

    private static func configurationSort(
        _ lhs: ProviderAccountConfiguration,
        _ rhs: ProviderAccountConfiguration,
        groupNames: [String: String] = [:]
    ) -> Bool {
        let lhsGroup = lhs.groupID.flatMap { groupNames[$0] } ?? ""
        let rhsGroup = rhs.groupID.flatMap { groupNames[$0] } ?? ""
        if lhsGroup != rhsGroup {
            return lhsGroup.localizedCaseInsensitiveCompare(rhsGroup) == .orderedAscending
        }

        if lhs.providerID.displayName != rhs.providerID.displayName {
            return lhs.providerID.displayName < rhs.providerID.displayName
        }

        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    private static func groupSort(_ lhs: ProviderAccountGroup, _ rhs: ProviderAccountGroup) -> Bool {
        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func isAccountNameUnique(_ configuration: ProviderAccountConfiguration) -> Bool {
        let name = configuration.displayName

        return !configurations.contains {
            $0.id != configuration.id
                && $0.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    private func isGroupNameUnique(_ name: String, excluding groupID: String? = nil) -> Bool {
        !groups.contains {
            $0.id != groupID
                && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
    }

    private static func normalizedGroupName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func suggestedAccountLabel(for providerID: ProviderID) -> String {
        let base = providerID.displayName
        var index = configurations(for: providerID).count + 1
        while true {
            let candidate = "\(base) \(index)"
            let matchesExisting = configurations.contains {
                $0.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(candidate) == .orderedSame
            }
            if !matchesExisting {
                return candidate
            }
            index += 1
        }
    }
}

#if DEBUG
public extension ProviderConfigurationStore {
    static func appStoreScreenshotDemo() -> ProviderConfigurationStore {
        let suiteName = "com.hemsoft.CodexBarIOS.appStoreScreenshots"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return ProviderConfigurationStore(secretStore: AppStoreScreenshotSecretStore(accounts: []))
        }

        defaults.removePersistentDomain(forName: suiteName)

        let usageGroup = ProviderAccountGroup(id: AppStoreScreenshotFixtureID.usageGroup, name: "Usage Limits")
        let balanceGroup = ProviderAccountGroup(id: AppStoreScreenshotFixtureID.balanceGroup, name: "API Balances")
        let configurations = [
            ProviderAccountConfiguration(
                id: AppStoreScreenshotFixtureID.codexAccount,
                providerID: .codex,
                accountLabel: "Personal Codex",
                groupID: usageGroup.id,
                authMethod: .browserSession
            ),
            ProviderAccountConfiguration(
                id: AppStoreScreenshotFixtureID.copilotAccount,
                providerID: .copilot,
                accountLabel: "GitHub Copilot",
                groupID: usageGroup.id,
                authMethod: .browserSession,
                copilotAccountScope: .organization,
                githubOrganization: "fableton-labs"
            ),
            ProviderAccountConfiguration(
                id: AppStoreScreenshotFixtureID.claudeAccount,
                providerID: .claude,
                accountLabel: "Claude Pro",
                groupID: usageGroup.id,
                authMethod: .browserSession
            ),
            ProviderAccountConfiguration(
                id: AppStoreScreenshotFixtureID.cursorAccount,
                providerID: .cursor,
                accountLabel: "Cursor Pro",
                groupID: usageGroup.id,
                authMethod: .browserSession
            ),
            ProviderAccountConfiguration(
                id: AppStoreScreenshotFixtureID.openRouterAccount,
                providerID: .openRouter,
                accountLabel: "OpenRouter",
                groupID: balanceGroup.id,
                authMethod: .apiKey
            ),
            ProviderAccountConfiguration(
                id: AppStoreScreenshotFixtureID.openCodeZenAccount,
                providerID: .openCodeZen,
                accountLabel: "OpenCode ZEN",
                groupID: balanceGroup.id,
                authMethod: .apiKey,
                openCodeWorkspaceId: "demo-workspace"
            )
        ]

        let encoder = JSONEncoder()
        defaults.set(try? encoder.encode([usageGroup, balanceGroup]), forKey: DefaultsKey.groups)
        defaults.set(try? encoder.encode(configurations), forKey: DefaultsKey.configurations)
        defaults.set(DashboardOrderingMode.manual.rawValue, forKey: DefaultsKey.dashboardOrderingMode)
        defaults.set(configurations.map(\.id), forKey: DefaultsKey.dashboardCardOrder)

        let accounts = Set(configurations.map(Self.keychainAccount(for:)))
        return ProviderConfigurationStore(defaults: defaults, secretStore: AppStoreScreenshotSecretStore(accounts: accounts))
    }
}

private struct AppStoreScreenshotSecretStore: SecretStore {
    let accounts: Set<String>

    func readSecret(account: String) throws -> String? {
        accounts.contains(account) ? "app-store-screenshot-secret" : nil
    }

    func saveSecret(_ secret: String, account: String) throws {}

    func deleteSecret(account: String) throws {}
}
#endif
