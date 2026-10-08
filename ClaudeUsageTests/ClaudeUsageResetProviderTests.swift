import Foundation
import XCTest
@testable import CodexBarIOS

final class ClaudeUsageResetProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_893_456_000)

    func testOnlyFreshProviderInventoryIsAttachedToItsAccount() async throws {
        for status in [429, 503] {
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.protocolClasses = [ResetFetchProtocol.self]
            let session = URLSession(configuration: sessionConfiguration)
            defer { session.invalidateAndCancel() }
            let secrets = ResetFetchSecrets()
            let clock = now
            let provider = ClaudeUsageProvider(secretStore: secrets, session: session, now: { clock })
            let account = ProviderAccountConfiguration(id: "claude-reset-fetch", providerID: .claude, authMethod: .cliToken)
            ResetFetchProtocol.configure(status: 200, inventory: true)
            let fresh = try await provider.fetchUsage(for: account)
            XCTAssertEqual(fresh.accountID, account.id)
            XCTAssertEqual(fresh.bars.first?.used, 42)
            XCTAssertEqual(fresh.claudeUsageResetInventory?.availableCount(at: now), 2)
            XCTAssertEqual(fresh.claudeUsageResetInventory?.credentialBinding,
                           ClaudeUsageResetClient.credentialBinding(for: "fixture-token"))
            XCTAssertEqual(ResetFetchProtocol.requests.count, 1)
            XCTAssertEqual(ResetFetchProtocol.requests.first?.url?.query, "cedar_ember=1")
            ResetFetchProtocol.configure(status: status, inventory: false)
            let failed = try await provider.fetchUsage(for: account)
            XCTAssertNotNil(failed.failureMessage)
            XCTAssertEqual(failed.bars, fresh.bars)
            XCTAssertNil(failed.claudeUsageResetInventory)
            XCTAssertEqual(ResetFetchProtocol.requests.count, 1)
        }
    }

    func testMissingInventoryAndChangedCredentialNeverReuseSavedGrants() async throws {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ResetFetchProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        defer { session.invalidateAndCancel() }
        let secrets = ResetFetchSecrets()
        let clock = now
        let provider = ClaudeUsageProvider(secretStore: secrets, session: session, now: { clock })
        let account = ProviderAccountConfiguration(id: "claude-reset-fetch", providerID: .claude, authMethod: .cliToken)
        ResetFetchProtocol.configure(status: 200, inventory: true)
        let first = try await provider.fetchUsage(for: account)
        XCTAssertNotNil(first.claudeUsageResetInventory)
        let confirmed = try XCTUnwrap(first.claudeUsageResetInventory?.redeemableGrant(at: now))
        ResetFetchProtocol.configure(status: 200, inventory: true, count: 1)
        let changed = try await provider.fetchUsage(for: account)
        XCTAssertEqual(changed.claudeUsageResetInventory?.grants.first?.remainingCount, 1)
        ResetFetchProtocol.configure(status: 200, inventory: true, count: 1)
        do {
            _ = try await provider.consumeClaudeReset(
                for: account, grantID: confirmed.id, confirmedGrant: confirmed,
                credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "fixture-token")
            )
            XCTFail("A refreshed cache must not replace the grant the user confirmed")
        } catch { XCTAssertEqual(error as? ClaudeUsageResetError, .unavailable) }
        XCTAssertTrue(ResetFetchProtocol.requests.isEmpty, "Changed confirmation must be rejected before any reset preflight or POST")
        ResetFetchProtocol.configure(status: 200, inventory: false)
        let missing = try await provider.fetchUsage(for: account)
        XCTAssertNil(missing.claudeUsageResetInventory)
        XCTAssertNil(missing.failureMessage)
        secrets.replace(with: "replacement-token")
        ResetFetchProtocol.configure(status: 503, inventory: false)
        let replacement = try await provider.fetchUsage(for: account)
        XCTAssertNotNil(replacement.failureMessage)
        XCTAssertTrue(replacement.bars.isEmpty)
        XCTAssertNil(replacement.claudeUsageResetInventory)
        XCTAssertEqual(ResetFetchProtocol.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer replacement-token")
    }
}

private final class ResetFetchSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var token = "fixture-token"
    func replace(with value: String) { lock.withLock { token = value } }
    func readSecret(account: String) throws -> String? { lock.withLock { token } }
    func saveSecret(_ secret: String, account: String) throws { replace(with: secret) }
    func deleteSecret(account: String) throws { replace(with: "") }
}

private class ResetFetchProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var includesInventory = true
    nonisolated(unsafe) private static var remainingCount = 2
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func configure(status: Int, inventory: Bool, count: Int = 2) {
        lock.withLock { self.status = status; includesInventory = inventory; remainingCount = count; recorded = [] }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let responseState = Self.lock.withLock {
            Self.recorded.append(request)
            return (Self.status, Self.includesInventory, Self.remainingCount)
        }
        let inventory = responseState.1 ? #"""
        ,"cedar_ember":{"eligible":true,"next_grant_id":"fixture_grant","grants":[{
          "id":"fixture_grant","resets_left":2,"starts_at":"2029-12-01T00:00:00Z",
          "ends_at":"2030-01-08T00:00:00Z","clears":["five_hour","seven_day"],"usable_now":true
        }]}
        """#.replacingOccurrences(of: "\"resets_left\":2", with: "\"resets_left\":\(responseState.2)") : ""
        let body = "{\"five_hour\":{\"utilization\":42}" + inventory + "}"
        let response = HTTPURLResponse(url: request.url!, statusCode: responseState.0, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
