import Foundation
import XCTest
@testable import CodexBarIOS

final class CursorRenewalRegressionTests: XCTestCase, @unchecked Sendable {
    func testEarlyRenewalBackoffExpiresAndSeparatesCredentialKeys() async {
        let backoff = CursorEarlyRenewalBackoff()
        let now = Date(timeIntervalSince1970: 1000)
        await backoff.deferAttempt(key: "synthetic-old", at: now)
        let before = await backoff.permits(key: "synthetic-old", at: now.addingTimeInterval(899))
        let other = await backoff.permits(key: "synthetic-new", at: now)
        let expired = await backoff.permits(key: "synthetic-old", at: now.addingTimeInterval(900))
        XCTAssertFalse(before)
        XCTAssertTrue(other)
        XCTAssertTrue(expired)
    }

    func testFirstPartyEarlyRenewalWindowAvoidsOldTokenZeroResponse() async throws {
        let token = CursorSessionRegressionTests.token(expiration: Int(Date().timeIntervalSince1970) + 5 * 86_400)
        let fixture = CursorRenewalFixture(accessToken: token)
        let result = try await fixture.fetch()
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(result.bars.map(\.used), [0.1, 13])
        XCTAssertEqual(fixture.state.paths.first, "token")
        XCTAssertEqual(fixture.state.refreshCount, 1)
    }

    func testFailedEarlyRenewalStillAcceptsValidPrimaryZero() async throws {
        let token = CursorSessionRegressionTests.token(expiration: Int(Date().timeIntervalSince1970) + 5 * 86_400)
        let fixture = CursorRenewalFixture(accessToken: token)
        fixture.state.refreshReply = (401, "{}")
        let result = try await fixture.fetch()
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(result.bars.map(\.used), [0, 0])
        XCTAssertEqual(fixture.state.refreshCount, 1)
        XCTAssertEqual(try fixture.saved(), fixture.original)
        let repeated = try await fixture.fetch()
        XCTAssertNil(repeated.failureMessage)
        XCTAssertEqual(repeated.bars.map(\.used), [0, 0])
        XCTAssertEqual(fixture.state.refreshCount, 1, "Automatic refresh must back off the rejected early grant")
    }

    func testRenewalWithoutAuthIDKeepsCacheIdentity() async throws {
        let fixture = CursorRenewalFixture()
        let original = CursorWebAuthResult(accessToken: CursorSessionRegressionTests.token(expiration: 1),
                                          refreshToken: "synthetic-refresh", authID: nil, userID: nil).storedCredential
        try fixture.secrets.saveSecret(original, account: fixture.key)
        let before = try XCTUnwrap(CursorSessionCredential(storedSecret: original))
        _ = try await fixture.fetch()
        let after = try XCTUnwrap(CursorSessionCredential(storedSecret: try XCTUnwrap(fixture.saved())))
        XCTAssertEqual(after.cacheIdentity, before.cacheIdentity)
        let withUser = CursorWebAuthResult(accessToken: "synthetic-a", refreshToken: nil, authID: nil, userID: "saved-user")
        let otherToken = CursorWebAuthResult(accessToken: "synthetic-b", refreshToken: nil, authID: nil, userID: "saved-user")
        XCTAssertEqual(CursorSessionCredential(storedSecret: withUser.storedCredential)?.cacheIdentity,
                       CursorSessionCredential(storedSecret: otherToken.storedCredential)?.cacheIdentity)
    }

    func testFailedEarlyRenewalAndPrimaryRejectionCannotRepeatGrant() async throws {
        let token = CursorSessionRegressionTests.token(expiration: Int(Date().timeIntervalSince1970) + 5 * 86_400)
        let fixture = CursorRenewalFixture(accessToken: token)
        fixture.state.refreshReply = (401, "{}")
        fixture.state.rejectOldToken = true
        let result = try await fixture.fetch()
        XCTAssertEqual(result.recoveryAction, .reauthenticate)
        XCTAssertEqual(fixture.state.refreshCount, 1)
        XCTAssertEqual(fixture.state.paths.first, "token")
        XCTAssertEqual(fixture.state.paths.filter { $0 == "GetCurrentPeriodUsage" }.count, 1)
    }

    func testExplicitLogoutDuringEarlyRenewalCannotAcceptZeroQuota() async throws {
        let token = CursorSessionRegressionTests.token(expiration: Int(Date().timeIntervalSince1970) + 5 * 86_400)
        let fixture = CursorRenewalFixture(accessToken: token)
        for body in [
            #"{"shouldLogout":true,"error":"synthetic-rejection"}"#,
            #"{"shouldLogout":true,"access_token":true,"error":{"code":"synthetic"}}"#,
        ] {
            fixture.state.refreshReply = (200, body)
            let result = try await fixture.fetch()
            XCTAssertNotNil(result.failureMessage)
            XCTAssertEqual(result.recoveryAction, .reauthenticate)
            XCTAssertFalse(fixture.state.paths.contains("GetCurrentPeriodUsage"))
            XCTAssertEqual(try fixture.saved(), fixture.original)
        }
    }

    func testInFlightCancellationCannotRotateCredentials() async throws {
        let fixture = CursorRenewalFixture()
        let gate = AsyncStream.makeStream(of: Void.self)
        let task = Task {
            for await _ in gate.stream { break }
            return try await fixture.fetch()
        }
        fixture.state.onRefresh = { task.cancel() }
        gate.continuation.yield(())
        gate.continuation.finish()
        let result = try await task.value
        XCTAssertNotNil(result.failureMessage)
        XCTAssertEqual(try fixture.saved(), fixture.original)
        XCTAssertFalse(fixture.state.paths.contains("GetCurrentPeriodUsage"))
    }

    func testFirstPartyNoRotatedGrantStoresNewAccessAsNextGrant() async throws {
        let fixture = CursorRenewalFixture()
        fixture.state.refreshReply = (200, "{\"access_token\":\"\(fixture.freshToken)\"}")
        let result = try await fixture.fetch()
        XCTAssertNil(result.failureMessage)
        let saved = try XCTUnwrap(CursorSessionCredential(storedSecret: try XCTUnwrap(fixture.saved())))
        XCTAssertEqual(saved.refreshToken, fixture.freshToken)
    }

    func testExpiredSessionIsRenewedBeforeReadingQuota() async throws {
        let fixture = CursorRenewalFixture()
        let result = try await fixture.fetch()
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(result.bars.map(\.used), [0.1, 13])
        XCTAssertEqual(fixture.state.refreshCount, 1)
        XCTAssertEqual(CursorUsageProvider.normalizedAccessToken(from: try fixture.saved()), fixture.freshToken)
        XCTAssertEqual(fixture.state.paths.first, "token")
    }

    func testRejectedSessionRenewsAndRetriesOnce() async throws {
        let fixture = CursorRenewalFixture(expired: false)
        fixture.state.rejectOldToken = true
        let result = try await fixture.fetch()
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(result.bars.map(\.used), [0.1, 13])
        XCTAssertEqual(fixture.state.refreshCount, 1)
        XCTAssertEqual(fixture.state.paths.filter { $0 == "GetCurrentPeriodUsage" }.count, 2)
    }

    func testRenewalFailuresKeepCredentialAndOfferReconnect() async throws {
        let replies = [
            (401, "{}"), (200, #"{"shouldLogout":true}"#), (200, "{}"), (500, "{}"),
            (200, #"{"access_token":true}"#), (200, #"{"access_token":"synthetic poisoned token"}"#),
        ]
        for reply in replies {
            let fixture = CursorRenewalFixture()
            fixture.state.refreshReply = reply
            let result = try await fixture.fetch()
            XCTAssertNotNil(result.failureMessage)
            XCTAssertEqual(result.recoveryAction, .reauthenticate)
            XCTAssertTrue(result.bars.isEmpty)
            XCTAssertEqual(try fixture.saved(), fixture.original)
            XCTAssertFalse(fixture.state.paths.contains("GetCurrentPeriodUsage"))
        }
    }

    func testOldRenewalCannotOverwriteAReconnectedAccount() async throws {
        let fixture = CursorRenewalFixture()
        fixture.state.onRefresh = {
            try? fixture.secrets.saveSecret("synthetic-new-account", account: fixture.key)
        }
        let result = try await fixture.fetch()
        XCTAssertNotNil(result.failureMessage)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(try fixture.saved(), "synthetic-new-account")
        XCTAssertFalse(fixture.state.paths.contains("GetCurrentPeriodUsage"))
    }

    func testCancellationDoesNotRotateOrPublishUsage() async throws {
        let fixture = CursorRenewalFixture()
        let task = Task { try await fixture.fetch() }
        task.cancel()
        let result = try await task.value
        XCTAssertNotNil(result.failureMessage)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(try fixture.saved(), fixture.original)
    }
}

private final class CursorRenewalFixture: @unchecked Sendable {
    let state = CursorRenewalState()
    let secrets = GrokTestSecrets()
    let configuration: ProviderAccountConfiguration
    let freshToken = CursorSessionRegressionTests.token(expiration: 2_524_608_000)
    let original: String
    var key: String { ProviderConfigurationStore.keychainAccount(for: configuration) }
    let session: URLSession

    init(expired: Bool = true, accessToken: String? = nil) {
        configuration = ProviderAccountConfiguration(
            id: "cursor-renewal-\(UUID().uuidString)", providerID: .cursor,
            accountLabel: "Synthetic Cursor", authMethod: .browserSession
        )
        let token = accessToken ?? (expired ? CursorSessionRegressionTests.token(expiration: 1) : "synthetic-rejected-token")
        original = CursorWebAuthResult(
            accessToken: token, refreshToken: "synthetic-refresh", authID: "synthetic-owner", userID: nil
        ).storedCredential
        state.freshToken = freshToken
        state.refreshReply = (200, "{\"access_token\":\"\(freshToken)\",\"refresh_token\":\"synthetic-rotated-refresh\"}")
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [CursorRenewalReplay.self]
        session = URLSession(configuration: settings)
        CursorRenewalReplay.state = state
        try? secrets.saveSecret(original, account: ProviderConfigurationStore.keychainAccount(for: configuration))
    }

    deinit { session.invalidateAndCancel() }
    func saved() throws -> String? { try secrets.readSecret(account: key) }
    func fetch() async throws -> ProviderUsageResult {
        try await CursorUsageProvider(secretStore: secrets, session: session).fetchUsage(for: configuration)
    }
}

private final class CursorRenewalReplay: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var state = CursorRenewalState()
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let reply = Self.state.reply(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class CursorRenewalState: @unchecked Sendable {
    private let lock = NSLock()
    var freshToken = ""
    var rejectOldToken = false
    var refreshReply = (200, "{}")
    var onRefresh: (@Sendable () -> Void)?
    private var recordedPaths: [String] = []
    var paths: [String] { lock.withLock { recordedPaths } }
    var refreshCount: Int { paths.filter { $0 == "token" }.count }
    func reply(_ request: URLRequest) -> (Int, String) {
        let path = request.url!.lastPathComponent
        lock.withLock { recordedPaths.append(path) }
        if path == "token" { onRefresh?(); return refreshReply }
        guard path == "GetCurrentPeriodUsage" else { return (403, "{}") }
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer \(freshToken)" {
            return (200, #"{"planUsage":{"autoPercentUsed":0.1,"apiPercentUsed":13}}"#)
        }
        return rejectOldToken ? (401, "{}") : (200, #"{"planUsage":{"autoPercentUsed":0,"apiPercentUsed":0}}"#)
    }
}
