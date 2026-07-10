import Foundation

enum AppReviewLinks {
    static let writeReviewURL = URL(
        string: "https://apps.apple.com/us/app/codexbar-usage-monitor/id6787769891?action=write-review"
    )!
    static let supportURL = URL(string: "https://github.com/HemSoft/codexbar-ios/blob/main/SUPPORT.md")!
}

enum AppReviewPromptEligibility {
    static func hasSuccessfulUsage(
        lastRefreshError: String?,
        results: [ProviderUsageResult]
    ) -> Bool {
        lastRefreshError == nil && results.contains {
            !$0.bars.isEmpty || $0.creditsRemaining != nil
        }
    }
}

struct AppReviewPromptPolicy {
    static let defaultMinimumSuccessfulRefreshes = 5
    static let defaultMinimumEngagementDuration: TimeInterval = 7 * 24 * 60 * 60
    static let defaultMinimumPromptInterval: TimeInterval = 120 * 24 * 60 * 60

    private let defaults: UserDefaults
    private let appVersion: String
    private let minimumSuccessfulRefreshes: Int
    private let minimumEngagementDuration: TimeInterval
    private let minimumPromptInterval: TimeInterval

    init(
        defaults: UserDefaults = .standard,
        appVersion: String = AppReviewPromptPolicy.runningAppVersion,
        minimumSuccessfulRefreshes: Int = AppReviewPromptPolicy.defaultMinimumSuccessfulRefreshes,
        minimumEngagementDuration: TimeInterval = AppReviewPromptPolicy.defaultMinimumEngagementDuration,
        minimumPromptInterval: TimeInterval = AppReviewPromptPolicy.defaultMinimumPromptInterval
    ) {
        self.defaults = defaults
        self.appVersion = appVersion
        self.minimumSuccessfulRefreshes = max(1, minimumSuccessfulRefreshes)
        self.minimumEngagementDuration = max(0, minimumEngagementDuration)
        self.minimumPromptInterval = max(0, minimumPromptInterval)
    }

    @discardableResult
    func registerSuccessfulRefresh(at now: Date = Date()) -> Bool {
        let previousCount = defaults.integer(forKey: DefaultsKey.successfulRefreshCount)
        let firstSuccessDate = defaults.object(forKey: DefaultsKey.firstSuccessDate) as? Date ?? now
        let successCount = min(previousCount + 1, minimumSuccessfulRefreshes)

        if previousCount == 0 {
            defaults.set(firstSuccessDate, forKey: DefaultsKey.firstSuccessDate)
        }
        defaults.set(successCount, forKey: DefaultsKey.successfulRefreshCount)

        guard successCount >= minimumSuccessfulRefreshes else {
            return false
        }
        guard now.timeIntervalSince(firstSuccessDate) >= minimumEngagementDuration else {
            return false
        }
        guard defaults.string(forKey: DefaultsKey.lastRequestedVersion) != appVersion else {
            return false
        }
        if let lastRequestDate = defaults.object(forKey: DefaultsKey.lastRequestDate) as? Date {
            guard now.timeIntervalSince(lastRequestDate) >= minimumPromptInterval else {
                return false
            }
        }

        defaults.set(now, forKey: DefaultsKey.lastRequestDate)
        defaults.set(appVersion, forKey: DefaultsKey.lastRequestedVersion)
        defaults.set(0, forKey: DefaultsKey.successfulRefreshCount)
        defaults.removeObject(forKey: DefaultsKey.firstSuccessDate)
        return true
    }

    private static var runningAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private enum DefaultsKey {
        static let successfulRefreshCount = "appReview.successfulRefreshCount"
        static let firstSuccessDate = "appReview.firstSuccessDate"
        static let lastRequestDate = "appReview.lastRequestDate"
        static let lastRequestedVersion = "appReview.lastRequestedVersion"
    }
}
