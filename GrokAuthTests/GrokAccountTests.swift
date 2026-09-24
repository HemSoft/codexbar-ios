import Combine
import Foundation
import XCTest
@testable import CodexBarIOS

final class GrokAccountTests: XCTestCase {
    @MainActor
    func testConnectionRequiresSavedCredentialAndSubjectCannotBeReplaced() throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = GrokTestSecrets()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        let account = store.addAccount(for: .grok)
        var changed: [String] = []
        let subscription = store.credentialChanges.sink { changed.append($0) }
        var clearedHistory: [String] = []
        let historySubscription = store.grokHistoryInvalidations.sink { clearedHistory.append($0) }
        defer { subscription.cancel(); historySubscription.cancel() }
        XCTAssertFalse(store.isConfigured(account))
        let first = credential(subject: "first")
        let other = credential(subject: "other")
        XCTAssertTrue(store.canReconnectGrok(first, accountID: account.id))
        XCTAssertTrue(store.replaceCredential(try first.encoded(), for: account))
        XCTAssertEqual(changed, [account.id])
        XCTAssertTrue(store.isConfigured(account))
        XCTAssertTrue(store.canReconnectGrok(first, accountID: account.id))
        XCTAssertFalse(store.canReconnectGrok(other, accountID: account.id))
        XCTAssertTrue(store.replaceCredential(try first.encoded(), for: account))
        XCTAssertTrue(clearedHistory.isEmpty)
        XCTAssertTrue(store.saveSecret("", for: account))
        XCTAssertEqual(clearedHistory, [account.id])
        XCTAssertEqual(changed, [account.id, account.id, account.id])
        XCTAssertFalse(store.isConfigured(account))
        XCTAssertTrue(store.canReconnectGrok(other, accountID: account.id))
    }

    @MainActor
    func testChangingVerifiedSubjectInvalidatesHistory() throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(
            defaults: defaults, secretStore: GrokTestSecrets(), widgetSnapshotDefaults: defaults
        )
        let account = store.addAccount(for: .grok)
        var clearedHistory: [String] = []
        let subscription = store.grokHistoryInvalidations.sink { clearedHistory.append($0) }
        defer { subscription.cancel() }
        XCTAssertTrue(store.replaceCredential(try credential(subject: "first").encoded(), for: account))
        XCTAssertTrue(clearedHistory.isEmpty)
        XCTAssertTrue(store.replaceCredential(try credential(subject: "other").encoded(), for: account))
        XCTAssertEqual(clearedHistory, [account.id])
    }

    @MainActor
    func testFailedPersistenceAndRemovalCannotClaimAConnection() throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let secrets = GrokTestSecrets()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secrets, widgetSnapshotDefaults: defaults)
        let account = store.addAccount(for: .grok)
        var changed: [String] = []
        let subscription = store.credentialChanges.sink { changed.append($0) }
        defer { subscription.cancel() }
        secrets.failWrites = true
        XCTAssertFalse(store.replaceCredential(try credential(subject: "one").encoded(), for: account))
        XCTAssertTrue(changed.isEmpty)
        XCTAssertFalse(store.isConfigured(account))
        secrets.failWrites = false
        XCTAssertTrue(store.replaceCredential(try credential(subject: "one").encoded(), for: account))
        XCTAssertTrue(store.removeAccount(account))
        XCTAssertEqual(changed, [account.id, account.id])
        XCTAssertFalse(store.canReconnectGrok(credential(subject: "one"), accountID: account.id))
        XCTAssertNil(try secrets.readSecret(account: ProviderConfigurationStore.keychainAccount(for: account)))
    }

    private func credential(subject: String) -> GrokCredential {
        GrokCredential(
            kind: "grok-oauth-v1", accessToken: "fixture-token", refreshToken: "fixture-refresh",
            expiresAt: Date().addingTimeInterval(3600), subject: subject, email: nil
        )
    }
}

final class GrokTestSecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]
    private var shouldFail = false

    var failWrites: Bool {
        get { lock.withLock { shouldFail } }
        set { lock.withLock { shouldFail = newValue } }
    }

    func readSecret(account: String) throws -> String? { lock.withLock { values[account] } }
    func saveSecret(_ secret: String, account: String) throws {
        try lock.withLock {
            if shouldFail { throw GrokAuthError.invalidResponse }
            values[account] = secret
        }
    }
    func deleteSecret(account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}
