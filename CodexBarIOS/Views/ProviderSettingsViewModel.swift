import Foundation
import SwiftUI

@MainActor
final class ProviderSettingsViewModel: ObservableObject {
    enum PersistenceBehavior {
        case immediate
        case debounced
    }

    @Published private(set) var configuration: ProviderAccountConfiguration
    @Published var secret = ""
    @Published private(set) var isSigningInWithCodex = false
    @Published private(set) var isSigningInWithCopilot = false
    @Published private(set) var isSigningInWithClaude = false
    @Published private(set) var isSigningInWithCursor = false
    @Published private(set) var codexAuthError: String?
    @Published private(set) var copilotAuthError: String?
    @Published private(set) var claudeAuthError: String?
    @Published private(set) var claudeAuthDiagnostic: String?
    @Published private(set) var cursorAuthError: String?
    @Published var authURL: PresentedAuthURL?
    @Published private(set) var copilotTotalAllotmentText = ""
    @Published private(set) var openCodeCredentialMessage: String?
    @Published private(set) var isRefreshingOpenCode = false

    private let configurationStore: ProviderConfigurationStore
    private let accountID: String
    private let onCredentialsChanged: @MainActor () -> Void
    private let onAccountRefresh: @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult?
    private let codexAuthService: CodexWebAuthService
    private let copilotAuthService: CopilotWebAuthService
    private let claudeAuthService: ClaudeWebAuthService
    private let cursorAuthService: CursorWebAuthService
    private let copilotUsageProvider: CopilotUsageProvider
    private var cursorSignInTask: Task<Void, Never>?
    private var cursorAuthPresenter = CursorWebAuthenticationPresenter()
    private var debugAutostartedCopilotAuth = false
    private var pendingPersistenceTask: Task<Void, Never>?
    private var pendingConfiguration: ProviderAccountConfiguration?

    init(
        configurationStore: ProviderConfigurationStore,
        accountID: String,
        onCredentialsChanged: @escaping @MainActor () -> Void = {},
        onAccountRefresh: @escaping @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult? = { _ in nil },
        codexAuthService: CodexWebAuthService = CodexWebAuthService(),
        copilotAuthService: CopilotWebAuthService = CopilotWebAuthService(),
        claudeAuthService: ClaudeWebAuthService = ClaudeWebAuthService(),
        cursorAuthService: CursorWebAuthService = CursorWebAuthService(),
        copilotUsageProvider: CopilotUsageProvider = CopilotUsageProvider()
    ) {
        self.configurationStore = configurationStore
        self.accountID = accountID
        self.onCredentialsChanged = onCredentialsChanged
        self.onAccountRefresh = onAccountRefresh
        self.codexAuthService = codexAuthService
        self.copilotAuthService = copilotAuthService
        self.claudeAuthService = claudeAuthService
        self.cursorAuthService = cursorAuthService
        self.copilotUsageProvider = copilotUsageProvider
        self.configuration = configurationStore.configuration(accountID: accountID)
            ?? ProviderID(rawValue: accountID).map(ProviderAccountConfiguration.defaultConfiguration)
            ?? .defaultConfiguration(for: .codex)
    }

    var providerID: ProviderID {
        configuration.providerID
    }

    var availableAuthMethods: [ProviderAuthMethod] {
        switch providerID {
        case .codex, .claude, .cursor:
            [.browserSession]
        case .copilot:
            [.browserSession, .cliToken]
        case .openRouter, .openCodeZen, .moonshot:
            [.apiKey]
        }
    }

    func binding<Value>(
        for keyPath: WritableKeyPath<ProviderAccountConfiguration, Value>,
        persistence: PersistenceBehavior = .immediate
    ) -> Binding<Value> {
        Binding(
            get: { self.configuration[keyPath: keyPath] },
            set: { value in
                var updated = self.configuration
                updated[keyPath: keyPath] = value
                self.updateConfiguration(updated, persistence: persistence)
            }
        )
    }

    var copilotAllotmentBinding: Binding<String> {
        Binding(
            get: { self.copilotTotalAllotmentText },
            set: { value in
                self.copilotTotalAllotmentText = value
                var updated = self.configuration
                updated.copilotTotalAllotment = self.parsedAllotment(value)
                self.updateConfiguration(updated, persistence: .debounced)
            }
        )
    }

    func prepare() async {
        let stored = configurationStore.configuration(accountID: accountID) ?? configuration
        let normalized = normalizedConfiguration(stored)
        configuration = normalized
        copilotTotalAllotmentText = allotmentText(normalized.copilotTotalAllotment)
        if normalized != stored {
            _ = configurationStore.update(normalized)
        }
        configurationStore.refreshSecretAvailability()
        await debugAutostartCopilotAuthIfNeeded()
    }

    func cancelAuthentication() {
        cursorSignInTask?.cancel()
        cursorAuthPresenter.finish()
    }

    func flushPendingChanges() {
        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = nil
        guard let pendingConfiguration else { return }
        self.pendingConfiguration = nil
        _ = persist(pendingConfiguration)
    }

    func saveGenericCredential() {
        guard persist(configuration) else { return }
        configurationStore.saveSecret(secret, for: configuration)
        secret = ""
        onCredentialsChanged()
    }

    func removeSavedCredential(message: String? = nil) {
        configurationStore.saveSecret("", for: configuration)
        openCodeCredentialMessage = message
        onCredentialsChanged()
    }

    func signInWithCodex() async {
        isSigningInWithCodex = true
        codexAuthError = nil
        defer { isSigningInWithCodex = false }

        do {
            let result = try await codexAuthService.signIn { url in
                self.authURL = PresentedAuthURL(url: url)
            }
            var updated = configuration
            updated.authMethod = .browserSession
            guard persist(updated) else {
                codexAuthError = configurationStore.lastError
                authURL = nil
                return
            }
            configurationStore.saveSecret(result.storedCredential, for: configuration)
            onCredentialsChanged()
            authURL = nil
        } catch {
            codexAuthError = error.localizedDescription
            authURL = nil
        }
    }

    func signInWithCopilot() async {
        isSigningInWithCopilot = true
        copilotAuthError = nil
        defer { isSigningInWithCopilot = false }

        do {
            let result = try await copilotAuthService.signIn(configuration: .bundled) { url in
                self.authURL = PresentedAuthURL(url: url)
            }
            let username = try await copilotUsageProvider.fetchUsername(accessToken: result.accessToken)
            guard let username, !username.isEmpty else {
                copilotAuthError = "GitHub sign-in completed, but the token could not be verified for Copilot access."
                authURL = nil
                return
            }

            var updated = configuration
            updateCopilotAccountLabel(&updated, username: username)
            updated.authMethod = .browserSession
            guard persist(updated) else {
                copilotAuthError = configurationStore.lastError
                authURL = nil
                return
            }
            configurationStore.saveSecret(result.storedCredential(username: username), for: configuration)
            secret = ""
            onCredentialsChanged()
            authURL = nil
        } catch {
            copilotAuthError = error.localizedDescription
            authURL = nil
        }
    }

    func signInWithClaude() async {
        isSigningInWithClaude = true
        claudeAuthError = nil
        claudeAuthDiagnostic = nil
        defer { isSigningInWithClaude = false }

        do {
            let result = try await claudeAuthService.signIn(
                presentAuthorizationURL: { url in
                    self.authURL = PresentedAuthURL(url: url)
                },
                reportStage: { message in
                    self.claudeAuthDiagnostic = message
                }
            )
            var updated = configuration
            updated.authMethod = .browserSession
            guard persist(updated) else {
                claudeAuthError = configurationStore.lastError
                authURL = nil
                return
            }
            configurationStore.saveSecret(result.storedCredential, for: configuration)
            secret = ""
            onCredentialsChanged()
            authURL = nil
            claudeAuthDiagnostic = "Claude sign-in complete."
        } catch {
            claudeAuthError = error.localizedDescription
            authURL = nil
            if claudeAuthDiagnostic == nil {
                claudeAuthDiagnostic = "Claude sign-in failed."
            }
        }
    }

    func startCursorSignIn() {
        guard cursorSignInTask == nil else { return }
        cursorSignInTask = Task { @MainActor in
            await self.signInWithCursor()
        }
    }

    func signOutOfCursor() {
        cursorAuthError = nil
        flushPendingChanges()
        guard let disconnected = configurationStore.disconnectCursorAccount(configuration) else {
            cursorAuthError = configurationStore.lastError
            return
        }
        configuration = disconnected
        onCredentialsChanged()
    }

    func saveOpenCodeCredential() {
        guard persist(configuration) else {
            openCodeCredentialMessage = configurationStore.lastError
            return
        }
        configurationStore.saveSecret(secret, for: configuration)
        guard configurationStore.lastError == nil else {
            openCodeCredentialMessage = configurationStore.lastError
            return
        }

        secret = ""
        openCodeCredentialMessage = configuration.openCodeWorkspaceId
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "OpenCode dashboard auth value saved. Enter the workspace ID, then refresh."
            : "OpenCode dashboard auth value saved. Refreshing..."
        Task { await refreshOpenCode() }
    }

    func refreshOpenCode() async {
        guard !isRefreshingOpenCode else { return }
        isRefreshingOpenCode = true
        openCodeCredentialMessage = "Refreshing OpenCode ZEN..."
        defer { isRefreshingOpenCode = false }

        guard let result = await onAccountRefresh(configuration) else {
            openCodeCredentialMessage = "Refresh finished. Check the dashboard."
            return
        }
        if let balance = result.creditsRemaining {
            let formatted = Self.openCodeBalanceFormatter.string(from: NSNumber(value: balance)) ?? "$\(balance)"
            openCodeCredentialMessage = "OpenCode ZEN balance refreshed: \(formatted)"
        } else {
            openCodeCredentialMessage = result.subtitle
        }
    }

    func saveCopilotCredential() async {
        isSigningInWithCopilot = true
        copilotAuthError = nil
        defer { isSigningInWithCopilot = false }

        do {
            let token = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            let username = try await copilotUsageProvider.fetchUsername(accessToken: token)
            guard let username, !username.isEmpty else {
                copilotAuthError = "GitHub token could not be verified for Copilot access."
                return
            }

            var updated = configuration
            updateCopilotAccountLabel(&updated, username: username)
            updated.authMethod = .cliToken
            guard persist(updated) else {
                copilotAuthError = configurationStore.lastError
                return
            }
            let credentials = CopilotCredentials(accessToken: token, username: username)
            if let data = try? JSONEncoder().encode(credentials),
               let storedCredential = String(data: data, encoding: .utf8) {
                configurationStore.saveSecret(storedCredential, for: configuration)
            } else {
                configurationStore.saveSecret(token, for: configuration)
            }
            secret = ""
            onCredentialsChanged()
        } catch {
            copilotAuthError = error.localizedDescription
        }
    }

    private func signInWithCursor() async {
        isSigningInWithCursor = true
        cursorAuthError = nil
        defer {
            cursorAuthPresenter.finish()
            cursorSignInTask = nil
            isSigningInWithCursor = false
        }

        do {
            let result = try await cursorAuthService.signIn { url in
                self.cursorAuthPresenter.present(url: url) {
                    self.cursorSignInTask?.cancel()
                }
            }
            flushPendingChanges()
            guard let connected = configurationStore.connectCursorAccount(
                configuration,
                credential: result.storedCredential
            ) else {
                cursorAuthError = configurationStore.lastError
                return
            }
            configuration = connected
            secret = ""
            onCredentialsChanged()
        } catch {
            cursorAuthError = Task.isCancelled
                ? "Cursor sign-in canceled. The existing account was not changed."
                : error.localizedDescription
        }
    }

    private func debugAutostartCopilotAuthIfNeeded() async {
        #if DEBUG
        guard providerID == .copilot,
              !debugAutostartedCopilotAuth,
              ProcessInfo.processInfo.environment["CODEXBAR_DEBUG_AUTOSTART_COPILOT_AUTH"] == "1"
        else { return }

        debugAutostartedCopilotAuth = true
        await Task.yield()
        await signInWithCopilot()
        #endif
    }

    private func updateConfiguration(
        _ updated: ProviderAccountConfiguration,
        persistence: PersistenceBehavior
    ) {
        configuration = updated
        switch persistence {
        case .immediate:
            pendingPersistenceTask?.cancel()
            pendingPersistenceTask = nil
            pendingConfiguration = nil
            _ = configurationStore.update(updated)
        case .debounced:
            pendingConfiguration = updated
            pendingPersistenceTask?.cancel()
            pendingPersistenceTask = Task { @MainActor [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(350))
                } catch {
                    return
                }
                self?.flushPendingChanges()
            }
        }
    }

    @discardableResult
    private func persist(_ updated: ProviderAccountConfiguration) -> Bool {
        pendingPersistenceTask?.cancel()
        pendingPersistenceTask = nil
        pendingConfiguration = nil
        configuration = updated
        return configurationStore.update(updated)
    }

    private func normalizedConfiguration(_ configuration: ProviderAccountConfiguration) -> ProviderAccountConfiguration {
        var normalized = configuration
        if [.codex, .claude, .cursor].contains(configuration.providerID) {
            normalized.authMethod = .browserSession
        }
        return normalized
    }

    private func updateCopilotAccountLabel(
        _ configuration: inout ProviderAccountConfiguration,
        username: String
    ) {
        if configuration.copilotAccountScope == .personal {
            configuration.accountLabel = username
        } else if configuration.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            configuration.accountLabel = configuration.githubOrganization.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func allotmentText(_ value: Double?) -> String {
        guard let value else { return "" }
        return value.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
    }

    private func parsedAllotment(_ value: String) -> Double? {
        let normalized = value.replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : Double(normalized)
    }

    private static let openCodeBalanceFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}
