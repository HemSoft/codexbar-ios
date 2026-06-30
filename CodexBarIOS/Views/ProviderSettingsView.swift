import SwiftUI

struct ProviderSettingsView: View {
    @ObservedObject var configurationStore: ProviderConfigurationStore
    let providerID: ProviderID

    @State private var configuration: ProviderAccountConfiguration
    @State private var secret = ""

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
            configuration = configurationStore.configuration(for: providerID)
            configurationStore.refreshSecretAvailability()
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
        case .oauth:
            "This provider will use OAuth once its sign-in flow is implemented."
        case .apiKey, .cliToken:
            "Paste a credential to save it in Keychain."
        }
    }
}

#Preview {
    NavigationStack {
        ProviderSettingsView(configurationStore: ProviderConfigurationStore(), providerID: .openRouter)
    }
}

