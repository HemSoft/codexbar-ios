import Foundation

public enum CodexBarWidgetConstants {
    public static let appGroupIdentifier = "group.com.hemsoft.CodexBarIOS"
    public static let widgetKind = "CodexBarUsageWidget"
}

public struct CodexBarWidgetSnapshot: Codable, Equatable, Sendable {
    public let generatedAt: Date
    public let results: [CodexBarWidgetProviderSnapshot]

    public init(generatedAt: Date, results: [CodexBarWidgetProviderSnapshot]) {
        self.generatedAt = generatedAt
        self.results = results
    }

    public static let empty = CodexBarWidgetSnapshot(generatedAt: .distantPast, results: [])
}

public struct CodexBarWidgetProviderSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let accountID: String
    public let providerID: String
    public let title: String
    public let subtitle: String
    public let bars: [CodexBarWidgetUsageBarSnapshot]
    public let creditsRemaining: Double?
    public let fetchedAt: Date
    public let severity: CodexBarWidgetSeverity

    public init(
        accountID: String,
        providerID: String,
        title: String,
        subtitle: String,
        bars: [CodexBarWidgetUsageBarSnapshot],
        creditsRemaining: Double?,
        fetchedAt: Date,
        severity: CodexBarWidgetSeverity
    ) {
        self.accountID = accountID
        self.providerID = providerID
        self.title = title
        self.subtitle = subtitle
        self.bars = bars
        self.creditsRemaining = creditsRemaining
        self.fetchedAt = fetchedAt
        self.severity = severity
    }

    public var id: String {
        accountID
    }
}

public struct CodexBarWidgetUsageBarSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let fractionUsed: Double
    public let usageText: String
    public let resetDescription: String?
    public let severity: CodexBarWidgetSeverity
    public let projectedFraction: Double?
    public let projectionDescription: String?
    public let projectedSeverity: CodexBarWidgetSeverity?

    public init(
        id: String,
        label: String,
        fractionUsed: Double,
        usageText: String,
        resetDescription: String?,
        severity: CodexBarWidgetSeverity,
        projectedFraction: Double? = nil,
        projectionDescription: String? = nil,
        projectedSeverity: CodexBarWidgetSeverity? = nil
    ) {
        self.id = id
        self.label = label
        self.fractionUsed = fractionUsed
        self.usageText = usageText
        self.resetDescription = resetDescription
        self.severity = severity
        self.projectedFraction = projectedFraction
        self.projectionDescription = projectionDescription
        self.projectedSeverity = projectedSeverity
    }

    public var effectiveSeverity: CodexBarWidgetSeverity {
        max(severity, projectedSeverity ?? .normal)
    }

    public var effectiveFractionUsed: Double {
        max(fractionUsed, projectedFraction ?? 0)
    }
}

public enum CodexBarWidgetSeverity: String, Codable, Comparable, Sendable {
    case normal
    case warning
    case critical

    public static func < (lhs: CodexBarWidgetSeverity, rhs: CodexBarWidgetSeverity) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .normal:
            0
        case .warning:
            1
        case .critical:
            2
        }
    }
}

public enum WidgetSnapshotStore {
    private static let snapshotKey = "widgetUsageSnapshot"
    private static let refreshIntervalKey = "widgetRefreshInterval"

    public static func userDefaults(suiteName: String = CodexBarWidgetConstants.appGroupIdentifier) -> UserDefaults? {
        UserDefaults(suiteName: suiteName)
    }

    public static func loadSnapshot(defaults: UserDefaults? = userDefaults()) -> CodexBarWidgetSnapshot {
        guard
            let data = defaults?.data(forKey: snapshotKey),
            let snapshot = try? JSONDecoder().decode(CodexBarWidgetSnapshot.self, from: data)
        else {
            return .empty
        }

        return snapshot
    }

    public static func saveSnapshot(
        _ snapshot: CodexBarWidgetSnapshot,
        defaults: UserDefaults? = userDefaults()
    ) {
        guard let data = try? JSONEncoder().encode(snapshot) else {
            return
        }

        defaults?.set(data, forKey: snapshotKey)
    }

    public static func loadRefreshInterval(defaults: UserDefaults? = userDefaults()) -> WidgetRefreshInterval {
        guard
            let rawValue = defaults?.object(forKey: refreshIntervalKey) as? Int,
            let interval = WidgetRefreshInterval(rawValue: rawValue)
        else {
            return .thirtyMinutes
        }

        return interval
    }

    public static func saveRefreshInterval(
        _ interval: WidgetRefreshInterval,
        defaults: UserDefaults? = userDefaults()
    ) {
        defaults?.set(interval.rawValue, forKey: refreshIntervalKey)
    }
}
