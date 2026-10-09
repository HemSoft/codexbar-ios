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
}
