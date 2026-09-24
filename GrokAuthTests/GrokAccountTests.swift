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

    @MainActor
    func testVerifiedPlanNamesRespectSubjectsCustomLabelsAndDuplicates() throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(
            defaults: defaults, secretStore: GrokTestSecrets(), widgetSnapshotDefaults: defaults
        )
        let first = store.addAccount(for: .grok)
        let second = store.addAccount(for: .grok)
        XCTAssertTrue(store.replaceCredential(try credential(subject: "one").encoded(), for: first))
        XCTAssertTrue(store.replaceCredential(try credential(subject: "two").encoded(), for: second))
        func result(_ account: ProviderAccountConfiguration, subject: String, plan: String?) throws -> ProviderUsageResult {
            try GrokUsageProvider.parseCredits(
                Data(#"{"config":{"isUnifiedBillingUser":true}}"#.utf8),
                configuration: account, subject: subject, now: Date(), verifiedPlanName: plan
            )
        }
        XCTAssertFalse(store.applyVerifiedGrokPlan(try result(first, subject: "two", plan: "SuperGrok Lite")))
        XCTAssertTrue(store.applyVerifiedGrokPlan(try result(first, subject: "one", plan: "SuperGrok Lite")))
        XCTAssertTrue(store.applyVerifiedGrokPlan(try result(second, subject: "two", plan: "SuperGrok Lite")))
        XCTAssertEqual(store.configuration(accountID: first.id)?.accountLabel, "SuperGrok Lite")
        XCTAssertEqual(store.configuration(accountID: second.id)?.accountLabel, "SuperGrok Lite 2")
        XCTAssertTrue(store.applyVerifiedGrokPlan(try result(first, subject: "one", plan: "SuperGrok Plus")))
        XCTAssertEqual(store.configuration(accountID: first.id)?.accountLabel, "SuperGrok Plus")
        var custom = try XCTUnwrap(store.configuration(accountID: first.id))
        custom.accountLabel = "My Grok"
        XCTAssertTrue(store.update(custom))
        XCTAssertFalse(store.applyVerifiedGrokPlan(try result(first, subject: "one", plan: "SuperGrok Heavy")))
        XCTAssertEqual(store.configuration(accountID: first.id)?.accountLabel, "My Grok")
        XCTAssertFalse(store.applyVerifiedGrokPlan(try result(second, subject: "two", plan: nil)))
        XCTAssertEqual(store.configuration(accountID: second.id)?.accountLabel, "SuperGrok Lite 2")
    }

    @MainActor
    func testWidgetUsesCurrentGrokLabelEvenBeforeTheNextUsageFetch() throws {
        let suite = "GrokAuthTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProviderConfigurationStore(
            defaults: defaults, secretStore: GrokTestSecrets(), widgetSnapshotDefaults: defaults
        )
        let account = store.addAccount(for: .grok)
        XCTAssertTrue(store.replaceCredential(try credential(subject: "one").encoded(), for: account))
        let result = try GrokUsageProvider.parseCredits(
            Data(#"{"config":{"isUnifiedBillingUser":true,"prepaidBalance":{"val":0}}}"#.utf8),
            configuration: account, subject: "one", now: Date(), verifiedPlanName: "SuperGrok Lite"
        )
        XCTAssertTrue(store.applyVerifiedGrokPlan(result))
        XCTAssertEqual(result.title, account.accountLabel)
        let refresh = UsageRefreshService(providers: [], initialResults: [result])
        refresh.updateGrokResultTitle("SuperGrok Lite", accountID: account.id)
        XCTAssertEqual(refresh.results.first?.title, "SuperGrok Lite")
        WidgetSnapshotPublisher.publish(results: [result], configurationStore: store, snapshotDefaults: defaults)
        XCTAssertEqual(WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first?.title, "SuperGrok Lite")
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
