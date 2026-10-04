import Combine
import Foundation
import XCTest
@testable import CodexBarIOS

@MainActor
final class CursorStalePublicationRegressionTests: XCTestCase {
    func testRejectedSessionRetainsMeasuredTimestampButCannotEnterHistoryOrFreshPublication() async throws {
        let fixture = try makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let account = fixture.account
        let secret = CursorWebAuthResult(accessToken: "synthetic-token", refreshToken: nil, authID: "owner-a", userID: nil)
        XCTAssertTrue(fixture.store.saveSecret(secret.storedCredential, for: account))
        let credential = try XCTUnwrap(CursorSessionCredential(storedSecret: secret.storedCredential))
        let measuredAt = Date(timeIntervalSince1970: 1_790_000_000)
        let good = try XCTUnwrap(CursorUsageProvider.parseUsage(
            Data(#"{"planUsage":{"autoPercentUsed":0.1,"apiPercentUsed":13}}"#.utf8),
            configuration: account, fetchedAt: measuredAt, cacheIdentity: credential.cacheIdentity
        ))
        let failed = ProviderUsageResult(
            accountID: account.id, providerID: .cursor, title: account.displayName,
            subtitle: "Cursor sign-in needs renewal.", bars: [], failureMessage: "Reconnect Cursor",
            recoveryAction: .reauthenticate, cacheIdentity: credential.cacheIdentity, fetchedAt: Date()
        )
        let service = UsageRefreshService(providers: [CursorFixedFailure(result: failed)], initialResults: [good])
        await service.refresh(configurations: [account])
        let retained = try XCTUnwrap(service.results.first)
        XCTAssertEqual(retained.bars.map(\.used), [0.1, 13])
        XCTAssertEqual(retained.fetchedAt, measuredAt)
        XCTAssertEqual(retained.barsFetchedAt, measuredAt)
        XCTAssertNotNil(retained.failureMessage)
        XCTAssertEqual(retained.recoveryAction, .reauthenticate)
        XCTAssertTrue(service.successfulRefreshResults.isEmpty)
        WidgetSnapshotPublisher.publish(results: service.results, configurationStore: fixture.store, snapshotDefaults: fixture.defaults)
        let widget = try XCTUnwrap(WidgetSnapshotStore.loadSnapshot(defaults: fixture.defaults).results.first)
        XCTAssertTrue(widget.subtitle.contains("last known data"))
        XCTAssertEqual(widget.fetchedAt, measuredAt)
        let watch = WatchSnapshotPublisher.makeSnapshot(results: service.results, configurationStore: fixture.store)
        XCTAssertTrue(watch.accounts.first?.statusText?.contains("last known data") == true)
        XCTAssertEqual(watch.accounts.first?.fetchedAt, measuredAt)
    }

    func testReconnectInvalidatesOldRefreshAndClearsOnlyDifferentIdentityHistory() throws {
        let fixture = try makeStore()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let account = fixture.account
        var changes = 0
        var histories = 0
        let credentials = fixture.store.credentialChanges.sink { _ in changes += 1 }
        let history = fixture.store.cursorHistoryInvalidations.sink { _ in histories += 1 }
        defer { credentials.cancel(); history.cancel() }
        let first = CursorWebAuthResult(accessToken: "synthetic-a", refreshToken: nil, authID: "owner-a", userID: nil)
        let renewal = CursorWebAuthResult(accessToken: "synthetic-a-renewed", refreshToken: nil, authID: "owner-a", userID: nil)
        let other = CursorWebAuthResult(accessToken: "synthetic-b", refreshToken: nil, authID: "owner-b", userID: nil)
        XCTAssertNotNil(fixture.store.connectCursorAccount(account, credential: first.storedCredential))
        XCTAssertNotNil(fixture.store.connectCursorAccount(account, credential: renewal.storedCredential))
        XCTAssertEqual(changes, 2)
        XCTAssertEqual(histories, 0)
        XCTAssertNotNil(fixture.store.connectCursorAccount(account, credential: other.storedCredential))
        XCTAssertEqual(changes, 3)
        XCTAssertEqual(histories, 1)
        XCTAssertNotNil(fixture.store.disconnectCursorAccount(account))
        XCTAssertEqual(changes, 4)
        XCTAssertEqual(histories, 2)
    }

    private func makeStore() throws -> (
        store: ProviderConfigurationStore, defaults: UserDefaults, suite: String, account: ProviderAccountConfiguration
    ) {
        let suite = "CursorSession.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: GrokTestSecrets(), widgetSnapshotDefaults: defaults)
        let account = ProviderAccountConfiguration(
            id: "cursor-stale-publication", providerID: .cursor, accountLabel: "Synthetic Cursor", authMethod: .browserSession
        )
        XCTAssertTrue(store.update(account))
        return (store, defaults, suite, account)
    }
}

private struct CursorFixedFailure: UsageProvider {
    let result: ProviderUsageResult
    let providerID = ProviderID.cursor
    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult { result }
}
