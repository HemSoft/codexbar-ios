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
            ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen).authMethod,
            .apiKey
        )
        XCTAssertEqual(
            ProviderAccountConfiguration.defaultConfiguration(for: .copilot).authMethod,
            .browserSession
        )
        XCTAssertEqual(
            ProviderAccountConfiguration.defaultConfiguration(for: .codex).authMethod,
            .browserSession
        )
        XCTAssertEqual(
            ProviderAccountConfiguration.defaultConfiguration(for: .claude).authMethod,
            .browserSession
        )
        XCTAssertEqual(
            ProviderAccountConfiguration.defaultConfiguration(for: .cursor).authMethod,
            .browserSession
        )
    }

    @MainActor
    func testAutoRefreshIntervalDefaultsToOffAndPersists() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(store.autoRefreshInterval, .off)

        store.updateAutoRefreshInterval(.fiveMinutes)

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(reloadedStore.autoRefreshInterval, .fiveMinutes)
    }

    @MainActor
    func testWidgetRefreshIntervalDefaultsToThirtyMinutesAndPersists() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(store.widgetRefreshInterval, .thirtyMinutes)

        store.updateWidgetRefreshInterval(.oneHour)

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(reloadedStore.widgetRefreshInterval, .oneHour)
    }

    func testWidgetSnapshotStoreRoundTripsSnapshotAndRefreshInterval() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let generatedAt = Date(timeIntervalSince1970: 1_788_475_200)
        let snapshot = CodexBarWidgetSnapshot(
            generatedAt: generatedAt,
            results: [
                CodexBarWidgetProviderSnapshot(
                    accountID: "openCodeZen",
                    providerID: "openCodeZen",
                    title: "OpenCode ZEN",
                    subtitle: "Balance",
                    bars: [],
                    creditsRemaining: 42.25,
                    fetchedAt: generatedAt,
                    severity: .normal
                ),
            ]
        )

        WidgetSnapshotStore.saveSnapshot(snapshot, defaults: defaults)
        WidgetSnapshotStore.saveRefreshInterval(.threeHours, defaults: defaults)

        XCTAssertEqual(WidgetSnapshotStore.loadSnapshot(defaults: defaults), snapshot)
        XCTAssertEqual(WidgetSnapshotStore.loadRefreshInterval(defaults: defaults), .threeHours)
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

    @MainActor
    func testDashboardCardOrderPersistsAndRemovesDuplicates() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        store.updateDashboardCardOrder(["claude", "codex", "claude", "copilot"])

        XCTAssertEqual(store.dashboardCardOrder, ["claude", "codex", "copilot"])

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertEqual(reloadedStore.dashboardCardOrder, ["claude", "codex", "copilot"])
    }

    @MainActor
    func testUsageAlertSettingsPersistAndClamp() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertFalse(store.usageAlertSettings.isEnabled)
        XCTAssertEqual(store.usageAlertSettings.usageThreshold, 0.80)
        XCTAssertEqual(store.usageAlertSettings.balanceThreshold, 5.00)

        store.updateUsageAlertsEnabled(true)
        store.updateUsageAlertUsageThreshold(1.8)
        store.updateUsageAlertBalanceThreshold(-5)
        store.updateUsageAlertIncludesSeverityAlerts(false)
        store.updateUsageAlertActiveIDs(["usage.codex.weekly", "balance.openRouter"])

        let reloadedStore = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        XCTAssertTrue(reloadedStore.usageAlertSettings.isEnabled)
        XCTAssertEqual(reloadedStore.usageAlertSettings.usageThreshold, 1.0)
        XCTAssertEqual(reloadedStore.usageAlertSettings.balanceThreshold, 0)
        XCTAssertFalse(reloadedStore.usageAlertSettings.includesSeverityAlerts)
        XCTAssertEqual(reloadedStore.usageAlertActiveIDs, ["usage.codex.weekly", "balance.openRouter"])
    }

    @MainActor
    func testUsageAlertSettingsChangeClearsActiveSuppressionState() {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: EmptySecretStore())
        store.updateUsageAlertActiveIDs(["usage.codex.weekly"])
        store.updateUsageAlertUsageThreshold(0.90)

        XCTAssertTrue(store.usageAlertActiveIDs.isEmpty)
    }

    func testUsageAlertEvaluatorSendsOnceUntilRecovery() {
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    label: "5-hour",
                    used: 81,
                    limit: 100
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.80,
            includesSeverityAlerts: false
        )

        let first = UsageAlertEvaluator.evaluate(results: [result], settings: settings, activeAlertIDs: [])
        XCTAssertEqual(first.notifications.count, 1)
        XCTAssertEqual(first.notifications.first?.title, "Codex 5-hour")

        let repeated = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: settings,
            activeAlertIDs: first.activeAlertIDs
        )
        XCTAssertTrue(repeated.notifications.isEmpty)

        let recoveredResult = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                    label: "5-hour",
                    used: 40,
                    limit: 100
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_580)
        )
        let recovered = UsageAlertEvaluator.evaluate(
            results: [recoveredResult],
            settings: settings,
            activeAlertIDs: repeated.activeAlertIDs
        )
        XCTAssertTrue(recovered.activeAlertIDs.isEmpty)

        let crossedAgain = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: settings,
            activeAlertIDs: recovered.activeAlertIDs
        )
        XCTAssertEqual(crossedAgain.notifications.count, 1)
    }

    func testUsageAlertEvaluatorUsesStableUsageKeysForMutableLabels() {
        let firstResult = ProviderUsageResult(
            accountID: "cursor.main",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
                    label: "On-demand $12.00 / $20.00",
                    used: 12,
                    limit: 20
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let secondResult = ProviderUsageResult(
            accountID: "cursor.main",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
                    label: "On-demand $14.00 / $20.00",
                    used: 14,
                    limit: 20
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_580)
        )
        let settings = UsageAlertSettings(isEnabled: true, usageThreshold: 0.50)

        let first = UsageAlertEvaluator.evaluate(results: [firstResult], settings: settings, activeAlertIDs: [])
        let repeated = UsageAlertEvaluator.evaluate(
            results: [secondResult],
            settings: settings,
            activeAlertIDs: first.activeAlertIDs
        )

        XCTAssertEqual(first.notifications.count, 1)
        XCTAssertEqual(first.activeAlertIDs, ["usage.cursor.main.on-demand"])
        XCTAssertTrue(repeated.notifications.isEmpty)
        XCTAssertEqual(repeated.activeAlertIDs, ["usage.cursor.main.on-demand"])
    }

    func testUsageAlertEvaluatorDeduplicatesBarsWithSameStableKey() {
        let result = ProviderUsageResult(
            accountID: "cursor.main",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Live usage",
            bars: [
                UsageBar(label: "On-demand $12.00 / $20.00", used: 12, limit: 20),
                UsageBar(label: "On-demand $18.00 / $30.00", used: 18, limit: 30),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.50,
            includesSeverityAlerts: false
        )

        let evaluation = UsageAlertEvaluator.evaluate(results: [result], settings: settings, activeAlertIDs: [])

        XCTAssertEqual(evaluation.notifications.count, 1)
        XCTAssertEqual(evaluation.activeAlertIDs, ["usage.cursor.main.on-demand"])
    }

    func testUsageAlertEvaluatorReportsBalanceThreshold() {
        let result = ProviderUsageResult(
            accountID: "openRouter.main",
            providerID: .openRouter,
            title: "OpenRouter",
            subtitle: "Credit balance",
            bars: [],
            creditsRemaining: 4.50,
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(isEnabled: true, balanceThreshold: 5)

        let evaluation = UsageAlertEvaluator.evaluate(results: [result], settings: settings, activeAlertIDs: [])

        XCTAssertEqual(evaluation.notifications.count, 1)
        XCTAssertEqual(evaluation.notifications.first?.title, "OpenRouter Balance")
        XCTAssertTrue(evaluation.activeAlertIDs.contains("balance.openRouter.main"))
    }

    func testUsageAlertEvaluatorUsesSeverityWhenSpecificThresholdsDoNotMatch() {
        let result = ProviderUsageResult(
            accountID: "cursor.main",
            providerID: .cursor,
            title: "Cursor",
            subtitle: "Included usage - Total 76%",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                    label: "Total",
                    used: 76,
                    limit: 100
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.90,
            balanceThreshold: 5,
            includesSeverityAlerts: true
        )

        let evaluation = UsageAlertEvaluator.evaluate(results: [result], settings: settings, activeAlertIDs: [])

        XCTAssertEqual(evaluation.notifications.count, 1)
        XCTAssertEqual(evaluation.notifications.first?.title, "Cursor Warning")
        XCTAssertTrue(evaluation.activeAlertIDs.contains("severity.cursor.main"))
    }

    func testUsageAlertEvaluatorReportsSeverityAlongsideSpecificThresholds() {
        let result = ProviderUsageResult(
            accountID: "codex.personal",
            providerID: .codex,
            title: "Codex",
            subtitle: "Live usage",
            bars: [
                UsageBar(
                    id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!,
                    label: "Weekly usage limit",
                    used: 95,
                    limit: 100
                ),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_783_667_520)
        )
        let settings = UsageAlertSettings(
            isEnabled: true,
            usageThreshold: 0.80,
            balanceThreshold: 5,
            includesSeverityAlerts: true
        )

        let first = UsageAlertEvaluator.evaluate(results: [result], settings: settings, activeAlertIDs: [])
        let repeated = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: settings,
            activeAlertIDs: first.activeAlertIDs
        )

        XCTAssertEqual(first.notifications.map(\.title), ["Codex Weekly usage limit", "Codex Critical"])
        XCTAssertEqual(first.activeAlertIDs, ["usage.codex.personal.weekly-usage-limit", "severity.codex.personal"])
        XCTAssertTrue(repeated.notifications.isEmpty)
    }

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
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = CursorWebAuthService(
            session: session,
            pollIntervalNanoseconds: 1,
            maxPollAttempts: 1
        )

        MockURLProtocol.handler = { request in
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
            MockURLProtocol.handler = nil
        }

        var presentedURL: URL?
        let result = try await service.signIn { url in
            presentedURL = url
        }
        let authURL = try XCTUnwrap(presentedURL)
        let authComponents = try XCTUnwrap(URLComponents(url: authURL, resolvingAgainstBaseURL: false))

        XCTAssertEqual(authComponents.host, "cursor.com")
        XCTAssertEqual(result.accessToken, "cursor-access")
        XCTAssertEqual(result.refreshToken, "cursor-refresh")
        XCTAssertTrue(result.storedCredential.contains(#""accessToken": "cursor-access""#))
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
        configuration.protocolClasses = [MockURLProtocol.self]
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
        MockURLProtocol.handler = { request in
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
            MockURLProtocol.handler = nil
        }

        let total = try await provider.resolveOrganizationAllotment(
            configuration: accountConfiguration,
            accessToken: "github-token",
            date: Date(timeIntervalSince1970: 1_783_667_520)
        )

        XCTAssertEqual(total, 350000)
    }

    func testOpenRouterCreditsParserCalculatesBalance() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let configuration = ProviderAccountConfiguration(
            providerID: .openRouter,
            accountLabel: "OpenRouter API",
            authMethod: .apiKey
        )
        let payload = """
        {
          "data": {
            "total_credits": 25.5,
            "total_usage": 7.25
          }
        }
        """

        let result = try XCTUnwrap(OpenRouterUsageProvider.parseCredits(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.providerID, .openRouter)
        XCTAssertEqual(result.title, "OpenRouter API")
        XCTAssertEqual(result.subtitle, "Credit balance")
        XCTAssertEqual(result.creditsRemaining, 18.25)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenRouterCreditsParserRejectsMissingCreditFields() throws {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)
        let payload = """
        {
          "data": {
            "usage": 7.25
          }
        }
        """

        let result = OpenRouterUsageProvider.parseCredits(
            Data(payload.utf8),
            configuration: configuration
        )

        XCTAssertNil(result)
    }

    func testOpenRouterProviderFetchesKeyBalance() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)
        try secretStore.saveSecret("Bearer sk-or-test", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenRouterUsageProvider(secretStore: secretStore, session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/credits")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-or-test")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Title"), "CodexBar")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"data":{"total_credits":100,"total_usage":12.34}}"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openRouter)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 87.66, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenRouterNormalizesPastedAuthorizationHeader() {
        XCTAssertEqual(
            OpenRouterUsageProvider.normalizedAPIKey(from: "Authorization: Bearer sk-or-test"),
            "sk-or-test"
        )
        XCTAssertEqual(
            OpenRouterUsageProvider.normalizedAPIKey(from: "\"sk-or-quoted\""),
            "sk-or-quoted"
        )
    }

    func testOpenRouterProviderWithoutCredentialIsNotDemoData() async throws {
        let provider = OpenRouterUsageProvider(secretStore: EmptySecretStore())
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openRouter)
        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.subtitle, "Not configured - enter API key.")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenBalanceParserReadsJSONBalance() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.accountLabel = "OpenCode ZEN API"
        let payload = """
        {
          "data": {
            "balance": 42.5,
            "currency": "USD"
          }
        }
        """

        let result = try XCTUnwrap(OpenCodeZenUsageProvider.parseBalance(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.title, "OpenCode ZEN API")
        XCTAssertEqual(result.subtitle, "Credit balance")
        XCTAssertEqual(result.creditsRemaining, 42.5)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenBalanceParserReadsDashboardNanodollarBalance() throws {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        let payload = #"initial:{balance:1250000000,credits:[]}"#

        let result = try XCTUnwrap(OpenCodeZenUsageProvider.parseBalance(
            Data(payload.utf8),
            configuration: configuration
        ))

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 12.5, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenBalanceParserReadsQuotedDashboardBalance() throws {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        let payload = #"<script>data={"balance":875000000,"reloadAmount":20}</script>"#

        let result = try XCTUnwrap(OpenCodeZenUsageProvider.parseBalance(
            Data(payload.utf8),
            configuration: configuration
        ))

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 8.75, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenProviderFetchesDashboardBillingBalance() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret(
            "opencode-dashboard-token",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)
        var requestCount = 0

        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "opencode.ai")
            XCTAssertEqual(request.url?.path, "/workspace/wrk_test/billing")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=opencode-dashboard-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/html")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )!,
                Data(#"<html>data balance:2575000000 more</html>"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 25.75, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(requestCount, 1)
    }

    func testOpenCodeZenProviderExplainsModelAPIKeyCannotFetchBalanceAfterDashboardRejectsIt() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret(
            "sk-opencode-model-key",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=sk-opencode-model-key")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"<html><title>OpenAuth</title></html>"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.subtitle, "OpenCode ZEN API keys are valid for models, but OpenCode does not expose balance to API keys.")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenProviderReadsWindowsSettingsJSONCredentialAndWorkspace() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = ""
        let windowsSettings = """
        {
          "openCodeGoWorkspaceId": "wrk_from_windows",
          "providers": {
            "OpenCodeGo": {
              "enabled": true,
              "apiKey": "go-dashboard-token"
            },
            "OpenCodeZen": {
              "enabled": true
            }
          }
        }
        """
        try secretStore.saveSecret(
            windowsSettings,
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/workspace/wrk_from_windows/billing")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=go-dashboard-token")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"<html>balance:625000000</html>"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 6.25, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterStoresWindowsSettingsJSON() throws {
        let suiteName = "OpenCodeZenBootstrapImporter-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let secretStore = MemorySecretStore()
        let configurationStore = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let payload = """
        {
          "openCodeGoWorkspaceId": "wrk_from_windows",
          "providers": {
            "OpenCodeGo": {
              "apiKey": "go-dashboard-token"
            }
          }
        }
        """

        XCTAssertTrue(OpenCodeZenBootstrapImporter.importPayload(payload, configurationStore: configurationStore))

        let configuration = try XCTUnwrap(configurationStore.configurations(for: .openCodeZen).first)
        XCTAssertEqual(configuration.openCodeWorkspaceId, "wrk_from_windows")
        XCTAssertEqual(configuration.accountLabel, "OpenCode ZEN")
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration)),
            "go-dashboard-token"
        )
    }

    func testOpenCodeZenProviderNormalizesAuthHeaderBeforeDashboardRequest() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret(
            "Authorization: Bearer opencode-dashboard-token",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)
        var requestCount = 0

        MockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.absoluteString, "https://opencode.ai/workspace/wrk_test/billing")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=opencode-dashboard-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "text/html")
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "User-Agent"),
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Gecko/20100101 Firefox/148.0"
            )
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"<html>data balance:2575000000 more</html>"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 25.75, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(requestCount, 1)
    }

    func testOpenCodeZenProviderReportsRejectedCredential() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret("bad-balance-credential", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)

        MockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.subtitle, "OpenCode ZEN rejected this API key.")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenProviderExplainsOpenCodeSignInPage() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret("auth=opencode-dashboard-token", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=opencode-dashboard-token")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"<html><title>OpenAuth</title></html>"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.subtitle, "OpenCode returned the sign-in page. Refresh the saved dashboard auth value.")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenNormalizesPastedBalanceCredential() {
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: "Authorization: Bearer oczen-test-key"),
            "oczen-test-key"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: "\"quoted-key\""),
            "quoted-key"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: "auth=oczen-legacy-shaped-key; other=value"),
            "oczen-legacy-shaped-key"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: "Cookie: other=value; auth=oczen-cookie"),
            "oczen-cookie"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: "Set-Cookie: auth=oczen-cookie; Path=/; HttpOnly"),
            "oczen-cookie"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedWorkspaceId(from: "https://opencode.ai/workspace/wrk_test/billing"),
            "wrk_test"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedBalanceCredential(from: #"OPENCODE_GO_AUTH_COOKIE="go-dashboard-token""#),
            "go-dashboard-token"
        )
        XCTAssertEqual(
            OpenCodeZenUsageProvider.normalizedWorkspaceId(from: "OPENCODE_GO_WORKSPACE_ID=wrk_env"),
            "wrk_env"
        )
    }

    func testOpenCodeZenProviderWithoutWorkspaceIsNotConfigured() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        try secretStore.saveSecret("oczen-test-key", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let provider = OpenCodeZenUsageProvider(secretStore: secretStore)

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.subtitle, "Not configured - enter OpenCode workspace ID.")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testOpenCodeZenProviderWithoutCredentialIsNotDemoData() async throws {
        let provider = OpenCodeZenUsageProvider(secretStore: EmptySecretStore())
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        configuration.openCodeWorkspaceId = "wrk_test"

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.subtitle, "Not configured - enter OpenCode dashboard auth value.")
        XCTAssertNil(result.creditsRemaining)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testCursorNormalizesPastedAuthJSONAndBearerHeader() {
        XCTAssertEqual(
            CursorUsageProvider.normalizedAccessToken(from: #"{"accessToken":"cursor-token","refreshToken":"refresh"}"#),
            "cursor-token"
        )
        XCTAssertEqual(
            CursorUsageProvider.normalizedAccessToken(from: "Authorization: Bearer cursor-token"),
            "cursor-token"
        )
        XCTAssertEqual(
            CursorUsageProvider.normalizedAccessToken(from: "\"cursor-quoted\""),
            "cursor-quoted"
        )
    }

    func testCursorUsageParserReadsDashboardUsage() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)
        configuration.accountLabel = "Cursor Pro"
        let payload = """
        {
          "billingCycleEnd": "1784332800000",
          "planUsage": {
            "autoPercentUsed": 42.4,
            "apiPercentUsed": 18.2,
            "totalPercentUsed": 62.6
          },
          "spendLimitUsage": {
            "individualLimit": 2000,
            "individualRemaining": 800
          }
        }
        """

        let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.providerID, .cursor)
        XCTAssertEqual(result.title, "Cursor Pro")
        XCTAssertEqual(result.subtitle, "Included usage - Auto 42% - API 18%")
        XCTAssertEqual(result.bars.map(\.label), [
            "Total",
            "Auto",
            "API",
            "On-demand $12.00 / $20.00",
        ])
        XCTAssertEqual(result.bars.map(\.usageText), ["63%", "42%", "18%", "60%"])
    }

    func testCursorProviderFetchesDashboardUsage() async throws {
        let secretStore = MemorySecretStore()
        var configuration = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)
        configuration.accountLabel = "Cursor"
        try secretStore.saveSecret(
            #"{"accessToken":"cursor-token"}"#,
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = CursorUsageProvider(secretStore: secretStore, session: session)

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer cursor-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Connect-Protocol-Version"), "1")
            XCTAssertEqual(requestBodyData(from: request), Data("{}".utf8))
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"planUsage":{"totalPercentUsed":25,"autoPercentUsed":10,"apiPercentUsed":5}}"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .cursor)
        XCTAssertEqual(result.title, "Cursor")
        XCTAssertEqual(result.bars.map(\.label), ["Total", "Auto", "API"])
        XCTAssertEqual(result.bars.first?.usageText, "25%")
    }

    func testCursorProviderWithoutCredentialIsNotDemoData() async throws {
        let provider = CursorUsageProvider(secretStore: EmptySecretStore())
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .cursor)

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .cursor)
        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.subtitle, "Not configured - sign in with Cursor.")
        XCTAssertTrue(result.bars.isEmpty)
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

    func testClaudeUsageParserReadsOAuthUsageWindows() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let payload = """
        {
          "five_hour": {
            "utilization": 0.42,
            "resets_at": "2030-01-01T00:00:00Z"
          },
          "seven_day": {
            "utilization": 0.81,
            "resets_at": "2030-01-08T00:00:00Z"
          }
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "pro",
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.providerID, .claude)
        XCTAssertEqual(result.title, "Claude (Pro)")
        XCTAssertEqual(result.bars.map(\.label), ["5 hour usage limit", "Weekly usage limit"])
        XCTAssertEqual(result.bars.map(\.used), [42, 81])
        XCTAssertEqual(result.bars.map(\.usageText), ["42%", "81%"])
        XCTAssertEqual(result.bars.first?.projectionCurrent, 0.42)
        XCTAssertEqual(result.bars.first?.projectionLimit, 1)
        XCTAssertEqual(result.bars.first?.projectionPeriodStart, Date(timeIntervalSince1970: 1_893_438_000))
        XCTAssertEqual(result.bars.first?.projectionPeriodEnd, Date(timeIntervalSince1970: 1_893_456_000))
    }

    func testClaudeUsageParserReadsRateLimitHeaders() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let result = try XCTUnwrap(ClaudeUsageParser.parseRateLimitHeaders(
            [
                "anthropic-ratelimit-unified-5h-utilization": "0.25",
                "anthropic-ratelimit-unified-5h-reset": "1893456000"
            ],
            subscriptionType: "max",
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.title, "Claude (Max)")
        XCTAssertEqual(result.bars.map(\.label), ["5 hour usage limit"])
        XCTAssertEqual(result.bars.first?.used, 25)
        XCTAssertEqual(result.bars.first?.projectionCurrent, 0.25)
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
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .codex)
        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.subtitle, "Not configured - sign in with ChatGPT.")
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testClaudeUsageWithoutCredentialIsNotDemoData() async throws {
        let provider = ClaudeUsageProvider(secretStore: EmptySecretStore())
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .claude)
        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.subtitle, "Not configured - sign in with Claude.")
        XCTAssertTrue(result.bars.isEmpty)
    }

    @MainActor
    func testDemoRefreshReturnsSortedResults() async {
        let service = UsageRefreshService.demo()

        await service.refresh()

        XCTAssertEqual(
            service.results.map(\.providerID),
            [.codex, .copilot, .openCodeZen, .openRouter]
        )
        XCTAssertFalse(service.isRefreshing)
        XCTAssertNil(service.lastRefreshError)
    }

    @MainActor
    func testLiveRefreshIncludesOpenRouterProvider() async throws {
        let secretStore = MemorySecretStore()
        var openRouter = ProviderAccountConfiguration.defaultConfiguration(for: .openRouter)
        openRouter.accountLabel = "OpenRouter API"
        try secretStore.saveSecret("sk-or-test", account: ProviderConfigurationStore.keychainAccount(for: openRouter))

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = UsageRefreshService(providers: [
            OpenRouterUsageProvider(secretStore: secretStore, session: session)
        ])

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/credits")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"data":{"total_credits":10,"total_usage":2.5}}"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        await service.refresh(configurations: [openRouter])

        let result = try XCTUnwrap(service.results.first)
        XCTAssertEqual(result.providerID, .openRouter)
        XCTAssertEqual(result.title, "OpenRouter API")
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 7.5, accuracy: 0.0001)
    }

    @MainActor
    func testSingleAccountRefreshUpdatesOnlyRequestedProvider() async throws {
        let secretStore = MemorySecretStore()
        var openCode = ProviderAccountConfiguration.defaultConfiguration(for: .openCodeZen)
        openCode.accountLabel = "OpenCode ZEN"
        openCode.openCodeWorkspaceId = "wrk_test"
        try secretStore.saveSecret(
            "opencode-dashboard-token",
            account: ProviderConfigurationStore.keychainAccount(for: openCode)
        )

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let service = UsageRefreshService(providers: [
            OpenCodeZenUsageProvider(secretStore: secretStore, session: session),
            HangingUsageProvider(providerID: .openRouter),
        ])

        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/workspace/wrk_test/billing")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=opencode-dashboard-token")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "text/html"]
                )!,
                Data(#"<html>balance:1225000000</html>"#.utf8)
            )
        }
        defer {
            MockURLProtocol.handler = nil
        }

        let refreshedResult = await service.refresh(configuration: openCode)
        let result = try XCTUnwrap(refreshedResult)

        XCTAssertEqual(result.providerID, .openCodeZen)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 12.25, accuracy: 0.0001)
        XCTAssertEqual(service.results.map(\.accountID), [openCode.id])
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

private final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private var secrets: [String: String] = [:]

    func readSecret(account: String) throws -> String? {
        secrets[account]
    }

    func saveSecret(_ secret: String, account: String) throws {
        secrets[account] = secret
    }

    func deleteSecret(account: String) throws {
        secrets.removeValue(forKey: account)
    }
}

private func requestBodyData(from request: URLRequest) -> Data? {
    if let body = request.httpBody {
        return body
    }

    guard let stream = request.httpBodyStream else {
        return nil
    }

    stream.open()
    defer {
        stream.close()
    }

    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable {
        let byteCount = stream.read(&buffer, maxLength: buffer.count)
        guard byteCount > 0 else {
            break
        }
        data.append(contentsOf: buffer.prefix(byteCount))
    }
    return data
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private struct HangingUsageProvider: UsageProvider {
    let providerID: ProviderID

    func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        try await Task.sleep(for: .seconds(60))
        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: providerID,
            title: providerID.displayName,
            subtitle: "Unexpected",
            bars: [],
            fetchedAt: Date()
        )
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
