import Foundation

public final class CursorUsageProvider: UsageProvider {
    private let secretStore: SecretStore
    private let session: URLSession
    private let usageEndpoint: URL
    private let grokBotUsageEndpoint: URL

    public let providerID = ProviderID.cursor

    public init(
        secretStore: SecretStore = KeychainService(),
        session: URLSession = .shared,
        usageEndpoint: URL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!,
        grokBotUsageEndpoint: URL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus")!
    ) {
        self.secretStore = secretStore
        self.session = session
        self.usageEndpoint = usageEndpoint
        self.grokBotUsageEndpoint = grokBotUsageEndpoint
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        guard
            let storedSecret = try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration)),
            let accessToken = Self.normalizedAccessToken(from: storedSecret),
            !accessToken.isEmpty
        else {
            return failureResult("Not configured - sign in with Cursor.", configuration: configuration)
        }

        do {
            async let grokBotResponse = try? session.data(
                for: makeUsageRequest(
                    endpoint: grokBotUsageEndpoint,
                    accessToken: accessToken
                )
            )
            let (data, response) = try await session.data(for: makeUsageRequest(accessToken: accessToken))
            let grokBotData = Self.successfulResponseData(await grokBotResponse)
            guard let httpResponse = response as? HTTPURLResponse else {
                return failureResult("Cursor usage returned an invalid response.", configuration: configuration)
            }

            switch httpResponse.statusCode {
            case 200..<300:
                return Self.parseUsage(
                    data,
                    grokBotUsageData: grokBotData,
                    configuration: configuration
                )
                    ?? failureResult("Could not parse Cursor usage.", configuration: configuration)
            case 401, 403:
                return failureResult("Cursor rejected this session token. Sign in again.", configuration: configuration)
            case 429:
                return failureResult("Cursor rate limit reached. Try again later.", configuration: configuration)
            default:
                return failureResult("Cursor usage returned HTTP \(httpResponse.statusCode).", configuration: configuration)
            }
        } catch {
            return failureResult(error.localizedDescription, configuration: configuration)
        }
    }

    func makeUsageRequest(accessToken: String) -> URLRequest {
        makeUsageRequest(endpoint: usageEndpoint, accessToken: accessToken)
    }

    private func makeUsageRequest(endpoint: URL, accessToken: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.httpBody = Data("{}".utf8)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("CodexBarIOS/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func parseUsage(
        _ data: Data,
        grokBotUsageData: Data? = nil,
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date = Date()
    ) -> ProviderUsageResult? {
        guard let usage = try? JSONDecoder().decode(CursorCurrentPeriodUsage.self, from: data) else {
            return nil
        }

        var bars = buildUsageBars(usage, fetchedAt: fetchedAt)
        if let grokBotUsageData,
           let grokBotBar = buildGrokBotUsageBar(grokBotUsageData, fetchedAt: fetchedAt) {
            bars.append(grokBotBar)
        }
        guard !bars.isEmpty else {
            return nil
        }

        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: .cursor,
            title: configuration.displayName,
            subtitle: "Cursor plan usage",
            bars: bars,
            cardInformationSections: buildUsageInformationSections(usage.planUsage),
            fetchedAt: fetchedAt
        )
    }

    private static func successfulResponseData(_ response: (Data, URLResponse)?) -> Data? {
        guard let response else {
            return nil
        }
        let (data, urlResponse) = response
        guard
            let httpResponse = urlResponse as? HTTPURLResponse,
            (200..<300).contains(httpResponse.statusCode)
        else {
            return nil
        }
        return data
    }

    static func normalizedAccessToken(from storedSecret: String?) -> String? {
        guard var token = storedSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return nil
        }

        if token.hasPrefix("\""), token.hasSuffix("\""), token.count >= 2 {
            token.removeFirst()
            token.removeLast()
        }

        if let data = token.data(using: .utf8),
           let credentials = try? JSONDecoder().decode(CursorCredentials.self, from: data),
           let accessToken = credentials.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines),
           !accessToken.isEmpty {
            return accessToken
        }

        let authorizationPrefix = "authorization:"
        if token.lowercased().hasPrefix(authorizationPrefix) {
            token = String(token.dropFirst(authorizationPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let bearerPrefix = "bearer "
        if token.lowercased().hasPrefix(bearerPrefix) {
            token = String(token.dropFirst(bearerPrefix.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return token.isEmpty ? nil : token
    }

    private static func buildUsageBars(_ usage: CursorCurrentPeriodUsage, fetchedAt: Date) -> [UsageBar] {
        var bars: [UsageBar] = []
        let reset = parseUnixMilliseconds(usage.billingCycleEnd)
        let resetDescription = reset.map { formatReset($0, now: fetchedAt) }
        let billingPeriod = billingPeriod(for: usage, fetchedAt: fetchedAt)

        if let plan = usage.planUsage {
            bars.append(contentsOf: [
                usageBar(
                    stableKey: "total",
                    label: "Total",
                    percent: plan.totalPercentUsed,
                    reset: reset,
                    resetDescription: resetDescription,
                    billingPeriod: billingPeriod
                ),
                usageBar(
                    stableKey: "auto",
                    label: "Auto",
                    percent: plan.autoPercentUsed,
                    reset: reset,
                    resetDescription: resetDescription,
                    billingPeriod: billingPeriod
                ),
                usageBar(
                    stableKey: "api",
                    label: "API",
                    percent: plan.apiPercentUsed,
                    reset: reset,
                    resetDescription: resetDescription,
                    billingPeriod: billingPeriod
                ),
            ].compactMap { $0 })
        }

        if
            let onDemand = usage.spendLimitUsage,
            let limit = onDemand.individualLimit,
            limit > 0,
            let remaining = onDemand.individualRemaining {
            let used = max(0, limit - remaining)
            bars.append(UsageBar(
                stableKey: "on-demand",
                label: "On-demand \(formatCents(used)) / \(formatCents(limit))",
                used: used,
                limit: limit,
                resetDescription: resetDescription,
                resetsAt: reset,
                resetDisplayStyle: .shortLocalDate,
                projectionCurrent: billingPeriod == nil ? nil : used,
                projectionLimit: billingPeriod == nil ? nil : limit,
                projectionPeriodStart: billingPeriod?.start,
                projectionPeriodEnd: billingPeriod?.end,
                showProjectionOnCurrentBar: billingPeriod != nil
            ))
        }

        return bars
    }

    private static func buildGrokBotUsageBar(_ data: Data, fetchedAt: Date) -> UsageBar? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard
            let usage = try? decoder.decode(CursorGrokBotUsage.self, from: data),
            usage.usesPooledEnterpriseAllowance != true,
            let percent = usage.usagePercent,
            percent.isFinite
        else {
            return nil
        }

        let usedPercent = min(max(percent, 0), 100)
        let periodStart = parseTimestamp(usage.currentPeriodStart)
        let reset = parseTimestamp(usage.nextResetTimestampUtc)
        let hasCurrentPeriod = periodStart.map { $0 < fetchedAt } == true
            && reset.map { fetchedAt < $0 } == true

        return UsageBar(
            stableKey: "grok-bot-weekly",
            label: "Grok Bot weekly",
            used: usedPercent,
            limit: 100,
            resetDescription: reset.map { formatReset($0, now: fetchedAt) },
            resetsAt: reset,
            resetDisplayStyle: .shortLocalDate,
            projectionCurrent: hasCurrentPeriod ? usedPercent / 100 : nil,
            projectionLimit: hasCurrentPeriod ? 1 : nil,
            projectionPeriodStart: hasCurrentPeriod ? periodStart : nil,
            projectionPeriodEnd: hasCurrentPeriod ? reset : nil,
            showProjectionOnCurrentBar: hasCurrentPeriod
        )
    }

    private static func usageBar(
        stableKey: String,
        label: String,
        percent: Double?,
        reset: Date?,
        resetDescription: String?,
        billingPeriod: CursorBillingPeriod?
    ) -> UsageBar? {
        guard let percent else {
            return nil
        }

        let usedPercent = min(max(percent, 0), 100)
        return UsageBar(
            stableKey: stableKey,
            label: label,
            used: usedPercent,
            limit: 100,
            resetDescription: resetDescription,
            resetsAt: reset,
            resetDisplayStyle: .shortLocalDate,
            projectionCurrent: billingPeriod == nil ? nil : usedPercent / 100,
            projectionLimit: billingPeriod == nil ? nil : 1,
            projectionPeriodStart: billingPeriod?.start,
            projectionPeriodEnd: billingPeriod?.end,
            showProjectionOnCurrentBar: billingPeriod != nil
        )
    }

    private static func billingPeriod(
        for usage: CursorCurrentPeriodUsage,
        fetchedAt: Date
    ) -> CursorBillingPeriod? {
        guard
            let start = parseUnixMilliseconds(usage.billingCycleStart),
            let end = parseUnixMilliseconds(usage.billingCycleEnd),
            start < fetchedAt,
            fetchedAt < end
        else {
            return nil
        }

        return CursorBillingPeriod(start: start, end: end)
    }

    private static func buildUsageInformationSections(
        _ plan: CursorPlanUsage?
    ) -> [ProviderCardInformationSection] {
        guard let plan else {
            return []
        }

        let items = [
            plan.autoPercentUsed.map {
                ProviderCardInformationItem(
                    id: "cursor.included-usage.auto",
                    label: "Auto",
                    detail: formatPercent($0)
                )
            },
            plan.apiPercentUsed.map {
                ProviderCardInformationItem(
                    id: "cursor.included-usage.api",
                    label: "API",
                    detail: formatPercent($0)
                )
            },
            plan.totalPercentUsed.map {
                ProviderCardInformationItem(
                    id: "cursor.included-usage.total",
                    label: "Total",
                    detail: formatPercent($0)
                )
            },
        ].compactMap { $0 }

        guard !items.isEmpty else {
            return []
        }
        return [
            ProviderCardInformationSection(
                id: "cursor.included-usage",
                title: "Included usage",
                items: items
            ),
        ]
    }

    private static func parseUnixMilliseconds(_ value: String?) -> Date? {
        guard
            let value,
            let milliseconds = Double(value),
            milliseconds.isFinite,
            milliseconds > 0
        else {
            return nil
        }

        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func parseTimestamp(_ value: String?) -> Date? {
        guard let value else {
            return nil
        }
        if let unixTimestamp = parseUnixMilliseconds(value) {
            return unixTimestamp
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func formatReset(_ resetAt: Date, now _: Date) -> String {
        "Resets \(UserFacingDateTimeFormatter.current.shortDate(resetAt))"
    }

    private static func formatPercent(_ value: Double) -> String {
        "\(Int(min(max(value, 0), 100).rounded()))%"
    }

    private static func formatCents(_ cents: Double) -> String {
        let dollars = cents / 100
        return currencyFormatter.string(from: NSNumber(value: dollars)) ?? "$0.00"
    }

    private static let currencyFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()

    private func failureResult(_ message: String, configuration: ProviderAccountConfiguration) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .cursor,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            failureMessage: message,
            fetchedAt: Date()
        )
    }
}

private struct CursorCredentials: Decodable {
    let accessToken: String?
}

private struct CursorCurrentPeriodUsage: Decodable {
    let billingCycleStart: String?
    let billingCycleEnd: String?
    let planUsage: CursorPlanUsage?
    let spendLimitUsage: CursorSpendLimitUsage?
}

private struct CursorBillingPeriod {
    let start: Date
    let end: Date
}

private struct CursorPlanUsage: Decodable {
    let autoPercentUsed: Double?
    let apiPercentUsed: Double?
    let totalPercentUsed: Double?
}

private struct CursorSpendLimitUsage: Decodable {
    let individualLimit: Double?
    let individualRemaining: Double?
}

private struct CursorGrokBotUsage: Decodable {
    let currentPeriodStart: String?
    let nextResetTimestampUtc: String?
    let usagePercent: Double?
    let usesPooledEnterpriseAllowance: Bool?
}
