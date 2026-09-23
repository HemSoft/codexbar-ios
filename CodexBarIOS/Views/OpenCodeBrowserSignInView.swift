import SwiftUI

@MainActor
final class OpenCodeBrowserSignInSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var workspaceID: String?
    @Published private(set) var isSynthetic = false
    @Published private(set) var browserMode: OpenCodeBrowserMode?
    private let presenter = PrivateWebAuthenticationPresenter()
    private var completion: ((Result<OpenCodeBrowserCredential, Error>) -> Void)?
    private var task: Task<Void, Never>?
    private var browserAttemptID: UUID?

    init(completion: @escaping (Result<OpenCodeBrowserCredential, Error>) -> Void) {
        self.completion = completion
    }

    func start(mode: OpenCodeBrowserMode) {
        guard browserAttemptID == nil, completion != nil else { return }
        let attemptID = UUID()
        browserAttemptID = attemptID
        browserMode = mode
        #if DEBUG
        if UITestFixtures.current != nil {
            isSynthetic = true
            return
        }
        #endif
        task = Task { [weak self] in await self?.authorizeInBrowser(mode: mode, attemptID: attemptID) }
    }

    private func authorizeInBrowser(mode: OpenCodeBrowserMode, attemptID: UUID) async {
        let service = OpenCodeDeviceAuthService()
        defer { service.session.invalidateAndCancel() }
        do {
            let authorization = try await service.begin()
            try Task.checkCancellation()
            guard browserAttemptID == attemptID else { return }
            guard presenter.present(
                url: authorization.verificationURL,
                prefersEphemeralSession: mode.prefersEphemeralSession,
                onCancel: { [weak self] in self?.browserDidClose(attemptID: attemptID) }
            ) else { throw OpenCodeSignInError.browserFailed }
            let credential = try await service.authorize(authorization)
            try Task.checkCancellation()
            guard browserAttemptID == attemptID else { return }
            finish(.success(OpenCodeBrowserCredential(
                workspaceID: credential.workspaceID, session: try credential.encoded()
            )))
        } catch {
            guard browserAttemptID == attemptID, !Task.isCancelled else { return }
            finish(.failure(error as? OpenCodeSignInError ?? .browserFailed))
        }
    }

    private func browserDidClose(attemptID: UUID) {
        guard browserAttemptID == attemptID else { return }
        stopBrowserAttempt()
    }

    private func stopBrowserAttempt() {
        browserAttemptID = nil
        task?.cancel()
        task = nil
        presenter.finish()
        browserMode = nil
        workspaceID = nil
    }

    func cancel() { finish(.failure(OpenCodeSignInError.canceled)) }

    func invalidate() {
        completion = nil
        stopBrowserAttempt()
    }

    private func finish(_ result: Result<OpenCodeBrowserCredential, Error>) {
        let callback = completion
        invalidate()
        callback?(result)
    }

    func selectSyntheticWorkspace() {
        #if DEBUG
        guard isSynthetic, UITestFixtures.current != nil else { return }
        workspaceID = "wrk_fixture"
        #endif
    }

    func retrySyntheticBrowser() {
        #if DEBUG
        guard isSynthetic, UITestFixtures.current != nil, let browserAttemptID else { return }
        browserDidClose(attemptID: browserAttemptID)
        #endif
    }

    func connectSyntheticWorkspace() {
        #if DEBUG
        guard isSynthetic, UITestFixtures.current != nil, let workspaceID else { return }
        finish(.success(OpenCodeBrowserCredential(workspaceID: workspaceID, session: "ui-test-credential")))
        #endif
    }
}

struct OpenCodeBrowserSignInView: View {
    @ObservedObject var session: OpenCodeBrowserSignInSession

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "safari").font(.largeTitle)
                    if let mode = session.browserMode {
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
            Text("Browser sign-in can use accounts already signed in on this device. Private sign-in starts a separate session.")
            Button("Use browser sign-in") { session.start(mode: .existingSession) }
                .buttonStyle(.borderedProminent)
            Button("Use private sign-in") { session.start(mode: .privateSession) }
                .buttonStyle(.bordered)
            Text("If Google does not recognize this device, try browser sign-in. Google may still require identity verification.")
                .font(.footnote)
            Text("Check the account and workspace before approving. CodexBar does not read your browser cookies or passwords.")
                .font(.footnote)
        }
        .multilineTextAlignment(.center)
    }

    @ViewBuilder
    private func approvalContent(mode: OpenCodeBrowserMode) -> some View {
        Text("Approve CodexBar in your browser").font(.headline)
        Text("Sign in with OpenCode and choose your workspace. You will return here automatically after approval.")
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
