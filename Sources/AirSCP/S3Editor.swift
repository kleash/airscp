import AirSCPCore
import AppKit
import SwiftUI

/// The S3 connection editor: where the storage is (Amazon S3, or an S3-compatible service's endpoint), the keys, and
/// the bucket to open at. The secret key and a session token go to the Keychain, never to airscp.json. `close` gets
/// the saved connection's id, or nil for Cancel.
struct S3EditorView: View {
    @ObservedObject var model: AppModel
    let host: SSHHost
    let isNew: Bool
    /// For Test Connection's Session.
    let askpass: AskpassServer
    let close: (UUID?) -> Void
    @State private var label: String
    @State private var settings: S3Settings
    @State private var groupID: UUID?
    @State private var proxyID: UUID?
    /// What was typed in the secret and token fields (empty: keep what is saved).
    @State private var secret = ""
    @State private var token = ""
    @State private var hasSecret = false
    @State private var hasToken = false
    @State private var advanced: Bool
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?

    init(model: AppModel, host: SSHHost, isNew: Bool, askpass: AskpassServer, close: @escaping (UUID?) -> Void) {
        self.model = model
        self.host = host
        self.isNew = isNew
        self.askpass = askpass
        self.close = close
        _label = State(initialValue: host.label)
        _settings = State(initialValue: host.s3 ?? S3Settings())
        _groupID = State(initialValue: host.groupID)
        _proxyID = State(initialValue: host.proxyID)
        _advanced = State(initialValue: host.s3?.pathStyle == true || host.proxyID != nil)
    }

    /// The first thing to fix before saving.
    var problem: String? {
        if settings.accessKeyID.trimmingCharacters(in: .whitespaces).isEmpty { return "Enter the access key ID to begin." }
        if secret.isEmpty && !hasSecret { return "Enter the secret access key." }
        let endpoint = settings.endpoint.trimmingCharacters(in: .whitespaces)
        if !endpoint.isEmpty, URLComponents(string: endpoint.contains("://") ? endpoint : "https://" + endpoint)?.host?.isEmpty != false {
            return "The endpoint isn't an address, like https://s3.example.com."
        }
        if settings.bucket.contains("/") { return "A bucket's name has no “/”: type the bucket alone." }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isNew ? "New S3 Connection" : "Edit “\(host.displayName)”").font(.headline)
                Text("Amazon S3, or storage that speaks its language (MinIO, Cloudflare R2, Backblaze B2, Wasabi, Ceph…). "
                     + "Its buckets open like a server's folders.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Form {
                TextField("Name:", text: $label, prompt: Text("Optional")).accessibilityIdentifier("s3Editor.name")
                    .help("A name for the sidebar; the bucket or the endpoint is used when empty")
                TextField("Endpoint:", text: $settings.endpoint, prompt: Text("Empty for Amazon S3"))
                    .accessibilityIdentifier("s3Editor.endpoint")
                    .help("The storage's address, e.g. https://s3.eu-central-1.wasabisys.com; empty for Amazon S3")
                FormCaption("Your provider's S3 endpoint, e.g. https://<account>.r2.cloudflarestorage.com or http://192.168.1.10:9000.")
                TextField("Region:", text: $settings.region, prompt: Text("us-east-1"))
                    .accessibilityIdentifier("s3Editor.region")
                    .help("The region requests are signed for; Amazon S3 finds each bucket's region by itself")
                FormCaption("Optional for Amazon S3. Other services: the region they name (Cloudflare R2: auto).")
                TextField("Access key ID:", text: $settings.accessKeyID, prompt: Text("e.g. AKIA…"))
                    .accessibilityIdentifier("s3Editor.accessKey")
                    .help("The key's ID, from your provider's console (where the key was made)")
                SecureField("Secret access key:", text: $secret, prompt: Text(hasSecret ? "Saved in Keychain" : "Required"))
                    .accessibilityIdentifier("s3Editor.secret")
                    .help("The key's secret, shown once when the key was made; saved in your Keychain")
                FormCaption("Kept in your Keychain, never in AirSCP's settings file. Have an AWS CLI profile? File ▸ Import from "
                            + "~/.aws… makes connections from it.")
                TextField("Bucket:", text: $settings.bucket, prompt: Text("Optional: the bucket to open"))
                    .accessibilityIdentifier("s3Editor.bucket")
                    .help("Optional. The bucket shown when you connect; needed for keys that may not list the buckets")
                Picker("Group:", selection: $groupID) {
                    Text("None").tag(UUID?.none)
                    ForEach(model.data.groups) { Text($0.name).tag(Optional($0.id)) }
                }
                .accessibilityIdentifier("s3Editor.group")
                .help("The sidebar group this connection is listed under")
                AdvancedToggle(shown: $advanced, id: "s3Editor.advanced",
                               help: "Rarely needed: path-style addresses, a session token and a proxy")
                if advanced { advancedFields }
            }
            .scrollingOnShortScreens()
            HStack(spacing: 8) {
                Button("Test Connection", action: test).disabled(testing || problem != nil)
                    .accessibilityIdentifier("s3Editor.test")
                    .help("Check the keys with these settings (list the buckets, or the bucket), without saving")
                if testing { ProgressView().controlSize(.small) }
                if let testResult {
                    Text(testResult.text).font(.caption).foregroundColor(testResult.ok ? .green : .red).lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                HelpButton(.s3)
                Text(problem ?? "").font(.caption).foregroundColor(.secondary).lineLimit(2)
                Spacer()
                Button("Cancel") { close(nil) }.keyboardShortcut(.cancelAction).help("Close without saving")
                Button(isNew ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction).primaryTint()
                    .accessibilityIdentifier("s3Editor.save")
                    .disabled(problem != nil)
                    .help(isNew ? "Save this connection in the sidebar" : "Save the changes; a connected one uses them at its next connect")
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            hasSecret = model.savedPassword(host.id.uuidString) != nil
            hasToken = model.savedPassword(S3Settings.tokenKey(host.id)) != nil
            if model.data.proxy(proxyID) == nil { proxyID = nil }
        }
    }

    @ViewBuilder private var advancedFields: some View {
        Toggle("Path-style addresses (https://host/bucket)", isOn: $settings.pathStyle)
            .accessibilityIdentifier("s3Editor.pathStyle")
            .help("Off by default. On puts the bucket in the path instead of the host name, as MinIO and Ceph usually want")
        FormCaption("Most self-hosted servers want this; Amazon S3 doesn't. An endpoint at an IP address always uses it.")
        SecureField("Session token:", text: $token, prompt: Text(hasToken ? "Saved in Keychain" : "Optional: for temporary keys"))
            .accessibilityIdentifier("s3Editor.token")
            .help("Optional. Only for temporary keys (they start with ASIA on Amazon S3); saved in your Keychain")
        if hasToken {
            Button("Forget Session Token") {
                model.setSavedPassword(S3Settings.tokenKey(host.id), nil)
                hasToken = false
            }
            .help("Remove the session token from the Keychain; the key is then used without one")
        }
        Picker("Proxy:", selection: $proxyID) {
            Text("None").tag(UUID?.none)
            ForEach(model.data.proxies) { Text($0.displayName).tag(Optional($0.id)) }
        }
        .accessibilityIdentifier("s3Editor.proxy")
        .help("Reach the storage through an HTTP or SOCKS5 proxy (Proxies in the sidebar); only when your network needs one")
    }

    /// The connection as typed.
    private var edited: SSHHost {
        var edited = host
        edited.label = label.trimmingCharacters(in: .whitespaces)
        var settings = self.settings
        settings.endpoint = settings.endpoint.trimmingCharacters(in: .whitespaces)
        settings.region = settings.region.trimmingCharacters(in: .whitespaces)
        settings.accessKeyID = settings.accessKeyID.trimmingCharacters(in: .whitespaces)
        settings.bucket = settings.bucket.trimmingCharacters(in: .whitespaces)
        edited.s3 = settings
        edited.groupID = groupID
        edited.proxyID = proxyID
        return edited
    }

    private func save() {
        let saved = edited
        model.save(saved)
        if !secret.isEmpty { model.setSavedPassword(saved.id.uuidString, secret) }
        if !token.isEmpty { model.setSavedPassword(S3Settings.tokenKey(saved.id), token) }
        close(saved.id)
    }

    /// Connects with the settings as typed (the secret and token typed, else the saved ones), and disconnects.
    private func test() {
        var tested = edited
        tested.id = UUID()
        let secret = self.secret.isEmpty ? model.savedPassword(host.id.uuidString) : self.secret
        let token = self.token.isEmpty ? model.savedPassword(S3Settings.tokenKey(host.id)) : self.token
        let session = Session(host: tested, jump: nil, askpass: askpass)
        session.savedPassword = { _ in secret }
        session.savedS3Token = { _ in token }
        let proxy = model.data.proxy(tested.proxyID)
        session.s3?.useProxy(proxy, password: proxy.flatMap { model.savedPassword($0.keychainKey) })
        testing = true
        testResult = nil
        Task {
            do {
                try await session.connect()
                let buckets = try await session.list(session.capabilities.home)
                testResult = (true, tested.s3?.bucket.isEmpty == false ? "Connected: the bucket opens."
                              : "Connected: \(buckets.count == 1 ? "1 bucket" : "\(buckets.count) buckets").")
            } catch {
                testResult = (false, (error as? AirSCPError)?.message ?? error.localizedDescription)
            }
            await session.disconnect()
            askpass.setHandler(nil, for: tested.id.uuidString)
            testing = false
        }
    }
}
