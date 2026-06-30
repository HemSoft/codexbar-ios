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

    public func fetchUsage() async throws -> ProviderUsageResult {
        guard
            let storedSecret = try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: .codex)),
            let credentials = CodexCredentialsParser.parse(storedSecret)
        else {
            return try await DemoUsageProvider.samples.first { $0.providerID == .codex }!.fetchUsage()
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
            return failureResult("ChatGPT usage returned an invalid response.")
        }

        switch httpResponse.statusCode {
        case 200..<300:
            return CodexUsageParser.parse(data) ?? failureResult("Could not parse ChatGPT usage.")
        case 401, 403:
            return failureResult("ChatGPT / Codex credential expired.")
        default:
            return failureResult("ChatGPT usage returned HTTP \(httpResponse.statusCode).")
        }
    }

    private func failureResult(_ message: String) -> ProviderUsageResult {
        ProviderUsageResult(
            providerID: .codex,
            title: ProviderID.codex.displayName,
            subtitle: message,
            bars: [],
            fetchedAt: Date()
        )
    }
}

