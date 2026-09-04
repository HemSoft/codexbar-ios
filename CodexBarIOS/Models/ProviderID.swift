import Foundation

public enum ProviderID: String, CaseIterable, Codable, Identifiable, Sendable {
    case codex
    case copilot
    case claude
    case openRouter
    case openCodeZen
    case moonshot
    case cursor
    case greptile
    case gemini

    public var id: String {
        rawValue
    }

    public var displayName: String {
        switch self {
        case .codex:
            "ChatGPT / Codex"
        case .copilot:
            "GitHub Copilot"
        case .claude:
            "Claude"
        case .openRouter:
            "OpenRouter"
        case .openCodeZen:
            "OpenCode Go + Zen"
        case .moonshot:
            "Moonshot (Kimi)"
        case .cursor:
            "Cursor"
        case .greptile:
            "Greptile"
        case .gemini:
            "Google Gemini"
        }
    }

    public var supportsPlanBadge: Bool {
        switch self {
        case .codex, .copilot, .claude:
            true
        case .openRouter, .openCodeZen, .moonshot, .cursor, .greptile, .gemini:
            false
        }
    }
}
