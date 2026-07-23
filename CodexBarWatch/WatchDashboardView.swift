import SwiftUI

struct WatchDashboardView: View {
    let state: WatchDashboardState

    var body: some View {
        List {
            Section {
                ForEach(state.samplesByHighestUsage) { sample in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(sample.providerName)
                                .font(.headline)
                            Spacer(minLength: 4)
                            Text(sample.percentageText)
                                .font(.caption.monospacedDigit())
                        }

                        ProgressView(value: sample.clampedUsedFraction)
                            .tint(sample.clampedUsedFraction >= 0.8 ? .orange : .accentColor)

                        Text(sample.accountLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(sample.accessibilitySummary)
                }
            } header: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.title)
                        .font(.headline)
                        .accessibilityAddTraits(.isHeader)
                    Text(state.statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(state.title)
    }
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
                    usedFraction: 0.91
                ),
            ]
        )
    )
}
