import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import AirSCP
@testable import AirSCPCore

// The feature cycle's round 1 (fix step): the app's windows and agent control. One regression test per behaviour the
// area testers found broken, or per feature they couldn't reach (see /tmp/airscp-handoffs/feature-matrix.md).
// One at a time: each makes windows on the main thread, which everything else in the test process waits for too.

@MainActor @Suite(.serialized) struct FeatureRoundAppTests {
    // MARK: Windows

    /// Connect after an edit, while the Tunnels tab is shown, made a new Session whose tabs replaced the Tunnels tab's item:
    /// NSTabViewController threw and AirSCP stopped answering.
    @MainActor @Test func aNewSessionKeepsTheTunnelsTabShown() async throws {
        _ = NSApplication.shared
        try await withServer { @MainActor server in
            let host = server.host()
            let model = testModel([host])
            let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
            defer { askpass.close() }
            let main = MainWindowController(model: model, askpass: askpass)
            keptWindows.append(main)
            defer { main.window?.orderOut(nil) }
            main.sidebar.selection = .host(host.id)
            let workspace = try #require(main.selectedWorkspace)
            _ = workspace.view
            workspace.showTunnels()
            let tunnels = workspace.tabs.tabViewItems[2]
            model.updateHost(host.id) { $0.serverAliveInterval = 14 }  // a change in how ssh connects: a new Session
            let before = workspace.session
            _ = try await workspace.connectedSession()
            #expect(workspace.session !== before && workspace.tabs.selectedTabViewItemIndex == 2)
            #expect(workspace.tabs.tabViewItems.count == 3 && workspace.tabs.tabViewItems[2] === tunnels)
            #expect(workspace.tabs.tabViewItems[0].viewController === workspace.browser)
            workspace.tabs.selectedTabViewItemIndex = 0  // the new Files tab works
            #expect(workspace.browser.view.window != nil)
            await workspace.connection.disconnect()
        }
    }

    /// Commands and ssh options are kept as typed: no smart quotes or dashes, and Tab leaves the field.
    @MainActor @Test func commandFieldsKeepWhatIsTyped() throws {
        _ = NSApplication.shared
        final class Box { var text = "" }
        let box = Box()
        let field = NSHostingView(rootView: PlainTextEditor(text: Binding(get: { box.text }, set: { box.text = $0 }), id: "runCommand.command")
            .frame(width: 300, height: 64))
        let window = NSWindow(contentRect: NSRect(x: -22000, y: -22000, width: 300, height: 64), styleMask: [.titled], backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = field
        field.layoutSubtreeIfNeeded()
        let textView = try #require(AgentServer.views(NSTextView.self, in: field).first)
        #expect(!textView.isAutomaticQuoteSubstitutionEnabled && !textView.isAutomaticDashSubstitutionEnabled)
        #expect(!textView.isAutomaticTextReplacementEnabled && !textView.isAutomaticSpellingCorrectionEnabled)
        #expect(textView.accessibilityIdentifier() == "runCommand.command")
        window.makeFirstResponder(textView)
        textView.insertText("printf '[%s]\\n' \"a b\" c; ls --version", replacementRange: textView.selectedRange())
        #expect(box.text == "printf '[%s]\\n' \"a b\" c; ls --version")
        textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
        #expect(!box.text.contains("\t"))
        window.orderOut(nil)
    }

    /// The proxy's password question during Test Connection comes on the editor, where it is seen (it waited behind it).
    @MainActor @Test func aProxysQuestionComesOnTheSheetShown() async throws {
        _ = NSApplication.shared
        let proxy = Proxy(name: "Lab proxy", host: "127.0.0.1", port: 1, username: "porter")
        let model = testModel()
        model.save(proxy)
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let main = MainWindowController(model: model, askpass: askpass)
        keptWindows.append(main)
        let window = try #require(main.window)
        window.setFrame(NSRect(x: -20000, y: -20000, width: 1000, height: 640), display: false)
        defer { window.orderOut(nil) }
        presentSheet(on: window) { _ in Text("Edit “via proxy target”").frame(width: 300, height: 200) }
        let editor = try #require(window.attachedSheet)
        final class Answered { var value = false }
        let answered = Answered()
        main.answerProxy(proxy.id, mayAsk: true) { _ in answered.value = true }
        #expect(await eventually { editor.attachedSheet != nil })
        let question = try #require(editor.attachedSheet)
        #expect(AXNode.flatten(question).contains { ($0.value as? String)?.contains("Proxy “Lab proxy” needs a password") == true })
        editor.endSheet(question, returnCode: .alertSecondButtonReturn)
        #expect(await eventually { answered.value })
        window.endSheet(editor)
    }

    /// After a disconnect the Monitor shows no figures as if they were current (with Kill on).
    @MainActor @Test func theMonitorForgetsItsFiguresWhenDisconnected() throws {
        let session = Session(host: SSHHost(hostname: "nowhere"), jump: nil, askpass: try AskpassServer(helperPath: TestEnvironment.airscpBinary))
        defer { session.askpass.close() }
        let monitor = MonitorController(workspace: nil, session: session)
        monitor.model.snapshot = MonitorSnapshot(cpu: 2, processes: [MonitorProcess(pid: 1, ppid: 0, user: "root", cpu: 0, memory: 0, rss: 0,
                                                                                     elapsed: 1, state: "S", name: "init", command: "init")])
        monitor.stateChanged(.idle)
        #expect(monitor.model.snapshot == nil && !monitor.model.connected)
    }

    /// Run Command on an sftp-only account: Run says why once (no second, red copy), and Run in Terminal is off too.
    @MainActor @Test func runCommandOnAnSFTPOnlyAccountSaysWhyOnce() async throws {
        try await withServer(TestServer.Options(sftpOnly: true)) { @MainActor server in
            let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
            defer { askpass.close() }
            let host = server.host()
            let connection = HostConnection(host: host, model: testModel([host]), askpass: askpass)
            try await connection.connect()
            #expect(await eventually { connection.state == .connected })
            let runner = RunCommandModel(connection: connection, command: "uptime")
            runner.run()
            #expect(runner.unavailableReason != nil && runner.failure == nil && !runner.running)
            await connection.disconnect()
        }
    }

    // MARK: Agent control

    /// Agent control's robustness: malformed numbers, a request that never comes, a wait whose agent has gone, a long text
    /// typed key by key, the time of the last request, and a settings folder too deep for a socket.
    @MainActor @Test func agentControlStandsUpToOddRequests() async throws {
        _ = NSApplication.shared
        let model = testModel([SSHHost(label: "web", hostname: "web")])
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let (main, server, dir) = try agentWindow(model, askpass)
        defer {
            server.close()
            main.window?.orderOut(nil)
        }
        _ = await call(server, "select", ["pane": "sidebar", "names": ["web"]])
        // Negative counts crashed AirSCP.
        var reply = await call(server, "snapshot", ["include": ["log", "panes"], "log": -1, "rows": -1])
        #expect(reply.error == nil && (reply["log"] as? [Any])?.isEmpty == true)
        #expect(((reply["panes"] as? [String: Any])?["right"] as? [String: Any])?["rows"] as? [Any] != nil)
        // The last request before this one, not this one.
        let before = Date()
        try await Task.sleep(nanoseconds: 1_100_000_000)
        reply = await call(server, "snapshot", ["include": []])
        let last = (reply["agent"] as? [String: Any])?["lastRequest"] as? String
        #expect(last.flatMap { ISO8601DateFormatter().date(from: $0) }.map { $0 < before } == true, "\(String(describing: last))")
        // A wait for an agent that has gone stops (it kept polling, and the indicator lit, for up to 10 minutes).
        let gone = try await run(["/bin/sh", "-c", "echo $$"]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        let started = Date()
        let waited = await server.handle("wait", ["until": "connected", "timeout": 60], from: pid_t(gone) ?? 0)
        #expect(waited["isError"] as? Bool == true && Date().timeIntervalSince(started) < 30)  // not the wait's 60 s
        // Thousands of characters typed key by key would hold the app up.
        reply = await call(server, "type", ["text": String(repeating: "x", count: 5000)])
        #expect(reply.error?.contains("set") == true)
        // A connection that sends nothing is closed (it held a thread for ever).
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try #require(AgentBridge.unixAddress(dir + "/sock"))
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(connected == 0)
        let closedAt = await Task.detached { () -> TimeInterval in
            let start = Date()
            var byte: UInt8 = 0
            _ = recv(fd, &byte, 1, 0)  // 0: the server closed it
            return Date().timeIntervalSince(start)
        }.value
        close(fd)
        #expect(closedAt < 8)
        // A settings folder too deep for a socket's path says so.
        let deep = try scratch() + "/" + String(repeating: "x", count: 120)
        do {
            _ = try AgentServer(main: nil, model: model, directory: URL(fileURLWithPath: deep), windows: { [] })
            Issue.record("agent control started on a path too long for a socket")
        } catch let error as AirSCPError {
            #expect(error.message.contains("too long"))
        }
    }

    /// What testers couldn't reach or got wrong through agent control: Open/Save panels (file=), groups, the banner's
    /// text, other windows' text, why a button is off, columns, a filter's rows, Escape on sheets, Run Command's snippets,
    /// a refused octal mode, and commands while the Files tab isn't shown or a sheet covers the window.
    @MainActor @Test func agentsReachPanelsGroupsColumnsAndSheets() async throws {
        _ = NSApplication.shared
        try await withServer { @MainActor server in
            var host = server.host()
            host.label = "lab"
            let local = try server.scratch()
            host.lastLocalDir = local
            for index in 0..<300 { try write("x", to: local + "/file-\(index).txt") }
            try write("x", to: server.path("readme.txt"))
            let gone = SSHHost(label: "gone key", hostname: "127.0.0.1", auth: .keyFile, keyFile: "/nowhere/id_gone")
            let model = testModel([host, gone])
            model.save(Proxy(name: "Office", host: "proxy", port: 3128))
            let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
            defer { askpass.close() }
            let (main, agent, _) = try agentWindow(model, askpass)
            defer {
                agent.close()
                main.window?.orderOut(nil)
            }

            // The banner says what the view says (a missing key file).
            _ = await call(agent, "select", ["pane": "sidebar", "names": ["gone key"]])
            var reply = await call(agent, "snapshot", ["include": ["workspace"]])
            let banner = ((reply["workspace"] as? [String: Any])?["banner"] as? [String: Any])?["text"] as? String
            #expect(banner?.contains("The key file /nowhere/id_gone no longer exists") == true, "\(String(describing: banner))")

            // Other Key File… with file=: chosen without a panel (its runModal held up every request).
            let key = try server.scratch() + "/id_elsewhere"
            try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", key])
            _ = await call(agent, "menu", ["path": "Host > Edit…"])
            reply = await call(agent, "set", ["id": "hostEditor.login", "value": "Choose a Key File…", "file": key + ".pub"])
            #expect(reply.error == nil && reply["note"] == nil, "\(reply.json) \(reply.error ?? "")")
            // (The pop-up shows it once SwiftUI has updated: by an agent's next request, which comes over the socket.)
            var login: String?
            #expect(await eventually {
                let sheets = await call(agent, "snapshot", ["include": ["sheets"]])["sheets"] as? [[String: Any]]
                login = field(sheets?.first, "hostEditor.login")?["value"] as? String
                return login?.contains("id_elsewhere") == true
            }, "\(String(describing: login))")
            reply = await call(agent, "set", ["id": "hostEditor.login", "value": "Choose a Key File…", "file": "/nowhere/key"])
            #expect(reply.error?.contains("doesn't exist") == true, "\(reply.json)")
            #expect(await call(agent, "key", ["combo": "escape"]).error == nil)
            #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 5]).error == nil)

            // Groups: New Group and Rename Group refuse a name in use (the Host menu's Rename Group ▸ <group>: the lab test).
            main.newGroup()
            _ = await call(agent, "set", ["id": "prompt.name", "value": "Lab"])
            _ = await call(agent, "press", ["title": "Create"])
            main.newGroup()
            _ = await call(agent, "set", ["id": "prompt.name", "value": "lab"])
            reply = await call(agent, "press", ["title": "Create"])
            #expect((sheet(reply)?["title"] as? String)?.contains("already exists") == true && model.data.groups.count == 1, "\(reply.json)")
            _ = await call(agent, "press", ["title": "OK"])
            let otherGroup = model.addGroup(named: "Other")
            main.renameGroup(otherGroup)
            _ = await call(agent, "set", ["id": "prompt.name", "value": "LAB"])
            reply = await call(agent, "press", ["title": "Rename"])
            #expect((sheet(reply)?["title"] as? String)?.contains("already exists") == true && model.data.groups.map(\.name) == ["Lab", "Other"])
            _ = await call(agent, "press", ["title": "OK"])
            #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 5]).error == nil)

            // A disabled button says why (its help): Proxies ▸ Remove… of a proxy a host uses.
            model.updateHost(gone.id) { $0.proxyID = model.data.proxies.first?.id }
            main.showProxies()
            _ = await call(agent, "select", ["in": "sheet", "names": ["Office"]])
            reply = await call(agent, "press", ["title": "Remove…"])
            #expect(reply.error?.contains("is disabled now: ") == true && reply.error?.contains("gone key") == true, "\(reply.error ?? "")")
            // Escape closes the Proxies sheet (only Return did).
            _ = await call(agent, "key", ["combo": "escape"])
            #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 5]).error == nil)

            // Connect the lab host: its panes.
            _ = await call(agent, "select", ["pane": "sidebar", "names": ["lab"]])
            _ = await call(agent, "menu", ["path": "Host > Connect"])
            #expect(await call(agent, "wait", ["until": "connected", "timeout": 20]).error == nil)
            // The connection's state is said in words, not only by the dot's colour (VoiceOver reads the same tree), once
            // the sidebar has drawn it (a moment after the state, on a busy Mac).
            var elements: [[String: Any]] = []
            #expect(await eventually {
                elements = await call(agent, "snapshot", ["include": ["elements"]])["elements"] as? [[String: Any]] ?? []
                return elements.contains { $0["role"] as? String != "statictext" && $0["title"] as? String == "Connected" }
            }, "\(elements.filter { "\($0)".contains("Connected") })")
            #expect(await call(agent, "wait", ["until": "listed", "pane": "left", "text": "file-1.txt", "timeout": 20]).error == nil)
            _ = await call(agent, "wait", ["until": "listed", "pane": "right", "text": "readme.txt", "timeout": 20])

            // A filter's reply has the filtered rows (it had the old ones and busy: false).
            reply = await call(agent, "set", ["id": "left.filter", "value": "file-29"])
            let pane = reply["pane"] as? [String: Any]
            #expect(pane?["total"] as? Int == 11 && pane?["busy"] as? Bool == false, "\(String(describing: pane?["total"]))")
            _ = await call(agent, "set", ["id": "left.filter", "value": ""])

            // View ▸ Columns: the header's menu, and the hidden ones in the snapshot.
            _ = await call(agent, "focus", ["pane": "right"])
            #expect(await call(agent, "menu", ["path": "View > Columns > Owner"]).error == nil)
            reply = await call(agent, "snapshot", ["include": ["panes"], "rows": 0])
            #expect(((reply["panes"] as? [String: Any])?["right"] as? [String: Any])?["hiddenColumns"] as? [String] == ["owner"])
            _ = await call(agent, "menu", ["path": "View > Columns > Owner"])

            // A menu item whose title is set while the menu is checked (Upload to “<folder>”) is found as it reads.
            _ = await call(agent, "select", ["pane": "left", "names": ["file-1.txt"]])
            let folder = RemotePath.name(server.home)
            reply = await call(agent, "menu", ["path": "File > Upload to “\(folder)”"])
            #expect(reply.error == nil, "\(reply.error ?? "")")
            #expect(await call(agent, "wait", ["until": "transfers_done", "timeout": 30]).error == nil)

            // A transfer job by its id, and its context menu.
            reply = await call(agent, "snapshot", ["include": ["transfers"]])
            let id = try #require(((reply["transfers"] as? [String: Any])?["jobs"] as? [[String: Any]])?.last?["id"] as? String)
            reply = await call(agent, "select", ["pane": "transfers", "ids": [id]])
            #expect(reply["selected"] as? [String] == [id], "\(reply.json) \(reply.error ?? "")")
            #expect(await call(agent, "menu", ["path": "context > Show in Finder", "pane": "transfers"]).error?.contains("no “Show in Finder”") == true)
            #expect(await call(agent, "menu", ["path": "context > Remove", "pane": "transfers"]).error == nil)
            #expect(await eventually { !TransferCenter.shared.jobs.contains { $0.id.uuidString == id } })

            // A drag into a Finder window: the file promise's download, straight to the folder (no questions).
            let finder = try server.scratch()
            try write("there", to: finder + "/readme.txt")
            _ = await call(agent, "select", ["pane": "right", "names": ["readme.txt"]])
            reply = await call(agent, "drop", ["from": "right", "to": "finder:" + finder])
            #expect((reply["jobs"] as? [[String: Any]])?.count == 1 && sheet(reply) == nil, "\(reply.json) \(reply.error ?? "")")
            #expect(await call(agent, "wait", ["until": "transfers_done", "timeout": 30]).error == nil)
            #expect(read(finder + "/readme.txt") == "there" && read(finder + "/readme 2.txt") == "x")
            // Show in Finder, on a finished download, shows what it downloaded (in Finder, on the user's screen: replaced).
            let shown = Recorder<URL>(), showInFinder = TransfersPanel.showInFinder
            TransfersPanel.showInFinder = { $0.forEach(shown.append) }
            defer { TransfersPanel.showInFinder = showInFinder }
            let download = try #require((reply["jobs"] as? [[String: Any]])?.first?["id"] as? String)  // the drop's
            _ = await call(agent, "select", ["pane": "transfers", "ids": [download]])
            #expect(await call(agent, "menu", ["path": "context > Show in Finder", "pane": "transfers"]).error == nil)
            #expect(shown.all.map(\.path) == [finder + "/readme 2.txt"], "\(shown.all)")

            // Permissions: an octal mode that isn't one turns Apply off (it applied the old mode silently).
            _ = await call(agent, "menu", ["path": "File > Permissions…"])
            _ = await call(agent, "set", ["id": "permissions.octal", "value": "999"])
            #expect(await call(agent, "press", ["title": "Apply"]).error?.contains("disabled") == true)
            _ = await call(agent, "set", ["id": "permissions.octal", "value": "640"])
            #expect(await call(agent, "press", ["title": "Apply"]).error == nil)
            #expect(await eventually { (try? FileManager.default.attributesOfItem(atPath: server.path("readme.txt"))[.posixPermissions] as? Int) == 0o640 })

            // Get Info closes with Escape.
            _ = await call(agent, "menu", ["path": "File > Get Info"])
            #expect(await call(agent, "wait", ["until": "sheet", "text": "readme.txt", "timeout": 10]).error == nil)
            _ = await call(agent, "key", ["combo": "escape"])
            #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 5]).error == nil)

            // Run Command's snippets are a pop-up an agent sets.
            model.data.snippets = [Snippet(name: "Disk usage", command: "df -h .")]
            _ = await call(agent, "menu", ["path": "Host > Run Command…"])
            reply = await call(agent, "set", ["id": "runCommand.snippet", "value": "Disk usage"])
            #expect(reply.error == nil && field(sheet(reply), "runCommand.command")?["value"] as? String == "df -h .", "\(reply.json) \(reply.error ?? "")")
            // A sheet covers the window: its controls aren't pressed under it.
            reply = await call(agent, "press", ["title": "Monitor"])
            #expect(reply.error?.contains("sheet that is open") == true && main.selectedWorkspace?.tabs.selectedTabViewItemIndex == 0)
            _ = await call(agent, "press", ["title": "Close"])
            #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 5]).error == nil)

            // The Files tab isn't shown: File-menu commands and focus say so (they looped on "focus pane first").
            _ = await call(agent, "press", ["title": "Monitor"])
            #expect(await call(agent, "focus", ["pane": "right"]).error?.contains("The Files tab isn't shown") == true)
            #expect(await call(agent, "menu", ["path": "File > New Folder…"]).error?.contains("The Files tab isn't shown") == true)
            _ = await call(agent, "press", ["title": "Files"])

            // Text in AirSCP's other windows is waited for too.
            let other = NSWindow(contentRect: NSRect(x: -21000, y: -21000, width: 300, height: 100), styleMask: [.titled], backing: .buffered,
                                 defer: false)
            other.title = "Keys"
            other.isReleasedWhenClosed = false
            other.contentView = NSTextField(labelWithString: "Added id_lab to the agent.")
            let withOther = try AgentServer(main: main, model: model, directory: URL(fileURLWithPath: try scratch() + "/agent"),
                                            windows: { [other] })
            defer { withOther.close() }
            other.orderFront(nil)
            defer { other.orderOut(nil) }
            #expect(await call(withOther, "wait", ["until": "text", "text": "Added id_lab", "timeout": 5]).error == nil)

            _ = await call(agent, "menu", ["path": "Host > Disconnect"])
            #expect(await call(agent, "wait", ["until": "disconnected", "timeout": 20]).error == nil)
        }
    }

    /// Selecting among many processes or transfer jobs works from their models (it made a view for every cell: 50 s for
    /// 311 processes, 10 minutes for 3 017), and the process table sorts and searches for agents too.
    @MainActor @Test func processesAreSelectedAndSortedQuickly() async throws {
        _ = NSApplication.shared
        let host = SSHHost(label: "linux", hostname: "linux")
        let model = testModel([host])
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let (main, agent, _) = try agentWindow(model, askpass)
        defer {
            agent.close()
            main.window?.orderOut(nil)
        }
        _ = await call(agent, "select", ["pane": "sidebar", "names": ["linux"]])
        let monitor = try #require(main.selectedWorkspace?.monitor)
        var processes = (1...3000).map { pid in
            MonitorProcess(pid: pid, ppid: 1, user: "dev", cpu: Double(pid % 50), memory: 0.1, rss: 1024, elapsed: Double(pid),
                           state: "S", name: "worker", command: "/usr/bin/worker --id \(pid)")
        }
        processes.append(MonitorProcess(pid: 4242, ppid: 1, user: "dev", cpu: 0, memory: 0, rss: 0, elapsed: 5, state: "S",
                                        name: "porter-busy", command: "sh -c porter-busy"))
        monitor.model.connected = true
        monitor.model.snapshot = MonitorSnapshot(cpu: 10, processes: processes)
        _ = await call(agent, "press", ["title": "Monitor"])
        let started = Date()
        var reply = await call(agent, "select", ["pane": "processes", "names": ["porter-busy"]])
        #expect(reply["selected"] as? [Int] == [4242] && monitor.model.selection == [4242], "\(reply.json) \(reply.error ?? "")")
        #expect(Date().timeIntervalSince(started) < 20)  // it took minutes, a row at a time
        // With a search on, only what it lists.
        monitor.model.search = "worker --id 7"
        #expect(await call(agent, "select", ["pane": "processes", "names": ["porter-busy"]]).error?.contains("search") == true)
        monitor.model.search = ""
        reply = await call(agent, "sort", ["pane": "processes", "column": "pid", "ascending": false])
        let shown = reply["monitor"] as? [String: Any]
        #expect((shown?["processes"] as? [[String: Any]])?.first?["pid"] as? Int == 4242, "\(reply.error ?? "")")
        #expect((shown?["sort"] as? [String: Any])?["column"] as? String == "pid" && shown?["connected"] as? Bool == true)
        #expect(await call(agent, "sort", ["pane": "processes", "column": "colour"]).error?.contains("pid") == true)
        #expect(await call(agent, "wait", ["until": "monitor", "text": "porter-busy", "timeout": 2]).error == nil)
    }

    /// Reading the ports is costly (every process's open files), so only Monitor ▸ Ports does it, while it is shown:
    /// of every command the session sends, none reads them in the Processes view, after going back to it, or for the
    /// header's pulse strip; the Ports view reads them at once and every 5 s, and only then are they in the snapshot.
    @MainActor @Test func portsAreReadOnlyWhileTheyAreShown() async throws {
        _ = NSApplication.shared
        try await withServer(TestServer.Options(linux: true)) { @MainActor server in
            let host = server.host()
            let model = testModel([host])
            let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
            defer { askpass.close() }
            let (main, agent, _) = try agentWindow(model, askpass)
            defer {
                agent.close()
                main.window?.orderOut(nil)
            }
            _ = await call(agent, "select", ["pane": "sidebar", "names": [host.displayName]])
            _ = await call(agent, "menu", ["path": "Host > Connect"])
            #expect(await call(agent, "wait", ["until": "connected", "timeout": 30]).error == nil)
            let workspace = try #require(main.selectedWorkspace)
            let monitor = workspace.monitor.model
            // Each command as it is sent (the command log lists a repeated one once).
            let sent = Recorder<String>()
            let log = workspace.session.onLog
            workspace.session.onLog = { entry in
                sent.append(entry.command)
                log?(entry)
            }
            func reads(after start: Int) -> (figures: Int, ports: Int) {
                let refreshes = sent.all.dropFirst(start).filter { $0.contains("@@df") }
                return (refreshes.count, refreshes.filter { $0.contains("@@ports") }.count)
            }
            // An agent at work keeps the tab refreshing, also off screen.
            @MainActor func refreshes(_ count: Int, after start: Int) async -> Bool {
                await eventually {
                    model.agentRequested()
                    return reads(after: start).figures >= count
                }
            }
            @MainActor func snapshotPorts() async -> Any? {
                (await call(agent, "snapshot", ["include": ["monitor"]])["monitor"] as? [String: Any])?["ports"]
            }

            var start = sent.all.count
            _ = await call(agent, "press", ["title": "Monitor"])
            #expect(await refreshes(2, after: start))
            #expect(reads(after: 0).ports == 0 && monitor.shown == .processes)
            #expect(await snapshotPorts() == nil)
            #expect(await call(agent, "select", ["pane": "ports", "names": ["22"]]).error?.contains("shows no ports") == true)

            // Ports: at once (this Mac has no /proc/net: the note says so), then every 5 s.
            start = sent.all.count
            _ = await call(agent, "press", ["title": "Ports"])
            #expect(monitor.shown == .ports)
            #expect(await eventually {
                model.agentRequested()
                return reads(after: start).ports >= 2
            })
            let reply = await call(agent, "wait", ["until": "monitor", "timeout": 30])
            #expect((reply["ports"] as? [String: Any])?["note"] as? String == Monitor.noPortTables, "\(reply.json)")

            // Back to the processes: the read under way ends (or is stopped), and no other follows.
            _ = await call(agent, "press", ["title": "Processes"])
            #expect(await eventually { !monitor.refreshing })
            start = sent.all.count
            #expect(await refreshes(2, after: start))
            #expect(reads(after: start).ports == 0)
            #expect(monitor.snapshot?.ports == nil)
            #expect(await snapshotPorts() == nil)

            // Ports again, then another tab: the pulse strip's refreshes read no ports either.
            _ = await call(agent, "press", ["title": "Ports"])
            #expect(await eventually {
                model.agentRequested()
                return monitor.snapshot?.ports != nil
            })
            _ = await call(agent, "press", ["title": "Files"])
            #expect(await eventually { !monitor.refreshing })
            start = sent.all.count
            #expect(await refreshes(1, after: start))
            #expect(reads(after: start).ports == 0)
        }
    }

    // MARK: Screenshots

    /// An alert sheet is drawn with its background (its text lay over the window's rows, see-through).
    @MainActor @Test func screenshotsDrawAlertsWithTheirBackground() async throws {
        _ = NSApplication.shared
        let model = testModel([SSHHost(label: "web", hostname: "web")])
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let (main, agent, _) = try agentWindow(model, askpass)
        defer {
            agent.close()
            main.window?.orderOut(nil)
        }
        let window = try #require(main.window)
        // A red window under the alert: what shows through it is red.
        let red = NSView(frame: window.contentLayoutRect)
        red.wantsLayer = true
        red.layer?.backgroundColor = NSColor.systemRed.cgColor
        window.contentView = red
        confirm("Delete “b 2.txt” on “web”?", info: "This can't be undone.", button: "Delete", destructive: true, on: window) {}
        #expect(await eventually { window.attachedSheet != nil })
        let alert = try #require(window.attachedSheet)
        let image = try #require(agent.composite(window, scale: 1))
        let rep = NSBitmapImageRep(cgImage: image)
        // The middle of the alert, between its texts and buttons: not the red under it.
        let x = Int(alert.frame.midX - window.frame.minX), y = Int(window.frame.maxY - alert.frame.midY)
        let color = try #require(rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
        #expect(!(color.redComponent > 0.8 && color.greenComponent < 0.4), "\(color)")
        window.endSheet(alert)
    }

    // MARK: Remote Desktop's shared folder

    /// Upload… / drop into the shared folder: not the folder itself (it copied itself without end), Windows names, and
    /// Disconnect asks while Windows copies into it.
    @MainActor @Test func theSharedFolderTakesWhatWindowsCanShow() async throws {
        _ = NSApplication.shared
        let root = try scratch()
        let shared = root + "/nest/shared"
        try FileManager.default.createDirectory(atPath: shared, withIntermediateDirectories: true)
        try write("minutes", to: root + "/Minutes 10:30.txt")
        var entry = RDPEntry(label: "Win", hostname: "win")
        entry.sharedFolder = shared
        let model = testModel()
        model.data.rdpEntries = [entry]
        let desktop = RDPWorkspaceController(entryID: entry.id, model: model, sshSession: { _ in throw AirSCPError.cancelled })
        let window = NSWindow(contentRect: NSRect(x: -23000, y: -23000, width: 600, height: 400), styleMask: [.titled], backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = desktop
        defer { window.orderOut(nil) }
        desktop.upload([URL(fileURLWithPath: root + "/nest")])
        #expect(window.attachedSheet != nil && names(in: shared).isEmpty)
        if let sheet = window.attachedSheet { window.endSheet(sheet) }
        desktop.upload([URL(fileURLWithPath: root + "/Minutes 10:30.txt")])
        #expect(await eventually { names(in: shared) == ["Minutes 10_30.txt"] })
        #expect(desktop.bar.message == "In Windows: \\\\tsclient\\AirSCP\\Minutes 10_30.txt")
        // A file being written (as Windows' copy is, by FreeRDP's drive channel in this process) is found.
        let copying = FileHandle(forWritingAtPath: shared + "/Minutes 10_30.txt")
        #expect(RDPSession.filesBeingWritten(in: shared).map { ($0 as NSString).lastPathComponent } == ["Minutes 10_30.txt"])
        try copying?.close()
        #expect(RDPSession.filesBeingWritten(in: shared).isEmpty)
    }

    /// A Windows path typed as Windows writes it goes where sftp has it ("C:\Windows" is /C:/Windows).
    @MainActor @Test func windowsPathsAreTypedAsWindowsWritesThem() throws {
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let session = Session(host: SSHHost(hostname: "win"), jump: nil, askpass: askpass)
        var capabilities = Capabilities()
        capabilities.windows = true
        capabilities.home = "/C:/Users/porter"
        session.capabilities = capabilities
        let browser = BrowserContentController(workspace: nil, session: session)
        _ = browser.view
        #expect(browser.right.resolve("C:\\Windows") == "/C:/Windows")
        #expect(browser.right.resolve("C:\\Windows\\Web") == "/C:/Windows/Web")
        #expect(browser.left.resolve("a\\b").map { $0.hasSuffix("/a\\b") } == true)  // this Mac's names may have a backslash
    }

    /// Find Files' Show of an item the pane's filter hides clears the filter (it selected nothing and said nothing).
    @MainActor @Test func showingAFoundItemClearsAFilterThatHidesIt() async throws {
        _ = NSApplication.shared
        let folder = try scratch()
        try write("x", to: folder + "/apple.txt")
        try write("y", to: folder + "/berry.txt")
        let pane = FilePane(source: .local, choosesSource: false, showHidden: false)
        _ = pane.view
        #expect(await pane.open(folder))
        pane.filterField.stringValue = "apple"
        _ = pane.filterField.sendAction(pane.filterField.action, to: pane.filterField.target)
        #expect(await eventually { pane.rows.map(\.name) == ["apple.txt"] })
        pane.reveal(folder + "/berry.txt")
        #expect(await eventually { pane.filter.isEmpty && pane.selectedItems.map(\.name) == ["berry.txt"] })
    }

    /// An Open or Save panel takes what an agent gives with its request (`file`), when it fits the panel, instead of
    /// showing; at other times it shows as a sheet (never app-modal: that held up every agent request).
    @MainActor @Test func panelsTakeTheAgentsChoice() throws {
        let folder = try scratch()
        try write("k", to: folder + "/key")
        func choose(_ panel: NSSavePanel, _ urls: [URL]) -> (chosen: [URL]?, problem: String?) {
            Panels.agentChoice = urls
            Panels.agentProblem = nil
            defer {
                Panels.agentChoice = nil
                Panels.agentProblem = nil
            }
            var chosen: [URL]?
            Panels.run(panel, on: nil) { chosen = $0 }
            #expect(Panels.agentChoice == nil)  // taken by this panel
            return (chosen, Panels.agentProblem)
        }
        let file = URL(fileURLWithPath: folder + "/key"), dir = URL(fileURLWithPath: folder)
        let keyPanel = NSOpenPanel()
        keyPanel.canChooseDirectories = false
        #expect(choose(keyPanel, [file]).chosen == [file])
        #expect(choose(keyPanel, [dir]).problem?.contains("is a folder") == true)
        #expect(choose(keyPanel, [URL(fileURLWithPath: folder + "/nothing")]).problem?.contains("doesn't exist") == true)
        #expect(choose(keyPanel, [file, file]).problem?.contains("one item") == true)
        let folderPanel = NSOpenPanel()
        folderPanel.canChooseFiles = false
        folderPanel.canChooseDirectories = true
        #expect(choose(folderPanel, [dir]).chosen == [dir] && choose(folderPanel, [file]).problem?.contains("is a file") == true)
        let save = NSSavePanel()
        #expect(choose(save, [URL(fileURLWithPath: folder + "/new.json")]).chosen?.first?.lastPathComponent == "new.json")
        #expect(choose(save, [URL(fileURLWithPath: "/nowhere/new.json")]).problem?.contains("doesn't exist") == true)
    }

    /// Synchronize sends many changed files of one folder as one stream (a job per file took 140 ms each: 70 s for 500),
    /// with their times, so that the next compare finds the folders the same.
    @MainActor @Test func synchronizeSendsManyFilesAsOneStream() async throws {
        _ = NSApplication.shared
        try await withServer { @MainActor server in
            var host = server.host()
            let local = try server.scratch(), there = server.path("sync")
            host.lastLocalDir = local
            for index in 0..<60 { try write("v1 \(index)", to: local + "/f\(index).txt") }
            try write("few", to: local + "/sub/one.txt")
            try rawMkdir(there)
            let session = try await server.connectedSession(host)
            let browser = BrowserContentController(workspace: nil, session: session)
            _ = browser.view
            browser.stateChanged(session.state)
            let plan = Sync.plan(try await Sync.compare(local: local, remote: there, on: session) { _ in }.differences,
                                 direction: .upload, delete: false)
            let before = session.transfers.jobs.count
            browser.apply(plan, on: session)
            await session.transfers.waitUntilIdle()
            let jobs = session.transfers.jobs.dropFirst(before)
            #expect(jobs.count == 2 && jobs.allSatisfy { $0.status == .done }, "\(jobs.map(\.name))")  // the 60 files, and sub/
            #expect(jobs.contains { $0.names.count == 60 })
            #expect(read(there + "/f59.txt") == "v1 59" && read(there + "/sub/one.txt") == "few")
            #expect(try await Sync.compare(local: local, remote: there, on: session) { _ in }.differences.isEmpty)
            // 30 changed ones (another size: within the same minute, the size tells them apart) replace theirs, as one stream.
            for index in 0..<30 { try write("v2, changed \(index)", to: local + "/f\(index).txt") }
            let changes = Sync.plan(try await Sync.compare(local: local, remote: there, on: session) { _ in }.differences,
                                    direction: .upload, delete: false)
            #expect(changes.steps.count == 30)
            let count = session.transfers.jobs.count
            browser.apply(changes, on: session)
            await session.transfers.waitUntilIdle()
            #expect(session.transfers.jobs.count == count + 1 && read(there + "/f0.txt") == "v2, changed 0")
            #expect(try await Sync.compare(local: local, remote: there, on: session) { _ in }.differences.isEmpty)
        }
    }
}

extension FeatureRoundAppTests {
    /// After Disconnect the server pane showed the folder's old rows. Through agent control: it has none and isn't
    /// "listed", and its Reconnect lists the same folder again.
    @MainActor @Test func aDisconnectedPaneIsListedAgainByItsReconnect() async throws {
        _ = NSApplication.shared
        try await withServer { @MainActor server in
            try write("x", to: server.path("logs/app.log"))
            var host = server.host()
            host.label = "lab"
            host.defaultRemoteDir = server.path("logs")
            let model = testModel([host])
            let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
            defer { askpass.close() }
            let (main, agent, _) = try agentWindow(model, askpass)
            defer {
                agent.close()
                main.window?.orderOut(nil)
            }
            _ = await call(agent, "select", ["pane": "sidebar", "names": ["lab"]])
            _ = await call(agent, "menu", ["path": "Host > Connect"])
            #expect(await call(agent, "wait", ["until": "listed", "pane": "right", "text": "app.log", "timeout": 20]).error == nil)
            _ = await call(agent, "menu", ["path": "Host > Disconnect"])
            #expect(await call(agent, "wait", ["until": "disconnected", "timeout": 20]).error == nil)
            let right = try #require(main.selectedWorkspace?.browser.right)
            #expect(right.rows.isEmpty && right.dir == server.path("logs"))
            #expect(await call(agent, "wait", ["until": "listed", "pane": "right", "timeout": 1]).error?.hasPrefix("Timed out") == true)
            // The pane's Reconnect, as its click sends it: pressed by an agent in this process beside other tests, an AppKit
            // button's click ended the test run (PLAN.md's backlog, "Test infrastructure"); agent-session.sh presses it.
            let reconnect = try #require(AgentServer.views(NSButton.self, in: right.view).first {
                $0.accessibilityIdentifier() == "right.reconnect"
            })
            #expect(!reconnect.isHidden)
            NSApp.sendAction(try #require(reconnect.action), to: reconnect.target, from: reconnect)
            let reply = await call(agent, "wait", ["until": "listed", "pane": "right", "timeout": 20])
            let rows = (reply["rows"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            #expect(reply["dir"] as? String == server.path("logs") && rows == ["app.log"], "\(reply.json) \(reply.error ?? "")")
            await main.selectedWorkspace?.connection.disconnect()
        }
    }
}
