import CoreFoundation
import Foundation

/// The deployed Console Go contract; allowance resets and Zen reloads are not billing dates.
enum OpenCodeSubscriptionBilling {
    static func observation(_ data: Data, credential: OpenCodeConsoleCredential,
                            configuration: ProviderAccountConfiguration, at now: Date) -> SubscriptionRenewal? {
        guard configuration.providerID == .openCodeZen, configuration.openCodeWorkspaceId == credential.workspaceID,
              let root = SubscriptionBillingParser.object(data),
              root["subscriberUserId"] as? String == credential.userID,
              ["go", "go-plus"].contains(root["product"] as? String ?? ""),
              ["go", "go-plus"].contains(root["renewalProduct"] as? String ?? ""),
              let access = root["access"] as? [String: Any],
              let canceled = boolean(root["cancelAtPeriodEnd"]),
              boolean(access["cancelAtPeriodEnd"]) == canceled,
              let start = timestamp(access["startsAt"]), let end = timestamp(access["endsAt"]),
              start <= now, now < end else { return nil }
        // Explicit cancellation takes precedence over residual payment recovery fields.
        if !canceled {
            guard root["resumability"] as? String == "renewing", boolean(root["renewalPending"]) == false,
                  absent(root["renewalStopReason"]), absent(root["renewalRetryAt"]), absent(root["renewalPaymentAttemptId"]),
                  root["renewalAuthorizationRequired"] == nil || boolean(root["renewalAuthorizationRequired"]) == false else { return nil }
        }
        return SubscriptionRenewal(accountID: configuration.id, providerID: .openCodeZen,
                                   state: canceled ? .nonRenewing : .renewing, date: end, observedAt: now)
    }

    static func matchesIdentity(_ data: Data, credential: OpenCodeConsoleCredential) -> Bool {
        guard let root = SubscriptionBillingParser.object(data), let user = root["user"] as? [String: Any],
              user["id"] as? String == credential.userID else { return false }
        return absent(root["org_id"]) || root["org_id"] as? String == credential.workspaceID
    }

    private static func absent(_ value: Any?) -> Bool { value == nil || value is NSNull }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let value = value as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return value.boolValue
    }

    private static func timestamp(_ value: Any?) -> Date? {
        guard let text = value as? String,
              text.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T([01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9](\\.[0-9]+)?(Z|[+-]([01][0-9]|2[0-3]):[0-5][0-9])$",
                         options: .regularExpression) != nil else { return nil }
        let civil = DateFormatter()
        civil.locale = Locale(identifier: "en_US_POSIX")
        civil.calendar = Calendar(identifier: .gregorian)
        civil.timeZone = TimeZone(secondsFromGMT: 0)
        civil.dateFormat = "yyyy-MM-dd"
        civil.isLenient = false
        let prefix = String(text.prefix(10))
        guard let day = civil.date(from: prefix), civil.string(from: day) == prefix else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
