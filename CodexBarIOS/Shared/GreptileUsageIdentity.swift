enum GreptileUsageIdentity {
    static let creditAllowanceStableKey = "credit-allowance"
    static let creditAllowanceMetricID = "greptile.\(creditAllowanceStableKey)"
    static let completedReviewsStableKey = "completed-reviews"
    static let completedReviewsMetricID = "greptile.\(completedReviewsStableKey)"
    static let completedReviewsHistorySeriesID = "usage.\(completedReviewsStableKey)"
    static let reviewQuotaStableKey = "review-quota"
    static let reviewQuotaMetricID = "greptile.\(reviewQuotaStableKey)"
    static let reviewQuotaHistorySeriesID = "usage.\(reviewQuotaStableKey)"
    static let canonicalReviewUsageMetricID = "greptile.review-usage"

    static func label(forMetricID id: String) -> String? {
        switch id {
        case creditAllowanceMetricID: "Credits used"
        case completedReviewsMetricID: "Completed reviews"
        case reviewQuotaMetricID: "Reviews used"
        default: nil
        }
    }

    static func historySeriesID(forStableKey key: String) -> String? {
        switch key {
        case creditAllowanceStableKey, completedReviewsStableKey, reviewQuotaStableKey: "usage.\(key)"
        default: nil
        }
    }
}
