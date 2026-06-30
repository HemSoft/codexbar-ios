import SwiftUI
import SafariServices

struct ProviderSettingsView: View {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    let providerID: ProviderID

    @State private var configuration: ProviderAccountConfiguration
    @State private var secret = ""
    @State private var isSigningInWithCodex = false
    @State private var codexAuthError: String?
    @State private var codexAuthURL: PresentedAuthURL?

    private let codexAuthService = CodexWebAuthService()

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
        .sheet(item: $codexAuthURL) { authURL in
            SafariAuthView(url: authURL.url)
        }
    }

    private var secretPlaceholder: String {
        configurationStore.hasSecret(for: providerID)
            ? "Credential saved"
            : "Paste credential"
    }

    private var availableAuthMethods: [ProviderAuthMethod] {
        switch providerID {
        case .codex:
            [.browserSession]
        case .openRouter:
            [.apiKey]
        case .copilot:
            [.cliToken, .oauth]
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
        guard providerID == .codex else {
            return configuration
        }

        var normalized = configuration
        normalized.authMethod = .browserSession
        return normalized
    }

    @MainActor
    private func signInWithCodex() async {
        isSigningInWithCodex = true
        codexAuthError = nil

        do {
            let result = try await codexAuthService.signIn { url in
                codexAuthURL = PresentedAuthURL(url: url)
            }
            configuration.authMethod = .browserSession
            configurationStore.update(configuration)
            configurationStore.saveSecret(result.storedCredential, for: providerID)
            codexAuthURL = nil
        } catch {
            codexAuthError = error.localizedDescription
            codexAuthURL = nil
        }

        isSigningInWithCodex = false
    }
}

private struct PresentedAuthURL: Identifiable {
    let id = UUID()
    let url: URL
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
