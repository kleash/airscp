import AppKit
import Darwin
import Foundation
import SwiftUI
import Testing
@testable import AirSCP
@testable import AirSCPCore

// PLAN.md S.2 and the rest of the feature cycle's round-1 verdict, through the app's windows and agent control: the
// Transfers panel's speed limit, favourites, the conflict sheet's line about both items, the folder sheet's Leave out,
// the download folder, Keys ▸ Install on Host on an sftp-only account, a verification code, Escape on an alert with one
// button and the Window menu. One at a time, as FeatureRoundAppTests.

@MainActor @Suite(.serialized) struct S2AppTests {
    /// A connected host's window under agent control: the host "lab" of `server` (its local pane in `local`).
    private func connected(_ server: TestServer, local: String, _ askpass: AskpassServer,
                           model makeModel: ((SSHHost) -> AppModel)? = nil)
        async throws -> (main: MainWindowController, agent: AgentServer, model: AppModel, host: SSHHost) {
        var host = server.host()
        host.label = "lab"
        host.lastLocalDir = local
        let model = makeModel?(host) ?? testModel([host])
        let (main, agent, _) = try agentWindow(model, askpass)
        _ = await call(agent, "select", ["pane": "sidebar", "names": ["lab"]])
        _ = await call(agent, "menu", ["path": "Host > Connect"])
        #expect(await call(agent, "wait", ["until": "connected", "timeout": 20]).error == nil)
        #expect(await call(agent, "wait", ["until": "listed", "pane": "right", "path": server.home, "timeout": 20]).error == nil)
        #expect(await call(agent, "wait", ["until": "listed", "pane": "left", "path": local, "timeout": 20]).error == nil)
        return (main, agent, model, host)
    }

    // MARK: Speed limit

    /// The Transfers panel's Speed pop-up: the setting (saved in airscp.json), and the snapshot's transfers.speedLimit.
    @MainActor @Test func theSpeedLimitIsAPopUpInTheTransfersPanel() async throws {
        _ = NSApplication.shared
        let saved = Recorder<AirSCPData>()
        let model = testModel([SSHHost(label: "web", hostname: "web")], saved: saved)
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let (main, agent, _) = try agentWindow(model, askpass)
        defer {
            agent.close()
            main.window?.orderOut(nil)
        }
        var reply = await call(agent, "snapshot", ["include": ["transfers"]])
        #expect((reply["transfers"] as? [String: Any])?["speedLimit"] as? String == "Unlimited")
        reply = await call(agent, "set", ["id": "transfers.speedLimit", "value": "5 MB/s"])
        #expect(reply.error == nil, "\(reply.error ?? "")")
        #expect(model.data.settings.transferSpeedLimit == 5 && saved.all.last?.settings.transferSpeedLimit == 5)
        reply = await call(agent, "snapshot", ["include": ["transfers"]])
        #expect((reply["transfers"] as? [String: Any])?["speedLimit"] as? String == "5 MB/s")
        _ = await call(agent, "set", ["id": "transfers.speedLimit", "value": "Unlimited"])
        #expect(model.data.settings.transferSpeedLimit == 0)
    }

    // MARK: Favourites

    /// Go ▸ Add to Favourites keeps a server folder for its host; Go ▸ Favourites lists them for the focused pane, goes
    /// to one and removes one; a pane showing this Mac says why it can't.
    @MainActor @Test func favouritesAreKeptPerServerForTheFocusedPane() async throws {
        _ = NSApplication.shared
        try await withServer { @MainActor server in
            try rawMkdir(server.path("deep"))
            try rawMkdir(server.path("deep/er"))
            let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
            defer { askpass.close() }
            let (main, agent, model, host) = try await connected(server, local: try server.scratch(), askpass)
            defer {
                agent.close()
                main.window?.orderOut(nil)
            }
            let right = try #require(main.selectedWorkspace?.browser.right)
            let deep = server.path("deep/er")
            #expect(await right.open(deep))
            _ = await call(agent, "focus", ["pane": "right"])
            var reply = await call(agent, "menu", ["path": "Go > Add to Favourites"])
            #expect(reply.error == nil && model.host(host.id)?.favourites == [deep], "\(reply.error ?? "")")
            reply = await call(agent, "menu", ["path": "Go > Add to Favourites"])
            #expect(reply.error?.contains("in Go ▸ Favourites already") == true, "\(reply.error ?? "")")
            // In the menus (snapshot) and the pane's slice.
            reply = await call(agent, "snapshot", ["include": ["menus", "panes"], "rows": 0])
            let paths = (reply["menus"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            #expect(paths.contains("Go > Favourites > \(deep)") && paths.contains("Go > Favourites > Remove > \(deep)"),
                    "\(paths.filter { $0.hasPrefix("Go") })")
            #expect(((reply["panes"] as? [String: Any])?["right"] as? [String: Any])?["favourites"] as? [String] == [deep])
            // From elsewhere, back to it.
            #expect(await right.open(server.home))
            #expect(await call(agent, "menu", ["path": "Go > Favourites > \(deep)"]).error == nil)
            #expect(await call(agent, "wait", ["until": "listed", "pane": "right", "path": deep, "timeout": 20]).error == nil)
            // This Mac's pane: why not.
            _ = await call(agent, "focus", ["pane": "left"])
            #expect(await call(agent, "menu", ["path": "Go > Add to Favourites"]).error?.contains("a server's folders") == true)
            // Removed.
            _ = await call(agent, "focus", ["pane": "right"])
            #expect(await call(agent, "menu", ["path": "Go > Favourites > Remove > \(deep)"]).error == nil)
            #expect(model.host(host.id)?.favourites == [])
            reply = await call(agent, "snapshot", ["include": ["menus"]])
            #expect(!(reply["menus"] as? [[String: Any]] ?? []).contains { ($0["path"] as? String)?.hasPrefix("Go > Favourites >") == true })
            await main.selectedWorkspace?.connection.disconnect()
        }
    }

    // MARK: Conflicts

    /// The Replace / Keep Both / Skip sheet says how the two items compare (sizes and dates): uploads, downloads, renames.
    @MainActor @Test func conflictSheetsCompareTheTwoItems() async throws {
        _ = NSApplication.shared
        try await withServer { @MainActor server in
            let local = try server.scratch()
            try write("a newer, longer text", to: local + "/notes.txt")
            try write("old", to: server.path("notes.txt"))
            try write("b", to: server.path("b.txt"))
            let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
            defer { askpass.close() }
            let (main, agent, _, _) = try await connected(server, local: local, askpass)
            defer {
                agent.close()
                main.window?.orderOut(nil)
            }
            func line(_ reply: Reply) -> String { sheet(reply)?["text"] as? String ?? "" }
            // Upload onto the server's older, shorter file.
            _ = await call(agent, "select", ["pane": "left", "names": ["notes.txt"]])
            var reply = await call(agent, "drop", ["from": "left", "to": "right"])
            #expect(line(reply).contains("New: \(FileList.size(20)), ") && line(reply).contains(" · Existing: \(FileList.size(3)), "),
                    "\(reply.json) \(reply.error ?? "")")
            _ = await call(agent, "press", ["title": "Skip"])
            // Download onto this Mac's file.
            _ = await call(agent, "select", ["pane": "right", "names": ["notes.txt"]])
            reply = await call(agent, "drop", ["from": "right", "to": "left"])
            #expect(line(reply).contains("New: \(FileList.size(3)), ") && line(reply).contains(" · Existing: \(FileList.size(20)), "),
                    "\(reply.json)")
            _ = await call(agent, "press", ["title": "Skip"])
            #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 5]).error == nil)
            // Rename onto another file.
            _ = await call(agent, "select", ["pane": "right", "names": ["b.txt"]])
            _ = await call(agent, "menu", ["path": "File > Rename…"])
            _ = await call(agent, "set", ["id": "prompt.name", "value": "notes.txt"])
            reply = await call(agent, "press", ["title": "Rename"])
            if sheet(reply)?["title"] as? String == nil { reply = Reply(json: ["sheet": await call(agent, "wait", ["until": "sheet", "timeout": 10]).json]) }
            #expect(line(reply).contains("New: \(FileList.size(1)), ") && line(reply).contains(" · Existing: \(FileList.size(3)), "),
                    "\(reply.json)")
            _ = await call(agent, "press", ["title": "Cancel"])
            #expect(read(server.path("notes.txt")) == "old" && read(local + "/notes.txt") == "a newer, longer text")
            await main.selectedWorkspace?.connection.disconnect()
        }
    }

    // MARK: Leave out

    /// The folder sheet's Leave out: what matches stays behind (at any depth), and the patterns are remembered for the
    /// server.
    @MainActor @Test func leaveOutIsAskedForFoldersAndRemembered() async throws {
        _ = NSApplication.shared
        try await withServer { @MainActor server in
            let local = try server.scratch()
            for path in ["keep.txt", "debug.log", "node_modules/x/index.js", "sub/trace.log", "sub/c.txt"] {
                try write(path, to: local + "/site/" + path)
            }
            let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
            defer { askpass.close() }
            let (main, agent, model, host) = try await connected(server, local: local, askpass)
            defer {
                agent.close()
                main.window?.orderOut(nil)
            }
            _ = await call(agent, "select", ["pane": "left", "names": ["site"]])
            var reply = await call(agent, "drop", ["from": "left", "to": "right"])
            #expect(field(sheet(reply), "transfer.leaveOut") != nil, "\(reply.json) \(reply.error ?? "")")
            #expect(await call(agent, "set", ["id": "transfer.leaveOut", "value": "*.log, node_modules/"]).error == nil)
            _ = await call(agent, "press", ["title": "Upload"])
            #expect(await call(agent, "wait", ["until": "transfers_done", "timeout": 30]).error == nil)
            #expect(files(below: server.path("site")) == ["keep.txt", "sub/c.txt"])
            #expect(model.host(host.id)?.leaveOut == "*.log, node_modules/")
            // Remembered: the next folder sheet for this server has it.
            reply = await call(agent, "drop", ["from": "left", "to": "right"])
            #expect(field(sheet(reply), "transfer.leaveOut")?["value"] as? String == "*.log, node_modules/", "\(reply.json)")
            _ = await call(agent, "press", ["title": "Cancel"])
            await main.selectedWorkspace?.connection.disconnect()
        }
    }

    // MARK: The download folder

    /// Settings ▸ Download to (Choose…) is where Download To… opens and, with a server in the other pane, where Download
    /// as .tar.gz puts the archive. (Paste Items to Mac… of a Remote Desktop: the VM test.)
    @MainActor @Test func theDownloadFolderIsWhereDownloadsStart() async throws {
        _ = NSApplication.shared
        try await withServer { @MainActor server in
            try write("fetched", to: server.path("a.txt"))
            let first = try server.scratch(), chosen = try server.scratch(), into = try server.scratch()
            let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
            defer { askpass.close() }
            let (main, mainAgent, model, _) = try await connected(server, local: try server.scratch(), askpass) { host in
                let model = testModel([host])
                model.data.settings.downloadFolder = first
                return model
            }
            mainAgent.close()
            // The Settings window, as the app makes it, under agent control too.
            let settings = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
            settings.title = "Settings"
            settings.isReleasedWhenClosed = false
            settings.setFrameOrigin(NSPoint(x: -21000, y: -21000))
            let agent = try AgentServer(main: main, model: model, directory: URL(fileURLWithPath: try scratch() + "/agent"),
                                        windows: { [settings].filter(\.isVisible) })
            settings.orderFront(nil)
            defer {
                agent.close()
                settings.orderOut(nil)
                main.window?.orderOut(nil)
            }
            // (An agent's file is taken as a standardized URL gives it: /tmp, not /private/tmp.)
            func same(_ path: String?, _ other: String) -> Bool {
                path.map { URL(fileURLWithPath: $0).standardizedFileURL.path } == URL(fileURLWithPath: other).standardizedFileURL.path
            }
            var reply = await call(agent, "press", ["title": "Choose…", "in": "window:Settings", "file": chosen])
            #expect(reply.error == nil && same(reply["panelFolder"] as? String, first), "\(reply.json) \(reply.error ?? "")")
            #expect(same(model.data.settings.downloadFolder, chosen))
            #expect(await call(agent, "wait", ["until": "text", "text": RemotePath.name(chosen), "timeout": 5]).error == nil)

            // Download To… opens in it.
            _ = await call(agent, "select", ["pane": "right", "names": ["a.txt"]])
            reply = await call(agent, "menu", ["path": "File > Download To…", "file": into])
            #expect(reply.error == nil && same(reply["panelFolder"] as? String, chosen), "\(reply.json) \(reply.error ?? "")")
            #expect(await call(agent, "wait", ["until": "transfers_done", "timeout": 30]).error == nil)
            #expect(read(into + "/a.txt") == "fetched")

            // Download as .tar.gz with the other pane on a server: into the download folder.
            #expect(await call(agent, "set", ["id": "left.source", "value": "lab"]).error == nil)
            #expect(await call(agent, "wait", ["until": "listed", "pane": "left", "text": "a.txt", "timeout": 20]).error == nil)
            _ = await call(agent, "select", ["pane": "right", "names": ["a.txt"]])
            reply = await call(agent, "menu", ["path": "File > Download as .tar.gz…"])
            #expect((sheet(reply)?["text"] as? String)?.contains("Into “\(RemotePath.name(chosen))”") == true, "\(reply.json)")
            _ = await call(agent, "press", ["title": "Cancel"])
            await main.selectedWorkspace?.connection.disconnect()
        }
    }

    // MARK: Keys

    /// Keys ▸ Install on Host on an account that only allows file transfers: the key goes into its ~/.ssh/authorized_keys
    /// over sftp, and logs in afterwards. (The server's home is a scratch folder, never this Mac's ~/.ssh.)
    @MainActor @Test func installingAKeyOnAnSFTPOnlyAccountLetsItLogIn() async throws {
        _ = NSApplication.shared
        try await withServer(TestServer.Options(sftpOnly: true)) { @MainActor server in
            var host = server.host()
            host.label = "files only"
            let model = testModel([host])
            let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
            defer { askpass.close() }
            let (main, mainAgent, _) = try agentWindow(model, askpass)
            mainAgent.close()
            let folder = try server.scratch()
            try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "installed by airscp", "-f", folder + "/id_new"])
            let keys = KeysModel(folder: folder, askpass: [:])
            await keys.refresh()
            // The Keys window as the app makes it, installing as the app does (connect, then install).
            let keysWindow = NSWindow(contentRect: NSRect(x: -21000, y: -21500, width: 780, height: 400), styleMask: [.titled],
                                      backing: .buffered, defer: false)
            keysWindow.title = "Keys"
            keysWindow.isReleasedWhenClosed = false
            keysWindow.contentView = NSHostingView(rootView: KeysView(keys: keys, model: model, install: { [weak main] key, id in
                main?.open(id) { $0.installKey(key) }
            }, report: { _, _ in }))
            let agent = try AgentServer(main: main, model: model, directory: URL(fileURLWithPath: try scratch() + "/agent"),
                                        windows: { [keysWindow].filter(\.isVisible) })
            keysWindow.orderFront(nil)
            defer {
                agent.close()
                keysWindow.orderOut(nil)
                main.window?.orderOut(nil)
            }
            #expect(await call(agent, "select", ["in": "window:Keys", "names": ["id_new"]]).error == nil)
            #expect(await call(agent, "press", ["title": "Install on Host…", "in": "window:Keys"]).error == nil)
            var reply = await call(agent, "set", ["title": "Host", "value": "files only", "in": "window:Keys"])
            #expect(reply.error == nil, "\(reply.error ?? "")")
            #expect(await call(agent, "press", ["title": "Install", "in": "window:Keys"]).error == nil)
            reply = await call(agent, "wait", ["until": "sheet", "text": "The key was installed", "timeout": 30])
            #expect(reply.error == nil, "\(reply.json) \(reply.error ?? "")")
            #expect(await call(agent, "key", ["combo": "escape"]).error == nil)  // its one button, OK
            #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 5]).error == nil)
            let installed = read(server.path(".ssh/authorized_keys")) ?? ""
            #expect(installed.contains(try String(contentsOfFile: folder + "/id_new.pub").trimmingCharacters(in: .whitespacesAndNewlines)))
            #expect(main.selectedWorkspace?.session.capabilities.shell == false)  // the sftp route, not ssh-copy-id
            // It logs in.
            let session = try server.session(server.host(key: folder + "/id_new"))
            try await session.connect()
            #expect(session.state == .connected)
            await main.selectedWorkspace?.connection.disconnect()
        }
    }

    // MARK: Two-factor (AIRSCP_DOCKER=1)

    /// A verification code through the window: the question names the host and shows ssh's words, and a wrong code is
    /// asked again saying it wasn't accepted.
    @MainActor @Test(.enabled(if: Lab.enabled)) func aVerificationCodeIsAskedInTheWindow() async throws {
        _ = NSApplication.shared
        var host = Lab.twofactor()
        host.label = "two-factor"
        let model = testModel([host])
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let (main, agent, _) = try agentWindow(model, askpass)
        defer {
            agent.close()
            main.window?.orderOut(nil)
        }
        _ = await call(agent, "select", ["pane": "sidebar", "names": ["two-factor"]])
        _ = await call(agent, "menu", ["path": "Host > Connect"])
        var reply = await call(agent, "wait", ["until": "sheet", "timeout": 30])
        #expect(reply["title"] as? String == "two-factor asks", "\(reply.json) \(reply.error ?? "")")
        // ssh's words end in ":", so the snapshot gives them as the answer field's label.
        let answer = field(reply.json, "prompt.answer")
        #expect((answer?["label"] as? String)?.hasSuffix("Verification code") == true && answer?["secure"] as? Bool == true,
                "\(reply.json)")
        _ = await call(agent, "set", ["id": "prompt.answer", "value": "wrong"])
        _ = await call(agent, "press", ["title": "OK"])
        reply = await call(agent, "wait", ["until": "sheet", "text": "wasn't accepted", "timeout": 30])
        #expect((field(reply.json, "prompt.answer")?["label"] as? String)?.hasPrefix("That answer wasn't accepted. Try again.") == true,
                "\(reply.json) \(reply.error ?? "")")
        _ = await call(agent, "set", ["id": "prompt.answer", "value": Lab.verificationCode()])
        _ = await call(agent, "press", ["title": "OK"])
        #expect(await call(agent, "wait", ["until": "connected", "timeout": 30]).error == nil)
        await main.selectedWorkspace?.connection.disconnect()
    }

    // MARK: Agent control and menus

    /// Escape closes an alert with one button (OK) while AirSCP isn't the active app, as it does for a person; Escape on
    /// a question with Cancel still cancels.
    @MainActor @Test func escapeClosesAnAlertWithOneButton() async throws {
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
        showError(AirSCPError(.other, "A group called “Lab” already exists: choose another name."), on: window)
        #expect(await call(agent, "wait", ["until": "sheet", "timeout": 5]).error == nil)
        #expect(await call(agent, "key", ["combo": "escape"]).error == nil)
        #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 5]).error == nil)
        final class Done { var value = false }
        let done = Done()
        confirm("Delete “web”?", info: "", button: "Delete", destructive: true, on: window) { done.value = true }
        #expect(await call(agent, "wait", ["until": "sheet", "timeout": 5]).error == nil)
        _ = await call(agent, "key", ["combo": "escape"])
        #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 5]).error == nil)
        #expect(!done.value)
    }

    /// Escape closes the welcome sheet too (only Start, its Return, did), as it does the other sheets.
    @MainActor @Test func escapeClosesTheWelcomeSheet() async throws {
        _ = NSApplication.shared
        let model = testModel([])
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let (main, agent, _) = try agentWindow(model, askpass)
        defer {
            agent.close()
            main.window?.orderOut(nil)
        }
        let window = try #require(main.window)
        presentSheet(on: window) { close in WelcomeView { _ in close() } }
        #expect(await call(agent, "wait", ["until": "sheet", "text": "Welcome to AirSCP", "timeout": 5]).error == nil)
        #expect(await call(agent, "key", ["combo": "escape"]).error == nil)
        #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 5]).error == nil)
    }

    /// press and set scroll a control into view first, as a person scrolls to it: Settings' Debug logging, at the end of
    /// a form taller than its window, then shows in a screenshot (an agent couldn't get it on screen).
    @MainActor @Test func agentsScrollAControlIntoViewBeforeUsingIt() async throws {
        _ = NSApplication.shared
        let model = testModel([])
        let settings = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(model: model)))
        settings.title = "Settings"
        settings.isReleasedWhenClosed = false
        settings.setContentSize(NSSize(width: 540, height: 400))
        settings.setFrameOrigin(NSPoint(x: -21000, y: -21000))
        let agent = try AgentServer(main: nil, model: model, directory: URL(fileURLWithPath: try scratch() + "/agent"),
                                    windows: { [settings].filter(\.isVisible) })
        settings.orderFront(nil)
        defer {
            agent.close()
            settings.orderOut(nil)
        }
        @MainActor func bottom() async -> Double? {
            let elements = await call(agent, "snapshot", ["include": ["elements"], "in": "window:Settings"])["elements"]
                as? [[String: Any]] ?? []
            let frame = elements.first { $0["id"] as? String == "settings.debugLogging" }?["frame"] as? [Double]
            return frame.map { $0[1] + $0[3] }
        }
        let height = Double(settings.frame.height)  // the frames are from the window's top, its title bar included
        #expect(await eventually { await bottom().map { $0 > height } == true }, "below the window at first")
        #expect(await call(agent, "set", ["id": "settings.debugLogging", "value": false, "in": "window:Settings"]).error == nil)
        #expect(await eventually { await bottom().map { $0 <= height - 10 } == true })
        #expect(!model.data.settings.debugLogging)
    }

    /// The Window menu has the main window once: AirSCP (⌘0) and the connected hosts, not also AppKit's own entry.
    @MainActor @Test func theWindowMenuHasTheMainWindowOnce() throws {
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
        window.orderFront(nil)
        #expect(window.isExcludedFromWindowsMenu)
        #expect(!(NSApp.windowsMenu?.items ?? []).contains { $0.target === window })
    }
}
