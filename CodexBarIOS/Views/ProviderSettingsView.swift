import SwiftUI
import UniformTypeIdentifiers

struct ProviderSettingsView: View {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    let providerID: ProviderID

    @State private var configuration: ProviderAccountConfiguration
    @State private var secret = ""
    @State private var isImportingCodexAuth = false

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
                    ForEach(ProviderAuthMethod.allCases) { method in
                        Text(method.displayName).tag(method)
                    }
                }
            }

            Section {
                if configuration.requiresSecret {
                    if configuration.authMethod == .codexAuthJSON {
                        Button("Import auth.json") {
                            isImportingCodexAuth = true
                        }

                        TextEditor(text: $secret)
                            .font(.system(.footnote, design: .monospaced))
                            .frame(minHeight: 130)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    } else {
                        SecureField(secretPlaceholder, text: $secret)
                            .textContentType(.password)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

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
            configuration = configurationStore.configuration(for: providerID)
            configurationStore.refreshSecretAvailability()
        }
        .fileImporter(
            isPresented: $isImportingCodexAuth,
            allowedContentTypes: [.json, .text],
            allowsMultipleSelection: false
        ) { result in
            importCodexAuth(from: result)
        }
    }

    private var secretPlaceholder: String {
        configurationStore.hasSecret(for: providerID)
            ? "Credential saved"
            : "Paste credential"
    }

    private var nonSecretAuthText: String {
        switch configuration.authMethod {
        case .browserSession:
            "This provider will use an authenticated browser session once its fetcher is implemented."
        case .codexAuthJSON:
            "Paste Codex CLI auth.json contents or an access token."
        case .oauth:
            "This provider will use OAuth once its sign-in flow is implemented."
        case .apiKey, .cliToken:
            "Paste a credential to save it in Keychain."
        }
    }

    private func importCodexAuth(from result: Result<[URL], Error>) {
        guard
            case .success(let urls) = result,
            let url = urls.first
        else {
            return
        }

        let didAccessSecurityScopedResource = url.startAccessingSecurityScopedResource()
        defer {
            if didAccessSecurityScopedResource {
                url.stopAccessingSecurityScopedResource()
            }
        }

        guard
            let data = try? Data(contentsOf: url),
            let contents = String(data: data, encoding: .utf8)
        else {
            return
        }

        secret = contents
        configurationStore.saveSecret(contents, for: providerID)
        secret = ""
    }
}

#Preview {
    NavigationStack {
        ProviderSettingsView(configurationStore: ProviderConfigurationStore(), providerID: .openRouter)
    }
}
