import Foundation
import XCTest
@testable import CodexBarIOS

final class GrokTransportTests: XCTestCase, @unchecked Sendable {
    func testDeviceApprovalVerifiesIdentityWithoutSendingCookiesOrKeys() async throws {
        let service = makeService([
            (200, #"{"device_code":"synthetic","verification_uri_complete":"https://accounts.x.ai/oauth2/device?user_code=TEST","expires_in":1800,"interval":5}"#),
            (400, #"{"error":"authorization_pending"}"#),
            (400, #"{"error":"slow_down"}"#),
            (429, "{}"),
            (503, "{}"),
            (200, "{not-json"),
            (400, "{not-json"),
            (0, ""),
            (200, #"{"access_token":"access-one","refresh_token":"refresh-one","token_type":"Bearer","expires_in":3600}"#),
            (200, #"{"sub":"subject-one","email":"fixture@example.invalid"}"#),
        ])
        defer { service.session.invalidateAndCancel() }
        let challenge = try await service.begin()
        let delays = GrokDelayRecorder()
        let credential = try await service.authorize(challenge, sleep: { await delays.record($0) })
        XCTAssertEqual(credential.subject, "subject-one")
        XCTAssertEqual(credential.email, "fixture@example.invalid")
        let recordedDelays = await delays.values
        XCTAssertEqual(recordedDelays, [5, 5, 10, 15, 20, 25, 30, 35])
        let requests = GrokTestProtocol.state.requests
        XCTAssertEqual(requests.map { $0.url?.path }, [
            "/oauth2/device/code", "/oauth2/token", "/oauth2/token", "/oauth2/token",
            "/oauth2/token", "/oauth2/token", "/oauth2/token", "/oauth2/token",
            "/oauth2/token", "/oauth2/userinfo",
        ])
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer access-one")
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
        XCTAssertTrue(requests.allSatisfy { $0.url?.host == "auth.x.ai" })
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
        XCTAssertTrue(GrokDeviceAuthService.scope.contains("api:access"))
    }

    func testRefusalStopsWithoutIdentityOrBilling() async throws {
        let service = makeService([(400, #"{"error":"access_denied"}"#)])
        defer { service.session.invalidateAndCancel() }
        let challenge = GrokDeviceChallenge(
            code: "synthetic", approvalURL: URL(string: "https://accounts.x.ai/oauth2/device")!,
            expiresAt: Date().addingTimeInterval(1800), interval: 5
        )
        do {
            _ = try await service.authorize(challenge, sleep: { _ in })
            XCTFail("A refusal must stop authorization")
        } catch GrokAuthError.denied {
            XCTAssertEqual(GrokTestProtocol.state.requests.count, 1)
        }
    }

    func testCandidateRequiresMatchingVerifiedSubjectBeforeReadingBilling() async throws {
        let credential = GrokCredential(
            kind: "grok-oauth-v1", accessToken: "access-one", refreshToken: "refresh-one",
            expiresAt: Date().addingTimeInterval(3600), subject: "subject-one", email: nil
        )
        let session = makeSession([(200, #"{"sub":"subject-two"}"#)])
        defer { session.invalidateAndCancel() }
        let provider = GrokUsageProvider(session: session)
        do {
            _ = try await provider.fetchCandidate(credential, for: .defaultConfiguration(for: .grok))
            XCTFail("A changed identity must not fetch another account's usage")
        } catch GrokAuthError.unauthorized {
            XCTAssertEqual(GrokTestProtocol.state.requests.count, 1)
        }
    }

    func testCandidateReportsTemporaryProviderOutageWithoutSavingAConnection() async throws {
        let credential = GrokCredential(
            kind: "grok-oauth-v1", accessToken: "access", refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600), subject: "subject", email: nil
        )
        let session = makeSession([(200, #"{"sub":"subject"}"#), (503, "{}")])
        defer { session.invalidateAndCancel() }
        let provider = GrokUsageProvider(session: session)
        do {
            _ = try await provider.fetchCandidate(credential, for: .defaultConfiguration(for: .grok))
            XCTFail("A provider outage is not an unsupported account")
        } catch GrokAuthError.temporarilyUnavailable {
            XCTAssertEqual(GrokTestProtocol.state.requests.count, 2)
        }
        let identityOutage = makeSession([(503, "{}")])
        defer { identityOutage.invalidateAndCancel() }
        do {
            _ = try await GrokUsageProvider(session: identityOutage)
                .fetchCandidate(credential, for: .defaultConfiguration(for: .grok))
            XCTFail("A userinfo outage is not rejected authorization")
        } catch GrokAuthError.temporarilyUnavailable {
            XCTAssertEqual(GrokTestProtocol.state.requests.count, 1)
        }
    }

    @MainActor
    func testTransientFailuresOfferRetryButRejectedTokensOfferReconnect() async throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = GrokTestSecrets()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        let account = store.addAccount(for: .grok)
        let key = ProviderConfigurationStore.keychainAccount(for: account)
        let credential = GrokCredential(
            kind: "grok-oauth-v1", accessToken: "access", refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(3600), subject: "subject", email: nil
        )
        try secrets.saveSecret(credential.encoded(), account: key)
        let unavailable = makeSession([(429, "{}")])
        let retryUserInfo = try await GrokUsageProvider(secretStore: secrets, session: unavailable).fetchUsage(for: account)
        XCTAssertEqual(retryUserInfo.recoveryAction, .retryRefresh)
        unavailable.invalidateAndCancel()

        let billingOutage = makeSession([(200, #"{"sub":"subject"}"#), (503, "{}")])
        let retryBilling = try await GrokUsageProvider(secretStore: secrets, session: billingOutage).fetchUsage(for: account)
        XCTAssertEqual(retryBilling.recoveryAction, .retryRefresh)
        billingOutage.invalidateAndCancel()

        let rejected = makeSession([(401, "{}")])
        let reconnect = try await GrokUsageProvider(secretStore: secrets, session: rejected).fetchUsage(for: account)
        XCTAssertEqual(reconnect.recoveryAction, .reauthenticate)
        rejected.invalidateAndCancel()

        let expired = GrokCredential(
            kind: credential.kind, accessToken: credential.accessToken, refreshToken: credential.refreshToken,
            expiresAt: Date().addingTimeInterval(-10), subject: credential.subject, email: nil
        )
        try secrets.saveSecret(expired.encoded(), account: key)
        let renewalOutage = makeSession([(503, "{}")])
        let retryRenewal = try await GrokUsageProvider(secretStore: secrets, session: renewalOutage).fetchUsage(for: account)
        XCTAssertEqual(retryRenewal.recoveryAction, .retryRefresh)
        renewalOutage.invalidateAndCancel()

        let malformedRenewal = makeSession([(200, "{not-json")])
        let retryMalformed = try await GrokUsageProvider(secretStore: secrets, session: malformedRenewal).fetchUsage(for: account)
        XCTAssertEqual(retryMalformed.recoveryAction, .retryRefresh)
        malformedRenewal.invalidateAndCancel()

        let rejectedRenewal = makeSession([
            (200, #"{"access_token":"renewed","token_type":"Bearer","expires_in":3600}"#),
            (401, "{}"),
        ])
        let reconnectRenewal = try await GrokUsageProvider(secretStore: secrets, session: rejectedRenewal).fetchUsage(for: account)
        XCTAssertEqual(reconnectRenewal.recoveryAction, .reauthenticate)
        rejectedRenewal.invalidateAndCancel()
    }

    @MainActor
    func testRenewalWithoutRotatedRefreshTokenKeepsSameAccountAndZeroUsage() async throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = GrokTestSecrets()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        let account = store.addAccount(for: .grok)
        let key = ProviderConfigurationStore.keychainAccount(for: account)
        let old = GrokCredential(
            kind: "grok-oauth-v1", accessToken: "old-access", refreshToken: "old-refresh",
            expiresAt: Date().addingTimeInterval(-10), subject: "subject-one", email: nil
        )
        try secrets.saveSecret(old.encoded(), account: key)
        let start = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-86_400))
        let end = ISO8601DateFormatter().string(from: Date().addingTimeInterval(86_400))
        let billing = """
            {"config":{"isUnifiedBillingUser":true,"creditUsagePercent":0,
            "currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"\(start)","end":"\(end)"}}}
            """
        let session = makeSession([
            (200, #"{"access_token":"new-access","token_type":"Bearer","expires_in":3600}"#),
            (200, #"{"sub":"subject-one"}"#),
            (200, #"{"sub":"subject-one"}"#),
            (200, billing),
        ])
        defer { session.invalidateAndCancel() }
        let result = try await GrokUsageProvider(secretStore: secrets, session: session).fetchUsage(for: account)
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(result.bars.first?.used, 0)
        let saved = try XCTUnwrap(GrokCredential.parse(try secrets.readSecret(account: key)))
        XCTAssertEqual(saved.refreshToken, old.refreshToken)
        XCTAssertEqual(saved.subject, old.subject)
        XCTAssertEqual(saved.accessToken, "new-access")
        XCTAssertEqual(GrokTestProtocol.state.requests.last?.url?.host, "cli-chat-proxy.grok.com")
    }

    @MainActor
    func testRemovalDuringBillingCannotPublishAnOldAccountResult() async throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = GrokTestSecrets()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        let account = store.addAccount(for: .grok)
        let stored = GrokCredential(
            kind: "grok-oauth-v1", accessToken: "old-access", refreshToken: "old-refresh",
            expiresAt: Date().addingTimeInterval(3600), subject: "subject-one", email: nil
        )
        let key = ProviderConfigurationStore.keychainAccount(for: account)
        try secrets.saveSecret(stored.encoded(), account: key)
        let billingStarted = expectation(description: "billing request started")
        let allowBilling = DispatchSemaphore(value: 0)
        let session = makeSession([])
        GrokTestProtocol.state.reset(handler: { request in
            if request.url?.path == "/v1/billing" {
                billingStarted.fulfill()
                _ = allowBilling.wait(timeout: .now() + 5)
                return (200, #"{"config":{"creditUsagePercent":31}}"#)
            }
            return (200, #"{"sub":"subject-one"}"#)
        })
        defer { session.invalidateAndCancel() }
        let provider = GrokUsageProvider(secretStore: secrets, session: session)
        let task = Task { try await provider.fetchUsage(for: account) }
        await fulfillment(of: [billingStarted], timeout: 5)
        XCTAssertTrue(store.removeAccount(account))
        allowBilling.signal()
        let result = try await task.value
        XCTAssertNotNil(result.failureMessage)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertNil(try secrets.readSecret(account: key))
    }

    @MainActor
    func testRemovalDuringRenewalCannotRestoreAnOldCredential() async throws {
        try await assertCredentialStaysRemovedDuringRenewal(resetAll: false)
    }

    @MainActor
    func testResetDuringRenewalCannotRestoreAnOldCredential() async throws {
        try await assertCredentialStaysRemovedDuringRenewal(resetAll: true)
    }

    @MainActor
    private func assertCredentialStaysRemovedDuringRenewal(resetAll: Bool) async throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = GrokTestSecrets()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        let account = store.addAccount(for: .grok)
        let stored = GrokCredential(
            kind: "grok-oauth-v1", accessToken: "old-access", refreshToken: "old-refresh",
            expiresAt: Date().addingTimeInterval(-10), subject: "subject-one", email: nil
        )
        let key = ProviderConfigurationStore.keychainAccount(for: account)
        try secrets.saveSecret(stored.encoded(), account: key)
        let refreshStarted = expectation(description: "renewal request started")
        let allowRefresh = DispatchSemaphore(value: 0)
        let session = makeSession([])
        GrokTestProtocol.state.reset(handler: { request in
            if request.url?.path == "/oauth2/token" {
                refreshStarted.fulfill()
                _ = allowRefresh.wait(timeout: .now() + 5)
                return (200, #"{"access_token":"new-access","refresh_token":"new-refresh","token_type":"Bearer","expires_in":3600}"#)
            }
            return (200, #"{"sub":"subject-one"}"#)
        })
        defer { session.invalidateAndCancel() }
        let provider = GrokUsageProvider(secretStore: secrets, session: session)
        let task = Task { try await provider.fetchUsage(for: account) }
        await fulfillment(of: [refreshStarted], timeout: 5)
        if resetAll {
            XCTAssertTrue(store.resetAccounts())
        } else {
            XCTAssertTrue(store.removeAccount(account))
        }
        allowRefresh.signal()
        let result = try await task.value
        XCTAssertNotNil(result.failureMessage)
        XCTAssertNil(try secrets.readSecret(account: key))
    }

    private func makeService(_ replies: [(Int, String)]) -> GrokDeviceAuthService {
        GrokDeviceAuthService(session: makeSession(replies))
    }

    private func makeSession(_ replies: [(Int, String)]) -> URLSession {
        GrokTestProtocol.state.reset(replies)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GrokTestProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }
}

private actor GrokDelayRecorder {
    private var recorded: [TimeInterval] = []
    var values: [TimeInterval] { recorded }
    func record(_ value: TimeInterval) { recorded.append(value) }
}

private final class GrokTestProtocol: URLProtocol, @unchecked Sendable {
    static let state = GrokProtocolState()
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let reply = Self.state.next(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        if reply.0 == 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.0, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(reply.1.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class GrokProtocolState: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Int, String)] = []
    private var recorded: [URLRequest] = []
    private var handler: (@Sendable (URLRequest) -> (Int, String)?)?
    var requests: [URLRequest] { lock.withLock { recorded } }
    func reset(_ replies: [(Int, String)]) {
        lock.withLock { self.replies = replies; recorded = []; handler = nil }
    }
    func reset(handler: @escaping @Sendable (URLRequest) -> (Int, String)?) {
        lock.withLock { replies = []; recorded = []; self.handler = handler }
    }
    func next(_ request: URLRequest) -> (Int, String)? {
        lock.withLock {
            recorded.append(request)
            if let handler { return handler(request) }
            return replies.isEmpty ? nil : replies.removeFirst()
        }
    }
}
