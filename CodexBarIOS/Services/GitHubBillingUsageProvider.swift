import CryptoKit
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
    private let repositoryVisibilityCacheDuration: TimeInterval
    private let repositoryVisibilityCache = GitHubRepositoryVisibilityCache()
    private let now: @Sendable () -> Date

    public let providerID = ProviderID.githubBilling

    public init(
        secretStore: SecretStore = KeychainService(),
        session: URLSession = .shared,
        apiBaseURL: URL = URL(string: "https://api.github.com")!,
        tokenEndpoint: URL = GitHubBillingWebAuthService.tokenEndpoint,
        oauthConfiguration: GitHubBillingOAuthConfiguration = .bundled,
        repositoryVisibilityCacheDuration: TimeInterval = 15 * 60,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.secretStore = secretStore
        self.session = session
        self.apiBaseURL = apiBaseURL
        self.tokenEndpoint = tokenEndpoint
        self.oauthConfiguration = oauthConfiguration
        self.repositoryVisibilityCacheDuration = max(0, repositoryVisibilityCacheDuration)
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
        } catch GitHubBillingAPIError.httpStatus(401, _, _) where credentials.refreshToken?.isEmpty == false {
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
        let visibility = try await billingPreservingRepositoryVisibility(
            repositories: repositories,
            owner: owner,
            scope: .personal,
            configurationID: configuration.id,
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
        async let planResult = fetchOrganizationPlan(
            organization: owner,
            accessToken: credentials.accessToken
        )
        let (summary, usage, budgets, plan) = try await (summaryData, usageData, budgetResult, planResult)
        let visibility: RepositoryVisibilityResult
        if Self.organizationPlanSupportsAllowances(plan.name) {
            let repositories = Self.repositoryNames(in: usage)
            visibility = try await billingPreservingRepositoryVisibility(
                repositories: repositories,
                owner: owner,
                scope: .organization,
                configurationID: configuration.id,
                accessToken: credentials.accessToken
            )
        } else {
            visibility = RepositoryVisibilityResult(values: [:], hiddenRepositoryCount: 0, omittedRepositoryCount: 0)
        }
        guard let result = GitHubBillingUsageParser.parseOrganization(
            summaryData: summary,
            usageData: usage,
            budgetPageData: budgets.pages,
            budgetStatusMessage: budgets.message,
            repositoryVisibility: visibility.values,
            repositoryVisibilityMessage: visibility.message,
            planName: plan.name,
            planStatusMessage: plan.message,
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

    private static func organizationPlanSupportsAllowances(_ name: String) -> Bool {
        ["free", "team"].contains(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private func billingPreservingRepositoryVisibility(
        repositories: Set<String>,
        owner: String,
        scope: GitHubBillingAccountScope,
        configurationID: String,
        accessToken: String
    ) async throws -> RepositoryVisibilityResult {
        do {
            return try await repositoryVisibility(
                repositories: repositories,
                owner: owner,
                accessToken: accessToken,
                cacheNamespace: Self.repositoryVisibilityCacheNamespace(
                    scope: scope,
                    owner: owner,
                    configurationID: configurationID,
                    accessToken: accessToken
                )
            )
        } catch {
            guard Self.canPreserveBillingUsage(afterVisibilityFailure: error) else { throw error }
            return RepositoryVisibilityResult(
                values: [:],
                hiddenRepositoryCount: 0,
                omittedRepositoryCount: 0,
                failureMessage: "GitHub could not classify repository visibility, so Actions allowances are "
                    + "unavailable. \(error.localizedDescription)"
            )
        }
    }

    private static func canPreserveBillingUsage(afterVisibilityFailure error: Error) -> Bool {
        guard case let GitHubBillingAPIError.httpStatus(status, _, _) = error else { return true }
        return status != 401
    }

    private func fetchOrganizationPlan(
        organization: String,
        accessToken: String
    ) async -> OrganizationPlanResult {
        do {
            let data = try await responseData(for: makeRequest(
                pathComponents: ["orgs", organization],
                accessToken: accessToken
            ))
            guard let profile = try? JSONDecoder().decode(OrganizationProfile.self, from: data) else {
                return OrganizationPlanResult(
                    name: "",
                    message: "GitHub returned organization profile data without a verifiable plan. Refresh the "
                        + "account; if this continues, sign in again and approve organization access."
                )
            }
            return OrganizationPlanResult(
                name: profile.plan?.name ?? "",
                message: profile.plan == nil
                    ? "GitHub did not return the organization's plan. Sign in again and approve organization "
                        + "administration access, then refresh."
                    : nil
            )
        } catch {
            return OrganizationPlanResult(
                name: "",
                message: organizationPlanFailureMessage(error)
            )
        }
    }

    private func organizationPlanFailureMessage(_ error: Error) -> String {
        if case let GitHubBillingAPIError.httpStatus(status, isRateLimited, _) = error,
           status == 403,
           !isRateLimited {
            return "GitHub did not permit plan access. Sign in again and approve organization administration "
                + "access, then refresh."
        }
        if let apiError = error as? GitHubBillingAPIError {
            return "GitHub could not verify the organization's plan. \(apiError.localizedDescription)"
        }
        return "GitHub could not verify the organization's plan. Check your connection and refresh."
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
        } catch GitHubBillingAPIError.httpStatus(let status, let isRateLimited, let diagnostic) {
            guard
                !isRateLimited,
                status != 429,
                let message = Self.unavailableBudgetMessage(status: status)
            else {
                throw GitHubBillingAPIError.httpStatus(status, isRateLimited, diagnostic)
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

    private static func repositoryVisibilityCacheNamespace(
        scope: GitHubBillingAccountScope,
        owner: String,
        configurationID: String,
        accessToken: String
    ) -> String {
        let digest = SHA256.hash(data: Data(accessToken.utf8))
        let credentialID = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(scope.rawValue):\(owner.lowercased()):\(configurationID):\(credentialID)"
    }

    private func repositoryVisibility(
        repositories: Set<String>,
        owner: String,
        accessToken: String,
        cacheNamespace: String
    ) async throws -> RepositoryVisibilityResult {
        let orderedRepositories = Array(repositories.sorted().prefix(Self.maximumRepositoryVisibilityLookups))
        let cached = await repositoryVisibilityCache.resolve(
            repositories: orderedRepositories,
            namespace: cacheNamespace,
            at: now()
        )
        var result = RepositoryVisibilityResult(
            values: [:],
            hiddenRepositoryCount: 0,
            omittedRepositoryCount: max(0, repositories.count - orderedRepositories.count)
        )
        Self.mergeRepositoryVisibility(cached.lookups, into: &result)
        for batchStart in stride(from: 0, to: cached.missing.count, by: 8) {
            let batchEnd = min(batchStart + 8, cached.missing.count)
            let lookups = try await repositoryVisibilityLookups(
                repositories: cached.missing[batchStart..<batchEnd],
                owner: owner,
                accessToken: accessToken
            )
            await repositoryVisibilityCache.store(
                lookups,
                namespace: cacheNamespace,
                fetchedAt: now(),
                duration: repositoryVisibilityCacheDuration
            )
            Self.mergeRepositoryVisibility(lookups, into: &result)
        }
        return result
    }

    private func repositoryVisibilityLookups(
        repositories: ArraySlice<String>,
        owner: String,
        accessToken: String
    ) async throws -> [RepositoryVisibilityLookup] {
        try await withThrowingTaskGroup(of: RepositoryVisibilityLookup.self) { group in
            for repository in repositories {
                group.addTask { [self] in
                    try await repositoryVisibilityLookup(
                        repository: repository,
                        owner: owner,
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
        owner: String,
        accessToken: String
    ) async throws -> RepositoryVisibilityLookup {
        let components = repository.split(separator: "/", omittingEmptySubsequences: true)
        let repositoryOwner: String
        let repositoryName: String
        switch components.count {
        case 1:
            repositoryOwner = owner
            repositoryName = String(components[0])
        case 2:
            repositoryOwner = String(components[0])
            repositoryName = String(components[1])
        default:
            return RepositoryVisibilityLookup(repository: repository, isPrivate: nil, isHidden: false)
        }
        do {
            let request = try makeRequest(
                pathComponents: ["repos", repositoryOwner, repositoryName],
                accessToken: accessToken
            )
            let data = try await responseData(for: request)
            let metadata = try JSONDecoder().decode(RepositoryMetadata.self, from: data)
            return RepositoryVisibilityLookup(
                repository: repository,
                isPrivate: metadata.isPrivate,
                isHidden: false
            )
        } catch GitHubBillingAPIError.httpStatus(404, _, _) {
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
                isPotentialRepositoryAllowanceItem(item),
                let repository = item["repositoryName"] as? String,
                !repository.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                return nil
            }
            return repository
        })
    }

    private static func isPotentialRepositoryAllowanceItem(_ item: [String: Any]) -> Bool {
        if isPotentialActionsMinuteItem(item) { return true }
        let unit = (item["unitType"] as? String)?.lowercased() ?? ""
        let product = (item["product"] as? String)?.lowercased() ?? ""
        let sku = (item["sku"] as? String)?.lowercased() ?? ""
        guard product == "actions", !sku.contains("cache"), !sku.contains("custom_image") else { return false }
        return sku.contains("storage") || unit.contains("gb-hour")
    }

    private static func isPotentialActionsMinuteItem(_ item: [String: Any]) -> Bool {
        let product = (item["product"] as? String)?.lowercased() ?? ""
        let unit = (item["unitType"] as? String)?.lowercased() ?? ""
        guard product.contains("actions"), unit.contains("minute") else { return false }
        return GitHubActionsRunnerCatalog.isIncludedStandard(sku: item["sku"] as? String)
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
            let diagnostic = GitHubBillingRequestDiagnostic(
                request: request, response: httpResponse, apiVersion: Self.apiVersion
            )
            throw GitHubBillingAPIError.httpStatus(httpResponse.statusCode, isRateLimited, diagnostic)
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
            case .httpStatus(let status, let isRateLimited, _):
                return failureResult(
                    message: apiError.localizedDescription,
                    recoveryAction: Self.httpRecoveryAction(status: status, isRateLimited: isRateLimited),
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

    private static func httpRecoveryAction(status: Int, isRateLimited: Bool) -> ProviderUsageRecoveryAction {
        if status == 401 { return .reauthenticate }
        if isRateLimit(status: status, isRateLimited: isRateLimited) { return .retryRefresh }
        return [403, 404].contains(status) ? .reauthenticate : .retryRefresh
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

private struct OrganizationProfile: Decodable {
    struct Plan: Decodable {
        let name: String
    }

    let plan: Plan?
}

private struct OrganizationPlanResult: Sendable {
    let name: String
    let message: String?
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

private actor GitHubRepositoryVisibilityCache {
    private struct Key: Hashable {
        let namespace: String
        let repository: String
    }

    private struct Entry {
        let lookup: RepositoryVisibilityLookup
        let expiresAt: Date
    }

    private var entries: [Key: Entry] = [:]

    func resolve(
        repositories: [String],
        namespace: String,
        at date: Date
    ) -> RepositoryVisibilityCacheResolution {
        var lookups: [RepositoryVisibilityLookup] = []
        var missing: [String] = []
        for repository in repositories {
            let key = Key(namespace: namespace, repository: repository.lowercased())
            guard let entry = entries[key], entry.expiresAt > date else {
                entries[key] = nil
                missing.append(repository)
                continue
            }
            lookups.append(RepositoryVisibilityLookup(
                repository: repository,
                isPrivate: entry.lookup.isPrivate,
                isHidden: entry.lookup.isHidden
            ))
        }
        return RepositoryVisibilityCacheResolution(lookups: lookups, missing: missing)
    }

    func store(
        _ lookups: [RepositoryVisibilityLookup],
        namespace: String,
        fetchedAt: Date,
        duration: TimeInterval
    ) {
        guard duration > 0 else { return }
        let expiresAt = fetchedAt.addingTimeInterval(duration)
        for lookup in lookups {
            let key = Key(namespace: namespace, repository: lookup.repository.lowercased())
            entries[key] = Entry(lookup: lookup, expiresAt: expiresAt)
        }
    }
}

private struct RepositoryVisibilityCacheResolution: Sendable {
    let lookups: [RepositoryVisibilityLookup]
    let missing: [String]
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
    var failureMessage: String?

    init(
        values: [String: Bool],
        hiddenRepositoryCount: Int,
        omittedRepositoryCount: Int,
        failureMessage: String? = nil
    ) {
        self.values = values
        self.hiddenRepositoryCount = hiddenRepositoryCount
        self.omittedRepositoryCount = omittedRepositoryCount
        self.failureMessage = failureMessage
    }

    var message: String? {
        if let failureMessage { return failureMessage }
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

// Only fixed route labels and scope capabilities may reach user-visible diagnostics.
// Never retain URLs, owner names, raw response bodies, tokens, or arbitrary header values.
private struct GitHubBillingRequestDiagnostic: Sendable {
    let endpoint: String
    let apiVersion: String
    let acceptsUserScope: Bool
    let grantedUserScope: String

    init(request: URLRequest, response: HTTPURLResponse, apiVersion: String) {
        endpoint = Self.endpointLabel(path: request.url?.path ?? "")
        self.apiVersion = apiVersion
        acceptsUserScope = Self.scopes(response.value(forHTTPHeaderField: "X-Accepted-OAuth-Scopes"))
            .contains("user")
        if let scopes = response.value(forHTTPHeaderField: "X-OAuth-Scopes") {
            grantedUserScope = Self.scopes(scopes).contains("user") ? "present" : "missing"
        } else {
            grantedUserScope = "not reported"
        }
    }

    func description(status: Int) -> String {
        let requirement = acceptsUserScope ? "required" : "not reported"
        return "Request: \(endpoint); HTTP \(status); API \(apiVersion); "
            + "user scope: \(grantedUserScope), endpoint requirement: \(requirement)."
    }

    private static func scopes(_ value: String?) -> Set<String> {
        Set((value ?? "").split { $0 == "," || $0.isWhitespace }.map(String.init))
    }

    private static func endpointLabel(path: String) -> String {
        let components = path.split(separator: "/")
        if components.first == "repos" { return "repository visibility" }
        if components.first == "orgs" { return "organization profile" }
        if path == "/user" { return "signed-in profile" }
        if path == "/user/memberships/orgs" { return "organization membership" }
        let scope = components.first == "users" ? "personal" : "organization"
        let suffix = components.dropFirst(2).joined(separator: "/")
        let routes = [
            "settings/billing/usage/summary": "billing summary",
            "settings/billing/usage": "billing detail",
            "settings/billing/budgets": "billing budgets",
        ]
        guard let route = routes[suffix] else { return "GitHub API" }
        return "\(scope) \(route)"
    }
}

private enum GitHubBillingAPIError: LocalizedError {
    case invalidRequest
    case invalidResponse
    case httpStatus(Int, Bool, GitHubBillingRequestDiagnostic)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "GitHub Billing could not create a valid request."
        case .invalidResponse:
            "GitHub Billing returned data CodexBar could not read."
        case .httpStatus(let status, let isRateLimited, let diagnostic):
            Self.httpStatusMessage(status: status, isRateLimited: isRateLimited)
                + " " + diagnostic.description(status: status)
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
            "GitHub could not provide access to this resource. Sign in again to update permissions. "
                + "A 404 does not confirm that your account is unsupported."
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
