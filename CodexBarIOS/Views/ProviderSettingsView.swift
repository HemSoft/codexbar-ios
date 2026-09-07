import SwiftUI
import SafariServices

struct ProviderSettingsView: View {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    @StateObject private var viewModel: ProviderSettingsViewModel
    private let latestUsageResult: ProviderUsageResult?
    @State private var pendingGeminiConfirmation: GeminiConfirmation?
    @State private var isConfirmingGoogleAccount = false

    private enum GeminiConfirmation {
        case codingImport
        case legacyLink(ProviderAccountConfiguration)
        case appsReconnect
    }

    init(
        configurationStore: ProviderConfigurationStore,
        accountID: String,
        initialUsageResult: ProviderUsageResult? = nil,
        onCredentialsChanged: @escaping @MainActor () -> Void = {},
        onRefreshInputsChanged: @escaping @MainActor () -> Void = {},
        onAccountRefresh: @escaping @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult? = { _ in nil },
        onCredentialRefresh: (@MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult?)? = nil
    ) {
        self.configurationStore = configurationStore
        self.latestUsageResult = initialUsageResult
        self._viewModel = StateObject(
            wrappedValue: ProviderSettingsViewModel(
                configurationStore: configurationStore,
                accountID: accountID,
                initialUsageResult: initialUsageResult,
                onCredentialsChanged: onCredentialsChanged,
                onRefreshInputsChanged: onRefreshInputsChanged,
                onAccountRefresh: onAccountRefresh,
                onCredentialRefresh: onCredentialRefresh
            )
        )
    }

    var body: some View {
        let configuration = viewModel.configuration

        Form {
            Section {
                Toggle("Enabled", isOn: viewModel.binding(for: \.isEnabled))
                Toggle("Show History", isOn: viewModel.binding(for: \.showsHistory))

                TextField(
                    "Account label",
                    text: viewModel.binding(for: \.accountLabel, persistence: .debounced)
                )
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                .accessibilityIdentifier("account-label")

                Picker("Group", selection: viewModel.binding(for: \.groupID)) {
                    Text(ProviderAccountGroup.ungroupedDisplayName).tag(Optional<String>.none)
                    ForEach(configurationStore.groups) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }

                .accessibilityIdentifier("account-group-picker")
                .accessibilityValue(configurationStore.groupName(for: configuration.groupID))

                Picker("Auth method", selection: viewModel.binding(for: \.authMethod)) {
                    ForEach(availableAuthMethods) { method in
                        Text(authMethodDisplayName(method)).tag(method)
                    }
                }

                if providerID == .copilot {
                    Picker("Account type", selection: viewModel.binding(for: \.copilotAccountScope)) {
                        ForEach(CopilotAccountScope.allCases) { scope in
                            Text(scope.displayName).tag(scope)
                        }
                    }
                    .pickerStyle(.segmented)

                    if configuration.copilotAccountScope == .organization {
                        TextField(
                            "Organization",
                            text: viewModel.binding(for: \.githubOrganization, persistence: .debounced)
                        )
                            .textContentType(.organizationName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        TextField(
                            "Enterprise (optional)",
                            text: viewModel.binding(for: \.githubEnterprise, persistence: .debounced)
                        )
                            .textContentType(.organizationName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        TextField("Total allotment (optional)", text: viewModel.copilotAllotmentBinding)
                            .keyboardType(.decimalPad)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                } else if providerID == .openCodeZen {
                    TextField(
                        "Workspace ID",
                        text: viewModel.binding(for: \.openCodeWorkspaceId, persistence: .debounced)
                    )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }

            Section {
                if providerID == .codex {
                    Button {
                        viewModel.startCodexSignIn()
                    } label: {
                        if viewModel.isSigningInWithCodex {
                            ProgressView()
                        } else {
                            Text(viewModel.codexSignInButtonTitle)
                        }
                    }
                    .disabled(viewModel.isSigningInWithCodex)

                    Text(
                        viewModel.hasOtherCodexAccounts
                            ? "A private sign-in session keeps the active Safari account from being reused. "
                                + "Choose the distinct ChatGPT identity you want this Codex entry to track."
                            : "ChatGPT sign-in opens in a private browser session so you can choose the intended identity."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    if configurationStore.hasSecret(for: configuration) {
                        Button("Sign Out", role: .destructive) {
                            viewModel.removeSavedCredential()
                        }
                    }

                    if let codexAuthError = viewModel.codexAuthError {
                        Text(codexAuthError)
                            .foregroundStyle(.red)
                    }
                } else if providerID == .copilot {
                    Button {
                        Task {
                            await viewModel.signInWithCopilot()
                        }
                    } label: {
                        if viewModel.isSigningInWithCopilot {
                            ProgressView()
                        } else {
                            Text(configurationStore.hasSecret(for: configuration) ? "Sign in Again" : "Sign in with GitHub")
                        }
                    }
                    .disabled(viewModel.isSigningInWithCopilot)

                    if configuration.authMethod == .cliToken {
                        SecureField(copilotSecretPlaceholder, text: $viewModel.secret)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                        Button {
                            Task {
                                await viewModel.saveCopilotCredential()
                            }
                        } label: {
                            if viewModel.isSigningInWithCopilot {
                                ProgressView()
                            } else {
                                Text(configurationStore.hasSecret(for: configuration) ? "Update Token" : "Save Token")
                            }
                        }
                        .disabled(viewModel.isSigningInWithCopilot || viewModel.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if configurationStore.hasSecret(for: configuration) {
                        Button("Sign Out", role: .destructive) {
                            viewModel.removeSavedCredential()
                        }
                    }

                    if let copilotAuthError = viewModel.copilotAuthError {
                        Text(copilotAuthError)
                            .foregroundStyle(.red)
                    }
                } else if providerID == .claude {
                    Button {
                        Task {
                            await viewModel.signInWithClaude()
                        }
                    } label: {
                        if viewModel.isSigningInWithClaude {
                            ProgressView()
                        } else {
                            Text(configurationStore.hasSecret(for: configuration) ? "Sign in Again" : "Sign in with Claude")
                        }
                    }
                    .disabled(viewModel.isSigningInWithClaude)

                    if let claudeAuthDiagnostic = viewModel.claudeAuthDiagnostic {
                        Text(claudeAuthDiagnostic)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }

                    if configurationStore.hasSecret(for: configuration) {
                        Button("Sign Out", role: .destructive) {
                            viewModel.removeSavedCredential()
                        }
                    }

                    if let claudeAuthError = viewModel.claudeAuthError {
                        Text(claudeAuthError)
                            .foregroundStyle(.red)
                    }
                } else if providerID == .cursor {
                    Button {
                        viewModel.startCursorSignIn()
                    } label: {
                        if viewModel.isSigningInWithCursor {
                            ProgressView()
                        } else {
                            Text(configurationStore.hasSecret(for: configuration) ? "Switch Cursor Account" : "Sign in with Cursor")
                        }
                    }
                    .disabled(viewModel.isSigningInWithCursor)

                    if configurationStore.hasSecret(for: configuration) {
                        Button("Sign Out", role: .destructive) {
                            viewModel.signOutOfCursor()
                        }
                    }

                    if let cursorAuthError = viewModel.cursorAuthError {
                        Text(cursorAuthError)
                            .foregroundStyle(.red)
                    }
                } else if providerID == .gemini {
                    geminiAppsConnection
                } else if providerID == .openCodeZen {
                    SecureField(secretPlaceholder, text: $viewModel.secret)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button(configurationStore.hasSecret(for: configuration) ? "Update and Refresh" : "Save and Refresh") {
                        viewModel.saveOpenCodeCredential()
                    }
                    .disabled(
                        viewModel.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || viewModel.isRefreshingOpenCode
                    )

                    if configurationStore.hasSecret(for: configuration) {
                        Button {
                            Task {
                                await viewModel.refreshOpenCode()
                            }
                        } label: {
                            if viewModel.isRefreshingOpenCode {
                                ProgressView()
                            } else {
                                Label("Refresh Now", systemImage: "arrow.clockwise")
                            }
                        }
                        .disabled(viewModel.isRefreshingOpenCode)
                    }

                    if configurationStore.hasSecret(for: configuration) {
                        Button("Remove Saved Credential", role: .destructive) {
                            viewModel.removeSavedCredential(message: "OpenCode dashboard session removed.")
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            "Enter the OpenCode workspace ID and dashboard auth value to track Zen balance and Go usage.",
                            systemImage: "key"
                        )
                        Label("You can paste the Windows settings JSON or OPENCODE_GO_AUTH_COOKIE value.", systemImage: "checkmark.circle")
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    if let openCodeCredentialMessage = viewModel.openCodeCredentialMessage {
                        Text(openCodeCredentialMessage)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } else if configuration.requiresSecret {
                    SecureField(secretPlaceholder, text: $viewModel.secret)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button(viewModel.credentialPresentation.saveButtonTitle) {
                        viewModel.saveGenericCredential()
                    }
                    .disabled(viewModel.secret.isEmpty)

                    if configurationStore.hasSecret(for: configuration) {
                        Button("Remove Saved Credential", role: .destructive) {
                            viewModel.removeSavedCredential()
                        }
                    }

                    if let setupMessage = viewModel.credentialPresentation.setupMessage {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(setupMessage, systemImage: "key")

                            if
                                let setupLinkTitle = viewModel.credentialPresentation.setupLinkTitle,
                                let setupURL = viewModel.credentialPresentation.setupURL {
                                Link(setupLinkTitle, destination: setupURL)
                            }

                            if let securityMessage = viewModel.credentialPresentation.securityMessage {
                                Label(securityMessage, systemImage: "lock.shield")
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                } else {
                    Text(nonSecretAuthText)
                        .foregroundStyle(.secondary)
                }

                if let credentialError = viewModel.credentialError {
                    Text(credentialError)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("credential-error")
                } else if let credentialMessage = viewModel.credentialMessage {
                    Label(credentialMessage, systemImage: viewModel.credentialMessageSystemImage)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("credential-message")
                }
            } header: {
                Text(viewModel.credentialPresentation.sectionTitle)
            }

            if providerID == .gemini {
                geminiCodingConnection
            }

            Section {
                if let description = GoogleUsageMetricCatalog.setupDescription(for: providerID) {
                    Text(description)
                        .font(.subheadline)
                        .accessibilityIdentifier("google-quota-source-guide")
                }
                if viewModel.isLoadingMetrics {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading discovered metrics…")
                            .foregroundStyle(.secondary)
                    }
                } else if viewModel.availableMetrics.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(viewModel.metricsEmptyStateMessage)
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier("account-metrics-empty-state")

                        Button {
                            Task {
                                await viewModel.refreshMetrics()
                            }
                        } label: {
                            Label("Refresh Metrics", systemImage: "arrow.clockwise")
                        }
                        .disabled(!viewModel.canRefreshMetrics)
                    }
                } else {
                    ForEach(viewModel.availableMetrics) { metric in
                        let accessibilityStatus = if case let .unavailableUsage(reason) = metric.kind {
                            ". \(reason)"
                        } else {
                            ""
                        }
                        Toggle(isOn: Binding(
                                get: { viewModel.isMetricVisible(metric.id) },
                                set: { viewModel.setMetricVisibility($0, metricID: metric.id) }
                        )) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(metric.label)
                                if case let .unavailableUsage(reason) = metric.kind {
                                    Text(reason).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .accessibilityLabel("Show \(metric.label) on dashboard\(accessibilityStatus)")
                        .accessibilityIdentifier("account-metric-visibility-\(metric.id)")
                    }
                }
            } header: {
                Text("Metrics")
            } footer: {
                if !viewModel.availableMetrics.isEmpty {
                    Text("Changes apply immediately and stay in sync with Customize Card.")
                }
            }

            Section {
                Text(configurationStore.statusText(for: configuration))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Current Status")
            }
        }
        .accessibilityIdentifier("provider-account-settings-form")
        .navigationTitle(configuration.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await viewModel.prepare()
        }
        .onChange(of: latestUsageResult) { _, result in
            viewModel.synchronizeUsageResult(result)
        }
        .onDisappear {
            viewModel.flushPendingChanges()
            viewModel.cancelAuthentication()
        }
        .sheet(item: $viewModel.geminiBrowserSession) { session in
            GeminiBrowserSignInView(session: session)
        }
        .sheet(item: $viewModel.authURL) { authURL in
            SafariAuthSheet(url: authURL.url)
        }
        .alert("Confirm Google Account", isPresented: $isConfirmingGoogleAccount) {
            Button("Same Google Account") { confirmGeminiAction() }
            Button("Cancel", role: .cancel) { pendingGeminiConfirmation = nil }
        } message: {
            Text(geminiConfirmationMessage)
        }
    }

    private var geminiAppsConnection: some View {
        Group {
            Button(configurationStore.hasSecret(for: viewModel.configuration) ? "Sign in Again with Google" : "Sign in with Google") {
                if configurationStore.hasGeminiCodingSecret(for: viewModel.configuration) {
                    requestGeminiConfirmation(.appsReconnect)
                } else {
                    viewModel.startGeminiSignIn()
                }
            }
            .disabled(viewModel.isSigningInWithGemini)
            if viewModel.isSigningInWithGemini {
                ProgressView("Connecting Gemini Apps")
                Button("Cancel Sign-In") { viewModel.cancelGeminiSignIn() }
            }
            Text("Connect Gemini Apps in a private Google sign-in window to read its five-hour and weekly limits.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text("Google session credentials may grant broader account access. "
                + "CodexBar saves only the session values needed for usage in this account's Keychain entry.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if configurationStore.hasSecret(for: viewModel.configuration) {
                Button("Disconnect Gemini Apps", role: .destructive) {
                    viewModel.removeSavedCredential()
                }
            }
        }
    }

    private var geminiCodingConnection: some View {
        Section("Coding Usage") {
            Text("Connect Gemini Models and Other models, Claude/GPT, to show their four coding limits in this Gemini account.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            SecureField("Paste coding session JSON", text: $viewModel.geminiCodingSecret)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityIdentifier("gemini-coding-session")
            Button(configurationStore.hasGeminiCodingSecret(for: viewModel.configuration) ? "Update Coding Session" : "Connect Coding Session") {
                requestGeminiConfirmation(.codingImport)
            }
            .disabled(viewModel.geminiCodingSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Text("Import session JSON from your signed-in Antigravity desktop. "
                + "Coding access uses its own OAuth token, separate from Gemini Apps' website session. "
                + "Without renewal credentials, import again when the token expires.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Link("Coding session import instructions", destination: URL(
                string: "https://github.com/HemSoft/codexbar-ios/blob/main/ANTIGRAVITY-SETUP.md"
            )!)
            Text("Session tokens may grant broader Google account access. "
                + "CodexBar keeps coding credentials in a separate Keychain entry for this Gemini account.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if configurationStore.hasGeminiCodingSecret(for: viewModel.configuration) {
                Button("Disconnect Coding Session", role: .destructive) {
                    viewModel.disconnectGeminiCoding()
                }
            }
            if !configurationStore.unlinkedGeminiCodingAccounts.isEmpty {
                Text("Previously saved coding accounts are retained until you confirm which Gemini account they belong to.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                ForEach(configurationStore.unlinkedGeminiCodingAccounts) { legacy in
                    Button("Link saved coding account: \(legacy.displayName)") {
                        requestGeminiConfirmation(.legacyLink(legacy))
                    }
                    .accessibilityIdentifier("gemini-link-coding-\(legacy.id)")
                }
            }
            if let message = viewModel.geminiCodingMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("gemini-coding-message")
            }
        }
    }

    private var geminiConfirmationMessage: String {
        switch pendingGeminiConfirmation {
        case .appsReconnect:
            "Sign in to the same Google account as the coding session already linked to \(viewModel.configuration.displayName). "
                + "To use a different Google identity, add another Gemini account."
        case .legacyLink(let legacy):
            "Confirm that the saved coding account \(legacy.displayName) and \(viewModel.configuration.displayName) "
                + "belong to the same Google account. CodexBar cannot verify this identity automatically."
        case .codingImport, nil:
            "Confirm that this coding session and \(viewModel.configuration.displayName) belong to the same Google account. "
                + "CodexBar cannot verify this identity automatically."
        }
    }

    private func requestGeminiConfirmation(_ confirmation: GeminiConfirmation) {
        pendingGeminiConfirmation = confirmation
        isConfirmingGoogleAccount = true
    }

    private func confirmGeminiAction() {
        switch pendingGeminiConfirmation {
        case .codingImport:
            viewModel.saveGeminiCodingCredential(confirmedSameAccount: true)
        case .legacyLink(let legacy):
            viewModel.linkGeminiCodingAccount(legacy, confirmedSameAccount: true)
        case .appsReconnect:
            viewModel.startGeminiSignIn(confirmedSameAccount: true)
        case nil:
            break
        }
        pendingGeminiConfirmation = nil
    }

    private var secretPlaceholder: String {
        if providerID == .openCodeZen {
            return configurationStore.hasSecret(for: viewModel.configuration)
                ? "OpenCode dashboard auth value saved"
                : "Paste OpenCode dashboard auth value"
        }

        let presentation = viewModel.credentialPresentation
        return configurationStore.hasSecret(for: viewModel.configuration)
            ? presentation.savedPlaceholder
            : presentation.unsavedPlaceholder
    }

    private var copilotSecretPlaceholder: String {
        configurationStore.hasSecret(for: viewModel.configuration)
            ? "GitHub token saved"
            : "Paste GitHub token"
    }

    private var providerID: ProviderID {
        viewModel.providerID
    }

    private var availableAuthMethods: [ProviderAuthMethod] {
        viewModel.availableAuthMethods
    }

    private func authMethodDisplayName(_ method: ProviderAuthMethod) -> String {
        if providerID == .openCodeZen, method == .apiKey {
            return "Dashboard Session"
        }
        return method.displayName
    }

    private var nonSecretAuthText: String {
        switch viewModel.configuration.authMethod {
        case .browserSession:
            "Sign in through the browser to connect this account."
        case .apiKey, .cliToken:
            "Paste a credential to save it in Keychain."
        }
    }

}

struct PresentedAuthURL: Identifiable {
    let id = UUID()
    let url: URL

    init(url: URL) {
        self.url = url
    }
}

struct SafariAuthSheet: View {
    let url: URL

    var body: some View {
        SafariAuthView(url: url)
    }
}

struct SafariAuthView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {
    }
}

#Preview {
    NavigationStack {
        ProviderSettingsView(configurationStore: ProviderConfigurationStore(), accountID: ProviderID.openRouter.rawValue)
    }
}
