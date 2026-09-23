import Foundation

enum OpenCodeSignInError: LocalizedError {
    case canceled
    case expired
    case browserFailed
    case validationFailed

    var errorDescription: String? {
        switch self {
        case .canceled:
            "OpenCode sign-in canceled. Your saved account was not changed."
        case .expired:
            "OpenCode approval expired. Start sign-in again. Your saved account was not changed."
        case .browserFailed:
            "OpenCode sign-in could not load. Check your connection and try again."
        case .validationFailed:
            "OpenCode usage could not be verified. Check your workspace and try again. Your saved account was not changed."
        }
    }
}

enum OpenCodeBrowserMode: Sendable {
    case existingSession
    case privateSession

    var prefersEphemeralSession: Bool { self == .privateSession }
}

struct OpenCodeBrowserCredential {
    let workspaceID: String
    let session: String
}

protocol OpenCodeSessionValidating: Sendable {
    func validate(credential: String, configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult
}

struct OpenCodeSessionValidator: OpenCodeSessionValidating {
    static func canReconnect(
        workspaceID: String,
        configuredWorkspace: String,
        credential: String? = nil,
        savedCredential: String? = nil
    ) -> Bool {
        let matchesWorkspace = OpenCodeZenUsageProvider.normalizedWorkspaceId(from: configuredWorkspace)
            .map { $0 == workspaceID } ?? true
        guard matchesWorkspace else { return false }
        guard let saved = OpenCodeConsoleCredential.parse(savedCredential) else { return true }
        guard let candidate = OpenCodeConsoleCredential.parse(credential) else { return false }
        return saved.userID == candidate.userID
            && saved.workspaceID == candidate.workspaceID
            && candidate.workspaceID == workspaceID
    }

    static func hasVerifiedUsage(_ result: ProviderUsageResult) -> Bool {
        (!result.bars.isEmpty && result.hasCurrentBars)
            || (result.creditsRemaining != nil && result.hasCurrentCredits)
    }

    func validate(credential: String, configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        guard let candidate = OpenCodeConsoleCredential.parse(credential),
              candidate.workspaceID == configuration.openCodeWorkspaceId else { throw OpenCodeSignInError.validationFailed }
        let store = OpenCodeValidationSecretStore(
            credential: credential,
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        return await OpenCodeConsoleUsageProvider(secretStore: store).fetchUsage(credential: candidate, configuration: configuration)
    }
}

private struct OpenCodeValidationSecretStore: SecretStore {
    let credential: String
    let account: String

    func readSecret(account: String) throws -> String? {
        account == self.account ? credential : nil
    }

    func saveSecret(_ secret: String, account: String) throws {
        throw OpenCodeSignInError.validationFailed
    }

    func deleteSecret(account: String) throws {
        throw OpenCodeSignInError.validationFailed
    }
}
