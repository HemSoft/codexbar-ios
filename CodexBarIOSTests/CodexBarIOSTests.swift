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

        let result = try XCTUnwrap(CodexUsageParser.parse(Data(payload.utf8)))

        XCTAssertEqual(result.title, "ChatGPT / Codex (Pro)")
        XCTAssertEqual(result.bars.map(\.label), ["5-hour", "Weekly"])
        XCTAssertEqual(result.bars.map(\.used), [42, 81])
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
