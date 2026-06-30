import Foundation

public enum CodexCredentialsParser {
    public static func parse(_ input: String) -> CodexCredentials? {
        let trimmedInput = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInput.isEmpty else {
            return nil
        }

        guard trimmedInput.first == "{" else {
            return CodexCredentials(accessToken: trimmedInput)
        }

        guard
            let data = trimmedInput.data(using: .utf8),
            let rootObject = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tokens = rootObject["tokens"] as? [String: Any]
        else {
            return nil
        }

        let accessToken = stringValue(in: tokens, snakeCase: "access_token", camelCase: "accessToken")
        guard let accessToken, !accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return CodexCredentials(
            accessToken: accessToken,
            accountID: stringValue(in: tokens, snakeCase: "account_id", camelCase: "accountId")
        )
    }

    private static func stringValue(in object: [String: Any], snakeCase: String, camelCase: String) -> String? {
        if let value = object[snakeCase] as? String {
            return value
        }

        return object[camelCase] as? String
    }
}

