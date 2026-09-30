import Foundation

enum GitHubStatusNotificationPreference: Hashable, Sendable {
    case incident
    case recovery

    func updating(_ settings: GitHubStatusSettings, isEnabled: Bool) -> GitHubStatusSettings {
        var updated = settings
        switch self {
        case .incident:
            updated.sendsIncidentNotifications = isEnabled
        case .recovery:
            updated.sendsRecoveryNotifications = isEnabled
        }
        return updated
    }
}

/// Request identities isolate independent toggles and reject superseded completions.
struct GitHubStatusNotificationAuthorization: Equatable, Sendable {
    struct Request: Equatable, Sendable {
        let id: UUID
        let preference: GitHubStatusNotificationPreference
    }

    private var pending: [GitHubStatusNotificationPreference: UUID] = [:]

    func isPending(_ preference: GitHubStatusNotificationPreference) -> Bool {
        pending[preference] != nil
    }

    mutating func begin(_ preference: GitHubStatusNotificationPreference) -> Request {
        let request = Request(id: UUID(), preference: preference)
        pending[preference] = request.id
        return request
    }

    mutating func cancel(_ preference: GitHubStatusNotificationPreference) {
        pending[preference] = nil
    }

    mutating func cancelAll() {
        pending.removeAll()
    }

    /// Nil means an obsolete result, not a denied permission. Do not apply its settings or feedback.
    mutating func complete(_ request: Request, granted: Bool) -> Bool? {
        guard pending[request.preference] == request.id else { return nil }
        pending[request.preference] = nil
        return granted
    }

    static func permissionMessage(granted: Bool) -> String? {
        granted ? nil : "Notifications are disabled for CodexBar."
    }
}
