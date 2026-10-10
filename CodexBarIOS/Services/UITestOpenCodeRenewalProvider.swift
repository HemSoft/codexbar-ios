#if DEBUG
import Foundation

/// Offline simulator replay reaches the production Console client, parser and card.
struct UITestOpenCodeRenewalProvider: UsageProvider {
    let providerID = ProviderID.openCodeZen
    let secretStore: SecretStore

    @MainActor
    static func seed(in store: ProviderConfigurationStore, scenario: String?) {
        guard scenario?.hasPrefix("opencode-renewal-") == true, store.configurations.isEmpty else { return }
        var account = ProviderAccountConfiguration(id: "ui-opencode-renewal", providerID: .openCodeZen,
                                                   accountLabel: "OpenCode Go + Zen", authMethod: .browserSession)
        account.openCodeWorkspaceId = "org_synthetic"
        let credential = OpenCodeConsoleCredential(kind: "opencode-console-v1", accessToken: "synthetic-access",
                                                  refreshToken: "synthetic-refresh", expiresAt: Date().addingTimeInterval(3600),
                                                  workspaceID: "org_synthetic", userID: "user_synthetic")
        precondition(store.update(account))
        guard let encoded = try? credential.encoded() else { preconditionFailure("Cannot encode synthetic credential") }
        precondition(store.saveSecret(encoded, for: account))
    }

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        let key = ProviderConfigurationStore.keychainAccount(for: configuration)
        guard let credential = OpenCodeConsoleCredential.parse(try secretStore.readSecret(account: key)) else {
            throw OpenCodeSignInError.validationFailed
        }
        return await OpenCodeConsoleUsageProvider(secretStore: secretStore, makeSession: {
            OpenCodeDeviceAuthService.makeSession(protocolClasses: [UITestOpenCodeRenewalProtocol.self])
        }).fetchUsage(credential: credential, configuration: configuration)
    }
}

private final class UITestOpenCodeRenewalProtocol: URLProtocol, @unchecked Sendable {
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        guard let url = request.url, url.host == "opencode.ai", request.httpMethod == "GET",
              request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access" else { return fail() }
        let scenario = ProcessInfo.processInfo.environment["CODEXBAR_UI_TEST_SCENARIO"] ?? ""
        let format = ISO8601DateFormatter()
        let start = format.string(from: Date().addingTimeInterval(-86_400))
        let end = format.string(from: Date().addingTimeInterval(259_200))
        let canceled = scenario.hasSuffix("canceled")
        let payment = scenario.hasSuffix("payment")
        let body: String
        switch url.path {
        case "/console/auth/session":
            body = "{\"user\":{\"id\":\"user_synthetic\"},\"org_id\":\"org_synthetic\"}"
        case "/console/api/billing/status":
            if scenario.hasSuffix("balance-failure") { return fail() }
            body = "{\"balanceMicroCents\":\"2500000000\"}"
        case "/console/api/go/status":
            guard request.value(forHTTPHeaderField: "x-org-id") == "org_synthetic" else { return fail() }
            body = """
            {"subscriberUserId":"\(scenario.hasSuffix("mismatch") ? "other-member" : "user_synthetic")",
             "product":"go-plus","renewalProduct":"go","cancelAtPeriodEnd":\(canceled),
             "resumability":"\(payment ? "needs-payment-method" : "renewing")","renewalPending":\(payment),
             "access":{"startsAt":"\(start)","endsAt":"\(end)","cancelAtPeriodEnd":\(canceled),"meters":{
              "fiveHour":{"usedMicroCents":"25","limitMicroCents":"100","startsAt":"\(start)","resetsAt":"\(end)"},
              "week":{"usedMicroCents":"50","limitMicroCents":"100","resetsAt":"\(end)"},
              "month":{"usedMicroCents":"75","limitMicroCents":"100"}}}}
            """
        default: return fail()
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private func fail() { client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)) }
}
#endif
