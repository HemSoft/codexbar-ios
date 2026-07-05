import Foundation

public struct UsageHistoryBarSnapshot: Equatable, Codable, Sendable {
    public let label: String
    public let fractionUsed: Double
    public let used: Double
    public let limit: Double

    public init(bar: UsageBar) {
        self.label = bar.label
        self.fractionUsed = bar.fractionUsed
        self.used = bar.used
        self.limit = bar.limit
    }
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
    public let highestSeverity: UsageSeverity

    public init(result: ProviderUsageResult, capturedAt: Date? = nil) {
        let capturedAt = capturedAt ?? result.fetchedAt
        self.id = "\(result.accountID).\(capturedAt.timeIntervalSince1970)"
        self.accountID = result.accountID
        self.providerID = result.providerID
        self.title = result.title
        self.subtitle = result.subtitle
        self.capturedAt = capturedAt
        self.bars = result.bars.map(UsageHistoryBarSnapshot.init)
        self.creditsRemaining = result.creditsRemaining
        self.highestSeverity = result.highestSeverity(at: capturedAt)
    }

    public var primaryValue: Double? {
        if let creditsRemaining {
            return creditsRemaining
        }

        return bars.map(\.fractionUsed).max()
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

@MainActor
public final class UsageHistoryStore: ObservableObject {
    @Published public private(set) var snapshots: [UsageHistorySnapshot]

    private let defaults: UserDefaults
    private let retention: TimeInterval
    private let maxSnapshotsPerAccount: Int
    private let storageKey = "usageHistorySnapshots"

    public init(
        defaults: UserDefaults = .standard,
        retentionDays: Int = 30,
        maxSnapshotsPerAccount: Int = 240
    ) {
        self.defaults = defaults
        self.retention = TimeInterval(max(retentionDays, 1) * 24 * 60 * 60)
        self.maxSnapshotsPerAccount = max(maxSnapshotsPerAccount, 1)
        self.snapshots = Self.loadSnapshots(defaults: defaults, storageKey: storageKey)
    }

    public func record(results: [ProviderUsageResult], now: Date = Date()) {
        let recordableResults = results.filter { result in
            result.creditsRemaining != nil || !result.bars.isEmpty
        }
        guard !recordableResults.isEmpty else {
            return
        }

        var snapshotsByID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
        for snapshot in recordableResults.map({ UsageHistorySnapshot(result: $0) }) {
            snapshotsByID[snapshot.id] = snapshot
        }
        snapshots = Array(snapshotsByID.values)
        prune(now: now, validAccountIDs: Set(recordableResults.map(\.accountID)), removeMissingAccounts: false)
        save()
    }

    public func removeSnapshotsForMissingAccounts(validAccountIDs: Set<String>, now: Date = Date()) {
        prune(now: now, validAccountIDs: validAccountIDs, removeMissingAccounts: true)
        save()
    }

    public func snapshots(for accountID: String, since start: Date? = nil) -> [UsageHistorySnapshot] {
        snapshots
            .filter { snapshot in
                snapshot.accountID == accountID && start.map { snapshot.capturedAt >= $0 } != false
            }
            .sorted { $0.capturedAt < $1.capturedAt }
    }

    public func trendSummary(for result: ProviderUsageResult, now: Date = Date()) -> UsageTrendSummary? {
        let recent = snapshots(
            for: result.accountID,
            since: now.addingTimeInterval(-7 * 24 * 60 * 60)
        )
        guard recent.count >= 2 else {
            return nil
        }

        let values = recent.compactMap(\.primaryValue)
        guard values.count >= 2, let previous = values.dropLast().last, let current = values.last else {
            return nil
        }

        let delta = current - previous
        let isBalance = result.creditsRemaining != nil
        let direction: UsageTrendSummary.Direction
        let description: String

        if abs(delta) < 0.0001 {
            direction = .flat
            description = isBalance ? "Balance unchanged" : "Usage unchanged"
        } else if isBalance {
            direction = delta > 0 ? .up : .down
            description = "\(delta > 0 ? "Up" : "Down") \(Self.formatCurrency(abs(delta))) since last snapshot"
        } else {
            direction = delta > 0 ? .up : .down
            description = "\(delta > 0 ? "+" : "-")\(Int((abs(delta) * 100).rounded())) pts since last snapshot"
        }

        return UsageTrendSummary(
            accountID: result.accountID,
            points: values,
            valueDescription: description,
            windowDescription: "\(recent.count) snapshots / 7d",
            isBalance: isBalance,
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

    private func save() {
        if let data = try? JSONEncoder().encode(snapshots) {
            defaults.set(data, forKey: storageKey)
        }
    }

    private static func loadSnapshots(defaults: UserDefaults, storageKey: String) -> [UsageHistorySnapshot] {
        guard
            let data = defaults.data(forKey: storageKey),
            let snapshots = try? JSONDecoder().decode([UsageHistorySnapshot].self, from: data)
        else {
            return []
        }

        return snapshots.sorted { $0.capturedAt < $1.capturedAt }
    }

    private static func formatCurrency(_ value: Double) -> String {
        currencyFormatter.string(from: NSNumber(value: value)) ?? "$0.00"
    }

    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}
