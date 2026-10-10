import SwiftUI
import WebKit

@MainActor
final class SubscriptionBillingSignInSession: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate, WKHTTPCookieStoreObserver {
    let id = UUID()
    let webView: WKWebView
    let providerName: String
    let isSynthetic: Bool
    @Published private(set) var message: String?
    @Published private(set) var isVerifying = false
    @Published private(set) var host: String
    private let configuration: ProviderAccountConfiguration
    private let usageSecret: String
    private let client: SubscriptionBillingClient
    private var completion: ((Result<SubscriptionBillingSession, Error>) -> Void)?
    private var task: Task<Void, Never>?
    private var revision = UUID()
    private var started = false

    init(configuration: ProviderAccountConfiguration, usageSecret: String, client: SubscriptionBillingClient = SubscriptionBillingClient(),
         completion: @escaping (Result<SubscriptionBillingSession, Error>) -> Void) {
        self.configuration = configuration
        self.usageSecret = usageSecret
        #if DEBUG
        isSynthetic = UITestFixtures.current != nil
        self.client = isSynthetic ? SubscriptionBillingClient(session: UITestSubscriptionBillingProtocol.session()) : client
        #else
        isSynthetic = false
        self.client = client
        #endif
        self.completion = completion
        providerName = configuration.providerID == .claude ? "Claude" : "Grok"
        host = SubscriptionBillingSession.host(configuration.providerID) ?? ""
        let webConfiguration = WKWebViewConfiguration()
        webConfiguration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: webConfiguration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.configuration.websiteDataStore.httpCookieStore.add(self)
    }

    func start() {
        guard !started else { return }
        started = true
        if isSynthetic {
            webView.loadHTMLString("<html><body><p>Simulator billing fixture. No live account is accessed.</p></body></html>",
                                   baseURL: URL(string: "https://\(host)/")!)
            return
        }
        let path = configuration.providerID == .claude ? "/settings/billing" : "/"
        let providerHost = SubscriptionBillingSession.host(configuration.providerID)!
        webView.load(URLRequest(url: URL(string: "https://\(providerHost)\(path)")!))
    }

    func chooseSyntheticAccount(matching: Bool) {
        guard isSynthetic, completion != nil else { return }
        let cookie = HTTPCookie(properties: [
            .name: configuration.providerID == .claude ? "sessionKey" : "billing-fixture",
            .value: matching ? "matching" : "wrong",
            .domain: SubscriptionBillingSession.host(configuration.providerID)!, .path: "/", .secure: "TRUE",
        ])!
        webView.configuration.websiteDataStore.httpCookieStore.setCookie(cookie) { [weak self] in self?.verify() }
    }

    func invalidate() {
        completion = nil
        revision = UUID()
        task?.cancel()
        task = nil
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.configuration.websiteDataStore.httpCookieStore.remove(self)
    }

    func cancel() {
        let callback = completion
        invalidate()
        callback?(.failure(SubscriptionBillingError.canceled))
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        revision = UUID()
        task?.cancel()
        task = nil
        isVerifying = false
        host = webView.url?.host ?? host
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        host = webView.url?.host ?? host
        verify()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        message = "The sign-in page could not load. Try again when you have a connection."
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if (error as NSError).code != NSURLErrorCancelled { self.webView(webView, didFail: navigation, withError: error) }
    }

    func retrySignIn() {
        task?.cancel()
        task = nil
        revision = UUID()
        isVerifying = false
        message = nil
        started = false
        start()
    }

    func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        revision = UUID()
        task?.cancel()
        task = nil
        isVerifying = false
        verify()
    }

    func verify() {
        guard completion != nil, task == nil, !webView.isLoading,
              webView.url?.scheme == "https", webView.url?.host == SubscriptionBillingSession.host(configuration.providerID) else { return }
        let attempt = revision
        webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { [weak self] values in
            guard let self, self.completion != nil, self.task == nil, self.revision == attempt else { return }
            let cookies = SubscriptionBillingSession.capture(values, provider: self.configuration.providerID)
            guard !cookies.isEmpty else { return }
            self.isVerifying = true
            self.task = Task { [weak self] in
                guard let self else { return }
                do {
                    let billing = try await self.client.connect(configuration: self.configuration, usageSecret: self.usageSecret, cookies: cookies)
                    guard !Task.isCancelled, self.revision == attempt, self.completion != nil else { return }
                    let callback = self.completion
                    self.invalidate()
                    callback?(.success(billing))
                } catch {
                    guard !Task.isCancelled, self.revision == attempt, self.completion != nil else { return }
                    self.message = (error as? SubscriptionBillingError ?? .unavailable).localizedDescription
                    self.isVerifying = false
                    self.task = nil
                }
            }
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url, url.scheme == "https", url.user == nil, url.password == nil else { return .cancel }
        return .allow
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, navigationAction.request.url?.scheme == "https" { webView.load(navigationAction.request) }
        return nil
    }
}

struct SubscriptionBillingSignInView: View {
    @ObservedObject var session: SubscriptionBillingSignInSession

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Text("Sign in with the same \(session.providerName) account you connected for usage. CodexBar returns automatically after verifying billing.")
                    .font(.footnote)
                    .padding(.horizontal)
                Text(session.host).font(.caption).foregroundStyle(.secondary)
                if session.isSynthetic {
                    Button("Use another sample account") { session.chooseSyntheticAccount(matching: false) }
                        .accessibilityIdentifier("subscription-billing-synthetic-wrong")
                    Button("Use matching sample account") { session.chooseSyntheticAccount(matching: true) }
                        .accessibilityIdentifier("subscription-billing-synthetic-match")
                }
                if session.isVerifying { ProgressView("Verifying billing account…") }
                if let message = session.message {
                    Text(message).font(.footnote).foregroundStyle(.secondary).padding(.horizontal)
                    Button("Verify Billing Again") { session.verify() }
                        .accessibilityIdentifier("subscription-billing-verify")
                    Button("Reload Sign-In") { session.retrySignIn() }
                }
                BillingWebView(webView: session.webView)
            }
            .navigationTitle("\(session.providerName) billing")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { session.cancel() } }
            }
            .task { session.start() }
            .onDisappear { session.invalidate() }
        }
    }
}

private struct BillingWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
