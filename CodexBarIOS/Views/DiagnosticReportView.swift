import SwiftUI
import UIKit

extension FeedbackSupportContext {
    @MainActor
    static func current(installedVersion: InstalledAppVersion) -> FeedbackSupportContext {
        let device = UIDevice.current
        return FeedbackSupportContext(
            appVersion: installedVersion.marketingVersion,
            buildNumber: installedVersion.buildNumber,
            operatingSystemName: device.systemName,
            operatingSystemVersion: device.systemVersion,
            deviceCategory: device.localizedModel
        )
    }
}

struct DiagnosticReportView: View {
    let context: PrivacySafeDiagnosticContext

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var includesTechnicalDetails = true
    @State private var notice: Notice?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(
                        "Review exactly what CodexBar will copy or add to GitHub. GitHub issues and attachments are public."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                if context.technicalDetails != nil {
                    Section {
                        Toggle("Include optional technical details", isOn: $includesTechnicalDetails)
                    } footer: {
                        Text("Turn this off to remove configuration, failure, refresh, and freshness categories.")
                    }
                }

                Section("Diagnostic Preview") {
                    Text(summary)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .accessibilityLabel("Privacy-safe diagnostic preview")
                }

                Section {
                    Button {
                        UIPasteboard.general.string = summary
                        notice = Notice(
                            title: "Diagnostic Copied",
                            message: "Paste it only after reviewing the public report."
                        )
                    } label: {
                        Label("Copy Diagnostic", systemImage: "doc.on.doc")
                    }

                    Button {
                        openProblemReport()
                    } label: {
                        Label("Open GitHub Bug Form", systemImage: "arrow.up.forward.app")
                    }
                } footer: {
                    Text(
                        "CodexBar never uploads logs, screenshots, provider responses, credentials, account labels, balances, usage history, widget selections, or Apple Watch snapshots."
                    )
                }
            }
            .navigationTitle("Report This Problem")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .alert(item: $notice) { notice in
                Alert(
                    title: Text(notice.title),
                    message: Text(notice.message),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private var summary: String {
        PrivacySafeDiagnosticBuilder.summary(
            context: context,
            includeTechnicalDetails: includesTechnicalDetails
        )
    }

    private func openProblemReport() {
        switch FeedbackSupportDestination.problemReportLaunch(
            context: context,
            includeTechnicalDetails: includesTechnicalDetails
        ) {
        case .url(let url):
            openURL(url) { accepted in
                if !accepted {
                    notice = Notice(
                        title: "Couldn’t Open GitHub",
                        message: "Copy the diagnostic and try again later."
                    )
                }
            }
        case .copyOnly(let summary):
            UIPasteboard.general.string = summary
            notice = Notice(
                title: "Diagnostic Copied",
                message: "The prefilled link was too long, so no external page was opened. Open the bug form and paste the copied details."
            )
        }
    }

    private struct Notice: Identifiable {
        let title: String
        let message: String

        var id: String {
            "\(title)-\(message)"
        }
    }
}
