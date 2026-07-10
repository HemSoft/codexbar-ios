import SwiftUI

struct ProviderUsageCard: View {
    let result: ProviderUsageResult
    let statusText: String
    let trend: UsageTrendSummary?
    let alerts: [UsageAlertDetail]

    init(
        result: ProviderUsageResult,
        statusText: String,
        trend: UsageTrendSummary?,
        alerts: [UsageAlertDetail] = []
    ) {
        self.result = result
        self.statusText = statusText
        self.trend = trend
        self.alerts = alerts
    }

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
                    .fill(cardSeverity.tint)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }

            if !alerts.isEmpty {
                UsageAlertSummaryView(alerts: alerts)
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

            if let trend {
                UsageTrendRow(trend: trend)
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
    }

    private var cardSeverity: UsageSeverity {
        max(result.highestSeverity, alerts.map(\.severity).max() ?? .normal)
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

private struct UsageAlertSummaryView: View {
    let alerts: [UsageAlertDetail]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(alerts) { alert in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: alert.kind.systemImageName)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(alert.severity.tint)
                        .frame(width: 16)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(alert.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(alert.message)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        alerts
            .map { "\($0.title). \($0.message)" }
            .joined(separator: " ")
    }
}

struct UsageTrendRow: View {
    let trend: UsageTrendSummary

    var body: some View {
        HStack(spacing: 10) {
            UsageTrendSparkline(points: trend.points, tint: tint)
                .frame(width: 62, height: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text(trend.valueDescription)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(trend.windowDescription)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch trend.direction {
        case .flat:
            .secondary
        case .up where trend.isBalance:
            .green
        case .down where trend.isBalance:
            .orange
        case .up:
            .orange
        case .down:
            .green
        }
    }
}

struct UsageTrendSparkline: View {
    let points: [Double]
    let tint: Color

    var body: some View {
        Canvas { context, size in
            guard points.count >= 2 else {
                return
            }

            let minValue = points.min() ?? 0
            let maxValue = points.max() ?? 1
            let span = max(maxValue - minValue, 0.0001)
            let isFlat = abs(maxValue - minValue) < 0.0001
            let step = size.width / CGFloat(points.count - 1)
            var path = Path()

            for (index, point) in points.enumerated() {
                let x = CGFloat(index) * step
                let y = isFlat ? size.height / 2 : size.height - CGFloat((point - minValue) / span) * size.height
                let resolvedPoint = CGPoint(x: x, y: y)

                if index == 0 {
                    path.move(to: resolvedPoint)
                } else {
                    path.addLine(to: resolvedPoint)
                }
            }

            context.stroke(
                path,
                with: .color(tint),
                style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            )
        }
        .accessibilityHidden(true)
    }
}

private extension UsageAlertKind {
    var systemImageName: String {
        switch self {
        case .usage:
            "gauge.with.dots.needle.67percent"
        case .balance:
            "creditcard"
        case .severity:
            "exclamationmark.triangle.fill"
        }
    }
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
        statusText: "Not configured - demo data",
        trend: UsageTrendSummary(
            accountID: "codex",
            points: [0.34, 0.46, 0.52, 0.45, 0.62],
            valueDescription: "Changed +17 pts",
            windowDescription: "Since Sep 3, 2026 at 6:39 PM",
            isBalance: false,
            direction: .up
        ),
        alerts: [
            UsageAlertDetail(
                id: "usage.codex.weekly-usage-limit",
                accountID: "codex",
                kind: .usage,
                title: "Weekly usage limit at 92%",
                message: "92 of 100 used. Alert threshold: 80%. Resets 2d 4h.",
                severity: .critical
            ),
        ]
    )
    .padding()
    .background(Color(.systemGroupedBackground))
}
