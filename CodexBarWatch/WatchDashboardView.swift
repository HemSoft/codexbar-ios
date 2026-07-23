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
                    usedFraction: 0.91
                ),
            ]
        )
    )
}
