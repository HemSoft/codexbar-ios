// swiftlint:disable line_length
import Foundation
import CodexBarIOS

@main
enum GitHubBillingFixtureRunner {
    static func main() async throws {
        try await personalAuthorizationScopeRegression()
        try await personalPermissionDiagnostics()
        try personalFreeAndProAllowances()
        try planAllowanceContract()
        try packagesVisibilityEvidenceContract()
        try amountAndProductSummaryContract()
        try currencyEvidenceContract()
        try organizationBudgetsAndPaginationParsing()
        try malformedAndMissingFields()
        try await accountIsolationFixtures()
        try await providerRequestAndFailureFixtures()
        print("GitHub Billing fixture suite passed: personal and organization allowances, zero usage, overage, "
            + "repository classification, current-price runner validation, shared storage, Packages, Codespaces, "
            + "Git LFS, quantity discounts, budgets, pagination, currency evidence, product summaries, and failures.")
    }

    private static func personalAuthorizationScopeRegression() async throws {
        let authorizationURL = GitHubBillingWebAuthService.authorizationURL(
            clientID: "fixture-client", redirectURI: "http://localhost:8765/callback",
            state: "fixture-state", codeChallenge: "fixture-challenge"
        )
        let scope = URLComponents(url: authorizationURL, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "scope" }?.value ?? ""
        let scopes = Set(scope.split(separator: " ").map(String.init))
        let provider = GitHubBillingUsageProvider(session: FixtureURLProtocol.session())
        // GitHub advertises X-Accepted-OAuth-Scopes: user on both personal billing endpoints.
        // This models that permission boundary, not a live OAuth compatibility test.
        FixtureURLProtocol.setHandler { request in
            if request.url?.path == "/user" {
                return response(request, status: 200, body: #"{"login":"octocat","plan":{"name":"free"}}"#)
            }
            guard scopes.contains("user") else {
                return response(request, status: 404, body: #"{"message":"Not Found"}"#)
            }
            if request.url?.path.hasSuffix("/summary") == true {
                return response(request, status: 200, data: personalSummary())
            }
            return response(request, status: 200, body: #"{"usageItems":[]}"#)
        }
        let result = try await provider.validateCandidate(
            GitHubBillingCredentials(accessToken: "fixture-token", username: "octocat"),
            for: personalConfiguration()
        )
        try check(result.failureMessage == nil, "Personal connection must request the accepted user scope")
        try check(scopes == ["admin:org", "repo", "user"], "Billing must request only its documented scopes")
    }

    private static func personalPermissionDiagnostics() async throws {
        for endpoint in ["usage/summary", "usage"] {
            for scope: String? in ["repo, read:org, read:user", "repo,user", "", nil] {
                try await assertPersonalPermissionDiagnostic(endpoint: endpoint, grantedScope: scope)
            }
        }
    }

    private static func assertPersonalPermissionDiagnostic(endpoint: String, grantedScope: String?) async throws {
        let store = FixtureSecretStore()
        let provider = GitHubBillingUsageProvider(secretStore: store, session: FixtureURLProtocol.session())
        let credentials = GitHubBillingCredentials(accessToken: "fixture-secret-never-log", username: "octocat")
        FixtureURLProtocol.setHandler { request in
            if request.url?.path == "/user" {
                return response(request, status: 200, body: #"{"login":"octocat","plan":{"name":"free"}}"#)
            }
            if request.url?.path.hasSuffix("/billing/\(endpoint)") == true {
                var headers = [
                    "X-Accepted-OAuth-Scopes": "user, malicious-header-data",
                    "X-GitHub-Request-Id": "private-request-id",
                ]
                headers["X-OAuth-Scopes"] = grantedScope.map { $0 + ", malicious-header-data" }
                return response(request, status: 404, data: data(#"{"message":"fixture-secret-never-log octocat private-billing"}"#), headers: headers)
            }
            return response(request, status: 200, body: #"{"usageItems":[]}"#)
        }
        do {
            _ = try await provider.validateCandidate(credentials, for: personalConfiguration())
            throw FixtureFailure(message: "A rejected personal connection must not succeed")
        } catch {
            let message = error.localizedDescription
            let route = endpoint == "usage" ? "personal billing detail" : "personal billing summary"
            try check(message.contains(route), "Connection errors must identify the failing endpoint without its owner")
            try check(message.contains("HTTP 404; API 2026-03-10"), "Connection errors must retain status and requested API version")
            let reportedScope = grantedScope == "repo,user" ? "present" : "missing"
            let expectedScope = grantedScope == nil ? "not reported" : reportedScope
            try check(message.contains("user scope: \(expectedScope), endpoint requirement: required"), "Scope diagnostics must distinguish user from read:user")
            for privateValue in ["fixture-secret-never-log", "octocat", "private-billing", "malicious-header-data", "private-request-id"] {
                try check(!message.contains(privateValue), "Diagnostics must not disclose raw provider data")
            }
            try check(message.contains("Sign in again"), "An ambiguous 404 should offer reauthorization, not declare the account unsupported")
        }
        let savedSecret = try store.readSecret(account: ProviderConfigurationStore.keychainAccount(for: personalConfiguration()))
        try check(savedSecret == nil, "Failed candidate validation must never save credentials")
    }

    private static func personalFreeAndProAllowances() throws {
        let summary = data(#"""
        {
          "timePeriod": {"year": 2026, "month": 9},
          "user": "octocat",
          "usageItems": [
            {"product":"Actions","sku":"Actions Linux","unitType":"minutes","pricePerUnit":0.006,"grossQuantity":1000,"grossAmount":6,"discountQuantity":1000,"discountAmount":6,"netQuantity":0,"netAmount":0},
            {"product":"Actions","sku":"Actions Windows","unitType":"minutes","pricePerUnit":0.01,"grossQuantity":50,"grossAmount":0.5,"discountQuantity":50,"discountAmount":0.5,"netQuantity":0,"netAmount":0},
            {"product":"Actions","sku":"Actions macOS","unitType":"minutes","pricePerUnit":0.062,"grossQuantity":10,"grossAmount":0.62,"discountQuantity":10,"discountAmount":0.62,"netQuantity":0,"netAmount":0},
            {"product":"Actions","sku":"actions_linux_arm","unitType":"minutes","pricePerUnit":0.005,"grossQuantity":20,"grossAmount":0.1,"discountQuantity":20,"discountAmount":0.1,"netQuantity":0,"netAmount":0},
            {"product":"Actions","sku":"actions_windows_arm","unitType":"minutes","pricePerUnit":0.01,"grossQuantity":10,"grossAmount":0.1,"discountQuantity":10,"discountAmount":0.1,"netQuantity":0,"netAmount":0},
            {"product":"Actions","sku":"actions_storage","unitType":"GB-hours","grossQuantity":120,"grossAmount":2.125,"discountQuantity":120,"discountAmount":2.125,"netQuantity":0,"netAmount":0},
            {"product":"Packages","sku":"packages_storage","unitType":"GB-hours","grossQuantity":24,"grossAmount":0.25,"discountQuantity":12,"discountAmount":0.125,"netQuantity":12,"netAmount":0.125},
            {"product":"Actions","sku":"actions_cache_storage","unitType":"GB-hours","grossQuantity":100,"grossAmount":0,"discountAmount":0,"netAmount":0},
            {"product":"Git LFS","sku":"lfs_storage","unitType":"GiB-hours","grossQuantity":48,"grossAmount":0.40,"discountQuantity":48,"discountAmount":0.40,"netQuantity":0,"netAmount":0},
            {"product":"Git LFS","sku":"lfs_bandwidth","unitType":"GiB","grossQuantity":3.5,"grossAmount":0.35,"discountQuantity":0,"discountAmount":0,"netQuantity":3.5,"netAmount":0.35}
          ]
        }
        """#)
        let usage = data(#"""
        {
          "usageItems": [
            {"date":"2026-09-01","product":"Actions","sku":"Actions Linux","quantity":100,"unitType":"minutes","pricePerUnit":0.006,"grossAmount":0.6,"discountAmount":0.6,"netAmount":0,"repositoryName":"octocat/private"},
            {"date":"2026-09-02","product":"Actions","sku":"Actions Windows","quantity":50,"unitType":"minutes","pricePerUnit":0.01,"grossAmount":0.5,"discountAmount":0.5,"netAmount":0,"repositoryName":"octocat/private"},
            {"date":"2026-09-03","product":"Actions","sku":"Actions macOS","quantity":10,"unitType":"minutes","pricePerUnit":0.062,"grossAmount":0.62,"discountAmount":0.62,"netAmount":0,"repositoryName":"octocat/private"},
            {"date":"2026-09-04","product":"Actions","sku":"actions_linux_arm","quantity":20,"unitType":"minutes","pricePerUnit":0.005,"grossAmount":0.1,"discountAmount":0.1,"netAmount":0,"repositoryName":"octocat/private"},
            {"date":"2026-09-05","product":"Actions","sku":"actions_windows_arm","quantity":10,"unitType":"minutes","pricePerUnit":0.01,"grossAmount":0.1,"discountAmount":0.1,"netAmount":0,"repositoryName":"octocat/private"},
            {"date":"2026-09-06","product":"Actions","sku":"Actions Linux","quantity":900,"unitType":"minutes","pricePerUnit":0.006,"grossAmount":5.4,"discountAmount":5.4,"netAmount":0,"repositoryName":"octocat/public"},
            {"date":"2026-09-07","product":"Actions","sku":"actions_storage","quantity":100,"unitType":"GB-hours","pricePerUnit":0.01,"grossAmount":1,"discountAmount":1,"netAmount":0,"repositoryName":"octocat/private"},
            {"date":"2026-09-08","product":"Actions","sku":"actions_storage","quantity":20,"unitType":"GB-hours","pricePerUnit":0.01,"grossAmount":0.2,"discountAmount":0.2,"netAmount":0,"repositoryName":"octocat/public"},
            {"date":"2026-09-09","product":"Packages","sku":"packages_storage","quantity":20,"unitType":"GB-hours","pricePerUnit":0.01,"grossAmount":0.2,"discountAmount":0.1,"netAmount":0.1,"repositoryName":"octocat/private"},
            {"date":"2026-09-10","product":"Packages","sku":"packages_storage","quantity":4,"unitType":"GB-hours","pricePerUnit":0.01,"grossAmount":0.04,"discountAmount":0.04,"netAmount":0,"repositoryName":"octocat/public"}
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
        try check(actionBar.used == 190, "Mixed standard runners must use GitHub's returned minute quantities")
        try check(actionBar.limit == 2_000, "Free accounts must receive 2,000 included Actions minutes")
        try check(
            free.cardInformationSections.contains { section in
                section.items.contains { item in
                    item.label == "Actions plan allowance"
                        && item.detail.contains("190 of 2,000 minutes used")
                        && item.detail.contains("1,810 minutes remaining")
                }
            },
            "Personal allowance details must show used, included, and remaining minutes"
        )
        try check(
            free.unavailableUsageMetrics["githubBilling.actions-packages-storage"]?
                .contains("does not identify package visibility") == true,
            "Nonzero Packages storage must not be inferred from repository visibility"
        )
        try incompleteStorageEvidenceFixtures(
            summary: summary,
            configuration: configuration,
            fetchedAt: fetchedAt
        )
        let lfsStorage = try require(free.bars.first { $0.stableKey == "lfs-storage" }, "Git LFS storage bar missing")
        try check(lfsStorage.used == 48 && lfsStorage.limit == 7_200, "Git LFS storage must use its 10 GiB accrued allowance")
        let lfsBandwidth = try require(free.bars.first { $0.stableKey == "lfs-bandwidth" }, "Git LFS bandwidth bar missing")
        try check(lfsBandwidth.used == 3.5 && lfsBandwidth.limit == 10, "Git LFS bandwidth must use its separate monthly allowance")
        try check(free.monetaryMetrics.first { $0.kind == .grossSpend }?.amount == Decimal(string: "10.445"), "Gross spend precision was lost")
        try check(free.monetaryMetrics.first { $0.kind == .discounts }?.amount == Decimal(string: "9.97"), "Full and partial discounts were not retained")
        try check(free.monetaryMetrics.first { $0.kind == .spent }?.amount == Decimal(string: "0.475"), "Net spend precision was lost")
        try check(
            free.cardInformationSections.contains { section in
                section.id == "github-billing.amounts-and-currency"
                    && section.items.contains { item in
                        item.label == "Personal budgets"
                            && item.detail.contains("does not expose personal budgets")
                    }
            },
            "Personal budget qualifications belong in the organized amounts and currency section"
        )
        try check(
            !free.usageMessages.contains { $0.contains("does not expose personal budgets") },
            "Healthy cards must not stack the routine personal-budget disclaimer below the values"
        )
        try check(
            free.monetaryMetrics.allSatisfy { $0.decimalPlaces == 2 },
            "Aggregate spend metrics must always use exactly two fractional digits"
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
        try check(
            pro.bars.contains { $0.stableKey == "actions-packages-storage" } == false
                && pro.unavailableUsageMetrics["githubBilling.actions-packages-storage"] != nil,
            "Conflicting Pro storage entitlements must keep the shared allowance unavailable"
        )
        try check(
            pro.bars.first { $0.stableKey == "lfs-storage" }?.limit == 7_200,
            "Pro Git LFS storage must retain its separate 10 GiB allowance"
        )

        let paidLargerSummary = data(#"{"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[{"product":"Actions","sku":"actions_macos_l","unitType":"minutes","pricePerUnit":0.12,"grossQuantity":10,"grossAmount":1.2,"discountQuantity":0,"discountAmount":0,"netQuantity":10,"netAmount":1.2}]}"#)
        let paidLargerUsage = data(#"{"usageItems":[{"product":"Actions","sku":"actions_macos_l","quantity":10,"unitType":"minutes","pricePerUnit":0.12,"repositoryName":"octocat/private","grossAmount":1.2,"discountAmount":0,"netAmount":1.2}]}"#)
        let paidLargerRunner = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: paidLargerSummary,
            usageData: paidLargerUsage,
            repositoryVisibility: [:],
            planName: "pro",
            configuration: configuration,
            fetchedAt: fetchedAt
        ), "Paid larger runner fixture did not parse")
        try check(
            paidLargerRunner.bars.first { $0.stableKey == "actions-private-minutes" }?.used == 0,
            "Known paid larger runners must be excluded from standard included minutes"
        )

        try runnerContractFailures(configuration: configuration, fetchedAt: fetchedAt)

        let unknownRunnerSummary = data(#"{"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[{"product":"Actions","sku":"actions_future_runner","unitType":"minutes","pricePerUnit":0.02,"grossQuantity":10,"grossAmount":0.2,"discountQuantity":10,"discountAmount":0.2,"netQuantity":0,"netAmount":0}]}"#)
        let unknownRunnerUsage = data(#"{"usageItems":[{"product":"Actions","sku":"actions_future_runner","quantity":10,"unitType":"minutes","pricePerUnit":0.02,"repositoryName":"octocat/private","grossAmount":0.2,"discountAmount":0.2,"netAmount":0}]}"#)
        let unknownRunner = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: unknownRunnerSummary,
            usageData: unknownRunnerUsage,
            repositoryVisibility: ["octocat/private": true],
            planName: "pro",
            configuration: configuration,
            fetchedAt: fetchedAt
        ), "Unknown runner fixture did not parse")
        try check(
            unknownRunner.bars.contains { $0.stableKey == "actions-private-minutes" } == false,
            "Unknown runners must not be guessed as standard included minutes"
        )
        try check(
            unknownRunner.unavailableUsageMetrics["githubBilling.actions-private-minutes"] != nil,
            "Unknown runners need an unavailable explanation"
        )
        try check(
            unknownRunner.usageMessages.contains { $0.contains("outside the verified runner") },
            "Unavailable allowance explanations must be visible on the account card"
        )

        try changedActionsProductFixture(configuration: configuration, fetchedAt: fetchedAt)

        let partialActionsSummary = data(#"{"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[{"product":"Actions","sku":"actions_linux","unitType":"minutes","pricePerUnit":0.006,"grossQuantity":100,"grossAmount":0.6,"discountQuantity":100,"discountAmount":0.6,"netQuantity":0,"netAmount":0},{"product":"Actions","sku":"actions_windows","unitType":"minutes","pricePerUnit":0.01,"grossQuantity":50,"grossAmount":0.5,"discountQuantity":50,"discountAmount":0.5,"netQuantity":0,"netAmount":0}]}"#)
        let partialActionsUsage = data(#"{"usageItems":[{"product":"Actions","sku":"actions_linux","quantity":100,"unitType":"minutes","pricePerUnit":0.006,"repositoryName":"octocat/private","grossAmount":0.6,"discountAmount":0.6,"netAmount":0}]}"#)
        let partialActions = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: partialActionsSummary,
            usageData: partialActionsUsage,
            repositoryVisibility: ["octocat/private": true],
            planName: "free",
            configuration: configuration,
            fetchedAt: fetchedAt
        ), "Partial Actions fixture did not parse")
        try check(
            partialActions.unavailableUsageMetrics["githubBilling.actions-private-minutes"]?
                .contains("did not reconcile") == true,
            "Partial Actions detail must not produce an understated complete percentage"
        )

        let unknownStorage = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: data(#"{"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[{"product":"Actions","sku":"actions_cache_storage","unitType":"GB-hours","grossQuantity":200,"grossAmount":0,"discountAmount":0,"netAmount":0},{"product":"Actions","sku":"actions_mystery_storage","unitType":"GB-hours","grossQuantity":10,"grossAmount":0,"discountAmount":0,"netAmount":0}]}"#),
            usageData: data(#"{"usageItems":[]}"#),
            repositoryVisibility: [:],
            planName: "free",
            configuration: configuration,
            fetchedAt: fetchedAt
        ), "Unknown shared storage fixture did not parse")
        try check(
            unknownStorage.unavailableUsageMetrics["githubBilling.actions-packages-storage"] != nil,
            "An unknown shared-storage SKU must fail closed without turning cache into account-wide usage"
        )
        try check(
            unknownStorage.bars.contains { $0.stableKey == "actions-packages-storage" } == false,
            "Incomplete shared-storage evidence must not produce an understated percentage"
        )
    }

    private static func incompleteStorageEvidenceFixtures(
        summary: Data,
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date
    ) throws {
        let missingStorageDetails = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: summary,
            usageData: data(#"{"usageItems":[]}"#),
            repositoryVisibility: [:],
            planName: "free",
            configuration: configuration,
            fetchedAt: fetchedAt
        ), "Incomplete repository storage fixture did not parse")
        try check(
            missingStorageDetails.unavailableUsageMetrics["githubBilling.actions-packages-storage"] != nil,
            "Shared storage must stay unavailable without complete repository eligibility"
        )
        let incompleteStorageQuantities = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: data(#"{"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[{"product":"Actions","sku":"actions_storage","unitType":"GB-hours","grossQuantity":10,"grossAmount":0.1,"discountAmount":0.1,"netAmount":0}]}"#),
            usageData: data(#"{"usageItems":[{"product":"Actions","sku":"actions_storage","quantity":10,"unitType":"GB-hours","repositoryName":"octocat/private"}]}"#),
            repositoryVisibility: ["octocat/private": true],
            planName: "free",
            configuration: configuration,
            fetchedAt: fetchedAt
        ), "Incomplete storage quantity fixture did not parse")
        try check(
            incompleteStorageQuantities.unavailableUsageMetrics["githubBilling.actions-packages-storage"]?
                .contains("gross, discount, and billable") == true,
            "Missing discount or billable quantities must keep the allowance unavailable"
        )
    }

    private static func changedActionsProductFixture(
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date
    ) throws {
        let renamedProduct = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: data(#"{"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[{"product":"CI","sku":"actions_linux","unitType":"minutes","pricePerUnit":0.006,"grossQuantity":10,"grossAmount":0.06,"discountQuantity":10,"discountAmount":0.06,"netQuantity":0,"netAmount":0}]}"#),
            usageData: data(#"{"usageItems":[{"product":"CI","sku":"actions_linux","quantity":10,"unitType":"minutes","pricePerUnit":0.006,"repositoryName":"octocat/private","grossAmount":0.06,"discountAmount":0.06,"netAmount":0}]}"#),
            repositoryVisibility: ["octocat/private": true],
            planName: "free",
            configuration: configuration,
            fetchedAt: fetchedAt
        ), "Changed Actions product fixture did not parse")
        try check(
            renamedProduct.unavailableUsageMetrics["githubBilling.actions-private-minutes"] != nil,
            "A known Actions SKU with a changed product contract must fail closed"
        )
        try check(
            renamedProduct.bars.contains { $0.stableKey == "actions-private-minutes" } == false,
            "A changed Actions product contract must not silently understate allowance usage"
        )
    }

    private static func runnerContractFailures(
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date
    ) throws {
        let selfHostedSummary = data(#"{"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[{"product":"Actions","sku":"actions_self_hosted","unitType":"minutes","pricePerUnit":0,"grossQuantity":100,"grossAmount":0,"discountQuantity":0,"discountAmount":0,"netQuantity":100,"netAmount":0}]}"#)
        let selfHostedUsage = data(#"{"usageItems":[{"product":"Actions","sku":"actions_self_hosted","quantity":100,"unitType":"minutes","pricePerUnit":0,"repositoryName":"octocat/private","grossAmount":0,"discountAmount":0,"netAmount":0}]}"#)
        let selfHosted = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: selfHostedSummary,
            usageData: selfHostedUsage,
            repositoryVisibility: ["octocat/private": true],
            planName: "free",
            configuration: configuration,
            fetchedAt: fetchedAt
        ), "Self-hosted runner fixture did not parse")
        try check(
            selfHosted.bars.first { $0.stableKey == "actions-private-minutes" }?.used == 0,
            "Self-hosted runners must not consume the hosted standard-runner allowance"
        )

        let unsupportedUnitSummary = data(#"{"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[{"product":"Actions","sku":"actions_linux","unitType":"hours","pricePerUnit":0.006,"grossQuantity":1,"grossAmount":0.006,"discountQuantity":1,"discountAmount":0.006,"netQuantity":0,"netAmount":0}]}"#)
        let unsupportedUnitUsage = data(#"{"usageItems":[{"product":"Actions","sku":"actions_linux","quantity":1,"unitType":"hours","pricePerUnit":0.006,"repositoryName":"octocat/private","grossAmount":0.006,"discountAmount":0.006,"netAmount":0}]}"#)
        let unsupportedUnit = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: unsupportedUnitSummary,
            usageData: unsupportedUnitUsage,
            repositoryVisibility: ["octocat/private": true],
            planName: "free",
            configuration: configuration,
            fetchedAt: fetchedAt
        ), "Unsupported runner unit fixture did not parse")
        try check(
            unsupportedUnit.unavailableUsageMetrics["githubBilling.actions-private-minutes"] != nil,
            "A changed Actions unit contract must fail closed instead of presenting zero usage"
        )

        let changedPriceSummary = data(#"{"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[{"product":"Actions","sku":"actions_linux","unitType":"minutes","pricePerUnit":0.007,"grossQuantity":10,"grossAmount":0.07,"discountQuantity":10,"discountAmount":0.07,"netQuantity":0,"netAmount":0}]}"#)
        let changedPriceUsage = data(#"{"usageItems":[{"product":"Actions","sku":"actions_linux","quantity":10,"unitType":"minutes","pricePerUnit":0.007,"repositoryName":"octocat/private","grossAmount":0.07,"discountAmount":0.07,"netAmount":0}]}"#)
        let changedPrice = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: changedPriceSummary,
            usageData: changedPriceUsage,
            repositoryVisibility: ["octocat/private": true],
            planName: "free",
            configuration: configuration,
            fetchedAt: fetchedAt
        ), "Changed runner price fixture did not parse")
        try check(
            changedPrice.unavailableUsageMetrics["githubBilling.actions-private-minutes"]?
                .contains("price outside") == true,
            "A changed standard-runner price must fail closed"
        )

        let conflictingDiscount = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: data(#"{"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[{"product":"Actions","sku":"actions_linux","unitType":"minutes","pricePerUnit":0.006,"grossQuantity":10,"grossAmount":0.06,"discountQuantity":2,"discountAmount":0.012,"netQuantity":8,"netAmount":0.048}]}"#),
            usageData: data(#"{"usageItems":[{"product":"Actions","sku":"actions_linux","quantity":10,"unitType":"minutes","pricePerUnit":0.006,"repositoryName":"octocat/private","grossAmount":0.06,"discountAmount":0.012,"netAmount":0.048}]}"#),
            repositoryVisibility: ["octocat/private": true],
            planName: "free",
            configuration: configuration,
            fetchedAt: fetchedAt
        ), "Conflicting Actions discount fixture did not parse")
        try check(
            conflictingDiscount.unavailableUsageMetrics["githubBilling.actions-private-minutes"]?
                .contains("before the included allowance was exhausted") == true,
            "Billable standard minutes below the included limit must fail closed"
        )
    }

    private static func planAllowanceContract() throws {
        let fetchedAt = try fixtureDate("2026-09-15T12:00:00Z")
        let summary = data(#"""
        {
          "timePeriod": {"year": 2026, "month": 9},
          "user": "octocat",
          "usageItems": [
            {"product":"Actions","sku":"actions_linux","unitType":"minutes","pricePerUnit":0.006,"grossQuantity":1100,"grossAmount":6.6,"discountQuantity":1100,"discountAmount":6.6,"netQuantity":0,"netAmount":0},
            {"product":"Actions","sku":"actions_windows","unitType":"minutes","pricePerUnit":0.01,"grossQuantity":60,"grossAmount":0.6,"discountQuantity":60,"discountAmount":0.6,"netQuantity":0,"netAmount":0},
            {"product":"Actions","sku":"actions_storage","unitType":"GB-hours","pricePerUnit":0.01,"grossQuantity":120,"grossAmount":1.2,"discountQuantity":120,"discountAmount":1.2,"netQuantity":0,"netAmount":0},
            {"product":"Git LFS","sku":"lfs_storage","unitType":"GB-hours","pricePerUnit":0.001,"grossQuantity":48,"grossAmount":0.048,"discountQuantity":48,"discountAmount":0.048,"netQuantity":0,"netAmount":0},
            {"product":"Git LFS","sku":"lfs_bandwidth","unitType":"GB","pricePerUnit":0.0875,"grossQuantity":3.5,"grossAmount":0.30625,"discountQuantity":3.5,"discountAmount":0.30625,"netQuantity":0,"netAmount":0},
            {"product":"Codespaces","sku":"codespaces_compute_d4","unitType":"hours","pricePerUnit":0.36,"grossQuantity":7.5,"grossAmount":2.7,"discountQuantity":7.5,"discountAmount":2.7,"netQuantity":0,"netAmount":0},
            {"product":"Codespaces","sku":"codespaces_storage","unitType":"GB-hours","pricePerUnit":0.0001,"grossQuantity":7200,"grossAmount":0.72,"discountQuantity":7200,"discountAmount":0.72,"netQuantity":0,"netAmount":0}
          ]
        }
        """#)
        let usage = data(#"""
        {"usageItems":[
          {"date":"2026-09-01","product":"Actions","sku":"actions_linux","quantity":100,"unitType":"minutes","pricePerUnit":0.006,"grossAmount":0.6,"discountAmount":0.6,"netAmount":0,"repositoryName":"octocat/private"},
          {"date":"2026-09-02","product":"Actions","sku":"actions_windows","quantity":60,"unitType":"minutes","pricePerUnit":0.01,"grossAmount":0.6,"discountAmount":0.6,"netAmount":0,"repositoryName":"octocat/private"},
          {"date":"2026-09-03","product":"Actions","sku":"actions_linux","quantity":1000,"unitType":"minutes","pricePerUnit":0.006,"grossAmount":6,"discountAmount":6,"netAmount":0,"repositoryName":"octocat/public"},
          {"date":"2026-09-04","product":"Actions","sku":"actions_storage","quantity":100,"unitType":"GB-hours","pricePerUnit":0.01,"grossAmount":1,"discountAmount":1,"netAmount":0,"repositoryName":"octocat/private"},
          {"date":"2026-09-05","product":"Actions","sku":"actions_storage","quantity":20,"unitType":"GB-hours","pricePerUnit":0.01,"grossAmount":0.2,"discountAmount":0.2,"netAmount":0,"repositoryName":"octocat/public"}
        ]}
        """#)
        let free = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: summary,
            usageData: usage,
            repositoryVisibility: ["octocat/private": true, "octocat/public": false],
            planName: "free",
            configuration: personalConfiguration(),
            fetchedAt: fetchedAt
        ), "Complete Free allowance fixture did not parse")
        let expected: [(String, Double, Double)] = [
            ("actions-private-minutes", 160, 2_000),
            ("actions-packages-storage", 100, 360),
            ("packages-data-transfer", 0, 1),
            ("lfs-storage", 48, 7_200),
            ("lfs-bandwidth", 3.5, 10),
            ("codespaces-core-hours", 30, 120),
            ("codespaces-storage", 7_200, 10_800),
        ]
        for (key, used, limit) in expected {
            let bar = try require(free.bars.first { $0.stableKey == key }, "Missing allowance bar \(key)")
            try check(bar.used == used && bar.limit == limit, "Incorrect allowance values for \(key)")
        }

        let isolatedMalformedLFS = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: data(#"{"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[{"product":"Git LFS","sku":"lfs_storage","unitType":"GB","pricePerUnit":0.01,"grossQuantity":2,"grossAmount":0.02,"discountQuantity":2,"discountAmount":0.02,"netQuantity":0,"netAmount":0},{"product":"Git LFS","sku":"lfs_bandwidth","unitType":"GB","pricePerUnit":0.01,"grossQuantity":3,"grossAmount":0.03,"discountQuantity":3,"discountAmount":0.03,"netQuantity":0,"netAmount":0}]}"#),
            usageData: data(#"{"usageItems":[]}"#),
            repositoryVisibility: [:],
            planName: "free",
            configuration: personalConfiguration(),
            fetchedAt: fetchedAt
        ), "Isolated malformed Git LFS fixture did not parse")
        try check(
            isolatedMalformedLFS.unavailableUsageMetrics["githubBilling.lfs-storage"] != nil,
            "Malformed Git LFS storage must remain unavailable"
        )
        try check(
            isolatedMalformedLFS.bars.first { $0.stableKey == "lfs-bandwidth" }?.used == 3,
            "Malformed Git LFS storage must not erase trustworthy bandwidth"
        )

        let monthlyCodespaces = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: data(#"{"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[{"product":"Codespaces","sku":"codespaces_storage","unitType":"GB-month","grossQuantity":10,"grossAmount":0.7,"discountQuantity":10,"discountAmount":0.7,"netQuantity":0,"netAmount":0}]}"#),
            usageData: data(#"{"usageItems":[]}"#),
            repositoryVisibility: [:],
            planName: "free",
            configuration: personalConfiguration(),
            fetchedAt: fetchedAt
        ), "Monthly Codespaces storage fixture did not parse")
        try check(
            monthlyCodespaces.bars.first { $0.stableKey == "codespaces-storage" }?.used == 7_200,
            "A monthly Codespaces quantity must normalize to the accrued GB-hour presentation"
        )
        let transfer = try require(
            free.bars.first { $0.stableKey == "packages-data-transfer" },
            "Packages transfer allowance missing"
        )
        try check(transfer.usageText == "0%", "Verified zero Packages transfer must remain visible")
        try check(
            free.cardInformationSections.contains { section in
                section.id == "github-billing.plan-allowances"
                    && section.items.contains { item in
                        item.id == "packages-data-transfer" && item.detail.contains("1 GB remaining")
                    }
            },
            "A verified zero Packages transfer quantity must show the full remaining allowance"
        )

        let zero = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: data(#"{"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[]}"#),
            usageData: data(#"{"usageItems":[]}"#),
            repositoryVisibility: [:],
            planName: "free",
            configuration: personalConfiguration(),
            fetchedAt: fetchedAt
        ), "Zero-usage allowance fixture did not parse")
        try check(zero.bars.count == 7, "A verified Free plan must expose every supported zero-usage allowance")
        try check(zero.bars.allSatisfy { $0.used == 0 && $0.usageText == "0%" }, "Missing usage must not hide verified zero-percent allowances")

        let stalePeriod = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: data(#"{"timePeriod":{"year":2026,"month":8},"user":"octocat","usageItems":[]}"#),
            usageData: data(#"{"usageItems":[]}"#),
            repositoryVisibility: [:],
            planName: "free",
            configuration: personalConfiguration(),
            fetchedAt: fetchedAt
        ), "Stale billing-period fixture did not parse")
        try check(
            stalePeriod.bars.isEmpty
                && stalePeriod.unavailableUsageMetrics["githubBilling.actions-private-minutes"] != nil,
            "A stale billing period must fail every allowance closed"
        )

        let overageSummary = data(#"{"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[{"product":"Actions","sku":"actions_windows","unitType":"minutes","pricePerUnit":0.01,"grossQuantity":2500,"grossAmount":25,"discountQuantity":2000,"discountAmount":20,"netQuantity":500,"netAmount":5}]}"#)
        let overageUsage = data(#"{"usageItems":[{"date":"2026-09-01","product":"Actions","sku":"actions_windows","quantity":2500,"unitType":"minutes","pricePerUnit":0.01,"grossAmount":25,"discountAmount":20,"netAmount":5,"repositoryName":"octocat/private"}]}"#)
        let overage = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: overageSummary,
            usageData: overageUsage,
            repositoryVisibility: ["octocat/private": true],
            planName: "free",
            configuration: personalConfiguration(),
            fetchedAt: fetchedAt
        ), "Actions overage fixture did not parse")
        let actionsOverage = try require(
            overage.bars.first { $0.stableKey == "actions-private-minutes" },
            "Actions overage bar missing"
        )
        try check(actionsOverage.used > actionsOverage.limit, "Actions usage above the plan allowance must not be clamped")
        try check(actionsOverage.usageText == "125%", "Actions overage must retain its percentage above 100%")

        let organizationFree = try require(GitHubBillingUsageParser.parseOrganization(
            summaryData: organizationSummary(),
            usageData: organizationUsage(),
            budgetPageData: [],
            repositoryVisibility: organizationRepositoryVisibility,
            planName: "free",
            configuration: organizationConfiguration(),
            fetchedAt: fetchedAt
        ), "Organization Free allowance fixture did not parse")
        try check(
            organizationFree.bars.first { $0.stableKey == "actions-private-minutes" }?.limit == 2_000,
            "Organization Free must use the organization plan allowance"
        )
        try check(
            organizationFree.bars.contains { $0.stableKey == "codespaces-core-hours" } == false,
            "Organization plans must not invent personal Codespaces allowances"
        )

        let enterprise = try require(GitHubBillingUsageParser.parseOrganization(
            summaryData: organizationSummary(),
            usageData: organizationUsage(),
            budgetPageData: [],
            repositoryVisibility: organizationRepositoryVisibility,
            planName: "enterprise",
            configuration: organizationConfiguration(),
            fetchedAt: fetchedAt
        ), "Enterprise pooling fixture did not parse")
        try check(
            enterprise.bars.contains { $0.stableKey == "actions-private-minutes" } == false,
            "An enterprise pool must not be assigned in full to an organization"
        )
        try check(
            enterprise.usageMessages.contains { $0.contains("allowances are pooled") },
            "Enterprise organizations need a scoped unavailable explanation"
        )
    }

    private static func packagesVisibilityEvidenceContract() throws {
        let fetchedAt = try fixtureDate("2026-09-15T12:00:00Z")
        let result = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: data(#"{"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[{"product":"Packages","sku":"packages_storage","unitType":"GB-hours","pricePerUnit":0.01,"grossQuantity":24,"grossAmount":0.24,"discountQuantity":24,"discountAmount":0.24,"netQuantity":0,"netAmount":0},{"product":"Packages","sku":"packages_bandwidth","unitType":"GB","pricePerUnit":0.5,"grossQuantity":2,"grossAmount":1,"discountQuantity":1.5,"discountAmount":0.75,"netQuantity":0.5,"netAmount":0.25}]}"#),
            usageData: data(#"{"usageItems":[{"product":"Packages","sku":"packages_storage","quantity":24,"unitType":"GB-hours","pricePerUnit":0.01,"grossAmount":0.24,"discountAmount":0.24,"netAmount":0,"repositoryName":"octocat/private"},{"product":"Packages","sku":"packages_bandwidth","quantity":2,"unitType":"GB","pricePerUnit":0.5,"grossAmount":1,"discountAmount":0.75,"netAmount":0.25,"repositoryName":"octocat/private"}]}"#),
            repositoryVisibility: ["octocat/private": true],
            planName: "free",
            configuration: personalConfiguration(),
            fetchedAt: fetchedAt
        ), "Packages visibility fixture did not parse")
        try check(
            result.unavailableUsageMetrics["githubBilling.actions-packages-storage"]?
                .contains("does not identify package visibility") == true,
            "Private repository visibility must not be treated as private package visibility"
        )
        try check(
            result.unavailableUsageMetrics["githubBilling.packages-data-transfer"]?
                .contains("free Actions downloads") == true,
            "Packages transfer must fail closed when GitHub omits package visibility and transfer cause"
        )
    }

    private static func amountAndProductSummaryContract() throws {
        let aggregateText: (Decimal) -> String = {
            $0.formatted(.currency(code: "USD").precision(.fractionLength(2)))
        }
        let unitPriceText: (Decimal, Int) -> String = {
            $0.formatted(.currency(code: "USD").precision(.fractionLength($1)))
        }
        let summary = data(#"""
        {
          "timePeriod": {"year": 2026, "month": 9},
          "user": "octocat",
          "usageItems": [
            {"product":"Actions","sku":"Actions Linux","unitType":"minutes","pricePerUnit":0.006,"grossQuantity":100,"grossAmount":0.6,"discountQuantity":100,"discountAmount":0.6,"netQuantity":0,"netAmount":0},
            {"product":"Actions","sku":"Actions Windows","unitType":"minutes","pricePerUnit":0.01,"grossQuantity":60,"grossAmount":0.6,"discountQuantity":60,"discountAmount":0.6,"netQuantity":0,"netAmount":0},
            {"product":"Actions","sku":"actions_storage","unitType":"GB-hours","pricePerUnit":0.04,"grossQuantity":144,"grossAmount":5.10,"discountQuantity":31,"discountAmount":1.10,"netQuantity":113,"netAmount":4.00},
            {"product":"Copilot","sku":"copilot_premium_requests","unitType":"requests","pricePerUnit":0.04,"grossQuantity":10,"grossAmount":0.40,"discountQuantity":0,"discountAmount":0,"netQuantity":10,"netAmount":0.40},
            {"product":"Codespaces","sku":"codespaces_compute_d2","unitType":"hours","pricePerUnit":0.18,"grossQuantity":2.5,"grossAmount":0.40,"discountQuantity":0.625,"discountAmount":0.10,"netQuantity":1.875,"netAmount":0.30},
            {"product":"Git LFS","sku":"lfs_storage","unitType":"GB-hours","pricePerUnit":0.07,"grossQuantity":1,"grossAmount":0,"discountQuantity":1,"discountAmount":0,"netQuantity":0,"netAmount":0},
            {"product":"LFS","sku":"lfs_bandwidth","unitType":"GB-hours","pricePerUnit":0.07,"grossQuantity":1,"grossAmount":0,"discountQuantity":1,"discountAmount":0,"netQuantity":0,"netAmount":0},
            {"product":"Advanced Security","sku":"secret_scanning","unitType":"active-committers","pricePerUnit":0,"grossQuantity":1,"grossAmount":0,"discountQuantity":0,"discountAmount":0,"netQuantity":1,"netAmount":0},
            {"product":"Packages","sku":"packages_storage","unitType":"GB-hours","pricePerUnit":0.04,"grossQuantity":50,"grossAmount":1.125,"discountQuantity":25,"discountAmount":0.5625,"netQuantity":25,"netAmount":0.5625}
          ]
        }
        """#)
        let usage = data(#"""
        {
          "usageItems": [
            {"date":"2026-09-01","product":"Actions","sku":"Actions Linux","quantity":100,"unitType":"minutes","pricePerUnit":0.006,"grossAmount":0.6,"discountAmount":0.6,"netAmount":0,"repositoryName":"octocat/private"},
            {"date":"2026-09-02","product":"Actions","sku":"Actions Windows","quantity":60,"unitType":"minutes","pricePerUnit":0.01,"grossAmount":0.6,"discountAmount":0.6,"netAmount":0,"repositoryName":"octocat/private"},
            {"date":"2026-09-03","product":"Actions","sku":"actions_storage","quantity":144,"unitType":"GB-hours","pricePerUnit":0.04,"grossAmount":5.76,"discountAmount":1.76,"netAmount":4,"repositoryName":"octocat/private"},
            {"date":"2026-09-04","product":"Packages","sku":"packages_storage","quantity":50,"unitType":"GB-hours","pricePerUnit":0.04,"grossAmount":2,"discountAmount":1,"netAmount":1,"repositoryName":"octocat/private"}
          ]
        }
        """#)
        let fetchedAt = try fixtureDate("2026-09-15T12:00:00Z")
        let result = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: summary,
            usageData: usage,
            repositoryVisibility: ["octocat/private": true],
            planName: "free",
            configuration: personalConfiguration(),
            fetchedAt: fetchedAt
        ), "Amount contract fixture did not parse")

        // Products group into known sections in a stable order and keep unknown products.
        let sectionIDs = result.cardInformationSections.map(\.id)
        let copilotIndex = try require(sectionIDs.firstIndex(of: "github-billing.product.copilot"), "Copilot summary missing")
        let actionsIndex = try require(sectionIDs.firstIndex(of: "github-billing.product.actions"), "Actions summary missing")
        let codespacesIndex = try require(sectionIDs.firstIndex(of: "github-billing.product.codespaces"), "Codespaces summary missing")
        let gitLFSIndex = try require(sectionIDs.firstIndex(of: "github-billing.product.git-lfs"), "Git LFS summary missing")
        try check(
            sectionIDs.filter { $0 == "github-billing.product.git-lfs" }.count == 1,
            "Git LFS aliases must merge into one canonical product summary"
        )
        try check(
            result.cardInformationSections[gitLFSIndex].items.contains { item in
                item.label == "Consumed usage" && item.detail.contains("2 GB-hours")
            },
            "The canonical Git LFS summary must include quantities from every recognized alias"
        )
        let advancedSecurityIndex = try require(sectionIDs.firstIndex(of: "github-billing.product.advanced-security"), "An unknown product must remain visible under its GitHub product name")
        let packagesIndex = try require(sectionIDs.firstIndex(of: "github-billing.product.packages"), "Packages summary missing")
        try check(
            copilotIndex < actionsIndex && actionsIndex < codespacesIndex && codespacesIndex < packagesIndex
                && packagesIndex < gitLFSIndex && gitLFSIndex < advancedSecurityIndex,
            "All known products must sort before alphabetized unknown products"
        )

        let actionsSection = result.cardInformationSections[actionsIndex]
        try check(actionsSection.items.contains { item in
            item.label == "Consumed usage"
                && item.detail == "\(aggregateText(Decimal(string: "6.30")!)) · 144 GB-hours · 160 minutes"
        }, "Consumed usage must show the two-decimal aggregate with its returned quantity")
        try check(actionsSection.items.contains {
            $0.label == "Discount usage"
                && $0.detail == "\(aggregateText(Decimal(string: "2.30")!)) · 31 GB-hours · 160 minutes"
        }, "Discount usage must keep its amount and covered quantity separate from consumed usage")
        try check(actionsSection.items.contains {
            $0.label == "Billable usage"
                && $0.detail == "\(aggregateText(Decimal(string: "4.00")!)) · 113 GB-hours · 0 minutes"
        }, "Billable usage must show the authoritative net amount and quantity")
        try check(actionsSection.items.contains { item in
            item.label == "Included usage · Minutes"
                && item.detail == "160 of 2,000 minutes used (private standard runners) · "
                    + "1,840 minutes remaining"
        }, "Actions included minutes must show used, included, and remaining values")
        try check(
            actionsSection.items.contains { item in
                item.label == "Included usage · Storage"
                    && item.detail.contains("does not identify package visibility")
            },
            "Nonzero Packages storage must stay unavailable beside trustworthy Actions minute progress"
        )

        // Aggregate amounts use two fractional digits; unit rates keep their source precision.
        let detailItems = result.cardInformationSections
            .first { $0.id == "github-billing.usage-detail" }?.items ?? []
        try check(!detailItems.isEmpty, "Usage detail rows must stay available alongside product summaries")
        try check(detailItems.contains { item in
            item.detail.contains("\(unitPriceText(Decimal(string: "0.006")!, 3))/minute ·")
        }, "Unit prices must keep GitHub's source precision with a singular denominator")
        try check(detailItems.contains { item in
            item.detail.contains("\(unitPriceText(Decimal(string: "0.01")!, 2))/minute ·")
        }, "Two-digit unit rates must keep the standard currency display")
        try check(detailItems.contains { item in
            item.detail.contains("\(aggregateText(Decimal(string: "0.60")!)) gross")
        }, "Aggregate amounts in detail rows must use two fractional digits")
        try check(
            result.monetaryMetrics.first { $0.kind == .grossSpend }?.amount == Decimal(string: "8.225"),
            "Aggregate precision must be retained even though the display shows two decimals"
        )
        try check(
            result.monetaryMetrics.first { $0.kind == .discounts }?.amount == Decimal(string: "2.9625"),
            "Discount precision must be retained"
        )
        try check(
            result.monetaryMetrics.first { $0.kind == .spent }?.amount == Decimal(string: "5.2625"),
            "Net spend precision must be retained"
        )
        try check(result.monetaryMetrics.allSatisfy { $0.decimalPlaces == 2 && $0.currencyCode == "USD" }, "Aggregates must render exactly two decimals in USD")

        // Locale separators and symbol placement adapt while the currency stays USD.
        let localeMetric = ProviderMonetaryMetric(
            kind: .grossSpend,
            label: "Locale",
            minorUnits: 590,
            currencyCode: "USD",
            decimalPlaces: 2
        )
        try check(
            localeMetric.formattedAmount(locale: Locale(identifier: "en_US")) == "$5.90",
            "United States formatting must show the dollar symbol first"
        )
        let german = localeMetric.formattedAmount(locale: Locale(identifier: "de_DE"))
        try check(german.contains("5,90"), "German separators must adapt: \(german)")
        try check(german.contains("$"), "German formatting must keep the USD symbol: \(german)")

        let notes = result.cardInformationSections.first { $0.id == "github-billing.amounts-and-currency" }
        try check(notes?.items.contains { item in
            item.label == "Currency" && item.detail.contains("USD")
                && item.detail.contains("does not report a currency code")
        } == true, "GitHub Billing must identify amounts as USD because the API reports no currency")

        let unknownPlan = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: summary,
            usageData: usage,
            repositoryVisibility: ["octocat/private": true],
            planName: "enterprise",
            configuration: personalConfiguration(),
            fetchedAt: fetchedAt
        ), "Unknown-plan fixture did not parse")
        let unknownPlanNotes = unknownPlan.cardInformationSections
            .first { $0.id == "github-billing.amounts-and-currency" }?.items ?? []
        try check(
            unknownPlanNotes.contains { $0.label == "Personal budgets" },
            "The personal-budget API limitation must remain visible for an unknown plan"
        )
        try check(
            !unknownPlanNotes.contains { $0.label == "Actions plan allowance" },
            "The plan-dependent Actions calculation note must stay hidden for an unknown plan"
        )
    }

    private static func currencyEvidenceContract() throws {
        let usage = data(#"{"usageItems":[]}"#)
        let configuration = personalConfiguration()
        let fetchedAt = try fixtureDate("2026-09-15T12:00:00Z")

        func parse(summaryData: Data) throws -> ProviderUsageResult? {
            GitHubBillingUsageParser.parsePersonal(
                summaryData: summaryData,
                usageData: usage,
                repositoryVisibility: [:],
                planName: "free",
                configuration: configuration,
                fetchedAt: fetchedAt
            )
        }

        let reported = try require(try parse(summaryData: data(
            #"{"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[{"product":"Actions","sku":"actions_storage","unitType":"GB-hours","currency":"EUR","grossQuantity":1,"grossAmount":5.9,"discountAmount":0,"netAmount":5.9}]}"#
        )), "A currency-reporting fixture did not parse")
        try check(
            reported.monetaryMetrics.allSatisfy { $0.currencyCode == "EUR" },
            "A consistently supplied currency code must be used instead of assuming USD"
        )
        try check(
            reported.cardInformationSections.contains { section in
                section.id == "github-billing.amounts-and-currency"
                    && section.items.contains { item in
                        item.label == "Currency" && item.detail.hasPrefix("EUR")
                            && item.detail.contains("not converted")
                    }
            },
            "A reported currency must be disclosed without locale conversion"
        )

        let conflicting = try parse(summaryData: data(
            #"{"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[{"product":"Actions","sku":"actions_storage","unitType":"GB-hours","currency":"EUR","grossQuantity":1,"grossAmount":1,"discountAmount":0,"netAmount":1},{"product":"Packages","sku":"packages_storage","unitType":"GB-hours","currency":"USD","grossQuantity":1,"grossAmount":1,"discountAmount":0,"netAmount":1}]}"#
        ))
        try check(
            conflicting?.usageMessages.contains { $0.contains("currency evidence") } == true,
            "Conflicting currency evidence must stay an actionable inline message"
        )
        try check(
            conflicting?.monetaryMetrics.isEmpty == true,
            "Conflicting currency evidence must make aggregate monetary values unavailable"
        )
        try check(
            conflicting?.cardInformationSections
                .filter { $0.id.hasPrefix("github-billing.product.") }
                .flatMap(\.items)
                .filter { ["Discount usage", "Billable usage"].contains($0.label) }
                .allSatisfy { $0.detail.hasPrefix("Unavailable ·") } == true,
            "Conflicting currency evidence must not relabel product amounts as USD"
        )
        try check(
            conflicting?.cardInformationSections.contains { section in
                section.id == "github-billing.amounts-and-currency"
                    && section.items.contains { item in
                        item.label == "Currency evidence" && item.detail.contains("cannot verify")
                    }
                    && section.items.contains { item in
                        item.label == "Currency" && item.detail.hasPrefix("Unavailable")
                            && item.detail.contains("could not verify") && !item.detail.contains("does not report")
                    }
            } == true,
            "Conflicting currency evidence must explain the USD fallback without claiming no code was reported"
        )

        let partialCurrency = try parse(summaryData: data(
            #"{"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[{"product":"Actions","sku":"actions_storage","unitType":"GB-hours","currency":"EUR","grossQuantity":1,"grossAmount":1,"discountAmount":0,"netAmount":1},{"product":"Packages","sku":"packages_storage","unitType":"GB-hours","grossQuantity":1,"grossAmount":1,"discountAmount":0,"netAmount":1}]}"#
        ))
        try check(
            partialCurrency?.monetaryMetrics.isEmpty == true,
            "Item-level currency evidence must cover every monetary summary row"
        )
        try check(
            partialCurrency?.usageMessages.contains { $0.contains("currency evidence") } == true,
            "Partial item-level currency evidence must remain an actionable warning"
        )

        let malformedCurrency = try parse(summaryData: data(
            #"{"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[{"product":"Actions","sku":"actions_storage","unitType":"GB-hours","currency":"ZZZ","grossQuantity":1,"grossAmount":1,"discountAmount":0,"netAmount":1}]}"#
        ))
        try check(
            malformedCurrency?.monetaryMetrics.isEmpty == true,
            "An unsupported three-letter currency value must make monetary values unavailable"
        )
        try check(
            malformedCurrency?.usageMessages.contains { $0.contains("currency evidence") } == true,
            "Invalid currency evidence must be reported, not silently dropped"
        )

        let topLevelReported = try parse(summaryData: data(
            #"{"timePeriod":{"year":2026,"month":9},"user":"octocat","currency":"CAD","usageItems":[{"product":"Actions","sku":"actions_storage","unitType":"GB-hours","grossQuantity":1,"grossAmount":1,"discountAmount":0,"netAmount":1}]}"#
        ))
        try check(
            topLevelReported?.monetaryMetrics.allSatisfy { $0.currencyCode == "CAD" } == true,
            "A top-level currency code must apply to every amount"
        )
    }

    private static func organizationBudgetsAndPaginationParsing() throws {
        let summary = data(#"{"timePeriod":{"year":2026,"month":9},"organization":"Example-Engineering","usageItems":[{"product":"Actions","sku":"actions_linux","unitType":"minutes","pricePerUnit":0.006,"grossQuantity":1200,"grossAmount":7.2,"discountQuantity":1200,"discountAmount":7.2,"netQuantity":0,"netAmount":0},{"product":"Actions","sku":"actions_macos_l","unitType":"minutes","pricePerUnit":0.12,"grossQuantity":100,"grossAmount":12,"discountQuantity":0,"discountAmount":2,"netQuantity":100,"netAmount":10}]}"#)
        let usage = data(#"{"usageItems":[{"date":"2026-09-01","product":"Actions","sku":"actions_linux","quantity":1000,"unitType":"minutes","pricePerUnit":0.006,"grossAmount":6,"discountAmount":6,"netAmount":0,"organizationName":"Example-Engineering","repositoryName":"example/private"},{"date":"2026-09-02","product":"Actions","sku":"actions_linux","quantity":200,"unitType":"minutes","pricePerUnit":0.006,"grossAmount":1.2,"discountAmount":1.2,"netAmount":0,"organizationName":"Example-Engineering","repositoryName":"example/other"},{"date":"2026-09-03","product":"Actions","sku":"actions_macos_l","quantity":80,"unitType":"minutes","pricePerUnit":0.12,"grossAmount":9.6,"discountAmount":1.6,"netAmount":8,"organizationName":"Example-Engineering","repositoryName":"example/private"},{"date":"2026-09-04","product":"Actions","sku":"actions_macos_l","quantity":20,"unitType":"minutes","pricePerUnit":0.12,"grossAmount":2.4,"discountAmount":0.4,"netAmount":2,"organizationName":"Example-Engineering","repositoryName":"example/other"}]}"#)
        let pages = [
            data(#"""
            {"budgets":[{"id":"product-budget","budget_type":"ProductPricing","budget_amount":100,"prevent_further_usage":true,"budget_scope":"organization","budget_product_sku":"Actions","budget_alerting":{"will_alert":true,"alert_recipients":[]}}],"has_next_page":true}
            """#),
            data(#"""
            {"budgets":[{"id":"sku-budget","budget_type":"SkuPricing","budget_amount":20,"prevent_further_usage":false,"budget_scope":"repository","budget_entity_name":"example/private","budget_product_skus":["actions_macos_l"],"budget_alerting":{"will_alert":true,"alert_recipients":[]}},{"id":"tracking-budget","budget_type":"ProductPricing","budget_amount":25,"prevent_further_usage":false,"budget_scope":"organization","budget_product_sku":"Packages","budget_alerting":{"will_alert":false,"alert_recipients":[]}},{"id":"zero-budget","budget_type":"SkuPricing","budget_amount":0,"prevent_further_usage":true,"budget_scope":"organization","budget_product_sku":"actions_macos","budget_alerting":{"will_alert":true,"alert_recipients":[]}},{"id":"cost-center-budget","budget_type":"ProductPricing","budget_amount":50,"prevent_further_usage":false,"budget_scope":"cost_center","budget_entity_name":"engineering","budget_product_sku":"Actions","budget_alerting":{"will_alert":true,"alert_recipients":[]}}],"has_next_page":false}
            """#),
        ]
        let configuration = organizationConfiguration()
        let result = try require(GitHubBillingUsageParser.parseOrganization(
            summaryData: summary,
            usageData: usage,
            budgetPageData: pages,
            repositoryVisibility: organizationRepositoryVisibility,
            planName: "team",
            configuration: configuration,
            fetchedAt: try fixtureDate("2026-09-15T12:00:00Z")
        ), "Organization fixture did not parse")
        try check(result.bars.contains { $0.stableKey == "budget-product-budget" && $0.used == 10 && $0.limit == 100 }, "Organization budget did not use organization-wide product net spend")
        try check(result.bars.contains { $0.stableKey == "budget-sku-budget" && $0.used == 8 && $0.limit == 20 }, "Repository budget did not limit SKU net spend to its repository")
        try check(!result.bars.contains { $0.stableKey == "budget-zero-budget" }, "A zero-dollar budget must not render a meaningless percentage bar")
        try check(result.cardInformationSections.contains { $0.id == "github-billing.budget.zero-budget" }, "A returned zero-dollar budget must remain visible")
        try check(!result.bars.contains { $0.stableKey == "budget-cost-center-budget" }, "Unsupported budget scopes must not show guessed consumption")
        try check(result.usageMessages.contains { $0.contains("cost_center") }, "Unsupported budget scopes need an unavailable explanation")
        try check(
            result.cardInformationSections.contains { section in
                section.id == "github-billing.budget.cost-center-budget"
                    && section.items.contains { $0.detail == "Unavailable for this budget scope" }
            },
            "Unsupported budget scopes must retain returned amount, behavior, and unavailable headroom"
        )
        try check(result.cardInformationSections.contains { section in
            section.items.contains { $0.label == "Behavior" && $0.detail == "Hard stop" }
        }, "Hard-stop behavior was not retained")
        try check(result.cardInformationSections.contains { section in
            section.items.contains { $0.label == "Behavior" && $0.detail == "Alert only" }
        }, "Alert-only behavior was not retained")
        try check(result.cardInformationSections.contains { section in
            section.items.contains { $0.label == "Behavior" && $0.detail == "Tracking only" }
        }, "A nonblocking budget with alerts disabled must not be labeled alert-only")
        try check(
            !result.cardInformationSections.contains { section in
                section.items.contains { $0.label == "Personal budgets" }
            },
            "Organization cards must not show the personal-budget API limitation"
        )
        let organizationActions = try require(
            result.bars.first { $0.stableKey == "actions-private-minutes" },
            "A Team organization must expose its verified Actions allowance"
        )
        try check(organizationActions.limit == 3_000, "A Team organization must receive 3,000 included Actions minutes")
        try check(
            result.cardInformationSections.contains { section in
                section.id == "github-billing.product.actions"
                    && section.items.contains { $0.label == "Included usage · Minutes" }
            },
            "Organization product details must separate included usage from budgets"
        )

        let conflictingCurrency = try require(GitHubBillingUsageParser.parseOrganization(
            summaryData: data(#"{"timePeriod":{"year":2026,"month":9},"organization":"Example-Engineering","usageItems":[{"product":"Actions","sku":"actions_linux","unitType":"minutes","currency":"EUR","pricePerUnit":0.006,"grossQuantity":1200,"grossAmount":12.25,"discountAmount":2.25,"netAmount":10},{"product":"Packages","sku":"packages_storage","unitType":"GB-hours","currency":"USD","pricePerUnit":0.0225,"grossQuantity":50,"grossAmount":1.125,"discountAmount":0.5625,"netAmount":0.5625}]}"#),
            usageData: organizationUsage(),
            budgetPageData: pages,
            repositoryVisibility: organizationRepositoryVisibility,
            planName: "team",
            configuration: configuration,
            fetchedAt: try fixtureDate("2026-09-15T12:00:00Z")
        ), "Conflicting organization currency fixture did not parse")
        try check(
            !conflictingCurrency.bars.contains { $0.stableKey?.hasPrefix("budget-") == true },
            "Unverified organization currency must suppress monetary budget bars"
        )
        let conflictingBudgetAmounts = conflictingCurrency.cardInformationSections
            .filter { $0.id.hasPrefix("github-billing.budget.") }
            .flatMap(\.items)
            .filter { ["Current net spend", "Remaining headroom"].contains($0.label) }
        try check(!conflictingBudgetAmounts.isEmpty, "Conflicting currency fixture must retain budget sections")
        try check(
            conflictingBudgetAmounts.allSatisfy { $0.detail == "Unavailable" },
            "Unverified currency must suppress budget amounts and consumption percentages"
        )

        let noBudget = try require(GitHubBillingUsageParser.parseOrganization(
            summaryData: summary,
            usageData: organizationUsage(),
            budgetPageData: [data("{\"budgets\":[],\"has_next_page\":false}")],
            repositoryVisibility: organizationRepositoryVisibility,
            planName: "team",
            configuration: configuration,
            fetchedAt: try fixtureDate("2026-09-15T12:00:00Z")
        ), "No-budget fixture did not parse")
        try check(noBudget.cardInformationSections.contains { section in
            section.id == "github-billing.amounts-and-currency"
                && section.items.contains { $0.detail.contains("no organization budgets") }
        }, "Missing budget state was not explicit in the amounts and currency section")
        try check(
            !noBudget.usageMessages.contains { $0.contains("no organization budgets") },
            "A missing-budget qualification is routine and must stay off the card body"
        )

        let fetchedAt = try fixtureDate("2026-09-15T12:00:00Z")
        let scopedBudget = try require(GitHubBillingUsageParser.parseOrganization(
            summaryData: organizationSummary(),
            usageData: organizationUsage(),
            budgetPageData: [data(#"{"budgets":[{"id":"scoped","budget_type":"ProductPricing","budget_amount":10.5,"prevent_further_usage":true,"budget_scope":"organization","budget_product_sku":"Actions","budget_alerting":{"will_alert":true,"alert_recipients":[]}}],"has_next_page":false}"#)],
            repositoryVisibility: organizationRepositoryVisibility,
            planName: "team",
            configuration: configuration,
            fetchedAt: fetchedAt
        ), "Scoped budget fixture did not parse")
        try check(!scopedBudget.hasReachedSpendLimit, "Unrelated account spend must not trigger a scoped budget alert")

        let duplicateSummary = data(#"{"timePeriod":{"year":2026,"month":9},"organization":"Example-Engineering","usageItems":[{"product":"Actions","sku":"actions_linux","unitType":"minutes","pricePerUnit":0.006,"grossQuantity":200,"grossAmount":2,"discountAmount":0,"netAmount":2},{"product":"Actions","sku":"actions_linux","unitType":"minutes","pricePerUnit":0.006,"grossQuantity":1000,"grossAmount":10.25,"discountAmount":2.25,"netAmount":8}]}"#)
        let aggregated = try require(GitHubBillingUsageParser.parseOrganization(
            summaryData: duplicateSummary,
            usageData: organizationUsage(),
            budgetPageData: [],
            repositoryVisibility: organizationRepositoryVisibility,
            planName: "team",
            configuration: configuration,
            fetchedAt: fetchedAt
        ), "Duplicate organization usage fixture did not parse")
        let usageBars = aggregated.bars.filter { $0.stableKey?.hasPrefix("usage-") == true }
        try check(usageBars.count == 1, "Duplicate product and SKU rows must aggregate into one stable metric")
        try check(usageBars.first?.used == 1_200, "Aggregated organization usage quantity was incorrect")
        try check(
            usageBars.first?.stableKey == "usage-actions-actions-linux-minutes",
            "Organization metric identity must use semantic fields rather than response order"
        )
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
            summaryData: data("{\"user\":\"octocat\",\"usageItems\":[{\"product\":\"Actions\"}]}"),
            usageData: data("{\"usageItems\":[]}"),
            repositoryVisibility: [:],
            planName: "unknown-plan",
            configuration: configuration,
            fetchedAt: Date()
        )
        let result = try require(missing, "Missing optional fields should produce unavailable metrics instead of a crash")
        try check(!result.unavailableUsageMetrics.isEmpty, "Unknown plans must explain unavailable allowances")
        try check(result.monetaryMetrics.isEmpty, "Missing spend fields must not be presented as zero-dollar usage")
        try check(result.usageMessages.contains { $0.contains("complete gross") }, "Missing spend fields need an unavailable explanation")

        let incompleteQuantities = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: data(#"{"user":"octocat","timePeriod":{"year":2026,"month":9},"usageItems":[{"product":"Copilot","sku":"copilot_premium_requests","unitType":"requests","grossAmount":1,"discountAmount":0,"netAmount":1},{"product":"Codespaces","sku":"codespaces_compute","unitType":"core-hours","grossQuantity":-1,"grossAmount":1,"discountAmount":0,"netAmount":1},{"product":"Git LFS","sku":"lfs_storage","grossQuantity":1,"grossAmount":1,"discountAmount":0,"netAmount":1}]}"#),
            usageData: data(#"{"usageItems":[]}"#),
            repositoryVisibility: [:],
            planName: "free",
            configuration: configuration,
            fetchedAt: Date()
        ), "Incomplete product quantities should remain readable")
        for sectionID in [
            "github-billing.product.copilot",
            "github-billing.product.codespaces",
            "github-billing.product.git-lfs",
        ] {
            try check(
                incompleteQuantities.cardInformationSections.first { $0.id == sectionID }?.items.contains { item in
                    item.label == "Consumed usage" && item.detail.contains("Quantity unavailable")
                } == true,
                "Missing, negative, or unitless product quantities must be explicit in \(sectionID)"
            )
        }

        let incompleteAmount = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: data(#"{"user":"octocat","timePeriod":{"year":2026,"month":9},"usageItems":[{"product":"Copilot","sku":"copilot_premium_requests","unitType":"requests","grossQuantity":2,"discountAmount":0,"netAmount":0}]}"#),
            usageData: data(#"{"usageItems":[]}"#),
            repositoryVisibility: [:],
            planName: "free",
            configuration: configuration,
            fetchedAt: Date()
        ), "A product row with quantity but no gross amount should remain readable")
        try check(
            incompleteAmount.cardInformationSections
                .first { $0.id == "github-billing.product.copilot" }?.items.contains { item in
                    item.label == "Consumed usage" && item.detail == "Unavailable · 2 requests"
                } == true,
            "A valid quantity must remain visible when only the consumed amount is unavailable"
        )

        let missingActionsProduct = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: personalSummary(),
            usageData: data(#"{"usageItems":[{"sku":"actions_linux","quantity":1,"unitType":"minutes","repositoryName":"octocat/private","grossAmount":0.01,"discountAmount":0.01,"netAmount":0}]}"#),
            repositoryVisibility: ["octocat/private": true],
            planName: "free",
            configuration: configuration,
            fetchedAt: Date()
        ), "An incomplete Actions row should remain a readable response")
        try check(
            missingActionsProduct.unavailableUsageMetrics["githubBilling.actions-private-minutes"] != nil,
            "An Actions minute row missing its product must make the allowance unavailable"
        )

        let missingStorageSKU = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: data(#"{"user":"octocat","timePeriod":{"year":2026,"month":9},"usageItems":[{"product":"Actions","unitType":"GB-hours","grossQuantity":1,"grossAmount":0.01,"discountAmount":0.01,"netAmount":0}]}"#),
            usageData: data(#"{"usageItems":[]}"#),
            repositoryVisibility: [:],
            planName: "free",
            configuration: configuration,
            fetchedAt: Date()
        ), "An incomplete storage row should remain a readable response")
        try check(
            missingStorageSKU.unavailableUsageMetrics["githubBilling.actions-packages-storage"] != nil,
            "An Actions storage row missing its SKU must make the allowance unavailable"
        )

        let missingLFSSKU = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: data(#"{"user":"octocat","timePeriod":{"year":2026,"month":9},"usageItems":[{"product":"Git LFS","unitType":"GiB-hours","grossQuantity":1,"grossAmount":0.01,"discountAmount":0.01,"netAmount":0}]}"#),
            usageData: data(#"{"usageItems":[]}"#),
            repositoryVisibility: [:],
            planName: "free",
            configuration: configuration,
            fetchedAt: Date()
        ), "An incomplete Git LFS row should remain a readable response")
        try check(
            missingLFSSKU.unavailableUsageMetrics["githubBilling.lfs-storage"] != nil,
            "A Git LFS storage row missing its SKU must make storage unavailable"
        )

        let missingLFSProduct = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: data(#"{"user":"octocat","timePeriod":{"year":2026,"month":9},"usageItems":[{"sku":"lfs_bandwidth","unitType":"GiB","grossQuantity":1,"grossAmount":0.01,"discountAmount":0.01,"netAmount":0}]}"#),
            usageData: data(#"{"usageItems":[]}"#),
            repositoryVisibility: [:],
            planName: "free",
            configuration: configuration,
            fetchedAt: Date()
        ), "An incomplete Git LFS bandwidth row should remain a readable response")
        try check(
            missingLFSProduct.unavailableUsageMetrics["githubBilling.lfs-bandwidth"] != nil,
            "A Git LFS bandwidth row missing its product must make bandwidth unavailable"
        )

        let missingSummaryItems = GitHubBillingUsageParser.parsePersonal(
            summaryData: data("{\"timePeriod\":{\"year\":2026,\"month\":9}}"),
            usageData: data("{\"usageItems\":[]}"),
            repositoryVisibility: [:],
            planName: "free",
            configuration: configuration,
            fetchedAt: Date()
        )
        try check(missingSummaryItems == nil, "A missing top-level summary usageItems field must fail closed")

        let missingDetailedItems = GitHubBillingUsageParser.parsePersonal(
            summaryData: personalSummary(),
            usageData: data("{}"),
            repositoryVisibility: [:],
            planName: "free",
            configuration: configuration,
            fetchedAt: Date()
        )
        try check(missingDetailedItems == nil, "A missing top-level detailed usageItems field must fail closed")

        let mismatchedPersonalOwner = GitHubBillingUsageParser.parsePersonal(
            summaryData: data(#"{"user":"someone-else","usageItems":[]}"#),
            usageData: data(#"{"usageItems":[]}"#),
            repositoryVisibility: [:],
            planName: "free",
            configuration: configuration,
            fetchedAt: Date()
        )
        try check(mismatchedPersonalOwner == nil, "Personal summary data must match the configured owner")

        let missingBudgets = GitHubBillingUsageParser.parseOrganization(
            summaryData: organizationSummary(),
            usageData: organizationUsage(),
            budgetPageData: [data("{}")],
            configuration: organizationConfiguration(),
            fetchedAt: Date()
        )
        try check(missingBudgets == nil, "A missing top-level budgets field must fail closed")

        let incompleteOrganizationSummary = GitHubBillingUsageParser.parseOrganization(
            summaryData: data(#"{"timePeriod":{"year":2026,"month":9},"organization":"Example-Engineering","usageItems":[{"product":"Actions","unitType":"minutes","grossQuantity":1,"grossAmount":1,"discountAmount":0,"netAmount":1}]}"#),
            usageData: organizationUsage(),
            budgetPageData: [],
            configuration: organizationConfiguration(),
            fetchedAt: Date()
        )
        try check(incompleteOrganizationSummary == nil, "Incomplete organization summary rows must fail closed")

        let incompleteOrganizationUsage = GitHubBillingUsageParser.parseOrganization(
            summaryData: organizationSummary(),
            usageData: data(#"{"usageItems":[{"product":"Actions","sku":"actions_linux","quantity":1,"unitType":"minutes","repositoryName":"example/private"}]}"#),
            budgetPageData: [],
            configuration: organizationConfiguration(),
            fetchedAt: Date()
        )
        try check(incompleteOrganizationUsage == nil, "Incomplete organization detail rows must fail closed")

        let negativeOrganizationUsage = GitHubBillingUsageParser.parseOrganization(
            summaryData: organizationSummary(),
            usageData: data(#"{"usageItems":[{"date":"2026-09-01","product":"Actions","sku":"actions_linux","quantity":-1,"unitType":"minutes","pricePerUnit":0.01,"grossAmount":-0.01,"discountAmount":0,"netAmount":-0.01,"organizationName":"Example-Engineering"}]}"#),
            budgetPageData: [],
            configuration: organizationConfiguration(),
            fetchedAt: Date()
        )
        try check(negativeOrganizationUsage == nil, "Negative organization detail values must fail closed")

        let mismatchedOrganizationOwner = GitHubBillingUsageParser.parseOrganization(
            summaryData: data(#"{"timePeriod":{"year":2026,"month":9},"organization":"other-org","usageItems":[]}"#),
            usageData: data(#"{"usageItems":[]}"#),
            budgetPageData: [],
            configuration: organizationConfiguration(),
            fetchedAt: Date()
        )
        try check(mismatchedOrganizationOwner == nil, "Organization summary data must match the configured owner")
    }

    @MainActor
    private static func accountIsolationFixtures() async throws {
        let suiteName = "GitHubBillingFixtureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let historyStore = UsageHistoryStore(defaults: defaults)
        let accountID = "github-billing.personal"
        let fetchedAt = try fixtureDate("2026-09-15T12:00:00Z")
        historyStore.record(
            results: [
                ProviderUsageResult(
                    accountID: accountID,
                    providerID: .githubBilling,
                    title: "GitHub Billing",
                    subtitle: "Personal billing",
                    bars: [UsageBar(stableKey: "actions", label: "Actions", used: 10, limit: 2_000)],
                    fetchedAt: fetchedAt
                ),
            ],
            now: fetchedAt
        )
        try check(!historyStore.snapshots.isEmpty, "Billing history fixture did not record")
        try check(!historyStore.dailySnapshots.isEmpty, "Daily billing history fixture did not record")
        historyStore.removeSnapshots(for: accountID)
        try check(historyStore.snapshots.isEmpty, "Changing billing owner must clear frequent history")
        try check(historyStore.dailySnapshots.isEmpty, "Changing billing owner must clear daily history")
        let reloadedHistoryStore = UsageHistoryStore(defaults: defaults)
        try check(reloadedHistoryStore.snapshots.isEmpty, "Cleared billing history must remain empty after reload")
        try check(reloadedHistoryStore.dailySnapshots.isEmpty, "Cleared daily history must remain empty after reload")

        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .githubBilling)
        configuration.githubBillingOwner = "new-owner"
        let cachedResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .githubBilling,
            title: configuration.displayName,
            subtitle: "Old owner billing",
            bars: [UsageBar(label: "Actions", used: 25, limit: 100)],
            monetaryMetrics: [
                ProviderMonetaryMetric(
                    kind: .spent,
                    label: "Net spend",
                    minorUnits: 1_000,
                    currencyCode: "USD",
                    decimalPlaces: 2
                ),
            ],
            cacheIdentity: "old-owner",
            fetchedAt: fetchedAt
        )
        let refreshService = UsageRefreshService(
            providers: [FixtureIdentifiedFailureProvider()],
            initialResults: [cachedResult]
        )
        _ = await refreshService.refresh(configuration: configuration)
        let failure = try require(refreshService.results.first, "Billing cache failure result is missing")
        try check(failure.bars.isEmpty, "A failed refresh must not reuse another owner's billing bars")
        try check(failure.monetaryMetrics.isEmpty, "A failed refresh must not reuse another owner's spend")
        try check(failure.cacheIdentity == "new-owner", "The failed result must retain the requested owner identity")
    }

    private static func providerRequestAndFailureFixtures() async throws {
        let store = FixtureSecretStore()
        let personal = personalConfiguration()
        let credentials = GitHubBillingCredentials(accessToken: "fixture-token", username: "octocat")
        let credential = try require(
            GitHubBillingCredentialsParser.storedCredential(from: credentials),
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
        let zeroNetSpend = success.monetaryMetrics.first { $0.kind == .spent }
        try check(zeroNetSpend?.amount == 0, "Fully discounted usage must retain zero net spend")
        try check(
            zeroNetSpend?.detail == "No current charge after discounts",
            "Fully discounted usage must be presented as no current charge"
        )

        for status in [401, 403, 404, 429, 500] {
            FixtureURLProtocol.setHandler { request in response(request, status: status, body: "{}") }
            let result = try await provider.fetchUsage(for: personal)
            let expected: String = switch status {
            case 401: "Sign in again"
            case 403: "lacks permission"
            case 404: "could not provide access"
            case 429: "rate limit"
            default: "temporarily unavailable"
            }
            try check(
                result.failureMessage?.localizedCaseInsensitiveContains(expected) == true,
                "HTTP \(status) did not produce its distinct safe message"
            )
            do {
                _ = try await provider.discoverAccounts(credentials: credentials)
                throw FixtureFailure(message: "Account discovery HTTP \(status) unexpectedly succeeded")
            } catch {
                try check(
                    error.localizedDescription.localizedCaseInsensitiveContains(expected),
                    "Account discovery HTTP \(status) did not produce setup guidance"
                )
            }
        }

        try await assertRepositoryMetadataFailures(provider: provider, personal: personal)

        try await assertOrganizationFailures(
            provider: provider,
            store: store,
            credential: credential
        )
    }

    private static func assertRepositoryMetadataFailures(
        provider: GitHubBillingUsageProvider,
        personal: ProviderAccountConfiguration
    ) async throws {
        for status in [401, 403, 429, 500] {
            FixtureURLProtocol.setHandler { request in
                switch request.url?.path {
                case "/user":
                    response(request, status: 200, body: #"{"login":"octocat","plan":{"name":"free"}}"#)
                case "/users/octocat/settings/billing/usage/summary":
                    response(request, status: 200, data: personalSummary())
                case "/users/octocat/settings/billing/usage":
                    response(request, status: 200, body: personalUsageBody)
                case "/repos/octocat/private":
                    response(request, status: status, body: "{}")
                default:
                    response(request, status: 404, body: "{}")
                }
            }
            let result = try await provider.fetchUsage(for: personal)
            let expected: String = switch status {
            case 401: "Sign in again"
            case 403: "lacks permission"
            case 429: "rate limit"
            default: "temporarily unavailable"
            }
            try check(
                result.failureMessage?.localizedCaseInsensitiveContains(expected) == true,
                "Repository metadata HTTP \(status) did not produce its distinct safe message"
            )
        }

        FixtureURLProtocol.setHandler { request in
            switch request.url?.path {
            case "/user":
                response(request, status: 200, body: #"{"login":"octocat","plan":{"name":"free"}}"#)
            case "/users/octocat/settings/billing/usage/summary":
                response(request, status: 200, data: personalSummary())
            case "/users/octocat/settings/billing/usage":
                response(request, status: 200, body: personalUsageBody)
            case "/repos/octocat/private":
                response(request, status: 404, body: "{}")
            default:
                response(request, status: 404, body: "{}")
            }
        }
        let hiddenRepository = try await provider.fetchUsage(for: personal)
        try check(hiddenRepository.failureMessage == nil, "A hidden repository must not hide the rest of personal billing")
        try check(
            hiddenRepository.usageMessages.contains { $0.contains("hidden or not found") },
            "Hidden repository metadata needs a distinct explanation"
        )
        try check(
            hiddenRepository.unavailableUsageMetrics["githubBilling.actions-private-minutes"] != nil,
            "Hidden repository metadata must make private Actions classification unavailable"
        )
        try check(
            hiddenRepository.bars.contains { $0.stableKey == "actions-packages-storage" },
            "An unavailable Actions-minute classification must not erase unrelated storage progress"
        )

        let metadataCounter = LockedCounter()
        let manyRepositories = try manyRepositoryUsage(count: 205)
        FixtureURLProtocol.setHandler { request in
            switch request.url?.path {
            case "/user":
                return response(request, status: 200, body: #"{"login":"octocat","plan":{"name":"free"}}"#)
            case "/users/octocat/settings/billing/usage/summary":
                return response(request, status: 200, data: personalSummary())
            case "/users/octocat/settings/billing/usage":
                return response(request, status: 200, data: manyRepositories)
            default:
                metadataCounter.increment()
                return response(request, status: 200, body: #"{"private":true}"#)
            }
        }
        let cappedRepositories = try await provider.fetchUsage(for: personal)
        try check(metadataCounter.value == 200, "Repository metadata requests must stop at the safety limit")
        try check(
            cappedRepositories.usageMessages.contains { $0.contains("lookup safety limit") },
            "Omitted repository metadata needs an unavailable explanation"
        )
        try check(
            cappedRepositories.cardInformationSections.contains { section in
                section.id == "github-billing.amounts-and-currency"
                    && section.items.contains { $0.detail.contains("detail rows were omitted") }
            },
            "Truncated repository, product, and SKU details need an explicit explanation"
        )

        try await assertActionsOnlyMetadataLookups(provider: provider, personal: personal)
    }

    private static func assertActionsOnlyMetadataLookups(
        provider: GitHubBillingUsageProvider,
        personal: ProviderAccountConfiguration
    ) async throws {
        let actionsMetadataCounter = LockedCounter()
        let mixedProducts = try mixedProductRepositoryUsage(unrelatedCount: 205)
        FixtureURLProtocol.setHandler { request in
            switch request.url?.path {
            case "/user":
                return response(request, status: 200, body: #"{"login":"octocat","plan":{"name":"free"}}"#)
            case "/users/octocat/settings/billing/usage/summary":
                return response(request, status: 200, body: #"{"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[{"product":"Actions","sku":"actions_linux","unitType":"minutes","pricePerUnit":0.006,"grossQuantity":1,"grossAmount":0.006,"discountQuantity":1,"discountAmount":0.006,"netQuantity":0,"netAmount":0}]}"#)
            case "/users/octocat/settings/billing/usage":
                return response(request, status: 200, data: mixedProducts)
            default:
                actionsMetadataCounter.increment()
                return response(request, status: 200, body: #"{"private":true}"#)
            }
        }
        let actionsOnlyMetadata = try await provider.fetchUsage(for: personal)
        try check(actionsMetadataCounter.value == 1, "Only Actions-minute repositories should need visibility metadata")
        try check(
            actionsOnlyMetadata.bars.first { $0.stableKey == "actions-private-minutes" }?.used == 1,
            "Unrelated product repositories must not consume the Actions metadata lookup limit"
        )
    }

    private static func assertOrganizationFailures(
        provider: GitHubBillingUsageProvider,
        store: FixtureSecretStore,
        credential: String
    ) async throws {
        let organization = organizationConfiguration()
        try store.saveSecret(credential, account: ProviderConfigurationStore.keychainAccount(for: organization))
        try await assertOrganizationPlanAllowance(provider: provider, organization: organization)
        try await assertOrganizationPlanPermissionGuidance(provider: provider, organization: organization)

        FixtureURLProtocol.setHandler { request in response(request, status: 404, body: "{}") }
        let hiddenOrganization = try await provider.fetchUsage(for: organization)
        try check(
            hiddenOrganization.failureMessage?.contains("A 404 does not confirm that your account is unsupported") == true,
            "Organization billing 404 responses must not claim to know the account state"
        )

        FixtureURLProtocol.setHandler { request in
            guard let url = request.url else { return response(request, status: 500, body: "{}") }
            if url.path.hasSuffix("/usage/summary") {
                return response(request, status: 200, data: organizationSummary())
            }
            if url.path.hasSuffix("/usage") {
                return response(request, status: 200, data: organizationUsage())
            }
            if url.path.hasSuffix("/budgets") {
                return response(request, status: 403, body: "{}")
            }
            return response(request, status: 404, body: "{}")
        }
        let budgetPermission = try await provider.fetchUsage(for: organization)
        try check(budgetPermission.failureMessage == nil, "A budget 403 must not discard readable organization usage")
        try check(
            budgetPermission.usageMessages.contains { $0.contains("not permitted") },
            "A budget 403 needs a distinct permission explanation"
        )

        FixtureURLProtocol.setHandler { request in
            guard let url = request.url else { return response(request, status: 500, body: "{}") }
            if url.path.hasSuffix("/usage/summary") {
                return response(request, status: 200, data: organizationSummary())
            }
            if url.path.hasSuffix("/usage") {
                return response(request, status: 200, data: organizationUsage())
            }
            if url.path.hasSuffix("/budgets") {
                return response(
                    request,
                    status: 403,
                    data: data("{}"),
                    headers: ["X-RateLimit-Remaining": "0"]
                )
            }
            return response(request, status: 404, body: "{}")
        }
        let budgetRateLimit = try await provider.fetchUsage(for: organization)
        try check(
            budgetRateLimit.failureMessage?.contains("rate limit") == true,
            "A rate-limited budget 403 must not be mislabeled as a permission failure"
        )

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
                    ? #"{"budgets":[{"id":"one","budget_type":"ProductPricing","budget_amount":100,"prevent_further_usage":true,"budget_scope":"organization","budget_product_sku":"Actions","budget_alerting":{"will_alert":true,"alert_recipients":[]}}],"has_next_page":true}"#
                    : #"{"budgets":[{"id":"two","budget_type":"SkuPricing","budget_amount":20,"prevent_further_usage":false,"budget_scope":"organization","budget_product_sku":"actions_linux","budget_alerting":{"will_alert":true,"alert_recipients":[]}}],"has_next_page":false}"#
                return response(request, status: 200, body: body)
            }
            return response(request, status: 404, body: "{}")
        }
        let paged = try await provider.fetchUsage(for: organization)
        try check(paged.failureMessage == nil, "Paginated organization fixture failed")
        try check(pageCounter.value == 2, "Budget pagination did not retrieve every page")

        FixtureURLProtocol.setHandler { request in
            guard let url = request.url else { return response(request, status: 500, body: "{}") }
            if url.path.hasSuffix("/usage/summary") {
                return response(request, status: 200, data: organizationSummary())
            }
            if url.path.hasSuffix("/usage") {
                return response(request, status: 200, data: organizationUsage())
            }
            if url.path.hasSuffix("/budgets") {
                return response(request, status: 200, body: #"{"budgets":[],"has_next_page":true}"#)
            }
            return response(request, status: 404, body: "{}")
        }
        let excessivePagination = try await provider.fetchUsage(for: organization)
        try check(
            excessivePagination.failureMessage?.contains("could not read") == true,
            "A pagination response that never terminates must fail instead of returning partial data"
        )
    }

    private static func assertOrganizationPlanPermissionGuidance(
        provider: GitHubBillingUsageProvider,
        organization: ProviderAccountConfiguration
    ) async throws {
        FixtureURLProtocol.setHandler { request in
            guard let path = request.url?.path else { return response(request, status: 500, body: "{}") }
            switch path {
            case "/orgs/Example-Engineering":
                return response(request, status: 403, body: "{}")
            case "/organizations/Example-Engineering/settings/billing/usage/summary":
                return response(request, status: 200, data: organizationSummary())
            case "/organizations/Example-Engineering/settings/billing/usage":
                return response(request, status: 200, data: organizationUsage())
            case "/organizations/Example-Engineering/settings/billing/budgets":
                return response(request, status: 200, body: #"{"budgets":[],"has_next_page":false}"#)
            case "/repos/example/private", "/repos/example/other":
                return response(request, status: 200, body: #"{"private":true}"#)
            case "/repos/example/priv-ate":
                return response(request, status: 200, body: #"{"private":false}"#)
            default:
                return response(request, status: 404, body: "{}")
            }
        }
        let result = try await provider.fetchUsage(for: organization)
        try check(result.failureMessage == nil, "A plan permission failure must preserve readable billing usage")
        try check(
            result.usageMessages.contains { $0.contains("approve organization administration access") },
            "A missing admin:org grant must explain how to restore organization allowance progress"
        )
    }

    private static func assertOrganizationPlanAllowance(
        provider: GitHubBillingUsageProvider,
        organization: ProviderAccountConfiguration
    ) async throws {
        FixtureURLProtocol.setHandler { request in
            guard let path = request.url?.path else { return response(request, status: 500, body: "{}") }
            switch path {
            case "/orgs/Example-Engineering":
                return response(request, status: 200, body: #"{"plan":{"name":"team"}}"#)
            case "/organizations/Example-Engineering/settings/billing/usage/summary":
                return response(request, status: 200, data: organizationSummary())
            case "/organizations/Example-Engineering/settings/billing/usage":
                return response(request, status: 200, data: organizationUsage())
            case "/organizations/Example-Engineering/settings/billing/budgets":
                return response(request, status: 200, body: #"{"budgets":[],"has_next_page":false}"#)
            case "/repos/example/private", "/repos/example/other":
                return response(request, status: 200, body: #"{"private":true}"#)
            case "/repos/example/priv-ate":
                return response(request, status: 200, body: #"{"private":false}"#)
            default:
                return response(request, status: 404, body: "{}")
            }
        }
        let result = try await provider.fetchUsage(for: organization)
        try check(result.failureMessage == nil, "A readable organization plan must not discard billing usage")
        try check(
            result.bars.first { $0.stableKey == "actions-private-minutes" }?.limit == 3_000,
            "The provider must retrieve the organization's Team allowance"
        )
        try check(
            result.unavailableUsageMetrics["githubBilling.actions-packages-storage"]?
                .contains("does not identify package visibility") == true,
            "The provider must not infer package visibility from repository metadata"
        )
    }

    private static let personalUsageBody = #"{"usageItems":[{"date":"2026-09-01","product":"Actions","sku":"Actions Linux","quantity":10,"unitType":"minutes","pricePerUnit":0.006,"repositoryName":"octocat/private","grossAmount":0.06,"discountAmount":0.06,"netAmount":0}]}"#

    private static func manyRepositoryUsage(count: Int) throws -> Data {
        let items: [[String: Any]] = (0..<count).map { index in
            [
                "product": "Actions",
                "sku": "Actions Linux",
                "quantity": 1,
                "unitType": "minutes",
                "pricePerUnit": 0.01,
                "date": "2026-09-01",
                "repositoryName": "octocat/repository-\(index)",
                "grossAmount": 0.01,
                "discountAmount": 0.01,
                "netAmount": 0,
            ]
        }
        return try JSONSerialization.data(withJSONObject: ["usageItems": items])
    }

    private static func mixedProductRepositoryUsage(unrelatedCount: Int) throws -> Data {
        var items: [[String: Any]] = (0..<unrelatedCount).map { index in
            [
                "date": "2026-09-01",
                "product": "Copilot",
                "sku": "copilot_premium_requests",
                "quantity": 1,
                "unitType": "requests",
                "pricePerUnit": 0.01,
                "repositoryName": "octocat/package-\(index)",
                "grossAmount": 0.01,
                "discountAmount": 0,
                "netAmount": 0.01,
            ]
        }
        items.append([
            "date": "2026-09-01",
            "product": "Actions",
            "sku": "actions_linux",
            "quantity": 1,
            "unitType": "minutes",
            "pricePerUnit": NSDecimalNumber(string: "0.006"),
            "repositoryName": "octocat/actions",
            "grossAmount": 0.006,
            "discountAmount": 0.006,
            "netAmount": 0,
        ])
        return try JSONSerialization.data(withJSONObject: ["usageItems": items])
    }

    private static func personalSummary() -> Data {
        data(#"{"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[{"product":"Copilot","sku":"copilot_premium_requests","unitType":"requests","grossQuantity":1,"grossAmount":0.1,"discountAmount":0.1,"netAmount":0}]}"#)
    }

    private static func organizationSummary() -> Data {
        data(#"{"timePeriod":{"year":2026,"month":9},"organization":"Example-Engineering","usageItems":[{"product":"Actions","sku":"actions_linux","unitType":"minutes","pricePerUnit":0.006,"grossQuantity":1200,"grossAmount":7.2,"discountQuantity":1200,"discountAmount":7.2,"netQuantity":0,"netAmount":0},{"product":"Packages","sku":"packages_storage","unitType":"GB-hours","pricePerUnit":0.0225,"grossQuantity":50,"grossAmount":1.125,"discountQuantity":25,"discountAmount":0.5625,"netQuantity":25,"netAmount":0.5625}]}"#)
    }

    private static func organizationUsage() -> Data {
        data(#"{"usageItems":[{"date":"2026-09-01","product":"Actions","sku":"actions_linux","quantity":1000,"unitType":"minutes","pricePerUnit":0.006,"grossAmount":6,"discountAmount":6,"netAmount":0,"organizationName":"Example-Engineering","repositoryName":"example/private"},{"date":"2026-09-02","product":"Actions","sku":"actions_linux","quantity":200,"unitType":"minutes","pricePerUnit":0.006,"grossAmount":1.2,"discountAmount":1.2,"netAmount":0,"organizationName":"Example-Engineering","repositoryName":"example/other"},{"date":"2026-09-03","product":"Other","sku":"other_linux","quantity":400,"unitType":"minutes","pricePerUnit":0.01,"grossAmount":4,"discountAmount":0,"netAmount":4,"organizationName":"Example-Engineering","repositoryName":"example/priv-ate"},{"date":"2026-09-04","product":"Packages","sku":"packages_storage","quantity":40,"unitType":"GB-hours","pricePerUnit":0.0225,"grossAmount":0.9,"discountAmount":0.45,"netAmount":0.45,"organizationName":"Example-Engineering","repositoryName":"example/private"},{"date":"2026-09-05","product":"Packages","sku":"packages_storage","quantity":10,"unitType":"GB-hours","pricePerUnit":0.0225,"grossAmount":0.225,"discountAmount":0.1125,"netAmount":0.1125,"organizationName":"Example-Engineering","repositoryName":"example/priv-ate"}]}"#)
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

    private static let organizationRepositoryVisibility = [
        "example/private": true,
        "example/other": true,
        "example/priv-ate": false,
    ]

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
        data: Data,
        headers: [String: String]? = nil
    ) -> (HTTPURLResponse, Data) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: nil,
            headerFields: headers
        )!
        return (response, data)
    }
}

private struct FixtureIdentifiedFailureProvider: UsageProvider {
    let providerID = ProviderID.githubBilling

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: providerID,
            title: configuration.displayName,
            subtitle: "Refresh failed",
            bars: [],
            failureMessage: "Refresh failed",
            cacheIdentity: configuration.githubBillingOwner.lowercased(),
            fetchedAt: Date()
        )
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
