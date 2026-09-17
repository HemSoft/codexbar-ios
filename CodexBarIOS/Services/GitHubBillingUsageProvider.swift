import Foundation

public struct GitHubBillingAccountOption: Identifiable, Equatable, Sendable {
    public let scope: GitHubBillingAccountScope
    public let owner: String
    public let role: String

    public init(scope: GitHubBillingAccountScope, owner: String, role: String) {
        self.scope = scope
        self.owner = owner
        self.role = role
    }

    public var id: String {
        "\(scope.rawValue):\(owner.lowercased())"
    }

    public var displayName: String {
        switch scope {
        case .personal:
            "\(owner) · Personal account"
        case .organization:
            "\(owner) · Organization \(role.replacingOccurrences(of: "_", with: " "))"
        }
    }
}

public final class GitHubBillingUsageProvider: UsageProvider {
    private enum CredentialPreparation {
        case ready(GitHubBillingCredentials)
        case failure(ProviderUsageResult)
    }

    private static let refreshCoordinator = CredentialRefreshCoordinator<ProviderCredentialRefreshResult<GitHubBillingCredentials>>()
    private static let apiVersion = "2026-03-10"
    private static let userAgent = "CodexBarIOS/1.0"
    private static let maximumPageCount = 100
    private static let maximumRepositoryVisibilityLookups = 200

    private let secretStore: SecretStore
    private let session: URLSession
    private let apiBaseURL: URL
    private let tokenEndpoint: URL
    private let oauthConfiguration: GitHubBillingOAuthConfiguration
    private let now: @Sendable () -> Date

    public let providerID = ProviderID.githubBilling

    public init(
        secretStore: SecretStore = KeychainService(),
        session: URLSession = .shared,
        apiBaseURL: URL = URL(string: "https://api.github.com")!,
        tokenEndpoint: URL = GitHubBillingWebAuthService.tokenEndpoint,
        oauthConfiguration: GitHubBillingOAuthConfiguration = .bundled,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.secretStore = secretStore
        self.session = session
        self.apiBaseURL = apiBaseURL
        self.tokenEndpoint = tokenEndpoint
        self.oauthConfiguration = oauthConfiguration
        self.now = now
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        let keychainAccount = ProviderConfigurationStore.keychainAccount(for: configuration)
        guard
            let storedSecret = try secretStore.readSecret(account: keychainAccount),
            let credentials = GitHubBillingCredentialsParser.parse(storedSecret)
        else {
            return failureResult(
                message: "Not configured - sign in with GitHub for billing access.",
                recoveryAction: .signIn,
                configuration: configuration
            )
        }

        switch await prepareCredentials(
            credentials,
            keychainAccount: keychainAccount,
            configuration: configuration
        ) {
        case .ready(let readyCredentials):
            return await fetchWithUnauthorizedRetry(
                configuration: configuration,
                credentials: readyCredentials,
                keychainAccount: keychainAccount
            )
        case .failure(let result):
            return result
        }
    }

    private func prepareCredentials(
        _ credentials: GitHubBillingCredentials,
        keychainAccount: String,
        configuration: ProviderAccountConfiguration
    ) async -> CredentialPreparation {
        guard credentials.shouldRefresh(at: now()) else { return .ready(credentials) }
        return credentialPreparation(
            from: await refreshCredentials(credentials, keychainAccount: keychainAccount),
            original: credentials,
            configuration: configuration
        )
    }

    private func credentialPreparation(
        from refresh: ProviderCredentialRefreshResult<GitHubBillingCredentials>,
        original: GitHubBillingCredentials,
        configuration: ProviderAccountConfiguration
    ) -> CredentialPreparation {
        switch refresh {
        case .success(let refreshed):
            .ready(refreshed)
        case .expired, .rejected:
            .failure(failureResult(
                message: "GitHub Billing authorization expired or was revoked. Sign in again.",
                recoveryAction: .reauthenticate,
                configuration: configuration
            ))
        case .temporarilyUnavailable:
            temporaryCredentialPreparation(original: original, configuration: configuration)
        case .persistenceFailed:
            .failure(failureResult(
                message: "The renewed GitHub Billing credential could not be saved in Keychain. Sign in again.",
                recoveryAction: .reauthenticate,
                configuration: configuration
            ))
        }
    }

    private func temporaryCredentialPreparation(
        original: GitHubBillingCredentials,
        configuration: ProviderAccountConfiguration
    ) -> CredentialPreparation {
        guard original.isExpired(at: now()) else { return .ready(original) }
        return .failure(failureResult(
            message: "GitHub Billing authorization could not be renewed. Try again.",
            recoveryAction: .retryRefresh,
            configuration: configuration
        ))
    }

    private func fetchWithUnauthorizedRetry(
        configuration: ProviderAccountConfiguration,
        credentials: GitHubBillingCredentials,
        keychainAccount: String
    ) async -> ProviderUsageResult {
        do {
            return try await fetchUsage(configuration: configuration, credentials: credentials)
        } catch GitHubBillingAPIError.httpStatus(401, _) where credentials.refreshToken?.isEmpty == false {
            return await retryAfterUnauthorized(
                configuration: configuration,
                credentials: credentials,
                keychainAccount: keychainAccount
            )
        } catch {
            return failureResult(error: error, configuration: configuration)
        }
    }

    private func retryAfterUnauthorized(
        configuration: ProviderAccountConfiguration,
        credentials: GitHubBillingCredentials,
        keychainAccount: String
    ) async -> ProviderUsageResult {
        switch await refreshCredentials(credentials, keychainAccount: keychainAccount) {
        case .success(let refreshed):
            do {
                return try await fetchUsage(configuration: configuration, credentials: refreshed)
            } catch {
                return failureResult(error: error, configuration: configuration)
            }
        case .expired, .rejected, .persistenceFailed:
            return failureResult(
                message: "GitHub Billing authorization was rejected. Sign in again.",
                recoveryAction: .reauthenticate,
                configuration: configuration
            )
        case .temporarilyUnavailable:
            return failureResult(
                message: "GitHub Billing authorization could not be renewed. Try again.",
                recoveryAction: .retryRefresh,
                configuration: configuration
            )
        }
    }

    public func discoverAccounts(
        credentials: GitHubBillingCredentials
    ) async throws -> [GitHubBillingAccountOption] {
        let profile = try await fetchProfile(accessToken: credentials.accessToken)
        var options = [
            GitHubBillingAccountOption(
                scope: .personal,
                owner: profile.login,
                role: "owner"
            ),
        ]
        var page = 1
        while true {
            let request = try makeRequest(
                pathComponents: ["user", "memberships", "orgs"],
                queryItems: [
                    URLQueryItem(name: "state", value: "active"),
                    URLQueryItem(name: "per_page", value: "100"),
                    URLQueryItem(name: "page", value: String(page)),
                ],
                accessToken: credentials.accessToken
            )
            let data = try await responseData(for: request)
            guard let memberships = try? JSONDecoder().decode([OrganizationMembership].self, from: data) else {
                throw GitHubBillingAPIError.invalidResponse
            }
            options.append(contentsOf: memberships.compactMap { membership in
                guard
                    membership.state == "active",
                    membership.role == "admin",
                    let login = membership.organization.login?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !login.isEmpty
                else {
                    return nil
                }
                return GitHubBillingAccountOption(
                    scope: .organization,
                    owner: login,
                    role: membership.role
                )
            })
            guard memberships.count == 100 else { break }
            guard page < Self.maximumPageCount else {
                throw GitHubBillingAPIError.invalidResponse
            }
            page += 1
        }
        return options
    }

    public func validateCandidate(
        _ credentials: GitHubBillingCredentials,
        for configuration: ProviderAccountConfiguration
    ) async throws -> ProviderUsageResult {
        let result: ProviderUsageResult
        do {
            result = try await fetchUsage(configuration: configuration, credentials: credentials)
        } catch {
            result = failureResult(error: error, configuration: configuration)
        }
        if let failureMessage = result.failureMessage {
            throw GitHubBillingValidationError.validationFailed(failureMessage)
        }
        return result
    }

    private func fetchUsage(
        configuration: ProviderAccountConfiguration,
        credentials: GitHubBillingCredentials
    ) async throws -> ProviderUsageResult {
        let owner = configuration.githubBillingOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty else {
            throw GitHubBillingValidationError.missingAccount
        }
        switch configuration.githubBillingAccountScope {
        case .personal:
            return try await fetchPersonalUsage(
                owner: owner,
                configuration: configuration,
                credentials: credentials
            )
        case .organization:
            return try await fetchOrganizationUsage(
                owner: owner,
                configuration: configuration,
                credentials: credentials
            )
        }
    }

    private func fetchPersonalUsage(
        owner: String,
        configuration: ProviderAccountConfiguration,
        credentials: GitHubBillingCredentials
    ) async throws -> ProviderUsageResult {
        let profile = try await fetchProfile(accessToken: credentials.accessToken)
        guard profile.login.caseInsensitiveCompare(owner) == .orderedSame else {
            throw GitHubBillingValidationError.accountMismatch
        }
        let date = now()
        let query = billingPeriodQuery(date: date)
        async let summaryData = responseData(for: try makeRequest(
            pathComponents: ["users", owner, "settings", "billing", "usage", "summary"],
            queryItems: query,
            accessToken: credentials.accessToken
        ))
        async let usageData = responseData(for: try makeRequest(
            pathComponents: ["users", owner, "settings", "billing", "usage"],
            queryItems: query,
            accessToken: credentials.accessToken
        ))
        let (summary, usage) = try await (summaryData, usageData)
        let repositories = Self.repositoryNames(in: usage)
        let visibility = try await repositoryVisibility(
            repositories: repositories,
            accessToken: credentials.accessToken
        )
        guard let result = GitHubBillingUsageParser.parsePersonal(
            summaryData: summary,
            usageData: usage,
            repositoryVisibility: visibility.values,
            repositoryVisibilityMessage: visibility.message,
            planName: profile.plan?.name ?? "",
            configuration: configuration,
            fetchedAt: date
        ) else {
            throw GitHubBillingAPIError.invalidResponse
        }
        return result
    }

    private func fetchOrganizationUsage(
        owner: String,
        configuration: ProviderAccountConfiguration,
        credentials: GitHubBillingCredentials
    ) async throws -> ProviderUsageResult {
        let date = now()
        let query = billingPeriodQuery(date: date)
        async let summaryData = responseData(for: try makeRequest(
            pathComponents: ["organizations", owner, "settings", "billing", "usage", "summary"],
            queryItems: query,
            accessToken: credentials.accessToken
        ))
        async let usageData = responseData(for: try makeRequest(
            pathComponents: ["organizations", owner, "settings", "billing", "usage"],
            queryItems: query,
            accessToken: credentials.accessToken
        ))
        async let budgetResult = fetchBudgetPages(
            organization: owner,
            accessToken: credentials.accessToken
        )
        let (summary, usage, budgets) = try await (summaryData, usageData, budgetResult)
        guard let result = GitHubBillingUsageParser.parseOrganization(
            summaryData: summary,
            usageData: usage,
            budgetPageData: budgets.pages,
            budgetStatusMessage: budgets.message,
            configuration: configuration,
            fetchedAt: date
        ) else {
            throw GitHubBillingAPIError.invalidResponse
        }
        return result
    }

    private func fetchProfile(accessToken: String) async throws -> UserProfile {
        let data = try await responseData(for: makeRequest(
            pathComponents: ["user"],
            accessToken: accessToken
        ))
        guard let profile = try? JSONDecoder().decode(UserProfile.self, from: data), !profile.login.isEmpty else {
            throw GitHubBillingAPIError.invalidResponse
        }
        return profile
    }

    private func fetchBudgetPages(
        organization: String,
        accessToken: String
    ) async throws -> BudgetFetchResult {
        var pages: [Data] = []
        var page = 1
        while true {
            switch try await fetchBudgetPage(
                organization: organization,
                page: page,
                accessToken: accessToken
            ) {
            case .page(let data, let info):
                pages.append(data)
                guard info.hasNextPage == true else { return BudgetFetchResult(pages: pages, message: nil) }
            case .unavailable(let message):
                return BudgetFetchResult(pages: nil, message: message)
            }
            guard page < Self.maximumPageCount else {
                throw GitHubBillingAPIError.invalidResponse
            }
            page += 1
        }
    }

    private func fetchBudgetPage(
        organization: String,
        page: Int,
        accessToken: String
    ) async throws -> BudgetPageFetchOutcome {
        let request = try makeRequest(
            pathComponents: ["organizations", organization, "settings", "billing", "budgets"],
            queryItems: [
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "page", value: String(page)),
            ],
            accessToken: accessToken
        )
        do {
            let data = try await responseData(for: request)
            guard let info = try? JSONDecoder().decode(BudgetPageInfo.self, from: data) else {
                throw GitHubBillingAPIError.invalidResponse
            }
            return .page(data, info)
        } catch GitHubBillingAPIError.httpStatus(let status, let isRateLimited) {
            guard
                !isRateLimited,
                status != 429,
                let message = Self.unavailableBudgetMessage(status: status)
            else {
                throw GitHubBillingAPIError.httpStatus(status, isRateLimited)
            }
            return .unavailable(message)
        }
    }

    private static func unavailableBudgetMessage(status: Int) -> String? {
        switch status {
        case 403:
            "GitHub's organization budget endpoint is not permitted for the signed-in user. Usage is still shown."
        case 404:
            "GitHub's organization budget endpoint is unavailable for this account. Usage is still shown."
        default:
            nil
        }
    }

    private func repositoryVisibility(
        repositories: Set<String>,
        accessToken: String
    ) async throws -> RepositoryVisibilityResult {
        let orderedRepositories = Array(repositories.sorted().prefix(Self.maximumRepositoryVisibilityLookups))
        var result = RepositoryVisibilityResult(
            values: [:],
            hiddenRepositoryCount: 0,
            omittedRepositoryCount: max(0, repositories.count - orderedRepositories.count)
        )
        for batchStart in stride(from: 0, to: orderedRepositories.count, by: 8) {
            let batchEnd = min(batchStart + 8, orderedRepositories.count)
            let lookups = try await repositoryVisibilityLookups(
                repositories: orderedRepositories[batchStart..<batchEnd],
                accessToken: accessToken
            )
            Self.mergeRepositoryVisibility(lookups, into: &result)
        }
        return result
    }

    private func repositoryVisibilityLookups(
        repositories: ArraySlice<String>,
        accessToken: String
    ) async throws -> [RepositoryVisibilityLookup] {
        try await withThrowingTaskGroup(of: RepositoryVisibilityLookup.self) { group in
            for repository in repositories {
                group.addTask { [self] in
                    try await repositoryVisibilityLookup(
                        repository: repository,
                        accessToken: accessToken
                    )
                }
            }
            var results: [RepositoryVisibilityLookup] = []
            for try await lookup in group {
                results.append(lookup)
            }
            return results
        }
    }

    private func repositoryVisibilityLookup(
        repository: String,
        accessToken: String
    ) async throws -> RepositoryVisibilityLookup {
        let components = repository.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 2 else {
            return RepositoryVisibilityLookup(repository: repository, isPrivate: nil, isHidden: false)
        }
        do {
            let request = try makeRequest(
                pathComponents: ["repos", String(components[0]), String(components[1])],
                accessToken: accessToken
            )
            let data = try await responseData(for: request)
            let metadata = try JSONDecoder().decode(RepositoryMetadata.self, from: data)
            return RepositoryVisibilityLookup(
                repository: repository,
                isPrivate: metadata.isPrivate,
                isHidden: false
            )
        } catch GitHubBillingAPIError.httpStatus(404, _) {
            return RepositoryVisibilityLookup(repository: repository, isPrivate: nil, isHidden: true)
        }
    }

    private static func mergeRepositoryVisibility(
        _ lookups: [RepositoryVisibilityLookup],
        into result: inout RepositoryVisibilityResult
    ) {
        for lookup in lookups {
            if let isPrivate = lookup.isPrivate {
                result.values[lookup.repository] = isPrivate
            }
            if lookup.isHidden {
                result.hiddenRepositoryCount += 1
            }
        }
    }

    private static func repositoryNames(in usageData: Data) -> Set<String> {
        guard
            let object = try? JSONSerialization.jsonObject(with: usageData) as? [String: Any],
            let items = object["usageItems"] as? [[String: Any]]
        else {
            return []
        }
        return Set(items.compactMap { item in
            guard
                let repository = item["repositoryName"] as? String,
                !repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            return repository
        })
    }

    private func makeRequest(
        pathComponents: [String],
        queryItems: [URLQueryItem] = [],
        accessToken: String
    ) throws -> URLRequest {
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)
        components?.percentEncodedPath = "/" + pathComponents.map(Self.percentEncodedPathComponent).joined(separator: "/")
        components?.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components?.url else {
            throw GitHubBillingAPIError.invalidRequest
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    private func responseData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitHubBillingAPIError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let isRateLimited = httpResponse.statusCode == 429
                || httpResponse.value(forHTTPHeaderField: "Retry-After") != nil
                || httpResponse.value(forHTTPHeaderField: "X-RateLimit-Remaining") == "0"
            throw GitHubBillingAPIError.httpStatus(httpResponse.statusCode, isRateLimited)
        }
        return data
    }

    private func billingPeriodQuery(date: Date) -> [URLQueryItem] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month], from: date)
        return [
            URLQueryItem(name: "year", value: components.year.map(String.init)),
            URLQueryItem(name: "month", value: components.month.map(String.init)),
        ]
    }

    private static func percentEncodedPathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func refreshCredentials(
        _ credentials: GitHubBillingCredentials,
        keychainAccount: String
    ) async -> ProviderCredentialRefreshResult<GitHubBillingCredentials> {
        await Self.refreshCoordinator.run(for: keychainAccount) { [self] in
            await performProviderCredentialRefresh(
                credentials: credentials,
                keychainAccount: keychainAccount,
                secretStore: secretStore,
                session: session,
                now: now,
                parse: { GitHubBillingCredentialsParser.parse($0) },
                storedCredential: { GitHubBillingCredentialsParser.storedCredential(from: $0) ?? "" },
                prepare: { [self] refreshedAt in
                    self.prepareRefreshRequest(credentials: credentials, refreshedAt: refreshedAt)
                },
                decode: { data, refreshedAt in
                    Self.decodeRefreshResponse(
                        data,
                        refreshedAt: refreshedAt,
                        original: credentials
                    )
                }
            )
        }
    }

    private func prepareRefreshRequest(
        credentials: GitHubBillingCredentials,
        refreshedAt: Date
    ) -> ProviderCredentialRefreshPreparation<GitHubBillingCredentials> {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            return .finished(.rejected)
        }
        if let refreshTokenExpiresAt = credentials.refreshTokenExpiresAt,
           Date(timeIntervalSince1970: TimeInterval(refreshTokenExpiresAt)) <= refreshedAt {
            return .finished(.expired)
        }
        let clientID = oauthConfiguration.clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let clientSecret = oauthConfiguration.clientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty, !clientSecret.isEmpty else {
            return .finished(.temporarilyUnavailable)
        }
        var request = URLRequest(url: tokenEndpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = GitHubBillingWebAuthService.makeRefreshTokenRequestBody(
            clientID: clientID,
            clientSecret: clientSecret,
            refreshToken: refreshToken
        )
        return .request(request)
    }

    private static func decodeRefreshResponse(
        _ data: Data,
        refreshedAt: Date,
        original: GitHubBillingCredentials
    ) -> ProviderCredentialRefreshResult<GitHubBillingCredentials> {
        guard let response = try? JSONDecoder().decode(TokenRefreshResponse.self, from: data) else {
            return .temporarilyUnavailable
        }
        if response.error != nil { return .rejected }
        guard let accessToken = response.accessToken, !accessToken.isEmpty else {
            return .temporarilyUnavailable
        }
        return .success(GitHubBillingCredentials(
            accessToken: accessToken,
            username: original.username,
            refreshToken: response.refreshToken ?? original.refreshToken,
            expiresAt: response.expiresIn.map {
                Int64(refreshedAt.addingTimeInterval(TimeInterval($0)).timeIntervalSince1970)
            },
            refreshTokenExpiresAt: response.refreshTokenExpiresIn.map {
                Int64(refreshedAt.addingTimeInterval(TimeInterval($0)).timeIntervalSince1970)
            } ?? (response.refreshToken == nil ? original.refreshTokenExpiresAt : nil)
        ))
    }

    private func failureResult(
        error: Error,
        configuration: ProviderAccountConfiguration
    ) -> ProviderUsageResult {
        if let validation = error as? GitHubBillingValidationError {
            return failureResult(
                message: validation.localizedDescription,
                recoveryAction: .retryRefresh,
                configuration: configuration
            )
        }
        if let apiError = error as? GitHubBillingAPIError {
            switch apiError {
            case .httpStatus(let status, let isRateLimited):
                return httpFailureResult(
                    status: status,
                    isRateLimited: isRateLimited,
                    configuration: configuration
                )
            case .invalidRequest, .invalidResponse:
                return failureResult(
                    message: "GitHub Billing returned data CodexBar could not read.",
                    recoveryAction: .retryRefresh,
                    configuration: configuration
                )
            }
        }
        return failureResult(
            message: "GitHub Billing could not be reached. Check the connection and try again.",
            recoveryAction: .retryRefresh,
            configuration: configuration
        )
    }

    private func httpFailureResult(
        status: Int,
        isRateLimited: Bool,
        configuration: ProviderAccountConfiguration
    ) -> ProviderUsageResult {
        if status == 401 {
            return failureResult(
                message: "GitHub Billing authorization expired or was revoked. Sign in again.",
                recoveryAction: .reauthenticate,
                configuration: configuration
            )
        }
        if Self.isRateLimit(status: status, isRateLimited: isRateLimited) {
            return failureResult(
                message: "GitHub Billing rate limit reached. Try again later.",
                recoveryAction: .retryRefresh,
                configuration: configuration
            )
        }
        if status == 403 {
            return failureResult(
                message: "The signed-in user lacks permission to read this billing account. "
                    + "Organization monitoring requires an administrator role.",
                recoveryAction: .reauthenticate,
                configuration: configuration
            )
        }
        if status == 404 {
            return failureResult(
                message: "GitHub Enhanced Billing is unavailable or unsupported for this account.",
                recoveryAction: .retryRefresh,
                configuration: configuration
            )
        }
        if (500..<600).contains(status) {
            return failureResult(
                message: "GitHub Billing is temporarily unavailable. Try again later.",
                recoveryAction: .retryRefresh,
                configuration: configuration
            )
        }
        return failureResult(
            message: "GitHub Billing returned HTTP \(status).",
            recoveryAction: .retryRefresh,
            configuration: configuration
        )
    }

    private static func isRateLimit(status: Int, isRateLimited: Bool) -> Bool {
        isRateLimited || status == 429
    }

    private func failureResult(
        message: String,
        recoveryAction: ProviderUsageRecoveryAction,
        configuration: ProviderAccountConfiguration
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .githubBilling,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            failureMessage: message,
            recoveryAction: recoveryAction,
            cacheIdentity: configuration.githubBillingOwner.lowercased(),
            fetchedAt: now()
        )
    }
}

private struct UserProfile: Decodable {
    struct Plan: Decodable {
        let name: String
    }

    let login: String
    let plan: Plan?
}

private struct OrganizationMembership: Decodable {
    struct Organization: Decodable {
        let login: String?
    }

    let state: String
    let role: String
    let organization: Organization
}

private struct RepositoryMetadata: Decodable {
    let isPrivate: Bool

    enum CodingKeys: String, CodingKey {
        case isPrivate = "private"
    }
}

private struct RepositoryVisibilityLookup: Sendable {
    let repository: String
    let isPrivate: Bool?
    let isHidden: Bool
}

private struct RepositoryVisibilityResult: Sendable {
    var values: [String: Bool]
    var hiddenRepositoryCount: Int
    let omittedRepositoryCount: Int

    var message: String? {
        var reasons: [String] = []
        if hiddenRepositoryCount > 0 {
            let noun = hiddenRepositoryCount == 1 ? "repository was" : "repositories were"
            reasons.append("\(hiddenRepositoryCount) \(noun) hidden or not found")
        }
        if omittedRepositoryCount > 0 {
            reasons.append("\(omittedRepositoryCount) additional repositories exceeded the lookup safety limit")
        }
        guard !reasons.isEmpty else { return nil }
        return reasons.joined(separator: ", and ")
            + ", so private Actions usage could not be fully classified."
    }
}

private struct BudgetPageInfo: Decodable {
    let hasNextPage: Bool?

    enum CodingKeys: String, CodingKey {
        case hasNextPage = "has_next_page"
    }
}

private enum BudgetPageFetchOutcome {
    case page(Data, BudgetPageInfo)
    case unavailable(String)
}

private struct BudgetFetchResult {
    let pages: [Data]?
    let message: String?
}

private struct TokenRefreshResponse: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int64?
    let refreshTokenExpiresIn: Int64?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case refreshTokenExpiresIn = "refresh_token_expires_in"
        case error
    }
}

private enum GitHubBillingAPIError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case httpStatus(Int, Bool)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "GitHub Billing could not create a valid request."
        case .invalidResponse:
            "GitHub Billing returned data CodexBar could not read."
        case .httpStatus(let status, let isRateLimited):
            Self.httpStatusMessage(status: status, isRateLimited: isRateLimited)
        }
    }

    private static func httpStatusMessage(status: Int, isRateLimited: Bool) -> String {
        if let priorityMessage = priorityHTTPStatusMessage(status: status, isRateLimited: isRateLimited) {
            return priorityMessage
        }
        return fallbackHTTPStatusMessage(status: status)
    }

    private static func priorityHTTPStatusMessage(status: Int, isRateLimited: Bool) -> String? {
        if status == 401 {
            return "GitHub Billing authorization expired or was revoked. Sign in again."
        }
        if isRateLimited || status == 429 {
            return "GitHub Billing rate limit reached. Try again later."
        }
        return nil
    }

    private static func fallbackHTTPStatusMessage(status: Int) -> String {
        switch status {
        case 403:
            "The signed-in user lacks permission to read this billing account."
        case 404:
            "GitHub Enhanced Billing is unavailable, hidden, or not found for this account."
        case 500..<600:
            "GitHub Billing is temporarily unavailable. Try again later."
        default:
            "GitHub Billing returned HTTP \(status)."
        }
    }
}

private enum GitHubBillingValidationError: LocalizedError {
    case missingAccount
    case accountMismatch
    case validationFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingAccount:
            "Choose a personal account or eligible organization before saving."
        case .accountMismatch:
            "The selected personal account does not match the signed-in GitHub user. Sign in again with the intended account."
        case .validationFailed(let message):
            message
        }
    }
}
