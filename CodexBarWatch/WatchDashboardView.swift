import SwiftUI

struct WatchDashboardView: View {
    let state: WatchDashboardState

    var body: some View {
        List {
            Section {
                if state.samples.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "iphone.and.arrow.forward")
                            .font(.title2)
                            .foregroundStyle(.tint)
                            .accessibilityHidden(true)
                        Text(state.statusText)
                            .font(.callout)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .combine)
                } else {
                    ForEach(state.samples) { sample in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(alignment: .firstTextBaseline) {
                                Text(sample.providerName)
                                    .font(.headline)
                                Spacer(minLength: 4)
                                Text(sample.exactValue)
                                    .font(.caption.monospacedDigit())
                            }

                            Text(sample.metricLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            WatchMetricVisualization(sample: sample)

                            HStack(spacing: 4) {
                                Text(sample.accountLabel)
                                if let severityText = sample.severityText {
                                    Text("•")
                                    Label(severityText, systemImage: "exclamationmark.triangle.fill")
                                        .labelStyle(.titleOnly)
                                }
                            }
                            .font(.caption2)
                            .foregroundStyle(sample.severity == .normal ? .secondary : .primary)

                            if let resetText = sample.resetText {
                                Text(resetText)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(sample.accessibilitySummary)
                    }
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    if !state.samples.isEmpty {
                        Text(state.statusText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle(state.title)
    }
}

private struct WatchMetricVisualization: View {
    let sample: WatchUsageSample

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Group {
            switch resolvedStyle {
            case .automatic:
                EmptyView()
            case .linearBar:
                ProgressView(value: sample.clampedUsedFraction)
                    .tint(tint)
            case .segmentedBar:
                HStack(spacing: 2) {
                    ForEach(0..<10, id: \.self) { index in
                        Capsule()
                            .fill(index < filledSegments ? tint : Color.secondary.opacity(0.2))
                            .frame(height: 7)
                    }
                }
            case .circularRing:
                Gauge(value: sample.clampedUsedFraction) {
                    Text(sample.metricLabel)
                } currentValueLabel: {
                    Text(sample.percentageText)
                        .font(.caption2.monospacedDigit())
                }
                .gaugeStyle(.accessoryCircular)
                .tint(tint)
                .frame(height: 48)
            case .semicircularDial:
                SemicircularMetricView(fraction: sample.clampedUsedFraction, tint: tint)
                    .frame(height: 34)
            case .largeNumeric:
                Text(sample.exactValue)
                    .font(.title3.bold().monospacedDigit())
                    .minimumScaleFactor(0.65)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityHidden(true)
    }

    private var resolvedStyle: WatchMetricVisualizationStyle {
        sample.visualizationStyle.resolvedForWatch(allowsGauge: !dynamicTypeSize.isAccessibilitySize)
    }

    private var filledSegments: Int {
        Int((sample.clampedUsedFraction * 10).rounded(.up))
    }

    private var tint: Color {
        switch sample.severity {
        case .normal:
            .accentColor
        case .warning:
            .orange
        case .critical:
            .red
        }
    }
}

private struct SemicircularMetricView: View {
    let fraction: Double
    let tint: Color

    var body: some View {
        ZStack {
            ZStack {
                Circle()
                    .trim(from: 0, to: 0.5)
                    .stroke(
                        Color.secondary.opacity(0.2),
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                Circle()
                    .trim(from: 0, to: 0.5 * fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: 7, lineCap: .round))
            }
            .rotationEffect(.degrees(180))

            Text("\(Int((fraction * 100).rounded()))%")
                .font(.caption2.monospacedDigit())
                .offset(y: 8)
        }
        .clipped()
    }
}

#Preview("Set up on iPhone") {
    WatchDashboardView(state: .empty)
}

#Preview("Sample usage") {
    WatchDashboardView(state: .sample)
}

#Preview("Long labels") {
    WatchDashboardView(
        state: WatchDashboardState(
            title: "CodexBar",
            statusText: "Deterministic preview",
            samples: [
                WatchUsageSample(
                    id: "long-account",
                    providerName: "OpenCode ZEN",
                    accountLabel: "A deliberately long account label",
                    metricLabel: "API balance",
                    exactValue: "$12.48",
                    usedFraction: nil,
                    severity: .normal,
                    resetText: nil,
                    visualizationStyle: .largeNumeric,
                    freshnessText: "Updated just now"
                ),
            ]
        )
    )
}
