import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AirSCP
@testable import AirSCPCore

// Settings ▸ Ask before agents change things: an agent's request that would change something outside AirSCP's own
// windows waits for the person at the Mac (Allow Once, Allow for 15 Minutes, Deny, or no answer), while looking,
// selecting and AirSCP's own fields never ask.

/// The question an agent's request waits on, once it shows.
@MainActor
func waitForQuestion(_ server: AgentServer) async -> AgentQuestion? {
    _ = await eventually(timeout: 10) { server.question != nil }
    return server.question
}

/// With the window tests that send keys and open sheets, one at a time.
extension FeatureRoundAppTests {
    @MainActor @Test func agentChangesWaitForThePersonAtTheMac() async throws {
        _ = NSApplication.shared
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let model = testModel([SSHHost(label: "web", hostname: "web")])
        let (main, server, _) = try agentWindow(model, askpass)
        defer {
            server.close()
            main.window?.orderOut(nil)
        }
        let window = try #require(main.window)
        model.data.settings.askBeforeAgentChanges = true
        var deleted = 0
        /// A question whose button is destructive, as File ▸ Delete… asks it.
        @MainActor func askToDelete() async {
            confirm("Delete “notes.txt” on “web”?", info: "This can't be undone.", button: "Delete", destructive: true,
                    on: window) { deleted += 1 }
            _ = await eventually(timeout: 10) { window.attachedSheet != nil }
        }

        // Looking, selecting and AirSCP's own sheets and fields never ask.
        #expect(await call(server, "snapshot").error == nil)
        #expect(await call(server, "screenshot").error == nil)
        #expect(await call(server, "select", ["pane": "sidebar", "names": ["web"]]).error == nil)
        #expect(await call(server, "menu", ["path": "Host > Edit…"]).error == nil)
        #expect(await call(server, "set", ["id": "hostEditor.name", "value": "web 2"]).error == nil)
        #expect(await call(server, "press", ["title": "Cancel"]).error == nil)
        #expect(server.question == nil && model.data.hosts[0].label == "web")
        let looking = await call(server, "snapshot", ["include": [String]()])
        #expect((looking["agent"] as? [String: Any])?["asksFirst"] as? Bool == true)

        // Deny: nothing happens, and the agent is told why. The question names the change and what it answers.
        await askToDelete()
        let denied = Task { await call(server, "press", ["title": "Delete"]) }
        let question = try #require(await waitForQuestion(server))
        #expect(question.change == "press “Delete”")
        #expect(question.detail.contains("Delete “notes.txt” on “web”?") && question.detail.contains("This can't be undone."))
        #expect(model.agentQuestion == "press “Delete”" && AgentStatus.state(model).contains("waits for your OK"))
        // Agents can't answer it: the panel is no window of theirs.
        let panel = try #require(NSApp.windows.first { $0 is AgentQuestionPanel && $0.isVisible })
        let other = try AgentServer(main: main, model: model, directory: URL(fileURLWithPath: try scratch() + "/agent"),
                                    windows: { NSApp.windows })
        #expect(!other.appWindows.contains(panel) && !other.isOurs(panel))
        other.close()
        #expect(await call(server, "press", ["title": "Allow Once"]).error != nil)
        question.answer = .deny
        #expect(await denied.value.error == AgentBridge.declined + "press “Delete”.")
        #expect(deleted == 0 && server.question == nil && model.agentQuestion == nil && !panel.isVisible)
        #expect(window.attachedSheet != nil)  // AirSCP's own question is still there

        // Allow Once, with the panel's own button: done.
        let allowed = Task { await call(server, "press", ["title": "Delete"]) }
        _ = try #require(await waitForQuestion(server))
        let shown = try #require(NSApp.windows.first { $0 is AgentQuestionPanel && $0.isVisible })
        let texts = AXNode.flatten(shown).compactMap { $0.value as? String }
        #expect(texts.contains("An AI agent wants to press “Delete”."))
        #expect(AXNode.flatten(shown).first { $0.title == "Allow Once" }?.press() == true)
        #expect(await allowed.value.error == nil)
        #expect(await eventually(timeout: 10) { deleted == 1 && window.attachedSheet == nil })

        // Return presses the default button, Delete: it asks too. Nobody answers: it isn't done.
        server.questionTimeout = 0.5
        await askToDelete()
        let silent = await call(server, "key", ["combo": "return"])
        #expect(silent.error?.hasPrefix(AgentBridge.noAnswer) == true, "\(silent.error ?? "")")
        #expect(deleted == 1 && window.attachedSheet != nil && server.question == nil)
        server.questionTimeout = 30

        // A click on Delete asks too.
        let elements = await call(server, "snapshot", ["include": ["elements"]])["elements"] as? [[String: Any]] ?? []
        let frame = try #require(elements.first { $0["title"] as? String == "Delete" && $0["role"] as? String == "button" }?["frame"]
            as? [Double])
        let clicked = Task { await call(server, "click", ["x": frame[0] + frame[2] / 2, "y": frame[1] + frame[3] / 2]) }
        try #require(await waitForQuestion(server)).answer = .deny
        #expect(await clicked.value.error == AgentBridge.declined + "press “Delete”.")
        #expect(deleted == 1)

        // Allow for 15 Minutes: no question until they are over (on a clock the test moves).
        var clock = Date()
        server.now = { clock }
        let first = Task { await call(server, "press", ["title": "Delete"]) }
        try #require(await waitForQuestion(server)).answer = .fifteenMinutes
        #expect(await first.value.error == nil)
        #expect(await eventually(timeout: 10) { deleted == 2 && window.attachedSheet == nil })
        #expect(model.agentAllowedUntil == clock.addingTimeInterval(15 * 60))
        #expect(AgentStatus.state(model).contains("without asking until"))
        let allowing = await call(server, "snapshot", ["include": [String]()])
        #expect((allowing["agent"] as? [String: Any])?["asksFirst"] as? Bool == false)
        await askToDelete()
        #expect(await call(server, "press", ["title": "Delete"]).error == nil)
        #expect(await eventually(timeout: 10) { deleted == 3 && window.attachedSheet == nil })
        clock = clock.addingTimeInterval(15 * 60 + 1)
        await askToDelete()
        let late = Task { await call(server, "press", ["title": "Delete"]) }
        try #require(await waitForQuestion(server)).answer = .deny
        #expect(await late.value.error == AgentBridge.declined + "press “Delete”.")
        #expect(deleted == 3)

        // Turned off: no questions.
        model.data.settings.askBeforeAgentChanges = false
        #expect(await call(server, "press", ["title": "Delete"]).error == nil && server.question == nil)
        #expect(await eventually(timeout: 10) { deleted == 4 })

        // Agent control turned off while a question waits: it goes, and the change isn't made.
        model.data.settings.askBeforeAgentChanges = true
        await askToDelete()
        let closing = Task { await call(server, "press", ["title": "Delete"]) }
        _ = try #require(await waitForQuestion(server))
        server.close()
        #expect(await closing.value.error == AgentServer.controlOff)
        #expect(deleted == 4 && !(NSApp.windows.contains { $0 is AgentQuestionPanel && $0.isVisible }))
        _ = window.attachedSheet.map { window.endSheet($0) }
    }

    /// Only the person at the Mac turns the questions off: an agent's set, press or click is refused (turning them on
    /// is fine).
    @MainActor @Test func agentsCantTurnTheQuestionsOff() async throws {
        _ = NSApplication.shared
        let model = testModel([])
        model.data.settings.askBeforeAgentChanges = true
        let settings = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        settings.title = "Settings"
        settings.isReleasedWhenClosed = false
        settings.setContentSize(NSSize(width: 540, height: 400))
        settings.setFrameOrigin(NSPoint(x: -21000, y: -21000))
        let agent = try AgentServer(main: nil, model: model, directory: URL(fileURLWithPath: try scratch() + "/agent"),
                                    windows: { [settings].filter(\.isVisible) })
        agent.showQuestion = offScreen
        settings.orderFront(nil)
        defer {
            agent.close()
            settings.orderOut(nil)
        }
        let id = AgentServer.askSetting
        #expect(await call(agent, "set", ["id": id, "value": false, "in": "window:Settings"]).error == AgentServer.onlyThePerson)
        #expect(await call(agent, "press", ["id": id, "in": "window:Settings"]).error == AgentServer.onlyThePerson)
        // Nor a space pressed or typed while the switch has the keyboard (as Tab gives it with keyboard navigation on).
        let toggle = try #require(AXNode.flatten(settings).first { $0.id == id }?.view)
        #expect(settings.makeFirstResponder(toggle))
        #expect(await call(agent, "key", ["combo": "space", "in": "window:Settings"]).error == AgentServer.onlyThePerson)
        #expect(await call(agent, "type", ["text": " ", "in": "window:Settings"]).error == AgentServer.onlyThePerson)
        #expect(model.data.settings.askBeforeAgentChanges && agent.question == nil)
        model.data.settings.askBeforeAgentChanges = false
        #expect(await eventually(timeout: 10) {  // the switch shows it
            let elements = await call(agent, "snapshot", ["include": ["elements"], "in": "window:Settings"])["elements"]
                as? [[String: Any]] ?? []
            return (elements.first { $0["id"] as? String == id }?["value"] as? NSNumber)?.boolValue == false
        })
        #expect(await call(agent, "set", ["id": id, "value": true, "in": "window:Settings"]).error == nil)
        #expect(await eventually(timeout: 10) { model.data.settings.askBeforeAgentChanges })
    }

    /// What asks on a server: a delete that doesn't ask itself, a drop, Permissions' Apply, Make Executable, Rename's
    /// button, typing into the Terminal tab, a snippet typed at its prompt, cd typed into a shell that may be busy; not a
    /// delete whose own question asks (its Delete button does), nor going, opening folders, selecting, sorting, waiting
    /// or cd at an empty prompt.
    @MainActor @Test func agentChangesOnAServerAskAndLookingDoesNot() async throws {
        _ = NSApplication.shared
        var options = TestServer.Options()
        options.shell = "/bin/zsh"  // marks its commands: AirSCP knows when it waits at an empty prompt
        try await withServer(options) { @MainActor server in
            var host = server.host()
            host.label = "lab"
            let local = try server.scratch()
            host.lastLocalDir = local
            try write("one", to: server.path("a.txt"))
            try write("two", to: server.path("b.txt"))
            try rawMkdir(server.path("folder"))
            try write("", to: server.path(".zshrc"))
            try write("up", to: local + "/up.txt")
            let model = testModel([host])
            let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
            defer { askpass.close() }
            let (main, agent, _) = try agentWindow(model, askpass)
            defer {
                agent.close()
                main.window?.orderOut(nil)
            }
            model.data.settings.askBeforeAgentChanges = true
            agent.questionTimeout = 5  // a question nobody expects ends the step with an error, soon

            // Connecting, trusting the server, going, opening a folder, selecting, sorting and waiting don't ask.
            #expect(await call(agent, "select", ["pane": "sidebar", "names": ["lab"]]).error == nil)
            #expect(await call(agent, "menu", ["path": "Host > Connect"]).error == nil)
            #expect(await call(agent, "wait", ["until": "connected", "timeout": 20]).error == nil)
            #expect(await call(agent, "wait", ["until": "listed", "pane": "right", "text": "a.txt", "timeout": 20]).error == nil)
            #expect(await call(agent, "open", ["name": "folder"]).error == nil)
            #expect(await call(agent, "open", ["name": ".."]).error == nil)
            #expect(await call(agent, "sort", ["pane": "right", "column": "size"]).error == nil)
            #expect(await call(agent, "select", ["pane": "right", "names": ["a.txt"]]).error == nil)
            #expect(agent.question == nil)

            // Delete asks its own question: its Delete button asks the person.
            let reply = await call(agent, "menu", ["path": "File > Delete…"])
            #expect(reply.error == nil && agent.question == nil && sheet(reply) != nil)
            let pressed = Task { await call(agent, "press", ["title": "Delete"]) }
            let question = try #require(await waitForQuestion(agent))
            #expect(question.change == "press “Delete”" && question.detail.contains("Delete “a.txt” on “lab”?"))
            question.answer = .once
            #expect(await pressed.value.error == nil)
            #expect(await eventually(timeout: 20) { !FileManager.default.fileExists(atPath: server.path("a.txt")) })
            #expect(await call(agent, "wait", ["until": "listed", "pane": "right", "timeout": 20]).error == nil)

            // Without that question (Settings), File ▸ Delete… asks the person itself, naming what it deletes.
            model.data.settings.confirmDelete = false
            #expect(await call(agent, "select", ["pane": "right", "names": ["b.txt"]]).error == nil)
            let deleting = Task { await call(agent, "menu", ["path": "File > Delete…"]) }
            let delete = try #require(await waitForQuestion(agent))
            #expect(delete.change == "choose File ▸ Delete…" && delete.detail.contains("“b.txt” in \(server.home) on “lab”"))
            delete.answer = .deny
            #expect(await deleting.value.error == AgentBridge.declined + "choose File ▸ Delete….")
            #expect(FileManager.default.fileExists(atPath: server.path("b.txt")))

            // A drop that uploads asks, naming the files and where they go.
            let dropping = Task { await call(agent, "drop", ["files": [local + "/up.txt"], "pane": "right"]) }
            let drop = try #require(await waitForQuestion(agent))
            #expect(drop.change == "upload “up.txt” into \(server.home) on “lab”" && drop.detail.hasSuffix("/up.txt"))
            drop.answer = .once
            #expect(await dropping.value.error == nil)
            #expect(await eventually(timeout: 20) { FileManager.default.fileExists(atPath: server.path("up.txt")) })

            // Permissions' Apply (chmod and chown, with folders everything in them too) asks; filling in the sheet doesn't.
            func mode() -> Int? { (try? FileManager.default.attributesOfItem(atPath: server.path("up.txt")))?[.posixPermissions] as? Int }
            let before = mode()
            #expect(await call(agent, "wait", ["until": "listed", "pane": "right", "text": "up.txt", "timeout": 20]).error == nil)
            #expect(await call(agent, "select", ["pane": "right", "names": ["up.txt"]]).error == nil)
            #expect(await call(agent, "menu", ["path": "File > Permissions…"]).error == nil)
            #expect(await call(agent, "set", ["id": "permissions.octal", "value": "600"]).error == nil && agent.question == nil)
            let applying = Task { await call(agent, "press", ["title": "Apply"]) }
            let apply = try #require(await waitForQuestion(agent))
            #expect(apply.change == "press “Apply”")
            apply.answer = .deny
            #expect(await applying.value.error == AgentBridge.declined + "press “Apply”.")
            #expect(await call(agent, "press", ["title": "Cancel"]).error == nil && mode() == before && before != 0o600)

            // Make Executable (chmod +x) asks; so does Rename's button, with the new name (typing it doesn't).
            let executable = Task { await call(agent, "menu", ["path": "File > Make Executable"]) }
            let chmodX = try #require(await waitForQuestion(agent))
            #expect(chmodX.change == "choose File ▸ Make Executable" && chmodX.detail.contains("“up.txt”"), "\(chmodX.detail)")
            chmodX.answer = .deny
            #expect(await executable.value.error == AgentBridge.declined + "choose File ▸ Make Executable.")
            #expect(mode() == before)
            #expect(await call(agent, "menu", ["path": "File > Rename…"]).error == nil && agent.question == nil)
            #expect(await call(agent, "set", ["id": "prompt.name", "value": "renamed.txt"]).error == nil && agent.question == nil)
            let renaming = Task { await call(agent, "press", ["title": "Rename"]) }
            let rename = try #require(await waitForQuestion(agent))
            #expect(rename.change == "press “Rename”" && rename.detail.contains("Rename “up.txt”")
                    && rename.detail.contains("renamed.txt"), "\(rename.detail)")
            rename.answer = .deny
            #expect(await renaming.value.error == AgentBridge.declined + "press “Rename”.")
            #expect(await call(agent, "press", ["title": "Cancel"]).error == nil)
            #expect(exists(server.path("up.txt")) && !exists(server.path("renamed.txt")))

            // Typing into the Terminal tab asks, showing what would be typed.
            #expect(await call(agent, "menu", ["path": "Host > Terminal Tab"]).error == nil)
            #expect(await eventually(timeout: 20) { main.selectedWorkspace?.terminal.session?.screen.shellPID != nil })
            agent.questionTimeout = 30
            let typing = Task { await call(agent, "type", ["text": "rm -rf ~/x\n", "target": "terminal"]) }
            let type = try #require(await waitForQuestion(agent))
            #expect(type.change == "type into the Terminal tab of “lab”" && type.detail == "rm -rf ~/x⏎" && type.code)
            type.answer = .deny
            #expect(await typing.value.error == AgentBridge.declined + "type into the Terminal tab of “lab”.")

            // Insert Snippet types a snippet at the prompt: it asks, showing the snippet.
            let screen = try #require(main.selectedWorkspace?.terminal.session?.screen)
            #expect(await eventually(timeout: 20) { screen.waitsAtPrompt }, "\(screen.text)")
            model.data.snippets = [Snippet(name: "clean", command: "rm -rf build")]
            let inserting = Task { await call(agent, "set", ["id": "terminal.snippets", "value": "clean"]) }
            let insert = try #require(await waitForQuestion(agent))
            #expect(insert.change == "type the snippet “clean” into the Terminal tab of “lab”" && insert.detail == "rm -rf build"
                    && insert.code)
            insert.answer = .deny
            #expect(await inserting.value.error == AgentBridge.declined + insert.change + ".")
            #expect(!screen.text.contains("rm -rf build") && screen.waitsAtPrompt)

            // History… types its entry at the prompt: its Insert asks, showing the command.
            main.selectedWorkspace?.terminal.history.add("rm -rf cache")
            #expect(await call(agent, "press", ["id": "terminal.history"]).error == nil && agent.question == nil)
            #expect(await call(agent, "wait", ["until": "sheet", "timeout": 10]).error == nil)
            let inserting2 = Task { await call(agent, "press", ["title": "Insert"]) }
            let history = try #require(await waitForQuestion(agent))
            #expect(history.change == "type into the Terminal tab of “lab”" && history.detail == "rm -rf cache" && history.code)
            history.answer = .deny
            #expect(await inserting2.value.error == AgentBridge.declined + history.change + ".")
            #expect(await call(agent, "press", ["title": "Cancel"]).error == nil)
            #expect(!screen.text.contains("rm -rf cache") && screen.waitsAtPrompt)

            // Open Terminal Here in the tab: cd at the empty prompt goes to a folder, which doesn't ask. A shell that may
            // be busy gets nothing typed: a new tab opens there, which doesn't ask either.
            model.data.settings.openTerminalHereInTab = true
            _ = await call(agent, "press", ["title": "Files"])
            #expect(await call(agent, "select", ["pane": "right", "names": ["folder"]]).error == nil)
            #expect(await call(agent, "menu", ["path": "File > Open Terminal Here"]).error == nil && agent.question == nil)
            #expect(await eventually(timeout: 20) { screen.directory == server.path("folder") && screen.waitsAtPrompt },
                    "\(screen.directory ?? "nil")")
            main.selectedWorkspace?.terminal.session?.send("echo")  // typed at the prompt: not empty any more
            #expect(await eventually(timeout: 10) { !screen.waitsAtPrompt })
            _ = await call(agent, "press", ["title": "Files"])
            #expect(await call(agent, "go", ["pane": "right", "path": server.home]).error == nil)
            #expect(await call(agent, "select", ["pane": "right", "names": ["folder"]]).error == nil)
            #expect(await call(agent, "menu", ["path": "File > Open Terminal Here"]).error == nil && agent.question == nil)
            #expect(main.selectedWorkspace?.terminal.sessions.count == 2 && !screen.waitsAtPrompt)
            #expect(await eventually(timeout: 20) { main.selectedWorkspace?.terminal.session?.screen.directory == server.path("folder") })

            // Closing a tab whose command still runs: AirSCP's own question, whose Close Tab asks the person.
            let terminal = try #require(main.selectedWorkspace?.terminal)
            let busy = try #require(terminal.session?.screen)
            #expect(await eventually(timeout: 20) { busy.waitsAtPrompt })
            terminal.session?.send("sleep 30\r")
            #expect(await eventually(timeout: 20) { busy.blocks.last?.running == true })
            let closing = await call(agent, "press", ["id": "terminal.closeTab"])
            #expect(closing.error == nil && agent.question == nil && sheet(closing) != nil, "\(closing.json)")
            let closed = Task { await call(agent, "press", ["title": "Close Tab"]) }
            let close = try #require(await waitForQuestion(agent))
            #expect(close.change == "press “Close Tab”" && close.detail.contains("sleep 30"), "\(close.detail)")
            close.answer = .deny
            #expect(await closed.value.error == AgentBridge.declined + "press “Close Tab”.")
            #expect(terminal.sessions.count == 2 && terminal.session?.screen === busy)
            #expect(await call(agent, "press", ["title": "Cancel"]).error == nil)

            terminal.sessions.forEach { $0.close() }
            await main.selectedWorkspace?.connection.disconnect()
        }
    }

    /// On S3 storage, what changes it asks as on a server (Move To…, a drop, Rename's and Delete's buttons); so do Compress
    /// and Extract, which copy through this Mac there, and a presigned link, which lets anyone download the file. Allowed,
    /// Compress's own question doesn't ask again.
    @MainActor @Test func s3ChangesZipsAndPresignedLinksAsk() async throws {
        _ = NSApplication.shared
        let storage = try TestS3()
        defer { storage.stop() }
        storage.put("bucket", "a.txt", Data("a".utf8))
        storage.put("bucket", "b.zip", Data("not opened".utf8))
        let local = try scratch()
        try write("up", to: local + "/up.txt")
        let model = testModel([storage.host()])
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let (main, agent, _) = try agentWindow(model, askpass)
        defer {
            agent.close()
            main.window?.orderOut(nil)
        }
        model.data.settings.askBeforeAgentChanges = true
        _ = await call(agent, "select", ["pane": "sidebar", "names": ["Test storage"]])
        #expect(await call(agent, "menu", ["path": "Host > Connect"]).error == nil)
        #expect(await call(agent, "wait", ["until": "connected", "timeout": 20]).error == nil)
        #expect(await call(agent, "wait", ["until": "listed", "pane": "right", "text": "bucket", "timeout": 20]).error == nil)
        #expect(await call(agent, "open", ["name": "bucket"]).error == nil && agent.question == nil)
        for (name, path) in [("a.txt", "File > Move To…"), ("a.txt", "File > Compress…"), ("b.zip", "File > Extract Here"),
                             ("b.zip", "File > Extract to New Folder"), ("a.txt", "context > Copy Presigned Link…")] {
            #expect(await call(agent, "select", ["pane": "right", "names": [name]]).error == nil)
            let asking = Task { await call(agent, "menu", ["path": path, "pane": "right"]) }
            let question = try #require(await waitForQuestion(agent), "\(path)")
            #expect(question.detail.contains("“\(name)” in /bucket on “Test storage”"), "\(path): \(question.detail)")
            question.answer = .deny
            #expect(await asking.value.error?.hasPrefix(AgentBridge.declined) == true, "\(path)")
        }
        let dropping = Task { await call(agent, "drop", ["files": [local + "/up.txt"], "pane": "right"]) }
        try #require(await waitForQuestion(agent)).answer = .deny
        #expect(await dropping.value.error?.hasPrefix(AgentBridge.declined) == true)
        for (menu, field, button) in [("File > Rename…", "renamed.txt", "Rename"), ("File > Delete…", nil, "Delete")] {
            #expect(await call(agent, "select", ["pane": "right", "names": ["a.txt"]]).error == nil)
            #expect(await call(agent, "menu", ["path": menu]).error == nil && agent.question == nil)
            if let field { #expect(await call(agent, "set", ["id": "prompt.name", "value": field]).error == nil) }
            let pressing = Task { await call(agent, "press", ["title": button]) }
            let question = try #require(await waitForQuestion(agent), "\(menu)")
            #expect(question.change == "press “\(button)”")
            question.answer = .deny
            #expect(await pressing.value.error == AgentBridge.declined + "press “\(button)”.")
            #expect(await call(agent, "press", ["title": "Cancel"]).error == nil)
        }
        #expect(storage.keys("bucket") == ["a.txt", "b.zip"])
        #expect(main.selectedWorkspace?.session.transfers.jobs.isEmpty == true && main.window?.attachedSheet == nil)

        _ = await call(agent, "select", ["pane": "right", "names": ["a.txt"]])
        let compressing = Task { await call(agent, "menu", ["path": "File > Compress…"]) }
        try #require(await waitForQuestion(agent)).answer = .once
        #expect(await compressing.value.error == nil)
        #expect(await call(agent, "press", ["title": "Compress"]).error == nil && agent.question == nil)
        #expect(await eventually(timeout: 30) { storage.keys("bucket").contains("a.txt.zip") }, "\(storage.keys("bucket"))")
        await main.selectedWorkspace?.connection.disconnect()
    }
}

/// Text past a question's tenth line isn't hidden unsaid: the panel shows ten lines, then how many more there are (a
/// command's end could be anywhere below).
@MainActor @Test func aLongQuestionSaysHowManyLinesItLeavesOut() throws {
    _ = NSApplication.shared
    let agent = try AgentServer(main: nil, model: testModel([]), directory: URL(fileURLWithPath: try scratch() + "/agent"),
                                windows: { [] })  // agent control on: SwiftUI builds the panel's accessibility nodes
    defer { agent.close() }
    let lines = (1...15).map { "echo \($0)⏎" }
    for (count, shown) in [(15, lines.prefix(10).joined(separator: "\n") + "\n… and 5 more lines"),
                           (11, lines.prefix(10).joined(separator: "\n") + "\n… and 1 more line"),
                           (10, lines.prefix(10).joined(separator: "\n"))] {
        let panel = AgentQuestionPanel(AgentQuestion(change: "type into the Terminal tab of “web”",
                                                     detail: lines.prefix(count).joined(separator: "\n"), code: true,
                                                     client: nil, timeout: 45))
        offScreen(panel)
        defer { panel.close() }
        let texts = AXNode.flatten(panel).compactMap { $0.value as? String }
        #expect(texts.contains(shown) && !texts.contains { $0.contains("echo 11⏎") }, "\(count): \(texts)")
    }
}

/// A Save panel that an agent's file= answers asks before it replaces a file, as the panel would: the save waits for
/// agent control, which asks the person at the Mac. A new file is saved at once.
@MainActor @Test func anAgentsSaveOverAFileWaitsForTheQuestion() throws {
    _ = NSApplication.shared
    let dir = try scratch()
    let existing = URL(fileURLWithPath: dir + "/hosts.json"), new = URL(fileURLWithPath: dir + "/new.json")
    try write("{}", to: existing.path)
    defer {
        Panels.agentChoice = nil
        Panels.agentReplacing = nil
    }
    var saved: [URL] = []
    Panels.agentChoice = [new]
    Panels.run(NSSavePanel(), on: nil) { saved += $0 }
    #expect(saved == [new] && Panels.agentReplacing == nil)
    Panels.agentChoice = [existing]
    Panels.run(NSSavePanel(), on: nil) { saved += $0 }
    #expect(saved == [new] && Panels.agentReplacing?.file == existing)
    Panels.agentReplacing?.save()
    #expect(saved == [new, existing])
    // An Open panel takes what is there: no question.
    Panels.agentReplacing = nil
    Panels.agentChoice = [existing]
    Panels.run(NSOpenPanel(), on: nil) { saved += $0 }
    #expect(saved == [new, existing, existing] && Panels.agentReplacing == nil)
}
