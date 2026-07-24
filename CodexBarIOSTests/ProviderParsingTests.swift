import XCTest
@testable import CodexBarIOS

final class ProviderParsingTests: XCTestCase {
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
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenRouterUsageProvider(secretStore: secretStore, session: session)

        ProviderParsingMockURLProtocol.handler = { request in
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
            ProviderParsingMockURLProtocol.handler = nil
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

    func testMoonshotBalanceParserReadsAvailableBalance() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let configuration = ProviderAccountConfiguration(
            providerID: .moonshot,
            accountLabel: "Moonshot API",
            authMethod: .apiKey
        )
        let payload = """
        {
          "code": 0,
          "data": {
            "available_balance": 49.58894,
            "voucher_balance": 46.58893,
            "cash_balance": 3.00001
          },
          "scode": "0x0",
          "status": true
        }
        """

        let result = try XCTUnwrap(MoonshotUsageProvider.parseBalance(
            Data(payload.utf8),
            configuration: configuration,
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.providerID, .moonshot)
        XCTAssertEqual(result.title, "Moonshot API")
        XCTAssertEqual(result.subtitle, "Credit balance")
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 49.58894, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(result.fetchedAt, fetchedAt)
    }

    func testMoonshotBalanceParserRejectsMissingBalance() throws {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .moonshot)
        let payload = """
        {
          "code": 0,
          "data": {
            "voucher_balance": 46.58893
          },
          "status": true
        }
        """

        let result = MoonshotUsageProvider.parseBalance(
            Data(payload.utf8),
            configuration: configuration
        )

        XCTAssertNil(result)
    }

    func testMoonshotProviderFetchesBalance() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .moonshot)
        try secretStore.saveSecret("Bearer sk-moonshot-test", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = MoonshotUsageProvider(secretStore: secretStore, session: session)

        ProviderParsingMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.moonshot.ai/v1/users/me/balance")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-moonshot-test")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"code":0,"data":{"available_balance":37.5,"voucher_balance":30,"cash_balance":7.5},"scode":"0x0","status":true}"#.utf8)
            )
        }
        defer {
            ProviderParsingMockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .moonshot)
        XCTAssertEqual(try XCTUnwrap(result.creditsRemaining), 37.5, accuracy: 0.0001)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testMoonshotProviderRejectsInvalidKey() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .moonshot)
        try secretStore.saveSecret("sk-moonshot-bad", account: ProviderConfigurationStore.keychainAccount(for: configuration))

        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = MoonshotUsageProvider(secretStore: secretStore, session: session)

        ProviderParsingMockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"error":{"message":"Invalid API key"}}"#.utf8)
            )
        }
        defer {
            ProviderParsingMockURLProtocol.handler = nil
        }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .moonshot)
        XCTAssertEqual(result.failureMessage, "Moonshot rejected this API key.")
        XCTAssertNil(result.creditsRemaining)
    }

    func testMoonshotNormalizesPastedAuthorizationHeader() {
        XCTAssertEqual(
            MoonshotUsageProvider.normalizedAPIKey(from: "Authorization: Bearer sk-moonshot-test"),
            "sk-moonshot-test"
        )
        XCTAssertEqual(
            MoonshotUsageProvider.normalizedAPIKey(from: "\"sk-moonshot-quoted\""),
            "sk-moonshot-quoted"
        )
    }

    func testMoonshotProviderWithoutCredentialIsNotConfigured() async throws {
        let provider = MoonshotUsageProvider(secretStore: EmptySecretStore())
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .moonshot)

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .moonshot)
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
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)
        var requestCount = 0

        ProviderParsingMockURLProtocol.handler = { request in
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
            ProviderParsingMockURLProtocol.handler = nil
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
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)

        ProviderParsingMockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=sk-opencode-model-key")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"<html><title>OpenAuth</title></html>"#.utf8)
            )
        }
        defer {
            ProviderParsingMockURLProtocol.handler = nil
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
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)

        ProviderParsingMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/workspace/wrk_from_windows/billing")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "auth=go-dashboard-token")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"<html>balance:625000000</html>"#.utf8)
            )
        }
        defer {
            ProviderParsingMockURLProtocol.handler = nil
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

    @MainActor
    func testOpenCodeZenBootstrapImporterAppliesCompleteFileProtection() throws {
        let fileManager = RecordingFileProtectionManager()
        let importURL = URL(fileURLWithPath: "/tmp/\(OpenCodeZenBootstrapImporter.importFileName)")

        XCTAssertTrue(
            OpenCodeZenBootstrapImporter.protectImportFile(at: importURL, fileManager: fileManager)
        )
        XCTAssertEqual(fileManager.recordedPath, importURL.path)
        XCTAssertEqual(
            fileManager.recordedAttributes?[.protectionKey] as? FileProtectionType,
            .complete
        )
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterProtectsImportsAndRemovesStagingFile() throws {
        let suiteName = "OpenCodeZenBootstrapProtectedImport-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fileManager = FileManager.default
        let importDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("OpenCodeZenBootstrapImport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: importDirectory)
        }

        let importURL = importDirectory.appendingPathComponent(OpenCodeZenBootstrapImporter.importFileName)
        let payload = """
        {
          "openCodeGoWorkspaceId": "wrk_protected",
          "providers": {
            "OpenCodeGo": {
              "apiKey": "protected-dashboard-token"
            }
          }
        }
        """
        try Data(payload.utf8).write(to: importURL)

        let secretStore = MemorySecretStore()
        let configurationStore = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        OpenCodeZenBootstrapImporter.importIfNeeded(
            configurationStore: configurationStore,
            fileManager: fileManager,
            importDirectory: importDirectory
        )

        XCTAssertFalse(fileManager.fileExists(atPath: importURL.path))
        let configuration = try XCTUnwrap(configurationStore.configurations(for: .openCodeZen).first)
        XCTAssertEqual(configuration.openCodeWorkspaceId, "wrk_protected")
        XCTAssertEqual(
            try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration)),
            "protected-dashboard-token"
        )
    }

    @MainActor
    func testOpenCodeZenBootstrapImporterDeletesFileWithoutReadingWhenProtectionFails() throws {
        let suiteName = "OpenCodeZenBootstrapProtectionFailure-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }

        let fileManager = RecordingFileProtectionManager()
        fileManager.shouldFail = true
        let importDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("OpenCodeZenBootstrapFailure-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: importDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: importDirectory)
        }

        let importURL = importDirectory.appendingPathComponent(OpenCodeZenBootstrapImporter.importFileName)
        try Data(#"{"openCodeGoWorkspaceId":"wrk_secret","providers":{"OpenCodeGo":{"apiKey":"secret-token"}}}"#.utf8)
            .write(to: importURL)

        let configurationStore = ProviderConfigurationStore(
            defaults: defaults,
            secretStore: MemorySecretStore()
        )
        OpenCodeZenBootstrapImporter.importIfNeeded(
            configurationStore: configurationStore,
            fileManager: fileManager,
            importDirectory: importDirectory
        )

        XCTAssertFalse(fileManager.fileExists(atPath: importURL.path))
        XCTAssertTrue(configurationStore.configurations(for: .openCodeZen).isEmpty)
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
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)
        var requestCount = 0

        ProviderParsingMockURLProtocol.handler = { request in
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
            ProviderParsingMockURLProtocol.handler = nil
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
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)

        ProviderParsingMockURLProtocol.handler = { request in
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
            ProviderParsingMockURLProtocol.handler = nil
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
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = OpenCodeZenUsageProvider(secretStore: secretStore, session: session)

        ProviderParsingMockURLProtocol.handler = { request in
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
            ProviderParsingMockURLProtocol.handler = nil
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
          "billingCycleStart": "1783036800000",
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
        XCTAssertTrue(result.bars.allSatisfy(\.showProjectionOnCurrentBar))
        XCTAssertEqual(
            result.bars.compactMap(\.projectionPeriodStart),
            Array(repeating: Date(timeIntervalSince1970: 1_783_036_800), count: 4)
        )
        XCTAssertEqual(
            result.bars.compactMap(\.projectionPeriodEnd),
            Array(repeating: Date(timeIntervalSince1970: 1_784_332_800), count: 4)
        )
        XCTAssertEqual(try XCTUnwrap(result.bars[0].projectionCurrent), 0.626, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(result.bars[1].projectionCurrent), 0.424, accuracy: 0.000_001)
        XCTAssertEqual(try XCTUnwrap(result.bars[2].projectionCurrent), 0.182, accuracy: 0.000_001)
        XCTAssertEqual(result.bars[3].projectionCurrent, 1_200)
        XCTAssertEqual(result.bars.compactMap(\.projectionLimit), [1, 1, 1, 2_000])
        XCTAssertTrue(try XCTUnwrap(result.bars[0].projectionDescription(at: fetchedAt)).hasPrefix(
            "Projected 100% at current pace - Limit hit "
        ))
        XCTAssertEqual(result.bars[2].projectionDescription(at: fetchedAt), "Projected to stay under limit")
        XCTAssertTrue(try XCTUnwrap(result.bars[3].projectionDescription(at: fetchedAt)).hasPrefix(
            "Projected 100% at current pace - Limit hit "
        ))
    }

    func testCursorUsageParserSuppressesPredictionsWithoutValidCurrentBillingPeriod() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_783_667_520)
        let invalidPeriods = [
            #""billingCycleEnd": "1784332800000","#,
            #""billingCycleStart": "invalid", "billingCycleEnd": "1784332800000","#,
            #""billingCycleStart": "1784332800000", "billingCycleEnd": "1781740800000","#,
            #""billingCycleStart": "1784332800000", "billingCycleEnd": "1786924800000","#,
        ]

        for periodFields in invalidPeriods {
            let payload = """
            {
              \(periodFields)
              "planUsage": {
                "autoPercentUsed": 10,
                "apiPercentUsed": 5,
                "totalPercentUsed": 25
              },
              "spendLimitUsage": {
                "individualLimit": 2000,
                "individualRemaining": 1500
              }
            }
            """

            let result = try XCTUnwrap(CursorUsageProvider.parseUsage(
                Data(payload.utf8),
                configuration: .defaultConfiguration(for: .cursor),
                fetchedAt: fetchedAt
            ))

            XCTAssertEqual(result.bars.count, 4)
            XCTAssertTrue(result.bars.allSatisfy { !$0.showProjectionOnCurrentBar })
            XCTAssertTrue(result.bars.allSatisfy { $0.projectionDescription(at: fetchedAt) == nil })
        }
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
        urlSessionConfiguration.protocolClasses = [ProviderParsingMockURLProtocol.self]
        let session = URLSession(configuration: urlSessionConfiguration)
        let provider = CursorUsageProvider(secretStore: secretStore, session: session)

        ProviderParsingMockURLProtocol.handler = { request in
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
            ProviderParsingMockURLProtocol.handler = nil
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
        let formatter = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Berlin")),
            locale: Locale(identifier: "en_US")
        )
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

        let result = try XCTUnwrap(CodexUsageParser.parse(
            Data(payload.utf8),
            fetchedAt: fetchedAt,
            dateTimeFormatter: formatter
        ))

        XCTAssertEqual(result.title, "ChatGPT / Codex (Pro)")
        XCTAssertEqual(result.bars.map(\.label), ["5 hour usage limit", "Weekly usage limit"])
        XCTAssertEqual(result.bars.map(\.used), [42, 81])
        XCTAssertEqual(result.bars.map(\.usageText), ["42%", "81%"])
        XCTAssertTrue(result.usageMessages.isEmpty)
        let resetDescription = try XCTUnwrap(result.bars.first?.resetDescription)
        XCTAssertTrue(resetDescription.hasPrefix("Resets 1d 0h (Tue 1:00"))
        XCTAssertTrue(resetDescription.hasSuffix("GMT+1)"))
        let newYorkFormatter = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "America/New_York")),
            locale: Locale(identifier: "en_US")
        )
        let reformattedReset = try XCTUnwrap(result.bars.first?.localizedResetDescription(
            at: fetchedAt,
            dateTimeFormatter: newYorkFormatter
        ))
        XCTAssertTrue(reformattedReset.hasSuffix("EST)"))
        XCTAssertFalse(reformattedReset.contains("GMT+1"))
        XCTAssertEqual(result.bars.first?.projectionCurrent, 0.42)
        XCTAssertEqual(result.bars.first?.projectionLimit, 1)
        XCTAssertEqual(result.bars.first?.projectionPeriodStart, Date(timeIntervalSince1970: 1_893_438_000))
        XCTAssertEqual(result.bars.first?.projectionPeriodEnd, Date(timeIntervalSince1970: 1_893_456_000))

    }

    func testCodexUsageParserReadsBankedResetCountsDefensively() throws {
        func parse(_ resetCreditsJSON: String?) -> CodexBankedRateLimitResets? {
            let resetCredits = resetCreditsJSON.map { ",\"rate_limit_reset_credits\":\($0)" } ?? ""
            let payload = """
            {
              "rate_limit": {
                "primary_window": {
                  "used_percent": 25,
                  "reset_at": 1893456000,
                  "limit_window_seconds": 18000
                }
              }
              \(resetCredits)
            }
            """
            return CodexUsageParser.parse(Data(payload.utf8))?.codexBankedRateLimitResets
        }

        XCTAssertNil(parse(nil))
        XCTAssertNil(parse("null"))
        XCTAssertNil(parse(#"{"available_count":0}"#))
        XCTAssertNil(parse(#"{"available_count":-1}"#))
        XCTAssertNil(parse(#"{"available_count":1.5}"#))
        XCTAssertNil(parse(#"{"available_count":"2"}"#))
        XCTAssertEqual(parse(#"{"available_count":1}"#)?.availableCount, 1)
        XCTAssertEqual(parse(#"{"available_count":3}"#)?.availableCount, 3)
        XCTAssertFalse(try XCTUnwrap(parse(#"{"available_count":1}"#)).canConsume)
    }

    func testCodexUsageParserReadsDetailedAndCountOnlyResetCredits() throws {
        let detailed = try XCTUnwrap(CodexUsageParser.parseResetCredits(
            Data("""
            {
              "available_count":2,
              "credits":[
                {
                  "id":"credit-1",
                  "status":"available",
                  "title":"Full reset (Weekly + 5 hr)",
                  "description":"Ready to redeem",
                  "expires_at":"2030-01-02T03:04:05Z"
                },
                {"id":"credit-used","status":"redeemed","title":"Do not show"}
              ]
            }
            """.utf8),
            canConsume: true
        ))

        XCTAssertEqual(detailed.availableCount, 2)
        XCTAssertTrue(detailed.canConsume)
        XCTAssertEqual(detailed.credits?.map(\.id), ["credit-1"])
        XCTAssertEqual(detailed.preferredCredit?.title, "Full reset (Weekly + 5 hr)")
        XCTAssertEqual(
            detailed.preferredCredit?.expiresAt,
            ISO8601DateFormatter().date(from: "2030-01-02T03:04:05Z")
        )

        let countOnly = try XCTUnwrap(CodexUsageParser.parseResetCredits(
            Data(#"{"available_count":4}"#.utf8),
            canConsume: true
        ))
        XCTAssertEqual(countOnly.availableCount, 4)
        XCTAssertNil(countOnly.credits)
        XCTAssertTrue(countOnly.canConsume)
    }

    func testCodexUsageParserSilentlyAcceptsMissingFiveHourWindowAndDurationDrift() throws {
        let weeklyOnlyPayload = #"{"plan_type":"prolite","rate_limit":{"primary_window":{"used_percent":30,"reset_at":1894060800,"limit_window_seconds":604800},"secondary_window":null}}"#
        let weeklyOnly = try XCTUnwrap(CodexUsageParser.parse(Data(weeklyOnlyPayload.utf8)))

        XCTAssertEqual(weeklyOnly.bars.map(\.label), ["Weekly usage limit"])
        XCTAssertTrue(weeklyOnly.usageMessages.isEmpty)

        let driftedPayload = #"{"rate_limit":{"primary_window":{"used_percent":20,"reset_at":1894060800,"limit_window_seconds":604800},"secondary_window":{"used_percent":10,"reset_at":1893456000,"limit_window_seconds":17999}}}"#
        let drifted = try XCTUnwrap(CodexUsageParser.parse(Data(driftedPayload.utf8)))

        XCTAssertEqual(drifted.bars.map(\.label), ["5 hour usage limit", "Weekly usage limit"])
        XCTAssertEqual(
            drifted.bars.enumerated().map {
                $0.element.metricIdentifier(providerID: .codex, index: $0.offset)
            },
            ["codex.window-18000", "codex.window-604800"]
        )
        XCTAssertTrue(drifted.usageMessages.isEmpty)

        let outsideTolerancePayload = #"{"rate_limit":{"primary_window":{"used_percent":10,"reset_at":1893456000,"limit_window_seconds":18901}}}"#
        let outsideTolerance = try XCTUnwrap(CodexUsageParser.parse(Data(outsideTolerancePayload.utf8)))

        XCTAssertEqual(outsideTolerance.bars.map(\.label), ["315 minute usage limit"])
        XCTAssertEqual(
            outsideTolerance.bars.first?.metricIdentifier(providerID: .codex, index: 0),
            "codex.window-18901"
        )
        XCTAssertTrue(outsideTolerance.usageMessages.isEmpty)
    }

    func testClaudeUsageParserReadsOAuthUsageWindows() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let formatter = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Berlin")),
            locale: Locale(identifier: "de_DE")
        )
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
            fetchedAt: fetchedAt,
            dateTimeFormatter: formatter
        ))

        XCTAssertEqual(result.providerID, .claude)
        XCTAssertEqual(result.title, "Claude (Pro)")
        XCTAssertEqual(result.bars.map(\.label), ["5 hour usage limit", "Weekly usage limit"])
        XCTAssertEqual(result.bars.map(\.used), [42, 81])
        XCTAssertEqual(result.bars.map(\.usageText), ["42%", "81%"])
        let resetDescription = try XCTUnwrap(result.bars.first?.resetDescription)
        XCTAssertTrue(resetDescription.contains("Di. 01:00"))
        XCTAssertTrue(resetDescription.hasSuffix("GMT+1)"))
        XCTAssertEqual(result.bars.first?.projectionCurrent, 0.42)
        XCTAssertEqual(result.bars.first?.projectionLimit, 1)
        XCTAssertEqual(result.bars.first?.projectionPeriodStart, Date(timeIntervalSince1970: 1_893_438_000))
        XCTAssertEqual(result.bars.first?.projectionPeriodEnd, Date(timeIntervalSince1970: 1_893_456_000))

        let percentagePayload = #"{"five_hour":{"utilization":15},"seven_day":{"utilization":36}}"#
        let percentageResult = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(percentagePayload.utf8),
            subscriptionType: "pro"
        ))
        XCTAssertEqual(percentageResult.bars.map(\.used), [15, 36])

        let onePercentResult = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"five_hour":{"utilization":1}}"#.utf8),
            subscriptionType: "pro"
        ))
        XCTAssertEqual(onePercentResult.bars.first?.used, 1)
    }

    func testClaudeUsageParserPreservesScopedFiveHourLimits() throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let payload = """
        {
          "five_hour": {"utilization": 0.99, "resets_at": "2030-01-01T06:00:00Z"},
          "limits": [
            {"kind":"session","percent":27,"resets_at":"2030-01-01T02:00:00Z","is_active":true},
            {"kind":"session","percent":64,"resets_at":"2030-01-01T04:00:00Z","scope":{"model":{"display_name":"Fable"}},"is_active":true},
            {"kind":"session","percent":91,"scope":{"model":{"display_name":"Fable"}},"is_active":true}
          ]
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "max",
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(result.bars.map(\.label), [
            "Other models 5 hour usage limit",
            "Fable 5 hour usage limit",
        ])
        XCTAssertEqual(result.bars.map(\.used), [27, 64])
        XCTAssertEqual(
            result.bars.map(\.resetsAt),
            [
                ISO8601DateFormatter().date(from: "2030-01-01T02:00:00Z"),
                ISO8601DateFormatter().date(from: "2030-01-01T04:00:00Z"),
            ]
        )
        XCTAssertEqual(
            result.bars.map(\.projectionPeriodStart),
            [
                ISO8601DateFormatter().date(from: "2029-12-31T21:00:00Z"),
                ISO8601DateFormatter().date(from: "2029-12-31T23:00:00Z"),
            ]
        )

        let legacyAndScopedPayload = """
        {
          "five_hour": {"utilization": 0.31, "resets_at": "2030-01-01T06:00:00Z"},
          "limits": [
            {"kind":"session","percent":44,"resets_at":"2030-01-01T04:00:00Z","scope":{"model":{"display_name":"Fable"}},"is_active":true}
          ]
        }
        """
        let legacyAndScoped = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(legacyAndScopedPayload.utf8),
            subscriptionType: "max",
            fetchedAt: fetchedAt
        ))

        XCTAssertEqual(legacyAndScoped.bars.map(\.label), [
            "Fable 5 hour usage limit",
            "5 hour usage limit",
        ])
        XCTAssertEqual(legacyAndScoped.bars.map(\.used), [44, 31])
        XCTAssertEqual(
            legacyAndScoped.bars.map(\.resetsAt),
            [
                ISO8601DateFormatter().date(from: "2030-01-01T04:00:00Z"),
                ISO8601DateFormatter().date(from: "2030-01-01T06:00:00Z"),
            ]
        )

        let inactiveScopedPayload = """
        {
          "five_hour": {"utilization": 0.25},
          "limits": [
            {"kind":"session","percent":80,"scope":{"model":{"display_name":"Fable"}},"is_active":false}
          ]
        }
        """
        let inactiveScoped = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(inactiveScopedPayload.utf8),
            subscriptionType: "max",
            fetchedAt: fetchedAt
        ))
        XCTAssertEqual(inactiveScoped.bars.map(\.label), ["5 hour usage limit"])
        XCTAssertEqual(inactiveScoped.bars.map(\.used), [25])
    }

    func testClaudeUsageParserShowsObservedInactiveFableWeeklyLimit() throws {
        let payload = """
        {
          "five_hour": {"utilization":11,"resets_at":"2030-01-01T02:00:00Z"},
          "seven_day": {"utilization":9,"resets_at":"2030-01-08T04:00:00Z"},
          "limits": [
            {"kind":"session","group":"session","percent":11,"resets_at":"2030-01-01T02:00:00Z","scope":null,"is_active":true},
            {"kind":"weekly_all","group":"weekly","percent":9,"resets_at":"2030-01-08T04:00:00Z","scope":null,"is_active":false},
            {"kind":"weekly_scoped","group":"weekly","percent":5,"resets_at":"2030-01-08T04:00:00Z","scope":{"model":{"id":null,"display_name":"Fable"}},"is_active":false}
          ]
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "max"
        ))

        XCTAssertEqual(result.bars.map(\.label), [
            "5 hour usage limit",
            "All models weekly usage limit",
            "Fable weekly usage limit",
        ])
        XCTAssertEqual(result.bars.map(\.used), [11, 9, 5])
        XCTAssertEqual(result.bars.map(\.stableKey), [
            "session",
            "weekly-all",
            "weekly-scoped-fable",
        ])
        XCTAssertEqual(
            result.bars.map(\.resetsAt),
            [
                ISO8601DateFormatter().date(from: "2030-01-01T02:00:00Z"),
                ISO8601DateFormatter().date(from: "2030-01-08T04:00:00Z"),
                ISO8601DateFormatter().date(from: "2030-01-08T04:00:00Z"),
            ]
        )
    }

    func testClaudeUsageParserPrefersActiveDuplicateWeeklyLimit() throws {
        let payload = """
        {
          "limits": [
            {"kind":"weekly_all","group":"monthly","percent":99,"is_active":true},
            {"kind":"weekly_all","group":"weekly","percent":9,"is_active":false},
            {"kind":"weekly_all","group":"weekly","percent":14,"is_active":true}
          ]
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "max"
        ))

        XCTAssertEqual(result.bars.map(\.label), ["Weekly usage limit"])
        XCTAssertEqual(result.bars.map(\.used), [14])
        XCTAssertEqual(result.bars.map(\.stableKey), ["weekly-all"])
    }

    @MainActor
    func testClaudeStructuredScopedWeeklyLimitsPreserveLegacyIdentities() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let payload = """
        {
          "seven_day_sonnet": {"utilization":44},
          "seven_day_opus": {"utilization":32},
          "limits": [
            {"kind":"weekly_scoped","group":"weekly","percent":5,"scope":{"model":{"display_name":"Fable"}},"is_active":false},
            {"kind":"weekly_scoped","group":"weekly","percent":45,"scope":{"model":{"display_name":"Claude Sonnet 4.5"}},"is_active":false},
            {"kind":"weekly_scoped","group":"weekly","percent":33,"scope":{"model":{"display_name":"Claude Opus 4.1"}},"is_active":false}
          ]
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "max"
        ))

        XCTAssertEqual(result.bars.map(\.label), [
            "Fable weekly usage limit",
            "Claude Sonnet 4.5 weekly usage limit",
            "Claude Opus 4.1 weekly usage limit",
        ])
        XCTAssertEqual(result.bars.map(\.used), [5, 45, 33])
        XCTAssertEqual(result.bars.map(\.stableKey), [
            "weekly-scoped-fable",
            "sonnet-weekly-limit",
            "opus-weekly-limit",
        ])

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: MemorySecretStore())
        let configuration = store.addAccount(for: .claude)
        store.saveSecret("claude-token", for: configuration)
        let accountResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: result.providerID,
            title: result.title,
            subtitle: result.subtitle,
            bars: result.bars,
            fetchedAt: result.fetchedAt
        )
        let existingAlertIDs: Set<String> = [
            "usage.\(configuration.id).sonnet-weekly-limit",
            "usage.\(configuration.id).opus-weekly-limit",
        ]
        let evaluation = UsageAlertEvaluator.evaluate(
            results: [accountResult],
            settings: UsageAlertSettings(
                isEnabled: true,
                usageThreshold: 0.20,
                includesSeverityAlerts: false
            ),
            activeAlertIDs: existingAlertIDs
        )
        XCTAssertTrue(evaluation.notifications.isEmpty)
        XCTAssertEqual(evaluation.activeAlertIDs, existingAlertIDs)

        WidgetSnapshotPublisher.publish(
            results: [accountResult],
            configurationStore: store,
            snapshotDefaults: defaults
        )
        let snapshot = WidgetSnapshotStore.loadSnapshot(defaults: defaults)
        let widgetProvider = try XCTUnwrap(snapshot.results.first)
        XCTAssertEqual(widgetProvider.bars.map(\.id), [
            "\(configuration.id).0.fable-weekly-usage-limit",
            "\(configuration.id).sonnet-weekly-limit",
            "\(configuration.id).opus-weekly-limit",
        ])
        XCTAssertEqual(
            snapshot.builderTile(
                resolvingSavedID: "bar.\(configuration.id).0.sonnet-weekly-limit"
            )?.title,
            "Claude Sonnet 4.5 weekly usage limit"
        )
        XCTAssertEqual(
            snapshot.builderTile(
                resolvingSavedID: "bar.\(configuration.id).1.opus-weekly-limit"
            )?.title,
            "Claude Opus 4.1 weekly usage limit"
        )
        XCTAssertEqual(
            snapshot.builderTile(
                resolvingSavedID: "bar.\(configuration.id).2.fable-weekly-limit"
            )?.title,
            "Fable weekly usage limit"
        )
    }

    @MainActor
    func testClaudeStructuredScopedWeeklyLimitsKeepModelVersionsDistinct() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let payload = """
        {
          "seven_day_sonnet": {"utilization":55},
          "limits": [
            {"kind":"weekly_scoped","group":"weekly","percent":42,"scope":{"model":{"display_name":"Claude Sonnet 4"}},"is_active":true},
            {"kind":"weekly_scoped","group":"weekly","percent":68,"scope":{"model":{"display_name":"Claude Sonnet 4.5"}},"is_active":true}
          ]
        }
        """
        let parsed = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "max"
        ))
        XCTAssertEqual(parsed.bars.map(\.stableKey), [
            "weekly-scoped-claudesonnet4",
            "weekly-scoped-claudesonnet45",
        ])
        XCTAssertEqual(parsed.bars.map(\.used), [42, 68])

        let store = ProviderConfigurationStore(defaults: defaults, secretStore: MemorySecretStore())
        let configuration = store.addAccount(for: .claude)
        store.saveSecret("claude-token", for: configuration)
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: parsed.providerID,
            title: parsed.title,
            subtitle: parsed.subtitle,
            bars: parsed.bars,
            fetchedAt: parsed.fetchedAt
        )
        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: UsageAlertSettings(
                isEnabled: true,
                usageThreshold: 0.20,
                includesSeverityAlerts: false
            ),
            activeAlertIDs: []
        )
        XCTAssertEqual(evaluation.activeAlertIDs, [
            "usage.\(configuration.id).weekly-scoped-claudesonnet4",
            "usage.\(configuration.id).weekly-scoped-claudesonnet45",
        ])

        WidgetSnapshotPublisher.publish(
            results: [result],
            configurationStore: store,
            snapshotDefaults: defaults
        )
        let widgetBars = try XCTUnwrap(
            WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first
        ).bars
        XCTAssertEqual(Set(widgetBars.map(\.id)).count, 2)
    }

    @MainActor
    func testClaudeWeeklyMetricsRemainDistinctAcrossHistoryWidgetsAndAlerts() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let secretStore = MemorySecretStore()
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let fetchedAt = Date(timeIntervalSince1970: 1_893_369_600)
        let payload = """
        {
          "limits": [
            {"kind":"session","group":"session","percent":27,"resets_at":"2030-01-01T02:00:00Z","is_active":true},
            {"kind":"weekly_all","group":"weekly","percent":64,"resets_at":"2030-01-08T04:00:00Z","is_active":false},
            {"kind":"weekly_scoped","group":"weekly","percent":71,"resets_at":"2030-01-08T06:00:00Z","scope":{"model":{"display_name":"Fable"}},"is_active":false}
          ]
        }
        """
        let parsed = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "max",
            fetchedAt: fetchedAt
        ))
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let configuration = store.addAccount(for: .claude)
        store.saveSecret("claude-token", for: configuration)
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: parsed.providerID,
            title: parsed.title,
            subtitle: parsed.subtitle,
            bars: parsed.bars,
            fetchedAt: parsed.fetchedAt
        )

        let historySnapshot = UsageHistorySnapshot(result: result)
        XCTAssertEqual(historySnapshot.bars.map(\.label), result.bars.map(\.label))
        XCTAssertEqual(Set(historySnapshot.bars.map(\.label)).count, 3)

        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: UsageAlertSettings(
                isEnabled: true,
                usageThreshold: 0.20,
                includesSeverityAlerts: false
            ),
            activeAlertIDs: []
        )
        XCTAssertEqual(evaluation.notifications.count, 3)
        XCTAssertEqual(evaluation.activeAlertIDs, [
            "usage.\(configuration.id).session",
            "usage.\(configuration.id).weekly-usage-limit",
            "usage.\(configuration.id).weekly-scoped-fable",
        ])

        WidgetSnapshotPublisher.publish(
            results: [result],
            configurationStore: store,
            snapshotDefaults: defaults,
            now: fetchedAt
        )
        let widgetProvider = try XCTUnwrap(
            WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first
        )
        XCTAssertEqual(widgetProvider.bars.map(\.label), result.bars.map(\.label))
        XCTAssertEqual(Set(widgetProvider.bars.map(\.id)).count, 3)
        XCTAssertEqual(widgetProvider.bars.map(\.id), [
            "\(configuration.id).0.5-hour-usage-limit",
            "\(configuration.id).weekly-usage-limit",
            "\(configuration.id).2.fable-weekly-usage-limit",
        ])
    }

    func testClaudeScopedAlertKeysPreserveModelVersions() throws {
        let payload = """
        {
          "limits": [
            {"kind":"session","percent":42,"scope":{"model":{"display_name":"Claude Sonnet 4"}},"is_active":true},
            {"kind":"session","percent":68,"scope":{"model":{"display_name":"Claude Sonnet 4.5"}},"is_active":true}
          ]
        }
        """
        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "max"
        ))

        XCTAssertEqual(result.bars.map(\.stableKey), [
            "session-scoped-claudesonnet4",
            "session-scoped-claudesonnet45",
        ])
        let evaluation = UsageAlertEvaluator.evaluate(
            results: [result],
            settings: UsageAlertSettings(
                isEnabled: true,
                usageThreshold: 0.20,
                includesSeverityAlerts: false
            ),
            activeAlertIDs: []
        )
        XCTAssertEqual(evaluation.notifications.count, 2)
        XCTAssertEqual(evaluation.activeAlertIDs, [
            "usage.claude.session-scoped-claudesonnet4",
            "usage.claude.session-scoped-claudesonnet45",
        ])
    }

    func testClaudeUnscopedAlertKeySurvivesScopedLabelChange() throws {
        let unscopedPayload = """
        {"limits":[{"kind":"session","percent":42,"is_active":true}]}
        """
        let scopedPayload = """
        {
          "limits": [
            {"kind":"session","percent":42,"is_active":true},
            {"kind":"session","percent":68,"scope":{"model":{"display_name":"Fable"}},"is_active":true}
          ]
        }
        """
        let legacyPayload = """
        {"five_hour":{"utilization":0.42,"resets_at":"2030-01-01T02:00:00Z"}}
        """
        let unscopedResult = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(unscopedPayload.utf8),
            subscriptionType: "max"
        ))
        let scopedResult = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(scopedPayload.utf8),
            subscriptionType: "max"
        ))
        let legacyResult = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(legacyPayload.utf8),
            subscriptionType: "max"
        ))
        let headerResult = try XCTUnwrap(ClaudeUsageParser.parseRateLimitHeaders(
            [
                "anthropic-ratelimit-unified-5h-utilization": "0.42",
                "anthropic-ratelimit-unified-5h-reset": "1893456000",
            ],
            subscriptionType: "max"
        ))

        XCTAssertEqual(unscopedResult.bars.first?.label, "5 hour usage limit")
        XCTAssertEqual(scopedResult.bars.first?.label, "Other models 5 hour usage limit")
        XCTAssertEqual(unscopedResult.bars.first?.stableKey, "session")
        XCTAssertEqual(scopedResult.bars.first?.stableKey, "session")
        XCTAssertEqual(legacyResult.bars.first?.stableKey, "session")
        XCTAssertEqual(headerResult.bars.first?.stableKey, "session")

        for result in [unscopedResult, legacyResult, headerResult] {
            let evaluation = UsageAlertEvaluator.evaluate(
                results: [result],
                settings: UsageAlertSettings(
                    isEnabled: true,
                    usageThreshold: 0.20,
                    includesSeverityAlerts: false
                ),
                activeAlertIDs: []
            )
            XCTAssertEqual(evaluation.activeAlertIDs, ["usage.claude.session"])
        }
    }

    func testClaudeUsageParserReadsStructuredAndScopedLimitsWithoutDuplicates() throws {
        let payload = """
        {
          "five_hour": {"utilization": 0.99, "resets_at": "2030-01-01T00:00:00Z"},
          "seven_day": {"utilization": 0.88, "resets_at": "2030-01-08T00:00:00Z"},
          "seven_day_sonnet": {"utilization": 0.44, "resets_at": "2030-01-08T00:00:00Z"},
          "limits": [
            {"kind":"session","percent":15,"is_active":true},
            {"kind":"weekly_all","percent":36,"resets_at":"2030-01-08T00:00:00Z","is_active":true},
            {"kind":"weekly_scoped","percent":71,"resets_at":"2030-01-08T00:00:00.838164+00:00","scope":{"model":{"display_name":"Fable"}},"is_active":true},
            {"kind":"weekly_scoped","percent":112,"scope":{"model":{"display_name":"Future Model"}},"is_active":true},
            {"kind":"weekly_scoped","percent":49,"scope":{"model":{"display_name":"Claude Sonnet 4.5"}},"is_active":true},
            {"kind":"internal_codename","percent":100,"scope":{"model":{"display_name":"Do Not Show"}},"is_active":true},
            {"kind":"weekly_scoped","percent":90,"scope":{"model":{"id":"internal-only"}},"is_active":true}
          ]
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "max_20x"
        ))

        XCTAssertEqual(result.bars.map(\.label), [
            "5 hour usage limit",
            "All models weekly usage limit",
            "Fable weekly usage limit",
            "Future Model weekly usage limit",
            "Claude Sonnet 4.5 weekly usage limit",
        ])
        XCTAssertEqual(result.bars.map(\.used), [15, 36, 71, 112, 49])
        XCTAssertEqual(result.bars[3].usageText, "112%")
        XCTAssertEqual(result.bars[0].resetsAt, ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z"))
        XCTAssertNil(result.bars[3].resetsAt)
        XCTAssertNotNil(result.bars[2].resetsAt)
        XCTAssertTrue(result.usageMessages.contains {
            $0 == "Fable usage is capped within the all-model weekly allowance."
        })
        XCTAssertFalse(result.bars.contains { $0.label.contains("Do Not Show") })

        let incompleteStructured = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"five_hour":{"utilization":0.42},"limits":[{"kind":"session","percent":null}]}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(incompleteStructured.bars.first?.used, 42)
    }

    func testClaudeUsageParserReadsCurrencyAwareUsageCredits() throws {
        let payload = """
        {
          "limits": [{"kind":"weekly_all","percent":24,"is_active":true}],
          "extra_usage": {
            "is_enabled": true,
            "monthly_limit": 5000,
            "used_credits": 1250,
            "currency": "EUR",
            "decimal_places": 2
          }
        }
        """

        let result = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(payload.utf8),
            subscriptionType: "pro"
        ))

        XCTAssertEqual(result.bars.first?.used, 24)
        XCTAssertEqual(result.monetaryMetrics.map(\.kind), [.spent, .spendLimit, .remainingHeadroom])
        XCTAssertEqual(result.monetaryMetrics.map(\.minorUnits), [Decimal(1250), Decimal(5000), Decimal(3750)])
        XCTAssertEqual(result.monetaryMetrics.map(\.amount), [Decimal(string: "12.5")!, Decimal(50), Decimal(string: "37.5")!])
        XCTAssertEqual(result.monetaryMetrics.map(\.currencyCode), ["EUR", "EUR", "EUR"])
        XCTAssertEqual(result.monetaryMetrics.last?.detail, "Not a prepaid balance")
        XCTAssertNil(result.creditsRemaining)
    }

    func testClaudeUsageParserRepresentsDisabledUnlimitedAndMalformedExtraUsage() throws {
        let disabled = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"is_enabled":false,"disabled_reason":"Not funded"}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(disabled.usageMessages, ["Usage credits are disabled: Not funded."])
        XCTAssertTrue(disabled.monetaryMetrics.isEmpty)

        let unlimited = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"is_enabled":true,"used_credits":250,"currency":"GBP","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(unlimited.monetaryMetrics.map(\.kind), [.spent])
        XCTAssertEqual(unlimited.usageMessages, ["Usage credits are enabled with no monthly spend limit reported."])

        let malformed = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"limits":[{"kind":"unknown","percent":50}],"extra_usage":{"is_enabled":true,"used_credits":10,"currency":"US"}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertTrue(malformed.monetaryMetrics.isEmpty)
        XCTAssertEqual(
            malformed.usageMessages,
            ["Usage credits are enabled, but monetary details are temporarily unavailable."]
        )

        let missingCurrency = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"is_enabled":true,"used_credits":1250,"monthly_limit":5000,"decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(missingCurrency.monetaryMetrics.map(\.currencyCode), ["USD", "USD", "USD"])
        XCTAssertEqual(missingCurrency.monetaryMetrics.map(\.amount), [12.5, 50, 37.5])

        let unknownState = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(
            unknownState.usageMessages,
            ["Usage credits are enabled, but monetary details are temporarily unavailable."]
        )

        let missingSpend = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"is_enabled":true,"monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertTrue(missingSpend.monetaryMetrics.isEmpty)
        XCTAssertEqual(
            missingSpend.usageMessages,
            ["Usage credits are enabled, but monetary details are temporarily unavailable."]
        )

        let inferredPrecision = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"is_enabled":true,"used_credits":1250,"monthly_limit":5000,"currency":"USD"}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(inferredPrecision.monetaryMetrics.map(\.decimalPlaces), [2, 2, 2])
        XCTAssertEqual(inferredPrecision.monetaryMetrics.map(\.amount), [12.5, 50, 37.5])

        let unreportedEnabledState = try XCTUnwrap(ClaudeUsageParser.parse(
            Data(#"{"extra_usage":{"used_credits":1250,"monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8),
            subscriptionType: nil
        ))
        XCTAssertEqual(unreportedEnabledState.monetaryMetrics.map(\.kind), [.spent, .spendLimit, .remainingHeadroom])
        XCTAssertEqual(
            unreportedEnabledState.usageMessages,
            ["Usage-credit enabled status was not reported."]
        )
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
        XCTAssertEqual(result.bars.first?.stableKey, "session")
        XCTAssertEqual(result.bars.first?.used, 25)
        XCTAssertEqual(result.bars.first?.projectionCurrent, 0.25)

        let overQuota = try XCTUnwrap(ClaudeUsageParser.parseRateLimitHeaders(
            [
                "anthropic-ratelimit-unified-5h-utilization": "1.2",
                "anthropic-ratelimit-unified-5h-reset": "1893456000"
            ],
            subscriptionType: "max",
            fetchedAt: fetchedAt
        ))
        XCTAssertEqual(overQuota.bars.first?.used, 100)
    }

    func testUsageBarFormatsPercentAndProjection() throws {
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
        XCTAssertEqual(bar.projectedSeverity(at: now), .critical)
        XCTAssertEqual(bar.effectiveSeverity(at: now), .critical)
        let projection = try XCTUnwrap(bar.projectionDescription(at: now))
        XCTAssertTrue(projection.hasPrefix("Projected 100% at current pace - Limit hit "))
        XCTAssertTrue(projection.hasSuffix(" - 1h early"))
    }

    func testUserFacingDateTimeFormatterUsesTimezoneAtDisplayedInstant() throws {
        let winter = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z"))
        let summer = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z"))
        let marchMismatch = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-03-20T12:00:00Z"))
        let octoberMismatch = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-10-29T12:00:00Z"))
        let locale = Locale(identifier: "en_US")
        let cases: [(String, String, String)] = [
            ("Europe/Berlin", "GMT+1", "GMT+2"),
            ("America/New_York", "EST", "EDT"),
            ("Asia/Kathmandu", "GMT+5:45", "GMT+5:45"),
        ]

        for (identifier, winterZone, summerZone) in cases {
            let formatter = UserFacingDateTimeFormatter(
                timeZone: try XCTUnwrap(TimeZone(identifier: identifier)),
                locale: locale
            )

            XCTAssertTrue(formatter.timeWithZone(winter, includesWeekday: false).hasSuffix(winterZone))
            XCTAssertTrue(formatter.timeWithZone(summer, includesWeekday: false).hasSuffix(summerZone))
        }

        let berlin = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Berlin")),
            locale: locale
        )
        let newYork = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "America/New_York")),
            locale: locale
        )
        XCTAssertTrue(berlin.timeWithZone(marchMismatch, includesWeekday: false).hasSuffix("GMT+1"))
        XCTAssertTrue(newYork.timeWithZone(marchMismatch, includesWeekday: false).hasSuffix("EDT"))
        XCTAssertTrue(berlin.timeWithZone(octoberMismatch, includesWeekday: false).hasSuffix("GMT+1"))
        XCTAssertTrue(newYork.timeWithZone(octoberMismatch, includesWeekday: false).hasSuffix("EDT"))
    }

    func testUserFacingDateTimeFormatterHonorsLocaleAndLocalWeekday() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2030-01-01T00:00:00Z"))
        let newYork = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let berlin = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let usFormatter = UserFacingDateTimeFormatter(
            timeZone: newYork,
            locale: Locale(identifier: "en_US")
        )
        let germanFormatter = UserFacingDateTimeFormatter(
            timeZone: berlin,
            locale: Locale(identifier: "de_DE")
        )

        let newYorkValue = usFormatter.timeWithZone(instant, includesWeekday: true)
        let berlinValue = germanFormatter.timeWithZone(instant, includesWeekday: true)
        XCTAssertTrue(newYorkValue.contains("Mon"))
        XCTAssertTrue(newYorkValue.contains("PM"))
        XCTAssertTrue(berlinValue.contains("Di."))
        XCTAssertTrue(berlinValue.contains("01:00"))
        XCTAssertFalse(berlinValue.contains("AM"))
        XCTAssertFalse(berlinValue.contains("PM"))
    }

    func testUserFacingDateTimeFormatterReevaluatesTimezoneProvider() throws {
        let instant = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-15T12:00:00Z"))
        var timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let formatter = UserFacingDateTimeFormatter(
            timeZoneProvider: { timeZone },
            localeProvider: { Locale(identifier: "en_US") }
        )

        XCTAssertTrue(formatter.timeWithZone(instant, includesWeekday: false).hasSuffix("EST"))
        timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Berlin"))
        let updatedValue = formatter.timeWithZone(instant, includesWeekday: false)
        XCTAssertTrue(updatedValue.hasSuffix("GMT+1"))
        XCTAssertFalse(updatedValue.contains("EST"))
    }

    func testCodexResetDescriptionsCoverRelativeAndExpiredRanges() throws {
        let resetAt = Date(timeIntervalSince1970: 1_893_456_000)
        let formatter = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Berlin")),
            locale: Locale(identifier: "en_US")
        )
        let payload = """
        {
          "rate_limit": {
            "primary_window": {
              "used_percent": 42,
              "reset_at": 1893456000,
              "limit_window_seconds": 18000
            }
          }
        }
        """
        let cases: [(Date, String)] = [
            (resetAt.addingTimeInterval(60), "Resets now"),
            (resetAt.addingTimeInterval(-30 * 60), "Resets 30m"),
            (resetAt.addingTimeInterval(-2 * 60 * 60), "Resets 2h 0m"),
            (resetAt.addingTimeInterval(-(2 * 24 + 4) * 60 * 60), "Resets 2d 4h"),
        ]

        for (fetchedAt, expectedPrefix) in cases {
            let result = try XCTUnwrap(CodexUsageParser.parse(
                Data(payload.utf8),
                fetchedAt: fetchedAt,
                dateTimeFormatter: formatter
            ))
            XCTAssertTrue(try XCTUnwrap(result.bars.first?.resetDescription).hasPrefix(expectedPrefix))
        }
    }

    func testUsageBarFormatsProjectedLimitInInjectedTimezone() throws {
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let now = start.addingTimeInterval(60 * 60)
        let end = start.addingTimeInterval(5 * 60 * 60)
        let formatter = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "Asia/Kathmandu")),
            locale: Locale(identifier: "en_US")
        )

        let description = UsageBar.formatLimitHit(
            current: 0.25,
            limit: 1,
            periodStart: start,
            periodEnd: end,
            now: now,
            dateTimeFormatter: formatter
        )

        XCTAssertTrue(description.contains("Thu 9:45"))
        XCTAssertTrue(description.contains("GMT+5:45"))
        XCTAssertTrue(description.hasSuffix(" - 1h early"))
    }

    @MainActor
    func testWidgetSnapshotReformatsResetAndProjectionForChangedTimezone() throws {
        let suiteName = "CodexBarIOSTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let secretStore = MemorySecretStore()
        let store = ProviderConfigurationStore(defaults: defaults, secretStore: secretStore)
        let configuration = store.addAccount(for: .codex)
        store.saveSecret("test-token", for: configuration)
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let now = start.addingTimeInterval(60 * 60)
        let resetAt = start.addingTimeInterval(3 * 60 * 60)
        let result = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .codex,
            title: "ChatGPT / Codex",
            subtitle: "Live ChatGPT usage",
            bars: [
                UsageBar(
                    label: "5 hour usage limit",
                    used: 25,
                    limit: 100,
                    resetDescription: "Resets 2h (10:00 PM EST)",
                    resetsAt: resetAt,
                    resetDisplayStyle: .relativeWithLocalTime,
                    projectionCurrent: 0.25,
                    projectionLimit: 1,
                    projectionPeriodStart: start,
                    projectionPeriodEnd: start.addingTimeInterval(5 * 60 * 60),
                    showProjectionOnCurrentBar: true
                ),
            ],
            fetchedAt: now
        )
        let newYork = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "America/New_York")),
            locale: Locale(identifier: "en_US")
        )
        let berlin = UserFacingDateTimeFormatter(
            timeZone: try XCTUnwrap(TimeZone(identifier: "Europe/Berlin")),
            locale: Locale(identifier: "en_US")
        )

        WidgetSnapshotPublisher.publish(
            results: [result],
            configurationStore: store,
            snapshotDefaults: defaults,
            now: now,
            dateTimeFormatter: newYork
        )
        let storedBar = try XCTUnwrap(
            WidgetSnapshotStore.loadSnapshot(defaults: defaults).results.first?.bars.first
        )
        let easternProjection = try XCTUnwrap(storedBar.localizedProjectionDescription(
            dateTimeFormatter: newYork
        ))
        let easternReset = try XCTUnwrap(storedBar.localizedResetDescription(
            at: now,
            dateTimeFormatter: newYork
        ))
        XCTAssertTrue(easternProjection.contains("EST"))
        XCTAssertTrue(easternReset.contains("EST"))

        let localProjection = try XCTUnwrap(storedBar.localizedProjectionDescription(
            dateTimeFormatter: berlin
        ))
        let localReset = try XCTUnwrap(storedBar.localizedResetDescription(
            at: now,
            dateTimeFormatter: berlin
        ))
        XCTAssertTrue(localProjection.contains("GMT+1"))
        XCTAssertFalse(localProjection.contains("EST"))
        XCTAssertTrue(localReset.contains("GMT+1"))
        XCTAssertFalse(localReset.contains("EST"))
    }

    func testUsageBarShowsSafeProjectionWhenPaceStaysBelowLimit() {
        let start = Date(timeIntervalSince1970: 1_767_225_600)
        let now = start.addingTimeInterval(60 * 60)
        let end = start.addingTimeInterval(5 * 60 * 60)
        let bar = UsageBar(
            label: "5 hour usage limit",
            used: 8,
            limit: 100,
            projectionCurrent: 0.08,
            projectionLimit: 1,
            projectionPeriodStart: start,
            projectionPeriodEnd: end,
            showProjectionOnCurrentBar: true
        )

        XCTAssertEqual(bar.projectedFraction(at: now), 0.4)
        XCTAssertEqual(bar.projectedSeverity(at: now), .normal)
        XCTAssertEqual(bar.effectiveSeverity(at: now), .normal)
        XCTAssertEqual(bar.projectionDescription(at: now), "Projected to stay under limit")
    }

    func testUsageBarKeepsOverLimitPercentVisible() {
        let bar = UsageBar(label: "Weekly usage limit", used: 112, limit: 100)

        XCTAssertEqual(bar.usageText, "112%")
        XCTAssertEqual(bar.fractionUsed, 1)
    }

}
