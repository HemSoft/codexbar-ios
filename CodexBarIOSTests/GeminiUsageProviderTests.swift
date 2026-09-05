import XCTest
@testable import CodexBarIOS

final class GeminiUsageProviderTests: XCTestCase {
    func testCredentialParserKeepsOnlyRequiredSessionCookies() throws {
        let stored = try GeminiSessionCredentialsParser.storedCredential(
            from: "Cookie: SID=discard; __Secure-1PSID=primary-value; "
                + "__Secure-1PSIDTS=rotating-value; OTHER=discard"
        )

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [String: String]
        )
        XCTAssertEqual(
            object,
            [
                "__Secure-1PSID": "primary-value",
                "__Secure-1PSIDTS": "rotating-value",
            ]
        )
        XCTAssertFalse(stored.contains("discard"))
    }

    func testCredentialParserRejectsMissingPrimaryCookie() {
        XCTAssertThrowsError(
            try GeminiSessionCredentialsParser.storedCredential(
                from: "Cookie: __Secure-1PSIDTS=rotating-value"
            )
        )
    }

    func testCredentialParserAcceptsJSONAndKeepsOnlySupportedValues() throws {
        let stored = try GeminiSessionCredentialsParser.storedCredential(
            from: #"{"__Secure-1PSID":"primary-value","__Secure-1PSIDTS":"rotating-value","SID":"discard"}"#
        )

        XCTAssertEqual(
            try GeminiSessionCredentialsParser.parse(stored),
            GeminiSessionCredentials(
                securePSID: "primary-value",
                securePSIDTS: "rotating-value"
            )
        )
        XCTAssertFalse(stored.contains("discard"))
    }

    func testProviderFetchesFiveHourAndWeeklyUsage() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            id: "gemini.personal",
            providerID: .gemini,
            accountLabel: "Personal Gemini",
            authMethod: .apiKey
        )
        try secretStore.saveSecret(
            GeminiSessionCredentialsParser.storedCredential(
                from: "__Secure-1PSID=primary-value; __Secure-1PSIDTS=rotating-value; SID=discard"
            ),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let sessionFixture = IsolatedTestURLSession { request in
            XCTAssertEqual(
                request.value(forHTTPHeaderField: "Cookie"),
                "__Secure-1PSID=primary-value; __Secure-1PSIDTS=rotating-value"
            )
            XCTAssertFalse(request.value(forHTTPHeaderField: "Cookie")?.contains("SID=discard") == true)

            if request.url?.path == "/usage" {
                XCTAssertEqual(request.httpMethod, "GET")
                let html = #"<script>window.WIZ_global_data={"SNlM0e":"at-token","cfb2h":"build-token","FdrFJe":"session-token"};</script><div>Google AI Pro</div>"#
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data(html.utf8)
                )
            }

            XCTAssertEqual(request.url?.path, "/_/BardChatUi/data/batchexecute")
            XCTAssertEqual(request.httpMethod, "POST")
            let queryItems = URLComponents(
                url: try XCTUnwrap(request.url),
                resolvingAgainstBaseURL: false
            )?.queryItems
            XCTAssertEqual(queryItems?.first { $0.name == "rpcids" }?.value, "jSf9Qc")
            XCTAssertEqual(queryItems?.first { $0.name == "source-path" }?.value, "/usage")
            XCTAssertEqual(queryItems?.first { $0.name == "bl" }?.value, "build-token")
            XCTAssertEqual(queryItems?.first { $0.name == "f.sid" }?.value, "session-token")
            let requestData = try XCTUnwrap(requestBodyData(from: request))
            let body = try XCTUnwrap(String(bytes: requestData, encoding: .utf8))
            XCTAssertTrue(body.contains("at=at-token"))
            XCTAssertTrue(body.contains("jSf9Qc"))

            let payload: [Any] = [
                2,
                [
                    [48_106, 0.005_726_25, 2, [[1_781_646_433, 197_701_000]]],
                    [2_400, 0.25, 1, [[1_781_135_233, 197_509_000]]],
                ],
                false,
            ]
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                try makeGeminiBatchResponse(payload)
            )
        }
        defer { sessionFixture.invalidate() }

        let result = try await GeminiUsageProvider(
            secretStore: secretStore,
            session: sessionFixture.session
        ).fetchUsage(for: configuration)

        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(result.providerID, .gemini)
        XCTAssertEqual(result.accountID, configuration.id)
        XCTAssertEqual(result.title, "Personal Gemini")
        XCTAssertNil(result.plan)
        XCTAssertEqual(result.bars.map(\.stableKey), ["five-hour", "weekly"])
        let fiveHour = try XCTUnwrap(result.bars.first)
        let weekly = try XCTUnwrap(result.bars.dropFirst().first)
        XCTAssertEqual(fiveHour.used, 25, accuracy: 0.000_001)
        XCTAssertEqual(fiveHour.resetsAt, Date(timeIntervalSince1970: 1_781_135_233))
        XCTAssertEqual(weekly.used, 0.572_625, accuracy: 0.000_001)
        XCTAssertEqual(weekly.resetsAt, Date(timeIntervalSince1970: 1_781_646_433))
    }

    func testUsageParserIgnoresUnknownSiblingBucket() throws {
        let payload: [Any] = [
            2,
            [
                [48_106, 0.5, 2, [[1_781_646_433, 0]]],
                [2_400, 0.25, 1, [[1_781_135_233, 0]]],
                [10, 0, 4, NSNull(), NSNull(), [[1_781_732_833, 0], 4]],
            ],
            false,
        ]

        let parsed = try XCTUnwrap(GeminiUsageProvider.parseUsageResponse(makeGeminiBatchResponse(payload)))
        XCTAssertEqual(parsed.fiveHour?.fractionUsed, 0.25)
        XCTAssertEqual(parsed.weekly?.fractionUsed, 0.5)
    }

    func testUsageParserRejectsFractionalAndOutOfRangePeriods() throws {
        let payload: [Any] = [
            2,
            [
                [2_400, 0.75, 1.5, [[1_781_135_233, 0]]],
                [2_400, 0.5, 1e300, [[1_781_135_233, 0]]],
                [48_106, 0.25, 2, [[1_781_646_433, 0]]],
            ],
            false,
        ]

        let parsed = try XCTUnwrap(GeminiUsageProvider.parseUsageResponse(makeGeminiBatchResponse(payload)))
        XCTAssertNil(parsed.fiveHour)
        XCTAssertEqual(parsed.weekly?.fractionUsed, 0.25)
    }

    func testProviderPropagatesCancelledRequests() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            id: "gemini.cancelled",
            providerID: .gemini,
            authMethod: .apiKey
        )
        try secretStore.saveSecret(
            GeminiSessionCredentialsParser.storedCredential(from: "__Secure-1PSID=session-value"),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let sessionFixture = IsolatedTestURLSession { _ in
            throw URLError(.cancelled)
        }
        defer { sessionFixture.invalidate() }

        do {
            _ = try await GeminiUsageProvider(
                secretStore: secretStore,
                session: sessionFixture.session
            ).fetchUsage(for: configuration)
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // Expected.
        }
    }

    func testProviderTreatsSignInRedirectAsExpiredCredentials() async throws {
        let secretStore = MemorySecretStore()
        let configuration = ProviderAccountConfiguration(
            id: "gemini.expired",
            providerID: .gemini,
            authMethod: .apiKey
        )
        try secretStore.saveSecret(
            GeminiSessionCredentialsParser.storedCredential(from: "__Secure-1PSID=expired-value"),
            account: ProviderConfigurationStore.keychainAccount(for: configuration)
        )

        let sessionFixture = IsolatedTestURLSession { request in
            (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 302,
                    httpVersion: nil,
                    headerFields: nil
                )!,
                Data()
            )
        }
        defer { sessionFixture.invalidate() }

        let result = try await GeminiUsageProvider(
            secretStore: secretStore,
            session: sessionFixture.session
        ).fetchUsage(for: configuration)

        XCTAssertEqual(result.recoveryAction, .reauthenticate)
        XCTAssertTrue(result.failureMessage?.contains("sign in") == true)
        XCTAssertTrue(result.preserveCachedBarsOnFailure)
    }

    func testProviderTreatsUsageRPCPermissionDeniedAsExpiredCredentials() async throws {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .gemini)
        let (provider, sessionFixture) = try makeGeminiFixtureProvider(
            responseData: geminiPermissionDeniedFixture,
            configuration: configuration
        )
        defer { sessionFixture.invalidate() }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.recoveryAction, .reauthenticate)
        XCTAssertEqual(
            result.failureMessage,
            "Gemini rejected these session credentials. Sign in again with Google."
        )
        XCTAssertEqual(result.subtitle, result.failureMessage)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertTrue(result.preserveCachedBarsOnFailure)
        for marker in ["fixture-account", "fixture-cookie", "fixture-token", "fixture-trace", "__Secure-1PSID"] {
            XCTAssertFalse(result.failureMessage?.contains(marker) == true)
        }
    }

    @MainActor
    func testUsageRPCPermissionDeniedPreservesStaleCachedBars() async throws {
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .gemini)
        let (provider, sessionFixture) = try makeGeminiFixtureProvider(
            responseData: geminiPermissionDeniedFixture,
            configuration: configuration
        )
        defer { sessionFixture.invalidate() }
        let cachedResult = ProviderUsageResult(
            accountID: configuration.id,
            providerID: .gemini,
            title: configuration.displayName,
            subtitle: "Gemini Apps usage",
            bars: [
                UsageBar(stableKey: "five-hour", label: "5-hour usage limit", used: 25, limit: 100),
                UsageBar(stableKey: "weekly", label: "Weekly usage limit", used: 50, limit: 100),
            ],
            fetchedAt: Date(timeIntervalSince1970: 1_781_000_000)
        )
        let service = UsageRefreshService(providers: [provider], initialResults: [cachedResult])

        _ = await service.refresh(configuration: configuration)

        let preserved = try XCTUnwrap(service.results.first)
        XCTAssertEqual(preserved.bars, cachedResult.bars)
        XCTAssertEqual(preserved.barsFetchedAt, cachedResult.barsFetchedAt)
        XCTAssertFalse(preserved.hasFreshBars)
        XCTAssertEqual(preserved.recoveryAction, .reauthenticate)
        XCTAssertNotNil(preserved.failureMessage)
    }

    func testUnknownAndMalformedRPCEnvelopesFailClosedWithoutReauthentication() async throws {
        let responses = [
            #"[["wrb.fr","otherRPC",null,null,null,[7],"generic"]]"#,
            #"[["wrb.fr","jSf9Qc",null,null,null,[6],"generic"]]"#,
            #"[["wrb.fr","jSf9Qc",null,null,null,[7.5],"generic"]]"#,
            #"[["wrb.fr","jSf9Qc",null,null,null,["7"],"generic"]]"#,
            #"[["wrb.fr","jSf9Qc",null,null,null,[true],"generic"]]"#,
            #"[["wrb.fr","jSf9Qc",null,null,null,7,"generic"]]"#,
            #"[["wrb.fr","jSf9Qc",null,null,null,[],"generic"]]"#,
            #"[["wrb.fr","jSf9Qc",null,null,null,null,"generic"]]"#,
            #"[["wrb.fr","jSf9Qc",null]]"#,
            #"[["wrb.fr","jSf9Qc"]]"#,
            #"[["wrb.fr","jSf9Qc",null],["unknown","jSf9Qc",null,null,null,[7]]]"#,
            #"[["wrb.fr","jSf9Qc",null,null,null,[7],"generic"]"#,
            #"[["wrb.fr","jSf9Qc","{}",null,null,null,"generic"]]"#,
            "[]",
        ]
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .gemini)
        for response in responses {
            let (provider, sessionFixture) = try makeGeminiFixtureProvider(
                responseData: Data(response.utf8),
                configuration: configuration
            )
            defer { sessionFixture.invalidate() }

            let result = try await provider.fetchUsage(for: configuration)

            XCTAssertEqual(result.recoveryAction, .retryRefresh, response)
            XCTAssertEqual(
                result.failureMessage,
                "Gemini's usage response format changed. No limit values were saved.",
                response
            )
            XCTAssertTrue(result.bars.isEmpty, response)
            XCTAssertTrue(result.preserveCachedBarsOnFailure, response)
        }
    }

    func testUnrelatedRPCRejectionDoesNotDiscardValidUsage() async throws {
        let payload: [Any] = [
            2,
            [[2_400, 0.25, 1, [[1_781_135_233, 0]]], [48_106, 0.5, 2, [[1_781_646_433, 0]]]],
            false,
        ]
        let unrelatedRejection = #"[["wrb.fr","otherRPC",null,null,null,[7],"generic"]]"#
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .gemini)
        let (provider, sessionFixture) = try makeGeminiFixtureProvider(
            responseData: Data(unrelatedRejection.utf8) + makeGeminiBatchResponse(payload),
            configuration: configuration
        )
        defer { sessionFixture.invalidate() }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertNil(result.failureMessage)
        XCTAssertEqual(result.bars.map(\.stableKey), ["five-hour", "weekly"])
        XCTAssertEqual(result.bars.map(\.used), [25, 50])
    }

    func testUsageRPCPermissionDeniedTakesPrecedenceOverValidUsage() async throws {
        let payload: [Any] = [2, [[2_400, 0.25, 1, [[1_781_135_233, 0]]]], false]
        let configuration = ProviderAccountConfiguration.defaultConfiguration(for: .gemini)
        let (provider, sessionFixture) = try makeGeminiFixtureProvider(
            responseData: makeGeminiBatchResponse(payload) + geminiPermissionDeniedFixture,
            configuration: configuration
        )
        defer { sessionFixture.invalidate() }

        let result = try await provider.fetchUsage(for: configuration)

        XCTAssertEqual(result.recoveryAction, .reauthenticate)
        XCTAssertNotNil(result.failureMessage)
        XCTAssertTrue(result.bars.isEmpty)
        XCTAssertTrue(result.preserveCachedBarsOnFailure)
    }
}

// Synthetic account, credential, and trace markers exercise response privacy.
private let geminiPermissionDeniedFixture = Data(
    """
    )]}'

    [["wrb.fr","jSf9Qc",null,null,null,[7,null,["fixture-account@example.invalid","__Secure-1PSID=fixture-cookie","fixture-token","fixture-trace"]],"generic"],["di",199]]
    """.utf8
)

private func makeGeminiFixtureProvider(
    responseData: Data,
    configuration: ProviderAccountConfiguration
) throws -> (GeminiUsageProvider, IsolatedTestURLSession) {
    let secretStore = MemorySecretStore()
    try secretStore.saveSecret(
        GeminiSessionCredentialsParser.storedCredential(from: "__Secure-1PSID=fixture-cookie"),
        account: ProviderConfigurationStore.keychainAccount(for: configuration)
    )
    let sessionFixture = IsolatedTestURLSession { request in
        let data = request.url?.path == "/usage"
            ? Data(#"<script>window.WIZ_global_data={"SNlM0e":"fixture-token"};</script>"#.utf8)
            : responseData
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
    return (
        GeminiUsageProvider(secretStore: secretStore, session: sessionFixture.session),
        sessionFixture
    )
}

private func makeGeminiBatchResponse(_ payload: [Any]) throws -> Data {
    let payloadData = try JSONSerialization.data(withJSONObject: payload)
    let payloadString = try XCTUnwrap(String(bytes: payloadData, encoding: .utf8))
    let rows: [Any] = [
        ["wrb.fr", "jSf9Qc", payloadString, NSNull(), NSNull(), NSNull(), "generic"],
        ["di", 199],
    ]
    let rowsData = try JSONSerialization.data(withJSONObject: rows)
    let rowsString = try XCTUnwrap(String(bytes: rowsData, encoding: .utf8))
    return Data(")]}'\n\n\(rowsString)\n".utf8)
}
