import Foundation
import XCTest
@testable import CodexBarIOS

final class ProviderCardPlanTests: XCTestCase {
    func testCodexProTiersComeFromMetadataRatherThanUsage() throws {
        for (raw, label) in [("pro", "PRO 20X"), ("prolite", "PRO 5X"), ("unknown", "Plan unavailable")] {
            let payload = "{\"plan_type\":\"\(raw)\",\"rate_limit\":{\"primary_window\":{\"used_percent\":42,\"reset_at\":1893542400,\"limit_window_seconds\":18000}}}"
            let parsed = try XCTUnwrap(CodexUsageParser.parse(Data(payload.utf8)))
            XCTAssertEqual(parsed.cardPlan.displayLabel, label)
            XCTAssertEqual(parsed.bars.first?.used, 42)
        }
    }

    func testClaudeMaxVariantsAndUnknownTier() throws {
        for (subscription, tier, label) in [
            ("max", "default_claude_max_5x", "MAX 5×"),
            ("max", "default_claude_max_20x", "MAX 20×"),
            ("max", "unknown", "MAX"),
            ("unknown", "unknown", "Plan unavailable"),
        ] {
            let parsed = try XCTUnwrap(ClaudeUsageParser.parse(
                Data(#"{"five_hour":{"utilization":42}}"#.utf8), subscriptionType: subscription, rateLimitTier: tier
            ))
            XCTAssertEqual(parsed.cardPlan.displayLabel, label)
        }
    }

    func testEveryProviderHasAnHonestTypeWithoutGuessingFromAccountName() {
        for provider in ProviderID.allCases {
            let result = ProviderUsageResult(
                accountID: provider.rawValue, providerID: provider, title: "Google AI Ultra Pro Max 20x",
                subtitle: "Synthetic", bars: [UsageBar(label: "Weekly", used: 42, limit: 100)], fetchedAt: Date()
            )
            let expected = [.openRouter, .moonshot].contains(provider) ? "API credits" : "Plan unavailable"
            XCTAssertEqual(result.cardPlan.displayLabel, expected, provider.rawValue)
            XCTAssertNil(result.plan, "Presentation fallback must not become verified metadata")
        }
    }

    func testVerifiedGrokMetadataAndOtherReportedPlansAreHonored() {
        let grok = ProviderUsageResult(
            providerID: .grok, title: "Synthetic", verifiedGrokPlanName: "SuperGrok Lite",
            subtitle: "Synthetic", bars: [], fetchedAt: Date()
        )
        XCTAssertEqual(grok.cardPlan.displayLabel, "SuperGrok Lite")
        let cursorPlan = ProviderPlanDescriptor.make(providerPrefix: "cursor", identifier: "business", label: "Business")
        let cursor = ProviderUsageResult(providerID: .cursor, title: "Synthetic", plan: cursorPlan,
                                         subtitle: "Synthetic", bars: [], fetchedAt: Date())
        XCTAssertEqual(cursor.cardPlan, cursorPlan)
        let differentProvider = ProviderUsageResult(
            providerID: .claude, title: "Synthetic", verifiedGrokPlanName: "SuperGrok Lite",
            subtitle: "Synthetic", bars: [], fetchedAt: Date()
        )
        XCTAssertEqual(differentProvider.cardPlan.displayLabel, "Plan unavailable")
    }

    @MainActor
    func testGrokPlanSurvivesOnlyReusableSameAccountRefreshFailure() async throws {
        let account = ProviderAccountConfiguration(id: "grok.fixture", providerID: .grok, accountLabel: "Grok", authMethod: .apiKey)
        let cached = ProviderUsageResult(
            accountID: account.id, providerID: .grok, title: "Grok", verifiedGrokPlanName: "SuperGrok Lite",
            subtitle: "Synthetic", bars: [UsageBar(label: "Weekly", used: 31, limit: 100)],
            cacheIdentity: "same-subject", fetchedAt: Date()
        )
        for (identity, reauthenticate, expected) in [
            ("same-subject", false, "SuperGrok Lite"),
            ("different-subject", false, "Plan unavailable"),
            ("same-subject", true, "Plan unavailable"),
        ] {
            let service = UsageRefreshService(
                providers: [FailedGrokPlanProvider(identity: identity, reauthenticate: reauthenticate)], initialResults: [cached]
            )
            await service.refresh(configurations: [account])
            XCTAssertEqual(try XCTUnwrap(service.results.first).cardPlan.displayLabel, expected)
        }
    }

    func testReportedPlanAndFreeBillingAreAccountScoped() {
        let verified = ProviderPlanDescriptor.make(providerPrefix: "claude", identifier: "pro", label: "Pro")
        let first = ProviderUsageResult(accountID: "first", providerID: .claude, title: "Same title", plan: verified,
                                        subtitle: "Synthetic", bars: [], fetchedAt: Date())
        let second = ProviderUsageResult(accountID: "second", providerID: .claude, title: "Same title",
                                         subtitle: "Synthetic", bars: [], fetchedAt: Date())
        XCTAssertEqual(first.cardPlan, verified)
        XCTAssertEqual(second.cardPlan.displayLabel, "Plan unavailable")
        let free = ProviderUsageResult(
            providerID: .greptile, title: "Synthetic", subtitle: "Synthetic", bars: [],
            greptileAllowanceRenewal: GreptileAllowanceRenewal(renewsAt: nil, observedAt: Date(), isApplicable: true),
            fetchedAt: Date()
        )
        XCTAssertEqual(free.cardPlan.displayLabel, "FREE")
    }
}

private struct FailedGrokPlanProvider: UsageProvider {
    let providerID = ProviderID.grok
    let identity: String
    let reauthenticate: Bool

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id, providerID: .grok, title: configuration.displayName, subtitle: "Synthetic failure",
            bars: [], failureMessage: "Synthetic failure", recoveryAction: reauthenticate ? .reauthenticate : .retryRefresh,
            cacheIdentity: identity, fetchedAt: Date()
        )
    }
}
