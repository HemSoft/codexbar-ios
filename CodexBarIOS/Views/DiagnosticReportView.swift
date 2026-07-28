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
    @State private var emailFallbackDraft: FeedbackEmailDraft?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(
                        "Review the privacy-safe diagnostic below. Email is private and needs no GitHub account; opening the composer does not send anything. You review and explicitly send the message."
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
                        emailFallbackDraft = problemEmailDraft
                    } label: {
                        Label("Review or Copy Email Details", systemImage: "doc.on.doc")
                    }

                    Button {
                        openGitHubProblemReport()
                    } label: {
                        Label("Open Public GitHub Bug Form", systemImage: "arrow.up.forward.app")
                    }
                } footer: {
                    Text(
                        "GitHub is public and requires an account. CodexBar never includes logs, screenshots, provider responses, credentials, account labels or identifiers, balances, usage history, widget selections, or Apple Watch snapshots."
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
            .sheet(item: $emailFallbackDraft) { draft in
                FeedbackEmailFallbackView(draft: draft)
            }
        }
    }

    private var summary: String {
        PrivacySafeDiagnosticBuilder.summary(
            context: context,
            includeTechnicalDetails: includesTechnicalDetails
        )
    }

    private var problemEmailDraft: FeedbackEmailDraft {
        FeedbackEmailDraft.problemReport(
            context: context,
            includeTechnicalDetails: includesTechnicalDetails
        )
    }

    private func openGitHubProblemReport() {
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

}

private struct Notice: Identifiable {
    let title: String
    let message: String

    var id: String {
        "\(title)-\(message)"
    }
}

struct FeedbackEmailFallbackView: View {
    let draft: FeedbackEmailDraft

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var notice: Notice?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(
                        FeedbackEmailDraft.externalComposerPrivacyNotice
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                ForEach(draft.copyableFields) { field in
                    Section(field.title) {
                        Text(field.value)
                            .font(field.kind == .message ? .callout : .body)
                            .textSelection(.enabled)
                        copyButton(
                            "Copy \(field.title)",
                            fieldName: field.title,
                            value: field.value
                        )
                    }
                }

                Section {
                    Button {
                        openEmailDraft()
                    } label: {
                        Label("Open Email Draft", systemImage: "envelope")
                    }
                } footer: {
                    Text(
                        "Opening the external composer does not send anything. Review the selected sending account before you send."
                    )
                }
            }
            .navigationTitle("Copy Email Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
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

    private func openEmailDraft() {
        openURL(draft.url) { accepted in
            if !accepted {
                notice = Notice(
                    title: "Couldn’t Open Email",
                    message: "Copy the recipient, subject, and message into another email service."
                )
            }
        }
    }

    private func copyButton(_ title: String, fieldName: String, value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
            notice = Notice(
                title: "\(fieldName) Copied",
                message: "\(fieldName) copied to the clipboard."
            )
        } label: {
            Label(title, systemImage: "doc.on.doc")
        }
    }
}
