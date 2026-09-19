// swiftlint:disable line_length
import Foundation
import CodexBarIOS

@main
enum GitHubBillingFixtureRunner {
    static func main() async throws {
        try await personalAuthorizationScopeRegression()
        try await personalPermissionDiagnostics()
        try personalFreeAndProAllowances()
        try amountAndProductSummaryContract()
        try currencyEvidenceContract()
        try organizationBudgetsAndPaginationParsing()
        try malformedAndMissingFields()
        try await accountIsolationFixtures()
        try await providerRequestAndFailureFixtures()
        print("GitHub Billing fixture suite passed: personal plans, repository classification, mixed runners, "
            + "accrued storage, Git LFS, discounts, budgets, pagination, missing data, two-decimal aggregates, "
            + "unit-rate precision, USD currency evidence, product summaries, and HTTP failures.")
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
        try check(scopes == ["repo", "read:org", "user"], "Billing must request only its documented scopes")
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
            {"product":"Actions","sku":"actions_storage","unitType":"GB-hours","grossQuantity":120,"grossAmount":2.125,"discountAmount":2.125,"netAmount":0},
            {"product":"Packages","sku":"packages_storage","unitType":"GB-hours","grossQuantity":24,"grossAmount":0.25,"discountAmount":0.125,"netAmount":0.125},
            {"product":"Actions","sku":"actions_cache_storage","unitType":"GB-hours","grossQuantity":100,"grossAmount":0,"discountAmount":0,"netAmount":0},
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
            {"date":"2026-09-04","product":"Actions","sku":"actions_linux_arm","quantity":20,"unitType":"minutes","pricePerUnit":0.005,"grossAmount":0.1,"discountAmount":0.1,"netAmount":0,"repositoryName":"octocat/private"},
            {"date":"2026-09-05","product":"Actions","sku":"actions_windows_arm","quantity":10,"unitType":"minutes","pricePerUnit":0.01,"grossAmount":0.1,"discountAmount":0.1,"netAmount":0,"repositoryName":"octocat/private"},
            {"date":"2026-09-06","product":"Actions","sku":"Actions Linux","quantity":900,"unitType":"minutes","pricePerUnit":0.006,"grossAmount":5.4,"discountAmount":5.4,"netAmount":0,"repositoryName":"octocat/public"}
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
        try check(actionBar.used == 340, "Mixed standard runners must apply x64, arm64, and macOS multipliers")
        try check(actionBar.limit == 2_000, "Free accounts must receive 2,000 included Actions minutes")
        try check(
            free.cardInformationSections.contains { section in
                section.items.contains { item in
                    item.label == "Private Actions minutes"
                        && item.detail.contains("340 used")
                        && item.detail.contains("2,000 included")
                        && item.detail.contains("1,660 remaining")
                }
            },
            "Personal allowance details must show used, included, and remaining minutes"
        )
        let storage = try require(free.bars.first { $0.stableKey == "actions-packages-storage" }, "Storage bar missing")
        try check(storage.used == 144, "Actions and Packages GB-hours must share one accrued total")
        try check(storage.limit == 360, "September Free storage allowance must be 0.5 GB times 720 hours")
        let lfsStorage = try require(free.bars.first { $0.stableKey == "lfs-storage" }, "Git LFS storage bar missing")
        try check(lfsStorage.used == 48 && lfsStorage.limit == 7_200, "Git LFS storage must use its 10 GiB accrued allowance")
        let lfsBandwidth = try require(free.bars.first { $0.stableKey == "lfs-bandwidth" }, "Git LFS bandwidth bar missing")
        try check(lfsBandwidth.used == 3.5 && lfsBandwidth.limit == 10, "Git LFS bandwidth must use its separate monthly allowance")
        try check(free.monetaryMetrics.first { $0.kind == .grossSpend }?.amount == Decimal(string: "3.125"), "Gross spend precision was lost")
        try check(free.monetaryMetrics.first { $0.kind == .discounts }?.amount == Decimal(string: "2.65"), "Full and partial discounts were not retained")
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
            pro.bars.first { $0.stableKey == "actions-packages-storage" }?.limit == 720,
            "Pro accounts must receive 1 GiB of shared Actions and Packages storage"
        )
        try check(
            pro.bars.first { $0.stableKey == "lfs-storage" }?.limit == 7_200,
            "Pro Git LFS storage must retain its separate 10 GiB allowance"
        )

        let unknownRunnerUsage = data(#"{"usageItems":[{"product":"Actions","sku":"Actions macOS 12-core","quantity":10,"unitType":"minutes","repositoryName":"octocat/private","grossAmount":1,"discountAmount":1,"netAmount":0}]}"#)
        let unknownRunner = try require(GitHubBillingUsageParser.parsePersonal(
            summaryData: summary,
            usageData: unknownRunnerUsage,
            repositoryVisibility: ["octocat/private": true],
            planName: "pro",
            configuration: configuration,
            fetchedAt: fetchedAt
        ), "Unknown runner fixture did not parse")
        try check(
            unknownRunner.bars.contains { $0.stableKey == "actions-private-minutes" } == false,
            "Unknown or larger runners must not be guessed as standard included minutes"
        )
        try check(
            unknownRunner.unavailableUsageMetrics["githubBilling.actions-private-minutes"] != nil,
            "Unknown runners need an unavailable explanation"
        )
        try check(
            unknownRunner.usageMessages.contains { $0.contains("could not classify") },
            "Unavailable allowance explanations must be visible on the account card"
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
            {"product":"Actions","sku":"actions_storage","unitType":"GB-hours","pricePerUnit":0.04,"grossQuantity":144,"grossAmount":5.10,"discountAmount":1.10,"netAmount":4.00},
            {"product":"Copilot","sku":"copilot_premium_requests","unitType":"requests","pricePerUnit":0.04,"grossQuantity":10,"grossAmount":0.40,"discountAmount":0,"netAmount":0.40},
            {"product":"Codespaces","sku":"codespaces_compute","unitType":"core-hours","pricePerUnit":0.08,"grossQuantity":5,"grossAmount":0.40,"discountAmount":0.10,"netAmount":0.30},
            {"product":"Git LFS","sku":"lfs_storage","unitType":"GB-hours","pricePerUnit":0.07,"grossQuantity":1,"grossAmount":0,"discountAmount":0,"netAmount":0},
            {"product":"Advanced Security","sku":"secret_scanning","unitType":"active-committers","pricePerUnit":0,"grossQuantity":1,"grossAmount":0,"discountAmount":0,"netAmount":0},
            {"product":"Packages","sku":"packages_storage","unitType":"GB-hours","pricePerUnit":0.04,"grossQuantity":50,"grossAmount":1.125,"discountAmount":0.5625,"netAmount":0.5625}
          ]
        }
        """#)
        let usage = data(#"""
        {
          "usageItems": [
            {"date":"2026-09-01","product":"Actions","sku":"Actions Linux","quantity":100,"unitType":"minutes","pricePerUnit":0.006,"grossAmount":0.6,"discountAmount":0.6,"netAmount":0,"repositoryName":"octocat/private"},
            {"date":"2026-09-02","product":"Actions","sku":"Actions Windows","quantity":50,"unitType":"minutes","pricePerUnit":0.01,"grossAmount":0.5,"discountAmount":0.5,"netAmount":0,"repositoryName":"octocat/private"}
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
        let advancedSecurityIndex = try require(sectionIDs.firstIndex(of: "github-billing.product.advanced-security"), "An unknown product must remain visible under its GitHub product name")
        let packagesIndex = try require(sectionIDs.firstIndex(of: "github-billing.product.packages"), "Packages summary missing")
        try check(
            copilotIndex < actionsIndex && actionsIndex < codespacesIndex && codespacesIndex < gitLFSIndex
                && gitLFSIndex < advancedSecurityIndex && advancedSecurityIndex < packagesIndex,
            "All known products must sort before alphabetized unknown products"
        )

        let actionsSection = result.cardInformationSections[actionsIndex]
        try check(actionsSection.items.contains { item in
            item.label == "Consumed usage" && item.detail == "\(aggregateText(Decimal(string: "5.10")!)) · 144 GB-hours"
        }, "Consumed usage must show the two-decimal aggregate with its returned quantity")
        try check(actionsSection.items.contains { $0.label == "Discount usage" && $0.detail == aggregateText(Decimal(string: "1.10")!) }, "Discount usage must stay separate from consumed usage")
        try check(actionsSection.items.contains { $0.label == "Billable usage" && $0.detail == aggregateText(Decimal(string: "4.00")!) }, "Billable usage must show the authoritative net amount")
        try check(actionsSection.items.contains { item in
            item.label == "Included usage · Minutes"
                && item.detail == "200 of 2,000 minutes used · 1,800 minutes remaining"
        }, "Actions included minutes must show used, included, and remaining values")
        try check(actionsSection.items.contains { item in
            item.label == "Included usage · Storage"
                && item.detail == "194 of 360 GB-hours used (Actions and Packages storage) · 166 GB-hours remaining"
        }, "Actions included storage must split from minutes with used and remaining values")

        // Aggregate amounts use two fractional digits; unit rates keep their source precision.
        let detailItems = result.cardInformationSections
            .first { $0.id == "github-billing.usage-detail" }?.items ?? []
        try check(!detailItems.isEmpty, "Usage detail rows must stay available alongside product summaries")
        try check(detailItems.contains { item in
            item.detail.contains("\(unitPriceText(Decimal(string: "0.006")!, 3))/minute")
        }, "Unit prices must keep GitHub's source precision instead of rounding the rate")
        try check(detailItems.contains { item in
            item.detail.contains("\(unitPriceText(Decimal(string: "0.01")!, 2))/minute")
        }, "Two-digit unit rates must keep the standard currency display")
        try check(detailItems.contains { item in
            item.detail.contains("\(aggregateText(Decimal(string: "0.60")!)) gross")
        }, "Aggregate amounts in detail rows must use two fractional digits")
        try check(
            result.monetaryMetrics.first { $0.kind == .grossSpend }?.amount == Decimal(string: "7.025"),
            "Aggregate precision must be retained even though the display shows two decimals"
        )
        try check(
            result.monetaryMetrics.first { $0.kind == .discounts }?.amount == Decimal(string: "1.7625"),
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
            !unknownPlanNotes.contains { $0.label == "Private Actions minutes" },
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
            conflicting?.monetaryMetrics.allSatisfy { $0.currencyCode == "USD" } == true,
            "Unverifiable currency evidence must fall back to the documented USD rendering"
        )
        try check(
            conflicting?.cardInformationSections.contains { section in
                section.id == "github-billing.amounts-and-currency"
                    && section.items.contains { item in
                        item.label == "Currency evidence" && item.detail.contains("cannot verify")
                    }
            } == true,
            "Conflicting currency evidence must be explained in the amounts and currency section"
        )

        let malformedCurrency = try parse(summaryData: data(
            #"{"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[{"product":"Actions","sku":"actions_storage","unitType":"GB-hours","currency":"ZZZ","grossQuantity":1,"grossAmount":1,"discountAmount":0,"netAmount":1}]}"#
        ))
        try check(
            malformedCurrency?.monetaryMetrics.allSatisfy { $0.currencyCode == "USD" } == true,
            "An unsupported three-letter currency value must not become the rendered currency"
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
        let summary = organizationSummary()
        let pages = [
            data(#"""
            {"budgets":[{"id":"product-budget","budget_type":"ProductPricing","budget_amount":100,"prevent_further_usage":true,"budget_scope":"organization","budget_product_sku":"Actions","budget_alerting":{"will_alert":true,"alert_recipients":[]}}],"has_next_page":true}
            """#),
            data(#"""
            {"budgets":[{"id":"sku-budget","budget_type":"SkuPricing","budget_amount":20,"prevent_further_usage":false,"budget_scope":"repository","budget_entity_name":"example/private","budget_product_skus":["actions_linux"],"budget_alerting":{"will_alert":true,"alert_recipients":[]}},{"id":"tracking-budget","budget_type":"ProductPricing","budget_amount":25,"prevent_further_usage":false,"budget_scope":"organization","budget_product_sku":"Packages","budget_alerting":{"will_alert":false,"alert_recipients":[]}},{"id":"zero-budget","budget_type":"SkuPricing","budget_amount":0,"prevent_further_usage":true,"budget_scope":"organization","budget_product_sku":"actions_macos","budget_alerting":{"will_alert":true,"alert_recipients":[]}},{"id":"cost-center-budget","budget_type":"ProductPricing","budget_amount":50,"prevent_further_usage":false,"budget_scope":"cost_center","budget_entity_name":"engineering","budget_product_sku":"Actions","budget_alerting":{"will_alert":true,"alert_recipients":[]}}],"has_next_page":false}
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

        let noBudget = try require(GitHubBillingUsageParser.parseOrganization(
            summaryData: summary,
            usageData: organizationUsage(),
            budgetPageData: [data("{\"budgets\":[],\"has_next_page\":false}")],
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
            configuration: configuration,
            fetchedAt: fetchedAt
        ), "Scoped budget fixture did not parse")
        try check(!scopedBudget.hasReachedSpendLimit, "Unrelated account spend must not trigger a scoped budget alert")

        let duplicateSummary = data(#"{"timePeriod":{"year":2026,"month":9},"organization":"Example-Engineering","usageItems":[{"product":"Actions","sku":"actions_linux","unitType":"minutes","pricePerUnit":0.01,"grossQuantity":200,"grossAmount":2,"discountAmount":0,"netAmount":2},{"product":"Actions","sku":"actions_linux","unitType":"minutes","pricePerUnit":0.01,"grossQuantity":1000,"grossAmount":10.25,"discountAmount":2.25,"netAmount":8}]}"#)
        let aggregated = try require(GitHubBillingUsageParser.parseOrganization(
            summaryData: duplicateSummary,
            usageData: organizationUsage(),
            budgetPageData: [],
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
                return response(request, status: 200, data: personalSummary())
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
                "product": "Packages",
                "sku": "packages_storage",
                "quantity": 1,
                "unitType": "GB-hours",
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
            "pricePerUnit": 0.006,
            "repositoryName": "octocat/actions",
            "grossAmount": 0.006,
            "discountAmount": 0.006,
            "netAmount": 0,
        ])
        return try JSONSerialization.data(withJSONObject: ["usageItems": items])
    }

    private static func personalSummary() -> Data {
        data(#"{"timePeriod":{"year":2026,"month":9},"user":"octocat","usageItems":[{"product":"Actions","sku":"actions_storage","unitType":"GB-hours","grossQuantity":12,"grossAmount":0.1,"discountAmount":0.1,"netAmount":0}]}"#)
    }

    private static func organizationSummary() -> Data {
        data(#"{"timePeriod":{"year":2026,"month":9},"organization":"Example-Engineering","usageItems":[{"product":"Actions","sku":"actions_linux","unitType":"minutes","pricePerUnit":0.01,"grossQuantity":1200,"grossAmount":12.25,"discountQuantity":200,"discountAmount":2.25,"netQuantity":1000,"netAmount":10.00},{"product":"Packages","sku":"packages_storage","unitType":"GB-hours","pricePerUnit":0.0225,"grossQuantity":50,"grossAmount":1.125,"discountQuantity":25,"discountAmount":0.5625,"netQuantity":25,"netAmount":0.5625}]}"#)
    }

    private static func organizationUsage() -> Data {
        data(#"{"usageItems":[{"date":"2026-09-01","product":"Actions","sku":"actions_linux","quantity":1000,"unitType":"minutes","pricePerUnit":0.01,"grossAmount":10.25,"discountAmount":2.25,"netAmount":8,"organizationName":"Example-Engineering","repositoryName":"example/private"},{"date":"2026-09-02","product":"Actions","sku":"actions_linux","quantity":200,"unitType":"minutes","pricePerUnit":0.01,"grossAmount":2,"discountAmount":0,"netAmount":2,"organizationName":"Example-Engineering","repositoryName":"example/other"},{"date":"2026-09-03","product":"Other","sku":"actions_linux","quantity":400,"unitType":"minutes","pricePerUnit":0.01,"grossAmount":4,"discountAmount":0,"netAmount":4,"organizationName":"Example-Engineering","repositoryName":"example/priv-ate"}]}"#)
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
