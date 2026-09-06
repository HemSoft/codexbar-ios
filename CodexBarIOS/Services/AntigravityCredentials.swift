import CoreFoundation
import Foundation

struct AntigravityCredentials: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var clientID: String?
    var clientSecret: String?
    var expiry: Date?

    enum CredentialError: LocalizedError {
        case invalid

        var errorDescription: String? {
            "Import Antigravity session JSON containing a valid access_token."
        }
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case clientID = "client_id"
        case clientSecret = "client_secret"
        case expiry
    }

    var canRefresh: Bool {
        refreshToken != nil && clientID != nil && clientSecret != nil
    }

    static func parse(_ value: String) throws -> Self {
        guard let root = try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any] else {
            throw CredentialError.invalid
        }
        let token = root["token"] as? [String: Any] ?? root
        guard let accessToken = try field("access_token", in: token) else { throw CredentialError.invalid }
        return try Self(
            accessToken: accessToken,
            refreshToken: field("refresh_token", in: token),
            clientID: field("client_id", in: root),
            clientSecret: field("client_secret", in: root),
            expiry: expiryDate(in: token)
        )
    }

    func encoded() throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let value = String(bytes: try encoder.encode(self), encoding: .utf8) else {
            throw CredentialError.invalid
        }
        return value
    }

    private static func field(_ key: String, in object: [String: Any]) throws -> String? {
        guard let raw = object[key], !(raw is NSNull) else { return nil }
        guard let string = raw as? String else { throw CredentialError.invalid }
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw CredentialError.invalid
        }
        return value
    }

    private static func expiryDate(in token: [String: Any]) throws -> Date? {
        if let raw = token["expiry"], !(raw is NSNull) {
            guard let string = raw as? String, let date = AntigravityQuotaParser.date(string) else {
                throw CredentialError.invalid
            }
            return date
        }
        if let raw = token["expiry_date"], !(raw is NSNull) {
            guard let number = raw as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue > 0 else { throw CredentialError.invalid }
            return Date(timeIntervalSince1970: number.doubleValue / 1_000)
        }
        return nil
    }
}
