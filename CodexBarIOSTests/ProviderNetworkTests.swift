import XCTest
@testable import CodexBarIOS

final class ProviderNetworkTests: XCTestCase {
    func testCodexUsageProviderProactivelyRefreshesAndPersistsRotation() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let account = ProviderConfigurationStore.keychainAccount(for: configuration)
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "old-access",
                refreshToken: "old-refresh",
                idToken: "old-id",
                accountID: "account-id",
                expiresAt: 2_000_000_060
            )),
            account: account
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: session,
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            tokenEndpoint: URL(string: "https://example.test/codex-token")!,
            now: { now }
        )
        var requestCount = 0

        ProviderNetworkMockURLProtocol.handler = { request in
            requestCount += 1
            if request.url?.path == "/codex-token" {
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(request.timeoutInterval, 15)
                XCTAssertEqual(
                    String(data: try XCTUnwrap(requestBodyData(from: request)), encoding: .utf8),
                    "grant_type=refresh_token&refresh_token=old-refresh&client_id=app_EMoamEEZ73f0CkXaXp7hrann"
                )
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8)
                )
            }

            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account-id")
            let persisted = try XCTUnwrap(
                CodexCredentialsParser.parse(try XCTUnwrap(secretStore.readSecret(account: account)))
            )
            XCTAssertEqual(persisted.accessToken, "new-access")
            XCTAssertEqual(persisted.refreshToken, "new-refresh")
            XCTAssertEqual(persisted.expiresAt, 2_000_003_600)
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":25,"reset_at":2000007200,"limit_window_seconds":18000}}}"#.utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(result.bars.first?.used, 25)
    }

    func testCodexUsageProviderVerifiesResetInventoryForTheConfiguredAccount() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "codex-access",
                accountID: "chatgpt-account",
                expiresAt: 2_100_000_000
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/wham/usage")!,
            resetCreditsEndpoint: URL(string: "https://example.test/wham/rate-limit-reset-credits")!,
            consumeResetEndpoint: URL(string: "https://example.test/wham/rate-limit-reset-credits/consume")!,
            now: { Date(timeIntervalSince1970: 2_000_000_000) }
        )

        ProviderNetworkMockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer codex-access")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "chatgpt-account")
            if request.url?.path == "/wham/rate-limit-reset-credits" {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"available_count":2,"credits":[{"id":"credit-1","status":"available","title":"Full reset (Weekly + 5 hr)","expires_at":"2030-01-02T03:04:05Z"}]}"#.utf8)
                )
            }
            XCTAssertEqual(request.url?.path, "/wham/usage")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":25,"reset_at":2000007200,"limit_window_seconds":18000}},"rate_limit_reset_credits":{"available_count":2}}"#.utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.codexBankedRateLimitResets?.availableCount, 2)
        XCTAssertTrue(try XCTUnwrap(result.codexBankedRateLimitResets).canConsume)
        XCTAssertEqual(result.codexBankedRateLimitResets?.preferredCredit?.id, "credit-1")
    }

    func testCodexUsageProviderConsumesEachOfficialResetOutcomeWithOpaqueCreditID() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "codex-access",
                accountID: "chatgpt-account",
                expiresAt: 2_100_000_000
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            consumeResetEndpoint: URL(string: "https://example.test/wham/rate-limit-reset-credits/consume")!,
            now: { Date(timeIntervalSince1970: 2_000_000_000) }
        )
        let codes = ["reset", "already_redeemed", "nothing_to_reset", "no_credit"]
        var requestIndex = 0
        ProviderNetworkMockURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/wham/rate-limit-reset-credits/consume")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer codex-access")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "chatgpt-account")
            let body = try XCTUnwrap(requestBodyData(from: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(json["redeem_request_id"], "attempt-\(requestIndex)")
            XCTAssertEqual(json["credit_id"], "opaque-credit")
            let code = codes[requestIndex]
            requestIndex += 1
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data("{\"code\":\"\(code)\"}".utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        var outcomes: [CodexBankedResetConsumptionOutcome] = []
        for index in codes.indices {
            outcomes.append(try await provider.consumeBankedReset(
                for: configuration,
                creditID: "opaque-credit",
                idempotencyKey: "attempt-\(index)"
            ))
        }

        XCTAssertEqual(outcomes, [.reset, .alreadyRedeemed, .nothingToReset, .noCredit])
        XCTAssertEqual(requestIndex, 4)
    }

    @MainActor
    func testUsageRefreshServiceJoinsRapidResetSubmissions() async throws {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let gate = UsageProviderGate()
        let provider = ResetConsumptionTestProvider(
            outcome: .reset,
            fetchFails: false,
            consumeGate: gate
        )
        let service = UsageRefreshService(providers: [provider])

        let first = Task {
            try await service.consumeCodexBankedReset(for: configuration, creditID: nil)
        }
        await gate.waitUntilBlocked()
        let second = Task {
            try await service.consumeCodexBankedReset(for: configuration, creditID: nil)
        }
        await Task.yield()
        await gate.release()

        let firstOutcome = try await first.value
        let secondOutcome = try await second.value
        XCTAssertEqual(firstOutcome, .reset)
        XCTAssertEqual(secondOutcome, .reset)
        let consumedKeys = await provider.recordedConsumedKeys()
        XCTAssertEqual(consumedKeys.count, 1)
    }

    @MainActor
    func testUsageRefreshServiceReusesIdempotencyKeyAfterTransportFailure() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "codex-access",
                expiresAt: 2_100_000_000
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            consumeResetEndpoint: URL(string: "https://example.test/consume")!,
            now: { Date(timeIntervalSince1970: 2_000_000_000) }
        )
        let service = UsageRefreshService(providers: [provider])
        var idempotencyKeys: [String] = []
        var creditIDs: [String?] = []
        ProviderNetworkMockURLProtocol.handler = { request in
            let body = try XCTUnwrap(requestBodyData(from: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            idempotencyKeys.append(try XCTUnwrap(json["redeem_request_id"]))
            creditIDs.append(json["credit_id"])
            if idempotencyKeys.count == 1 {
                throw URLError(.timedOut)
            }
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"code":"reset"}"#.utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        do {
            _ = try await service.consumeCodexBankedReset(for: configuration, creditID: "credit-original")
            XCTFail("Expected the first transport attempt to fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        let outcome = try await service.consumeCodexBankedReset(for: configuration, creditID: "credit-changed")

        XCTAssertEqual(outcome, .reset)
        XCTAssertEqual(idempotencyKeys.count, 2)
        XCTAssertEqual(idempotencyKeys[0], idempotencyKeys[1])
        XCTAssertFalse(idempotencyKeys[0].isEmpty)
        XCTAssertEqual(creditIDs.compactMap { $0 }, ["credit-original", "credit-original"])
    }

    @MainActor
    func testUsageRefreshServiceClearsAttemptAfterDefinitiveClientFailure() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "codex-access",
                expiresAt: 2_100_000_000
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            consumeResetEndpoint: URL(string: "https://example.test/consume")!,
            now: { Date(timeIntervalSince1970: 2_000_000_000) }
        )
        let service = UsageRefreshService(providers: [provider])
        var idempotencyKeys: [String] = []
        var creditIDs: [String?] = []
        ProviderNetworkMockURLProtocol.handler = { request in
            let body = try XCTUnwrap(requestBodyData(from: request))
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            idempotencyKeys.append(try XCTUnwrap(json["redeem_request_id"]))
            creditIDs.append(json["credit_id"])
            let status = idempotencyKeys.count == 1 ? 400 : 200
            let responseBody = status == 200 ? Data(#"{"code":"reset"}"#.utf8) : Data()
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil)!,
                responseBody
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        do {
            _ = try await service.consumeCodexBankedReset(for: configuration, creditID: "credit-original")
            XCTFail("Expected the first client-error attempt to fail")
        } catch {
            XCTAssertEqual(error as? CodexBankedResetConsumptionError, .httpStatus(400))
        }
        let outcome = try await service.consumeCodexBankedReset(for: configuration, creditID: "credit-changed")

        XCTAssertEqual(outcome, .reset)
        XCTAssertEqual(idempotencyKeys.count, 2)
        XCTAssertNotEqual(idempotencyKeys[0], idempotencyKeys[1])
        XCTAssertEqual(creditIDs.compactMap { $0 }, ["credit-original", "credit-changed"])
    }

    func testCodexUsageProviderSilentlyPreservesWeeklyOnlyUsage() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "codex-access",
                expiresAt: 2_000_003_600
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            now: { now }
        )
        ProviderNetworkMockURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/codex-usage")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"plan_type":"prolite","rate_limit":{"primary_window":{"used_percent":30,"reset_at":2000604800,"limit_window_seconds":604800},"secondary_window":null}}"#.utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.bars.map(\.label), ["Weekly usage limit"])
        XCTAssertTrue(result.usageMessages.isEmpty)
    }

    func testCodexUsageProviderPreservesCredentialChangedDuringRefresh() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let initial = CodexCredentialsParser.storedCredential(from: CodexCredentials(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            expiresAt: 1_999_999_000
        ))
        let replacement = CodexCredentialsParser.storedCredential(from: CodexCredentials(
            accessToken: "signed-in-access",
            refreshToken: "signed-in-refresh",
            expiresAt: 2_000_003_600
        ))
        let secretStore = ReplacingThirdReadSecretStore(initialSecret: initial, replacementSecret: replacement)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            tokenEndpoint: URL(string: "https://example.test/codex-token")!,
            now: { now }
        )
        ProviderNetworkMockURLProtocol.handler = { request in
            if request.url?.path == "/codex-token" {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"refreshed-old-access","refresh_token":"rotated-old-refresh","expires_in":3600}"#.utf8)
                )
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer signed-in-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":25,"reset_at":2000007200,"limit_window_seconds":18000}}}"#.utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 25)
        XCTAssertEqual(secretStore.saveCount, 0)
    }

    func testCodexUsageProviderDerivesRefreshedExpiryFromJWT() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let expectedExpiry: Int64 = 2_000_003_600
        let header = #"{"alg":"none"}"#.base64URLEncodedForTest()
        let payload = #"{"exp":2000003600,"chatgpt_account_id":"refreshed-account"}"#.base64URLEncodedForTest()
        let refreshedAccessToken = "\(header).\(payload).signature"
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let account = ProviderConfigurationStore.keychainAccount(for: configuration)
        let secretStore = MemorySecretStore()
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "expired-access",
                refreshToken: "refresh-token",
                expiresAt: 1_999_999_000
            )),
            account: account
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            tokenEndpoint: URL(string: "https://example.test/codex-token")!,
            now: { now }
        )
        ProviderNetworkMockURLProtocol.handler = { request in
            if request.url?.path == "/codex-token" {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"\#(refreshedAccessToken)","refresh_token":"rotated"}"#.utf8)
                )
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(refreshedAccessToken)")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "refreshed-account")
            let persisted = try XCTUnwrap(
                CodexCredentialsParser.parse(try XCTUnwrap(secretStore.readSecret(account: account)))
            )
            XCTAssertEqual(persisted.expiresAt, expectedExpiry)
            XCTAssertEqual(persisted.accountID, "refreshed-account")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":25,"reset_at":2000007200,"limit_window_seconds":18000}}}"#.utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 25)
    }

    func testCodexUsageProviderExplainsExpiredCredentialWithoutRefreshToken() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "expired-access",
                expiresAt: 1_999_999_000
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let provider = CodexUsageProvider(secretStore: secretStore, now: { now })

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(
            result.subtitle,
            "ChatGPT / Codex credential expired and cannot be renewed. Sign in again."
        )
    }

    func testCodexUsageProviderUsesValidTokenWhenProactiveRefreshIsTemporarilyUnavailable() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "still-valid-access",
                refreshToken: "refresh-token",
                expiresAt: 2_000_000_060
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            tokenEndpoint: URL(string: "https://example.test/codex-token")!,
            now: { now }
        )
        var requestCount = 0
        ProviderNetworkMockURLProtocol.handler = { request in
            requestCount += 1
            if request.url?.path == "/codex-token" {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 503, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer still-valid-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":25,"reset_at":2000007200,"limit_window_seconds":18000}}}"#.utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(result.bars.first?.used, 25)
    }

    func testCodexUsageProviderDoesNotUseCredentialWhenKeychainRotationFails() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let stored = CodexCredentialsParser.storedCredential(from: CodexCredentials(
            accessToken: "expired-access",
            refreshToken: "refresh-token",
            expiresAt: 1_999_999_000
        ))
        let secretStore = FailingSaveSecretStore(secret: stored)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: session,
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            tokenEndpoint: URL(string: "https://example.test/codex-token")!,
            now: { now }
        )
        var requestCount = 0
        ProviderNetworkMockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/codex-token")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"access_token":"new-access","refresh_token":"rotated","expires_in":3600}"#.utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(
            result.subtitle,
            "Could not securely save the renewed ChatGPT / Codex credential. Sign in again."
        )
    }

    func testCopilotUsageProviderRequestsSignInWhenKeychainRotationFails() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        let stored = CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
            accessToken: "expired-access",
            refreshToken: "refresh-token",
            expiresAt: 1_999_999_000
        ))
        let secretStore = FailingSaveSecretStore(secret: stored)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/copilot-usage")!,
            tokenEndpoint: URL(string: "https://example.test/github-token")!,
            oauthConfiguration: CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret"),
            now: { now }
        )
        var requestCount = 0
        ProviderNetworkMockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/github-token")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"access_token":"new-access","refresh_token":"rotated","expires_in":28800}"#.utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(
            result.subtitle,
            "Could not securely save the renewed GitHub credential. Sign in again."
        )
    }

    func testCodexUsageProviderRetriesOnlyOnceAfterAuthenticationRejection() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-token"
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: session,
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            tokenEndpoint: URL(string: "https://example.test/codex-token")!
        )
        var usageRequests = 0
        var refreshRequests = 0

        ProviderNetworkMockURLProtocol.handler = { request in
            if request.url?.path == "/codex-token" {
                refreshRequests += 1
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"rotated-refresh","expires_in":3600}"#.utf8)
                )
            }
            usageRequests += 1
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(usageRequests, 2)
        XCTAssertEqual(refreshRequests, 1)
        XCTAssertEqual(result.subtitle, "ChatGPT / Codex authorization was revoked. Sign in again.")
    }

    func testCodexUsageProviderRecoversFromUsageRejectionWithRefreshedCredential() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-token"
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/codex-usage")!,
            tokenEndpoint: URL(string: "https://example.test/codex-token")!
        )
        var usageRequests = 0
        var refreshRequests = 0
        ProviderNetworkMockURLProtocol.handler = { request in
            if request.url?.path == "/codex-token" {
                refreshRequests += 1
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"rotated-refresh","expires_in":3600}"#.utf8)
                )
            }
            usageRequests += 1
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                usageRequests == 1 ? "Bearer old-access" : "Bearer new-access"
            )
            let statusCode = usageRequests == 1 ? 401 : 200
            let data = usageRequests == 1
                ? Data()
                : Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":25,"reset_at":2000007200,"limit_window_seconds":18000}}}"#.utf8)
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: statusCode, httpVersion: nil, headerFields: nil)!,
                data
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(usageRequests, 2)
        XCTAssertEqual(refreshRequests, 1)
        XCTAssertEqual(result.bars.first?.used, 25)
    }

    func testCodexUsageProviderExplainsRejectedRefreshAndLegacyRejection() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)
        let account = ProviderConfigurationStore.keychainAccount(for: configuration)
        try secretStore.saveSecret(
            CodexCredentialsParser.storedCredential(from: CodexCredentials(
                accessToken: "expired-access",
                refreshToken: "rejected-refresh",
                expiresAt: 1_999_999_000
            )),
            account: account
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let provider = CodexUsageProvider(
            secretStore: secretStore,
            session: session,
            tokenEndpoint: URL(string: "https://example.test/codex-token")!,
            now: { now }
        )
        ProviderNetworkMockURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 400, httpVersion: nil, headerFields: nil)!,
                Data(#"{"error":"invalid_grant","access_token":"must-not-leak"}"#.utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let rejected = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(rejected.subtitle, "ChatGPT / Codex credential renewal was rejected. Sign in again.")
        XCTAssertFalse(rejected.subtitle.contains("must-not-leak"))

        try secretStore.saveSecret("legacy-access", account: account)
        ProviderNetworkMockURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 401, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        let legacy = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(legacy.subtitle, "ChatGPT / Codex credential was rejected. Sign in again.")
    }

    func testCopilotUsageProviderProactivelyRefreshesAndPersistsRotation() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        let account = ProviderConfigurationStore.keychainAccount(for: configuration)
        try secretStore.saveSecret(
            CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
                accessToken: "old-access",
                username: "octocat",
                refreshToken: "old-refresh",
                expiresAt: 2_000_000_060,
                refreshTokenExpiresAt: 2_100_000_000
            )),
            account: account
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: session,
            usageEndpoint: URL(string: "https://example.test/copilot-usage")!,
            tokenEndpoint: URL(string: "https://example.test/github-token")!,
            oauthConfiguration: CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret"),
            now: { now }
        )
        var requestCount = 0

        ProviderNetworkMockURLProtocol.handler = { request in
            requestCount += 1
            if request.url?.path == "/github-token" {
                XCTAssertEqual(request.timeoutInterval, 15)
                XCTAssertEqual(
                    String(data: try XCTUnwrap(requestBodyData(from: request)), encoding: .utf8),
                    "client_id=client&client_secret=secret&grant_type=refresh_token&refresh_token=old-refresh"
                )
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":28800,"refresh_token_expires_in":15897600}"#.utf8)
                )
            }

            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token new-access")
            let persisted = try XCTUnwrap(
                CopilotCredentialsParser.parse(try XCTUnwrap(secretStore.readSecret(account: account)))
            )
            XCTAssertEqual(persisted.accessToken, "new-access")
            XCTAssertEqual(persisted.refreshToken, "new-refresh")
            XCTAssertEqual(persisted.username, "octocat")
            XCTAssertEqual(persisted.expiresAt, 2_000_028_800)
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"login":"octocat","copilot_plan":"individual_pro","quota_reset_date_utc":"2033-05-19T03:33:20Z","quota_snapshots":{"premium_interactions":{"entitlement":100,"remaining":75,"unlimited":false}}}"#.utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(result.bars.first?.used, 25)
    }

    func testCopilotUsageProviderDoesNotCarryStaleExpiryWhenRefreshOmitsLifetime() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let priorExpiry: Int64 = 2_000_000_060
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        let account = ProviderConfigurationStore.keychainAccount(for: configuration)
        let secretStore = MemorySecretStore()
        try secretStore.saveSecret(
            CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
                accessToken: "old-access",
                refreshToken: "old-refresh",
                expiresAt: priorExpiry,
                refreshTokenExpiresAt: 2_100_000_000
            )),
            account: account
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/copilot-usage")!,
            tokenEndpoint: URL(string: "https://example.test/github-token")!,
            oauthConfiguration: CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret"),
            now: { now }
        )
        ProviderNetworkMockURLProtocol.handler = { request in
            if request.url?.path == "/github-token" {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"new-refresh"}"#.utf8)
                )
            }
            let persisted = try XCTUnwrap(
                CopilotCredentialsParser.parse(try XCTUnwrap(secretStore.readSecret(account: account)))
            )
            XCTAssertNil(persisted.expiresAt)
            XCTAssertNil(persisted.refreshTokenExpiresAt)
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"login":"octocat","copilot_plan":"individual_pro","quota_reset_date_utc":"2033-05-19T03:33:20Z","quota_snapshots":{"premium_interactions":{"entitlement":100,"remaining":75,"unlimited":false}}}"#.utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 25)
    }

    func testCopilotUsageProviderPreservesCredentialChangedDuringRefresh() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        let initial = CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
            accessToken: "old-access",
            refreshToken: "old-refresh",
            expiresAt: 1_999_999_000
        ))
        let replacement = CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
            accessToken: "signed-in-access",
            refreshToken: "signed-in-refresh",
            expiresAt: 2_000_028_800
        ))
        let secretStore = ReplacingThirdReadSecretStore(initialSecret: initial, replacementSecret: replacement)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/copilot-usage")!,
            tokenEndpoint: URL(string: "https://example.test/github-token")!,
            oauthConfiguration: CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret"),
            now: { now }
        )
        ProviderNetworkMockURLProtocol.handler = { request in
            if request.url?.path == "/github-token" {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"refreshed-old-access","refresh_token":"rotated-old-refresh","expires_in":28800}"#.utf8)
                )
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token signed-in-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"login":"octocat","copilot_plan":"individual_pro","quota_reset_date_utc":"2033-05-19T03:33:20Z","quota_snapshots":{"premium_interactions":{"entitlement":100,"remaining":75,"unlimited":false}}}"#.utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 25)
        XCTAssertEqual(secretStore.saveCount, 0)
    }

    func testCopilotUsageProviderSharesConcurrentRefreshForSameAccount() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        try secretStore.saveSecret(
            CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
                accessToken: "old-access",
                refreshToken: "single-use-refresh",
                expiresAt: 1_999_999_000
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let refreshJoined = TestSignal()
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/copilot-usage")!,
            tokenEndpoint: URL(string: "https://example.test/github-token")!,
            oauthConfiguration: CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret"),
            now: { now },
            onJoinInFlightRefresh: { refreshJoined.signal() }
        )
        let counterLock = NSLock()
        let refreshGate = TestRequestGate()
        var refreshRequests = 0
        var usageRequests = 0
        ProviderNetworkMockURLProtocol.handler = { request in
            if request.url?.path == "/github-token" {
                counterLock.lock()
                refreshRequests += 1
                counterLock.unlock()
                refreshGate.blockUntilReleased()
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"rotated","expires_in":28800}"#.utf8)
                )
            }

            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token new-access")
            counterLock.lock()
            usageRequests += 1
            counterLock.unlock()
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"login":"octocat","copilot_plan":"individual_pro","quota_reset_date_utc":"2033-05-19T03:33:20Z","quota_snapshots":{"premium_interactions":{"entitlement":100,"remaining":75,"unlimited":false}}}"#.utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let first = Task { try await provider.fetchUsage(for: configuration) }
        XCTAssertTrue(refreshGate.waitUntilBlocked(), "Expected the first credential refresh request to start.")
        let second = Task { try await provider.fetchUsage(for: configuration) }
        XCTAssertTrue(refreshJoined.wait(), "Expected the second fetch to join the in-flight credential refresh.")
        refreshGate.release()
        let results = try await [first.value, second.value]

        XCTAssertEqual(refreshRequests, 1)
        XCTAssertEqual(usageRequests, 2)
        XCTAssertTrue(results.allSatisfy { $0.bars.first?.used == 25 })
    }

    func testCopilotUsageProviderDoesNotReuseRotatedTokenFromLateStaleRead() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        let stored = CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
            accessToken: "old-access",
            refreshToken: "single-use-refresh",
            expiresAt: 1_999_999_000
        ))
        let secretStore = StaleThirdReadSecretStore(initialSecret: stored)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/copilot-usage")!,
            tokenEndpoint: URL(string: "https://example.test/github-token")!,
            oauthConfiguration: CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret"),
            now: { now }
        )
        var refreshRequests = 0
        ProviderNetworkMockURLProtocol.handler = { request in
            if request.url?.path == "/github-token" {
                refreshRequests += 1
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"rotated-refresh","expires_in":28800}"#.utf8)
                )
            }

            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token new-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"login":"octocat","copilot_plan":"individual_pro","quota_reset_date_utc":"2033-05-19T03:33:20Z","quota_snapshots":{"premium_interactions":{"entitlement":100,"remaining":75,"unlimited":false}}}"#.utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let first = try await provider.fetchUsage(for: configuration)
        let second = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(refreshRequests, 1)
        XCTAssertEqual(first.bars.first?.used, 25)
        XCTAssertEqual(second.bars.first?.used, 25)
    }

    func testCopilotUsageProviderExplainsExpiredCredentialWithoutRefreshToken() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        try secretStore.saveSecret(
            CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
                accessToken: "expired-access",
                expiresAt: 1_999_999_000
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let provider = CopilotUsageProvider(secretStore: secretStore, now: { now })

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(
            result.subtitle,
            "GitHub credential expired and cannot be renewed. Sign in again."
        )
    }

    func testCopilotUsageProviderExplainsExpiredRefreshToken() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        try secretStore.saveSecret(
            CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
                accessToken: "expired-access",
                refreshToken: "expired-refresh",
                expiresAt: 1_999_999_000,
                refreshTokenExpiresAt: 1_999_999_500
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let provider = CopilotUsageProvider(secretStore: secretStore, now: { now })

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(
            result.subtitle,
            "GitHub credential expired and cannot be renewed. Sign in again."
        )
    }

    func testCopilotUsageProviderUsesValidTokenWhenProactiveRefreshIsTemporarilyUnavailable() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        try secretStore.saveSecret(
            CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
                accessToken: "still-valid-access",
                refreshToken: "refresh-token",
                expiresAt: 2_000_000_060
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/copilot-usage")!,
            tokenEndpoint: URL(string: "https://example.test/github-token")!,
            oauthConfiguration: CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret"),
            now: { now }
        )
        var requestCount = 0
        ProviderNetworkMockURLProtocol.handler = { request in
            requestCount += 1
            if request.url?.path == "/github-token" {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 503, httpVersion: nil, headerFields: nil)!,
                    Data()
                )
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token still-valid-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"login":"octocat","copilot_plan":"individual_pro","quota_reset_date_utc":"2033-05-19T03:33:20Z","quota_snapshots":{"premium_interactions":{"entitlement":100,"remaining":75,"unlimited":false}}}"#.utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(result.bars.first?.used, 25)
    }

    func testCopilotUsageProviderExplainsRejectedRefreshWithoutLeakingResponse() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        try secretStore.saveSecret(
            CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
                accessToken: "expired-access",
                refreshToken: "rejected-refresh",
                expiresAt: 1_999_999_000
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: session,
            tokenEndpoint: URL(string: "https://example.test/github-token")!,
            oauthConfiguration: CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret"),
            now: { now }
        )
        ProviderNetworkMockURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 400, httpVersion: nil, headerFields: nil)!,
                Data(#"{"error":"bad_refresh_token","access_token":"must-not-leak"}"#.utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.subtitle, "GitHub credential renewal was rejected. Sign in again.")
        XCTAssertFalse(result.subtitle.contains("must-not-leak"))
    }

    func testCopilotUsageProviderRetriesOnceAndSeparatesPermissionFailures() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        try secretStore.saveSecret(
            CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-token"
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: session,
            usageEndpoint: URL(string: "https://example.test/copilot-usage")!,
            tokenEndpoint: URL(string: "https://example.test/github-token")!,
            oauthConfiguration: CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret")
        )
        var usageRequests = 0
        var refreshRequests = 0

        ProviderNetworkMockURLProtocol.handler = { request in
            if request.url?.path == "/github-token" {
                refreshRequests += 1
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"rotated","expires_in":28800}"#.utf8)
                )
            }
            usageRequests += 1
            let status = usageRequests <= 2 ? 401 : 403
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: status, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let rejected = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(usageRequests, 2)
        XCTAssertEqual(refreshRequests, 1)
        XCTAssertEqual(rejected.subtitle, "GitHub authorization was revoked. Sign in again.")

        try secretStore.saveSecret("legacy-access", account: ProviderConfigurationStore.keychainAccount(for: configuration))
        let forbidden = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(forbidden.subtitle, "This GitHub account does not have access to Copilot usage.")
    }

    func testCopilotUsageProviderRecoversFromUsageRejectionWithRefreshedCredential() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        try secretStore.saveSecret(
            CopilotCredentialsParser.storedCredential(from: CopilotCredentials(
                accessToken: "old-access",
                refreshToken: "refresh-token"
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/copilot-usage")!,
            tokenEndpoint: URL(string: "https://example.test/github-token")!,
            oauthConfiguration: CopilotOAuthConfiguration(clientID: "client", clientSecret: "secret")
        )
        var usageRequests = 0
        var refreshRequests = 0
        ProviderNetworkMockURLProtocol.handler = { request in
            if request.url?.path == "/github-token" {
                refreshRequests += 1
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"rotated-refresh","expires_in":28800}"#.utf8)
                )
            }
            usageRequests += 1
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Authorization"),
                usageRequests == 1 ? "token old-access" : "token new-access"
            )
            let statusCode = usageRequests == 1 ? 401 : 200
            let data = usageRequests == 1
                ? Data()
                : Data(#"{"login":"octocat","copilot_plan":"individual_pro","quota_reset_date_utc":"2033-05-19T03:33:20Z","quota_snapshots":{"premium_interactions":{"entitlement":100,"remaining":75,"unlimited":false}}}"#.utf8)
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: statusCode, httpVersion: nil, headerFields: nil)!,
                data
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(usageRequests, 2)
        XCTAssertEqual(refreshRequests, 1)
        XCTAssertEqual(result.bars.first?.used, 25)
    }

    func testCopilotUsageProviderSeparatesRateLimitFromMissingAccess() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .copilot)
        try secretStore.saveSecret(
            "legacy-access",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            usageEndpoint: URL(string: "https://example.test/copilot-usage")!
        )
        ProviderNetworkMockURLProtocol.handler = { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 403,
                    httpVersion: nil,
                    headerFields: ["X-RateLimit-Remaining": "0"]
                )!,
                Data()
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.subtitle, "GitHub rate limit reached. Try again later.")
    }

    func testCopilotOrganizationUsageDistinguishesPermissionFailureFromMissingOrganization() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            providerID: .copilot,
            authMethod: .browserSession,
            copilotAccountScope: .organization,
            githubOrganization: "HemSoft"
        )
        try secretStore.saveSecret(
            "legacy-access",
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let session = URLSession(configuration: sessionConfiguration)
        let provider = CopilotUsageProvider(
            secretStore: secretStore,
            session: session,
            githubAPIBaseURL: URL(string: "https://example.test")!
        )
        var statusCode = 403
        ProviderNetworkMockURLProtocol.handler = { request in
            (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: statusCode, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(
            result.subtitle,
            "This GitHub account lacks permission to read the configured Copilot organization billing data."
        )

        statusCode = 404
        let missing = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(
            missing.subtitle,
            "GitHub Copilot organization not found. Check the configured organization name."
        )
    }

    func testCodexUsageWithoutCredentialIsNotDemoData() async throws {
        let provider = CodexUsageProvider(secretStore: EmptySecretStore())
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .codex)

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .codex)
        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.subtitle, "Not configured - sign in with ChatGPT.")
        XCTAssertEqual(result.failureMessage, result.subtitle)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testClaudeUsageWithoutCredentialIsNotDemoData() async throws {
        let provider = ClaudeUsageProvider(secretStore: EmptySecretStore())
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.providerID, .claude)
        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.subtitle, "Not configured - sign in with Claude.")
        XCTAssertEqual(result.failureMessage, result.subtitle)
        XCTAssertTrue(result.bars.isEmpty)
    }

    func testClaudeUsageProviderPreservesCredentialChangedDuringRefresh() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        let initial = ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            subscriptionType: "pro",
            expiresAt: 1_999_999_000_000,
            accessToken: "old-access",
            refreshToken: "old-refresh"
        ))
        let replacement = ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
            subscriptionType: "pro",
            expiresAt: 2_000_003_600_000,
            accessToken: "signed-in-access",
            refreshToken: "signed-in-refresh"
        ))
        let secretStore = ReplacingThirdReadSecretStore(initialSecret: initial, replacementSecret: replacement)
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            now: { now }
        )
        ProviderNetworkMockURLProtocol.handler = { request in
            if request.url?.path == "/v1/oauth/token" {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"refreshed-old-access","refresh_token":"rotated-old-refresh","expires_in":3600}"#.utf8)
                )
            }
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer signed-in-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"limits":[{"kind":"weekly_all","percent":25,"is_active":true}]}"#.utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.bars.first?.used, 25)
        XCTAssertEqual(secretStore.saveCount, 0)
    }

    func testClaudeUsageProviderUsesInjectedClockForRefreshAndExpiry() async throws {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        let keychainAccount = ProviderConfigurationStore.keychainAccount(for: configuration)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
                subscriptionType: "pro",
                expiresAt: 1_999_999_000_000,
                accessToken: "old-access",
                refreshToken: "old-refresh"
            )),
            account: keychainAccount
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            now: { now }
        )
        ProviderNetworkMockURLProtocol.handler = { request in
            if request.url?.path == "/v1/oauth/token" {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8)
                )
            }
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                Data(#"{"limits":[{"kind":"weekly_all","percent":25,"is_active":true}]}"#.utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)
        let persisted = try XCTUnwrap(
            ClaudeCredentialsParser.parse(try XCTUnwrap(secretStore.readSecret(account: keychainAccount)))
        )

        XCTAssertEqual(result.bars.first?.used, 25)
        XCTAssertEqual(persisted.accessToken, "new-access")
        XCTAssertEqual(persisted.expiresAt, 2_000_003_600_000)
    }

    func testClaudeUsageProviderPreservesCachedBarsAcrossTokenRefresh() async throws {
        let clock = TestDateProvider(Date(timeIntervalSince1970: 2_000_000_000))
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        let keychainAccount = ProviderConfigurationStore.keychainAccount(for: configuration)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
                subscriptionType: "pro",
                expiresAt: 2_000_000_030_000,
                accessToken: "old-access",
                refreshToken: "old-refresh"
            )),
            account: keychainAccount
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            now: { clock.now() }
        )
        var requestCount = 0
        ProviderNetworkMockURLProtocol.handler = { request in
            requestCount += 1
            switch requestCount {
            case 1:
                XCTAssertEqual(request.url?.path, "/api/oauth/usage")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer old-access")
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"limits":[{"kind":"weekly_all","percent":25,"is_active":true}]}"#.utf8)
                )
            case 2:
                XCTAssertEqual(request.url?.path, "/v1/oauth/token")
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8)
                )
            case 3:
                XCTAssertEqual(request.url?.path, "/api/oauth/usage")
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-access")
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"extra_usage":{"is_enabled":true,"used_credits":1250,"monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8)
                )
            default:
                XCTFail("Unexpected request \(request.url?.absoluteString ?? "nil")")
                throw URLError(.badURL)
            }
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let full = try await provider.fetchUsage(for: configuration)
        clock.advance(by: 60)
        let partialAfterRefresh = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 3)
        XCTAssertFalse(full.subtitle.contains("Cached rate-limit windows"))
        XCTAssertEqual(partialAfterRefresh.bars, full.bars)
        XCTAssertEqual(partialAfterRefresh.barsFetchedAt, full.fetchedAt)
        XCTAssertEqual(partialAfterRefresh.fetchedAt, full.fetchedAt.addingTimeInterval(60))
        XCTAssertFalse(partialAfterRefresh.hasFreshBars)
        XCTAssertTrue(partialAfterRefresh.subtitle.contains("Cached rate-limit windows"))
        XCTAssertEqual(
            partialAfterRefresh.monetaryMetrics.map(\.kind),
            [.spent, .spendLimit, .remainingHeadroom]
        )
    }

    func testClaudeUsageProviderPreservesStaleSnapshotOnRateLimitWithoutProbe() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
                subscriptionType: "pro",
                rateLimitTier: nil,
                expiresAt: 0,
                accessToken: "claude-token",
                refreshToken: nil
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let clock = TestDateProvider(Date(timeIntervalSince1970: 1_800_000_000))
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: urlSessionConfiguration),
            now: { clock.now() }
        )
        var requestCount = 0
        ProviderNetworkMockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            if requestCount == 1 {
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data(#"{"limits":[{"kind":"weekly_all","percent":36,"is_active":true}]}"#.utf8)
                )
            }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let fresh = try await provider.fetchUsage(for: configuration)
        let stale = try await provider.fetchUsage(for: configuration)
        let backedOff = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(fresh.bars, stale.bars)
        XCTAssertEqual(stale.bars, backedOff.bars)
        XCTAssertEqual(fresh.fetchedAt, stale.fetchedAt)
        XCTAssertTrue(stale.subtitle.contains("rate-limited"))
        XCTAssertTrue(stale.subtitle.contains("last known data"))

        clock.advance(by: 61)
        _ = try await provider.fetchUsage(for: configuration)
        XCTAssertEqual(requestCount, 3)
    }

    func testClaudeUsageProviderPreservesCachedBarsWhenOAuthUsageBecomesUnavailable() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(accessToken: "claude-token")),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration)
        )
        var requestCount = 0
        ProviderNetworkMockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            if requestCount == 1 {
                return (
                    HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data(#"{"limits":[{"kind":"weekly_all","percent":36,"is_active":true}]}"#.utf8)
                )
            }
            return (
                HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: 404, httpVersion: nil, headerFields: nil)!,
                Data()
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let fresh = try await provider.fetchUsage(for: configuration)
        let unavailable = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(unavailable.bars, fresh.bars)
        XCTAssertEqual(unavailable.barsFetchedAt, fresh.barsFetchedAt)
        XCTAssertEqual(
            unavailable.failureMessage,
            "Claude subscription usage is unavailable for this account."
        )
        XCTAssertTrue(unavailable.subtitle.contains("Showing last known data"))
    }

    func testClaudeUsageProviderClearsBackoffWhenCredentialChanges() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        let keychainAccount = ProviderConfigurationStore.keychainAccount(for: configuration)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(accessToken: "old-token")),
            account: keychainAccount
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration)
        )
        var requestCount = 0
        ProviderNetworkMockURLProtocol.handler = { request in
            requestCount += 1
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer old-token" {
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 429,
                        httpVersion: nil,
                        headerFields: ["Retry-After": "3600"]
                    )!,
                    Data()
                )
            }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-token")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"limits":[{"kind":"weekly_all","percent":24,"is_active":true}]}"#.utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let rateLimited = try await provider.fetchUsage(for: configuration)
        XCTAssertTrue(rateLimited.subtitle.contains("rate-limited"))

        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(accessToken: "new-token")),
            account: keychainAccount
        )
        let refreshed = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(refreshed.bars.first?.used, 24)
        XCTAssertFalse(refreshed.subtitle.contains("rate-limited"))
    }

    func testClaudeUsageProviderDoesNotProbeMessagesWhenOAuthUsageIsUnavailable() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(accessToken: "claude-token")),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration)
        )
        var requestCount = 0
        ProviderNetworkMockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 503,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{}"#.utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(result.subtitle, "Claude usage is temporarily unavailable (server error 503).")
    }

    func testClaudeUsageProviderReturnsOAuthOnlyStateWithoutMessagesProbe() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(accessToken: "claude-token")),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration)
        )
        var requestCount = 0
        ProviderNetworkMockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{"extra_usage":{"used_credits":1250,"monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(result.monetaryMetrics.map(\.kind), [.spent, .spendLimit, .remainingHeadroom])
        XCTAssertEqual(result.usageMessages, ["Usage-credit enabled status was not reported."])
    }

    func testClaudeUsageProviderPreservesCachedBarsAfterOAuthOnlyState() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(accessToken: "claude-token")),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let clock = TestDateProvider(Date(timeIntervalSince1970: 1_800_000_000))
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration),
            now: { clock.now() }
        )
        var requestCount = 0
        ProviderNetworkMockURLProtocol.handler = { request in
            requestCount += 1
            switch requestCount {
            case 1:
                XCTAssertEqual(request.url?.path, "/api/oauth/usage")
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data(#"{"limits":[{"kind":"weekly_all","percent":25,"is_active":true}]}"#.utf8)
                )
            case 2:
                XCTAssertEqual(request.url?.path, "/api/oauth/usage")
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data(#"{"extra_usage":{"is_enabled":true,"used_credits":1250,"monthly_limit":5000,"currency":"USD","decimal_places":2}}"#.utf8)
                )
            case 3:
                XCTAssertEqual(request.url?.path, "/api/oauth/usage")
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 429,
                        httpVersion: nil,
                        headerFields: ["Retry-After": "120"]
                    )!,
                    Data()
                )
            default:
                XCTFail("Unexpected request \(request.url?.absoluteString ?? "nil")")
                throw URLError(.badURL)
            }
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let full = try await provider.fetchUsage(for: configuration)
        clock.advance(by: 60)
        let partial = try await provider.fetchUsage(for: configuration)
        let stale = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 3)
        XCTAssertEqual(full.bars.first?.used, 25)
        XCTAssertFalse(full.subtitle.contains("Cached rate-limit windows"))
        XCTAssertEqual(partial.bars, full.bars)
        XCTAssertEqual(partial.fetchedAt, full.fetchedAt.addingTimeInterval(60))
        XCTAssertEqual(partial.barsFetchedAt, full.fetchedAt)
        XCTAssertFalse(partial.hasFreshBars)
        XCTAssertTrue(partial.subtitle.contains("Cached rate-limit windows"))
        XCTAssertEqual(partial.monetaryMetrics.map(\.kind), [.spent, .spendLimit, .remainingHeadroom])
        XCTAssertEqual(stale.bars, full.bars)
        XCTAssertTrue(stale.subtitle.contains("last known data"))

        let historySnapshot = UsageHistorySnapshot(result: partial)
        XCTAssertTrue(historySnapshot.bars.isEmpty)
        XCTAssertEqual(historySnapshot.capturedAt, partial.fetchedAt)
        XCTAssertEqual(historySnapshot.monetaryMetrics?.map(\.kind), [.spent, .spendLimit, .remainingHeadroom])
    }

    func testClaudeUsageProviderDoesNotSendMessagesRequestDuringOAuthBackoff() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(accessToken: "claude-token")),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration)
        )
        var requestCount = 0
        ProviderNetworkMockURLProtocol.handler = { request in
            requestCount += 1
            if requestCount == 1 {
                XCTAssertEqual(request.url?.path, "/api/oauth/usage")
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data(#"{"extra_usage":{"is_enabled":false}}"#.utf8)
                )
            }
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 429,
                    httpVersion: nil,
                    headerFields: ["Retry-After": "120"]
                )!,
                Data()
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let oauthOnly = try await provider.fetchUsage(for: configuration)
        let stale = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(oauthOnly.usageMessages, stale.usageMessages)
        XCTAssertTrue(stale.subtitle.contains("rate-limited"))
    }

    func testClaudeUsageProviderDistinguishesOAuthUsageFailures() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(
                accessToken: "claude-token"
            )),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let urlSessionConfiguration = URLSessionConfiguration.ephemeral
        urlSessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: urlSessionConfiguration)
        )
        var statusCode = 401
        var requestCount = 0
        ProviderNetworkMockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: statusCode,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let unauthorized = try await provider.fetchUsage(for: configuration)
        statusCode = 403
        let forbidden = try await provider.fetchUsage(for: configuration)
        statusCode = 404
        let missing = try await provider.fetchUsage(for: configuration)
        statusCode = 503
        let unavailable = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 4)
        XCTAssertEqual(unauthorized.subtitle, "Claude credential was rejected. Sign in again.")
        XCTAssertEqual(forbidden.subtitle, "Claude credential lacks permission to read subscription usage.")
        XCTAssertEqual(missing.subtitle, "Claude subscription usage is unavailable for this account.")
        XCTAssertEqual(unavailable.subtitle, "Claude usage is temporarily unavailable (server error 503).")
    }

    func testClaudeUsageProviderDoesNotProbeMessagesWhenOAuthPayloadIsUnrecognized() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(accessToken: "claude-token")),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration)
        )
        var requestCount = 0
        ProviderNetworkMockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data(#"{}"#.utf8)
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 1)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertEqual(result.subtitle, "Claude usage did not include rate-limit windows.")
    }

    func testClaudeUsageProviderPreservesCachedBarsWhenOAuthPayloadIsUnrecognized() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .claude)
        try secretStore.saveSecret(
            ClaudeCredentialsParser.storedCredential(from: ClaudeCredentials(accessToken: "claude-token")),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [ProviderNetworkMockURLProtocol.self]
        let provider = ClaudeUsageProvider(
            secretStore: secretStore,
            session: URLSession(configuration: sessionConfiguration)
        )
        var requestCount = 0
        ProviderNetworkMockURLProtocol.handler = { request in
            requestCount += 1
            XCTAssertEqual(request.url?.path, "/api/oauth/usage")
            let data = requestCount == 1
                ? Data(#"{"limits":[{"kind":"weekly_all","percent":25,"is_active":true}]}"#.utf8)
                : Data(#"{}"#.utf8)
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                data
            )
        }
        defer { ProviderNetworkMockURLProtocol.handler = nil }

        let fresh = try await provider.fetchUsage(for: configuration)
        let preserved = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(requestCount, 2)
        XCTAssertEqual(preserved.bars, fresh.bars)
        XCTAssertEqual(preserved.failureMessage, "Claude usage did not include rate-limit windows.")
        XCTAssertTrue(preserved.subtitle.contains("last known data"))
    }

}
