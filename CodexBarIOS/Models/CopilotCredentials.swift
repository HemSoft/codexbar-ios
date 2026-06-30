import Foundation

public struct CopilotCredentials: Equatable, Codable, Sendable {
    public let accessToken: String
    public let username: String?

    public init(accessToken: String, username: String? = nil) {
        self.accessToken = accessToken
        self.username = username
    }
}
