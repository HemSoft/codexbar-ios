import Foundation

public struct ProviderAccountConfiguration: Identifiable, Equatable, Codable, Sendable {
    public let providerID: ProviderID
    public var isEnabled: Bool
    public var accountLabel: String
    public var authMethod: ProviderAuthMethod

    public init(
        providerID: ProviderID,
        isEnabled: Bool = true,
        accountLabel: String = "",
        authMethod: ProviderAuthMethod
    ) {
        self.providerID = providerID
        self.isEnabled = isEnabled
        self.accountLabel = accountLabel
        self.authMethod = authMethod
    }

    public var id: ProviderID {
        providerID
    }

    public var requiresSecret: Bool {
        authMethod.requiresSecret
    }
}

public enum ProviderAuthMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case apiKey
    case browserSession
    case codexAuthJSON
    case cliToken
    case oauth

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .apiKey:
            "API Key"
        case .browserSession:
            "Browser Session"
        case .codexAuthJSON:
            "Codex auth.json"
        case .cliToken:
            "CLI Token"
        case .oauth:
            "OAuth"
        }
    }

    public var requiresSecret: Bool {
        switch self {
        case .apiKey, .codexAuthJSON, .cliToken:
            true
        case .browserSession, .oauth:
            false
        }
    }
}

public extension ProviderAccountConfiguration {
    static func defaultConfiguration(for providerID: ProviderID) -> ProviderAccountConfiguration {
        switch providerID {
        case .codex:
            ProviderAccountConfiguration(providerID: providerID, authMethod: .browserSession)
        case .copilot:
            ProviderAccountConfiguration(providerID: providerID, authMethod: .cliToken)
        case .claude:
            ProviderAccountConfiguration(providerID: providerID, authMethod: .browserSession)
        case .openRouter:
            ProviderAccountConfiguration(providerID: providerID, authMethod: .apiKey)
        case .cursor:
            ProviderAccountConfiguration(providerID: providerID, authMethod: .browserSession)
        }
    }
}
