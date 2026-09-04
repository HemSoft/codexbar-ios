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
