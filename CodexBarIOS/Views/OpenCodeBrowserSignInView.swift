import SwiftUI

@MainActor
final class OpenCodeBrowserSignInSession: ObservableObject, Identifiable {
    let id = UUID()
    @Published private(set) var workspaceID: String?
    @Published private(set) var isSynthetic = false
    private let presenter = PrivateWebAuthenticationPresenter()
    private var completion: ((Result<OpenCodeBrowserCredential, Error>) -> Void)?
    private var task: Task<Void, Never>?
    private var didStart = false

    init(completion: @escaping (Result<OpenCodeBrowserCredential, Error>) -> Void) {
        self.completion = completion
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        #if DEBUG
        if UITestFixtures.current != nil {
            isSynthetic = true
            return
        }
        #endif
        task = Task { [weak self] in await self?.authorizeInBrowser() }
    }

    private func authorizeInBrowser() async {
        let service = OpenCodeDeviceAuthService()
        defer { service.session.invalidateAndCancel() }
        do {
            let authorization = try await service.begin()
            try Task.checkCancellation()
            guard presenter.present(url: authorization.verificationURL, onCancel: { [weak self] in
                self?.cancel()
            }) else { throw OpenCodeSignInError.browserFailed }
            let credential = try await service.authorize(authorization)
            try Task.checkCancellation()
            finish(.success(OpenCodeBrowserCredential(
                workspaceID: credential.workspaceID, session: try credential.encoded()
            )))
        } catch {
            guard !Task.isCancelled else { return }
            finish(.failure(error as? OpenCodeSignInError ?? .browserFailed))
        }
    }

    func cancel() { finish(.failure(OpenCodeSignInError.canceled)) }

    func invalidate() {
        completion = nil
        task?.cancel()
        task = nil
        presenter.finish()
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
            VStack(spacing: 20) {
                Image(systemName: "safari").font(.largeTitle)
                Text("Approve CodexBar in your browser").font(.headline)
                Text("Sign in with OpenCode and choose your workspace. You will return here automatically after approval.")
                    .multilineTextAlignment(.center)
                if session.isSynthetic {
                    Text("Synthetic browser approval. No live account or credentials.").font(.footnote)
                    if session.workspaceID == nil {
                        Button("Choose Sample workspace") { session.selectSyntheticWorkspace() }
                    } else {
                        Text("Sample workspace")
                        Button("Connect this workspace") { session.connectSyntheticWorkspace() }
                    }
                } else {
                    ProgressView("Waiting for OpenCode approval...")
                }
            }
            .padding()
            .navigationTitle("OpenCode sign-in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { session.cancel() }
                }
            }
        }
        .interactiveDismissDisabled()
        .task { session.start() }
    }
}
