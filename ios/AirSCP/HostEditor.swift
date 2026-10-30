import AirSCPCore
import SwiftUI

/// Adds or changes a saved server: its address, how it logs in, and a jump host. `isNew`: not saved yet (a new
/// server, or a quick connect's to save), added on Save.
struct HostEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let isNew: Bool
    @State private var host: SSHHost
    @State private var port: String
    /// Saved in the Keychain on Save; empty keeps what is saved.
    @State private var password = ""
    @State private var keys = KeyStore.all()
    @State private var confirmingDelete = false

    init(host: SSHHost, isNew: Bool) {
        var host = host
        if host.auth == .agent { host.auth = .password }  // a Mac's host: iOS has no agent, so the server asks for a password
        _host = State(initialValue: host)
        _port = State(initialValue: host.port.map(String.init) ?? "")
        self.isNew = isNew
    }

    /// Why Save is off, if it is.
    private var problem: String? {
        let address = host.hostname.trimmingCharacters(in: .whitespaces)
        if address.isEmpty { return "Type the server's address" }
        if address.contains(where: \.isWhitespace) { return "Take the spaces out of the address" }
        // Unlike the Mac's, an empty user can't work here: it would log in as this device's NSUserName().
        return host.username.trimmingCharacters(in: .whitespaces).isEmpty ? "Type the user name" : nil
    }

    /// The saved servers this one can go through. One hop only: none that goes through another itself, and none
    /// while others go through this one.
    private var jumpHosts: [SSHHost] {
        let inUse = app.data.hosts.contains { $0.jumpHostID == host.id }
        return app.data.hosts.filter { $0.id == host.jumpHostID || (!inUse && $0.id != host.id && $0.jumpHostID == nil && $0.s3 == nil) }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Group {
                        LabeledContent("Name") {
                            TextField("Name", text: $host.label, prompt: Text("Optional"))
                                .help("Name the server in the list; its address shows when empty")
                        }
                        LabeledContent("Address") {
                            TextField("Address", text: $host.hostname, prompt: Text("Host name or IP address"))
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .help("Type the server's host name or IP address")
                        }
                        LabeledContent("Port") {
                            TextField("Port", text: $port, prompt: Text("22"))
                                .keyboardType(.numberPad)
                                .help("Type the SSH port; 22 when empty")
                        }
                        LabeledContent("User") {
                            TextField("User", text: $host.username, prompt: Text("Required"))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .help("Type the account you log in as on the server")
                        }
                    }
                    .multilineTextAlignment(.trailing)
                } footer: {
                    if let problem { Text(problem) }
                }
                Section {
                    Picker("Log in with", selection: $host.auth) {
                        Text("Password").tag(SSHHost.Auth.password)
                        Text("Key").tag(SSHHost.Auth.keyFile)
                    }
                    .pickerStyle(.segmented)
                    .help("Choose how you prove who you are: a password or a key")
                    if host.auth == .password {
                        LabeledContent("Password") {
                            SecureField("Password", text: $password,
                                        prompt: Text(Keychain.password(for: host.id) == nil ? "Optional" : "Saved in Keychain"))
                                .multilineTextAlignment(.trailing)
                                .help("Type the password to keep it in the Keychain; when empty, AirSCP asks when connecting")
                        }
                    } else if !keys.isEmpty {
                        Picker("Key", selection: $host.keyFile) {
                            ForEach(keys) { Text($0.name).tag($0.name) }
                        }
                        .help("Choose the key to log in with")
                    }
                } header: {
                    Text("Log in with")
                } footer: {
                    if host.auth == .password {
                        Text("Saved in the Keychain. Without one, AirSCP asks when connecting.")
                    } else if keys.isEmpty {
                        Text("No keys yet. Add one in Settings ▸ Keys.")
                    }
                }
                Section {
                    Picker("Jump host", selection: $host.jumpHostID) {
                        Text("None").tag(UUID?.none)
                        ForEach(jumpHosts) { Text($0.displayName).tag(Optional($0.id)) }
                    }
                    .help("Choose a saved server to connect through first (ProxyJump)")
                } footer: {
                    Text("Connect through another server first (ProxyJump).")
                }
                if !isNew {
                    Section {
                        Button("Delete Server", role: .destructive) { confirmingDelete = true }
                            .help("Forget this server and its saved password")
                            .confirmationDialog("Delete “\(host.displayName)”?", isPresented: $confirmingDelete,
                                                titleVisibility: .visible) {
                                Button("Delete", role: .destructive) {
                                    app.delete(host)
                                    dismiss()
                                }
                            } message: {
                                Text("AirSCP forgets its settings and saved password.")
                            }
                    }
                }
            }
            .navigationTitle(isNew ? "New Server" : "Edit Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                        .help("Close without saving")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", role: .confirm, action: save)
                        .disabled(problem != nil)
                        .help(problem ?? (isNew ? "Add this server to the list" : "Save the changes"))
                }
            }
            .onChange(of: host.auth, initial: true) {
                // The picker needs a saved key: the first one when none is chosen yet, or the chosen one is gone.
                if host.auth == .keyFile, !keys.contains(where: { $0.name == host.keyFile }), let first = keys.first {
                    host.keyFile = first.name
                }
            }
        }
    }

    private func save() {
        var host = host
        host.label = host.label.trimmingCharacters(in: .whitespaces)
        host.hostname = host.hostname.trimmingCharacters(in: .whitespaces)
        host.username = host.username.trimmingCharacters(in: .whitespaces)
        host.port = Int(port).flatMap { (1...65535).contains($0) ? $0 : nil }
        app.save(host, password: host.auth == .password ? password : nil)
        dismiss()
    }
}
