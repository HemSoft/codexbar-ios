import Combine
import Foundation

#if os(iOS)
import WatchConnectivity
#endif

private extension WatchMetricSeverity {
    init(_ severity: UsageSeverity) {
        switch severity {
        case .normal:
            self = .normal
        case .warning:
            self = .warning
        case .critical:
            self = .critical
        }
    }
}

private extension WatchMetricVisualizationStyle {
    init(_ style: MetricVisualizationStyle) {
        self = Self(rawValue: style.rawValue) ?? .automatic
    }
}

@MainActor
protocol WatchSnapshotSending: AnyObject {
    func activate(onActivated: @escaping @MainActor () -> Void)
    @discardableResult
    func publish(_ snapshot: WatchDashboardSnapshot, force: Bool) -> Bool
}

struct WatchSnapshotDeduplicator {
    private(set) var lastSemanticData: Data?

    func shouldSend(_ snapshot: WatchDashboardSnapshot, force: Bool) throws -> Bool {
        let semanticData = try snapshot.semanticData()
        return force || semanticData != lastSemanticData
    }

    mutating func recordSent(_ snapshot: WatchDashboardSnapshot) throws {
        lastSemanticData = try snapshot.semanticData()
    }
}

@MainActor
enum WatchSnapshotPublisher {
    static func makeSnapshot(
        results: [ProviderUsageResult],
        configurationStore: ProviderConfigurationStore,
        now: Date = Date(),
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) -> WatchDashboardSnapshot {
        let orderedResults = orderedDisplayableResults(
            results: results,
            configurationStore: configurationStore,
            now: now
        )

        return WatchDashboardSnapshot(
            generatedAt: now,
            refreshIntervalSeconds: configurationStore.autoRefreshInterval.seconds,
            accounts: orderedResults.compactMap { result -> WatchAccountSnapshot? in
                guard let configuration = configurationStore.configuration(accountID: result.accountID) else {
                    return nil
                }

                let barMetrics = result.bars.enumerated().map { index, bar in
                    let metricID = bar.metricIdentifier(providerID: result.providerID, index: index)
                    let fraction = bar.fractionUsed
                    return WatchMetricSnapshot(
                        id: metricID,
                        label: bar.label,
                        usedFraction: fraction,
                        remainingFraction: 1 - fraction,
                        exactValue: bar.usageText,
                        severity: result.hasFreshBars
                            ? WatchMetricSeverity(bar.effectiveSeverity(at: now))
                            : .normal,
                        resetText: bar.localizedResetDescription(
                            at: now,
                            dateTimeFormatter: dateTimeFormatter
                        ),
                        visualizationStyle: WatchMetricVisualizationStyle(
                            configurationStore.visualizationStyle(
                                accountID: result.accountID,
                                metricID: metricID
                            )
                        )
                    )
                }

                let monetaryMetrics = result.monetaryMetrics.map { metric in
                    WatchMetricSnapshot(
                        id: "\(result.providerID.rawValue).monetary.\(metric.id)",
                        label: metric.label,
                        exactValue: metric.formattedAmount(),
                        severity: result.hasReachedSpendLimit ? .critical : .normal,
                        visualizationStyle: .largeNumeric
                    )
                }

                var metrics = barMetrics + monetaryMetrics
                if let creditsRemaining = result.creditsRemaining, monetaryMetrics.isEmpty {
                    metrics.append(
                        WatchMetricSnapshot(
                            id: "\(result.providerID.rawValue).credits-remaining",
                            label: "Credits remaining",
                            exactValue: creditsRemaining.formatted(
                                .number.precision(.fractionLength(0...2))
                            ),
                            visualizationStyle: .largeNumeric
                        )
                    )
                }

                return WatchAccountSnapshot(
                    id: result.accountID,
                    providerName: result.title,
                    accountLabel: watchAccountLabel(
                        configuration: configuration,
                        result: result
                    ),
                    statusText: statusText(
                        for: result,
                        configurationStore: configurationStore
                    ),
                    fetchedAt: result.fetchedAt,
                    metrics: metrics
                )
            }
        )
    }

    @discardableResult
    static func publish(
        results: [ProviderUsageResult],
        configurationStore: ProviderConfigurationStore,
        sender: (any WatchSnapshotSending)? = nil,
        now: Date = Date(),
        force: Bool = false
    ) -> Bool {
        let resolvedSender = sender ?? PhoneWatchConnectivityCoordinator.shared
        return resolvedSender.publish(
            makeSnapshot(
                results: results,
                configurationStore: configurationStore,
                now: now
            ),
            force: force
        )
    }

    private static func orderedDisplayableResults(
        results: [ProviderUsageResult],
        configurationStore: ProviderConfigurationStore,
        now: Date
    ) -> [ProviderUsageResult] {
        let resultsByAccountID = Dictionary(
            uniqueKeysWithValues: results.map { ($0.accountID, $0) }
        )
        let displayable: [ProviderUsageResult] = configurationStore.configurations.compactMap {
            configuration -> ProviderUsageResult? in
            guard configurationStore.shouldDisplayOnDashboard(configuration) else {
                return nil
            }
            return resultsByAccountID[configuration.id]
        }
        return DashboardUsageSorter.orderedResults(
            displayable,
            mode: configurationStore.dashboardOrderingMode,
            manualOrder: configurationStore.dashboardCardOrder,
            now: now
        )
    }

    private static func watchAccountLabel(
        configuration: ProviderAccountConfiguration,
        result: ProviderUsageResult
    ) -> String {
        let configuredLabel = configuration.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        if !configuredLabel.isEmpty {
            return configuredLabel
        }
        let subtitle = result.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return subtitle.isEmpty ? configuration.providerID.displayName : subtitle
    }

    private static func statusText(
        for result: ProviderUsageResult,
        configurationStore: ProviderConfigurationStore
    ) -> String {
        guard let configuration = configurationStore.configuration(accountID: result.accountID) else {
            return result.subtitle
        }
        if configurationStore.isConfigured(configuration),
           !result.subtitle.localizedCaseInsensitiveContains("not configured") {
            return result.subtitle
        }
        return configurationStore.statusText(for: configuration)
    }
}

@MainActor
final class WatchSnapshotCoordinator {
    typealias SnapshotPublisher = @MainActor (
        [ProviderUsageResult],
        ProviderConfigurationStore,
        Bool
    ) -> Void

    private let refreshService: UsageRefreshService
    private let configurationStore: ProviderConfigurationStore
    private let publishSnapshot: SnapshotPublisher
    private let coalescingDelay: Duration
    private var cancellables: Set<AnyCancellable> = []
    private var snapshotPublishTask: Task<Void, Never>?

    init(
        refreshService: UsageRefreshService,
        configurationStore: ProviderConfigurationStore,
        sender: (any WatchSnapshotSending)? = nil,
        coalescingDelay: Duration = .milliseconds(250),
        publishSnapshot: SnapshotPublisher? = nil
    ) {
        let resolvedSender = sender ?? PhoneWatchConnectivityCoordinator.shared
        self.refreshService = refreshService
        self.configurationStore = configurationStore
        self.coalescingDelay = coalescingDelay
        self.publishSnapshot = publishSnapshot ?? { results, store, force in
            WatchSnapshotPublisher.publish(
                results: results,
                configurationStore: store,
                sender: resolvedSender,
                force: force
            )
        }

        refreshService.$results.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$configurations.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$dashboardCardOrder.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$dashboardOrderingMode.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$metricVisualizationPreferences.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$autoRefreshInterval.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)

        resolvedSender.activate { [weak self] in
            self?.publishCurrentSnapshot(force: true)
        }
    }

    func publishCurrentSnapshot(force: Bool = false) {
        let awaitsInitialResults = refreshService.results.isEmpty
            && configurationStore.configurations.contains(
                where: configurationStore.shouldDisplayOnDashboard
            )
        guard !awaitsInitialResults else {
            return
        }
        publishSnapshot(refreshService.results, configurationStore, force)
    }

    private func scheduleSnapshotPublish() {
        snapshotPublishTask?.cancel()
        snapshotPublishTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: coalescingDelay)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            publishCurrentSnapshot()
        }
    }
}

#if os(iOS)
@MainActor
final class PhoneWatchConnectivityCoordinator: NSObject, WatchSnapshotSending {
    static let shared = PhoneWatchConnectivityCoordinator()

    private let session: WCSession?
    private var activationHandler: (@MainActor () -> Void)?
    private var deduplicator = WatchSnapshotDeduplicator()

    init(session: WCSession? = WCSession.isSupported() ? .default : nil) {
        self.session = session
        super.init()
    }

    func activate(onActivated: @escaping @MainActor () -> Void) {
        activationHandler = onActivated
        guard let session else { return }
        session.delegate = self
        if session.activationState == .activated {
            onActivated()
        } else {
            session.activate()
        }
    }

    @discardableResult
    func publish(_ snapshot: WatchDashboardSnapshot, force: Bool) -> Bool {
        guard let session else { return false }
        do {
            guard try deduplicator.shouldSend(snapshot, force: force) else {
                return false
            }
            try session.updateApplicationContext(snapshot.applicationContext())
            try deduplicator.recordSent(snapshot)
            return true
        } catch {
            return false
        }
    }
}

extension PhoneWatchConnectivityCoordinator: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated, error == nil else { return }
        Task { @MainActor [weak self] in
            self?.activationHandler?()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
#else
@MainActor
final class PhoneWatchConnectivityCoordinator: WatchSnapshotSending {
    static let shared = PhoneWatchConnectivityCoordinator()

    func activate(onActivated: @escaping @MainActor () -> Void) {}

    func publish(_ snapshot: WatchDashboardSnapshot, force: Bool) -> Bool {
        false
    }
}
#endif
