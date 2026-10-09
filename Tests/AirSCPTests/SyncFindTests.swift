import AppKit
import Darwin
import Foundation
import Testing
@testable import AirSCP
@testable import AirSCPCore

// PLAN.md S.1: Find Files and Synchronize. Without a server: the comparison of times and what a plan does in each
// direction. Against throwaway sshd servers (a shell, and sftp only): searching, comparing and synchronizing.

/// Sets a file's modification time (and access time) to `time` seconds since 1970.
private func touch(_ path: String, _ time: TimeInterval) {
    var times = [timeval(tv_sec: Int(time), tv_usec: 0), timeval(tv_sec: Int(time), tv_usec: 0)]
    _ = lutimes(path, &times)
}

private func file(_ name: String, size: Int64 = 1, modified: TimeInterval, in dir: String = "/mac") -> FileItem {
    FileItem(local: name, path: dir + "/" + name, kind: .file, size: size, modified: Date(timeIntervalSince1970: modified),
             mode: 0o644, owner: "me", group: "staff")
}

private func remote(_ name: String, _ kind: RemoteEntry.Kind = .file, size: Int64 = 1, modified: TimeInterval,
                    in dir: String = "/srv") -> FileItem {
    FileItem(RemoteEntry(name: name, path: dir + "/" + name, kind: kind, size: size,
                         modified: Date(timeIntervalSince1970: modified), permissions: "rw-r--r--", mode: 0o644,
                         owner: "dev", group: "dev"))
}

@Test func syncComparesTimesAtTheListingsPrecision() {
    let now = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 14:13 UTC
    func order(_ mine: TimeInterval, _ theirs: TimeInterval, dateOnly: Bool = false) -> ComparisonResult {
        Sync.order(Date(timeIntervalSince1970: mine), Date(timeIntervalSince1970: theirs), dateOnly: dateOnly)
    }
    let minute = 1_789_990_000.0 - 1_789_990_000.0.truncatingRemainder(dividingBy: 60)
    // Within the minute ls shows: the same; a minute later: not.
    #expect(order(minute + 59, minute) == .orderedSame)
    #expect(order(minute + 60, minute) == .orderedDescending)
    #expect(order(minute - 1, minute) == .orderedAscending)
    // A day only (over six months ago; its midnight in UTC): any time that day, in UTC or here, is the same.
    let day = 1_579_046_400.0  // 2020-01-15 00:00 UTC
    #expect(order(day + 49_510, day, dateOnly: true) == .orderedSame)
    #expect(order(day + 86_400 + 15 * 3600, day, dateOnly: true) == .orderedDescending)
    #expect(order(day - 15 * 3600, day, dateOnly: true) == .orderedAscending)
    // A day only that is today (a time after the server's clock): the Mac's file from today is of that day too, so an
    // identical copy isn't copied again (`plan` takes the server's as the newer when they differ). It was compared to
    // the minute as midnight.
    let today = 1_789_948_800.0
    #expect(order(now.timeIntervalSince1970 - 3600, today, dateOnly: true) == .orderedSame)
    // A midnight to the minute is just that minute.
    #expect(order(today + 600, today) == .orderedDescending)
    #expect(Sync.order(nil, Date(timeIntervalSince1970: day)) == .orderedSame)
}

/// Both ways (and This Mac → server) uploaded an older Mac copy over a server file whose time was after the server's
/// clock (ls showed it with its year): the server's is the newer.
@Test func syncNeverReplacesAServerFileDatedAfterItsClock() {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let mac = file("ahead.txt", size: 30, modified: 1_790_000_000 - 3600)
    let server = FileItem(RemoteEntry(name: "ahead.txt", path: "/srv/ahead.txt", kind: .file, size: 34,
                                      modified: Date(timeIntervalSince1970: 1_789_948_800), permissions: "rw-r--r--",
                                      mode: 0o644, owner: "dev", group: "dev", dateOnly: true))
    let difference = Sync.Difference(localFolder: "/mac", remoteFolder: "/srv", local: mac, remote: server, path: "ahead.txt")
    let both = Sync.plan([difference], direction: .both, delete: false, now: now)
    #expect(both.steps.map(\.action) == [.download] && both.steps.first?.replaces == true)
    let up = Sync.plan([difference], direction: .upload, delete: false, now: now)
    #expect(up.steps.isEmpty && up.leftAsIs == 1)
}

@Test func syncPlansEachDirection() {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let old = 1_789_899_960.0, new = 1_789_949_940.0  // whole minutes, as listings show them
    func difference(_ local: FileItem?, _ remote: FileItem?) -> Sync.Difference {
        Sync.Difference(localFolder: "/mac", remoteFolder: "/srv", local: local, remote: remote,
                        path: (local ?? remote)!.name)
    }
    let differences = [
        difference(file("only-here.txt", modified: old), nil),
        difference(nil, remote("only-there.txt", modified: old)),
        difference(file("newer-here.txt", modified: new), remote("newer-here.txt", modified: old)),
        difference(file("newer-there.txt", modified: old), remote("newer-there.txt", modified: new)),
        difference(file("same-time.txt", size: 5, modified: old), remote("same-time.txt", size: 9, modified: old)),
        difference(file("kinds", modified: old), remote("kinds", .directory, modified: old)),
    ]
    func steps(_ plan: Sync.Plan) -> [String] {
        plan.steps.map { step in
            let verb: String
            switch step.action {
            case .upload: verb = "up"
            case .download: verb = "down"
            case .deleteHere: verb = "trash"
            case .deleteThere: verb = "delete"
            }
            return "\(verb) \(step.path)\(step.replaces ? " (replaces)" : "") → \(step.destination)"
        }
    }

    let up = Sync.plan(differences, direction: .upload, delete: false, now: now)
    #expect(steps(up) == ["up only-here.txt → /srv/only-here.txt", "up newer-here.txt (replaces) → /srv/newer-here.txt",
                          "up same-time.txt (replaces) → /srv/same-time.txt"])
    #expect(up.leftAsIs == 2)  // newer on the server, and a file against a folder
    let mirror = Sync.plan(differences, direction: .upload, delete: true, now: now)
    #expect(steps(mirror).contains("delete only-there.txt → ") && mirror.steps.count == 4)

    let down = Sync.plan(differences, direction: .download, delete: true, now: now)
    #expect(steps(down) == ["trash only-here.txt → ", "down only-there.txt → /mac/only-there.txt",
                            "down newer-there.txt (replaces) → /mac/newer-there.txt",
                            "down same-time.txt (replaces) → /mac/same-time.txt"])
    #expect(down.leftAsIs == 2)

    let both = Sync.plan(differences, direction: .both, delete: true, now: now)  // (no deleting both ways)
    #expect(steps(both) == ["up only-here.txt → /srv/only-here.txt", "down only-there.txt → /mac/only-there.txt",
                            "up newer-here.txt (replaces) → /srv/newer-here.txt",
                            "down newer-there.txt (replaces) → /mac/newer-there.txt"])
    #expect(both.leftAsIs == 2)  // the same time with another size, and a file against a folder
}

/// Find Files at "/" named the folder “” ("Nothing found below “”."). A search stopped at once takes in no matches
/// that come later; one that ends shows its matches in order.
@MainActor @Test func findFilesNamesTheRootAndStopsCleanly() async throws {
    try await withServer { @MainActor server in
        let session = try await server.connectedSession()
        #expect(FindModel(session: session, dir: "/").folder == session.host.displayName)
        try write("x", to: server.path("proj/a-report.txt"))
        let model = FindModel(session: session, dir: server.path("proj"))
        model.pattern = "report"
        model.start()
        model.stop()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(model.status == "Stopped." && model.results.isEmpty && !model.searching)
        model.start()
        #expect(await eventually { !model.searching })
        #expect(model.results.map(\.path) == [server.path("proj/a-report.txt")] && model.status == "1 found.", "\(model.status)")
    }
}

@Test func findFilesSearchesBelowTheFolderWithAndWithoutAShell() async throws {
    for sftpOnly in [false, true] {
        try await withServer(TestServer.Options(sftpOnly: sftpOnly)) { server in
            let session = try await server.connectedSession()
            let root = server.path("proj")
            try write("x", to: root + "/Report.TXT")
            try write("x", to: root + "/sub/deep/report-2024.txt")
            try write("x", to: root + "/notes.md")
            try rawMkdir(root + "/reports")
            try write("x", to: root + "/it's \"quoted\" report.txt")
            try write("x", to: root + "/.hidden-report")
            if !sftpOnly { try write("x", to: root + "/line\nbreak report.txt") }  // sftp's listing can't show it

            // The matches also come as they are found (they showed only once the search had ended, and Stop lost them).
            let streamed = Recorder<FoundItem>()
            let (found, truncated) = try await session.find("*report*", in: root) { items in items.forEach(streamed.append) }
            #expect(Set(streamed.all.map(\.path)) == Set(found.map(\.path)) && streamed.all.count == found.count, "sftp only: \(sftpOnly)")
            var expected = [".hidden-report", "it's \"quoted\" report.txt", "Report.TXT", "reports", "sub/deep/report-2024.txt"]
            if !sftpOnly { expected.append("line\nbreak report.txt") }
            #expect(Set(found.map { String($0.path.dropFirst(root.count + 1)) }) == Set(expected), "sftp only: \(sftpOnly)")
            #expect(found.filter(\.isFolder).map(\.path) == [root + "/reports"] && !truncated)
            #expect(try await session.find("*.TXT", in: root + "/sub").items.map(\.path) == [root + "/sub/deep/report-2024.txt"])
            #expect(try await session.find("nothing*", in: root).items.isEmpty)
            let (some, more) = try await session.find("*", in: root, limit: 3)
            #expect(some.count == 3 && more)
            await #expect(throws: AirSCPError.self) { try await session.find("*", in: root + "/missing") }
        }
    }
}

/// The Files tab of a connected session, without a workspace window (`workspace: nil`), its panes listed.
@MainActor
private func filesTab(_ session: Session) async -> BrowserContentController {
    let browser = BrowserContentController(workspace: nil, session: session)
    _ = browser.view
    browser.stateChanged(session.state)
    _ = await eventually { browser.left.dir != nil && browser.right.dir != nil }
    return browser
}

@MainActor @Test func synchronizeMakesTheFoldersTheSameAndThenFindsNothing() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        var host = server.host()
        let local = try server.scratch(), there = server.path("site")
        host.lastLocalDir = local
        let earlier = Date().timeIntervalSince1970 - 3_600, ancient = 1_579_096_510.0  // 2020-01-15 13:55:10 UTC
        // This Mac: new files and folders, one changed since, the same files, one older than the server's.
        try write("new", to: local + "/new.txt")
        try write("changed here", to: local + "/changed.txt")
        try write("same", to: local + "/same.txt")
        touch(local + "/same.txt", earlier)
        try write("old", to: local + "/ancient.txt")
        touch(local + "/ancient.txt", ancient)
        try write("inner", to: local + "/sub/inner.txt")
        try write("deep", to: local + "/newdir/deeper/x.txt")
        try write("older", to: local + "/theirs-newer.txt")
        touch(local + "/theirs-newer.txt", earlier - 600)
        try write("x", to: local + "/.DS_Store")
        try FileManager.default.createSymbolicLink(atPath: local + "/link", withDestinationPath: "same.txt")
        // The server: the same, older, newer and extra items.
        try write("changed", to: there + "/changed.txt")
        touch(there + "/changed.txt", earlier)
        try write("same", to: there + "/same.txt")
        touch(there + "/same.txt", earlier)
        try write("old", to: there + "/ancient.txt")
        touch(there + "/ancient.txt", ancient)
        try rawMkdir(there + "/sub")
        try write("extra", to: there + "/only-there.txt")
        try write("y", to: there + "/olddir/y.txt")
        try write("newer on the server", to: there + "/theirs-newer.txt")
        try write("part", to: there + "/.airscp-12345678.part")

        let session = try await server.connectedSession(host)
        let browser = await filesTab(session)
        await browser.right.open(there)
        #expect(browser.synchronizedPanes?.local === browser.left && browser.synchronizedPanes?.remote === browser.right)

        let comparison = try await Sync.compare(local: local, remote: there, on: session) { _ in }
        #expect(comparison.differences.map(\.path) == ["changed.txt", "new.txt", "newdir", "olddir", "only-there.txt",
                                                        "sub/inner.txt", "theirs-newer.txt"])
        #expect(comparison.leftOut == 1 && comparison.folders == 2)  // the link; this folder and sub
        let plan = Sync.plan(comparison.differences, direction: .upload, delete: true)
        #expect(plan.steps.count == 6 && plan.leftAsIs == 1)  // theirs-newer.txt stays
        browser.apply(plan, on: session)
        #expect(await eventually { !exists(there + "/only-there.txt") && !exists(there + "/olddir") })
        await session.transfers.waitUntilIdle()
        #expect(read(there + "/new.txt") == "new" && read(there + "/changed.txt") == "changed here")
        #expect(read(there + "/sub/inner.txt") == "inner" && read(there + "/newdir/deeper/x.txt") == "deep")
        #expect(read(there + "/theirs-newer.txt") == "newer on the server" && exists(there + "/.airscp-12345678.part"))

        // Times were kept: comparing again finds only what was left as it is.
        let again = try await Sync.compare(local: local, remote: there, on: session) { _ in }
        #expect(again.differences.map(\.path) == ["theirs-newer.txt"], "\(again.differences.map(\.path))")
        // Both ways: the server's newer file comes down; then the folders are the same.
        let both = Sync.plan(again.differences, direction: .both, delete: false)
        #expect(both.steps.map(\.action) == [.download])
        browser.apply(both, on: session)
        await session.transfers.waitUntilIdle()
        #expect(read(local + "/theirs-newer.txt") == "newer on the server")
        #expect(try await Sync.compare(local: local, remote: there, on: session) { _ in }.differences.isEmpty)

        // The other way with deleting: an item only on this Mac goes to the Trash.
        let trashed = "airscp-sync-\(UUID().uuidString.prefix(8)).txt"
        try write("mine", to: local + "/" + trashed)
        try write("theirs", to: there + "/fresh.txt")
        let down = Sync.plan(try await Sync.compare(local: local, remote: there, on: session) { _ in }.differences,
                             direction: .download, delete: true)
        #expect(down.steps.map(\.path) == [trashed, "fresh.txt"])
        browser.apply(down, on: session)
        await session.transfers.waitUntilIdle()
        #expect(await eventually { !exists(local + "/" + trashed) } && read(local + "/fresh.txt") == "theirs")
        if let trash = try? FileManager.default.url(for: .trashDirectory, in: .userDomainMask, appropriateFor: nil, create: false) {
            try? FileManager.default.removeItem(at: trash.appendingPathComponent(trashed))
        }
    }
}

/// The host's Leave out patterns: what matches is neither compared (a folder that matches isn't listed), copied nor
/// deleted, also inside a folder copied whole; other patterns compare again. Unticked items are neither copied nor
/// deleted, and the summary counts and adds up only the ticked ones.
@MainActor @Test func synchronizeLeavesOutWhatMatchesAndDoesOnlyTheTickedItems() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        var host = server.host()
        let local = try server.scratch(), there = server.path("site")
        host.lastLocalDir = local
        for path in ["keep.txt", "debug.log", "node_modules/x/index.js", "sub/c.txt", "sub/trace.log", "newdir/a.txt",
                     "newdir/b.log", "skip-me.txt"] {
            try write(path == "keep.txt" ? "keep" : "x", to: local + "/" + path)
        }
        for path in ["node_modules/y.js", "old.log", "stale.txt", "gone.txt"] { try write("gone", to: there + "/" + path) }
        try rawMkdir(there + "/sub")
        let session = try await server.connectedSession(host)
        let browser = await filesTab(session)

        let model = SyncModel(session: session, localDir: local, remoteDir: there, leaveOut: "*.log, node_modules/")
        model.delete = true
        model.compare()
        #expect(await eventually { model.comparison != nil })
        #expect(model.patterns == ["*.log", "node_modules"] && model.comparison?.folders == 2)  // not node_modules
        #expect(model.plan.steps.map(\.path) == ["gone.txt", "keep.txt", "newdir", "skip-me.txt", "stale.txt", "sub/c.txt"],
                "\(model.plan.steps.map(\.path))")
        model.unticked = ["skip-me.txt", "stale.txt"]
        #expect(model.chosen.steps.map(\.path) == ["gone.txt", "keep.txt", "newdir", "sub/c.txt"])
        #expect(model.summary.hasPrefix("3 uploads (\(FileList.size(5)) and 1 folder), 1 deletion on \(model.server) "
                                        + "(\(FileList.size(4)))\n2 unticked: left as they are."), "\(model.summary)")
        browser.apply(model.chosen, on: session, excluding: model.patterns)
        await session.transfers.waitUntilIdle()
        #expect(await eventually { !exists(there + "/gone.txt") })
        #expect(files(below: there) == ["keep.txt", "newdir/a.txt", "node_modules/y.js", "old.log", "stale.txt", "sub/c.txt"],
                "\(files(below: there))")

        // The same patterns as typed otherwise: the plan stays. Others: compared again (the unticked stay unticked).
        model.leaveOut = "*.log,node_modules"
        #expect(model.comparison != nil)
        model.leaveOut = "node_modules"
        #expect(model.comparison == nil && model.chosen.steps.isEmpty)  // Synchronize is off until then
        #expect(await eventually { model.comparison != nil })
        #expect(model.plan.steps.map(\.path) == ["debug.log", "newdir/b.log", "old.log", "skip-me.txt", "stale.txt", "sub/trace.log"],
                "\(model.plan.steps.map(\.path))")
        #expect(model.chosen.steps.map(\.path) == ["debug.log", "newdir/b.log", "old.log", "sub/trace.log"])
        model.unticked = Set(model.plan.steps.map(\.path))  // Select None
        #expect(model.chosen.steps.isEmpty && model.summary.hasPrefix("Nothing ticked.\n6 unticked: left as they are."),
                "\(model.summary)")
    }
}

/// The commands' menu items: on when the panes allow them, else off with the reason.
@MainActor @Test func synchronizeAndFindFilesNeedTheirPanes() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        try write("x", to: server.path("dir/.secret"))
        var host = server.host()
        host.lastLocalDir = try server.scratch()
        let session = try await server.connectedSession(host)
        let browser = await filesTab(session)
        #expect(browser.left.check(#selector(FilePane.synchronize(_:)), for: []).0)
        #expect(browser.right.check(#selector(FilePane.findFiles(_:)), for: []).0)
        let local = browser.left.check(#selector(FilePane.findFiles(_:)), for: [])
        #expect(!local.0 && local.1 == "Find Files searches a server's folders.")
        // Show: the item's folder, the item selected (hidden files shown for a hidden one).
        #expect(!browser.right.showHidden)
        browser.right.reveal(server.path("dir/.secret"))
        #expect(await eventually { browser.right.dir == server.path("dir") && browser.right.selectedItems.map(\.name) == [".secret"] })
        #expect(browser.right.showHidden)
        // Another server on the left: nothing on this Mac to compare.
        let other = try await server.connectedSession(server.host())
        browser.chooseSource(.remote(other), for: browser.left)
        #expect(await eventually { browser.left.session === other && browser.left.dir != nil })
        let both = browser.right.check(#selector(FilePane.synchronize(_:)), for: [])
        #expect(!both.0 && both.1?.hasPrefix("Synchronize compares a folder on this Mac") == true)
    }
}
