import AirSCPCore
import SwiftUI

/// Adds or changes a saved server (its address, how it logs in, and a jump host) or S3 storage (`host.s3`: where it
/// is and its key, the secret saved in the Keychain as the Mac saves it). `isNew`: not saved yet (a new server, or a
/// quick connect's to save), added on Save.
struct HostEditor: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let isNew: Bool
    @State private var host: SSHHost
    @State private var port: String
    /// The password, or S3 storage's secret access key: saved in the Keychain on Save; empty keeps what is saved.
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
        if let s3 = host.s3 {  // the Mac's checks
            if s3.accessKeyID.trimmingCharacters(in: .whitespaces).isEmpty { return "Type the access key ID" }
            if password.isEmpty && Keychain.password(for: host.id) == nil { return "Type the secret access key" }
            let endpoint = s3.endpoint.trimmingCharacters(in: .whitespaces)
            if !endpoint.isEmpty, URLComponents(string: endpoint.contains("://") ? endpoint : "https://" + endpoint)?.host?.isEmpty != false {
                return "Type the endpoint as an address, like https://s3.example.com"
            }
            return s3.bucket.contains("/") ? "Type the bucket's name alone, without “/”" : nil
        }
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
                if isNew { kind }
                if let s3 = Binding($host.s3) { storage(s3) } else { server }
                if !isNew { remove }
            }
            .navigationTitle(host.s3 == nil ? (isNew ? "New Server" : "Edit Server") : (isNew ? "New S3 Storage" : "Edit S3 Storage"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark", role: .cancel) { dismiss() }
                        .help("Close without saving")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark", role: .confirm, action: save)
                        .disabled(problem != nil)
                        .help(problem ?? (isNew ? (host.s3 == nil ? "Add this server to the list" : "Add this storage to the list")
                                          : "Save the changes"))
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

    /// A new one: a server, or S3 storage.
    private var kind: some View {
        Section {
            Picker("Kind", selection: Binding(get: { host.s3 != nil }, set: { host.s3 = $0 ? S3Settings() : nil })) {
                Text("Server").tag(false)
                Text("S3 storage").tag(true)
            }
            .pickerStyle(.segmented)
            .help("Choose what to add: a server you log in to, or S3 storage (Amazon S3 or a service like it)")
        } footer: {
            if host.s3 != nil {
                Text("Amazon S3, or storage that speaks its language (MinIO, Cloudflare R2, Backblaze B2, Wasabi, Ceph…). "
                     + "Its buckets open like a server's folders.")
            }
        }
    }

    @ViewBuilder private var server: some View {
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
    }

    /// S3 storage's fields, as the Mac's S3 editor has them (path-style addresses, a session token and a proxy aren't
    /// here: an endpoint at an IP address goes path-style by itself).
    @ViewBuilder private func storage(_ s3: Binding<S3Settings>) -> some View {
        Section {
            Group {
                LabeledContent("Name") {
                    TextField("Name", text: $host.label, prompt: Text("Optional"))
                        .help("Name the storage in the list; its bucket or endpoint shows when empty")
                }
                LabeledContent("Endpoint") {
                    TextField("Endpoint", text: s3.endpoint, prompt: Text("Empty for Amazon S3"))
                        .keyboardType(.URL)
                        .help("Type the storage's address, e.g. https://s3.example.com; empty for Amazon S3")
                }
                LabeledContent("Region") {
                    TextField("Region", text: s3.region, prompt: Text("us-east-1"))
                        .help("Type the region requests are signed for; Amazon S3 finds each bucket's region by itself")
                }
                LabeledContent("Bucket") {
                    TextField("Bucket", text: s3.bucket, prompt: Text("Optional"))
                        .help("Type the bucket to open; needed for keys that may not list the buckets")
                }
            }
            .multilineTextAlignment(.trailing)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        } footer: {
            Text("The endpoint of another service, e.g. https://<account>.r2.cloudflarestorage.com or http://192.168.1.10:9000. "
                 + "Region: optional for Amazon S3; others name theirs (Cloudflare R2: auto).")
        }
        Section {
            Group {
                LabeledContent("Access key ID") {
                    TextField("Access key ID", text: s3.accessKeyID, prompt: Text("Required"))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .help("Type the key's ID, from your provider's console (where the key was made)")
                }
                LabeledContent("Secret key") {
                    SecureField("Secret access key", text: $password,
                                prompt: Text(Keychain.password(for: host.id) == nil ? "Required" : "Saved in Keychain"))
                        .help("Type the key's secret, shown once when the key was made; it is kept in the Keychain")
                }
            }
            .multilineTextAlignment(.trailing)
        } header: {
            Text("Key")
        } footer: {
            Text(problem ?? "The secret is kept in the Keychain, never in AirSCP's settings file.")
        }
    }

    private var remove: some View {
        Section {
            Button(host.s3 == nil ? "Delete Server" : "Delete Storage", role: .destructive) { confirmingDelete = true }
                .help(host.s3 == nil ? "Forget this server and its saved password" : "Forget this storage and its saved key")
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

    private func save() {
        var host = host
        host.label = host.label.trimmingCharacters(in: .whitespaces)
        if var s3 = host.s3 {
            for field in [\S3Settings.endpoint, \.region, \.accessKeyID, \.bucket] {
                s3[keyPath: field] = s3[keyPath: field].trimmingCharacters(in: .whitespaces)
            }
            host.s3 = s3
            app.save(host, password: password)  // the secret: the host's Keychain password, as the Mac keeps it
            return dismiss()
        }
        host.hostname = host.hostname.trimmingCharacters(in: .whitespaces)
        host.username = host.username.trimmingCharacters(in: .whitespaces)
        host.port = Int(port).flatMap { (1...65535).contains($0) ? $0 : nil }
        app.save(host, password: host.auth == .password ? password : nil)
        dismiss()
    }
}
