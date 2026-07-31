import SwiftUI
import SafariServices

struct ProviderSettingsView: View {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    @StateObject private var viewModel: ProviderSettingsViewModel

    init(
        configurationStore: ProviderConfigurationStore,
        accountID: String,
        onCredentialsChanged: @escaping @MainActor () -> Void = {},
        onAccountRefresh: @escaping @MainActor (ProviderAccountConfiguration) async -> ProviderUsageResult? = { _ in nil }
    ) {
        self.configurationStore = configurationStore
        self._viewModel = StateObject(
            wrappedValue: ProviderSettingsViewModel(
                configurationStore: configurationStore,
                accountID: accountID,
                onCredentialsChanged: onCredentialsChanged,
                onAccountRefresh: onAccountRefresh
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

                Picker("Group", selection: viewModel.binding(for: \.groupID)) {
                    Text(ProviderAccountGroup.ungroupedDisplayName).tag(Optional<String>.none)
                    ForEach(configurationStore.groups) { group in
                        Text(group.name).tag(Optional(group.id))
                    }
                }

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
                } else if providerID == .openCodeZen {
                    SecureField(secretPlaceholder, text: $viewModel.secret)
                        .textContentType(.password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button(configurationStore.hasSecret(for: configuration) ? "Update and Refresh" : "Save and Refresh") {
                        viewModel.saveOpenCodeCredential()
                    }
                    .disabled(viewModel.secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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
                }
            } header: {
                Text(viewModel.credentialPresentation.sectionTitle)
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
        .task {
            await viewModel.prepare()
        }
        .onDisappear {
            viewModel.flushPendingChanges()
            viewModel.cancelAuthentication()
        }
        .sheet(item: $viewModel.authURL) { authURL in
            SafariAuthSheet(url: authURL.url)
        }
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
