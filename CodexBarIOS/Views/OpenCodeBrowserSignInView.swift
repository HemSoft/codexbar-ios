import SwiftUI
import WebKit

@MainActor
final class OpenCodeBrowserSignInSession: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    let webView: WKWebView
    @Published private(set) var host = "opencode.ai"
    @Published private(set) var workspaceID: String?
    @Published private(set) var message: String?
    @Published private(set) var isConnecting = false
    private var completion: ((Result<OpenCodeBrowserCredential, Error>) -> Void)?
    private var didStart = false
    private var navigationRevision = 0

    init(completion: @escaping (Result<OpenCodeBrowserCredential, Error>) -> Void) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration)
        self.completion = completion
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        #if DEBUG
        if let fixtures = UITestFixtures.current {
            fixtures.loadOpenCodePage(into: webView, url: OpenCodeBrowserSessionPolicy.signInURL)
            return
        }
        #endif
        webView.load(URLRequest(url: OpenCodeBrowserSessionPolicy.signInURL))
    }

    func cancel() { finish(.failure(OpenCodeSignInError.canceled)) }

    func invalidate() {
        completion = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    private func finish(_ result: Result<OpenCodeBrowserCredential, Error>) {
        let callback = completion
        invalidate()
        callback?(result)
    }

    func connect() {
        guard let workspaceID, !isConnecting else { return }
        isConnecting = true
        let revision = navigationRevision
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            self.isConnecting = false
            guard self.completion != nil, self.navigationRevision == revision else { return }
            self.readCredential(cookies, workspaceID: workspaceID)
        }
    }

    private func readCredential(_ cookies: [HTTPCookie], workspaceID: String) {
        guard OpenCodeBrowserSessionPolicy.workspaceID(from: webView.url) == workspaceID else { return }
        do {
            guard let credential = try OpenCodeBrowserSessionPolicy.credential(from: cookies) else {
                message = "Finish signing in on OpenCode, then choose Connect this workspace."
                return
            }
            finish(.success(OpenCodeBrowserCredential(workspaceID: workspaceID, session: credential)))
        } catch {
            message = OpenCodeSignInError.ambiguousSession.localizedDescription
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationRevision += 1
        workspaceID = nil
        message = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        host = webView.url?.host ?? "opencode.ai"
        workspaceID = OpenCodeBrowserSessionPolicy.workspaceID(from: webView.url)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard OpenCodeBrowserSessionPolicy.allowsNavigation(to: navigationAction.request.url) else {
            message = "This window only opens OpenCode and its GitHub or Google sign-in pages. Cancel to return safely."
            return .cancel
        }
        #if DEBUG
        if let fixtures = UITestFixtures.current, navigationAction.navigationType == .linkActivated,
           let url = navigationAction.request.url {
            fixtures.loadOpenCodePage(into: webView, url: url)
            return .cancel
        }
        #endif
        return .allow
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        guard navigationAction.targetFrame == nil,
              OpenCodeBrowserSessionPolicy.allowsNavigation(to: navigationAction.request.url) else { return nil }
        webView.load(navigationAction.request)
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationFailed(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(OpenCodeSignInError.browserFailed))
    }

    private func navigationFailed(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        // Provider URLs and WebKit errors can contain authorization codes. Do not display them.
        finish(.failure(OpenCodeSignInError.browserFailed))
    }
}

struct OpenCodeBrowserSignInView: View {
    @ObservedObject var session: OpenCodeBrowserSignInSession

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Sign in on OpenCode's website and choose your workspace. Connect it to return to CodexBar automatically.")
                    .font(.footnote).padding()
                if let message = session.message {
                    Text(message).font(.footnote).foregroundStyle(.red).padding(.horizontal)
                }
                OpenCodeBrowserWebView(session: session)
            }
            .navigationTitle(session.host)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { session.cancel() }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Connect this workspace") { session.connect() }
                        .disabled(session.workspaceID == nil || session.isConnecting)
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

private struct OpenCodeBrowserWebView: UIViewRepresentable {
    let session: OpenCodeBrowserSignInSession

    func makeUIView(context: Context) -> WKWebView {
        session.start()
        return session.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
