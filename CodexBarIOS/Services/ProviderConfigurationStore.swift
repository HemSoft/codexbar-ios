import Foundation

@MainActor
public final class ProviderConfigurationStore: ObservableObject {
    @Published public private(set) var configurations: [ProviderAccountConfiguration]
    @Published public private(set) var secretAvailability: [String: Bool]
    @Published public private(set) var appAppearance: AppAppearance
    @Published public private(set) var autoRefreshInterval: AutoRefreshInterval
    @Published public private(set) var widgetRefreshInterval: WidgetRefreshInterval
    @Published public private(set) var dashboardCardOrder: [String]
    @Published public private(set) var lastError: String?

    private let defaults: UserDefaults
    private let secretStore: SecretStore
    private let configurationsKey = DefaultsKey.configurations
    private let appAppearanceKey = DefaultsKey.appAppearance
    private let autoRefreshIntervalKey = DefaultsKey.autoRefreshInterval
    private let widgetRefreshIntervalKey = DefaultsKey.widgetRefreshInterval
    private let dashboardCardOrderKey = DefaultsKey.dashboardCardOrder

    public init(
        defaults: UserDefaults = .standard,
        secretStore: SecretStore = KeychainService()
    ) {
        self.defaults = defaults
        self.secretStore = secretStore
        self.configurations = Self.loadConfigurations(from: defaults)
        self.secretAvailability = [:]
        self.appAppearance = Self.loadAppAppearance(from: defaults)
        self.autoRefreshInterval = Self.loadAutoRefreshInterval(from: defaults)
        self.widgetRefreshInterval = Self.loadWidgetRefreshInterval(from: defaults)
        self.dashboardCardOrder = Self.loadDashboardCardOrder(from: defaults)
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
        let normalized = Self.normalizedConfiguration(configuration)
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
            secretAvailability = [:]
            dashboardCardOrder = []
            defaults.removeObject(forKey: configurationsKey)
            defaults.removeObject(forKey: dashboardCardOrderKey)
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

    public func updateDashboardCardOrder(_ accountIDs: [String]) {
        var seenAccountIDs = Set<String>()
        dashboardCardOrder = accountIDs.filter { seenAccountIDs.insert($0).inserted }
        defaults.set(dashboardCardOrder, forKey: dashboardCardOrderKey)
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
        static let appAppearance = "appAppearance"
        static let autoRefreshInterval = "autoRefreshInterval"
        static let widgetRefreshInterval = "widgetRefreshInterval"
        static let dashboardCardOrder = "dashboardCardOrder"
    }

    private static func loadConfigurations(from defaults: UserDefaults) -> [ProviderAccountConfiguration] {
        guard
            let data = defaults.data(forKey: DefaultsKey.configurations),
            let decoded = try? JSONDecoder().decode([ProviderAccountConfiguration].self, from: data)
        else {
            return []
        }

        return decoded
            .map(normalizedConfiguration)
            .sorted(by: configurationSort)
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

    private static func loadDashboardCardOrder(from defaults: UserDefaults) -> [String] {
        var seenAccountIDs = Set<String>()
        return (defaults.stringArray(forKey: DefaultsKey.dashboardCardOrder) ?? [])
            .filter { seenAccountIDs.insert($0).inserted }
    }

    private static func normalizedConfiguration(_ configuration: ProviderAccountConfiguration) -> ProviderAccountConfiguration {
        var normalized = configuration
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
        configurations.sort(by: Self.configurationSort)
    }

    private static func configurationSort(_ lhs: ProviderAccountConfiguration, _ rhs: ProviderAccountConfiguration) -> Bool {
        if lhs.providerID.displayName != rhs.providerID.displayName {
            return lhs.providerID.displayName < rhs.providerID.displayName
        }

        return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
    }

    private func isAccountNameUnique(_ configuration: ProviderAccountConfiguration) -> Bool {
        let name = configuration.displayName

        return !configurations.contains {
            $0.id != configuration.id
                && $0.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame
        }
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
