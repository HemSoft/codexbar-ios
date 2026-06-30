import SwiftUI

struct ProviderUsageCard: View {
    let result: ProviderUsageResult
    let statusText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title)
                        .font(.headline)
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Circle()
                    .fill(result.highestSeverity.tint)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }

            ForEach(result.bars) { bar in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(bar.label)
                        Spacer()
                        Text(bar.usageText)
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)

                    ProgressView(value: bar.fractionUsed)
                        .tint(bar.severity.tint)
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

#Preview {
    ProviderUsageCard(
        result: ProviderUsageResult(
            providerID: .codex,
            title: ProviderID.codex.displayName,
            subtitle: "Preview data",
            bars: [
                UsageBar(label: "5-hour", used: 45, limit: 100),
                UsageBar(label: "Weekly", used: 92, limit: 100)
            ],
            fetchedAt: Date()
        ),
        statusText: "Not configured - demo data"
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}
