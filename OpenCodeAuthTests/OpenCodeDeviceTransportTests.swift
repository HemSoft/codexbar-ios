import Foundation
import XCTest
@testable import CodexBarIOS

final class OpenCodeDeviceTransportTests: XCTestCase, @unchecked Sendable {
    func testApprovalPollsPendingSlowsDownAndVerifiesScopedIdentity() async throws {
        let service = makeService([
            (200, #"{"device_code":"synthetic-device","verification_uri_complete":"/console/device?user_code=TEST","expires_in":900,"interval":5}"#),
            (400, #"{"error":"authorization_pending"}"#),
            (400, #"{"error":"slow_down"}"#),
            (200, #"{"access_token":"synthetic-access","refresh_token":"synthetic-refresh","token_type":"Bearer","expires_in":3600,"org_id":"wrk_one"}"#),
            (200, #"{"user":{"id":"user_one"},"org_id":"wrk_one"}"#),
        ])
        defer { service.session.invalidateAndCancel() }
        let authorization = try await service.begin()
        let delays = AuthRecordedDelays()
        let credential = try await service.authorize(authorization, sleep: { await delays.append($0) })
        XCTAssertEqual(credential.workspaceID, "wrk_one")
        XCTAssertEqual(credential.userID, "user_one")
        let recorded = await delays.values
        XCTAssertEqual(recorded, [5, 5, 10])
        let requests = AuthTestURLProtocol.state.requests
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/console/auth/device/code", "/console/auth/device/token", "/console/auth/device/token",
            "/console/auth/device/token", "/console/auth/session",
        ])
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-access")
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
    }

    func testDeniedExpiredAndNetworkFailureDoNotProduceCredentials() async throws {
        for (status, body) in [
            (400, #"{"error":"access_denied"}"#), (400, #"{"error":"expired_token"}"#),
            (500, #"{"error":"authorization_pending"}"#),
        ] {
            let service = makeService([(status, body)])
            defer { service.session.invalidateAndCancel() }
            do {
                _ = try await service.authorize(authorization(), sleep: { _ in })
                XCTFail("A failed approval must not produce credentials")
            } catch { XCTAssertTrue(error is OpenCodeSignInError) }
        }
    }

    func testCancellationStopsPollingBeforeAnyTokenRequest() async throws {
        let service = makeService([])
        defer { service.session.invalidateAndCancel() }
        do {
            _ = try await service.authorize(authorization(), sleep: { _ in throw CancellationError() })
            XCTFail("Canceled authorization should throw")
        } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(AuthTestURLProtocol.state.requests.isEmpty)
    }

    func testIdentityCannotReplaceTheApprovedWorkspace() async throws {
        let service = makeService([
            (200, #"{"access_token":"synthetic-access","refresh_token":"synthetic-refresh","token_type":"Bearer","expires_in":3600,"org_id":"wrk_one"}"#),
            (200, #"{"user":{"id":"user_one"},"org_id":"wrk_other"}"#),
        ])
        defer { service.session.invalidateAndCancel() }
        do {
            _ = try await service.authorize(authorization(), sleep: { _ in })
            XCTFail("Mismatched workspace identity must fail")
        } catch { XCTAssertTrue(error is OpenCodeSignInError) }
    }

    func testRefreshPreservesAccountScopeAndIndependentBalanceSuccess() async throws {
        let (configuration, credential, secrets) = try expiredAccount()
        AuthTestURLProtocol.state.reset { request in
            switch request.url?.lastPathComponent {
            case "token": return (200, Self.refreshedToken)
            default:
                XCTAssertEqual(request.value(forHTTPHeaderField: "x-org-id"), "wrk_one")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer renewed-access")
                return request.url?.path.contains("/billing/") == true
                    ? (200, #"{"balanceMicroCents":"2500000000"}"#) : (503, "{}")
            }
        }
        let provider = OpenCodeConsoleUsageProvider(secretStore: secrets, makeSession: Self.mockSession)
        let result = await provider.fetchUsage(credential: credential, configuration: configuration)
        XCTAssertEqual(result.creditsRemaining, 25)
        XCTAssertTrue(result.hasCurrentCredits)
        XCTAssertTrue(result.bars.isEmpty)
        let saved = try secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration))
        XCTAssertEqual(OpenCodeConsoleCredential.parse(saved)?.accessToken, "renewed-access")
    }

    func testCacheIdentitySurvivesTokenRenewal() async throws {
        let (configuration, expired, secrets) = try expiredAccount()
        let valid = OpenCodeConsoleCredential(
            kind: expired.kind, accessToken: expired.accessToken, refreshToken: expired.refreshToken,
            expiresAt: Date().addingTimeInterval(3600), workspaceID: expired.workspaceID, userID: expired.userID
        )
        let account = ProviderConfigurationStore.keychainAccount(for: configuration)
        try secrets.saveSecret(valid.encoded(), account: account)
        AuthTestURLProtocol.state.reset(handler: Self.balanceOnlyResponse)
        let provider = OpenCodeConsoleUsageProvider(secretStore: secrets, makeSession: Self.mockSession)
        let before = await provider.fetchUsage(credential: valid, configuration: configuration)
        try secrets.saveSecret(expired.encoded(), account: account)
        AuthTestURLProtocol.state.reset { request in
            request.url?.lastPathComponent == "token" ? (200, Self.refreshedToken) : Self.balanceOnlyResponse(request)
        }
        let after = await provider.fetchUsage(credential: expired, configuration: configuration)
        XCTAssertNotNil(before.cacheIdentity)
        XCTAssertEqual(before.cacheIdentity, after.cacheIdentity)
        XCTAssertTrue(after.preserveCachedBarsOnFailure)
    }

    func testTransientRenewalFailureUsesTheStillSavedValidToken() async throws {
        let (configuration, expired, secrets) = try expiredAccount()
        let valid = OpenCodeConsoleCredential(
            kind: expired.kind, accessToken: expired.accessToken, refreshToken: expired.refreshToken,
            expiresAt: Date().addingTimeInterval(30), workspaceID: expired.workspaceID, userID: expired.userID
        )
        let account = ProviderConfigurationStore.keychainAccount(for: configuration)
        try secrets.saveSecret(valid.encoded(), account: account)
        AuthTestURLProtocol.state.reset { request in
            request.url?.lastPathComponent == "token" ? (503, "{}") : Self.balanceOnlyResponse(request)
        }
        let provider = OpenCodeConsoleUsageProvider(secretStore: secrets, makeSession: Self.mockSession)
        let result = await provider.fetchUsage(credential: valid, configuration: configuration)
        XCTAssertEqual(result.creditsRemaining, 25)
        XCTAssertTrue(result.hasCurrentCredits)
        XCTAssertEqual(OpenCodeConsoleCredential.parse(try secrets.readSecret(account: account)), valid)
    }

    func testRenewalFallbackRejectsRemovedReplacedExpiredAndRejectedCredentials() async throws {
        for scenario in ["removed", "replaced", "expired", "rejected"] {
            let (configuration, original, secrets) = try expiredAccount()
            let credential = OpenCodeConsoleCredential(
                kind: original.kind, accessToken: original.accessToken, refreshToken: original.refreshToken,
                expiresAt: Date().addingTimeInterval(scenario == "expired" ? -1 : 30),
                workspaceID: original.workspaceID, userID: original.userID
            )
            let account = ProviderConfigurationStore.keychainAccount(for: configuration)
            try secrets.saveSecret(credential.encoded(), account: account)
            AuthTestURLProtocol.state.reset { _ in
                if scenario == "removed" { try? secrets.deleteSecret(account: account) }
                if scenario == "replaced" { try? secrets.saveSecret("different-account-session", account: account) }
                return (scenario == "rejected" ? 401 : 503, "{}")
            }
            let provider = OpenCodeConsoleUsageProvider(secretStore: secrets, makeSession: Self.mockSession)
            let result = await provider.fetchUsage(credential: credential, configuration: configuration)
            XCTAssertNotNil(result.failureMessage, scenario)
            XCTAssertFalse(result.hasCurrentCredits, scenario)
            XCTAssertEqual(AuthTestURLProtocol.state.requests.count, 1, scenario)
        }
    }

    private static func balanceOnlyResponse(_ request: URLRequest) -> (Int, String) {
        request.url?.path.contains("/billing/") == true ? (200, #"{"balanceMicroCents":"2500000000"}"#) : (503, "{}")
    }

    func testRemovedOrUnsavableCredentialsCannotBeRestoredByRefresh() async throws {
        for removeDuringRequest in [false, true] {
            let (configuration, credential, secrets) = try expiredAccount()
            let account = ProviderConfigurationStore.keychainAccount(for: configuration)
            secrets.setFailure(!removeDuringRequest)
            AuthTestURLProtocol.state.reset { _ in
                if removeDuringRequest { try? secrets.deleteSecret(account: account) }
                return (200, Self.refreshedToken)
            }
            let provider = OpenCodeConsoleUsageProvider(secretStore: secrets, makeSession: Self.mockSession)
            let result = await provider.fetchUsage(credential: credential, configuration: configuration)
            XCTAssertNotNil(result.failureMessage)
            XCTAssertFalse(result.hasCurrentCredits)
            XCTAssertEqual(AuthTestURLProtocol.state.requests.count, 1)
            let saved = try secrets.readSecret(account: account)
            if removeDuringRequest { XCTAssertNil(saved) } else {
                XCTAssertEqual(OpenCodeConsoleCredential.parse(saved), credential)
            }
        }
    }

    private static let refreshedToken = #"""
    {"access_token":"renewed-access","refresh_token":"renewed-refresh",
     "token_type":"Bearer","expires_in":3600,"org_id":"wrk_one"}
    """#

    private func expiredAccount() throws -> (ProviderAccountConfiguration, OpenCodeConsoleCredential, OpenCodeTestSecrets) {
        var configuration = ProviderAccountConfiguration(id: UUID().uuidString, providerID: .openCodeZen, authMethod: .browserSession)
        configuration.openCodeWorkspaceId = "wrk_one"
        let credential = OpenCodeConsoleCredential(
            kind: "opencode-console-v1", accessToken: "expired", refreshToken: "synthetic-refresh",
            expiresAt: Date(timeIntervalSince1970: 0), workspaceID: "wrk_one", userID: "user_one"
        )
        let secrets = OpenCodeTestSecrets()
        try secrets.saveSecret(credential.encoded(), account: ProviderConfigurationStore.keychainAccount(for: configuration))
        return (configuration, credential, secrets)
    }

    private static func mockSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthTestURLProtocol.self]
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    private func authorization() -> OpenCodeDeviceAuthorization {
        OpenCodeDeviceAuthorization(
            deviceCode: "synthetic-device", verificationURL: URL(string: "https://opencode.ai/console/device")!,
            expiresAt: Date().addingTimeInterval(900), interval: 5
        )
    }

    private func makeService(_ responses: [(Int, String)]) -> OpenCodeDeviceAuthService {
        AuthTestURLProtocol.state.reset(responses)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AuthTestURLProtocol.self]
        configuration.httpCookieStorage = nil
        return OpenCodeDeviceAuthService(session: URLSession(configuration: configuration))
    }
}

private actor AuthRecordedDelays {
    var values: [TimeInterval] = []
    func append(_ value: TimeInterval) { values.append(value) }
}

private final class AuthTestURLProtocol: URLProtocol, @unchecked Sendable {
    static let state = AuthProtocolState()
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let response = Self.state.next(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.0, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class AuthProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Int, String)] = []
    private var recorded: [URLRequest] = []
    private var handler: (@Sendable (URLRequest) -> (Int, String)?)?
    var requests: [URLRequest] { lock.withLock { recorded } }
    func reset(_ responses: [(Int, String)]) {
        lock.withLock { self.responses = responses; recorded = []; handler = nil }
    }
    func reset(handler: @escaping @Sendable (URLRequest) -> (Int, String)?) {
        lock.withLock { responses = []; recorded = []; self.handler = handler }
    }
    func next(_ request: URLRequest) -> (Int, String)? {
        lock.withLock {
            recorded.append(request)
            if let handler { return handler(request) }
            return responses.isEmpty ? nil : responses.removeFirst()
        }
    }
}
