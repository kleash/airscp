import AirSCPCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// New Key Pair, Import Key (a PuTTY .ppk) and Export as PuTTY Key, in one sheet (PLAN.md K.1, K.2): a form, the
/// work, then what came of it. The Keys window opens it, and the host editor (Generate New Key…, a .ppk chosen as the
/// key file). ssh-keygen and ssh-add run through `keys`: their passphrase questions get what was typed here, and any
/// other question (a security key's PIN, the passphrase of a key being exported) is a sheet on this one.
@MainActor
final class KeyFlow: ObservableObject, Identifiable {
    enum Step: Equatable {
        case newKey, importKey, working(String), result, export, exported
    }

    let id = UUID()
    @Published var step: Step
    /// What went wrong, under the form (which stays, to try again).
    @Published var problem: String?
    /// The key made or imported (the result), or the one to export.
    @Published private(set) var pair: Keys.KeyPair?
    /// The result's public key, in `publicFormat`.
    @Published private(set) var publicText = ""
    @Published var publicFormat = Keys.PublicFormat.openSSH {
        didSet { if oldValue != publicFormat { showPublicKey() } }
    }
    @Published private(set) var copied = false
    /// The .ppk written by Export.
    @Published private(set) var exportedFile: String?
    /// Remember in Keychain didn't work (the key was made all the same): why.
    @Published private(set) var rememberProblem: String?

    // The forms' fields.
    @Published var kindID = Keys.Kind.ed25519.id
    @Published var privateFormat = Keys.PrivateFormat.openSSH
    @Published var name = ""
    @Published var folder: String
    @Published var comment: String
    @Published var passphrase = ""
    @Published var confirm = ""
    @Published var remember = false
    @Published var copyAfter = true
    /// Import: the .ppk's own passphrase, and whether the OpenSSH key keeps it.
    @Published var ppkPassphrase = ""
    @Published var samePassphrase = true

    let keys: KeysModel
    /// The .ppk being imported (its text, read when the sheet opened) and whether it is encrypted.
    let ppk: (url: URL, text: String, encrypted: Bool)?
    /// Why the file chosen for Import isn't one.
    private var notPPK: String?
    /// Started from the host editor: the name suggestion (id_ed25519_<host>), and Use for This Host.
    let host: String?
    let useForHost: ((String) -> Void)?
    /// Install on Host… (the Keys window: a host to choose) or Install on This Host (the host editor), given the key.
    let install: ((Keys.KeyPair) -> Void)?
    let installTitle: String
    let close: () -> Void
    /// Where Export's Save panel starts.
    let downloads: String
    /// The passphrase typed for the key made or imported here (Export answers ssh-keygen with it).
    private var knownPassphrase: String?

    init(newKeyIn folder: String, keys: KeysModel, host: String? = nil, downloads: String,
         useForHost: ((String) -> Void)? = nil, install: ((Keys.KeyPair) -> Void)?, installTitle: String = "Install on Host…",
         close: @escaping () -> Void) {
        step = .newKey
        self.folder = folder
        self.keys = keys
        ppk = nil
        self.host = host
        self.downloads = downloads
        self.useForHost = useForHost
        self.install = install
        self.installTitle = installTitle
        self.close = close
        let computer = ProcessInfo.processInfo.hostName.components(separatedBy: ".").first ?? "mac"
        comment = "\(NSUserName())@\(computer)"
        name = suggestedName(for: Keys.Kind.ed25519)
    }

    /// Import Key: `url` is a PuTTY key file (else the sheet says why it can't be imported).
    init(importing url: URL, into folder: String, keys: KeysModel, downloads: String, useForHost: ((String) -> Void)? = nil,
         install: ((Keys.KeyPair) -> Void)?, installTitle: String = "Install on Host…", close: @escaping () -> Void) {
        step = .importKey
        self.folder = folder
        self.keys = keys
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let encrypted = PuTTYKey.isEncrypted(text)
        ppk = (url, text, encrypted ?? false)
        host = nil
        self.downloads = downloads
        self.useForHost = useForHost
        self.install = install
        self.installTitle = installTitle
        self.close = close
        comment = ""
        samePassphrase = encrypted == true
        name = KeysModel.freeName(Self.fileName(url), in: folder)
        if encrypted == nil {
            notPPK = "“\(url.lastPathComponent)” isn't a PuTTY private key file (.ppk). Choose one saved by PuTTYgen or WinSCP."
        }
    }

    /// Export as PuTTY Key for a key that is already there.
    init(exporting pair: Keys.KeyPair, keys: KeysModel, downloads: String, close: @escaping () -> Void) {
        step = .export
        self.pair = pair
        folder = RemotePath.parent(pair.privateKey)
        self.keys = keys
        ppk = nil
        host = nil
        self.downloads = downloads
        useForHost = nil
        install = nil
        installTitle = ""
        self.close = close
        comment = pair.comment
    }

    var kind: Keys.Kind { Keys.Kind.all.first { $0.id == kindID } ?? .ed25519 }

    /// The name for a new key of `kind`: id_ed25519, or id_ed25519_<host> from the host editor; never one in use.
    func suggestedName(for kind: Keys.Kind) -> String {
        let suffix = host.map { "_" + String($0.map { $0.isLetter || $0.isNumber || "._-".contains($0) ? $0 : "_" }) } ?? ""
        return KeysModel.freeName(kind.fileName + suffix, in: folder)
    }

    /// A .ppk file's name without ".ppk", as a key name.
    static func fileName(_ url: URL) -> String {
        let name = url.lastPathComponent
        return name.lowercased().hasSuffix(".ppk") ? String(name.dropLast(4)) : name + "_openssh"
    }

    /// What keeps the form's main button off, or nil.
    var formProblem: String? {
        if case .importKey = step {
            if let notPPK { return notPPK }
            if ppk?.encrypted == true && ppkPassphrase.isEmpty { return "Type the PuTTY key's passphrase." }
        }
        if step == .newKey || step == .importKey {
            if let problem = KeysModel.nameProblem(name, in: folder) { return problem }
            if !(step == .importKey && samePassphrase) && passphrase != confirm { return "The two passphrases aren't the same." }
        }
        if step == .export && passphrase != confirm { return "The two passphrases aren't the same." }
        return nil
    }

    // MARK: Work

    func generate() {
        guard formProblem == nil else { return }
        let kind = self.kind, format = kind.openSSHOnly ? Keys.PrivateFormat.openSSH : privateFormat
        let passphrase = self.passphrase, remember = self.remember && !passphrase.isEmpty
        problem = nil
        step = .working(kind.onSecurityKey ? "Touch the security key when it blinks…" : "Making the key…")
        Task {
            do {
                let pair = try await keys.generate(kind, format: format, name: name, folder: folder, comment: comment,
                                                   passphrase: passphrase)
                knownPassphrase = passphrase
                if remember {
                    do {
                        try await keys.addToAgent(pair, passphrase: passphrase)
                    } catch {
                        let error = error as? AirSCPError ?? AirSCPError(.other, error.localizedDescription)
                        rememberProblem = "The passphrase wasn't remembered in the Keychain: \(error.message)"
                    }
                }
                done(pair, copy: copyAfter)
            } catch {
                failed(error, back: .newKey)
            }
        }
    }

    func importKey() {
        guard formProblem == nil, let ppk else { return }
        let newPassphrase = ppk.encrypted && samePassphrase ? ppkPassphrase : passphrase
        problem = nil
        step = .working("Importing the key…")
        Task {
            do {
                let pair = try await keys.importPPK(ppk.text, passphrase: ppkPassphrase, name: name, folder: folder,
                                                    newPassphrase: newPassphrase)
                knownPassphrase = newPassphrase
                done(pair, copy: false)
            } catch {
                failed(error, back: .importKey)
            }
        }
    }

    /// Export…: a Save panel on this sheet, then the .ppk.
    func export(on window: NSWindow?) {
        guard formProblem == nil, let pair else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = RemotePath.name(pair.privateKey) + ".ppk"
        panel.allowedContentTypes = [UTType(filenameExtension: "ppk") ?? .data]
        panel.directoryURL = URL(fileURLWithPath: downloads, isDirectory: true)
        panel.message = "Where to save the PuTTY key (.ppk)."
        Panels.run(panel, on: window) { [self] urls in
            guard let url = urls.first else { return }
            let passphrase = self.passphrase, known = knownPassphrase
            problem = nil
            step = .working("Writing the PuTTY key…")
            Task {
                do {
                    try await keys.exportPPK(pair, to: url.path, passphrase: passphrase, knownPassphrase: known)
                    exportedFile = url.path
                    step = .exported
                } catch {
                    failed(error, back: .export)
                }
            }
        }
    }

    private func done(_ pair: Keys.KeyPair, copy: Bool) {
        self.pair = pair
        passphrase = ""
        confirm = ""
        ppkPassphrase = ""
        step = .result
        // The format chosen in the form, if the key comes in it.
        if !Keys.PublicFormat.formats(forType: pair.type).contains(publicFormat) { publicFormat = .openSSH }
        Task {
            showPublicKey()
            if copy {
                await loaded()
                copyPublicKey()
            }
        }
    }

    private func failed(_ error: Error, back: Step) {
        let error = error as? AirSCPError ?? AirSCPError(.other, error.localizedDescription)
        if error.kind == .cancelled { return close() }
        problem = error.message
        step = back
    }

    /// The result's public key in the chosen format.
    func showPublicKey() {
        guard let pair else { return }
        let format = publicFormat
        loading = Task {
            let text = (try? await Keys.publicKey(of: pair.privateKey, format: format)) ?? ""
            if format == publicFormat { publicText = text }
        }
    }

    private var loading: Task<Void, Never>?

    private func loaded() async { await loading?.value }

    func copyPublicKey() {
        guard !publicText.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(publicText, forType: .string)
        copied = true
    }

    /// Export as PuTTY Key from the result: the key just made or imported.
    func startExport() {
        passphrase = ""
        confirm = ""
        problem = nil
        step = .export
    }

    func chooseFolder(on window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: folder, isDirectory: true)
        panel.prompt = "Choose"
        panel.message = "Choose the folder for the key pair."
        Panels.run(panel, on: window) { [self] urls in
            guard let url = urls.first else { return }
            let suggested = name == suggestedName(for: kind)
            folder = url.path
            if suggested && step == .newKey { name = suggestedName(for: kind) }
            if step == .importKey, let ppk { name = KeysModel.freeName(Self.fileName(ppk.url), in: folder) }
        }
    }
}

/// The sheet's views, by step.
struct KeyFlowView: View {
    @ObservedObject var flow: KeyFlow
    @State private var advanced = false
    @State private var window: NSWindow?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch flow.step {
            case .newKey: newKey
            case .importKey: importKey
            case .working(let text):
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(text)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            case .result: result
            case .export: export
            case .exported: exported
            }
        }
        .padding(20)
        .frame(width: 560)
        .background(WindowReader(window: $window))
    }

    // MARK: New Key Pair

    private var newKey: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("New Key Pair", "A key lets you log in without typing a password: make one here, then install it on a server.")
            Form {
                Picker("Type:", selection: $flow.kindID) {
                    ForEach(Keys.Kind.available) { Text($0.title).tag($0.id) }
                }
                .accessibilityIdentifier("newKey.type")
                .help("The kind of key and its size. Ed25519 suits nearly every server. DSA isn't offered: it is obsolete "
                      + "and modern OpenSSH refuses it." + (Keys.securityKeysSupported ? ""
                        : " Security keys (YubiKey) need ssh-keygen with FIDO support, which macOS's doesn't have."))
                FormCaption(flow.kind.explanation)
                TextField("Name:", text: $flow.name).accessibilityIdentifier("newKey.name")
                    .help("The file name; the public key is saved next to it as <name>.pub. An existing key is never replaced")
                folderRow(id: "newKey.folder")
                TextField("Comment:", text: $flow.comment, prompt: Text("Optional")).accessibilityIdentifier("newKey.comment")
                    .help("A note stored in the public key, usually you@mac, so you can tell keys apart on a server")
                passphraseFields(("newKey.passphrase", "newKey.confirm"), label: "Passphrase:")
                FormCaption("Optional. A passphrase protects the key if someone copies the file; you type it, or the "
                            + "Keychain does, when the key is used.")
                Toggle("Remember the passphrase in Keychain", isOn: $flow.remember)
                    .disabled(flow.passphrase.isEmpty || Keychain.memoryOnly)
                    .accessibilityIdentifier("newKey.remember")
                    .help(Keychain.memoryOnly ? "This AirSCP is a test instance (AIRSCP_SUPPORT_DIR): it doesn't use the Keychain"
                          : flow.passphrase.isEmpty ? "Type a passphrase first"
                          : "Off by default. On, macOS unlocks the key for ssh (ssh-add --apple-use-keychain), so you aren't asked")
                Toggle("Copy the public key after generating", isOn: $flow.copyAfter)
                    .accessibilityIdentifier("newKey.copy")
                    .help("On by default: the public key goes on the clipboard, ready to paste into a server or web console")
                AdvancedToggle(shown: $advanced, id: "newKey.advanced",
                               help: "Rarely needed: the private key's file format and the public key's format for copying")
                if advanced {
                    Picker("Private key format:", selection: $flow.privateFormat) {
                        Text("OpenSSH (default)").tag(Keys.PrivateFormat.openSSH)
                        Text("PEM (PKCS#1 or SEC1)").tag(Keys.PrivateFormat.pem)
                        Text("PKCS#8").tag(Keys.PrivateFormat.pkcs8)
                    }
                    .disabled(flow.kind.openSSHOnly)
                    .accessibilityIdentifier("newKey.format")
                    .help(flow.kind.openSSHOnly ? "\(flow.kind.title.components(separatedBy: " ").first ?? "These") keys come in "
                          + "OpenSSH's format only" : "How the private key file is written; OpenSSH's own format unless a tool needs another")
                    FormCaption(flow.kind.openSSHOnly ? "Ed25519 and security keys come in OpenSSH's format only."
                                : "PEM: older tools and libraries (BEGIN RSA/EC PRIVATE KEY). PKCS#8: Java, .NET and OpenSSL "
                                    + "(BEGIN PRIVATE KEY). ssh reads all three.")
                    publicFormatPicker(id: "newKey.publicFormat", formats: flow.kind.openSSHOnly ? [.openSSH, .rfc4716]
                                        : Keys.PublicFormat.allCases)
                }
            }
            buttons(primary: "Generate", help: "Make the key pair with ssh-keygen", action: flow.generate)
        }
        .onChange(of: flow.kindID) { _ in
            // The name follows the type while it is still a suggestion.
            if Keys.Kind.all.contains(where: { flow.name.hasPrefix($0.fileName) }) { flow.name = flow.suggestedName(for: flow.kind) }
            if flow.kind.openSSHOnly {
                flow.privateFormat = .openSSH
                if flow.publicFormat == .pkcs8 { flow.publicFormat = .openSSH }
            }
        }
    }

    // MARK: Import Key

    private var importKey: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Import “\(flow.ppk?.url.lastPathComponent ?? "")”",
                   "A PuTTY key (from PuTTYgen or WinSCP) becomes an OpenSSH key that ssh and AirSCP use. The .ppk file "
                    + "stays as it is.")
            Form {
                if flow.ppk?.encrypted == true {
                    SecureField("PuTTY key's passphrase:", text: $flow.ppkPassphrase, prompt: Text("Required"))
                        .accessibilityIdentifier("importKey.ppkPassphrase")
                        .help("The passphrase the .ppk file was saved with")
                }
                TextField("Name:", text: $flow.name).accessibilityIdentifier("importKey.name")
                    .help("The new key's file name; the public key goes next to it as <name>.pub. An existing key is never "
                          + "replaced")
                folderRow(id: "importKey.folder")
                if flow.ppk?.encrypted == true {
                    Toggle("Keep the same passphrase", isOn: $flow.samePassphrase).accessibilityIdentifier("importKey.same")
                        .help("On by default: the new key is protected with the PuTTY key's passphrase. Off: choose another, "
                              + "or none")
                }
                if flow.ppk?.encrypted != true || !flow.samePassphrase {
                    passphraseFields(("importKey.passphrase", "importKey.confirm"), label: "New passphrase:")
                    FormCaption("Optional. A passphrase protects the key if someone copies the file.")
                }
            }
            buttons(primary: "Import", help: "Check the key file and save it as an OpenSSH key", action: flow.importKey)
        }
    }

    // MARK: The result

    private var result: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let pair = flow.pair {
                header(flow.ppk == nil ? "Key pair created" : "Key imported",
                       (pair.privateKey as NSString).abbreviatingWithTildeInPath + " and its .pub")
                Text(verbatim: "\(pair.type) \(pair.bits) · \(pair.fingerprint)")  // 2048, not 2,048
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .help("The key's fingerprint, as servers and ssh-keygen -l show it")
                if let problem = flow.rememberProblem {
                    Text(problem).font(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Text("Public key").font(.headline)
                    Spacer()
                    publicFormatPicker(id: "keyResult.format", formats: Keys.PublicFormat.formats(forType: pair.type))
                        .labelsHidden()
                        .fixedSize()
                }
                ScrollView {
                    Text(flow.publicText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(6)
                }
                .frame(height: 76)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.35)))
                .accessibilityIdentifier("keyResult.publicKey")
                HStack {
                    Button("Copy Public Key", action: flow.copyPublicKey)
                        .accessibilityIdentifier("keyResult.copy")
                        .help("Copy the public key in the format shown, to paste into a server's authorized_keys or a web console")
                    if flow.copied {
                        Text("Copied to the clipboard.").font(.caption).foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: pair.privateKey)]) }
                        .help("Show the key files in Finder")
                    Button("Export as PuTTY Key (.ppk)…", action: flow.startExport)
                        .disabled(!KeysModel.canExportToPuTTY(pair))
                        .help(KeysModel.canExportToPuTTY(pair) ? "Save a copy for PuTTY or WinSCP on Windows"
                              : "PuTTY keys can be RSA, ECDSA or Ed25519 only")
                }
                HStack {
                    if let install = flow.install {
                        Button(flow.installTitle) { install(pair) }
                            .help("Put the public key on a server so you log in without a password (ssh-copy-id); its "
                                  + "password is asked once")
                    }
                    Spacer()
                    if let use = flow.useForHost {
                        Button("Done", action: flow.close).help("Close without changing how the host logs in")
                        Button("Use for This Host") {
                            use(pair.privateKey)
                            flow.close()
                        }
                        .keyboardShortcut(.defaultAction).primaryTint()
                        .help("Log in to this host with the new key (Log in with); save the host to keep it")
                    } else {
                        Button("Done", action: flow.close).keyboardShortcut(.defaultAction).primaryTint().help("Close this")
                    }
                }
            }
        }
    }

    // MARK: Export

    private var export: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("Export “\(flow.pair.map { RemotePath.name($0.privateKey) } ?? "")” as a PuTTY key",
                   "A copy for PuTTY 0.75 or later, WinSCP and other Windows tools (.ppk, version 3). The key itself "
                    + "stays as it is.")
            Form {
                passphraseFields(("exportKey.passphrase", "exportKey.confirm"), label: "Passphrase:")
                FormCaption("Optional: protects the .ppk file. If the key has a passphrase, AirSCP asks for it to read the key.")
            }
            buttons(primary: "Export…", help: "Choose where to save the .ppk file") { flow.export(on: window) }
        }
    }

    private var exported: some View {
        VStack(alignment: .leading, spacing: 14) {
            header("PuTTY key saved", (flow.exportedFile.map { ($0 as NSString).abbreviatingWithTildeInPath }) ?? "")
            HStack {
                Spacer()
                Button("Show in Finder") {
                    if let file = flow.exportedFile { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) }
                }
                .help("Show the .ppk file in Finder")
                Button("Done", action: flow.close).keyboardShortcut(.defaultAction).primaryTint().help("Close this")
            }
        }
    }

    // MARK: Parts

    private func header(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(text).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func folderRow(id: String) -> some View {
        LabeledContent("Folder:") {
            HStack {
                Text((flow.folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                Button("Change…") { flow.chooseFolder(on: window) }
                    .accessibilityIdentifier(id)
                    .help("Save the key in another folder (Settings ▸ Keys sets the usual one)")
            }
        }
        .help("Where the key files go: ~/.ssh unless Settings ▸ Keys names another folder")
    }

    /// The passphrase and, once one is typed, the same again; `ids`: their accessibility ids.
    @ViewBuilder private func passphraseFields(_ ids: (passphrase: String, confirm: String), label: String) -> some View {
        SecureField(label, text: $flow.passphrase, prompt: Text("Optional")).accessibilityIdentifier(ids.passphrase)
            .help("Leave it empty for no passphrase. It goes to ssh-keygen only, never into a command line")
        if !flow.passphrase.isEmpty {
            SecureField("Again:", text: $flow.confirm).accessibilityIdentifier(ids.confirm)
                .help("The same passphrase again, to catch a typing mistake")
        }
    }

    private func publicFormatPicker(id: String, formats: [Keys.PublicFormat] = Keys.PublicFormat.allCases) -> some View {
        Picker("Public key format:", selection: $flow.publicFormat) {
            Text("OpenSSH (one line)").tag(Keys.PublicFormat.openSSH)
            Text("SSH2 (RFC 4716)").tag(Keys.PublicFormat.rfc4716)
            if formats.contains(.pkcs8) { Text("PEM (PKCS#8)").tag(Keys.PublicFormat.pkcs8) }
        }
        .accessibilityIdentifier(id)
        .help("OpenSSH: one line for authorized_keys and most consoles. SSH2 (RFC 4716): commercial SSH servers and some "
              + "network appliances. PEM: tools that take a standard public key (not Ed25519)")
    }

    private func buttons(primary: String, help: String, action: @escaping () -> Void) -> some View {
        HStack {
            HelpButton(flow.step == .newKey ? .newKeyPair : .puttyKeys)
            Text(flow.problem ?? flow.formProblem ?? "")
                .font(.caption)
                .foregroundColor(flow.problem == nil ? .secondary : .red)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button("Cancel", action: flow.close).keyboardShortcut(.cancelAction).help("Close without doing anything")
            Button(primary, action: action)
                .keyboardShortcut(.defaultAction).primaryTint()
                .disabled(flow.formProblem != nil)
                .help(flow.formProblem ?? help)
        }
    }
}

/// The NSWindow a SwiftUI view is in (a sheet's, for the panels and questions it opens).
struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if view.window !== window { DispatchQueue.main.async { window = view.window } }
    }
}

/// The frontmost sheet on `window` (or the window itself): where a new question can be shown at once.
@MainActor
func frontSheet(_ window: NSWindow) -> NSWindow {
    var front = window
    while let sheet = front.attachedSheet { front = sheet }
    return front
}
