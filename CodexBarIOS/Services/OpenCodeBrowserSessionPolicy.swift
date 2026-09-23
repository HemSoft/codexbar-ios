import Foundation

enum OpenCodeSignInError: LocalizedError {
    case canceled
    case expired
    case approvalNotReady
    case browserFailed
    case validationFailed

    var errorDescription: String? {
        switch self {
        case .canceled:
            "OpenCode sign-in canceled. Your saved account was not changed."
        case .expired:
            "OpenCode approval expired. Start sign-in again. Your saved account was not changed."
        case .approvalNotReady:
            "OpenCode approval is not available. Try signing in again. Your saved account was not changed."
        case .browserFailed:
            "OpenCode sign-in could not load. Check your connection and try again."
        case .validationFailed:
            "OpenCode usage could not be verified. Check your workspace and try again. Your saved account was not changed."
        }
    }
}

enum OpenCodeBrowserMode: Sendable {
    case existingSession
    case privateSession

    var prefersEphemeralSession: Bool { self == .privateSession }
}

struct OpenCodeBrowserCredential {
    let workspaceID: String
    let session: String
}

protocol OpenCodeSessionValidating: Sendable {
    func validate(credential: String, configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult
}

struct OpenCodeSessionValidator: OpenCodeSessionValidating {
    static func canReconnect(
        workspaceID: String,
        configuredWorkspace: String,
        credential: String? = nil,
        savedCredential: String? = nil
    ) -> Bool {
        let matchesWorkspace = OpenCodeZenUsageProvider.normalizedWorkspaceId(from: configuredWorkspace)
            .map { $0 == workspaceID } ?? true
        guard matchesWorkspace else { return false }
        guard let saved = OpenCodeConsoleCredential.parse(savedCredential) else { return true }
        guard let candidate = OpenCodeConsoleCredential.parse(credential) else { return false }
        return saved.userID == candidate.userID
            && saved.workspaceID == candidate.workspaceID
            && candidate.workspaceID == workspaceID
    }

    static func hasVerifiedUsage(_ result: ProviderUsageResult) -> Bool {
        (!result.bars.isEmpty && result.hasCurrentBars)
            || (result.creditsRemaining != nil && result.hasCurrentCredits)
    }

    func validate(credential: String, configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        guard let candidate = OpenCodeConsoleCredential.parse(credential),
              candidate.workspaceID == configuration.openCodeWorkspaceId else { throw OpenCodeSignInError.validationFailed }
        let store = OpenCodeValidationSecretStore(
            credential: credential,
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        return await OpenCodeConsoleUsageProvider(secretStore: store).fetchUsage(credential: candidate, configuration: configuration)
    }
}

private struct OpenCodeValidationSecretStore: SecretStore {
    let credential: String
    let account: String

    func readSecret(account: String) throws -> String? {
        account == self.account ? credential : nil
    }

    func saveSecret(_ secret: String, account: String) throws {
        throw OpenCodeSignInError.validationFailed
    }

    func deleteSecret(account: String) throws {
        throw OpenCodeSignInError.validationFailed
    }
}

#if canImport(UIKit)
import Combine

@MainActor
protocol OpenCodeBrowserPresenting: AnyObject {
    func present(url: URL, prefersEphemeralSession: Bool, onCancel: @escaping () -> Void) -> Bool
    func finish()
}

extension PrivateWebAuthenticationPresenter: OpenCodeBrowserPresenting {}

enum OpenCodeBrowserProgress {
    case waitingForApproval
    case checkingApproval
    case verifyingAccount
}

struct OpenCodeBrowserCallbacks: Sendable {
    var shouldContinuePolling: @Sendable () async -> Bool
    var tokenReceived: @Sendable () async -> Void
}

struct OpenCodeBrowserClient: Sendable {
    var begin: @Sendable () async throws -> OpenCodeDeviceAuthorization
    var authorize: @Sendable (OpenCodeDeviceAuthorization, OpenCodeBrowserCallbacks) async throws -> OpenCodeConsoleCredential
    var invalidate: @Sendable () -> Void

    static func live() -> Self {
        let service = OpenCodeDeviceAuthService()
        return Self(
            begin: { try await service.begin() },
            authorize: { authorization, callbacks in
                try await service.authorize(
                    authorization, shouldContinuePolling: callbacks.shouldContinuePolling,
                    onTokenReceived: callbacks.tokenReceived
                )
            },
            invalidate: { service.session.invalidateAndCancel() }
        )
    }
}

@MainActor
final class OpenCodeBrowserSignInSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var workspaceID: String?
    @Published private(set) var isSynthetic = false
    @Published private(set) var browserMode: OpenCodeBrowserMode?
    @Published private(set) var progress = OpenCodeBrowserProgress.waitingForApproval
    @Published private(set) var retryMessage: String?
    private let presenter: any OpenCodeBrowserPresenting
    private let makeClient: @Sendable () -> OpenCodeBrowserClient
    private let approvalCheckTimeout: Duration
    private var browserCloseTask: Task<Void, Never>?
    private var completion: ((Result<OpenCodeBrowserCredential, Error>) -> Void)?
    private var task: Task<Void, Never>?
    private var browserAttemptID: UUID?

    init(
        isSynthetic: Bool = false,
        presenter: any OpenCodeBrowserPresenting = PrivateWebAuthenticationPresenter(),
        makeClient: @escaping @Sendable () -> OpenCodeBrowserClient = OpenCodeBrowserClient.live,
        approvalCheckTimeout: Duration = .seconds(30),
        completion: @escaping (Result<OpenCodeBrowserCredential, Error>) -> Void
    ) {
        self.presenter = presenter
        self.makeClient = makeClient
        self.approvalCheckTimeout = approvalCheckTimeout
        self.completion = completion
        #if DEBUG
        self.isSynthetic = isSynthetic
        #endif
    }

    func start(mode: OpenCodeBrowserMode) {
        guard browserAttemptID == nil, completion != nil else { return }
        let attemptID = UUID()
        browserAttemptID = attemptID
        browserMode = mode
        retryMessage = nil
        if isSynthetic { return }
        task = Task { [weak self] in await self?.authorizeInBrowser(mode: mode, attemptID: attemptID) }
    }

    private func authorizeInBrowser(mode: OpenCodeBrowserMode, attemptID: UUID) async {
        let client = makeClient()
        defer { client.invalidate() }
        do {
            let authorization = try await client.begin()
            try Task.checkCancellation()
            guard browserAttemptID == attemptID else { return }
            guard presenter.present(
                url: authorization.verificationURL,
                prefersEphemeralSession: mode.prefersEphemeralSession,
                onCancel: { [weak self] in self?.browserDidClose(attemptID: attemptID) }
            ) else { throw OpenCodeSignInError.browserFailed }
            let credential = try await client.authorize(authorization, callbacks(attemptID: attemptID))
            try Task.checkCancellation()
            guard browserAttemptID == attemptID else { return }
            finish(.success(OpenCodeBrowserCredential(
                workspaceID: credential.workspaceID, session: try credential.encoded()
            )))
        } catch {
            authorizationFailed(error, attemptID: attemptID)
        }
    }

    private func callbacks(attemptID: UUID) -> OpenCodeBrowserCallbacks {
        OpenCodeBrowserCallbacks(
            shouldContinuePolling: { [weak self] in await self?.mayContinuePolling(attemptID: attemptID) ?? false },
            tokenReceived: { [weak self] in await self?.receivedToken(attemptID: attemptID) }
        )
    }

    private func mayContinuePolling(attemptID: UUID) -> Bool {
        browserAttemptID == attemptID && progress == .waitingForApproval
    }

    private func receivedToken(attemptID: UUID) {
        guard browserAttemptID == attemptID else { return }
        browserCloseTask?.cancel()
        browserCloseTask = nil
        progress = .verifyingAccount
        presenter.finish()
    }

    private func authorizationFailed(_ error: Error, attemptID: UUID) {
        guard browserAttemptID == attemptID, !Task.isCancelled else { return }
        let failure = error as? OpenCodeSignInError ?? .browserFailed
        if progress == .checkingApproval {
            stopBrowserAttempt()
            retryMessage = failure.localizedDescription
        } else {
            finish(.failure(failure))
        }
    }

    private func browserDidClose(attemptID: UUID) {
        guard browserAttemptID == attemptID, progress == .waitingForApproval else { return }
        if isSynthetic { stopBrowserAttempt(); return }
        // Keep the existing exchange so an issued, single-use grant is not
        // lost. An older pending reply still allows one post-close poll.
        progress = .checkingApproval
        let timeout = approvalCheckTimeout
        browserCloseTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.approvalCheckTimedOut(attemptID: attemptID)
        }
    }

    private func approvalCheckTimedOut(attemptID: UUID) {
        guard browserAttemptID == attemptID, progress == .checkingApproval else { return }
        stopBrowserAttempt()
        retryMessage = OpenCodeSignInError.approvalNotReady.localizedDescription
    }

    private func stopBrowserAttempt() {
        browserAttemptID = nil
        task?.cancel()
        task = nil
        browserCloseTask?.cancel()
        browserCloseTask = nil
        presenter.finish()
        progress = .waitingForApproval
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
        guard isSynthetic else { return }
        workspaceID = "wrk_fixture"
        #endif
    }

    func retrySyntheticBrowser() {
        #if DEBUG
        guard isSynthetic, let browserAttemptID else { return }
        browserDidClose(attemptID: browserAttemptID)
        #endif
    }

    func connectSyntheticWorkspace() {
        #if DEBUG
        guard isSynthetic, workspaceID != nil else { return }
        progress = .checkingApproval
        #endif
    }

    func rejectSyntheticApproval() {
        #if DEBUG
        guard isSynthetic, let browserAttemptID else { return }
        authorizationFailed(OpenCodeSignInError.approvalNotReady, attemptID: browserAttemptID)
        #endif
    }

    func receiveSyntheticToken() {
        #if DEBUG
        guard isSynthetic, let browserAttemptID else { return }
        receivedToken(attemptID: browserAttemptID)
        #endif
    }

    func completeSyntheticVerification() {
        #if DEBUG
        guard isSynthetic, let workspaceID, progress == .verifyingAccount else { return }
        finish(.success(OpenCodeBrowserCredential(workspaceID: workspaceID, session: "ui-test-credential")))
        #endif
    }
}
#endif
