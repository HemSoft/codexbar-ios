import Foundation

public enum MetricVisualizationStyle: String, CaseIterable, Equatable, Sendable, Identifiable {
    case automatic
    case linearBar
    case segmentedBar
    case circularRing
    case semicircularDial
    case largeNumeric

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .automatic:
            String(localized: "Automatic")
        case .linearBar:
            String(localized: "Linear bar")
        case .segmentedBar:
            String(localized: "Segmented bar")
        case .circularRing:
            String(localized: "Circular ring")
        case .semicircularDial:
            String(localized: "Semicircular dial")
        case .largeNumeric:
            String(localized: "Large numeric")
        }
    }

    public func resolvedForWidget(allowsGauge: Bool) -> MetricVisualizationStyle {
        if self == .automatic {
            return .linearBar
        }
        if !allowsGauge && (self == .circularRing || self == .semicircularDial) {
            return .linearBar
        }
        return self
    }
}

extension MetricVisualizationStyle: Codable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self = MetricVisualizationStyle(rawValue: rawValue) ?? .automatic
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

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
    public static let preview = CodexBarWidgetSnapshot(
        generatedAt: Date(),
        results: [
            previewUsageProvider(
                id: "codex",
                title: "ChatGPT / Codex",
                subtitle: "Pro",
                barLabel: "5-hour usage limit",
                fractionUsed: 0.42
            ),
            previewUsageProvider(
                id: "copilot",
                title: "GitHub Copilot",
                subtitle: "Individual",
                barLabel: "Premium requests",
                fractionUsed: 0.73
            ),
            previewUsageProvider(
                id: "claude",
                title: "Claude",
                subtitle: "Pro",
                barLabel: "All models weekly usage limit",
                fractionUsed: 0.58
            ),
            previewUsageProvider(
                id: "cursor",
                title: "Cursor",
                subtitle: "Pro",
                barLabel: "Monthly included usage",
                fractionUsed: 0.51
            ),
            previewBalanceProvider(
                id: "moonshot",
                title: "Moonshot (Kimi)",
                balance: 24.15
            ),
            previewBalanceProvider(
                id: "openCodeZen",
                title: "OpenCode ZEN",
                balance: 12.48
            ),
            previewBalanceProvider(
                id: "openRouter",
                title: "OpenRouter",
                balance: 18.72
            ),
        ]
    )

    private static func previewUsageProvider(
        id: String,
        title: String,
        subtitle: String,
        barLabel: String,
        fractionUsed: Double
    ) -> CodexBarWidgetProviderSnapshot {
        CodexBarWidgetProviderSnapshot(
            accountID: id,
            providerID: id,
            title: title,
            subtitle: subtitle,
            bars: [
                CodexBarWidgetUsageBarSnapshot(
                    id: "\(id).preview",
                    label: barLabel,
                    fractionUsed: fractionUsed,
                    usageText: "\(Int((fractionUsed * 100).rounded()))%",
                    resetDescription: "Resets soon",
                    severity: CodexBarWidgetSeverity(fractionUsed: fractionUsed)
                )
            ],
            creditsRemaining: nil,
            fetchedAt: Date(),
            severity: CodexBarWidgetSeverity(fractionUsed: fractionUsed)
        )
    }

    private static func previewBalanceProvider(
        id: String,
        title: String,
        balance: Double
    ) -> CodexBarWidgetProviderSnapshot {
        CodexBarWidgetProviderSnapshot(
            accountID: id,
            providerID: id,
            title: title,
            subtitle: "API balance",
            bars: [],
            creditsRemaining: balance,
            fetchedAt: Date(),
            severity: .normal
        )
    }
}

public struct CodexBarWidgetProviderSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let accountID: String
    public let providerID: String
    public let title: String
    public let subtitle: String
    public let groupID: String?
    public let groupName: String?
    public let bars: [CodexBarWidgetUsageBarSnapshot]
    public let creditsRemaining: Double?
    public let monetaryMetrics: [CodexBarWidgetMonetaryMetricSnapshot]?
    public let usageMessages: [String]?
    public let fetchedAt: Date
    public let severity: CodexBarWidgetSeverity

    public init(
        accountID: String,
        providerID: String,
        title: String,
        subtitle: String,
        groupID: String? = nil,
        groupName: String? = nil,
        bars: [CodexBarWidgetUsageBarSnapshot],
        creditsRemaining: Double?,
        monetaryMetrics: [CodexBarWidgetMonetaryMetricSnapshot] = [],
        usageMessages: [String] = [],
        fetchedAt: Date,
        severity: CodexBarWidgetSeverity
    ) {
        self.accountID = accountID
        self.providerID = providerID
        self.title = title
        self.subtitle = subtitle
        self.groupID = groupID
        self.groupName = groupName
        self.bars = bars
        self.creditsRemaining = creditsRemaining
        self.monetaryMetrics = monetaryMetrics
        self.usageMessages = usageMessages
        self.fetchedAt = fetchedAt
        self.severity = severity
    }

    public var id: String {
        accountID
    }

    public var summaryMonetaryMetric: CodexBarWidgetMonetaryMetricSnapshot? {
        guard bars.isEmpty, creditsRemaining == nil else {
            return nil
        }
        return monetaryMetrics?.first
    }

    public var standaloneMonetaryMetrics: [CodexBarWidgetMonetaryMetricSnapshot] {
        let summaryMetricID = summaryMonetaryMetric?.id
        return (monetaryMetrics ?? []).filter { $0.id != summaryMetricID }
    }
}

public struct CodexBarWidgetMonetaryMetricSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let kind: String
    public let label: String
    public let minorUnits: Decimal
    public let currencyCode: String
    public let decimalPlaces: Int
    public let detail: String?

    public init(
        kind: String,
        label: String,
        minorUnits: Decimal,
        currencyCode: String,
        decimalPlaces: Int,
        detail: String?
    ) {
        self.kind = kind
        self.label = label
        self.minorUnits = minorUnits
        self.currencyCode = currencyCode
        self.decimalPlaces = decimalPlaces
        self.detail = detail
    }

    public var id: String {
        "\(kind).\(label).\(currencyCode)"
    }

    public var formattedAmount: String {
        let decimalPlaces = min(max(self.decimalPlaces, 0), 6)
        var divisor = Decimal(1)
        for _ in 0..<decimalPlaces {
            divisor *= 10
        }
        let amount = NSDecimalNumber(decimal: minorUnits / divisor)
        return amount.decimalValue.formatted(
            .currency(code: currencyCode)
                .precision(.fractionLength(decimalPlaces))
        )
    }
}

public struct CodexBarWidgetUsageBarSnapshot: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public let metricID: String?
    public let label: String
    public let fractionUsed: Double
    public let usageText: String
    public let resetDescription: String?
    public let resetsAt: Date?
    public let resetDisplayStyle: UsageResetDisplayStyle?
    public let severity: CodexBarWidgetSeverity
    public let projectedFraction: Double?
    public let projectionDescription: String?
    public let projectionLeadingText: String?
    public let projectionTimestamp: Date?
    public let projectionTrailingText: String?
    public let projectedSeverity: CodexBarWidgetSeverity?
    public let visualizationStyle: MetricVisualizationStyle?

    public init(
        id: String,
        metricID: String? = nil,
        label: String,
        fractionUsed: Double,
        usageText: String,
        resetDescription: String?,
        resetsAt: Date? = nil,
        resetDisplayStyle: UsageResetDisplayStyle? = nil,
        severity: CodexBarWidgetSeverity,
        projectedFraction: Double? = nil,
        projectionDescription: String? = nil,
        projectionLeadingText: String? = nil,
        projectionTimestamp: Date? = nil,
        projectionTrailingText: String? = nil,
        projectedSeverity: CodexBarWidgetSeverity? = nil,
        visualizationStyle: MetricVisualizationStyle? = nil
    ) {
        self.id = id
        self.metricID = metricID
        self.label = label
        self.fractionUsed = fractionUsed
        self.usageText = usageText
        self.resetDescription = resetDescription
        self.resetsAt = resetsAt
        self.resetDisplayStyle = resetDisplayStyle
        self.severity = severity
        self.projectedFraction = projectedFraction
        self.projectionDescription = projectionDescription
        self.projectionLeadingText = projectionLeadingText
        self.projectionTimestamp = projectionTimestamp
        self.projectionTrailingText = projectionTrailingText
        self.projectedSeverity = projectedSeverity
        self.visualizationStyle = visualizationStyle
    }

    public var effectiveSeverity: CodexBarWidgetSeverity {
        max(severity, projectedSeverity ?? .normal)
    }

    public var effectiveFractionUsed: Double {
        max(fractionUsed, projectedFraction ?? 0)
    }

    public func localizedResetDescription(
        at now: Date = Date(),
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) -> String? {
        dateTimeFormatter.resetDescription(
            resetAt: resetsAt,
            now: now,
            style: resetDisplayStyle ?? .verbatim,
            fallback: resetDescription
        )
    }

    public func localizedProjectionDescription(
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) -> String? {
        guard let projectionLeadingText else {
            return projectionDescription
        }

        guard let projectionTimestamp else {
            return projectionLeadingText
        }

        return "\(projectionLeadingText)\(dateTimeFormatter.timeWithZone(projectionTimestamp, includesWeekday: true))\(projectionTrailingText ?? "")"
    }
}

public enum CodexBarWidgetSeverity: String, Codable, Comparable, Sendable {
    case normal
    case warning
    case critical

    public init(fractionUsed: Double) {
        if fractionUsed >= 0.9 {
            self = .critical
        } else if fractionUsed >= 0.75 {
            self = .warning
        } else {
            self = .normal
        }
    }

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
    private static let builderConfigurationKey = "widgetBuilderConfiguration"

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

    public static func loadSnapshot(
        forPreview isPreview: Bool,
        defaults: UserDefaults? = userDefaults()
    ) -> CodexBarWidgetSnapshot {
        isPreview ? .preview : loadSnapshot(defaults: defaults)
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

    public static func loadBuilderConfiguration(
        defaults: UserDefaults? = userDefaults()
    ) -> CodexBarWidgetBuilderConfiguration {
        guard
            let data = defaults?.data(forKey: builderConfigurationKey),
            let configuration = try? JSONDecoder().decode(CodexBarWidgetBuilderConfiguration.self, from: data)
        else {
            return .default
        }

        return CodexBarWidgetBuilderConfiguration(
            layout: configuration.layout,
            selectedTileIDs: configuration.selectedTileIDs,
            displayModes: configuration.displayModes
        )
    }

    public static func loadBuilderConfiguration(
        forPreview isPreview: Bool,
        defaults: UserDefaults? = userDefaults()
    ) -> CodexBarWidgetBuilderConfiguration {
        isPreview ? .default : loadBuilderConfiguration(defaults: defaults)
    }

    public static func saveBuilderConfiguration(
        _ configuration: CodexBarWidgetBuilderConfiguration,
        defaults: UserDefaults? = userDefaults()
    ) {
        guard let data = try? JSONEncoder().encode(configuration) else {
            return
        }

        defaults?.set(data, forKey: builderConfigurationKey)
    }
}
