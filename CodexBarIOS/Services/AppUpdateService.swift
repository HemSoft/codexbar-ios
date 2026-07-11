import Foundation

struct InstalledAppVersion: Equatable, Sendable {
    let marketingVersion: String
    let buildNumber: String

    var displayText: String {
        "Version \(marketingVersion) (\(buildNumber))"
    }

    static func current(bundle: Bundle = .main) -> InstalledAppVersion {
        InstalledAppVersion(
            marketingVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? "Unknown",
            buildNumber: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
                ?? "Unknown"
        )
    }
}

struct AppVersion: Comparable, Sendable {
    private let components: [Int]

    init?(_ rawValue: String) {
        let parts = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
        guard
            !parts.isEmpty,
            parts.allSatisfy({ !$0.isEmpty }),
            parts.allSatisfy({ Int($0).map { $0 >= 0 } == true })
        else {
            return nil
        }

        components = parts.compactMap { Int($0) }
    }

    static func == (lhs: AppVersion, rhs: AppVersion) -> Bool {
        compare(lhs.components, rhs.components) == .orderedSame
    }

    static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        compare(lhs.components, rhs.components) == .orderedAscending
    }

    private static func compare(_ lhs: [Int], _ rhs: [Int]) -> ComparisonResult {
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left < right {
                return .orderedAscending
            }
            if left > right {
                return .orderedDescending
            }
        }
        return .orderedSame
    }
}

struct AppStoreRelease: Codable, Equatable, Sendable {
    let version: String
    let productURL: URL
}

protocol AppStoreReleaseFetching: Sendable {
    func fetchRelease() async throws -> AppStoreRelease
}

enum AppStoreReleaseError: Error, Equatable, Sendable {
    case invalidResponse
    case httpStatus(Int)
    case missingRelease
}

struct AppStoreReleaseService: AppStoreReleaseFetching {
    static let lookupURL = URL(string: "https://itunes.apple.com/lookup?id=6787769891")!
    static let fallbackProductURL = URL(
        string: "https://apps.apple.com/us/app/codexbar-usage-monitor/id6787769891"
    )!

    private let session: URLSession
    private let lookupURL: URL
    private let fallbackProductURL: URL

    init(
        session: URLSession = .shared,
        lookupURL: URL = AppStoreReleaseService.lookupURL,
        fallbackProductURL: URL = AppStoreReleaseService.fallbackProductURL
    ) {
        self.session = session
        self.lookupURL = lookupURL
        self.fallbackProductURL = fallbackProductURL
    }

    func fetchRelease() async throws -> AppStoreRelease {
        let (data, response) = try await session.data(from: lookupURL)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppStoreReleaseError.invalidResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw AppStoreReleaseError.httpStatus(httpResponse.statusCode)
        }

        return try Self.decodeRelease(from: data, fallbackProductURL: fallbackProductURL)
    }

    static func decodeRelease(
        from data: Data,
        fallbackProductURL: URL = fallbackProductURL
    ) throws -> AppStoreRelease {
        let response = try JSONDecoder().decode(LookupResponse.self, from: data)
        guard
            let result = response.results.first,
            AppVersion(result.version) != nil
        else {
            throw AppStoreReleaseError.missingRelease
        }

        return AppStoreRelease(
            version: result.version,
            productURL: validatedProductURL(result.trackViewUrl) ?? fallbackProductURL
        )
    }

    private static func validatedProductURL(_ rawValue: String?) -> URL? {
        guard
            let rawValue,
            let url = URL(string: rawValue),
            url.scheme == "https"
        else {
            return nil
        }
        return url
    }

    private struct LookupResponse: Decodable {
        let results: [LookupResult]
    }

    private struct LookupResult: Decodable {
        let version: String
        let trackViewUrl: String?
    }
}

@MainActor
final class AppUpdateController: ObservableObject {
    nonisolated static let defaultCheckInterval: TimeInterval = 24 * 60 * 60

    @Published private(set) var availableRelease: AppStoreRelease?
    @Published private(set) var dismissedVersion: String?
    @Published private(set) var isChecking = false

    let installedVersion: InstalledAppVersion

    private let defaults: UserDefaults
    private let releaseFetcher: any AppStoreReleaseFetching
    private let checkInterval: TimeInterval

    init(
        installedVersion: InstalledAppVersion = .current(),
        defaults: UserDefaults = .standard,
        releaseFetcher: any AppStoreReleaseFetching = AppStoreReleaseService(),
        checkInterval: TimeInterval = AppUpdateController.defaultCheckInterval
    ) {
        self.installedVersion = installedVersion
        self.defaults = defaults
        self.releaseFetcher = releaseFetcher
        self.checkInterval = max(0, checkInterval)
        self.dismissedVersion = defaults.string(forKey: DefaultsKey.dismissedVersion)

        if
            let data = defaults.data(forKey: DefaultsKey.cachedRelease),
            let cachedRelease = try? JSONDecoder().decode(AppStoreRelease.self, from: data)
        {
            self.availableRelease = Self.newerRelease(
                cachedRelease,
                than: installedVersion.marketingVersion
            )
        } else {
            self.availableRelease = nil
        }
    }

    var dashboardRelease: AppStoreRelease? {
        guard availableRelease?.version != dismissedVersion else {
            return nil
        }
        return availableRelease
    }

    func checkForUpdates(force: Bool = false, at now: Date = Date()) async {
        guard !isChecking else {
            return
        }
        if
            !force,
            let lastCheck = defaults.object(forKey: DefaultsKey.lastSuccessfulCheck) as? Date,
            now.timeIntervalSince(lastCheck) >= 0,
            now.timeIntervalSince(lastCheck) < checkInterval
        {
            return
        }

        isChecking = true
        defer {
            isChecking = false
        }

        do {
            let release = try await releaseFetcher.fetchRelease()
            if let data = try? JSONEncoder().encode(release) {
                defaults.set(data, forKey: DefaultsKey.cachedRelease)
            }
            defaults.set(now, forKey: DefaultsKey.lastSuccessfulCheck)
            availableRelease = Self.newerRelease(
                release,
                than: installedVersion.marketingVersion
            )
        } catch {
            // Update discovery is best effort; retain any previously cached result.
        }
    }

    func dismissDashboardNotice() {
        guard let version = availableRelease?.version else {
            return
        }
        dismissedVersion = version
        defaults.set(version, forKey: DefaultsKey.dismissedVersion)
    }

    nonisolated static func newerRelease(
        _ release: AppStoreRelease,
        than installedVersion: String
    ) -> AppStoreRelease? {
        guard
            let installed = AppVersion(installedVersion),
            let available = AppVersion(release.version),
            available > installed
        else {
            return nil
        }
        return release
    }

    private enum DefaultsKey {
        static let cachedRelease = "appUpdate.cachedRelease"
        static let lastSuccessfulCheck = "appUpdate.lastSuccessfulCheck"
        static let dismissedVersion = "appUpdate.dismissedVersion"
    }
}
