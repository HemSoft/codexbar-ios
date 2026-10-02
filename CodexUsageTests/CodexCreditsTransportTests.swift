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
