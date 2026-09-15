import Foundation

public enum GitHubBillingUsageParser {
    public static func parsePersonal(
        summaryData: Data,
        usageData: Data,
        repositoryVisibility: [String: Bool],
        planName: String,
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date
    ) -> ProviderUsageResult? {
        guard
            let summary = try? JSONDecoder().decode(SummaryResponse.self, from: summaryData),
            let usage = try? JSONDecoder().decode(UsageResponse.self, from: usageData)
        else {
            return nil
        }

        let period = BillingPeriod(timePeriod: summary.timePeriod)
        let plan = PersonalPlan(name: planName)
        var bars: [UsageBar] = []
        var unavailable: [String: String] = [:]
        let allowanceFailure = plan == nil
            ? "GitHub did not return a supported Free or Pro plan, so CodexBar cannot calculate this allowance."
            : nil

        appendPersonalActionsMinutes(
            usage.usageItems,
            repositoryVisibility: repositoryVisibility,
            plan: plan,
            period: period,
            bars: &bars,
            unavailable: &unavailable,
            failure: allowanceFailure
        )
        appendAccruedStorage(
            summary.usageItems,
            plan: plan,
            period: period,
            bars: &bars,
            unavailable: &unavailable,
            failure: allowanceFailure
        )
        appendLFSUsage(
            summary.usageItems,
            plan: plan,
            period: period,
            bars: &bars,
            unavailable: &unavailable,
            failure: allowanceFailure
        )

        let totals = SpendTotals(items: summary.usageItems)
        let monetaryMetrics = makeSpendMetrics(totals: totals, period: period, fetchedAt: fetchedAt)
        let planDescriptor = plan.map { plan in
            ProviderPlanDescriptor.make(
                providerPrefix: ProviderID.githubBilling.rawValue,
                identifier: plan.id,
                label: plan.label
            )
        }
        let details = usageDetails(usage.usageItems)
        let accountName = configuration.githubBillingOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: .githubBilling,
            title: configuration.displayName,
            plan: planDescriptor,
            subtitle: accountName.isEmpty
                ? "GitHub personal billing"
                : "GitHub personal billing for \(accountName)",
            bars: bars,
            monetaryMetrics: monetaryMetrics,
            unavailableUsageMetrics: unavailable,
            usageMessages: [
                "GitHub does not expose personal budgets through its public API. Included allowances and current charges are shown separately.",
            ],
            cardInformationSections: details.isEmpty ? [] : [
                ProviderCardInformationSection(
                    id: "github-billing.usage-detail",
                    title: "Repository, product, and SKU usage",
                    items: details
                ),
            ],
            cacheIdentity: accountName.lowercased(),
            fetchedAt: fetchedAt
        )
    }

    public static func parseOrganization(
        summaryData: Data,
        usageData: Data,
        budgetPageData: [Data]?,
        budgetStatusMessage: String? = nil,
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date
    ) -> ProviderUsageResult? {
        guard
            let summary = try? JSONDecoder().decode(SummaryResponse.self, from: summaryData),
            let usage = try? JSONDecoder().decode(UsageResponse.self, from: usageData),
            let budgets = decodeBudgets(from: budgetPageData)
        else {
            return nil
        }

        let period = BillingPeriod(timePeriod: summary.timePeriod)
        var bars = organizationUsageBars(summary.usageItems)
        let budgetOutput = makeBudgetOutput(
            budgets: budgets,
            usageItems: summary.usageItems,
            period: period,
            fetchedAt: fetchedAt
        )
        bars.append(contentsOf: budgetOutput.bars)

        let totals = SpendTotals(items: summary.usageItems)
        var monetaryMetrics = makeSpendMetrics(totals: totals, period: period, fetchedAt: fetchedAt)
        if budgetOutput.validBudgets.count == 1, let budget = budgetOutput.validBudgets.first {
            monetaryMetrics.append(monetaryMetric(
                kind: .spendLimit,
                label: "Budget",
                amount: budget.amount,
                detail: budget.preventFurtherUsage ? "Hard stop" : "Alert only"
            ))
            monetaryMetrics.append(monetaryMetric(
                kind: .remainingHeadroom,
                label: "Budget remaining",
                amount: max(budget.amount - budget.consumed, 0),
                detail: budget.name
            ))
        }

        var messages: [String] = []
        if let budgetStatusMessage {
            messages.append(budgetStatusMessage)
        } else if budgets.isEmpty {
            messages.append("GitHub returned no organization budgets. Metered usage can still incur charges.")
        }

        let details = usageDetails(usage.usageItems)
        var sections = budgetOutput.sections
        if !details.isEmpty {
            sections.append(ProviderCardInformationSection(
                id: "github-billing.usage-detail",
                title: "Repository, product, and SKU usage",
                items: details
            ))
        }
        let owner = configuration.githubBillingOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: .githubBilling,
            title: configuration.displayName,
            subtitle: owner.isEmpty
                ? "GitHub organization billing"
                : "GitHub organization billing for \(owner)",
            bars: bars,
            monetaryMetrics: monetaryMetrics,
            usageMessages: messages,
            cardInformationSections: sections,
            cacheIdentity: owner.lowercased(),
            fetchedAt: fetchedAt
        )
    }

    private static func appendPersonalActionsMinutes(
        _ items: [UsageItem],
        repositoryVisibility: [String: Bool],
        plan: PersonalPlan?,
        period: BillingPeriod?,
        bars: inout [UsageBar],
        unavailable: inout [String: String],
        failure: String?
    ) {
        let metricID = "githubBilling.actions-private-minutes"
        guard let plan else {
            unavailable[metricID] = failure ?? "The GitHub plan allowance is unavailable."
            return
        }

        var consumed = Decimal.zero
        var isClassifiable = true
        for item in items where item.isActionsMinutes {
            guard
                let repositoryName = item.repositoryName,
                let isPrivate = repositoryVisibility[repositoryName],
                let multiplier = item.standardRunnerMultiplier,
                let quantity = item.quantity
            else {
                isClassifiable = false
                continue
            }
            if isPrivate {
                consumed += quantity * multiplier
            }
        }

        guard isClassifiable else {
            unavailable[metricID] = "GitHub returned Actions usage that CodexBar could not classify as a private standard runner."
            return
        }
        bars.append(allowanceBar(
            stableKey: "actions-private-minutes",
            label: "Private Actions minutes",
            used: consumed,
            limit: Decimal(plan.actionsMinutes),
            period: period
        ))
    }

    private static func appendAccruedStorage(
        _ items: [SummaryItem],
        plan: PersonalPlan?,
        period: BillingPeriod?,
        bars: inout [UsageBar],
        unavailable: inout [String: String],
        failure: String?
    ) {
        let metricID = "githubBilling.actions-packages-storage"
        guard let plan else {
            unavailable[metricID] = failure ?? "The GitHub plan allowance is unavailable."
            return
        }
        guard let period else {
            unavailable[metricID] = "GitHub did not return a complete billing period for accrued storage."
            return
        }
        let matching = items.filter { $0.isActionsOrPackagesStorage }
        guard matching.allSatisfy(\.isGBHours) else {
            unavailable[metricID] = "GitHub returned storage in a unit that cannot be compared with a GB-hour allowance."
            return
        }
        let used = matching.compactMap(\.grossQuantity).reduce(.zero, +)
        let limit = plan.sharedStorageGB * Decimal(period.hours)
        bars.append(allowanceBar(
            stableKey: "actions-packages-storage",
            label: "Actions + Packages storage",
            used: used,
            limit: limit,
            period: period
        ))
    }

    private static func appendLFSUsage(
        _ items: [SummaryItem],
        plan: PersonalPlan?,
        period: BillingPeriod?,
        bars: inout [UsageBar],
        unavailable: inout [String: String],
        failure: String?
    ) {
        guard let plan else {
            unavailable["githubBilling.lfs-storage"] = failure ?? "The GitHub plan allowance is unavailable."
            unavailable["githubBilling.lfs-bandwidth"] = failure ?? "The GitHub plan allowance is unavailable."
            return
        }

        let storageItems = items.filter(\.isLFSStorage)
        if storageItems.allSatisfy(\.isGBHours), let period {
            bars.append(allowanceBar(
                stableKey: "lfs-storage",
                label: "Git LFS storage",
                used: storageItems.compactMap(\.grossQuantity).reduce(.zero, +),
                limit: Decimal(plan.lfsStorageGB) * Decimal(period.hours),
                period: period
            ))
        } else {
            unavailable["githubBilling.lfs-storage"] = period == nil
                ? "GitHub did not return a complete billing period for accrued Git LFS storage."
                : "GitHub returned Git LFS storage in an unsupported unit."
        }

        let bandwidthItems = items.filter(\.isLFSBandwidth)
        if bandwidthItems.allSatisfy(\.isGB) {
            bars.append(allowanceBar(
                stableKey: "lfs-bandwidth",
                label: "Git LFS bandwidth",
                used: bandwidthItems.compactMap(\.grossQuantity).reduce(.zero, +),
                limit: Decimal(plan.lfsBandwidthGB),
                period: period
            ))
        } else {
            unavailable["githubBilling.lfs-bandwidth"] = "GitHub returned Git LFS bandwidth in an unsupported unit."
        }
    }

    private static func allowanceBar(
        stableKey: String,
        label: String,
        used: Decimal,
        limit: Decimal,
        period: BillingPeriod?
    ) -> UsageBar {
        UsageBar(
            stableKey: stableKey,
            label: label,
            used: used.doubleValue,
            limit: limit.doubleValue,
            resetsAt: period?.end,
            resetDisplayStyle: .relativeWithLocalTime,
            projectionCurrent: used.doubleValue,
            projectionLimit: limit.doubleValue,
            projectionPeriodStart: period?.start,
            projectionPeriodEnd: period?.end,
            showProjectionOnCurrentBar: period != nil
        )
    }

    private static func organizationUsageBars(_ items: [SummaryItem]) -> [UsageBar] {
        items.enumerated().compactMap { index, item in
            guard
                let product = item.product?.nonempty,
                let sku = item.sku?.nonempty,
                let quantity = item.grossQuantity,
                let unit = item.unitType?.nonempty
            else {
                return nil
            }
            return UsageBar(
                stableKey: "usage-\(stableKey(product))-\(stableKey(sku))-\(index)",
                label: "\(product) · \(sku)",
                used: quantity.doubleValue,
                limit: 0,
                fractionlessUsageText: "\(decimalText(quantity)) \(unit)"
            )
        }
    }

    private static func decodeBudgets(from pages: [Data]?) -> [Budget]? {
        guard let pages else { return [] }
        var budgets: [Budget] = []
        for page in pages {
            guard let response = try? JSONDecoder().decode(BudgetResponse.self, from: page) else {
                return nil
            }
            budgets.append(contentsOf: response.budgets)
        }
        return budgets
    }

    private static func makeBudgetOutput(
        budgets: [Budget]?,
        usageItems: [SummaryItem],
        period: BillingPeriod?,
        fetchedAt: Date
    ) -> BudgetOutput {
        guard let budgets else { return BudgetOutput() }
        var output = BudgetOutput()
        for budget in budgets {
            guard
                let id = budget.id?.nonempty,
                let amount = budget.budgetAmount,
                amount > 0
            else {
                continue
            }
            let targets = budget.productsOrSKUs.compactMap(\.nonempty)
            guard !targets.isEmpty else { continue }
            let normalizedTargets = Set(targets.map(\.normalized))
            let isProduct = budget.budgetType?.normalized == "productpricing"
            let matchingItems = usageItems.filter { item in
                let candidate = isProduct ? item.product : item.sku
                return candidate.map { normalizedTargets.contains($0.normalized) } == true
            }
            let consumed = matchingItems.compactMap(\.netAmount).reduce(.zero, +)
            let targetLabel = targets.joined(separator: ", ")
            let name = "\(targetLabel) budget"
            let normalized = NormalizedBudget(
                id: id,
                name: name,
                amount: amount,
                consumed: consumed,
                preventFurtherUsage: budget.preventFurtherUsage ?? false
            )
            output.validBudgets.append(normalized)
            output.bars.append(UsageBar(
                stableKey: "budget-\(id)",
                label: name,
                used: consumed.doubleValue,
                limit: amount.doubleValue,
                resetsAt: period?.end,
                resetDisplayStyle: .relativeWithLocalTime,
                projectionCurrent: consumed.doubleValue,
                projectionLimit: amount.doubleValue,
                projectionPeriodStart: period?.start,
                projectionPeriodEnd: period?.end,
                showProjectionOnCurrentBar: period != nil
            ))
            let remaining = max(amount - consumed, 0)
            let percent = amount > 0 ? consumed / amount * 100 : 0
            output.sections.append(ProviderCardInformationSection(
                id: "github-billing.budget.\(id)",
                title: name,
                items: [
                    ProviderCardInformationItem(
                        id: "\(id).scope",
                        label: isProduct ? "Product budget" : "SKU budget",
                        detail: targetLabel
                    ),
                    ProviderCardInformationItem(
                        id: "\(id).behavior",
                        label: "Behavior",
                        detail: normalized.preventFurtherUsage ? "Hard stop" : "Alert only"
                    ),
                    ProviderCardInformationItem(
                        id: "\(id).consumed",
                        label: "Current net spend",
                        detail: currencyText(consumed)
                    ),
                    ProviderCardInformationItem(
                        id: "\(id).remaining",
                        label: "Remaining headroom",
                        detail: "\(currencyText(remaining)) · \(decimalText(percent))% consumed"
                    ),
                ]
            ))
        }
        return output
    }

    private static func makeSpendMetrics(
        totals: SpendTotals,
        period: BillingPeriod?,
        fetchedAt: Date
    ) -> [ProviderMonetaryMetric] {
        var metrics = [
            monetaryMetric(kind: .grossSpend, label: "Gross usage", amount: totals.gross),
            monetaryMetric(kind: .discounts, label: "Discounts", amount: totals.discount),
            monetaryMetric(
                kind: .spent,
                label: "Net spend",
                amount: totals.net,
                detail: totals.net == 0 && totals.discount >= totals.gross && totals.gross > 0
                    ? "No current charge after discounts"
                    : "Current metered charge"
            ),
        ]
        if let period, fetchedAt > period.start, fetchedAt < period.end {
            let elapsed = Decimal(fetchedAt.timeIntervalSince(period.start))
            let total = Decimal(period.end.timeIntervalSince(period.start))
            if elapsed > 0 {
                metrics.append(monetaryMetric(
                    kind: .projectedSpend,
                    label: "Projected month-end spend",
                    amount: totals.net * total / elapsed,
                    detail: "Estimate based on current pace"
                ))
            }
        }
        return metrics
    }

    private static func monetaryMetric(
        kind: ProviderMonetaryMetricKind,
        label: String,
        amount: Decimal,
        detail: String? = nil
    ) -> ProviderMonetaryMetric {
        let decimalPlaces = decimalPlaces(for: amount)
        var multiplier = Decimal(1)
        for _ in 0..<decimalPlaces { multiplier *= 10 }
        return ProviderMonetaryMetric(
            kind: kind,
            label: label,
            minorUnits: amount * multiplier,
            currencyCode: "USD",
            decimalPlaces: decimalPlaces,
            detail: detail
        )
    }

    private static func usageDetails(_ items: [UsageItem]) -> [ProviderCardInformationItem] {
        items.prefix(40).enumerated().compactMap { index, item in
            guard let product = item.product?.nonempty, let sku = item.sku?.nonempty else {
                return nil
            }
            let repository = item.repositoryName?.nonempty ?? "Account-wide"
            let quantity = item.quantity.map(decimalText) ?? "Unknown quantity"
            let unit = item.unitType?.nonempty ?? "units"
            let net = item.netAmount.map(currencyText) ?? "Unknown charge"
            return ProviderCardInformationItem(
                id: "usage.\(index).\(stableKey(repository)).\(stableKey(sku))",
                label: repository,
                detail: "\(product) · \(sku) · \(quantity) \(unit) · \(net) net"
            )
        }
    }

    private static func decimalPlaces(for value: Decimal) -> Int {
        let text = NSDecimalNumber(decimal: value).stringValue
        guard let separator = text.firstIndex(of: ".") else { return 2 }
        let count = text.distance(from: text.index(after: separator), to: text.endIndex)
        return min(max(count, 2), 6)
    }

    private static func decimalText(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private static func currencyText(_ value: Decimal) -> String {
        value.formatted(
            .currency(code: "USD")
                .precision(.fractionLength(decimalPlaces(for: value)))
        )
    }

    private static func stableKey(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
    }
}

private struct SummaryResponse: Decodable {
    let timePeriod: TimePeriod?
    let usageItems: [SummaryItem]

    enum CodingKeys: String, CodingKey {
        case timePeriod
        case usageItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timePeriod = try container.decodeIfPresent(TimePeriod.self, forKey: .timePeriod)
        usageItems = try container.decodeIfPresent([SummaryItem].self, forKey: .usageItems) ?? []
    }
}

private struct TimePeriod: Decodable {
    let year: Int?
    let month: Int?
}

private struct SummaryItem: Decodable {
    let product: String?
    let sku: String?
    let unitType: String?
    let grossQuantity: Decimal?
    let grossAmount: Decimal?
    let discountAmount: Decimal?
    let netAmount: Decimal?

    var isActionsOrPackagesStorage: Bool {
        let product = product?.normalized ?? ""
        let sku = sku?.normalized ?? ""
        return (product.contains("actions") || product.contains("packages"))
            && sku.contains("storage")
    }

    var isLFSStorage: Bool {
        isLFS && (sku?.normalized.contains("storage") == true)
    }

    var isLFSBandwidth: Bool {
        isLFS && (sku?.normalized.contains("bandwidth") == true)
    }

    var isLFS: Bool {
        let product = product?.normalized ?? ""
        return product.contains("gitlfs") || product == "lfs"
    }

    var isGBHours: Bool {
        let unit = unitType?.normalized ?? ""
        return unit.contains("gbhour") || unit.contains("gibhour")
    }

    var isGB: Bool {
        let unit = unitType?.normalized ?? ""
        return unit == "gb" || unit == "gib" || unit == "gigabytes"
    }
}

private struct UsageResponse: Decodable {
    let usageItems: [UsageItem]

    enum CodingKeys: String, CodingKey {
        case usageItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usageItems = try container.decodeIfPresent([UsageItem].self, forKey: .usageItems) ?? []
    }
}

private struct UsageItem: Decodable {
    let product: String?
    let sku: String?
    let quantity: Decimal?
    let unitType: String?
    let grossAmount: Decimal?
    let discountAmount: Decimal?
    let netAmount: Decimal?
    let repositoryName: String?

    var isActionsMinutes: Bool {
        product?.normalized.contains("actions") == true
            && unitType?.normalized.contains("minute") == true
    }

    var standardRunnerMultiplier: Decimal? {
        let normalized = sku?.normalized ?? ""
        let unsupportedMarkers = ["larger", "gpu", "arm", "4core", "8core", "16core", "32core", "64core"]
        guard !unsupportedMarkers.contains(where: normalized.contains) else { return nil }
        if normalized.contains("linux") { return 1 }
        if normalized.contains("windows") { return 2 }
        if normalized.contains("macos") { return 10 }
        return nil
    }
}

private struct BudgetResponse: Decodable {
    let budgets: [Budget]

    enum CodingKeys: String, CodingKey {
        case budgets
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        budgets = try container.decodeIfPresent([Budget].self, forKey: .budgets) ?? []
    }
}

private struct Budget: Decodable {
    let id: String?
    let budgetType: String?
    let budgetAmount: Decimal?
    let preventFurtherUsage: Bool?
    let budgetProductSKU: String?
    let budgetProductSKUs: [String]?

    var productsOrSKUs: [String] {
        if let budgetProductSKU { return [budgetProductSKU] }
        return budgetProductSKUs ?? []
    }

    enum CodingKeys: String, CodingKey {
        case id
        case budgetType = "budget_type"
        case budgetAmount = "budget_amount"
        case preventFurtherUsage = "prevent_further_usage"
        case budgetProductSKU = "budget_product_sku"
        case budgetProductSKUs = "budget_product_skus"
    }
}

private struct SpendTotals {
    let gross: Decimal
    let discount: Decimal
    let net: Decimal

    init(items: [SummaryItem]) {
        gross = items.compactMap(\.grossAmount).reduce(.zero, +)
        discount = items.compactMap(\.discountAmount).reduce(.zero, +)
        net = items.compactMap(\.netAmount).reduce(.zero, +)
    }
}

private struct BillingPeriod {
    let start: Date
    let end: Date
    let hours: Int

    init?(timePeriod: TimePeriod?) {
        guard
            let year = timePeriod?.year,
            let month = timePeriod?.month,
            (1...12).contains(month)
        else {
            return nil
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard
            let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
            let end = calendar.date(byAdding: .month, value: 1, to: start)
        else {
            return nil
        }
        self.start = start
        self.end = end
        self.hours = Int(end.timeIntervalSince(start) / 3_600)
    }
}

private struct PersonalPlan {
    let id: String
    let label: String
    let actionsMinutes: Int
    let sharedStorageGB: Decimal
    let lfsStorageGB: Int
    let lfsBandwidthGB: Int

    private init(
        id: String,
        label: String,
        actionsMinutes: Int,
        sharedStorageGB: Decimal,
        lfsStorageGB: Int,
        lfsBandwidthGB: Int
    ) {
        self.id = id
        self.label = label
        self.actionsMinutes = actionsMinutes
        self.sharedStorageGB = sharedStorageGB
        self.lfsStorageGB = lfsStorageGB
        self.lfsBandwidthGB = lfsBandwidthGB
    }

    init?(name: String) {
        switch name.normalized {
        case "free":
            self.init(
                id: "free",
                label: "Free",
                actionsMinutes: 2_000,
                sharedStorageGB: Decimal(5) / Decimal(10),
                lfsStorageGB: 10,
                lfsBandwidthGB: 10
            )
        case "pro":
            self.init(
                id: "pro",
                label: "Pro",
                actionsMinutes: 3_000,
                sharedStorageGB: 1,
                lfsStorageGB: 10,
                lfsBandwidthGB: 10
            )
        default:
            return nil
        }
    }
}

private struct NormalizedBudget {
    let id: String
    let name: String
    let amount: Decimal
    let consumed: Decimal
    let preventFurtherUsage: Bool
}

private struct BudgetOutput {
    var bars: [UsageBar] = []
    var sections: [ProviderCardInformationSection] = []
    var validBudgets: [NormalizedBudget] = []
}

private extension Decimal {
    var doubleValue: Double {
        NSDecimalNumber(decimal: self).doubleValue
    }
}

private extension String {
    var nonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var normalized: String {
        String(lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
