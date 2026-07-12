import Foundation

public enum ClaudeUsageParser {
    private struct UsageResponse: Decodable {
        let fiveHour: UsageWindow?
        let sevenDay: UsageWindow?
        let sevenDayOAuthApps: UsageWindow?
        let sevenDayOpus: UsageWindow?
        let sevenDaySonnet: UsageWindow?
        let limits: [StructuredLimit]?
        let extraUsage: ExtraUsage?

        enum CodingKeys: String, CodingKey {
            case fiveHour = "five_hour"
            case sevenDay = "seven_day"
            case sevenDayOAuthApps = "seven_day_oauth_apps"
            case sevenDayOpus = "seven_day_opus"
            case sevenDaySonnet = "seven_day_sonnet"
            case limits
            case extraUsage = "extra_usage"
        }
    }

    private struct UsageWindow: Decodable {
        let utilization: Double?
        let resetsAt: String?

        enum CodingKeys: String, CodingKey {
            case utilization
            case resetsAt = "resets_at"
        }
    }

    private struct StructuredLimit: Decodable {
        let kind: String?
        let percent: Double?
        let resetsAt: String?
        let scope: LimitScope?
        let isActive: Bool?

        enum CodingKeys: String, CodingKey {
            case kind
            case percent
            case resetsAt = "resets_at"
            case scope
            case isActive = "is_active"
        }
    }

    private struct LimitScope: Decodable {
        let model: LimitModel?
    }

    private struct LimitModel: Decodable {
        let displayName: String?

        enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
        }
    }

    private struct ExtraUsage: Decodable {
        let isEnabled: Bool?
        let monthlyLimit: Decimal?
        let usedCredits: Decimal?
        let currency: String?
        let decimalPlaces: Int?
        let disabledReason: String?

        enum CodingKeys: String, CodingKey {
            case isEnabled = "is_enabled"
            case monthlyLimit = "monthly_limit"
            case usedCredits = "used_credits"
            case currency
            case decimalPlaces = "decimal_places"
            case disabledReason = "disabled_reason"
        }
    }

    public static func parse(
        _ data: Data,
        subscriptionType: String?,
        fetchedAt: Date = Date(),
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) -> ProviderUsageResult? {
        guard let usage = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
            return nil
        }

        var bars: [UsageBar] = []
        var semanticKeys = Set<String>()
        var usageMessages: [String] = []

        for limit in usage.limits ?? [] where limit.isActive != false {
            guard let percent = limit.percent else {
                continue
            }

            let definition: (key: String, label: String, duration: TimeInterval, scopedName: String?)?
            switch limit.kind {
            case "session":
                definition = ("session", "5 hour usage limit", 18_000, nil)
            case "weekly_all":
                definition = ("weekly-all", "Weekly usage limit", 604_800, nil)
            case "weekly_scoped":
                guard let modelName = sanitizedModelName(limit.scope?.model?.displayName) else {
                    continue
                }
                let key = "weekly-scoped-\(normalizedKey(modelName))"
                definition = (key, "\(modelName) weekly limit", 604_800, modelName)
            default:
                definition = nil
            }

            guard
                let definition,
                semanticKeys.insert(definition.key).inserted
            else {
                continue
            }
            let fallbackKey = definition.scopedName.flatMap(legacyScopedKey(for:)) ?? definition.key
            bars.append(usageBar(
                label: definition.label,
                usedPercent: sanitizedPercent(percent),
                reset: parseReset(limit.resetsAt) ?? legacyReset(for: fallbackKey, usage: usage),
                durationSeconds: definition.duration,
                fetchedAt: fetchedAt,
                dateTimeFormatter: dateTimeFormatter
            ))
            if let scopedName = definition.scopedName {
                if let legacyKey = legacyScopedKey(for: scopedName) {
                    semanticKeys.insert(legacyKey)
                }
                usageMessages.append("\(scopedName) usage is capped within the all-model weekly allowance.")
            }
        }

        appendLegacyBar(
            key: "session",
            label: "5 hour usage limit",
            window: usage.fiveHour,
            durationSeconds: 18_000,
            semanticKeys: &semanticKeys,
            bars: &bars,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        )
        appendLegacyBar(
            key: "weekly-all",
            label: "Weekly usage limit",
            window: usage.sevenDay ?? usage.sevenDayOAuthApps,
            durationSeconds: 604_800,
            semanticKeys: &semanticKeys,
            bars: &bars,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        )
        appendLegacyBar(
            key: "weekly-scoped-sonnet",
            label: "Sonnet weekly limit",
            window: usage.sevenDaySonnet,
            durationSeconds: 604_800,
            semanticKeys: &semanticKeys,
            bars: &bars,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        )
        appendLegacyBar(
            key: "weekly-scoped-opus",
            label: "Opus weekly limit",
            window: usage.sevenDayOpus,
            durationSeconds: 604_800,
            semanticKeys: &semanticKeys,
            bars: &bars,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        )

        let extraUsage = extraUsageMetrics(from: usage.extraUsage)
        usageMessages.append(contentsOf: extraUsage.messages)

        guard !bars.isEmpty || !extraUsage.metrics.isEmpty || !usageMessages.isEmpty else {
            return nil
        }

        return ProviderUsageResult(
            providerID: .claude,
            title: formatDisplayName(subscriptionType: subscriptionType),
            subtitle: "Live Claude usage",
            bars: bars,
            monetaryMetrics: extraUsage.metrics,
            usageMessages: uniqueMessages(usageMessages),
            fetchedAt: fetchedAt
        )
    }

    public static func parseRateLimitHeaders(
        _ fields: [AnyHashable: Any],
        subscriptionType: String?,
        fetchedAt: Date = Date(),
        dateTimeFormatter: UserFacingDateTimeFormatter = .current
    ) -> ProviderUsageResult? {
        var bars: [UsageBar] = []
        if let bar = usageBarFromHeaders(
            label: "5 hour usage limit",
            utilizationKey: "anthropic-ratelimit-unified-5h-utilization",
            resetKey: "anthropic-ratelimit-unified-5h-reset",
            durationSeconds: 18_000,
            fields: fields,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        ) {
            bars.append(bar)
        }

        if let bar = usageBarFromHeaders(
            label: "Weekly usage limit",
            utilizationKey: "anthropic-ratelimit-unified-7d-utilization",
            resetKey: "anthropic-ratelimit-unified-7d-reset",
            durationSeconds: 604_800,
            fields: fields,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        ) {
            bars.append(bar)
        }

        guard !bars.isEmpty else {
            return nil
        }

        return ProviderUsageResult(
            providerID: .claude,
            title: formatDisplayName(subscriptionType: subscriptionType),
            subtitle: "Live Claude usage",
            bars: bars,
            fetchedAt: fetchedAt
        )
    }

    private static func usageBar(
        label: String,
        window: UsageWindow?,
        durationSeconds: TimeInterval,
        fetchedAt: Date,
        dateTimeFormatter: UserFacingDateTimeFormatter
    ) -> UsageBar? {
        guard let utilization = window?.utilization else {
            return nil
        }

        return usageBar(
            label: label,
            usedPercent: normalizedOAuthPercent(utilization),
            reset: parseReset(window?.resetsAt),
            durationSeconds: durationSeconds,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        )
    }

    private static func usageBarFromHeaders(
        label: String,
        utilizationKey: String,
        resetKey: String,
        durationSeconds: TimeInterval,
        fields: [AnyHashable: Any],
        fetchedAt: Date,
        dateTimeFormatter: UserFacingDateTimeFormatter
    ) -> UsageBar? {
        guard
            let utilization = doubleHeader(fields[utilizationKey]),
            let reset = epochHeader(fields[resetKey])
        else {
            return nil
        }

        return usageBar(
            label: label,
            usedPercent: normalizedHeaderPercent(utilization),
            reset: reset,
            durationSeconds: durationSeconds,
            fetchedAt: fetchedAt,
            dateTimeFormatter: dateTimeFormatter
        )
    }

    private static func usageBar(
        label: String,
        usedPercent: Double,
        reset: Date?,
        durationSeconds: TimeInterval,
        fetchedAt: Date,
        dateTimeFormatter: UserFacingDateTimeFormatter
    ) -> UsageBar {
        return UsageBar(
            label: label,
            used: usedPercent,
            limit: 100,
            resetDescription: reset.map { formatReset(
                $0,
                now: fetchedAt,
                dateTimeFormatter: dateTimeFormatter
            ) },
            resetsAt: reset,
            resetDisplayStyle: .relativeWithLocalTime,
            projectionCurrent: reset == nil ? nil : usedPercent / 100,
            projectionLimit: reset == nil ? nil : 1,
            projectionPeriodStart: reset?.addingTimeInterval(-durationSeconds),
            projectionPeriodEnd: reset,
            showProjectionOnCurrentBar: reset != nil
        )
    }

    private static func appendLegacyBar(
        key: String,
        label: String,
        window: UsageWindow?,
        durationSeconds: TimeInterval,
        semanticKeys: inout Set<String>,
        bars: inout [UsageBar],
        fetchedAt: Date,
        dateTimeFormatter: UserFacingDateTimeFormatter
    ) {
        guard
            !semanticKeys.contains(key),
            let bar = usageBar(
                label: label,
                window: window,
                durationSeconds: durationSeconds,
                fetchedAt: fetchedAt,
                dateTimeFormatter: dateTimeFormatter
            )
        else {
            return
        }
        semanticKeys.insert(key)
        bars.append(bar)
    }

    private static func extraUsageMetrics(
        from extraUsage: ExtraUsage?
    ) -> (metrics: [ProviderMonetaryMetric], messages: [String]) {
        guard let extraUsage else {
            return ([], [])
        }
        if extraUsage.isEnabled == false {
            let reason = extraUsage.disabledReason?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let reason, !reason.isEmpty {
                return ([], ["Usage credits are disabled: \(reason)."])
            }
            return ([], ["Usage credits are disabled."])
        }
        let reportedCurrency = extraUsage.currency?.trimmingCharacters(in: .whitespacesAndNewlines)
        let currency = reportedCurrency.flatMap { $0.isEmpty ? nil : $0 } ?? "USD"
        guard currency.count == 3, let usedCredits = extraUsage.usedCredits else {
            return ([], ["Usage credits are enabled, but monetary details are temporarily unavailable."])
        }
        let decimalPlaces = extraUsage.decimalPlaces ?? currencyDecimalPlaces(currency)

        let spent = max(usedCredits, 0)
        var metrics = [ProviderMonetaryMetric(
            kind: .spent,
            label: "Usage credits spent",
            minorUnits: spent,
            currencyCode: currency,
            decimalPlaces: decimalPlaces,
            detail: "Month to date"
        )]
        var messages: [String] = extraUsage.isEnabled == nil
            ? ["Usage-credit enabled status was not reported."]
            : []

        if let monthlyLimit = extraUsage.monthlyLimit {
            let limit = max(monthlyLimit, 0)
            metrics.append(ProviderMonetaryMetric(
                kind: .spendLimit,
                label: "Monthly spend limit",
                minorUnits: limit,
                currencyCode: currency,
                decimalPlaces: decimalPlaces,
                detail: "Usage-credit policy cap"
            ))
            metrics.append(ProviderMonetaryMetric(
                kind: .remainingHeadroom,
                label: "Remaining spend headroom",
                minorUnits: max(limit - spent, 0),
                currencyCode: currency,
                decimalPlaces: decimalPlaces,
                detail: "Not a prepaid balance"
            ))
            if limit > 0, spent >= limit {
                messages.append("The monthly usage-credit spend limit has been reached.")
            }
        } else {
            messages.append("Usage credits are enabled with no monthly spend limit reported.")
        }
        return (metrics, messages)
    }

    private static func uniqueMessages(_ messages: [String]) -> [String] {
        var seen = Set<String>()
        return messages.filter { seen.insert($0).inserted }
    }

    // OAuth legacy windows have shipped both 0...1 fractions and percentage values such as 15 and 36.
    private static func normalizedOAuthPercent(_ value: Double) -> Double {
        sanitizedPercent(value <= 1 ? value * 100 : value)
    }

    private static func normalizedHeaderPercent(_ value: Double) -> Double {
        sanitizedPercent(min(value, 1) * 100)
    }

    private static func currencyDecimalPlaces(_ currencyCode: String) -> Int {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode.uppercased()
        return formatter.maximumFractionDigits
    }

    private static func sanitizedPercent(_ value: Double) -> Double {
        value.isFinite ? max(value, 0) : 0
    }

    private static func sanitizedModelName(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func normalizedKey(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func legacyScopedKey(for modelName: String) -> String? {
        let key = normalizedKey(modelName)
        if key.contains("sonnet") {
            return "weekly-scoped-sonnet"
        }
        if key.contains("opus") {
            return "weekly-scoped-opus"
        }
        return nil
    }

    private static func legacyReset(for key: String, usage: UsageResponse) -> Date? {
        let window: UsageWindow?
        switch key {
        case "session":
            window = usage.fiveHour
        case "weekly-all":
            window = usage.sevenDay ?? usage.sevenDayOAuthApps
        case "weekly-scoped-sonnet":
            window = usage.sevenDaySonnet
        case "weekly-scoped-opus":
            window = usage.sevenDayOpus
        default:
            window = nil
        }
        return parseReset(window?.resetsAt)
    }

    private static func parseReset(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else {
            return nil
        }

        if let epoch = Double(value) {
            let seconds = epoch >= 1_000_000_000_000 ? epoch / 1000 : epoch
            return Date(timeIntervalSince1970: seconds)
        }

        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractionalFormatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }

    private static func doubleHeader(_ value: Any?) -> Double? {
        if let value = value as? String {
            return Double(value)
        }

        if let value = value as? NSNumber {
            return value.doubleValue
        }

        return nil
    }

    private static func epochHeader(_ value: Any?) -> Date? {
        guard let rawValue = doubleHeader(value) else {
            return nil
        }

        let seconds = rawValue >= 1_000_000_000_000 ? rawValue / 1000 : rawValue
        return Date(timeIntervalSince1970: seconds)
    }

    private static func formatReset(
        _ resetAt: Date,
        now: Date,
        dateTimeFormatter: UserFacingDateTimeFormatter
    ) -> String {
        dateTimeFormatter.resetDescription(
            resetAt: resetAt,
            now: now,
            style: .relativeWithLocalTime,
            fallback: nil
        ) ?? "Resets now"
    }

    private static func formatDisplayName(subscriptionType: String?) -> String {
        guard
            let subscriptionType,
            !subscriptionType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return ProviderID.claude.displayName
        }

        return "\(ProviderID.claude.displayName) (\(formatPlanName(subscriptionType)))"
    }

    private static func formatPlanName(_ value: String) -> String {
        value
            .replacingOccurrences(of: "_", with: " ")
            .split(separator: " ")
            .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
            .joined(separator: " ")
    }
}
