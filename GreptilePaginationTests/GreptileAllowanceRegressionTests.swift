import Foundation
import XCTest
@testable import CodexBarIOS

final class GreptileAllowanceRegressionTests: XCTestCase, @unchecked Sendable {
    func testActivityOnlyKeepsTheReviewCountWithoutExplanatoryCopy() async throws {
        let fixture = GreptileHTTPFixture([try GreptileHTTPFixture.page(["first", "second"], total: 2)])
        defer { fixture.invalidate() }
        let result = try await fixture.provider().fetchUsage(for: GreptileHTTPFixture.account)
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(result.greptileAllowanceRenewal?.requiresNewAccount, true)
        XCTAssertEqual(result.greptileAllowanceRenewal?.requiresAuthentication, false)
        XCTAssertNil(result.greptileAllowanceRenewal?.isApplicable)
        XCTAssertEqual(result.subtitle, "")
        XCTAssertEqual(result.bars.first?.used, 2)
        XCTAssertEqual(result.bars.first?.limit, 0)
        XCTAssertNil(result.bars.first?.resetsAt)
        XCTAssertNil(result.plan)
        XCTAssertEqual(result.bars.first?.stableKey, GreptileUsageIdentity.completedReviewsStableKey)
        XCTAssertTrue(result.usageMessages.isEmpty)
        XCTAssertEqual(fixture.requests.count, 1)
        XCTAssertEqual(try GreptileHTTPFixture.offset(in: fixture.requests[0]), 0)
    }

    func testEmptyActivityDoesNotRepresentMissingBillingDataAsZero() async throws {
        let fixture = GreptileHTTPFixture([try GreptileHTTPFixture.page([], total: 0)])
        defer { fixture.invalidate() }
        let result = try await fixture.provider().fetchUsage(for: GreptileHTTPFixture.account)
        XCTAssertNil(result.failureMessage)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertNil(result.plan)
        XCTAssertTrue(result.usageMessages.isEmpty)
    }

    func testCreditLookingMetadataCannotBecomeAReviewQuotaOrFreePlanBalance() async throws {
        for quota in [
            ["creditsUsed": 3, "includedCredits": 50, "plan": "Starter"],
            ["reviewsUsed": true, "includedReviews": 50, "plan": "Starter"],
            ["reviewsUsed": 2, "includedReviews": 0, "plan": "Starter"],
        ] as [[String: Any]] {
            let fixture = GreptileHTTPFixture([try GreptileHTTPFixture.page(["first"], total: 1, quota: quota)])
            defer { fixture.invalidate() }
            let result = try await fixture.provider().fetchUsage(for: GreptileHTTPFixture.account)
            XCTAssertNil(result.failureMessage)
            XCTAssertEqual(result.bars.first?.used, 1)
            XCTAssertEqual(result.bars.first?.limit, 0)
            XCTAssertNil(result.bars.first?.resetsAt)
            XCTAssertNil(result.plan)
            XCTAssertEqual(result.bars.first?.stableKey, GreptileUsageIdentity.completedReviewsStableKey)
        }
    }

    func testExplicitReturnedReviewQuotaAndResetRemainAuthoritative() async throws {
        let quota: [String: Any] = [
            "reviewsUsed": 0, "includedReviews": 17, "plan": "Starter",
            "billingPeriodStart": "2030-01-01T00:00:00Z", "billingPeriodEnd": "2030-01-31T00:00:00Z",
        ]
        let fixture = GreptileHTTPFixture([try GreptileHTTPFixture.page(["first"], total: 1, quota: quota)])
        defer { fixture.invalidate() }
        let result = try await fixture.provider().fetchUsage(for: GreptileHTTPFixture.account)
        let bar = try XCTUnwrap(result.bars.first)
        XCTAssertEqual(bar.stableKey, GreptileUsageIdentity.reviewQuotaStableKey)
        XCTAssertEqual(bar.used, 0)
        XCTAssertEqual(bar.limit, 17)
        XCTAssertEqual(bar.resetsAt, ISO8601DateFormatter().date(from: "2030-01-31T00:00:00Z"))
        XCTAssertEqual(bar.projectionPeriodStart, ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z"))
        XCTAssertEqual(result.subtitle, "")
        XCTAssertTrue(result.usageMessages.isEmpty)
    }

    func testAuthorizationFailureIsNotSuccessfulMissingBillingData() async throws {
        let fixture = GreptileHTTPFixture([.payload(Data("{}".utf8), status: 401)])
        defer { fixture.invalidate() }
        let result = try await fixture.provider().fetchUsage(for: GreptileHTTPFixture.account)
        XCTAssertTrue(result.failureMessage?.contains("rejected this organization API key") == true)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertFalse(result.usageMessages.contains { $0.contains("remaining credits") })
        XCTAssertEqual(fixture.requests.count, 1)
    }
}
