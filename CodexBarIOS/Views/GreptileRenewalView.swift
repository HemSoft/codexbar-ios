import SwiftUI

struct GreptileRenewalView: View {
    let renewal: GreptileAllowanceRenewal
    var onConnect: (() -> Void)?
    var showsTitle = true

    private func connectionStatus(at date: Date) -> String {
        if renewal.requiresNewAccount { return "Add a Greptile account" }
        if renewal.requiresAuthentication && renewal.isApplicable != true { return "Sign in again to Greptile" }
        return renewal.status(at: date)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 6) {
                if showsTitle {
                    Text(renewal.isApplicable == true ? "Free allowance renewal" : "Greptile connection")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(connectionStatus(at: context.date))
                    .font(.subheadline.weight(.semibold))
                    .accessibilityIdentifier("greptile-renewal-status")
                if let date = renewal.localDateText {
                    Text(date).font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("greptile-renewal-date")
                } else {
                    Text(renewal.unavailableReason ?? (renewal.isApplicable == true
                         ? "Greptile did not return a valid free-allowance renewal date." : "Your Greptile session needs reconnecting."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if renewal.renewsAt == nil || renewal.requiresAuthentication {
                    if renewal.requiresAuthentication || renewal.requiresNewAccount, let onConnect {
                        Button(renewal.requiresNewAccount ? "Add Greptile account" : "Sign in to Greptile", action: onConnect)
                            .font(.caption).accessibilityIdentifier("greptile-renewal-connect")
                    }
                    Link("Open Greptile Usage", destination: URL(string: "https://app.greptile.com/-/settings/usage")!)
                        .font(.caption)
                }
            }
            .buttonStyle(.borderless)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
