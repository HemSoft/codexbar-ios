import AppIntents
import Foundation
import SwiftUI
import WidgetKit

struct CodexBarWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: CodexBarWidgetSnapshot
    let configuration: CodexBarWidgetConfigurationIntent
    let isPreview: Bool
}

struct CodexBarWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> CodexBarWidgetEntry {
        CodexBarWidgetEntry(
            date: Date(),
            snapshot: .preview,
            configuration: CodexBarWidgetConfigurationIntent(),
            isPreview: true
        )
    }

    func snapshot(
        for configuration: CodexBarWidgetConfigurationIntent,
        in context: Context
    ) async -> CodexBarWidgetEntry {
        CodexBarWidgetEntry(
            date: Date(),
            snapshot: WidgetSnapshotStore.loadSnapshot(forPreview: context.isPreview),
            configuration: configuration,
            isPreview: context.isPreview
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
                    configuration: configuration,
                    isPreview: false
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

    @Parameter(title: "Group")
    var group: CodexBarWidgetGroupChoice?

    @Parameter(title: "Tile 1")
    var tile1: CodexBarWidgetTileChoice?

    @Parameter(title: "Tile 1 Display", default: .automatic)
    var tile1DisplayMode: CodexBarWidgetTileDisplayMode

    @Parameter(title: "Tile 2")
    var tile2: CodexBarWidgetTileChoice?

    @Parameter(title: "Tile 2 Display", default: .automatic)
    var tile2DisplayMode: CodexBarWidgetTileDisplayMode

    @Parameter(title: "Tile 3")
    var tile3: CodexBarWidgetTileChoice?

    @Parameter(title: "Tile 3 Display", default: .automatic)
    var tile3DisplayMode: CodexBarWidgetTileDisplayMode

    @Parameter(title: "Tile 4")
    var tile4: CodexBarWidgetTileChoice?

    @Parameter(title: "Tile 4 Display", default: .automatic)
    var tile4DisplayMode: CodexBarWidgetTileDisplayMode

    @Parameter(title: "Tile 5")
    var tile5: CodexBarWidgetTileChoice?

    @Parameter(title: "Tile 5 Display", default: .automatic)
    var tile5DisplayMode: CodexBarWidgetTileDisplayMode

    @Parameter(title: "Tile 6")
    var tile6: CodexBarWidgetTileChoice?

    @Parameter(title: "Tile 6 Display", default: .automatic)
    var tile6DisplayMode: CodexBarWidgetTileDisplayMode

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
    case moonshot
    case openCodeZen
    case openRouter

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Focus")
    static let caseDisplayRepresentations: [CodexBarWidgetFocus: DisplayRepresentation] = [
        .dashboardOrder: "Dashboard Order",
        .codex: "ChatGPT / Codex",
        .copilot: "GitHub Copilot",
        .claude: "Claude",
        .cursor: "Cursor",
        .moonshot: "Moonshot (Kimi)",
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
        case .moonshot:
            "moonshot"
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

enum CodexBarWidgetTileDisplayMode: String, AppEnum {
    case automatic
    case compactPercent
    case fullBar
    case balanceOnly
    case urgentStatus

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Tile Display")
    static let caseDisplayRepresentations: [CodexBarWidgetTileDisplayMode: DisplayRepresentation] = [
        .automatic: "Automatic",
        .compactPercent: "Compact Percent",
        .fullBar: "Full Bar",
        .balanceOnly: "Balance Only",
        .urgentStatus: "Urgent Status",
    ]
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

struct CodexBarWidgetGroupChoice: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Group")
    static let defaultQuery = CodexBarWidgetGroupChoiceQuery()
    static let ungroupedID = "__ungrouped"

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct CodexBarWidgetGroupChoiceQuery: EntityStringQuery {
    func entities(for identifiers: [CodexBarWidgetGroupChoice.ID]) async throws -> [CodexBarWidgetGroupChoice] {
        let choices = Self.choices()
        return identifiers.map { identifier in
            choices.first { $0.id == identifier }
                ?? CodexBarWidgetGroupChoice(id: identifier, title: "Saved Group")
        }
    }

    func entities(matching string: String) async throws -> [CodexBarWidgetGroupChoice] {
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Self.choices()
        }

        return Self.choices().filter { choice in
            choice.title.localizedCaseInsensitiveContains(string)
        }
    }

    func suggestedEntities() async throws -> [CodexBarWidgetGroupChoice] {
        Self.choices()
    }

    private static func choices() -> [CodexBarWidgetGroupChoice] {
        WidgetSnapshotStore.loadSnapshot().groupChoices
    }
}

struct CodexBarWidgetTileChoiceQuery: EntityStringQuery {
    @IntentParameterDependency<CodexBarWidgetConfigurationIntent>(\.$group, \.$focus)
    var intent

    func entities(for identifiers: [CodexBarWidgetTileChoice.ID]) async throws -> [CodexBarWidgetTileChoice] {
        let choices = choices()
        return identifiers.map { identifier in
            choices.first { $0.id == identifier }
                ?? CodexBarWidgetTileChoice(id: identifier, title: "Saved Tile", subtitle: "Open CodexBar to refresh")
        }
    }

    func entities(matching string: String) async throws -> [CodexBarWidgetTileChoice] {
        guard !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return choices()
        }

        return choices().filter { choice in
            choice.title.localizedCaseInsensitiveContains(string)
                || choice.subtitle.localizedCaseInsensitiveContains(string)
        }
    }

    func suggestedEntities() async throws -> [CodexBarWidgetTileChoice] {
        choices()
    }

    private func choices() -> [CodexBarWidgetTileChoice] {
        Self.choices(
            group: intent?.group,
            focus: intent?.focus ?? .dashboardOrder
        )
    }

    private static func choices(
        group: CodexBarWidgetGroupChoice? = nil,
        focus: CodexBarWidgetFocus = .dashboardOrder
    ) -> [CodexBarWidgetTileChoice] {
        WidgetSnapshotStore.loadSnapshot().selectableTiles(group: group, focus: focus).map { tile in
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
