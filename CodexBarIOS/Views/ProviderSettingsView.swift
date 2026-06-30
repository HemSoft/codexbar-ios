import SwiftUI
import SafariServices

struct ProviderSettingsView: View {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    let providerID: ProviderID

    @State private var configuration: ProviderAccountConfiguration
    @State private var secret = ""
    @State private var isSigningInWithCodex = false
    @State private var isSigningInWithCopilot = false
    @State private var codexAuthError: String?
    @State private var copilotAuthError: String?
    @State private var authURL: PresentedAuthURL?

    private let codexAuthService = CodexWebAuthService()
    private let copilotAuthService = CopilotWebAuthService()
    private let copilotUsageProvider = CopilotUsageProvider()

    init(configurationStore: ProviderConfigurationStore, providerID: ProviderID) {
        self.configurationStore = configurationStore
        self.providerID = providerID
        self._configuration = State(initialValue: configurationStore.configuration(for: providerID))
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enabled", isOn: $configuration.isEnabled)

                TextField("Account label", text: $configuration.accountLabel)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Picker("Auth method", selection: $configuration.authMethod) {
                    ForEach(availableAuthMethods) { method in
                        Text(method.displayName).tag(method)
                    }
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
                            Text(configurationStore.hasSecret(for: providerID) ? "Sign in Again" : "Sign in with ChatGPT")
                        }
                    }
                    .disabled(isSigningInWithCodex)

                    if configurationStore.hasSecret(for: providerID) {
                        Button("Sign Out", role: .destructive) {
                            configurationStore.saveSecret("", for: providerID)
                        }
                    }

                    if let codexAuthError {
                        Text(codexAuthError)
                            .foregroundStyle(.red)
                    }
                } else if providerID == .copilot {
                    TextField("GitHub OAuth Client ID", text: oauthClientIDBinding)
                        .textContentType(.oneTimeCode)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        Task {
                            await signInWithCopilot()
                        }
                    } label: {
                        if isSigningInWithCopilot {
                            ProgressView()
                        } else {
                            Text(configurationStore.hasSecret(for: providerID) ? "Sign in Again" : "Sign in with GitHub")
                        }
                    }
                    .disabled(isSigningInWithCopilot || normalizedOAuthClientID.isEmpty)

                    if configurationStore.hasSecret(for: providerID) {
                        Button("Sign Out", role: .destructive) {
                            configurationStore.saveSecret("", for: providerID)
                        }
                    }

                    if let copilotAuthError {
                        Text(copilotAuthError)
                            .foregroundStyle(.red)
                    }
                } else if configuration.requiresSecret {
                        SecureField(secretPlaceholder, text: $secret)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()

                    Button("Save Credential") {
                        configurationStore.saveSecret(secret, for: providerID)
                        secret = ""
                    }
                    .disabled(secret.isEmpty)

                    if configurationStore.hasSecret(for: providerID) {
                        Button("Remove Saved Credential", role: .destructive) {
                            configurationStore.saveSecret("", for: providerID)
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
                Text(configurationStore.statusText(for: providerID))
                    .foregroundStyle(.secondary)
            } header: {
                Text("Current Status")
            }
        }
        .navigationTitle(providerID.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: configuration) { _, newValue in
            configurationStore.update(newValue)
        }
        .onAppear {
            configuration = normalizedConfiguration(configurationStore.configuration(for: providerID))
            configurationStore.update(configuration)
            configurationStore.refreshSecretAvailability()
        }
        .sheet(item: $authURL) { authURL in
            SafariAuthSheet(authURL: authURL)
        }
    }

    private var secretPlaceholder: String {
        configurationStore.hasSecret(for: providerID)
            ? "Credential saved"
            : "Paste credential"
    }

    private var availableAuthMethods: [ProviderAuthMethod] {
        switch providerID {
        case .codex, .copilot:
            [.browserSession]
        case .openRouter:
            [.apiKey]
        case .claude, .cursor:
            [.browserSession, .oauth, .apiKey]
        }
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
        guard providerID == .codex || providerID == .copilot else {
            return configuration
        }

        var normalized = configuration
        normalized.authMethod = .browserSession
        return normalized
    }

    private var normalizedOAuthClientID: String {
        (configuration.oauthClientID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var oauthClientIDBinding: Binding<String> {
        Binding(
            get: { configuration.oauthClientID ?? "" },
            set: { configuration.oauthClientID = $0 }
        )
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
            configurationStore.update(configuration)
            configurationStore.saveSecret(result.storedCredential, for: providerID)
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
                clientID: normalizedOAuthClientID,
                presentAuthorizationURL: { url in
                    authURL = PresentedAuthURL(url: url, userCode: authURL?.userCode)
                },
                presentUserCode: { userCode in
                    authURL = PresentedAuthURL(url: authURL?.url ?? URL(string: "https://github.com/login/device")!, userCode: userCode)
                }
            )
            let username = try await copilotUsageProvider.fetchUsername(accessToken: result.accessToken)
            if let username, !username.isEmpty {
                configuration.accountLabel = username
            }
            configuration.authMethod = .browserSession
            configurationStore.update(configuration)
            configurationStore.saveSecret(result.storedCredential(username: username), for: providerID)
            authURL = nil
        } catch {
            copilotAuthError = error.localizedDescription
            authURL = nil
        }

        isSigningInWithCopilot = false
    }
}

private struct PresentedAuthURL: Identifiable {
    let id = UUID()
    let url: URL
    let userCode: String?

    init(url: URL, userCode: String? = nil) {
        self.url = url
        self.userCode = userCode
    }
}

private struct SafariAuthSheet: View {
    let authURL: PresentedAuthURL

    var body: some View {
        VStack(spacing: 0) {
            if let userCode = authURL.userCode {
                VStack(spacing: 6) {
                    Text("GitHub device code")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(userCode)
                        .font(.system(.title2, design: .monospaced).weight(.semibold))
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color(.secondarySystemGroupedBackground))
            }

            SafariAuthView(url: authURL.url)
        }
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

#Preview {
    NavigationStack {
        ProviderSettingsView(configurationStore: ProviderConfigurationStore(), providerID: .openRouter)
    }
}
