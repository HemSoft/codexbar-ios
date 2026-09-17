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
        let monetaryMetrics = totals.map {
            makeSpendMetrics(totals: $0, period: period, fetchedAt: fetchedAt)
        } ?? []
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
            ] + spendStatusMessages(for: totals),
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
            usageItems: usage.usageItems,
            period: period
        )
        bars.append(contentsOf: budgetOutput.bars)

        let totals = SpendTotals(items: summary.usageItems)
        var monetaryMetrics = totals.map {
            makeSpendMetrics(totals: $0, period: period, fetchedAt: fetchedAt)
        } ?? []
        if budgetOutput.validBudgets.count == 1, let budget = budgetOutput.validBudgets.first {
            monetaryMetrics.append(monetaryMetric(
                kind: .spendLimit,
                label: "Budget",
                amount: budget.amount,
                detail: budget.behaviorLabel
            ))
            monetaryMetrics.append(monetaryMetric(
                kind: .remainingHeadroom,
                label: "Budget remaining",
                amount: max(budget.amount - budget.consumed, 0),
                detail: budget.name
            ))
        }

        var messages = budgetOutput.messages + spendStatusMessages(for: totals)
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
        guard matching.allSatisfy({ $0.grossQuantity != nil }) else {
            unavailable[metricID] = "GitHub did not return a complete accrued storage quantity."
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
        if storageItems.allSatisfy(\.isGBHours),
           storageItems.allSatisfy({ $0.grossQuantity != nil }),
           let period {
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
        if bandwidthItems.allSatisfy(\.isGB),
           bandwidthItems.allSatisfy({ $0.grossQuantity != nil }) {
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
        usageItems: [UsageItem],
        period: BillingPeriod?
    ) -> BudgetOutput {
        guard let budgets else { return BudgetOutput() }
        var output = BudgetOutput()
        for budget in budgets {
            let candidate = budgetCandidate(budget, usageItems: usageItems)
            if let unavailableMessage = candidate.unavailableMessage {
                output.messages.append(unavailableMessage)
                continue
            }
            guard let normalized = candidate.normalized else { continue }
            output.validBudgets.append(normalized)
            output.bars.append(contentsOf: budgetBars(for: normalized, period: period))
            output.sections.append(budgetSection(
                normalized,
                isProduct: candidate.isProduct,
                targetLabel: candidate.targetLabel
            ))
        }
        return output
    }

    private static func budgetBars(
        for budget: NormalizedBudget,
        period: BillingPeriod?
    ) -> [UsageBar] {
        guard budget.amount > 0 else { return [] }
        return [
            UsageBar(
                stableKey: "budget-\(budget.id)",
                label: budget.name,
                used: budget.consumed.doubleValue,
                limit: budget.amount.doubleValue,
                resetsAt: period?.end,
                resetDisplayStyle: .relativeWithLocalTime,
                projectionCurrent: budget.consumed.doubleValue,
                projectionLimit: budget.amount.doubleValue,
                projectionPeriodStart: period?.start,
                projectionPeriodEnd: period?.end,
                showProjectionOnCurrentBar: period != nil
            ),
        ]
    }

    private static func budgetCandidate(
        _ budget: Budget,
        usageItems: [UsageItem]
    ) -> BudgetCandidate {
        guard
            let id = budget.id?.nonempty,
            let amount = budget.budgetAmount,
            amount >= 0,
            let preventFurtherUsage = budget.preventFurtherUsage,
            let willAlert = budget.budgetAlerting?.willAlert
        else {
            return BudgetCandidate(
                unavailableMessage: "GitHub returned a budget without complete amount, behavior, or alert settings."
            )
        }
        let targets = budget.productsOrSKUs.compactMap(\.nonempty)
        guard !targets.isEmpty else {
            return BudgetCandidate(unavailableMessage: "GitHub returned a budget without a product or SKU.")
        }
        let normalizedTargets = Set(targets.map(\.normalized))
        let targetLabel = targets.joined(separator: ", ")
        guard let isProduct = budget.isProductPricing else {
            return BudgetCandidate(
                unavailableMessage: "GitHub returned an unsupported budget pricing type for \(targetLabel)."
            )
        }
        guard let matching = matchingUsageItems(
            for: budget,
            isProduct: isProduct,
            normalizedTargets: normalizedTargets,
            usageItems: usageItems
        ) else {
            return BudgetCandidate(
                unavailableMessage: "GitHub returned a \(budget.scopeLabel) budget whose consumption cannot be calculated from organization usage."
            )
        }
        guard matching.allSatisfy({ $0.netAmount != nil }) else {
            return BudgetCandidate(
                unavailableMessage: "GitHub did not return complete net spend for the \(targetLabel) budget."
            )
        }
        let normalized = NormalizedBudget(
            id: id,
            name: "\(targetLabel) budget",
            amount: amount,
            consumed: matching.compactMap(\.netAmount).reduce(.zero, +),
            preventFurtherUsage: preventFurtherUsage,
            willAlert: willAlert,
            scopeDescription: budget.scopeDescription
        )
        return BudgetCandidate(
            normalized: normalized,
            isProduct: isProduct,
            targetLabel: targetLabel
        )
    }

    private static func matchingUsageItems(
        for budget: Budget,
        isProduct: Bool,
        normalizedTargets: Set<String>,
        usageItems: [UsageItem]
    ) -> [UsageItem]? {
        let scopedItems: [UsageItem]
        switch budget.budgetScope?.normalized {
        case "organization":
            scopedItems = usageItems
        case "repository":
            guard let entity = budget.budgetEntityName?.repositoryIdentity else { return nil }
            scopedItems = usageItems.filter { $0.repositoryName?.repositoryIdentity == entity }
        default:
            return nil
        }
        return scopedItems.filter { item in
            let candidate = isProduct ? item.product : item.sku
            return candidate.map { normalizedTargets.contains($0.normalized) } == true
        }
    }

    private static func budgetSection(
        _ budget: NormalizedBudget,
        isProduct: Bool,
        targetLabel: String
    ) -> ProviderCardInformationSection {
        let remaining = max(budget.amount - budget.consumed, 0)
        let consumptionDetail = budget.amount > 0
            ? "\(currencyText(remaining)) · \(decimalText(budget.consumed / budget.amount * 100))% consumed"
            : "\(currencyText(remaining)) · Zero-dollar budget"
        return ProviderCardInformationSection(
            id: "github-billing.budget.\(budget.id)",
            title: budget.name,
            items: [
                ProviderCardInformationItem(
                    id: "\(budget.id).scope",
                    label: isProduct ? "Product budget" : "SKU budget",
                    detail: targetLabel
                ),
                ProviderCardInformationItem(
                    id: "\(budget.id).applies-to",
                    label: "Applies to",
                    detail: budget.scopeDescription
                ),
                ProviderCardInformationItem(
                    id: "\(budget.id).behavior",
                    label: "Behavior",
                    detail: budget.behaviorLabel
                ),
                ProviderCardInformationItem(
                    id: "\(budget.id).consumed",
                    label: "Current net spend",
                    detail: currencyText(budget.consumed)
                ),
                ProviderCardInformationItem(
                    id: "\(budget.id).remaining",
                    label: "Remaining headroom",
                    detail: consumptionDetail
                ),
            ]
        )
    }

    private static func spendStatusMessages(for totals: SpendTotals?) -> [String] {
        totals == nil
            ? ["GitHub did not return complete gross, discount, and net amounts for this billing period."]
            : []
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
        usageItems = try container.decode([SummaryItem].self, forKey: .usageItems)
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
        usageItems = try container.decode([UsageItem].self, forKey: .usageItems)
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
        budgets = try container.decode([Budget].self, forKey: .budgets)
    }
}

private struct Budget: Decodable {
    let id: String?
    let budgetType: String?
    let budgetAmount: Decimal?
    let preventFurtherUsage: Bool?
    let budgetProductSKU: String?
    let budgetProductSKUs: [String]?
    let budgetScope: String?
    let budgetEntityName: String?
    let budgetAlerting: BudgetAlerting?

    var productsOrSKUs: [String] {
        if let budgetProductSKU { return [budgetProductSKU] }
        return budgetProductSKUs ?? []
    }

    var scopeLabel: String {
        budgetScope?.nonempty ?? "unknown-scope"
    }

    var isProductPricing: Bool? {
        switch budgetType?.normalized {
        case "productpricing": true
        case "skupricing": false
        default: nil
        }
    }

    var scopeDescription: String {
        if budgetScope?.normalized == "repository", let entity = budgetEntityName?.nonempty {
            return "Repository \(entity)"
        }
        return "Organization"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case budgetType = "budget_type"
        case budgetAmount = "budget_amount"
        case preventFurtherUsage = "prevent_further_usage"
        case budgetProductSKU = "budget_product_sku"
        case budgetProductSKUs = "budget_product_skus"
        case budgetScope = "budget_scope"
        case budgetEntityName = "budget_entity_name"
        case budgetAlerting = "budget_alerting"
    }
}

private struct BudgetAlerting: Decodable {
    let willAlert: Bool?

    enum CodingKeys: String, CodingKey {
        case willAlert = "will_alert"
    }
}

private struct SpendTotals {
    let gross: Decimal
    let discount: Decimal
    let net: Decimal

    init?(items: [SummaryItem]) {
        guard items.allSatisfy({
            $0.grossAmount != nil && $0.discountAmount != nil && $0.netAmount != nil
        }) else {
            return nil
        }
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
    let willAlert: Bool
    let scopeDescription: String

    var behaviorLabel: String {
        if preventFurtherUsage { return "Hard stop" }
        return willAlert ? "Alert only" : "Tracking only"
    }
}

private struct BudgetCandidate {
    let normalized: NormalizedBudget?
    let isProduct: Bool
    let targetLabel: String
    let unavailableMessage: String?

    init(
        normalized: NormalizedBudget? = nil,
        isProduct: Bool = false,
        targetLabel: String = "",
        unavailableMessage: String? = nil
    ) {
        self.normalized = normalized
        self.isProduct = isProduct
        self.targetLabel = targetLabel
        self.unavailableMessage = unavailableMessage
    }
}

private struct BudgetOutput {
    var bars: [UsageBar] = []
    var sections: [ProviderCardInformationSection] = []
    var validBudgets: [NormalizedBudget] = []
    var messages: [String] = []
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

    var repositoryIdentity: String? {
        let components = split(separator: "/", omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }
        let owner = components[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let repository = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !owner.isEmpty, !repository.isEmpty else { return nil }
        return "\(owner.lowercased())/\(repository.lowercased())"
    }
}
