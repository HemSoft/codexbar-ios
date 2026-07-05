import SwiftUI

struct ProviderUsageCard: View {
    let result: ProviderUsageResult
    let statusText: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .center, spacing: 8) {
                        ProviderLogoTile(providerID: result.providerID)

                        Text(result.title)
                            .font(.headline)
                    }

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

            if let creditsRemaining = result.creditsRemaining {
                Text(Self.currencyFormatter.string(from: NSNumber(value: creditsRemaining)) ?? "$0.00")
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            } else {
                ForEach(result.bars) { bar in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(bar.label)
                            Spacer()
                            Text(bar.usageText)
                                .foregroundStyle(.secondary)
                        }
                        .font(.footnote)

                        if let resetDescription = bar.resetDescription {
                            Text(resetDescription)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        UsageProgressBar(bar: bar)

                        if let projectionDescription = bar.projectionDescription() {
                            Text(projectionDescription)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}

private extension ProviderID {
    var cardLogoAssetName: String {
        switch self {
        case .codex:
            "CodexLogo"
        case .copilot:
            "CopilotLogo"
        case .claude:
            "ClaudeLogo"
        case .openRouter:
            "OpenRouterLogo"
        case .openCodeZen:
            "OpenCodeZenLogo"
        case .cursor:
            "CursorLogo"
        }
    }
}

private struct ProviderLogoTile: View {
    let providerID: ProviderID

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(Color(.separator).opacity(0.3), lineWidth: 0.5)
                }

            Image(providerID.cardLogoAssetName)
                .resizable()
                .renderingMode(.original)
                .scaledToFit()
                .padding(4)
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

private struct UsageProgressBar: View {
    let bar: UsageBar

    var body: some View {
        GeometryReader { proxy in
            let actualWidth = proxy.size.width * bar.fractionUsed
            let projectedFraction = bar.projectedFraction() ?? 0
            let projectedWidth = proxy.size.width * projectedFraction

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(.tertiarySystemFill))

                if projectedWidth > actualWidth {
                    Capsule()
                        .fill(UsageSeverity(fractionUsed: projectedFraction).projectedTint.opacity(0.55))
                        .frame(width: projectedWidth)
                }

                Capsule()
                    .fill(bar.severity.tint)
                    .frame(width: actualWidth)
            }
        }
        .frame(height: 7)
        .accessibilityLabel("\(bar.label) \(bar.usageText)")
    }
}

#Preview {
    ProviderUsageCard(
        result: ProviderUsageResult(
            providerID: .codex,
            title: ProviderID.codex.displayName,
            subtitle: "Preview data",
            bars: [
                UsageBar(
                    label: "5 hour usage limit",
                    used: 45,
                    limit: 100,
                    resetDescription: "Resets 2h 15m (3:42 PM EDT)",
                    resetsAt: Date().addingTimeInterval(8_100),
                    projectionCurrent: 0.45,
                    projectionLimit: 1,
                    projectionPeriodStart: Date().addingTimeInterval(-3_600),
                    projectionPeriodEnd: Date().addingTimeInterval(8_100),
                    showProjectionOnCurrentBar: true
                ),
                UsageBar(
                    label: "Weekly usage limit",
                    used: 92,
                    limit: 100,
                    resetDescription: "Resets 2d 4h (Thu 4:00 AM EDT)"
                )
            ],
            fetchedAt: Date()
        ),
        statusText: "Not configured - demo data"
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}
