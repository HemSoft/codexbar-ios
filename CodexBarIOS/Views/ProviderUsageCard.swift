import Charts
import SwiftUI
import UIKit

struct CodexBankedResetInventoryPresentation: Identifiable, Equatable {
    let id = UUID()
    let resets: CodexBankedRateLimitResets
    let canRedeem: Bool
}

struct ProviderUsageCard: View {
    let result: ProviderUsageResult
    let statusText: String
    let history: UsageHistorySeries
    let alerts: [UsageAlertDetail]
    let isHistoryEnabled: Bool
    let isRefreshing: Bool
    let refreshErrorMessage: String?
    let onShowHistory: () -> Void
    let onRetry: () -> Void
    let onUseCodexReset: ((String?) async -> CodexBankedResetRedemptionFeedback)?

    @State private var resetInventoryPresentation: CodexBankedResetInventoryPresentation?
    @State private var resetFeedback: CodexBankedResetRedemptionFeedback?
    @State private var isResetActionUnavailable = false
    @StateObject private var resetRedemptionController: CodexBankedResetRedemptionController

    init(
        result: ProviderUsageResult,
        statusText: String,
        history: UsageHistorySeries,
        alerts: [UsageAlertDetail] = [],
        isHistoryEnabled: Bool = true,
        isRefreshing: Bool = false,
        refreshErrorMessage: String? = nil,
        onShowHistory: @escaping () -> Void = {},
        onRetry: @escaping () -> Void = {},
        retainedCodexResetAttempt: CodexRetainedResetAttempt? = nil,
        onUseCodexReset: ((String?) async -> CodexBankedResetRedemptionFeedback)? = nil
    ) {
        self.result = result
        self.statusText = statusText
        self.history = history
        self.alerts = alerts
        self.isHistoryEnabled = isHistoryEnabled
        self.isRefreshing = isRefreshing
        self.refreshErrorMessage = refreshErrorMessage
        self.onShowHistory = onShowHistory
        self.onRetry = onRetry
        self.onUseCodexReset = onUseCodexReset
        _resetRedemptionController = StateObject(
            wrappedValue: CodexBankedResetRedemptionController(
                retainedAttempt: retainedCodexResetAttempt,
                resets: result.codexBankedRateLimitResets
            )
        )
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

                ZStack {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("Refreshing \(result.title)")
                    }
                }
                .frame(width: 16, height: 16)

                Circle()
                    .fill(cardSeverity.tint)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }

            if !displayedAlerts.isEmpty {
                UsageAlertSummaryView(alerts: displayedAlerts)
            }

            if showsRetryAction {
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Refreshes usage for \(result.title)")
            }

            if let creditsRemaining = result.creditsRemaining, result.bars.isEmpty {
                Text(CodexBarCurrencyText.format(creditsRemaining))
                    .font(.system(size: 34, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.primary)
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }

            ForEach(result.bars) { bar in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(bar.label)
                        Spacer()
                        Text(bar.usageText)
                            .foregroundStyle(.secondary)
                    }
                    .font(.footnote)

                    if let resetDescription = bar.localizedResetDescription() {
                        Text(resetDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    UsageProgressBar(bar: bar, showsSeverity: result.hasFreshBars)

                    if result.hasFreshBars, let projectionDescription = bar.projectionDescription() {
                        Text(projectionDescription)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if bankedResets != nil {
                HStack(spacing: 8) {
                    Label(bankedResetAvailabilityText, systemImage: "arrow.counterclockwise.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(bankedResetAvailabilityText)

                    Spacer(minLength: 8)

                    if showsCodexResetInventoryAction {
                        Button {
                            resetInventoryPresentation = Self.reconciledResetInventoryPresentation(
                                current: resetInventoryPresentation,
                                requestedResets: bankedResets,
                                canRedeem: showsCodexResetRedemptionActions,
                                requestsPresentation: true
                            )
                        } label: {
                            Text(resetInventoryActionTitle)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .accessibilityHint("Shows each available banked reset and its expiration")
                    }
                }

            }

            if let resetFeedback = resetPresentationFeedback {
                Label(
                    resetFeedback.message,
                    systemImage: resetFeedback.isSuccess ? "checkmark.circle" : "info.circle"
                )
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel(resetFeedback.message)
            }

            if !result.monetaryMetrics.isEmpty {
                Divider()

                ForEach(result.monetaryMetrics) { metric in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Text(metric.label)
                            Spacer()
                            Text(metric.formattedAmount())
                                .fontWeight(.semibold)
                                .monospacedDigit()
                        }
                        .font(.footnote)

                        if let detail = metric.detail {
                            Text(detail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(monetaryAccessibilityLabel(metric))
                }
            }

            ForEach(result.usageMessages, id: \.self) { message in
                Label(message, systemImage: "info.circle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(message)
            }

            if showsHistory {
                UsageHistoryCompactView(
                    series: history,
                    onShowHistory: onShowHistory
                )
            }
        }
        .padding(16)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
        .sheet(item: $resetInventoryPresentation) { presentation in
            CodexBankedResetInventoryView(
                resets: presentation.resets,
                canRedeem: presentation.canRedeem,
                onUseReset: onUseCodexReset,
                onFeedback: { feedback in
                    resetFeedback = feedback
                    isResetActionUnavailable = feedback.hidesAction
                },
                redemptionController: resetRedemptionController
            )
        }
        .onChange(of: result.fetchedAt) {
            resetInventoryPresentation = Self.reconciledResetInventoryPresentation(
                current: resetInventoryPresentation,
                requestedResets: bankedResets,
                canRedeem: showsCodexResetRedemptionActions,
                requestsPresentation: false
            )
            isResetActionUnavailable = false
            resetFeedback = nil
        }
    }

    private var cardSeverity: UsageSeverity {
        max(result.highestSeverity, alerts.map(\.severity).max() ?? .normal)
    }

    var displayedAlerts: [UsageAlertDetail] {
        guard result.providerID == .codex else {
            return alerts
        }
        return alerts.filter { $0.kind != .usage }
    }

    var showsHistory: Bool {
        isHistoryEnabled && (result.creditsRemaining != nil
            || !result.bars.isEmpty
            || !result.monetaryMetrics.isEmpty
            || !history.points.isEmpty)
    }

    var showsRetryAction: Bool {
        refreshErrorMessage != nil && !isRefreshing
    }

    var bankedResets: CodexBankedRateLimitResets? {
        guard
            result.providerID == .codex,
            let resets = result.codexBankedRateLimitResets,
            resets.availableCount > 0
        else {
            return nil
        }
        return resets
    }

    var bankedResetAvailabilityText: String {
        guard let count = bankedResets?.availableCount else {
            return ""
        }
        return count == 1 ? "1 reset available" : "\(count) resets available"
    }

    var showsCodexResetInventoryAction: Bool {
        bankedResets != nil
    }

    var resetInventoryActionTitle: String {
        "View Resets"
    }

    var showsCodexResetRedemptionActions: Bool {
        bankedResets?.canConsume == true
            && onUseCodexReset != nil
            && !isResetActionUnavailable
    }

    var resetPresentationFeedback: CodexBankedResetRedemptionFeedback? {
        Self.resetPresentationFeedback(resetFeedback, availableResets: bankedResets)
    }

    static func resetPresentationFeedback(
        _ feedback: CodexBankedResetRedemptionFeedback?,
        availableResets _: CodexBankedRateLimitResets?
    ) -> CodexBankedResetRedemptionFeedback? {
        feedback
    }

    static func reconciledResetInventoryPresentation(
        current: CodexBankedResetInventoryPresentation?,
        requestedResets: CodexBankedRateLimitResets?,
        canRedeem: Bool,
        requestsPresentation: Bool
    ) -> CodexBankedResetInventoryPresentation? {
        if let current {
            return current
        }
        guard requestsPresentation, let requestedResets else {
            return nil
        }
        return CodexBankedResetInventoryPresentation(
            resets: requestedResets,
            canRedeem: canRedeem
        )
    }

    private func monetaryAccessibilityLabel(_ metric: ProviderMonetaryMetric) -> String {
        [metric.label, metric.formattedAmount(), metric.detail]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

struct CodexBankedResetInventoryItem: Identifiable, Equatable, Sendable {
    let id: String
    let creditID: String?
    let title: String
    let detail: String
    let expiration: String

    init(
        credit: CodexBankedRateLimitReset,
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) {
        id = credit.id
        creditID = credit.id
        title = Self.nonempty(credit.title) ?? "Banked reset"
        detail = Self.nonempty(credit.description) ?? "No description provided."
        expiration = credit.expiresAt.map {
            "Expires \(dateTimeFormatter.dateAndTime($0))"
        } ?? "Expiration unavailable"
    }

    static func generic() -> CodexBankedResetInventoryItem {
        CodexBankedResetInventoryItem(
            id: "generic-banked-reset",
            creditID: nil,
            title: "Use one banked reset",
            detail: "Individual reset details are unavailable for this account.",
            expiration: "Expiration unavailable"
        )
    }

    private init(
        id: String,
        creditID: String?,
        title: String,
        detail: String,
        expiration: String
    ) {
        self.id = id
        self.creditID = creditID
        self.title = title
        self.detail = detail
        self.expiration = expiration
    }

    var confirmationMessage: String {
        if creditID == nil {
            return "This will use one banked reset for the current ChatGPT account. Individual reset details and expiration are unavailable."
        }
        return "This will use the selected banked reset for the current ChatGPT account. \(detail) \(expiration)."
    }

    var accessibilityLabel: String {
        "\(title), \(detail), \(expiration), available"
    }

    private static func nonempty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }
}

@MainActor
final class CodexBankedResetRedemptionController: ObservableObject {
    @Published private(set) var selectedItem: CodexBankedResetInventoryItem?
    @Published private(set) var pendingItem: CodexBankedResetInventoryItem?
    @Published private(set) var retryItem: CodexBankedResetInventoryItem?

    var pendingItemID: String? {
        pendingItem?.id
    }

    var retryItemID: String? {
        retryItem?.id
    }

    var isConfirmationPresented: Bool {
        selectedItem != nil
    }

    init(
        retainedAttempt: CodexRetainedResetAttempt? = nil,
        resets: CodexBankedRateLimitResets? = nil
    ) {
        guard let retainedAttempt else {
            return
        }
        if
            let creditID = retainedAttempt.creditID,
            let credit = resets?.credits?.first(where: { $0.id == creditID })
        {
            retryItem = CodexBankedResetInventoryItem(credit: credit)
        } else if let creditID = retainedAttempt.creditID {
            retryItem = CodexBankedResetInventoryItem(
                credit: CodexBankedRateLimitReset(id: creditID)
            )
        } else {
            retryItem = .generic()
        }
    }

    func requestConfirmation(for item: CodexBankedResetInventoryItem) {
        guard canRequestConfirmation(for: item) else {
            return
        }
        selectedItem = item
    }

    func cancelConfirmation() {
        selectedItem = nil
    }

    func beginRedemption() -> CodexBankedResetInventoryItem? {
        guard let selectedItem else {
            return nil
        }
        return beginRedemption(for: selectedItem)
    }

    func beginRedemption(
        for item: CodexBankedResetInventoryItem
    ) -> CodexBankedResetInventoryItem? {
        guard canRequestConfirmation(for: item) else {
            return nil
        }
        pendingItem = item
        retryItem = nil
        self.selectedItem = nil
        return item
    }

    func finishRedemption(
        for item: CodexBankedResetInventoryItem,
        requiresSameResetForRetry: Bool = false
    ) {
        guard pendingItemID == item.id else {
            return
        }
        pendingItem = nil
        retryItem = requiresSameResetForRetry ? item : nil
    }

    func canRequestConfirmation(for item: CodexBankedResetInventoryItem) -> Bool {
        pendingItemID == nil && (retryItemID == nil || retryItemID == item.id)
    }
}

struct CodexBankedResetInventoryView: View {
    let resets: CodexBankedRateLimitResets
    let canRedeem: Bool
    let onUseReset: ((String?) async -> CodexBankedResetRedemptionFeedback)?
    let onFeedback: (CodexBankedResetRedemptionFeedback) -> Void
    @ObservedObject var redemptionController: CodexBankedResetRedemptionController

    @Environment(\.dismiss) private var dismiss
    @State private var feedback: CodexBankedResetRedemptionFeedback?

    var inventoryItems: [CodexBankedResetInventoryItem] {
        let currentItems: [CodexBankedResetInventoryItem]
        if !resets.orderedCredits.isEmpty {
            let detailedItems = resets.orderedCredits.map {
                CodexBankedResetInventoryItem(credit: $0)
            }
            currentItems = if canRedeem, resets.availableCount > detailedItems.count {
                detailedItems + [.generic()]
            } else {
                detailedItems
            }
        } else {
            currentItems = canRedeem ? [.generic()] : []
        }

        guard
            let retainedItem = redemptionController.pendingItem ?? redemptionController.retryItem,
            !currentItems.contains(where: { $0.id == retainedItem.id })
        else {
            return currentItems
        }
        return [retainedItem] + currentItems
    }

    var unavailableDetailCount: Int {
        max(resets.availableCount - resets.orderedCredits.count, 0)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if inventoryItems.isEmpty {
                        Text("Individual reset details are unavailable. Redemption is not available from CodexBar right now.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        ForEach(inventoryItems) { item in
                            if canRedeem {
                                Button {
                                    redemptionController.requestConfirmation(for: item)
                                } label: {
                                    resetRow(item)
                                }
                                .buttonStyle(.plain)
                                .disabled(!redemptionController.canRequestConfirmation(for: item))
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(item.accessibilityLabel)
                                .accessibilityHint(
                                    redemptionController.retryItemID == item.id
                                        ? "Retries the original redemption attempt for this reset"
                                        : "Asks for confirmation before using this reset"
                                )
                            } else {
                                resetRow(item)
                                    .accessibilityElement(children: .ignore)
                                    .accessibilityLabel(item.accessibilityLabel)
                            }
                        }
                    }
                } header: {
                    Text(resets.availableCount == 1 ? "1 reset available" : "\(resets.availableCount) resets available")
                } footer: {
                    if unavailableDetailCount > 0, !resets.orderedCredits.isEmpty {
                        Text(unavailableDetailCount == 1
                            ? "Details are unavailable for 1 additional reset."
                            : "Details are unavailable for \(unavailableDetailCount) additional resets.")
                    } else if !canRedeem, !inventoryItems.isEmpty {
                        Text("This inventory is read-only because redemption is not available from CodexBar right now.")
                    }
                }

                if let feedback {
                    Section {
                        Label(
                            feedback.message,
                            systemImage: feedback.isSuccess ? "checkmark.circle" : "info.circle"
                        )
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(feedback.message)
                    }
                }
            }
            .navigationTitle("Saved Codex Resets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert(
                redemptionController.selectedItem.map { "Use \($0.title)?" } ?? "Use Reset?",
                isPresented: Binding(
                    get: { redemptionController.isConfirmationPresented },
                    set: { isPresented in
                        if !isPresented {
                            redemptionController.cancelConfirmation()
                        }
                    }
                ),
                presenting: redemptionController.selectedItem
            ) { item in
                Button("Cancel", role: .cancel) {
                    redemptionController.cancelConfirmation()
                }
                Button("Use Reset", role: .destructive) {
                    redeemSelectedReset(item)
                }
            } message: { item in
                Text(item.confirmationMessage)
            }
        }
    }

    @ViewBuilder
    private func resetRow(_ item: CodexBankedResetInventoryItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(item.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(item.expiration, systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if redemptionController.retryItemID == item.id {
                    Label("Retry this reset", systemImage: "arrow.clockwise")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if redemptionController.pendingItemID == item.id {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Using \(item.title)")
            } else if canRedeem {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
    }

    private func redeemSelectedReset(_ presentedItem: CodexBankedResetInventoryItem) {
        guard
            let onUseReset,
            let item = redemptionController.beginRedemption(for: presentedItem)
        else {
            return
        }

        feedback = nil
        Task {
            let result = await onUseReset(item.creditID)
            redemptionController.finishRedemption(
                for: item,
                requiresSameResetForRetry: result.requiresSameResetForRetry
            )
            feedback = result
            onFeedback(result)
            UIAccessibility.post(notification: .announcement, argument: result.message)
            if result.isSuccess || result.hidesAction {
                dismiss()
            }
        }
    }
}

struct ProviderUsagePlaceholderCard: View {
    let configuration: ProviderAccountConfiguration
    let errorMessage: String?
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 8) {
                ProviderLogoTile(providerID: configuration.providerID)

                Text(configuration.displayName)
                    .font(.headline)

                Spacer()
            }

            if let errorMessage {
                Label("Could not load usage", systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)

                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityHint("Refreshes usage for \(configuration.displayName)")
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)

                    Text("Loading current usage")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading current usage for \(configuration.displayName)")

                VStack(alignment: .leading, spacing: 10) {
                    loadingRow(labelWidth: 92, valueWidth: 64)
                    loadingRow(labelWidth: 116, valueWidth: 48)
                }
                .accessibilityHidden(true)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(.separator).opacity(0.22), lineWidth: 0.5)
        }
    }

    private func loadingRow(labelWidth: CGFloat, valueWidth: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                loadingBar(width: labelWidth, height: 11)
                Spacer()
                loadingBar(width: valueWidth, height: 11)
            }

            loadingBar(width: nil, height: 7)
        }
    }

    private func loadingBar(width: CGFloat?, height: CGFloat) -> some View {
        Capsule()
            .fill(Color(.tertiarySystemFill))
            .frame(width: width, height: height)
    }
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

private struct UsageHistoryCompactView: View {
    let series: UsageHistorySeries
    let onShowHistory: () -> Void

    var body: some View {
        Button(action: onShowHistory) {
            HStack(spacing: 12) {
                UsageTrendSparkline(series: series, tint: series.tint)
                    .frame(width: 88, height: 38)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(series.latestValueDescription)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .monospacedDigit()

                        Text(series.changeDescription)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(series.tint)
                            .lineLimit(1)
                    }

                    Text(series.rangeDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(series.sampleWindowDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "Usage history. Latest \(series.latestValueDescription). \(series.changeDescription). \(series.rangeDescription)."
        )
        .accessibilityHint("Shows the expanded history graph.")
    }
}

private struct UsageTrendSparkline: View {
    let series: UsageHistorySeries
    let tint: Color

    var body: some View {
        Canvas { context, size in
            guard !series.points.isEmpty else {
                var placeholder = Path()
                placeholder.move(to: CGPoint(x: 0, y: size.height / 2))
                placeholder.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(
                    placeholder,
                    with: .color(tint.opacity(0.35)),
                    style: StrokeStyle(lineWidth: 1.5, dash: [3, 3])
                )
                return
            }

            let firstDate = series.points.first?.capturedAt ?? Date()
            let lastDate = series.points.last?.capturedAt ?? firstDate
            let timeSpan = max(lastDate.timeIntervalSince(firstDate), 1)
            let valueSpan = max(series.chartDomain.upperBound - series.chartDomain.lowerBound, 0.0001)
            var path = Path()
            var lastResolvedPoint = CGPoint(x: size.width / 2, y: size.height / 2)

            for (index, point) in series.points.enumerated() {
                let x = series.points.count == 1
                    ? size.width / 2
                    : CGFloat(point.capturedAt.timeIntervalSince(firstDate) / timeSpan) * size.width
                let normalizedValue = (point.value - series.chartDomain.lowerBound) / valueSpan
                let y = size.height - CGFloat(min(max(normalizedValue, 0), 1)) * size.height
                let resolvedPoint = CGPoint(x: x, y: y)
                lastResolvedPoint = resolvedPoint

                if index == 0 {
                    path.move(to: resolvedPoint)
                } else {
                    path.addLine(to: resolvedPoint)
                }
            }

            if series.points.count >= 2 {
                context.stroke(
                    path,
                    with: .color(tint),
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
                )
            }

            context.fill(
                Path(ellipseIn: CGRect(
                    x: lastResolvedPoint.x - 3,
                    y: lastResolvedPoint.y - 3,
                    width: 6,
                    height: 6
                )),
                with: .color(tint)
            )
        }
        .accessibilityHidden(true)
    }
}

struct ProviderUsageHistoryDetailView: View {
    @Environment(\.dismiss) private var dismiss

    let result: ProviderUsageResult
    let seriesOptions: [UsageHistorySeriesOption]

    @State private var selectedDate: Date?
    @State private var selectedSeriesID: String

    init(result: ProviderUsageResult, seriesOptions: [UsageHistorySeriesOption]) {
        self.result = result
        self.seriesOptions = seriesOptions
        _selectedSeriesID = State(initialValue: seriesOptions.first?.id ?? "primary")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    accountHeader

                    if seriesOptions.count > 1 {
                        Picker("History metric", selection: $selectedSeriesID) {
                            ForEach(seriesOptions) { option in
                                Text(option.label).tag(option.id)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: selectedSeriesID) {
                            selectedDate = nil
                        }
                    }

                    if series.points.isEmpty {
                        ContentUnavailableView(
                            "No History Yet",
                            systemImage: "chart.xyaxis.line",
                            description: Text("A history graph will appear after usage has been refreshed.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        chartSection
                        statisticsSection
                        recentSamplesSection
                    }
                }
                .frame(maxWidth: 720, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var series: UsageHistorySeries {
        seriesOptions.first(where: { $0.id == selectedSeriesID })?.series
            ?? seriesOptions.first?.series
            ?? UsageHistorySeries(accountID: result.accountID, points: [], isBalance: false)
    }

    private var accountHeader: some View {
        HStack(spacing: 10) {
            ProviderLogoTile(providerID: result.providerID)
                .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.title)
                    .font(.headline)

                Text(series.sampleWindowDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var chartSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(displayedPoint.map { series.valueDescription(for: $0.value) } ?? series.latestValueDescription)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()

                    if let displayedPoint {
                        Text(UserFacingDateTimeFormatter.current.dateAndTime(displayedPoint.capturedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Text(series.changeDescription)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(series.tint)
            }

            Chart {
                ForEach(series.points) { point in
                    if series.points.count >= 2 {
                        AreaMark(
                            x: .value("Time", point.capturedAt),
                            yStart: .value("Baseline", series.chartDomain.lowerBound),
                            yEnd: .value("Value", point.value)
                        )
                        .foregroundStyle(series.tint.opacity(0.1))

                        LineMark(
                            x: .value("Time", point.capturedAt),
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(series.tint)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    }

                    if series.points.count <= 12 {
                        PointMark(
                            x: .value("Time", point.capturedAt),
                            y: .value("Value", point.value)
                        )
                        .foregroundStyle(series.tint.opacity(0.75))
                        .symbolSize(24)
                    }
                }

                if !series.isBalance {
                    RuleMark(y: .value("Limit", 1.0))
                        .foregroundStyle(Color.secondary.opacity(0.6))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .top, alignment: .trailing) {
                            Text("100% limit")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                }

                if let displayedPoint {
                    RuleMark(x: .value("Selected time", displayedPoint.capturedAt))
                        .foregroundStyle(Color.secondary.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

                    PointMark(
                        x: .value("Selected time", displayedPoint.capturedAt),
                        y: .value("Selected value", displayedPoint.value)
                    )
                    .foregroundStyle(series.tint)
                    .symbolSize(52)
                }
            }
            .chartYScale(domain: series.chartDomain)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { value in
                    AxisGridLine()
                        .foregroundStyle(Color.secondary.opacity(0.15))
                    AxisTick()
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(axisDateText(for: date))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                    AxisGridLine()
                        .foregroundStyle(Color.secondary.opacity(0.15))
                    AxisTick()
                    AxisValueLabel {
                        if let numericValue = value.as(Double.self) {
                            Text(series.valueDescription(for: numericValue))
                        }
                    }
                }
            }
            .chartXSelection(value: $selectedDate)
            .frame(height: 260)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(result.title) history chart")
            .accessibilityValue(
                "\(series.sampleWindowDescription). Latest \(series.latestValueDescription). \(series.changeDescription). \(series.rangeDescription)."
            )
            .accessibilityHint("Drag across the chart to inspect historical values.")

            if series.points.count == 1 {
                Text("More samples will appear after future refreshes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statisticsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Summary")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 14) {
                GridRow {
                    HistoryMetricView(title: "Latest", value: series.latestValueDescription)
                    HistoryMetricView(title: "Change", value: series.changeDescription)
                }

                Divider()
                    .gridCellColumns(2)

                GridRow {
                    HistoryMetricView(title: "Low", value: series.minimumValueDescription)
                    HistoryMetricView(title: "High", value: series.maximumValueDescription)
                }
            }
        }
    }

    private var recentSamplesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Recent Samples")
                .font(.headline)
                .padding(.bottom, 8)

            ForEach(Array(series.points.suffix(20).reversed())) { point in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(series.valueDescription(for: point.value))
                            .font(.body.weight(.semibold))
                            .monospacedDigit()

                        Text(UserFacingDateTimeFormatter.current.dateAndTime(point.capturedAt))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Circle()
                        .fill(point.severity.tint)
                        .frame(width: 9, height: 9)
                        .accessibilityHidden(true)
                }
                .padding(.vertical, 10)

                Divider()
            }
        }
    }

    private var displayedPoint: UsageHistoryPoint? {
        guard let selectedDate else {
            return series.points.last
        }

        return series.points.min { lhs, rhs in
            abs(lhs.capturedAt.timeIntervalSince(selectedDate))
                < abs(rhs.capturedAt.timeIntervalSince(selectedDate))
        }
    }

    private func axisDateText(for date: Date) -> String {
        guard
            let first = series.points.first?.capturedAt,
            let last = series.points.last?.capturedAt
        else {
            return ""
        }

        if last.timeIntervalSince(first) < 24 * 60 * 60 {
            return UserFacingDateTimeFormatter.current.time(date)
        }

        return UserFacingDateTimeFormatter.current.shortDate(date)
    }
}

private struct HistoryMetricView: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private extension UsageHistorySeries {
    var tint: Color {
        switch direction {
        case .flat:
            .secondary
        case .up where isBalance:
            .green
        case .down where isBalance:
            .orange
        case .up:
            .orange
        case .down:
            .green
        }
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

private struct ProviderLogoTile: View {
    let providerID: ProviderID

    var body: some View {
        CodexBarProviderLogo(
            providerID: providerID.rawValue,
            size: 24,
            background: Color(.secondarySystemGroupedBackground),
            border: Color(.separator).opacity(0.3),
            imagePadding: 4
        )
    }
}

private struct UsageProgressBar: View {
    let bar: UsageBar
    let showsSeverity: Bool

    var body: some View {
        let projectedFraction = showsSeverity ? bar.projectedFraction() : nil
        CodexBarUsageProgressBar(
            fractionUsed: bar.fractionUsed,
            projectedFraction: projectedFraction,
            severity: showsSeverity ? bar.severity.widgetSeverity : .normal,
            projectedSeverity: projectedFraction.map { UsageSeverity(fractionUsed: $0).widgetSeverity },
            fillColor: showsSeverity ? nil : Color.secondary.opacity(0.55),
            height: 7,
            trackColor: Color(.tertiarySystemFill),
            accessibilityText: "\(bar.label) \(bar.usageText)"
        )
    }
}

private extension UsageSeverity {
    var widgetSeverity: CodexBarWidgetSeverity {
        switch self {
        case .normal:
            .normal
        case .warning:
            .warning
        case .critical:
            .critical
        }
    }
}

#Preview {
    let fiveHourReset = Date().addingTimeInterval(8_100)
    let weeklyReset = Date().addingTimeInterval(2 * 24 * 60 * 60 + 4 * 60 * 60)
    let formatter = UserFacingDateTimeFormatter.current
    let fiveHourResetDescription = "Resets 2h 15m (\(formatter.timeWithZone(fiveHourReset, includesWeekday: false)))"
    let weeklyResetDescription = "Resets 2d 4h (\(formatter.timeWithZone(weeklyReset, includesWeekday: true)))"
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
                    resetDescription: fiveHourResetDescription,
                    resetsAt: fiveHourReset,
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
                    resetDescription: weeklyResetDescription
                )
            ],
            fetchedAt: Date()
        ),
        statusText: "Not configured - demo data",
        history: UsageHistorySeries(
            accountID: "codex",
            points: [0.34, 0.46, 0.52, 0.45, 0.62].enumerated().map { index, value in
                UsageHistoryPoint(
                    id: "preview.\(index)",
                    capturedAt: Date().addingTimeInterval(TimeInterval(index - 4) * 24 * 60 * 60),
                    value: value,
                    severity: UsageSeverity(fractionUsed: value)
                )
            },
            isBalance: false
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
