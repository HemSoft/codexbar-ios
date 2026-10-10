import XCTest
@testable import CodexBarIOS

final class CursorPlanTests: XCTestCase {
    func testMembershipMappingRejectsGuessesAndMalformedValues() throws {
        for (raw, label) in [("pro", "Pro"), ("pro_plus", "Pro+"), ("ultra", "Ultra"),
                             ("free", "Hobby"), ("free_trial", "Pro Trial"),] {
            let plan = try XCTUnwrap(CursorUsageProvider.parseMembership(Data("{\"membershipType\":\"\(raw)\"}".utf8)))
            XCTAssertEqual(plan.identifier, "cursor.\(raw)")
            XCTAssertEqual(plan.displayLabel, label)
            XCTAssertEqual(plan.accessibilityLabel, label)
        }
        for body in ["{}", "null", "[]", "invalid", #"{"membershipType":null}"#,
                     #"{"membershipType":123}"#, #"{"membershipType":"enterprise"}"#,
                     #"{"membershipType":"future","price":60,"limit":200}"#,] {
            XCTAssertNil(CursorUsageProvider.parseMembership(Data(body.utf8)), body)
        }
    }

    func testOptionalMembershipFailuresPreserveValidUsage() async throws {
        for (status, body) in [(403, "{}"), (500, "{}"), (200, "invalid"), (200, #"{"membershipType":42}"#)] {
            let store = MemorySecretStore()
            let account = configuration("personal")
            try store.saveSecret("personal-token", account: ProviderConfigurationStore.keychainAccount(for: account))
            let fixture = IsolatedTestURLSession { request in
                let membership = request.url?.lastPathComponent == "full_stripe_profile"
                if membership {
                    XCTAssertEqual(request.httpMethod, "GET")
                    XCTAssertNil(requestBodyData(from: request))
                    XCTAssertNil(request.value(forHTTPHeaderField: "Connect-Protocol-Version"))
                }
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer personal-token")
                return Self.response(request, status: membership ? status : 200,
                                     body: membership ? body : Self.responseBody(request))
            }
            defer { fixture.invalidate() }
            let result = try await CursorUsageProvider(secretStore: store, session: fixture.session).fetchUsage(for: account)
            XCTAssertNil(result.plan)
            XCTAssertEqual(result.bars.first?.usageText, "25%")
            XCTAssertNil(result.failureMessage)
        }
    }

    func testIndependentAccountsRefreshAndReloadWithTheirOwnMembership() async throws {
        let store = MemorySecretStore()
        let personal = configuration("personal"), work = configuration("work")
        try store.saveSecret("personal-token", account: ProviderConfigurationStore.keychainAccount(for: personal))
        try store.saveSecret("work-token", account: ProviderConfigurationStore.keychainAccount(for: work))
        let fixture = IsolatedTestURLSession { request in
            let raw = request.value(forHTTPHeaderField: "Authorization") == "Bearer personal-token" ? "pro" : "pro_plus"
            return Self.response(request, body: request.url?.lastPathComponent == "full_stripe_profile"
                                 ? "{\"membershipType\":\"\(raw)\"}" : Self.responseBody(request))
        }
        defer { fixture.invalidate() }
        for _ in 0..<2 {
            let provider = CursorUsageProvider(secretStore: store, session: fixture.session)
            async let first = provider.fetchUsage(for: personal)
            async let second = provider.fetchUsage(for: work)
            let results = try await [first, second]
            XCTAssertEqual(results.map(\.accountID), [personal.id, work.id])
            XCTAssertEqual(results.map { $0.plan?.displayLabel }, ["Pro", "Pro+"])
            XCTAssertNotEqual(results[0].cacheIdentity, results[1].cacheIdentity)
        }
    }

    func testLateMembershipIsDiscardedAfterReplacementOrSignOut() async throws {
        for replacement in ["replacement-token", nil] as [String?] {
            let store = MemorySecretStore(), account = configuration("personal")
            let key = ProviderConfigurationStore.keychainAccount(for: account)
            try store.saveSecret("personal-token", account: key)
            let fixture = IsolatedTestURLSession { request in
                if request.url?.lastPathComponent == "full_stripe_profile" {
                    if let replacement { try store.saveSecret(replacement, account: key) } else { try store.deleteSecret(account: key) }
                    return Self.response(request, body: #"{"membershipType":"pro"}"#)
                }
                return Self.response(request, body: Self.responseBody(request))
            }
            defer { fixture.invalidate() }
            let result = try await CursorUsageProvider(secretStore: store, session: fixture.session).fetchUsage(for: account)
            XCTAssertNil(result.plan)
            XCTAssertTrue(result.bars.isEmpty)
            XCTAssertNotNil(result.failureMessage)
            XCTAssertEqual(result.cacheIdentity, "superseded")
        }
    }

    @MainActor
    func testStalePlanIsKeptOnlyForTheSameCredential() async throws {
        let store = MemorySecretStore(), account = configuration("personal")
        let key = ProviderConfigurationStore.keychainAccount(for: account)
        try store.saveSecret("personal-token", account: key)
        let fixture = IsolatedTestURLSession { request in
            let failure = try store.readSecret(account: "test-mode") == "failure"
            if failure && request.url?.lastPathComponent == "GetCurrentPeriodUsage" {
                return Self.response(request, status: 503, body: "{}")
            }
            return Self.response(request, body: request.url?.lastPathComponent == "full_stripe_profile"
                                 ? #"{"membershipType":"pro"}"# : Self.responseBody(request))
        }
        defer { fixture.invalidate() }
        let service = UsageRefreshService(providers: [CursorUsageProvider(secretStore: store, session: fixture.session)])
        await service.refresh(configurations: [account])
        XCTAssertEqual(service.results.first?.plan?.displayLabel, "Pro")
        try store.saveSecret("failure", account: "test-mode")
        await service.refresh(configurations: [account])
        XCTAssertEqual(service.results.first?.plan?.displayLabel, "Pro")
        XCTAssertNotNil(service.results.first?.failureMessage)
        try store.saveSecret("replacement-token", account: key)
        await service.refresh(configurations: [account])
        XCTAssertNil(service.results.first?.plan)
        try store.deleteSecret(account: key)
        await service.refresh(configurations: [account])
        XCTAssertNil(service.results.first?.plan)
    }

    func testStalledMembershipIsOptionalAndCanceledAtDeadline() async throws {
        let store = MemorySecretStore(), account = configuration("personal")
        try store.saveSecret("personal-token", account: ProviderConfigurationStore.keychainAccount(for: account))
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [CursorPlanStallProtocol.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let result = try await CursorUsageProvider(secretStore: store, session: session,
                                                  membershipRequestTimeout: .milliseconds(25)).fetchUsage(for: account)
        XCTAssertNil(result.plan)
        XCTAssertEqual(result.bars.first?.usageText, "25%")
        XCTAssertNil(result.failureMessage)
    }

    private func configuration(_ id: String) -> ProviderAccountConfiguration {
        ProviderAccountConfiguration(id: "cursor.\(id)", providerID: .cursor,
                                     accountLabel: id, authMethod: .browserSession)
    }

    private static func responseBody(_ request: URLRequest) -> String {
        request.url?.lastPathComponent == "GetCurrentPeriodUsage"
            ? #"{"planUsage":{"autoPercentUsed":25,"apiPercentUsed":5}}"# : #"{"usagePercent":12}"#
    }

    private static func response(_ request: URLRequest, status: Int = 200, body: String) -> (HTTPURLResponse, Data) {
        (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
    }
}

private final class CursorPlanStallProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard request.url?.lastPathComponent != "full_stripe_profile", let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) else { return }
        let body = request.url?.lastPathComponent == "GetCurrentPeriodUsage"
            ? #"{"planUsage":{"autoPercentUsed":25,"apiPercentUsed":5}}"# : #"{"usagePercent":12}"#
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
