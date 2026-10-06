import AppKit
import Darwin
import Foundation
import Testing
@testable import AirSCP
@testable import AirSCPCore

// The app's parts that run without anyone at the screen: the model behind the windows, the host editor's checks, the
// connection flow a host window drives (against throwaway sshd servers), Run Command, tunnels, the Keys window's key
// generation, the terminal launcher, the command log, prompt sheets and the alerts' Details.

/// Saved passwords by Keychain key, standing in for the Keychain.
final class Passwords {
    var saved: [String: String] = [:]
}

/// A model with these hosts that saves nowhere (or into `saved`) and keeps passwords in `passwords`, never in the
/// Keychain.
@MainActor
func testModel(_ hosts: [SSHHost] = [], groups: [HostGroup] = [], saved: Recorder<AirSCPData>? = nil,
               passwords: Passwords = Passwords()) -> AppModel {
    _ = TestEnvironment.isolated  // no Keychain, no ~/.ssh
    let model = AppModel(data: AirSCPData(hosts: hosts, groups: groups), store: { saved?.append($0) })
    model.savedPassword = { passwords.saved[$0] }
    model.setSavedPassword = { passwords.saved[$0] = $1 }
    return model
}

// MARK: Model

@MainActor @Test func sidebarGroupsSortsAndSearches() {
    let prod = HostGroup(name: "Prod"), lab = HostGroup(name: "Lab"), empty = HostGroup(name: "Empty")
    var web = SSHHost(label: "web", hostname: "web.example.com")
    web.groupID = prod.id
    var db = SSHHost(label: "Database", hostname: "db.internal", username: "postgres")
    db.groupID = prod.id
    var pi = SSHHost(hostname: "pi.local")
    pi.groupID = lab.id
    let loose = SSHHost(label: "backup", hostname: "10.0.0.5")
    var orphan = SSHHost(hostname: "orphan")
    orphan.groupID = UUID()  // its group was deleted
    let data = AirSCPData(hosts: [web, db, pi, loose, orphan], groups: [prod, lab, empty])

    let sections = AppModel.sections(data, search: "")
    #expect(sections.map(\.title) == ["Hosts", "Empty", "Lab", "Prod"])
    #expect(sections[0].hosts.map(\.displayName) == ["backup", "orphan"])
    #expect(sections[1].hosts.isEmpty)
    #expect(sections[3].hosts.map(\.displayName) == ["Database", "web"])
    // A search matches names, addresses and user names; groups without matches are left out.
    #expect(AppModel.sections(data, search: "POSTGRES").map(\.title) == ["Prod"])
    #expect(AppModel.sections(data, search: " local ").flatMap(\.hosts).map(\.hostname) == ["pi.local"])
    #expect(AppModel.sections(data, search: "nothing like it").isEmpty)
}

@MainActor @Test func duplicatingDeletingAndGroupsSaveTheData() throws {
    var web = SSHHost(label: "web", hostname: "web.example.com", auth: .password)
    web.tunnels = [Tunnel(kind: .local, listenPort: 8080, targetPort: 80)]
    let saved = Recorder<AirSCPData>()
    let passwords = Passwords()
    passwords.saved[web.id.uuidString] = "s3cret"
    let model = testModel([web], saved: saved, passwords: passwords)

    let copy = try #require(model.duplicate(web.id))
    #expect(copy.label == "web copy" && copy.id != web.id && copy.hostname == web.hostname)
    #expect(copy.tunnels.count == 1 && copy.tunnels[0].id != web.tunnels[0].id)
    #expect(model.data.hosts.map(\.id) == [web.id, copy.id])
    #expect(passwords.saved[copy.id.uuidString] == "s3cret")
    #expect(saved.all.last == model.data)

    // Deleting a group keeps its hosts, without a group.
    let group = model.addGroup(named: "Prod")
    model.updateHost(web.id) { $0.groupID = group.id }
    model.renameGroup(group.id, to: "Production")
    #expect(model.data.groups.map(\.name) == ["Production"])
    model.deleteGroup(group.id)
    #expect(model.data.groups.isEmpty && model.host(web.id)?.groupID == nil)

    // Deleting a host forgets its saved password.
    model.delete(copy.id)
    #expect(model.data.hosts.map(\.id) == [web.id] && passwords.saved.keys.sorted() == [web.id.uuidString])

    // A change that changes nothing isn't written.
    let writes = saved.all.count
    model.updateHost(web.id) { $0.label = "web" }
    #expect(saved.all.count == writes)
}

/// A search narrows the Connected section too (many connected hosts hid the matching ones), keeping each row's ⌘ number.
@MainActor @Test func theSearchNarrowsTheConnectedSection() {
    let web = SSHHost(label: "web", hostname: "web"), tgt = SSHHost(label: "my-tgt", hostname: "target")
    let desktop = RDPEntry(label: "tgt desktop", hostname: "win")
    let data = AirSCPData(hosts: [web, tgt], rdpEntries: [desktop])
    let connected = [web.id, tgt.id, desktop.id]
    #expect(AppModel.connectedRows(data, connected: connected, search: " ").map(\.number) == [1, 2, 3])
    let found = AppModel.connectedRows(data, connected: connected, search: "tgt")
    #expect(found.map(\.id) == [tgt.id, desktop.id] && found.map(\.number) == [2, 3])
}

@MainActor @Test func jumpHostsAreOneHopOnly() {
    let bastion = SSHHost(label: "bastion", hostname: "bastion")
    var inner = SSHHost(label: "inner", hostname: "inner")
    inner.jumpHostID = bastion.id
    let other = SSHHost(label: "other", hostname: "other")
    let model = testModel([bastion, inner, other])
    // other may go through bastion, not through inner (two hops).
    #expect(model.jumpCandidates(for: other).map(\.label) == ["bastion"])
    // inner's own jump host stays on its list.
    #expect(model.jumpCandidates(for: inner).map(\.label) == ["bastion", "other"])
    // bastion is someone's jump host, so it can't get one itself.
    #expect(model.jumpCandidates(for: bastion).isEmpty)
    #expect(model.hostsJumping(through: bastion.id).map(\.label) == ["inner"])
}

/// A host given a jump host drops its own HTTP proxy (the jump host's is the first hop), so the proxy isn't counted as
/// used by it, and can be removed.
@MainActor @Test func aJumpHostReplacesTheHostsOwnProxy() {
    let proxy = Proxy(name: "openproxy", host: "proxy.example.com", port: 3128)
    let bastion = SSHHost(label: "bastion", hostname: "bastion")
    var both = SSHHost(label: "both-routes", hostname: "target")
    both.proxyID = proxy.id
    var draft = HostDraft(both)
    draft.jumpHostID = bastion.id
    draft.apply(to: &both)
    #expect(both.proxyID == nil && both.jumpHostID == bastion.id)
    // Saved before this: the proxy a jumped host still names isn't one it uses.
    var old = SSHHost(label: "old", hostname: "old")
    old.proxyID = proxy.id
    old.jumpHostID = bastion.id
    let model = testModel([bastion, both, old])
    model.data.proxies = [proxy]
    #expect(model.hostsUsing(proxy: proxy.id).isEmpty)
}

@MainActor @Test func importsSkipKnownAndOptionLikeNames() {
    let model = testModel([SSHHost(hostname: "web")])
    #expect(model.importAliases(["web", "db", "db", "-oProxyCommand=evil"]).map(\.hostname) == ["db"])
    #expect(model.data.hosts.map(\.hostname) == ["web", "db"])
    let exported = AirSCPData(hosts: [SSHHost(hostname: "-oProxyCommand=evil"), SSHHost(label: "ok", hostname: "ok")])
    let result = model.importHosts(exported)
    #expect(result.imported == ["ok"] && result.skipped == ["-oProxyCommand=evil"])  // said, not dropped silently
    #expect(model.data.hosts.map(\.hostname) == ["web", "db", "ok"])

    // An alias ssh would read as an option is shown, not ticked, and says why.
    let importer = ConfigImport(aliases: ["web", "fresh", "-oProxyCommand=evil"], model: model)
    #expect(importer.rows.map(\.added) == [true, false, false] && importer.chosen == ["fresh"])
    #expect(importer.rows.map(\.chosen) == [false, true, false] && importer.rows[2].refused?.hasPrefix("A name starting with") == true)
    // Options that run a program on this Mac are what an imported file must ask about.
    #expect(["ProxyCommand=sh -c x", "localcommand touch y", "KnownHostsCommand=/bin/k", "PKCS11Provider=/lib.so"]
        .allSatisfy(SSHConfig.runsCommandHere))
    #expect(!["Compression=yes", "ProxyJump=bastion", "PermitLocalCommand=yes"].contains(where: SSHConfig.runsCommandHere))
    let resolved = SSHConfig.Resolved(hostname: "10.0.0.5", user: "deploy", port: 2222, hostKeyAlias: nil,
                                      knownHostsFiles: [], proxyJump: "bastion", proxyCommand: nil)
    #expect(ConfigImport.summary(resolved) == "deploy@10.0.0.5:2222 via bastion")
}

@MainActor @Test func configImportShowsWhatSSHResolves() async {
    _ = TestEnvironment.isolated  // ssh -G reads the tests' own config (-F), never ~/.ssh/config
    let importer = ConfigImport(aliases: ["airscp-alias"], model: testModel())
    await importer.resolve()
    #expect(importer.rows.first?.summary == "airscp-test@127.0.0.1:2222")
}

@Test func hostEditorChecksWhatWasTyped() {
    var draft = HostDraft(SSHHost())
    #expect(draft.validationError == "Enter the server's address to begin.")
    draft.hostname = "-oProxyCommand=evil"
    #expect(draft.validationError?.contains("“-”") == true)
    draft.hostname = " example.com "
    #expect(draft.validationError == nil)
    draft.port = "70000"
    #expect(draft.validationError?.contains("port") == true)
    draft.port = "2222"
    draft.auth = .keyFile
    #expect(draft.validationError == "Choose the key file.")
    draft.keyFile = "~/.ssh/id_test"
    draft.extraOptions = "Compression=yes\n\nnonsense"
    #expect(draft.validationError?.contains("“nonsense”") == true)
    draft.extraOptions = "Compression=yes\n# a comment\n  ServerAliveInterval 30  \n"
    #expect(draft.validationError == nil)

    var host = SSHHost()
    draft.apply(to: &host)
    #expect(host.hostname == "example.com" && host.port == 2222 && host.auth == .keyFile && host.keyFile == "~/.ssh/id_test")
    #expect(host.extraOptions == ["Compression=yes", "# a comment", "ServerAliveInterval 30"])
    #expect(HostDraft(host).port == "2222" && HostDraft(host).extraOptions == "Compression=yes\n# a comment\nServerAliveInterval 30")
    draft.port = ""
    draft.apply(to: &host)
    #expect(host.port == nil)
}

/// A tunnel's route says where each end is: "localhost" is the far end itself, looked up there (ssh -L, -R).
@Test func tunnelTitlesAndChecks() {
    let local = Tunnel(kind: .local, listenPort: 8080, targetHost: "db", targetPort: 5432)
    #expect(TunnelsModel.title(local, server: "web") == "localhost:8080 on this Mac → web → db:5432")
    #expect(TunnelsModel.title(Tunnel(kind: .local, listenPort: 8649, targetPort: 8649), server: "web")
            == "localhost:8649 on this Mac → web → localhost:8649 on web (the server itself)")
    #expect(TunnelsModel.title(Tunnel(kind: .remote, listenPort: 9000, targetHost: "127.0.0.1", targetPort: 3000), server: "web")
            == "localhost:9000 on web → this Mac → 127.0.0.1:3000 on this Mac")
    #expect(TunnelsModel.title(Tunnel(kind: .remote, listenPort: 9000, targetHost: "fe80::1", targetPort: 22), server: "web")
            == "localhost:9000 on web → this Mac → [fe80::1]:22")
    #expect(TunnelsModel.title(Tunnel(kind: .dynamic, listenPort: 1080), server: "web")
            == "localhost:1080 on this Mac (SOCKS proxy) → web → any address web can reach")
    // The editor's preview before anything is typed.
    #expect(TunnelsModel.title(Tunnel(kind: .local, listenPort: 0, targetHost: ""), server: "web") == "localhost:… on this Mac → web → …:…")
    #expect(["localhost", "LOCALHOST", "127.0.0.1", "::1"].allSatisfy(TunnelsModel.isItself) && !TunnelsModel.isItself("db"))
    #expect(TunnelsModel.validationError(local) == nil)
    #expect(TunnelsModel.validationError(Tunnel(kind: .dynamic, listenPort: 1080)) == nil)
    #expect(TunnelsModel.validationError(Tunnel(kind: .local, listenPort: 0)) != nil)
    #expect(TunnelsModel.validationError(Tunnel(kind: .remote, listenPort: 9000, targetHost: "", targetPort: 80)) != nil)
    #expect(TunnelsModel.validationError(Tunnel(kind: .remote, listenPort: 9000, targetPort: 70000)) != nil)
    // Below 1024 on this Mac AirSCP can't listen (Session.startTunnel); on the server a root login can.
    #expect(TunnelsModel.validationError(Tunnel(kind: .local, listenPort: 80, targetPort: 80)) != nil)
    #expect(TunnelsModel.validationError(Tunnel(kind: .dynamic, listenPort: 1023)) != nil)
    #expect(TunnelsModel.validationError(Tunnel(kind: .remote, listenPort: 80, targetPort: 8080)) == nil)
}

@Test func newKeyNamesNeverOverwrite() throws {
    let folder = try scratch()
    try write("x", to: folder + "/id_ed25519")
    try write("x", to: folder + "/id_rsa.pub")
    #expect(KeysModel.nameProblem("id_ed25519", in: folder) != nil)
    #expect(KeysModel.nameProblem("id_rsa", in: folder) != nil)  // its .pub exists
    #expect(KeysModel.nameProblem("a/b", in: folder) != nil)
    #expect(KeysModel.nameProblem("key.pub", in: folder) != nil)
    #expect(KeysModel.nameProblem("", in: folder) != nil)
    #expect(KeysModel.nameProblem("id_new", in: folder) == nil)
    #expect(KeysModel.freeName("id_ed25519", in: folder) == "id_ed25519_2")
    #expect(KeysModel.freeName("id_new", in: folder) == "id_new")
}

@MainActor @Test func keysWindowGeneratesIntoAMissingFolder() async throws {
    let folder = try scratch() + "/ssh dir"
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let prompts = Recorder<String>()
    askpass.setHandler({ request, reply in
        prompts.append(request.prompt)
        reply("")  // no passphrase
    }, for: KeysModel.askpassID)
    let keys = KeysModel(folder: folder, askpass: askpass.environment(for: KeysModel.askpassID))
    try await keys.generate(.ed25519, name: "id_test", comment: "airscp app test")
    var info = stat()
    #expect(lstat(folder, &info) == 0 && info.st_mode & 0o777 == 0o700)
    #expect(keys.pairs.map(\.comment) == ["airscp app test"])
    #expect(keys.selection == folder + "/id_test")
    #expect(prompts.all.count == 2)  // passphrase, and again to confirm
    #expect(await eventually { keys.log.entries.contains { $0.command.contains("ssh-keygen -t ed25519 -C 'airscp app test'") } })
    await #expect(throws: AirSCPError.self) { try await keys.generate(.ed25519, name: "id_test", comment: "again") }
}

@MainActor @Test func cancellingTheNewKeysPassphraseLeavesNoKey() async throws {
    let folder = try scratch()
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let keys = KeysModel(folder: folder, askpass: askpass.environment(for: KeysModel.askpassID))
    var shown = 0
    // As the Keys window does: the user's Cancel, then the rest cancelled unseen.
    askpass.setHandler({ _, reply in
        if keys.cancelled { return reply(nil) }
        shown += 1
        reply(nil)
        keys.promptCancelled()
    }, for: KeysModel.askpassID)
    do {
        try await keys.generate(.ed25519, name: "id_cancelled", comment: "cancelled")
        Issue.record("generated despite the cancel")
    } catch let error as AirSCPError {
        #expect(error.kind == .cancelled)
    }
    // ssh-keygen takes a cancel as an empty passphrase and makes the key anyway: it is removed again.
    #expect(shown == 1)
    #expect(!rawExists(folder + "/id_cancelled") && !rawExists(folder + "/id_cancelled.pub"))
}

@MainActor @Test func commandLogListsTheMasterOnceAndCopiesCommands() {
    let log = CommandLog()
    let master = "/usr/bin/ssh -M -N host"
    func entry(_ command: String, _ status: Int32?, _ stderr: String = "") -> LogEntry {
        LogEntry(date: Date(), hostID: nil, command: command, status: status, stderr: stderr)
    }
    log.append(entry(master, nil))
    log.append(entry("ls", 0))
    log.append(entry(master, 255, "Connection closed\n"))
    #expect(log.entries.map(\.command) == ["ls", master])
    #expect(log.entries.last?.status == 255)
    #expect(log.commands([]) == "ls\n" + master)
    #expect(log.commands([log.entries[0].id]) == "ls")
    #expect(log.errorOutput(Set(log.entries.map(\.id))) == "Connection closed")
    // A command that succeeds again moves down instead of filling the log (the Monitor tab's refresh); failures stay.
    log.append(entry("ls", 0))
    log.append(entry("ls", 2, "No such file\n"))
    log.append(entry("ls", 2, "No such file\n"))
    #expect(log.entries.map(\.command) == [master, "ls", "ls", "ls"])
    log.append(entry("ls", 0))
    #expect(log.entries.map(\.status) == [255, 2, 2, 0])
    for index in 0..<(CommandLog.limit + 10) { log.append(entry("echo \(index)", 0)) }
    #expect(log.entries.count == CommandLog.limit)
    #expect(log.entries.last?.command == "echo \(CommandLog.limit + 9)")
}

// MARK: Terminal

@Test func terminalScriptsRideTheMasterAndRemoveThemselves() async throws {
    let host = SSHHost(label: "Web", hostname: "example.com", port: 2222, username: "deploy")
    let script = TerminalLauncher.script(host, jump: nil)
    #expect(script.hasPrefix("#!/bin/sh\nrm -f -- \"$0\"\nexec /usr/bin/ssh "))
    #expect(script.contains("-o ControlPath=\(Session.socketPath(for: host.id)) -o ControlMaster=no"))
    #expect(script.hasSuffix(" example.com\n") && !script.contains("ASKPASS"))
    let here = TerminalLauncher.script(host, jump: nil, command: OpenSSH.shellIn("/srv/my site"))
    #expect(here.contains(" -t example.com ") && here.contains(Quote.shellWord(OpenSSH.shellIn("/srv/my site"))))

    // The script: named after the host, executable by its owner only, gone once it ran.
    let folder = URL(fileURLWithPath: try scratch())
    let url = try TerminalLauncher.write("#!/bin/sh\nrm -f -- \"$0\"\necho ran\n", name: "a/b:c", in: folder)
    #expect(url.lastPathComponent.hasPrefix("a-b-c ") && url.pathExtension == "command")
    var info = stat()
    #expect(lstat(url.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
    let result = await Runner.run([url.path])
    #expect(result.output == "ran\n" && !rawExists(url.path))

    #expect(TerminalLauncher.opener(.terminal, script: "/a b.command") == ["/usr/bin/open", "-a", "Terminal", "/a b.command"])
    let iTerm = TerminalLauncher.opener(.iTerm, script: "/a b.command")
    #expect(iTerm.first == "/usr/bin/osascript" && iTerm.last == "'/a b.command'")
    #expect(iTerm.contains("create window with default profile command (item 1 of argv)"))
}

// MARK: Alerts and prompt sheets

@MainActor @Test func errorAlertsKeepTheRawOutputUnderDetails() throws {
    _ = NSApplication.shared
    let error = AirSCPError(.refused, "The server refused the connection.",
                            details: "ssh: connect to host x port 22: Connection refused")
    let alert = errorAlert(error, title: "Can't connect to “x”")
    #expect(alert.messageText == "Can't connect to “x”" && alert.informativeText == error.message)
    let details = try #require(alert.accessoryView as? AlertDetails)
    alert.layout()
    let collapsed = alert.window.frame.height
    #expect(!details.isExpanded)
    details.toggle.performClick(nil)
    #expect(details.isExpanded && alert.window.frame.height > collapsed + 100)
    #expect(errorAlert(AirSCPError(.other, "Nothing more to say."), title: nil).accessoryView == nil)
}

@MainActor @Test func promptSheetsAnswerAndCanBeWithdrawn() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    let host = SSHHost(label: "web", hostname: "web.example.com")
    var answers: [String] = []
    func record(_ answer: PromptAnswer?, _ byUser: Bool) {
        answers.append("\(answer?.text ?? "nil") remember:\(answer?.remember ?? false) user:\(byUser)")
    }

    let password = showPrompt(.password(user: "deploy", host: "web.example.com"), text: "deploy@web.example.com's password: ",
                              host: host, canRemember: true, on: window, reply: record)
    #expect(password.messageText == "Password for web")
    let field = try #require(password.accessoryView?.subviews.compactMap { $0 as? NSSecureTextField }.first)
    let remember = try #require(password.accessoryView?.subviews.compactMap { $0 as? NSButton }.first)
    field.stringValue = "s3cret"
    remember.state = .on
    window.endSheet(password.window, returnCode: .alertFirstButtonReturn)

    let text = "The authenticity of host '[web]:2222 ([10.0.0.5]:2222)' can't be established.\n"
        + "ED25519 key fingerprint is SHA256:abc.\nAre you sure you want to continue connecting (yes/no/[fingerprint])? "
    let hostKey = showPrompt(Askpass.classify(text), text: text, host: host, canRemember: false, on: window, reply: record)
    #expect(hostKey.messageText == "Trust “[web]:2222”?")
    window.endSheet(hostKey.window, returnCode: .alertFirstButtonReturn)

    // ssh stopped waiting: the app ends the sheet, which isn't the user's Cancel.
    let passphrase = showPrompt(.passphrase, text: "Enter passphrase for key '/k':", host: nil, canRemember: false,
                                on: window, reply: record)
    window.endSheet(passphrase.window, returnCode: .cancel)
    #expect(await eventually { answers.count == 3 })
    #expect(answers == ["s3cret remember:true user:true", "yes remember:false user:true", "nil remember:false user:false"])
}

// MARK: The connection flow of a host window (throwaway sshd servers)

@MainActor @Test func hostConnectionTrustsANewKeyAndCleansUp() async throws {
    try await withServer { @MainActor server in
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let host = server.host(trustNewHostKeys: false)
        let model = testModel([host])
        let connection = HostConnection(host: host, model: model, askpass: askpass)
        var asked: [PromptKind] = []
        connection.ask = { prompt, reply in
            asked.append(prompt.kind)
            if case .hostKey = prompt.kind { reply(.trust) } else { reply(nil) }
        }
        var states: [Session.State] = []
        connection.onStateChange = { states.append($0) }

        try await connection.connect()
        #expect(await eventually { connection.state == .connected })
        #expect(states == [.connecting, .connected] && model.states[host.id] == .connected)
        #expect(asked.count == 1)
        #expect(connection.session.capabilities.shell && connection.session.capabilities.home == server.home)
        #expect(connection.log.entries.contains { $0.command.hasPrefix("/usr/bin/ssh -M -N ") && $0.status == nil })
        try await connection.connect()  // already connected: nothing happens
        #expect(states.count == 2)

        await connection.disconnect()
        #expect(await eventually { connection.state == .idle })
        #expect(model.states[host.id] == nil && !rawExists(connection.session.socketPath))
        // The master's line now says how it ended (one line, not two).
        #expect(await eventually {
            let master = connection.log.entries.filter { $0.command.hasPrefix("/usr/bin/ssh -M -N ") }
            return master.count == 1 && master[0].status != nil
        })
    }
}

@MainActor @Test func editingAHostMakesANewSessionWhosePromptsStillArrive() async throws {
    try await withServer { @MainActor server in
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let host = server.host(key: server.encryptedKey)
        let model = testModel([host])
        let connection = HostConnection(host: host, model: model, askpass: askpass)
        var asked = 0
        connection.ask = { prompt, reply in
            asked += 1
            if case .passphrase = prompt.kind { reply(PromptAnswer(TestServer.passphrase)) } else { reply(nil) }
        }
        var newSessions = 0
        connection.onNewSession = { _ in newSessions += 1 }

        try await connection.connect()
        weak var first: Session?
        first = connection.session
        await connection.disconnect()
        try await connection.connect()  // nothing edited: the same Session
        #expect(connection.session === first && newSessions == 0)
        await connection.disconnect()

        // An edit that changes how ssh connects: Connect makes a new Session (a Session's host is fixed).
        model.updateHost(host.id) { $0.extraOptions.append("Compression=yes") }
        try await connection.connect()
        #expect(newSessions == 1 && connection.session !== first)
        #expect(connection.session.host.extraOptions.contains("Compression=yes"))
        await connection.disconnect()
        // The old Session going away must not take the host's prompts with it.
        #expect(await eventually { first == nil })
        try await connection.connect()
        #expect(await eventually { connection.state == .connected })
        #expect(asked == 4)
        await connection.disconnect()
    }
}

@MainActor @Test func cancellingAPromptStopsConnectingQuietly() async throws {
    try await withServer { @MainActor server in
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let host = server.host(key: server.encryptedKey)
        let connection = HostConnection(host: host, model: testModel([host]), askpass: askpass)
        var asked = 0
        connection.ask = { [weak connection] _, reply in
            asked += 1
            reply(nil)
            connection?.promptCancelled()
        }
        await #expect(throws: AirSCPError.self) { try await connection.connect() }
        #expect(connection.cancelledByUser && asked == 1)
        // Prompts after the cancel (ssh asking again) are cancelled without being shown.
        let environment = askpass.environment(for: host.id.uuidString)
        let again = await Runner.run([TestEnvironment.airscpBinary, "sa@127.0.0.1's password: "], environment: environment)
        #expect(again.status == 1 && asked == 1)
        #expect(await eventually { connection.state == .idle })

        // The next Connect starts afresh.
        connection.ask = { _, reply in reply(PromptAnswer(TestServer.passphrase)) }
        try await connection.connect()
        #expect(!connection.cancelledByUser)
        await connection.disconnect()
    }
}

@MainActor @Test func changedHostKeyIsReplacedFromTheWindow() async throws {
    try await withServer { @MainActor server in
        let other = server.root + "/other_key"
        try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", other])
        let fakeKey = try #require(read(other + ".pub")).split(separator: " ").prefix(2).joined(separator: " ")
        try "[127.0.0.1]:\(server.port) \(fakeKey)\n".write(toFile: server.knownHosts, atomically: true, encoding: .utf8)

        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let host = server.host(trustNewHostKeys: false)
        let connection = HostConnection(host: host, model: testModel([host]), askpass: askpass)
        var asked = 0
        connection.ask = { prompt, reply in
            asked += 1
            if case .hostKey = prompt.kind { reply(.trust) } else { reply(nil) }
        }
        do {
            try await connection.connect()
            Issue.record("connected despite a changed host key")
        } catch let error as AirSCPError {
            #expect(error.kind == .hostKeyChanged)
        }
        #expect(asked == 0)
        try await connection.removeOldHostKeyAndReconnect()
        #expect(await eventually { connection.state == .connected })
        #expect(asked == 1 && read(server.knownHosts)?.contains(fakeKey) == false)
        await connection.disconnect()
    }
}

@MainActor @Test func runningMastersAreTakenOverAndQuitClosesEverything() async throws {
    try await withServer { @MainActor server in
        let host = server.host()
        let previous = try await server.connectedSession(host)  // as a crashed AirSCP would leave it
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let model = testModel([host])
        let adopted = HostConnection(host: host, model: model, askpass: askpass)
        #expect(await adopted.adopt())
        #expect(adopted.adopted)
        #expect(await eventually { adopted.state == .connected && model.states[host.id] == .connected })

        // It isn't AirSCP's child: checkAdopted notices when it goes.
        try await killMaster(of: previous)
        await adopted.checkAdopted()
        #expect(await eventually {
            if case .disconnected = adopted.state { return true }
            return false
        })

        // Quit disconnects every host (ssh -O exit) within its time limit.
        let second = server.host()
        model.save(second)
        let other = HostConnection(host: second, model: model, askpass: askpass)
        try await adopted.connect()
        try await other.connect()
        #expect(!adopted.adopted)
        let started = Date()
        await AppDelegate().disconnectAll([adopted, other])
        #expect(Date().timeIntervalSince(started) < 20)  // its limit is 15 s (13 s on a busy Mac, all of it done)
        #expect(!rawExists(adopted.session.socketPath) && !rawExists(other.session.socketPath))
        #expect(await eventually { adopted.state == .idle && other.state == .idle && model.states.isEmpty })
    }
}

@MainActor @Test func runCommandShowsOutputErrorsAndStatus() async throws {
    try await withServer { @MainActor server in
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let host = server.host()
        let connection = HostConnection(host: host, model: testModel([host]), askpass: askpass)
        try await connection.connect()
        #expect(await eventually { connection.state == .connected })

        let runner = RunCommandModel(connection: connection, command: "echo out; echo err >&2; exit 3")
        #expect(runner.unavailableReason == nil)
        runner.run()
        #expect(await eventually { !runner.running })
        #expect(runner.result?.output == "out\n" && runner.result?.stderr == "err\n" && runner.result?.status == 3)

        let slow = RunCommandModel(connection: connection, command: "sleep 30")
        slow.run()
        try await Task.sleep(nanoseconds: 300_000_000)
        slow.stop()
        #expect(await eventually { !slow.running })
        #expect(slow.failure == "Stopped." && slow.result == nil)
        await connection.disconnect()
    }
}

@MainActor @Test func runCommandIsUnavailableOnAnSFTPOnlyAccount() async throws {
    try await withServer(TestServer.Options(sftpOnly: true)) { @MainActor server in
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let host = server.host()
        let connection = HostConnection(host: host, model: testModel([host]), askpass: askpass)
        try await connection.connect()
        #expect(await eventually { connection.state == .connected })
        #expect(RunCommandModel(connection: connection, command: "ls").unavailableReason?.contains("sftp") == true)
        await connection.disconnect()
    }
}

@MainActor @Test func tunnelsSwitchOnAndOffAndGoOffWithTheConnection() async throws {
    try await withServer { @MainActor server in
        let free = try listener()
        close(free.fd)
        close(free.fd6)
        let busy = try listener()
        defer {
            close(busy.fd)
            close(busy.fd6)
        }
        var host = server.host()
        let open = Tunnel(kind: .local, listenPort: free.port, targetHost: "127.0.0.1", targetPort: server.port)
        let blocked = Tunnel(kind: .dynamic, listenPort: busy.port)
        host.tunnels = [open, blocked]
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let model = testModel([host])
        let connection = HostConnection(host: host, model: model, askpass: askpass)
        try await connection.connect()
        #expect(await eventually { connection.state == .connected })

        let tunnels = TunnelsModel(connection: connection, model: model)
        #expect(tunnels.tunnels.map(\.id) == [open.id, blocked.id] && tunnels.active.isEmpty)
        tunnels.set(open, on: true)
        #expect(await eventually { tunnels.active == [open.id] && tunnels.switching.isEmpty })
        #expect(canConnect(to: free.port))
        tunnels.set(blocked, on: true)
        #expect(await eventually { tunnels.errors[blocked.id]?.kind == .portInUse })
        #expect(tunnels.active == [open.id])

        // Edits are saved with the host; removing one that is on switches it off first.
        tunnels.save(Tunnel(kind: .remote, listenPort: 9000, targetPort: 3000))
        #expect(model.host(host.id)?.tunnels.count == 3)
        tunnels.remove(open)
        #expect(await eventually { tunnels.active.isEmpty && tunnels.switching.isEmpty })
        #expect(model.host(host.id)?.tunnels.map(\.kind) == [.dynamic, .remote])
        #expect(await eventually { !canConnect(to: free.port) })

        tunnels.set(Tunnel(kind: .dynamic, listenPort: free.port), on: true)
        #expect(await eventually { tunnels.active.count == 1 })
        await connection.disconnect()
        tunnels.refresh()
        #expect(tunnels.active.isEmpty)
    }
}

/// ⌘Q with unsaved text in an "Edit in AirSCP" window: the quit stops and the window asks Save / Don't Save / Cancel
/// (AppKit asks only document windows when an app quits).
@MainActor @Test func quittingAsksAboutUnsavedEditorText() throws {
    _ = NSApplication.shared
    _ = TestEnvironment.isolated
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let session = Session(host: SSHHost(hostname: "unused.invalid"), jump: nil, askpass: askpass)
    let editor = RemoteEditor(session: session, path: "/srv/app.conf", text: "port=80\n")
    let window = try #require(editor.window)
    window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
    editor.showWindow(nil)
    let delegate = AppDelegate()
    window.isDocumentEdited = true
    #expect(delegate.applicationShouldTerminate(NSApp) == .terminateCancel)
    let sheet = try #require(window.attachedSheet)
    window.endSheet(sheet, returnCode: .alertSecondButtonReturn)  // Don't Save
    #expect(!window.isVisible)
    #expect(delegate.applicationShouldTerminate(NSApp) == .terminateNow)
}

/// The host editor's Test Connection logs in with the settings as typed and out again, under an id of its own: the
/// host's own connection (socket) is never touched. A failure says why.
@MainActor @Test func hostEditorTestConnectionLogsInAndOut() async throws {
    try await withServer { @MainActor server in
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let host = server.host()
        let model = testModel([host])
        let asked = Recorder<Prompt>()
        let worked = await testConnection(host, jump: nil, password: nil, model: model, askpass: askpass) { prompt, reply in
            asked.append(prompt)
            reply(nil)
        }
        #expect(worked?.ok == true && worked?.text == "Logged in." && asked.all.isEmpty)
        #expect(!rawExists(Session.socketPath(for: host.id)))
        let closed = try listener()
        close(closed.fd)
        close(closed.fd6)
        var refused = host
        refused.port = closed.port
        let failed = await testConnection(refused, jump: nil, password: nil, model: model, askpass: askpass) { _, reply in reply(nil) }
        #expect(failed?.ok == false && failed?.text.contains("refused") == true)
        // An encrypted key whose passphrase is asked (here: cancelled) doesn't log in.
        let cancelled = await testConnection(server.host(key: server.encryptedKey), jump: nil, password: nil, model: model,
                                             askpass: askpass) { prompt, reply in
            asked.append(prompt)
            reply(nil)
        }
        #expect(cancelled?.ok != true && asked.all.map(\.kind) == [.passphrase])
    }
}

/// Other Key File… in the Keys window: a key outside the folder joins the list (after the folder's own), selected, so
/// that Install on Host and Add to Agent work on it (PLAN.md K).
@MainActor @Test func keysFromElsewhereJoinTheList() async throws {
    let folder = try scratch(), elsewhere = try scratch()
    try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "in folder", "-f", folder + "/id_here"])
    try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "outside", "-f", elsewhere + "/aws.pem"])
    let keys = KeysModel(folder: folder, askpass: [:])
    await keys.refresh()
    #expect(keys.pairs.map(\.comment) == ["in folder"])
    await keys.add(elsewhere + "/aws.pem")
    #expect(keys.pairs.map(\.comment) == ["in folder", "outside"] && keys.selected?.privateKey == elsewhere + "/aws.pem")
    #expect(keys.selected?.type == "ED25519" && keys.selected?.publicKey == elsewhere + "/aws.pem.pub")
    await keys.add(elsewhere + "/aws.pem")  // once only
    await keys.refresh()
    #expect(keys.pairs.count == 2)
}
