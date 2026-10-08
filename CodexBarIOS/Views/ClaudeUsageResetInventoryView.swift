import SwiftUI

/// Confirmation is separate from the irreversible provider request. Only a verified, selected grant is actionable.
struct ClaudeUsageResetInventoryView: View {
    let inventory: ClaudeUsageResetInventory
    let accountName: String
    let canRedeem: Bool
    let onUseReset: ((String, String) async -> ClaudeUsageResetFeedback)?

    @Environment(\.dismiss) private var dismiss
    @State private var selectedGrant: ClaudeUsageResetGrant?
    @State private var isConfirming = false
    @State private var isSubmitting = false
    @State private var feedback: ClaudeUsageResetFeedback?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(accountName)
                    Text(summary)
                        .accessibilityIdentifier("claude-reset-summary")
                    if !inventory.isEligible {
                        Text("Claude has not made usage resets available for this account.")
                    }
                    if !canRedeem {
                        Text("Refresh Claude usage before using a reset.")
                    }
                }
                Section("Saved usage resets") {
                    if inventory.grants.isEmpty {
                        Text("No saved usage resets.")
                    }
                    ForEach(inventory.grants, id: \.id) { grant in
                        grantRow(grant)
                    }
                }
                if let feedback {
                    Section {
                        Label(feedback.message, systemImage: feedback.isSuccess ? "checkmark.circle" : "info.circle")
                            .accessibilityIdentifier("claude-reset-feedback")
                    }
                }
            }
            .navigationTitle("Claude resets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(isSubmitting)
                }
            }
            .alert("Use one Claude reset?", isPresented: $isConfirming) {
                Button("Cancel", role: .cancel) { selectedGrant = nil }
                Button("Use reset") { redeemSelectedGrant() }
            } message: {
                if let grant = selectedGrant {
                    Text("This uses one saved reset for \(accountName). \(windowDescription(grant)) \(expiration(grant)) This cannot be undone.")
                }
            }
        }
        .interactiveDismissDisabled(isSubmitting)
    }

    private var summary: String {
        let count = inventory.availableCount(at: Date())
        return count == 1 ? "1 reset available" : "\(count) resets available"
    }

    private func grantRow(_ grant: ClaudeUsageResetGrant) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(grant.title).font(.headline)
            Text(grant.remainingCount == 1 ? "1 saved reset" : "\(grant.remainingCount) saved resets")
            Text(windowDescription(grant))
            Text(expiration(grant)).font(.subheadline).foregroundStyle(.secondary)
            if grant.isPaused {
                Text("Paused by Claude").foregroundStyle(.secondary)
            } else if !grant.isCurrent(at: Date()) {
                Text("Not currently available").foregroundStyle(.secondary)
            } else if inventory.redeemableGrant(at: Date())?.id != grant.id {
                Text(grant.requiresLimit
                     ? "Claude may require a usage limit to be reached before this reset can be used."
                     : "Claude has not enabled this reset for use now.").foregroundStyle(.secondary)
            }
            if isSubmitting && selectedGrant?.id == grant.id
                || (canRedeem && onUseReset != nil && inventory.credentialBinding != nil
                    && inventory.redeemableGrant(at: Date())?.id == grant.id) {
                Button {
                    selectedGrant = grant
                    isConfirming = true
                } label: {
                    if isSubmitting { ProgressView("Using reset…") } else { Text("Use one reset") }
                }
                .buttonStyle(.bordered)
                .disabled(isSubmitting || !canRedeem)
                .accessibilityIdentifier("claude-use-reset")
            }
        }
        .padding(.vertical, 4)
    }

    private func windowDescription(_ grant: ClaudeUsageResetGrant) -> String {
        let windows = grant.clears.map { value in
            switch value {
            case "five_hour": "five-hour usage"
            case "seven_day": "weekly usage"
            case "seven_day_opus": "Opus weekly usage"
            case "seven_day_sonnet": "Sonnet weekly usage"
            default: "provider-scoped usage"
            }
        }
        return "Resets \(Array(Set(windows)).sorted().joined(separator: " and "))."
    }

    private func expiration(_ grant: ClaudeUsageResetGrant) -> String {
        guard let date = grant.expiresAt else { return "Expiration not provided by Claude." }
        return "Expires \(date.formatted(date: .abbreviated, time: .shortened))."
    }

    private func redeemSelectedGrant() {
        guard !isSubmitting, canRedeem, let onUseReset, let selectedGrant, let binding = inventory.credentialBinding,
              inventory.redeemableGrant(at: Date())?.id == selectedGrant.id
        else { return }
        isSubmitting = true
        Task { @MainActor in
            feedback = await onUseReset(selectedGrant.id, binding)
            self.selectedGrant = nil
            isSubmitting = false
        }
    }
}
