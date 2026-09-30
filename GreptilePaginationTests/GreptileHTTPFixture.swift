import Foundation
import XCTest
@testable import CodexBarIOS

final class GreptileHTTPFixture: @unchecked Sendable {
    enum Reply {
        case payload(Data, status: Int = 200)
        case failure(URLError)
        case waitForCancellation
    }

    let endpoint = URL(string: "https://greptile-fixture.invalid/\(UUID())")!
    let started = XCTestExpectation(description: "Synthetic Greptile request started")
    let session: URLSession
    private let lock = NSLock()
    private var replies: [Reply]
    private var recordedRequests: [URLRequest] = []

    static let account = ProviderAccountConfiguration(id: "greptile.synthetic", providerID: .greptile, authMethod: .apiKey)

    init(_ replies: [Reply]) {
        self.replies = replies
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GreptileFixtureProtocol.self]
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        self.session = URLSession(configuration: configuration)
        GreptileFixtureProtocol.registry.register(self)
    }

    var requests: [URLRequest] { lock.withLock { recordedRequests } }

    func provider(pageSize: Int = 2, maximumPageCount: Int = 100, secrets: (any SecretStore)? = nil) -> GreptileUsageProvider {
        GreptileUsageProvider(
            secretStore: secrets ?? GreptileFixtureSecrets(values: [
                ProviderConfigurationStore.keychainAccount(for: Self.account): "fixture-key",
            ]),
            session: session, endpoint: endpoint, pageSize: pageSize, maximumPageCount: maximumPageCount
        )
    }

    func invalidate() {
        session.invalidateAndCancel()
        GreptileFixtureProtocol.registry.remove(endpoint)
    }

    func reply(to request: URLRequest) -> Reply {
        lock.withLock {
            if recordedRequests.isEmpty { started.fulfill() }
            recordedRequests.append(request)
            guard !replies.isEmpty else { return .failure(URLError(.badServerResponse)) }
            return replies.removeFirst()
        }
    }

    static func page(
        _ ids: [String], total: Int? = nil, truncated: Bool = false, quota: [String: Any]? = nil
    ) throws -> Reply {
        var payload: [String: Any] = [
            "codeReviews": ids.map { ["id": $0, "status": "COMPLETED"] },
            "truncated": truncated,
        ]
        if let total { payload["total"] = total }
        if let quota { payload["reviewUsage"] = quota }
        return .payload(try JSONSerialization.data(withJSONObject: ["result": payload]))
    }

    static func offset(in request: URLRequest) throws -> Int {
        let body = try requestBody(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        XCTAssertEqual(object["method"] as? String, "tools/call")
        XCTAssertEqual(params["name"] as? String, "list_code_reviews")
        let arguments = try XCTUnwrap(params["arguments"] as? [String: Any])
        return try XCTUnwrap(arguments["offset"] as? Int)
    }

    private static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
}

private final class GreptileFixtureRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var fixtures: [URL: GreptileHTTPFixture] = [:]

    func register(_ fixture: GreptileHTTPFixture) { lock.withLock { fixtures[fixture.endpoint] = fixture } }
    func remove(_ endpoint: URL) { _ = lock.withLock { fixtures.removeValue(forKey: endpoint) } }
    func fixture(for request: URLRequest) -> GreptileHTTPFixture? {
        lock.withLock { request.url.flatMap { fixtures[$0] } }
    }
}

private class GreptileFixtureProtocol: URLProtocol, @unchecked Sendable {
    static let registry = GreptileFixtureRegistry()

    // Reject an unregistered request here too; no synthetic test can fall through to a live network.
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let fixture = Self.registry.fixture(for: request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        switch fixture.reply(to: request) {
        case let .payload(data, status):
            let response = HTTPURLResponse(url: fixture.endpoint, statusCode: status, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .failure(error):
            client?.urlProtocol(self, didFailWithError: error)
        case .waitForCancellation:
            break
        }
    }

    override func stopLoading() {}
}

struct GreptileFixtureSecrets: SecretStore {
    let values: [String: String]
    var failsRead = false

    func readSecret(account: String) throws -> String? {
        if failsRead { throw URLError(.cannotOpenFile) }
        return values[account]
    }
    func saveSecret(_ secret: String, account: String) throws { throw URLError(.unsupportedURL) }
    func deleteSecret(account: String) throws { throw URLError(.unsupportedURL) }
}
