import XCTest
@testable import CodexBarIOS

final class CodexBarIOSTests: XCTestCase {
    func testUsageSeverityThresholds() {
        XCTAssertEqual(UsageSeverity(fractionUsed: 0.74), .normal)
        XCTAssertEqual(UsageSeverity(fractionUsed: 0.75), .warning)
        XCTAssertEqual(UsageSeverity(fractionUsed: 0.90), .critical)
    }

    func testProviderConfigurationDefaults() {
        XCTAssertEqual(
            ProviderAccountConfiguration.defaultConfiguration(for: .openRouter).authMethod,
            .apiKey
        )
        XCTAssertEqual(
            ProviderAccountConfiguration.defaultConfiguration(for: .copilot).authMethod,
            .cliToken
        )
        XCTAssertEqual(
            ProviderAccountConfiguration.defaultConfiguration(for: .codex).authMethod,
            .browserSession
        )
    }

    @MainActor
    func testAppAppearanceDefaultsToSystemAndPersists() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(store.appAppearance, .system)

        store.updateAppAppearance(.dark)

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(reloadedStore.appAppearance, .dark)
    }

    func testCodexAuthURLUsesBrowserLoginFlow() throws {
        let url = CodexWebAuthService.authorizationURL(
            redirectURI: "http://localhost:1455/auth/callback",
            state: "state",
            codeChallenge: "challenge"
        )

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "auth.openai.com")
        XCTAssertEqual(components.path, "/oauth/authorize")
        XCTAssertEqual(components.queryItemValue(named: "response_type"), "code")
        XCTAssertEqual(components.queryItemValue(named: "redirect_uri"), "http://localhost:1455/auth/callback")
        XCTAssertEqual(components.queryItemValue(named: "code_challenge_method"), "S256")
        XCTAssertEqual(components.queryItemValue(named: "originator"), "codex_cli_rs")
        XCTAssertEqual(components.queryItemValue(named: "codex_cli_simplified_flow"), "true")
    }

    func testCodexTokenRequestBodyUsesPKCECodeExchange() {
        let body = String(
            data: CodexWebAuthService.makeTokenRequestBody(
                code: "code value",
                redirectURI: "http://localhost:1455/auth/callback",
                codeVerifier: "verifier value"
            ),
            encoding: .utf8
        )

        XCTAssertEqual(
            body,
            "grant_type=authorization_code&code=code%20value&redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback&client_id=app_EMoamEEZ73f0CkXaXp7hrann&code_verifier=verifier%20value"
        )
    }

    func testCodexAuthExtractsChatGPTAccountID() {
        let header = #"{"alg":"none"}"#.base64URLEncodedForTest()
        let payload = #"{"chatgpt_account_id":"account-id"}"#.base64URLEncodedForTest()
        let token = "\(header).\(payload).signature"

        XCTAssertEqual(CodexWebAuthService.accountID(from: token), "account-id")
    }

    func testCodexCredentialsParserReadsCliAuthJson() {
        let credentials = CodexCredentialsParser.parse("""
        {
          "tokens": {
            "access_token": "access-token",
            "account_id": "account-id"
          }
        }
        """)

        XCTAssertEqual(credentials, CodexCredentials(accessToken: "access-token", accountID: "account-id"))
    }

    func testCodexUsageParserReadsUsageWindows() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let payload = """
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": {
              "used_percent": 42,
              "reset_at": 1893456000,
              "limit_window_seconds": 18000
            },
            "secondary_window": {
              "used_percent": 81,
              "reset_at": 1894060800,
              "limit_window_seconds": 604800
            }
          }
        }
        """

        let result = try XCTUnwrap(CodexUsageParser.parse(Data(payload.utf8), fetchedAt: fetchedAt))

        XCTAssertEqual(result.title, "ChatGPT / Codex (Pro)")
        XCTAssertEqual(result.bars.map(\.label), ["5 hour usage limit", "Weekly usage limit"])
        XCTAssertEqual(result.bars.map(\.used), [42, 81])
        XCTAssertEqual(result.bars.map(\.usageText), ["42%", "81%"])
        XCTAssertEqual(result.bars.first?.resetDescription, "Resets 1d 0h (Mon 7:00 PM EST)")
        XCTAssertEqual(result.bars.first?.projectionCurrent, 0.42)
        XCTAssertEqual(result.bars.first?.projectionLimit, 1)
        XCTAssertEqual(result.bars.first?.projectionPeriodStart, Date(timeIntervalSince1970: 1_893_438_000))
        XCTAssertEqual(result.bars.first?.projectionPeriodEnd, Date(timeIntervalSince1970: 1_893_456_000))
    }

    func testUsageBarFormatsPercentAndProjection() {
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let now = start.addingTimeInterval(60 * 60)
        let end = start.addingTimeInterval(5 * 60 * 60)
        let bar = UsageBar(
            label: "5 hour usage limit",
            used: 25,
            limit: 100,
            projectionCurrent: 0.25,
            projectionLimit: 1,
            projectionPeriodStart: start,
            projectionPeriodEnd: end,
            showProjectionOnCurrentBar: true
        )

        XCTAssertEqual(bar.usageText, "25%")
        XCTAssertEqual(bar.projectedFraction(at: now), 1)
        XCTAssertEqual(
            bar.projectionDescription(at: now),
            "Projected 100% at current pace - Limit hit Wed 11:00 PM EST - 1h early"
        )
    }

    func testUsageBarKeepsOverLimitPercentVisible() {
        let bar = UsageBar(label: "Weekly usage limit", used: 112, limit: 100)

        XCTAssertEqual(bar.usageText, "112%")
        XCTAssertEqual(bar.fractionUsed, 1)
    }

    func testCodexUsageWithoutCredentialIsNotDemoData() async throws {
        let provider = CodexUsageProvider(secretStore: EmptySecretStore())

        let result = try await provider.fetchUsage()

        XCTAssertEqual(result.providerID, .codex)
        XCTAssertEqual(result.subtitle, "Not configured - sign in with ChatGPT.")
        XCTAssertTrue(result.bars.isEmpty)
    }

    @MainActor
    func testDemoRefreshReturnsSortedResults() async {
        let service = UsageRefreshService.demo()

        await service.refresh()

        XCTAssertEqual(
            service.results.map(\.providerID),
            [.codex, .copilot, .openRouter]
        )
        XCTAssertFalse(service.isRefreshing)
        XCTAssertNil(service.lastRefreshError)
    }
}

private struct EmptySecretStore: SecretStore {
    func readSecret(account: String) throws -> String? {
        nil
    }

    func saveSecret(_ secret: String, account: String) throws {
    }

    func deleteSecret(account: String) throws {
    }
}

private extension URLComponents {
    func queryItemValue(named name: String) -> String? {
        queryItems?.first { $0.name == name }?.value
    }
}

private extension String {
    func base64URLEncodedForTest() -> String {
        Data(utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
