import AppKit
import Darwin
import Foundation
import Testing
@testable import AirSCP
@testable import AirSCPCore

// The main window (ui-shell): the Connected section and ⌘1…9, workspaces kept while connected, RDP entries, proxies
// and their passwords, the host editor's new fields and key menu, the appearance setting, Terminal's exports and the
// command log's bounds.

/// A main window that isn't shown (off screen, where a sheet or ⌘1 would show it). Window work holds up the main queue,
/// and so other tests' callbacks: these tests do theirs before waiting for anything, and none waits for a server.
@MainActor
private func testWindow(_ model: AppModel, _ askpass: AskpassServer) -> MainWindowController {
    let main = MainWindowController(model: model, askpass: askpass)
    main.window?.setFrame(NSRect(x: -20000, y: -20000, width: 1000, height: 640), display: false)
    return main
}

@MainActor
private func views<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
    guard let view else { return [] }
    return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
}

// MARK: Model

@MainActor @Test func connectedSectionKeepsTheOrderThingsConnectedIn() {
    let model = testModel()
    let a = UUID(), b = UUID(), desktop = UUID()
    model.states[a] = .connecting
    model.rdpStates[desktop] = .connecting
    model.states[b] = .connected
    #expect(model.connected == [a, desktop, b])
    model.states[a] = .connected  // a change of state keeps the place
    #expect(model.connected == [a, desktop, b])
    model.states[a] = nil
    #expect(model.connected == [desktop, b])
    model.states[a] = .reconnecting(nextTry: Date())
    model.rdpStates[desktop] = nil
    #expect(model.connected == [b, a])
}

@Test func transferBadgesCountQueuedAndRunningJobsPerHost() {
    let a = UUID(), b = UUID()
    func job(_ host: UUID, _ status: TransferJob.Status) -> TransferJob {
        TransferJob(id: UUID(), direction: .upload, hostID: host, sourceHostID: nil, source: "/x", destination: "/y",
                    names: [], isFolder: false, replacing: false, preserveTimes: false, status: status)
    }
    let jobs = [job(a, .running), job(a, .queued), job(a, .done), job(b, .failed(AirSCPError(.other, "x"))), job(b, .queued),
                job(b, .cancelled)]
    #expect(AppModel.activeTransferCounts(jobs) == [a: 2, b: 1])
    #expect(AppModel.activeTransferCounts([job(a, .done)]).isEmpty)
}

@MainActor @Test func rdpEntriesAndProxiesAreSavedDuplicatedAndForgotten() throws {
    let bastion = SSHHost(label: "bastion", hostname: "bastion")
    var inner = SSHHost(label: "inner", hostname: "inner")
    inner.jumpHostID = bastion.id
    let proxy = Proxy(name: "Office", host: "proxy", port: 3128, username: "me")
    var proxied = SSHHost(label: "proxied", hostname: "far")
    proxied.proxyID = proxy.id
    var windows = RDPEntry(label: "Windows", hostname: "win.example.com", username: "admin")
    windows.viaHostID = bastion.id
    let passwords = Passwords()
    passwords.saved = [windows.keychainKey: "rdp", proxy.keychainKey: "proxy"]
    let model = testModel([bastion, inner, proxied], passwords: passwords)
    model.save(windows)
    model.save(proxy)

    // A host that others go through (jump host or RDP entry) can't be deleted.
    #expect(model.dependents(of: bastion.id) == ["inner", "Windows"])
    #expect(model.dependents(of: inner.id).isEmpty)
    #expect(model.hostsUsing(proxy: proxy.id).map(\.label) == ["proxied"])

    // Sidebar: the entries by name, searched like the hosts.
    model.save(RDPEntry(hostname: "alpha.example.com"))
    #expect(AppModel.rdpEntries(model.data, search: "").map(\.displayName) == ["alpha.example.com", "Windows"])
    #expect(AppModel.rdpEntries(model.data, search: "ADMIN").map(\.displayName) == ["Windows"])

    let copy = try #require(model.duplicateRDPEntry(windows.id))
    #expect(copy.label == "Windows copy" && copy.id != windows.id && copy.viaHostID == bastion.id)
    #expect(passwords.saved[copy.keychainKey] == "rdp")  // as for hosts, the copy has the password too
    model.deleteRDPEntry(windows.id)
    #expect(model.rdpEntry(windows.id) == nil && passwords.saved[windows.keychainKey] == nil)
    model.deleteProxy(proxy.id)
    #expect(model.data.proxies.isEmpty && passwords.saved == [copy.keychainKey: "rdp"])
}

// MARK: Editors

@Test func hostEditorChecksKeepAliveAndKeepsTheNewSettings() {
    var host = SSHHost(hostname: "example.com")
    host.serverAliveInterval = 30
    host.autoReconnect = false
    var draft = HostDraft(host)
    #expect(draft.keepAlive == "30" && !draft.autoReconnect && draft.validationError == nil)
    for wrong in ["", "0", "3601", "ten"] {
        draft.keepAlive = wrong
        #expect(draft.validationError?.contains("keep-alive") == true)
    }
    draft.keepAlive = " 5 "
    draft.autoReconnect = true
    let proxy = UUID()
    draft.proxyID = proxy
    draft.apply(to: &host)
    #expect(host.serverAliveInterval == 5 && host.autoReconnect && host.proxyID == proxy)
}

@Test func keyMenuListsTheKeysAndMarksAMissingOne() throws {
    let folder = try scratch()
    try write("key", to: folder + "/elsewhere")
    func pair(_ name: String, _ type: String, _ comment: String) -> Keys.KeyPair {
        Keys.KeyPair(privateKey: folder + "/" + name, publicKey: folder + "/" + name + ".pub", bits: 256,
                     fingerprint: "SHA256:x", comment: comment, type: type)
    }
    let pairs = [pair("id_ed25519", "ED25519", "sa@mac"), pair("id_rsa", "RSA", "")]
    // The host's key is one of them: just the keys.
    #expect(KeyOption.options(pairs, current: folder + "/id_rsa").map(\.title) == ["id_ed25519 · ED25519 · sa@mac", "id_rsa · RSA"])
    // A key elsewhere is added; one that is gone is marked.
    let other = KeyOption.options(pairs, current: folder + "/elsewhere")
    #expect(other.count == 3 && other[2].path == folder + "/elsewhere" && !other[2].missing)
    let gone = KeyOption.options(pairs, current: folder + "/id_gone")
    #expect(gone.last?.missing == true && gone.last?.title.hasSuffix(" (missing)") == true)
    #expect(KeyOption.options([], current: "").isEmpty)

    var host = SSHHost(hostname: "example.com", auth: .keyFile, keyFile: folder + "/id_gone")
    #expect(missingKeyFile(host) == folder + "/id_gone")
    host.keyFile = folder + "/elsewhere"
    #expect(missingKeyFile(host) == nil)
    host.auth = .agent
    host.keyFile = folder + "/id_gone"
    #expect(missingKeyFile(host) == nil)  // not used
}

@Test func proxyEditorChecksWhatWasTyped() {
    var draft = ProxyDraft(Proxy())
    #expect(draft.port == "8080" && draft.validationError?.contains("host") == true)
    draft.host = "proxy example"
    #expect(draft.validationError?.contains("spaces") == true)
    draft.host = " proxy.example.com "
    draft.port = "70000"
    #expect(draft.validationError?.contains("port") == true)
    draft.port = "3128"
    draft.username = " me "
    #expect(draft.validationError == nil)
    var proxy = Proxy()
    draft.apply(to: &proxy)
    #expect(proxy.host == "proxy.example.com" && proxy.port == 3128 && proxy.username == "me" && proxy.displayName == "proxy.example.com:3128")
}

// MARK: Settings, Terminal, command log

@Test func appearanceSettingSetsTheAppsAppearance() {
    #expect(appAppearance(.system) == nil)
    #expect(appAppearance(.light)?.name == .aqua)
    #expect(appAppearance(.dark)?.name == .darkAqua)
}

@Test func terminalScriptsExportTheAskpassEnvironment() {
    let host = SSHHost(hostname: "example.com")
    let script = TerminalLauncher.script(host, jump: nil, environment: ["AIRSCP_ASKPASS_SOCK": "/tmp/a b/sock", "B": "x"])
    #expect(script.hasPrefix("#!/bin/sh\nrm -f -- \"$0\"\nexport AIRSCP_ASKPASS_SOCK='/tmp/a b/sock'\nexport B='x'\nexec /usr/bin/ssh "))
    #expect(!TerminalLauncher.script(host, jump: nil).contains("export"))
}

@MainActor @Test func commandLogCutsHugeEntries() {
    let log = CommandLog()
    let huge = "sftp " + String(repeating: "x", count: 100_000)
    log.append(LogEntry(date: Date(), hostID: nil, command: huge, status: nil, stderr: ""))
    log.append(LogEntry(date: Date(), hostID: nil, command: huge, status: 1, stderr: String(repeating: "e", count: 50_000) + "the end"))
    #expect(log.entries.count == 1)  // the finished line replaced the running one
    let entry = log.entries[0]
    #expect(entry.command.count < CommandLog.textLimit + 100 && entry.command.hasPrefix("sftp xxx"))
    #expect(entry.command.contains("characters left out"))
    #expect(entry.stderr.hasSuffix("the end") && entry.stderr.count < CommandLog.textLimit + 100)
    #expect(CommandLog.cut("short") == "short")
}

// MARK: Main window

@MainActor @Test func proxyPasswordsComeFromTheKeychainOrAPrompt() throws {
    _ = NSApplication.shared
    let open = Proxy(name: "Open", host: "proxy", port: 3128)
    let saved = Proxy(name: "Saved", host: "proxy", port: 3128, username: "me")
    let asked = Proxy(name: "Asked", host: "proxy", port: 3128, username: "you")
    let passwords = Passwords()
    passwords.saved[saved.keychainKey] = "s3cret"
    let model = testModel(passwords: passwords)
    [open, saved, asked].forEach(model.save)
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let main = testWindow(model, askpass)
    defer { main.window?.orderOut(nil) }
    var replies: [String] = []
    func record(_ answer: (proxy: Proxy, password: String)?) {
        replies.append(answer.map { "\($0.proxy.name):\($0.password)" } ?? "nil")
    }

    main.answerProxy(open.id, mayAsk: true, reply: record)  // no user name: no password
    main.answerProxy(saved.id, mayAsk: true, reply: record)
    main.answerProxy(asked.id, mayAsk: false, reply: record)  // a silent reconnect never asks
    main.answerProxy(UUID(), mayAsk: false, reply: record)  // not on this Mac
    #expect(replies == ["Open:", "Saved:s3cret", "nil", "nil"] && main.window?.attachedSheet == nil)
    // A proxy not on this Mac, when asking is allowed: explained (ssh only sees a cancel).
    main.answerProxy(UUID(), mayAsk: true, reply: record)
    let window = try #require(main.window)
    let alert = try #require(window.attachedSheet)
    #expect(replies.last == "nil" && views(NSTextField.self, in: alert.contentView).contains { $0.stringValue.contains("isn't saved") })
    window.endSheet(alert, returnCode: .alertFirstButtonReturn)

    // Asked, with Remember: the reply and the Keychain get it.
    main.answerProxy(asked.id, mayAsk: true, reply: record)
    let sheet = try #require(window.attachedSheet)
    #expect(views(NSTextField.self, in: sheet.contentView).contains { $0.stringValue == "Proxy “Asked” needs a password" })
    try #require(views(NSSecureTextField.self, in: sheet.contentView).first).stringValue = "typed"
    try #require(views(NSButton.self, in: sheet.contentView).first { $0.title == "Remember in Keychain" }).state = .on
    window.endSheet(sheet, returnCode: .alertFirstButtonReturn)  // the alert's handler runs before this returns
    #expect(replies.count == 6 && replies.last == "Asked:typed" && passwords.saved[asked.keychainKey] == "typed")
}

/// A proxy that rejects its saved password (HTTP 407): the password is forgotten, so that the next Connect asks for it
/// instead of failing the same way. A host with a jump host goes through the jump host's proxy.
@MainActor @Test func aRejectedProxyPasswordIsForgotten() {
    let proxy = Proxy(name: "Office", host: "proxy", port: 3128, username: "me")
    let passwords = Passwords()
    passwords.saved[proxy.keychainKey] = "wrong"
    var direct = SSHHost(hostname: "direct")
    direct.proxyID = proxy.id
    var bastion = SSHHost(hostname: "bastion")
    bastion.proxyID = proxy.id
    var inner = SSHHost(hostname: "inner")
    inner.jumpHostID = bastion.id
    let model = testModel([direct, bastion, inner], passwords: passwords)
    model.save(proxy)
    let refused = ErrorMapping.map("ssh: connect to host direct port 22: Connection refused", status: 255)
    let rejected = ErrorMapping.map("AirSCP proxy: HTTP/1.1 407 Proxy Authentication Required\n"
                                    + "Connection closed by UNKNOWN port 65535", status: 255)
    #expect(!model.forgetRejectedProxyPassword(for: direct, after: refused) && passwords.saved[proxy.keychainKey] == "wrong")
    #expect(model.forgetRejectedProxyPassword(for: inner, after: rejected) && passwords.saved[proxy.keychainKey] == nil)
    #expect(!model.forgetRejectedProxyPassword(for: direct, after: rejected))  // nothing saved any more
}

@MainActor @Test func rdpEntriesGetADesktopWhenShown() async throws {
    _ = NSApplication.shared
    var entry = RDPEntry(label: "Windows", hostname: "win")
    let host = SSHHost(label: "bastion", hostname: "bastion")
    entry.viaHostID = host.id
    let model = testModel([host])
    model.save(entry)
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let main = testWindow(model, askpass)
    defer { main.window?.orderOut(nil) }

    main.sidebar.selection = .rdp(entry.id)
    let desktop = try #require(main.desktops[entry.id])
    #expect(desktop.entryID == entry.id && main.window?.title == "Windows")
    // Connect and Disconnect (toolbar, Host menu) act on the selected entry's desktop; host-only commands are off.
    func enabled(_ action: Selector) -> Bool { main.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")) }
    #expect(enabled(#selector(MainWindowController.connectHost(_:))))
    #expect(!enabled(#selector(MainWindowController.disconnectHost(_:))))
    #expect(!enabled(#selector(MainWindowController.openTerminal(_:))) && !enabled(#selector(MainWindowController.runCommand(_:))))
    // Its state shows in the sidebar and the Connected section.
    desktop.onStateChange?(.connecting)
    #expect(model.rdpStates[entry.id] == .connecting && model.connected == [entry.id])
    #expect(main.window?.subtitle == "Not connected · via bastion")  // the desktop's own state is still idle, and its route

    // Deleting the entry ends its desktop and forgets it.
    main.remove(.rdp(entry.id))
    #expect(model.rdpEntry(entry.id) == nil && main.desktops.isEmpty && model.rdpStates.isEmpty && main.sidebar.selection == nil)
}

@MainActor @Test func showingMakesWorkspacesAndIdleOnesGo() throws {
    _ = NSApplication.shared
    let web = SSHHost(label: "web", hostname: "web"), db = SSHHost(label: "db", hostname: "db")
    let desktop = RDPEntry(label: "Windows", hostname: "win")
    let model = testModel([web, db])
    model.save(desktop)
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let main = testWindow(model, askpass)
    defer { main.window?.orderOut(nil) }

    // Showing a host makes its workspace; an idle one goes when another is shown.
    main.sidebar.selection = .host(web.id)
    let workspace = try #require(main.workspaces[web.id])
    #expect(main.selectedWorkspace === workspace && workspace.window === main.window)
    #expect(main.window?.title == "web" && main.window?.subtitle == "Not connected")
    main.sidebar.selection = .host(db.id)
    #expect(Array(main.workspaces.keys) == [db.id])
    main.sidebar.selection = .rdp(desktop.id)
    #expect(main.workspaces.isEmpty && main.desktops[desktop.id] != nil && main.window?.title == "Windows")

    // ⌘1…⌘9: the Connected section's items, in the order they connected.
    model.states[db.id] = .connected
    model.rdpStates[desktop.id] = .connecting
    model.states[web.id] = .connecting
    main.selectConnected(0)
    #expect(main.sidebar.selection == .connected(db.id) && main.selectedHost?.label == "db" && main.window?.title == "db")
    main.selectConnected(2)
    #expect(main.sidebar.selection == .connected(web.id) && main.selectedWorkspace === main.workspaces[web.id])
    main.selectConnected(5)  // nothing there
    #expect(main.sidebar.selection == .connected(web.id))
    model.states = [:]
    model.rdpStates = [:]
}

/// Reports a connection state as the workspace's Session does (no server needed).
@MainActor
private func report(_ state: Session.State, _ workspace: HostWorkspace?) {
    workspace?.session.onStateChange?(state)
}

@MainActor @Test func connectedHostsKeepTheirWorkspaces() async throws {
    _ = TestEnvironment.isolated  // it runs ssh once (a refused connect): never with ~/.ssh or the app's sockets
    _ = NSApplication.shared
    let a = SSHHost(label: "a", hostname: "a"), b = SSHHost(label: "b", hostname: "b"), c = SSHHost(label: "c", hostname: "c")
    let model = testModel([a, b, c])
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let main = testWindow(model, askpass)

    // Connected (or connecting, reconnecting) hosts keep their workspace while they aren't shown.
    let first = main.workspace(for: a.id)
    report(.connecting, first)
    report(.connected, first)
    report(.connected, main.workspace(for: b.id))
    #expect(model.connected == [a.id, b.id] && main.workspaces.count == 2)
    #expect(main.connectedSessions.map(\.host.id) == [a.id, b.id] && first?.connectedSessions.count == 2)
    report(.reconnecting(nextTry: Date()), main.workspaces[b.id])
    #expect(main.connectedSessions.map(\.host.id) == [a.id] && main.workspaces[b.id] != nil)

    // An idle one goes when it isn't shown, and stays while it is.
    report(.idle, first)
    #expect(main.workspaces[a.id] == nil && model.connected == [b.id])
    main.sidebar.selection = .host(c.id)
    report(.idle, main.workspaces[c.id])
    #expect(main.workspaces[c.id] != nil)

    // Deleting a host disconnects it and lets its workspace go.
    main.remove(.connected(b.id))
    #expect(model.host(b.id) == nil && main.workspaces[b.id] == nil)
    #expect(await eventually { model.connected.isEmpty })
    await #expect(throws: AirSCPError.self) { try await main.connectedSession(for: UUID()) }

    // A connect that fails for a host that isn't shown lets its workspace go (nothing listens on that port).
    var refused = SSHHost(label: "refused", hostname: "127.0.0.1", port: 1)
    refused.extraOptions = ["ConnectTimeout=5"]
    model.save(refused)
    await #expect(throws: AirSCPError.self) { try await main.connectedSession(for: refused.id) }
    #expect(await eventually { main.workspaces[refused.id] == nil })
}

// The SSH host of an RDP entry: its workspace connects it on demand. (No window: window work while waiting for a server
// would hold up the main queue that other tests' callbacks need.)
@MainActor @Test func aWorkspaceConnectsOnDemand() async throws {
    try await withServer { @MainActor server in
        let host = server.host()
        let model = testModel([host])
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let workspace = HostWorkspace(connection: HostConnection(host: host, model: model, askpass: askpass), model: model,
                                      main: nil)
        let session = try await workspace.connectedSession()
        #expect(session.state == .connected && session === workspace.session)
        #expect(await eventually { workspace.connectedSessions.map(\.host.id) == [host.id] && model.connected == [host.id] })
        #expect(try await workspace.connectedSession() === session)  // already connected
        workspace.disconnect()
        #expect(await eventually { model.connected.isEmpty && !rawExists(session.socketPath) })
    }
}

/// A connected host's workspace fills the detail area. (The banner is empty while connected; a maximum width of 0 on
/// it squeezed the workspace and shrank the window.)
@MainActor @Test func aConnectedWorkspaceFillsTheWindow() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        let host = server.host()
        let model = testModel([host])
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let main = testWindow(model, askpass)
        defer { main.window?.orderOut(nil) }
        main.sidebar.selection = .host(host.id)
        let workspace = try #require(main.selectedWorkspace)
        _ = try await workspace.connectedSession()
        #expect(await eventually { model.states[host.id] == .connected })
        main.window?.layoutIfNeeded()
        #expect(main.window?.frame.width == 1000)
        #expect(workspace.view.frame.width > 600)
        workspace.disconnect()
        #expect(await eventually { model.states[host.id] == nil })
    }
}

// MARK: Window sizes

/// A frame AppKit saved is used only when it lies on a screen: Porter's main window, saved taller than the screen,
/// opened AirSCP full height (user report, 2026-10-05). A window's own size is made smaller on a small screen.
@Test func savedFramesAreUsedOnlyWhenTheyFitTheScreen() {
    let screen = NSRect(x: 0, y: 0, width: 1728, height: 1084)
    #expect(WindowFrame.fits("336 180 1118 813 0 0 1728 1084 ", on: [screen]))
    #expect(WindowFrame.fits("0 0 1728 1084 0 0 1728 1084 ", on: [screen]))  // zoomed: the whole visible frame
    #expect(!WindowFrame.fits("338 -966 1113 2050 0 0 1728 1084 ", on: [screen]))  // Porter's: taller than the screen
    #expect(!WindowFrame.fits("200 -40 1100 700 0 0 1728 1084 ", on: [screen]))  // partly below the screen
    #expect(!WindowFrame.fits("1900 200 1100 700 0 0 1728 1084 ", on: [screen]))  // on a display that has gone…
    #expect(WindowFrame.fits("1900 200 1100 700 0 0 1728 1084 ", on: [screen, NSRect(x: 1728, y: 0, width: 1920, height: 1050)]))
    #expect(!WindowFrame.fits("", on: [screen]) && !WindowFrame.fits("10 10 0 0", on: [screen]))
    #expect(!WindowFrame.fits("left top width height", on: [screen]) && !WindowFrame.fits("10 10 800 600", on: []))

    let main = NSSize(width: 1100, height: 700), mainMinimum = NSSize(width: 760, height: 460)
    #expect(WindowFrame.fitted(main, minimum: mainMinimum, on: screen) == main)
    // A 13-inch MacBook Air with the largest text: 85 % of the width, 80 % of the height, never below the minimum.
    let small = NSRect(x: 0, y: 0, width: 1024, height: 615)
    #expect(WindowFrame.fitted(main, minimum: mainMinimum, on: small) == NSSize(width: 870, height: 492))
    #expect(WindowFrame.fitted(NSSize(width: 1000, height: 600), minimum: NSSize(width: 960, height: 420), on: small)
            == NSSize(width: 960, height: 492))
    // A throwaway AirSCP (the tests are one) neither reads nor saves frames: the user's own stay as they are.
    _ = TestEnvironment.isolated
    #expect(layoutName("Main") == nil)
}

/// Nor a pane's columns: without a name AppKit saved them under "(null)" in the user's AirSCP defaults (shared with a
/// throwaway).
@MainActor @Test func aThrowawaysPanesSaveNoColumns() throws {
    _ = TestEnvironment.isolated
    _ = NSApplication.shared
    let pane = FilePane(source: .local, choosesSource: false, showHidden: false)
    _ = pane.view
    #expect(pane.table.autosaveName == nil && !pane.table.autosaveTableColumns)
    let owner = try #require(pane.table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("owner")))
    owner.isHidden.toggle()
    defer { owner.isHidden.toggle() }
    #expect(UserDefaults.standard.object(forKey: "NSTableView Columns v3 (null)") == nil)
}

/// A window with an autosave name opens at its saved frame when that fits on the screen; else at its own size in the
/// middle of the screen, and the bad frame goes. (This test process's own defaults.)
@MainActor @Test func aWindowOpensAtItsSavedFrameOnlyWhenItFits() throws {
    _ = NSApplication.shared
    let visible = try #require(NSScreen.main?.visibleFrame)
    let name = "AirSCPTests.Window", key = "NSWindow Frame AirSCPTests.Window"
    defer { UserDefaults.standard.removeObject(forKey: key) }
    func opened(saved: String?) -> NSWindow {
        UserDefaults.standard.set(saved, forKey: key)
        let window = NSWindow(contentRect: .zero, styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.open(size: NSSize(width: 500, height: 300), autosave: name)
        window.setFrameAutosaveName("")  // the name is free for the next window
        return window
    }
    let screen = [visible.minX, visible.minY, visible.width, visible.height].map { String(Int($0)) }.joined(separator: " ")
    // Nothing saved: its own size, in the middle of the screen.
    var window = opened(saved: nil)
    #expect(window.contentLayoutRect.size == NSSize(width: 500, height: 300))
    #expect(abs(window.frame.midX - visible.midX) <= 1 && visible.contains(window.frame), "\(window.frame) \(visible)")
    // A frame that fits: kept.
    let good = NSRect(x: (visible.minX + 40).rounded(), y: (visible.minY + 30).rounded(), width: 420, height: 260)
    window = opened(saved: "\(Int(good.minX)) \(Int(good.minY)) 420 260 " + screen)
    #expect(window.frame == good)
    // Taller than the screen, as Porter's was: its own size in the middle of the screen, and the bad frame is gone.
    let porter = "\(Int(visible.minX) + 338) \(Int(visible.minY) - 966) 1113 \(Int(visible.height) + 966) " + screen
    window = opened(saved: porter)
    #expect(window.contentLayoutRect.size == NSSize(width: 500, height: 300) && abs(window.frame.midX - visible.midX) <= 1)
    #expect(UserDefaults.standard.string(forKey: key) != porter)
}

// MARK: Menu bar

/// The shell's menus and the browser's File, View and Go items (BrowserContentController.addMenuItems) together: no
/// shortcut is used twice.
@MainActor @Test func menuBarShortcutsAreUsedOnce() {
    _ = NSApplication.shared
    var seen: [String: String] = [:]
    func walk(_ menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu { walk(submenu) }
            guard !item.keyEquivalent.isEmpty else { continue }
            var modifiers = item.keyEquivalentModifierMask
            let key = item.keyEquivalent.lowercased()
            if key != item.keyEquivalent { modifiers.insert(.shift) }  // an upper-case letter means Shift
            let shortcut = "\(key) \(modifiers.rawValue)"
            #expect(seen[shortcut] == nil, "“\(item.title)” and “\(seen[shortcut] ?? "")” have the same shortcut")
            seen[shortcut] = item.title
        }
    }
    let bar = AppDelegate().mainMenu()
    walk(bar)
    #expect(bar.items.map(\.title) == ["AirSCP", "File", "Edit", "View", "Go", "Host", "Tools", "Window", "Help"])
    #expect(seen.count > 40)
}

/// The toolbar's + (an NSMenuToolbarItem) is a pull-down button, whose first item is its title and is never listed: it
/// offered only New Remote Desktop… and New Group…, with or without hosts. It lists New Host… first.
@MainActor @Test func theAddButtonOffersNewHostFirst() throws {
    _ = NSApplication.shared
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    for model in [testModel([]), testModel([SSHHost(label: "web", hostname: "web")])] {
        let main = testWindow(model, askpass)
        defer { main.window?.orderOut(nil) }
        let add = try #require(main.window?.toolbar?.items.first { $0.itemIdentifier == .add } as? NSMenuToolbarItem)
        #expect(add.menu.items.first?.title == "")  // the pull-down's title
        #expect(add.menu.items.dropFirst().map(\.title) == ["New Host…", "New Remote Desktop…", "New Group…"])
        #expect(add.menu.items.dropFirst().allSatisfy { $0.toolTip?.isEmpty == false })
        // AppKit draws it as a pull-down of this menu (when its view is there).
        let frame = main.window?.contentView?.superview
        for button in views(NSPopUpButton.self, in: frame) where button.menu === add.menu { #expect(button.pullsDown) }
    }
}

/// The sidebar's "Debug logging on" had no way to turn it off there: its Turn Off does, and Help ▸ Turn Off Debug
/// Logging (Turn On Debug Logging while it is off) too. Settings keeps its switch.
@MainActor @Test func debugLoggingTurnsOffFromTheSidebarAndTheHelpMenu() async throws {
    _ = NSApplication.shared
    _ = TestEnvironment.isolated
    let model = testModel([])
    let delegate = AppDelegate()
    delegate.model = model
    let help = try #require(delegate.mainMenu().item(withTitle: "Help")?.submenu)
    let toggle = try #require(help.items.first { $0.action == #selector(AppDelegate.toggleDebugLogging(_:)) })
    #expect(delegate.validateMenuItem(toggle) && toggle.title == "Turn On Debug Logging")
    delegate.toggleDebugLogging(toggle)
    #expect(model.data.settings.debugLogging)
    model.debugLoggingOn = true  // as the app's observer of the setting does
    #expect(delegate.validateMenuItem(toggle) && toggle.title == "Turn Off Debug Logging")
    delegate.toggleDebugLogging(toggle)
    #expect(!model.data.settings.debugLogging)

    // The sidebar: Turn Off next to "Debug logging on".
    model.data.settings.debugLogging = true
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let (main, agent, _) = try agentWindow(model, askpass)
    defer {
        agent.close()
        main.window?.orderOut(nil)
    }
    let window = try #require(main.window)
    #expect(await eventually { AXNode.flatten(window).contains { $0.id == "debugLog.turnOff" && $0.help?.isEmpty == false } })
    #expect(await call(agent, "press", ["id": "debugLog.turnOff"]).error == nil)
    #expect(!model.data.settings.debugLogging)
    model.debugLoggingOn = false
}
