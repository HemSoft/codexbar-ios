import Foundation
import XCTest
@testable import CodexBarIOS

final class CursorSessionRegressionTests: XCTestCase, @unchecked Sendable {
    func testExpiredCredentialDoesNotAcceptSuccessfulZeroQuotaResponse() async throws {
        let result = try await fetch(token: Self.token(expiration: 1), primaryStatus: 200)
        XCTAssertNotNil(result.failureMessage)
        XCTAssertEqual(result.recoveryAction, .reauthenticate)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertFalse(CursorSessionReplay.state.requests.contains {
            $0.url?.lastPathComponent == "GetCurrentPeriodUsage"
        })
    }

    func testPrimaryRejectionOffersReconnectInsteadOfRetry() async throws {
        for status in [401, 403] {
            let result = try await fetch(token: "synthetic-unstructured-token", primaryStatus: status)
            XCTAssertEqual(result.recoveryAction, .reauthenticate)
            XCTAssertTrue(result.bars.isEmpty)
        }
    }

    func testFreshZeroWithBotRejectionIsNotAnAuthenticationFailure() async throws {
        let result = try await fetch(token: Self.token(expiration: 2_524_608_000), primaryStatus: 200)
        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(result.bars.map(\.usageText), ["0%", "0%"])
        XCTAssertEqual(result.configurableMetrics.count, 4)
        XCTAssertNotEqual(result.recoveryAction, .reauthenticate)
    }

    private func fetch(token: String, primaryStatus: Int) async throws -> ProviderUsageResult {
        CursorSessionReplay.state.reset(status: primaryStatus)
        let settings = URLSessionConfiguration.ephemeral
        settings.protocolClasses = [CursorSessionReplay.self]
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        let configuration = ProviderAccountConfiguration(
            id: "cursor-session-regression", providerID: .cursor,
            accountLabel: "Synthetic Cursor", authMethod: .browserSession
        )
        let secrets = GrokTestSecrets()
        try secrets.saveSecret(token, account: ProviderConfigurationStore.keychainAccount(for: configuration))
        return try await CursorUsageProvider(secretStore: secrets, session: session).fetchUsage(for: configuration)
    }

    static func token(expiration: Int) -> String {
        let payload = Data("{\"exp\":\(expiration),\"sub\":\"synthetic-subject\"}".utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJIUzI1NiJ9.\(payload).synthetic-signature"
    }
}

private final class CursorSessionReplay: URLProtocol, @unchecked Sendable {
    static let state = CursorSessionReplayState()
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        let status = Self.state.record(request)
        let body = status == 200 ? #"{"planUsage":{"autoPercentUsed":0,"apiPercentUsed":0}}"# : "{}"
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class CursorSessionReplayState: @unchecked Sendable {
    private let lock = NSLock()
    private var primaryStatus = 200
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.withLock { recorded } }
    func reset(status: Int) { lock.withLock { primaryStatus = status; recorded = [] } }
    func record(_ request: URLRequest) -> Int {
        lock.withLock {
            recorded.append(request)
            return request.url?.lastPathComponent == "GetCurrentPeriodUsage" ? primaryStatus : 403
        }
    }
}
