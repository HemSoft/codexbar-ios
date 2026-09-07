import Foundation

#if DEBUG
/// Installs an existing session during a developer-controlled device deployment.
/// This is excluded from release builds and is never an end-user setup flow.
@MainActor
enum DeveloperGoogleSessionInstaller {
    static let fileName = "google-coding-development-session.json"
    static let launchArgument = "--install-development-google-session"

    private struct Payload: Decodable {
        let accountID: String
        let credential: String
        let confirmedSameAccount: Bool
    }

    static func installIfRequested(
        configurationStore: ProviderConfigurationStore,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        directory: URL? = nil
    ) -> Bool {
        guard arguments.contains(launchArgument),
              let directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return false }
        let url = directory.appendingPathComponent(fileName)
        defer { try? FileManager.default.removeItem(at: url) }
        guard OpenCodeZenBootstrapImporter.protectImportFile(at: url, fileManager: .default),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 65_536,
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.confirmedSameAccount,
              let account = configurationStore.configuration(accountID: payload.accountID),
              account.providerID == .gemini,
              !configurationStore.hasGeminiCodingSecret(for: account),
              let credential = try? AntigravityCredentials.parse(payload.credential),
              credential.canRefresh
        else { return false }
        return configurationStore.saveGeminiCodingSecret(
            payload.credential, for: account, confirmedSameAccount: true
        )
    }
}
#endif

@MainActor
enum OpenCodeZenBootstrapImporter {
    static let importFileName = "opencode-zen-import.txt"

    @discardableResult
    static func replaceCorruptedConfigurationsAndImportIfNeeded(
        configurationStore: ProviderConfigurationStore,
        fileManager: FileManager = .default,
        importDirectory: URL? = nil
    ) -> Bool {
        guard configurationStore.replaceCorruptedConfigurations() else {
            return false
        }

        importIfNeeded(
            configurationStore: configurationStore,
            fileManager: fileManager,
            importDirectory: importDirectory
        )
        return true
    }

    @discardableResult
    static func replaceCorruptedGroupsAndImportIfNeeded(
        configurationStore: ProviderConfigurationStore,
        fileManager: FileManager = .default,
        importDirectory: URL? = nil
    ) -> Bool {
        guard configurationStore.replaceCorruptedGroups() else {
            return false
        }

        importIfNeeded(
            configurationStore: configurationStore,
            fileManager: fileManager,
            importDirectory: importDirectory
        )
        return true
    }

    static func importIfNeeded(
        configurationStore: ProviderConfigurationStore,
        fileManager: FileManager = .default,
        importDirectory: URL? = nil
    ) {
        let directory = importDirectory ?? fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
        guard let importURL = directory?.appendingPathComponent(importFileName) else {
            return
        }

        guard fileManager.fileExists(atPath: importURL.path) else {
            return
        }

        guard protectImportFile(at: importURL, fileManager: fileManager) else {
            try? fileManager.removeItem(at: importURL)
            return
        }

        guard !configurationStore.isPersistenceRecoveryRequired else {
            return
        }

        defer {
            try? fileManager.removeItem(at: importURL)
        }

        guard
            let data = try? Data(contentsOf: importURL),
            let payload = String(data: data, encoding: .utf8)
        else {
            return
        }

        importPayload(payload, configurationStore: configurationStore)
    }

    @discardableResult
    static func protectImportFile(
        at importURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        do {
            try fileManager.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: importURL.path
            )
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    static func importPayload(
        _ payload: String,
        configurationStore: ProviderConfigurationStore
    ) -> Bool {
        guard
            let balanceCredential = OpenCodeZenUsageProvider.normalizedBalanceCredential(from: payload),
            let goCredential = OpenCodeZenUsageProvider.normalizedGoCredential(from: payload)
        else {
            return false
        }
        let storedCredential = balanceCredential == goCredential
            ? balanceCredential
            : payload

        let existingConfiguration = configurationStore.configurations(for: .openCodeZen).first
        let existingWorkspaceId = OpenCodeZenUsageProvider.normalizedWorkspaceId(
            from: existingConfiguration?.openCodeWorkspaceId
        )
        guard let workspaceId = OpenCodeZenUsageProvider.normalizedWorkspaceId(from: payload) ?? existingWorkspaceId else {
            return false
        }

        var configuration = existingConfiguration ?? .defaultConfiguration(for: .openCodeZen)
        configuration.isEnabled = true
        configuration.authMethod = .apiKey
        configuration.openCodeWorkspaceId = workspaceId

        guard configurationStore.update(configuration) else {
            return false
        }

        configurationStore.saveSecret(storedCredential, for: configuration)
        return configurationStore.hasSecret(for: configuration)
    }
}
