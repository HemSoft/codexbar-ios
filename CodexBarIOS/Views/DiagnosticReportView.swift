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
                        openProblemEmail()
                    } label: {
                        Label("Open Email Draft", systemImage: "envelope")
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

    private func openProblemEmail() {
        let draft = FeedbackEmailDraft.problemReport(
            context: context,
            includeTechnicalDetails: includesTechnicalDetails
        )
        openURL(draft.url) { accepted in
            if !accepted {
                emailFallbackDraft = draft
            }
        }
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

    private struct Notice: Identifiable {
        let title: String
        let message: String

        var id: String {
            "\(title)-\(message)"
        }
    }
}

struct FeedbackEmailFallbackView: View {
    let draft: FeedbackEmailDraft

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(
                        "No configured email app could be opened. Copy these fields into any email service. Nothing has been sent."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section("Recipient") {
                    Text(FeedbackEmailDraft.recipient)
                        .textSelection(.enabled)
                    copyButton("Copy Recipient", value: FeedbackEmailDraft.recipient)
                }

                Section("Subject") {
                    Text(draft.subject)
                        .textSelection(.enabled)
                    copyButton("Copy Subject", value: draft.subject)
                }

                Section("Message") {
                    Text(draft.body)
                        .font(.callout)
                        .textSelection(.enabled)
                    copyButton("Copy Message", value: draft.body)
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
        }
    }

    private func copyButton(_ title: String, value: String) -> some View {
        Button {
            UIPasteboard.general.string = value
        } label: {
            Label(title, systemImage: "doc.on.doc")
        }
    }
}
