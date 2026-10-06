import AppKit
import Darwin
import Foundation
import Testing
@testable import AirSCP
@testable import AirSCPCore

// The workspace's Files tab, Transfers panel and Monitor tab (ui-workspace). Without a server: the rows (sorting,
// filtering, this Mac's folders), name conflicts, permissions, names, paths, the menus, drop rules and the panels'
// texts. Against throwaway sshd servers: the panes, copies between them, file promises, the editor and the monitor.
// The controllers are made without a workspace window (`workspace: nil`): no SwiftUI hosting views, so these tests
// keep the main thread free for the others.

private func entry(_ name: String, _ kind: RemoteEntry.Kind = .file, size: Int64 = 0, modified: Date? = nil,
                   mode: Int = 0o644, in dir: String = "/srv") -> RemoteEntry {
    RemoteEntry(name: name, path: RemotePath.join(dir, name), kind: kind, size: size, modified: modified,
                permissions: FileList.symbolic(mode), mode: mode, owner: "dev", group: "staff")
}

private func item(_ name: String, _ kind: RemoteEntry.Kind = .file, size: Int64 = 0, modified: Date? = nil) -> FileItem {
    FileItem(entry(name, kind, size: size, modified: modified))
}

/// The Files tab of a connected session, on its own (no workspace window): the local pane starts in the host's
/// `lastLocalDir`.
@MainActor
private func filesTab(_ session: Session) -> BrowserContentController {
    let browser = BrowserContentController(workspace: nil, session: session)
    _ = browser.view
    browser.stateChanged(session.state)
    return browser
}

// MARK: Rows

@Test func rowsSortLikeFinderWithFoldersFirst() {
    let old = Date(timeIntervalSince1970: 1_000_000), new = Date(timeIntervalSince1970: 2_000_000)
    let items = [item("file 10.txt", size: 5, modified: new), item("b", .directory), item("File 2.txt", size: 50, modified: old),
                 item("a.zip", size: 1), item("Z", .directory), item("link", .symlink)]
    #expect(FileList.sorted(items, by: "name", ascending: true, folderSizes: [:]).map(\.name)
            == ["b", "Z", "a.zip", "File 2.txt", "file 10.txt", "link"])
    // Descending keeps the folders on top.
    #expect(FileList.sorted(items, by: "name", ascending: false, folderSizes: [:]).map(\.name)
            == ["Z", "b", "link", "file 10.txt", "File 2.txt", "a.zip"])
    // Calculated folder sizes count; folders not measured come first.
    #expect(FileList.sorted(items, by: "size", ascending: true, folderSizes: ["b": 10]).map(\.name)
            == ["Z", "b", "link", "a.zip", "file 10.txt", "File 2.txt"])
    // No date sorts as the oldest; ties go by name.
    #expect(FileList.sorted(items, by: "modified", ascending: false, folderSizes: [:]).map(\.name)
            == ["b", "Z", "file 10.txt", "File 2.txt", "a.zip", "link"])
}

/// Files over six months old list with a day only: they show that day, not an invented time (its midnight in UTC, shown
/// in this Mac's time zone: 8:00 AM east of UTC, the day before west of it). The conflict sheet's line too.
@MainActor @Test func dateOnlyEntriesShowTheirDay() {
    var old = entry("old.log", size: 42, modified: Date(timeIntervalSince1970: 1_704_067_200))  // 1 Jan 2024
    old.dateOnly = true
    let day = FileList.day(Date(timeIntervalSince1970: 1_704_067_200))
    #expect(day.contains("2024") && !day.contains(":"))
    let line = FileList.comparison(new: item("old.log", size: 12, modified: Date()), existing: FileItem(old))
    #expect(line.hasSuffix("Existing: 42 bytes, " + day), "\(line)")
}

@Test func rowsFilterByNameAndHideDotFiles() {
    let rows = [item(".bashrc"), item("Report.txt"), item("résumé.pdf"), item("notes")]
    #expect(FileList.visible(rows, filter: "", showHidden: false).map(\.name) == ["Report.txt", "résumé.pdf", "notes"])
    #expect(FileList.visible(rows, filter: "", showHidden: true).count == 4)
    #expect(FileList.visible(rows, filter: "REPORT", showHidden: false).map(\.name) == ["Report.txt"])
    #expect(FileList.visible(rows, filter: "resume", showHidden: false).map(\.name) == ["résumé.pdf"])
    #expect(FileList.visible(rows, filter: "bash", showHidden: false).isEmpty)
    #expect(FileList.visible(rows, filter: " bash ", showHidden: true).map(\.name) == [".bashrc"])
}

@Test func fiftyThousandRowsAreSortedAndFilteredQuickly() {
    let entries = (0..<50_000).map { (index: Int) -> RemoteEntry in
        let folder = index % 10 == 0
        let name = folder ? "folder \(index)" : "file \(index).txt"
        return entry(name, folder ? .directory : .file, size: Int64(index), modified: Date(timeIntervalSince1970: TimeInterval(index)))
    }
    let started = Date()
    let items = entries.map(FileItem.init)
    let sorted = FileList.sorted(items, by: "name", ascending: true, folderSizes: [:])
    let rows = FileList.visible(sorted, filter: "", showHidden: false)
    let filtered = FileList.visible(sorted, filter: "99", showHidden: false)
    let bySize = FileList.sorted(items, by: "size", ascending: false, folderSizes: [:])
    let elapsed = Date().timeIntervalSince(started)
    #expect(rows.count == 50_000 && filtered.count > 0 && bySize.count == 50_000)
    #expect(sorted.prefix(5_000).allSatisfy { $0.isFolder } && sorted[5_000].name == "file 1.txt")
    // All of it runs off the main thread. About 1 s in a debug build next to the other tests (a release build takes a
    // fraction of that; a Mac busy with other work, several times that: 38 s on CI); the limit catches a slowdown like
    // a quadratic sort, which would take an hour.
    #expect(elapsed < 120, "building 50 000 rows took \(elapsed) s")
}

@Test func localFoldersAreListedWithNamesAsStored() throws {
    let folder = try scratch()
    let precomposed = "caf\u{E9}.txt", decomposed = "e\u{301}te\u{301}"
    try rawCreate(folder + "/" + precomposed, "hello")
    chmod(folder + "/" + precomposed, 0o640)
    try rawMkdir(folder + "/" + decomposed)
    try FileManager.default.createSymbolicLink(atPath: folder + "/link", withDestinationPath: decomposed)
    let items = try FileList.local(folder)
    #expect(Set(items.map { Array($0.name.utf8) }) == [Array(precomposed.utf8), Array(decomposed.utf8), Array("link".utf8)])
    let file = try #require(items.first { $0.name == precomposed })
    #expect(file.kind == .file && file.size == 5 && file.mode == 0o640 && file.permissions == "rw-r-----")
    #expect(file.owner == NSUserName() && file.entry == nil && file.path == folder + "/" + precomposed)
    #expect(items.first { $0.name == "link" }?.kind == .symlink && items.first { $0.name == decomposed }?.kind == .directory)
    #expect(FileList.isLocalFolder(folder + "/link") && !FileList.isLocalFolder(folder + "/" + precomposed))
    // Finder's URL may spell the name in the other Unicode form: the row has it as stored.
    let dropped = FileList.localItems([URL(fileURLWithPath: folder + "/" + "cafe\u{301}.txt"), URL(fileURLWithPath: folder + "/link"),
                                       URL(fileURLWithPath: folder + "/gone")])
    #expect(dropped.count == 2 && Array(dropped[0].name.utf8) == Array(precomposed.utf8) && dropped[0].size == 5)
    #expect(dropped[1].name == "link" && dropped[1].kind == .symlink)
    #expect(Set(FileList.localNames(folder).map { Array($0.utf8) }) == Set(items.map { Array($0.name.utf8) }))
    #expect(throws: AirSCPError.self) { try FileList.local(folder + "/missing") }
}

// MARK: Names

@Test func conflictsAreReplacedRenamedOrSkipped() {
    let existing = ["a.txt", "B.txt", "caf\u{E9}", "logs.tar.gz", "logs 2.tar.gz"]
    let names = ["a.txt", "b.txt", "cafe\u{301}", "logs.tar.gz", "new"]
    // Case counts on a server, not on a Mac's disk; Unicode forms never count.
    #expect(FileList.conflicts(names, existing: existing, caseInsensitive: false) == ["a.txt", "cafe\u{301}", "logs.tar.gz"])
    #expect(FileList.conflicts(names, existing: existing, caseInsensitive: true) == ["a.txt", "b.txt", "cafe\u{301}", "logs.tar.gz"])
    let plan = FileList.plan(names, existing: existing, caseInsensitive: false,
                             choices: ["a.txt": .replace, "cafe\u{301}": .replace, "logs.tar.gz": .keepBoth])
    #expect(plan == [FileList.Planned(name: "a.txt", replaces: "a.txt"), FileList.Planned(name: "b.txt"),
                     FileList.Planned(name: "caf\u{E9}", replaces: "caf\u{E9}"), FileList.Planned(name: "logs 3.tar.gz"),
                     FileList.Planned(name: "new")])
    // Replace goes onto the existing item's exact name.
    #expect(Array(plan[2]!.name.utf8) == Array("caf\u{E9}".utf8))
    // Skip, or no answer: left out.
    #expect(FileList.plan(["a.txt", "x"], existing: ["a.txt"], caseInsensitive: false, choices: ["a.txt": .skip])
            == [nil, FileList.Planned(name: "x")])
    #expect(FileList.plan(["a.txt"], existing: ["a.txt"], caseInsensitive: false, choices: [:]) == [nil])
    // Two items with one name in one transfer keep both.
    #expect(FileList.plan(["x", "x"], existing: [], caseInsensitive: false, choices: [:]).map { $0?.name } == ["x", "x 2"])
    #expect(FileList.plan(["B.TXT"], existing: ["b.txt"], caseInsensitive: true, choices: ["B.TXT": .keepBoth]).map { $0?.name }
            == ["B 2.TXT"])
}

@Test func namesThatCantBeFilesAreRefused() {
    for good in ["notes.txt", " leading space", "-dash", "a*b?[c]", "it's \"quoted\""] { #expect(FileList.nameProblem(good) == nil) }
    for bad in ["", ".", "..", "a/b", "line\nbreak", "nul\u{0}"] { #expect(FileList.nameProblem(bad) != nil) }
}

@Test func permissionsReadAndWriteBothWays() {
    #expect(FileList.symbolic(0o755) == "rwxr-xr-x" && FileList.symbolic(0o4755) == "rwsr-xr-x")
    #expect(FileList.symbolic(0o2640) == "rw-r-S---" && FileList.symbolic(0o1777) == "rwxrwxrwt" && FileList.symbolic(0o1776) == "rwxrwxrwT")
    // The listing's parser reads back every mode.
    #expect((0...0o7777).allSatisfy { Listing.mode(FileList.symbolic($0)) == $0 })
    #expect(PermissionsGrid.octal(0o644) == "644" && PermissionsGrid.octal(0o4755) == "4755" && PermissionsGrid.octal(0o7) == "007")
}

@MainActor @Test func typedPathsResolveInThePane() {
    #expect(FilePane.normalized("/a/./b/../c/") == "/a/c")
    #expect(FilePane.normalized("/../..") == "/" && FilePane.normalized("//srv//www/") == "/srv/www")
    let pane = FilePane(source: .local, choosesSource: true, showHidden: false)
    #expect(pane.resolve("~") == NSHomeDirectory())
    #expect(pane.resolve("  ~/Documents/../Desktop ") == NSHomeDirectory() + "/Desktop")
    #expect(pane.resolve("relative/x") == NSHomeDirectory() + "/relative/x")
    #expect(pane.resolve("/etc/") == "/etc" && pane.resolve("  ") == nil)
}

// MARK: Menus and drops

@MainActor @Test func browserCommandsJoinTheFileViewAndGoMenus() throws {
    let main = NSMenu()
    for title in ["AirSCP", "File", "Edit", "View", "Host", "Window"] {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = NSMenu(title: title)
        main.addItem(item)
    }
    let file = main.item(withTitle: "File")!.submenu!
    file.addItem(NSMenuItem(title: "New Host…", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "n"))
    file.addItem(.separator())
    file.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
    BrowserContentController.addMenuItems(to: main)

    #expect(main.items.map(\.title) == ["AirSCP", "File", "Edit", "View", "Go", "Host", "Window"])
    #expect(file.items.first?.title == "New Host…" && file.items.last?.title == "Close")
    #expect(file.item(withTitle: "New Folder…")?.keyEquivalent == "N" && file.item(withTitle: "Get Info")?.keyEquivalent == "i")
    let view = main.item(withTitle: "View")!.submenu!
    #expect(view.item(withTitle: "Show Hidden Files")?.keyEquivalentModifierMask == [.command, .shift])
    let go = main.item(withTitle: "Go")!.submenu!
    #expect(go.items.filter { !$0.isSeparatorItem }.map(\.title)
            == ["Back", "Forward", "Enclosing Folder", "Open Selection", "Home", "Go to Folder…", "Add to Favourites", "Favourites"])
    // View ▸ Columns: the header's menu (not the name column, which always shows).
    let columns = try #require(view.item(withTitle: "Columns")?.submenu)
    #expect(columns.items.map(\.title) == ["Size", "Date Modified", "Permissions", "Owner", "Group", "Kind"])
    // Every command is a pane's, and no shortcut is used twice.
    let added = (file.items + view.items + go.items + columns.items)
        .filter { !$0.isSeparatorItem && $0.submenu == nil && $0.title != "New Host…" && $0.title != "Close" }
    #expect(added.allSatisfy { $0.action.map(FilePane.instancesRespond) == true })
    let shortcuts = (file.items + view.items + go.items).filter { !$0.keyEquivalent.isEmpty }
        .map { "\($0.keyEquivalent)|\($0.keyEquivalentModifierMask.rawValue)" }
    #expect(Set(shortcuts).count == shortcuts.count)
}

@MainActor @Test func dropsCopyBetweenPlacesAndMoveWithinAServer() throws {
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let a = Session(host: SSHHost(hostname: "a.example"), jump: nil, askpass: askpass)
    let b = Session(host: SSHHost(hostname: "b.example"), jump: nil, askpass: askpass)
    a.capabilities.shell = true
    let items = [FileItem(entry("x")), FileItem(entry("site", .directory))]
    func drop(_ from: FilePane.Source, _ to: FilePane.Source, _ dir: String,
              _ mask: NSDragOperation = [.copy, .move]) -> NSDragOperation {
        BrowserContentController.dropOperation(items, from: from, to: to, into: dir, mask: mask)
    }
    #expect(drop(.remote(a), .local, "/Users/me") == .copy && drop(.local, .remote(a), "/srv") == .copy)
    #expect(drop(.remote(a), .remote(b), "/srv") == .copy)  // another server, even into the same path
    #expect(drop(.remote(a), .remote(a), "/srv/other") == .move)
    #expect(drop(.remote(a), .remote(a), "/srv/other", .copy) == .copy)  // ⌥ copies
    #expect(drop(.remote(a), .remote(a), "/srv") == [])  // already there
    #expect(drop(.remote(a), .remote(a), "/srv", .copy) == .copy)  // ⌥ in the same folder: a copy beside it
    #expect(drop(.remote(a), .remote(a), "/srv/site/inner") == [])  // a folder into itself
    #expect(drop(.local, .local, "/tmp") == [])
    #expect(BrowserContentController.dropOperation([], from: .local, to: .remote(a), into: "/srv", mask: .copy) == [])
    // An account without a shell can't copy within its server (cp); it can move (sftp's rename).
    a.capabilities.shell = false
    #expect(drop(.remote(a), .remote(a), "/srv/other", .copy) == [] && drop(.remote(a), .remote(a), "/srv/other") == .move)
}

// MARK: Panels

@Test func transferPanelTexts() {
    let host = UUID()
    func job(_ direction: TransferJob.Direction = .upload, names: [String] = [], folder: Bool = false,
             status: TransferJob.Status = .running, progress: TransferProgress = TransferProgress(), started: Date? = nil) -> TransferJob {
        TransferJob(id: UUID(), direction: direction, hostID: host, sourceHostID: nil, source: "/Users/me/site",
                    destination: "/srv/www/site", names: names, isFolder: folder, replacing: false, preserveTimes: false,
                    status: status, progress: progress, started: started)
    }
    var progress = TransferProgress()
    progress.percent = 48
    progress.bytes = 14 << 20
    progress.speed = "5.8MB/s"
    progress.eta = "00:02"
    let running = job(progress: progress)
    #expect(TransferText.name(running) == "site" && TransferText.status(running) == "Uploading")
    #expect(TransferText.fraction(running) == 0.48 && TransferText.eta(running) == "00:02")
    #expect(TransferText.size(running) == FileList.size(14 << 20) && TransferText.detail(running) == nil)
    // A streamed archive: no percentage; the bytes so far against the estimate, and the time since it started.
    var streamed = TransferProgress()
    streamed.indeterminate = true
    streamed.bytes = 3 << 20
    streamed.total = 10 << 20
    let started = Date()
    let archive = job(.download, names: ["a", "b"], progress: streamed, started: started)
    #expect(TransferText.name(archive) == "2 items" && TransferText.detail(archive) == "as site")
    #expect(TransferText.status(archive) == "Downloading" && TransferText.status(job(.relay)) == "Copying")
    #expect(TransferText.fraction(archive) == nil && TransferText.eta(archive, now: started.addingTimeInterval(75)) == "1:15 elapsed")
    #expect(TransferText.size(archive) == FileList.size(3 << 20) + " of ~" + FileList.size(10 << 20))
    // A folder shows the file being copied.
    var files = TransferProgress()
    files.file = "index.html"
    files.filesDone = 3
    #expect(TransferText.detail(job(folder: true, progress: files)) == "index.html · 3 done")
    // scp -r's meter starts again for each file: such a folder has no size of the whole (it showed the last file's).
    var perFile = TransferProgress()
    perFile.bytes = 9
    #expect(TransferText.size(job(folder: true, progress: perFile)) == "—" && TransferText.size(job(progress: perFile)) == FileList.size(9))
    #expect(TransferText.fraction(job(status: .done)) == 1 && TransferText.fraction(job(status: .queued)) == nil)
    let partial = job(status: .completedWithErrors("scp: broken: No such file or directory"))
    #expect(TransferText.status(partial) == "Completed with errors")
    #expect(TransferText.problem(partial)?.details == "scp: broken: No such file or directory")
    #expect(TransferText.canRetry(partial) && !TransferText.canRetry(job(status: .done)) && !TransferText.canRetry(running))
    let failed = job(status: .failed(AirSCPError(.permissionDenied, "Permission denied on the server.")))
    #expect(TransferText.status(failed) == "Failed: Permission denied on the server.")
    #expect(TransferText.summary([running, failed, partial, job(status: .queued)]) == "1 running, 1 queued, 2 with problems")
    #expect(TransferText.duration(3725) == "1:02:05" && TransferText.duration(42) == "0:42")
    #expect(TransferText.route(job(names: ["x"])) == "/Users/me/site/x → /srv/www/site")
    #expect(TransferText.symbol(.relay) == "arrow.left.arrow.right" && TransferText.direction(.relay) == "Server to server")
}

@Test func monitorTexts() {
    #expect(MonitorText.uptime(12 * 86400 + 3 * 3600 + 4 * 60) == "12 days, 3:04")
    #expect(MonitorText.uptime(240) == "4 min" && MonitorText.uptime(86400 + 60) == "1 day, 1 min")
    #expect(MonitorText.elapsed(307) == "05:07" && MonitorText.elapsed(3723) == "1:02:03")
    #expect(MonitorText.elapsed(2 * 86400 + 3 * 3600 + 4 * 60 + 5) == "2-03:04:05")
    let processes = [
        MonitorProcess(pid: 1, ppid: 0, user: "root", cpu: nil, memory: 0.1, rss: 1, elapsed: 5, state: "Ss", name: "init",
                       command: "/sbin/init"),
        MonitorProcess(pid: 4242, ppid: 1, user: "dev", cpu: 12.5, memory: 3, rss: 2, elapsed: nil, state: "R", name: "python3",
                       command: "python3 -m http.server 8080"),
    ]
    #expect(MonitorText.filter(processes, "HTTP").map(\.pid) == [4242] && MonitorText.filter(processes, "root").map(\.pid) == [1])
    #expect(MonitorText.filter(processes, "4242").map(\.pid) == [4242] && MonitorText.filter(processes, " ").count == 2)
    // BusyBox has no %CPU: such processes sort last.
    #expect(processes.sorted(using: KeyPathComparator(\MonitorProcess.cpuOrder, order: .reverse)).map(\.pid) == [4242, 1])
}

// MARK: Against a server

@MainActor @Test func remotePaneListsNavigatesAndRenames() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        let session = try await server.connectedSession()
        try rawMkdir(server.path("site"))
        try rawMkdir(server.path("site/assets"))
        try write("x", to: server.path("site/index.html"))
        try write("x", to: server.path(".hidden"))
        try write("y", to: server.path("notes.txt"))
        try FileManager.default.createSymbolicLink(atPath: server.path("to-site"), withDestinationPath: "site")
        let pane = FilePane(source: .remote(session), choosesSource: false, showHidden: false)
        _ = pane.view
        #expect(await pane.open(server.home))
        #expect(pane.rows.map(\.name) == ["site", "notes.txt", "to-site"] && pane.items.count == 4)
        pane.toggleHiddenFiles(nil)
        #expect(await eventually { pane.rows.count == 4 })
        #expect(await pane.open(server.path("site")))
        #expect(pane.rows.map(\.name) == ["assets", "index.html"])
        pane.goUp(nil)
        #expect(await eventually { pane.dir == server.home && pane.selectedItems.map(\.name) == ["site"] })
        pane.goBack(nil)
        #expect(await eventually { pane.dir == server.path("site") })
        pane.goForward(nil)
        #expect(await eventually { pane.dir == server.home && pane.back.last == server.path("site") })
        // A link to a folder lists it; a folder that isn't there keeps the one shown.
        #expect(await pane.open(server.path("to-site")))
        #expect(pane.rows.map(\.name) == ["assets", "index.html"])
        #expect(await !pane.open(server.path("missing")))
        #expect(pane.dir == server.path("to-site") && (pane.lastError as? AirSCPError)?.kind == .noSuchFile)
        let index = try #require(pane.rows.first { $0.name == "index.html" })
        await pane.rename(index, to: "home page.html", in: server.path("to-site"))
        #expect(read(server.path("site/home page.html")) == "x" && !exists(server.path("site/index.html")))
        #expect(pane.rows.map(\.name) == ["assets", "home page.html"] && pane.selectedItems.map(\.name) == ["home page.html"])
    }
}

@MainActor @Test func commandsAServerCantRunAreOffWithTheReason() async throws {
    _ = NSApplication.shared
    try await withServer(TestServer.Options(sftpOnly: true)) { @MainActor server in
        try rawMkdir(server.path("site"))
        try write("x", to: server.path("logs.tar.gz"))
        let session = try await server.connectedSession()
        let pane = FilePane(source: .remote(session), choosesSource: false, showHidden: false)
        _ = pane.view
        #expect(await pane.open(server.home))
        let archive = try #require(pane.rows.first { $0.name == "logs.tar.gz" })
        let shellOnly = [#selector(FilePane.duplicateItems(_:)), #selector(FilePane.compressItems(_:)),
                         #selector(FilePane.extractHere(_:)), #selector(FilePane.downloadArchive(_:)),
                         #selector(FilePane.calculateFolderSizes(_:))]
        for action in shellOnly {
            let (enabled, reason) = pane.check(action, for: [archive])
            #expect(!enabled && reason?.contains("sftp") == true, "\(action)")
        }
        // sftp works for the rest.
        for action in [#selector(FilePane.renameItem(_:)), #selector(FilePane.editPermissions(_:)), #selector(FilePane.getInfo(_:)),
                       #selector(FilePane.deleteItems(_:)), #selector(FilePane.editItem(_:)), #selector(FilePane.downloadTo(_:))] {
            let (enabled, reason) = pane.check(action, for: [archive])
            #expect(enabled && reason == nil, "\(action)")
        }
        // Run and Terminal go to the workspace's own host, which a pane without a browser can't name.
        let (canRun, _) = pane.check(#selector(FilePane.runItem(_:)), for: [archive])
        #expect(!canRun)
        // The menu for an archive offers extracting; the folder's own menu offers new items and the hidden files.
        func titles(_ entries: [(String, Selector)?]) -> [String] { entries.compactMap { entry in entry?.0 } }
        let forArchive = titles(pane.contextMenu(for: [archive]))
        #expect(forArchive.contains("Extract Here") && forArchive.contains("Get Info") && forArchive.contains("Delete…"))
        #expect(!forArchive.contains("Move to Trash"))
        let forFolder = titles(pane.contextMenu(for: []))
        #expect(Array(forFolder.prefix(3)) == ["New Folder…", "New File…", "Upload…"])
        let local = FilePane(source: .local, choosesSource: true, showHidden: false)
        #expect(titles(local.contextMenu(for: [archive])).contains("Move to Trash"))
    }
}

@MainActor @Test func localPaneListsAndRenames() async throws {
    _ = NSApplication.shared
    let folder = try scratch()
    try rawMkdir(folder + "/Photos")
    try write("a", to: folder + "/a.txt")
    try write("b", to: folder + "/.DS_Store")
    let pane = FilePane(source: .local, choosesSource: true, showHidden: false)
    _ = pane.view
    #expect(await pane.open(folder))
    #expect(pane.rows.map(\.name) == ["Photos", "a.txt"])
    await pane.rename(try #require(pane.rows.last), to: "b.txt", in: folder)
    #expect(read(folder + "/b.txt") == "a" && !rawExists(folder + "/a.txt"))
    #expect(pane.rows.map(\.name) == ["Photos", "b.txt"])
}

@MainActor @Test func draggingServerItemsToFinderDownloadsThem() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        let session = try await server.connectedSession()
        try write("promised", to: server.path("promise.txt"))
        try rawMkdir(server.path("folder"))
        try write("inner", to: server.path("folder/inner.txt"))
        // Links and a special file promise plain data: AppKit raised for a link's or a pipe's own type, and AirSCP crashed.
        // A link to a file came as a folder (the listing doesn't say what a link points to), and its cd failed.
        symlink("promise.txt", server.path("to-file"))
        symlink("folder", server.path("to-folder"))
        mkfifo(server.path("pipe"), 0o644)
        let pane = FilePane(source: .remote(session), choosesSource: false, showHidden: false)
        _ = pane.view
        #expect(await pane.open(server.home))
        let drop = try server.scratch()
        for name in ["promise.txt", "folder", "to-file", "to-folder", "pipe"] {
            let row = try #require(pane.rows.firstIndex { $0.name == name })
            let provider = try #require(pane.tableView(pane.table, pasteboardWriterForRow: row) as? NSFilePromiseProvider)
            #expect(pane.filePromiseProvider(provider, fileNameForType: provider.fileType) == name)
            // Finder calls this on the promise queue and shows the item when it returns.
            let done = Recorder<String>()
            let destination = URL(fileURLWithPath: drop + "/" + name)
            OffMainThread {
                pane.filePromiseProvider(provider, writePromiseTo: destination) { error in done.append(error.map { "\($0)" } ?? "ok") }
            }.start()
            // A pipe can't be copied: its promise ends with the reason.
            #expect(await eventually { name == "pipe" ? done.all.first?.contains("a pipe, a socket or a device") == true : done.all == ["ok"] },
                    "\(name): \(done.all)")
        }
        #expect(read(drop + "/promise.txt") == "promised" && read(drop + "/folder/inner.txt") == "inner")
        #expect(read(drop + "/to-file") == "promised" && read(drop + "/to-folder/inner.txt") == "inner")
        #expect(names(in: drop) == ["folder", "promise.txt", "to-file", "to-folder"])  // no part files left
    }
}

/// A failed Open left an empty temporary folder behind (and quitting left every opened file in $TMPDIR: the folder now goes
/// when AirSCP quits, as when its tab closes).
@MainActor @Test func aFailedOpenLeavesNoTemporaryFolder() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        let session = try await server.connectedSession()
        let browser = filesTab(session)
        let made = try #require(browser.temporaryFolder())
        let root = made.deletingLastPathComponent()
        try FileManager.default.removeItem(at: made)
        browser.openWithDefaultApp([FileItem(entry("gone.txt", in: server.home))], on: session, from: browser.right)
        #expect(await eventually { await server.logEntries().contains { $0.command.contains("gone.txt") } })
        #expect(await eventually { (try? FileManager.default.contentsOfDirectory(atPath: root.path))?.isEmpty == true })
    }
}

/// The folder shown was deleted on the server: Refresh and Enclosing Folder failed, and its rows stayed. They now go to
/// the nearest folder that is there.
@MainActor @Test func aDeletedFolderGivesWayToTheNearestOneThere() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        let session = try await server.connectedSession()
        try write("x", to: server.path("vanish/inner/x"))
        let pane = FilePane(source: .remote(session), choosesSource: false, showHidden: false)
        _ = pane.view
        #expect(await pane.open(server.path("vanish/inner")))
        try FileManager.default.removeItem(atPath: server.path("vanish"))
        await pane.reload()
        #expect(pane.dir == server.home && !pane.rows.contains { $0.name == "vanish" } && pane.lastError == nil)
        try write("y", to: server.path("a/b/c/y"))
        #expect(await pane.open(server.path("a/b/c")))
        try FileManager.default.removeItem(atPath: server.path("a/b"))
        pane.goUp(nil)
        #expect(await eventually { pane.dir == server.path("a") }, "\(pane.dir ?? "")")
        #expect(pane.lastError == nil)
    }
}

@MainActor @Test func editorSavesBackToTheServer() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        let session = try await server.connectedSession()
        try write("port=80\n", to: server.path("app.conf"))
        chmod(server.path("app.conf"), 0o600)
        let editor = RemoteEditor(session: session, path: server.path("app.conf"),
                                  text: try await session.readText(server.path("app.conf")))
        var saved = 0
        editor.onSaved = { saved += 1 }
        let text = try #require(editor.window?.initialFirstResponder as? NSTextView)
        #expect(text.string == "port=80\n")
        text.string = "port=8080\n"
        editor.save(nil)
        #expect(await eventually { saved == 1 })
        #expect(read(server.path("app.conf")) == "port=8080\n")
        var info = stat()
        #expect(lstat(server.path("app.conf"), &info) == 0 && info.st_mode & 0o777 == 0o600)
        editor.close()
    }
}

@MainActor @Test func browserCopiesBetweenThePanesAndRefreshesThem() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        var host = server.host()
        let local = try server.scratch()
        host.lastLocalDir = local
        try write("upload me", to: local + "/up.txt")
        try write("download me", to: server.path("down.txt"))
        let session = try await server.connectedSession(host)
        let browser = filesTab(session)
        #expect(await eventually { browser.right.rows.map(\.name) == ["down.txt"] && browser.left.rows.map(\.name) == ["up.txt"] })
        #expect(browser.right.dir == server.home && browser.left.dir == local)
        #expect(browser.transferTitle(for: browser.left).button == "Upload")
        #expect(browser.transferTitle(for: browser.right).button == "Download")

        browser.copyToOtherPane(browser.left.rows, from: browser.left)
        #expect(await eventually { read(server.path("up.txt")) == "upload me" })
        #expect(await eventually { browser.right.rows.map(\.name) == ["down.txt", "up.txt"] })  // listed again when done
        browser.copyToOtherPane(browser.right.rows.filter { $0.name == "down.txt" }, from: browser.right)
        #expect(await eventually { read(local + "/down.txt") == "download me" })
        #expect(await eventually { browser.left.rows.map(\.name) == ["down.txt", "up.txt"] })

        // Upload Compressed: one queued job with the names, unpacked into the folder shown.
        try write("fresh", to: local + "/fresh.txt")
        await browser.left.reload()
        browser.uploadCompressed(browser.left.rows.filter { $0.name == "fresh.txt" }, from: browser.left)
        #expect(await eventually {
            session.transfers.jobs.contains { $0.names == ["fresh.txt"] && $0.source == local && $0.destination == server.home }
        })
    }
}

@MainActor @Test func monitorRunsNothingWhileNotOnScreen() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        let session = try await server.connectedSession()
        let monitor = MonitorController(workspace: nil, session: session)
        monitor.stateChanged(.connected)
        try await Task.sleep(nanoseconds: 500_000_000)
        // A refresh would have left a snapshot or a reason: there was none.
        #expect(!monitor.isVisible && !monitor.model.refreshing && monitor.model.snapshot == nil && monitor.model.failure == nil)
        // Asked directly, a server that isn't Linux (this Mac's sshd) says why there is nothing to show.
        monitor.model.refresh()
        #expect(await eventually { !monitor.model.refreshing && monitor.model.failure != nil && monitor.model.snapshot == nil })
    }
}

/// A window for a Files tab, with sheets that come and go without AppKit's animation: it runs on the main thread,
/// which the other tests' callbacks need too. (A registered default: nothing is saved.)
@MainActor
private func window(for browser: BrowserContentController) -> NSWindow {
    UserDefaults.standard.register(defaults: ["NSWindowResizeTime": 0.001])
    let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 500), styleMask: [.titled],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false  // the tests close it, and ARC holds it: a close must not release it once more
    window.contentViewController = browser
    return window
}

/// Runs `body` on a thread of its own, as Finder's promise queue would call the pane (whose promise method is
/// nonisolated and thread-safe).
private final class OffMainThread: @unchecked Sendable {
    private let body: () -> Void

    init(_ body: @escaping () -> Void) {
        self.body = body
    }

    func start() {
        Thread.detachNewThread { self.body() }
    }
}

/// Answers the sheet that comes up on `window`: sets its checkbox (if any) and clicks button `index` (0: the first).
/// Returns the sheet's message, or nil when none came up.
@MainActor
private func answerSheet(on window: NSWindow, button index: Int, checkbox: NSControl.StateValue? = nil) async -> String? {
    guard await eventually({ window.attachedSheet != nil }), let sheet = window.attachedSheet else { return nil }
    func views(_ view: NSView?) -> [NSView] { view.map { [$0] + $0.subviews.flatMap(views) } ?? [] }
    let all = views(sheet.contentView)
    if let checkbox, let box = all.compactMap({ $0 as? NSButton }).first(where: { $0.bezelStyle == .regularSquare || $0.title.hasPrefix("Do the same") || $0.title.hasPrefix("Compress") }) {
        box.state = checkbox
    }
    let message = all.compactMap { $0 as? NSTextField }.map(\.stringValue).first { !$0.isEmpty }
    window.endSheet(sheet, returnCode: NSApplication.ModalResponse(rawValue: NSApplication.ModalResponse.alertFirstButtonReturn.rawValue + index))
    return message
}

@MainActor @Test func sheetsAskAboutConflictsFoldersAndDeleting() async throws {
    _ = NSApplication.shared
    // Each sheet holds the main thread for about 0.3 s in AppKit: start after the other tests' busy first seconds
    // (SessionTests' killedMasterMeansDisconnectedAndNoFallbackPrompts reads a main-queue callback without waiting).
    try await Task.sleep(nanoseconds: 4_000_000_000)
    try await withServer { @MainActor server in
        var host = server.host()
        let local = try server.scratch()
        host.lastLocalDir = local
        try write("new a", to: local + "/a.txt")
        try write("new b", to: local + "/b.txt")
        try write("mine", to: local + "/notes.txt")
        try rawMkdir(local + "/site")
        try write("page", to: local + "/site/index.html")
        try write("old a", to: server.path("a.txt"))
        try write("old b", to: server.path("b.txt"))
        try write("theirs", to: server.path("NOTES.TXT"))
        let session = try await server.connectedSession(host)
        let browser = BrowserContentController(workspace: nil, session: session)
        let window = window(for: browser)
        defer { window.close() }
        browser.stateChanged(session.state)
        #expect(await eventually { browser.left.rows.count == 4 && browser.right.rows.count == 3 })

        // Both names exist on the server: Keep Both, and the same for the other one.
        browser.copyToOtherPane(browser.left.rows.filter { $0.name == "a.txt" || $0.name == "b.txt" }, from: browser.left)
        #expect(await answerSheet(on: window, button: 1, checkbox: .on) == "“a.txt” already exists in “home”.")
        #expect(await eventually { read(server.path("a 2.txt")) == "new a" && read(server.path("b 2.txt")) == "new b" })
        #expect(read(server.path("a.txt")) == "old a" && window.attachedSheet == nil)

        // A folder: the transfer sheet, here without compressing (scp -r).
        browser.copyToOtherPane(browser.left.rows.filter(\.isFolder), from: browser.left)
        #expect(await answerSheet(on: window, button: 0, checkbox: .off) == "Upload 1 folder to “home”?")
        #expect(await eventually { read(server.path("site/index.html")) == "page" })
        #expect(await eventually { browser.right.rows.map(\.name) == ["site", "a 2.txt", "a.txt", "b 2.txt", "b.txt", "NOTES.TXT"] })

        // This Mac's disk ignores case: NOTES.TXT meets notes.txt. Keep Both makes "NOTES 2.TXT".
        browser.copyToOtherPane(browser.right.rows.filter { $0.name == "NOTES.TXT" }, from: browser.right)
        #expect(await answerSheet(on: window, button: 1) == "“NOTES.TXT” already exists in “\(RemotePath.name(local))”.")
        #expect(await eventually { read(local + "/NOTES 2.TXT") == "theirs" } && read(local + "/notes.txt") == "mine")

        // Delete asks first (the Settings default).
        let doomed: Set<String> = ["site", "a 2.txt"]
        browser.right.table.selectRowIndexes(IndexSet(browser.right.rows.indices.filter { doomed.contains(browser.right.rows[$0].name) }),
                                             byExtendingSelection: false)
        browser.right.deleteItems(nil)
        #expect(await answerSheet(on: window, button: 0) == "Delete 2 items on “Test server”?")
        #expect(await eventually { !exists(server.path("site")) && !exists(server.path("a 2.txt")) })
        #expect(await eventually { browser.right.rows.map(\.name) == ["a.txt", "b 2.txt", "b.txt", "NOTES.TXT"] })

        // Another server on the left (here the same sshd under another saved host): a copy is one relay job in the
        // destination's queue, from the source host.
        let other = try await server.connectedSession(server.host())
        browser.chooseSource(.remote(other), for: browser.left)
        #expect(await eventually { browser.left.session === other && browser.left.dir == server.home })
        #expect(browser.transferTitle(for: browser.right).menu == "Copy to \(other.host.displayName) “home”")
        try rawMkdir(server.path("inbox"))
        browser.transfer(browser.right.rows.filter { $0.name == "b.txt" }, from: browser.right.source, to: browser.left.source,
                         into: server.path("inbox"), move: false)
        #expect(await eventually {
            other.transfers.jobs.contains { $0.direction == .relay && $0.names == ["b.txt"] && $0.sourceHostID == host.id
                && $0.source == server.home && $0.destination == server.path("inbox") }
        })
        browser.chooseSource(.local, for: browser.left)
        #expect(await eventually { browser.left.session == nil && browser.left.dir == local })
    }
}

/// Extract Here asks before replacing what is there: Extract to New Folder leaves it alone, Replace replaces it.
@MainActor @Test func extractHereAsksBeforeReplacing() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        let session = try await server.connectedSession()
        try write("NEW\n", to: server.path("index.html"))
        try write("other\n", to: server.path("other.txt"))
        let zip = try await session.compress(["index.html", "other.txt"], in: server.home, format: .zip)
        try FileManager.default.removeItem(atPath: server.path("other.txt"))
        try write("OLD\n", to: server.path("index.html"))
        let browser = BrowserContentController(workspace: nil, session: session)
        let window = window(for: browser)
        defer { window.close() }
        browser.stateChanged(session.state)
        #expect(await eventually { browser.right.rows.contains { $0.path == zip } })
        @MainActor func extractHere() {
            let rows = browser.right.rows
            browser.right.table.selectRowIndexes(IndexSet(rows.indices.filter { rows[$0].path == zip }), byExtendingSelection: false)
            browser.right.extractHere(nil)
        }
        extractHere()
        #expect(await answerSheet(on: window, button: 0) == "“index.html” already exists in “home”.")
        #expect(await eventually { read(server.path("Archive/index.html")) == "NEW\n" })
        #expect(read(server.path("index.html")) == "OLD\n" && !exists(server.path("other.txt")))
        await browser.right.reload()
        extractHere()
        #expect(await answerSheet(on: window, button: 1) == "“index.html” already exists in “home”.")
        #expect(await eventually { read(server.path("index.html")) == "NEW\n" && read(server.path("other.txt")) == "other\n" })
    }
}

/// Many files chosen at once (⌘A, a Finder drop) can go as one tar stream instead of an scp each (PLAN.md S): from
/// `TransferQueue.streamThreshold` items on, the transfer sheet offers "Compress during transfer", as for folders.
@MainActor @Test func manyChosenFilesGoAsOneStream() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        var host = server.host()
        let local = try server.scratch(), back = try server.scratch()
        host.lastLocalDir = local
        let count = TransferQueue.streamThreshold + 10
        for index in 0..<count { try write("file \(index)\n", to: local + "/f\(index).txt") }
        let session = try await server.connectedSession(host)
        let browser = BrowserContentController(workspace: nil, session: session)
        let window = window(for: browser)
        defer { window.close() }
        browser.stateChanged(session.state)
        #expect(await eventually { browser.left.rows.count == count && browser.right.dir == server.home })
        browser.copyToOtherPane(browser.left.rows, from: browser.left)
        #expect(await answerSheet(on: window, button: 0, checkbox: .on) == "Upload \(count) items to “home”?")
        #expect(await eventually { (0..<count).allSatisfy { read(server.path("f\($0).txt")) == "file \($0)\n" } })
        #expect(session.transfers.jobs.map(\.names.count) == [count])

        // And back into another folder here: one archive, unpacked.
        #expect(await browser.left.open(back))
        await session.transfers.waitUntilIdle()
        await browser.right.reload()
        #expect(browser.right.rows.count == count)
        browser.copyToOtherPane(browser.right.rows, from: browser.right)
        #expect(await answerSheet(on: window, button: 0, checkbox: .on) == "Download \(count) items to “\(RemotePath.name(back))”?")
        #expect(await eventually { (0..<count).allSatisfy { read(back + "/f\($0).txt") == "file \($0)\n" } })
        #expect(session.transfers.jobs.map(\.names.count) == [count, count])
        await session.transfers.waitUntilIdle()
        #expect(names(in: back).count == count)  // no archive or part file left
    }
}

/// Listings, Calculate Folder Sizes and Get Info run in the host's command lane, which the next listing waits for:
/// leaving the folder (or closing Get Info) stops what still waits or runs for it instead of letting it finish.
@MainActor @Test func leftWorkIsStoppedNotWaitedFor() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        let session = try await server.connectedSession()
        for name in ["a", "b"] { try rawMkdir(server.path(name)) }
        let pane = FilePane(source: .remote(session), choosesSource: false, showHidden: false)
        _ = pane.view
        #expect(await pane.open(server.home))
        /// The commands mentioning `text` that were stopped (SIGTERM, or cancelled before they ran).
        func stopped(_ text: String) async -> Bool {
            await eventually { (await server.logEntries()).contains { $0.command.contains(text) && $0.status == 128 + SIGTERM } }
        }
        func busy() -> Task<CommandResult, Error> { Task { try await session.run("sleep 1") } }

        // A listing left before it ran.
        var lane = busy()
        try await Task.sleep(nanoseconds: 200_000_000)
        let toA = Task { await pane.open(server.path("a")) }
        let toB = Task { await pane.open(server.path("b")) }
        let (wentToA, wentToB) = (await toA.value, await toB.value)
        #expect(!wentToA && wentToB && pane.dir == server.path("b"))
        #expect(await stopped(server.path("a") + "'"))
        _ = try await lane.value

        // Calculate Folder Sizes, then another folder.
        #expect(await pane.open(server.home))
        lane = busy()
        try await Task.sleep(nanoseconds: 200_000_000)
        pane.calculateFolderSizes(nil)
        #expect(await pane.open(server.path("a")))
        #expect(await stopped("$du --") && pane.folderSizes.isEmpty)
        _ = try await lane.value

        // Get Info, closed while it reads.
        let entry = try #require(try await session.list(server.home).first { $0.name == "b" })
        lane = busy()
        try await Task.sleep(nanoseconds: 200_000_000)
        let info = InfoModel(session: session, entry: entry)
        info.load()
        info.cancel()
        #expect(await stopped("file -b -h"))
        _ = try await lane.value
    }
}

/// Open (a server file in its app): a big file downloads through the transfer queue (progress and Cancel there, and
/// the browsing goes on), then opens; a small one opens at once.
@MainActor @Test func bigFilesOpenThroughTheTransferQueue() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        var host = server.host()
        host.lastLocalDir = try server.scratch()
        let session = try await server.connectedSession(host)
        try writeRandom(bytes: Int(BrowserContentController.openDirectlyLimit) + 1000, to: server.path("big.bin"))
        try write("small\n", to: server.path("small.txt"))
        let browser = filesTab(session)
        let opened = Recorder<URL>()
        browser.openFile = { opened.append($0) }
        #expect(await eventually { browser.right.rows.count == 2 })
        browser.openWithDefaultApp(browser.right.rows, on: session, from: browser.right)
        #expect(await eventually { opened.all.count == 2 })
        let big = try #require(opened.all.first { $0.lastPathComponent == "big.bin" })
        #expect(try Data(contentsOf: big) == Data(contentsOf: URL(fileURLWithPath: server.path("big.bin"))))
        #expect(read(try #require(opened.all.first { $0.lastPathComponent == "small.txt" }).path) == "small\n")
        #expect(session.transfers.jobs.map(\.source) == [server.path("big.bin")])
    }
}

// MARK: Session.copy, move, folderSizes and info from the panes

@MainActor @Test func copiesAndMovesWithinTheServer() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        var host = server.host()
        host.lastLocalDir = try server.scratch()
        try rawMkdir(server.path("sub"))
        try write("a", to: server.path("a.txt"))
        try write("b", to: server.path("b.txt"))
        let browser = filesTab(try await server.connectedSession(host))
        #expect(await eventually { browser.right.rows.map(\.name) == ["sub", "a.txt", "b.txt"] })
        let here = browser.right.source
        let a = try #require(browser.right.rows.first { $0.name == "a.txt" })
        let b = try #require(browser.right.rows.first { $0.name == "b.txt" })
        browser.transfer([a], from: here, to: here, into: server.path("sub"), move: false)
        #expect(await eventually { read(server.path("sub/a.txt")) == "a" && read(server.path("a.txt")) == "a" })
        browser.transfer([b], from: here, to: here, into: server.path("sub"), move: true)
        #expect(await eventually { read(server.path("sub/b.txt")) == "b" && !exists(server.path("b.txt")) })
        // A copy into its own folder goes beside it, as Finder's Duplicate does.
        browser.transfer([a], from: here, to: here, into: server.home, move: false)
        #expect(await eventually { read(server.path("a 2.txt")) == "a" })
        #expect(await eventually { browser.right.rows.map(\.name) == ["sub", "a 2.txt", "a.txt"] })
        #expect(browser.right.lastError == nil)
    }
}

@MainActor @Test func calculatedFolderSizesFillTheSizeColumn() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        let session = try await server.connectedSession()
        try rawMkdir(server.path("site"))
        try writeRandom(bytes: 300_000, to: server.path("site/data.bin"))
        let pane = FilePane(source: .remote(session), choosesSource: false, showHidden: false)
        _ = pane.view
        #expect(await pane.open(server.home))
        pane.calculateFolderSizes(nil)
        #expect(await eventually { (pane.folderSizes["site"] ?? 0) >= 300_000 })
        let column = try #require(pane.table.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier("size")))
        let cell = pane.tableView(pane.table, viewFor: column, row: 0) as? NSTableCellView
        #expect(cell?.textField?.stringValue == FileList.size(pane.folderSizes["site"] ?? 0))
        #expect(pane.lastError == nil)
    }
}

@MainActor @Test func getInfoReadsTheServerAndChangesPermissions() async throws {
    try await withServer { @MainActor server in
        let session = try await server.connectedSession()
        try rawMkdir(server.path("box"))
        try write("one", to: server.path("box/1.txt"))
        try write("two", to: server.path("box/2.txt"))
        let box = try #require(try await session.list(server.home).first { $0.name == "box" })
        let info = InfoModel(session: session, entry: box)
        info.load()
        #expect(await eventually { !info.loading })
        #expect(info.failure == nil && info.info?.itemCount == 2 && (info.info?.size ?? 0) > 0)
        info.mode = 0o700
        info.applyPermissions()
        #expect(await eventually { !info.loading && info.appliedMode == 0o700 })
        var status = stat()
        #expect(lstat(server.path("box"), &status) == 0 && status.st_mode & 0o777 == 0o700)
    }
}

/// The host's start folder: kept across reconnects while it is the same, applied at the next connect once edited, and
/// when it can't be opened, the home folder is shown with the reason in the status line.
@MainActor @Test func theStartFolderAppliesWhenEditedAndSaysWhenItCantBeOpened() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        try write("x", to: server.path("one/a.txt"))
        try write("y", to: server.path("two/b.txt"))
        var host = server.host()
        host.defaultRemoteDir = server.path("one")
        let session = try await server.connectedSession(host)
        let pane = try #require(filesTab(session).right)  // (its view's load, then the state: two connect calls)
        pane.connectionChanged(.connected, startIn: server.path("one"))  // one more, before any listing is done
        // The start folder, not the home folder a listing that another took over fell back to. (60 s: the main queue,
        // which lists the panes, is busy at the suite's start.)
        #expect(await eventually { pane.dir == server.path("one") && pane.activities.isEmpty }, "\(pane.dir ?? "")")
        #expect(!pane.statusLabel.stringValue.contains("the start folder"))
        await pane.open(server.path("two"))  // where the user went
        pane.connectionChanged(.connected, startIn: server.path("one"))  // reconnected, the same start folder
        #expect(await eventually { pane.dir == server.path("two") && pane.activities.isEmpty })
        pane.connectionChanged(.connected, startIn: "/no/such/dir")  // edited meanwhile
        #expect(await eventually { pane.dir == server.home && pane.statusLabel.stringValue.contains("the start folder") },
                "\(pane.dir ?? "") \(pane.statusLabel.stringValue)")
        #expect(pane.statusLabel.stringValue.contains("the start folder /no/such/dir can't be opened"))
    }
}
