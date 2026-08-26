import Foundation
import SwiftUI

struct ProviderCredentialPresentation: Equatable {
    let sectionTitle: String
    let unsavedPlaceholder: String
    let savedPlaceholder: String
    let saveButtonTitle: String
    let setupMessage: String?
    let setupLinkTitle: String?
    let setupURL: URL?
    let securityMessage: String?
}

@MainActor
final class ProviderSettingsViewModel: ObservableObject {
    private static let greptileValidatedMessage = "API key saved in Keychain and validated by Greptile."

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
    @Published private(set) var credentialError: String?
    @Published private(set) var credentialMessage: String?
    @Published var authURL: PresentedAuthURL?
    @Published private(set) var copilotTotalAllotmentText = ""
    @Published private(set) var openCodeCredentialMessage: String?
    @Published private(set) var isRefreshingOpenCode = false
    @Published private(set) var usageResult: ProviderUsageResult?
    @Published private(set) var isLoadingMetrics = false

    private let configurationStore: ProviderConfigurationStore
    private let accountID: String
    private let onCredentialsChanged: @MainActor () -> Void
    private let onRefreshInputsChanged: @MainActor () -> Void
    private let onAccountRefresh: @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult?
    private let onCredentialRefresh: @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult?
    private let codexAuthService: any CodexWebAuthenticating
    private let copilotAuthService: any CopilotWebAuthenticating
    private let claudeAuthService: ClaudeWebAuthService
    private let cursorAuthService: CursorWebAuthService
    private let copilotUsageProvider: CopilotUsageProvider
    private var codexSignInTask: Task<Void, Never>?
    private var codexAuthPresenter = PrivateWebAuthenticationPresenter()
    private var cursorSignInTask: Task<Void, Never>?
    private var cursorAuthPresenter = PrivateWebAuthenticationPresenter()
    private var debugAutostartedCopilotAuth = false
    private var pendingPersistenceTask: Task<Void, Never>?
    private var pendingConfiguration: ProviderAccountConfiguration?
    private var needsCredentialMetricsRefresh = false
    private var metricsCredentialRevision = 0
    private var isCredentialRefreshPending = false
    private var showsGreptileValidationFeedback = false

    var credentialMessageSystemImage: String {
        credentialMessage == Self.greptileValidatedMessage
            ? "checkmark.circle"
            : "clock"
    }

    init(
        configurationStore: ProviderConfigurationStore,
        accountID: String,
        initialUsageResult: ProviderUsageResult? = nil,
        onCredentialsChanged: @escaping @MainActor () -> Void = {},
        onRefreshInputsChanged: @escaping @MainActor () -> Void = {},
        onAccountRefresh: @escaping @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult? = { _ in nil },
        onCredentialRefresh: (@MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult?)? = nil,
        codexAuthService: any CodexWebAuthenticating = CodexWebAuthService(),
        copilotAuthService: any CopilotWebAuthenticating = CopilotWebAuthService(),
        claudeAuthService: ClaudeWebAuthService = ClaudeWebAuthService(),
        cursorAuthService: CursorWebAuthService = CursorWebAuthService(),
        copilotUsageProvider: CopilotUsageProvider = CopilotUsageProvider()
    ) {
        self.configurationStore = configurationStore
        self.accountID = accountID
        self.usageResult = initialUsageResult?.accountID == accountID
            ? initialUsageResult
            : nil
        self.onCredentialsChanged = onCredentialsChanged
        self.onRefreshInputsChanged = onRefreshInputsChanged
        self.onAccountRefresh = onAccountRefresh
        self.onCredentialRefresh = onCredentialRefresh ?? onAccountRefresh
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
        case .openRouter, .openCodeZen, .moonshot, .greptile:
            [.apiKey]
        }
    }

    var credentialPresentation: ProviderCredentialPresentation {
        if providerID == .openRouter {
            return ProviderCredentialPresentation(
                sectionTitle: "OpenRouter Management API Key",
                unsavedPlaceholder: "Paste OpenRouter Management API Key",
                savedPlaceholder: "OpenRouter Management API Key saved",
                saveButtonTitle: "Save Management API Key",
                setupMessage: "OpenRouter credit balances require a Management API Key, not a regular inference key.",
                setupLinkTitle: "Create a Management API Key in OpenRouter",
                setupURL: URL(string: "https://openrouter.ai/settings/management-keys"),
                securityMessage: "Management keys can administer API keys and are more sensitive than inference "
                    + "keys. CodexBar stores this credential only in Keychain."
            )
        }

        if providerID == .greptile {
            return ProviderCredentialPresentation(
                sectionTitle: "Greptile Organization API Key",
                unsavedPlaceholder: "Paste Greptile organization API key",
                savedPlaceholder: "Greptile organization API key saved",
                saveButtonTitle: "Save and Validate API Key",
                setupMessage: "Create an organization API key in Greptile Settings. "
                    + "CodexBar uses it only for read-only review-usage requests and never triggers reviews.",
                setupLinkTitle: "Open Greptile API Key Settings",
                setupURL: URL(string: "https://app.greptile.com/settings/api"),
                securityMessage: "CodexBar stores this credential only in Keychain. "
                    + "When Greptile omits review allowance data, CodexBar leaves quota usage unknown."
            )
        }

        return ProviderCredentialPresentation(
            sectionTitle: "Credential",
            unsavedPlaceholder: "Paste credential",
            savedPlaceholder: "Credential saved",
            saveButtonTitle: "Save Credential",
            setupMessage: nil,
            setupLinkTitle: nil,
            setupURL: nil,
            securityMessage: nil
        )
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

    var hasOtherCodexAccounts: Bool {
        configurationStore.configurations(for: .codex).contains { $0.id != configuration.id }
    }

    var codexSignInButtonTitle: String {
        if configurationStore.hasSecret(for: configuration) {
            return "Sign in Again"
        }
        return hasOtherCodexAccounts
            ? "Connect a Different ChatGPT Account"
            : "Sign in with ChatGPT"
    }

    var availableMetrics: [ProviderUsageMetric] {
        usageResult?.availableMetrics ?? []
    }

    var canRefreshMetrics: Bool {
        configuration.isEnabled && configurationStore.isConfigured(configuration)
    }

    var metricsEmptyStateMessage: String {
        configuration.isEnabled
            ? "No metrics discovered yet. Refresh this account to load its dashboard metrics."
            : "Enable this account to discover its dashboard metrics."
    }

    func isMetricVisible(_ metricID: String) -> Bool {
        configurationStore.isMetricVisible(accountID: accountID, metricID: metricID)
    }

    func setMetricVisibility(_ isVisible: Bool, metricID: String) {
        configurationStore.updateMetricVisibility(
            isVisible,
            accountID: accountID,
            metricID: metricID
        )
    }

    func synchronizeUsageResult(_ result: ProviderUsageResult?) {
        guard !isCredentialRefreshPending else { return }
        guard let result else {
            usageResult = nil
            return
        }
        acceptUsageResult(result)
    }

    func refreshMetrics() async {
        await refreshMetrics(allowUnconfiguredAccount: false, requiresFreshRequest: false)
    }

    private func refreshMetrics(
        allowUnconfiguredAccount: Bool,
        requiresFreshRequest: Bool
    ) async {
        if isLoadingMetrics {
            if allowUnconfiguredAccount {
                needsCredentialMetricsRefresh = true
            }
            return
        }

        let credentialRevision = metricsCredentialRevision
        guard
            configuration.isEnabled,
            allowUnconfiguredAccount || canRefreshMetrics
        else {
            if requiresFreshRequest {
                completeCredentialRefresh(revision: credentialRevision)
            }
            return
        }

        flushPendingChanges()
        isLoadingMetrics = true
        let result = requiresFreshRequest
            ? await onCredentialRefresh(configuration)
            : await onAccountRefresh(configuration)
        isLoadingMetrics = false

        if needsCredentialMetricsRefresh {
            needsCredentialMetricsRefresh = false
            await refreshMetrics(allowUnconfiguredAccount: true, requiresFreshRequest: true)
            return
        }

        if requiresFreshRequest {
            completeCredentialRefresh(revision: credentialRevision)
        }
        guard credentialRevision == metricsCredentialRevision else { return }
        guard let result else {
            if requiresFreshRequest, providerID == .greptile, showsGreptileValidationFeedback {
                credentialMessage = "API key saved in Keychain. Greptile validation did not complete; refresh to try again."
            }
            return
        }
        acceptUsageResult(result)
        if showsGreptileValidationFeedback {
            updateGreptileCredentialFeedback(with: result)
            if result.failureMessage == nil {
                showsGreptileValidationFeedback = false
            }
        }
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
        await loadMetricsIfNeeded()
    }

    func cancelAuthentication() {
        codexSignInTask?.cancel()
        codexAuthPresenter.finish()
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
        credentialError = nil
        credentialMessage = nil
        showsGreptileValidationFeedback = false
        guard persist(configuration) else {
            credentialError = configurationStore.lastError
            return
        }
        guard persistSecret(secret) else {
            credentialError = configurationStore.lastError
            return
        }
        secret = ""
        if providerID == .greptile {
            showsGreptileValidationFeedback = true
            credentialMessage = configuration.isEnabled
                ? "API key saved in Keychain. Validating with Greptile..."
                : "API key saved in Keychain. Enable this account to validate it with Greptile."
        }
        credentialsDidChange()
    }

    func removeSavedCredential(message: String? = nil) {
        credentialError = nil
        credentialMessage = nil
        showsGreptileValidationFeedback = false
        flushPendingChanges()
        guard persistSecret("") else {
            credentialError = configurationStore.lastError
            return
        }
        openCodeCredentialMessage = message
        credentialsDidChange()
    }

    func startCodexSignIn() {
        guard codexSignInTask == nil else { return }
        codexSignInTask = Task { @MainActor in
            await self.signInWithCodex()
        }
    }

    func signInWithCodex() async {
        isSigningInWithCodex = true
        credentialError = nil
        codexAuthError = nil
        defer {
            codexAuthPresenter.finish()
            codexSignInTask = nil
            isSigningInWithCodex = false
        }

        do {
            let result = try await codexAuthService.signIn { url in
                self.codexAuthPresenter.present(url: url) {
                    self.codexSignInTask?.cancel()
                }
            }

            switch configurationStore.validateCodexAccountIdentity(
                result.accountID,
                for: configuration
            ) {
            case .available:
                break
            case .duplicate(let accountName):
                codexAuthError = "That ChatGPT account is already connected as “\(accountName)”. No saved account was changed. Cancel or try again with a different identity."
                return
            case .unableToVerify:
                codexAuthError = "ChatGPT sign-in completed, but CodexBar could not safely verify it against the "
                    + "other saved ChatGPT accounts. No saved account was changed. Try again."
                return
            }

            var updated = configuration
            updated.authMethod = .browserSession
            guard persistCredential(result.storedCredential, with: updated) else {
                codexAuthError = configurationStore.lastError
                return
            }
            credentialsDidChange()
        } catch {
            codexAuthError = error is CancellationError || Task.isCancelled
                ? "ChatGPT sign-in canceled. Saved accounts were not changed."
                : error.localizedDescription
        }
    }

    func signInWithCopilot() async {
        isSigningInWithCopilot = true
        credentialError = nil
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
            guard persistCredential(
                result.storedCredential(username: username),
                with: updated
            ) else {
                copilotAuthError = configurationStore.lastError
                authURL = nil
                return
            }
            secret = ""
            credentialsDidChange()
            authURL = nil
        } catch {
            copilotAuthError = error.localizedDescription
            authURL = nil
        }
    }

    func signInWithClaude() async {
        isSigningInWithClaude = true
        credentialError = nil
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
            guard persistCredential(result.storedCredential, with: updated) else {
                claudeAuthError = configurationStore.lastError
                claudeAuthDiagnostic = "Claude sign-in failed."
                authURL = nil
                return
            }
            secret = ""
            credentialsDidChange()
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
        credentialError = nil
        cursorAuthError = nil
        flushPendingChanges()
        guard let disconnected = configurationStore.disconnectCursorAccount(configuration) else {
            cursorAuthError = configurationStore.lastError
            return
        }
        configuration = disconnected
        credentialsDidChange()
    }

    func saveOpenCodeCredential() {
        credentialError = nil
        guard persist(configuration) else {
            openCodeCredentialMessage = configurationStore.lastError
            return
        }
        guard persistSecret(secret) else {
            openCodeCredentialMessage = configurationStore.lastError
            return
        }

        secret = ""
        openCodeCredentialMessage = configuration.openCodeWorkspaceId
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "OpenCode dashboard auth value saved. Enter the workspace ID, then refresh."
            : "OpenCode dashboard auth value saved. Refreshing..."
        credentialsDidChange(refreshMetrics: false)
        Task { await refreshOpenCode(requiresFreshRequest: true) }
    }

    func refreshOpenCode() async {
        await refreshOpenCode(requiresFreshRequest: false)
    }

    private func refreshOpenCode(requiresFreshRequest: Bool) async {
        guard !isRefreshingOpenCode else {
            return
        }
        isRefreshingOpenCode = true
        openCodeCredentialMessage = "Refreshing OpenCode Go + Zen..."
        defer { isRefreshingOpenCode = false }

        flushPendingChanges()
        let credentialRevision = metricsCredentialRevision
        let result = requiresFreshRequest
            ? await onCredentialRefresh(configuration)
            : await onAccountRefresh(configuration)
        if requiresFreshRequest {
            completeCredentialRefresh(revision: credentialRevision)
        }
        guard credentialRevision == metricsCredentialRevision else { return }
        guard let result else {
            openCodeCredentialMessage = "Refresh finished. Check the dashboard."
            return
        }
        acceptUsageResult(result)
        let usageContext = result.usageMessages.isEmpty
            ? ""
            : " \(result.usageMessages.joined(separator: " "))"
        if !result.bars.isEmpty, result.creditsRemaining != nil {
            openCodeCredentialMessage = "OpenCode Go usage and Zen balance refreshed.\(usageContext)"
        } else if !result.bars.isEmpty {
            openCodeCredentialMessage = "OpenCode Go usage refreshed.\(usageContext)"
        } else if let balance = result.creditsRemaining {
            let formatted = Self.openCodeBalanceFormatter.string(from: NSNumber(value: balance)) ?? "$\(balance)"
            openCodeCredentialMessage = "OpenCode Zen balance refreshed: \(formatted)\(usageContext)"
        } else {
            openCodeCredentialMessage = result.subtitle
        }
    }

    private func loadMetricsIfNeeded() async {
        if let usageResult {
            acceptUsageResult(usageResult)
            return
        }
        guard configurationStore.isConfigured(configuration) else {
            return
        }
        await refreshMetrics()
    }

    private func acceptUsageResult(_ result: ProviderUsageResult) {
        guard result.accountID == accountID else {
            return
        }
        usageResult = result
        configurationStore.reconcileMetricLayout(
            accountID: accountID,
            availableMetricIDs: result.availableMetrics.map(\.id)
        )
    }

    private func updateGreptileCredentialFeedback(with result: ProviderUsageResult) {
        guard providerID == .greptile else {
            return
        }
        if let failureMessage = result.failureMessage {
            if result.recoveryAction == .reauthenticate || result.recoveryAction == .signIn {
                credentialMessage = nil
                credentialError = "API key saved in Keychain, but Greptile validation failed. \(failureMessage)"
            } else {
                credentialError = nil
                credentialMessage = "API key saved in Keychain. Greptile could not validate it right now. \(failureMessage)"
            }
        } else {
            credentialError = nil
            credentialMessage = Self.greptileValidatedMessage
        }
    }

    func saveCopilotCredential() async {
        isSigningInWithCopilot = true
        credentialError = nil
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
            let credentials = CopilotCredentials(accessToken: token, username: username)
            let storedCredential = CopilotCredentialsParser.storedCredential(from: credentials)
            guard persistCredential(storedCredential, with: updated) else {
                copilotAuthError = configurationStore.lastError
                return
            }
            secret = ""
            credentialsDidChange()
        } catch {
            copilotAuthError = error.localizedDescription
        }
    }

    private func signInWithCursor() async {
        isSigningInWithCursor = true
        credentialError = nil
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
            credentialsDidChange()
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

    private func credentialsDidChange(refreshMetrics: Bool = true) {
        onCredentialsChanged()
        requestCredentialMetricsRefresh(refreshMetrics: refreshMetrics)
    }

    private func requestCredentialMetricsRefresh(refreshMetrics: Bool = true) {
        usageResult = nil
        metricsCredentialRevision += 1
        isCredentialRefreshPending = true
        guard refreshMetrics else { return }
        if isLoadingMetrics {
            needsCredentialMetricsRefresh = true
            return
        }
        Task { @MainActor [weak self] in
            await self?.refreshMetrics(allowUnconfiguredAccount: true, requiresFreshRequest: true)
        }
    }

    private func completeCredentialRefresh(revision: Int) {
        guard revision == metricsCredentialRevision else { return }
        isCredentialRefreshPending = false
    }

    private func updateConfiguration(
        _ updated: ProviderAccountConfiguration,
        persistence: PersistenceBehavior
    ) {
        let shouldValidateSavedGreptileCredential = providerID == .greptile
            && !configuration.isEnabled
            && updated.isEnabled
            && showsGreptileValidationFeedback
        let didChangeRefreshInputs = refreshInputsChanged(from: configuration, to: updated)
        configuration = updated
        if didChangeRefreshInputs {
            onRefreshInputsChanged()
        }
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
        if shouldValidateSavedGreptileCredential {
            credentialError = nil
            credentialMessage = "API key saved in Keychain. Validating with Greptile..."
            requestCredentialMetricsRefresh()
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

    private func persistSecret(_ secret: String) -> Bool {
        configurationStore.saveSecret(secret, for: configuration)
    }

    private func persistCredential(
        _ credential: String,
        with updated: ProviderAccountConfiguration
    ) -> Bool {
        flushPendingChanges()
        guard configurationStore.replaceCredential(credential, for: updated) else {
            return false
        }
        configuration = configurationStore.configuration(accountID: updated.id) ?? updated
        return true
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

    private func refreshInputsChanged(
        from current: ProviderAccountConfiguration,
        to updated: ProviderAccountConfiguration
    ) -> Bool {
        current.isEnabled != updated.isEnabled
            || current.authMethod != updated.authMethod
            || current.oauthClientID != updated.oauthClientID
            || current.copilotAccountScope != updated.copilotAccountScope
            || current.githubOrganization != updated.githubOrganization
            || current.githubEnterprise != updated.githubEnterprise
            || current.copilotTotalAllotment != updated.copilotTotalAllotment
            || current.openCodeWorkspaceId != updated.openCodeWorkspaceId
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
