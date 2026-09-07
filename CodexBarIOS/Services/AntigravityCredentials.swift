import CoreFoundation
import Foundation

struct AntigravityCredentials: Codable, Equatable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var clientID: String?
    var clientSecret: String?
    var expiry: Date?
    var isPublicClient: Bool?

    enum CredentialError: LocalizedError {
        case invalid

        var errorDescription: String? {
            "The saved coding session is invalid. Open Gemini settings to manage the connection."
        }
    }

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case clientID = "client_id"
        case clientSecret = "client_secret"
        case expiry
        case isPublicClient
    }

    var canRefresh: Bool {
        refreshToken != nil && clientID != nil && (clientSecret != nil || isPublicClient == true)
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
            expiry: expiryDate(in: token),
            isPublicClient: root["isPublicClient"] as? Bool
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

#if DEBUG
/// Installs an existing session during a developer-controlled device deployment.
/// This is excluded from release builds and is never an end-user setup flow.
@MainActor
enum DeveloperGoogleSessionInstaller {
    static let fileName = "google-coding-development-session.json"
    static let launchArgument = "--install-development-google-session"

    private struct Payload: Decodable {
        let accountID: String
        let credential: String
        let confirmedSameAccount: Bool
    }

    static func installIfRequested(
        configurationStore: ProviderConfigurationStore,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        directory: URL? = nil
    ) -> Bool {
        guard arguments.contains(launchArgument),
              let directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
        else { return false }
        let url = directory.appendingPathComponent(fileName)
        defer { try? FileManager.default.removeItem(at: url) }
        guard OpenCodeZenBootstrapImporter.protectImportFile(at: url, fileManager: .default),
              let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 65_536,
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.confirmedSameAccount,
              let account = configurationStore.configuration(accountID: payload.accountID),
              account.providerID == .gemini,
              let credential = try? AntigravityCredentials.parse(payload.credential),
              credential.canRefresh
        else { return false }
        return configurationStore.saveGeminiCodingSecret(
            payload.credential, for: account, confirmedSameAccount: true, requireEmptySlot: true
        )
    }
}
#endif
