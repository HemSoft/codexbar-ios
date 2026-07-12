import Foundation

public enum CodexBarWidgetBuilderLayout: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case oneTile
    case twoTiles
    case fourTiles

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .automatic:
            "Auto"
        case .oneTile:
            "1"
        case .twoTiles:
            "2"
        case .fourTiles:
            "4"
        }
    }

    public func tileCount(maximum: Int, automaticCount: Int) -> Int {
        switch self {
        case .automatic:
            min(maximum, automaticCount)
        case .oneTile:
            min(maximum, 1)
        case .twoTiles:
            min(maximum, 2)
        case .fourTiles:
            min(maximum, 4)
        }
    }

    public var previewTileCount: Int {
        switch self {
        case .automatic:
            4
        case .oneTile:
            1
        case .twoTiles:
            2
        case .fourTiles:
            4
        }
    }
}

public enum CodexBarWidgetBuilderDisplayMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case automatic
    case compactPercent
    case fullBar
    case balanceOnly
    case urgentStatus

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .automatic:
            "Automatic"
        case .compactPercent:
            "Compact Percent"
        case .fullBar:
            "Full Bar"
        case .balanceOnly:
            "Balance Only"
        case .urgentStatus:
            "Urgent Status"
        }
    }
}

public struct CodexBarWidgetBuilderConfiguration: Codable, Equatable, Sendable {
    public static let maximumSlots = 4
    public static let `default` = CodexBarWidgetBuilderConfiguration()

    public var layout: CodexBarWidgetBuilderLayout
    public var selectedTileIDs: [String?]
    public var displayModes: [CodexBarWidgetBuilderDisplayMode]

    public init(
        layout: CodexBarWidgetBuilderLayout = .automatic,
        selectedTileIDs: [String?] = [],
        displayModes: [CodexBarWidgetBuilderDisplayMode] = []
    ) {
        self.layout = layout
        self.selectedTileIDs = Array(selectedTileIDs.prefix(Self.maximumSlots))
        self.displayModes = Array(displayModes.prefix(Self.maximumSlots))
    }

    public var hasSelectedTiles: Bool {
        selectedTileIDs.contains { $0 != nil }
    }

    public var hasCustomizations: Bool {
        layout != .automatic
            || hasSelectedTiles
            || displayModes.contains { $0 != .automatic }
    }

    public func tileID(at index: Int) -> String? {
        selectedTileIDs.indices.contains(index) ? selectedTileIDs[index] : nil
    }

    public func displayMode(at index: Int) -> CodexBarWidgetBuilderDisplayMode {
        displayModes.indices.contains(index) ? displayModes[index] : .automatic
    }

    public mutating func setTileID(_ tileID: String?, at index: Int) {
        guard index >= 0, index < Self.maximumSlots else {
            return
        }

        growSelectedTiles(toInclude: index)
        selectedTileIDs[index] = tileID
        trimTrailingEmptySlots()
    }

    public mutating func setDisplayMode(_ displayMode: CodexBarWidgetBuilderDisplayMode, at index: Int) {
        guard index >= 0, index < Self.maximumSlots else {
            return
        }

        while displayModes.count <= index {
            displayModes.append(.automatic)
        }
        displayModes[index] = displayMode
        trimTrailingAutomaticModes()
    }

    private mutating func growSelectedTiles(toInclude index: Int) {
        while selectedTileIDs.count <= index {
            selectedTileIDs.append(nil)
        }
    }

    private mutating func trimTrailingEmptySlots() {
        while selectedTileIDs.last == .some(nil) {
            selectedTileIDs.removeLast()
        }
    }

    private mutating func trimTrailingAutomaticModes() {
        while displayModes.last == .automatic {
            displayModes.removeLast()
        }
    }
}

public struct CodexBarWidgetBuilderTile: Equatable, Identifiable, Sendable {
    public let id: String
    public let providerID: String
    public let providerTitle: String
    public let title: String
    public let subtitle: String
    public let value: String
    public let fractionUsed: Double?
    public let creditsRemaining: Double?
    public let severity: CodexBarWidgetSeverity

    public static func unavailable(id: String) -> CodexBarWidgetBuilderTile {
        CodexBarWidgetBuilderTile(
            id: id,
            providerID: "unavailable",
            providerTitle: "Saved Tile",
            title: "Saved Tile",
            subtitle: "Open CodexBar to refresh this tile.",
            value: "--",
            fractionUsed: nil,
            creditsRemaining: nil,
            severity: .warning
        )
    }
}

public extension CodexBarWidgetSnapshot {
    var builderTiles: [CodexBarWidgetBuilderTile] {
        results.flatMap { provider in
            [provider.builderSummaryTile]
                + provider.bars.map { provider.builderBarTile($0) }
                + (provider.monetaryMetrics ?? []).map { provider.builderMonetaryTile($0) }
        }
    }
}

private extension CodexBarWidgetProviderSnapshot {
    var builderSummaryTile: CodexBarWidgetBuilderTile {
        let bar = representativeBar
        let monetaryMetric = summaryMonetaryMetric
        return CodexBarWidgetBuilderTile(
            id: "provider.\(accountID)",
            providerID: providerID,
            providerTitle: title,
            title: monetaryMetric?.label ?? (creditsRemaining == nil ? title : "\(title) Balance"),
            subtitle: monetaryMetric?.detail ?? groupName ?? subtitle,
            value: creditsRemaining.map(Self.formattedCurrency)
                ?? bar?.usageText
                ?? monetaryMetric?.formattedAmount
                ?? "No data",
            fractionUsed: bar?.effectiveFractionUsed,
            creditsRemaining: creditsRemaining,
            severity: severity
        )
    }

    private var representativeBar: CodexBarWidgetUsageBarSnapshot? {
        bars.max { lhs, rhs in
            if lhs.effectiveSeverity == rhs.effectiveSeverity {
                return lhs.effectiveFractionUsed < rhs.effectiveFractionUsed
            }

            return lhs.effectiveSeverity < rhs.effectiveSeverity
        }
    }

    func builderBarTile(_ bar: CodexBarWidgetUsageBarSnapshot) -> CodexBarWidgetBuilderTile {
        CodexBarWidgetBuilderTile(
            id: "bar.\(bar.id)",
            providerID: providerID,
            providerTitle: title,
            title: bar.label,
            subtitle: groupName ?? subtitle,
            value: bar.usageText,
            fractionUsed: bar.effectiveFractionUsed,
            creditsRemaining: nil,
            severity: bar.effectiveSeverity
        )
    }

    func builderMonetaryTile(_ metric: CodexBarWidgetMonetaryMetricSnapshot) -> CodexBarWidgetBuilderTile {
        CodexBarWidgetBuilderTile(
            id: "money.\(accountID).\(metric.id)",
            providerID: providerID,
            providerTitle: title,
            title: metric.label,
            subtitle: metric.detail ?? groupName ?? subtitle,
            value: metric.formattedAmount,
            fractionUsed: nil,
            creditsRemaining: nil,
            severity: .normal
        )
    }

    private static func formattedCurrency(_ amount: Double) -> String {
        currencyFormatter.string(from: NSNumber(value: amount)) ?? "$0.00"
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
