import CoreFoundation
import Foundation

/// Optional billing read. Rejected access never changes the successful usage result.
final class CodexSubscriptionClient: @unchecked Sendable {
    private let session: URLSession
    private let endpoint: URL

    init(session: URLSession, endpoint: URL = URL(string: "https://chatgpt.com/backend-api/subscriptions")!) {
        let configuration = session.configuration
        configuration.httpAdditionalHeaders = configuration.httpAdditionalHeaders?.filter {
            String(describing: $0.key).lowercased() != "cookie"
        }
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 3
        self.session = URLSession(configuration: configuration, delegate: CodexSubscriptionRejectRedirects(), delegateQueue: nil)
        self.endpoint = endpoint
    }

    deinit { session.invalidateAndCancel() }

    func fetch(credentials: CodexCredentials, accountID: String, observedAt: Date) async throws -> SubscriptionRenewal? {
        guard let providerAccount = credentials.accountID, !providerAccount.isEmpty else { return nil }
        var request = URLRequest(url: endpoint)
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(providerAccount, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexBarIOS", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse, response.statusCode == 200, data.count <= 65_536 else { return nil }
            return Self.parse(data, accountID: accountID, providerAccountID: providerAccount, observedAt: observedAt)
        } catch {
            try Task.checkCancellation()
            return nil
        }
    }

    static func parse(_ data: Data, accountID: String, providerAccountID: String, observedAt: Date) -> SubscriptionRenewal? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let flag = object["will_renew"] as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else { return nil }
        if let returnedAccount = object["account_id"], returnedAccount as? String != providerAccountID { return nil }
        guard let rawDate = object["active_until"] as? String else {
            guard object["active_until"] is NSNull, !flag.boolValue else { return nil }
            return SubscriptionRenewal(accountID: accountID, providerID: .codex, state: .notApplicable, date: nil, observedAt: observedAt)
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = formatter.date(from: rawDate)
        formatter.formatOptions = [.withInternetDateTime]
        guard let date = fractional ?? formatter.date(from: rawDate) else { return nil }
        return SubscriptionRenewal(accountID: accountID, providerID: .codex,
                                   state: flag.boolValue ? .renewing : .nonRenewing, date: date, observedAt: observedAt)
    }
}

private final class CodexSubscriptionRejectRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
