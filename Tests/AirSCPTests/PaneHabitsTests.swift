import AppKit
import Darwin
import Foundation
import Testing
@testable import AirSCP
@testable import AirSCPCore

// MARK: The file panes' everyday commands

@MainActor
private func filesTab(_ session: Session) async -> BrowserContentController {
    let browser = BrowserContentController(workspace: nil, session: session)
    _ = browser.view
    browser.stateChanged(session.state)
    _ = await eventually { browser.left.dir != nil && browser.right.dir != nil }
    return browser
}

private func touch(_ path: String, _ time: TimeInterval) {
    var times = [timeval(tv_sec: Int(time), tv_usec: 0), timeval(tv_sec: Int(time), tv_usec: 0)]
    utimes(path, &times)
}

@MainActor @Test func panesSelectByPatternSameKindAndInvert() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        let dir = server.path("pick")
        for name in ["a.log", "B.LOG", "c.txt", "d.txt", "notes"] { try write("x", to: dir + "/" + name) }
        try FileManager.default.createDirectory(atPath: dir + "/logs", withIntermediateDirectories: true)
        let session = try await server.connectedSession()
        let browser = await filesTab(session)
        let pane = try #require(browser.right)
        #expect(await pane.open(dir))
        @MainActor func selected() -> [String] { pane.selectedItems.map(\.name).sorted() }
        // Patterns as Leave out takes them, in any case.
        let matching = FilePane.rows(matching: "*.log, c*", in: pane.rows)
        #expect(matching.map { pane.rows[$0].name }.sorted() == ["B.LOG", "a.log", "c.txt"])
        #expect(FilePane.rows(matching: "nothing-*", in: pane.rows).isEmpty)
        // Same kind: the selected item's extension (folders stay out).
        pane.table.selectRowIndexes(IndexSet(integer: try #require(pane.rows.firstIndex { $0.name == "c.txt" })), byExtendingSelection: false)
        pane.selectSameKind(nil)
        #expect(selected() == ["c.txt", "d.txt"])
        pane.invertSelection(nil)
        #expect(selected() == ["B.LOG", "a.log", "logs", "notes"])
        // Copy Names: one per line.
        await TestClipboard.take()
        defer { TestClipboard.give() }
        pane.copyNames(nil)
        #expect((NSPasteboard.general.string(forType: .string) ?? "").components(separatedBy: "\n").sorted()
                == ["B.LOG", "a.log", "logs", "notes"])
        // The other pane's folder: only between panes of the same computer.
        #expect(pane.habitCheck(#selector(FilePane.goToOtherPanesFolder(_:)), for: [])?.0 == false)
        browser.chooseSource(.remote(session), for: browser.left)
        #expect(await eventually { browser.left.dir != nil })
        #expect(await browser.left.open(server.home))
        #expect(pane.habitCheck(#selector(FilePane.goToOtherPanesFolder(_:)), for: [])?.0 == true)
        browser.left.goToOtherPanesFolder(nil)
        #expect(await eventually { browser.left.dir == dir })
    }
}

@MainActor @Test func compareFoldersMarksWhatDiffersUntilTheNextListing() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        var host = server.host()
        let local = try server.scratch(), there = server.path("site")
        host.lastLocalDir = local
        let earlier = Date().timeIntervalSince1970 - 3_600
        try write("same", to: local + "/same.txt"); touch(local + "/same.txt", earlier)
        try write("same", to: there + "/same.txt"); touch(there + "/same.txt", earlier)
        try write("mine", to: local + "/mine.txt")
        try write("theirs", to: there + "/theirs.txt")
        try write("newer here", to: local + "/edited.txt")
        try write("older", to: there + "/edited.txt"); touch(there + "/edited.txt", earlier)
        try write("in a folder", to: local + "/sub/x.txt")
        try write("other", to: there + "/sub/y.txt")  // inside a folder on both sides: one level only, not marked
        let session = try await server.connectedSession(host)
        let browser = await filesTab(session)
        #expect(await browser.right.open(there))
        browser.right.compareFolders(nil)
        #expect(await eventually { !browser.left.marks.isEmpty })
        #expect(browser.left.marks == ["mine.txt": "Only here: not on Test server", "edited.txt": "Newer here"])
        #expect(browser.right.marks == ["theirs.txt": "Only here: not on this Mac", "edited.txt": "Older here: newer on this Mac"])
        // Gone once the pane lists again.
        await browser.right.reload()
        #expect(browser.right.marks.isEmpty)
        // Without a folder on this Mac in the other pane, it says what it needs.
        browser.chooseSource(.remote(session), for: browser.left)
        #expect(await eventually { browser.synchronizedPanes == nil })
        #expect(browser.right.habitCheck(#selector(FilePane.compareFolders(_:)), for: [])?.0 == false)
    }
}

@Test func symbolicLinksAreMadeWithAndWithoutAShell() async throws {
    for sftpOnly in [false, true] {
        try await withServer(TestServer.Options(sftpOnly: sftpOnly)) { server in
            try write("target", to: server.path("real.txt"))
            let session = try await server.connectedSession()
            #expect(session.capabilities.shell == !sftpOnly)
            let dir = server.home  // ForceCommand's -d only sets sftp's first folder: absolute paths work there too
            try await session.makeLink(RemotePath.join(dir, "link"), to: "real.txt")
            #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: server.path("link"))) == "real.txt")
            // Nothing is replaced.
            await #expect(throws: AirSCPError.self) { try await session.makeLink(RemotePath.join(dir, "real.txt"), to: "x") }
            #expect((try? String(contentsOfFile: server.path("real.txt"), encoding: .utf8)) == "target")
        }
    }
}

// MARK: Transfers and Get Info

@Test func replaceIfNewerComparesAtTheListingsPrecision() {
    func local(_ time: TimeInterval) -> FileItem {
        FileItem(local: "f", path: "/mac/f", kind: .file, size: 1, modified: Date(timeIntervalSince1970: time), mode: 0o644,
                 owner: "", group: "")
    }
    func remote(_ time: TimeInterval, dateOnly: Bool = false, kind: RemoteEntry.Kind = .file) -> FileItem {
        var entry = RemoteEntry(name: "f", path: "/srv/f", kind: kind, size: 1, modified: Date(timeIntervalSince1970: time),
                                permissions: "rw-r--r--", mode: 0o644, owner: "", group: "")
        entry.dateOnly = dateOnly
        return FileItem(entry)
    }
    #expect(FileList.isNewer(local(1_000_120), than: remote(1_000_020)) == true)    // upload, newer here
    #expect(FileList.isNewer(local(1_000_030), than: remote(1_000_020)) == false)   // the same minute as the listing
    #expect(FileList.isNewer(remote(1_000_200), than: local(1_000_030)) == true)    // download, newer there
    #expect(FileList.isNewer(remote(1_000_200), than: local(1_000_250)) == false)
    #expect(FileList.isNewer(remote(1_000_200, kind: .directory), than: local(1)) == nil)  // folders: can't tell
    #expect(FileList.isNewer(remote(86_400 * 3), than: remote(86_400 * 3 + 600, dateOnly: true)) == false)  // the same day
}

extension FeatureRoundAppTests {
    /// Replace If Newer, for every conflict: a newer file replaces the older one, an older one is skipped.
    @MainActor @Test func replaceIfNewerReplacesOnlyNewerFiles() async throws {
        _ = NSApplication.shared
        try await withServer { @MainActor server in
            var host = server.host()
            host.label = "lab"
            let local = try server.scratch()
            host.lastLocalDir = local
            let hourAgo = Date().timeIntervalSince1970 - 3_600
            try write("server, old", to: server.path("mine-newer.txt"))
            var times = [timeval(tv_sec: Int(hourAgo), tv_usec: 0), timeval(tv_sec: Int(hourAgo), tv_usec: 0)]
            utimes(server.path("mine-newer.txt"), &times)
            try write("server, new", to: server.path("theirs-newer.txt"))
            try write("mac, new", to: local + "/mine-newer.txt")
            try write("mac, old", to: local + "/theirs-newer.txt")
            utimes(local + "/theirs-newer.txt", &times)
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
            #expect(await call(agent, "wait", ["until": "listed", "pane": "right", "text": "mine-newer.txt", "timeout": 30]).error == nil)
            let reply = await call(agent, "drop", ["files": [local + "/mine-newer.txt", local + "/theirs-newer.txt"], "pane": "right"])
            let buttons = titles(sheet(reply)?["buttons"])
            #expect(buttons.contains("Replace If Newer"), "\(reply.json)")
            #expect(await call(agent, "press", ["title": "Do the same for the other conflict"]).error == nil)
            #expect(await call(agent, "press", ["title": "Replace If Newer"]).error == nil)
            #expect(await eventually { read(server.path("mine-newer.txt")) == "mac, new" })
            await main.selectedWorkspace?.session.transfers.waitUntilIdle()
            #expect(read(server.path("theirs-newer.txt")) == "server, new")
            await main.selectedWorkspace?.connection.disconnect()
        }
    }
}

extension FeatureRoundAppTests {
    /// Download and Delete: the server's file goes once its copy is here, and stays when the copy fails.
    @MainActor @Test func downloadAndDeleteRemovesTheOriginalOnlyAfterACopy() async throws {
        _ = NSApplication.shared
        try await withServer { @MainActor server in
            var host = server.host()
            host.label = "lab"
            let local = try server.scratch()
            host.lastLocalDir = local
            try write("moving", to: server.path("move-me.txt"))
            try write("staying", to: server.path("stay.txt"))
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
            #expect(await call(agent, "wait", ["until": "listed", "pane": "right", "text": "move-me.txt", "timeout": 30]).error == nil)
            _ = await call(agent, "select", ["pane": "right", "names": ["move-me.txt"]])
            var reply = await call(agent, "menu", ["path": "File > Download and Delete…"])
            #expect((sheet(reply)?["title"] as? String)?.hasPrefix("Move “move-me.txt”") == true, "\(reply.json) \(reply.error ?? "")")
            #expect(await call(agent, "press", ["title": "Move"]).error == nil)
            #expect(await eventually { read(local + "/move-me.txt") == "moving" && !rawExists(server.path("move-me.txt")) })

            // A copy that fails (this Mac's folder can't be written): the original stays.
            let right = try #require(main.selectedWorkspace?.browser.right)
            #expect(await eventually { !right.rows.contains { $0.name == "move-me.txt" } && right.rows.contains { $0.name == "stay.txt" } })
            chmod(local, 0o555)
            defer { chmod(local, 0o755) }
            _ = await call(agent, "select", ["pane": "right", "names": ["stay.txt"]])
            reply = await call(agent, "menu", ["path": "File > Download and Delete…"])
            let pressed = await call(agent, "press", ["title": "Move"])
            #expect(pressed.error == nil, "\(reply.json) \(reply.error ?? "") \(pressed.error ?? "")")
            await main.selectedWorkspace?.session.transfers.waitUntilIdle()
            #expect(main.selectedWorkspace?.session.transfers.jobs.last?.status.isFinished == true)
            for _ in 0..<3 { await MainActor.run {} }  // a deletion would be queued on the main queue as the job ends
            #expect(rawExists(server.path("stay.txt")))
            await main.selectedWorkspace?.connection.disconnect()
        }
    }
}

/// Move Up / Move Down: a queued job changes places with its queued neighbour and runs in its new turn; a running job
/// keeps its place.
@Test func queuedTransfersMoveUpAndDown() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let local = try server.scratch()
        try writeRandom(bytes: 200_000_000, to: local + "/big.bin")  // keeps the queue busy while the others wait
        for name in ["a", "b", "c"] { try write(name, to: local + "/\(name).txt") }
        let queue = session.transfers
        let big = queue.upload(local + "/big.bin", to: server.path("big.bin"), isFolder: false)
        let ids = ["a", "b", "c"].map { queue.upload(local + "/\($0).txt", to: server.path("\($0).txt"), isFolder: false) }
        #expect(await eventually { queue.jobs.first { $0.id == big }?.status == .running })
        #expect(queue.move(ids[2], up: true))   // a, c, b
        #expect(queue.move(ids[0], up: false))  // c, a, b
        #expect(!queue.move(ids[2], up: true))  // first among the queued: nowhere to go
        #expect(!queue.move(big, up: false))  // the running one stays
        #expect(queue.jobs.map(\.id).filter { ids.contains($0) } == [ids[2], ids[0], ids[1]])
        await queue.waitUntilIdle()
        let started = Dictionary(uniqueKeysWithValues: queue.jobs.map { ($0.id, $0.started ?? .distantFuture) })
        #expect(started[ids[2]]! < started[ids[0]]! && started[ids[0]]! < started[ids[1]]!)
        #expect(queue.jobs.allSatisfy { $0.status == .done })
    }
}

/// When Done fires once, when the last transfer finishes (not while some are paused), then goes back to Do Nothing.
@MainActor @Test func whenDoneFiresOnceWhenTheTransfersFinish() {
    let model = WhenDoneModel()
    var done: [WhenDone] = []
    model.perform = { choice, _ in done.append(choice) }
    model.activeChanged(0, unfinished: false)
    #expect(done.isEmpty)  // nothing ran yet
    model.choice = .sleep
    model.activeChanged(2, unfinished: true)
    model.activeChanged(0, unfinished: true)  // paused, not finished
    #expect(done.isEmpty && model.choice == .sleep)
    model.activeChanged(1, unfinished: true)
    model.activeChanged(0, unfinished: false)
    #expect(done == [.sleep] && model.choice == .nothing)
    model.activeChanged(1, unfinished: true)
    model.activeChanged(0, unfinished: false)
    #expect(done == [.sleep])  // once
    #expect(WhenDone.allCases.map(\.rawValue) == ["Do Nothing", "Disconnect", "Sleep This Mac", "Notify"])
}

/// Owner and group (Permissions…): chown with a shell, sftp's chgrp (numbers only) without; root's files are root's.
@Test func ownerAndGroupChangeWithAndWithoutAShell() async throws {
    for sftpOnly in [false, true] {
        try await withServer(TestServer.Options(sftpOnly: sftpOnly)) { server in
            try write("x", to: server.path("mine.txt"))
            let session = try await server.connectedSession()
            let entry = try #require(try await session.list(server.home).first { $0.name == "mine.txt" })
            func gid() -> gid_t {
                var info = stat()
                stat(server.path("mine.txt"), &info)
                return info.st_gid
            }
            // A group this user is in (everyone, 12), by name with a shell, by number without.
            try await session.setOwner([entry], owner: "", group: sftpOnly ? "12" : "everyone")
            #expect(gid() == 12)
            if sftpOnly {
                await #expect(throws: AirSCPError.self) { try await session.setOwner([entry], owner: "", group: "staff") }
            }
            // Only root gives files away: refused, in words.
            await #expect(throws: AirSCPError.self) { try await session.setOwner([entry], owner: sftpOnly ? "0" : "root", group: "") }
            try await session.setOwner([], owner: "root", group: "")  // nothing to do
            if !sftpOnly {
                // An owner typed with a leading "-" is a user chown doesn't know, never one of its options.
                let refused = await #expect(throws: AirSCPError.self) { try await session.setOwner([entry], owner: "-h", group: "") }
                let words = refused?.details ?? ""
                #expect(words.contains("-h") && words.contains("user") && !words.lowercased().contains("usage"), "\(words)")
            }
        }
    }
}

/// Get Info's Checksum: on the server with its tools, or from a temporary copy where there is no shell.
@MainActor @Test func checksumsComeFromTheServerOrATemporaryCopy() async throws {
    let expected: [Session.ChecksumAlgorithm: String] = [
        .sha256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824",
        .sha1: "aaf4c61ddcc5e8a2dabede0f3b482cd9aea9434d", .md5: "5d41402abc4b2a76b9719d911017c592",
    ]
    for sftpOnly in [false, true] {
        try await withServer(TestServer.Options(sftpOnly: sftpOnly)) { @MainActor server in
            try write("hello", to: server.path("hello.txt"))
            let session = try await server.connectedSession()
            for (algorithm, hash) in expected {
                #expect(try await session.checksum(server.path("hello.txt"), algorithm) == hash, "\(algorithm) sftpOnly \(sftpOnly)")
            }
            await #expect(throws: AirSCPError.self) { try await session.checksum(server.path("missing.txt"), .sha256) }
            // Get Info's comparison with a pasted checksum: case and spaces don't matter.
            let entry = try #require(try await session.list(server.home).first { $0.name == "hello.txt" })
            let info = InfoModel(session: session, entry: entry)
            info.computeChecksum()
            #expect(await eventually { info.checksum != nil })
            #expect(info.matches == nil)
            info.expected = " 2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824 "
            #expect(info.matches == true)
            info.expected = "abc"
            #expect(info.matches == false)
        }
    }
}

// MARK: Snippets on files

/// Placeholders are shell-quoted, whatever the names hold; {file} and {name} run once per item, {files} once.
@Test func snippetPlaceholdersAreQuotedAndRepeatedPerItem() {
    let paths = ["/srv/a b.txt", "/srv/it's", "/srv/line\nbreak", "/srv/-n"]
    let each = Snippet(name: "wc", command: "wc -c {file} # {name}")
    #expect(each.usesPlaceholders && each.needsFiles)
    #expect(each.expanded(paths: Array(paths.prefix(2)), folder: "/srv")
            == "wc -c '/srv/a b.txt' # 'a b.txt'\nwc -c '/srv/it'\\''s' # 'it'\\''s'")
    let all = Snippet(name: "tar", command: "tar czf {folder}/out.tgz {files}")
    #expect(all.expanded(paths: paths, folder: "/srv/my dir")
            == "tar czf '/srv/my dir'/out.tgz '/srv/a b.txt' '/srv/it'\\''s' '/srv/line\nbreak' '/srv/-n'")
    let folderOnly = Snippet(name: "ls", command: "ls -la {folder}")
    #expect(folderOnly.usesPlaceholders && !folderOnly.needsFiles)
    #expect(!Snippet(name: "uptime", command: "uptime").usesPlaceholders)
    // A server's name that holds a placeholder's text stays inside its quotes: what is put in isn't read again.
    #expect(each.expanded(paths: ["/srv/a{name};id"], folder: "/srv") == "wc -c '/srv/a{name};id' # 'a{name};id'")
    #expect(Snippet(name: "ls", command: "ls {folder} {file}").expanded(paths: ["/srv/{name}/x;id"], folder: "/srv/{name}")
            == "ls '/srv/{name}' '/srv/{name}/x;id'")
}

extension FeatureRoundAppTests {
    /// Right-click ▸ Run Snippet runs a snippet with the selected items in it, then lists the folder again.
    @MainActor @Test func snippetsRunOnTheSelectedItems() async throws {
        _ = NSApplication.shared
        try await withServer { @MainActor server in
            var host = server.host()
            host.label = "lab"
            for name in ["one.txt", "two words.txt", "skip.txt"] { try write(name, to: server.path("files/" + name)) }
            let model = testModel([host])
            model.data.snippets = [Snippet(name: "Copy aside", command: "cp {file} {file}.bak"),
                                   Snippet(name: "Uptime", command: "uptime")]
            let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
            defer { askpass.close() }
            let (main, agent, _) = try agentWindow(model, askpass)
            defer {
                agent.close()
                main.window?.orderOut(nil)
            }
            _ = await call(agent, "select", ["pane": "sidebar", "names": ["lab"]])
            _ = await call(agent, "menu", ["path": "Host > Connect"])
            #expect(await call(agent, "wait", ["until": "connected", "timeout": 30]).error == nil)
            _ = await call(agent, "go", ["path": server.path("files")])
            _ = await call(agent, "select", ["pane": "right", "names": ["one.txt", "two words.txt"]])
            // Only snippets with placeholders are offered.
            let pane = try #require(main.selectedWorkspace?.browser.right)
            #expect(pane.runSnippetMenu()?.submenu?.items.map(\.title) == ["Copy aside"])
            let reply = await call(agent, "menu", ["path": "context > Run Snippet > Copy aside", "pane": "right"])
            #expect(reply.error == nil, "\(reply.error ?? "")")
            #expect(await eventually { read(server.path("files/one.txt.bak")) == "one.txt" && read(server.path("files/two words.txt.bak")) == "two words.txt" })
            #expect(!rawExists(server.path("files/skip.txt.bak")))
            #expect(await eventually { pane.rows.contains { $0.name == "one.txt.bak" } })  // listed again
            // The names are the server's: the script is piped to `sh -s` on standard input, so the login shell's own
            // command line is only `exec sh -s`. A login shell that reads POSIX quoting differently (fish, csh, tcsh)
            // never sees the names, so it can't run commands a name contains. (Without this, the names would be the
            // ssh command's remote argument instead.)
            let commands = main.selectedWorkspace?.connection.log.entries.map(\.command) ?? []
            let snippetRun = try #require(commands.first { $0.contains(".bak") })
            #expect(snippetRun.hasSuffix(" 'exec sh -s'"), "\(snippetRun)")
            await main.selectedWorkspace?.connection.disconnect()
        }
    }

    /// Move To… and Copy To… take a folder as Go to Folder does: ~ is the server's home folder (not a folder called
    /// "~"), and a relative path starts in the folder shown.
    @MainActor @Test func moveToAndCopyToTakeTheHomeFolderAndRelativePaths() async throws {
        _ = NSApplication.shared
        try await withServer { @MainActor server in
            var host = server.host()
            host.label = "lab"
            try write("one", to: server.path("from/one.txt"))
            try write("two", to: server.path("from/two.txt"))
            try FileManager.default.createDirectory(atPath: server.path("to"), withIntermediateDirectories: true)
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
            #expect(await call(agent, "wait", ["until": "connected", "timeout": 30]).error == nil)
            _ = await call(agent, "go", ["path": server.path("from")])
            _ = await call(agent, "select", ["pane": "right", "names": ["one.txt"]])
            #expect(await call(agent, "menu", ["path": "context > Move To…", "pane": "right"]).error == nil)
            #expect(await call(agent, "set", ["id": "transfer.folder", "value": "~/to"]).error == nil)
            #expect(await call(agent, "press", ["title": "Move"]).error == nil)
            #expect(await eventually { read(server.path("to/one.txt")) == "one" && !rawExists(server.path("from/one.txt")) })
            _ = await call(agent, "select", ["pane": "right", "names": ["two.txt"]])
            #expect(await call(agent, "menu", ["path": "context > Copy To…", "pane": "right"]).error == nil)
            #expect(await call(agent, "set", ["id": "transfer.folder", "value": "../to"]).error == nil)
            #expect(await call(agent, "press", ["title": "Copy"]).error == nil)
            #expect(await eventually { read(server.path("to/two.txt")) == "two" && read(server.path("from/two.txt")) == "two" })
            await main.selectedWorkspace?.connection.disconnect()
        }
    }
}

/// Upload and Delete / Download and Delete deletes the originals only when the copy is sound: with Verify transfers on,
/// a checksum mismatch or a check that couldn't run keeps them.
@Test func moveDeletesOriginalsOnlyWhenTheCopyIsSound() {
    #expect(BrowserContentController.moveMayDelete(nil))                                  // no check asked for
    #expect(BrowserContentController.moveMayDelete(.verified(String(repeating: "a", count: 64))))
    #expect(!BrowserContentController.moveMayDelete(.mismatch(original: "a", copy: "b")))
    #expect(!BrowserContentController.moveMayDelete(.unchecked("no sha256sum on the server")))
    #expect(!BrowserContentController.moveMayDelete(.checking))
    #expect(!BrowserContentController.moveMayDelete(.wanted))
}

// MARK: Synchronize's options

@MainActor @Test func synchronizeComparesByEachCriterionAndPlansWithTheOptions() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        let local = try server.scratch(), there = server.path("sync")
        let hourAgo = Date().timeIntervalSince1970 - 3_600
        // same size and time, other contents; other size, same time; same contents, other time; newer there; one side only
        try write("aaaa", to: local + "/swapped.txt"); try write("bbbb", to: there + "/swapped.txt")
        try write("short", to: local + "/sized.txt"); try write("longer!", to: there + "/sized.txt")
        try write("same", to: local + "/touched.txt"); try write("same", to: there + "/touched.txt")
        try write("old here", to: local + "/theirs.txt"); try write("new there", to: there + "/theirs.txt")
        try write("only here", to: local + "/mine-only.txt")
        for name in ["swapped.txt", "sized.txt"] { touch(local + "/" + name, hourAgo); touch(there + "/" + name, hourAgo) }
        touch(local + "/touched.txt", hourAgo - 600)
        touch(local + "/theirs.txt", hourAgo - 600)
        let session = try await server.connectedSession()
        func differing(_ criterion: Sync.Criterion) async throws -> [String] {
            try await Sync.compare(local: local, remote: there, on: session, criterion: criterion) { _ in }.differences.map(\.path)
        }
        #expect(try await differing(.sizeAndTime) == ["mine-only.txt", "sized.txt", "theirs.txt", "touched.txt"])
        #expect(try await differing(.size) == ["mine-only.txt", "sized.txt", "theirs.txt"])
        #expect(try await differing(.time) == ["mine-only.txt", "theirs.txt", "touched.txt"])
        var checked = 0
        let byContents = try await Sync.compare(local: local, remote: there, on: session, criterion: .contents,
                                                checked: { checked = $0 }) { _ in }
        #expect(byContents.differences.map(\.path) == ["mine-only.txt", "sized.txt", "swapped.txt", "theirs.txt"])
        #expect(checked == 2)  // swapped.txt and touched.txt: the same size, so hashed

        // The plan's options, one way up.
        let differences = try await Sync.compare(local: local, remote: there, on: session) { _ in }.differences
        func uploads(_ plan: Sync.Plan) -> [String] { plan.steps.filter { $0.action == .upload }.map(\.path) }
        // touched.txt and theirs.txt are newer on the server: one way up leaves them.
        #expect(uploads(Sync.plan(differences, direction: .upload, delete: false)) == ["mine-only.txt", "sized.txt"])
        #expect(uploads(Sync.plan(differences, direction: .upload, delete: false, onlyBoth: true)) == ["sized.txt"])
        // Mirror: the server's newer files are replaced too.
        #expect(uploads(Sync.plan(differences, direction: .upload, delete: false, mirror: true))
                == ["mine-only.txt", "sized.txt", "theirs.txt", "touched.txt"])

        // Reverse one step in the sheet: it is downloaded instead.
        let model = SyncModel(session: session, localDir: local, remoteDir: there)
        model.compare()
        #expect(await eventually { model.comparison != nil })
        let sized = try #require(model.plan.steps.first { $0.path == "sized.txt" })
        #expect(model.reversible(sized) != nil)
        #expect(model.reversible(try #require(model.plan.steps.first { $0.path == "mine-only.txt" })) == nil)  // one side only
        model.reversed.insert("sized.txt")
        let reversed = try #require(model.chosen.steps.first { $0.path == "sized.txt" })
        #expect(reversed.action == .download && reversed.destination == local + "/sized.txt")
        // Another criterion compares again.
        model.criterion = .contents
        #expect(await eventually { model.comparison != nil && model.plan.steps.contains { $0.path == "swapped.txt" } })
        #expect(model.reversed.isEmpty)
    }
}

@Test func hostsSavedBeforeLocalFavouriteFoldersStillLoad() throws {
    let old = #"{"id":"6E1C2D44-1111-4222-8333-944455556666","label":"web","hostname":"w","favourites":["/var/www"]}"#
    let host = try JSONDecoder().decode(SSHHost.self, from: Data(old.utf8))
    #expect(host.favourites == ["/var/www"] && host.favouriteLocalFolders.isEmpty)
    var withLocal = host
    withLocal.favouriteLocalFolders["/var/www"] = "/Users/me/Sites"
    let again = try JSONDecoder().decode(SSHHost.self, from: JSONEncoder().encode(withLocal))
    #expect(again.favouriteLocalFolders == ["/var/www": "/Users/me/Sites"])
}

extension FeatureRoundAppTests {
    /// A favourite added with this Mac's folder in the other pane brings both folders back.
    @MainActor @Test func favouritesRememberThisMacsFolderToo() async throws {
        _ = NSApplication.shared
        try await withServer { @MainActor server in
            var host = server.host()
            host.label = "lab"
            let local = try server.scratch()
            try FileManager.default.createDirectory(atPath: local + "/site", withIntermediateDirectories: true)
            host.lastLocalDir = local + "/site"
            try write("x", to: server.path("www/index.html"))
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
            #expect(await call(agent, "wait", ["until": "connected", "timeout": 30]).error == nil)
            _ = await call(agent, "go", ["path": server.path("www")])
            let browser = try #require(main.selectedWorkspace?.browser)
            #expect(await eventually { browser.left.dir == local + "/site" })
            _ = await call(agent, "focus", ["pane": "right"])
            #expect(await call(agent, "menu", ["path": "Go > Add to Favourites"]).error == nil)
            #expect(model.host(host.id)?.favouriteLocalFolders[server.path("www")] == local + "/site")
            // Elsewhere on both sides, then the favourite.
            #expect(await browser.left.open(local))
            #expect(await browser.right.open(server.home))
            let item = NSMenuItem(title: server.path("www"), action: #selector(FilePane.openFavourite(_:)), keyEquivalent: "")
            item.representedObject = server.path("www")
            browser.right.openFavourite(item)
            #expect(await eventually { browser.right.dir == server.path("www") && browser.left.dir == local + "/site" })
            await main.selectedWorkspace?.connection.disconnect()
        }
    }
}

// MARK: The editor

@Test func goToLineFindsEachLine() {
    let text = "first\nsecond line\r\n\nlast"
    let string = text as NSString
    #expect(RemoteEditor.range(ofLine: 1, in: text).map(string.substring) == "first")
    #expect(RemoteEditor.range(ofLine: 2, in: text).map(string.substring) == "second line")  // without the \r
    #expect(RemoteEditor.range(ofLine: 3, in: text).map(string.substring) == "")
    #expect(RemoteEditor.range(ofLine: 4, in: text).map(string.substring) == "last")
    #expect(RemoteEditor.range(ofLine: 5, in: text) == nil && RemoteEditor.range(ofLine: 0, in: text) == nil)
    #expect(RemoteEditor.range(ofLine: 2, in: "é😀\nx") == NSRange(location: 4, length: 1))  // UTF-16, as NSTextView counts
}

@MainActor @Test func theEditorRevertsToTheServersVersion() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        try write("one\n", to: server.path("conf.txt"))
        let session = try await server.connectedSession()
        let editor = RemoteEditor(session: session, path: server.path("conf.txt"), text: "one\n")
        defer { editor.close() }
        let text = try #require(editor.window?.contentView.map { views(NSTextView.self, in: $0) }?.first)
        #expect(text.usesFindBar && text.isIncrementalSearchingEnabled)
        try write("two\n", to: server.path("conf.txt"))  // changed on the server meanwhile
        editor.revertToServer(nil)  // nothing edited here: no question
        #expect(await eventually { text.string == "two\n" })
        #expect(editor.window?.isDocumentEdited == false)
    }
}

@MainActor private func views<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
}

// MARK: Find Files' results

extension FeatureRoundAppTests {
    @MainActor @Test func findResultsDownloadDeleteAndCopyPaths() async throws {
        _ = NSApplication.shared
        try await withServer { @MainActor server in
            var host = server.host()
            host.label = "lab"
            for name in ["logs/a.log", "logs/deep/b.log", "logs/c.log"] { try write(name, to: server.path(name)) }
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
            #expect(await call(agent, "wait", ["until": "connected", "timeout": 30]).error == nil)
            _ = await call(agent, "go", ["path": server.path("logs")])
            _ = await call(agent, "menu", ["path": "File > Find Files…"])
            _ = await call(agent, "set", ["id": "find.pattern", "value": "*.log"])
            _ = await call(agent, "press", ["title": "Find"])
            #expect(await call(agent, "wait", ["until": "found", "timeout": 30]).error == nil)
            let find = try #require(agent.findModel)
            #expect(find.results.count == 3)
            // Several at once: Copy Paths, then Delete… (asks, naming the host).
            #expect(await call(agent, "select", ["in": "sheet", "names": ["a.log", "deep/b.log"]]).error == nil)
            #expect(find.selection.count == 2)
            await TestClipboard.take()
            defer { TestClipboard.give() }
            _ = await call(agent, "press", ["id": "find.copyPaths"])
            #expect(NSPasteboard.general.string(forType: .string) == server.path("logs/a.log") + "\n" + server.path("logs/deep/b.log"))
            let asked = await call(agent, "press", ["id": "find.delete"])
            #expect((sheet(asked)?["title"] as? String)?.contains("on “lab”") == true, "\(asked.json)")
            #expect(await call(agent, "press", ["title": "Delete"]).error == nil)
            #expect(await eventually { !rawExists(server.path("logs/a.log")) && !rawExists(server.path("logs/deep/b.log")) })
            #expect(await eventually { find.results.map { find.relative($0.path) } == ["c.log"] })
            // Download…: into the folder chosen.
            let local = try server.scratch()
            #expect(await call(agent, "select", ["in": "sheet", "names": ["c.log"]]).error == nil)
            let pressed = await call(agent, "press", ["id": "find.download", "file": local])
            #expect(pressed.error == nil, "\(pressed.error ?? "")")
            #expect(await eventually { read(local + "/c.log") == "logs/c.log" })
            await main.selectedWorkspace?.connection.disconnect()
        }
    }
}

// MARK: Server tools and links

@Test func linksParseAndAreMadeWithoutPasswords() throws {
    let link = try #require(HostLink(URL(string: "sftp://dev:secret@[::1]:2222/var/www/site")!))
    #expect(link == HostLink(scheme: .sftp, user: "dev", host: "::1", port: 2222, path: "/var/www/site"))
    #expect(HostLink(URL(string: "sftp://web.example.com/~/logs")!)?.path == "~/logs")
    #expect(HostLink(URL(string: "SSH://Web.Example.com")!) == HostLink(scheme: .ssh, host: "Web.Example.com"))
    #expect(HostLink(URL(string: "https://example.com")!) == nil && HostLink(URL(string: "sftp:///nohost")!) == nil)
    var host = SSHHost(label: "v6", hostname: "::1", port: 2222, username: "dev")
    #expect(link.matches(host) && !link.matches(SSHHost(hostname: "::1", port: 22, username: "dev")))
    #expect(HostLink(scheme: .ssh, host: "WEB.example.com").matches(SSHHost(hostname: "web.example.com")))
    #expect(HostLink.string(for: host, path: "/var/my site") == "sftp://dev@%5B::1%5D:2222/var/my%20site"
            || HostLink.string(for: host, path: "/var/my site") == "sftp://dev@[::1]:2222/var/my%20site")
    host.username = ""
    host.port = nil
    host.hostname = "web.example.com"
    #expect(HostLink.string(for: host, path: nil) == "ssh://web.example.com")
    // What it makes, it reads back.
    let made = try #require(URL(string: HostLink.string(for: SSHHost(hostname: "h", port: 2200, username: "u"), path: "/a b")))
    #expect(HostLink(made) == HostLink(scheme: .sftp, user: "u", host: "h", port: 2200, path: "/a b"))
}

@Test func serverInfoReadsTheDebugLogAndKnownHosts() {
    let log = """
        2026-10-10 07:49:53.714 [web] ssh[1]: debug1: Remote protocol version 2.0, remote software version OpenSSH_9.6p1 Ubuntu-3
        2026-10-10 07:49:53.723 [web] ssh[1]: debug1: kex: algorithm: curve25519-sha256
        2026-10-10 07:49:53.723 [web] ssh[1]: debug1: kex: server->client cipher: aes128-gcm@openssh.com MAC: <implicit> compression: none
        """
    let negotiated = ServerInfo.negotiated(log)
    #expect(negotiated.version == "OpenSSH_9.6p1 Ubuntu-3" && negotiated.kex == "curve25519-sha256")
    #expect(negotiated.cipher == "aes128-gcm@openssh.com" && negotiated.mac == "built into the cipher")
    #expect(ServerInfo.fingerprints("# Host x found: line 1\nx ED25519 SHA256:abc\nx RSA SHA256:def\n") == ["ED25519 SHA256:abc", "RSA SHA256:def"])
    #expect(ServerInfo(keys: [], version: nil).text(host: "web", capabilities: ["runs commands"]).contains("Server key: not in known_hosts"))
}

@Test func serverInfoNamesTheTrustedKeyAndFreeSpace() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let info = await session.serverInfo(folder: server.home)
        #expect(!info.keys.isEmpty && info.keys.allSatisfy { $0.contains("SHA256:") }, "\(info)")
        #expect((info.free ?? 0) > 0)
    }
}

extension FeatureRoundAppTests {
    /// An sftp:// link opens the saved host at its path; one for an unknown server fills in New Host….
    @MainActor @Test func linksOpenSavedHostsOrNewHost() async throws {
        _ = NSApplication.shared
        try await withServer { @MainActor server in
            var host = server.host()
            host.label = "lab"
            try write("x", to: server.path("www/index.html"))
            let model = testModel([host])
            let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
            defer { askpass.close() }
            let (main, agent, _) = try agentWindow(model, askpass)
            defer {
                agent.close()
                main.window?.orderOut(nil)
            }
            main.open(try #require(HostLink(URL(string: "sftp://127.0.0.1:\(server.port)\(server.path("www"))")!)))
            #expect(await eventually { main.selectedWorkspace?.browser.right.dir == server.path("www") })
            // Server Info and Copy Link for it.
            #expect(await call(agent, "menu", ["path": "Host > Server Info…"]).error == nil)
            #expect(await call(agent, "wait", ["until": "sheet", "text": "Server Info", "timeout": 20]).error == nil)
            _ = await call(agent, "press", ["title": "Done"])
            await TestClipboard.take()
            defer { TestClipboard.give() }
            _ = await call(agent, "menu", ["path": "Host > Copy Link"])
            #expect(NSPasteboard.general.string(forType: .string)?.hasSuffix(":\(server.port)\(server.path("www"))") == true)
            // "~" in a link is the home folder, as Go to Folder takes it.
            try write("y", to: server.path("logs/a.log"))
            main.open(try #require(HostLink(URL(string: "sftp://127.0.0.1:\(server.port)/~/logs")!)))
            #expect(await eventually { main.selectedWorkspace?.browser.right.dir == server.path("logs") },
                    "\(main.selectedWorkspace?.browser.right.dir ?? "nil")")
            await main.selectedWorkspace?.connection.disconnect()
            // Unknown: New Host… with its address.
            main.open(try #require(HostLink(URL(string: "sftp://deploy@new.example.com:2200/srv")!)))
            let reply = await call(agent, "wait", ["until": "sheet", "text": "New Host", "timeout": 10])
            #expect(reply.error == nil)
            let values = (reply["fields"] as? [[String: Any]] ?? []).compactMap { $0["value"] as? String }
            #expect(values.contains("new.example.com") && values.contains("deploy"), "\(reply.json)")
            _ = await call(agent, "press", ["title": "Cancel"])
        }
    }
}

// MARK: Browse and transfer as another user

@Test func sudoCommandLinesRunAsTheOtherUser() {
    #expect(OpenSSH.longScript("ls", sudo: "").command == "exec sh -s")
    #expect(OpenSSH.longScript("ls", sudo: "root").command == "exec sudo -n -u 'root' sh -s")
    let host = SSHHost(hostname: "h")
    let argv = OpenSSH.sftpBatch(host, jump: nil, socket: "/tmp/s", server: "sudo -n -u 'root' /usr/lib/ssh/sftp-server")
    #expect(argv.contains("-s") && argv[argv.firstIndex(of: "-s")! + 1] == "sudo -n -u 'root' /usr/lib/ssh/sftp-server")
    #expect(!OpenSSH.sftpBatch(host, jump: nil, socket: "/tmp/s").contains("-s"))
    #expect(HostDraft(SSHHost(hostname: "h")).validationError == nil)
    var draft = HostDraft(SSHHost(hostname: "h"))
    draft.sudoUser = "root; rm -rf /"
    #expect(draft.validationError?.contains("isn't a user name") == true)
}

/// Without sudo for that user, connecting says why instead of browsing as the login user. (A user that doesn't exist:
/// CI's runner account may sudo to anyone without a password.)
@Test func browsingAsAnotherUserNeedsPasswordlessSudo() async throws {
    try await withServer { server in
        var host = server.host()
        host.sudoUser = "airscp-no-such-user"
        let session = try server.session(host)
        do {
            try await session.connect()
            Issue.record("connected without sudo for root")
        } catch let error as AirSCPError {
            #expect(error.kind == .permissionDenied && error.message.contains("NOPASSWD"), "\(error.message)")
        }
        #expect(session.state != .connected)
    }
}
