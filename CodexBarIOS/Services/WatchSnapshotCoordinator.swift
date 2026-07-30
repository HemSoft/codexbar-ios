import Combine
import CryptoKit
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
    func activate(onSnapshotNeeded: @escaping @MainActor () -> Void)
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
            accounts: orderedResults.compactMap {
                result -> WatchAccountSnapshot? in
                guard let configuration = configurationStore.configuration(accountID: result.accountID) else {
                    return nil
                }

                let barMetrics: [WatchMetricSnapshot] = result.bars.enumerated().map {
                    index, bar in
                    let severityThresholds =
                        configurationStore.usageAlertSettings.severityThresholds
                    let metricID = bar.metricIdentifier(providerID: result.providerID, index: index)
                    let fraction = bar.fractionUsed
                    let hasKnownLimit = bar.limit > 0
                    let localizedResetText = bar.localizedResetDescription(
                        at: now,
                        dateTimeFormatter: dateTimeFormatter
                    )
                    return WatchMetricSnapshot(
                        id: metricID,
                        label: bar.label,
                        usedFraction: hasKnownLimit ? fraction : nil,
                        remainingFraction: hasKnownLimit ? 1 - fraction : nil,
                        exactValue: hasKnownLimit
                            ? bar.usageText
                            : (bar.fractionlessUsageText ?? bar.used.formatted()),
                        severity: result.hasFreshBars
                            ? WatchMetricSeverity(
                                bar.effectiveSeverity(
                                    at: now,
                                    thresholds: severityThresholds
                                )
                            )
                            : .normal,
                        resetText: localizedResetText
                            ?? (result.hasFreshBars ? bar.projectionDescriptionOverride : nil),
                        resetsAt: bar.resetsAt,
                        resetDisplayStyle: bar.resetDisplayStyle,
                        fetchedAt: result.barsFetchedAt ?? result.fetchedAt,
                        visualizationStyle: WatchMetricVisualizationStyle(
                            configurationStore.visualizationStyle(
                                accountID: result.accountID,
                                metricID: metricID
                            )
                        )
                    )
                }

                let monetaryMetrics: [WatchMetricSnapshot] = result.monetaryMetrics.map {
                    metric in
                    let metricID = metric.metricIdentifier(providerID: result.providerID)
                    return WatchMetricSnapshot(
                        id: metricID,
                        label: metric.label,
                        exactValue: metric.formattedAmount(),
                        severity: result.hasReachedSpendLimit ? .critical : .normal,
                        fetchedAt: result.fetchedAt,
                        visualizationStyle: .largeNumeric
                    )
                }

                var availableMetrics = barMetrics + monetaryMetrics
                let creditsMetricID = "\(result.providerID.rawValue).credits-remaining"
                if let creditsRemaining = result.freshCreditsRemaining {
                    availableMetrics.append(
                        WatchMetricSnapshot(
                            id: creditsMetricID,
                            label: "Credits remaining",
                            exactValue: creditsRemaining.formatted(
                                .number.precision(.fractionLength(0...2))
                            ),
                            fetchedAt: result.fetchedAt,
                            visualizationStyle: .largeNumeric
                        )
                    )
                }
                let savedOrder = configurationStore.metricLayouts[result.accountID]?.orderedMetricIDs ?? []
                let metrics = orderedVisibleMetrics(
                    accountID: result.accountID,
                    availableMetrics: availableMetrics,
                    providerAvailableMetricIDs: result.availableMetrics.map(\.id),
                    savedOrder: savedOrder,
                    configurationStore: configurationStore
                )
                let displayedBarMetricIDs = Set(barMetrics.map(\.id))
                let displayedDataFetchedAt = metrics.contains {
                    displayedBarMetricIDs.contains($0.id)
                }
                    ? (result.barsFetchedAt ?? result.fetchedAt)
                    : result.fetchedAt
                let plan = result.providerID.supportsPlanBadge ? result.plan : nil

                return WatchAccountSnapshot(
                    id: snapshotAccountID(
                        providerID: result.providerID,
                        configurationID: configuration.id
                    ),
                    providerName: result.providerID == .openCodeZen
                        ? result.title
                        : configuration.providerID.displayName,
                    accountLabel: watchAccountLabel(
                        configuration: configuration,
                        result: result
                    ),
                    planIdentifier: plan?.identifier,
                    planDisplayLabel: plan?.displayLabel,
                    planAccessibilityLabel: plan?.accessibilityLabel,
                    statusText: statusText(
                        for: result,
                        configurationStore: configurationStore
                    ),
                    fetchedAt: displayedDataFetchedAt,
                    metrics: metrics
                )
            }
        )
    }

    static func snapshotAccountID(
        providerID: ProviderID,
        configurationID: String
    ) -> String {
        let digest = SHA256.hash(data: Data(configurationID.utf8))
        let opaqueID = digest.prefix(16).map { String(format: "%02x", $0) }.joined()
        return "\(providerID.rawValue).\(opaqueID)"
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
            now: now,
            severityThresholds: configurationStore.usageAlertSettings.severityThresholds
        )
    }

    private static func orderedVisibleMetrics(
        accountID: String,
        availableMetrics: [WatchMetricSnapshot],
        providerAvailableMetricIDs: [String],
        savedOrder: [String],
        configurationStore: ProviderConfigurationStore
    ) -> [WatchMetricSnapshot] {
        let snapshotsByID = Dictionary(
            availableMetrics.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var seenMetricIDs = Set<String>()
        var orderedMetricIDs: [String] = []

        func appendAvailableMetricIDs<S: Sequence>(_ metricIDs: S) where S.Element == String {
            for metricID in metricIDs
            where snapshotsByID[metricID] != nil && seenMetricIDs.insert(metricID).inserted {
                orderedMetricIDs.append(metricID)
            }
        }

        appendAvailableMetricIDs(savedOrder)
        appendAvailableMetricIDs(providerAvailableMetricIDs)
        appendAvailableMetricIDs(availableMetrics.map(\.id))

        return orderedMetricIDs.compactMap { metricID in
            guard configurationStore.isMetricVisibleOnWatch(
                accountID: accountID,
                metricID: metricID
            ) else {
                return nil
            }
            return snapshotsByID[metricID]
        }
    }

    private static func watchAccountLabel(
        configuration: ProviderAccountConfiguration,
        result: ProviderUsageResult
    ) -> String {
        if result.providerID == .openCodeZen {
            let subtitle = result.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
            return subtitle.isEmpty ? result.title : subtitle
        }
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
    private let sender: any WatchSnapshotSending
    private let publishSnapshot: SnapshotPublisher
    private let coalescingDelay: Duration
    private var cancellables: Set<AnyCancellable> = []
    private var snapshotPublishTask: Task<Void, Never>?
    private var hasStarted = false

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
        self.sender = resolvedSender
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
        configurationStore.$metricLayouts.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)
        configurationStore.$autoRefreshInterval.dropFirst().sink { [weak self] _ in
            self?.scheduleSnapshotPublish()
        }.store(in: &cancellables)

    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        sender.activate { [weak self] in
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

    deinit {
        snapshotPublishTask?.cancel()
    }
}

#if os(iOS)
@MainActor
final class PhoneWatchConnectivityCoordinator: NSObject, WatchSnapshotSending {
    static let shared = PhoneWatchConnectivityCoordinator()

    private let session: WCSession?
    private var snapshotNeededHandler: (@MainActor () -> Void)?
    private var deduplicator = WatchSnapshotDeduplicator()

    init(session: WCSession? = WCSession.isSupported() ? .default : nil) {
        self.session = session
        super.init()
    }

    func activate(onSnapshotNeeded: @escaping @MainActor () -> Void) {
        snapshotNeededHandler = onSnapshotNeeded
        guard let session else { return }
        session.delegate = self
        if session.activationState == .activated {
            onSnapshotNeeded()
        } else {
            session.activate()
        }
    }

    @discardableResult
    func handleMessage(_ message: [String: Any]) -> Bool {
        guard WatchDashboardSnapshot.isSnapshotRequest(message) else {
            return false
        }
        handleSnapshotRequest()
        return true
    }

    private func handleSnapshotRequest() {
        snapshotNeededHandler?()
    }

    func watchStateDidChange() {
        snapshotNeededHandler?()
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
            self?.snapshotNeededHandler?()
        }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessage message: [String: Any]
    ) {
        guard WatchDashboardSnapshot.isSnapshotRequest(message) else { return }
        Task { @MainActor [weak self] in
            self?.handleSnapshotRequest()
        }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.watchStateDidChange()
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

    func activate(onSnapshotNeeded: @escaping @MainActor () -> Void) {}

    func publish(_ snapshot: WatchDashboardSnapshot, force: Bool) -> Bool {
        false
    }
}
#endif
