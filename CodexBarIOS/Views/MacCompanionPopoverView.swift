import SwiftUI

struct MacCompanionPopoverView: View {
    let snapshot: MacCompanionMenuSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(snapshot.headline)
                    .font(.headline)
                    .lineLimit(1)

                Text(snapshot.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Divider()

            if snapshot.rows.isEmpty {
                ContentUnavailableView(
                    "No Usage Data",
                    systemImage: "gauge.with.dots.needle.50percent",
                    description: Text("Open CodexBar to refresh.")
                )
                .frame(minHeight: 120)
            } else {
                VStack(spacing: 0) {
                    ForEach(snapshot.rows) { row in
                        MacCompanionProviderRow(row: row)

                        if row.id != snapshot.rows.last?.id {
                            Divider()
                                .padding(.leading, 36)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

private struct MacCompanionProviderRow: View {
    let row: MacCompanionMenuRow

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(row.severity.tint)
                .frame(width: 9, height: 9)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(row.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            Text(row.value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
        }
        .padding(.vertical, 8)
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
    MacCompanionPopoverView(
        snapshot: MacCompanionMenuSnapshot(
            snapshot: CodexBarWidgetSnapshot(
                generatedAt: Date(),
                results: [
                    CodexBarWidgetProviderSnapshot(
                        accountID: "codex.personal",
                        providerID: "codex",
                        title: "ChatGPT / Codex",
                        subtitle: "Personal",
                        bars: [
                            CodexBarWidgetUsageBarSnapshot(
                                id: "codex.personal.0",
                                label: "5-hour",
                                fractionUsed: 0.94,
                                usageText: "94%",
                                resetDescription: "Resets 1h",
                                severity: .critical
                            ),
                        ],
                        creditsRemaining: nil,
                        fetchedAt: Date(),
                        severity: .critical
                    ),
                    CodexBarWidgetProviderSnapshot(
                        accountID: "openrouter.work",
                        providerID: "openRouter",
                        title: "OpenRouter",
                        subtitle: "API key",
                        bars: [],
                        creditsRemaining: 8.25,
                        fetchedAt: Date(),
                        severity: .normal
                    ),
                ]
            )
        )
    )
}
