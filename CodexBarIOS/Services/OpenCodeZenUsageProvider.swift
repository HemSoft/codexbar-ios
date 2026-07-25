import CryptoKit
import Foundation

private struct OpenCodeGoWindow {
    let stableKey: String
    let label: String
    let usagePercent: Double
    let resetInSeconds: TimeInterval
}

private enum OpenCodeBalanceFetchOutcome {
    case value(Double)
    case failure(String)
}

private enum OpenCodeGoPageOutcome {
    case subscribed([OpenCodeGoWindow])
    case notSubscribed
    case otherWorkspaceMember
    case failure(String)
}

public final class OpenCodeZenUsageProvider: UsageProvider {
    private let secretStore: SecretStore
    private let session: URLSession
    private let dashboardBaseURL: URL

    public let providerID = ProviderID.openCodeZen

    public init(
        secretStore: SecretStore = KeychainService(),
        session: URLSession = .shared,
        dashboardBaseURL: URL = URL(string: "https://opencode.ai")!
    ) {
        self.secretStore = secretStore
        self.session = session
        self.dashboardBaseURL = dashboardBaseURL
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        let storedSecret = try secretStore.readSecret(account: ProviderConfigurationStore.keychainAccount(for: configuration))
        guard let workspaceId = Self.normalizedWorkspaceId(from: configuration.openCodeWorkspaceId)
            ?? Self.workspaceId(fromCredentialPayload: storedSecret)
        else {
            return failureResult("Not configured - enter OpenCode workspace ID.", configuration: configuration)
        }

        guard let balanceCredential = Self.normalizedAPIKey(from: storedSecret) else {
            return failureResult("Not configured - enter OpenCode dashboard auth value.", configuration: configuration)
        }

        return await fetchDashboards(
            workspaceId: workspaceId,
            apiKey: balanceCredential,
            cacheIdentity: Self.cacheIdentity(
                workspaceId: workspaceId,
                credential: balanceCredential
            ),
            configuration: configuration
        )
    }

    func makeDashboardRequest(workspaceId: String, apiKey: String) -> URLRequest {
        makeDashboardRequest(workspaceId: workspaceId, apiKey: apiKey, page: "billing")
    }

    func makeGoDashboardRequest(workspaceId: String, apiKey: String) -> URLRequest {
        makeDashboardRequest(workspaceId: workspaceId, apiKey: apiKey, page: "go")
    }

    private func makeDashboardRequest(workspaceId: String, apiKey: String, page: String) -> URLRequest {
        var url = dashboardBaseURL
        url.append(path: "workspace")
        url.append(path: workspaceId)
        url.append(path: page)

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.httpMethod = "GET"
        request.setValue("text/html", forHTTPHeaderField: "Accept")
        request.setValue("auth=\(apiKey)", forHTTPHeaderField: "Cookie")
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Gecko/20100101 Firefox/148.0",
            forHTTPHeaderField: "User-Agent"
        )
        return request
    }

    private func fetchDashboards(
        workspaceId: String,
        apiKey: String,
        cacheIdentity: String,
        configuration: ProviderAccountConfiguration
    ) async -> ProviderUsageResult {
        let fetchedAt = Date()
        async let balanceTask = fetchBalance(workspaceId: workspaceId, apiKey: apiKey)
        async let goUsageTask = fetchGoUsage(workspaceId: workspaceId, apiKey: apiKey)
        let (balance, goUsage) = await (balanceTask, goUsageTask)
        return Self.buildCombinedResult(
            balance: balance,
            goUsage: goUsage,
            configuration: configuration,
            cacheIdentity: cacheIdentity,
            fetchedAt: fetchedAt
        )
    }

    private static func cacheIdentity(workspaceId: String, credential: String) -> String {
        let source = Data("\(workspaceId)\u{0}\(credential)".utf8)
        return Data(SHA256.hash(data: source)).base64EncodedString()
    }

    private func fetchBalance(
        workspaceId: String,
        apiKey: String
    ) async -> OpenCodeBalanceFetchOutcome {
        do {
            let (data, response) = try await session.data(for: makeDashboardRequest(workspaceId: workspaceId, apiKey: apiKey))
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure("OpenCode ZEN balance returned an invalid response.")
            }

            switch httpResponse.statusCode {
            case 200..<300:
                if let text = String(data: data, encoding: .utf8), Self.looksLikeOpenAuthPage(text) {
                    let message = Self.looksLikeZenModelAPIKey(apiKey)
                        ? "OpenCode ZEN API keys are valid for models, but OpenCode does not expose balance to API keys."
                        : "OpenCode returned the sign-in page. Refresh the saved dashboard auth value."
                    return .failure(message)
                }

                guard let balance = Self.parsedBalance(data) else {
                    return .failure("Could not parse OpenCode ZEN balance.")
                }
                return .value(balance)
            case 401, 403:
                return .failure("OpenCode rejected the saved dashboard auth value.")
            case 429:
                return .failure("OpenCode ZEN rate limit reached. Try again later.")
            default:
                return .failure("OpenCode ZEN dashboard returned HTTP \(httpResponse.statusCode).")
            }
        } catch {
            return .failure("OpenCode ZEN balance could not be refreshed: \(error.localizedDescription)")
        }
    }

    private func fetchGoUsage(
        workspaceId: String,
        apiKey: String
    ) async -> OpenCodeGoPageOutcome {
        do {
            let (data, response) = try await session.data(
                for: makeGoDashboardRequest(workspaceId: workspaceId, apiKey: apiKey)
            )
            guard let httpResponse = response as? HTTPURLResponse else {
                return .failure("OpenCode Go usage returned an invalid response.")
            }

            switch httpResponse.statusCode {
            case 200..<300:
                guard let text = String(data: data, encoding: .utf8) else {
                    return .failure("Could not read the OpenCode Go dashboard response.")
                }
                if Self.looksLikeOpenAuthPage(text) {
                    return .failure("OpenCode returned the sign-in page. Refresh the saved dashboard auth value.")
                }
                return Self.parseGoPage(text)
            case 401, 403:
                return .failure("OpenCode rejected the saved dashboard auth value.")
            case 404:
                return .failure("OpenCode Go dashboard returned HTTP 404.")
            case 429:
                return .failure("OpenCode Go rate limit reached. Try again later.")
            default:
                return .failure("OpenCode Go dashboard returned HTTP \(httpResponse.statusCode).")
            }
        } catch {
            return .failure("OpenCode Go usage could not be refreshed: \(error.localizedDescription)")
        }
    }

    static func parseBalance(
        _ data: Data,
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date = Date()
    ) -> ProviderUsageResult? {
        parsedBalance(data).map {
            buildResult(balance: $0, configuration: configuration, fetchedAt: fetchedAt)
        }
    }

    static func parseGoUsage(
        _ data: Data,
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date = Date()
    ) -> ProviderUsageResult? {
        guard
            let text = String(data: data, encoding: .utf8),
            case let .subscribed(windows) = parseGoPage(text)
        else {
            return nil
        }

        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: configuration.displayName,
            subtitle: "OpenCode Go usage",
            bars: bars(from: windows, fetchedAt: fetchedAt),
            fetchedAt: fetchedAt
        )
    }

    static func normalizedBalanceCredential(from storedSecret: String?) -> String? {
        normalizedAPIKey(from: storedSecret)
    }

    static func normalizedAPIKey(from storedSecret: String?) -> String? {
        guard var credential = storedSecret?.trimmingCharacters(in: .whitespacesAndNewlines), !credential.isEmpty else {
            return nil
        }

        if let settingsCredential = openCodeDashboardCredential(fromSettingsJSON: credential)
            ?? environmentValue(named: "OPENCODE_ZEN_AUTH_COOKIE", in: credential)
            ?? environmentValue(named: "OPENCODE_GO_AUTH_COOKIE", in: credential)
        {
            credential = settingsCredential
        }

        guard let normalizedCredential = ProviderSecretNormalizer.normalizedSecret(
            from: credential,
            removingPrefixes: ["authorization:", "bearer ", "cookie:", "set-cookie:"]
        ) else {
            return nil
        }
        credential = normalizedCredential

        if
            let authValue = cookieValue(named: "auth", from: credential),
            !authValue.isEmpty
        {
            credential = authValue
        }

        return credential.isEmpty ? nil : credential
    }

    static func normalizedWorkspaceId(from value: String?) -> String? {
        var workspaceId = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let settingsWorkspaceId = openCodeWorkspaceId(fromSettingsJSON: workspaceId)
            ?? environmentValue(named: "OPENCODE_ZEN_WORKSPACE_ID", in: workspaceId)
            ?? environmentValue(named: "OPENCODE_GO_WORKSPACE_ID", in: workspaceId)
        {
            workspaceId = settingsWorkspaceId
        }

        if
            let url = URL(string: workspaceId),
            let workspaceIndex = url.pathComponents.firstIndex(of: "workspace"),
            url.pathComponents.indices.contains(workspaceIndex + 1)
        {
            workspaceId = url.pathComponents[workspaceIndex + 1]
        }

        workspaceId = workspaceId
            .replacingOccurrences(of: "/billing", with: "")
            .replacingOccurrences(of: "/go", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/").union(.whitespacesAndNewlines))
        return workspaceId.isEmpty ? nil : workspaceId
    }

    private static func workspaceId(fromCredentialPayload value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let workspaceId = openCodeWorkspaceId(fromSettingsJSON: trimmed)
            ?? environmentValue(named: "OPENCODE_ZEN_WORKSPACE_ID", in: trimmed)
            ?? environmentValue(named: "OPENCODE_GO_WORKSPACE_ID", in: trimmed)
        {
            return normalizedWorkspaceId(from: workspaceId)
        }

        if
            let url = URL(string: trimmed),
            let workspaceIndex = url.pathComponents.firstIndex(of: "workspace"),
            url.pathComponents.indices.contains(workspaceIndex + 1)
        {
            return normalizedWorkspaceId(from: trimmed)
        }

        return nil
    }

    private static func parseJSONBalance(_ data: Data) -> Double? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            return nil
        }

        if let payload = root as? [String: Any] {
            return balance(from: payload)
                ?? (payload["data"] as? [String: Any]).flatMap { balance(from: $0) }
                ?? (payload["credits"] as? [String: Any]).flatMap { balance(from: $0) }
        }

        return nil
    }

    private static func parsedBalance(_ data: Data) -> Double? {
        if let jsonBalance = parseJSONBalance(data) {
            return jsonBalance
        }

        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return parseDashboardBalance(text)
    }

    private static func parseGoPage(_ text: String) -> OpenCodeGoPageOutcome {
        if let windows = parseHydrationGoWindows(text) ?? parseRenderedGoWindows(text) {
            return .subscribed(windows)
        }

        if containsDataSlot("promo-description", in: text) {
            return .notSubscribed
        }

        if containsDataSlot("other-message", in: text) {
            let visibleText = strippedHTML(text).lowercased()
            if visibleText.contains("another member") {
                return .otherWorkspaceMember
            }
            return .failure("OpenCode Go usage is unavailable for this workspace.")
        }

        return .failure("Could not parse all OpenCode Go usage windows.")
    }

    private static func parseHydrationGoWindows(_ text: String) -> [OpenCodeGoWindow]? {
        let descriptors = goWindowDescriptors
        var windows: [OpenCodeGoWindow] = []

        for descriptor in descriptors {
            guard let values = hydrationValues(for: descriptor.sourceKey, in: text) else {
                return nil
            }
            windows.append(
                OpenCodeGoWindow(
                    stableKey: descriptor.stableKey,
                    label: descriptor.label,
                    usagePercent: values.usagePercent,
                    resetInSeconds: values.resetInSeconds
                )
            )
        }

        return windows
    }

    private static func hydrationValues(
        for sourceKey: String,
        in text: String
    ) -> (usagePercent: Double, resetInSeconds: TimeInterval)? {
        var searchStart = text.startIndex

        while
            searchStart < text.endIndex,
            let keyRange = text.range(
                of: sourceKey,
                range: searchStart..<text.endIndex
            )
        {
            var segmentEnd = text.index(
                keyRange.upperBound,
                offsetBy: 1_500,
                limitedBy: text.endIndex
            ) ?? text.endIndex

            for otherKey in goWindowDescriptors.map(\.sourceKey) {
                if
                    let nextRange = text.range(
                        of: otherKey,
                        range: keyRange.upperBound..<segmentEnd
                    ),
                    nextRange.lowerBound < segmentEnd
                {
                    segmentEnd = nextRange.lowerBound
                }
            }

            let segment = String(text[keyRange.upperBound..<segmentEnd])
            if
                let usagePercent = numericField(named: "usagePercent", in: segment),
                let resetInSeconds = numericField(named: "resetInSec", in: segment),
                usagePercent.isFinite,
                usagePercent >= 0,
                resetInSeconds.isFinite,
                resetInSeconds >= 0
            {
                return (usagePercent, resetInSeconds)
            }

            searchStart = keyRange.upperBound
        }

        return nil
    }

    private static func numericField(named name: String, in text: String) -> Double? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?:\\?")?"# + escapedName + #"(?:\\?")?\s*:\s*(-?\d+(?:\.\d+)?)"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = regex.firstMatch(
                in: text,
                range: NSRange(location: 0, length: text.utf16.count)
            ),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return Double(text[range])
    }

    private static func parseRenderedGoWindows(_ text: String) -> [OpenCodeGoWindow]? {
        let markerPattern = #"data-slot\s*=\s*["']usage-item["']"#
        guard let regex = try? NSRegularExpression(pattern: markerPattern, options: [.caseInsensitive]) else {
            return nil
        }

        let fullRange = NSRange(location: 0, length: text.utf16.count)
        let matches = regex.matches(in: text, range: fullRange)
        guard !matches.isEmpty else {
            return nil
        }

        var parsedByKey: [String: OpenCodeGoWindow] = [:]
        for (index, match) in matches.enumerated() {
            guard let start = Range(match.range, in: text)?.lowerBound else {
                continue
            }
            let end: String.Index
            if
                matches.indices.contains(index + 1),
                let nextRange = Range(matches[index + 1].range, in: text)
            {
                end = nextRange.lowerBound
            } else {
                end = text.endIndex
            }

            let item = String(text[start..<end])
            guard
                let sourceLabel = htmlSlotText("usage-label", in: item),
                let descriptor = descriptor(forRenderedLabel: sourceLabel),
                let usageText = htmlSlotText("usage-value", in: item),
                let usagePercent = firstNumber(in: usageText),
                let resetText = htmlSlotText("reset-time", in: item),
                let resetInSeconds = resetDuration(in: resetText),
                usagePercent >= 0
            else {
                continue
            }

            parsedByKey[descriptor.stableKey] = OpenCodeGoWindow(
                stableKey: descriptor.stableKey,
                label: descriptor.label,
                usagePercent: usagePercent,
                resetInSeconds: resetInSeconds
            )
        }

        let ordered = goWindowDescriptors.compactMap { parsedByKey[$0.stableKey] }
        return ordered.count == goWindowDescriptors.count ? ordered : nil
    }

    private static func containsDataSlot(_ slot: String, in text: String) -> Bool {
        let escapedSlot = NSRegularExpression.escapedPattern(for: slot)
        return text.range(
            of: #"data-slot\s*=\s*["']"# + escapedSlot + #"["']"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func htmlSlotText(_ slot: String, in text: String) -> String? {
        let escapedSlot = NSRegularExpression.escapedPattern(for: slot)
        let pattern = #"<[^>]+data-slot\s*=\s*["']"# + escapedSlot + #"["'][^>]*>(.*?)</[^>]+>"#
        guard
            let regex = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive, .dotMatchesLineSeparators]
            ),
            let match = regex.firstMatch(
                in: text,
                range: NSRange(location: 0, length: text.utf16.count)
            ),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: text)
        else {
            return nil
        }
        return strippedHTML(String(text[range]))
    }

    private static func strippedHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#160;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func firstNumber(in text: String) -> Double? {
        guard
            let range = text.range(of: #"-?\d+(?:\.\d+)?"#, options: .regularExpression)
        else {
            return nil
        }
        return Double(text[range])
    }

    private static func resetDuration(in text: String) -> TimeInterval? {
        let value = text.lowercased()
        if value.contains("few seconds") {
            return 5
        }

        let days = durationComponent(named: #"days?|d"#, in: value)
        let hours = durationComponent(named: #"hours?|hrs?|h"#, in: value)
        let minutes = durationComponent(named: #"minutes?|mins?|m"#, in: value)
        let duration = days * 86_400 + hours * 3_600 + minutes * 60
        let recognizedUnitPattern = #"\b(?:days?|hours?|hrs?|minutes?|mins?)\b|\d+(?:\.\d+)?\s*[dhm]\b"#
        return value.range(of: recognizedUnitPattern, options: .regularExpression) == nil
            ? nil
            : duration
    }

    private static func durationComponent(named unitPattern: String, in text: String) -> Double {
        let pattern = #"(\d+(?:\.\d+)?)\s*(?:"# + unitPattern + #")\b"#
        guard
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
            let match = regex.firstMatch(
                in: text,
                range: NSRange(location: 0, length: text.utf16.count)
            ),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: text)
        else {
            return 0
        }
        return Double(text[range]) ?? 0
    }

    private static func descriptor(
        forRenderedLabel label: String
    ) -> (sourceKey: String, stableKey: String, label: String)? {
        let normalized = label.lowercased()
        if normalized.contains("rolling") || normalized.contains("5-hour") || normalized.contains("5 hour") {
            return goWindowDescriptors[0]
        }
        if normalized.contains("week") {
            return goWindowDescriptors[1]
        }
        if normalized.contains("month") {
            return goWindowDescriptors[2]
        }
        return nil
    }

    private static let goWindowDescriptors = [
        (sourceKey: "rollingUsage", stableKey: "go.rolling-5-hour", label: "5-hour usage limit"),
        (sourceKey: "weeklyUsage", stableKey: "go.weekly", label: "Weekly usage limit"),
        (sourceKey: "monthlyUsage", stableKey: "go.monthly", label: "Monthly usage limit"),
    ]

    private static func balance(from payload: [String: Any]) -> Double? {
        for key in ["balance", "current_balance", "currentBalance", "credits_remaining", "creditsRemaining"] {
            if let value = number(from: payload[key]) {
                return value
            }
        }

        return nil
    }

    private static func parseDashboardBalance(_ text: String) -> Double? {
        for pattern in [
            #"balance\s*:\s*(\d+)"#,
            #""balance"\s*:\s*(\d+)"#,
            #"\\?"balance\\?"\s*:\s*(\d+)"#,
        ] {
            guard let range = text.range(of: pattern, options: .regularExpression) else {
                continue
            }

            let match = String(text[range])
            guard
                let digitsRange = match.range(of: #"\d+"#, options: .regularExpression),
                let rawBalance = Double(match[digitsRange])
            else {
                continue
            }

            return rawBalance / 100_000_000
        }

        return nil
    }

    private static func looksLikeOpenAuthPage(_ text: String) -> Bool {
        ["<title>OpenAuth</title>", "openauth.js.org", "OpenAuth"].contains { marker in
            text.range(of: marker, options: .caseInsensitive) != nil
        }
    }

    static func looksLikeZenModelAPIKey(_ credential: String) -> Bool {
        credential.hasPrefix("sk-")
    }

    private static func openCodeDashboardCredential(fromSettingsJSON value: String) -> String? {
        guard let root = jsonObject(from: value) else {
            return nil
        }

        let providers = root["providers"] as? [String: Any]
        return providerAPIKey(named: "OpenCodeZen", in: providers)
            ?? providerAPIKey(named: "OpenCodeGo", in: providers)
    }

    private static func openCodeWorkspaceId(fromSettingsJSON value: String) -> String? {
        guard let root = jsonObject(from: value) else {
            return nil
        }

        return nonEmptyString(root["openCodeGoWorkspaceId"])
    }

    private static func providerAPIKey(named providerName: String, in providers: [String: Any]?) -> String? {
        guard let provider = providers?[providerName] as? [String: Any] else {
            return nil
        }

        return nonEmptyString(provider["apiKey"])
    }

    private static func jsonObject(from value: String) -> [String: Any]? {
        guard
            let data = value.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }

        return root
    }

    private static func environmentValue(named name: String, in value: String) -> String? {
        let escapedName = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?i)(?:^|[\s;])"# + escapedName + #"\s*=\s*("[^"]+"|'[^']+'|[^\s;]+)"#
        let fullRange = NSRange(location: 0, length: value.utf16.count)
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: value, range: fullRange),
            match.numberOfRanges > 1,
            let captureRange = Range(match.range(at: 1), in: value)
        else {
            return nil
        }

        return unquote(String(value[captureRange]))
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else {
            return nil
        }

        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func unquote(_ value: String) -> String {
        var result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if
            result.count >= 2,
            let first = result.first,
            let last = result.last,
            (first == "\"" && last == "\"") || (first == "'" && last == "'")
        {
            result.removeFirst()
            result.removeLast()
        }

        return result
    }

    private static func cookieValue(named name: String, from header: String) -> String? {
        let parts = header.split(separator: ";")
        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("\(name.lowercased())=") else {
                continue
            }

            return String(trimmed.dropFirst(name.count + 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return nil
    }

    private static func buildResult(
        balance: Double,
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: configuration.displayName,
            subtitle: "Credit balance",
            bars: [],
            creditsRemaining: balance,
            fetchedAt: fetchedAt
        )
    }

    private static func bars(
        from windows: [OpenCodeGoWindow],
        fetchedAt: Date
    ) -> [UsageBar] {
        windows.map { window in
            UsageBar(
                stableKey: window.stableKey,
                label: window.label,
                used: window.usagePercent,
                limit: 100,
                resetsAt: fetchedAt.addingTimeInterval(window.resetInSeconds),
                resetDisplayStyle: .relativeWithLocalTime
            )
        }
    }

    private static func buildCombinedResult(
        balance: OpenCodeBalanceFetchOutcome,
        goUsage: OpenCodeGoPageOutcome,
        configuration: ProviderAccountConfiguration,
        cacheIdentity: String,
        fetchedAt: Date
    ) -> ProviderUsageResult {
        let creditsRemaining: Double?
        let balanceFailure: String?
        switch balance {
        case let .value(value):
            creditsRemaining = value
            balanceFailure = nil
        case let .failure(message):
            creditsRemaining = nil
            balanceFailure = message
        }

        let usageBars: [UsageBar]
        let goFailure: String?
        let goStateIsAuthoritativeWithoutBars: Bool
        var usageMessages: [String] = []
        switch goUsage {
        case let .subscribed(windows):
            usageBars = bars(from: windows, fetchedAt: fetchedAt)
            goFailure = nil
            goStateIsAuthoritativeWithoutBars = false
        case .notSubscribed:
            usageBars = []
            goFailure = nil
            goStateIsAuthoritativeWithoutBars = true
            usageMessages.append("This workspace is not subscribed to OpenCode Go.")
        case .otherWorkspaceMember:
            usageBars = []
            goFailure = nil
            goStateIsAuthoritativeWithoutBars = true
            usageMessages.append("Another workspace member owns the OpenCode Go subscription.")
        case let .failure(message):
            usageBars = []
            goFailure = message
            goStateIsAuthoritativeWithoutBars = false
        }

        if let balanceFailure, !usageBars.isEmpty || goStateIsAuthoritativeWithoutBars {
            usageMessages.append("ZEN balance unavailable: \(balanceFailure)")
        }
        if let goFailure, creditsRemaining != nil {
            usageMessages.append("Go usage unavailable: \(goFailure)")
        }

        let preserveCachedCredits = balanceFailure != nil
            && (!usageBars.isEmpty || goStateIsAuthoritativeWithoutBars)
        let preserveCachedBars = goFailure != nil && creditsRemaining != nil
        let partialFailureMessage = [
            preserveCachedCredits ? balanceFailure.map { "ZEN balance unavailable: \($0)" } : nil,
            preserveCachedBars ? goFailure.map { "Go usage unavailable: \($0)" } : nil,
        ].compactMap { $0 }.joined(separator: " ")

        let hasUsableResult = creditsRemaining != nil || !usageBars.isEmpty || goStateIsAuthoritativeWithoutBars
        guard hasUsableResult else {
            var failures = [balanceFailure, goFailure]
                .compactMap { $0 }
                .reduce(into: [String]()) { unique, message in
                    if !unique.contains(message) {
                        unique.append(message)
                    }
                }
            if
                let modelKeyExplanation = failures.first(where: {
                    $0.contains("API keys are valid for models")
                })
            {
                failures = [modelKeyExplanation]
            }
            let message = failures.isEmpty
                ? "OpenCode usage could not be refreshed."
                : failures.joined(separator: " ")
            return ProviderUsageResult(
                accountID: configuration.id,
                providerID: .openCodeZen,
                title: configuration.displayName,
                subtitle: message,
                bars: [],
                failureMessage: message,
                cacheIdentity: cacheIdentity,
                fetchedAt: fetchedAt
            )
        }

        let subtitle: String
        switch (!usageBars.isEmpty, creditsRemaining != nil, goUsage) {
        case (true, true, _):
            subtitle = "Go usage and ZEN credit balance"
        case (true, false, _):
            subtitle = "OpenCode Go usage"
        case (false, true, .notSubscribed):
            subtitle = "ZEN credit balance - Go not subscribed"
        case (false, true, .otherWorkspaceMember):
            subtitle = "ZEN credit balance - Go owned by another member"
        case (false, true, _):
            subtitle = "ZEN credit balance"
        case (false, false, .notSubscribed):
            subtitle = "OpenCode Go not subscribed"
        case (false, false, .otherWorkspaceMember):
            subtitle = "OpenCode Go owned by another member"
        default:
            subtitle = "OpenCode usage"
        }

        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: configuration.displayName,
            subtitle: subtitle,
            bars: usageBars,
            creditsRemaining: creditsRemaining,
            usageMessages: usageMessages,
            failureMessage: partialFailureMessage.isEmpty ? nil : partialFailureMessage,
            preserveCachedBarsOnFailure: preserveCachedBars,
            preserveCachedCreditsOnFailure: preserveCachedCredits,
            cacheIdentity: cacheIdentity,
            fetchedAt: fetchedAt
        )
    }

    private static func number(from value: Any?) -> Double? {
        switch value {
        case let number as NSNumber:
            number.doubleValue
        case let string as String:
            Double(string.trimmingCharacters(in: .whitespacesAndNewlines))
        default:
            nil
        }
    }

    private func failureResult(_ message: String, configuration: ProviderAccountConfiguration) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .openCodeZen,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            failureMessage: message,
            fetchedAt: Date()
        )
    }
}
