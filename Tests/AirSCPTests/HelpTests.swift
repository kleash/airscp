import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AirSCP
@testable import AirSCPCore

// PLAN.md U: AirSCP explains itself. Every menu item and every interactive control (in every window, sheet and
// state, walked in-process through agent control's accessibility tree) has a tooltip or help text; the sidebar shows
// each host's route (U.1); the agent indicator says who acts and what (U.2); Other ssh options are checked (U.3).

/// The controls the walk looked at, once each (window, role, id, title), for its report.
@MainActor var distinctControls = Set<String>()

/// The interactive controls of `window` and its sheets (`sheetsOnly`: just its sheets) without a tooltip or help text:
/// "where: role id “title”". `checked` counts the controls looked at.
@MainActor
func unexplained(_ window: NSWindow, sheetsOnly: Bool = false, checked: inout Int) -> [String] {
    let interactive: Set<String> = ["button", "checkbox", "radiobutton", "popupbutton", "menubutton", "textfield", "textarea",
                                    "combobox", "slider", "link", "disclosuretriangle", "searchfield"]
    // AppKit's own parts, which say nothing of AirSCP: the window's buttons and the scroll bars' arrows and pages. SwiftUI
    // table headers have no API for a tooltip (their rows say what they hold). An editor's text is the document itself,
    // as is the server's version shown beside it.
    let exempt: Set<String> = ["closebutton", "minimizebutton", "zoombutton", "fullscreenbutton", "sortbutton",
                               "incrementarrow", "decrementarrow", "incrementpage", "decrementpage"]
    var windows = sheetsOnly ? [] : [window], sheet = window.attachedSheet
    while let current = sheet {
        windows.append(current)
        sheet = current.attachedSheet
    }
    let controls = windows.flatMap { root in
        AXNode.flatten(root).filter { interactive.contains($0.role) && !exempt.contains($0.subrole)
            && !["editor.text", "editor.serverText"].contains($0.id) }
            .map { (root, $0) }
    }
    checked += controls.count
    for (root, node) in controls { distinctControls.insert("\(root.title)|\(node.role)|\(node.id)|\(node.title)") }
    return controls.filter { $0.1.help == nil }
        .map { "\($0.0.title.isEmpty ? "sheet" : $0.0.title): \($0.1.role) \($0.1.id) “\($0.1.title)”" }
}

/// Every item of `menu` and its submenus (filled as they open) without a tooltip: their paths.
@MainActor
func unexplained(_ menu: NSMenu, path: [String] = []) -> [String] {
    menu.delegate?.menuNeedsUpdate?(menu)
    return menu.items.filter { !$0.isSeparatorItem && !$0.isHidden && !$0.title.isEmpty }.flatMap { item -> [String] in
        let here = path + [item.title]
        var missing = (item.toolTip ?? "").isEmpty && !path.isEmpty ? [here.joined(separator: " > ")] : []
        if let submenu = item.submenu, submenu !== NSApp.servicesMenu, item.title != "Services" {
            missing += unexplained(submenu, path: here)
        }
        return missing
    }
}

@MainActor @Test func everyMenuItemSaysWhatItDoes() {
    _ = NSApplication.shared
    _ = TestEnvironment.isolated
    let bar = AppDelegate().mainMenu()
    #expect(unexplained(bar).isEmpty, "\(unexplained(bar))")
    func count(_ menu: NSMenu) -> Int {
        menu.items.filter { !$0.isSeparatorItem && !$0.title.isEmpty }.reduce(0) { $0 + 1 + ($1.submenu.map(count) ?? 0) }
    }
    print("section U: \(count(bar)) menu items, all with a tooltip")
    // Help has AirSCP's own pages; Edit's ⌘F says what it filters.
    let help = bar.item(withTitle: "Help")?.submenu?.items.map(\.title) ?? []
    #expect(help == ["AirSCP Help", "Getting Started", "What's New", "", "Welcome to AirSCP…", "AirSCP Tips", "Agent Guide", "",
                     "Turn On Debug Logging", "Show Debug Log in Finder", "Copy Diagnostics", "Report a Problem"])
    #expect(bar.item(withTitle: "Help")?.submenu?.item(withTitle: "AirSCP Help")?.keyEquivalent == "")  // ⌘? is macOS's
    #expect(bar.item(withTitle: "Edit")?.submenu?.item(withTitle: "Filter")?.keyEquivalent == "f")
    // A context menu entry says the same as the menu-bar command with that action; so does each Transfers action.
    let pane = FilePane(source: .local, choosesSource: true, showHidden: false)
    _ = pane.view
    let file = FileItem(RemoteEntry(name: "a.txt", path: "/tmp/a.txt", kind: .file, size: 1, modified: nil,
                                    permissions: "rw-r--r--", mode: 0o644, owner: "me", group: "staff"))
    for entry in (pane.contextMenu(for: []) + pane.contextMenu(for: [file])).compactMap({ $0 }) {
        #expect(MenuHelp.tips[entry.1] != nil, "\(entry.0)")
    }
    for action in TransfersPanel.actions(for: []) { #expect(TransfersPanel.actionTips[action.title] != nil, "\(action.title)") }
    #expect(["Show Details…", "Show in Finder"].allSatisfy { TransfersPanel.actionTips[$0] != nil })
}

/// The section U walk runs with the other heavy window tests, one at a time: their sheets and keys go to whichever
/// window is key, and this walk makes its own window key many times (Edit…, New Host…).
extension FeatureRoundAppTests {
    /// The section U walk: the main window in each state, every sheet, AirSCP's other windows, and the agent popover.
    @MainActor @Test func everyControlSaysWhatItDoes() async throws {
        _ = NSApplication.shared
        try await withServer { @MainActor server in
            var host = server.host()
            host.label = "lab"
            let local = try server.scratch()
            host.lastLocalDir = local
            host.tunnels = [Tunnel(kind: .local, listenPort: 18_022, targetHost: "localhost", targetPort: 22)]
            try write("hello", to: server.path("a.txt"))
            try write("mine", to: local + "/a.txt")
            try write("x", to: local + "/folder/inside.txt")
            var inner = SSHHost(label: "inner", hostname: "inner")
            inner.jumpHostID = host.id
            let model = testModel([host, inner], groups: [HostGroup(name: "Lab")])
            model.save(Proxy(name: "Office", host: "proxy", port: 3128, username: "me"))
            var entry = RDPEntry(label: "Windows", hostname: "win")
            entry.viaHostID = host.id
            model.save(entry)
            model.data.snippets = [Snippet(name: "uptime", command: "uptime")]
            model.agentControlOn = true
            model.debugLoggingOn = true  // the sidebar's "Debug logging on" (PLAN.md AE)
            let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
            defer { askpass.close() }
            let (main, agent, _) = try agentWindow(model, askpass)
            defer {
                agent.close()
                main.window?.orderOut(nil)
            }
            let window = try #require(main.window)
            var missing: [String] = [], checked = 0
            @MainActor func check(_ what: String, _ window: NSWindow, sheetsOnly: Bool = false) {
                missing += unexplained(window, sheetsOnly: sheetsOnly, checked: &checked).map { what + " — " + $0 }
            }
            /// Opens a sheet, checks it (and `then`'s states), and closes it with `close`.
            @MainActor func sheet(_ what: String, close: String = "Cancel", then: () async -> Void = {}, _ open: () async -> Void) async {
                await open()
                #expect(await call(agent, "wait", ["until": "sheet", "timeout": 10]).error == nil, "\(what)")
                try? await Task.sleep(nanoseconds: 300_000_000)  // SwiftUI's controls, a moment after the sheet
                check(what, window, sheetsOnly: true)
                await then()
                _ = await call(agent, "press", ["title": close])
                #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 10]).error == nil, "\(what)")
            }

            check("nothing selected", window)
            _ = await call(agent, "select", ["pane": "sidebar", "names": ["lab"]])
            check("not connected", window)
            _ = await call(agent, "menu", ["path": "Host > Connect"])
            #expect(await call(agent, "wait", ["until": "connected", "timeout": 20]).error == nil)
            #expect(await call(agent, "wait", ["until": "listed", "pane": "right", "text": "a.txt", "timeout": 20]).error == nil)
            _ = await call(agent, "menu", ["path": "View > Show Command Log"])
            check("connected, with the command log", window)
            for tab in ["Monitor", "Tunnels", "Files"] {
                _ = await call(agent, "press", ["title": tab])
                try await Task.sleep(nanoseconds: 300_000_000)
                check(tab + " tab", window)
            }

            // The sheets on the main window.
            await sheet("new host", then: {
                _ = await call(agent, "press", ["title": "Advanced"])
                try? await Task.sleep(nanoseconds: 300_000_000)
                check("new host, Advanced", window, sheetsOnly: true)
            }) { main.newHost() }
            await sheet("host editor") { _ = await call(agent, "menu", ["path": "Host > Edit…"]) }
            await sheet("new Remote Desktop", then: {
                _ = await call(agent, "press", ["title": "Advanced"])
                try? await Task.sleep(nanoseconds: 300_000_000)
                check("new Remote Desktop, Advanced", window, sheetsOnly: true)
                // A company certificate authority: its file and Choose… (PLAN.md U.4).
                _ = await call(agent, "set", ["id": "rdpEditor.certificate", "value": "Trust my company's certificate authority"])
                try? await Task.sleep(nanoseconds: 300_000_000)
                check("new Remote Desktop, company certificate authority", window, sheetsOnly: true)
                #expect(AXNode.flatten(try! #require(window.attachedSheet)).contains { $0.id == "rdpEditor.caFile" })
            }) { main.newRemoteDesktop() }
            await sheet("Proxies", close: "Done", then: {
                _ = await call(agent, "press", ["title": "Add Proxy…"])
                _ = await call(agent, "wait", ["until": "sheet", "text": "proxyEditor", "timeout": 5])
                try? await Task.sleep(nanoseconds: 300_000_000)
                check("proxy editor", window, sheetsOnly: true)
                _ = await call(agent, "press", ["title": "Cancel"])
            }) { main.showProxies() }
            await sheet("new group") { main.newGroup() }
            await sheet("Run Command", close: "Close") { _ = await call(agent, "menu", ["path": "Host > Run Command…"]) }
            await sheet("tunnel editor", then: {
                // Another machine's field, then Remote's and the SOCKS proxy's sentences.
                for (id, value) in [("tunnelEditor.destination", "Another machine"), ("tunnelEditor.type", "Remote"),
                                    ("tunnelEditor.type", "SOCKS proxy")] {
                    _ = await call(agent, "set", ["id": id, "value": value])
                    try? await Task.sleep(nanoseconds: 300_000_000)
                    check("tunnel editor, " + value, window, sheetsOnly: true)
                }
            }) {
                _ = await call(agent, "press", ["title": "Tunnels"])
                _ = await call(agent, "press", ["title": "Add Tunnel…"])
            }
            _ = await call(agent, "press", ["title": "Files"])
            _ = await call(agent, "select", ["pane": "right", "names": ["a.txt"]])
            for (command, close) in [("File > Rename…", "Cancel"), ("File > Permissions…", "Cancel"), ("File > Get Info", "Done"),
                                     ("File > Compress…", "Cancel"), ("File > Run…", "Cancel"), ("File > Delete…", "Cancel"),
                                     ("File > Download as .tar.gz…", "Cancel")] {
                await sheet(command, close: close) { _ = await call(agent, "menu", ["path": command]) }
                _ = await call(agent, "select", ["pane": "right", "names": ["a.txt"]])
            }
            await sheet("Find Files", close: "Done") { _ = await call(agent, "menu", ["path": "File > Find Files…"]) }
            // The server's home folder: Synchronize waits for Compare, then shows the plan.
            await sheet("Synchronize", then: {
                _ = await call(agent, "press", ["title": "Compare"])
                _ = await call(agent, "wait", ["until": "compared", "timeout": 20])
                check("Synchronize, compared", window, sheetsOnly: true)
            }) { _ = await call(agent, "menu", ["path": "File > Synchronize…"]) }
            await sheet("conflict") { _ = await call(agent, "drop", ["files": [local + "/a.txt"], "pane": "right"]) }
            await sheet("folder transfer") { _ = await call(agent, "drop", ["files": [local + "/folder"], "pane": "right"]) }
            await sheet("welcome", close: "Start") {
                presentSheet(on: window) { close in WelcomeView { _ in close() } }
            }
            await sheet("import from ~/.ssh/config") {
                let importer = ConfigImport(aliases: ["labalias"], model: model)
                presentSheet(on: window) { close in ConfigImportView(importer: importer, importChosen: { _ in }, close: close) }
            }
            await sheet("password question") {
                showPrompt(.password(user: "dev", host: "lab"), text: "dev@lab's password:", host: host, canRemember: true,
                           on: window) { _, _ in }
            }
            await sheet("host key question") {
                showPrompt(.hostKey(host: "lab", fingerprint: "SHA256:abc"), text: "", host: host, canRemember: false,
                           on: window) { _, _ in }
            }
            await sheet("an error", close: "OK") {
                showError(AirSCPError(.other, "It failed.", details: "the tool's words"), title: "Can't do it", on: window)
            }
            await sheet("certificate question") {
                let certificate = RDPSession.Certificate(server: "win:3389", subject: "CN=win", issuer: "CN=win",
                                                         fingerprint: "AB:CD", oldFingerprint: nil, nameMismatch: false)
                certificateAlert(certificate, server: "Windows").beginSheetModal(for: window)
            }
            _ = await call(agent, "select", ["pane": "sidebar", "names": ["Windows"]])
            check("Remote Desktop, not connected", window)

            // The agent indicator's popover.
            _ = await call(agent, "select", ["pane": "sidebar", "names": ["lab"]])
            _ = await call(agent, "press", ["id": "agent.indicator"])
            try await Task.sleep(nanoseconds: 500_000_000)
            let popover = try #require(NSApp.windows.first { $0.isVisible && NSStringFromClass(type(of: $0)).contains("Popover") })
            check("agent popover", popover)
            #expect(AXNode.flatten(popover).contains { $0.title == "Turn Off Agent Control" })
            popover.close()

            // AirSCP's other windows.
            @MainActor func other<V: View>(_ title: String, _ view: V) -> NSWindow {
                let window = NSWindow(contentViewController: NSHostingController(rootView: view))
                window.title = title
                window.isReleasedWhenClosed = false
                window.setFrameOrigin(NSPoint(x: -21000, y: -21000))
                window.orderFront(nil)
                return window
            }
            // Settings with every row showing: a company certificate authority for new desktops, a key folder of one's own.
            model.data.settings.certificateCheck = .companyCA
            model.data.settings.keyFolder = "~/Keys"
            let settings = other("Settings", SettingsView(model: model))
            let keyFolder = try scratch()
            _ = await Runner.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "help", "-f", keyFolder + "/id_help"])
            let keys = KeysModel(folder: keyFolder, askpass: [:])
            await keys.refresh()
            let keysWindow = other("Keys", KeysView(keys: keys, model: model, install: { _, _ in }, report: { _, _ in }))
            let emptyKeys = KeysModel(folder: try scratch(), askpass: [:])
            let emptyKeysWindow = other("Keys", KeysView(keys: emptyKeys, model: model, install: { _, _ in }, report: { _, _ in }))
            let snippets = other("Snippets", SnippetsView(model: model) { _, _ in })
            let tips = textWindow(title: "AirSCP Tips", text: AirSCPTips.text)
            let guide = textWindow(title: "Agent Guide", text: AgentBridge.guideText)
            let editor = RemoteEditor(session: try #require(main.selectedWorkspace?.session), path: server.path("a.txt"), text: "hello")
            let windows = [settings, keysWindow, emptyKeysWindow, snippets, tips, guide, try #require(editor.window)]
            defer { windows.forEach { $0.orderOut(nil) } }
            for (index, window) in [tips, guide].enumerated() {  // off the screen, as the tests' other windows
                window.setFrameOrigin(NSPoint(x: -22000, y: -21000 - 700 * index))
                window.orderFront(nil)
            }
            editor.window?.setFrameOrigin(NSPoint(x: -23000, y: -21000))
            try await Task.sleep(nanoseconds: 500_000_000)
            for window in windows { check(window.title, window) }
            // The Keys window's empty command log says what it shows there (it said "for this host", as a host's does).
            let emptyLog = AXNode.flatten(emptyKeysWindow).map { $0.title + " " + "\($0.value ?? "")" }
            #expect(emptyLog.contains { $0.contains("The ssh-keygen and ssh-add commands this window runs") }
                    && !emptyLog.contains { $0.contains("for this host") }, "\(emptyLog.filter { $0.contains("Nothing") })")
            // Keys: a key's buttons on, and its two sheets.
            keys.selection = keys.pairs.first?.id
            try await Task.sleep(nanoseconds: 300_000_000)
            check("Keys, a key selected", keysWindow)
            let install = other("install", InstallKeyView(pair: try #require(keys.pairs.first), model: model, install: { _ in },
                                                          cancel: {}))
            try await Task.sleep(nanoseconds: 300_000_000)
            check("Keys, install", install)
            install.orderOut(nil)
            // The key sheet in each of its steps (PLAN.md K.1, K.2), on the main window.
            let pair = try #require(keys.pairs.first)
            let ppk = keyFolder + "/help.ppk"
            try write(try PuTTYKey.write(try PuTTYKey.fromOpenSSH(try #require(read(pair.privateKey))), passphrase: "help",
                                         passes: 1), to: ppk)
            await sheet("new key pair", then: {
                _ = await call(agent, "press", ["id": "newKey.advanced"])
                _ = await call(agent, "set", ["id": "newKey.passphrase", "value": "a passphrase"])
                try? await Task.sleep(nanoseconds: 300_000_000)
                check("new key pair, Advanced and a passphrase", window, sheetsOnly: true)
            }) {
                presentSheet(on: window) { close in
                    KeyFlowView(flow: KeyFlow(newKeyIn: keyFolder, keys: keys, downloads: keyFolder, install: { _ in }, close: close))
                }
            }
            await sheet("import a PuTTY key", then: {
                _ = await call(agent, "set", ["id": "importKey.same", "value": false])
                try? await Task.sleep(nanoseconds: 300_000_000)
                check("import a PuTTY key, another passphrase", window, sheetsOnly: true)
            }) {
                presentSheet(on: window) { close in
                    KeyFlowView(flow: KeyFlow(importing: URL(fileURLWithPath: ppk), into: keyFolder, keys: keys, downloads: keyFolder,
                                              useForHost: { _ in }, install: { _ in }, close: close))
                }
            }
            await sheet("export as a PuTTY key") {
                presentSheet(on: window) { close in KeyFlowView(flow: KeyFlow(exporting: pair, keys: keys, downloads: keyFolder, close: close)) }
            }
            for (step, close) in [(KeyFlow.Step.result, "Done"), (.exported, "Done")] {
                await sheet("the key sheet's \(step)", close: close) {
                    presentSheet(on: window) { close in
                        let flow = KeyFlow(exporting: pair, keys: keys, downloads: keyFolder, close: close)
                        flow.step = step
                        return KeyFlowView(flow: flow)
                    }
                }
            }
            // A PuTTY key imported from the host editor (its passphrase given, none for the new key): the result has Use
            // for This Host and Install on This Host.
            await sheet("an imported key, from the host editor", close: "Done", then: {
                #expect(await call(agent, "wait", ["until": "sheet", "text": "Key imported", "timeout": 20]).error == nil)
                try? await Task.sleep(nanoseconds: 300_000_000)
                check("an imported key's result", window, sheetsOnly: true)
                #expect(AXNode.flatten(try! #require(window.attachedSheet)).contains { $0.title == "Use for This Host" })
            }) {
                presentSheet(on: window) { close in
                    let flow = KeyFlow(importing: URL(fileURLWithPath: ppk), into: keyFolder, keys: keys, downloads: keyFolder,
                                       useForHost: { _ in }, install: { _ in }, installTitle: "Install on This Host", close: close)
                    flow.ppkPassphrase = "help"
                    flow.samePassphrase = false
                    flow.importKey()
                    return KeyFlowView(flow: flow)
                }
            }
            // A snippet selected: its editor.
            if let list = AgentServer.views(NSTableView.self, in: snippets.contentView).first {
                list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
                try await Task.sleep(nanoseconds: 300_000_000)
                check("Snippets, one selected", snippets)
            }

            #expect(missing.isEmpty, "Without a tooltip or help:\n\(missing.joined(separator: "\n"))")
            #expect(checked > 400, "only \(checked) controls were looked at")
            print("section U: \(distinctControls.count) controls (\(checked) looks in all states), \(missing.count) without help")
            await main.selectedWorkspace?.connection.disconnect()
        }
    }
}

extension FeatureRoundAppTests {
    /// PLAN.md U: a disabled menu item says why, in each state of the main window (the reason is its tooltip while it is
    /// off, and what agents are told). Duplicate, Compress…, Run…, Go ▸ Back and others said nothing.
    @MainActor @Test func everyDisabledMenuItemSaysWhy() async throws {
        _ = NSApplication.shared
        try await withServer { @MainActor server in
            var host = server.host()
            host.label = "lab"
            let local = try server.scratch()
            host.lastLocalDir = local
            try write("hello", to: server.path("a.txt"))
            try rawMkdir(server.path("folder"))
            try write("mine", to: local + "/b.txt")
            let model = testModel([host])
            let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
            defer { askpass.close() }
            let (main, agent, _) = try agentWindow(model, askpass)
            defer { main.window?.orderOut(nil) }
            var silent: [String] = []
            @MainActor func check(_ state: String) {
                // macOS's own items say nothing of AirSCP: Hide Others is off when no other app is open (a fresh CI runner).
                let appKits: Set<String> = ["AirSCP > Hide Others", "AirSCP > Show All", "AirSCP > Services"]
                for item in agent.menusJSON() where item["enabled"] as? Bool == false && (item["reason"] as? String ?? "").isEmpty
                    && !appKits.contains(item["path"] as? String ?? "") {
                    silent.append("\(state): \(item["path"] as? String ?? "")")
                }
            }
            check("nothing selected")
            _ = await call(agent, "select", ["pane": "sidebar", "names": ["lab"]])
            check("not connected")
            _ = await call(agent, "menu", ["path": "Host > Connect"])
            #expect(await call(agent, "wait", ["until": "connected", "timeout": 20]).error == nil)
            #expect(await call(agent, "wait", ["until": "listed", "pane": "right", "text": "a.txt", "timeout": 20]).error == nil)
            _ = await call(agent, "select", ["pane": "right", "none": true])
            check("a server's folder")
            for names in [["a.txt"], ["folder"], ["a.txt", "folder"]] {
                _ = await call(agent, "select", ["pane": "right", "names": names])
                check("the server's " + names.joined(separator: " and "))
            }
            #expect(await call(agent, "wait", ["until": "listed", "pane": "left", "text": "b.txt", "timeout": 20]).error == nil)
            _ = await call(agent, "select", ["pane": "left", "none": true])
            check("this Mac's folder")
            _ = await call(agent, "select", ["pane": "left", "names": ["b.txt"]])
            check("this Mac's b.txt")
            _ = await call(agent, "menu", ["path": "File > New Folder…"])
            #expect(await call(agent, "wait", ["until": "sheet", "timeout": 10]).error == nil)
            check("a sheet")
            _ = await call(agent, "press", ["title": "Cancel"])
            #expect(silent.isEmpty, "Disabled without a reason:\n\(silent.joined(separator: "\n"))")
            await main.selectedWorkspace?.connection.disconnect()
        }
    }
}

// MARK: U.1 routes

@MainActor @Test func theSidebarShowsEachHostsRoute() {
    let proxy = Proxy(name: "corp-proxy", host: "proxy.example.com", port: 8080, username: "me")
    var bastion = SSHHost(label: "bastion", hostname: "bastion.example.com", port: 22, username: "jump")
    bastion.proxyID = proxy.id
    var target = SSHHost(label: "target", hostname: "10.0.0.5", username: "dev")
    target.jumpHostID = bastion.id
    var proxied = SSHHost(label: "proxied", hostname: "p.example.com")
    proxied.proxyID = proxy.id
    var lost = SSHHost(label: "lost", hostname: "lost.example.com")
    lost.jumpHostID = UUID()
    let direct = SSHHost(label: "direct", hostname: "d.example.com")
    var data = AirSCPData(hosts: [bastion, target, proxied, lost, direct], proxies: [proxy])
    var entry = RDPEntry(label: "Windows", hostname: "win")
    entry.viaHostID = target.id
    data.rdpEntries = [entry]

    #expect(data.route(for: direct) == nil)
    #expect(data.route(for: bastion)?.short == "via proxy corp-proxy")
    #expect(data.route(for: proxied)?.short == "via proxy corp-proxy")
    // The proxy first, as the connection goes; every hop's user@host:port in the tooltip.
    let route = data.route(for: target)
    #expect(route?.short == "via corp-proxy → bastion" && route?.missing == false)
    #expect(route?.full == "Connects to dev@10.0.0.5 through the HTTP proxy corp-proxy (me@proxy.example.com:8080), then the "
            + "jump host bastion (jump@bastion.example.com:22).")
    #expect(data.route(for: lost)?.short == "via a missing jump host" && data.route(for: lost)?.missing == true)
    #expect(data.route(for: entry)?.short == "via corp-proxy → bastion → target")
    // The search finds a host by its jump host's and proxy's names.
    #expect(AppModel.sections(data, search: "corp-proxy").flatMap(\.hosts).map(\.label).sorted() == ["bastion", "proxied", "target"])
    #expect(AppModel.sections(data, search: "bastion").flatMap(\.hosts).map(\.label).sorted() == ["bastion", "target"])
    // Copy ssh Command is off, saying why, where its command couldn't work in another terminal.
    #expect(copyCommandProblem(direct, jump: nil) == nil)
    #expect(copyCommandProblem(lost, jump: data.jump(for: lost))?.hasPrefix("Its jump host no longer exists") == true)
    for host in [proxied, bastion, target] {
        #expect(copyCommandProblem(host, jump: data.jump(for: host))?.hasPrefix("Its HTTP proxy is reached through AirSCP") == true)
    }
}

// MARK: U.2 the agent indicator

@MainActor @Test func theAgentIndicatorSaysWhoActsAndWhat() async throws {
    _ = NSApplication.shared
    let model = testModel([SSHHost(label: "web", hostname: "web")])
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let (main, agent, _) = try agentWindow(model, askpass)
    defer {
        agent.close()
        main.window?.orderOut(nil)
    }
    // A snapshot only looks: it lights the dot, but isn't an action.
    _ = await agent.handle("snapshot", [:], from: getpid(), client: "claude-code 2.1")
    #expect(model.agentActive && model.agentActions.isEmpty && model.agentClient?.name == "claude-code 2.1")
    _ = await agent.handle("select", ["pane": "sidebar", "names": ["web"]], from: getpid(), client: "claude-code 2.1")
    // The workspace header gives the address as the sidebar does: no port when the host has none (ssh's config decides).
    let window = try #require(main.window)
    func header() -> [String] { AXNode.flatten(window).compactMap { $0.value as? String } }
    #expect(await eventually { header().contains { $0.hasPrefix("web · ") } }, "\(header())")
    #expect(!header().contains { $0.contains("web:22") })
    main.newHost()
    _ = await agent.handle("set", ["id": "hostEditor.name", "value": "chain target"], from: getpid(), client: "claude-code 2.1")
    _ = await agent.handle("set", ["title": "Log in with", "value": "Password"], from: getpid(), client: "claude-code 2.1")
    _ = await agent.handle("set", ["id": "hostEditor.password", "value": "s3cret"], from: getpid(), client: "claude-code 2.1")
    _ = await agent.handle("press", ["title": "Cancel"], from: getpid(), client: "claude-code 2.1")
    let texts = model.agentActions.map(\.text)
    #expect(texts == ["Selected “web” in the sidebar", "Set “hostEditor.name” to “chain target”",
                      "Set “Log in with” to “Password”", "Set “hostEditor.password” to •••", "Pressed “Cancel”"], "\(texts)")
    #expect(model.agentActions.last?.target == "the sheet “New Host”" && model.agentActionCount == 5)
    #expect(!texts.joined().contains("s3cret"))
    let summary = AgentStatus.summary(model)
    // (Acting now, or a loaded Mac took over 5 s since: connected.)
    #expect(summary.contains("claude-code 2.1") && summary.contains("Last: Pressed “Cancel” in the sheet")
            && summary.contains("Actions so far: 5"), "\(summary)")
    // The snapshot names the client too; only the last 20 actions are kept.
    #expect(((await call(agent, "snapshot", ["include": []]))["agent"] as? [String: Any])?["actions"] as? Int == 5)
    for _ in 0..<25 { _ = await agent.handle("wait", ["until": "no_sheet"], from: getpid(), client: "claude-code 2.1") }
    #expect(model.agentActions.count == 20 && model.agentActionCount == 30)
    // A screenshot is listed once it is taken (it shows the window as the request found it, the dot not lit by it).
    _ = await agent.handle("screenshot", [:], from: getpid(), client: "claude-code 2.1")
    #expect(model.agentActions.last?.text == "Took a screenshot" && model.agentActionCount == 31)
    // A field that isn't there (yet) may be a secure one: an answer set before its sheet opens shows no value either.
    for id in ["prompt.answer", "newKey.passphrase", "importKey.confirm"] {
        _ = await agent.handle("set", ["id": id, "value": "TopSecret-\(id)"], from: getpid(), client: "claude-code 2.1")
        #expect(model.agentActions.last?.text == "Set “\(id)” to •••")
    }
    #expect(!model.agentActions.map(\.text).joined().contains("TopSecret") && !AgentStatus.summary(model).contains("TopSecret"))
}

/// An MCP client stays named while a one-off `AirSCP --agent` call comes and goes, and keeps its "since".
@MainActor @Test func theIndicatorKeepsAClientThatIsStillConnected() async throws {
    _ = NSApplication.shared
    let model = testModel([SSHHost(label: "web", hostname: "web")])
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let (main, agent, _) = try agentWindow(model, askpass)
    defer {
        agent.close()
        main.window?.orderOut(nil)
    }
    _ = await agent.handle("snapshot", [:], from: getpid(), client: "claude-code 2.1")
    let since = try #require(model.agentClient?.since)
    // A one-off call from another process (a short sleep standing in for AirSCP --agent).
    let other = Process()
    other.executableURL = URL(fileURLWithPath: "/bin/sleep")
    other.arguments = ["1"]
    try other.run()
    _ = await agent.handle("snapshot", [:], from: other.processIdentifier, client: "AirSCP --agent")
    #expect(model.agentClient?.name == "AirSCP --agent")
    other.waitUntilExit()
    #expect(await eventually { await MainActor.run { model.agentClient?.name == "claude-code 2.1" } })
    #expect(model.agentClient?.since == since && AgentStatus.state(model).contains("claude-code 2.1"))
}

/// Help ▸ Agent Guide reads as text: each paragraph and list item flows (no breaks where the guide's 120 columns end
/// mid-sentence), headings without "#", code without backticks, and no word left out.
@Test func theAgentGuideWindowReadsAsText() {
    let shown = String(readableMarkdown(AgentBridge.guideText).characters)
    let lines = shown.components(separatedBy: "\n")
    #expect(!lines.contains { $0.hasPrefix("#") } && !shown.contains("`") && lines.contains("Overview"))
    #expect(lines.contains { $0.hasPrefix("• Loop: snapshot → one action") && $0.hasSuffix("when a sheet appears.") })
    func words(_ text: String) -> String { String(text.filter { $0.isLetter || $0.isNumber }).lowercased() }
    #expect(words(shown) == words(AgentBridge.guideText))
}

// MARK: U.3 Other ssh options

@MainActor @Test func otherSSHOptionsAreCheckedAsTyped() async {
    _ = TestEnvironment.isolated
    #expect(await SSHConfig.check("Compression=yes") == nil)
    #expect(await SSHConfig.check("SetEnv LANG=en_US.UTF-8") == nil)
    #expect(await SSHConfig.check("Compresion=yes") == "ssh has no option called “Compresion”.")
    #expect(await SSHConfig.check("ConnectTimeout=abc") == "Invalid time value.")
    // Every line Add Common Option… offers is one ssh takes.
    for option in HostEditorView.commonOptions {
        for line in option.lines { #expect(await SSHConfig.check(line) == nil, "\(line)") }
    }
    // What AirSCP runs itself says why it can't be changed; a proxy command is only refused where it would be ignored.
    #expect(SSHConfig.refusal("ControlPersist=yes", routed: false)?.contains("AirSCP keeps one shared connection") == true)
    #expect(SSHConfig.refusal("RequestTTY yes", routed: false) != nil)
    #expect(SSHConfig.refusal("ProxyCommand nc -X 5 -x socks:1080 %h %p", routed: false) == nil)
    #expect(SSHConfig.refusal("ProxyJump=other", routed: true)?.contains("would be ignored") == true)
    #expect(SSHConfig.refusal("Compression=yes", routed: true) == nil)
}

/// The welcome sheet comes on a first run (no hosts or desktops, not shown before), once.
@MainActor @Test func theWelcomeSheetComesOnceOnAFirstRun() throws {
    var settings = AppSettings()
    #expect(!settings.welcomeShown)
    settings.welcomeShown = true
    let data = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(AppSettings.self, from: data).welcomeShown)
    #expect(try !JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).welcomeShown)
}
