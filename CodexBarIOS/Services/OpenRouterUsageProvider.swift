import Foundation

public final class OpenRouterUsageProvider: UsageProvider {
    private let secretStore: SecretStore
    private let session: URLSession
    private let creditsEndpoint: URL

    public let providerID = ProviderID.openRouter

    public init(
        secretStore: SecretStore = KeychainService(),
        session: URLSession = .shared,
        creditsEndpoint: URL = URL(string: "https://openrouter.ai/api/v1/credits")!
    ) {
        self.secretStore = secretStore
        self.session = session
        self.creditsEndpoint = creditsEndpoint
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        guard
            let storedSecret = try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration)),
            let apiKey = Self.normalizedAPIKey(from: storedSecret),
            !apiKey.isEmpty
        else {
            return failureResult("Not configured - enter API key.", configuration: configuration)
        }

        do {
            let (data, response) = try await session.data(for: makeCreditsRequest(apiKey: apiKey))
            guard let httpResponse = response as? HTTPURLResponse else {
                return failureResult("OpenRouter balance returned an invalid response.", configuration: configuration)
            }

            switch httpResponse.statusCode {
            case 200..<300:
                return Self.parseCredits(data, configuration: configuration)
                    ?? failureResult("Could not parse OpenRouter balance.", configuration: configuration)
            case 401, 403:
                return failureResult("OpenRouter rejected this API key.", configuration: configuration)
            case 429:
                return failureResult("OpenRouter rate limit reached. Try again later.", configuration: configuration)
            default:
                return failureResult("OpenRouter balance returned HTTP \(httpResponse.statusCode).", configuration: configuration)
            }
        } catch {
            return failureResult(error.localizedDescription, configuration: configuration)
        }
    }

    func makeCreditsRequest(apiKey: String) -> URLRequest {
        var request = URLRequest(url: creditsEndpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBarIOS/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("CodexBar", forHTTPHeaderField: "X-Title")
        return request
    }

    static func parseCredits(
        _ data: Data,
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date = Date()
    ) -> ProviderUsageResult? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let payload = root["data"] as? [String: Any]
        else {
            return nil
        }

        guard
            let totalCredits = number(from: payload["total_credits"]),
            let totalUsage = number(from: payload["total_usage"])
        else {
            return nil
        }

        let balance = totalCredits - totalUsage

        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openRouter,
            title: configuration.displayName,
            subtitle: "Credit balance",
            bars: [],
            creditsRemaining: balance,
            fetchedAt: fetchedAt
        )
    }

    static func normalizedAPIKey(from storedSecret: String?) -> String? {
        guard var key = storedSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
            return nil
        }

        if key.hasPrefix("\""), key.hasSuffix("\""), key.count >= 2 {
            key.removeFirst()
            key.removeLast()
        }

        let authorizationPrefix = "authorization:"
        if key.lowercased().hasPrefix(authorizationPrefix) {
            key = String(key.dropFirst(authorizationPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let bearerPrefix = "bearer "
        if key.lowercased().hasPrefix(bearerPrefix) {
            key = String(key.dropFirst(bearerPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return key.isEmpty ? nil : key
    }

    private static func number(from value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            number.doubleValue
        case let string as String:
            Double(string)
        default:
            nil
        }
    }

    private static func string(from value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func failureResult(_ message: String, configuration: ProviderAccountConfiguration) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openRouter,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            failureMessage: message,
            fetchedAt: Date()
        )
    }
}
