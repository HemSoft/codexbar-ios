import Foundation

enum GreptileUsageIdentity {
    static let completedReviewsStableKey = "completed-reviews"
    static let completedReviewsMetricID = "greptile.\(completedReviewsStableKey)"
    static let completedReviewsHistorySeriesID = "usage.\(completedReviewsStableKey)"
}

public final class GreptileUsageProvider: UsageProvider {
    struct ReviewPage: Equatable {
        struct Review: Equatable {
            let id: String
            let status: String
        }

        let reviews: [Review]
        let total: Int?
    }

    private enum PageResponse {
        case page(ReviewPage)
        case authenticationFailure
        case permissionFailure
        case rateLimited
        case serverFailure
        case malformed
    }

    private struct StatusCounts {
        var completed = 0
        var pending = 0
        var inProgress = 0
        var failed = 0
        var skipped = 0
        var other = 0

        mutating func record(_ rawStatus: String) {
            switch rawStatus.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
            case "COMPLETED":
                completed += 1
            case "PENDING":
                pending += 1
            case "REVIEWING_FILES", "GENERATING_SUMMARY", "IN_PROGRESS", "IN-PROGRESS":
                inProgress += 1
            case "FAILED":
                failed += 1
            case "SKIPPED":
                skipped += 1
            default:
                other += 1
            }
        }
    }

    private let secretStore: SecretStore
    private let session: URLSession
    private let endpoint: URL
    private let pageSize: Int
    private let maximumPageCount: Int

    public let providerID = ProviderID.greptile

    public init(
        secretStore: SecretStore = KeychainService(),
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://api.greptile.com/mcp")!,
        pageSize: Int = 100,
        maximumPageCount: Int = 100
    ) {
        self.secretStore = secretStore
        self.session = session
        self.endpoint = endpoint
        self.pageSize = min(max(pageSize, 1), 100)
        self.maximumPageCount = max(maximumPageCount, 1)
    }

    public func fetchUsage(for configuration: ProviderAccountConfiguration) async throws -> ProviderUsageResult {
        let storedSecret: String?
        do {
            storedSecret = try secretStore.readSecret(
                account: ProviderConfigurationStore.keychainAccount(for: configuration)
            )
        } catch {
            return failureResult(
                "Greptile credential could not be read from Keychain.",
                configuration: configuration
            )
        }

        guard
            let apiKey = Self.normalizedAPIKey(from: storedSecret),
            !apiKey.isEmpty
        else {
            return failureResult(
                "Not configured - enter a Greptile organization API key.",
                configuration: configuration
            )
        }

        var offset = 0
        var pageCount = 0
        var expectedTotal: Int?
        var seenReviewIDs = Set<String>()
        var counts = StatusCounts()

        while pageCount < pageLimit(expectedTotal: expectedTotal) {
            let request = makeReviewsRequest(apiKey: apiKey, offset: offset)
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await session.data(for: request)
            } catch {
                return failureResult(
                    "Could not reach Greptile. Check the connection and try again.",
                    configuration: configuration
                )
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                return failureResult(
                    "Greptile returned an invalid network response.",
                    configuration: configuration
                )
            }

            if let httpFailure = httpFailureResult(
                response: httpResponse,
                configuration: configuration
            ) {
                return httpFailure
            }

            switch Self.parseReviewPage(data) {
            case .page(let page):
                pageCount += 1
                if let total = page.total {
                    expectedTotal = max(expectedTotal ?? 0, total)
                }

                for (index, review) in page.reviews.enumerated() {
                    let reviewID = review.id.isEmpty
                        ? "page-\(pageCount)-offset-\(offset)-index-\(index)"
                        : review.id
                    guard seenReviewIDs.insert(reviewID).inserted else {
                        continue
                    }
                    counts.record(review.status)
                }

                let nextOffset = offset + page.reviews.count
                if let expectedTotal, nextOffset >= expectedTotal {
                    return successResult(counts: counts, configuration: configuration)
                }
                if page.reviews.isEmpty {
                    if expectedTotal == nil || offset >= expectedTotal ?? 0 {
                        return successResult(counts: counts, configuration: configuration)
                    }
                    return incompletePaginationFailure(configuration: configuration)
                }
                if page.reviews.count < pageSize {
                    if expectedTotal == nil {
                        return successResult(counts: counts, configuration: configuration)
                    }
                    return incompletePaginationFailure(configuration: configuration)
                }
                offset = nextOffset
            case .authenticationFailure:
                return failureResult(
                    "Greptile rejected this organization API key.",
                    configuration: configuration
                )
            case .permissionFailure:
                return failureResult(
                    "This Greptile API key lacks permission to read organization review activity.",
                    configuration: configuration
                )
            case .rateLimited:
                return failureResult(
                    "Greptile rate limit reached. Wait before refreshing again.",
                    configuration: configuration
                )
            case .serverFailure:
                return failureResult(
                    "Greptile could not complete the read-only review request. Try again later.",
                    configuration: configuration
                )
            case .malformed:
                return failureResult(
                    "Could not parse Greptile review activity.",
                    configuration: configuration
                )
            }
        }

        return incompletePaginationFailure(configuration: configuration)
    }

    func makeReviewsRequest(apiKey: String, offset: Int) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("CodexBarIOS/1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "jsonrpc": "2.0",
            "id": "codexbar.greptile.reviews.\(offset)",
            "method": "tools/call",
            "params": [
                "name": "list_code_reviews",
                "arguments": [
                    "limit": pageSize,
                    "offset": offset,
                ],
            ],
        ])
        return request
    }

    static func normalizedAPIKey(from storedSecret: String?) -> String? {
        ProviderSecretNormalizer.normalizedSecret(from: storedSecret)
    }

    private static func parseReviewPage(_ data: Data) -> PageResponse {
        for root in responseObjects(in: data) {
            let response = parseReviewPage(root)
            if case .malformed = response {
                continue
            }
            return response
        }
        return .malformed
    }

    private static func parseReviewPage(_ root: [String: Any]) -> PageResponse {

        if let error = root["error"] as? [String: Any] {
            return pageResponse(for: error)
        }

        guard
            let payload = reviewPayload(in: root),
            let rawReviews = payload["codeReviews"] as? [[String: Any]]
        else {
            return .malformed
        }

        let reviews = rawReviews.map { review in
            ReviewPage.Review(
                id: stringValue(review["id"]) ?? "",
                status: stringValue(review["status"]) ?? "UNKNOWN"
            )
        }
        let total = integerValue(payload["total"])
        guard total.map({ $0 >= 0 }) != false else {
            return .malformed
        }
        return .page(ReviewPage(reviews: reviews, total: total))
    }

    private static func responseObjects(in data: Data) -> [[String: Any]] {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return [object]
        }

        guard let eventStream = String(data: data, encoding: .utf8) else {
            return []
        }

        var objects: [[String: Any]] = []
        var dataLines: [String] = []

        func appendEvent() {
            guard !dataLines.isEmpty else {
                return
            }
            defer { dataLines.removeAll(keepingCapacity: true) }
            let payload = dataLines.joined(separator: "\n")
            guard
                payload != "[DONE]",
                let payloadData = payload.data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
            else {
                return
            }
            objects.append(object)
        }

        for rawLine in eventStream.components(separatedBy: .newlines) {
            let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
            if line.isEmpty {
                appendEvent()
            } else if line.hasPrefix("data:") {
                dataLines.append(
                    String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                )
            }
        }
        appendEvent()
        return objects
    }

    private static func reviewPayload(in root: [String: Any]) -> [String: Any]? {
        if root["codeReviews"] is [[String: Any]] {
            return root
        }

        guard let result = root["result"] as? [String: Any] else {
            return nil
        }
        if result["codeReviews"] is [[String: Any]] {
            return result
        }
        if
            let structured = result["structuredContent"] as? [String: Any],
            structured["codeReviews"] is [[String: Any]] {
            return structured
        }

        guard let content = result["content"] as? [[String: Any]] else {
            return nil
        }
        for item in content {
            guard
                stringValue(item["type"]) == "text",
                let text = stringValue(item["text"]),
                let textData = text.data(using: .utf8),
                let payload = try? JSONSerialization.jsonObject(with: textData) as? [String: Any],
                payload["codeReviews"] is [[String: Any]]
            else {
                continue
            }
            return payload
        }
        return nil
    }

    private static func pageResponse(for error: [String: Any]) -> PageResponse {
        let message = stringValue(error["message"])?.lowercased() ?? ""
        if message.contains("auth") || message.contains("api key") || message.contains("unauthorized") {
            return .authenticationFailure
        }
        if message.contains("permission") || message.contains("forbidden") || message.contains("organization") {
            return .permissionFailure
        }
        if message.contains("rate") || message.contains("too many") {
            return .rateLimited
        }
        return .serverFailure
    }

    private static func stringValue(_ value: Any?) -> String? {
        value as? String
    }

    private static func integerValue(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber:
            number.intValue
        case let string as String:
            Int(string)
        default:
            nil
        }
    }

    private static func rateLimitMessage(response: HTTPURLResponse) -> String {
        guard
            let rawValue = response.value(forHTTPHeaderField: "Retry-After"),
            let seconds = Int(rawValue),
            seconds > 0
        else {
            return "Greptile rate limit reached. Wait before refreshing again."
        }
        return "Greptile rate limit reached. Try again in about \(seconds) seconds."
    }

    private func httpFailureResult(
        response: HTTPURLResponse,
        configuration: ProviderAccountConfiguration
    ) -> ProviderUsageResult? {
        switch response.statusCode {
        case 200..<300:
            nil
        case 401:
            failureResult(
                "Greptile rejected this organization API key.",
                configuration: configuration
            )
        case 403:
            failureResult(
                "This Greptile API key lacks permission to read organization review activity.",
                configuration: configuration
            )
        case 429:
            failureResult(
                Self.rateLimitMessage(response: response),
                configuration: configuration
            )
        case 500..<600:
            failureResult(
                "Greptile is temporarily unavailable (HTTP \(response.statusCode)). Try again later.",
                configuration: configuration
            )
        default:
            failureResult(
                "Greptile review activity returned HTTP \(response.statusCode).",
                configuration: configuration
            )
        }
    }

    private func successResult(
        counts: StatusCounts,
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date = Date()
    ) -> ProviderUsageResult {
        let statusItems = [
            ("completed", "Completed", counts.completed),
            ("pending", "Pending", counts.pending),
            ("in-progress", "In progress", counts.inProgress),
            ("failed", "Failed", counts.failed),
            ("skipped", "Skipped", counts.skipped),
            ("other", "Other statuses", counts.other),
        ].compactMap { identifier, label, count -> ProviderCardInformationItem? in
            guard count > 0 || identifier == "completed" else {
                return nil
            }
            return ProviderCardInformationItem(
                id: "greptile.status.\(identifier)",
                label: label,
                detail: count.formatted()
            )
        }

        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: .greptile,
            title: configuration.displayName,
            subtitle: "All available review history",
            bars: [
                UsageBar(
                    stableKey: GreptileUsageIdentity.completedReviewsStableKey,
                    label: "Completed reviews",
                    used: Double(counts.completed),
                    limit: 0,
                    fractionlessUsageText: counts.completed.formatted()
                ),
            ],
            usageMessages: [
                "Greptile's API does not currently expose billing-credit usage.",
            ],
            cardInformationSections: [
                ProviderCardInformationSection(
                    id: "greptile.review-statuses",
                    title: "Review statuses",
                    items: statusItems
                ),
            ],
            fetchedAt: fetchedAt
        )
    }

    private func incompletePaginationFailure(
        configuration: ProviderAccountConfiguration
    ) -> ProviderUsageResult {
        failureResult(
            "Greptile returned incomplete paginated review activity. Try again later.",
            configuration: configuration
        )
    }

    private func pageLimit(expectedTotal: Int?) -> Int {
        guard let expectedTotal else {
            return maximumPageCount
        }
        let completePageCount = expectedTotal / pageSize
        let requiredPageCount = completePageCount + (expectedTotal.isMultiple(of: pageSize) ? 0 : 1)
        return max(maximumPageCount, requiredPageCount)
    }

    private func failureResult(
        _ message: String,
        configuration: ProviderAccountConfiguration
    ) -> ProviderUsageResult {
        ProviderUsageResult(
            accountID: configuration.id,
            providerID: .greptile,
            title: configuration.displayName,
            subtitle: message,
            bars: [],
            failureMessage: message,
            fetchedAt: Date()
        )
    }
}
