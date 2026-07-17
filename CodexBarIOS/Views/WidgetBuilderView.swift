import SwiftUI
import WidgetKit

struct WidgetBuilderView: View {
    @State private var configuration: CodexBarWidgetBuilderConfiguration
    @State private var snapshot: CodexBarWidgetSnapshot

    private let defaults: UserDefaults?

    init(defaults: UserDefaults? = WidgetSnapshotStore.userDefaults()) {
        self.defaults = defaults
        _configuration = State(initialValue: WidgetSnapshotStore.loadBuilderConfiguration(defaults: defaults))
        _snapshot = State(initialValue: WidgetSnapshotStore.loadSnapshot(defaults: defaults))
    }

    var body: some View {
        List {
            Section {
                Picker("Layout", selection: layoutBinding) {
                    ForEach(CodexBarWidgetBuilderLayout.allCases) { layout in
                        Text(layout.displayName).tag(layout)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Layout")
            }

            Section {
                WidgetBuilderPreviewGrid(tiles: previewTiles, layout: configuration.layout)
            } header: {
                Text("Preview")
            }

            Section {
                ForEach(0..<slotCount, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Tile \(index + 1)", selection: tileBinding(for: index)) {
                            Text("Dashboard Default").tag(Optional<String>.none)

                            ForEach(availableTiles) { tile in
                                Text(tile.choiceTitle).tag(Optional(tile.id))
                            }
                        }

                        Picker("Display", selection: displayModeBinding(for: index)) {
                            ForEach(CodexBarWidgetBuilderDisplayMode.allCases) { displayMode in
                                Text(displayMode.displayName).tag(displayMode)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Tiles")
            } footer: {
                Text("Placed widgets keep their own edits. New widgets use this default when their tile slots are empty.")
            }
        }
        .navigationTitle("Widget Builder")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    refreshSnapshot()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh preview")

                Button {
                    resetConfiguration()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                }
                .accessibilityLabel("Reset widget builder")
            }
        }
    }

    private var availableTiles: [CodexBarWidgetBuilderTile] {
        snapshot.builderTiles
    }

    private var slotCount: Int {
        configuration.layout.previewTileCount
    }

    private var previewTiles: [CodexBarWidgetBuilderTile] {
        let fallbackTiles = Array(availableTiles.prefix(slotCount))

        if configuration.hasCustomizations {
            return (0..<slotCount).compactMap { index -> CodexBarWidgetBuilderTile? in
                if let tileID = configuration.tileID(at: index) {
                    return snapshot.builderTile(resolvingSavedID: tileID) ?? .unavailable(id: tileID)
                }

                return fallbackTiles.indices.contains(index) ? fallbackTiles[index] : nil
            }
        }

        return fallbackTiles
    }

    private var layoutBinding: Binding<CodexBarWidgetBuilderLayout> {
        Binding(
            get: { configuration.layout },
            set: { layout in
                configuration.layout = layout
                saveConfiguration()
            }
        )
    }

    private func tileBinding(for index: Int) -> Binding<String?> {
        Binding(
            get: {
                guard let tileID = configuration.tileID(at: index) else {
                    return nil
                }
                return snapshot.builderTile(resolvingSavedID: tileID)?.id ?? tileID
            },
            set: { tileID in
                configuration.setTileID(tileID, at: index)
                saveConfiguration()
            }
        )
    }

    private func displayModeBinding(for index: Int) -> Binding<CodexBarWidgetBuilderDisplayMode> {
        Binding(
            get: { configuration.displayMode(at: index) },
            set: { displayMode in
                configuration.setDisplayMode(displayMode, at: index)
                saveConfiguration()
            }
        )
    }

    private func refreshSnapshot() {
        snapshot = WidgetSnapshotStore.loadSnapshot(defaults: defaults)
    }

    private func resetConfiguration() {
        configuration = .default
        saveConfiguration()
    }

    private func saveConfiguration() {
        WidgetSnapshotStore.saveBuilderConfiguration(configuration, defaults: defaults)
        WidgetCenter.shared.reloadTimelines(ofKind: CodexBarWidgetConstants.widgetKind)
    }
}

private struct WidgetBuilderPreviewGrid: View {
    let tiles: [CodexBarWidgetBuilderTile]
    let layout: CodexBarWidgetBuilderLayout

    var body: some View {
        Group {
            if tiles.isEmpty {
                ContentUnavailableView(
                    "No Widget Data",
                    systemImage: "square.grid.2x2",
                    description: Text("Refresh CodexBar to publish widget tiles.")
                )
                .frame(minHeight: 150)
            } else {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(tiles) { tile in
                        WidgetBuilderPreviewTile(tile: tile)
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    private var columns: [GridItem] {
        let count = layout == .oneTile ? 1 : 2
        return Array(repeating: GridItem(.flexible(), spacing: 8), count: count)
    }
}

private struct WidgetBuilderPreviewTile: View {
    let tile: CodexBarWidgetBuilderTile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                WidgetBuilderProviderLogo(providerID: tile.providerID)

                Text(tile.providerTitle)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                Spacer(minLength: 0)
            }

            Text(tile.value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.58)

            Text(tile.title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            if let fractionUsed = tile.fractionUsed {
                WidgetBuilderProgressBar(fractionUsed: fractionUsed, severity: tile.severity)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 118, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct WidgetBuilderProgressBar: View {
    let fractionUsed: Double
    let severity: CodexBarWidgetSeverity

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.12))

                Capsule()
                    .fill(severity.tint)
                    .frame(width: proxy.size.width * min(max(fractionUsed, 0), 1))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

private struct WidgetBuilderProviderLogo: View {
    let providerID: String

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(.systemBackground))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 0.5)
                }

            if let assetName {
                Image(assetName)
                    .resizable()
                    .renderingMode(.original)
                    .scaledToFit()
                    .padding(3)
            } else {
                Image(systemName: "square.grid.2x2")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityHidden(true)
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
        case "moonshot":
            "MoonshotLogo"
        case "cursor":
            "CursorLogo"
        default:
            nil
        }
    }
}

private extension CodexBarWidgetBuilderTile {
    var choiceTitle: String {
        providerTitle == title ? title : "\(providerTitle) - \(title)"
    }
}

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

#Preview {
    NavigationStack {
        WidgetBuilderView()
    }
}
