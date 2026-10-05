import SwiftUI
import WebKit

@MainActor
final class GreptileBrowserSignInSession: NSObject, ObservableObject, Identifiable,
    WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    let id = UUID()
    let webView: WKWebView
    @Published private(set) var host = "app.greptile.com"
    @Published private(set) var organizations: [GreptileOrganization] = []
    @Published private(set) var message: String?
    @Published private(set) var isVerifying = false
    private let client = GreptileDashboardClient(session: GreptileDashboardClient.isolatedSession())
    private var identity: GreptileDashboardIdentity?
    private var cookies: [GreptileSessionCookie] = []
    private var completion: ((Result<GreptileSessionCredentials, Error>) -> Void)?
    private var task: Task<Void, Never>?
    private var didStart = false
    private var navigationRevision = UUID()
    private var cookieInspectionPending = false
    @Published private(set) var canGoBack = false

    init(completion: @escaping (Result<GreptileSessionCredentials, Error>) -> Void) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.completion = completion
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        configuration.websiteDataStore.httpCookieStore.add(self)
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        openUsage()
    }

    func openUsage() {
        resetInspection()
        message = nil
        webView.load(URLRequest(url: URL(string: "https://app.greptile.com/-/settings/usage")!))
    }

    private func resetInspection() {
        navigationRevision = UUID()
        cookieInspectionPending = false
        message = nil
        task?.cancel()
        task = nil
        isVerifying = false
        organizations = []
        identity = nil
        cookies = []
    }

    func goBack() {
        guard webView.canGoBack, !isVerifying else { return }
        resetInspection()
        webView.goBack()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        resetInspection()
        canGoBack = webView.canGoBack
    }

    func cancel() { finish(.failure(GreptileSignInError.canceled)) }

    func invalidate() {
        completion = nil
        task?.cancel()
        task = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
        client.session.invalidateAndCancel()
        cookies = []
        identity = nil
    }

    private func finish(_ result: Result<GreptileSessionCredentials, Error>) {
        let callback = completion
        invalidate()
        callback?(result)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        canGoBack = webView.canGoBack
        host = webView.url?.host ?? "app.greptile.com"
        inspectSession()
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        if task != nil { cookieInspectionPending = true; return }
        organizations = []
        identity = nil
        inspectSession()
    }

    private func finishVerification(revision: UUID) {
        guard navigationRevision == revision else { return }
        task = nil
        isVerifying = false
        guard cookieInspectionPending else { return }
        cookieInspectionPending = false
        organizations = []
        identity = nil
        inspectSession()
    }

    private func inspectSession() {
        guard completion != nil, task == nil, organizations.isEmpty, !webView.isLoading,
              webView.url?.scheme == "https", webView.url?.host == "app.greptile.com" else { return }
        let revision = navigationRevision
        let url = webView.url
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] values in
            guard let self, self.completion != nil, self.task == nil, self.navigationRevision == revision,
                  self.webView.url == url, !self.webView.isLoading else { return }
            guard let cookies = try? GreptileSessionCredentials.sessionCookies(from: values), !cookies.isEmpty else { return }
            self.inspect(cookies: cookies, revision: revision)
        }
    }

    private func inspect(cookies: [GreptileSessionCookie], revision: UUID) {
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishVerification(revision: revision) }
            self.isVerifying = true
            do {
                let identity = try await self.client.identity(cookies: cookies)
                guard !Task.isCancelled, self.completion != nil, self.navigationRevision == revision else { return }
                guard !identity.organizations.isEmpty else {
                    self.message = "Greptile returned no organizations. Finish account setup, then return to Usage."
                    return
                }
                self.cookies = cookies
                self.identity = identity
                self.organizations = identity.organizations
            } catch {
                guard !Task.isCancelled, self.completion != nil, self.navigationRevision == revision else { return }
                self.message = "Finish signing in, then choose Greptile Usage to retry verification."
            }
        }
    }

    func connect(_ organization: GreptileOrganization) {
        guard completion != nil, task == nil, let identity,
              identity.organizations.contains(organization) else { return }
        let credential = GreptileSessionCredentials(
            version: 1, subject: identity.greptileId, organization: organization, cookies: cookies
        )
        isVerifying = true
        let revision = navigationRevision
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.finishVerification(revision: revision) }
            do {
                _ = try await self.client.verifiedIdentity(for: credential)
                _ = try await self.client.billingState(for: credential)
                guard !Task.isCancelled, self.completion != nil else { return }
                self.finish(.success(credential))
            } catch {
                guard !Task.isCancelled, self.completion != nil else { return }
                self.message = (error as? GreptileSignInError ?? .unavailable).localizedDescription
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else {
            explainBlockedNavigation(action)
            return .cancel
        }
        return .allow
    }

    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil else { return nil }
        if let url = navigationAction.request.url, url.scheme == "https", url.user == nil, url.password == nil,
           url.port == nil || url.port == 443 {
            webView.load(navigationAction.request)
        } else {
            explainBlockedNavigation(navigationAction)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { navigationFailed(error) }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        message = "The sign-in page closed. Choose Greptile Usage to try again."
    }

    private func explainBlockedNavigation(_ action: WKNavigationAction) {
        guard action.targetFrame?.isMainFrame != false, action.request.url?.absoluteString != "about:blank" else { return }
        message = "This sign-in link could not be opened securely. Choose Greptile Usage to continue."
    }

    private func navigationFailed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        message = "Greptile sign-in could not load. Check the connection and try again."
    }
}

struct GreptileBrowserSignInView: View {
    @ObservedObject var session: GreptileBrowserSignInSession

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("Sign in on Greptile's website, then choose your organization. CodexBar verifies access and returns automatically.")
                    .font(.footnote).padding(.horizontal)
                if let message = session.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                }
                if session.isVerifying { ProgressView("Verifying Greptile access…") }
                if session.organizations.isEmpty {
                    GreptileSignInWebView(session: session)
                } else {
                    List(session.organizations) { organization in
                        Button("Connect \(organization.name)") { session.connect(organization) }
                            .disabled(session.isVerifying)
                    }
                    Text("Your verified organization session is saved securely for this account.")
                        .font(.footnote).padding()
                }
            }
            .navigationTitle(session.organizations.isEmpty ? session.host : "Choose Organization")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { session.cancel() } }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Back", systemImage: "chevron.left") { session.goBack() }
                        .disabled(!session.canGoBack || session.isVerifying)
                    Spacer()
                    Button("Greptile Usage") { session.openUsage() }.disabled(session.isVerifying)
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

private struct GreptileSignInWebView: UIViewRepresentable {
    let session: GreptileBrowserSignInSession
    func makeUIView(context: Context) -> WKWebView { session.start(); return session.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
