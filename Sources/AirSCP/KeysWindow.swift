import AirSCPCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The Keys window: the key pairs in ~/.ssh (and the folder Settings ▸ Keys names) with type, comment and
/// fingerprint; New Key Pair, Import Key (PuTTY .ppk, also dropped on the window), Copy Public Key in three formats,
/// Install on Host, Export as PuTTY Key and Add to Agent. ssh-keygen and ssh-add ask for passphrases through askpass
/// (answered from the sheets, or asked on this window), so nothing secret goes into a command line. AirSCP never
/// changes or deletes an existing key.
@MainActor
final class KeysWindowController: NSWindowController, NSWindowDelegate {
    let keys: KeysModel

    init(model: AppModel, askpass: AskpassServer, install: @escaping (_ publicKey: String, _ hostID: UUID) -> Void) {
        keys = KeysModel(askpass: askpass.environment(for: KeysModel.askpassID),
                         alsoList: { model.data.settings.keyFolder.isEmpty ? nil : (model.data.settings.keyFolder as NSString).expandingTildeInPath })
        // Wide enough for the buttons' titles, tall enough for New Key Pair's sheet with Advanced open.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 600),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Keys"
        window.minSize = NSSize(width: 960, height: 420)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: KeysView(keys: keys, model: model, install: install, report: {
            [weak self] error, title in showError(error, title: title, on: self?.window)
        }))
        window.open(size: NSSize(width: 1000, height: 600))
        askpass.setHandler({ [weak self] request, reply in
            guard let self, let window = self.window else { return reply(nil) }
            self.showWindow(nil)
            self.keys.reply(to: request, on: window, reply)
        }, for: KeysModel.askpassID)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

@MainActor
final class KeysModel: ObservableObject {
    /// The askpass id of ssh-keygen and ssh-add run from the Keys window.
    static let askpassID = "keys"

    @Published private(set) var pairs: [Keys.KeyPair] = []
    @Published var selection: Keys.KeyPair.ID?
    @Published private(set) var busy = false
    /// A file dropped on the window's list (by a drag, or by an agent's `drop target=keys`): the window opens Import
    /// Key for it.
    @Published var dropped: URL?
    /// The user cancelled a passphrase prompt of the running ssh-keygen or ssh-add: it gets no more answers, and the
    /// operation is undone. (Tools take a cancel as an empty answer: ssh-keygen would make a key without a passphrase.)
    private(set) var cancelled = false
    /// The passphrase the running ssh-keygen or ssh-add gets for its passphrase questions: what was typed in the sheet
    /// (nil: they are asked).
    private(set) var answer: String?
    /// ~/.ssh (or $AIRSCP_SSH_DIR).
    let folder: String
    let log = CommandLog()
    let environment: [String: String]
    /// Another folder whose keys are listed too (Settings ▸ Keys), after the folder's own.
    private let alsoList: () -> String?
    /// Keys elsewhere, chosen with Other Key File… or made in another folder: listed after the folders' own.
    private var others: [String] = []

    init(folder: String = sshDirectory, askpass environment: [String: String], alsoList: @escaping () -> String? = { nil }) {
        self.folder = folder
        self.environment = environment
        self.alsoList = alsoList
    }

    var selected: Keys.KeyPair? { pairs.first { $0.id == selection } }

    func refresh() async {
        var pairs = await Keys.list(in: folder, log: logger)
        if let other = alsoList(), other != folder {
            pairs += await Keys.list(in: other, log: logger).filter { pair in !pairs.contains { $0.privateKey == pair.privateKey } }
        }
        for path in others where !pairs.contains(where: { $0.privateKey == path }) {
            pairs.append(await Keys.describe(path, log: logger))
        }
        self.pairs = pairs
        if selected == nil { selection = nil }
    }

    /// A key outside the folder (Other Key File…): listed and selected, for Install on Host and Add to Agent.
    func add(_ privateKey: String) async {
        if !others.contains(privateKey) { others.append(privateKey) }
        await refresh()
        selection = privateKey
    }

    /// A question from this model's ssh-keygen or ssh-add: a passphrase question gets `answer` when one was typed in
    /// the sheet; any other is a sheet on `window` (or on the sheet in front of it).
    func reply(to request: AskpassRequest, on window: NSWindow?, _ reply: @escaping (String?) -> Void) {
        guard !cancelled else { return reply(nil) }
        if let answer, request.kind == .passphrase, request.fromAirSCP { return reply(answer) }
        guard let window else { return reply(nil) }
        showPrompt(request.kind, text: request.prompt, host: nil, canRemember: false, on: frontSheet(window)) {
            [weak self] answer, byUser in
            reply(answer?.text)
            if answer == nil && byUser { self?.promptCancelled() }
        }
    }

    /// Runs `body` with `passphrase` as the answer to passphrase questions, busy, and with cancels turned into
    /// `.cancelled`.
    private func running<T>(answering passphrase: String?, _ body: () async throws -> T) async throws -> T {
        busy = true
        cancelled = false
        answer = passphrase
        defer {
            busy = false
            answer = nil
        }
        do {
            let result = try await body()
            if cancelled { throw AirSCPError(.cancelled, "Cancelled.") }
            return result
        } catch {
            throw cancelled ? AirSCPError(.cancelled, "Cancelled.") : error
        }
    }

    /// Creates `name` in `folder` (made, private, if missing) with ssh-keygen, which gets `passphrase` (empty: none)
    /// through askpass. A question the user cancelled (a security key's PIN) removes the new key again and throws
    /// `.cancelled`.
    @discardableResult
    func generate(_ kind: Keys.Kind = .ed25519, format: Keys.PrivateFormat = .openSSH, name: String, folder: String? = nil,
                  comment: String, passphrase: String = "") async throws -> Keys.KeyPair {
        let folder = folder ?? self.folder
        let path = folder + "/" + name
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        do {
            try await running(answering: passphrase) {
                try await Keys.generate(kind, format: format, path: path, comment: comment, askpass: environment, log: logger)
            }
        } catch let error as AirSCPError where error.kind == .cancelled {
            // New files (generate never replaces any), made with an answer the user didn't give.
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".pub")
            throw error
        }
        return await listed(path)
    }

    /// Imports a PuTTY key (.ppk text) as `name` in `folder`, with `newPassphrase` (empty: none).
    @discardableResult
    func importPPK(_ text: String, passphrase: String, name: String, folder: String? = nil,
                   newPassphrase: String) async throws -> Keys.KeyPair {
        let folder = folder ?? self.folder
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = folder + "/" + name
        try await running(answering: newPassphrase) {
            try await Keys.importPPK(text, passphrase: passphrase, to: path, newPassphrase: newPassphrase, askpass: environment,
                                     log: logger)
        }
        return await listed(path)
    }

    /// Saves `pair` as a PuTTY key at `destination`. The key's own passphrase is `knownPassphrase` when it was typed
    /// here, else asked.
    func exportPPK(_ pair: Keys.KeyPair, to destination: String, passphrase: String,
                   knownPassphrase: String? = nil) async throws {
        try await running(answering: knownPassphrase) {
            try await Keys.exportPPK(pair.privateKey, to: destination, passphrase: passphrase,
                                     askpass: environment, log: logger)
        }
    }

    /// The new key, listed (a key outside the listed folders as one of the others) and selected.
    private func listed(_ path: String) async -> Keys.KeyPair {
        if RemotePath.parent(path) != folder && RemotePath.parent(path) != alsoList() && !others.contains(path) {
            others.append(path)
        }
        await refresh()
        selection = path
        if let pair = pairs.first(where: { $0.privateKey == path }) { return pair }
        return await Keys.describe(path, log: logger)
    }

    /// ssh-add --apple-use-keychain: the agent gets the key, the login Keychain its passphrase (`passphrase` when it was
    /// typed in a sheet, else asked).
    func addToAgent(_ pair: Keys.KeyPair, passphrase: String? = nil) async throws {
        try await running(answering: passphrase) {
            try await Keys.addToAgent(pair.privateKey, askpass: environment, log: logger)
        }
    }

    func promptCancelled() { cancelled = true }

    /// What is wrong with a new key's file name, or nil.
    nonisolated static func nameProblem(_ name: String, in folder: String) -> String? {
        if name.isEmpty { return "Enter a file name." }
        if name.contains("/") || name == "." || name == ".." { return "The name can't contain “/”." }
        if name.hasSuffix(".pub") { return "Enter the private key's name (without .pub)." }
        let path = folder + "/" + name
        if FileManager.default.fileExists(atPath: path) || FileManager.default.fileExists(atPath: path + ".pub") {
            return "A key named \(name) already exists."
        }
        return nil
    }

    /// `base`, else "base_2", "base_3", … (the first that is free).
    nonisolated static func freeName(_ base: String, in folder: String) -> String {
        var name = base
        var number = 2
        while nameProblem(name, in: folder) != nil {
            name = "\(base)_\(number)"
            number += 1
        }
        return name
    }

    /// PuTTY takes RSA, ECDSA and Ed25519 keys (not security keys, nor DSA).
    nonisolated static func canExportToPuTTY(_ pair: Keys.KeyPair) -> Bool {
        ["RSA", "ECDSA", "ED25519"].contains(pair.type)
    }

    private var logger: (LogEntry) -> Void {
        { [weak self] entry in self?.log.append(entry) }
    }
}

struct KeysView: View {
    @ObservedObject var keys: KeysModel
    @ObservedObject var model: AppModel
    let install: (_ publicKey: String, _ hostID: UUID) -> Void
    let report: (_ error: Error, _ title: String) -> Void
    @State private var sheet: KeysSheet?
    @State private var message = ""
    @State private var dropTargeted = false

    /// The window's one sheet: the key sheet (New Key Pair, Import, Export) or Install on Host. One item, so that the
    /// key sheet's Install on Host… can give way to the host chooser.
    private enum KeysSheet: Identifiable {
        case flow(KeyFlow)
        case install(Keys.KeyPair)

        var id: String {
            switch self {
            case .flow(let flow): return flow.id.uuidString
            case .install(let pair): return "install " + pair.id
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Table(keys.pairs, selection: $keys.selection) {
                TableColumn("Name") { pair in
                    Text(RemotePath.parent(pair.privateKey) == keys.folder ? RemotePath.name(pair.privateKey)
                         : (pair.privateKey as NSString).abbreviatingWithTildeInPath)
                }
                TableColumn("Type") { pair in Text(verbatim: "\(pair.type) \(pair.bits)") }  // 2048, as ssh-keygen says it
                    .width(min: 70, ideal: 100)
                TableColumn("Comment") { pair in Text(pair.comment) }
                TableColumn("Fingerprint") { pair in
                    Text(pair.fingerprint).font(.system(.caption, design: .monospaced))
                }
                .width(min: 180, ideal: 330)
            }
            .overlay {
                if keys.pairs.isEmpty {
                    Text("No keys in \(folderName) yet. A key lets you log in without typing a password: New Key Pair… "
                         + "makes one, Install on Host… puts it on a server. Have a PuTTY key (.ppk)? Drop it here.")
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                        .allowsHitTesting(false)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 3).opacity(dropTargeted ? 1 : 0))
            .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: dropped)
            .onReceive(keys.$dropped.compactMap { $0 }) { url in
                keys.dropped = nil
                startImport(url)
            }
            HStack {
                Button("New Key Pair…") { startNewKey() }
                    .help("Make a new key pair (ssh-keygen): Ed25519, ECDSA or RSA, with an optional passphrase")
                Button("Import Key…", action: chooseImport)
                    .help("Turn a PuTTY key (.ppk, from PuTTYgen or WinSCP) into an OpenSSH key in \(folderName)")
                Button("Other Key File…", action: chooseOther)
                    .help("A key outside \(folderName), to install on a host or add to the agent")
                Divider().frame(height: 16)
                copyMenu
                Button("Install on Host…") { keys.selected.map { sheet = .install($0) } }
                    .disabled(noPublicKey || model.data.hosts.isEmpty)
                    .help(noPublicKey || model.data.hosts.isEmpty ? "Select a key with a .pub file, and add a host first"
                          : "Put the public key on a host so you log in without a password (ssh-copy-id)")
                Button("Export for PuTTY…") { if let pair = keys.selected { startExport(pair) } }
                    .disabled(!(keys.selected.map(KeysModel.canExportToPuTTY) ?? false))
                    .help(keys.selected == nil ? "Select a key first"
                          : !KeysModel.canExportToPuTTY(keys.selected!) ? "PuTTY keys can be RSA, ECDSA or Ed25519 only"
                          : "Export as PuTTY Key (.ppk): a copy for PuTTY or WinSCP on Windows")
                Button("Add to Agent", action: addToAgent).disabled(keys.selected == nil || keys.busy)
                    .help(keys.selected == nil ? "Select a key first"
                          : "Adds the key to the ssh agent and its passphrase to your login Keychain")
                // Cut short before the buttons are (whole on hover).
                Text(message).font(.caption).foregroundColor(.secondary).lineLimit(1).layoutPriority(-1).help(message)
                Spacer()
                Button { Task { await keys.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("List the keys in \(folderName) again")
                    .accessibilityLabel("Refresh")
            }
            .padding(10)
            Divider()
            CommandLogView(log: keys.log, emptyText: "Nothing run yet. The ssh-keygen and ssh-add commands this window runs "
                           + "appear here, with their results.")
                .frame(height: 130)
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .flow(let flow):
                KeyFlowView(flow: flow)
            case .install(let pair):
                InstallKeyView(pair: pair, model: model, install: { hostID in
                    self.sheet = nil
                    install(pair.publicKey, hostID)
                }, cancel: { self.sheet = nil })
            }
        }
    }

    private var folderName: String { (keys.folder as NSString).abbreviatingWithTildeInPath }

    /// Where New Key Pair and Import put keys: Settings ▸ Keys, else ~/.ssh.
    private var keyFolder: String {
        model.data.settings.keyFolder.isEmpty ? keys.folder : (model.data.settings.keyFolder as NSString).expandingTildeInPath
    }

    /// Copy Public Key: OpenSSH's line, SSH2 (RFC 4716) or PEM.
    private var copyMenu: some View {
        let formats = keys.selected.map { Keys.PublicFormat.formats(forType: $0.type) } ?? []
        return Menu("Copy Public Key") {
            Button("OpenSSH (one line)") { copyPublicKey(.openSSH) }
                .help("One line, for a server's authorized_keys and most web consoles")
            Button("SSH2 (RFC 4716)") { copyPublicKey(.rfc4716) }
                .help("For commercial SSH servers and some network appliances")
            Button("PEM (PKCS#8)") { copyPublicKey(.pkcs8) }
                .disabled(!formats.contains(.pkcs8))
                .help(formats.contains(.pkcs8) ? "A standard public key (BEGIN PUBLIC KEY), for other tools"
                      : "Ed25519 and security keys have no PEM public key")
        }
        .fixedSize()
        .disabled(noPublicKey)
        .help(keys.selected == nil ? "Select a key first" : noPublicKey ? "This key has no .pub file next to it"
              : "Copy the public key, to paste into a server's authorized_keys or a web console; choose its format")
        .accessibilityIdentifier("keys.copy")
    }

    /// No key selected, or the selected one has no .pub file (Keys.list also lists private keys found alone).
    private var noPublicKey: Bool {
        keys.selected.map { !FileManager.default.fileExists(atPath: $0.publicKey) } ?? true
    }

    private func copyPublicKey(_ format: Keys.PublicFormat) {
        guard let pair = keys.selected else { return }
        Task {
            do {
                let text = try await Keys.publicKey(of: pair.privateKey, format: format)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                message = "Copied the public key of \(RemotePath.name(pair.privateKey))."
            } catch {
                report(error, "Can't copy the public key")
            }
        }
    }

    private var window: NSWindow? { NSApp.windows.first { $0.isVisible && $0.title == "Keys" } }

    private func close() { sheet = nil }

    private func installFromResult(_ pair: Keys.KeyPair) { sheet = .install(pair) }

    private func startNewKey() {
        sheet = .flow(KeyFlow(newKeyIn: keyFolder, keys: keys, downloads: model.data.settings.downloadFolder,
                              install: model.data.hosts.isEmpty ? nil : installFromResult, close: close))
    }

    private func startImport(_ url: URL) {
        sheet = .flow(KeyFlow(importing: url, into: keyFolder, keys: keys, downloads: model.data.settings.downloadFolder,
                              install: model.data.hosts.isEmpty ? nil : installFromResult, close: close))
    }

    private func startExport(_ pair: Keys.KeyPair) {
        sheet = .flow(KeyFlow(exporting: pair, keys: keys, downloads: model.data.settings.downloadFolder, close: close))
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.allowedContentTypes = [UTType(filenameExtension: "ppk") ?? .data]
        panel.message = "Choose a PuTTY private key (.ppk)."
        Panels.run(panel, on: window) { urls in
            if let url = urls.first { startImport(url) }
        }
    }

    /// A .ppk dropped on the list: imported (`KeysModel.dropped`).
    private func dropped(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { [keys] url, _ in
            guard let url, url.isFileURL else { return }
            DispatchQueue.main.async { keys.dropped = url }
        }
        return true
    }

    private func chooseOther() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.message = "Choose a private key (not the .pub file). A PuTTY key (.ppk) is imported."
        Panels.run(panel, on: window) { [keys] urls in
            guard var path = urls.first?.path else { return }
            if PuTTYKey.isEncrypted((try? String(contentsOfFile: path, encoding: .utf8)) ?? "") != nil {
                return startImport(URL(fileURLWithPath: path))
            }
            if path.hasSuffix(".pub") && FileManager.default.fileExists(atPath: String(path.dropLast(4))) {
                path = String(path.dropLast(4))
            }
            Task { await keys.add(path) }
        }
    }

    private func addToAgent() {
        guard let pair = keys.selected else { return }
        Task {
            do {
                try await keys.addToAgent(pair)
                message = "Added \(RemotePath.name(pair.privateKey)) to the agent."
            } catch {
                if (error as? AirSCPError)?.kind != .cancelled { report(error, "Can't add the key to the agent") }
            }
        }
    }
}

struct InstallKeyView: View {
    let pair: Keys.KeyPair
    @ObservedObject var model: AppModel
    let install: (UUID) -> Void
    let cancel: () -> Void
    @State private var hostID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Install “\(RemotePath.name(pair.privateKey))” on a host").font(.headline)
            Picker("Host:", selection: $hostID) {
                Text("Choose a host").tag(UUID?.none)
                ForEach(model.data.hosts.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) {
                    Text($0.displayName).tag(Optional($0.id))
                }
            }
            .help("The host whose account gets the key")
            Text("AirSCP connects to the host and adds the public key to ~/.ssh/authorized_keys of its account "
                 + "(ssh-copy-id; over sftp on an account that only allows file transfers).")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                HelpButton(.installKey)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).help("Close without installing")
                Button("Install") { if let hostID { install(hostID) } }
                    .keyboardShortcut(.defaultAction).primaryTint()
                    .disabled(hostID == nil)
                    .help(hostID == nil ? "Choose a host first" : "Connect and add the key; a password may be asked once")
            }
        }
        .padding(20)
        .frame(width: 440)
    }
}
