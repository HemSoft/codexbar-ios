import SwiftUI

struct GreptileRenewalView: View {
    let renewal: GreptileAllowanceRenewal
    var onConnect: (() -> Void)?
    var showsTitle = true

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 6) {
                if showsTitle {
                    Text(renewal.isApplicable == true ? "Free allowance renewal" : "Greptile connection")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(renewal.requiresAuthentication && renewal.isApplicable != true
                     ? "Sign in again to Greptile" : renewal.status(at: context.date))
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
                    if renewal.requiresAuthentication, let onConnect {
                        Button("Sign in to Greptile", action: onConnect)
                            .font(.caption).accessibilityIdentifier("greptile-renewal-connect")
                    }
                    Link("Open Greptile Usage", destination: URL(string: "https://app.greptile.com/-/settings/usage")!)
                        .font(.caption)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}
