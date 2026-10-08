import Foundation
import XCTest
@testable import CodexBarIOS

final class ClaudeUsageResetFlowTests: XCTestCase, @unchecked Sendable {
    @MainActor
    func testAccountInventoryAndBindingValidationPreventConsumption() async throws {
        for mode in ["disabled", "wrongAccount", "wrongBinding", "wrongGrant", "expired", "failed", "unbound"] {
            let harness = makeHarness(mode: mode)
            defer { harness.clear() }
            do {
                _ = try await harness.service.consumeClaudeReset(
                    for: harness.account, grantID: mode == "wrongGrant" ? "other" : "fixture_grant",
                    credentialBinding: mode == "wrongBinding" ? "replacement" : "binding"
                )
                XCTFail("Invalid confirmation must not reach provider: \(mode)")
            } catch {
                XCTAssertEqual(error as? ClaudeUsageResetError, .unavailable, mode)
            }
            let calls = await harness.provider.consumptionCount()
            XCTAssertEqual(calls, 0, mode)
        }
    }

    @MainActor
    func testEveryOutcomeRefreshesAuthoritativeUsage() async throws {
        for outcome in [ClaudeUsageResetOutcome.reset, .alreadyRedeemed, .nothingToReset, .noCredit, .stateChanged] {
            let harness = makeHarness(outcome: outcome)
            defer { harness.clear() }
            let feedback = await harness.orchestrator.consumeClaudeReset(
                for: harness.account, grantID: "fixture_grant", credentialBinding: "binding"
            )
            let calls = await harness.provider.consumptionCount()
            let fetches = await harness.provider.fetchCount()
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(fetches, 1)
            XCTAssertEqual(harness.service.results.first?.bars.first?.used, 17)
            XCTAssertEqual(harness.service.results.first?.claudeUsageResetInventory?.availableCount(at: Date()), 1)
            XCTAssertEqual(feedback.isSuccess, outcome == .reset || outcome == .alreadyRedeemed)
        }
    }

    @MainActor
    func testFailedOrAmbiguousConsumptionStillRefreshesWithoutReplay() async throws {
        for error in [ClaudeUsageResetError.indeterminate, .credentialChanged, .storageUnavailable] {
            let harness = makeHarness(error: error)
            defer { harness.clear() }
            let feedback = await harness.orchestrator.consumeClaudeReset(
                for: harness.account, grantID: "fixture_grant", credentialBinding: "binding"
            )
            XCTAssertFalse(feedback.isSuccess)
            let calls = await harness.provider.consumptionCount()
            let fetches = await harness.provider.fetchCount()
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(fetches, 1)
            XCTAssertEqual(harness.service.results.first?.bars.first?.used, 17)
        }
    }

    @MainActor
    func testConcurrentConfirmationsForwardExactlyOneConsumption() async throws {
        let harness = makeHarness(paused: true)
        defer { harness.clear() }
        let first = Task { @MainActor in
            try await harness.service.consumeClaudeReset(for: harness.account, grantID: "fixture_grant", credentialBinding: "binding")
        }
        let started = await harness.provider.waitUntilConsuming()
        guard started else {
            first.cancel()
            await harness.provider.release()
            XCTFail("Consumption did not start within the fixture deadline")
            return
        }
        do {
            _ = try await harness.service.consumeClaudeReset(for: harness.account, grantID: "fixture_grant", credentialBinding: "binding")
            XCTFail("Duplicate confirmation must be rejected")
        } catch { XCTAssertEqual(error as? ClaudeUsageResetError, .inProgress) }
        await harness.provider.release()
        let completed = try await first.value
        XCTAssertEqual(completed, .reset)
        let calls = await harness.provider.consumptionCount()
        XCTAssertEqual(calls, 1)
    }

    @MainActor
    func testCredentialInvalidationDiscardsPendingCompletion() async throws {
        let harness = makeHarness(paused: true)
        defer { harness.clear() }
        let first = Task { @MainActor in
            try await harness.service.consumeClaudeReset(for: harness.account, grantID: "fixture_grant", credentialBinding: "binding")
        }
        let started = await harness.provider.waitUntilConsuming()
        guard started else {
            first.cancel()
            await harness.provider.release()
            XCTFail("Consumption did not start within the fixture deadline")
            return
        }
        harness.service.invalidateCredentials(accountID: harness.account.id)
        await harness.provider.release()
        do {
            _ = try await first.value
            XCTFail("Stale completion must be rejected")
        } catch { XCTAssertEqual(error as? ClaudeUsageResetError, .credentialChanged) }
        let calls = await harness.provider.consumptionCount()
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(harness.service.results.isEmpty)
    }

    @MainActor
    private func makeHarness(
        mode: String = "valid", outcome: ClaudeUsageResetOutcome = .reset,
        error: ClaudeUsageResetError? = nil, paused: Bool = false
    ) -> Harness {
        let suite = "ClaudeResetFlow.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: FlowSecrets(), widgetSnapshotDefaults: defaults)
        var account = store.addAccount(for: .claude)
        account.isEnabled = mode != "disabled"
        XCTAssertTrue(store.update(account))
        let provider = FlowProvider(outcome: outcome, error: error, paused: paused)
        let resultAccount = mode == "wrongAccount"
            ? ProviderAccountConfiguration(id: "other-account", providerID: .claude, authMethod: .cliToken) : account
        let initial = FlowProvider.result(account: resultAccount, count: 2, used: 64, mode: mode)
        let service = UsageRefreshService(providers: [provider], initialResults: [initial])
        let orchestrator = DashboardOrchestrator(
            refreshService: service, configurationStore: store, historyStore: UsageHistoryStore(defaults: defaults),
            usageAlertNotifier: FlowNotifier(), appReviewPromptPolicy: AppReviewPromptPolicy(defaults: defaults),
            widgetSnapshotCoordinator: WidgetSnapshotCoordinator(refreshService: service, configurationStore: store,
                                                                 publishSnapshot: { _, _ in }, publishSettings: { _ in }),
            watchSnapshotCoordinator: WatchSnapshotCoordinator(refreshService: service, configurationStore: store,
                                                               sender: FlowWatchSender(), publishSnapshot: { _, _, _ in })
        )
        return Harness(account: account, service: service, provider: provider, orchestrator: orchestrator, defaults: defaults, suite: suite)
    }

    @MainActor
    private struct Harness {
        let account: ProviderAccountConfiguration
        let service: UsageRefreshService
        let provider: FlowProvider
        let orchestrator: DashboardOrchestrator
        let defaults: UserDefaults
        let suite: String
        func clear() { defaults.removePersistentDomain(forName: suite) }
    }
}

private actor FlowProvider: UsageProvider, ClaudeUsageResetConsuming {
    nonisolated let providerID = ProviderID.claude
    private let outcome: ClaudeUsageResetOutcome
    private let error: ClaudeUsageResetError?
    private let paused: Bool
    private var calls = 0
    private var fetches = 0
    private var continuation: CheckedContinuation<Void, Never>?
    init(outcome: ClaudeUsageResetOutcome, error: ClaudeUsageResetError?, paused: Bool) {
        self.outcome = outcome
        self.error = error
        self.paused = paused
    }
    func consumeClaudeReset(
        for configuration: ProviderAccountConfiguration, grantID: String, credentialBinding: String
    ) async throws -> ClaudeUsageResetOutcome {
        calls += 1
        if paused { await withCheckedContinuation { continuation = $0 } }
        if let error { throw error }
        return outcome
    }
    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        fetches += 1
        return Self.result(account: configuration, count: 1, used: 17)
    }
    func consumptionCount() -> Int { calls }
    func fetchCount() -> Int { fetches }
    func release() {
        continuation?.resume()
        continuation = nil
    }
    func waitUntilConsuming() async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(2))
        while calls == 0 && clock.now < deadline { await Task.yield() }
        return calls > 0
    }
    nonisolated static func result(
        account: ProviderAccountConfiguration, count: Int, used: Double, mode: String = "valid"
    ) -> ProviderUsageResult {
        let grant = ClaudeUsageResetGrant(id: "fixture_grant", title: "Fixture", remainingCount: count,
                                         startsAt: nil, expiresAt: Date().addingTimeInterval(mode == "expired" ? -60 : 3600),
                                         clears: ["five_hour", "seven_day"], isPaused: false, isUsableNow: true, requiresLimit: false)
        let inventory = ClaudeUsageResetInventory(isEligible: true, grants: [grant], selectedGrantID: grant.id,
                                                  cooldownUntil: nil, credentialBinding: mode == "unbound" ? nil : "binding")
        return ProviderUsageResult(accountID: account.id, providerID: .claude, title: account.displayName, subtitle: "Synthetic",
                                   bars: [UsageBar(label: "Weekly", used: used, limit: 100)], claudeUsageResetInventory: inventory,
                                   failureMessage: mode == "failed" ? "Unavailable" : nil, fetchedAt: Date())
    }
}
private final class FlowSecrets: SecretStore, @unchecked Sendable {
    func readSecret(account: String) throws -> String? { "synthetic-flow-token" }
    func saveSecret(_ secret: String, account: String) throws {}
    func deleteSecret(account: String) throws {}
}
@MainActor private final class FlowNotifier: UsageAlertNotifying {
    func requestAuthorization() async -> Bool { false }
    func deliver(_ notification: UsageAlertNotification) async throws {}
}
@MainActor private final class FlowWatchSender: WatchSnapshotSending {
    func activate(onSnapshotNeeded: @escaping @MainActor (Bool) -> Void) {}
    func publish(_ snapshot: WatchDashboardSnapshot, force: Bool) -> Bool { true }
}
