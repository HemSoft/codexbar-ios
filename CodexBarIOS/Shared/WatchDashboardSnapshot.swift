import Foundation

public enum WatchDashboardPayloadError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
}

public enum WatchMetricVisualizationStyle: String, CaseIterable, Equatable, Sendable {
    case automatic
    case linearBar
    case segmentedBar
    case circularRing
    case semicircularDial
    case largeNumeric

    public func resolvedForWatch(allowsGauge: Bool) -> WatchMetricVisualizationStyle {
        if self == .automatic {
            return .linearBar
        }
        if !allowsGauge && (self == .circularRing || self == .semicircularDial) {
            return .linearBar
        }
        return self
    }
}

extension WatchMetricVisualizationStyle: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .automatic
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum WatchMetricSeverity: String, Equatable, Sendable {
    case normal
    case warning
    case critical
}

extension WatchMetricSeverity: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = Self(rawValue: rawValue) ?? .normal
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct WatchMetricSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let scope: String?
    public let usedFraction: Double?
    public let remainingFraction: Double?
    public let exactValue: String
    public let severity: WatchMetricSeverity
    public let resetText: String?
    public let visualizationStyle: WatchMetricVisualizationStyle

    public init(
        id: String,
        label: String,
        scope: String? = nil,
        usedFraction: Double? = nil,
        remainingFraction: Double? = nil,
        exactValue: String,
        severity: WatchMetricSeverity = .normal,
        resetText: String? = nil,
        visualizationStyle: WatchMetricVisualizationStyle = .automatic
    ) {
        self.id = id
        self.label = label
        self.scope = scope
        self.usedFraction = usedFraction.map { min(max($0, 0), 1) }
        self.remainingFraction = remainingFraction.map { min(max($0, 0), 1) }
        self.exactValue = exactValue
        self.severity = severity
        self.resetText = resetText
        self.visualizationStyle = visualizationStyle
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case label
        case scope
        case usedFraction
        case remainingFraction
        case exactValue
        case severity
        case resetText
        case visualizationStyle
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            label: try container.decode(String.self, forKey: .label),
            scope: try container.decodeIfPresent(String.self, forKey: .scope),
            usedFraction: try container.decodeIfPresent(Double.self, forKey: .usedFraction),
            remainingFraction: try container.decodeIfPresent(Double.self, forKey: .remainingFraction),
            exactValue: try container.decode(String.self, forKey: .exactValue),
            severity: try container.decodeIfPresent(WatchMetricSeverity.self, forKey: .severity) ?? .normal,
            resetText: try container.decodeIfPresent(String.self, forKey: .resetText),
            visualizationStyle: try container.decodeIfPresent(
                WatchMetricVisualizationStyle.self,
                forKey: .visualizationStyle
            ) ?? .automatic
        )
    }
}

public struct WatchAccountSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let providerName: String
    public let accountLabel: String
    public let statusText: String?
    public let fetchedAt: Date
    public let metrics: [WatchMetricSnapshot]

    public init(
        id: String,
        providerName: String,
        accountLabel: String,
        statusText: String? = nil,
        fetchedAt: Date,
        metrics: [WatchMetricSnapshot]
    ) {
        self.id = id
        self.providerName = providerName
        self.accountLabel = accountLabel
        self.statusText = statusText
        self.fetchedAt = fetchedAt
        self.metrics = metrics
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case providerName
        case accountLabel
        case statusText
        case fetchedAt
        case metrics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedMetrics = try container.decodeIfPresent(
            [LossyDecodable<WatchMetricSnapshot>].self,
            forKey: .metrics
        ) ?? []
        self.init(
            id: try container.decode(String.self, forKey: .id),
            providerName: try container.decode(String.self, forKey: .providerName),
            accountLabel: try container.decode(String.self, forKey: .accountLabel),
            statusText: try container.decodeIfPresent(String.self, forKey: .statusText),
            fetchedAt: try container.decode(Date.self, forKey: .fetchedAt),
            metrics: decodedMetrics.compactMap(\.value)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(providerName, forKey: .providerName)
        try container.encode(accountLabel, forKey: .accountLabel)
        try container.encodeIfPresent(statusText, forKey: .statusText)
        try container.encode(fetchedAt, forKey: .fetchedAt)
        try container.encode(metrics, forKey: .metrics)
    }
}

public struct WatchDashboardSnapshot: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let applicationContextDataKey = "codexbar.dashboard.snapshot"
    public static let applicationContextVersionKey = "codexbar.dashboard.schema"

    public let schemaVersion: Int
    public let generatedAt: Date
    public let refreshIntervalSeconds: TimeInterval?
    public let accounts: [WatchAccountSnapshot]

    public init(
        schemaVersion: Int = Self.currentSchemaVersion,
        generatedAt: Date,
        refreshIntervalSeconds: TimeInterval?,
        accounts: [WatchAccountSnapshot]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.accounts = accounts
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generatedAt
        case refreshIntervalSeconds
        case accounts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedAccounts = try container.decodeIfPresent(
            [LossyDecodable<WatchAccountSnapshot>].self,
            forKey: .accounts
        ) ?? []
        self.init(
            schemaVersion: try container.decode(Int.self, forKey: .schemaVersion),
            generatedAt: try container.decode(Date.self, forKey: .generatedAt),
            refreshIntervalSeconds: try container.decodeIfPresent(
                TimeInterval.self,
                forKey: .refreshIntervalSeconds
            ),
            accounts: decodedAccounts.compactMap(\.value)
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encodeIfPresent(refreshIntervalSeconds, forKey: .refreshIntervalSeconds)
        try container.encode(accounts, forKey: .accounts)
    }

    public func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> WatchDashboardSnapshot {
        let snapshot = try decoder.decode(Self.self, from: data)
        guard snapshot.schemaVersion == currentSchemaVersion else {
            throw WatchDashboardPayloadError.unsupportedSchemaVersion(snapshot.schemaVersion)
        }
        return snapshot
    }

    public static func decodeApplicationContext(
        _ applicationContext: [String: Any]
    ) throws -> WatchDashboardSnapshot {
        guard let data = applicationContext[applicationContextDataKey] as? Data else {
            throw CocoaError(.coderReadCorrupt)
        }
        return try decode(data)
    }

    public func applicationContext() throws -> [String: Any] {
        [
            Self.applicationContextVersionKey: schemaVersion,
            Self.applicationContextDataKey: try encoded(),
        ]
    }

    public func semanticData() throws -> Data {
        try Self.encoder.encode(
            Self(
                schemaVersion: schemaVersion,
                generatedAt: .distantPast,
                refreshIntervalSeconds: refreshIntervalSeconds,
                accounts: accounts
            )
        )
    }

    public func isStale(at date: Date) -> Bool {
        let refreshWindow = refreshIntervalSeconds.map { max($0 * 2, 15 * 60) } ?? 60 * 60
        return date.timeIntervalSince(generatedAt) > refreshWindow
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }()
}

private struct LossyDecodable<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: Decoder) throws {
        value = try? Value(from: decoder)
    }
}
