import Foundation

enum WatchComplicationConstants {
    static let appGroupIdentifier = "group.com.hemsoft.CodexBarIOS"
    static let widgetKind = "CodexBarWatchUsageComplication"
    static let snapshotDefaultsKey = "watch.complication.last-good-snapshot"
}

struct WatchComplicationSelection: Equatable, Sendable {
    let accountID: String?
    let metricID: String?

    static let automatic = WatchComplicationSelection(accountID: nil, metricID: nil)

    static func resolving(
        accountID: String?,
        metricAccountID: String?,
        metricID: String?
    ) -> WatchComplicationSelection {
        let resolvedAccountID = accountID ?? metricAccountID
        let resolvedMetricID = metricAccountID == nil || metricAccountID == resolvedAccountID
            ? metricID
            : nil
        return WatchComplicationSelection(
            accountID: resolvedAccountID,
            metricID: resolvedMetricID
        )
    }
}

struct WatchComplicationAccountChoice: Equatable, Sendable {
    let id: String
    let providerName: String
    let accountLabel: String
}

struct WatchComplicationMetricChoice: Equatable, Sendable {
    let id: String
    let accountID: String
    let metricID: String
    let providerName: String
    let accountLabel: String
    let metricLabel: String

    var subtitle: String {
        [providerName, accountLabel]
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }
}

struct WatchComplicationChoiceCatalog {
    private let snapshot: WatchDashboardSnapshot?

    init(snapshot: WatchDashboardSnapshot?) {
        self.snapshot = snapshot
    }

    var accounts: [WatchComplicationAccountChoice] {
        (snapshot?.accounts ?? [])
            .filter { !$0.metrics.isEmpty }
            .map {
                WatchComplicationAccountChoice(
                    id: $0.id,
                    providerName: $0.providerName,
                    accountLabel: $0.accountLabel
                )
            }
    }

    var metrics: [WatchComplicationMetricChoice] {
        (snapshot?.accounts ?? []).flatMap { account in
            account.metrics.map { metric in
                WatchComplicationMetricChoice(
                    id: Self.metricChoiceID(accountID: account.id, metricID: metric.id),
                    accountID: account.id,
                    metricID: metric.id,
                    providerName: account.providerName,
                    accountLabel: account.accountLabel,
                    metricLabel: metric.label
                )
            }
        }
    }

    func accounts(for identifiers: [String]) -> [WatchComplicationAccountChoice] {
        let choicesByID = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        return identifiers.map { identifier in
            choicesByID[identifier] ?? WatchComplicationAccountChoice(
                id: identifier,
                providerName: "Saved Account",
                accountLabel: "Open CodexBar to refresh"
            )
        }
    }

    func metrics(for identifiers: [String]) -> [WatchComplicationMetricChoice] {
        let choicesByID = Dictionary(uniqueKeysWithValues: metrics.map { ($0.id, $0) })
        return identifiers.map { identifier in
            choicesByID[identifier] ?? Self.savedMetricChoice(identifier: identifier)
        }
    }

    static func metricChoiceID(accountID: String, metricID: String) -> String {
        "\(accountID)::\(metricID)"
    }

    private static func savedMetricChoice(identifier: String) -> WatchComplicationMetricChoice {
        let accountID: String
        let metricID: String
        if let separator = identifier.range(of: "::") {
            accountID = String(identifier[..<separator.lowerBound])
            metricID = String(identifier[separator.upperBound...])
        } else {
            accountID = identifier
            metricID = "__saved-metric"
        }
        return WatchComplicationMetricChoice(
            id: identifier,
            accountID: accountID,
            metricID: metricID,
            providerName: "Saved Account",
            accountLabel: "Open CodexBar to refresh",
            metricLabel: "Saved Metric"
        )
    }
}

enum WatchComplicationAvailability: Equatable, Sendable {
    case empty
    case unavailable
    case value
}

struct WatchComplicationSample: Equatable, Sendable {
    let availability: WatchComplicationAvailability
    let providerName: String
    let accountLabel: String
    let metricLabel: String
    let exactValue: String
    let usedFraction: Double?
    let severity: WatchMetricSeverity
    let resetText: String?
    let freshnessText: String
    let isStale: Bool

    static let empty = WatchComplicationSample(
        availability: .empty,
        providerName: "CodexBar",
        accountLabel: "",
        metricLabel: "Open iPhone app",
        exactValue: "--",
        usedFraction: nil,
        severity: .normal,
        resetText: nil,
        freshnessText: "No usage yet",
        isStale: false
    )

    static let unavailable = WatchComplicationSample(
        availability: .unavailable,
        providerName: "CodexBar",
        accountLabel: "",
        metricLabel: "Selection unavailable",
        exactValue: "--",
        usedFraction: nil,
        severity: .warning,
        resetText: nil,
        freshnessText: "Open iPhone app",
        isStale: false
    )

    var clampedUsedFraction: Double {
        min(max(usedFraction ?? 0, 0), 1)
    }

    var supportsGauge: Bool {
        availability == .value && usedFraction != nil
    }

    var cornerContextLabel: String {
        guard availability == .value else {
            return "CodexBar"
        }
        return isStale ? "Stale • \(metricLabel)" : metricLabel
    }

    var stateLabel: String? {
        let freshnessState = isStale ? "Stale" : nil
        let severityState: String?
        switch severity {
        case .normal:
            severityState = nil
        case .warning:
            severityState = "Warning"
        case .critical:
            severityState = "Critical"
        }
        let labels = [freshnessState, severityState].compactMap { $0 }
        return labels.isEmpty ? nil : labels.joined(separator: " • ")
    }

    var accessibilityLabel: String {
        [
            providerName,
            accountLabel,
            metricLabel,
            exactValue,
            stateLabel,
            resetText,
            freshnessText,
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: ", ")
    }
}

struct WatchComplicationResolver {
    func resolve(
        snapshot: WatchDashboardSnapshot?,
        selection: WatchComplicationSelection,
        at date: Date
    ) -> WatchComplicationSample {
        guard let snapshot else {
            return .empty
        }

        let accounts = snapshot.accounts.filter { !$0.metrics.isEmpty }
        guard !accounts.isEmpty else {
            return .empty
        }

        guard let account = displayedAccount(in: accounts, selection: selection) else {
            return .unavailable
        }

        let metric: WatchMetricSnapshot
        if let metricID = selection.metricID {
            guard let selected = account.metrics.first(where: { $0.id == metricID }) else {
                return .unavailable
            }
            metric = selected
        } else {
            metric = account.metrics[0]
        }

        return WatchComplicationSample(
            availability: .value,
            providerName: account.providerName,
            accountLabel: account.accountLabel,
            metricLabel: metric.label,
            exactValue: metric.exactValue,
            usedFraction: metric.usedFraction,
            severity: metric.severity,
            resetText: metric.resetText,
            freshnessText: Self.freshnessText(account.fetchedAt, now: date),
            isStale: snapshot.isStale(dataDate: account.fetchedAt, at: date)
        )
    }

    func nextReloadDate(
        snapshot: WatchDashboardSnapshot?,
        selection: WatchComplicationSelection,
        now: Date
    ) -> Date {
        guard let snapshot else {
            return now.addingTimeInterval(30 * 60)
        }

        let accounts = snapshot.accounts.filter { !$0.metrics.isEmpty }
        let account = displayedAccount(in: accounts, selection: selection)

        guard let account else {
            return now.addingTimeInterval(30 * 60)
        }

        let staleWindow = snapshot.refreshIntervalSeconds.map {
            max($0 * 2, 15 * 60)
        } ?? 60 * 60
        let staleDate = account.fetchedAt.addingTimeInterval(staleWindow + 1)
        if staleDate > now {
            return max(staleDate, now.addingTimeInterval(60))
        }

        let retryInterval = max(snapshot.refreshIntervalSeconds ?? 60 * 60, 15 * 60)
        return now.addingTimeInterval(retryInterval)
    }

    func timelineEntryDates(
        snapshot: WatchDashboardSnapshot?,
        selection: WatchComplicationSelection,
        now: Date
    ) -> [Date] {
        guard let snapshot else {
            return [now]
        }

        let accounts = snapshot.accounts.filter { !$0.metrics.isEmpty }
        guard let account = displayedAccount(in: accounts, selection: selection) else {
            return [now]
        }

        let staleDate = nextReloadDate(snapshot: snapshot, selection: selection, now: now)
        guard !snapshot.isStale(dataDate: account.fetchedAt, at: now), staleDate > now else {
            return [now]
        }

        var dates = [now]
        let elapsedMinutes = floor(max(0, now.timeIntervalSince(account.fetchedAt)) / 60)
        var transition = account.fetchedAt.addingTimeInterval((elapsedMinutes + 1) * 60)
        let firstHourEnd = account.fetchedAt.addingTimeInterval(60 * 60)

        while transition < staleDate, transition <= firstHourEnd {
            dates.append(transition)
            transition = transition.addingTimeInterval(60)
        }

        if transition < staleDate {
            let elapsedHours = floor(max(1, now.timeIntervalSince(account.fetchedAt) / (60 * 60)))
            transition = account.fetchedAt.addingTimeInterval((elapsedHours + 1) * 60 * 60)
            while transition < staleDate {
                dates.append(transition)
                transition = transition.addingTimeInterval(60 * 60)
            }
        }

        dates.append(staleDate)
        return Array(Set(dates)).sorted()
    }

    private func displayedAccount(
        in accounts: [WatchAccountSnapshot],
        selection: WatchComplicationSelection
    ) -> WatchAccountSnapshot? {
        if let accountID = selection.accountID {
            return accounts.first { $0.id == accountID }
        }
        return accounts.first
    }

    private static func freshnessText(_ fetchedAt: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(fetchedAt)))
        if seconds < 60 {
            return "Updated now"
        }
        if seconds < 3_600 {
            return "Updated \(seconds / 60)m ago"
        }
        if seconds < 86_400 {
            return "Updated \(seconds / 3_600)h ago"
        }
        return "Updated \(seconds / 86_400)d ago"
    }
}

struct WatchComplicationSnapshotStore {
    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = UserDefaults(
            suiteName: WatchComplicationConstants.appGroupIdentifier
        ) ?? .standard
    ) {
        self.defaults = defaults
    }

    func load() -> WatchDashboardSnapshot? {
        guard let data = defaults.data(forKey: WatchComplicationConstants.snapshotDefaultsKey) else {
            return nil
        }
        return try? WatchDashboardSnapshot.decode(data)
    }

    @discardableResult
    func saveIfChanged(_ snapshot: WatchDashboardSnapshot) throws -> Bool {
        let data = try snapshot.encoded()
        guard defaults.data(forKey: WatchComplicationConstants.snapshotDefaultsKey) != data else {
            return false
        }
        defaults.set(data, forKey: WatchComplicationConstants.snapshotDefaultsKey)
        return true
    }
}

enum WatchComplicationFamilyLayout: CaseIterable, Hashable, Sendable {
    case inline
    case circular
    case rectangular
    case corner

    var showsResetContext: Bool {
        self == .rectangular
    }

    var usesGauge: Bool {
        self == .circular || self == .corner
    }

    func usesGauge(for sample: WatchComplicationSample) -> Bool {
        usesGauge && sample.supportsGauge
    }
}
