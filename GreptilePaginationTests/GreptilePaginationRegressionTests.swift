import Foundation
import XCTest
@testable import CodexBarIOS

final class GreptilePaginationRegressionTests: XCTestCase, @unchecked Sendable {
    func testEmptyFirstPageWithUnknownOrZeroTotalDoesNotInventUsage() async throws {
        for pageSize in [0, 1, 2, 100] {
            for total in [nil, 0] as [Int?] {
                let fixture = GreptileHTTPFixture([try GreptileHTTPFixture.page([], total: total)])
                defer { fixture.invalidate() }
                let result = try await fixture.provider(pageSize: pageSize).fetchUsage(for: GreptileHTTPFixture.account)
                XCTAssertNil(result.failureMessage)
                XCTAssertTrue(result.bars.isEmpty)
                XCTAssertEqual(fixture.requests.count, 1)
                XCTAssertTrue(result.usageMessages.isEmpty)
            }
        }
    }

    func testUnknownTotalFullThenEmptyPageCompletesWithoutAnotherRequest() async throws {
        let fixture = GreptileHTTPFixture([
            try GreptileHTTPFixture.page(["one", "two"]),
            try GreptileHTTPFixture.page([]),
        ])
        defer { fixture.invalidate() }
        let result = try await fixture.provider().fetchUsage(for: GreptileHTTPFixture.account)
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(result.bars.first?.used, 2)
        XCTAssertEqual(try fixture.requests.map(GreptileHTTPFixture.offset), [0, 2])
    }

    func testKnownOutstandingTotalRejectsAnEmptyPage() async throws {
        let fixture = GreptileHTTPFixture([
            try GreptileHTTPFixture.page(["one", "two"], total: 3),
            try GreptileHTTPFixture.page([], total: 3),
        ])
        defer { fixture.invalidate() }
        let result = try await fixture.provider().fetchUsage(for: GreptileHTTPFixture.account)
        XCTAssertTrue(result.failureMessage?.contains("incomplete paginated") == true)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(try fixture.requests.map(GreptileHTTPFixture.offset), [0, 2])
    }

    func testShortPageOnlyCompletesIfNoReportedReviewsRemain() async throws {
        for total in [nil, 1, 3] as [Int?] {
            let fixture = GreptileHTTPFixture([try GreptileHTTPFixture.page(["one"], total: total)])
            defer { fixture.invalidate() }
            let result = try await fixture.provider().fetchUsage(for: GreptileHTTPFixture.account)
            if total == 3 {
                XCTAssertNotNil(result.failureMessage)
                XCTAssertTrue(result.bars.isEmpty)
            } else {
                XCTAssertNil(result.failureMessage)
                XCTAssertEqual(result.bars.first?.used, 1)
            }
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testKnownTotalCompleteScanStopsBeforeAnEmptyRequestAndKeepsReportedQuota() async throws {
        let quota: [String: Any] = [
            "reviewsUsed": 0, "includedReviews": 50,
            "billingPeriodEnd": "2030-01-03T00:00:00Z", "plan": "Fixture plan",
        ]
        let fixture = GreptileHTTPFixture([
            try GreptileHTTPFixture.page(["one", "two"], total: 4, quota: quota),
            try GreptileHTTPFixture.page(["three", "four"], total: 4),
        ])
        defer { fixture.invalidate() }
        let result = try await fixture.provider().fetchUsage(for: GreptileHTTPFixture.account)
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(result.bars.first?.used, 0)
        XCTAssertEqual(result.bars.first?.limit, 50)
        XCTAssertEqual(result.bars.first?.resetsAt, ISO8601DateFormatter().date(from: "2030-01-03T00:00:00Z"))
        XCTAssertEqual(try fixture.requests.map(GreptileHTTPFixture.offset), [0, 2])
        XCTAssertTrue(fixture.requests.allSatisfy { $0.httpMethod == "POST" && $0.url == fixture.endpoint })
        XCTAssertTrue(fixture.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key" })
    }

    func testDuplicatePagesCannotSatisfyAReportedTotal() async throws {
        let fixture = GreptileHTTPFixture([
            try GreptileHTTPFixture.page(["same-one", "same-two"], total: 4),
            try GreptileHTTPFixture.page(["same-one", "same-two"], total: 4),
        ])
        defer { fixture.invalidate() }
        let result = try await fixture.provider().fetchUsage(for: GreptileHTTPFixture.account)
        XCTAssertNotNil(result.failureMessage)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(fixture.requests.count, 2)
    }

    func testTruncatedEmptyShortAndFullPagesNeverBecomeCompleteScans() async throws {
        for ids in [[], ["one"], ["one", "two"]] {
            let fixture = GreptileHTTPFixture([try GreptileHTTPFixture.page(ids, truncated: true)])
            defer { fixture.invalidate() }
            let result = try await fixture.provider().fetchUsage(for: GreptileHTTPFixture.account)
            XCTAssertTrue(result.failureMessage?.contains("incomplete paginated") == true)
            XCTAssertTrue(result.bars.isEmpty)
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testConfiguredPageLimitAndPublishedOffsetLimitRejectIncompleteScans() async throws {
        let limited = GreptileHTTPFixture([try GreptileHTTPFixture.page(["one", "two"], total: 4)])
        defer { limited.invalidate() }
        let result = try await limited.provider(maximumPageCount: 1).fetchUsage(for: GreptileHTTPFixture.account)
        XCTAssertNotNil(result.failureMessage)
        XCTAssertEqual(limited.requests.count, 1)

        let pages = try (0..<11).map { page in
            try GreptileHTTPFixture.page((0..<100).map { "\(page)-\($0)" }, total: 1200)
        }
        let bounded = GreptileHTTPFixture(pages)
        defer { bounded.invalidate() }
        let incomplete = try await bounded.provider(pageSize: 100).fetchUsage(for: GreptileHTTPFixture.account)
        XCTAssertNotNil(incomplete.failureMessage)
        XCTAssertTrue(incomplete.bars.isEmpty)
        let offsets = try bounded.requests.map(GreptileHTTPFixture.offset)
        XCTAssertEqual(offsets, Array(stride(from: 0, through: 1000, by: 100)))
    }

    func testHTTPParserAndTransportFailuresNeverPublishPartialUsage() async throws {
        let failures: [GreptileHTTPFixture.Reply] = [
            .payload(Data(), status: 401), .payload(Data(), status: 403),
            .payload(Data(), status: 429), .payload(Data(), status: 503),
            .payload(Data("not-json".utf8)),
            .payload(Data(#"{"error":{"message":"Permission denied"}}"#.utf8)),
            .payload(Data(#"{"error":{"message":"Rate limit"}}"#.utf8)),
            .payload(Data(#"{"error":{"message":"Server failure"}}"#.utf8)),
            .failure(URLError(.timedOut)),
        ]
        for failure in failures {
            let fixture = GreptileHTTPFixture([try GreptileHTTPFixture.page(["one", "two"], total: 3), failure])
            defer { fixture.invalidate() }
            let result = try await fixture.provider().fetchUsage(for: GreptileHTTPFixture.account)
            XCTAssertNotNil(result.failureMessage)
            XCTAssertTrue(result.bars.isEmpty)
            XCTAssertEqual(fixture.requests.count, 2)
            XCTAssertFalse(result.failureMessage?.contains("fixture-key") == true)
        }
    }

    func testCancelingTheNetworkReadDoesNotPublishACompleteScan() async throws {
        let fixture = GreptileHTTPFixture([.waitForCancellation])
        defer { fixture.invalidate() }
        let provider = fixture.provider()
        let task = Task { try await provider.fetchUsage(for: GreptileHTTPFixture.account) }
        defer { task.cancel() }
        await fulfillment(of: [fixture.started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Canceled reads must not publish a failure result")
        } catch is CancellationError {
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testMissingOrUnreadableCredentialStopsBeforeAnyRequest() async throws {
        for failsRead in [false, true] {
            let fixture = GreptileHTTPFixture([])
            defer { fixture.invalidate() }
            let result = try await fixture.provider(secrets: GreptileFixtureSecrets(values: [:], failsRead: failsRead))
                .fetchUsage(for: GreptileHTTPFixture.account)
            XCTAssertNotNil(result.failureMessage)
            XCTAssertTrue(result.bars.isEmpty)
            XCTAssertTrue(fixture.requests.isEmpty)
        }
    }

    @MainActor
    func testIncompleteScanPreservesTheLastCompleteResultOnlyForItsAccount() async throws {
        let account = GreptileHTTPFixture.account
        let other = ProviderAccountConfiguration(id: "greptile.other", providerID: .greptile, authMethod: .apiKey)
        let oldDate = Date(timeIntervalSince1970: 1_000)
        func previous(_ configuration: ProviderAccountConfiguration, used: Double) -> ProviderUsageResult {
            ProviderUsageResult(
                accountID: configuration.id, providerID: .greptile, title: "Synthetic team", subtitle: "All available review history",
                bars: [UsageBar(label: "Completed reviews", used: used, limit: 0)], fetchedAt: oldDate
            )
        }
        let fixture = GreptileHTTPFixture([
            try GreptileHTTPFixture.page(["partial-one", "partial-two"], total: 3),
            try GreptileHTTPFixture.page([], total: 3),
        ])
        defer { fixture.invalidate() }
        let oldOther = previous(other, used: 11)
        let service = UsageRefreshService(providers: [fixture.provider()], initialResults: [previous(account, used: 7), oldOther])
        _ = await service.refresh(configuration: account)
        let retained = try XCTUnwrap(service.results.first { $0.accountID == account.id })
        XCTAssertEqual(retained.bars.first?.used, 7)
        XCTAssertNotNil(retained.failureMessage)
        XCTAssertFalse(retained.hasCurrentBars)
        XCTAssertEqual(service.results.first { $0.accountID == other.id }, oldOther)
    }

    func testSeparateAccountsReadOnlyTheirOwnCredentialAndDoNotShareCounts() async throws {
        let first = GreptileHTTPFixture.account
        let second = ProviderAccountConfiguration(id: "greptile.second", providerID: .greptile, authMethod: .apiKey)
        let fixture = GreptileHTTPFixture([
            try GreptileHTTPFixture.page(["same-id"], total: 1),
            try GreptileHTTPFixture.page(["same-id", "second-id"], total: 2),
        ])
        defer { fixture.invalidate() }
        let provider = fixture.provider(secrets: GreptileFixtureSecrets(values: [
            ProviderConfigurationStore.keychainAccount(for: first): "first-fixture-key",
            ProviderConfigurationStore.keychainAccount(for: second): "second-fixture-key",
        ]))
        let firstResult = try await provider.fetchUsage(for: first)
        let secondResult = try await provider.fetchUsage(for: second)
        XCTAssertEqual(firstResult.accountID, first.id)
        XCTAssertEqual(secondResult.accountID, second.id)
        XCTAssertEqual(firstResult.bars.first?.used, 1)
        XCTAssertEqual(secondResult.bars.first?.used, 2)
        XCTAssertEqual(fixture.requests.map { $0.value(forHTTPHeaderField: "Authorization") }, [
            "Bearer first-fixture-key", "Bearer second-fixture-key",
        ])
    }
}
