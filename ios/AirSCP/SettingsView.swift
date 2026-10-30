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
