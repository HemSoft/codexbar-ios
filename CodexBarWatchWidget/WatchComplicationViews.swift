import SwiftUI
import WidgetKit

struct WatchComplicationView: View {
    let entry: WatchComplicationEntry

    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                WatchInlineComplication(sample: entry.sample)
            case .accessoryCircular:
                WatchCircularComplication(sample: entry.sample)
            case .accessoryRectangular:
                WatchRectangularComplication(sample: entry.sample)
            case .accessoryCorner:
                WatchCornerComplication(sample: entry.sample)
            default:
                WatchRectangularComplication(sample: entry.sample)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
        .widgetURL(URL(string: "codexbar://watch"))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.sample.accessibilityLabel)
    }
}

private struct WatchInlineComplication: View {
    let sample: WatchComplicationSample

    var body: some View {
        Label {
            Text(inlineText)
        } icon: {
            Image(systemName: statusSymbol)
        }
    }

    private var inlineText: String {
        switch sample.availability {
        case .empty:
            return "CodexBar • Open iPhone app"
        case .unavailable:
            return "CodexBar • Selection unavailable"
        case .value:
            let state = sample.stateLabel.map { " • \($0)" } ?? ""
            return "\(sample.providerName) \(sample.metricLabel) \(sample.exactValue)\(state)"
        }
    }

    private var statusSymbol: String {
        switch sample.availability {
        case .empty:
            return "iphone"
        case .unavailable:
            return "questionmark.circle"
        case .value:
            if sample.isStale {
                return "clock.badge.exclamationmark"
            }
            switch sample.severity {
            case .normal:
                return "gauge.with.dots.needle.50percent"
            case .warning, .critical:
                return "exclamationmark.triangle.fill"
            }
        }
    }
}

private struct WatchCircularComplication: View {
    let sample: WatchComplicationSample

    var body: some View {
        if sample.availability == .value {
            Gauge(value: sample.clampedUsedFraction) {
                Image(systemName: sample.isStale ? "clock.badge.exclamationmark" : "gauge")
            } currentValueLabel: {
                Text(sample.exactValue)
                    .font(.system(size: 10, weight: .semibold))
                    .minimumScaleFactor(0.55)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(tint)
            .widgetAccentable()
        } else {
            VStack(spacing: 1) {
                Image(systemName: sample.availability == .empty ? "iphone" : "questionmark")
                Text("--")
                    .font(.caption2.bold())
            }
        }
    }

    private var tint: Color {
        switch sample.severity {
        case .normal:
            return sample.isStale ? .secondary : .accentColor
        case .warning:
            return .orange
        case .critical:
            return .red
        }
    }
}

private struct WatchRectangularComplication: View {
    let sample: WatchComplicationSample

    var body: some View {
        if sample.availability == .value {
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    Text(sample.providerName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 2)
                    Text(sample.exactValue)
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .lineLimit(1)
                }
                Text(sample.metricLabel)
                    .font(.caption2)
                    .lineLimit(1)
                HStack(spacing: 3) {
                    if let stateLabel = sample.stateLabel {
                        Label(stateLabel, systemImage: statusSymbol)
                            .labelStyle(.titleAndIcon)
                    } else {
                        Text(sample.freshnessText)
                    }
                    Spacer(minLength: 2)
                    if let resetText = sample.resetText {
                        Text(resetText)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 2) {
                Text("CodexBar")
                    .font(.caption.weight(.semibold))
                Label(
                    sample.availability == .empty ? "Open iPhone app" : "Selection unavailable",
                    systemImage: sample.availability == .empty ? "iphone" : "questionmark.circle"
                )
                .font(.caption2)
            }
        }
    }

    private var statusSymbol: String {
        sample.isStale ? "clock.badge.exclamationmark" : "exclamationmark.triangle.fill"
    }
}

private struct WatchCornerComplication: View {
    let sample: WatchComplicationSample

    var body: some View {
        Text(sample.availability == .value ? sample.exactValue : "--")
            .font(.caption.monospacedDigit().weight(.semibold))
            .widgetLabel {
                Gauge(value: sample.clampedUsedFraction) {
                    Text(sample.providerName)
                }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(tint)
                .widgetAccentable()
            }
    }

    private var tint: Color {
        if sample.availability != .value {
            return .secondary
        }
        switch sample.severity {
        case .normal:
            return sample.isStale ? .secondary : .accentColor
        case .warning:
            return .orange
        case .critical:
            return .red
        }
    }
}
