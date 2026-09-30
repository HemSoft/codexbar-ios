import Foundation

/// A snapshot of browser state taken on the main actor, before or after a cookie read.
struct GeminiBrowserInspectionContext {
    let isActive: Bool
    let isLoading: Bool
    let url: URL?
    let navigationRevision: Int

    func canInspect() -> Bool {
        isActive && !isLoading && GeminiBrowserSessionPolicy.canReturnToUsage(from: url)
    }
}

/// Decides what a cookie read means without owning a browser, account, or secret store.
struct GeminiBrowserInspectionState {
    enum Action: Equatable {
        case ignore
        case credential(String)
        case openUsage
        case explainRepeatedReturn
        case ambiguousSession
    }

    private var isReadingCookies = false
    private var returnState = GeminiBrowserReturnState()

    mutating func begin(in context: GeminiBrowserInspectionContext) -> Int? {
        guard !isReadingCookies, context.canInspect() else { return nil }
        isReadingCookies = true
        return context.navigationRevision
    }

    mutating func complete(
        cookies: [HTTPCookie], revision: Int, in context: GeminiBrowserInspectionContext
    ) -> Action {
        isReadingCookies = false
        guard context.canInspect(), context.navigationRevision == revision else { return .ignore }
        do {
            guard let credential = try GeminiBrowserSessionPolicy.storedCredential(from: cookies) else { return .ignore }
            return action(for: credential, at: context.url)
        } catch {
            return .ambiguousSession
        }
    }

    private mutating func action(for credential: String, at url: URL?) -> Action {
        if GeminiBrowserSessionPolicy.isUsagePage(url) { return .credential(credential) }
        return returnState.shouldReturn(for: credential) ? .openUsage : .explainRepeatedReturn
    }
}
