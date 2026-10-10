import Foundation
import XCTest
@testable import CodexBarIOS

@MainActor
final class CodexCreditsTransportTests: XCTestCase {
    func testReadOnlyAccountScopedBalanceAndUnlimitedSurviveResetMetadata() async throws {
        let accounts = ["personal", "work", "unlimited"].map {
            ProviderAccountConfiguration(id: "credits-\($0)", providerID: .codex, accountLabel: $0, authMethod: .browserSession)
        }
        let provider = makeProvider(accounts: accounts)
        for account in accounts {
            let result = try await provider.fetchUsage(for: account)
            XCTAssertEqual(result.accountID, account.id)
            XCTAssertEqual(result.codexBankedRateLimitResets?.availableCount, 1)
            if account.accountLabel == "unlimited" {
                XCTAssertEqual(result.unavailableUsageMetrics[CodexUsageParser.creditsPoolMetricID], "Unlimited credits")
                XCTAssertEqual(result.bars.count, 1)
            } else {
                XCTAssertEqual(result.bars.last?.used, account.accountLabel == "personal" ? 62500 : 770)
                XCTAssertTrue(try XCTUnwrap(result.bars.last).isUnboundedNumeric)
            }
        }
    }

    func testFailureKeepsLastKnownBalanceButSuccessfulAbsenceClearsIt() async throws {
        let account = ProviderAccountConfiguration(id: "failure-\(UUID().uuidString)", providerID: .codex,
                                                  accountLabel: "Failure", authMethod: .browserSession)
        let provider = makeProvider(accounts: [account])
        let service = UsageRefreshService(providers: [provider])
        await service.refresh(configurations: [account])
        let original = try XCTUnwrap(service.results.first)
        XCTAssertEqual(original.bars.last?.used, 62500)
        await service.refresh(configurations: [account])
        let stale = try XCTUnwrap(service.results.first)
        XCTAssertEqual(stale.bars.last?.used, 62500)
        XCTAssertNotNil(stale.failureMessage)
        XCTAssertFalse(stale.hasCurrentBars)
        XCTAssertEqual(stale.barsFetchedAt, original.barsFetchedAt)
        await service.refresh(configurations: [account])
        let absent = try XCTUnwrap(service.results.first)
        XCTAssertNil(absent.failureMessage)
        XCTAssertEqual(absent.bars.count, 1)
        XCTAssertEqual(absent.unavailableUsageMetrics[CodexUsageParser.creditsPoolMetricID], "Credits unavailable")
    }

    func testCreditOnlySuccessfulAbsenceClearsThePreviousBalance() async throws {
        let account = ProviderAccountConfiguration(id: "credit-only-\(UUID().uuidString)", providerID: .codex,
                                                  accountLabel: "Credit-only", authMethod: .browserSession)
        let service = UsageRefreshService(providers: [makeProvider(accounts: [account])])
        await service.refresh(configurations: [account])
        XCTAssertEqual(service.results.first?.bars.last?.used, 62500)
        await service.refresh(configurations: [account])
        let absent = try XCTUnwrap(service.results.first)
        XCTAssertNil(absent.failureMessage)
        XCTAssertTrue(absent.bars.isEmpty)
        XCTAssertEqual(absent.unavailableUsageMetrics[CodexUsageParser.creditsPoolMetricID], "Credits unavailable")
    }

    func testPlanRefreshAndFailuresStayBoundToTheSameCredential() async throws {
        let fixture = CodexPlanTransportFixture()
        defer { fixture.close() }
        let service = UsageRefreshService(providers: [fixture.provider])
        await service.refresh(configurations: [fixture.account])
        XCTAssertEqual(service.results.first?.cardPlan.displayLabel, "ChatGPT Pro (More)")
        XCTAssertEqual(service.results.first?.bars.first?.used, 42)
        fixture.state.update(plan: "promax")
        await service.refresh(configurations: [fixture.account])
        XCTAssertEqual(service.results.first?.cardPlan.displayLabel, "ChatGPT Pro (Max)")
        fixture.state.update(status: 200, plan: "future-pro")
        await service.refresh(configurations: [fixture.account])
        XCTAssertEqual(service.results.first?.cardPlan.displayLabel, "Plan unavailable")
        XCTAssertEqual(service.results.first?.bars.first?.used, 42)
        fixture.state.update(status: 200, plan: "promax")
        await service.refresh(configurations: [fixture.account])
        for status in [503, 0] {
            fixture.state.update(status: status)
            await service.refresh(configurations: [fixture.account])
            XCTAssertEqual(service.results.first?.cardPlan.displayLabel, "ChatGPT Pro (Max)")
            XCTAssertNotNil(service.results.first?.failureMessage)
        }
        fixture.state.replaceCredential(token: "replacement")
        await service.refresh(configurations: [fixture.account])
        XCTAssertEqual(service.results.first?.cardPlan.displayLabel, "Plan unavailable")
        XCTAssertTrue(try XCTUnwrap(service.results.first).bars.isEmpty)
        fixture.state.update(status: 200, plan: "future-pro")
        await service.refresh(configurations: [fixture.account])
        XCTAssertEqual(service.results.first?.cardPlan.displayLabel, "Plan unavailable")
        XCTAssertEqual(service.results.first?.bars.first?.used, 42)
    }

    func testPlanAuthenticationFailureAndSignOutClearCachedTier() async throws {
        for status in [401, 403] {
            let fixture = CodexPlanTransportFixture()
            defer { fixture.close() }
            let service = UsageRefreshService(providers: [fixture.provider])
            await service.refresh(configurations: [fixture.account])
            XCTAssertEqual(service.results.first?.cardPlan.displayLabel, "ChatGPT Pro (More)")
            fixture.state.update(status: status)
            await service.refresh(configurations: [fixture.account])
            XCTAssertEqual(service.results.first?.cardPlan.displayLabel, "Plan unavailable")
            fixture.state.update(status: 200)
            await service.refresh(configurations: [fixture.account])
            XCTAssertEqual(service.results.first?.cardPlan.displayLabel, "ChatGPT Pro (More)")
            fixture.state.deleteSecret(account: ProviderConfigurationStore.keychainAccount(for: fixture.account))
            await service.refresh(configurations: [fixture.account])
            XCTAssertEqual(service.results.first?.cardPlan.displayLabel, "Plan unavailable")
        }
    }

    func testLateUsageOrInventoryCannotPublishAfterCredentialReplacement() async throws {
        for changedPath in ["/usage", "/inventory"] {
            let fixture = CodexPlanTransportFixture()
            defer { fixture.close() }
            fixture.state.changeCredentialOnRequest(path: changedPath)
            do {
                _ = try await fixture.provider.fetchUsage(for: fixture.account)
                XCTFail("A response from the old credential must be rejected")
            } catch is CancellationError {
                XCTAssertEqual(fixture.state.token, "replacement")
            }
        }
    }

    func testDifferentAccountsCannotReuseEachOthersPlan() async throws {
        let first = CodexPlanTransportFixture()
        let second = CodexPlanTransportFixture()
        defer { first.close(); second.close() }
        second.state.update(plan: "prolite")
        let firstResult = try await first.provider.fetchUsage(for: first.account)
        let secondResult = try await second.provider.fetchUsage(for: second.account)
        XCTAssertEqual(firstResult.cardPlan.displayLabel, "ChatGPT Pro (More)")
        XCTAssertEqual(secondResult.cardPlan.displayLabel, "ChatGPT Pro")
        XCTAssertNotEqual(firstResult.cacheIdentity, secondResult.cacheIdentity)
        XCTAssertEqual(firstResult.title, first.account.displayName)
        XCTAssertEqual(secondResult.title, second.account.displayName)
    }

    private func makeProvider(accounts: [ProviderAccountConfiguration]) -> CodexUsageProvider {
        let credentials = Dictionary(uniqueKeysWithValues: accounts.map {
            (ProviderConfigurationStore.keychainAccount(for: $0),
             CodexCredentialsParser.storedCredential(from: CodexCredentials(accessToken: "synthetic-token", accountID: $0.id)))
        })
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CreditsReadOnlyURLProtocol.self]
        return CodexUsageProvider(secretStore: CreditsTransportSecretStore(credentials: credentials),
                                  session: URLSession(configuration: config),
                                  usageEndpoint: URL(string: "https://credits.invalid/usage")!,
                                  resetCreditsEndpoint: URL(string: "https://credits.invalid/inventory")!)
    }
}

private struct CreditsTransportSecretStore: SecretStore {
    let credentials: [String: String]
    func readSecret(account: String) throws -> String? { credentials[account] }
    func saveSecret(_ secret: String, account: String) throws {}
    func deleteSecret(account: String) throws {}
}

private class CreditsReadOnlyURLProtocol: URLProtocol, @unchecked Sendable {
    private static let attempts = CreditsRequestAttempts()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "credits.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.httpMethod == "GET", request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token",
              let identity = request.value(forHTTPHeaderField: "ChatGPT-Account-Id") else {
            client?.urlProtocol(self, didFailWithError: URLError(.userAuthenticationRequired))
            return
        }
        let body: String
        var status = 200
        if request.url?.path == "/inventory" {
            body = #"{"available_count":1}"#
        } else {
            let count = Self.attempts.next(identity)
            if identity.hasPrefix("failure-") && count == 2 { status = 503 }
            let balance = identity.hasSuffix("work") ? "770" : "62500"
            let credits = identity.hasSuffix("unlimited")
                ? #"{"has_credits":true,"unlimited":true,"balance":null}"#
                : ((identity.hasPrefix("failure-") && count >= 3) || (identity.hasPrefix("credit-only-") && count >= 2)
                   ? #"{"has_credits":true,"unlimited":false,"balance":null}"#
                   : #"{"has_credits":true,"unlimited":false,"balance":"\#(balance)"}"#)
            body = identity.hasPrefix("credit-only-") ? #"{"credits":\#(credits)}"# : #"""
            {"credits":\#(credits),"rate_limit":{"primary_window":{
            "used_percent":12,"reset_at":1893456000,"limit_window_seconds":18000}}}
            """#
        }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: status,
                                                                  httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class CreditsRequestAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    func next(_ identity: String) -> Int {
        lock.withLock {
            counts[identity, default: 0] += 1
            return counts[identity, default: 0]
        }
    }
}

private struct CodexPlanTransportFixture {
    let state = CodexPlanTransportState()
    let account: ProviderAccountConfiguration
    let provider: CodexUsageProvider
    private let host: String

    init() {
        host = "\(UUID().uuidString.lowercased()).invalid"
        account = ProviderAccountConfiguration(id: host, providerID: .codex, accountLabel: "Custom fixture title", authMethod: .browserSession)
        state.accountID = account.id
        CodexPlanURLProtocol.register(state, host: host)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CodexPlanURLProtocol.self]
        provider = CodexUsageProvider(secretStore: state, session: URLSession(configuration: config),
                                      usageEndpoint: URL(string: "https://\(host)/usage")!,
                                      resetCreditsEndpoint: URL(string: "https://\(host)/inventory")!)
    }

    func close() { CodexPlanURLProtocol.unregister(host: host) }
}

private final class CodexPlanTransportState: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    var accountID = ""
    private var credential: String? = "original"
    private var status = 200
    private var plan = "pro"
    private var changingPath: String?
    var token: String? { lock.withLock { credential } }

    func update(status: Int? = nil, plan: String? = nil) {
        lock.withLock {
            if let status { self.status = status }
            if let plan { self.plan = plan }
        }
    }
    func replaceCredential(token: String) { lock.withLock { credential = token } }
    func changeCredentialOnRequest(path: String) { lock.withLock { changingPath = path } }
    func readSecret(account: String) throws -> String? {
        lock.withLock {
            credential.map { CodexCredentialsParser.storedCredential(from: CodexCredentials(accessToken: $0, accountID: accountID)) }
        }
    }
    func saveSecret(_ secret: String, account: String) throws {}
    func deleteSecret(account: String) { lock.withLock { credential = nil } }

    func response(for request: URLRequest) -> (Int, Data) {
        lock.withLock {
            guard request.httpMethod == "GET", request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == accountID,
                  request.value(forHTTPHeaderField: "Authorization") == "Bearer \(credential ?? "")" else {
                return (401, Data())
            }
            if request.url?.path == changingPath { credential = "replacement" }
            if request.url?.path == "/inventory" { return (503, Data()) }
            return (status, Data(#"""
            {"plan_type":"\#(plan)","rate_limit":{"primary_window":{
            "used_percent":42,"reset_at":1893542400,"limit_window_seconds":18000}}}
            """#.utf8))
        }
    }
}

private class CodexPlanURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var states: [String: CodexPlanTransportState] = [:]
    static func register(_ state: CodexPlanTransportState, host: String) { lock.withLock { states[host] = state } }
    static func unregister(host: String) { _ = lock.withLock { states.removeValue(forKey: host) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let state = Self.lock.withLock({ Self.states[url.host ?? ""] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, data) = state.response(for: request)
        if status == 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
