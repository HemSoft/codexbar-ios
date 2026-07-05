import AppIntents
import SwiftUI
import WidgetKit

struct CodexBarWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: CodexBarWidgetSnapshot
    let configuration: CodexBarWidgetConfigurationIntent
}

struct CodexBarWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CodexBarWidgetEntry {
        CodexBarWidgetEntry(
            date: Date(),
            snapshot: .preview,
            configuration: CodexBarWidgetConfigurationIntent()
        )
    }

    func snapshot(
        for configuration: CodexBarWidgetConfigurationIntent,
        in context: Context
    ) async -> CodexBarWidgetEntry {
        CodexBarWidgetEntry(
            date: Date(),
            snapshot: WidgetSnapshotStore.loadSnapshot(),
            configuration: configuration
        )
    }

    func timeline(
        for configuration: CodexBarWidgetConfigurationIntent,
        in context: Context
    ) async -> Timeline<CodexBarWidgetEntry> {
        let now = Date()
        let snapshot = WidgetSnapshotStore.loadSnapshot()
        let interval = configuration.refreshPolicy.interval(fallback: WidgetSnapshotStore.loadRefreshInterval())
        return Timeline(
            entries: [
                CodexBarWidgetEntry(
                    date: now,
                    snapshot: snapshot,
                    configuration: configuration
                )
            ],
            policy: .after(now.addingTimeInterval(interval.seconds))
        )
    }
}

struct CodexBarWidgetConfigurationIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "CodexBar Widget"
    static let description = IntentDescription("Choose the CodexBar tiles and refresh preference for this widget.")

    @Parameter(title: "Layout", default: .automatic)
    var layout: CodexBarWidgetLayout

    @Parameter(title: "Focus", default: .dashboardOrder)
    var focus: CodexBarWidgetFocus

    @Parameter(title: "Tile 1")
    var tile1: CodexBarWidgetTileChoice?

    @Parameter(title: "Tile 2")
    var tile2: CodexBarWidgetTileChoice?

    @Parameter(title: "Tile 3")
    var tile3: CodexBarWidgetTileChoice?

    @Parameter(title: "Tile 4")
    var tile4: CodexBarWidgetTileChoice?

    @Parameter(title: "Update Preference", default: .appDefault)
    var refreshPolicy: CodexBarWidgetRefreshPolicy
}

enum CodexBarWidgetLayout: String, AppEnum {
    case automatic
    case oneTile
    case twoTiles
    case fourTiles

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Layout")
    static let caseDisplayRepresentations: [CodexBarWidgetLayout: DisplayRepresentation] = [
        .automatic: "Automatic",
        .oneTile: "One Tile",
        .twoTiles: "Two Tiles",
        .fourTiles: "Four Tiles",
    ]
}

enum CodexBarWidgetFocus: String, AppEnum {
    case dashboardOrder
    case codex
    case copilot
    case claude
    case cursor
    case openCodeZen
    case openRouter

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Focus")
    static let caseDisplayRepresentations: [CodexBarWidgetFocus: DisplayRepresentation] = [
        .dashboardOrder: "Dashboard Order",
        .codex: "ChatGPT / Codex",
        .copilot: "GitHub Copilot",
        .claude: "Claude",
        .cursor: "Cursor",
        .openCodeZen: "OpenCode ZEN",
        .openRouter: "OpenRouter",
    ]

    var providerID: String? {
        switch self {
        case .dashboardOrder:
            nil
        case .codex:
            "codex"
        case .copilot:
            "copilot"
        case .claude:
            "claude"
        case .cursor:
            "cursor"
        case .openCodeZen:
            "openCodeZen"
        case .openRouter:
            "openRouter"
        }
    }
}

enum CodexBarWidgetRefreshPolicy: String, AppEnum {
    case appDefault
    case fifteenMinutes
    case thirtyMinutes
    case oneHour
    case threeHours

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Update Preference")
    static let caseDisplayRepresentations: [CodexBarWidgetRefreshPolicy: DisplayRepresentation] = [
        .appDefault: "App Default",
        .fifteenMinutes: "Every 15 Minutes",
        .thirtyMinutes: "Every 30 Minutes",
        .oneHour: "Every Hour",
        .threeHours: "Every 3 Hours",
    ]

    func interval(fallback: WidgetRefreshInterval) -> WidgetRefreshInterval {
        switch self {
        case .appDefault:
            fallback
        case .fifteenMinutes:
            .fifteenMinutes
        case .thirtyMinutes:
            .thirtyMinutes
        case .oneHour:
            .oneHour
        case .threeHours:
            .threeHours
        }
    }
}

struct CodexBarWidgetTileChoice: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Tile")
    static let defaultQuery = CodexBarWidgetTileChoiceQuery()

    let id: String
    let title: String
    let subtitle: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)", subtitle: "\(subtitle)")
    }
}

struct CodexBarWidgetTileChoiceQuery: EntityStringQuery {
    func entities(for identifiers: [CodexBarWidgetTileChoice.ID]) async throws -> [CodexBarWidgetTileChoice] {
        let choices = Self.choices()
        return identifiers.map { identifier in
            choices.first { $0.id == identifier }
                ?? CodexBarWidgetTileChoice(id: identifier, title: "Saved Tile", subtitle: "Open CodexBar to refresh")
        }
    }

    func entities(matching string: String) async throws -> [CodexBarWidgetTileChoice] {
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.choices()
        }

        return Self.choices().filter { choice in
            choice.title.localizedCaseInsensitiveContains(string)
                || choice.subtitle.localizedCaseInsensitiveContains(string)
        }
    }

    func suggestedEntities() async throws -> [CodexBarWidgetTileChoice] {
        Self.choices()
    }

    private static func choices() -> [CodexBarWidgetTileChoice] {
        WidgetSnapshotStore.loadSnapshot().selectableTiles.map { tile in
            CodexBarWidgetTileChoice(
                id: tile.id,
                title: tile.choiceTitle,
                subtitle: tile.choiceSubtitle
            )
        }
    }
}

struct CodexBarIOSWidget: Widget {
    let kind = CodexBarWidgetConstants.widgetKind

    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: kind,
            intent: CodexBarWidgetConfigurationIntent.self,
            provider: CodexBarWidgetProvider()
        ) { entry in
            CodexBarWidgetView(entry: entry)
        }
        .configurationDisplayName("CodexBar")
        .description("Track AI provider usage from the Home Screen and Lock Screen.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .systemExtraLarge,
            .accessoryInline,
            .accessoryCircular,
            .accessoryRectangular,
        ])
    }
}

struct CodexBarWidgetView: View {
    let entry: CodexBarWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            AccessoryInlineWidget(tiles: selectedTiles)
        case .accessoryCircular:
            AccessoryCircularWidget(tile: selectedTiles.first)
        case .accessoryRectangular:
            AccessoryRectangularWidget(tile: selectedTiles.first)
        default:
            TileWidget(
                tiles: selectedTiles,
                generatedAt: entry.snapshot.generatedAt,
                family: family
            )
        }
    }

    private var selectedTiles: [CodexBarWidgetTile] {
        let allTiles = entry.snapshot.selectableTiles
        let configuredChoices = [
            entry.configuration.tile1,
            entry.configuration.tile2,
            entry.configuration.tile3,
            entry.configuration.tile4,
        ]

        if configuredChoices.contains(where: { $0 != nil }) {
            return configuredChoices
                .prefix(tileCount)
                .compactMap { choice in
                    guard let choice else {
                        return nil
                    }

                    return resolvedTile(for: choice, in: allTiles)
                }
        }

        return Array(defaultTiles.prefix(tileCount))
    }

    private var defaultTiles: [CodexBarWidgetTile] {
        let providers = entry.configuration.focus.providerID.map { providerID in
            entry.snapshot.results.filter { $0.providerID == providerID }
        } ?? entry.snapshot.results

        return providers.map(\.summaryTile)
    }

    private func resolvedTile(
        for choice: CodexBarWidgetTileChoice,
        in allTiles: [CodexBarWidgetTile]
    ) -> CodexBarWidgetTile {
        if let exactMatch = allTiles.first(where: { $0.id == choice.id }) {
            return exactMatch
        }

        if let legacyMatch = legacyBarTile(for: choice.id) {
            return legacyMatch
        }

        let titleMatches = allTiles.filter {
            $0.choiceTitle.localizedCaseInsensitiveCompare(choice.title) == .orderedSame
        }
        if titleMatches.count == 1, let titleMatch = titleMatches.first {
            return titleMatch
        }

        return .unavailable(choice: choice)
    }

    private func legacyBarTile(for choiceID: String) -> CodexBarWidgetTile? {
        guard choiceID.hasPrefix("bar.") else {
            return nil
        }

        let savedBarID = String(choiceID.dropFirst("bar.".count))
        let providers = entry.snapshot.results
            .filter { provider in
                savedBarID == provider.accountID
                    || savedBarID.hasPrefix("\(provider.accountID).")
            }
            .sorted { $0.accountID.count > $1.accountID.count }

        for provider in providers {
            let savedAccountSuffix = savedBarID.droppingPrefix("\(provider.accountID).")

            if let matchingBar = provider.bars.first(where: { bar in
                savedBarID == bar.id
                    || savedAccountSuffix == bar.id
                    || savedBarID == "\(provider.accountID).\(bar.id)"
            }) {
                return provider.barTile(matchingBar)
            }

            if provider.bars.count == 1, let onlyBar = provider.bars.first {
                return provider.barTile(onlyBar)
            }
        }

        return nil
    }

    private var tileCount: Int {
        switch entry.configuration.layout {
        case .automatic:
            switch family {
            case .systemSmall:
                1
            case .systemMedium:
                2
            case .systemLarge:
                4
            case .systemExtraLarge:
                6
            default:
                1
            }
        case .oneTile:
            1
        case .twoTiles:
            min(maximumTileCount, 2)
        case .fourTiles:
            min(maximumTileCount, 4)
        }
    }

    private var maximumTileCount: Int {
        switch family {
        case .systemSmall:
            1
        case .systemMedium:
            2
        case .systemLarge:
            4
        case .systemExtraLarge:
            6
        default:
            1
        }
    }
}

struct TileWidget: View {
    let tiles: [CodexBarWidgetTile]
    let generatedAt: Date
    let family: WidgetFamily

    var body: some View {
        Group {
            if tiles.isEmpty {
                EmptyWidgetState()
            } else if usesDenseGrid {
                DenseTileWidget(tiles: Array(tiles.prefix(4)), generatedAt: generatedAt)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                            ProviderWidgetTile(tile: tile, style: family == .systemSmall ? .small : .standard)
                        }
                    }

                    if family != .systemSmall {
                        Text("Updated \(generatedAt, style: .relative) ago")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .containerBackground(.background, for: .widget)
    }

    private var usesDenseGrid: Bool {
        switch family {
        case .systemLarge, .systemExtraLarge:
            tiles.count >= 4
        default:
            false
        }
    }

    private var columns: [GridItem] {
        switch family {
        case .systemSmall:
            [GridItem(.flexible(), spacing: 8)]
        case .systemMedium:
            [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        default:
            [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
        }
    }
}

struct DenseTileWidget: View {
    let tiles: [CodexBarWidgetTile]
    let generatedAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Updated \(generatedAt, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    denseTile(at: 0)
                    denseTile(at: 1)
                }
                .frame(maxHeight: .infinity)

                HStack(spacing: 8) {
                    denseTile(at: 2)
                    denseTile(at: 3)
                }
                .frame(maxHeight: .infinity)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    @ViewBuilder
    private func denseTile(at index: Int) -> some View {
        if tiles.indices.contains(index) {
            ProviderWidgetTile(tile: tiles[index], style: .dense)
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct ProviderWidgetTile: View {
    enum Style {
        case small
        case standard
        case dense
    }

    let tile: CodexBarWidgetTile
    let style: Style

    var body: some View {
        Group {
            switch style {
            case .dense:
                denseBody
            case .small, .standard:
                standardBody
            }
        }
        .padding(padding)
        .frame(
            maxWidth: .infinity,
            maxHeight: style == .dense ? .infinity : nil,
            alignment: .topLeading
        )
        .frame(minHeight: minimumHeight, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }

    private var standardBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            header(font: .caption.weight(.semibold), logoSize: 22)

            if let creditsRemaining = tile.creditsRemaining {
                Text(widgetCurrencyFormatter.string(from: NSNumber(value: creditsRemaining)) ?? "$0.00")
                    .font(.system(size: style == .standard ? 22 : 20, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            } else if let bar = tile.bar {
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(bar.label)
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(bar.usageText)
                            .monospacedDigit()
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                    ProgressView(value: bar.fractionUsed)
                        .tint(bar.severity.tint)
                }
            } else {
                Text(tile.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(style == .standard ? 2 : 1)
            }
        }
    }

    private var denseBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(font: .caption2.weight(.semibold), logoSize: 18)

            if let creditsRemaining = tile.creditsRemaining {
                Text(widgetCurrencyFormatter.string(from: NSNumber(value: creditsRemaining)) ?? "$0.00")
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)

                Text(tile.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            } else if let bar = tile.bar {
                Text(bar.usageText)
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(bar.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                ProgressView(value: bar.fractionUsed)
                    .tint(bar.severity.tint)

                if let resetDescription = bar.resetDescription {
                    Text(resetDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
            } else {
                Text(tile.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
            }

            Spacer(minLength: 0)
        }
    }

    private func header(font: Font, logoSize: CGFloat) -> some View {
        HStack(spacing: 5) {
            ProviderLogo(providerID: tile.providerID, size: logoSize)

            Text(tile.providerTitle)
                .font(font)
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Spacer(minLength: 0)
        }
    }

    private var padding: CGFloat {
        switch style {
        case .dense:
            8
        case .small, .standard:
            10
        }
    }

    private var minimumHeight: CGFloat {
        switch style {
        case .small:
            110
        case .standard:
            86
        case .dense:
            0
        }
    }
}

struct AccessoryInlineWidget: View {
    let tiles: [CodexBarWidgetTile]

    var body: some View {
        if let tile = tiles.first {
            Text("\(tile.providerTitle) \(summary(for: tile))")
        } else {
            Text("CodexBar")
        }
    }
}

struct AccessoryCircularWidget: View {
    let tile: CodexBarWidgetTile?

    var body: some View {
        Gauge(value: tile?.bar?.fractionUsed ?? 0) {
            Image(systemName: "gauge.with.dots.needle.50percent")
        } currentValueLabel: {
            Text(tile.map(summary) ?? "--")
                .font(.system(size: 10, weight: .semibold))
                .minimumScaleFactor(0.6)
        }
        .gaugeStyle(.accessoryCircularCapacity)
    }
}

struct AccessoryRectangularWidget: View {
    let tile: CodexBarWidgetTile?

    var body: some View {
        if let tile {
            VStack(alignment: .leading, spacing: 2) {
                Text(tile.providerTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text(summary(for: tile))
                    .font(.caption2)
                    .lineLimit(1)
            }
        } else {
            Text("Open CodexBar")
        }
    }
}

struct EmptyWidgetState: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.title2)
            Text("CodexBar")
                .font(.headline)
            Text("Open the app to refresh usage.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(.background, for: .widget)
    }
}

struct ProviderLogo: View {
    let providerID: String
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(.background)
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(.separator.opacity(0.35), lineWidth: 0.5)
                }

            if let assetName {
                Image(assetName)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .padding(3)
            } else {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }

    private var assetName: String? {
        switch providerID {
        case "codex":
            "CodexLogo"
        case "copilot":
            "CopilotLogo"
        case "claude":
            "ClaudeLogo"
        case "openRouter":
            "OpenRouterLogo"
        case "openCodeZen":
            "OpenCodeZenLogo"
        case "cursor":
            "CursorLogo"
        default:
            nil
        }
    }
}

struct CodexBarWidgetTile: Identifiable {
    let id: String
    let providerID: String
    let providerTitle: String
    let title: String
    let subtitle: String
    let bar: CodexBarWidgetUsageBarSnapshot?
    let creditsRemaining: Double?
    let severity: CodexBarWidgetSeverity

    var choiceTitle: String {
        if bar != nil {
            "\(providerTitle) - \(title)"
        } else {
            title
        }
    }

    var choiceSubtitle: String {
        if let bar {
            return "\(bar.usageText) used"
        }

        if let creditsRemaining {
            return widgetCurrencyFormatter.string(from: NSNumber(value: creditsRemaining)) ?? subtitle
        }

        return subtitle
    }

    static func unavailable(choice: CodexBarWidgetTileChoice) -> CodexBarWidgetTile {
        CodexBarWidgetTile(
            id: "unavailable.\(choice.id)",
            providerID: "unavailable",
            providerTitle: choice.title,
            title: choice.title,
            subtitle: "Open CodexBar to refresh this tile.",
            bar: nil,
            creditsRemaining: nil,
            severity: .warning
        )
    }
}

private extension CodexBarWidgetSnapshot {
    var selectableTiles: [CodexBarWidgetTile] {
        results.flatMap { provider in
            [provider.summaryTile] + provider.bars.map { provider.barTile($0) }
        }
    }
}

private extension CodexBarWidgetProviderSnapshot {
    var summaryTile: CodexBarWidgetTile {
        CodexBarWidgetTile(
            id: "provider.\(accountID)",
            providerID: providerID,
            providerTitle: title,
            title: creditsRemaining == nil ? title : "\(title) Balance",
            subtitle: subtitle,
            bar: bars.first,
            creditsRemaining: creditsRemaining,
            severity: severity
        )
    }

    func barTile(_ bar: CodexBarWidgetUsageBarSnapshot) -> CodexBarWidgetTile {
        CodexBarWidgetTile(
            id: "bar.\(bar.id)",
            providerID: providerID,
            providerTitle: title,
            title: bar.label,
            subtitle: subtitle,
            bar: bar,
            creditsRemaining: nil,
            severity: bar.severity
        )
    }
}

private extension String {
    func droppingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }
}

private func summary(for tile: CodexBarWidgetTile) -> String {
    if let creditsRemaining = tile.creditsRemaining {
        return widgetCurrencyFormatter.string(from: NSNumber(value: creditsRemaining)) ?? "$0.00"
    }

    return tile.bar?.usageText ?? "No data"
}

private let widgetCurrencyFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency
    formatter.currencyCode = "USD"
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return formatter
}()

private extension CodexBarWidgetSeverity {
    var tint: Color {
        switch self {
        case .normal:
            .green
        case .warning:
            .orange
        case .critical:
            .red
        }
    }
}

private extension CodexBarWidgetSnapshot {
    static let preview = CodexBarWidgetSnapshot(
        generatedAt: Date(),
        results: [
            CodexBarWidgetProviderSnapshot(
                accountID: "codex",
                providerID: "codex",
                title: "ChatGPT / Codex",
                subtitle: "Pro",
                bars: [
                    CodexBarWidgetUsageBarSnapshot(
                        id: "primary",
                        label: "5 hour",
                        fractionUsed: 0.42,
                        usageText: "42%",
                        resetDescription: "Resets 2h",
                        severity: .normal
                    )
                ],
                creditsRemaining: nil,
                fetchedAt: Date(),
                severity: .normal
            ),
            CodexBarWidgetProviderSnapshot(
                accountID: "openCodeZen",
                providerID: "openCodeZen",
                title: "OpenCode ZEN",
                subtitle: "Balance",
                bars: [],
                creditsRemaining: 184.25,
                fetchedAt: Date(),
                severity: .normal
            ),
        ]
    )
}

#Preview(as: .systemMedium) {
    CodexBarIOSWidget()
} timeline: {
    CodexBarWidgetEntry(
        date: Date(),
        snapshot: .preview,
        configuration: CodexBarWidgetConfigurationIntent()
    )
}
