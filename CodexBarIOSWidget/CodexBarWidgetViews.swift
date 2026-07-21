import SwiftUI
import WidgetKit

struct CodexBarWidgetView: View {
    let entry: CodexBarWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            AccessoryInlineWidget(tiles: selectedTiles.map(\.tile))
        case .accessoryCircular:
            AccessoryCircularWidget(tile: selectedTiles.first?.tile)
        case .accessoryRectangular:
            AccessoryRectangularWidget(tile: selectedTiles.first?.tile)
        default:
            TileWidget(
                tiles: selectedTiles,
                generatedAt: entry.snapshot.generatedAt,
                family: family
            )
        }
    }

    private var selectedTiles: [CodexBarWidgetRenderedTile] {
        let allTiles = scopedSelectableTiles
        let builderConfiguration = WidgetSnapshotStore.loadBuilderConfiguration()
        let usesBuilderDefaults = usesBuilderDefaults(builderConfiguration)
        let configuredChoices = [
            entry.configuration.tile1,
            entry.configuration.tile2,
            entry.configuration.tile3,
            entry.configuration.tile4,
            entry.configuration.tile5,
            entry.configuration.tile6,
        ]
        let configuredDisplayModes = [
            entry.configuration.tile1DisplayMode,
            entry.configuration.tile2DisplayMode,
            entry.configuration.tile3DisplayMode,
            entry.configuration.tile4DisplayMode,
            entry.configuration.tile5DisplayMode,
            entry.configuration.tile6DisplayMode,
        ]

        let maximumTiles = tileCount(
            builderConfiguration: builderConfiguration,
            usesBuilderDefaults: usesBuilderDefaults
        )
        let fallbackTiles = Array(defaultTiles.prefix(maximumTiles))

        if configuredChoices.contains(where: { $0 != nil }) {
            return (0..<maximumTiles).compactMap { index in
                guard configuredChoices.indices.contains(index), let choice = configuredChoices[index] else {
                    return nil
                }

                return CodexBarWidgetRenderedTile(
                    tile: resolvedTile(for: choice, in: allTiles),
                    displayMode: displayMode(at: index, in: configuredDisplayModes)
                )
            }
        }

        if usesBuilderDefaults {
            return (0..<maximumTiles).compactMap { index in
                let tile: CodexBarWidgetTile?
                if let tileID = builderConfiguration.tileID(at: index) {
                    tile = resolvedTile(for: tileID, in: allTiles)
                } else if fallbackTiles.indices.contains(index) {
                    tile = fallbackTiles[index]
                } else {
                    tile = nil
                }

                guard let tile else {
                    return nil
                }

                return CodexBarWidgetRenderedTile(
                    tile: tile,
                    displayMode: displayMode(from: builderConfiguration.displayMode(at: index))
                )
            }
        }

        return fallbackTiles.enumerated().map { index, tile in
            CodexBarWidgetRenderedTile(
                tile: tile,
                displayMode: displayMode(at: index, in: configuredDisplayModes)
            )
        }
    }

    private func usesBuilderDefaults(_ configuration: CodexBarWidgetBuilderConfiguration) -> Bool {
        configuration.hasCustomizations
            && entry.configuration.focus == .dashboardOrder
            && entry.configuration.group == nil
    }

    private var defaultTiles: [CodexBarWidgetTile] {
        scopedProviders.map(\.summaryTile)
    }

    private var scopedSelectableTiles: [CodexBarWidgetTile] {
        entry.snapshot.selectableTiles(group: entry.configuration.group, focus: entry.configuration.focus)
    }

    private var scopedProviders: [CodexBarWidgetProviderSnapshot] {
        entry.snapshot.scopedProviders(group: entry.configuration.group, focus: entry.configuration.focus)
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

    private func resolvedTile(
        for tileID: String,
        in allTiles: [CodexBarWidgetTile]
    ) -> CodexBarWidgetTile {
        if let exactMatch = allTiles.first(where: { $0.id == tileID }) {
            return exactMatch
        }

        if let legacyMatch = legacyBarTile(for: tileID) {
            return legacyMatch
        }

        return .unavailable(
            choice: CodexBarWidgetTileChoice(
                id: tileID,
                title: "Saved Tile",
                subtitle: "Open CodexBar to refresh"
            )
        )
    }

    private func legacyBarTile(for choiceID: String) -> CodexBarWidgetTile? {
        guard choiceID.hasPrefix("bar.") else {
            return nil
        }

        let savedBarID = String(choiceID.dropFirst("bar.".count))
        let providers = scopedProviders
            .filter { provider in
                savedBarID == provider.accountID
                    || savedBarID.hasPrefix("\(provider.accountID).")
            }
            .sorted { $0.accountID.count > $1.accountID.count }

        for provider in providers {
            if let matchingBar = provider.bars.first(where: {
                $0.matchesSavedBuilderTileID(choiceID, accountID: provider.accountID)
            }) {
                return provider.barTile(matchingBar)
            }

            if provider.bars.count == 1, let onlyBar = provider.bars.first {
                return provider.barTile(onlyBar)
            }
        }

        return nil
    }

    private func displayMode(
        at index: Int,
        in displayModes: [CodexBarWidgetTileDisplayMode]
    ) -> CodexBarWidgetTileDisplayMode {
        displayModes.indices.contains(index) ? displayModes[index] : .automatic
    }

    private func displayMode(from displayMode: CodexBarWidgetBuilderDisplayMode) -> CodexBarWidgetTileDisplayMode {
        CodexBarWidgetTileDisplayMode(rawValue: displayMode.rawValue) ?? .automatic
    }

    private func tileCount(
        builderConfiguration: CodexBarWidgetBuilderConfiguration,
        usesBuilderDefaults: Bool
    ) -> Int {
        if entry.configuration.layout == .automatic, usesBuilderDefaults {
            return builderConfiguration.layout.tileCount(
                maximum: maximumTileCount,
                automaticCount: automaticTileCount
            )
        }

        switch entry.configuration.layout {
        case .automatic:
            return automaticTileCount
        case .oneTile:
            return 1
        case .twoTiles:
            return min(maximumTileCount, 2)
        case .fourTiles:
            return min(maximumTileCount, 4)
        }
    }

    private var automaticTileCount: Int {
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
    let tiles: [CodexBarWidgetRenderedTile]
    let generatedAt: Date
    let family: WidgetFamily

    var body: some View {
        Group {
            if tiles.isEmpty {
                EmptyWidgetState()
            } else if usesDenseGrid {
                DenseTileWidget(tiles: tiles, generatedAt: generatedAt, family: family)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(Array(tiles.enumerated()), id: \.offset) { _, tile in
                            ProviderWidgetTile(renderedTile: tile, style: family == .systemSmall ? .small : .standard)
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
    let tiles: [CodexBarWidgetRenderedTile]
    let generatedAt: Date
    let family: WidgetFamily

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Updated \(generatedAt, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(Array(displayedTiles.enumerated()), id: \.offset) { _, tile in
                    ProviderWidgetTile(renderedTile: tile, style: .dense)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(maxHeight: .infinity)
    }

    private var displayedTiles: [CodexBarWidgetRenderedTile] {
        switch family {
        case .systemExtraLarge:
            Array(tiles.prefix(6))
        default:
            Array(tiles.prefix(4))
        }
    }

    private var columns: [GridItem] {
        let columnCount = family == .systemExtraLarge && displayedTiles.count > 4 ? 3 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount)
    }
}

struct ProviderWidgetTile: View {
    enum Style {
        case small
        case standard
        case dense
    }

    let renderedTile: CodexBarWidgetRenderedTile
    let style: Style

    private var tile: CodexBarWidgetTile {
        renderedTile.tile
    }

    var body: some View {
        Group {
            if renderedTile.displayMode == .automatic {
                switch style {
                case .dense:
                    automaticDenseBody
                case .small, .standard:
                    automaticStandardBody
                }
            } else {
                configuredModeBody
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

    private var automaticStandardBody: some View {
        VStack(alignment: .leading, spacing: 7) {
            header(font: .caption.weight(.semibold), logoSize: 22)

            if let monetaryValueText = tile.monetaryValueText {
                Text(monetaryValueText)
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

                    WidgetUsageProgressBar(bar: bar)
                }
            } else {
                Text(tile.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(style == .standard ? 2 : 1)
            }
        }
    }

    private var automaticDenseBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            header(font: .caption2.weight(.semibold), logoSize: 18)

            if let monetaryValueText = tile.monetaryValueText {
                Text(monetaryValueText)
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
                Text(metricText(for: bar))
                    .font(.system(size: 25, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(bar.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                WidgetUsageProgressBar(bar: bar)

                if let detail = bar.localizedProjectionDescription() ?? bar.localizedResetDescription() {
                    Text(detail)
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

    private var configuredModeBody: some View {
        VStack(alignment: .leading, spacing: modeSpacing) {
            header(font: headerFont, logoSize: logoSize)

            switch renderedTile.displayMode {
            case .automatic:
                EmptyView()
            case .compactPercent:
                compactPercentContent
            case .fullBar:
                fullBarContent
            case .balanceOnly:
                balanceOnlyContent
            case .urgentStatus:
                urgentStatusContent
            }

            if style == .dense {
                Spacer(minLength: 0)
            }
        }
    }

    private var compactPercentContent: some View {
        VStack(alignment: .leading, spacing: modeSpacing) {
            Text(primaryMetric)
                .font(primaryMetricFont)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.55)

            Text(compactDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(style == .dense ? 2 : 1)
                .minimumScaleFactor(0.65)

            if let bar = tile.bar {
                WidgetUsageProgressBar(bar: bar)
            }
        }
    }

    private var fullBarContent: some View {
        VStack(alignment: .leading, spacing: modeSpacing) {
            if let bar = tile.bar {
                HStack(alignment: .firstTextBaseline) {
                    Text(bar.label)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                    Spacer(minLength: 4)
                    Text(bar.usageText)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)

                WidgetUsageProgressBar(bar: bar)

                if let detail = bar.localizedProjectionDescription() ?? bar.localizedResetDescription() {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
            } else if let monetaryValueText = tile.monetaryValueText {
                Text(monetaryValueText)
                    .font(primaryMetricFont)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)

                Text(tile.title)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text(tile.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(style == .dense ? 3 : 2)
                    .minimumScaleFactor(0.7)
            }
        }
    }

    private var balanceOnlyContent: some View {
        VStack(alignment: .leading, spacing: modeSpacing) {
            if let monetaryValueText = tile.monetaryValueText {
                Text(monetaryValueText)
                    .font(primaryMetricFont)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)

                Text(tile.monetaryMetric?.label ?? "Balance")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("No balance data")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tile.severity.tint)
                    .lineLimit(1)

                Text(tile.subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(style == .dense ? 2 : 1)
            }
        }
    }

    private var urgentStatusContent: some View {
        VStack(alignment: .leading, spacing: modeSpacing) {
            Text(statusLabel)
                .font(primaryMetricFont)
                .foregroundStyle(tile.severity.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.58)

            Text(statusDetail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(style == .dense ? 3 : 2)
                .minimumScaleFactor(0.65)
        }
    }

    private func header(font: Font, logoSize: CGFloat) -> some View {
        HStack(spacing: 5) {
            CodexBarProviderLogo(
                providerID: tile.providerID,
                size: logoSize,
                background: Color(.systemBackground),
                fallbackSystemName: "arrow.clockwise"
            )

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
            renderedTile.displayMode == .automatic ? 8 : 7
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

    private var modeSpacing: CGFloat {
        style == .dense ? 5 : 6
    }

    private var headerFont: Font {
        style == .dense ? .caption2.weight(.semibold) : .caption.weight(.semibold)
    }

    private var logoSize: CGFloat {
        style == .dense ? 18 : 22
    }

    private var primaryMetricFont: Font {
        switch style {
        case .dense:
            .system(size: 24, weight: .semibold, design: .rounded)
        case .standard:
            .system(size: 22, weight: .semibold, design: .rounded)
        case .small:
            .system(size: 20, weight: .semibold, design: .rounded)
        }
    }

    private var primaryMetric: String {
        if let bar = tile.bar {
            return metricText(for: bar)
        }

        if let monetaryValueText = tile.monetaryValueText {
            return monetaryValueText
        }

        return statusLabel
    }

    private var compactDetail: String {
        if let bar = tile.bar {
            return bar.label
        }

        if tile.monetaryValueText != nil {
            return tile.title
        }

        return tile.subtitle
    }

    private var statusLabel: String {
        switch tile.severity {
        case .normal:
            "OK"
        case .warning:
            "Warning"
        case .critical:
            "Critical"
        }
    }

    private var statusDetail: String {
        if let bar = tile.bar {
            if let projectionDescription = bar.localizedProjectionDescription() {
                return projectionDescription
            }

            return [bar.usageText, bar.localizedResetDescription()]
                .compactMap { $0 }
                .joined(separator: " - ")
        }

        if let metric = tile.monetaryMetric {
            return "\(metric.formattedAmount) - \(metric.label)"
        }

        if let creditsRemaining = tile.creditsRemaining {
            let balance = CodexBarCurrencyText.format(creditsRemaining)
            return "\(balance) balance"
        }

        return tile.subtitle
    }
}

private struct WidgetUsageProgressBar: View {
    let bar: CodexBarWidgetUsageBarSnapshot

    var body: some View {
        CodexBarUsageProgressBar(
            fractionUsed: bar.fractionUsed,
            projectedFraction: bar.projectedFraction,
            severity: bar.severity,
            projectedSeverity: bar.effectiveSeverity,
            accessibilityText: "\(bar.label) \(bar.usageText)"
        )
    }
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
