import SwiftUI

struct OpenCodeBrowserSignInView: View {
    @ObservedObject var session: OpenCodeBrowserSignInSession

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "safari").font(.largeTitle)
                    if session.progress != .waitingForApproval {
                        verificationContent
                    } else if let mode = session.browserMode {
                        approvalContent(mode: mode)
                    } else {
                        browserChoice
                    }
                }
                .padding()
            }
            .navigationTitle("OpenCode sign-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { session.cancel() }
                }
            }
        }
        .interactiveDismissDisabled()
    }

    private var browserChoice: some View {
        VStack(spacing: 20) {
            Text("Choose how to sign in").font(.headline)
            if let message = session.retryMessage {
                Text(message).foregroundStyle(.secondary)
            }
            Text("Browser sign-in can use accounts already signed in on this device. Private sign-in starts a separate session.")
            Button("Use browser sign-in") { session.start(mode: .existingSession) }
                .buttonStyle(.borderedProminent)
            Button("Use private sign-in") { session.start(mode: .privateSession) }
                .buttonStyle(.bordered)
            Text("If Google does not recognize this device, try browser sign-in. Google may still require identity verification.")
                .font(.footnote)
            Text("Closing the browser checks the current approval. Cancel here stops sign-in.")
                .font(.footnote)
            Text("Check the account and workspace before approving. CodexBar does not read your browser cookies or passwords.")
                .font(.footnote)
        }
        .multilineTextAlignment(.center)
    }

    private var verificationContent: some View {
        VStack(spacing: 20) {
            Text(session.progress == .checkingApproval ? "Checking OpenCode approval" : "Verifying OpenCode account")
                .font(.headline)
            ProgressView()
            Text("Your account is not connected until verification and secure storage finish. Cancel here stops sign-in.")
                .multilineTextAlignment(.center)
            if session.isSynthetic {
                Text("Synthetic approval. No live account or credentials.").font(.footnote)
                if session.progress == .checkingApproval {
                    Button("Receive synthetic token") { session.receiveSyntheticToken() }
                    Button("Approval not available") { session.rejectSyntheticApproval() }
                } else {
                    Button("Finish synthetic verification") { session.completeSyntheticVerification() }
                }
            }
        }
    }

    @ViewBuilder
    private func approvalContent(mode: OpenCodeBrowserMode) -> some View {
        Text("Approve CodexBar in your browser").font(.headline)
        Text("Approve your OpenCode workspace. If the browser stays open, close it to check approval. Verification continues here.")
            .multilineTextAlignment(.center)
        if session.isSynthetic {
            Text(mode.prefersEphemeralSession ? "Synthetic private browser approval." : "Synthetic saved-session browser approval.")
                .font(.footnote)
            Text("No live account or credentials.").font(.footnote)
            if session.workspaceID == nil {
                Button("Choose Sample workspace") { session.selectSyntheticWorkspace() }
            } else {
                Text("Sample workspace")
                Button("Connect this workspace") { session.connectSyntheticWorkspace() }
            }
            Button("Back to browser choices") { session.retrySyntheticBrowser() }
        } else {
            ProgressView("Waiting for OpenCode approval...")
        }
    }
}
