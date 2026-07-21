import XCTest
@testable import CodexBarIOS
#if canImport(AuthenticationServices) && canImport(UIKit)
import AuthenticationServices
#endif

final class ConfigurationAndAuthTests: XCTestCase {
    @MainActor
    func testProviderConfigurationStoreStartsWithoutAccounts() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())

        XCTAssertTrue(store.configurations.isEmpty)
    }

    @MainActor
    func testProviderConfigurationStorePreservesCopilotBrowserSession() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let oldCopilotConfiguration = ProviderAccountConfiguration(
            providerID: .copilot,
            authMethod: .browserSession
        )
        let data = try! JSONEncoder().encode([oldCopilotConfiguration])
        defaults.set(data, forKey: "providerConfigurations")

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())

        XCTAssertEqual(store.configuration(for: .copilot).authMethod, .browserSession)
    }

    @MainActor
    func testProviderConfigurationStoreSupportsMultipleAccountsForProvider() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let original = store.addAccount(for: .copilot)
        let added = store.addAccount(for: .copilot)

        XCTAssertEqual(store.configurations(for: .copilot).count, 2)
        XCTAssertNotEqual(original.id, added.id)
        XCTAssertEqual(
            ProviderConfigurationStore.keychainAccount(for: original).hasPrefix("providerAccount.copilot."),
            true
        )
        XCTAssertTrue(
            ProviderConfigurationStore.keychainAccount(for: added)
                .hasPrefix("providerAccount.copilot.")
        )
    }

    @MainActor
    func testCursorIdentityChangeRemovesStaleEmailButPreservesCustomLabel() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: MemorySecretStore())
        var cursor = store.addAccount(for: .cursor)
        cursor.accountLabel = "franz_hemmer@hotmail.com"
        XCTAssertTrue(store.update(cursor))

        XCTAssertEqual(store.cursorAccountLabelAfterIdentityChange(for: cursor), "")

        cursor.accountLabel = "Work Cursor"
        XCTAssertEqual(store.cursorAccountLabelAfterIdentityChange(for: cursor), "Work Cursor")

        cursor.accountLabel = "team@acme"
        XCTAssertEqual(store.cursorAccountLabelAfterIdentityChange(for: cursor), "team@acme")
    }

    @MainActor
    func testConnectingCursorAccountPersistsCredentialAndClearsStaleEmail() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        var cursor = store.addAccount(for: .cursor)
        cursor.accountLabel = "old@example.com"
        XCTAssertTrue(store.update(cursor))

        let connected = try XCTUnwrap(
            store.connectCursorAccount(cursor, credential: "replacement-token")
        )

        XCTAssertEqual(connected.accountLabel, "")
        XCTAssertEqual(connected.displayName, "Cursor")
        XCTAssertEqual(store.configuration(accountID: cursor.id), connected)
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: cursor)),
            "replacement-token"
        )
        XCTAssertTrue(store.hasSecret(for: cursor))
    }

    @MainActor
    func testDisconnectingCursorAccountPreservesOtherCursorCredential() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        var first = store.addAccount(for: .cursor)
        first.accountLabel = "first@example.com"
        XCTAssertTrue(store.update(first))
        let second = store.addAccount(for: .cursor)
        store.saveSecret("first-token", for: first)
        store.saveSecret("second-token", for: second)

        let disconnected = try XCTUnwrap(store.disconnectCursorAccount(first))

        XCTAssertFalse(store.hasSecret(for: first))
        XCTAssertEqual(disconnected.accountLabel, "")
        XCTAssertEqual(disconnected.displayName, "Cursor")
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: second)),
            "second-token"
        )
        XCTAssertTrue(store.hasSecret(for: second))
    }

    @MainActor
    func testFailedCursorCredentialReplacementPreservesExistingIdentity() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = FailingSaveSecretStore(secret: "existing-token")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        var cursor = store.addAccount(for: .cursor)
        cursor.accountLabel = "existing@example.com"
        XCTAssertTrue(store.update(cursor))

        XCTAssertNil(store.connectCursorAccount(cursor, credential: "replacement-token"))
        XCTAssertEqual(store.configuration(accountID: cursor.id)?.accountLabel, "existing@example.com")
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: cursor)),
            "existing-token"
        )
    }

    @MainActor
    func testProviderConfigurationStoreSurfacesSecretReadFailures() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: FailingReadSecretStore()
        )
        let claude = store.addAccount(for: .claude)

        XCTAssertFalse(store.hasSecret(for: claude))
        XCTAssertEqual(
            store.lastError,
            "Could not read the saved credential for Claude 1: Keychain unavailable"
        )
    }

    @MainActor
    func testProviderConfigurationStoreRequiresClaudeSecretForBrowserSession() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let claude = store.addAccount(for: .claude)

        XCTAssertFalse(store.isConfigured(claude))
        XCTAssertEqual(store.statusText(for: claude), "Not configured - sign in with Claude")

        store.saveSecret("claude-token", for: claude)

        XCTAssertTrue(store.isConfigured(claude))
        XCTAssertEqual(store.statusText(for: claude), "Claude 1 - live usage enabled")
    }

    @MainActor
    func testOpenCodeZenDisplaysOnDashboardWhenKeyIsSavedBeforeWorkspace() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let openCodeZen = store.addAccount(for: .openCodeZen)

        XCTAssertFalse(store.isConfigured(openCodeZen))
        XCTAssertFalse(store.shouldDisplayOnDashboard(openCodeZen))

        store.saveSecret("oczen-test-key", for: openCodeZen)

        XCTAssertFalse(store.isConfigured(openCodeZen))
        XCTAssertTrue(store.shouldDisplayOnDashboard(openCodeZen))
        XCTAssertEqual(store.statusText(for: openCodeZen), "Not configured - enter OpenCode workspace ID")
    }

    @MainActor
    func testProviderConfigurationStoreRejectsDuplicateAccountNames() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: MemorySecretStore())
        var first = store.addAccount(for: .copilot)
        first.accountLabel = "Work"
        store.update(first)

        var second = store.addAccount(for: .codex)
        second.accountLabel = "work"
        store.update(second)

        XCTAssertEqual(store.lastError, "Account names must be unique.")
        XCTAssertNotEqual(store.configuration(accountID: second.id)?.accountLabel, "work")
    }

    @MainActor
    func testProviderConfigurationStoreRejectsDuplicateFallbackDisplayNames() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: MemorySecretStore())
        var first = store.addAccount(for: .copilot)
        first.accountLabel = "Work Copilot"
        store.update(first)
        var second = store.addAccount(for: .copilot)
        second.accountLabel = "work copilot"

        XCTAssertFalse(store.update(second))
        XCTAssertEqual(store.lastError, "Account names must be unique.")
        XCTAssertNotEqual(store.configuration(accountID: second.id)?.displayName, "work copilot")
    }

    @MainActor
    func testProviderConfigurationStoreResetRemovesAccountsAndSecrets() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let account = store.addAccount(for: .claude)
        store.saveSecret("token", for: account)
        XCTAssertTrue(store.hasSecret(for: account))

        store.resetAccounts()

        XCTAssertTrue(store.configurations.isEmpty)
        XCTAssertFalse(store.hasSecret(for: account))
        XCTAssertNil(try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: account)))
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

    @MainActor
    func testCodexBrowserSignInUsesLocalhostRedirectAndTimesOut() async throws {
        let service = CodexWebAuthService(callbackTimeoutNanoseconds: 10_000_000)
        var presentedURL: URL?

        do {
            _ = try await service.signIn { presentedURL = $0 }
            XCTFail("Expected ChatGPT browser sign-in to time out without a callback.")
        } catch {
            XCTAssertEqual(error as? CodexWebAuthService.AuthError, .callbackTimedOut)
        }

        let authorizationComponents = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(presentedURL), resolvingAgainstBaseURL: false)
        )
        let redirectURI = try XCTUnwrap(authorizationComponents.queryItemValue(named: "redirect_uri"))
        XCTAssertEqual(URL(string: redirectURI)?.host, "localhost")
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

    func testCodexRefreshTokenRequestBodyUsesRefreshGrant() {
        let body = String(
            data: CodexWebAuthService.makeRefreshTokenRequestBody(refreshToken: "refresh value"),
            encoding: .utf8
        )

        XCTAssertEqual(
            body,
            "grant_type=refresh_token&refresh_token=refresh%20value&client_id=app_EMoamEEZ73f0CkXaXp7hrann"
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

    func testCodexCredentialsParserReadsAccountIDFromAccessJWT() throws {
        let header = #"{"alg":"none"}"#.base64URLEncodedForTest()
        let payload = #"{"chatgpt_account_id":"access-account"}"#.base64URLEncodedForTest()
        let accessToken = "\(header).\(payload).signature"

        let credentials = try XCTUnwrap(CodexCredentialsParser.parse("""
        {"tokens":{"access_token":"\(accessToken)"}}
        """))

        XCTAssertEqual(credentials.accountID, "access-account")
    }

    func testCodexCredentialsParserRetainsOAuthLifecycleFieldsAndLegacyTokens() throws {
        let credentials = try XCTUnwrap(CodexCredentialsParser.parse("""
        {
          "tokens": {
            "access_token": "access-token",
            "refresh_token": "refresh-token",
            "id_token": "id-token",
            "account_id": "account-id",
            "expires_at": 2000000000000
          }
        }
        """))

        XCTAssertEqual(credentials.accessToken, "access-token")
        XCTAssertEqual(credentials.refreshToken, "refresh-token")
        XCTAssertEqual(credentials.idToken, "id-token")
        XCTAssertEqual(credentials.accountID, "account-id")
        XCTAssertEqual(credentials.expiresAt, 2_000_000_000)
        XCTAssertEqual(
            CodexCredentialsParser.parse("legacy-access-token"),
            CodexCredentials(accessToken: "legacy-access-token")
        )

        let roundTripped = try XCTUnwrap(
            CodexCredentialsParser.parse(CodexCredentialsParser.storedCredential(from: credentials))
        )
        XCTAssertEqual(roundTripped, credentials)

        let accessOnly = CodexCredentialsParser.storedCredential(from: CodexCredentials(accessToken: "access-only"))
        let accessOnlyData = try XCTUnwrap(accessOnly.data(using: .utf8))
        let accessOnlyRoot = try XCTUnwrap(
            JSONSerialization.jsonObject(with: accessOnlyData) as? [String: Any]
        )
        let accessOnlyTokens = try XCTUnwrap(accessOnlyRoot["tokens"] as? [String: Any])
        XCTAssertEqual(accessOnlyTokens.count, 1)
        XCTAssertEqual(accessOnlyTokens["access_token"] as? String, "access-only")
    }

    func testCopilotAuthURLUsesGitHubBrowserCallbackFlow() throws {
        let url = CopilotWebAuthService.authorizationURL(
            clientID: "client id",
            redirectURI: "http://127.0.0.1:1456/callback",
            state: "state",
            codeChallenge: "challenge"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "github.com")
        XCTAssertEqual(components.path, "/login/oauth/authorize")
        XCTAssertEqual(components.queryItemValue(named: "response_type"), "code")
        XCTAssertEqual(components.queryItemValue(named: "client_id"), "client id")
        XCTAssertEqual(components.queryItemValue(named: "redirect_uri"), "http://127.0.0.1:1456/callback")
        XCTAssertEqual(components.queryItemValue(named: "scope"), "repo read:org gist")
        XCTAssertEqual(components.queryItemValue(named: "state"), "state")
        XCTAssertEqual(components.queryItemValue(named: "code_challenge"), "challenge")
        XCTAssertEqual(components.queryItemValue(named: "code_challenge_method"), "S256")
        XCTAssertEqual(components.queryItemValue(named: "prompt"), "select_account")
    }

    @MainActor
    func testCopilotBrowserSignInUsesRegisteredLoopbackRedirectAndTimesOut() async throws {
        let service = CopilotWebAuthService(callbackTimeoutNanoseconds: 10_000_000)
        let configuration = CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret")
        var presentedURL: URL?

        do {
            _ = try await service.signIn(configuration: configuration) { presentedURL = $0 }
            XCTFail("Expected GitHub browser sign-in to time out without a callback.")
        } catch {
            XCTAssertEqual(error as? CopilotWebAuthService.AuthError, .callbackTimedOut)
        }

        let authorizationComponents = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(presentedURL), resolvingAgainstBaseURL: false)
        )
        let redirectURI = try XCTUnwrap(authorizationComponents.queryItemValue(named: "redirect_uri"))
        XCTAssertEqual(URL(string: redirectURI)?.host, "127.0.0.1")
    }

    func testCopilotTokenRequestBodyUsesAuthorizationCodeExchange() {
        let body = String(
            data: CopilotWebAuthService.makeTokenRequestBody(
                clientID: "client",
                clientSecret: "secret",
                code: "code value",
                redirectURI: "http://127.0.0.1:1456/callback",
                codeVerifier: "verifier value"
            ),
            encoding: .utf8
        )

        XCTAssertEqual(
            body,
            "client_id=client&client_secret=secret&code=code%20value&redirect_uri=http%3A%2F%2F127.0.0.1%3A1456%2Fcallback&code_verifier=verifier%20value"
        )
    }

    func testCopilotRefreshTokenRequestBodyUsesRefreshGrant() {
        let body = String(
            data: CopilotWebAuthService.makeRefreshTokenRequestBody(
                clientID: "client",
                clientSecret: "secret",
                refreshToken: "refresh value"
            ),
            encoding: .utf8
        )

        XCTAssertEqual(
            body,
            "client_id=client&client_secret=secret&grant_type=refresh_token&refresh_token=refresh%20value"
        )
    }

    func testClaudeAuthURLUsesBrowserCallbackFlow() throws {
        let url = ClaudeWebAuthService.authorizationURL(
            redirectURI: "http://localhost:1461/callback",
            state: "state",
            codeChallenge: "challenge"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "claude.com")
        XCTAssertEqual(components.path, "/cai/oauth/authorize")
        XCTAssertEqual(components.queryItemValue(named: "code"), "true")
        XCTAssertEqual(components.queryItemValue(named: "client_id"), "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        XCTAssertEqual(components.queryItemValue(named: "response_type"), "code")
        XCTAssertEqual(components.queryItemValue(named: "redirect_uri"), "http://localhost:1461/callback")
        XCTAssertEqual(components.queryItemValue(named: "scope"), "org:create_api_key user:profile user:inference user:sessions:claude_code")
        XCTAssertEqual(components.queryItemValue(named: "code_challenge"), "challenge")
        XCTAssertEqual(components.queryItemValue(named: "code_challenge_method"), "S256")
        XCTAssertEqual(components.queryItemValue(named: "state"), "state")
    }

    @MainActor
    func testClaudeBrowserSignInUsesLocalhostRedirectAndTimesOut() async throws {
        let service = ClaudeWebAuthService(callbackTimeoutNanoseconds: 10_000_000)
        var presentedURL: URL?

        do {
            _ = try await service.signIn { presentedURL = $0 }
            XCTFail("Expected Claude browser sign-in to time out without a callback.")
        } catch {
            XCTAssertEqual(error as? ClaudeWebAuthService.AuthError, .callbackTimedOut)
        }

        let authorizationComponents = try XCTUnwrap(
            URLComponents(url: try XCTUnwrap(presentedURL), resolvingAgainstBaseURL: false)
        )
        let redirectURI = try XCTUnwrap(authorizationComponents.queryItemValue(named: "redirect_uri"))
        XCTAssertEqual(URL(string: redirectURI)?.host, "localhost")
    }

    func testClaudeTokenRequestBodyUsesAuthorizationCodeExchange() throws {
        let data = ClaudeWebAuthService.makeTokenRequestBody(
            code: "code value",
            redirectURI: "http://localhost:1461/callback",
            state: "state value",
            codeVerifier: "verifier value"
        )
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])

        XCTAssertEqual(body["grant_type"], "authorization_code")
        XCTAssertEqual(body["code"], "code value")
        XCTAssertEqual(body["redirect_uri"], "http://localhost:1461/callback")
        XCTAssertEqual(body["client_id"], "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        XCTAssertEqual(body["code_verifier"], "verifier value")
        XCTAssertEqual(body["state"], "state value")
    }

    func testTokenEndpointErrorFormatterOnlySurfacesSafeOAuthErrorCode() {
        let body = Data(#"{"error":"invalid_grant","error_description":"authorization code=secret-code client_id=secret-client"}"#.utf8)

        let message = TokenEndpointErrorFormatter.message(statusCode: 400, body: body)

        XCTAssertEqual(message, "HTTP 400 (invalid_grant)")
        XCTAssertFalse(message.contains("secret-code"))
        XCTAssertFalse(message.contains("secret-client"))
    }

    func testTokenEndpointErrorFormatterDropsUntrustedResponseContent() {
        let rawBody = Data("<html>authorization: Bearer secret-token</html>".utf8)
        let unsafeJSON = Data(#"{"error":"invalid grant code=secret-code"}"#.utf8)
        let nonASCIIJSON = Data(#"{"error":"invalid_grant_🔑"}"#.utf8)

        XCTAssertEqual(
            TokenEndpointErrorFormatter.message(statusCode: 502, body: rawBody),
            "HTTP 502"
        )
        XCTAssertEqual(
            TokenEndpointErrorFormatter.message(statusCode: 400, body: unsafeJSON),
            "HTTP 400"
        )
        XCTAssertEqual(
            TokenEndpointErrorFormatter.message(statusCode: 400, body: nonASCIIJSON),
            "HTTP 400"
        )
        XCTAssertEqual(
            TokenEndpointErrorFormatter.message(errorCode: String(repeating: "x", count: 65)),
            "Token endpoint rejected the request."
        )
    }

    @MainActor
    func testClaudeBrowserSignInSanitizesTokenExchangeFailure() async throws {
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ConfigurationAndAuthMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = ClaudeWebAuthService(session: session, callbackTimeoutNanoseconds: 1_000_000_000)

        ConfigurationAndAuthMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://platform.claude.com/v1/oauth/token")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 400,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"error":"invalid_grant","error_description":"code=secret-code client_id=secret-client"}"#.utf8)
            )
        }
        defer {
            ConfigurationAndAuthMockURLProtocol.handler = nil
        }

        do {
            _ = try await service.signIn { authorizationURL in
                guard
                    let authorizationComponents = URLComponents(
                        url: authorizationURL,
                        resolvingAgainstBaseURL: false
                    ),
                    let redirectURI = authorizationComponents.queryItemValue(named: "redirect_uri"),
                    let state = authorizationComponents.queryItemValue(named: "state"),
                    var callbackComponents = URLComponents(string: redirectURI)
                else {
                    XCTFail("Expected a valid Claude authorization callback URL.")
                    return
                }
                callbackComponents.queryItems = [
                    URLQueryItem(name: "code", value: "authorization-code"),
                    URLQueryItem(name: "state", value: state)
                ]
                guard let callbackURL = callbackComponents.url else {
                    XCTFail("Expected a valid Claude callback URL.")
                    return
                }
                Task.detached {
                    _ = try? await URLSession.shared.data(from: callbackURL)
                }
            }
            XCTFail("Expected Claude sign-in to fail.")
        } catch {
            XCTAssertEqual(
                error as? ClaudeWebAuthService.AuthError,
                .tokenExchangeFailed("HTTP 400 (invalid_grant)")
            )
            XCTAssertFalse(error.localizedDescription.contains("secret-code"))
            XCTAssertFalse(error.localizedDescription.contains("secret-client"))
        }
    }

    func testClaudeCredentialsParserReadsClaudeCodeOAuthShape() {
        let credentials = ClaudeCredentialsParser.parse("""
        {
          "claudeAiOauth": {
            "subscriptionType": "pro",
            "rateLimitTier": "standard",
            "expiresAt": 1893456000000,
            "accessToken": "access-token",
            "refreshToken": "refresh-token"
          }
        }
        """)

        XCTAssertEqual(
            credentials,
            ClaudeCredentials(
                subscriptionType: "pro",
                rateLimitTier: "standard",
                expiresAt: 1_893_456_000_000,
                accessToken: "access-token",
                refreshToken: "refresh-token"
            )
        )
    }

    func testCursorAuthURLUsesBrowserPollingFlow() throws {
        let url = CursorWebAuthService.authorizationURL(
            uuid: "request-id",
            codeChallenge: "challenge"
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "cursor.com")
        XCTAssertEqual(components.path, "/loginDeepControl")
        XCTAssertEqual(components.queryItemValue(named: "challenge"), "challenge")
        XCTAssertEqual(components.queryItemValue(named: "uuid"), "request-id")
        XCTAssertEqual(components.queryItemValue(named: "mode"), "login")
        XCTAssertEqual(components.queryItemValue(named: "redirectTarget"), "cli")
    }

    func testCursorPollRequestUsesPKCEVerifier() throws {
        let request = CursorWebAuthService.pollRequest(uuid: "request-id", codeVerifier: "verifier")
        let url = try XCTUnwrap(request.url)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "api2.cursor.sh")
        XCTAssertEqual(components.path, "/auth/poll")
        XCTAssertEqual(components.queryItemValue(named: "uuid"), "request-id")
        XCTAssertEqual(components.queryItemValue(named: "verifier"), "verifier")
        XCTAssertEqual(request.httpMethod, "GET")
    }

    @MainActor
    func testCursorBrowserSignInPollsAndStoresSessionShape() async throws {
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ConfigurationAndAuthMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = CursorWebAuthService(
            session: session,
            pollIntervalNanoseconds: 1,
            maxPollAttempts: 1
        )

        ConfigurationAndAuthMockURLProtocol.handler = { request in
            let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.host, "api2.cursor.sh")
            XCTAssertEqual(components.path, "/auth/poll")
            XCTAssertNotNil(components.queryItemValue(named: "uuid"))
            XCTAssertNotNil(components.queryItemValue(named: "verifier"))
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"accessToken":"cursor-access","refreshToken":"cursor-refresh","authId":"auth0|user-id"}"#.utf8)
            )
        }
        defer {
            ConfigurationAndAuthMockURLProtocol.handler = nil
        }

        var presentedURL: URL?
        let result = try await service.signIn { url in
            presentedURL = url
            return true
        }
        let authURL = try XCTUnwrap(presentedURL)
        let authComponents = try XCTUnwrap(URLComponents(url: authURL, resolvingAgainstBaseURL: false))

        XCTAssertEqual(authComponents.host, "cursor.com")
        XCTAssertEqual(result.accessToken, "cursor-access")
        XCTAssertEqual(result.refreshToken, "cursor-refresh")
        XCTAssertTrue(result.storedCredential.contains(#""accessToken": "cursor-access""#))
    }

    @MainActor
    func testCursorBrowserSignInSanitizesTokenPollFailure() async throws {
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ConfigurationAndAuthMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = CursorWebAuthService(
            session: session,
            pollIntervalNanoseconds: 1,
            maxPollAttempts: 1
        )

        ConfigurationAndAuthMockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 400,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"error":"invalid_grant","error_description":"code=secret-code"}"#.utf8)
            )
        }
        defer {
            ConfigurationAndAuthMockURLProtocol.handler = nil
        }

        do {
            _ = try await service.signIn { _ in true }
            XCTFail("Expected Cursor sign-in to fail.")
        } catch {
            XCTAssertEqual(error as? CursorWebAuthService.AuthError, .tokenPollFailed("HTTP 400 (invalid_grant)"))
            XCTAssertFalse(error.localizedDescription.contains("secret-code"))
        }
    }

#if canImport(AuthenticationServices) && canImport(UIKit)
    @MainActor
    func testCursorBrowserSessionUsesEphemeralStorage() {
        let session = CursorWebAuthenticationPresenter.makeSession(
            url: URL(string: "https://cursor.com/loginDeepControl")!
        ) { _ in }

        XCTAssertTrue(session.prefersEphemeralWebBrowserSession)
    }
#endif

    func testCursorBrowserSessionIgnoresStaleCompletionAfterRetry() {
        var generation = CursorWebAuthenticationSessionGeneration()
        let firstSessionID = generation.start()
        let retrySessionID = generation.start()

        XCTAssertFalse(generation.complete(firstSessionID))
        XCTAssertTrue(generation.complete(retrySessionID))
        XCTAssertFalse(generation.complete(retrySessionID))
    }

    @MainActor
    func testCursorSignInStopsWhenPrivateBrowserCannotStart() async {
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ConfigurationAndAuthMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = CursorWebAuthService(
            session: session,
            pollIntervalNanoseconds: 1,
            maxPollAttempts: 1
        )
        ConfigurationAndAuthMockURLProtocol.handler = { _ in
            XCTFail("Token polling should not start when the browser session cannot start.")
            throw URLError(.badServerResponse)
        }
        defer {
            ConfigurationAndAuthMockURLProtocol.handler = nil
        }

        do {
            _ = try await service.signIn { _ in false }
            XCTFail("Expected Cursor sign-in to reject a failed browser session.")
        } catch {
            XCTAssertEqual(error as? CursorWebAuthService.AuthError, .couldNotStartBrowserSession)
        }
    }

    func testCopilotCredentialsParserReadsStoredJSONAndRawToken() {
        XCTAssertEqual(
            CopilotCredentialsParser.parse(#"{"accessToken":"token","username":"octocat"}"#),
            CopilotCredentials(accessToken: "token", username: "octocat")
        )
        XCTAssertEqual(
            CopilotCredentialsParser.parse("gho_raw_token"),
            CopilotCredentials(accessToken: "gho_raw_token")
        )
    }

    func testCopilotCredentialsParserRetainsRefreshAndExpiryFields() throws {
        let credentials = CopilotCredentials(
            accessToken: "access-token",
            username: "octocat",
            refreshToken: "refresh-token",
            expiresAt: 2_000_000_000,
            refreshTokenExpiresAt: 2_100_000_000
        )

        let stored = CopilotCredentialsParser.storedCredential(from: credentials)
        XCTAssertEqual(try XCTUnwrap(CopilotCredentialsParser.parse(stored)), credentials)
        XCTAssertEqual(
            CopilotCredentialsParser.parse("legacy-token"),
            CopilotCredentials(accessToken: "legacy-token")
        )
    }

    func testCopilotUsageRequestMatchesWindowsCopilotHeaders() {
        let provider = CopilotUsageProvider(
            secretStore: EmptySecretStore(),
            usageEndpoint: URL(string: "https://api.github.com/copilot_internal/user")!
        )

        let request = provider.makeUsageRequest(accessToken: "github-token")

        XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/copilot_internal/user")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token github-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "GitHubCopilotChat/0.26.7")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Editor-Version"), "vscode/1.96.2")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Editor-Plugin-Version"), "copilot-chat/0.26.7")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Github-Api-Version"), "2025-04-01")
    }

    func testCopilotOrganizationBillingRequestSupportsStandaloneOrganization() throws {
        let provider = CopilotUsageProvider(
            secretStore: EmptySecretStore(),
            githubAPIBaseURL: URL(string: "https://api.github.com")!
        )
        let date = Date(timeIntervalSince1970: 1_782_882_000)
        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            authMethod: .browserSession,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering"
        )

        let request = try XCTUnwrap(provider.makeOrganizationBillingRequest(
            accessToken: "github-token",
            configuration: configuration,
            date: date
        ))
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.path, "/organizations/Relias-Engineering/settings/billing/ai_credit/usage")
        XCTAssertEqual(components.queryItemValue(named: "year"), "2026")
        XCTAssertEqual(components.queryItemValue(named: "month"), "7")
        XCTAssertEqual(components.queryItemValue(named: "product"), "Copilot")
        XCTAssertNil(components.queryItemValue(named: "organization"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer github-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
    }

    func testCopilotOrganizationBillingRequestSupportsEnterpriseOrganization() throws {
        let provider = CopilotUsageProvider(
            secretStore: EmptySecretStore(),
            githubAPIBaseURL: URL(string: "https://api.github.com")!
        )
        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            authMethod: .browserSession,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering",
            githubEnterprise: "bertelsmann"
        )

        let request = try XCTUnwrap(provider.makeOrganizationBillingRequest(
            accessToken: "github-token",
            configuration: configuration,
            date: Date(timeIntervalSince1970: 1_782_882_000)
        ))
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false))

        XCTAssertEqual(components.path, "/enterprises/bertelsmann/settings/billing/ai_credit/usage")
        XCTAssertEqual(components.queryItemValue(named: "organization"), "Relias-Engineering")
    }

    func testCopilotOrganizationSeatCountRequestUsesOrgBillingEndpoint() throws {
        let provider = CopilotUsageProvider(
            secretStore: EmptySecretStore(),
            githubAPIBaseURL: URL(string: "https://api.github.com")!
        )
        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            authMethod: .browserSession,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering"
        )

        let request = try XCTUnwrap(provider.makeOrganizationSeatCountRequest(
            accessToken: "github-token",
            configuration: configuration
        ))

        XCTAssertEqual(request.url?.path, "/orgs/Relias-Engineering/copilot/billing")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer github-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
    }

    func testCopilotOrganizationCreditsPerSeatMatchesWindowsPromotionalWindow() {
        XCTAssertEqual(CopilotUsageProvider.creditsPerSeat(year: 2026, month: 6), 7_000)
        XCTAssertEqual(CopilotUsageProvider.creditsPerSeat(year: 2026, month: 7), 7_000)
        XCTAssertEqual(CopilotUsageProvider.creditsPerSeat(year: 2026, month: 8), 7_000)
        XCTAssertEqual(CopilotUsageProvider.creditsPerSeat(year: 2026, month: 9), 3_900)
    }

    func testCopilotUsageParserReadsQuotaSnapshots() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let payload = """
        {
          "login": "octocat",
          "copilot_plan": "individual_pro",
          "quota_reset_date_utc": "2030-01-03T00:00:00Z",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 2000,
              "remaining": 500,
              "unlimited": false
            },
            "chat": {
              "entitlement": 100,
              "remaining": 12,
              "unlimited": false
            }
          }
        }
        """

        let result = try XCTUnwrap(CopilotUsageParser.parse(Data(payload.utf8), fetchedAt: fetchedAt))

        XCTAssertEqual(result.providerID, .copilot)
        XCTAssertEqual(result.title, "GitHub Copilot (octocat) - Pro")
        XCTAssertEqual(result.bars.map(\.label), ["Premium interactions (1,500 / 2,000)", "Chat (88 / 100)"])
        XCTAssertEqual(result.bars.map(\.usageText), ["75%", "88%"])
        XCTAssertEqual(result.subtitle, "Resets in 3d")
        XCTAssertEqual(result.bars.first?.projectionCurrent, 1500)
        XCTAssertEqual(result.bars.first?.projectionLimit, 2000)
        XCTAssertEqual(result.bars.first?.projectionPeriodStart, Date(timeIntervalSince1970: 1_890_950_400))
        XCTAssertEqual(result.bars.first?.projectionPeriodEnd, Date(timeIntervalSince1970: 1_893_628_800))
        XCTAssertEqual(result.bars.first?.showProjectionOnCurrentBar, true)
    }

    func testCopilotAccountMetadataPreservesAllUsageDetails() {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let monetaryMetric = ProviderMonetaryMetric(
            kind: .balance,
            label: "Available balance",
            minorUnits: 1_250,
            currencyCode: "USD",
            decimalPlaces: 2,
            detail: "Provider-reported balance"
        )
        let parsedResult = ProviderUsageResult(
            accountID: "parsed-account",
            providerID: .copilot,
            title: "Parsed Copilot account",
            subtitle: "Live GitHub Copilot usage",
            bars: [],
            creditsRemaining: 42.5,
            monetaryMetrics: [monetaryMetric],
            usageMessages: ["Provider-reported message"],
            fetchedAt: fetchedAt
        )
        let configuration = ProviderAccountConfiguration(
            id: "copilot.work",
            providerID: .copilot,
            accountLabel: "Work Copilot",
            authMethod: .browserSession
        )
        let provider = CopilotUsageProvider(secretStore: EmptySecretStore())

        let result = provider.applyAccountMetadata(to: parsedResult, configuration: configuration)

        XCTAssertEqual(result.accountID, "copilot.work")
        XCTAssertEqual(result.title, "Work Copilot")
        XCTAssertEqual(result.creditsRemaining, parsedResult.creditsRemaining)
        XCTAssertEqual(result.monetaryMetrics, parsedResult.monetaryMetrics)
        XCTAssertEqual(result.usageMessages, parsedResult.usageMessages)
        XCTAssertEqual(result.fetchedAt, fetchedAt)
    }

    func testCopilotUsageParserOmitsUnlimitedChatQuota() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let payload = """
        {
          "login": "fphemmer",
          "copilot_plan": "business",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 2000,
              "remaining": 500,
              "unlimited": false
            },
            "chat": {
              "entitlement": 0,
              "remaining": 0,
              "unlimited": true
            }
          }
        }
        """

        let result = try XCTUnwrap(CopilotUsageParser.parse(Data(payload.utf8), fetchedAt: fetchedAt))

        XCTAssertEqual(result.bars.map(\.label), ["Premium interactions (1,500 / 2,000)"])
    }

    func testCopilotUsageParserInfersMonthlyProjectionWhenResetIsMissing() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let payload = """
        {
          "login": "octocat",
          "copilot_plan": "individual_pro",
          "quota_snapshots": {
            "premium_interactions": {
              "entitlement": 2000,
              "remaining": 500,
              "unlimited": false
            }
          }
        }
        """

        let result = try XCTUnwrap(CopilotUsageParser.parse(Data(payload.utf8), fetchedAt: fetchedAt))

        XCTAssertEqual(result.subtitle, "Live GitHub Copilot usage")
        XCTAssertEqual(result.bars.first?.resetDescription, "Resets in 21d 16h")
        XCTAssertEqual(result.bars.first?.projectionPeriodStart, Date(timeIntervalSince1970: 1_782_864_000))
        XCTAssertEqual(result.bars.first?.projectionPeriodEnd, Date(timeIntervalSince1970: 1_785_542_400))
        XCTAssertEqual(result.bars.first?.showProjectionOnCurrentBar, true)
    }

    func testCopilotBillingUsageParserReadsOrganizationUsage() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let payload = """
        {
          "timePeriod": { "year": 2026, "month": 7 },
          "organization": "Relias-Engineering",
          "usageItems": [
            { "product": "Copilot", "sku": "Copilot AI Credits", "grossQuantity": 1200 },
            { "product": "Actions", "sku": "Actions Linux", "grossQuantity": 99 },
            { "sku": "Copilot AI Credits", "grossQuantity": 300 }
          ]
        }
        """
        let configuration = ProviderAccountConfiguration(
            id: "copilot.org",
            providerID: .copilot,
            accountLabel: "Relias Engineering",
            authMethod: .browserSession,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering",
            copilotTotalAllotment: 350000
        )

        let result = try XCTUnwrap(CopilotBillingUsageParser.parse(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.accountID, "copilot.org")
        XCTAssertEqual(result.title, "Relias Engineering")
        XCTAssertEqual(result.subtitle, "Live GitHub Copilot usage for Relias-Engineering")
        XCTAssertEqual(result.bars.map(\.label), [
            "Current AI credits (1,500 / 350,000)",
        ])
        XCTAssertEqual(result.bars.map(\.usageText), ["0%"])
        XCTAssertEqual(result.bars.first?.projectionCurrent, 1500)
        XCTAssertEqual(result.bars.first?.projectionLimit, 350000)
        XCTAssertEqual(result.bars.first?.projectionPeriodStart, Date(timeIntervalSince1970: 1_782_864_000))
        XCTAssertEqual(result.bars.first?.projectionPeriodEnd, Date(timeIntervalSince1970: 1_785_542_400))
        XCTAssertEqual(result.bars.first?.showProjectionOnCurrentBar, true)
    }

    func testCopilotBillingUsageParserProjectsOrganizationUsageWithoutAllotment() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let payload = """
        {
          "timePeriod": { "year": 2026, "month": 7 },
          "usageItems": [
            { "product": "Copilot", "sku": "Copilot AI Credits", "grossQuantity": 1500 }
          ]
        }
        """
        let configuration = ProviderAccountConfiguration(
            id: "copilot.org",
            providerID: .copilot,
            accountLabel: "Relias Engineering",
            authMethod: .browserSession,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering"
        )

        let result = try XCTUnwrap(CopilotBillingUsageParser.parse(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.bars.map(\.label), ["AI credits used (1,500)"])
        XCTAssertEqual(
            result.bars.first?.projectionDescription(at: fetchedAt),
            "Projected month end at current pace - 5,000 AI credits"
        )
    }

    func testCopilotBillingUsageParserUsesResolvedOrganizationPoolAllotment() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let payload = """
        {
          "timePeriod": { "year": 2026, "month": 7 },
          "usageItems": [
            { "product": "Copilot", "sku": "Copilot AI Credits", "grossQuantity": 1500 }
          ]
        }
        """
        let configuration = ProviderAccountConfiguration(
            id: "copilot.org",
            providerID: .copilot,
            accountLabel: "Relias Engineering",
            authMethod: .browserSession,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering"
        )

        let result = try XCTUnwrap(CopilotBillingUsageParser.parse(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt,
            totalAllotment: 50 * 7_000
        ))

        XCTAssertEqual(result.bars.map(\.label), ["Current AI credits (1,500 / 350,000)"])
        XCTAssertEqual(result.bars.first?.usageText, "0%")
        XCTAssertEqual(result.bars.first?.projectionCurrent, 1500)
        XCTAssertEqual(result.bars.first?.projectionLimit, 350000)
        XCTAssertEqual(result.bars.first?.showProjectionOnCurrentBar, true)
    }

    func testCopilotOrganizationAllotmentResolvesFromSeatCount() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConfigurationAndAuthMockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let provider = CopilotUsageProvider(
            secretStore: EmptySecretStore(),
            session: session,
            githubAPIBaseURL: URL(string: "https://api.github.com")!
        )
        let accountConfiguration = ProviderAccountConfiguration(
            providerID: .copilot,
            authMethod: .browserSession,
            copilotAccountScope: .organization,
            githubOrganization: "Relias-Engineering"
        )
        ConfigurationAndAuthMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/orgs/Relias-Engineering/copilot/billing")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"seat_breakdown":{"total":50}}"#.utf8)
            )
        }
        defer {
            ConfigurationAndAuthMockURLProtocol.handler = nil
        }

        let total = try await provider.resolveOrganizationAllotment(
            configuration: accountConfiguration,
            accessToken: "github-token",
            date: Date(timeIntervalSince1970: 1_783_667_520)
        )

        XCTAssertEqual(total, 350000)
    }

}
