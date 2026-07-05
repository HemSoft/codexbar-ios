import Foundation

public final class CodexUsageProvider: UsageProvider {
    private let secretStore: SecretStore
    private let session: URLSession
    private let usageEndpoint: URL

    public let providerID = ProviderID.codex

    public init(
        secretStore: SecretStore = KeychainService(),
        session: URLSession = .shared,
        usageEndpoint: URL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    ) {
        self.secretStore = secretStore
        self.session = session
        self.usageEndpoint = usageEndpoint
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        guard
            let storedSecret = try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration)),
            let credentials = CodexCredentialsParser.parse(storedSecret)
        else {
            return failureResult("Not configured - sign in with ChatGPT.", configuration: configuration)
        }

        var request = URLRequest(url: usageEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBarIOS", forHTTPHeaderField: "User-Agent")

        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return failureResult("ChatGPT usage returned an invalid response.", configuration: configuration)
        }

        switch httpResponse.statusCode {
        case 200..<300:
            return applyAccountMetadata(
                to: CodexUsageParser.parse(data) ?? failureResult("Could not parse ChatGPT usage.", configuration: configuration),
                configuration: configuration
            )
        case 401, 403:
            return failureResult("ChatGPT / Codex credential expired.", configuration: configuration)
        default:
            return failureResult("ChatGPT usage returned HTTP \(httpResponse.statusCode).", configuration: configuration)
        }
    }

    private func failureResult(_ message: String, configuration: ProviderAccountConfiguration) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            fetchedAt: Date()
        )
    }

    private func applyAccountMetadata(
        to result: ProviderUsageResult,
        configuration: ProviderAccountConfiguration
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: result.providerID,
            title: configuration.displayName,
            subtitle: result.subtitle,
            bars: result.bars,
            fetchedAt: result.fetchedAt
        )
    }
}
