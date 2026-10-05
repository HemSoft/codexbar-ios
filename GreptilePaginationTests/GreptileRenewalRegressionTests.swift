import Foundation
import XCTest
@testable import CodexBarIOS

final class GreptileRenewalRegressionTests: XCTestCase, @unchecked Sendable {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func credential(subject: String = "fixture-user", organization: String = "fixture-org") -> GreptileSessionCredentials {
        GreptileSessionCredentials(
            version: 1, subject: subject,
            organization: GreptileOrganization(tenantExternalId: organization, name: "Synthetic organization"),
            cookies: [GreptileSessionCookie(name: "__Secure-authjs.session-token", value: "synthetic-cookie", expiresAt: nil)]
        )
    }

    private func identity(subject: String = "fixture-user", organization: String = "fixture-org") throws -> GreptileHTTPFixture.Reply {
        .payload(try JSONSerialization.data(withJSONObject: [
            "user": [
                "greptileId": subject, "greptileToken": "synthetic-user-token",
                "organizations": [["tenantExternalId": organization, "name": "Synthetic organization"]],
            ],
        ]))
    }

    private func billing(_ state: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: [["result": ["data": ["json": state]]]])
    }

    private func provider(_ fixture: GreptileHTTPFixture, credential: GreptileSessionCredentials) throws -> GreptileUsageProvider {
        let account = browserAccount()
        return GreptileUsageProvider(
            secretStore: GreptileFixtureSecrets(values: [
                ProviderConfigurationStore.keychainAccount(for: account): try credential.encoded(),
            ]),
            session: fixture.session, endpoint: fixture.endpoint, dashboardBaseURL: fixture.endpoint
        )
    }

    private func browserAccount() -> ProviderAccountConfiguration {
        ProviderAccountConfiguration(id: "synthetic-browser-account", providerID: .greptile, authMethod: .browserSession)
    }

    func testBillingDateDoesNotRequireCreditsOrReviewHistory() async throws {
        let date = "2030-02-15T12:03:41.000Z"
        let fixture = GreptileHTTPFixture([
            try identity(),
            .payload(try billing(["kind": "free", "currentPeriod": ["end": date]])),
            try GreptileHTTPFixture.page([], total: 0),
        ])
        defer { fixture.invalidate() }
        let result = try await provider(fixture, credential: credential()).fetchUsage(for: browserAccount())
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(result.greptileAllowanceRenewal?.renewsAt, ISO8601DateFormatter().date(from: "2030-02-15T12:03:41Z"))
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertNil(result.creditsRemaining)
        XCTAssertEqual(result.cacheIdentity, "fixture-user:fixture-org")
        let requests = fixture.requests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[0].url?.path, fixture.endpoint.path + "/api/auth/session")
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(requests[1].httpMethod, "GET")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Cookie"), "__Secure-authjs.session-token=synthetic-cookie")
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(requests[1].url), resolvingAgainstBaseURL: false))
        let input = try XCTUnwrap(components.queryItems?.first { $0.name == "input" }?.value)
        XCTAssertTrue(input.contains("fixture-org"))
        XCTAssertNil(requests[2].value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(requests[2].value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-user-token")
        let body = try GreptileHTTPFixture.requestBody(requests[2])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
        XCTAssertEqual(arguments["organization"] as? String, "fixture-org")
    }

    func testMissingMalformedAndUnrelatedPeriodsNeverInventADate() throws {
        for state: [String: Any] in [
            ["kind": "free"],
            ["kind": "free", "currentPeriod": ["end": "invalid"]],
            ["kind": "free", "currentPeriod": ["end": NSNull()]],
            ["kind": "free", "currentPeriod": ["start": "2030-03-01T00:00:00Z", "end": "2030-02-01T00:00:00Z"]],
            ["kind": "paid", "currentPeriod": ["end": "2030-02-01T00:00:00Z"]],
            ["kind": "free", "apiSubscription": ["currentPeriodEnd": "2030-02-01T00:00:00Z"]],
        ] {
            XCTAssertNil(try GreptileDashboardClient.parseBillingState(billing(state)).renewalDate)
        }
        XCTAssertThrowsError(try GreptileDashboardClient.parseBillingState(Data("[]".utf8)))
        XCTAssertThrowsError(try GreptileDashboardClient.parseBillingState(Data("not-json".utf8)))
    }

    func testWrongSubjectOrOrganizationStopsBeforeBillingAndReviewRequests() async throws {
        for reply in [try identity(subject: "another-user"), try identity(organization: "another-org")] {
            let fixture = GreptileHTTPFixture([reply])
            defer { fixture.invalidate() }
            let result = try await provider(fixture, credential: credential()).fetchUsage(for: browserAccount())
            XCTAssertEqual(result.recoveryAction, .reauthenticate)
            XCTAssertEqual(result.cacheIdentity, "unverified-greptile-session")
            XCTAssertTrue(result.bars.isEmpty)
            XCTAssertNil(result.greptileAllowanceRenewal)
            XCTAssertEqual(fixture.requests.count, 1)
        }
    }

    func testCookiesRejectExpiredIncompleteAndInjectedCredentials() throws {
        for cookies in [
            [GreptileSessionCookie(name: "__Secure-authjs.session-token", value: "a", expiresAt: now)],
            [GreptileSessionCookie(name: "__Secure-authjs.session-token", value: "a; other=b", expiresAt: nil)],
            [GreptileSessionCookie(name: "__Secure-authjs.session-token.1", value: "a", expiresAt: nil)],
            [GreptileSessionCookie(name: "unrelated", value: "a", expiresAt: nil)],
        ] {
            let invalid = GreptileSessionCredentials(version: 1, subject: "user", organization: credential().organization, cookies: cookies)
            XCTAssertThrowsError(try invalid.cookieHeader(now: now))
        }
        let chunks = GreptileSessionCredentials(
            version: 1, subject: "user", organization: credential().organization,
            cookies: [
                GreptileSessionCookie(name: "__Secure-authjs.session-token.0", value: "a", expiresAt: nil),
                GreptileSessionCookie(name: "__Secure-authjs.session-token.1", value: "b", expiresAt: nil),
            ]
        )
        XCTAssertEqual(try chunks.cookieHeader(), "__Secure-authjs.session-token.0=a; __Secure-authjs.session-token.1=b")
        XCTAssertEqual(GreptileSessionCredentials.parse(try chunks.encoded()), chunks)
        XCTAssertNotEqual(credential().cacheIdentity, credential(organization: "another-org").cacheIdentity)
    }

    func testCountdownPassedAndStaleDatesAreHonest() {
        let renewal = GreptileAllowanceRenewal(renewsAt: now.addingTimeInterval(90_000), observedAt: now)
        XCTAssertEqual(renewal.status(at: now), "Renews in 1d 1h")
        XCTAssertNotNil(renewal.localDateText)
        XCTAssertEqual(renewal.status(at: now.addingTimeInterval(90_000)), "Last known renewal date")
        let passed = GreptileAllowanceRenewal(renewsAt: now, observedAt: now)
        XCTAssertEqual(passed.status(at: now), "Period ended. Refresh for the next renewal.")
        let stale = GreptileAllowanceRenewal(renewsAt: now.addingTimeInterval(600), observedAt: now, isStale: true)
        XCTAssertEqual(stale.status(at: now), "Last known renewal date")
        XCTAssertEqual(GreptileAllowanceRenewal(renewsAt: nil, observedAt: now).status(at: now), "Renewal date unavailable")
    }

    @MainActor
    func testReconnectCannotReplaceAnotherOrganization() throws {
        let account = browserAccount()
        let saved = try credential().encoded()
        let secrets = GreptileFixtureSecrets(values: [ProviderConfigurationStore.keychainAccount(for: account): saved])
        let suite = "GreptileRenewalRegressionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secrets)
        XCTAssertTrue(store.canReconnectGreptile(credential(), for: account))
        XCTAssertFalse(store.canReconnectGreptile(credential(organization: "another-org"), for: account))
        XCTAssertFalse(store.canReconnectGreptile(credential(subject: "another-user"), for: account))
        XCTAssertEqual(try secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: account)), saved)
    }

    @MainActor
    func testUnverifiedSessionCannotReuseAnotherAccountsRenewal() async throws {
        let fixture = GreptileHTTPFixture([try identity(subject: "another-user")])
        defer { fixture.invalidate() }
        let account = browserAccount()
        let previous = ProviderUsageResult(
            accountID: account.id, providerID: .greptile, title: account.displayName, subtitle: "Previous account", bars: [],
            greptileAllowanceRenewal: GreptileAllowanceRenewal(renewsAt: now.addingTimeInterval(600), observedAt: now),
            cacheIdentity: credential().cacheIdentity, fetchedAt: now
        )
        let service = UsageRefreshService(providers: [try provider(fixture, credential: credential())], initialResults: [previous])
        await service.refresh(configurations: [account])
        XCTAssertNil(service.results.first?.greptileAllowanceRenewal)
        XCTAssertNotNil(service.results.first?.failureMessage)
    }

    @MainActor
    func testRefreshFailurePreservesStaleDateAndNextSuccessReplacesIt() async throws {
        let first = try billing(["kind": "free", "currentPeriod": ["end": "2030-02-01T00:00:00Z"]])
        let next = try billing(["kind": "free", "currentPeriod": ["end": "2030-03-01T00:00:00Z"]])
        let fixture = GreptileHTTPFixture([
            try identity(), .payload(first), try GreptileHTTPFixture.page(["first"], total: 1),
            .failure(URLError(.notConnectedToInternet)),
            try identity(), .payload(next), try GreptileHTTPFixture.page(["first"], total: 1),
        ])
        defer { fixture.invalidate() }
        let service = UsageRefreshService(providers: [try provider(fixture, credential: credential())])
        let account = browserAccount()
        await service.refresh(configurations: [account])
        let original = try XCTUnwrap(service.results.first?.greptileAllowanceRenewal)
        await service.refresh(configurations: [account])
        XCTAssertEqual(service.results.first?.greptileAllowanceRenewal?.renewsAt, original.renewsAt)
        XCTAssertEqual(service.results.first?.greptileAllowanceRenewal?.isStale, true)
        XCTAssertEqual(service.results.first?.recoveryAction, .retryRefresh)
        await service.refresh(configurations: [account])
        XCTAssertNotEqual(service.results.first?.greptileAllowanceRenewal?.renewsAt, original.renewsAt)
        XCTAssertEqual(service.results.first?.greptileAllowanceRenewal?.isStale, false)
        XCTAssertNil(service.results.first?.failureMessage)
    }
}
