import Foundation

public final class CopilotUsageProvider: UsageProvider {
    private static let editorVersion = "vscode/1.96.2"
    private static let editorPluginVersion = "copilot-chat/0.26.7"
    private static let userAgentProduct = "GitHubCopilotChat/0.26.7"
    private static let githubApiVersion = "2025-04-01"
    private static let githubRestApiVersion = "2026-03-10"
    private static let githubRestUserAgent = "CodexBarIOS/1.0"
    private static let promotionalCreditsPerSeat = 7_000
    private static let standardCreditsPerSeat = 3_900

    private let secretStore: SecretStore
    private let session: URLSession
    private let usageEndpoint: URL
    private let githubAPIBaseURL: URL

    public let providerID = ProviderID.copilot

    public init(
        secretStore: SecretStore = KeychainService(),
        session: URLSession = .shared,
        usageEndpoint: URL = URL(string: "https://api.github.com/copilot_internal/user")!,
        githubAPIBaseURL: URL = URL(string: "https://api.github.com")!
    ) {
        self.secretStore = secretStore
        self.session = session
        self.usageEndpoint = usageEndpoint
        self.githubAPIBaseURL = githubAPIBaseURL
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        guard
            let storedSecret = try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration)),
            let credentials = CopilotCredentialsParser.parse(storedSecret)
        else {
            return failureResult("Not configured - sign in with GitHub.", configuration: configuration)
        }

        if configuration.copilotAccountScope == .organization {
            return try await fetchOrganizationUsage(configuration: configuration, accessToken: credentials.accessToken)
        }

        let (data, response) = try await session.data(for: makeUsageRequest(accessToken: credentials.accessToken))
        guard let httpResponse = response as? HTTPURLResponse else {
            return failureResult("GitHub Copilot usage returned an invalid response.", configuration: configuration)
        }

        switch httpResponse.statusCode {
        case 200..<300:
            return applyAccountMetadata(
                to: CopilotUsageParser.parse(data) ?? failureResult("Could not parse GitHub Copilot usage.", configuration: configuration),
                configuration: configuration
            )
        case 401, 403:
            return failureResult("GitHub Copilot credential expired or lacks Copilot access.", configuration: configuration)
        default:
            return failureResult("GitHub Copilot usage returned HTTP \(httpResponse.statusCode).", configuration: configuration)
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

    func makeUsageRequest(accessToken: String) -> URLRequest {
        var request = URLRequest(url: usageEndpoint)
        request.httpMethod = "GET"
        request.setValue("token \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.userAgentProduct, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.editorVersion, forHTTPHeaderField: "Editor-Version")
        request.setValue(Self.editorPluginVersion, forHTTPHeaderField: "Editor-Plugin-Version")
        request.setValue(Self.githubApiVersion, forHTTPHeaderField: "X-Github-Api-Version")
        return request
    }

    func makeOrganizationBillingRequest(
        accessToken: String,
        configuration: ProviderAccountConfiguration,
        date: Date = Date()
    ) -> URLRequest? {
        let organization = configuration.githubOrganization.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !organization.isEmpty else {
            return nil
        }

        let enterprise = configuration.githubEnterprise.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let encodedOrganization = organization.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        let calendar = Calendar(identifier: .gregorian)
        let dateComponents = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
        guard let year = dateComponents.year, let month = dateComponents.month else {
            return nil
        }

        let path: String
        var queryItems = [
            URLQueryItem(name: "year", value: "\(year)"),
            URLQueryItem(name: "month", value: "\(month)"),
            URLQueryItem(name: "product", value: "Copilot"),
        ]

        if enterprise.isEmpty {
            path = "/organizations/\(encodedOrganization)/settings/billing/ai_credit/usage"
        } else {
            guard let encodedEnterprise = enterprise.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
                return nil
            }
            path = "/enterprises/\(encodedEnterprise)/settings/billing/ai_credit/usage"
            queryItems.append(URLQueryItem(name: "organization", value: organization))
        }

        var urlComponents = URLComponents(url: githubAPIBaseURL, resolvingAgainstBaseURL: false)
        urlComponents?.percentEncodedPath = path
        urlComponents?.queryItems = queryItems
        guard let url = urlComponents?.url else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.githubRestApiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(Self.githubRestUserAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    func makeOrganizationSeatCountRequest(
        accessToken: String,
        configuration: ProviderAccountConfiguration
    ) -> URLRequest? {
        let organization = configuration.githubOrganization.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !organization.isEmpty,
            let encodedOrganization = organization.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
        else {
            return nil
        }

        var urlComponents = URLComponents(url: githubAPIBaseURL, resolvingAgainstBaseURL: false)
        urlComponents?.percentEncodedPath = "/orgs/\(encodedOrganization)/copilot/billing"
        guard let url = urlComponents?.url else {
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.githubRestApiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(Self.githubRestUserAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    static func creditsPerSeat(year: Int, month: Int) -> Int {
        year == 2026 && (6...8).contains(month)
            ? promotionalCreditsPerSeat
            : standardCreditsPerSeat
    }

    private func failureResult(_ message: String, configuration: ProviderAccountConfiguration) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .copilot,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            fetchedAt: Date()
        )
    }

    private func fetchOrganizationUsage(
        configuration: ProviderAccountConfiguration,
        accessToken: String
    ) async throws -> ProviderUsageResult {
        guard let request = makeOrganizationBillingRequest(accessToken: accessToken, configuration: configuration) else {
            return failureResult("Not configured - enter organization.", configuration: configuration)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            return failureResult("GitHub Copilot organization usage returned an invalid response.", configuration: configuration)
        }

        switch httpResponse.statusCode {
        case 200..<300:
            let effectiveAllotment = try await resolveOrganizationAllotment(
                configuration: configuration,
                accessToken: accessToken
            )
            return CopilotBillingUsageParser.parse(
                data,
                configuration: configuration,
                fetchedAt: Date(),
                totalAllotment: effectiveAllotment
            ) ?? failureResult("Could not parse GitHub Copilot organization usage.", configuration: configuration)
        case 401, 403:
            return failureResult("GitHub credential lacks access to this Copilot organization billing data.", configuration: configuration)
        default:
            return failureResult("GitHub Copilot organization usage returned HTTP \(httpResponse.statusCode).", configuration: configuration)
        }
    }

    func resolveOrganizationAllotment(
        configuration: ProviderAccountConfiguration,
        accessToken: String,
        date: Date = Date()
    ) async throws -> Double? {
        if let override = configuration.copilotTotalAllotment, override > 0 {
            return override
        }

        guard let request = makeOrganizationSeatCountRequest(accessToken: accessToken, configuration: configuration) else {
            return nil
        }

        let (data, response) = try await session.data(for: request)
        guard
            let httpResponse = response as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode),
            let seatCount = CopilotSeatCountParser.parse(data),
            seatCount > 0
        else {
            return nil
        }

        let calendar = Calendar(identifier: .gregorian)
        let components = calendar.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: date)
        guard let year = components.year, let month = components.month else {
            return nil
        }

        return Double(seatCount * Self.creditsPerSeat(year: year, month: month))
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
