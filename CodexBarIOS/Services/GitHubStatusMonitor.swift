import Combine
import Foundation
import OSLog
#if os(iOS)
import BackgroundTasks
#endif

public enum GitHubStatusPollingInterval: Int, CaseIterable, Codable, Identifiable, Sendable {
    case fifteenMinutes = 900
    case thirtyMinutes = 1_800
    case oneHour = 3_600

    public var id: Self { self }
    public var seconds: TimeInterval { TimeInterval(rawValue) }

    public var displayName: String {
        switch self {
        case .fifteenMinutes: "Every 15 minutes"
        case .thirtyMinutes: "Every 30 minutes"
        case .oneHour: "Every hour"
        }
    }
}

public struct GitHubStatusSettings: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var pollingInterval: GitHubStatusPollingInterval
    public var showsInAppBanner: Bool
    public var sendsIncidentNotifications: Bool
    public var sendsRecoveryNotifications: Bool

    public init(
        isEnabled: Bool = false,
        pollingInterval: GitHubStatusPollingInterval = .thirtyMinutes,
        showsInAppBanner: Bool = true,
        sendsIncidentNotifications: Bool = false,
        sendsRecoveryNotifications: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.pollingInterval = pollingInterval
        self.showsInAppBanner = showsInAppBanner
        self.sendsIncidentNotifications = sendsIncidentNotifications
        self.sendsRecoveryNotifications = sendsRecoveryNotifications
    }
}

public enum GitHubServiceSeverity: Int, Codable, Comparable, Sendable {
    case operational
    case minor
    case major
    case critical

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    public var displayName: String {
        switch self {
        case .operational: "Operational"
        case .minor: "Degraded"
        case .major: "Major disruption"
        case .critical: "Critical outage"
        }
    }

    public var systemImage: String {
        switch self {
        case .operational: "checkmark.circle.fill"
        case .minor: "exclamationmark.circle.fill"
        case .major, .critical: "exclamationmark.triangle.fill"
        }
    }
}

public struct GitHubServiceStatusSnapshot: Codable, Equatable, Sendable {
    public let severity: GitHubServiceSeverity
    public let summary: String
    public let incidentIDs: [String]
    public let updateIdentity: String
    public let updatedAt: Date
    public let checkedAt: Date
    public let detailsURL: URL

    public var isActive: Bool { severity != .operational }
    public var bannerIdentity: String { "\(incidentIDs.joined(separator: ","))|\(updateIdentity)|\(severity.rawValue)" }
}

public enum GitHubStatusNotificationKind: Equatable, Sendable {
    case incident
    case escalation
    case recovery
}

public struct GitHubStatusNotification: Equatable, Sendable {
    public let id: String
    public let title: String
    public let body: String
    public let kind: GitHubStatusNotificationKind
}

public enum GitHubStatusTransitionEvaluator {
    public static func notification(
        previous: GitHubServiceStatusSnapshot?,
        current: GitHubServiceStatusSnapshot,
        settings: GitHubStatusSettings
    ) -> GitHubStatusNotification? {
        if current.isActive {
            let kind: GitHubStatusNotificationKind?
            if let previous, previous.isActive {
                let newIncident = !Set(current.incidentIDs).isSubset(of: Set(previous.incidentIDs))
                if newIncident {
                    kind = .incident
                } else if current.severity > previous.severity {
                    kind = .escalation
                } else {
                    kind = nil
                }
            } else {
                kind = .incident
            }

            guard let kind, settings.sendsIncidentNotifications else {
                return nil
            }
            let title = kind == .escalation
                ? "GitHub status escalated"
                : "GitHub service incident"
            return GitHubStatusNotification(
                id: "github-status.\(kind).\(current.incidentIDs.joined(separator: ".")).\(current.severity.rawValue)",
                title: title,
                body: "\(current.severity.displayName): \(current.summary)",
                kind: kind
            )
        }

        guard previous?.isActive == true, settings.sendsRecoveryNotifications else {
            return nil
        }
        return GitHubStatusNotification(
            id: "github-status.recovery.\(previous?.incidentIDs.joined(separator: ".") ?? "service")",
            title: "GitHub service recovered",
            body: "GitHub is reporting normal service again.",
            kind: .recovery
        )
    }
}

public enum GitHubStatusFreshness {
    public static func isStale(
        _ snapshot: GitHubServiceStatusSnapshot,
        interval: GitHubStatusPollingInterval,
        now: Date = Date()
    ) -> Bool {
        now.timeIntervalSince(snapshot.checkedAt) > max(interval.seconds * 2, 3_600)
    }
}

public enum GitHubStatusParsingError: Error, LocalizedError {
    case invalidResponse

    public var errorDescription: String? {
        "GitHub Status returned data CodexBar could not read."
    }
}

public enum GitHubStatusParser {
    private static let statusURL = URL(string: "https://www.githubstatus.com")!

    public static func parse(_ data: Data, checkedAt: Date = Date()) throws -> GitHubServiceStatusSnapshot {
        let response = try JSONDecoder().decode(StatuspageSummary.self, from: data)
        let activeIncidents = response.incidents.filter {
            $0.status != "resolved" && Self.severity(forImpact: $0.impact) != .operational
        }

        if !activeIncidents.isEmpty {
            let severity: GitHubServiceSeverity = activeIncidents
                .map { Self.severity(forImpact: $0.impact) }
                .max() ?? .minor
            let ordered = activeIncidents.sorted {
                let lhsSeverity = Self.severity(forImpact: $0.impact)
                let rhsSeverity = Self.severity(forImpact: $1.impact)
                if lhsSeverity != rhsSeverity {
                    return lhsSeverity > rhsSeverity
                }
                return $0.id < $1.id
            }
            guard let leadIncident = ordered.first else {
                throw GitHubStatusParsingError.invalidResponse
            }
            let latestUpdate = leadIncident.incidentUpdates.max {
                parsedDate($0.updatedAt) < parsedDate($1.updatedAt)
            }
            let summary = activeIncidents.count == 1
                ? leadIncident.name
                : "\(leadIncident.name) and \(activeIncidents.count - 1) more incident\(activeIncidents.count == 2 ? "" : "s")"
            return GitHubServiceStatusSnapshot(
                severity: severity,
                summary: summary,
                incidentIDs: activeIncidents.map(\.id).sorted(),
                updateIdentity: latestUpdate?.id ?? leadIncident.id,
                updatedAt: latestUpdate.map { parsedDate($0.updatedAt) }
                    ?? parsedDate(leadIncident.updatedAt),
                checkedAt: checkedAt,
                detailsURL: leadIncident.shortlink.flatMap(URL.init(string:)) ?? statusURL
            )
        }

        let degradedComponents = response.components.filter {
            $0.group != true && $0.status != "operational"
        }
        if !degradedComponents.isEmpty {
            let severity: GitHubServiceSeverity = degradedComponents
                .map { Self.severity(forComponentStatus: $0.status) }
                .max() ?? Self.severity(forIndicator: response.status.indicator)
            let names = degradedComponents.prefix(3).map(\.name).joined(separator: ", ")
            let suffix = degradedComponents.count > 3 ? " and \(degradedComponents.count - 3) more" : ""
            return GitHubServiceStatusSnapshot(
                severity: max(severity, .minor),
                summary: "Affected components: \(names)\(suffix)",
                incidentIDs: degradedComponents.map { "component:\($0.id)" }.sorted(),
                updateIdentity: degradedComponents
                    .map { "\($0.id):\($0.status):\($0.updatedAt)" }
                    .sorted()
                    .joined(separator: "|"),
                updatedAt: degradedComponents.map { parsedDate($0.updatedAt) }.max() ?? checkedAt,
                checkedAt: checkedAt,
                detailsURL: statusURL
            )
        }

        return GitHubServiceStatusSnapshot(
            severity: .operational,
            summary: response.status.description,
            incidentIDs: [],
            updateIdentity: response.status.indicator,
            updatedAt: checkedAt,
            checkedAt: checkedAt,
            detailsURL: statusURL
        )
    }

    private static func severity(forImpact impact: String) -> GitHubServiceSeverity {
        switch impact {
        case "none": .operational
        case "critical": .critical
        case "major": .major
        case "minor", "maintenance": .minor
        default: .minor
        }
    }

    private static func severity(forComponentStatus status: String) -> GitHubServiceSeverity {
        switch status {
        case "major_outage": .critical
        case "partial_outage": .major
        case "degraded_performance", "under_maintenance": .minor
        default: .operational
        }
    }

    private static func severity(forIndicator indicator: String) -> GitHubServiceSeverity {
        switch indicator {
        case "critical": .critical
        case "major": .major
        case "minor": .minor
        default: .operational
        }
    }

    private static func parsedDate(_ value: String) -> Date {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractionalFormatter.date(from: value) {
            return date
        }
        return ISO8601DateFormatter().date(from: value) ?? .distantPast
    }
}

private struct StatuspageSummary: Decodable {
    let components: [StatuspageComponent]
    let incidents: [StatuspageIncident]
    let status: StatuspageStatus
}

private struct StatuspageComponent: Decodable {
    let id: String
    let name: String
    let status: String
    let updatedAt: String
    let group: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, name, status, group
        case updatedAt = "updated_at"
    }
}

private struct StatuspageIncident: Decodable {
    let id: String
    let name: String
    let status: String
    let impact: String
    let updatedAt: String
    let shortlink: String?
    let incidentUpdates: [StatuspageIncidentUpdate]

    private enum CodingKeys: String, CodingKey {
        case id, name, status, impact, shortlink
        case updatedAt = "updated_at"
        case incidentUpdates = "incident_updates"
    }
}

private struct StatuspageIncidentUpdate: Decodable {
    let id: String
    let updatedAt: String

    private enum CodingKeys: String, CodingKey {
        case id
        case updatedAt = "updated_at"
    }
}

private struct StatuspageStatus: Decodable {
    let indicator: String
    let description: String
}

public protocol GitHubStatusFetching: Sendable {
    func fetchStatus(checkedAt: Date) async throws -> GitHubServiceStatusSnapshot
}

public struct LiveGitHubStatusFetcher: GitHubStatusFetching {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func fetchStatus(checkedAt: Date = Date()) async throws -> GitHubServiceStatusSnapshot {
        var request = URLRequest(url: URL(string: "https://www.githubstatus.com/api/v2/summary.json")!)
        request.timeoutInterval = 10
        request.cachePolicy = .reloadRevalidatingCacheData
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode)
        else {
            throw GitHubStatusParsingError.invalidResponse
        }
        return try GitHubStatusParser.parse(data, checkedAt: checkedAt)
    }
}

@MainActor
public protocol GitHubStatusNotifying: AnyObject {
    func deliverGitHubStatus(_ notification: GitHubStatusNotification) async throws
}

@MainActor
public final class GitHubStatusPreferences: ObservableObject {
    @Published public private(set) var settings: GitHubStatusSettings
    @Published public private(set) var snapshot: GitHubServiceStatusSnapshot?
    @Published public private(set) var lastChecked: Date?
    @Published public private(set) var lastError: String?
    @Published public private(set) var dismissedBannerIdentity: String?

    private let defaults: UserDefaults
    private let settingsKey = "githubStatusSettings"
    private let stateKey = "githubStatusObservationState"
    private var state: PersistedState

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: settingsKey),
           let decoded = try? JSONDecoder().decode(GitHubStatusSettings.self, from: data) {
            settings = decoded
        } else {
            settings = GitHubStatusSettings()
        }
        if let data = defaults.data(forKey: stateKey),
           let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) {
            state = decoded
        } else {
            state = PersistedState()
        }
        snapshot = state.snapshot
        lastChecked = state.lastChecked
        lastError = state.lastError
        dismissedBannerIdentity = state.dismissedBannerIdentity
    }

    public var nextEligibleCheck: Date {
        guard let lastAttempt = state.lastAttempt else { return .distantPast }
        let multiplier = pow(2, Double(min(state.consecutiveFailures, 4)))
        let backoff = min(settings.pollingInterval.seconds * multiplier, 14_400)
        return lastAttempt.addingTimeInterval(backoff)
    }

    public func updateSettings(_ settings: GitHubStatusSettings) {
        self.settings = settings
        if !settings.isEnabled {
            dismissedBannerIdentity = nil
            state.dismissedBannerIdentity = nil
            saveState()
        }
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: settingsKey)
        }
    }

    public func recordSuccess(_ snapshot: GitHubServiceStatusSnapshot) {
        self.snapshot = snapshot
        lastChecked = snapshot.checkedAt
        lastError = nil
        if dismissedBannerIdentity != nil,
           dismissedBannerIdentity != snapshot.bannerIdentity {
            dismissedBannerIdentity = nil
        }
        state.snapshot = snapshot
        state.lastAttempt = snapshot.checkedAt
        state.lastChecked = snapshot.checkedAt
        state.lastError = nil
        state.consecutiveFailures = 0
        state.dismissedBannerIdentity = dismissedBannerIdentity
        saveState()
    }

    public func recordFailure(_ error: Error, attemptedAt: Date) {
        let message = (error as? LocalizedError)?.errorDescription
            ?? "GitHub Status could not be checked."
        lastChecked = attemptedAt
        lastError = message
        state.lastAttempt = attemptedAt
        state.lastChecked = attemptedAt
        state.lastError = message
        state.consecutiveFailures += 1
        saveState()
    }

    public func dismissCurrentBanner() {
        guard let identity = snapshot?.bannerIdentity else { return }
        dismissedBannerIdentity = identity
        state.dismissedBannerIdentity = identity
        saveState()
    }

    private func saveState() {
        if let data = try? JSONEncoder().encode(state) {
            defaults.set(data, forKey: stateKey)
        }
    }

    private struct PersistedState: Codable {
        var snapshot: GitHubServiceStatusSnapshot?
        var lastAttempt: Date?
        var lastChecked: Date?
        var lastError: String?
        var dismissedBannerIdentity: String?
        var consecutiveFailures = 0
    }
}

@MainActor
public final class GitHubStatusMonitor: ObservableObject {
    #if os(iOS)
    public static let backgroundTaskIdentifier = "com.hemsoft.CodexBarIOS.github-status-refresh"
    #endif

    public let preferences: GitHubStatusPreferences
    @Published public private(set) var isRefreshing = false

    private let fetcher: any GitHubStatusFetching
    private let notifier: any GitHubStatusNotifying
    private static let logger = Logger(
        subsystem: "com.hemsoft.CodexBarIOS",
        category: "github-status"
    )

    public init(
        preferences: GitHubStatusPreferences,
        fetcher: any GitHubStatusFetching = LiveGitHubStatusFetcher(),
        notifier: any GitHubStatusNotifying
    ) {
        self.preferences = preferences
        self.fetcher = fetcher
        self.notifier = notifier
    }

    public func refreshIfDue(force: Bool = false, now: Date = Date()) async {
        guard preferences.settings.isEnabled,
              !isRefreshing,
              force || now >= preferences.nextEligibleCheck
        else {
            scheduleBackgroundRefresh()
            return
        }

        isRefreshing = true
        defer {
            isRefreshing = false
            scheduleBackgroundRefresh()
        }
        let previous = preferences.snapshot
        do {
            let snapshot = try await fetcher.fetchStatus(checkedAt: now)
            if let notification = GitHubStatusTransitionEvaluator.notification(
                previous: previous,
                current: snapshot,
                settings: preferences.settings
            ) {
                try? await notifier.deliverGitHubStatus(notification)
            }
            preferences.recordSuccess(snapshot)
        } catch {
            preferences.recordFailure(error, attemptedAt: now)
        }
    }

    public func runForegroundLoop() async {
        guard preferences.settings.isEnabled else {
            scheduleBackgroundRefresh()
            return
        }
        await refreshIfDue()
        while !Task.isCancelled, preferences.settings.isEnabled {
            let delay = max(preferences.nextEligibleCheck.timeIntervalSinceNow, 1)
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            await refreshIfDue()
        }
    }

    public func performBackgroundRefresh() async {
        await refreshIfDue(force: true)
    }

    public func scheduleBackgroundRefresh() {
        #if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.backgroundTaskIdentifier)
        guard preferences.settings.isEnabled else { return }
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundTaskIdentifier)
        request.earliestBeginDate = max(preferences.nextEligibleCheck, Date().addingTimeInterval(60))
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Self.logger.error(
                "Background status refresh scheduling failed: \(error.localizedDescription, privacy: .public)"
            )
        }
        #endif
    }
}
