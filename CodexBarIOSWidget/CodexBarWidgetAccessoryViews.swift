import SwiftUI
import WidgetKit

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
        Gauge(value: tile?.bar?.effectiveFractionUsed ?? 0) {
            Image(systemName: "gauge.with.dots.needle.50percent")
        } currentValueLabel: {
            Text(tile.map(summary) ?? "--")
                .font(.system(size: 10, weight: .semibold))
                .minimumScaleFactor(0.6)
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .tint(tile?.severity.tint ?? .secondary)
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
