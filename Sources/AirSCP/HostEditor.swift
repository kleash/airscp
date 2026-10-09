import AirSCPCore
import AppKit
import SwiftUI

/// The host editor's fields as typed. `validationError` names the first problem; `apply` writes them to a host.
struct HostDraft: Equatable {
    var label = ""
    var hostname = ""
    var port = ""
    var username = ""
    var auth = SSHHost.Auth.agent
    var keyFile = ""
    var jumpHostID: UUID?
    var proxyID: UUID?
    var defaultRemoteDir = ""
    var forwardAgent = false
    /// Seconds between keep-alive messages (ServerAliveInterval).
    var keepAlive = ""
    var autoReconnect = true
    /// Extra ssh options, one "Key=Value" per line.
    var extraOptions = ""
    var groupID: UUID?
    var hostKeyCheck = HostKeyCheck.ask
    /// What was typed in the password field: saved in the Keychain on Save (empty: keep what is saved).
    var password = ""

    init(_ host: SSHHost) {
        label = host.label
        hostname = host.hostname
        port = host.port.map(String.init) ?? ""
        username = host.username
        auth = host.auth
        keyFile = host.keyFile
        jumpHostID = host.jumpHostID
        proxyID = host.proxyID
        defaultRemoteDir = host.defaultRemoteDir
        forwardAgent = host.forwardAgent
        keepAlive = String(host.serverAliveInterval)
        autoReconnect = host.autoReconnect
        extraOptions = host.extraOptions.joined(separator: "\n")
        groupID = host.groupID
        hostKeyCheck = host.hostKeyCheck
    }

    var validationError: String? {
        let name = hostname.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Enter the server's address to begin." }
        if name.contains(where: \.isWhitespace) { return "The host name can't contain spaces." }
        if name.hasPrefix("-") { return "The host name can't start with “-”." }
        let port = self.port.trimmingCharacters(in: .whitespaces)
        if !port.isEmpty && Int(port).map({ (1...65535).contains($0) }) != true {
            return "The port must be a number from 1 to 65535."
        }
        if auth == .keyFile && keyFile.trimmingCharacters(in: .whitespaces).isEmpty { return "Choose the key file." }
        if keepAliveSeconds == nil { return "The keep-alive interval must be a number of seconds from 1 to 3600." }
        if let line = optionLines.first(where: { !Self.isOption($0) }) {
            return "“\(line)” isn't an ssh option. Write one option per line, like Compression=yes."
        }
        return nil
    }

    /// "Key=Value" or "Key Value" (a comment line starting with # is allowed too).
    static func isOption(_ line: String) -> Bool {
        line.hasPrefix("#") || line.range(of: #"^[A-Za-z][A-Za-z0-9]*\s*(=|\s)\s*\S"#, options: .regularExpression) != nil
    }

    private var keepAliveSeconds: Int? {
        Int(keepAlive.trimmingCharacters(in: .whitespaces)).flatMap { (1...3600).contains($0) ? $0 : nil }
    }

    var optionLines: [String] {
        extraOptions.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func apply(to host: inout SSHHost) {
        host.label = label.trimmingCharacters(in: .whitespaces)
        host.hostname = hostname.trimmingCharacters(in: .whitespaces)
        host.port = Int(port.trimmingCharacters(in: .whitespaces))
        host.username = username.trimmingCharacters(in: .whitespaces)
        host.auth = auth
        host.keyFile = keyFile.trimmingCharacters(in: .whitespaces)
        host.jumpHostID = jumpHostID
        host.proxyID = jumpHostID == nil ? proxyID : nil  // through a jump host, the first hop is its own proxy's
        host.defaultRemoteDir = defaultRemoteDir.trimmingCharacters(in: .whitespaces)
        host.forwardAgent = forwardAgent
        host.serverAliveInterval = keepAliveSeconds ?? host.serverAliveInterval
        host.autoReconnect = autoReconnect
        host.extraOptions = optionLines
        host.groupID = groupID
        host.hostKeyCheck = hostKeyCheck
    }
}

/// Test Connection (host editor): logs in with `host` as edited, under another id so that the host's own connection,
/// if it has one, is left alone, and logs out again. `password` (typed in the editor) or the host's saved one answers
/// its first password prompt; other prompts go to `ask`. A prompt cancelled (nil) ends the test, as for Connect: ssh
/// would only ask again. `work` runs once logged in (Install on This Host), its text shown. nil when it was cancelled,
/// else whether it worked and what to show.
@MainActor
func testConnection(_ host: SSHHost, jump: SSHHost?, password: String?, model: AppModel, askpass: AskpassServer,
                    ask: @escaping (Prompt, @escaping (PromptAnswer?) -> Void) -> Void,
                    then work: ((Session) async throws -> String)? = nil) async -> (ok: Bool, text: String)? {
    var tested = host
    tested.id = UUID()
    let saved = model.savedPassword
    let session = Session(host: tested, jump: jump, askpass: askpass)
    session.savedPassword = { $0.id == tested.id ? password ?? saved(host.id.uuidString) : saved($0.id.uuidString) }
    session.savePassword = { _, _ in }
    final class Cancelled { var value = false }
    let cancelled = Cancelled()
    session.onPrompt = { [weak session] prompt, reply in
        guard !cancelled.value else { return reply(nil) }
        ask(prompt) { answer in
            reply(answer)
            guard answer == nil, !cancelled.value else { return }
            cancelled.value = true
            if let session { Task { await session.disconnect() } }
        }
    }
    var result: (ok: Bool, text: String)?
    do {
        try await session.connect()
        result = (true, session.capabilities.shell ? "Logged in." : "Logged in. The account allows file transfers (sftp) only.")
        if let work { result = (true, try await work(session)) }
    } catch {
        let error = error as? AirSCPError ?? AirSCPError(.other, error.localizedDescription)
        result = error.kind == .cancelled || cancelled.value ? nil : (false, error.message)
    }
    await session.disconnect()
    askpass.setHandler(nil, for: tested.id.uuidString)
    return result
}

/// The key file of a host that logs in with one, when that file no longer exists (shown as typed), else nil.
func missingKeyFile(_ host: SSHHost) -> String? {
    guard host.auth == .keyFile, !host.keyFile.isEmpty,
          !FileManager.default.fileExists(atPath: (host.keyFile as NSString).expandingTildeInPath) else { return nil }
    return host.keyFile
}

/// A private key in the host editor's "Log in with" menu.
struct KeyOption: Hashable {
    /// The full path (~ expanded).
    let path: String
    /// "id_ed25519 · ED25519 · sa@mac", or the path for a key outside ~/.ssh, with "(missing)" when it is gone.
    let title: String
    let missing: Bool

    /// The keys in ~/.ssh (`Keys.list`), plus the host's own key file when it isn't one of them: a key outside ~/.ssh,
    /// or one that no longer exists.
    static func options(_ pairs: [Keys.KeyPair], current keyFile: String) -> [KeyOption] {
        var options = pairs.map { pair in
            KeyOption(path: pair.privateKey, title: ([RemotePath.name(pair.privateKey), pair.type] + (pair.comment.isEmpty ? [] : [pair.comment]))
                .joined(separator: " · "), missing: false)
        }
        let current = (keyFile as NSString).expandingTildeInPath
        if !keyFile.isEmpty && !options.contains(where: { $0.path == current }) {
            let missing = !FileManager.default.fileExists(atPath: current)
            options.append(KeyOption(path: current, title: (current as NSString).abbreviatingWithTildeInPath + (missing ? " (missing)" : ""),
                                     missing: missing))
        }
        return options
    }
}

/// The host editor sheet: every setting of a saved host. `close` gets the saved host's id, or nil for Cancel. The
/// usual fields come first; the rarely needed ones are under Advanced, open when one of them isn't at its default.
struct HostEditorView: View {
    /// A line of the "Log in with" menu.
    private enum Login: Hashable { case agent, key(String), other, generate, password }

    @ObservedObject var model: AppModel
    let host: SSHHost
    let isNew: Bool
    /// For Test Connection (none without it).
    let askpass: AskpassServer?
    /// The editor's own sheet, where Test Connection's questions go (AirSCP may not be the active app: an agent).
    let window: () -> NSWindow?
    let close: (UUID?) -> Void
    @State private var draft: HostDraft
    @State private var hasSavedPassword = false
    /// The key pairs in ~/.ssh, listed again each time the editor opens.
    @State private var pairs: [Keys.KeyPair] = []
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var advanced: Bool
    @State private var addingProxy = false
    /// What ssh (or AirSCP) says is wrong with lines of Other ssh options, by line (checked as they are typed).
    @State private var optionProblems: [String: String] = [:]
    /// Generate New Key… and a PuTTY key chosen as the key file (PLAN.md K.1, K.2): the key sheet, and what runs
    /// ssh-keygen for it (its questions are sheets on the editor).
    @State private var keyFlow: KeyFlow?
    @State private var keys: KeysModel?
    @State private var keysAskpassID = "keys-" + UUID().uuidString

    /// The HTTP proxy menu's "Add Proxy…" (it opens the proxy editor and chooses the new proxy).
    private static let addProxy = UUID(uuidString: "00000000-0000-0000-0000-00000000ADD1")!

    /// The Add Common Option… menu: the lines each entry adds, and when you'd use it (PLAN.md U.3). Options the editor
    /// has fields for are left out.
    static let commonOptions: [(lines: [String], why: String)] = [
        (["Compression=yes"], "faster on slow links for text and logs; slower on fast networks"),
        (["ConnectTimeout=10"], "give up after 10 s instead of waiting long for a dead server"),
        (["IdentitiesOnly=yes"], "try only the chosen key (fixes “Too many authentication failures”)"),
        (["PubkeyAcceptedAlgorithms=+ssh-rsa", "HostKeyAlgorithms=+ssh-rsa"], "old servers that only know RSA keys"),
        (["KexAlgorithms=+diffie-hellman-group14-sha1"], "very old servers (“no matching key exchange”)"),
        (["AddressFamily=inet"], "use IPv4 only (when IPv6 hangs)"),
        (["SetEnv LANG=en_US.UTF-8"], "fix garbled characters in names"),
        (["IPQoS=throughput"], "steadier big transfers on some Wi-Fi networks and routers"),
        (["LogLevel=ERROR"], "hide the server's banner noise in the log"),
    ]

    init(model: AppModel, host: SSHHost, isNew: Bool, askpass: AskpassServer? = nil, window: @escaping () -> NSWindow? = { nil },
         close: @escaping (UUID?) -> Void) {
        self.model = model
        self.host = host
        self.isNew = isNew
        self.askpass = askpass
        self.window = window
        self.close = close
        _draft = State(initialValue: HostDraft(host))
        let defaults = SSHHost()
        _advanced = State(initialValue: host.proxyID != nil || host.serverAliveInterval != defaults.serverAliveInterval
                          || host.autoReconnect != defaults.autoReconnect || host.forwardAgent || !host.extraOptions.isEmpty
                          || host.hostKeyCheck != defaults.hostKeyCheck)
    }

    /// The first problem: the draft's own, else one of its Other ssh options lines.
    private var problem: String? {
        draft.validationError ?? optionProblems.sorted { $0.key < $1.key }.first.map { "“\($0.key)”: \($0.value)" }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isNew ? "New Host" : "Edit “\(host.displayName)”").font(.headline)
                Text("A server you log in to over SSH. Only the address is required; the rest has sensible defaults.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Form {
                TextField("Name:", text: $draft.label, prompt: Text("Optional")).accessibilityIdentifier("hostEditor.name")
                    .help("A name for the sidebar; the address is used when empty")
                TextField("Address:", text: $draft.hostname, prompt: Text("Host name, IP address or ~/.ssh/config alias"))
                    .accessibilityIdentifier("hostEditor.hostname")
                    .help("The server's host name or IP address, or an alias from your ~/.ssh/config")
                TextField("Port:", text: $draft.port, prompt: Text("22")).accessibilityIdentifier("hostEditor.port")
                    .help("The SSH port; 22 unless the server uses another")
                TextField("User name:", text: $draft.username, prompt: Text(NSUserName())).accessibilityIdentifier("hostEditor.username")
                    .help("The account on the server; your Mac user name when empty")
                loginPicker.accessibilityIdentifier("hostEditor.login")
                    .help("How ssh proves who you are: a key, the agent, or a password")
                if let key = keyOptions.first(where: { $0.path == currentKey }), key.missing, draft.auth == .keyFile {
                    Text("This key file no longer exists. Choose another key, or the connection will fail.")
                        .font(.caption)
                        .foregroundColor(.red)
                } else {
                    caption("No key yet? Generate New Key… (in this menu) makes one and installs it on the server.")
                }
                if draft.auth == .password {
                    SecureField("Password:", text: $draft.password,
                                prompt: Text(hasSavedPassword ? "Saved in Keychain" : "Asked when connecting"))
                        .accessibilityIdentifier("hostEditor.password")
                        .help("Saved in your Keychain when you type it here; leave it empty to be asked when connecting")
                    if hasSavedPassword {
                        Button("Forget Saved Password") {
                            model.setSavedPassword(host.id.uuidString, nil)
                            hasSavedPassword = false
                        }
                        .help("Remove the password from the Keychain; AirSCP asks for it at the next connect")
                    }
                }
                Picker("Connect through:", selection: $draft.jumpHostID) {
                    Text("None (connect directly)").tag(UUID?.none)
                    ForEach(model.jumpCandidates(for: host)) { Text($0.displayName).tag(Optional($0.id)) }
                }
                .disabled(!model.hostsJumping(through: host.id).isEmpty && draft.jumpHostID == nil)
                .accessibilityIdentifier("hostEditor.jump")
                .help("First log in to this saved host, then reach the server from there (ProxyJump); one hop")
                if !model.hostsJumping(through: host.id).isEmpty {
                    caption("Other hosts go through this one, so it can't go through another host itself (one hop only).")
                } else {
                    caption("For servers behind a bastion. The bastion must be a saved host. (ProxyJump)")
                }
                TextField("Start in folder:", text: $draft.defaultRemoteDir, prompt: Text("Home folder"))
                    .accessibilityIdentifier("hostEditor.remoteFolder")
                    .help("The server folder shown when you connect; empty means the home folder (~ works)")
                Picker("Group:", selection: $draft.groupID) {
                    Text("None").tag(UUID?.none)
                    ForEach(model.data.groups) { Text($0.name).tag(Optional($0.id)) }
                }
                .accessibilityIdentifier("hostEditor.group")
                .help("The sidebar group this host is listed under")
                AdvancedToggle(shown: $advanced, id: "hostEditor.advanced",
                               help: "Rarely needed: an HTTP proxy, keep-alive, reconnecting, agent forwarding and other ssh options")
                if advanced { advancedFields }
            }
            .scrollingOnShortScreens()
            if askpass != nil {
                HStack(spacing: 8) {
                    Button("Test Connection", action: test).disabled(testing || problem != nil)
                        .help("Log in with these settings and out again, without saving; ssh's questions appear here")
                    if testing { ProgressView().controlSize(.small) }
                    if let testResult {
                        Text(testResult.text).font(.caption).foregroundColor(testResult.ok ? .green : .red).lineLimit(2)
                    }
                }
            }
            HStack {
                HelpButton(.host)
                Text(problem ?? "").font(.caption).foregroundColor(.secondary).lineLimit(2)
                Spacer()
                Button("Cancel") { close(nil) }.keyboardShortcut(.cancelAction).help("Close without saving")
                Button(isNew ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction).primaryTint()
                    .disabled(problem != nil)
                    .help(isNew ? "Save this host in the sidebar" : "Save the changes; a connected host uses them at its next connect")
            }
        }
        .padding(20)
        .frame(width: 580)
        .onAppear {
            checkSavedPassword()
            if model.data.proxy(draft.proxyID) == nil { draft.proxyID = nil }  // a proxy this Mac doesn't have
        }
        .onChange(of: draft.auth) { _ in checkSavedPassword() }
        .task { pairs = await Keys.list(in: sshDirectory) }
        .task(id: "\(draft.extraOptions)|\(draft.jumpHostID?.uuidString ?? "")|\(draft.proxyID?.uuidString ?? "")") {
            await checkOptions()
        }
        .sheet(isPresented: $addingProxy) {
            ProxyEditorView(model: model, proxy: Proxy(), isNew: true) { saved in
                addingProxy = false
                if let saved { draft.proxyID = saved }
            }
        }
        .sheet(item: $keyFlow) { KeyFlowView(flow: $0) }
        .onDisappear { askpass?.setHandler(nil, for: keysAskpassID) }
    }

    /// Under Advanced: the HTTP proxy, keep-alive, reconnecting, agent forwarding and other ssh options.
    @ViewBuilder private var advancedFields: some View {
        Picker("HTTP proxy:", selection: Binding(get: { draft.proxyID }, set: { choice in
            if choice == Self.addProxy { addingProxy = true } else { draft.proxyID = choice }
        })) {
            Text("None").tag(UUID?.none)
            ForEach(model.data.proxies) { Text($0.displayName).tag(Optional($0.id)) }
            Divider()
            Text("Add Proxy…").tag(Optional(Self.addProxy))
        }
        .disabled(draft.jumpHostID != nil)
        .accessibilityIdentifier("hostEditor.proxy")
        .help("Reach the server through an HTTP proxy (CONNECT); only when your network needs one")
        caption(draft.jumpHostID != nil ? "The host it connects through uses its own proxy (it is the first hop)."
                : "Only when the network reaches servers through an HTTP proxy. Most people need none.")
        LabeledContent("Keep-alive every:") {
            HStack(spacing: 6) {
                TextField("Keep-alive", text: $draft.keepAlive).labelsHidden().frame(width: 56).accessibilityIdentifier("hostEditor.keepAlive")
                Text("seconds").foregroundColor(.secondary)
            }
        }
        .help("How often the connection checks that the server is still there (ServerAliveInterval). 15 s by default; "
              + "shorter keeps idle connections open through strict firewalls")
        caption("15 seconds by default; the connection counts as lost after 3 unanswered. (ServerAliveInterval)")
        Toggle("Reconnect automatically", isOn: $draft.autoReconnect).accessibilityIdentifier("hostEditor.autoReconnect")
            .help("On by default. When the connection drops, AirSCP reconnects by itself if no question is needed (a key, "
                  + "the agent or a saved password); off, it shows Disconnected and waits")
        Toggle("Let the server use my ssh agent", isOn: $draft.forwardAgent).accessibilityIdentifier("hostEditor.forwardAgent")
            .help("Off by default. On, programs on the server can log in elsewhere with your keys (ForwardAgent=yes); only "
                  + "for servers you trust")
        Picker("Server key:", selection: $draft.hostKeyCheck) {
            ForEach(HostKeyCheck.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .accessibilityIdentifier("hostEditor.hostKey")
        .help("How ssh makes sure this is the right server: Ask (the default) shows a new server's key to trust first. "
              + "Settings ▸ Security sets it for new hosts")
        if draft.hostKeyCheck == .off {
            Text(draft.hostKeyCheck.explanation).font(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 390, alignment: .leading)
        } else {
            caption(draft.hostKeyCheck.explanation)
        }
        LabeledContent("Other ssh options:") {
            VStack(alignment: .leading, spacing: 4) {
                PlainTextEditor(text: $draft.extraOptions, id: "hostEditor.options",
                                help: "Anything else ssh -o would take, one per line, checked as you type")
                    .frame(height: 64)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.35)))
                    .overlay(alignment: .topLeading) {
                        if draft.extraOptions.isEmpty {  // examples, as a placeholder
                            Text("Compression=yes\nConnectTimeout=10")
                                .font(.system(.body, design: .monospaced))
                                .foregroundColor(Color(nsColor: .placeholderTextColor))
                                .padding(.horizontal, 7).padding(.vertical, 4)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
                Menu("Add Common Option…") {
                    ForEach(Self.commonOptions, id: \.lines) { option in
                        Button(option.lines.joined(separator: ", ") + " — " + option.why) { addOption(option.lines) }
                            .help(option.why)
                    }
                }
                .fixedSize()
                .accessibilityIdentifier("hostEditor.addOption")
                .help("Insert a common ssh setting; each one says when you'd use it")
                caption("Extra ssh settings, one per line as Name=value. Leave empty unless you need one.")
                ForEach(optionProblems.sorted { $0.key < $1.key }, id: \.key) { line, reason in
                    Text("“\(line)”: \(reason)").font(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func caption(_ text: String) -> some View { FormCaption(text) }

    /// Add Common Option…: its lines at the end (those that aren't there already).
    private func addOption(_ lines: [String]) {
        let have = Set(draft.optionLines)
        let new = lines.filter { !have.contains($0) }
        guard !new.isEmpty else { return }
        let text = draft.extraOptions.trimmingCharacters(in: .newlines)
        draft.extraOptions = (text.isEmpty ? "" : text + "\n") + new.joined(separator: "\n")
    }

    /// Each Other ssh options line, a moment after typing stops: refused by AirSCP (with why), else checked by
    /// `ssh -G` (which connects nowhere).
    private func checkOptions() async {
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard !Task.isCancelled else { return }
        let routed = draft.jumpHostID != nil || draft.proxyID != nil
        var problems: [String: String] = [:]
        for line in draft.optionLines where !line.hasPrefix("#") && HostDraft.isOption(line) {
            if let refusal = SSHConfig.refusal(line, routed: routed) {
                problems[line] = refusal
            } else if let reason = await SSHConfig.check(line) {
                problems[line] = reason
            }
        }
        guard !Task.isCancelled else { return }
        optionProblems = problems
    }

    /// "Log in with": the agent and default keys, each key in ~/.ssh, the host's own key file, Other…, Password.
    private var loginPicker: some View {
        Picker("Log in with:", selection: Binding(get: { login }, set: choose)) {
            Text("Keys in ~/.ssh and the ssh agent (default)").tag(Login.agent)
            if !keyOptions.isEmpty {
                Divider()
                ForEach(keyOptions, id: \.path) { key in
                    Text(key.title).foregroundColor(key.missing ? .red : nil).tag(Login.key(key.path))
                }
            }
            Divider()
            Text("Choose a Key File…").tag(Login.other)
            Text("Generate New Key…").tag(Login.generate)
            Text("Password").tag(Login.password)
        }
    }

    private var keyOptions: [KeyOption] { KeyOption.options(pairs, current: draft.keyFile) }

    private var currentKey: String { (draft.keyFile as NSString).expandingTildeInPath }

    private var login: Login {
        switch draft.auth {
        case .agent: return .agent
        case .keyFile: return draft.keyFile.isEmpty ? .other : .key(currentKey)
        case .password: return .password
        }
    }

    private func choose(_ choice: Login) {
        switch choice {
        case .agent: draft.auth = .agent
        case .key(let path):
            draft.auth = .keyFile
            draft.keyFile = path
        case .other:
            // Once the pop-up's menu has closed: the default run-loop mode doesn't run while a menu tracks the mouse,
            // and a panel opened inside that loop took AirSCP's keyboard until it closed.
            RunLoop.main.perform(inModes: [.default]) { chooseKey() }
        case .generate:
            RunLoop.main.perform(inModes: [.default]) { startKeyFlow(importing: nil) }
        case .password: draft.auth = .password
        }
    }

    /// Reads the Keychain only for password hosts (reading may ask the user once per AirSCP build).
    private func checkSavedPassword() {
        hasSavedPassword = draft.auth == .password && !isNew && model.savedPassword(host.id.uuidString) != nil
    }

    /// Choose a Key File…: any private key, e.g. outside ~/.ssh.
    private func chooseKey() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: sshDirectory, isDirectory: true)
        panel.message = "Choose the private key (not the .pub file). A PuTTY key (.ppk) is imported first."
        // A sheet on the editor (an app-modal panel would hold up everything, agent control too).
        Panels.run(panel, on: window()) { [self] urls in
            guard var path = urls.first?.path else { return }
            // A PuTTY key: ssh can't read it, so it becomes an OpenSSH key first (Use for This Host then chooses it).
            if PuTTYKey.isEncrypted((try? String(contentsOfFile: path, encoding: .utf8)) ?? "") != nil {
                return startKeyFlow(importing: URL(fileURLWithPath: path))
            }
            if path.hasSuffix(".pub") && FileManager.default.fileExists(atPath: String(path.dropLast(4))) {
                path = String(path.dropLast(4))
            }
            draft.auth = .keyFile
            draft.keyFile = path
        }
    }

    /// Generate New Key… (`importing` nil) or Import of a PuTTY key, in the key sheet on the editor. Its result can be
    /// used for this host, and installed on it with the settings as typed.
    private func startKeyFlow(importing ppk: URL?) {
        guard let askpass else { return }
        let keys = self.keys ?? KeysModel(askpass: askpass.environment(for: keysAskpassID))
        self.keys = keys
        askpass.setHandler({ [window] request, reply in keys.reply(to: request, on: window(), reply) }, for: keysAskpassID)
        let folder = model.data.settings.keyFolder.isEmpty ? sshDirectory : (model.data.settings.keyFolder as NSString).expandingTildeInPath
        let name = (draft.label.isEmpty ? draft.hostname : draft.label).trimmingCharacters(in: .whitespaces)
        let use: (String) -> Void = { path in
            draft.auth = .keyFile
            draft.keyFile = path
            Task { pairs = await Keys.list(in: sshDirectory) }
        }
        let install: ((Keys.KeyPair) -> Void)? = problem == nil ? { pair in
            keyFlow = nil
            installOnThisHost(pair)
        } : nil
        let close = { keyFlow = nil }
        if let ppk {
            keyFlow = KeyFlow(importing: ppk, into: folder, keys: keys, downloads: model.data.settings.downloadFolder,
                              useForHost: use, install: install, installTitle: "Install on This Host", close: close)
        } else {
            keyFlow = KeyFlow(newKeyIn: folder, keys: keys, host: name.isEmpty ? nil : name,
                              downloads: model.data.settings.downloadFolder, useForHost: use, install: install,
                              installTitle: "Install on This Host", close: close)
        }
    }

    /// Install on This Host (the key sheet): logs in with the settings as typed (as Test Connection does) and adds the
    /// key to the account's authorized_keys; then the host logs in with it (Save keeps that). The result shows next to
    /// Test Connection.
    private func installOnThisHost(_ pair: Keys.KeyPair) {
        guard let askpass, let window = window() ?? NSApp.keyWindow else { return }
        var tested = host
        draft.apply(to: &tested)
        let password = draft.auth == .password && !draft.password.isEmpty ? draft.password : nil
        testing = true
        testResult = nil
        Task {
            testResult = await testConnection(tested, jump: model.jump(for: tested), password: password, model: model,
                                              askpass: askpass, ask: { prompt, reply in
                var named: SSHHost? = tested
                if case .password = prompt.kind { named = prompt.host }
                showPrompt(prompt.kind, text: prompt.text, host: named, canRemember: false, on: frontSheet(window),
                           retry: prompt.retry) { answer, _ in reply(answer) }
            }, then: { session in
                try await session.installKey(pair.publicKey)
                return "Installed \(RemotePath.name(pair.privateKey)) on the server: “Log in with” uses it now (Save keeps it)."
            })
            if testResult?.ok == true {
                draft.auth = .keyFile
                draft.keyFile = pair.privateKey
            }
            testing = false
        }
    }

    private func save() {
        var saved = host
        draft.apply(to: &saved)
        model.save(saved)
        if draft.auth == .password && !draft.password.isEmpty { model.setSavedPassword(saved.id.uuidString, draft.password) }
        close(saved.id)
    }

    /// Logs in with the settings as typed, and out again; ssh's questions are sheets on the editor.
    private func test() {
        guard let askpass, let window = window() ?? NSApp.keyWindow else { return }
        var tested = host
        draft.apply(to: &tested)
        let password = draft.auth == .password && !draft.password.isEmpty ? draft.password : nil
        testing = true
        testResult = nil
        Task {
            testResult = await testConnection(tested, jump: model.jump(for: tested), password: password, model: model,
                                              askpass: askpass) { prompt, reply in
                var named: SSHHost? = tested
                if case .password = prompt.kind { named = prompt.host }  // the jump host's, or nil when it names neither
                showPrompt(prompt.kind, text: prompt.text, host: named, canRemember: false, on: window, retry: prompt.retry) {
                    answer, _ in reply(answer)
                }
            }
            testing = false
        }
    }
}

extension View {
    /// An editor sheet's form, in a scroll view as high as a screen of `screenHeight` points has room for (the sheet's
    /// title and buttons, and the window's toolbar above it): with Advanced open, the host and Remote Desktop editors
    /// (821 points) ran off screens under about 860 points. A form that fits shows whole, without scrolling.
    /// A field's focus ring is drawn 3 points outside it, inside the scroll view, which cuts off what goes past its edges
    /// (the first field's ring lost its top, every field's its right edge, and the ring seemed to sit below the field):
    /// the form has 4 points of room inside the scroll view, which reaches 4 points further out, so nothing moves.
    func scrollingOnShortScreens(screenHeight: CGFloat = NSScreen.main?.visibleFrame.height ?? 900) -> some View {
        ScrollView { fixedSize(horizontal: false, vertical: true).padding(4) }
            .frame(maxHeight: max(240, screenHeight - 260))
            .padding(-4)
    }
}

/// The editors' "Advanced" row: a disclosure that shows the rarely needed fields below it, in the form's own columns.
struct AdvancedToggle: View {
    @Binding var shown: Bool
    let id: String
    let help: String

    var body: some View {
        Button { shown.toggle() } label: {
            Label("Advanced", systemImage: shown ? "chevron.down" : "chevron.right")
        }
        .buttonStyle(.borderless)
        .accessibilityIdentifier(id)
        .accessibilityValue(shown ? "shown" : "hidden")
        .help(help + (shown ? "" : ". Click to show them"))
    }
}
