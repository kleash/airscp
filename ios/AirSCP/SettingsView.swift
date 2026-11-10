import AirSCPCore
import AirSCPSSH2
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var keys = KeyStore.all()
    @State private var naming = false
    @State private var newName = ""
    @State private var importing = false
    /// A PuTTY key file's text and name, waiting for its passphrase.
    @State private var locked: (text: String, name: String)?
    @State private var passphrase = ""
    @State private var deleting: KeyStore.Key?
    @State private var keyFailure: String?
    @State private var trusted = KnownHosts.entries(knownHostsPath)
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                keysSection
                trustedSection
                aboutSection
            }
            .navigationTitle("Settings")
            .toolbar {
                Button("Done", systemImage: "checkmark") { dismiss() }
                    .help("Close settings")
            }
            .alert("Make a New Key", isPresented: $naming) {
                TextField(suggestedName, text: $newName)
                Button("Make", action: make)
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("An Ed25519 key, the kind most servers take. Its name is also its comment in authorized_keys.")
            }
            // Keys often have no extension, so any file can be chosen.
            .fileImporter(isPresented: $importing, allowedContentTypes: [.data]) { result in
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    // Keys are a few kB: a big file chosen by mistake isn't read whole.
                    let data = try FileHandle(forReadingFrom: url).read(upToCount: 1 << 20) ?? Data()
                    add(String(decoding: data, as: UTF8.self), name: url.deletingPathExtension().lastPathComponent)
                } catch {
                    keyFailure = error.localizedDescription
                }
            }
            .alert("Enter the Passphrase", isPresented: .constant(locked != nil), presenting: locked) { locked in
                SecureField("Passphrase", text: $passphrase)
                Button("Import") {
                    self.locked = nil
                    add(locked.text, name: locked.name, passphrase: passphrase)
                    passphrase = ""
                }
                Button("Cancel", role: .cancel) {
                    self.locked = nil
                    passphrase = ""
                }
            } message: { locked in
                Text("“\(locked.name)” is a PuTTY key with a passphrase. Enter it to import the key.")
            }
            .alert("Delete the Key?", isPresented: .constant(deleting != nil), presenting: deleting) { key in
                Button("Delete", role: .destructive) {
                    deleting = nil
                    KeyStore.remove(key.name)
                    keys = KeyStore.all()
                }
                Button("Cancel", role: .cancel) { deleting = nil }
            } message: { key in
                Text("AirSCP keeps no other copy of “\(key.name)”. Servers that log in with it will need another key.")
            }
            .alert("Can't add the key", isPresented: .constant(keyFailure != nil)) {
                Button("OK") { keyFailure = nil }
            } message: {
                Text(keyFailure ?? "")
            }
            .alert("Can't remove the server", isPresented: .constant(failure != nil)) {
                Button("OK") { failure = nil }
            } message: {
                Text(failure ?? "")
            }
        }
    }

    private var keysSection: some View {
        Section {
            if keys.isEmpty {
                Text("No keys yet. A key lets you log in without typing a password.").foregroundStyle(.secondary)
            }
            ForEach(keys) { key in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(key.name)
                        if let type = key.type, let fingerprint = key.fingerprint {
                            Text("\(type)  \(fingerprint)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        } else {
                            Text("Encrypted or PEM key: its public key can't be shown. Its passphrase, if any, "
                                 + "is asked when you log in.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Menu("Public key of \(key.name)", systemImage: "ellipsis.circle") {
                        Button("Copy Public Key", systemImage: "doc.on.doc") {
                            UIPasteboard.general.string = key.publicLine
                        }
                        .help("Copy the public key, to paste into a server's authorized_keys")
                        ShareLink("Share Public Key", item: key.publicLine ?? "")
                            .help("Send the public key with another app, such as Mail or Messages")
                    }
                    .labelStyle(.iconOnly)
                    .disabled(key.publicLine == nil)
                    .help(key.publicLine == nil ? "AirSCP can't read the public key of an encrypted or PEM key"
                          : "Copy or share the public key, to add it to a server's authorized_keys")
                }
            }
            .onDelete { deleting = $0.first.map { keys[$0] } }
            Button("Make a New Key", systemImage: "plus") {
                newName = ""
                naming = true
            }
            .help("Make an Ed25519 key on this device, to log in without a password")
            Button("Import from Files", systemImage: "folder") { importing = true }
                .help("Import a private key from Files: OpenSSH, PEM or PuTTY (.ppk)")
        } header: {
            Text("Keys")
        } footer: {
            Text("Keys stay on this device, in the Keychain. Face ID or the passcode unlocks a key when AirSCP logs in "
                 + "with it. To use a key, add its public key to the server's ~/.ssh/authorized_keys.")
        }
    }

    private var trustedSection: some View {
        Section {
            if trusted.isEmpty {
                Text("None yet").foregroundStyle(.secondary)
            }
            ForEach(trusted) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.host)
                    Text("\(entry.type)  \(entry.fingerprint)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .onDelete(perform: forget)
        } header: {
            Text("Trusted servers")
        } footer: {
            Text("AirSCP asks before it trusts a server the first time. Remove one to be asked again.")
        }
    }

    private var aboutSection: some View {
        Section {
            HStack(spacing: 14) {
                if let icon = appIcon {
                    Image(uiImage: icon)
                        .resizable()
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("AirSCP").font(.title3.weight(.semibold))
                    Text("Version \(info("CFBundleShortVersionString")) (\(info("CFBundleVersion")))")
                        .foregroundStyle(.secondary)
                    Text("Files, terminal and Remote Desktop for your servers")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            aboutLink("Source Code", detail: "Open source on GitHub · Apache 2.0",
                      systemImage: "chevron.left.forwardslash.chevron.right", url: "https://github.com/kleash/airscp",
                      help: "Open AirSCP's source code on GitHub")
            aboutLink("Shubham Aggarwal (kleash)", detail: "Author · github.com/kleash", systemImage: "person",
                      url: "https://github.com/kleash", help: "Open the author's page on GitHub")
            aboutLink("Help and Documentation", systemImage: "book", url: "https://kleash.github.io/airscp/",
                      help: "Open AirSCP's guide in Safari")
            aboutLink("Report a Problem", systemImage: "exclamationmark.bubble",
                      url: "https://github.com/kleash/airscp/issues", help: "Report a problem or ask for a feature on GitHub")
            // A Hide My Email relay the author made to be public (not a personal address).
            aboutLink("Email the Developer", detail: "strobes01sport@icloud.com", systemImage: "envelope",
                      url: "mailto:strobes01sport@icloud.com?subject=AirSCP", help: "Write to the developer in Mail")
            aboutLink("Rate on the App Store", systemImage: "star",
                      url: "https://apps.apple.com/app/id6828032872?action=write-review",
                      help: "Rate or review AirSCP on the App Store")
            NavigationLink {
                LicencesView()
            } label: {
                Label("Licences", systemImage: "doc.text")
            }
            .help("Read the licences of AirSCP and what it is built with")
        } header: {
            Text("About")
        } footer: {
            Text("AirSCP is free and open source, under the Apache License 2.0. No account, no tracking: your servers "
                 + "and keys stay on this device. © 2026 Shubham Aggarwal")
        }
    }

    /// A row that opens `url` (Safari, Mail or the App Store), with an arrow saying it leaves AirSCP.
    private func aboutLink(_ title: String, detail: String? = nil, systemImage: String, url: String,
                           help: String) -> some View {
        Link(destination: URL(string: url)!) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                        if let detail { Text(detail).font(.caption).foregroundStyle(Color.secondary) }  // grey, not the tint
                    }
                } icon: {
                    Image(systemName: systemImage)
                }
                Spacer()
                Image(systemName: "arrow.up.right").font(.caption.weight(.semibold)).foregroundStyle(Color(.tertiaryLabel))
            }
        }
        .help(help)
    }

    private func info(_ key: String) -> String { Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "" }

    /// The app's own icon: the asset catalog gives it no name to load, the Info.plist names its files.
    private var appIcon: UIImage? {
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let files = (icons?["CFBundlePrimaryIcon"] as? [String: Any])?["CFBundleIconFiles"] as? [String]
        return files?.last.flatMap { UIImage(named: $0) }
    }

    /// "iPhone key" (or "iPad key"), made free.
    private var suggestedName: String { freeName("\(UIDevice.current.model) key") }

    /// `base`, else "base 2", "base 3", … (the first name no key has).
    private func freeName(_ base: String) -> String {
        var name = base, number = 2
        while keys.contains(where: { $0.name == name }) {
            name = "\(base) \(number)"
            number += 1
        }
        return name
    }

    /// Makes an Ed25519 key named as typed (empty: the suggested name), which is also its comment.
    private func make() {
        let typed = newName.trimmingCharacters(in: .whitespaces)
        let name = typed.isEmpty ? suggestedName : typed
        let key = PuTTYKey.newEd25519(comment: name)
        do {
            try KeyStore.add(name, privateKey: Data(PuTTYKey.openSSH(key).utf8), publicLine: PuTTYKey.publicLine(key))
        } catch {
            keyFailure = error.localizedDescription
        }
        keys = KeyStore.all()
    }

    /// Saves a key file's text under a free name (`name`, else "name 2", …). A PuTTY key with a passphrase asks for
    /// it first.
    private func add(_ text: String, name: String, passphrase: String? = nil) {
        do {
            let key = try KeyStore.read(text, passphrase: passphrase)
            try KeyStore.add(freeName(name), privateKey: key.privateKey, publicLine: key.publicLine)
        } catch is KeyStore.NeedsPassphrase {
            locked = (text, name)
        } catch {
            keyFailure = error.localizedDescription
        }
        keys = KeyStore.all()
    }

    private func forget(_ offsets: IndexSet) {
        do {
            for entry in offsets.map({ trusted[$0] }) { try KnownHosts.forget(entry, in: knownHostsPath) }
        } catch {
            failure = error.localizedDescription
        }
        trusted = KnownHosts.entries(knownHostsPath)
    }
}

/// AirSCP's licence (on GitHub) and the full licence texts of what the app is built with (in the app).
struct LicencesView: View {
    private let libraries = [("libssh2", "SSH, SFTP and SCP · BSD 3-Clause", "libssh2-LICENSE"),
                             ("OpenSSL", "Encryption · Apache License 2.0", "OpenSSL-LICENSE")]

    var body: some View {
        Form {
            Section("AirSCP") {
                Link(destination: URL(string: "https://github.com/kleash/airscp/blob/main/LICENSE")!) {
                    row("AirSCP", "Apache License 2.0")
                }
                .help("Read AirSCP's licence on GitHub")
            }
            Section {
                ForEach(libraries, id: \.0) { name, detail, file in
                    NavigationLink {
                        ScrollView {
                            Text(text(file))
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .padding()
                        }
                        .navigationTitle(name)
                    } label: {
                        row(name, detail)
                    }
                    .help("Read the licence of \(name)")
                }
            } header: {
                Text("Built with")
            } footer: {
                Text("Tap one to read its full licence.")
            }
        }
        .navigationTitle("Licences")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ name: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func text(_ file: String) -> String {
        Bundle.main.url(forResource: file, withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "The licence text is missing from this copy of AirSCP."
    }
}
