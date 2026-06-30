import Foundation

public final class CopilotUsageProvider: UsageProvider {
    private let secretStore: SecretStore
    private let session: URLSession
    private let usageEndpoint: URL

    public let providerID = ProviderID.copilot

    public init(
        secretStore: SecretStore = KeychainService(),
        session: URLSession = .shared,
        usageEndpoint: URL = URL(string: "https://api.github.com/copilot_internal/user")!
    ) {
        self.secretStore = secretStore
        self.session = session
        self.usageEndpoint = usageEndpoint
    }

    public func fetchUsage() async throws -> ProviderUsageResult {
        guard
            let storedSecret = try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: .copilot)),
            let credentials = CopilotCredentialsParser.parse(storedSecret)
        else {
            return failureResult("Not configured - sign in with GitHub.")
        }

        let (data, response) = try await session.data(for: makeUsageRequest(accessToken: credentials.accessToken))
        guard let httpResponse = response as? HTTPURLResponse else {
            return failureResult("GitHub Copilot usage returned an invalid response.")
        }

        switch httpResponse.statusCode {
        case 200..<300:
            return CopilotUsageParser.parse(data) ?? failureResult("Could not parse GitHub Copilot usage.")
        case 401, 403:
            return failureResult("GitHub Copilot credential expired or lacks Copilot access.")
        default:
            return failureResult("GitHub Copilot usage returned HTTP \(httpResponse.statusCode).")
        }
    }

    public func fetchUsername(accessToken: String) async throws -> String? {
        let (data, response) = try await session.data(for: makeUsageRequest(accessToken: accessToken))
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            return nil
        }

        return CopilotUsageParser.username(from: data)
    }

    private func makeUsageRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: usageEndpoint)
        request.httpMethod = "GET"
        request.setValue("token \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBarIOS", forHTTPHeaderField: "User-Agent")
        request.setValue("CodexBarIOS", forHTTPHeaderField: "Editor-Version")
        request.setValue("CodexBarIOS", forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-Github-Api-Version")
        return request
    }

    private func failureResult(_ message: String) -> ProviderUsageResult {
        ProviderUsageResult(
            providerID: .copilot,
            title: ProviderID.copilot.displayName,
            subtitle: message,
            bars: [],
            fetchedAt: Date()
        )
    }
}
