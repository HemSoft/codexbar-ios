import Foundation

public enum CodexBarDeepLink {
    public static let scheme = "codexbar"

    private static let providerHost = "provider"
    private static let accountQueryName = "account"

    public static func providerURL(accountID: String) -> URL? {
        guard !accountID.isEmpty else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = providerHost
        components.queryItems = [URLQueryItem(name: accountQueryName, value: accountID)]
        return components.url
    }

    public static func providerAccountID(from url: URL) -> String? {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            components.scheme?.lowercased() == scheme,
            components.host?.lowercased() == providerHost,
            components.path.isEmpty || components.path == "/"
        else {
            return nil
        }

        let accountItems = components.queryItems?.filter { $0.name == accountQueryName } ?? []
        guard accountItems.count == 1, let accountID = accountItems[0].value, !accountID.isEmpty else {
            return nil
        }

        return accountID
    }
}
