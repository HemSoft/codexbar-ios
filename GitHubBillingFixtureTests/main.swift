// swiftlint:disable line_length
import Foundation
import CodexBarIOS

@main
enum GitHubBillingFixtureRunner {
    static func main() async throws {
        try personalFreeAndProAllowances()
        try organizationBudgetsAndPaginationParsing()
        try malformedAndMissingFields()
        try await providerRequestAndFailureFixtures()
        print("GitHub Billing fixture suite passed: personal plans, repository classification, mixed runners, "
            + "accrued storage, Git LFS, discounts, budgets, pagination, missing data, and HTTP failures.")
    }

    private static func personalFreeAndProAllowances() throws {
        let summary = data(#"""
        {
          "timePeriod": {"year": 2026, "month": 9},
          "user": "octocat",
          "usageItems": [
            {"product":"Actions","sku":"actions_storage","unitType":"GB-hours","grossQuantity":120,"grossAmount":2.125,"discountAmount":2.125,"netAmount":0},
            {"product":"Packages","sku":"packages_storage","unitType":"GB-hours","grossQuantity":24,"grossAmount":0.25,"discountAmount":0.125,"netAmount":0.125},
            {"product":"Git LFS","sku":"lfs_storage","unitType":"GiB-hours","grossQuantity":48,"grossAmount":0.40,"discountAmount":0.40,"netAmount":0},
            {"product":"Git LFS","sku":"lfs_bandwidth","unitType":"GiB","grossQuantity":3.5,"grossAmount":0.35,"discountAmount":0,"netAmount":0.35}
          ]
        }
        """#)
        let usage = data(#"""
        {
          "usageItems": [
            {"date":"2026-09-01","product":"Actions","sku":"Actions Linux","quantity":100,"unitType":"minutes","pricePerUnit":0.006,"grossAmount":0.6,"discountAmount":0.6,"netAmount":0,"repositoryName":"octocat/private"},
            {"date":"2026-09-02","product":"Actions","sku":"Actions Windows","quantity":50,"unitType":"minutes","pricePerUnit":0.01,"grossAmount":0.5,"discountAmount":0.5,"netAmount":0,"repositoryName":"octocat/private"},
            {"date":"2026-09-03","product":"Actions","sku":"Actions macOS","quantity":10,"unitType":"minutes","pricePerUnit":0.062,"grossAmount":0.62,"discountAmount":0.62,"netAmount":0,"repositoryName":"octocat/private"},
            {"date":"2026-09-04","product":"Actions","sku":"Actions Linux","quantity":900,"unitType":"minutes","pricePerUnit":0.006,"grossAmount":5.4,"discountAmount":5.4,"netAmount":0,"repositoryName":"octocat/public"}
          ]
        }
        """#)
        let fetchedAt = try fixtureDate("2026-09-15T12:00:00Z")
        let configuration = personalConfiguration()
        let free = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: summary,
            usageData: usage,
            repositoryVisibility: ["octocat/private": true, "octocat/public": false],
            planName: "free",
            configuration: configuration,
            fetchedAt: fetchedAt
        ), "Free personal fixture did not parse")

        let actionBar = try require(free.bars.first { $0.stableKey == "actions-private-minutes" }, "Actions minutes missing")
        try check(actionBar.used == 300, "Mixed standard runners must apply Linux, Windows, and macOS multipliers")
        try check(actionBar.limit == 2_000, "Free accounts must receive 2,000 included Actions minutes")
        let storage = try require(free.bars.first { $0.stableKey == "actions-packages-storage" }, "Storage bar missing")
        try check(storage.used == 144, "Actions and Packages GB-hours must share one accrued total")
        try check(storage.limit == 360, "September Free storage allowance must be 0.5 GB times 720 hours")
        try check(free.monetaryMetrics.first { $0.kind == .spent }?.amount == Decimal(string: "0.475"), "Net spend precision was lost")
        try check(
            free.usageMessages.contains { $0.contains("does not expose personal budgets") },
            "Personal cards must state that GitHub does not expose personal budgets"
        )

        let pro = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: summary,
            usageData: usage,
            repositoryVisibility: ["octocat/private": true, "octocat/public": false],
            planName: "pro",
            configuration: configuration,
            fetchedAt: fetchedAt
        ), "Pro personal fixture did not parse")
        try check(
            pro.bars.first { $0.stableKey == "actions-private-minutes" }?.limit == 3_000,
            "Pro accounts must receive 3,000 included Actions minutes"
        )
    }

    private static func organizationBudgetsAndPaginationParsing() throws {
        let summary = organizationSummary()
        let pages = [
            data(#"""
            {"budgets":[{"id":"product-budget","budget_type":"ProductPricing","budget_amount":100,"prevent_further_usage":true,"budget_scope":"organization","budget_product_sku":"Actions","budget_alerting":{"will_alert":true,"alert_recipients":[]}}],"has_next_page":true}
            """#),
            data(#"""
            {"budgets":[{"id":"sku-budget","budget_type":"SkuPricing","budget_amount":20,"prevent_further_usage":false,"budget_scope":"organization","budget_product_skus":["actions_linux"],"budget_alerting":{"will_alert":true,"alert_recipients":[]}}],"has_next_page":false}
            """#),
        ]
        let configuration = organizationConfiguration()
        let result = try require(GitHubBillingUsageParser.parseOrganization(
            summaryData: summary,
            usageData: organizationUsage(),
            budgetPageData: pages,
            configuration: configuration,
            fetchedAt: try fixtureDate("2026-09-15T12:00:00Z")
        ), "Organization fixture did not parse")
        try check(result.bars.contains { $0.stableKey == "budget-product-budget" && $0.used == 8 && $0.limit == 100 }, "Product budget did not use product net spend")
        try check(result.bars.contains { $0.stableKey == "budget-sku-budget" && $0.used == 8 && $0.limit == 20 }, "SKU budget did not use SKU net spend")
        try check(result.cardInformationSections.contains { section in
            section.items.contains { $0.label == "Behavior" && $0.detail == "Hard stop" }
        }, "Hard-stop behavior was not retained")
        try check(result.cardInformationSections.contains { section in
            section.items.contains { $0.label == "Behavior" && $0.detail == "Alert only" }
        }, "Alert-only behavior was not retained")

        let noBudget = try require(GitHubBillingUsageParser.parseOrganization(
            summaryData: summary,
            usageData: organizationUsage(),
            budgetPageData: [data("{\"budgets\":[],\"has_next_page\":false}")],
            configuration: configuration,
            fetchedAt: try fixtureDate("2026-09-15T12:00:00Z")
        ), "No-budget fixture did not parse")
        try check(noBudget.usageMessages.contains { $0.contains("no organization budgets") }, "Missing budget state was not explicit")
    }

    private static func malformedAndMissingFields() throws {
        let configuration = personalConfiguration()
        let malformed = GitHubBillingUsageParser.parsePersonal(
            summaryData: data(#"{"timePeriod":{"year":2026,"month":9},"usageItems":[{"product":"Actions","grossAmount":"not-a-decimal"}]}"#),
            usageData: data("{\"usageItems\":[]}"),
            repositoryVisibility: [:],
            planName: "free",
            configuration: configuration,
            fetchedAt: Date()
        )
        try check(malformed == nil, "Malformed decimals must fail closed")

        let missing = GitHubBillingUsageParser.parsePersonal(
            summaryData: data("{\"usageItems\":[{\"product\":\"Actions\"}]}"),
            usageData: data("{\"usageItems\":[]}"),
            repositoryVisibility: [:],
            planName: "unknown-plan",
            configuration: configuration,
            fetchedAt: Date()
        )
        let result = try require(missing, "Missing optional fields should produce unavailable metrics instead of a crash")
        try check(!result.unavailableUsageMetrics.isEmpty, "Unknown plans must explain unavailable allowances")
    }

    private static func providerRequestAndFailureFixtures() async throws {
        let store = FixtureSecretStore()
        let personal = personalConfiguration()
        let credential = try require(
            GitHubBillingCredentialsParser.storedCredential(from: GitHubBillingCredentials(
                accessToken: "fixture-token",
                username: "octocat"
            )),
            "Could not encode fixture credential"
        )
        try store.saveSecret(credential, account: ProviderConfigurationStore.keychainAccount(for: personal))
        let session = FixtureURLProtocol.session()
        let apiBaseURL = try require(URL(string: "https://api.github.test"), "Invalid fixture API URL")
        let now = try fixtureDate("2026-09-15T12:00:00Z")
        let provider = GitHubBillingUsageProvider(
            secretStore: store,
            session: session,
            apiBaseURL: apiBaseURL,
            now: { now }
        )

        FixtureURLProtocol.setHandler { request in
            switch request.url?.path {
            case "/user":
                return response(request, status: 200, body: #"{"login":"octocat","plan":{"name":"free"}}"#)
            case "/users/octocat/settings/billing/usage/summary":
                return response(request, status: 200, data: personalSummary())
            case "/users/octocat/settings/billing/usage":
                return response(request, status: 200, body: #"{"usageItems":[{"product":"Actions","sku":"Actions Linux","quantity":10,"unitType":"minutes","repositoryName":"octocat/private","grossAmount":0.06,"discountAmount":0.06,"netAmount":0}]}"#)
            case "/repos/octocat/private":
                return response(request, status: 200, body: #"{"private":true}"#)
            default:
                return response(request, status: 404, body: "{}")
            }
        }
        let success = try await provider.fetchUsage(for: personal)
        try check(success.failureMessage == nil, "Documented personal endpoints should produce usage")

        for status in [401, 403, 404, 429, 500] {
            FixtureURLProtocol.setHandler { request in response(request, status: status, body: "{}") }
            let result = try await provider.fetchUsage(for: personal)
            let expected: String = switch status {
            case 401: "Sign in again"
            case 403: "lacks permission"
            case 404: "Enhanced billing"
            case 429: "rate limit"
            default: "temporarily unavailable"
            }
            try check(
                result.failureMessage?.localizedCaseInsensitiveContains(expected) == true,
                "HTTP \(status) did not produce its distinct safe message"
            )
        }

        let organization = organizationConfiguration()
        try store.saveSecret(credential, account: ProviderConfigurationStore.keychainAccount(for: organization))
        let pageCounter = LockedCounter()
        FixtureURLProtocol.setHandler { request in
            guard let url = request.url else { return response(request, status: 500, body: "{}") }
            if url.path.hasSuffix("/usage/summary") {
                return response(request, status: 200, data: organizationSummary())
            }
            if url.path.hasSuffix("/usage") {
                return response(request, status: 200, data: organizationUsage())
            }
            if url.path.hasSuffix("/budgets") {
                let page = Int(URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first { $0.name == "page" }?.value ?? "1") ?? 1
                pageCounter.increment()
                let body = page == 1
                    ? #"{"budgets":[{"id":"one","budget_type":"ProductPricing","budget_amount":100,"prevent_further_usage":true,"budget_product_sku":"Actions"}],"has_next_page":true}"#
                    : #"{"budgets":[{"id":"two","budget_type":"SkuPricing","budget_amount":20,"prevent_further_usage":false,"budget_product_sku":"actions_linux"}],"has_next_page":false}"#
                return response(request, status: 200, body: body)
            }
            return response(request, status: 404, body: "{}")
        }
        let paged = try await provider.fetchUsage(for: organization)
        try check(paged.failureMessage == nil, "Paginated organization fixture failed")
        try check(pageCounter.value == 2, "Budget pagination did not retrieve every page")
    }

    private static func personalSummary() -> Data {
        data(#"{"timePeriod":{"year":2026,"month":9},"usageItems":[{"product":"Actions","sku":"actions_storage","unitType":"GB-hours","grossQuantity":12,"grossAmount":0.1,"discountAmount":0.1,"netAmount":0}]}"#)
    }

    private static func organizationSummary() -> Data {
        data(#"{"timePeriod":{"year":2026,"month":9},"organization":"Example-Engineering","usageItems":[{"product":"Actions","sku":"actions_linux","unitType":"minutes","grossQuantity":1000,"grossAmount":10.25,"discountQuantity":200,"discountAmount":2.25,"netQuantity":800,"netAmount":8.00},{"product":"Packages","sku":"packages_storage","unitType":"GB-hours","grossQuantity":50,"grossAmount":1.125,"discountQuantity":25,"discountAmount":0.5625,"netQuantity":25,"netAmount":0.5625}]}"#)
    }

    private static func organizationUsage() -> Data {
        data(#"{"usageItems":[{"date":"2026-09-01","product":"Actions","sku":"actions_linux","quantity":1000,"unitType":"minutes","grossAmount":10.25,"discountAmount":2.25,"netAmount":8,"repositoryName":"example/private"}]}"#)
    }

    private static func personalConfiguration() -> ProviderAccountConfiguration {
        ProviderAccountConfiguration(
            id: "github-billing.personal",
            providerID: .githubBilling,
            accountLabel: "octocat",
            authMethod: .browserSession,
            githubBillingAccountScope: .personal,
            githubBillingOwner: "octocat"
        )
    }

    private static func organizationConfiguration() -> ProviderAccountConfiguration {
        ProviderAccountConfiguration(
            id: "github-billing.organization",
            providerID: .githubBilling,
            accountLabel: "Example Engineering",
            authMethod: .browserSession,
            githubBillingAccountScope: .organization,
            githubBillingOwner: "Example-Engineering"
        )
    }

    private static func fixtureDate(_ value: String) throws -> Date {
        guard let date = ISO8601DateFormatter().date(from: value) else {
            throw FixtureFailure(message: "Invalid fixture date: \(value)")
        }
        return date
    }

    private static func data(_ value: String) -> Data {
        Data(value.utf8)
    }

    private static func require<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else { throw FixtureFailure(message: message) }
        return value
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw FixtureFailure(message: message) }
    }

    private static func response(
        _ request: URLRequest,
        status: Int,
        body: String
    ) -> (HTTPURLResponse, Data) {
        response(request, status: status, data: data(body))
    }

    private static func response(
        _ request: URLRequest,
        status: Int,
        data: Data
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (response, data)
    }
}

private struct FixtureFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class FixtureSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func readSecret(account: String) throws -> String? {
        lock.withLock { values[account] }
    }

    func saveSecret(_ secret: String, account: String) throws {
        lock.withLock { values[account] = secret }
    }

    func deleteSecret(account: String) throws {
        _ = lock.withLock { values.removeValue(forKey: account) }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class FixtureURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (HTTPURLResponse, Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?

    static func setHandler(_ handler: @escaping Handler) {
        lock.withLock { self.handler = handler }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    // swiftlint:disable:next static_over_final_class
    override class func canInit(with request: URLRequest) -> Bool { true }
    // swiftlint:disable:next static_over_final_class
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.lock.withLock({ Self.handler }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
// swiftlint:enable line_length
