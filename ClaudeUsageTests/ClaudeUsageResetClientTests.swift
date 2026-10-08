import Foundation
import XCTest
@testable import CodexBarIOS

final class ClaudeUsageResetClientTests: XCTestCase {
    private let account = ProviderAccountConfiguration(id: "claude.fixture", providerID: .claude, authMethod: .cliToken)
    private let now = Date(timeIntervalSince1970: 1_893_456_000)

    func testFreshVerifiedGrantProducesOneOrganizationBoundPost() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        ResetClientProtocol.configure(mode: .success)
        let outcome = try await harness.client.consume(for: account, accessToken: "fixture-token", grantID: "fixture_grant",
                                                          credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "fixture-token"))
        XCTAssertEqual(outcome, .reset)
        let requests = ResetClientProtocol.requests
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
        let post = try XCTUnwrap(requests.last)
        XCTAssertEqual(post.url?.path, "/api/organizations/00000000-0000-0000-0000-000000000002/reset_rate_limits")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(post.httpBody)) as? [String: String])
        XCTAssertEqual(body["program"], "cedar_ember")
        XCTAssertEqual(body["grant_id"], "fixture_grant")
        XCTAssertNotNil(body["request_id"].flatMap(UUID.init(uuidString:)))
        XCTAssertEqual(post.value(forHTTPHeaderField: "User-Agent"), "CodexBarIOS")
        XCTAssertTrue(requests.contains { $0.url?.query == "cedar_ember=1" })
    }

    func testExpiredIneligibleOrDifferentGrantNeverSendsPost() async throws {
        for mode in [ResetClientProtocol.Mode.ineligible, .expired, .success] {
            let harness = makeHarness()
            ResetClientProtocol.configure(mode: mode)
            do {
                _ = try await harness.client.consume(for: account, accessToken: "fixture-token",
                                                     grantID: mode == .success ? "different_grant" : "fixture_grant",
                                                     credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "fixture-token")
                )
                XCTFail("An unselected grant must not be redeemed")
            } catch {
                XCTAssertEqual(error as? ClaudeUsageResetError, .unavailable)
            }
            XCTAssertFalse(ResetClientProtocol.requests.contains { $0.httpMethod == "POST" })
            try? FileManager.default.removeItem(at: harness.directory)
        }
    }

    func testChangedCredentialAndMissingVerifiedIdentityNeverSendPost() async throws {
        for mode in [ResetClientProtocol.Mode.success, .missingIdentity, .changedIdentity] {
            let harness = makeHarness(token: mode == .success ? "replacement-token" : "fixture-token")
            ResetClientProtocol.configure(mode: mode)
            do {
                _ = try await harness.client.consume(for: account, accessToken: "fixture-token", grantID: "fixture_grant",
                                                          credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "fixture-token"))
                XCTFail("Unverified identity or replaced credentials must prevent redemption")
            } catch {
                XCTAssertTrue([ClaudeUsageResetError.credentialChanged, .unavailable].contains(error as? ClaudeUsageResetError ?? .inProgress))
            }
            XCTAssertFalse(ResetClientProtocol.requests.contains { $0.httpMethod == "POST" })
            try? FileManager.default.removeItem(at: harness.directory)
        }
    }

    func testAmbiguousPostSurvivesClientRestartWithoutAutomaticReplay() async throws {
        for mode in [ResetClientProtocol.Mode.timeout, .serverError, .malformedSuccess] {
            let harness = makeHarness()
            ResetClientProtocol.configure(mode: mode)
            do {
                _ = try await harness.client.consume(for: account, accessToken: "fixture-token", grantID: "fixture_grant",
                                                          credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "fixture-token"))
                XCTFail("An unconfirmed mutation must remain unknown")
            } catch {
                XCTAssertEqual(error as? ClaudeUsageResetError, .indeterminate)
            }
            XCTAssertEqual(ResetClientProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
            let restarted = client(session: harness.session, directory: harness.directory, token: "rotated-token")
            ResetClientProtocol.configure(mode: .success)
            do {
                _ = try await restarted.consume(for: account, accessToken: "rotated-token", grantID: "fixture_grant",
                                                          credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "rotated-token"))
                XCTFail("Token rotation cannot erase an ambiguous same-subject request")
            } catch { XCTAssertEqual(error as? ClaudeUsageResetError, .indeterminate) }
            XCTAssertFalse(ResetClientProtocol.requests.contains { $0.httpMethod == "POST" })
            ResetClientProtocol.configure(mode: .reconciled)
            let outcome = try await restarted.consume(for: account, accessToken: "rotated-token", grantID: "fixture_grant",
                                                          credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "rotated-token"))
            XCTAssertEqual(outcome, .stateChanged)
            XCTAssertFalse(ResetClientProtocol.requests.contains { $0.httpMethod == "POST" })
            let receipts = try FileManager.default.contentsOfDirectory(atPath: harness.directory.path)
            XCTAssertTrue(receipts.isEmpty)
            try? FileManager.default.removeItem(at: harness.directory)
        }
    }

    func testCorruptReceiptAndMissingGrantNeverDiscardUnconfirmedMutation() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        ResetClientProtocol.configure(mode: .timeout)
        do {
            _ = try await harness.client.consume(for: account, accessToken: "fixture-token", grantID: "fixture_grant",
                credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "fixture-token"))
            XCTFail("Timeout must remain unknown")
        } catch { XCTAssertEqual(error as? ClaudeUsageResetError, .indeterminate) }
        let files = try FileManager.default.contentsOfDirectory(at: harness.directory, includingPropertiesForKeys: nil)
        let receiptURL = try XCTUnwrap(files.first)
        let receipt = try String(contentsOf: receiptURL, encoding: .utf8)
        XCTAssertFalse(receipt.contains("fixture_grant"))
        XCTAssertFalse(receipt.contains("fixture-token"))
        XCTAssertEqual(try harness.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        for mode in [ResetClientProtocol.Mode.missingGrant, .success] {
            if mode == .success { try Data("corrupt".utf8).write(to: receiptURL, options: .atomic) }
            ResetClientProtocol.configure(mode: mode)
            do {
                _ = try await harness.client.consume(for: account, accessToken: "fixture-token", grantID: "fixture_grant",
                    credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "fixture-token"))
                XCTFail("Missing grant or unreadable receipt must not permit another POST")
            } catch { XCTAssertEqual(error as? ClaudeUsageResetError, .indeterminate) }
            XCTAssertFalse(ResetClientProtocol.requests.contains { $0.httpMethod == "POST" })
            XCTAssertTrue(FileManager.default.fileExists(atPath: receiptURL.path))
        }
    }

    func testConfirmationCredentialBindingIsRequiredBeforeAnyNetworkRequest() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        ResetClientProtocol.configure(mode: .success)
        do {
            _ = try await harness.client.consume(for: account, accessToken: "fixture-token", grantID: "fixture_grant",
                credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "previous-account-token"))
            XCTFail("A previous account's confirmation cannot spend the current account's reset")
        } catch { XCTAssertEqual(error as? ClaudeUsageResetError, .credentialChanged) }
        XCTAssertTrue(ResetClientProtocol.requests.isEmpty)
    }

    func testConcurrentConfirmationCannotSendDuplicatePost() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        ResetClientProtocol.configure(mode: .delayed)
        let account = self.account
        let binding = ClaudeUsageResetClient.credentialBinding(for: "fixture-token")
        let first = Task {
            try await harness.client.consume(for: account, accessToken: "fixture-token", grantID: "fixture_grant",
                                             credentialBinding: binding)
        }
        for _ in 0..<100 where ResetClientProtocol.requests.isEmpty {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(ResetClientProtocol.requests.isEmpty)
        do {
            _ = try await harness.client.consume(for: account, accessToken: "fixture-token", grantID: "fixture_grant",
                                                credentialBinding: binding)
            XCTFail("A simultaneous confirmation must not start another request")
        } catch { XCTAssertEqual(error as? ClaudeUsageResetError, .inProgress) }
        let outcome = try await first.value
        XCTAssertEqual(outcome, .reset)
        XCTAssertEqual(ResetClientProtocol.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testUncertainReceiptDoesNotLeakAcrossVerifiedProviderAccounts() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        ResetClientProtocol.configure(mode: .timeout)
        let originalBinding = ClaudeUsageResetClient.credentialBinding(for: "fixture-token")
        do {
            _ = try await harness.client.consume(for: account, accessToken: "fixture-token", grantID: "fixture_grant",
                                                credentialBinding: originalBinding)
            XCTFail("Original account mutation should remain unconfirmed")
        } catch { XCTAssertEqual(error as? ClaudeUsageResetError, .indeterminate) }
        let other = client(session: harness.session, directory: harness.directory, token: "other-token")
        let otherAccount = ProviderAccountConfiguration(id: "claude.other", providerID: .claude, authMethod: .cliToken)
        ResetClientProtocol.configure(mode: .otherIdentity)
        let outcome = try await other.consume(for: otherAccount, accessToken: "other-token", grantID: "fixture_grant",
                                             credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "other-token"))
        XCTAssertEqual(outcome, .reset)
        let post = try XCTUnwrap(ResetClientProtocol.requests.first { $0.httpMethod == "POST" })
        XCTAssertEqual(post.url?.path, "/api/organizations/00000000-0000-0000-0000-000000000004/reset_rate_limits")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: harness.directory.path).count, 1)
    }

    func testUnwritableReceiptStopsBeforeMutatingRequest() async throws {
        let harness = makeHarness()
        defer { try? FileManager.default.removeItem(at: harness.directory) }
        try Data("file, not directory".utf8).write(to: harness.directory)
        ResetClientProtocol.configure(mode: .success)
        do {
            _ = try await harness.client.consume(for: account, accessToken: "fixture-token", grantID: "fixture_grant",
                credentialBinding: ClaudeUsageResetClient.credentialBinding(for: "fixture-token"))
            XCTFail("A mutation without a durable safety receipt must not start")
        } catch { XCTAssertEqual(error as? ClaudeUsageResetError, .storageUnavailable) }
        XCTAssertFalse(ResetClientProtocol.requests.contains { $0.httpMethod == "POST" })
    }

    private func makeHarness(token: String = "fixture-token") -> Harness {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeResetClientTests.\(UUID())")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ResetClientProtocol.self]
        let session = URLSession(configuration: configuration)
        return Harness(client: client(session: session, directory: directory, token: token), session: session, directory: directory)
    }

    private func client(session: URLSession, directory: URL, token: String) -> ClaudeUsageResetClient {
        let date = now
        return ClaudeUsageResetClient(session: session, secretStore: ResetClientSecrets(token: token), receiptDirectory: directory,
                                      baseURL: URL(string: "https://fixture.invalid")!, now: { date })
    }

    private struct Harness {
        let client: ClaudeUsageResetClient
        let session: URLSession
        let directory: URL
    }
}

private struct ResetClientSecrets: SecretStore {
    let token: String
    func readSecret(account _: String) throws -> String? { token }
    func saveSecret(_: String, account _: String) throws {}
    func deleteSecret(account _: String) throws {}
}

private class ResetClientProtocol: URLProtocol, @unchecked Sendable {
    enum Mode: Sendable {
        case success, ineligible, expired, missingIdentity, timeout, reconciled
        case serverError, malformedSuccess, missingGrant, changedIdentity, delayed, otherIdentity
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var mode = Mode.success
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func configure(mode: Mode) { lock.withLock { self.mode = mode; recorded = [] } }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        var recordedRequest = request
        if recordedRequest.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
            recordedRequest.httpBody = data
        }
        let mode = Self.lock.withLock { Self.recorded.append(recordedRequest); return Self.mode }
        if mode == .delayed, request.url?.path == "/api/oauth/profile" {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in respond(mode: mode) }
            return
        }
        respond(mode: mode)
    }

    private func respond(mode: Mode) {
        if request.httpMethod == "POST", mode == .timeout {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut))
            return
        }
        let body: String
        if request.url?.path == "/api/oauth/profile" {
            let profileCount = Self.requests.filter { $0.url?.path == "/api/oauth/profile" }.count
            let organization: String
            if mode == .otherIdentity {
                organization = "00000000-0000-0000-0000-000000000004"
            } else {
                organization = mode == .changedIdentity && profileCount > 1
                    ? "00000000-0000-0000-0000-000000000003" : "00000000-0000-0000-0000-000000000002"
            }
            let accountID = mode == .otherIdentity
                ? "00000000-0000-0000-0000-000000000003" : "00000000-0000-0000-0000-000000000001"
            body = mode == .missingIdentity ? "{}" : """
            {"account":{"uuid":"\(accountID)"},
             "organization":{"uuid":"\(organization)"}}
            """
        } else if request.httpMethod == "POST" {
            body = mode == .malformedSuccess ? "{}" : #"{"result":"reset","cleared":["five_hour","seven_day"]}"#
        } else if mode == .missingGrant {
            body = #"{"cedar_ember":{"eligible":true,"grants":[]}}"#
        } else {
            body = """
            {"cedar_ember":{"eligible":\(mode != .ineligible),"next_grant_id":"fixture_grant","grants":[{
              "id":"fixture_grant","resets_left":\(mode == .reconciled ? 1 : 2),
              "starts_at":"2029-12-01T00:00:00Z","ends_at":"\(mode == .expired ? "2029-12-31" : "2030-01-08")T00:00:00Z",
              "clears":["five_hour","seven_day"],"paused":false,"usable_now":true
            }]}}
            """
        }
        let status = request.httpMethod == "POST" && mode == .serverError ? 503 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
