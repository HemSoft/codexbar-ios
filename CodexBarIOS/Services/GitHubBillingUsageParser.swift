import Foundation

public enum GitHubBillingUsageParser {
    public static func parsePersonal(
        summaryData: Data,
        usageData: Data,
        repositoryVisibility: [String: Bool],
        repositoryVisibilityMessage: String? = nil,
        planName: String,
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date
    ) -> ProviderUsageResult? {
        let accountName = configuration.githubBillingOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !accountName.isEmpty,
            let summary = try? JSONDecoder().decode(SummaryResponse.self, from: summaryData),
            summary.user?.caseInsensitiveCompare(accountName) == .orderedSame,
            summary.organization == nil,
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
        let detailOutput = usageDetails(usage.usageItems)
        let sections = personalInformationSections(
            bars: bars,
            usageDetails: detailOutput.items
        )
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
            ] + Set(unavailable.values).sorted()
                + [repositoryVisibilityMessage, detailOutput.message].compactMap { $0 }
                + spendStatusMessages(for: totals),
            cardInformationSections: sections,
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
        let owner = configuration.githubBillingOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !owner.isEmpty,
            let summary = try? JSONDecoder().decode(SummaryResponse.self, from: summaryData),
            summary.organization?.caseInsensitiveCompare(owner) == .orderedSame,
            summary.user == nil,
            summary.usageItems.allSatisfy(\.hasOrganizationMetricFields),
            let usage = try? JSONDecoder().decode(UsageResponse.self, from: usageData),
            usage.usageItems.allSatisfy({ $0.isOrganizationDetail(for: owner) }),
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
        let monetaryMetrics = totals.map {
            makeSpendMetrics(totals: $0, period: period, fetchedAt: fetchedAt)
        } ?? []

        let presentation = organizationPresentation(
            budgetOutput: budgetOutput,
            totals: totals,
            details: usageDetails(usage.usageItems),
            budgetStatusMessage: budgetStatusMessage,
            hasBudgets: !budgets.isEmpty
        )
        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: .githubBilling,
            title: configuration.displayName,
            subtitle: "GitHub organization billing for \(owner)",
            bars: bars,
            monetaryMetrics: monetaryMetrics,
            usageMessages: presentation.messages,
            cardInformationSections: presentation.sections,
            cacheIdentity: owner.lowercased(),
            fetchedAt: fetchedAt
        )
    }

    private static func organizationPresentation(
        budgetOutput: BudgetOutput,
        totals: SpendTotals?,
        details: UsageDetailOutput,
        budgetStatusMessage: String?,
        hasBudgets: Bool
    ) -> OrganizationPresentationOutput {
        var messages = budgetOutput.messages + spendStatusMessages(for: totals)
        if let detailMessage = details.message {
            messages.append(detailMessage)
        }
        if let budgetStatusMessage {
            messages.append(budgetStatusMessage)
        } else if !hasBudgets {
            messages.append("GitHub returned no organization budgets. Metered usage can still incur charges.")
        }
        var sections = budgetOutput.sections
        if !details.items.isEmpty {
            sections.append(ProviderCardInformationSection(
                id: "github-billing.usage-detail",
                title: "Repository, product, and SKU usage",
                items: details.items
            ))
        }
        return OrganizationPresentationOutput(messages: messages, sections: sections)
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
        for item in items where item.isPotentialActionsMinutes {
            guard
                item.isActionsMinutes,
                let repositoryName = item.repositoryName,
                let isPrivate = repositoryVisibility[repositoryName],
                let multiplier = item.standardRunnerMultiplier,
                let quantity = item.quantity,
                quantity >= 0,
                item.hasNonnegativeFinancialFields
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
        let matching = items.filter { $0.isPotentialActionsOrPackagesStorage }
        guard matching.allSatisfy(\.isActionsOrPackagesStorage) else {
            unavailable[metricID] = "GitHub returned Actions or Packages storage without a recognized storage SKU."
            return
        }
        guard matching.allSatisfy(\.isGBHours) else {
            unavailable[metricID] = "GitHub returned storage in a unit that cannot be compared with a GB-hour allowance."
            return
        }
        guard matching.allSatisfy({ $0.grossQuantity.map { $0 >= 0 } == true }) else {
            unavailable[metricID] = "GitHub did not return a complete nonnegative accrued storage quantity."
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

        let storageItems = items.filter(\.isPotentialLFSStorage)
        if storageItems.allSatisfy(\.isLFSStorage),
           storageItems.allSatisfy(\.isGBHours),
           storageItems.allSatisfy({ $0.grossQuantity.map { $0 >= 0 } == true }),
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

        let bandwidthItems = items.filter(\.isPotentialLFSBandwidth)
        if bandwidthItems.allSatisfy(\.isLFSBandwidth),
           bandwidthItems.allSatisfy(\.isGB),
           bandwidthItems.allSatisfy({ $0.grossQuantity.map { $0 >= 0 } == true }) {
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

    private static func personalInformationSections(
        bars: [UsageBar],
        usageDetails: [ProviderCardInformationItem]
    ) -> [ProviderCardInformationSection] {
        var sections: [ProviderCardInformationSection] = []
        if !bars.isEmpty {
            sections.append(allowanceSection(bars))
        }
        if !usageDetails.isEmpty {
            sections.append(ProviderCardInformationSection(
                id: "github-billing.usage-detail",
                title: "Repository, product, and SKU usage",
                items: usageDetails
            ))
        }
        return sections
    }

    private static func allowanceSection(_ bars: [UsageBar]) -> ProviderCardInformationSection {
        ProviderCardInformationSection(
            id: "github-billing.personal-allowances",
            title: "Included personal allowances",
            items: bars.enumerated().map { index, bar in
                let remaining = max(bar.limit - bar.used, 0)
                return ProviderCardInformationItem(
                    id: bar.stableKey ?? "allowance-\(index)",
                    label: bar.label,
                    detail: "\(usageAmount(bar.used)) used · \(usageAmount(bar.limit)) included · "
                        + "\(usageAmount(remaining)) remaining"
                )
            }
        )
    }

    private static func usageAmount(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...6)))
    }

    private static func organizationUsageBars(_ items: [SummaryItem]) -> [UsageBar] {
        var buckets: [String: OrganizationUsageBucket] = [:]
        for item in items {
            guard
                let product = item.product?.nonempty,
                let sku = item.sku?.nonempty,
                let quantity = item.grossQuantity,
                let unit = item.unitType?.nonempty
            else {
                continue
            }
            let identity = [product, sku, unit].map(stableKey).joined(separator: "-")
            if var bucket = buckets[identity] {
                bucket.quantity += quantity
                buckets[identity] = bucket
            } else {
                buckets[identity] = OrganizationUsageBucket(
                    product: product,
                    sku: sku,
                    unit: unit,
                    quantity: quantity
                )
            }
        }
        return buckets.keys.sorted().compactMap { identity in
            guard let bucket = buckets[identity] else { return nil }
            return UsageBar(
                stableKey: "usage-\(identity)",
                label: "\(bucket.product) · \(bucket.sku)",
                used: bucket.quantity.doubleValue,
                limit: 0,
                fractionlessUsageText: "\(decimalText(bucket.quantity)) \(bucket.unit)"
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
                if let unavailableSection = candidate.unavailableSection {
                    output.sections.append(unavailableSection)
                }
                continue
            }
            guard let normalized = candidate.normalized else { continue }
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
                unavailableMessage: "GitHub returned a \(budget.scopeLabel) budget whose consumption cannot be calculated from organization usage.",
                unavailableSection: unavailableBudgetSection(
                    id: id,
                    targetLabel: targetLabel,
                    amount: amount,
                    isProduct: isProduct,
                    preventFurtherUsage: preventFurtherUsage,
                    willAlert: willAlert,
                    scopeDescription: budget.scopeDescription
                )
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

    private static func unavailableBudgetSection(
        id: String,
        targetLabel: String,
        amount: Decimal,
        isProduct: Bool,
        preventFurtherUsage: Bool,
        willAlert: Bool,
        scopeDescription: String
    ) -> ProviderCardInformationSection {
        let behavior = preventFurtherUsage ? "Hard stop" : (willAlert ? "Alert only" : "Tracking only")
        return ProviderCardInformationSection(
            id: "github-billing.budget.\(id)",
            title: "\(targetLabel) budget",
            items: [
                ProviderCardInformationItem(
                    id: "\(id).scope",
                    label: isProduct ? "Product budget" : "SKU budget",
                    detail: targetLabel
                ),
                ProviderCardInformationItem(
                    id: "\(id).applies-to",
                    label: "Applies to",
                    detail: scopeDescription
                ),
                ProviderCardInformationItem(id: "\(id).amount", label: "Budget", detail: currencyText(amount)),
                ProviderCardInformationItem(id: "\(id).behavior", label: "Behavior", detail: behavior),
                ProviderCardInformationItem(
                    id: "\(id).consumption",
                    label: "Consumption and headroom",
                    detail: "Unavailable for this budget scope"
                ),
            ]
        )
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

    private static func usageDetails(_ items: [UsageItem]) -> UsageDetailOutput {
        let details = items.enumerated().compactMap { index, item -> ProviderCardInformationItem? in
            guard let product = item.product?.nonempty, let sku = item.sku?.nonempty else {
                return nil
            }
            let repository = item.repositoryName?.nonempty ?? "Account-wide"
            let quantity = item.quantity.map(decimalText) ?? "Unknown quantity"
            let unit = item.unitType?.nonempty ?? "units"
            let unitPrice = item.pricePerUnit.map(currencyText) ?? "Unknown unit price"
            let gross = item.grossAmount.map(currencyText) ?? "Unknown gross amount"
            let discount = item.discountAmount.map(currencyText) ?? "Unknown discount"
            let net = item.netAmount.map(currencyText) ?? "Unknown net amount"
            return ProviderCardInformationItem(
                id: "usage.\(index).\(stableKey(repository)).\(stableKey(sku))",
                label: repository,
                detail: "\(product) · \(sku) · \(quantity) \(unit) · \(unitPrice)/unit · "
                    + "\(gross) gross · \(discount) discount · \(net) net"
            )
        }
        let omittedCount = max(0, details.count - UsageDetailOutput.maximumCount)
        return UsageDetailOutput(
            items: Array(details.prefix(UsageDetailOutput.maximumCount)),
            message: omittedCount == 0
                ? nil
                : "\(omittedCount) additional repository, product, and SKU detail rows were omitted from the card."
        )
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

private struct OrganizationPresentationOutput {
    let messages: [String]
    let sections: [ProviderCardInformationSection]
}

private struct UsageDetailOutput {
    static let maximumCount = 40

    let items: [ProviderCardInformationItem]
    let message: String?
}

private struct OrganizationUsageBucket {
    let product: String
    let sku: String
    let unit: String
    var quantity: Decimal
}

private struct SummaryResponse: Decodable {
    let timePeriod: TimePeriod?
    let user: String?
    let organization: String?
    let usageItems: [SummaryItem]

    enum CodingKeys: String, CodingKey {
        case timePeriod
        case user
        case organization
        case usageItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timePeriod = try container.decodeIfPresent(TimePeriod.self, forKey: .timePeriod)
        user = try container.decodeIfPresent(String.self, forKey: .user)?.nonempty
        organization = try container.decodeIfPresent(String.self, forKey: .organization)?.nonempty
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
    let pricePerUnit: Decimal?
    let grossQuantity: Decimal?
    let grossAmount: Decimal?
    let discountAmount: Decimal?
    let netAmount: Decimal?

    var hasOrganizationMetricFields: Bool {
        product?.nonempty != nil
            && sku?.nonempty != nil
            && unitType?.nonempty != nil
            && pricePerUnit.map { $0 >= 0 } == true
            && grossQuantity.map { $0 >= 0 } == true
            && grossAmount.map { $0 >= 0 } == true
            && discountAmount.map { $0 >= 0 } == true
            && netAmount.map { $0 >= 0 } == true
    }

    var isActionsOrPackagesStorage: Bool {
        let product = product?.normalized
        let sku = sku?.normalized
        return (product == "actions" && sku == "actionsstorage")
            || (product == "packages" && sku == "packagesstorage")
    }

    var isPotentialActionsOrPackagesStorage: Bool {
        let product = product?.normalized
        let sku = sku?.normalized
        guard product == "actions" || product == "packages" else { return false }
        return sku == "actionsstorage" || sku == "packagesstorage" || (sku == nil && isGBHours)
    }

    var isLFSStorage: Bool {
        isLFS && (sku?.normalized.contains("storage") == true)
    }

    var isLFSBandwidth: Bool {
        isLFS && (sku?.normalized.contains("bandwidth") == true)
    }

    var isPotentialLFSStorage: Bool {
        (isLFS || sku?.normalized.contains("lfs") == true)
            && (isGBHours || sku?.normalized.contains("storage") == true)
    }

    var isPotentialLFSBandwidth: Bool {
        (isLFS || sku?.normalized.contains("lfs") == true)
            && (isGB || sku?.normalized.contains("bandwidth") == true)
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
    let date: String?
    let product: String?
    let sku: String?
    let quantity: Decimal?
    let unitType: String?
    let pricePerUnit: Decimal?
    let grossAmount: Decimal?
    let discountAmount: Decimal?
    let netAmount: Decimal?
    let repositoryName: String?
    let organizationName: String?

    var hasNonnegativeFinancialFields: Bool {
        pricePerUnit.map { $0 >= 0 } == true
            && grossAmount.map { $0 >= 0 } == true
            && discountAmount.map { $0 >= 0 } == true
            && netAmount.map { $0 >= 0 } == true
    }

    func isOrganizationDetail(for owner: String) -> Bool {
        date?.nonempty != nil
            && product?.nonempty != nil
            && sku?.nonempty != nil
            && quantity.map { $0 >= 0 } == true
            && unitType?.nonempty != nil
            && hasNonnegativeFinancialFields
            && organizationName?.caseInsensitiveCompare(owner) == .orderedSame
    }

    var isActionsMinutes: Bool {
        product?.normalized.contains("actions") == true
            && unitType?.normalized.contains("minute") == true
    }

    var isPotentialActionsMinutes: Bool {
        guard unitType?.normalized.contains("minute") == true else { return false }
        return product?.normalized.contains("actions") == true
            || sku?.normalized.hasPrefix("actions") == true
    }

    var standardRunnerMultiplier: Decimal? {
        switch sku?.normalized {
        case "actionslinux", "actionslinuxarm": 1
        case "actionswindows", "actionswindowsarm": 2
        case "actionsmacos": 10
        default: nil
        }
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
            $0.grossAmount.map { $0 >= 0 } == true
                && $0.discountAmount.map { $0 >= 0 } == true
                && $0.netAmount.map { $0 >= 0 } == true
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
    let unavailableSection: ProviderCardInformationSection?

    init(
        normalized: NormalizedBudget? = nil,
        isProduct: Bool = false,
        targetLabel: String = "",
        unavailableMessage: String? = nil,
        unavailableSection: ProviderCardInformationSection? = nil
    ) {
        self.normalized = normalized
        self.isProduct = isProduct
        self.targetLabel = targetLabel
        self.unavailableMessage = unavailableMessage
        self.unavailableSection = unavailableSection
    }
}

private struct BudgetOutput {
    var bars: [UsageBar] = []
    var sections: [ProviderCardInformationSection] = []
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
