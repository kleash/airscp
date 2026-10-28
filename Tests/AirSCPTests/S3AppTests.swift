import AppKit
import Foundation
import Testing
@testable import AirSCP
@testable import AirSCPCore

// S3 storage in the app: the editor (secrets in the Keychain only), the workspace (the Files tab alone; server-only
// commands off, saying why), and agents browsing, uploading and deleting through their usual tools.

extension FeatureRoundAppTests {
    @Test func anAgentBrowsesUploadsAndDeletesOnS3Storage() async throws {
        _ = NSApplication.shared
        let storage = try TestS3()
        defer { storage.stop() }
        storage.put("bucket", "docs/readme.txt", Data("read me".utf8))
        let host = storage.host()
        let local = try scratch()
        try write("upload me", to: local + "/new.txt")
        let model = testModel([host])
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let (main, agent, _) = try agentWindow(model, askpass)
        defer {
            agent.close()
            main.window?.orderOut(nil)
        }
        _ = await call(agent, "select", ["pane": "sidebar", "names": ["Test storage"]])
        #expect(await call(agent, "menu", ["path": "Host > Connect"]).error == nil)
        #expect(await call(agent, "wait", ["until": "connected", "timeout": 20])["state"] as? String == "connected")
        #expect(await call(agent, "wait", ["until": "listed", "pane": "right", "text": "bucket", "timeout": 20]).error == nil)
        // The Files tab alone; a server's commands are off and say why.
        #expect(main.selectedWorkspace?.tabs.tabViewItems.map(\.label) == ["Files"])
        let terminal = await call(agent, "menu", ["path": "Host > Open Terminal"])
        #expect(terminal.error?.contains("S3 storage") == true, "\(terminal.error ?? "")")
        var reply = await call(agent, "open", ["name": "bucket"])
        #expect((reply["pane"] as? [String: Any])?["dir"] as? String == "/bucket", "\(reply.error ?? "")")
        reply = await call(agent, "open", ["name": "docs"])
        let rows = ((reply["pane"] as? [String: Any])?["rows"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        #expect(rows == ["readme.txt"])
        // Upload from Finder (a drop), then delete it again: Delete asks first.
        reply = await call(agent, "drop", ["files": [local + "/new.txt"], "pane": "right"])
        #expect(reply.error == nil, "\(reply.error ?? "")")
        #expect(await call(agent, "wait", ["until": "transfers_done", "timeout": 30]).error == nil)
        #expect(await call(agent, "wait", ["until": "listed", "pane": "right", "text": "new.txt", "timeout": 20]).error == nil)
        #expect(storage.object("bucket", "docs/new.txt")?.data == Data("upload me".utf8))
        _ = await call(agent, "select", ["pane": "right", "names": ["new.txt"]])
        reply = await call(agent, "menu", ["path": "File > Get Info"])
        _ = await call(agent, "wait", ["until": "sheet", "timeout": 10])
        try await Task.sleep(nanoseconds: 300_000_000)
        let info = AXNode.flatten(try #require(main.window?.attachedSheet)).map { $0.title + " " + (($0.value as? String) ?? "") }.joined(separator: "|")
        #expect(info.contains("Storage class") && info.contains("ETag") && !info.contains("Permissions"), "\(info)")
        _ = await call(agent, "press", ["title": "Done"])
        _ = await call(agent, "wait", ["until": "no_sheet", "timeout": 10])
        reply = await call(agent, "menu", ["path": "context > Delete…", "pane": "right"])
        #expect((sheet(reply)?["title"] as? String)?.hasPrefix("Delete “new.txt”") == true, "\(reply.json)")
        #expect(await call(agent, "press", ["title": "Delete"]).error == nil)
        #expect(await eventually { storage.object("bucket", "docs/new.txt") == nil })
        // A folder is its files: renaming or deleting one says how many first.
        _ = await call(agent, "open", ["name": ".."])
        _ = await call(agent, "select", ["pane": "right", "names": ["docs"]])
        _ = await call(agent, "menu", ["path": "File > Rename…"])
        _ = await call(agent, "set", ["id": "prompt.name", "value": "papers"])
        _ = await call(agent, "press", ["title": "Rename"])
        reply = await call(agent, "wait", ["until": "sheet", "text": "Rename “docs” (1 file)", "timeout": 10])
        #expect(reply.error == nil, "\(reply.json) \(reply.error ?? "")")
        _ = await call(agent, "press", ["title": "Rename"])
        #expect(await eventually { storage.keys("bucket") == ["papers/readme.txt"] }, "\(storage.keys("bucket"))")
        _ = await call(agent, "wait", ["until": "listed", "pane": "right", "text": "papers", "timeout": 20])
        _ = await call(agent, "select", ["pane": "right", "names": ["papers"]])
        _ = await call(agent, "menu", ["path": "File > Delete…"])
        reply = await call(agent, "wait", ["until": "sheet", "text": "(1 file)", "timeout": 10])
        #expect(reply.error == nil, "\(reply.json) \(reply.error ?? "")")
        _ = await call(agent, "press", ["title": "Delete"])
        #expect(await eventually { storage.keys("bucket").isEmpty })
        #expect(storage.badSignatures.all.isEmpty)
        _ = await call(agent, "menu", ["path": "Host > Disconnect"])
        #expect(await call(agent, "wait", ["until": "disconnected", "timeout": 20]).error == nil)
    }

    @Test func theS3EditorKeepsTheSecretInTheKeychainAndTestsTheKeys() async throws {
        _ = NSApplication.shared
        let storage = try TestS3()
        defer { storage.stop() }
        let saved = Recorder<AirSCPData>()
        let passwords = Passwords()
        let model = testModel([], saved: saved, passwords: passwords)
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let (main, agent, _) = try agentWindow(model, askpass)
        defer {
            agent.close()
            main.window?.orderOut(nil)
        }
        main.newS3Connection()
        #expect(await call(agent, "wait", ["until": "sheet", "timeout": 10]).error == nil)
        for (id, value) in [("s3Editor.name", "Photos"), ("s3Editor.endpoint", storage.endpoint), ("s3Editor.accessKey", TestS3.accessKey),
                            ("s3Editor.secret", TestS3.secret)] {
            #expect(await call(agent, "set", ["id": id, "value": value]).error == nil, "\(id)")
        }
        #expect(await call(agent, "press", ["id": "s3Editor.test"]).error == nil)
        #expect(await eventually(timeout: 20) {
            AXNode.flatten(main.window?.attachedSheet ?? NSWindow()).contains { ($0.title + " " + (($0.value as? String) ?? "")).contains("Connected: 1 bucket") }
        })
        #expect(await call(agent, "press", ["id": "s3Editor.save"]).error == nil)
        #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 10]).error == nil)
        let host = try #require(model.data.hosts.first)
        #expect(host.label == "Photos" && host.s3?.endpoint == storage.endpoint && host.s3?.accessKeyID == TestS3.accessKey)
        #expect(passwords.saved[host.id.uuidString] == TestS3.secret)
        // airscp.json has the connection, never the secret.
        let file = String(decoding: try JSONEncoder().encode(try #require(saved.all.last)), as: UTF8.self)
        #expect(file.contains(TestS3.accessKey) && !file.contains(TestS3.secret))
        // Its sidebar section, and a duplicate takes the secret along.
        #expect(AppModel.sections(model.data, search: "").map(\.title) == ["S3 Storage"])
        let copy = try #require(model.duplicate(host.id))
        #expect(passwords.saved[copy.id.uuidString] == TestS3.secret)
        model.delete(copy.id)
        #expect(passwords.saved[copy.id.uuidString] == nil)
    }

    /// Synchronize takes an S3 folder as it takes a server's, comparing by size and date (contents need a shell); a
    /// file uploaded then counts as newer on the storage, so uploading again finds nothing to do.
    @Test func synchronizeComparesAMacFolderWithAnS3FolderBySizeAndDate() async throws {
        let storage = try TestS3()
        defer { storage.stop() }
        storage.put("bucket", "dir/b.txt", Data("b".utf8), modified: Date().addingTimeInterval(-3600))
        storage.put("bucket", "dir/only-there.txt", Data("c".utf8))
        let session = try await s3Session(storage)
        let local = try scratch()
        try write("a", to: local + "/a.txt")
        try write("bb", to: local + "/b.txt")
        let comparison = try await Sync.compare(local: local, remote: "/bucket/dir", on: session) { _ in }
        #expect(comparison.differences.map(\.path) == ["a.txt", "b.txt", "only-there.txt"], "\(comparison.differences.map(\.path))")
        let browser = BrowserContentController(workspace: nil, session: session)
        browser.apply(Sync.plan(comparison.differences, direction: .upload, delete: false), on: session)
        await session.transfers.waitUntilIdle()
        #expect(storage.object("bucket", "dir/a.txt")?.data == Data("a".utf8) && storage.object("bucket", "dir/b.txt")?.data == Data("bb".utf8))
        let again = try await Sync.compare(local: local, remote: "/bucket/dir", on: session) { _ in }
        #expect(Sync.plan(again.differences, direction: .upload, delete: false).steps.isEmpty)
        #expect(SyncModel(session: session, localDir: local, remoteDir: "/bucket/dir", leaveOut: "").contentsUnavailable != nil)
    }

    /// The S3 workspace's controls and sheets say what they do (the help walk's rule, for what S3 storage adds).
    @Test func s3ControlsAndSheetsSayWhatTheyDo() async throws {
        _ = NSApplication.shared
        let storage = try TestS3()
        defer { storage.stop() }
        storage.put("bucket", "a.txt", Data("a".utf8))
        storage.put("bucket", "b.zip", Data("zip".utf8))
        var host = storage.host()
        let local = try scratch()
        try write("x", to: local + "/folder/inside.txt")
        host.lastLocalDir = local
        let model = testModel([host])
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let (main, agent, _) = try agentWindow(model, askpass)
        defer {
            agent.close()
            main.window?.orderOut(nil)
        }
        let window = try #require(main.window)
        var missing: [String] = [], checked = 0
        func check(_ what: String, sheetsOnly: Bool = false) {
            missing += unexplained(window, sheetsOnly: sheetsOnly, checked: &checked).map { what + " — " + $0 }
        }
        func sheet(_ what: String, close: String = "Cancel", _ open: () async -> Void) async {
            await open()
            #expect(await call(agent, "wait", ["until": "sheet", "timeout": 10]).error == nil, "\(what)")
            try? await Task.sleep(nanoseconds: 300_000_000)
            check(what, sheetsOnly: true)
            _ = await call(agent, "press", ["title": close])
            #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 10]).error == nil, "\(what)")
        }
        _ = await call(agent, "select", ["pane": "sidebar", "names": ["Test storage"]])
        _ = await call(agent, "menu", ["path": "Host > Connect"])
        #expect(await call(agent, "wait", ["until": "connected", "timeout": 20]).error == nil)
        _ = await call(agent, "open", ["name": "bucket"])
        check("S3 workspace")
        await sheet("S3 editor") {
            _ = await call(agent, "menu", ["path": "Host > Edit…"])
            _ = await call(agent, "press", ["id": "s3Editor.advanced"])
        }
        _ = await call(agent, "select", ["pane": "right", "names": ["a.txt"]])
        for (command, close) in [("File > Get Info", "Done"), ("File > Compress…", "Cancel"), ("File > Download as .zip…", "Cancel"),
                                 ("context > Copy Presigned Link…", "Cancel"), ("File > Delete…", "Cancel")] {
            await sheet(command, close: close) { _ = await call(agent, "menu", ["path": command, "pane": "right"]) }
            _ = await call(agent, "select", ["pane": "right", "names": ["a.txt"]])
        }
        await sheet("folder upload") { _ = await call(agent, "drop", ["files": [local + "/folder"], "pane": "right"]) }
        // S3 storage's context menus: entries with tooltips, none of a server's shell commands.
        let pane = try #require(main.selectedWorkspace?.browser.right)
        let entries = (pane.contextMenu(for: []) + pane.contextMenu(for: Array(pane.rows.prefix(1)))).compactMap { $0 }
        #expect(entries.allSatisfy { MenuHelp.tips[$0.1] != nil }, "\(entries.map(\.0))")
        let titles = entries.map(\.0)
        #expect(titles.contains("Copy S3 Link") && titles.contains("Copy Presigned Link…") && titles.contains("Download as .zip…"))
        #expect(!titles.contains("Open Terminal Here") && !titles.contains("Permissions…") && !titles.contains("New Symbolic Link…"))
        #expect(missing.isEmpty, "\(missing)")
        print("help: \(checked) S3 controls, all with help")
    }
}
