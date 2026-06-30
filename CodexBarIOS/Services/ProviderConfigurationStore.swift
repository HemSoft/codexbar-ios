import Foundation

@MainActor
public final class ProviderConfigurationStore: ObservableObject {
    @Published public private(set) var configurations: [ProviderAccountConfiguration]
    @Published public private(set) var secretAvailability: [ProviderID: Bool]
    @Published public private(set) var lastError: String?

    private let defaults: UserDefaults
    private let secretStore: SecretStore
    private let configurationsKey = "providerConfigurations"

    public init(
        defaults: UserDefaults = .standard,
        secretStore: SecretStore = KeychainService()
    ) {
        self.defaults = defaults
        self.secretStore = secretStore
        self.configurations = Self.loadConfigurations(from: defaults)
        self.secretAvailability = [:]
        refreshSecretAvailability()
    }

    public func configuration(for providerID: ProviderID) -> ProviderAccountConfiguration {
        configurations.first { $0.providerID == providerID }
            ?? .defaultConfiguration(for: providerID)
    }

    public func update(_ configuration: ProviderAccountConfiguration) {
        if let index = configurations.firstIndex(where: { $0.providerID == configuration.providerID }) {
            configurations[index] = configuration
        } else {
            configurations.append(configuration)
        }

        configurations.sort { $0.providerID.displayName < $1.providerID.displayName }
        saveConfigurations()
    }

    public func saveSecret(_ secret: String, for providerID: ProviderID) {
        do {
            if secret.isEmpty {
                try secretStore.deleteSecret(account: keychainAccount(for: providerID))
            } else {
                try secretStore.saveSecret(secret, account: keychainAccount(for: providerID))
            }

            lastError = nil
            refreshSecretAvailability()
        } catch {
            lastError = error.localizedDescription
        }
    }

    public func hasSecret(for providerID: ProviderID) -> Bool {
        secretAvailability[providerID] ?? false
    }

    public func isConfigured(_ providerID: ProviderID) -> Bool {
        let configuration = configuration(for: providerID)
        guard configuration.isEnabled else {
            return false
        }

        if configuration.requiresSecret {
            return hasSecret(for: providerID)
        }

        return !configuration.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func statusText(for providerID: ProviderID) -> String {
        let configuration = configuration(for: providerID)
        if !configuration.isEnabled {
            return "Disabled"
        }

        if isConfigured(providerID) {
            let label = configuration.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            if providerID == .codex {
                return label.isEmpty ? "Configured - live usage enabled" : "\(label) - live usage enabled"
            }

            return label.isEmpty ? "Configured - demo data" : "\(label) - demo data"
        }

        if providerID == .codex {
            return "Not configured - import auth.json"
        }

        return "Not configured - demo data"
    }

    public func refreshSecretAvailability() {
        var availability: [ProviderID: Bool] = [:]
        for providerID in ProviderID.allCases {
            availability[providerID] = ((try? secretStore.readSecret(account: keychainAccount(for: providerID))) ?? nil) != nil
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

    private func keychainAccount(for providerID: ProviderID) -> String {
        Self.keychainAccount(for: providerID)
    }

    private static func loadConfigurations(from defaults: UserDefaults) -> [ProviderAccountConfiguration] {
        guard
            let data = defaults.data(forKey: "providerConfigurations"),
            let decoded = try? JSONDecoder().decode([ProviderAccountConfiguration].self, from: data)
        else {
            return defaultConfigurations()
        }

        let decodedProviderIDs = Set(decoded.map(\.providerID))
        let missingConfigurations = ProviderID.allCases
            .filter { !decodedProviderIDs.contains($0) }
            .map(ProviderAccountConfiguration.defaultConfiguration)

        return (decoded + missingConfigurations)
            .map(normalizedConfiguration)
            .sorted { $0.providerID.displayName < $1.providerID.displayName }
    }

    private static func defaultConfigurations() -> [ProviderAccountConfiguration] {
        ProviderID.allCases
            .map(ProviderAccountConfiguration.defaultConfiguration)
            .sorted { $0.providerID.displayName < $1.providerID.displayName }
    }

    private static func normalizedConfiguration(_ configuration: ProviderAccountConfiguration) -> ProviderAccountConfiguration {
        guard configuration.providerID == .codex else {
            return configuration
        }

        var normalized = configuration
        normalized.authMethod = .codexAuthJSON
        return normalized
    }
}
