import Foundation
@testable import CodexBarIOS

func makeHistoryResult(
    accountID: String,
    providerID: ProviderID = .codex,
    fetchedAt: Date,
    used: Double? = nil,
    bars: [UsageBar]? = nil,
    creditsRemaining: Double? = nil
) -> ProviderUsageResult {
    ProviderUsageResult(
        accountID: accountID,
        providerID: providerID,
        title: providerID.displayName,
        subtitle: "Test data",
        bars: bars ?? used.map { [UsageBar(label: "Usage", used: $0, limit: 100)] } ?? [],
        creditsRemaining: creditsRemaining,
        fetchedAt: fetchedAt
    )
}

struct EmptySecretStore: SecretStore {
    func readSecret(account: String) throws -> String? {
        nil
    }

    func saveSecret(_ secret: String, account: String) throws {
    }

    func deleteSecret(account: String) throws {
    }
}

struct FailingReadSecretStore: SecretStore {
    func readSecret(account: String) throws -> String? {
        throw FailingReadSecretStoreError.unavailable
    }

    func saveSecret(_ secret: String, account: String) throws {
    }

    func deleteSecret(account: String) throws {
    }
}

enum FailingReadSecretStoreError: LocalizedError {
    case unavailable

    var errorDescription: String? {
        "Keychain unavailable"
    }
}

final class RecordingFileProtectionManager: FileManager, @unchecked Sendable {
    var shouldFail = false
    private(set) var recordedAttributes: [FileAttributeKey: Any]?
    private(set) var recordedPath: String?

    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        recordedAttributes = attributes
        recordedPath = path
        if shouldFail {
            throw CocoaError(.fileWriteNoPermission)
        }
    }
}

actor StubAppStoreReleaseFetcher: AppStoreReleaseFetching {
    private var result: Result<AppStoreRelease, AppStoreReleaseError>
    private var fetchCount = 0

    init(result: Result<AppStoreRelease, AppStoreReleaseError>) {
        self.result = result
    }

    func fetchRelease() async throws -> AppStoreRelease {
        fetchCount += 1
        return try result.get()
    }

    func setResult(_ result: Result<AppStoreRelease, AppStoreReleaseError>) {
        self.result = result
    }

    func currentFetchCount() -> Int {
        fetchCount
    }
}

final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    func readSecret(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return secrets[account]
    }

    func saveSecret(_ secret: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets[account] = secret
    }

    func deleteSecret(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets.removeValue(forKey: account)
    }
}

final class FailingSaveSecretStore: SecretStore, @unchecked Sendable {
    private let secret: String

    init(secret: String) {
        self.secret = secret
    }

    func readSecret(account: String) throws -> String? {
        secret
    }

    func saveSecret(_ secret: String, account: String) throws {
        throw KeychainError.unhandledStatus(-25308)
    }

    func deleteSecret(account: String) throws {}
}

struct FailingDeleteSecretStore: SecretStore {
    func readSecret(account: String) throws -> String? {
        "existing-token"
    }

    func saveSecret(_ secret: String, account: String) throws {}

    func deleteSecret(account: String) throws {
        throw KeychainError.unhandledStatus(-25308)
    }
}

final class SelectiveReadFailureSecretStore: SecretStore, @unchecked Sendable {
    var failingAccount: String?
    private let lock = NSLock()
    private var secrets: [String: String] = [:]

    func readSecret(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        if account == failingAccount {
            throw KeychainError.unhandledStatus(-25308)
        }
        return secrets[account]
    }

    func saveSecret(_ secret: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets[account] = secret
    }

    func deleteSecret(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        secrets.removeValue(forKey: account)
    }
}

final class StaleThirdReadSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private let initialSecret: String
    private var currentSecret: String
    private var readCount = 0

    init(initialSecret: String) {
        self.initialSecret = initialSecret
        self.currentSecret = initialSecret
    }

    func readSecret(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        return readCount == 3 ? initialSecret : currentSecret
    }

    func saveSecret(_ secret: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        currentSecret = secret
    }

    func deleteSecret(account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        currentSecret = ""
    }
}

final class ReplacingThirdReadSecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private let initialSecret: String
    private let replacementSecret: String
    private var readCount = 0
    private var storedSaveCount = 0

    init(initialSecret: String, replacementSecret: String) {
        self.initialSecret = initialSecret
        self.replacementSecret = replacementSecret
    }

    var saveCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedSaveCount
    }

    func readSecret(account: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        readCount += 1
        return readCount >= 3 ? replacementSecret : initialSecret
    }

    func saveSecret(_ secret: String, account: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storedSaveCount += 1
    }

    func deleteSecret(account: String) throws {}
}

func requestBodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer {
        stream.close()
    }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let byteCount = stream.read(&buffer, maxLength: buffer.count)
        guard byteCount > 0 else {
            break
        }
        data.append(contentsOf: buffer.prefix(byteCount))
    }
    return data
}

typealias TestURLProtocolHandler = (URLRequest) throws -> (HTTPURLResponse, Data)

final class TestURLProtocolHandlerStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storedHandler: TestURLProtocolHandler?

    var handler: TestURLProtocolHandler? {
        get {
            lock.withLock { storedHandler }
        }
        set {
            lock.withLock { storedHandler = newValue }
        }
    }
}

class TestURLProtocol: URLProtocol, @unchecked Sendable {
    class var handlerStore: TestURLProtocolHandlerStore {
        preconditionFailure("Concrete test URL protocols must provide a handler store.")
    }

    class var handler: TestURLProtocolHandler? {
        get { handlerStore.handler }
        set { handlerStore.handler = newValue }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = type(of: self).handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class AppAndWidgetMockURLProtocol: TestURLProtocol, @unchecked Sendable {
    private static let store = TestURLProtocolHandlerStore()
    override class var handlerStore: TestURLProtocolHandlerStore { store }
}

final class ConfigurationAndAuthMockURLProtocol: TestURLProtocol, @unchecked Sendable {
    private static let store = TestURLProtocolHandlerStore()
    override class var handlerStore: TestURLProtocolHandlerStore { store }
}

final class ProviderParsingMockURLProtocol: TestURLProtocol, @unchecked Sendable {
    private static let store = TestURLProtocolHandlerStore()
    override class var handlerStore: TestURLProtocolHandlerStore { store }
}

final class ProviderNetworkMockURLProtocol: TestURLProtocol, @unchecked Sendable {
    private static let store = TestURLProtocolHandlerStore()
    override class var handlerStore: TestURLProtocolHandlerStore { store }
}

final class DashboardAndSettingsMockURLProtocol: TestURLProtocol, @unchecked Sendable {
    private static let store = TestURLProtocolHandlerStore()
    override class var handlerStore: TestURLProtocolHandlerStore { store }
}

final class TestRequestGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var requestStarted = false
    private var released = false

    func blockUntilReleased() {
        condition.lock()
        requestStarted = true
        condition.broadcast()
        while !released {
            condition.wait()
        }
        condition.unlock()
    }

    func waitUntilBlocked(timeout: TimeInterval = 2) -> Bool {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while !requestStarted {
            guard condition.wait(until: deadline) else {
                return false
            }
        }
        return true
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

final class TestDateProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    func now() -> Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock {
            date.addTimeInterval(interval)
        }
    }
}

struct HangingUsageProvider: UsageProvider {
    let providerID: ProviderID

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        try await Task.sleep(for: .seconds(60))
        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: providerID,
            title: providerID.displayName,
            subtitle: "Unexpected",
            bars: [],
            fetchedAt: Date()
        )
    }
}

actor UsageProviderGate {
    private var shouldBlock = true
    private var isBlocked = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard shouldBlock else {
            return
        }
        shouldBlock = false
        isBlocked = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func waitUntilBlocked() async {
        while !isBlocked {
            await Task.yield()
        }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

actor AsyncFlag {
    private var value = false

    func set() {
        value = true
    }

    func currentValue() -> Bool {
        value
    }
}

actor UsageProviderRecorder {
    private var labels: [String] = []

    func record(_ label: String) {
        labels.append(label)
    }

    func recordedLabels() -> [String] {
        labels
    }
}

struct GatedUsageProvider: UsageProvider {
    let providerID: ProviderID
    let blockedAccountID: String
    let gate: UsageProviderGate
    let recorder: UsageProviderRecorder?

    init(
        providerID: ProviderID,
        blockedAccountID: String,
        gate: UsageProviderGate,
        recorder: UsageProviderRecorder? = nil
    ) {
        self.providerID = providerID
        self.blockedAccountID = blockedAccountID
        self.gate = gate
        self.recorder = recorder
    }

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        if let recorder {
            await recorder.record(configuration.accountLabel)
        }
        if configuration.id == blockedAccountID {
            await gate.wait()
        }

        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: providerID,
            title: configuration.displayName,
            subtitle: "Fresh usage",
            bars: [UsageBar(label: "Usage", used: 20, limit: 100)],
            fetchedAt: Date()
        )
    }
}

struct AccountGatedUsageProvider: UsageProvider {
    let providerID: ProviderID
    let gates: [String: UsageProviderGate]
    let recorder: UsageProviderRecorder

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        await recorder.record(configuration.accountLabel)
        if let gate = gates[configuration.id] {
            await gate.wait()
        }

        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: providerID,
            title: configuration.displayName,
            subtitle: "Fresh usage",
            bars: [],
            fetchedAt: Date()
        )
    }
}

enum TestUsageProviderError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Refresh failed"
    }
}

struct SelectivelyFailingUsageProvider: UsageProvider {
    let providerID: ProviderID
    let failedAccountID: String

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        if configuration.id == failedAccountID {
            throw TestUsageProviderError.failed
        }

        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: providerID,
            title: configuration.displayName,
            subtitle: "Fresh usage",
            bars: [],
            fetchedAt: Date()
        )
    }
}

struct ReturningFailureUsageProvider: UsageProvider {
    let providerID: ProviderID

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: providerID,
            title: configuration.displayName,
            subtitle: "Credential expired",
            bars: [],
            failureMessage: "Credential expired",
            fetchedAt: Date()
        )
    }
}

extension URLComponents {
    func queryItemValue(named name: String) -> String? {
        queryItems?.first { $0.name == name }?.value
    }
}

extension String {
    func base64URLEncodedForTest() -> String {
        Data(utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
