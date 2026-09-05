import SwiftUI
import WebKit

@MainActor
final class GeminiBrowserSignInSession: NSObject, ObservableObject, Identifiable,
    WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    let id = UUID()
    let webView: WKWebView
    @Published private(set) var host = "gemini.google.com"
    @Published private(set) var canGoBack = false
    @Published private(set) var message: String?
    private var completion: ((Result<String, Error>) -> Void)?
    private var isReadingCookies = false
    private var didStart = false
    private var didReturnToUsage = false
    private var navigationRevision = 0

    init(completion: @escaping (Result<String, Error>) -> Void) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        self.webView = WKWebView(frame: .zero, configuration: configuration)
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
        message = nil
        webView.load(URLRequest(url: GeminiBrowserSessionPolicy.usageURL))
    }

    func cancel() {
        finish(.failure(GeminiSignInError.canceled))
    }

    func invalidate() {
        completion = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
    }

    func finish(_ result: Result<String, Error>) {
        let callback = completion
        invalidate()
        callback?(result)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationRevision += 1
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        host = webView.url?.host ?? "google.com"
        canGoBack = webView.canGoBack
        inspectSession()
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        inspectSession()
    }

    private func inspectSession() {
        guard completion != nil, !isReadingCookies, !webView.isLoading,
              GeminiBrowserSessionPolicy.canReturnToUsage(from: webView.url) else { return }
        isReadingCookies = true
        let revision = navigationRevision
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] cookies in
            guard let self else { return }
            self.isReadingCookies = false
            guard self.completion != nil, !self.webView.isLoading, self.navigationRevision == revision,
                  GeminiBrowserSessionPolicy.canReturnToUsage(from: self.webView.url) else { return }
            do {
                guard let credential = try GeminiBrowserSessionPolicy.storedCredential(from: cookies) else { return }
                if GeminiBrowserSessionPolicy.isUsagePage(self.webView.url) {
                    self.finish(.success(credential))
                } else if !self.didReturnToUsage {
                    self.didReturnToUsage = true
                    self.openUsage()
                } else {
                    self.finish(.failure(GeminiSignInError.validationFailed))
                }
            } catch {
                self.finish(.failure(GeminiSignInError.ambiguousSession))
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard GeminiBrowserSessionPolicy.allowsNavigation(to: navigationAction.request.url) else {
            message = "This sign-in window only opens secure Google pages. Return to Gemini Usage or cancel to retry."
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil,
           GeminiBrowserSessionPolicy.allowsNavigation(to: navigationAction.request.url) {
            webView.load(navigationAction.request)
        }
        return nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        handleNavigationFailure(error)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finish(.failure(GeminiSignInError.browserFailed))
    }

    private func handleNavigationFailure(_ error: Error) {
        guard (error as NSError).code != NSURLErrorCancelled else { return }
        // Never expose WebKit's error text or failing URL; either may contain credentials.
        finish(.failure(GeminiSignInError.browserFailed))
    }
}

struct GeminiBrowserSignInView: View {
    @ObservedObject var session: GeminiBrowserSignInSession

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Sign in on Google's website. CodexBar returns automatically after verifying your Gemini session.")
                    .font(.footnote)
                    .padding()
                if let message = session.message {
                    Text(message).font(.footnote).foregroundStyle(.red).padding(.horizontal)
                }
                GeminiBrowserWebView(session: session)
            }
            .navigationTitle(session.host)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { session.cancel() }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Back", systemImage: "chevron.left") { session.webView.goBack() }
                        .disabled(!session.canGoBack)
                    Spacer()
                    Button("Gemini Usage") { session.openUsage() }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}

private struct GeminiBrowserWebView: UIViewRepresentable {
    let session: GeminiBrowserSignInSession

    func makeUIView(context: Context) -> WKWebView {
        session.start()
        return session.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
