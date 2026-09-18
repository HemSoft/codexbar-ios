import Foundation

public struct GitHubBillingCredentials: Codable, Equatable, Sendable {
    public let accessToken: String
    public let username: String
    public let refreshToken: String?
    public let expiresAt: Int64?
    public let refreshTokenExpiresAt: Int64?

    public init(
        accessToken: String,
        username: String,
        refreshToken: String? = nil,
        expiresAt: Int64? = nil,
        refreshTokenExpiresAt: Int64? = nil
    ) {
        self.accessToken = accessToken
        self.username = username
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
    }

    public func isExpired(at date: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return Date(timeIntervalSince1970: TimeInterval(expiresAt)) <= date
    }

    public func shouldRefresh(at date: Date = Date(), leadTime: TimeInterval = 300) -> Bool {
        guard let expiresAt else { return false }
        return Date(timeIntervalSince1970: TimeInterval(expiresAt)) <= date.addingTimeInterval(leadTime)
    }
}

public enum GitHubBillingCredentialsParser {
    public static func parse(_ value: String) -> GitHubBillingCredentials? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GitHubBillingCredentials.self, from: data)
    }

    public static func storedCredential(from credentials: GitHubBillingCredentials) -> String? {
        guard let data = try? JSONEncoder().encode(credentials) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
