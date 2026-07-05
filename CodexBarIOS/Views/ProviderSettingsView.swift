import SwiftUI
import SafariServices

struct ProviderSettingsView: View {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    let accountID: String
    var onCredentialsChanged: @MainActor () -> Void = {}
    var onAccountRefresh: @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult? = { _ in nil }

    @State private var configuration: ProviderAccountConfiguration
    @State private var secret = ""
    @State private var isSigningInWithCodex = false
    @State private var isSigningInWithCopilot = false
    @State private var isSigningInWithClaude = false
    @State private var isSigningInWithCursor = false
    @State private var debugAutostartedCopilotAuth = false
    @State private var codexAuthError: String?
    @State private var copilotAuthError: String?
    @State private var claudeAuthError: String?
    @State private var claudeAuthDiagnostic: String?
    @State private var cursorAuthError: String?
    @State private var authURL: PresentedAuthURL?
    @State private var copilotTotalAllotmentText = ""
    @State private var openCodeCredentialMessage: String?
    @State private var isRefreshingOpenCode = false

    private let codexAuthService = CodexWebAuthService()
    private let copilotAuthService = CopilotWebAuthService()
    private let claudeAuthService = ClaudeWebAuthService()
    private let cursorAuthService = CursorWebAuthService()
    private let copilotUsageProvider = CopilotUsageProvider()

    init(
        configurationStore: ProviderConfigurationStore,
        accountID: String,
        onCredentialsChanged: @escaping @MainActor () -> Void = {},
        onAccountRefresh: @escaping @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult? = { _ in nil }
    ) {
        self.configurationStore = configurationStore
        self.accountID = accountID
        self.onCredentialsChanged = onCredentialsChanged
        self.onAccountRefresh = onAccountRefresh
        self._configuration = State(
            initialValue: configurationStore.configuration(accountID: accountID)
                ?? ProviderID(rawValue: accountID).map(ProviderAccountConfiguration.defaultConfiguration)
                ?? .defaultConfiguration(for: .codex)
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $configuration.isEnabled)

                TextField("Account label", text: $configuration.accountLabel)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Picker("Group", selection: $configuration.groupID) {
                    Text(ProviderAccountGroup.ungroupedDisplayName).tag(Optional<String>.none)
                    ForEach(configurationStore.groups) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }

                Picker("Auth method", selection: $configuration.authMethod) {
                    ForEach(availableAuthMethods) { method in
                        Text(authMethodDisplayName(method)).tag(method)
                    }
                }

                if providerID == .copilot {
                    Picker("Account type", selection: $configuration.copilotAccountScope) {
                        ForEach(CopilotAccountScope.allCases) { scope in
                            Text(scope.displayName).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)

                    if configuration.copilotAccountScope == .organization {
                        TextField("Organization", text: $configuration.githubOrganization)
                            .textContentType(.organizationName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        TextField("Enterprise (optional)", text: $configuration.githubEnterprise)
                            .textContentType(.organizationName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        TextField("Total allotment (optional)", text: $copilotTotalAllotmentText)
                            .keyboardType(.decimalPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onChange(of: copilotTotalAllotmentText) { _, newValue in
                                configuration.copilotTotalAllotment = parsedAllotment(newValue)
                            }
                    }
                } else if providerID == .openCodeZen {
                    TextField("Workspace ID", text: $configuration.openCodeWorkspaceId)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            Section {
                if providerID == .codex {
                    Button {
                        Task {
                            await signInWithCodex()
                        }
                    } label: {
                        if isSigningInWithCodex {
                            ProgressView()
                        } else {
                            Text(configurationStore.hasSecret(for: configuration) ? "Sign in Again" : "Sign in with ChatGPT")
                        }
                    }
                    .disabled(isSigningInWithCodex)

                    if configurationStore.hasSecret(for: configuration) {
                        Button("Sign Out", role: .destructive) {
                            configurationStore.saveSecret("", for: configuration)
                            onCredentialsChanged()
                        }
                    }

                    if let codexAuthError {
                        Text(codexAuthError)
                            .foregroundStyle(.red)
                    }
                } else if providerID == .copilot {
                    Button {
                        Task {
                            await signInWithCopilot()
                        }
                    } label: {
                        if isSigningInWithCopilot {
                            ProgressView()
                        } else {
                            Text(configurationStore.hasSecret(for: configuration) ? "Sign in Again" : "Sign in with GitHub")
                        }
                    }
                    .disabled(isSigningInWithCopilot)

                    if configuration.authMethod == .cliToken {
                        SecureField(copilotSecretPlaceholder, text: $secret)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Button {
                            Task {
                                await saveCopilotCredential()
                            }
                        } label: {
                            if isSigningInWithCopilot {
                                ProgressView()
                            } else {
                                Text(configurationStore.hasSecret(for: configuration) ? "Update Token" : "Save Token")
                            }
                        }
                        .disabled(isSigningInWithCopilot || secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if configurationStore.hasSecret(for: configuration) {
                        Button("Sign Out", role: .destructive) {
                            configurationStore.saveSecret("", for: configuration)
                            onCredentialsChanged()
                        }
                    }

                    if let copilotAuthError {
                        Text(copilotAuthError)
                            .foregroundStyle(.red)
                    }
                } else if providerID == .claude {
                    Button {
                        Task {
                            await signInWithClaude()
                        }
                    } label: {
                        if isSigningInWithClaude {
                            ProgressView()
                        } else {
                            Text(configurationStore.hasSecret(for: configuration) ? "Sign in Again" : "Sign in with Claude")
                        }
                    }
                    .disabled(isSigningInWithClaude)

                    if let claudeAuthDiagnostic {
                        Text(claudeAuthDiagnostic)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if configurationStore.hasSecret(for: configuration) {
                        Button("Sign Out", role: .destructive) {
                            configurationStore.saveSecret("", for: configuration)
                            onCredentialsChanged()
                        }
                    }

                    if let claudeAuthError {
                        Text(claudeAuthError)
                            .foregroundStyle(.red)
                    }
                } else if providerID == .cursor {
                    Button {
                        Task {
                            await signInWithCursor()
                        }
                    } label: {
                        if isSigningInWithCursor {
                            ProgressView()
                        } else {
                            Text(configurationStore.hasSecret(for: configuration) ? "Sign in Again" : "Sign in with Cursor")
                        }
                    }
                    .disabled(isSigningInWithCursor)

                    if configurationStore.hasSecret(for: configuration) {
                        Button("Sign Out", role: .destructive) {
                            configurationStore.saveSecret("", for: configuration)
                            onCredentialsChanged()
                        }
                    }

                    if let cursorAuthError {
                        Text(cursorAuthError)
                            .foregroundStyle(.red)
                    }
                } else if providerID == .openCodeZen {
                    SecureField(secretPlaceholder, text: $secret)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button(configurationStore.hasSecret(for: configuration) ? "Update and Refresh" : "Save and Refresh") {
                        saveOpenCodeCredential()
                    }
                    .disabled(secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if configurationStore.hasSecret(for: configuration) {
                        Button {
                            Task {
                                await refreshOpenCode()
                            }
                        } label: {
                            if isRefreshingOpenCode {
                                ProgressView()
                            } else {
                                Label("Refresh Now", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(isRefreshingOpenCode)
                    }

                    if configurationStore.hasSecret(for: configuration) {
                        Button("Remove Saved Credential", role: .destructive) {
                            configurationStore.saveSecret("", for: configuration)
                            openCodeCredentialMessage = "OpenCode credential removed."
                            onCredentialsChanged()
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Enter the OpenCode workspace ID and dashboard auth value.", systemImage: "key")
                        Label("You can paste the Windows settings JSON or OPENCODE_GO_AUTH_COOKIE value.", systemImage: "checkmark.circle")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    if let openCodeCredentialMessage {
                        Text(openCodeCredentialMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if configuration.requiresSecret {
                    SecureField(secretPlaceholder, text: $secret)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("Save Credential") {
                        configurationStore.saveSecret(secret, for: configuration)
                        secret = ""
                        onCredentialsChanged()
                    }
                    .disabled(secret.isEmpty)

                    if configurationStore.hasSecret(for: configuration) {
                        Button("Remove Saved Credential", role: .destructive) {
                            configurationStore.saveSecret("", for: configuration)
                            onCredentialsChanged()
                        }
                    }
                } else {
                    Text(nonSecretAuthText)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Credential")
            }

            Section {
                Text(configurationStore.statusText(for: configuration))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Current Status")
            }
        }
        .navigationTitle(configuration.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: configuration) { _, newValue in
            configurationStore.update(newValue)
        }
        .onAppear {
            configuration = normalizedConfiguration(
                configurationStore.configuration(accountID: accountID) ?? configuration
            )
            copilotTotalAllotmentText = allotmentText(configuration.copilotTotalAllotment)
            configurationStore.update(configuration)
            configurationStore.refreshSecretAvailability()
        }
        .task {
            await debugAutostartCopilotAuthIfNeeded()
        }
        .sheet(item: $authURL) { authURL in
            SafariAuthSheet(authURL: authURL)
        }
    }

    private var secretPlaceholder: String {
        if providerID == .openCodeZen {
            return configurationStore.hasSecret(for: configuration)
                ? "OpenCode dashboard auth value saved"
                : "Paste OpenCode dashboard auth value"
        }

        return configurationStore.hasSecret(for: configuration)
            ? "Credential saved"
            : "Paste credential"
    }

    private var copilotSecretPlaceholder: String {
        configurationStore.hasSecret(for: configuration)
            ? "GitHub token saved"
            : "Paste GitHub token"
    }

    private var providerID: ProviderID {
        configuration.providerID
    }

    private var availableAuthMethods: [ProviderAuthMethod] {
        switch providerID {
        case .codex:
            [.browserSession]
        case .copilot:
            [.browserSession, .cliToken]
        case .openRouter, .openCodeZen:
            [.apiKey]
        case .claude:
            [.browserSession]
        case .cursor:
            [.browserSession]
        }
    }

    private func authMethodDisplayName(_ method: ProviderAuthMethod) -> String {
        return method.displayName
    }

    private var nonSecretAuthText: String {
        switch configuration.authMethod {
        case .browserSession:
            "Sign in through the browser to connect this account."
        case .codexAuthJSON:
            "Codex auth.json import is no longer used."
        case .oauth:
            "This provider will use OAuth once its sign-in flow is implemented."
        case .apiKey, .cliToken:
            "Paste a credential to save it in Keychain."
        }
    }

    private func normalizedConfiguration(_ configuration: ProviderAccountConfiguration) -> ProviderAccountConfiguration {
        var normalized = configuration
        if providerID == .codex {
            normalized.authMethod = .browserSession
        } else if providerID == .claude {
            normalized.authMethod = .browserSession
        } else if providerID == .cursor {
            normalized.authMethod = .browserSession
        }
        return normalized
    }

    private func allotmentText(_ value: Double?) -> String {
        guard let value else {
            return ""
        }

        return value.formatted(.number.grouping(.never).precision(.fractionLength(0...2)))
    }

    private func parsedAllotment(_ value: String) -> Double? {
        let normalized = value
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return nil
        }

        return Double(normalized)
    }

    @MainActor
    private func signInWithCodex() async {
        isSigningInWithCodex = true
        codexAuthError = nil

        do {
            let result = try await codexAuthService.signIn { url in
                authURL = PresentedAuthURL(url: url)
            }
            configuration.authMethod = .browserSession
            guard configurationStore.update(configuration) else {
                codexAuthError = configurationStore.lastError
                authURL = nil
                isSigningInWithCodex = false
                return
            }
            configurationStore.saveSecret(result.storedCredential, for: configuration)
            onCredentialsChanged()
            authURL = nil
        } catch {
            codexAuthError = error.localizedDescription
            authURL = nil
        }

        isSigningInWithCodex = false
    }

    @MainActor
    private func signInWithCopilot() async {
        isSigningInWithCopilot = true
        copilotAuthError = nil

        do {
            let result = try await copilotAuthService.signIn(
                configuration: .bundled
            ) { url in
                authURL = PresentedAuthURL(url: url)
            }
            let username = try await copilotUsageProvider.fetchUsername(accessToken: result.accessToken)
            guard let username, !username.isEmpty else {
                copilotAuthError = "GitHub sign-in completed, but the token could not be verified for Copilot access."
                authURL = nil
                isSigningInWithCopilot = false
                return
            }

            if configuration.copilotAccountScope == .personal {
                configuration.accountLabel = username
            } else if configuration.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                configuration.accountLabel = configuration.githubOrganization.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            configuration.authMethod = .browserSession
            guard configurationStore.update(configuration) else {
                copilotAuthError = configurationStore.lastError
                authURL = nil
                isSigningInWithCopilot = false
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

        isSigningInWithCopilot = false
    }

    @MainActor
    private func signInWithClaude() async {
        isSigningInWithClaude = true
        claudeAuthError = nil
        claudeAuthDiagnostic = nil

        do {
            let result = try await claudeAuthService.signIn(
                presentAuthorizationURL: { url in
                    authURL = PresentedAuthURL(url: url)
                },
                reportStage: { message in
                    claudeAuthDiagnostic = message
                }
            )
            configuration.authMethod = .browserSession
            guard configurationStore.update(configuration) else {
                claudeAuthError = configurationStore.lastError
                authURL = nil
                isSigningInWithClaude = false
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

        isSigningInWithClaude = false
    }

    @MainActor
    private func signInWithCursor() async {
        isSigningInWithCursor = true
        cursorAuthError = nil

        do {
            let result = try await cursorAuthService.signIn { url in
                authURL = PresentedAuthURL(url: url)
            }
            if configuration.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                configuration.accountLabel = ProviderID.cursor.displayName
            }
            configuration.authMethod = .browserSession
            guard configurationStore.update(configuration) else {
                cursorAuthError = configurationStore.lastError
                authURL = nil
                isSigningInWithCursor = false
                return
            }
            configurationStore.saveSecret(result.storedCredential, for: configuration)
            secret = ""
            onCredentialsChanged()
            authURL = nil
        } catch {
            cursorAuthError = error.localizedDescription
            authURL = nil
        }

        isSigningInWithCursor = false
    }

    @MainActor
    private func debugAutostartCopilotAuthIfNeeded() async {
        #if DEBUG
        guard
            providerID == .copilot,
            !debugAutostartedCopilotAuth,
            ProcessInfo.processInfo.environment["CODEXBAR_DEBUG_AUTOSTART_COPILOT_AUTH"] == "1"
        else {
            return
        }

        debugAutostartedCopilotAuth = true
        try? await Task.sleep(nanoseconds: 750_000_000)
        await signInWithCopilot()
        #endif
    }

    @MainActor
    private func saveOpenCodeCredential() {
        guard configurationStore.update(configuration) else {
            openCodeCredentialMessage = configurationStore.lastError
            return
        }

        configurationStore.saveSecret(secret, for: configuration)
        guard configurationStore.lastError == nil else {
            openCodeCredentialMessage = configurationStore.lastError
            return
        }

        secret = ""
        openCodeCredentialMessage = configuration.openCodeWorkspaceId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "OpenCode dashboard auth value saved. Enter the workspace ID, then refresh."
            : "OpenCode dashboard auth value saved. Refreshing..."
        Task {
            await refreshOpenCode()
        }
    }

    @MainActor
    private func refreshOpenCode() async {
        guard !isRefreshingOpenCode else {
            return
        }

        isRefreshingOpenCode = true
        openCodeCredentialMessage = "Refreshing OpenCode ZEN..."
        defer {
            isRefreshingOpenCode = false
        }

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

    @MainActor
    private func saveCopilotCredential() async {
        isSigningInWithCopilot = true
        copilotAuthError = nil
        defer {
            isSigningInWithCopilot = false
        }

        do {
            let token = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            let username = try await copilotUsageProvider.fetchUsername(accessToken: token)
            guard let username, !username.isEmpty else {
                copilotAuthError = "GitHub token could not be verified for Copilot access."
                return
            }

            if configuration.copilotAccountScope == .personal {
                configuration.accountLabel = username
            } else if configuration.accountLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                configuration.accountLabel = configuration.githubOrganization.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            configuration.authMethod = .cliToken
            guard configurationStore.update(configuration) else {
                copilotAuthError = configurationStore.lastError
                return
            }
            let credentials = CopilotCredentials(accessToken: token, username: username)
            if
                let data = try? JSONEncoder().encode(credentials),
                let storedCredential = String(data: data, encoding: .utf8)
            {
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

}

private struct PresentedAuthURL: Identifiable {
    let id = UUID()
    let url: URL

    init(url: URL) {
        self.url = url
    }
}

private struct SafariAuthSheet: View {
    let authURL: PresentedAuthURL

    var body: some View {
        SafariAuthView(url: authURL.url)
    }
}

private struct SafariAuthView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
    }
}

private extension ProviderSettingsView {
    static let openCodeBalanceFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter
    }()
}

#Preview {
    NavigationStack {
        ProviderSettingsView(configurationStore: ProviderConfigurationStore(), accountID: ProviderID.openRouter.rawValue)
    }
}
