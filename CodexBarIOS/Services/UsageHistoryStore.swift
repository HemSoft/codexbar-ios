import Foundation

private enum UsageHistoryFormatting {
    static func formatCurrency(_ value: Double, currencyCode: String = "USD", decimalPlaces: Int = 2) -> String {
        value.formatted(
            .currency(code: currencyCode)
                .precision(.fractionLength(decimalPlaces))
        )
    }
}

public struct UsageHistoryBarSnapshot: Equatable, Codable, Sendable {
    public let stableKey: String?
    public let label: String
    public let fractionUsed: Double
    public let used: Double
    public let limit: Double
    public let effectiveFractionUsed: Double
    public let effectiveSeverity: UsageSeverity
    let usesLegacySeverityFallback: Bool

    private enum CodingKeys: String, CodingKey {
        case stableKey
        case label
        case fractionUsed
        case used
        case limit
        case effectiveFractionUsed
        case effectiveSeverity
        case usesLegacySeverityFallback
    }

    public init(
        bar: UsageBar,
        capturedAt: Date,
        severityThresholds: UsageSeverityThresholds = .default
    ) {
        self.stableKey = bar.stableKey
        self.label = bar.label
        self.fractionUsed = bar.fractionUsed
        self.used = bar.used
        self.limit = bar.limit
        self.effectiveFractionUsed = max(
            bar.fractionUsed,
            bar.projectedFraction(at: capturedAt) ?? bar.fractionUsed
        )
        self.effectiveSeverity = UsageSeverity(
            fractionUsed: effectiveFractionUsed,
            thresholds: severityThresholds
        )
        self.usesLegacySeverityFallback = false
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.stableKey = try container.decodeIfPresent(String.self, forKey: .stableKey)
        self.label = try container.decode(String.self, forKey: .label)
        self.fractionUsed = try container.decode(Double.self, forKey: .fractionUsed)
        self.used = try container.decode(Double.self, forKey: .used)
        self.limit = try container.decode(Double.self, forKey: .limit)
        let decodedSeverity = try container.decodeIfPresent(
            UsageSeverity.self,
            forKey: .effectiveSeverity
        ) ?? UsageSeverity(fractionUsed: fractionUsed)
        let decodedEffectiveFraction = try container.decodeIfPresent(
            Double.self,
            forKey: .effectiveFractionUsed
        )
        self.effectiveFractionUsed =
            decodedEffectiveFraction ?? max(fractionUsed, decodedSeverity.minimumFraction)
        self.effectiveSeverity = decodedSeverity
        self.usesLegacySeverityFallback = try container.decodeIfPresent(
            Bool.self,
            forKey: .usesLegacySeverityFallback
        ) ?? (decodedEffectiveFraction == nil)
    }

    public func effectiveSeverity(
        using thresholds: UsageSeverityThresholds
    ) -> UsageSeverity {
        UsageSeverity(
            fractionUsed: effectiveFractionUsed,
            thresholds: thresholds
        )
    }
}

public struct UsageHistoryMonetaryMetricSnapshot: Equatable, Codable, Sendable {
    public let kind: ProviderMonetaryMetricKind
    public let label: String
    public let minorUnits: Decimal
    public let currencyCode: String
    public let decimalPlaces: Int

    public init(metric: ProviderMonetaryMetric) {
        self.kind = metric.kind
        self.label = metric.label
        self.minorUnits = metric.minorUnits
        self.currencyCode = metric.currencyCode
        self.decimalPlaces = metric.decimalPlaces
    }
}

private protocol MonetaryMetricSnapshot {
    var metricKind: ProviderMonetaryMetricKind { get }
    var minorUnits: Decimal { get }
    var currencyCode: String { get }
    var decimalPlaces: Int { get }
}

private extension MonetaryMetricSnapshot {
    var clampedDecimalPlaces: Int {
        min(max(decimalPlaces, 0), 6)
    }

    var doubleValue: Double {
        var divisor = Decimal(1)
        for _ in 0..<clampedDecimalPlaces {
            divisor *= 10
        }
        return NSDecimalNumber(decimal: minorUnits / divisor).doubleValue
    }
}

extension ProviderMonetaryMetric: MonetaryMetricSnapshot {
    fileprivate var metricKind: ProviderMonetaryMetricKind { kind }
}

extension UsageHistoryMonetaryMetricSnapshot: MonetaryMetricSnapshot {
    fileprivate var metricKind: ProviderMonetaryMetricKind { kind }
}

public struct UsageHistorySnapshot: Identifiable, Equatable, Codable, Sendable {
    public let id: String
    public let accountID: String
    public let providerID: ProviderID
    public let title: String
    public let subtitle: String
    public let capturedAt: Date
    public let bars: [UsageHistoryBarSnapshot]
    public let creditsRemaining: Double?
    public let monetaryMetrics: [UsageHistoryMonetaryMetricSnapshot]?
    public let highestSeverity: UsageSeverity
    public let hasReachedSpendLimit: Bool?

    public init(
        result: ProviderUsageResult,
        capturedAt: Date? = nil,
        severityThresholds: UsageSeverityThresholds = .default
    ) {
        let capturedAt = capturedAt ?? result.fetchedAt
        let recordableBars = result.hasFreshBars ? result.bars : []
        self.id = "\(result.accountID).\(capturedAt.timeIntervalSince1970)"
        self.accountID = result.accountID
        self.providerID = result.providerID
        self.title = result.title
        self.subtitle = result.subtitle
        self.capturedAt = capturedAt
        self.bars = recordableBars.map {
            UsageHistoryBarSnapshot(
                bar: $0,
                capturedAt: capturedAt,
                severityThresholds: severityThresholds
            )
        }
        self.creditsRemaining = result.freshCreditsRemaining
        self.monetaryMetrics = result.monetaryMetrics.map(UsageHistoryMonetaryMetricSnapshot.init)
        self.hasReachedSpendLimit = result.hasReachedSpendLimit
        self.highestSeverity = max(
            recordableBars.map {
                $0.effectiveSeverity(
                    at: capturedAt,
                    thresholds: severityThresholds
                )
            }.max() ?? .normal,
            result.hasReachedSpendLimit ? .critical : .normal
        )
    }

    public func highestSeverity(
        using thresholds: UsageSeverityThresholds
    ) -> UsageSeverity {
        let storedUsageSeverity = bars.map(\.effectiveSeverity).max() ?? .normal
        let activeUsageSeverity = bars.map {
            $0.effectiveSeverity(using: thresholds)
        }.max() ?? .normal
        let legacyReachedSpendLimit: Bool
        if hasReachedSpendLimit == nil,
           let spent = monetaryMetrics?.first(where: { $0.kind == .spent }),
           let limit = monetaryMetrics?.first(where: { $0.kind == .spendLimit }),
           spent.currencyCode == limit.currencyCode,
           spent.decimalPlaces == limit.decimalPlaces
        {
            legacyReachedSpendLimit =
                limit.minorUnits > 0 && spent.minorUnits >= limit.minorUnits
        } else {
            legacyReachedSpendLimit = false
        }
        let legacyExternalSeverity =
            hasReachedSpendLimit == nil && highestSeverity > storedUsageSeverity
                ? highestSeverity
                : .normal

        return max(
            activeUsageSeverity,
            hasReachedSpendLimit == true || legacyReachedSpendLimit
                ? .critical
                : legacyExternalSeverity
        )
    }

    fileprivate func effectiveSeverity(
        for bar: UsageHistoryBarSnapshot,
        using thresholds: UsageSeverityThresholds
    ) -> UsageSeverity {
        if bar.usesLegacySeverityFallback {
            return highestSeverity(using: thresholds)
        }
        return bar.effectiveSeverity(using: thresholds)
    }

    public var primaryValue: Double? {
        if let creditsRemaining {
            return creditsRemaining
        }

        if providerID == .cursor,
           let total = bars.first(where: {
                $0.stableKey == "total"
                    || ($0.stableKey == nil
                        && $0.label.caseInsensitiveCompare("Total") == .orderedSame)
           })
        {
            return total.fractionUsed
        }

        if let usage = bars.map(\.fractionUsed).max() {
            return usage
        }

        let metric = monetaryMetrics?.first(where: { $0.kind == .balance })
            ?? monetaryMetrics?.first(where: { $0.kind == .remainingHeadroom })
            ?? monetaryMetrics?.first
        return metric?.doubleValue
    }

    fileprivate var monetaryPrimaryValue: Double? {
        if let creditsRemaining {
            return creditsRemaining
        }
        let metric = monetaryMetrics?.first(where: { $0.kind == .balance })
            ?? monetaryMetrics?.first(where: { $0.kind == .remainingHeadroom })
            ?? monetaryMetrics?.first
        return metric?.doubleValue
    }
}

public struct UsageTrendSummary: Equatable, Sendable {
    public enum Direction: Equatable, Sendable {
        case up
        case down
        case flat
    }

    public let accountID: String
    public let points: [Double]
    public let valueDescription: String
    public let windowDescription: String
    public let isBalance: Bool
    public let direction: Direction
}

public struct UsageHistoryPoint: Identifiable, Equatable, Sendable {
    public let id: String
    public let capturedAt: Date
    public let value: Double
    public let severity: UsageSeverity

    public init(id: String, capturedAt: Date, value: Double, severity: UsageSeverity) {
        self.id = id
        self.capturedAt = capturedAt
        self.value = value
        self.severity = severity
    }

    public init(
        snapshot: UsageHistorySnapshot,
        value: Double,
        severityThresholds: UsageSeverityThresholds = .default
    ) {
        self.init(
            id: snapshot.id,
            capturedAt: snapshot.capturedAt,
            value: value,
            severity: snapshot.highestSeverity(using: severityThresholds)
        )
    }
}

private extension UsageSeverity {
    var minimumFraction: Double {
        switch self {
        case .normal:
            0
        case .warning:
            UsageSeverityThresholds.default.warning
        case .critical:
            UsageSeverityThresholds.default.critical
        }
    }
}

public struct UsageHistorySeries: Equatable, Sendable {
    public let accountID: String
    public let points: [UsageHistoryPoint]
    public let isBalance: Bool
    public let currencyCode: String?
    public let decimalPlaces: Int

    public init(
        accountID: String,
        points: [UsageHistoryPoint],
        isBalance: Bool,
        currencyCode: String? = nil,
        decimalPlaces: Int = 2
    ) {
        self.accountID = accountID
        self.points = points
        self.isBalance = isBalance
        self.currencyCode = currencyCode
        self.decimalPlaces = decimalPlaces
    }

    public var latestValueDescription: String {
        points.last.map { valueDescription(for: $0.value) } ?? "No data"
    }

    public var minimumValueDescription: String {
        points.map(\.value).min().map(valueDescription(for:)) ?? "--"
    }

    public var maximumValueDescription: String {
        points.map(\.value).max().map(valueDescription(for:)) ?? "--"
    }

    public var rangeDescription: String {
        guard
            let minimum = points.map(\.value).min(),
            let maximum = points.map(\.value).max()
        else {
            return "No range yet"
        }

        if abs(maximum - minimum) < Self.flatDeltaThreshold {
            return "Flat at \(valueDescription(for: maximum))"
        }

        return "Range \(valueDescription(for: minimum)) to \(valueDescription(for: maximum))"
    }

    public var changeDescription: String {
        guard let latestDelta else {
            return points.isEmpty ? "No history yet" : "Collecting history"
        }

        guard direction != .flat else {
            return "No change"
        }

        let directionDescription = direction == .up ? "Up" : "Down"
        if isBalance {
            let formattedDelta = UsageHistoryFormatting.formatCurrency(
                abs(latestDelta),
                currencyCode: currencyCode ?? "USD",
                decimalPlaces: decimalPlaces
            )
            return "\(directionDescription) \(formattedDelta)"
        }

        return "\(directionDescription) \(Int((abs(latestDelta) * 100).rounded())) pts"
    }

    public var sampleWindowDescription: String {
        guard let first = points.first, let last = points.last else {
            return "No samples"
        }

        let count = points.count
        let sampleText = "\(count) sample\(count == 1 ? "" : "s")"
        if Calendar.autoupdatingCurrent.isDate(first.capturedAt, inSameDayAs: last.capturedAt) {
            return "\(sampleText) - \(UserFacingDateTimeFormatter.current.shortDate(last.capturedAt))"
        }

        let formatter = UserFacingDateTimeFormatter.current
        return "\(sampleText) - \(formatter.shortDate(first.capturedAt)) - \(formatter.shortDate(last.capturedAt))"
    }

    public var direction: UsageTrendSummary.Direction {
        guard let latestDelta else {
            return .flat
        }

        if abs(latestDelta) < Self.flatDeltaThreshold {
            return .flat
        }

        return latestDelta > 0 ? .up : .down
    }

    public var chartDomain: ClosedRange<Double> {
        guard isBalance else {
            return 0...1
        }

        guard
            let minimum = points.map(\.value).min(),
            let maximum = points.map(\.value).max()
        else {
            return 0...1
        }

        let span = maximum - minimum
        let padding = span > 0
            ? max(span * 0.15, 0.25)
            : max(abs(maximum) * 0.08, 1)
        let lowerBound = minimum < 0 ? minimum - padding : max(0, minimum - padding)
        let upperBound = max(maximum + padding, lowerBound + 1)
        return lowerBound...upperBound
    }

    public func valueDescription(for value: Double) -> String {
        if isBalance {
            return UsageHistoryFormatting.formatCurrency(
                value,
                currencyCode: currencyCode ?? "USD",
                decimalPlaces: decimalPlaces
            )
        }

        return "\(Int((value * 100).rounded()))%"
    }

    fileprivate var latestDelta: Double? {
        guard points.count >= 2 else {
            return nil
        }

        return points[points.count - 1].value - points[points.count - 2].value
    }

    private static let flatDeltaThreshold = 0.0001

}

public struct UsageHistorySeriesOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let series: UsageHistorySeries
}

@MainActor
public final class UsageHistoryStore: ObservableObject {
    @Published public private(set) var snapshots: [UsageHistorySnapshot]
    @Published public private(set) var lastError: String?
    @Published public private(set) var requiresRecovery: Bool

    private let defaults: UserDefaults
    private let retention: TimeInterval
    private let maxSnapshotsPerAccount: Int
    private let storageKey = "usageHistorySnapshots"
    private static let loadErrorMessage =
        "Saved usage history could not be read. Reset history to resume recording."

    public init(
        defaults: UserDefaults = .standard,
        retentionDays: Int = 30,
        maxSnapshotsPerAccount: Int = 240
    ) {
        self.defaults = defaults
        self.retention = TimeInterval(max(retentionDays, 1) * 24 * 60 * 60)
        self.maxSnapshotsPerAccount = max(maxSnapshotsPerAccount, 1)
        switch Self.loadSnapshots(defaults: defaults, storageKey: storageKey) {
        case let .success(snapshots):
            self.snapshots = snapshots
            self.lastError = nil
            self.requiresRecovery = false
        case .failure:
            self.snapshots = []
            self.lastError = Self.loadErrorMessage
            self.requiresRecovery = true
        }
    }

    public func record(
        results: [ProviderUsageResult],
        now: Date = Date(),
        severityThresholds: UsageSeverityThresholds = .default
    ) {
        guard !requiresRecovery else {
            return
        }

        let recordableResults = results.filter { result in
            let hasFreshBars = result.hasFreshBars && !result.bars.isEmpty
            return result.freshCreditsRemaining != nil || hasFreshBars || !result.monetaryMetrics.isEmpty
        }
        guard !recordableResults.isEmpty else {
            return
        }

        let previousSnapshots = snapshots
        var snapshotsByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        for snapshot in recordableResults.map({
            UsageHistorySnapshot(
                result: $0,
                severityThresholds: severityThresholds
            )
        }) {
            snapshotsByID[snapshot.id] = snapshot
        }
        snapshots = Array(snapshotsByID.values)
        prune(now: now, validAccountIDs: Set(recordableResults.map(\.accountID)), removeMissingAccounts: false)
        save(restoringOnFailure: previousSnapshots)
    }

    public func removeSnapshotsForMissingAccounts(validAccountIDs: Set<String>, now: Date = Date()) {
        guard !requiresRecovery else {
            return
        }

        let previousSnapshots = snapshots
        prune(now: now, validAccountIDs: validAccountIDs, removeMissingAccounts: true)
        save(restoringOnFailure: previousSnapshots)
    }

    public func discardCorruptedHistory() {
        guard requiresRecovery else {
            return
        }

        defaults.removeObject(forKey: storageKey)
        snapshots = []
        requiresRecovery = false
        lastError = nil
    }

    public func snapshots(for accountID: String, since start: Date? = nil) -> [UsageHistorySnapshot] {
        snapshots
            .filter { snapshot in
                snapshot.accountID == accountID && start.map { snapshot.capturedAt >= $0 } != false
            }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    public func historySeries(
        for result: ProviderUsageResult,
        since start: Date? = nil,
        severityThresholds: UsageSeverityThresholds = .default
    ) -> UsageHistorySeries {
        let accountSnapshots = snapshots(for: result.accountID, since: start)
        let hasUsageHistory = accountSnapshots.contains { !$0.bars.isEmpty }
        if (result.hasFreshBars && !result.bars.isEmpty)
            || (!result.bars.isEmpty && hasUsageHistory)
        {
            return usageSeries(
                for: result,
                snapshots: accountSnapshots,
                severityThresholds: severityThresholds
            )
        }

        if result.freshCreditsRemaining != nil
            || accountSnapshots.contains(where: { $0.creditsRemaining != nil })
        {
            return balanceSeries(
                accountID: result.accountID,
                snapshots: accountSnapshots,
                severityThresholds: severityThresholds
            )
        }

        let primaryMetricIdentity = primaryMonetaryMetric(in: result.monetaryMetrics).map {
            ($0.metricKind, $0.currencyCode, $0.decimalPlaces)
        } ?? accountSnapshots.reversed().lazy.compactMap { snapshot in
            self.primaryMonetaryMetric(in: snapshot.monetaryMetrics ?? []).map {
                ($0.metricKind, $0.currencyCode, $0.decimalPlaces)
            }
        }.first

        return UsageHistorySeries(
            accountID: result.accountID,
            points: accountSnapshots.compactMap { snapshot in
                guard
                    let primaryMetricIdentity,
                    let storedMetric = snapshot.monetaryMetrics?.first(where: {
                        $0.kind == primaryMetricIdentity.0
                            && $0.currencyCode == primaryMetricIdentity.1
                    })
                else {
                    return nil
                }
                return UsageHistoryPoint(
                    snapshot: snapshot,
                    value: storedMetric.doubleValue,
                    severityThresholds: severityThresholds
                )
            },
            isBalance: true,
            currencyCode: primaryMetricIdentity?.1,
            decimalPlaces: min(max(primaryMetricIdentity?.2 ?? 2, 0), 6)
        )
    }

    private func usageSeries(
        for result: ProviderUsageResult,
        snapshots: [UsageHistorySnapshot],
        severityThresholds: UsageSeverityThresholds
    ) -> UsageHistorySeries {
        if result.providerID == .cursor {
            return cursorPrimaryUsageSeries(
                accountID: result.accountID,
                snapshots: snapshots,
                severityThresholds: severityThresholds
            )
        }

        return aggregateUsageSeries(
            accountID: result.accountID,
            snapshots: snapshots,
            severityThresholds: severityThresholds
        )
    }

    private func aggregateUsageSeries(
        accountID: String,
        snapshots: [UsageHistorySnapshot],
        severityThresholds: UsageSeverityThresholds
    ) -> UsageHistorySeries {
        UsageHistorySeries(
            accountID: accountID,
            points: snapshots.compactMap { snapshot in
                snapshot.bars.map(\.fractionUsed).max().map {
                    UsageHistoryPoint(
                        snapshot: snapshot,
                        value: $0,
                        severityThresholds: severityThresholds
                    )
                }
            },
            isBalance: false
        )
    }

    private func cursorPrimaryUsageSeries(
        accountID: String,
        snapshots: [UsageHistorySnapshot],
        severityThresholds: UsageSeverityThresholds
    ) -> UsageHistorySeries {
        UsageHistorySeries(
            accountID: accountID,
            points: snapshots.compactMap { snapshot in
                let total = snapshot.bars.first(where: {
                    $0.stableKey == "total"
                        || ($0.stableKey == nil
                            && Self.matchesLegacyCursorBar($0, stableKey: "total"))
                })
                let selectedBar = total
                    ?? snapshot.bars.max(by: { $0.fractionUsed < $1.fractionUsed })
                return selectedBar.map {
                    UsageHistoryPoint(
                        id: snapshot.id,
                        capturedAt: snapshot.capturedAt,
                        value: $0.fractionUsed,
                        severity: snapshot.effectiveSeverity(
                            for: $0,
                            using: severityThresholds
                        )
                    )
                }
            },
            isBalance: false
        )
    }

    private func usageSeries(
        accountID: String,
        snapshots: [UsageHistorySnapshot],
        stableKey: String,
        severityThresholds: UsageSeverityThresholds
    ) -> UsageHistorySeries {
        UsageHistorySeries(
            accountID: accountID,
            points: snapshots.compactMap { snapshot in
                snapshot.bars.first(where: {
                    $0.stableKey == stableKey
                        || ($0.stableKey == nil && Self.matchesLegacyCursorBar($0, stableKey: stableKey))
                }).map {
                    UsageHistoryPoint(
                        id: snapshot.id,
                        capturedAt: snapshot.capturedAt,
                        value: $0.fractionUsed,
                        severity: $0.effectiveSeverity(using: severityThresholds)
                    )
                }
            },
            isBalance: false
        )
    }

    private static func matchesLegacyCursorBar(
        _ bar: UsageHistoryBarSnapshot,
        stableKey: String
    ) -> Bool {
        let label = bar.label.trimmingCharacters(in: .whitespacesAndNewlines)
        switch stableKey {
        case "total":
            return label.caseInsensitiveCompare("Total") == .orderedSame
        case "auto":
            return label.caseInsensitiveCompare("Auto") == .orderedSame
        case "api":
            return label.caseInsensitiveCompare("API") == .orderedSame
        case "on-demand":
            return label.lowercased().hasPrefix("on-demand")
        default:
            return false
        }
    }

    private func cursorUsageSeriesOptions(
        accountID: String,
        snapshots: [UsageHistorySnapshot],
        currentBars: [UsageBar],
        severityThresholds: UsageSeverityThresholds
    ) -> [UsageHistorySeriesOption] {
        let metricOptions: [UsageHistorySeriesOption] = [
            ("total", "Total"),
            ("auto", "Auto"),
            ("api", "API"),
            ("on-demand", "On-demand"),
        ].compactMap { stableKey, label in
            let isAvailable = currentBars.contains(where: { $0.stableKey == stableKey })
                || snapshots.contains(where: { snapshot in
                    snapshot.bars.contains(where: {
                        $0.stableKey == stableKey
                            || ($0.stableKey == nil
                                && Self.matchesLegacyCursorBar($0, stableKey: stableKey))
                    })
                })
            guard isAvailable else {
                return nil
            }

            return UsageHistorySeriesOption(
                id: "usage.\(stableKey)",
                label: label,
                series: usageSeries(
                    accountID: accountID,
                    snapshots: snapshots,
                    stableKey: stableKey,
                    severityThresholds: severityThresholds
                )
            )
        }

        guard !metricOptions.contains(where: { $0.id == "usage.total" }) else {
            let hasFallbackSamples = snapshots.contains(where: { snapshot in
                !snapshot.bars.isEmpty
                    && !snapshot.bars.contains(where: {
                        $0.stableKey == "total"
                            || ($0.stableKey == nil
                                && Self.matchesLegacyCursorBar($0, stableKey: "total"))
                    })
            })
            guard hasFallbackSamples else {
                return metricOptions
            }

            return [
                UsageHistorySeriesOption(
                    id: "usage",
                    label: "Total / highest available",
                    series: cursorPrimaryUsageSeries(
                        accountID: accountID,
                        snapshots: snapshots,
                        severityThresholds: severityThresholds
                    )
                ),
            ] + metricOptions
        }

        return [
            UsageHistorySeriesOption(
                id: "usage",
                label: "Highest usage",
                series: cursorPrimaryUsageSeries(
                    accountID: accountID,
                    snapshots: snapshots,
                    severityThresholds: severityThresholds
                )
            ),
        ] + metricOptions
    }

    private func balanceSeries(
        accountID: String,
        snapshots: [UsageHistorySnapshot],
        severityThresholds: UsageSeverityThresholds
    ) -> UsageHistorySeries {
        UsageHistorySeries(
            accountID: accountID,
            points: snapshots.compactMap { snapshot in
                snapshot.creditsRemaining.map {
                    UsageHistoryPoint(
                        snapshot: snapshot,
                        value: $0,
                        severityThresholds: severityThresholds
                    )
                }
            },
            isBalance: true
        )
    }

    private func primaryMonetaryMetric<T>(in metrics: [T]) -> T? where T: MonetaryMetricSnapshot {
        metrics.first(where: { $0.metricKind == .balance })
            ?? metrics.first(where: { $0.metricKind == .remainingHeadroom })
            ?? metrics.first
    }

    public func historySeriesOptions(
        for result: ProviderUsageResult,
        since start: Date? = nil,
        severityThresholds: UsageSeverityThresholds = .default
    ) -> [UsageHistorySeriesOption] {
        let accountSnapshots = snapshots(for: result.accountID, since: start)
        var options: [UsageHistorySeriesOption] = []

        if (result.hasFreshBars && !result.bars.isEmpty)
            || accountSnapshots.contains(where: { !$0.bars.isEmpty })
        {
            if result.providerID == .cursor {
                options.append(contentsOf: cursorUsageSeriesOptions(
                    accountID: result.accountID,
                    snapshots: accountSnapshots,
                    currentBars: result.bars,
                    severityThresholds: severityThresholds
                ))
            } else {
                options.append(UsageHistorySeriesOption(
                    id: "usage",
                    label: "Usage",
                    series: aggregateUsageSeries(
                        accountID: result.accountID,
                        snapshots: accountSnapshots,
                        severityThresholds: severityThresholds
                    )
                ))
            }
        }

        if result.freshCreditsRemaining != nil
            || accountSnapshots.contains(where: { $0.creditsRemaining != nil })
        {
            options.append(UsageHistorySeriesOption(
                id: "balance",
                label: "Balance",
                series: balanceSeries(
                    accountID: result.accountID,
                    snapshots: accountSnapshots,
                    severityThresholds: severityThresholds
                )
            ))
        }

        for metric in result.monetaryMetrics {
            let points = accountSnapshots.compactMap { snapshot -> UsageHistoryPoint? in
                guard let storedMetric = snapshot.monetaryMetrics?.first(where: {
                    $0.kind == metric.kind
                        && $0.currencyCode == metric.currencyCode
                }) else {
                    return nil
                }
                return UsageHistoryPoint(
                    snapshot: snapshot,
                    value: storedMetric.doubleValue,
                    severityThresholds: severityThresholds
                )
            }
            options.append(UsageHistorySeriesOption(
                id: "money.\(metric.id)",
                label: metric.label,
                series: UsageHistorySeries(
                    accountID: result.accountID,
                    points: points,
                    isBalance: true,
                    currencyCode: metric.currencyCode,
                    decimalPlaces: metric.clampedDecimalPlaces
                )
            ))
        }

        return options.isEmpty
            ? [
                UsageHistorySeriesOption(
                    id: "primary",
                    label: "Usage",
                    series: historySeries(
                        for: result,
                        since: start,
                        severityThresholds: severityThresholds
                    )
                ),
            ]
            : options
    }

    public func trendSummary(
        for result: ProviderUsageResult,
        now: Date = Date(),
        severityThresholds: UsageSeverityThresholds = .default
    ) -> UsageTrendSummary? {
        let series = historySeries(
            for: result,
            since: now.addingTimeInterval(-7 * 24 * 60 * 60),
            severityThresholds: severityThresholds
        )
        guard
            series.points.count >= 2,
            let previous = series.points.dropLast().last,
            let delta = series.latestDelta
        else {
            return nil
        }

        let direction = series.direction
        let description: String

        if direction == .flat {
            description = "No change"
        } else if series.isBalance {
            let formattedDelta = UsageHistoryFormatting.formatCurrency(
                abs(delta),
                currencyCode: series.currencyCode ?? "USD",
                decimalPlaces: series.decimalPlaces
            )
            description = "Changed \(delta > 0 ? "+" : "-")\(formattedDelta)"
        } else {
            description = "Changed \(delta > 0 ? "+" : "-")\(Int((abs(delta) * 100).rounded())) pts"
        }

        return UsageTrendSummary(
            accountID: result.accountID,
            points: series.points.map(\.value),
            valueDescription: description,
            windowDescription: "Since \(Self.formatSnapshotDate(previous.capturedAt))",
            isBalance: series.isBalance,
            direction: direction
        )
    }

    private func prune(
        now: Date,
        validAccountIDs: Set<String>,
        removeMissingAccounts: Bool
    ) {
        let cutoff = now.addingTimeInterval(-retention)
        let sorted = snapshots
            .filter { snapshot in
                snapshot.capturedAt >= cutoff
                    && (!removeMissingAccounts || validAccountIDs.contains(snapshot.accountID))
            }
            .sorted { lhs, rhs in
                if lhs.accountID != rhs.accountID {
                    return lhs.accountID < rhs.accountID
                }

                return lhs.capturedAt > rhs.capturedAt
            }

        var counts: [String: Int] = [:]
        snapshots = sorted
            .filter { snapshot in
                let count = counts[snapshot.accountID, default: 0]
                guard count < maxSnapshotsPerAccount else {
                    return false
                }

                counts[snapshot.accountID] = count + 1
                return true
            }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    private func save(restoringOnFailure previousSnapshots: [UsageHistorySnapshot]) {
        do {
            let data = try JSONEncoder().encode(snapshots)
            defaults.set(data, forKey: storageKey)
            lastError = nil
        } catch {
            snapshots = previousSnapshots
            lastError = "Could not save usage history: \(error.localizedDescription)"
        }
    }

    private static func loadSnapshots(
        defaults: UserDefaults,
        storageKey: String
    ) -> Result<[UsageHistorySnapshot], Error> {
        guard defaults.object(forKey: storageKey) != nil else {
            return .success([])
        }

        guard let data = defaults.data(forKey: storageKey) else {
            return .failure(UsageHistoryLoadError.invalidStoredValue)
        }

        do {
            let snapshots = try JSONDecoder().decode([UsageHistorySnapshot].self, from: data)
            return .success(snapshots.sorted { $0.capturedAt < $1.capturedAt })
        } catch {
            return .failure(error)
        }
    }

    private static func formatSnapshotDate(_ date: Date) -> String {
        UserFacingDateTimeFormatter.current.dateAndTime(date)
    }
}

private enum UsageHistoryLoadError: Error {
    case invalidStoredValue
}
