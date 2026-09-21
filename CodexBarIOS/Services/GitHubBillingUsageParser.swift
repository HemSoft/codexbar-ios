import Foundation

public enum GitHubBillingUsageParser {
    private static let unavailableAmountText = "Unavailable"

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

        let period = BillingPeriod(timePeriod: summary.timePeriod, containing: fetchedAt)
        let plan = GitHubPlanAllowance(name: planName, scope: .personal)
        let allowanceFailure = unsupportedPlanMessage(name: planName, scope: .personal)
        let allowance = makeAllowanceOutput(
            summaryItems: summary.usageItems,
            usageItems: usage.usageItems,
            repositoryVisibility: repositoryVisibility,
            plan: plan,
            period: period,
            scope: .personal,
            failure: allowanceFailure
        )

        let totals = SpendTotals(items: summary.usageItems)
        let currency = currencyResolution(topLevel: summary.currency, items: summary.usageItems)
        let monetaryMetrics: [ProviderMonetaryMetric]
        if let totals, let currencyCode = currency.verifiedCode {
            monetaryMetrics = makeSpendMetrics(
                totals: totals,
                period: period,
                fetchedAt: fetchedAt,
                currencyCode: currencyCode
            )
        } else {
            monetaryMetrics = []
        }
        let planDescriptor = plan.map { plan in
            ProviderPlanDescriptor.make(
                providerPrefix: ProviderID.githubBilling.rawValue,
                identifier: plan.id,
                label: plan.label
            )
        }
        let detailOutput = usageDetails(usage.usageItems, currencyCode: currency.verifiedCode)
        let notes = amountsAndCurrencySection(
            currency: currency,
            includesPersonalBudgetNotes: true,
            plan: plan,
            budgetQualification: nil,
            omittedDetailCount: detailOutput.omittedCount
        )
        let sections = personalInformationSections(
            productSections: productSummarySections(
                summary.usageItems,
                currencyCode: currency.verifiedCode,
                includesPlanAllowances: true,
                bars: allowance.bars,
                unavailable: allowance.unavailable
            ),
            bars: allowance.bars,
            notes: notes,
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
            bars: allowance.bars,
            monetaryMetrics: monetaryMetrics,
            unavailableUsageMetrics: allowance.unavailable,
            usageMessages: Set(allowance.unavailable.values).sorted()
                + [repositoryVisibilityMessage, currency.conflictMessage].compactMap { $0 }
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
        repositoryVisibility: [String: Bool] = [:],
        repositoryVisibilityMessage: String? = nil,
        planName: String = "",
        planStatusMessage: String? = nil,
        configuration: ProviderAccountConfiguration,
        fetchedAt: Date
    ) -> ProviderUsageResult? {
        let owner = configuration.githubBillingOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !owner.isEmpty,
            let summary = try? JSONDecoder().decode(SummaryResponse.self, from: summaryData),
            summary.organization?.caseInsensitiveCompare(owner) == .orderedSame,
            summary.user == nil,
            let usage = try? JSONDecoder().decode(UsageResponse.self, from: usageData),
            usage.usageItems.allSatisfy({ $0.belongsToOrganization(owner) }),
            let budgets = decodeBudgets(from: budgetPageData)
        else {
            return nil
        }

        let period = BillingPeriod(timePeriod: summary.timePeriod, containing: fetchedAt)
        let currency = currencyResolution(topLevel: summary.currency, items: summary.usageItems)
        let plan = GitHubPlanAllowance(name: planName, scope: .organization)
        let allowance = makeAllowanceOutput(
            summaryItems: summary.usageItems,
            usageItems: usage.usageItems,
            repositoryVisibility: repositoryVisibility,
            plan: plan,
            period: period,
            scope: .organization,
            failure: planStatusMessage ?? unsupportedPlanMessage(name: planName, scope: .organization)
        )
        var bars = organizationUsageBars(summary.usageItems) + allowance.bars
        let budgetOutput = makeBudgetOutput(
            budgets: budgets,
            usageItems: usage.usageItems,
            period: period,
            currencyCode: currency.verifiedCode
        )
        bars.append(contentsOf: budgetOutput.bars)

        let totals = SpendTotals(items: summary.usageItems)
        let monetaryMetrics: [ProviderMonetaryMetric]
        if let totals, let currencyCode = currency.verifiedCode {
            monetaryMetrics = makeSpendMetrics(
                totals: totals,
                period: period,
                fetchedAt: fetchedAt,
                currencyCode: currencyCode
            )
        } else {
            monetaryMetrics = []
        }

        let presentation = organizationPresentation(
            summaryItems: summary.usageItems,
            currency: currency,
            allowance: allowance,
            plan: plan,
            budgetOutput: budgetOutput,
            totals: totals,
            details: usageDetails(usage.usageItems, currencyCode: currency.verifiedCode),
            budgetStatusMessage: budgetStatusMessage,
            repositoryVisibilityMessage: repositoryVisibilityMessage,
            hasBudgets: !budgets.isEmpty
        )
        let planDescriptor = plan.map { plan in
            ProviderPlanDescriptor.make(
                providerPrefix: ProviderID.githubBilling.rawValue,
                identifier: "organization-\(plan.id)",
                label: plan.label
            )
        }
        return ProviderUsageResult(
            accountID: configuration.id,
            providerID: .githubBilling,
            title: configuration.displayName,
            plan: planDescriptor,
            subtitle: "GitHub organization billing for \(owner)",
            bars: bars,
            monetaryMetrics: monetaryMetrics,
            unavailableUsageMetrics: allowance.unavailable,
            usageMessages: presentation.messages,
            cardInformationSections: presentation.sections,
            cacheIdentity: owner.lowercased(),
            fetchedAt: fetchedAt
        )
    }

    private static func organizationPresentation(
        summaryItems: [SummaryItem],
        currency: GitHubBillingCurrency,
        allowance: AllowanceOutput,
        plan: GitHubPlanAllowance?,
        budgetOutput: BudgetOutput,
        totals: SpendTotals?,
        details: UsageDetailOutput,
        budgetStatusMessage: String?,
        repositoryVisibilityMessage: String?,
        hasBudgets: Bool
    ) -> OrganizationPresentationOutput {
        var messages = Set(allowance.unavailable.values).sorted()
            + budgetOutput.messages
            + spendStatusMessages(for: totals)
        if let conflictMessage = currency.conflictMessage {
            messages.append(conflictMessage)
        }
        if let budgetStatusMessage {
            messages.append(budgetStatusMessage)
        }
        if let repositoryVisibilityMessage {
            messages.append(repositoryVisibilityMessage)
        }
        var sections = productSummarySections(
            summaryItems,
            currencyCode: currency.verifiedCode,
            includesPlanAllowances: true,
            bars: allowance.bars,
            unavailable: allowance.unavailable
        )
        sections.append(contentsOf: allowanceSections(allowance.bars))
        sections.append(contentsOf: budgetOutput.sections)
        let budgetQualification = budgetStatusMessage == nil && !hasBudgets
            ? "GitHub returned no organization budgets. Metered usage can still incur charges."
            : nil
        if let notes = amountsAndCurrencySection(
            currency: currency,
            includesPersonalBudgetNotes: false,
            plan: plan,
            budgetQualification: budgetQualification,
            omittedDetailCount: details.omittedCount
        ) {
            sections.append(notes)
        }
        if !details.items.isEmpty {
            sections.append(ProviderCardInformationSection(
                id: "github-billing.usage-detail",
                title: "Repository, product, and SKU usage",
                items: details.items
            ))
        }
        return OrganizationPresentationOutput(messages: messages, sections: sections)
    }

    // https://docs.github.com/en/billing/reference/actions-runner-pricing
    private static func unsupportedPlanMessage(
        name: String,
        scope: GitHubAllowanceScope
    ) -> String {
        if scope == .organization, ["business", "businessplus", "enterprise"].contains(name.normalized) {
            return "GitHub Enterprise allowances are pooled, but the organization API does not identify this organization's share."
        }
        let plans = scope == .personal ? "Free or Pro" : "Free or Team"
        let action = scope == .personal
            ? "Refresh the account or sign in again with the intended GitHub user."
            : "Refresh the account or sign in again and approve organization access."
        return "GitHub did not return a supported \(plans) plan, so included allowances are unavailable. \(action)"
    }

    private static func makeAllowanceOutput(
        summaryItems: [SummaryItem],
        usageItems: [UsageItem],
        repositoryVisibility: [String: Bool],
        plan: GitHubPlanAllowance?,
        period: BillingPeriod?,
        scope: GitHubAllowanceScope,
        failure: String
    ) -> AllowanceOutput {
        guard let plan else {
            return AllowanceOutput(unavailable: unavailableAllowances(scope: scope, reason: failure))
        }
        guard let period else {
            let reason = "GitHub did not return a complete billing period, so included allowances are unavailable."
            return AllowanceOutput(unavailable: unavailableAllowances(scope: scope, reason: reason))
        }

        var output = AllowanceOutput()
        appendActionsMinutes(
            summaryItems: summaryItems,
            usageItems: usageItems,
            repositoryVisibility: repositoryVisibility,
            plan: plan,
            period: period,
            output: &output
        )
        appendActionsStorage(
            summaryItems,
            usageItems: usageItems,
            repositoryVisibility: repositoryVisibility,
            plan: plan,
            period: period,
            output: &output
        )
        appendPackagesStorage(summaryItems, plan: plan, period: period, output: &output)
        appendPackagesDataTransfer(
            summaryItems,
            plan: plan,
            period: period,
            output: &output
        )
        appendLFSUsage(summaryItems, plan: plan, period: period, output: &output)
        appendCodespacesUsage(summaryItems, plan: plan, period: period, output: &output)
        return output
    }

    private static func unavailableAllowances(
        scope: GitHubAllowanceScope,
        reason: String
    ) -> [String: String] {
        var keys = [
            "githubBilling.actions-private-minutes",
            "githubBilling.actions-packages-storage",
            "githubBilling.packages-storage",
            "githubBilling.packages-data-transfer",
            "githubBilling.lfs-storage",
            "githubBilling.lfs-bandwidth",
        ]
        if scope == .personal {
            keys += ["githubBilling.codespaces-core-hours", "githubBilling.codespaces-storage"]
        }
        return Dictionary(uniqueKeysWithValues: keys.map { ($0, reason) })
    }

    private static func appendActionsMinutes(
        summaryItems: [SummaryItem],
        usageItems: [UsageItem],
        repositoryVisibility: [String: Bool],
        plan: GitHubPlanAllowance,
        period: BillingPeriod,
        output: inout AllowanceOutput
    ) {
        let metricID = "githubBilling.actions-private-minutes"
        let summaryCandidates = summaryItems.filter(\.isPotentialActionsMinutes)
        let candidates = usageItems.filter(\.isPotentialActionsMinutes)
        if let message = actionsMinutesEvidenceFailure(
            summaryCandidates: summaryCandidates,
            detailCandidates: candidates
        ) {
            output.unavailable[metricID] = message
            return
        }
        guard !candidates.isEmpty else {
            appendEmptyActionsMinutes(
                summaryItems: summaryItems,
                plan: plan,
                period: period,
                output: &output
            )
            return
        }
        let total = includedActionsMinutes(candidates, repositoryVisibility: repositoryVisibility)
        guard let used = total.used else {
            output.unavailable[metricID] = total.unavailableMessage
            return
        }
        let includedSummary = summaryCandidates.filter { item in
            if case .includedStandard = item.actionsRunnerAllowance { return true }
            return false
        }
        let reportedBillable = includedSummary.reduce(Decimal.zero) { total, item in
            guard let quantity = item.netQuantity, let price = item.pricePerUnit else { return total }
            return total + GitHubActionsRunnerCatalog.allowanceMinutes(quantity: quantity, unitPrice: price)
        }
        let planLimit = Decimal(plan.actionsMinutes)
        guard reportedBillable <= max(used - planLimit, .zero) else {
            output.unavailable[metricID] = "GitHub reported billable standard-runner minutes before the included "
                + "allowance was exhausted. Refresh the account; if this continues, review GitHub Billing."
            return
        }
        output.bars.append(allowanceBar(
            stableKey: "actions-private-minutes",
            label: "Actions minutes",
            used: used,
            limit: planLimit,
            period: period
        ))
    }

    private static func actionsMinutesEvidenceFailure(
        summaryCandidates: [SummaryItem],
        detailCandidates: [UsageItem]
    ) -> String? {
        guard summaryCandidates.allSatisfy(\.hasCompleteAllowanceQuantityEvidence) else {
            return "GitHub did not return complete Actions gross, discount, and billable quantities."
        }
        guard quantityTotals(summaryCandidates) == quantityTotals(detailCandidates) else {
            return "GitHub's Actions summary and repository detail did not reconcile completely."
        }
        return nil
    }

    private static func includedActionsMinutes(
        _ items: [UsageItem],
        repositoryVisibility: [String: Bool]
    ) -> ActionsMinutesTotal {
        var used = Decimal.zero
        for item in items {
            switch actionsMinuteContribution(item, repositoryVisibility: repositoryVisibility) {
            case let .included(reportedMinutes):
                used += reportedMinutes
            case .excluded:
                continue
            case let .unavailable(reason):
                return ActionsMinutesTotal(unavailableMessage: reason)
            }
        }
        return ActionsMinutesTotal(used: used)
    }

    private static func actionsMinuteContribution(
        _ item: UsageItem,
        repositoryVisibility: [String: Bool]
    ) -> ActionsMinuteContribution {
        guard
            item.isActionsMinutes,
            let quantity = item.quantity,
            quantity >= 0,
            item.hasNonnegativeFinancialFields
        else {
            return .unavailable("GitHub returned private Actions usage outside the verified runner allowance contract.")
        }
        switch item.actionsRunnerAllowance {
        case .includedStandard:
            return standardRunnerContribution(
                item,
                quantity: quantity,
                repositoryVisibility: repositoryVisibility
            )
        case .excludedPaidLarger, .excludedSelfHosted:
            return .excluded
        case .unknown:
            return .unavailable("GitHub returned private Actions usage outside the verified runner allowance contract.")
        }
    }

    private static func standardRunnerContribution(
        _ item: UsageItem,
        quantity: Decimal,
        repositoryVisibility: [String: Bool]
    ) -> ActionsMinuteContribution {
        guard
            let repositoryName = item.repositoryName,
            let isPrivate = repositoryVisibility[repositoryName]
        else {
            return .unavailable("GitHub returned Actions usage whose repository visibility CodexBar could not verify.")
        }
        guard isPrivate else { return .excluded }
        guard
            let unitPrice = item.pricePerUnit,
            let expectedRate = item.expectedStandardRunnerRate,
            unitPrice == expectedRate
        else {
            return .unavailable("GitHub returned a standard-runner price outside the verified billing contract.")
        }
        return .included(GitHubActionsRunnerCatalog.allowanceMinutes(quantity: quantity, unitPrice: unitPrice))
    }

    private static func quantityTotals<Item: MeteredQuantityItem>(
        _ items: [Item]
    ) -> [MeteredQuantityKey: Decimal]? {
        var totals: [MeteredQuantityKey: Decimal] = [:]
        for item in items {
            guard let quantity = item.allowanceQuantity, quantity >= 0 else { return nil }
            guard quantity > 0 else { continue }
            guard
                let sku = item.sku?.normalized.nonempty,
                let unit = item.unitType?.normalized.nonempty,
                let unitPrice = item.pricePerUnit,
                unitPrice >= 0
            else {
                return nil
            }
            totals[MeteredQuantityKey(sku: sku, unit: unit, unitPrice: unitPrice), default: 0] += quantity
        }
        return totals
    }

    private static func appendEmptyActionsMinutes(
        summaryItems: [SummaryItem],
        plan: GitHubPlanAllowance,
        period: BillingPeriod,
        output: inout AllowanceOutput
    ) {
        let summaryReportsUsage = summaryItems.contains { item in
            item.isPotentialActionsMinutes && item.grossQuantity.map { $0 > 0 } == true
        }
        if summaryReportsUsage {
            output.unavailable["githubBilling.actions-private-minutes"] =
                "GitHub's summary reported Actions minutes without the repository detail required to verify the allowance."
            return
        }
        output.bars.append(allowanceBar(
            stableKey: "actions-private-minutes",
            label: "Actions minutes",
            used: 0,
            limit: Decimal(plan.actionsMinutes),
            period: period
        ))
    }

    private static func appendActionsStorage(
        _ items: [SummaryItem],
        usageItems: [UsageItem],
        repositoryVisibility: [String: Bool],
        plan: GitHubPlanAllowance,
        period: BillingPeriod,
        output: inout AllowanceOutput
    ) {
        let metricID = "githubBilling.actions-packages-storage"
        let matching = items.filter(\.isPotentialActionsStorage)
        if let message = actionsStorageEvidenceFailure(matching) {
            output.unavailable[metricID] = message
            return
        }
        let total = matching.compactMap(\.grossQuantity).reduce(.zero, +)
        let details = usageItems.filter(\.isPotentialActionsStorage)
        guard let accruedUsage = privateRepositoryQuantity(
            expectedTotal: total,
            items: details,
            repositoryVisibility: repositoryVisibility,
            isValid: { $0.isActionsStorage && $0.isGBHours }
        ) else {
            output.unavailable[metricID] = "GitHub did not return complete repository eligibility for Actions storage."
            return
        }
        let periodHours = Decimal(period.hours)
        let used = accruedUsage / periodHours
        let billable = matching.compactMap(\.netQuantity).reduce(.zero, +) / periodHours
        guard allowanceBillingIsConsistent(used: used, limit: plan.actionsStorageGB, billable: billable) else {
            output.unavailable[metricID] = prematureBillingMessage(for: "Actions storage")
            return
        }
        output.bars.append(allowanceBar(
            stableKey: "actions-packages-storage",
            label: "Actions storage",
            used: used,
            limit: plan.actionsStorageGB,
            period: period
        ))
    }

    private static func actionsStorageEvidenceFailure(_ items: [SummaryItem]) -> String? {
        guard items.allSatisfy(\.isActionsStorage) else {
            return "GitHub returned Actions storage without the recognized storage SKU."
        }
        guard items.allSatisfy(\.isGBHours) else {
            return "GitHub returned Actions storage in a unit that cannot be compared with its monthly allowance."
        }
        guard items.allSatisfy(\.hasCompleteAllowanceQuantityEvidence) else {
            return "GitHub did not return complete Actions-storage gross, discount, and billable quantities."
        }
        return nil
    }

    private static func appendPackagesStorage(
        _ items: [SummaryItem],
        plan: GitHubPlanAllowance,
        period: BillingPeriod,
        output: inout AllowanceOutput
    ) {
        let metricID = "githubBilling.packages-storage"
        let matching = items.filter(\.isPotentialPackagesStorage)
        guard matching.allSatisfy(\.isPackagesStorage), matching.allSatisfy(\.isGBHours) else {
            output.unavailable[metricID] = "GitHub returned Packages storage in an unsupported SKU or unit."
            return
        }
        guard matching.allSatisfy(\.hasCompleteAllowanceQuantityEvidence) else {
            output.unavailable[metricID] = "GitHub did not return complete Packages-storage gross, discount, and billable quantities."
            return
        }
        let total = matching.compactMap(\.grossQuantity).reduce(.zero, +)
        guard total == 0 else {
            output.unavailable[metricID] = "GitHub Billing does not identify package visibility, so nonzero "
                + "Packages storage cannot be compared with the private-package allowance."
            return
        }
        output.bars.append(allowanceBar(
            stableKey: "packages-storage",
            label: "Packages storage",
            used: 0,
            limit: plan.packagesStorageGB,
            period: period
        ))
    }

    private static func appendPackagesDataTransfer(
        _ items: [SummaryItem],
        plan: GitHubPlanAllowance,
        period: BillingPeriod,
        output: inout AllowanceOutput
    ) {
        let metricID = "githubBilling.packages-data-transfer"
        let matching = items.filter(\.isPotentialPackagesDataTransfer)
        guard matching.allSatisfy(\.isPackagesDataTransfer), matching.allSatisfy(\.isGB) else {
            output.unavailable[metricID] = "GitHub returned Packages data transfer in an unsupported SKU or unit."
            return
        }
        guard matching.allSatisfy(\.hasCompleteAllowanceQuantityEvidence) else {
            output.unavailable[metricID] = "GitHub did not return complete Packages transfer gross, discount, and billable quantities."
            return
        }
        let total = matching.compactMap(\.grossQuantity).reduce(.zero, +)
        guard total == 0 else {
            output.unavailable[metricID] = "GitHub Billing does not identify package visibility or free Actions "
                + "downloads, so nonzero Packages transfer cannot be compared with the private-package allowance."
            return
        }
        output.bars.append(allowanceBar(
            stableKey: "packages-data-transfer",
            label: "Packages data transfer",
            used: 0,
            limit: Decimal(plan.packagesTransferGB),
            period: period
        ))
    }

    private static func privateRepositoryQuantity(
        expectedTotal: Decimal,
        items: [UsageItem],
        repositoryVisibility: [String: Bool],
        isValid: (UsageItem) -> Bool
    ) -> Decimal? {
        if items.isEmpty { return expectedTotal == 0 ? 0 : nil }
        var total = Decimal.zero
        var eligible = Decimal.zero
        for item in items {
            guard
                isValid(item),
                let quantity = item.quantity,
                quantity >= 0,
                let repositoryName = item.repositoryName,
                let isPrivate = repositoryVisibility[repositoryName]
            else {
                return nil
            }
            total += quantity
            if isPrivate { eligible += quantity }
        }
        guard total == expectedTotal else { return nil }
        return eligible
    }

    private static func appendLFSUsage(
        _ items: [SummaryItem],
        plan: GitHubPlanAllowance,
        period: BillingPeriod,
        output: inout AllowanceOutput
    ) {
        let storageItems = items.filter(\.isPotentialLFSStorage)
        appendLFSMetric(
            storageItems,
            hasExpectedContract: storageItems.allSatisfy(\.isLFSStorage)
                && storageItems.allSatisfy(\.isGBHours),
            stableKey: "lfs-storage",
            label: "Git LFS storage",
            limit: Decimal(plan.lfsStorageGB) * Decimal(period.hours),
            period: period,
            output: &output
        )
        let bandwidthItems = items.filter(\.isPotentialLFSBandwidth)
        appendLFSMetric(
            bandwidthItems,
            hasExpectedContract: bandwidthItems.allSatisfy(\.isLFSBandwidth)
                && bandwidthItems.allSatisfy(\.isGB),
            stableKey: "lfs-bandwidth",
            label: "Git LFS bandwidth",
            limit: Decimal(plan.lfsBandwidthGB),
            period: period,
            output: &output
        )
    }

    private static func appendLFSMetric(
        _ items: [SummaryItem],
        hasExpectedContract: Bool,
        stableKey: String,
        label: String,
        limit: Decimal,
        period: BillingPeriod,
        output: inout AllowanceOutput
    ) {
        let metricID = "githubBilling.\(stableKey)"
        guard hasExpectedContract else {
            output.unavailable[metricID] = "GitHub returned \(label) in an unsupported unit."
            return
        }
        guard items.allSatisfy(\.hasCompleteAllowanceQuantityEvidence) else {
            output.unavailable[metricID] = "GitHub did not return complete \(label) gross, discount, and billable quantities."
            return
        }
        let used = items.compactMap(\.grossQuantity).reduce(.zero, +)
        let billable = items.compactMap(\.netQuantity).reduce(.zero, +)
        guard allowanceBillingIsConsistent(used: used, limit: limit, billable: billable) else {
            output.unavailable[metricID] = prematureBillingMessage(for: label)
            return
        }
        output.bars.append(allowanceBar(
            stableKey: stableKey,
            label: label,
            used: used,
            limit: limit,
            period: period
        ))
    }

    private static func appendCodespacesUsage(
        _ items: [SummaryItem],
        plan: GitHubPlanAllowance,
        period: BillingPeriod,
        output: inout AllowanceOutput
    ) {
        guard
            let coreHours = plan.codespacesCoreHours,
            let storageGB = plan.codespacesStorageGB
        else {
            return
        }
        appendCodespacesCoreHours(items, limit: coreHours, period: period, output: &output)
        appendCodespacesStorage(items, limitGB: storageGB, period: period, output: &output)
    }

    private static func appendCodespacesCoreHours(
        _ items: [SummaryItem],
        limit: Int,
        period: BillingPeriod,
        output: inout AllowanceOutput
    ) {
        let matching = items.filter(\.isPotentialCodespacesCoreHours)
        guard matching.allSatisfy(\.isCodespacesCoreHours) else {
            output.unavailable["githubBilling.codespaces-core-hours"] = "GitHub returned Codespaces compute in an unsupported SKU or unit."
            return
        }
        guard matching.allSatisfy(\.hasCompleteAllowanceQuantityEvidence) else {
            output.unavailable["githubBilling.codespaces-core-hours"] =
                "GitHub did not return complete Codespaces compute gross, discount, and billable quantities."
            return
        }
        let used = matching.compactMap(\.codespacesCoreHours).reduce(.zero, +)
        let allowanceLimit = Decimal(limit)
        let billable = matching.compactMap(\.codespacesNetCoreHours).reduce(.zero, +)
        guard allowanceBillingIsConsistent(used: used, limit: allowanceLimit, billable: billable) else {
            output.unavailable["githubBilling.codespaces-core-hours"] = prematureBillingMessage(for: "Codespaces compute")
            return
        }
        output.bars.append(allowanceBar(
            stableKey: "codespaces-core-hours",
            label: "Codespaces core hours",
            used: used,
            limit: allowanceLimit,
            period: period
        ))
    }

    private static func appendCodespacesStorage(
        _ items: [SummaryItem],
        limitGB: Int,
        period: BillingPeriod,
        output: inout AllowanceOutput
    ) {
        let matching = items.filter(\.isPotentialCodespacesStorage)
        guard matching.allSatisfy(\.isCodespacesStorage) else {
            output.unavailable["githubBilling.codespaces-storage"] = "GitHub returned Codespaces storage with an unsupported SKU."
            return
        }
        guard matching.allSatisfy(\.hasCompleteAllowanceQuantityEvidence) else {
            output.unavailable["githubBilling.codespaces-storage"] =
                "GitHub did not return complete Codespaces storage gross, discount, and billable quantities."
            return
        }
        let isAccrued = matching.allSatisfy(\.isGBHours)
        let isMonthly = matching.allSatisfy { $0.isGB || $0.isGBMonths }
        guard isAccrued || isMonthly else {
            output.unavailable["githubBilling.codespaces-storage"] = "GitHub returned Codespaces storage in an unsupported unit."
            return
        }
        let monthlyToAccruedMultiplier = isAccrued ? Decimal(1) : Decimal(period.hours)
        let used = matching.compactMap(\.grossQuantity).reduce(.zero, +) * monthlyToAccruedMultiplier
        let allowanceLimit = Decimal(limitGB) * Decimal(period.hours)
        let billable = matching.compactMap(\.netQuantity).reduce(.zero, +) * monthlyToAccruedMultiplier
        guard allowanceBillingIsConsistent(used: used, limit: allowanceLimit, billable: billable) else {
            output.unavailable["githubBilling.codespaces-storage"] = prematureBillingMessage(for: "Codespaces storage")
            return
        }
        output.bars.append(allowanceBar(
            stableKey: "codespaces-storage",
            label: "Codespaces storage",
            used: used,
            limit: allowanceLimit,
            period: period
        ))
    }

    private static func allowanceBillingIsConsistent(
        used: Decimal,
        limit: Decimal,
        billable: Decimal
    ) -> Bool {
        billable <= max(used - limit, .zero)
    }

    private static func prematureBillingMessage(for metric: String) -> String {
        "GitHub reported billable \(metric) before the included allowance was exhausted. Refresh the account; "
            + "if this continues, review GitHub Billing."
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
        productSections: [ProviderCardInformationSection],
        bars: [UsageBar],
        notes: ProviderCardInformationSection?,
        usageDetails: [ProviderCardInformationItem]
    ) -> [ProviderCardInformationSection] {
        var sections = productSections
        if !bars.isEmpty {
            sections.append(allowanceSection(bars))
        }
        if let notes {
            sections.append(notes)
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

    private static func allowanceSections(_ bars: [UsageBar]) -> [ProviderCardInformationSection] {
        bars.isEmpty ? [] : [allowanceSection(bars)]
    }

    private static func allowanceSection(_ bars: [UsageBar]) -> ProviderCardInformationSection {
        ProviderCardInformationSection(
            id: "github-billing.plan-allowances",
            title: "Included plan allowances",
            items: bars.enumerated().map { index, bar in
                let unit = allowanceUnit(for: bar.stableKey)
                let suffix = allowanceRemainingText(bar, unit: unit)
                return ProviderCardInformationItem(
                    id: bar.stableKey ?? "allowance-\(index)",
                    label: bar.label,
                    detail: "\(usageAmount(bar.used)) of \(usageAmount(bar.limit)) \(unit) used · \(suffix)"
                )
            }
        )
    }

    private static func allowanceUnit(for stableKey: String?) -> String {
        switch stableKey {
        case "actions-private-minutes": "minutes"
        case "actions-packages-storage", "packages-storage": "GB"
        case "lfs-storage", "codespaces-storage": "GB-hours"
        case "packages-data-transfer", "lfs-bandwidth": "GB"
        case "codespaces-core-hours": "core hours"
        default: "units"
        }
    }

    private static func allowanceRemainingText(_ bar: UsageBar, unit: String) -> String {
        if bar.used > bar.limit {
            return "\(usageAmount(bar.used - bar.limit)) \(unit) over allowance"
        }
        return "\(usageAmount(bar.limit - bar.used)) \(unit) remaining"
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
                quantity >= 0,
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
        period: BillingPeriod?,
        currencyCode: String?
    ) -> BudgetOutput {
        guard let budgets else { return BudgetOutput() }
        var output = BudgetOutput()
        for budget in budgets {
            let candidate = budgetCandidate(budget, usageItems: usageItems, currencyCode: currencyCode)
            if let unavailableMessage = candidate.unavailableMessage {
                output.messages.append(unavailableMessage)
                if let unavailableSection = candidate.unavailableSection {
                    output.sections.append(unavailableSection)
                }
                continue
            }
            guard let normalized = candidate.normalized else { continue }
            output.bars.append(contentsOf: verifiedBudgetBars(
                for: normalized,
                period: period,
                currencyCode: currencyCode
            ))
            output.sections.append(budgetSection(
                normalized,
                isProduct: candidate.isProduct,
                targetLabel: candidate.targetLabel,
                currencyCode: currencyCode
            ))
        }
        return output
    }

    private static func verifiedBudgetBars(
        for budget: NormalizedBudget,
        period: BillingPeriod?,
        currencyCode: String?
    ) -> [UsageBar] {
        guard currencyCode != nil else { return [] }
        return budgetBars(for: budget, period: period)
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
        usageItems: [UsageItem],
        currencyCode: String?
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
                    scopeDescription: budget.scopeDescription,
                    currencyCode: currencyCode
                )
            )
        }
        guard matching.allSatisfy(\.hasNonnegativeFinancialFields) else {
            return BudgetCandidate(
                unavailableMessage: "GitHub did not return complete nonnegative financial evidence for the "
                    + "\(targetLabel) budget."
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
        scopeDescription: String,
        currencyCode: String?
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
                ProviderCardInformationItem(
                    id: "\(id).amount",
                    label: "Budget",
                    detail: aggregateCurrencyText(amount, currencyCode: currencyCode)
                ),
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
        targetLabel: String,
        currencyCode: String?
    ) -> ProviderCardInformationSection {
        let consumptionDetail = budgetConsumptionDetail(budget, currencyCode: currencyCode)
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
                    detail: aggregateCurrencyText(budget.consumed, currencyCode: currencyCode)
                ),
                ProviderCardInformationItem(
                    id: "\(budget.id).remaining",
                    label: "Remaining headroom",
                    detail: consumptionDetail
                ),
            ]
        )
    }

    private static func budgetConsumptionDetail(
        _ budget: NormalizedBudget,
        currencyCode: String?
    ) -> String {
        guard let currencyCode else { return unavailableAmountText }
        let remaining = max(budget.amount - budget.consumed, 0)
        if budget.amount > 0 {
            return "\(aggregateCurrencyText(remaining, currencyCode: currencyCode)) · "
                + "\(decimalText(budget.consumed / budget.amount * 100))% consumed"
        }
        return "\(aggregateCurrencyText(remaining, currencyCode: currencyCode)) · Zero-dollar budget"
    }

    private static func spendStatusMessages(for totals: SpendTotals?) -> [String] {
        totals == nil
            ? ["GitHub did not return complete gross, discount, and net amounts for this billing period."]
            : []
    }

    /// Groups summary rows into one concise section per GitHub product. Known
    /// products come first in a stable order; anything else keeps GitHub's own
    /// product name so returned data is never discarded.
    private static func productSummarySections(
        _ items: [SummaryItem],
        currencyCode: String?,
        includesPlanAllowances: Bool,
        bars: [UsageBar],
        unavailable: [String: String]
    ) -> [ProviderCardInformationSection] {
        var groups: [String: ProductUsageGroup] = [:]
        for item in items {
            let rawProduct = item.product?.nonempty
            let key = canonicalProductKey(for: rawProduct)
            let displayName = canonicalProductName(for: rawProduct)
            groups[key, default: ProductUsageGroup(displayName: displayName, items: [])]
                .items.append(item)
        }
        return groups
            .map { (key: $0.key, name: $0.value.displayName) }
            .sorted {
                productGroupOrder(key: $0.key, name: $0.name, key: $1.key, name: $1.name)
            }
            .compactMap { key in
                guard let group = groups[key.key] else { return nil }
                return productSection(
                    key: key.key,
                    displayName: group.displayName,
                    items: group.items,
                    currencyCode: currencyCode,
                    includesPlanAllowances: includesPlanAllowances,
                    bars: bars,
                    unavailable: unavailable
                )
            }
    }

    /// Known products come first in a stable order; anything else keeps GitHub's
    /// own product name so returned data is never discarded.
    private static let knownProductOrder: [String] = ["copilot", "actions", "codespaces", "packages", "git-lfs"]

    private static func productGroupOrder(
        key lhsKey: String,
        name lhsName: String,
        key rhsKey: String,
        name rhsName: String
    ) -> Bool {
        let lhsRank = knownProductOrder.firstIndex(of: lhsKey) ?? knownProductOrder.count
        let rhsRank = knownProductOrder.firstIndex(of: rhsKey) ?? knownProductOrder.count
        if lhsRank != rhsRank {
            return lhsRank < rhsRank
        }
        if lhsName.caseInsensitiveCompare(rhsName) == .orderedSame {
            return lhsKey < rhsKey
        }
        return lhsName.caseInsensitiveCompare(rhsName) == .orderedAscending
    }

    private static func canonicalProductKey(for rawProduct: String?) -> String {
        guard let rawProduct = rawProduct?.nonempty else { return "unlisted-products" }
        let key = stableKey(rawProduct)
        return knownProductAliases[key] ?? key
    }

    private static func canonicalProductName(for rawProduct: String?) -> String {
        guard let rawProduct = rawProduct?.nonempty else {
            return "Unlisted products"
        }
        return knownProductNames[stableKey(rawProduct)] ?? rawProduct
    }

    private static let knownProductAliases = ["lfs": "git-lfs"]

    private static let knownProductNames: [String: String] = [
        "copilot": "Copilot",
        "actions": "Actions",
        "codespaces": "Codespaces",
        "git-lfs": "Git LFS",
        "lfs": "Git LFS",
    ]

    private static func productSection(
        key: String,
        displayName: String,
        items: [SummaryItem],
        currencyCode: String?,
        includesPlanAllowances: Bool,
        bars: [UsageBar],
        unavailable: [String: String]
    ) -> ProviderCardInformationSection {
        var rows = [
            consumedUsageRow(items, key: key, currencyCode: currencyCode),
            amountAndQuantityUsageRow(
                id: "\(key).discount",
                label: "Discount usage",
                amounts: items.map(\.discountAmount),
                items: items,
                quantityKeyPath: \.discountQuantity,
                currencyCode: currencyCode
            ),
            amountAndQuantityUsageRow(
                id: "\(key).billable",
                label: "Billable usage",
                amounts: items.map(\.netAmount),
                items: items,
                quantityKeyPath: \.netQuantity,
                currencyCode: currencyCode
            ),
        ]
        if includesPlanAllowances {
            rows.append(contentsOf: includedUsageRows(
                productKey: key,
                bars: bars,
                unavailable: unavailable
            ))
        }
        return ProviderCardInformationSection(
            id: "github-billing.product.\(key)",
            title: displayName,
            items: rows
        )
    }

    private static func consumedUsageRow(
        _ items: [SummaryItem],
        key: String,
        currencyCode: String?
    ) -> ProviderCardInformationItem {
        let amounts = items.map(\.grossAmount)
        var detail = amountUsageRow(
            id: "\(key).consumed",
            label: "Consumed usage",
            amounts: amounts,
            currencyCode: currencyCode
        ).detail
        detail += " · \(quantitySummary(items, keyPath: \.grossQuantity))"
        return ProviderCardInformationItem(id: "\(key).consumed", label: "Consumed usage", detail: detail)
    }

    private static func amountAndQuantityUsageRow(
        id: String,
        label: String,
        amounts: [Decimal?],
        items: [SummaryItem],
        quantityKeyPath: KeyPath<SummaryItem, Decimal?>,
        currencyCode: String?
    ) -> ProviderCardInformationItem {
        let amount = amountUsageRow(
            id: id,
            label: label,
            amounts: amounts,
            currencyCode: currencyCode
        ).detail
        return ProviderCardInformationItem(
            id: id,
            label: label,
            detail: "\(amount) · \(quantitySummary(items, keyPath: quantityKeyPath))"
        )
    }

    private static func amountUsageRow(
        id: String,
        label: String,
        amounts: [Decimal?],
        currencyCode: String?
    ) -> ProviderCardInformationItem {
        let detail: String
        if let currencyCode, amounts.allSatisfy({ $0.map { $0 >= 0 } == true }) {
            detail = aggregateCurrencyText(amounts.compactMap { $0 }.reduce(.zero, +), currencyCode: currencyCode)
        } else {
            detail = unavailableAmountText
        }
        return ProviderCardInformationItem(id: id, label: label, detail: detail)
    }

    private static func quantitySummary(
        _ items: [SummaryItem],
        keyPath: KeyPath<SummaryItem, Decimal?>
    ) -> String {
        var totalsByUnit: [String: (unit: String, quantity: Decimal)] = [:]
        for item in items {
            guard let quantity = item[keyPath: keyPath], quantity >= 0, let unit = item.unitType?.nonempty else {
                return "Quantity unavailable"
            }
            let unitKey = stableKey(unit)
            totalsByUnit[unitKey, default: (unit, .zero)].quantity += quantity
        }
        guard !totalsByUnit.isEmpty else { return "Quantity unavailable" }
        return totalsByUnit.values
            .sorted { $0.unit.caseInsensitiveCompare($1.unit) == .orderedAscending }
            .map { "\(usageAmount($0.quantity.doubleValue)) \($0.unit)" }
            .joined(separator: " · ")
    }

    private static let includedUsageDefinitions: [String: [IncludedUsageDefinition]] = [
        "actions": [
            IncludedUsageDefinition(
                id: "actions.included.minutes",
                label: "Included usage · Minutes",
                stableKey: "actions-private-minutes",
                unit: "minutes",
                scopeNote: "private standard runners"
            ),
            IncludedUsageDefinition(
                id: "actions.included.storage",
                label: "Included usage · Storage",
                stableKey: "actions-packages-storage",
                unit: "GB",
                scopeNote: "private Actions storage"
            ),
        ],
        "packages": [
            IncludedUsageDefinition(
                id: "packages.included.storage",
                label: "Included usage · Storage",
                stableKey: "packages-storage",
                unit: "GB",
                scopeNote: "private Packages storage"
            ),
            IncludedUsageDefinition(
                id: "packages.included.transfer",
                label: "Included usage · Data transfer",
                stableKey: "packages-data-transfer",
                unit: "GB"
            ),
        ],
        "codespaces": [
            IncludedUsageDefinition(
                id: "codespaces.included.core-hours",
                label: "Included usage · Core hours",
                stableKey: "codespaces-core-hours",
                unit: "core hours"
            ),
            IncludedUsageDefinition(
                id: "codespaces.included.storage",
                label: "Included usage · Storage",
                stableKey: "codespaces-storage",
                unit: "GB-hours"
            ),
        ],
        "git-lfs": [
            IncludedUsageDefinition(
                id: "git-lfs.included.storage",
                label: "Included usage · Storage",
                stableKey: "lfs-storage",
                unit: "GB-hours"
            ),
            IncludedUsageDefinition(
                id: "git-lfs.included.bandwidth",
                label: "Included usage · Bandwidth",
                stableKey: "lfs-bandwidth",
                unit: "GB"
            ),
        ],
    ]

    private static func includedUsageRows(
        productKey: String,
        bars: [UsageBar],
        unavailable: [String: String]
    ) -> [ProviderCardInformationItem] {
        let definitions = includedUsageDefinitions[productKey] ?? []
        return definitions
            .filter { hasAllowanceMetric($0.stableKey, bars: bars, unavailable: unavailable) }
            .map { definition in
                includedUsageRow(
                    id: definition.id,
                    label: definition.label,
                    stableKey: definition.stableKey,
                    unit: definition.unit,
                    scopeNote: definition.scopeNote,
                    bars: bars,
                    unavailable: unavailable
                )
            }
    }

    private static func hasAllowanceMetric(
        _ stableKey: String,
        bars: [UsageBar],
        unavailable: [String: String]
    ) -> Bool {
        bars.contains { $0.stableKey == stableKey }
            || unavailable["githubBilling.\(stableKey)"] != nil
    }

    private static func includedUsageRow(
        id: String,
        label: String,
        stableKey: String,
        unit: String,
        scopeNote: String?,
        bars: [UsageBar],
        unavailable: [String: String]
    ) -> ProviderCardInformationItem {
        includedUsageRow(
            id: id,
            label: label,
            bar: bars.first { $0.stableKey == stableKey },
            unit: unit,
            scopeNote: scopeNote,
            reason: unavailable["githubBilling.\(stableKey)"]
        )
    }

    private static func includedUsageRow(
        id: String,
        label: String,
        bar: UsageBar?,
        unit: String,
        scopeNote: String?,
        reason: String?
    ) -> ProviderCardInformationItem {
        let detail: String
        if let bar {
            let scope = scopeNote.map { " (\($0))" } ?? ""
            detail = "\(usageAmount(bar.used)) of \(usageAmount(bar.limit)) \(unit) used\(scope) · "
                + allowanceRemainingText(bar, unit: unit)
        } else {
            detail = reason ?? unavailableAmountText
        }
        return ProviderCardInformationItem(id: id, label: label, detail: detail)
    }

    /// Routine qualifications and currency disclosure live behind
    /// "More Information…" so healthy cards keep only actionable messages.
    private static func amountsAndCurrencySection(
        currency: GitHubBillingCurrency,
        includesPersonalBudgetNotes: Bool,
        plan: GitHubPlanAllowance?,
        budgetQualification: String?,
        omittedDetailCount: Int
    ) -> ProviderCardInformationSection? {
        var items: [ProviderCardInformationItem] = []
        items.append(contentsOf: currencyNoteItems(currency: currency))
        if includesPersonalBudgetNotes {
            items.append(contentsOf: personalBudgetNotes())
        }
        if plan != nil {
            items.append(ProviderCardInformationItem(
                id: "github-billing.actions-classification",
                label: "Actions plan allowance",
                detail: "Private standard-runner usage is normalized to GitHub's Linux allowance-minute rate. "
                    + "Public and unverified runner usage is not counted."
            ))
        }
        if let budgetQualification {
            items.append(ProviderCardInformationItem(
                id: "github-billing.budget-qualification",
                label: "Organization budgets",
                detail: budgetQualification
            ))
        }
        if omittedDetailCount > 0 {
            items.append(ProviderCardInformationItem(
                id: "github-billing.omitted-details",
                label: "Detail rows",
                detail: "\(omittedDetailCount) additional repository, product, and SKU detail rows were omitted to keep the card readable."
            ))
        }
        return ProviderCardInformationSection(
            id: "github-billing.amounts-and-currency",
            title: "Amounts and currency",
            items: items
        )
    }

    private static func currencyNoteItems(currency: GitHubBillingCurrency) -> [ProviderCardInformationItem] {
        var items: [ProviderCardInformationItem] = []
        if let conflictMessage = currency.conflictMessage {
            items.append(ProviderCardInformationItem(
                id: "github-billing.currency-conflict",
                label: "Currency evidence",
                detail: conflictMessage
            ))
        }
        let currencyDetail: String
        if currency.conflictMessage != nil {
            currencyDetail = "Unavailable. GitHub returned currency evidence CodexBar could not verify, so monetary "
                + "amounts are unavailable instead of being relabeled or converted."
        } else if currency.isReported {
            currencyDetail = "\(currency.code), as GitHub's billing response reports it. Amounts are not converted to the device locale."
        } else {
            currencyDetail = "USD. GitHub's billing API does not report a currency code, so CodexBar shows the "
                + "USD amounts GitHub lists. Amounts are not converted to the device locale."
        }
        items.append(ProviderCardInformationItem(
            id: "github-billing.currency",
            label: "Currency",
            detail: currencyDetail
        ))
        return items
    }

    private static func personalBudgetNotes() -> [ProviderCardInformationItem] {
        [
            ProviderCardInformationItem(
                id: "github-billing.personal-budgets",
                label: "Personal budgets",
                detail: "GitHub does not expose personal budgets through its public API. "
                    + "Included allowances and current charges are shown separately."
            ),
        ]
    }

    private static func makeSpendMetrics(
        totals: SpendTotals,
        period: BillingPeriod?,
        fetchedAt: Date,
        currencyCode: String
    ) -> [ProviderMonetaryMetric] {
        var metrics = [
            monetaryMetric(kind: .grossSpend, label: "Gross usage", amount: totals.gross, currencyCode: currencyCode),
            monetaryMetric(kind: .discounts, label: "Discounts", amount: totals.discount, currencyCode: currencyCode),
            monetaryMetric(
                kind: .spent,
                label: "Net spend",
                amount: totals.net,
                currencyCode: currencyCode,
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
                    currencyCode: currencyCode,
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
        currencyCode: String,
        detail: String? = nil
    ) -> ProviderMonetaryMetric {
        ProviderMonetaryMetric(
            kind: kind,
            label: label,
            minorUnits: amount * 100,
            currencyCode: currencyCode,
            decimalPlaces: 2,
            detail: detail
        )
    }

    private static func usageDetails(_ items: [UsageItem], currencyCode: String?) -> UsageDetailOutput {
        let details = items.enumerated().compactMap { index, item -> ProviderCardInformationItem? in
            guard let product = item.product?.nonempty, let sku = item.sku?.nonempty else {
                return nil
            }
            let repository = item.repositoryName?.nonempty ?? "Account-wide"
            let quantity = item.quantity.map(decimalText) ?? "Unknown quantity"
            let unit = item.unitType?.nonempty ?? "units"
            let unitPrice = usageUnitPriceText(item.pricePerUnit, currencyCode: currencyCode)
            let unitPriceUnit = singularUnit(unit)
            let gross = usageAggregateText(item.grossAmount, currencyCode: currencyCode, missing: "Unknown gross amount")
            let discount = usageAggregateText(item.discountAmount, currencyCode: currencyCode, missing: "Unknown discount")
            let net = usageAggregateText(item.netAmount, currencyCode: currencyCode, missing: "Unknown net amount")
            return ProviderCardInformationItem(
                id: "usage.\(index).\(stableKey(repository)).\(stableKey(sku))",
                label: repository,
                detail: "\(product) · \(sku) · \(quantity) \(unit) · \(unitPrice)/\(unitPriceUnit) · "
                    + "\(gross) gross · \(discount) discount · \(net) net"
            )
        }
        let omittedCount = max(0, details.count - UsageDetailOutput.maximumCount)
        return UsageDetailOutput(
            items: Array(details.prefix(UsageDetailOutput.maximumCount)),
            omittedCount: omittedCount
        )
    }

    private static func currencyResolution(topLevel: String?, items: [SummaryItem]) -> GitHubBillingCurrency {
        if let topLevel = topLevel?.nonempty {
            let supplied = [topLevel] + items.compactMap(\.currency?.nonempty)
            return verifiedCurrency(from: supplied)
        }
        let monetaryItems = items.filter(\.hasMonetaryEvidence)
        let supplied = monetaryItems.compactMap(\.currency?.nonempty)
        guard !supplied.isEmpty else {
            return GitHubBillingCurrency(code: "USD", isReported: false, conflictMessage: nil)
        }
        guard supplied.count == monetaryItems.count else { return unverifiedCurrency() }
        return verifiedCurrency(from: supplied)
    }

    private static func verifiedCurrency(from supplied: [String]) -> GitHubBillingCurrency {
        let codes = Set(supplied.map { $0.uppercased() })
        guard codes.count == 1, let code = codes.first, isISOCurrencyCode(code) else {
            return unverifiedCurrency()
        }
        return GitHubBillingCurrency(code: code, isReported: true, conflictMessage: nil)
    }

    private static func unverifiedCurrency() -> GitHubBillingCurrency {
        GitHubBillingCurrency(
            code: "USD",
            isReported: false,
            conflictMessage: "GitHub returned currency evidence CodexBar cannot verify, so monetary amounts are unavailable."
        )
    }

    private static func isISOCurrencyCode(_ code: String) -> Bool {
        Locale.Currency.isoCurrencies.contains(Locale.Currency(code))
    }

    private static func decimalText(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private static func usageUnitPriceText(_ value: Decimal?, currencyCode: String?) -> String {
        guard let value else { return "Unknown unit price" }
        guard let currencyCode else { return unavailableAmountText }
        return unitPriceText(value, currencyCode: currencyCode)
    }

    private static func singularUnit(_ unit: String) -> String {
        unit.hasSuffix("s") ? String(unit.dropLast()) : unit
    }

    private static func usageAggregateText(
        _ value: Decimal?,
        currencyCode: String?,
        missing: String
    ) -> String {
        guard let value else { return missing }
        return aggregateCurrencyText(value, currencyCode: currencyCode)
    }

    /// Aggregate monetary amounts always show exactly two fractional digits.
    private static func aggregateCurrencyText(_ value: Decimal, currencyCode: String?) -> String {
        guard let currencyCode else { return unavailableAmountText }
        return value.formatted(
            .currency(code: currencyCode)
                .precision(.fractionLength(2))
        )
    }

    /// Unit prices keep the precision GitHub returned, for example $0.006/minute,
    /// instead of rounding into a different rate.
    private static func unitPriceText(_ value: Decimal, currencyCode: String) -> String {
        let fractionDigits = min(max(sourceFractionDigits(of: value), 2), 12)
        return value.formatted(
            .currency(code: currencyCode)
                .precision(.fractionLength(fractionDigits))
        )
    }

    private static func sourceFractionDigits(of value: Decimal) -> Int {
        let text = NSDecimalNumber(decimal: value).stringValue
        guard let separator = text.firstIndex(of: "."), !text.lowercased().contains("e") else { return 2 }
        return text.distance(from: text.index(after: separator), to: text.endIndex)
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
    let omittedCount: Int
}

private struct ProductUsageGroup {
    let displayName: String
    var items: [SummaryItem]
}

private struct OrganizationUsageBucket {
    let product: String
    let sku: String
    let unit: String
    var quantity: Decimal
}

/// The currency every GitHub Billing amount renders with. GitHub's documented
/// billing usage response has no currency field, so CodexBar treats USD as the
/// documented billing currency; a consistently supplied code wins instead.
private struct GitHubBillingCurrency {
    let code: String
    let isReported: Bool
    let conflictMessage: String?

    var verifiedCode: String? {
        conflictMessage == nil ? code : nil
    }
}

private struct SummaryResponse: Decodable {
    let timePeriod: TimePeriod?
    let user: String?
    let organization: String?
    let currency: String?
    let usageItems: [SummaryItem]

    enum CodingKeys: String, CodingKey {
        case timePeriod
        case user
        case organization
        case currency
        case usageItems
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timePeriod = try container.decodeIfPresent(TimePeriod.self, forKey: .timePeriod)
        user = try container.decodeIfPresent(String.self, forKey: .user)?.nonempty
        organization = try container.decodeIfPresent(String.self, forKey: .organization)?.nonempty
        currency = try container.decodeIfPresent(String.self, forKey: .currency)?.nonempty
        usageItems = try container.decode([SummaryItem].self, forKey: .usageItems)
    }
}

private struct TimePeriod: Decodable {
    let year: Int?
    let month: Int?
}

private struct MeteredQuantityKey: Hashable {
    let sku: String
    let unit: String
    let unitPrice: Decimal
}

private protocol MeteredQuantityItem {
    var sku: String? { get }
    var unitType: String? { get }
    var allowanceQuantity: Decimal? { get }
    var pricePerUnit: Decimal? { get }
}

private struct SummaryItem: Decodable, MeteredQuantityItem {
    let product: String?
    let sku: String?
    let unitType: String?
    let pricePerUnit: Decimal?
    let grossQuantity: Decimal?
    let grossAmount: Decimal?
    let discountQuantity: Decimal?
    let discountAmount: Decimal?
    let netQuantity: Decimal?
    let netAmount: Decimal?
    let currency: String?

    var allowanceQuantity: Decimal? { grossQuantity }

    var hasCompleteAllowanceQuantityEvidence: Bool {
        guard
            let grossQuantity,
            grossQuantity >= 0,
            let discountQuantity,
            discountQuantity >= 0,
            let netQuantity,
            netQuantity >= 0
        else {
            return false
        }
        return discountQuantity + netQuantity == grossQuantity
    }

    var hasMonetaryEvidence: Bool {
        [pricePerUnit, grossAmount, discountAmount, netAmount].contains { $0 != nil }
    }

    var isPotentialActionsMinutes: Bool {
        let normalizedProduct = product?.normalized ?? ""
        let normalizedSKU = sku?.normalized ?? ""
        guard !normalizedSKU.contains("storage"), !normalizedSKU.contains("cache") else { return false }
        if normalizedSKU.hasPrefix("actions") { return true }
        return normalizedProduct.contains("actions")
            && unitType?.normalized.contains("minute") == true
    }

    var actionsRunnerAllowance: ActionsRunnerAllowance {
        GitHubActionsRunnerCatalog.allowance(for: sku)
    }

    var isActionsStorage: Bool {
        product?.normalized == "actions" && sku?.normalized == "actionsstorage"
    }

    var isPotentialActionsStorage: Bool {
        guard product?.normalized == "actions" else { return false }
        let normalizedSKU = sku?.normalized ?? ""
        guard !normalizedSKU.contains("cache"), !normalizedSKU.contains("customimage") else { return false }
        return isGBHours || normalizedSKU.contains("storage")
    }

    var isPackagesStorage: Bool {
        product?.normalized == "packages" && sku?.normalized == "packagesstorage"
    }

    var isPotentialPackagesStorage: Bool {
        guard product?.normalized == "packages" else { return false }
        let normalizedSKU = sku?.normalized ?? ""
        guard !normalizedSKU.contains("transfer"), !normalizedSKU.contains("bandwidth") else { return false }
        return isGBHours || normalizedSKU.contains("storage")
    }

    var isPackagesDataTransfer: Bool {
        let normalizedSKU = sku?.normalized ?? ""
        return product?.normalized == "packages"
            && (normalizedSKU.contains("transfer") || normalizedSKU == "packagesbandwidth")
    }

    var isPotentialPackagesDataTransfer: Bool {
        guard product?.normalized == "packages" else { return false }
        let normalizedSKU = sku?.normalized ?? ""
        return normalizedSKU.contains("transfer") || normalizedSKU == "packagesbandwidth" || isGB
    }

    var isCodespacesCoreHours: Bool {
        product?.normalized == "codespaces"
            && codespacesCoreMultiplier != nil
            && isHours
    }

    var codespacesCoreHours: Decimal? {
        guard
            isCodespacesCoreHours,
            let grossQuantity,
            let codespacesCoreMultiplier
        else {
            return nil
        }
        return grossQuantity * Decimal(codespacesCoreMultiplier)
    }

    var codespacesNetCoreHours: Decimal? {
        guard
            isCodespacesCoreHours,
            let netQuantity,
            let codespacesCoreMultiplier
        else {
            return nil
        }
        return netQuantity * Decimal(codespacesCoreMultiplier)
    }

    var isPotentialCodespacesCoreHours: Bool {
        guard product?.normalized == "codespaces" else { return false }
        return sku?.normalized.contains("compute") == true || isHours
    }

    private var codespacesCoreMultiplier: Int? {
        switch sku?.normalized {
        case "codespacescomputed2": 2
        case "codespacescomputed4": 4
        case "codespacescomputed8": 8
        case "codespacescomputed16": 16
        case "codespacescomputed32": 32
        default: nil
        }
    }

    private var isHours: Bool {
        let unit = unitType?.normalized ?? ""
        return unit == "hour" || unit == "hours" || unit == "machinehours"
    }

    var isCodespacesStorage: Bool {
        product?.normalized == "codespaces"
            && sku?.normalized.contains("storage") == true
    }

    var isPotentialCodespacesStorage: Bool {
        guard product?.normalized == "codespaces" else { return false }
        return sku?.normalized.contains("storage") == true || isGBHours || isGBMonths
    }

    var isLFSStorage: Bool {
        isLFS && (sku?.normalized.contains("storage") == true)
    }

    var isLFSBandwidth: Bool {
        isLFS && (sku?.normalized.contains("bandwidth") == true)
    }

    var isPotentialLFSStorage: Bool {
        let normalizedSKU = sku?.normalized ?? ""
        guard isLFS || normalizedSKU.contains("lfs") else { return false }
        if normalizedSKU.contains("bandwidth") { return false }
        return normalizedSKU.contains("storage") || isGBHours
    }

    var isPotentialLFSBandwidth: Bool {
        let normalizedSKU = sku?.normalized ?? ""
        guard isLFS || normalizedSKU.contains("lfs") else { return false }
        if normalizedSKU.contains("storage") { return false }
        return normalizedSKU.contains("bandwidth") || isGB
    }

    var isLFS: Bool {
        let product = product?.normalized ?? ""
        return product.contains("gitlfs") || product == "lfs"
    }

    var isGBHours: Bool {
        let unit = unitType?.normalized ?? ""
        return unit.contains("gbhour") || unit.contains("gibhour") || unit.contains("gigabytehour")
    }

    var isGB: Bool {
        let unit = unitType?.normalized ?? ""
        return unit == "gb" || unit == "gib" || unit == "gigabytes"
    }

    var isGBMonths: Bool {
        let unit = unitType?.normalized ?? ""
        return unit.contains("gbmonth") || unit.contains("gibmonth")
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

private struct UsageItem: Decodable, MeteredQuantityItem {
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

    var allowanceQuantity: Decimal? { quantity }

    var hasNonnegativeFinancialFields: Bool {
        pricePerUnit.map { $0 >= 0 } == true
            && grossAmount.map { $0 >= 0 } == true
            && discountAmount.map { $0 >= 0 } == true
            && netAmount.map { $0 >= 0 } == true
    }

    func belongsToOrganization(_ owner: String) -> Bool {
        organizationName?.caseInsensitiveCompare(owner) == .orderedSame
    }

    var isActionsStorage: Bool {
        product?.normalized == "actions" && sku?.normalized == "actionsstorage"
    }

    var isPotentialActionsStorage: Bool {
        guard product?.normalized == "actions" else { return false }
        let normalizedSKU = sku?.normalized ?? ""
        guard !normalizedSKU.contains("cache"), !normalizedSKU.contains("customimage") else { return false }
        return isGBHours || normalizedSKU.contains("storage")
    }

    var isPackagesDataTransfer: Bool {
        let normalizedSKU = sku?.normalized ?? ""
        return product?.normalized == "packages"
            && (normalizedSKU.contains("transfer") || normalizedSKU == "packagesbandwidth")
    }

    var isPotentialPackagesDataTransfer: Bool {
        guard product?.normalized == "packages" else { return false }
        let normalizedSKU = sku?.normalized ?? ""
        let unit = unitType?.normalized
        return normalizedSKU.contains("transfer") || normalizedSKU == "packagesbandwidth"
            || unit == "gb" || unit == "gib" || unit == "gigabytes"
    }

    var isGBHours: Bool {
        let unit = unitType?.normalized ?? ""
        return unit.contains("gbhour") || unit.contains("gibhour") || unit.contains("gigabytehour")
    }

    var isGB: Bool {
        let unit = unitType?.normalized ?? ""
        return unit == "gb" || unit == "gib" || unit == "gigabytes"
    }

    var isActionsMinutes: Bool {
        product?.normalized.contains("actions") == true
            && unitType?.normalized.contains("minute") == true
    }

    var isPotentialActionsMinutes: Bool {
        let normalizedProduct = product?.normalized ?? ""
        let normalizedSKU = sku?.normalized ?? ""
        guard !normalizedSKU.contains("storage"), !normalizedSKU.contains("cache") else { return false }
        if normalizedSKU.hasPrefix("actions") { return true }
        return normalizedProduct.contains("actions")
            && unitType?.normalized.contains("minute") == true
    }

    var actionsRunnerAllowance: ActionsRunnerAllowance {
        GitHubActionsRunnerCatalog.allowance(for: sku)
    }

    var expectedStandardRunnerRate: Decimal? {
        GitHubActionsRunnerCatalog.standardRate(for: sku)
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

    init?(timePeriod: TimePeriod?, containing fetchedAt: Date) {
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
            let end = calendar.date(byAdding: .month, value: 1, to: start),
            fetchedAt >= start,
            fetchedAt < end
        else {
            return nil
        }
        self.start = start
        self.end = end
        self.hours = Int(end.timeIntervalSince(start) / 3_600)
    }
}

private enum GitHubAllowanceScope {
    case personal
    case organization
}

private enum ActionsRunnerAllowance {
    case includedStandard
    case excludedPaidLarger
    case excludedSelfHosted
    case unknown
}

private enum GitHubActionsRunnerCatalog {
    static func allowance(for sku: String?) -> ActionsRunnerAllowance {
        let normalizedSKU = sku?.normalized ?? ""
        if standardRates[normalizedSKU] != nil { return .includedStandard }
        if paidLargerSKUs.contains(normalizedSKU) { return .excludedPaidLarger }
        if normalizedSKU.contains("selfhosted") { return .excludedSelfHosted }
        return .unknown
    }

    static func standardRate(for sku: String?) -> Decimal? {
        standardRates[sku?.normalized ?? ""]
    }

    static func allowanceMinutes(quantity: Decimal, unitPrice: Decimal) -> Decimal {
        quantity * unitPrice / allowanceMinuteRate
    }

    private static let allowanceMinuteRate = Decimal(6) / 1_000

    private static let standardRates: [String: Decimal] = [
        "actionslinuxslim": Decimal(2) / 1_000,
        "actionslinux": Decimal(6) / 1_000,
        "actionslinuxarm": Decimal(5) / 1_000,
        "actionswindows": Decimal(1) / 100,
        "actionswindowsarm": Decimal(1) / 100,
        "actionsmacos": Decimal(62) / 1_000,
    ]

    // https://docs.github.com/en/billing/reference/product-and-sku-names#github-actions
    private static let paidLargerSKUs = Set([
        "actionslinux2coreadvanced", "actionslinux2corearm",
        "actionslinux4core", "actionslinux4corearm", "actionslinux4coregpu",
        "actionslinux8core", "actionslinux8corearm",
        "actionslinux16core", "actionslinux16corearm",
        "actionslinux32core", "actionslinux32corearm",
        "actionslinux64core", "actionslinux64corearm",
        "actionslinux96core", "actionsmacosl", "actionsmacosxl",
        "actionswindows2core", "actionswindows2coreadvanced", "actionswindows2corearm",
        "actionswindows4core", "actionswindows4corearm", "actionswindows4coregpu",
        "actionswindows8core", "actionswindows8corearm",
        "actionswindows16core", "actionswindows16corearm",
        "actionswindows32core", "actionswindows32corearm",
        "actionswindows64core", "actionswindows64corearm", "actionswindows96core",
    ])
}

private enum ActionsMinuteContribution {
    case included(Decimal)
    case excluded
    case unavailable(String)
}

private struct ActionsMinutesTotal {
    let used: Decimal?
    let unavailableMessage: String?

    init(used: Decimal? = nil, unavailableMessage: String? = nil) {
        self.used = used
        self.unavailableMessage = unavailableMessage
    }
}

// https://docs.github.com/en/billing/reference/product-usage-included
private struct GitHubPlanAllowance {
    let id: String
    let label: String
    let actionsMinutes: Int
    let actionsStorageGB: Decimal
    let packagesStorageGB: Decimal
    let packagesTransferGB: Int
    let lfsStorageGB: Int
    let lfsBandwidthGB: Int
    let codespacesCoreHours: Int?
    let codespacesStorageGB: Int?

    private init(
        id: String,
        label: String,
        actionsMinutes: Int,
        actionsStorageGB: Decimal,
        packagesStorageGB: Decimal,
        packagesTransferGB: Int,
        lfsStorageGB: Int,
        lfsBandwidthGB: Int,
        codespacesCoreHours: Int?,
        codespacesStorageGB: Int?
    ) {
        self.id = id
        self.label = label
        self.actionsMinutes = actionsMinutes
        self.actionsStorageGB = actionsStorageGB
        self.packagesStorageGB = packagesStorageGB
        self.packagesTransferGB = packagesTransferGB
        self.lfsStorageGB = lfsStorageGB
        self.lfsBandwidthGB = lfsBandwidthGB
        self.codespacesCoreHours = codespacesCoreHours
        self.codespacesStorageGB = codespacesStorageGB
    }

    init?(name: String, scope: GitHubAllowanceScope) {
        switch (scope, name.normalized) {
        case (.personal, "free"):
            self.init(
                id: "free", label: "Free", actionsMinutes: 2_000, actionsStorageGB: Decimal(5) / 10,
                packagesStorageGB: Decimal(5) / 10, packagesTransferGB: 1, lfsStorageGB: 10, lfsBandwidthGB: 10,
                codespacesCoreHours: 120, codespacesStorageGB: 15
            )
        case (.personal, "pro"):
            self.init(
                id: "pro", label: "Pro", actionsMinutes: 3_000, actionsStorageGB: 2,
                packagesStorageGB: 2, packagesTransferGB: 10, lfsStorageGB: 10, lfsBandwidthGB: 10,
                codespacesCoreHours: 180, codespacesStorageGB: 20
            )
        case (.organization, "free"):
            self.init(
                id: "free", label: "Free", actionsMinutes: 2_000, actionsStorageGB: Decimal(5) / 10,
                packagesStorageGB: Decimal(5) / 10, packagesTransferGB: 1, lfsStorageGB: 10, lfsBandwidthGB: 10,
                codespacesCoreHours: nil, codespacesStorageGB: nil
            )
        case (.organization, "team"):
            self.init(
                id: "team", label: "Team", actionsMinutes: 3_000, actionsStorageGB: 2,
                packagesStorageGB: 2, packagesTransferGB: 10, lfsStorageGB: 250, lfsBandwidthGB: 250,
                codespacesCoreHours: nil, codespacesStorageGB: nil
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

private struct IncludedUsageDefinition {
    let id: String
    let label: String
    let stableKey: String
    let unit: String
    let scopeNote: String?

    init(
        id: String,
        label: String,
        stableKey: String,
        unit: String,
        scopeNote: String? = nil
    ) {
        self.id = id
        self.label = label
        self.stableKey = stableKey
        self.unit = unit
        self.scopeNote = scopeNote
    }
}

private struct AllowanceOutput {
    var bars: [UsageBar]
    var unavailable: [String: String]

    init(
        bars: [UsageBar] = [],
        unavailable: [String: String] = [:]
    ) {
        self.bars = bars
        self.unavailable = unavailable
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
