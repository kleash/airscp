import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AirSCP
@testable import AirSCPCore

// MARK: Disk Usage

/// du's records (GNU's NUL-separated, the others' one per line) make the tree: a folder's record is its total and is
/// passed over, sizes add up, the folder's own items count as reached; taking an item off takes its size off above.
@MainActor @Test func diskUsageBuildsTheTreeFromDu() throws {
    let gnu = "5\t./a/x.bin\u{0}7\t./a/sub/y.bin\u{0}9\t./a/sub\u{0}20\t./a\u{0}3\t./b.txt\u{0}23\t.\u{0}"
    let bsd = "1\t./a/x.bin\n2\t./a/sub/y.bin\n2\t./a/sub\n3\t./a\n4\t./b.txt\n7\t.\n"
    for (output, unit, separator, sizes, largest) in [(gnu, Int64(1), UInt8(0), (Int64(5), Int64(7), Int64(3)), ["y.bin", "x.bin"]),
                                                       (bsd, 1024, 0x0A, (1024, 2048, 4096), ["b.txt", "y.bin"])] {
        let usage = DiskUsage(path: "/srv")
        usage.expected = 2
        usage.add(DiskUsage.parse(Data(output.utf8), unit: unit, separator: separator))
        let root = usage.root
        #expect(root.path == "/srv" && root.files == 3 && root.size == sizes.0 + sizes.1 + sizes.2)
        #expect(usage.reached == 2 && usage.latest == "b.txt")
        let a = try #require(root.children.first { $0.name == "a" })
        #expect(a.isFolder && a.size == sizes.0 + sizes.1 && a.files == 2 && a.path == "/srv/a")
        let sub = try #require(a.children.first)
        #expect(sub.isFolder && sub.children.map(\.path) == ["/srv/a/sub/y.bin"])
        #expect(root.largestFiles(2).map(\.name) == largest)
        sub.remove()
        #expect(a.size == sizes.0 && a.files == 1 && root.size == sizes.0 + sizes.2 && root.files == 2)
        #expect(a.children.map(\.name) == ["x.bin"])
        // Emptied: still listed, at 0 bytes, its size out of the folders above.
        let x = try #require(a.children.first)
        x.empty()
        #expect(x.size == 0 && a.children.map(\.name) == ["x.bin"] && a.size == 0 && root.size == sizes.2 && root.files == 2)
    }
    // The rings: each item's arc is its share of the one it is in, nested.
    let usage = DiskUsage(path: "/")
    usage.add([.init(path: "big/one", size: 60, folder: false), .init(path: "big/two", size: 20, folder: false),
               .init(path: "small", size: 20, folder: false)])
    let rings = DiskUsageModel.segments(of: usage.root)
    #expect(rings.map { "\($0.item.name) \($0.depth) \($0.start) \($0.end)" }
            == ["big 0 0.0 0.8", "one 1 0.0 0.6", "two 1 0.6 0.8", "small 0 0.8 1.0"])
}

/// This Mac: every file below, its folders (an empty one too), sizes as the files' own.
@Test func diskUsageScansAFolderOnThisMac() throws {
    let dir = try scratch()
    try write(String(repeating: "x", count: 1_000), to: dir + "/logs/app.log")
    try write("abc", to: dir + "/logs/deep/old.log")
    try write("hi", to: dir + "/.hidden")
    try FileManager.default.createDirectory(atPath: dir + "/empty", withIntermediateDirectories: true)
    let usage = DiskUsage(path: dir)
    try DiskUsage.scan(dir) { records, expected in
        usage.expected = expected
        usage.add(records)
    }
    #expect(usage.root.size == 1_005 && usage.root.files == 3)
    #expect(usage.expected == 3 && usage.reached == 3)
    #expect(usage.root.children.map(\.name) == ["logs", ".hidden", "empty"])
    #expect(usage.root.children.last?.isFolder == true)
    #expect(usage.root.largestFiles(10).map(\.path) == [dir + "/logs/app.log", dir + "/logs/deep/old.log", dir + "/.hidden"])
}

/// A server: one du, its records as they come (names as they are: "café"), the folder's own items counted.
@Test func diskUsageScansAServerFolder() async throws {
    try await withServer { server in
        try write(String(repeating: "x", count: 5_000), to: server.path("du/big.bin"))
        try write("small", to: server.path("du/sub/small.txt"))
        try write("odd", to: server.path("du/café with spaces/it's.txt"))
        let session = try await server.connectedSession()
        final class Found: @unchecked Sendable {  // filled on one background thread, read after the scan
            var records: [DiskUsage.Record] = []
            var expected = 0
        }
        let found = Found()
        try await session.diskUsage(of: server.path("du")) { records, expected in
            found.records += records
            found.expected = expected
        }
        let usage = DiskUsage(path: server.path("du"))
        usage.add(found.records)
        #expect(found.expected == 3 && usage.reached == 3)
        #expect(usage.root.files == 3)
        #expect(usage.root.children.first?.name == "big.bin")
        let largest = usage.root.largestFiles(5).map(\.path)
        #expect(largest.first == server.path("du/big.bin")
                && Set(largest) == [server.path("du/big.bin"), server.path("du/sub/small.txt"), server.path("du/café with spaces/it's.txt")])
        // Sizes in kilobytes from macOS's du: at least the bytes, at most a block more each.
        #expect(usage.root.size >= 5_008 && usage.root.size <= 5_008 + 3 * 4096)
    }
}

/// The window from File ▸ Disk Usage… on a server's folder: the scan ends with the items largest first; the same
/// command again brings that window forward; Delete… asks (naming the host), deletes on the server and takes the item's
/// size off; closing the window lets it go.
@MainActor @Test func diskUsageWindowScansAndDeletesOnAServer() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        var host = server.host()
        host.label = "lab"
        try write(String(repeating: "x", count: 50_000), to: server.path("du/big/one.bin"))
        try write("small", to: server.path("du/small.txt"))
        let model = testModel([host])
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        @MainActor func windows() -> [DiskUsageWindow] { DiskUsageWindow.open.values.filter { $0.model.dir == server.path("du") } }
        let (main, agent, _) = try agentWindow(model, askpass, windows: { windows().compactMap(\.window) })
        defer {
            agent.close()
            main.window?.orderOut(nil)
        }
        _ = await call(agent, "select", ["pane": "sidebar", "names": ["lab"]])
        _ = await call(agent, "menu", ["path": "Host > Connect"])
        #expect(await call(agent, "wait", ["until": "connected", "timeout": 30]).error == nil)
        _ = await call(agent, "go", ["path": server.path("du")])
        #expect(await call(agent, "menu", ["path": "File > Disk Usage…"]).error == nil)
        let window = try #require(windows().first)
        window.window?.setFrameOrigin(NSPoint(x: -21000, y: -21000))
        defer { window.close() }
        #expect(window.window?.title == "Disk Usage — du on lab" && main.window?.attachedSheet == nil)
        let usage = window.model
        #expect(await eventually { !usage.scanning })
        #expect(usage.status.hasPrefix("Scanned 2 files in"), "\(usage.status)")
        #expect(usage.rows.map(\.name) == ["big", "small.txt"] && usage.segments.count == 3)
        #expect(await call(agent, "menu", ["path": "File > Disk Usage…"]).error == nil)
        #expect(windows().count == 1 && !usage.scanning)
        let big = usage.rows[0].item
        #expect(usage.open(big) && usage.rows.map(\.name) == ["one.bin"] && usage.trail.map(\.name) == ["du", "big"])
        usage.goBack()
        #expect(usage.folder === usage.usage?.root && usage.back.isEmpty)
        usage.selection = [big.id]
        // Once the window has drawn the selection (Delete… is enabled then).
        var asked = Reply()
        #expect(await eventually(timeout: 10) {
            asked = await call(agent, "press", ["id": "diskUsage.delete"])
            return asked.error == nil
        })
        #expect((sheet(asked)?["title"] as? String)?.contains("on “lab”") == true, "\(asked.error ?? "") \(asked.json)")
        #expect(await call(agent, "press", ["title": "Delete"]).error == nil)
        #expect(await eventually { !rawExists(server.path("du/big")) })
        #expect(await eventually { usage.rows.map(\.name) == ["small.txt"] && usage.folder?.files == 1 })
        window.close()
        #expect(windows().isEmpty)
        await main.selectedWorkspace?.connection.disconnect()
    }
}

/// This Mac's folder scanned twice: By Type adds up the extensions and lists a type's largest files; the scan's record
/// keeps the folders and the files of 1 MB and more; the second scan's Changes lists what grew, the most first; Export
/// as CSV quotes what needs it.
@MainActor @Test func diskUsageAddsUpTypesComparesScansAndExportsCSV() async throws {
    let dir = try scratch(), records = URL(fileURLWithPath: try scratch())
    let mb = 1 << 20
    try write(String(repeating: "x", count: 2 * mb), to: dir + "/logs/app.log")
    try write(String(repeating: "x", count: 3 * mb / 2), to: dir + "/logs/old.LOG")
    try write("0123456789", to: dir + "/a,b \"q\".txt")
    try write("abc", to: dir + "/README")
    let model = DiskUsageModel(session: nil, dir: dir, records: records)
    model.start()
    #expect(await eventually { !model.scanning })
    #expect(model.status.hasPrefix("Scanned 4 files in"), "\(model.status)")
    let saved = try #require(DiskUsageRecord.load(from: model.recordFile))
    #expect(model.recordFile.path.hasPrefix(records.path + "/disk-usage/this-mac/"))
    let expected: [String: Int64] = ["": Int64(7 * mb / 2 + 13), "logs": Int64(7 * mb / 2), "logs/app.log": Int64(2 * mb),
                                     "logs/old.LOG": Int64(3 * mb / 2)]
    #expect(saved.sizes == expected)
    let root = try #require(model.usage?.root)
    #expect(model.previous == nil && model.change(of: root) == nil)

    model.shown = .types
    let types = model.types.map { "\($0.title) \($0.size) \($0.files)" }
    #expect(types == [".log \(7 * mb / 2) 2", ".txt 10 1", "No extension 3 1"])
    model.showLargest(ofType: "log")
    #expect(model.shown == .largest && model.rows.map(\.name) == ["logs/app.log", "logs/old.LOG"])
    model.shown = .contents
    #expect(model.onlyType == nil && model.rows.map(\.name) == ["logs", "a,b \"q\".txt", "README"])
    model.search = "read"
    #expect(model.rows.map(\.name) == ["README"])
    model.search = ""

    let csv = model.csv()
    #expect(csv.hasPrefix("Path,Size (bytes),Files,Share\r\n\(dir)/logs,\(7 * mb / 2),2,"))
    #expect(csv.contains("\r\n\"\(dir)/a,b \"\"q\"\".txt\",10,1,0.0000\r\n"))
    #expect(DiskUsageModel.csvField("plain") == "plain" && DiskUsageModel.csvField("two\nlines") == "\"two\nlines\"")

    // What changed: app.log grew by 1 MB, old.LOG went, new.bin (2 MB) came.
    try write(String(repeating: "x", count: 3 * mb), to: dir + "/logs/app.log")
    try FileManager.default.removeItem(atPath: dir + "/logs/old.LOG")
    try write(String(repeating: "x", count: 2 * mb), to: dir + "/logs/new.bin")
    model.start()
    #expect(await eventually { !model.scanning })
    #expect(model.previous?.date == saved.date)
    model.shown = .changes
    let changes = model.rows.map { "\($0.name) \($0.growth)" }
    #expect(changes == ["logs/new.bin \(2 * mb)", "logs \(3 * mb / 2)", "logs/app.log \(mb)"])
    let again = try #require(model.usage?.root)
    #expect(model.change(of: again) == Int64(3 * mb / 2))
    #expect(DiskUsageRecord.load(from: model.recordFile)?.sizes["logs/new.bin"] == Int64(2 * mb))

    // A deleted host's records go with it.
    let host = UUID(), file = DiskUsageRecord.file(host: host, dir: "/srv", folder: records)
    saved.save(to: file)
    #expect(FileManager.default.fileExists(atPath: file.path))
    DiskUsageRecord.forget(host: host, folder: records)
    #expect(!FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path))
}

/// One window per folder: Disk Usage of the same folder again brings it forward; closing it stops the scan and lets it
/// go. Download's archive holds the items' paths below the folder they share.
@MainActor @Test func diskUsageOpensOneWindowPerFolder() async throws {
    _ = NSApplication.shared
    let dir = try scratch()
    try write("hi", to: dir + "/a.txt")
    let first = DiskUsageWindow.show(dir, on: nil, from: nil)
    first.window?.setFrameOrigin(NSPoint(x: -21000, y: -21000))
    #expect(DiskUsageWindow.show(dir, on: nil, from: nil) === first)
    #expect(first.window?.title == "Disk Usage — \(RemotePath.name(dir)) on This Mac" && first.window?.isVisible == true)
    first.close()
    #expect(DiskUsageWindow.open.values.allSatisfy { $0 !== first } && !first.model.scanning)
    #expect(DiskUsageWindow.commonFolder(["/a/b/c.txt", "/a/b/d/e.txt"]) == "/a/b")
    #expect(DiskUsageWindow.commonFolder(["/x/1", "/y/2"]) == "/" && DiskUsageWindow.commonFolder(["/x/1"]) == "/x")
}

// MARK: Every server kind, disk space, open deleted files, Empty File, as root

/// A scan's records and how many items the folder holds (filled on one background thread, read after the scan).
final class Scanned: @unchecked Sendable {
    var records: [DiskUsage.Record] = []
    var expected = 0
    var batches = 0
}

/// `session`'s scan of `dir` as a tree, with what it passed over.
func diskScan(_ session: Session, _ dir: String, asRoot: Bool = false,
                  password: String? = nil) async throws -> (usage: DiskUsage, skipped: DiskUsage.Skipped, batches: Int) {
    let found = Scanned()
    let skipped = try await session.diskUsage(of: dir, asRoot: asRoot, password: password) { records, expected in
        found.records += records
        found.expected = expected
        found.batches += 1
    }
    let usage = DiskUsage(path: dir)
    usage.expected = found.expected
    usage.add(found.records)
    return (usage, skipped, found.batches)
}

/// What servers print (anonymized recordings): du's complaints (GNU, BusyBox, BSD), df -Pk (GNU, BusyBox, macOS with a
/// space in the mount point), sftp's df, Linux's /proc listing and lsof -F (one file held twice by a process, memory-only
/// files, files elsewhere), a Windows scan; sudo's refusals in plain words.
@Test func diskUsageReadsWhatServersPrint() {
    let du = """
        du: cannot read directory './locked': Permission denied
        du: cannot read directory "./it's/secret": Permission denied
        du: can't open './busy box': Permission denied
        du: ./bsd dir: Permission denied
        du: cannot read directory '.': Permission denied
        __AIRSCP_SKIPPED__31
        """
    #expect(DiskUsage.skipped(fromDu: du) == .init(count: 31, paths: ["locked", "it's/secret", "busy box", "bsd dir", ""]))
    #expect(DiskUsage.skipped(fromDu: "__AIRSCP_SKIPPED__0\n") == .init())
    #expect(DiskUsage.skipped(fromDu: "") == .init())

    let gnu = "Filesystem     1024-blocks     Used Available Capacity Mounted on\n/dev/vda1         61255492 20231908  37882620      35% /\n"
    let busybox = "Filesystem           1024-blocks    Used Available Capacity Mounted on\noverlay               1000  400  500  44% /\n"
    let mac = "Filesystem   1024-blocks      Used Available Capacity  Mounted on\n/dev/disk4s1  2000  1500  300    84%    /Volumes/My Disk\n"
    let kib: Int64 = 1024
    #expect(DiskUsage.space(fromDf: gnu) == DiskUsage.Space(total: 61_255_492 * kib, free: 37_882_620 * kib))
    #expect(DiskUsage.space(fromDf: busybox) == .init(total: 1_024_000, free: 512_000))
    #expect(DiskUsage.space(fromDf: mac) == .init(total: 2_048_000, free: 307_200))
    #expect(DiskUsage.space(fromDf: "") == nil && DiskUsage.space(fromDf: "df: /nope: No such file or directory\n") == nil)
    let sftp = "sftp> df /srv\n        Size         Used        Avail       (root)    %Capacity\n"
        + "    61255492     20231908     37882620     41023584          33%\n"
    #expect(DiskUsage.space(fromSFTPDf: sftp) == DiskUsage.Space(total: 61_255_492 * kib, free: 37_882_620 * kib))
    #expect(DiskUsage.space(fromSFTPDf: "sftp> df /\n") == nil)

    let proc = "812\tjava\tapp\t1048576\t/srv/logs/app.log (deleted)\n812\tjava\tapp\t1048576\t/srv/logs/app.log (deleted)\n"
        + "901\tnginx\twww\t2048\t/srv/logs/access log (deleted)\n77\tpulse\tdev\t4096\t/memfd:pulseaudio (deleted)\n"
        + "78\tpg\tpostgres\t0\t/SYSV0052e2c1 (deleted)\n90\tsh\tdev\t5\t/tmp/x (deleted)\n91\tsh\tdev\t5\t/srv/logsx/y (deleted)\n"
    let held = DiskUsage.openDeleted(fromProc: proc, below: "/srv/logs")
    #expect(held == [.init(pid: 812, process: "java", user: "app", path: "/srv/logs/app.log", size: 1_048_576),
                     .init(pid: 901, process: "nginx", user: "www", path: "/srv/logs/access log", size: 2048)])
    #expect(DiskUsage.openDeleted(fromProc: proc, below: "/").map(\.pid) == [812, 901, 90, 91])
    let lsof = "p656\ncloginwindow\nu501\nLalice\nftxt\ns76872\nn/private/var/db/cache.plist\np972\ncmysqld\nu74\nL_mysql\n"
        + "f12\ns300\nn/var/mysql/tmp/ib1\nf13\ns300\nn/var/mysql/tmp/ib1\nf14\nn/var/mysql/tmp/ib2\n"
    #expect(DiskUsage.openDeleted(fromLsof: lsof, below: "/var/mysql")
            == [.init(pid: 972, process: "mysqld", user: "_mysql", path: "/var/mysql/tmp/ib1", size: 300),
                .init(pid: 972, process: "mysqld", user: "_mysql", path: "/var/mysql/tmp/ib2", size: 0)])
    #expect(DiskUsage.openDeleted(fromLsof: lsof, below: "/").first?.user == "alice")

    var expected = 0, skipped = DiskUsage.Skipped()
    let windows = "count=2\r\nD\t0\tlogs\r\nF\t120\tnotes.txt\r\nF\t5\tlogs/a b.log\r\nS\tlogs/secret\r\nskipped=1\r\n"
    #expect(DiskUsage.parseWindows(Substring(windows), expected: &expected, skipped: &skipped)
            == [.init(path: "logs", size: 0, folder: true), .init(path: "notes.txt", size: 120, folder: false),
                .init(path: "logs/a b.log", size: 5, folder: false)])
    #expect(expected == 2 && skipped == .init(count: 1, paths: ["logs/secret"]))
    #expect(Session.windowsPath("/C:/Users/it's me") == "C:\\Users\\it's me" && Session.windowsPath("/D:") == "D:\\")
    #expect(Session.powershellLiteral("it's ‘x’") == "'it''s ‘‘x’’'")
    #expect(Session.windowsScanScript("/C:/Users").utf16.count < 3_000, "cmd.exe's line limit")

    #expect(Session.sudoError("[sudo] password for dev: Sorry, try again.\nsudo: 1 incorrect password attempt\n", status: 1).message
            == "sudo refused the password.")
    #expect(Session.sudoError("sudo: a password is required\n", status: 1).message == "sudo needs this account's password.")
    #expect(Session.sudoError("dev is not in the sudoers file.  This incident will be reported.\n", status: 1).message
            == "This account may not use sudo on the server.")
    #expect(Session.sudoError("sh: exec: sudo: not found\n", status: 127).kind == .missingTool)
    // The script rides on the command line, the password only on standard input.
    #expect(OpenSSH.viaSh("echo hi", sudo: "sudo -S -p '' ").hasPrefix("exec sudo -S -p '' sh -c 'eval \"$(printf "))
}

/// A secret standard input (sudo's password) reaches the command but neither the command log nor the debug log.
@Test func aSecretInputStaysOutOfTheLogs() async throws {
    let secret = "hunter2-" + UUID().uuidString.prefix(6)
    let logged = Recorder<LogEntry>()
    let result = await Runner.run(["/bin/cat"], input: secret + "\n", secretInput: true, hostID: UUID(), log: { logged.append($0) })
    #expect(result.output == secret + "\n")
    _ = await eventually { !logged.all.isEmpty }
    #expect(logged.all.count == 1 && !logged.all[0].command.contains(secret))
    let plain = Recorder<LogEntry>()
    _ = await Runner.run(["/bin/cat"], input: "visible\n", log: { plain.append($0) })
    _ = await eventually { !plain.all.isEmpty }
    #expect(plain.all.first?.command.contains("visible") == true)
}

/// This Mac: a folder it can't read is passed over and named; the volume's size; Empty File (through a link: the file it
/// points to); a file deleted while a process holds it open is found with its size.
@Test func diskUsageOnThisMacSkipsSpaceEmptiesAndFindsOpenDeleted() async throws {
    let dir = try scratch()
    try write("readable", to: dir + "/open/a.txt")
    try write("hidden", to: dir + "/locked/b.txt")
    chmod(dir + "/locked", 0)
    defer { chmod(dir + "/locked", 0o755) }
    let skipped = try DiskUsage.scan(dir) { _, _ in }
    #expect(skipped == .init(count: 1, paths: ["locked"]))

    let space = try #require(DiskUsage.localSpace(of: dir))
    #expect(space.total > 0 && space.free > 0 && space.free < space.total)

    try write(String(repeating: "x", count: 4_000), to: dir + "/big.log")
    try FileManager.default.createSymbolicLink(atPath: dir + "/link.log", withDestinationPath: dir + "/big.log")
    try DiskUsage.emptyLocalFile(dir + "/link.log")
    #expect(read(dir + "/big.log") == "" && exists(dir + "/link.log"))
    #expect(throws: AirSCPError.self) { try DiskUsage.emptyLocalFile(dir + "/nothing") }

    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: "/bin/sh")
    holder.arguments = ["-c", "exec 3>\"$1\"; head -c 70000 /dev/zero >&3; rm \"$1\"; exec sleep 60", "sh", dir + "/held.bin"]
    try holder.run()
    defer { holder.terminate() }
    let real = try #require(realpath(dir, nil).map { String(cString: $0) })  // /private/var/…, as lsof names it
    var held: [DiskUsage.OpenDeleted] = []
    _ = await eventually {
        held = (try? await DiskUsage.localOpenDeleted(below: dir)) ?? []
        return held.first?.process == "sleep"  // not the shell before its exec
    }
    #expect(held.map(\.path) == [real + "/held.bin"] && held.first?.size == 70_000 && held.first?.process == "sleep")
    #expect(held.first?.pid == Int(holder.processIdentifier) && held.first?.user == NSUserName())
}

/// The tests' server (this Mac's sshd: BSD du, macOS df, lsof): skipped folders, the disk, Empty File (a file, a link
/// to one; not a folder or a link to nothing), files deleted but open; Scan as Root isn't offered without sudo -n.
@Test func diskUsageOnAServerSkipsSpaceEmptiesAndFindsOpenDeleted() async throws {
    try await withServer { server in
        try write("readable", to: server.path("du/open/a.txt"))
        try write("hidden", to: server.path("du/locked/b.txt"))
        chmod(server.path("du/locked"), 0)
        defer { chmod(server.path("du/locked"), 0o755) }
        let session = try await server.connectedSession()
        let (usage, skipped, _) = try await diskScan(session, server.path("du"))
        #expect(skipped == .init(count: 1, paths: ["locked"]))
        #expect(usage.root.files == 1 && usage.expected == 2)

        let space = try #require(try await session.diskSpace(of: server.path("du")))
        let local = try #require(DiskUsage.localSpace(of: server.path("du")))
        #expect(space.total > 0 && space.free > 0 && abs(space.total - local.total) < local.total / 100)

        try write(String(repeating: "x", count: 3_000), to: server.path("du/app.log"))
        try FileManager.default.createSymbolicLink(atPath: server.path("du/it's link"), withDestinationPath: server.path("du/app.log"))
        try await session.emptyFile(server.path("du/it's link"))
        #expect(read(server.path("du/app.log")) == "")
        try FileManager.default.createSymbolicLink(atPath: server.path("du/dangling"), withDestinationPath: server.path("du/none"))
        await #expect(throws: AirSCPError.self) { try await session.emptyFile(server.path("du/dangling")) }
        #expect(!exists(server.path("du/none")))
        await #expect(throws: AirSCPError.self) { try await session.emptyFile(server.path("du/open")) }
        #expect(session.emptyFileProblem == nil && session.diskUsageProblem == nil)

        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/bin/sh")
        holder.arguments = ["-c", "exec 3>\"$1\"; head -c 9000 /dev/zero >&3; rm \"$1\"; exec sleep 60", "sh", server.path("du/held.bin")]
        try holder.run()
        defer { holder.terminate() }
        let real = try #require(realpath(server.path("du"), nil).map { String(cString: $0) })
        var held: [DiskUsage.OpenDeleted] = []
        _ = await eventually {
            held = (try? await session.openDeletedFiles(below: server.path("du"))) ?? []
            return !held.isEmpty
        }
        #expect(held.map(\.path) == [real + "/held.bin"] && held.first?.size == 9_000)

        let sudo = await session.diskUsageSudo()
        // The throwaway sshd runs as this account: CI's runners have sudo without a password, a Mac usually not.
        let passwordless = await Runner.run(["/usr/bin/sudo", "-n", "true"]).status == 0
        #expect(sudo.available && sudo.needsPassword == !passwordless)
    }
}

/// An sftp-only server: the scan walks the listings (a folder it may not list is passed over), the disk comes from
/// sftp's df; Empty File and open deleted files say why they can't.
@Test func diskUsageOnAnSFTPOnlyServer() async throws {
    var options = TestServer.Options()
    options.sftpOnly = true
    try await withServer(options) { server in
        try write(String(repeating: "x", count: 5_000), to: server.path("du/big.bin"))
        try write("small", to: server.path("du/sub/deeper/small.txt"))
        try write("odd", to: server.path("du/café with spaces/it's.txt"))
        try FileManager.default.createDirectory(atPath: server.path("du/empty"), withIntermediateDirectories: true)
        try write("hidden", to: server.path("du/locked/b.txt"))
        chmod(server.path("du/locked"), 0)
        defer { chmod(server.path("du/locked"), 0o755) }
        let session = try await server.connectedSession()
        #expect(!session.capabilities.shell && session.diskUsageProblem == nil)
        let (usage, skipped, _) = try await diskScan(session, server.path("du"))
        #expect(skipped == .init(count: 1, paths: ["locked"]))
        #expect(usage.expected == 5 && usage.reached == 5 && usage.root.files == 3 && usage.root.size == 5_008)
        #expect(usage.root.children.first { $0.name == "empty" }?.isFolder == true)
        #expect(usage.root.largestFiles(1).first?.path == server.path("du/big.bin"))
        await #expect(throws: AirSCPError.self) { try await diskScan(session, server.path("nothing")) }

        let space = try await session.diskSpace(of: server.path("du"))
        #expect((space?.total ?? 0) > 0 && (space?.free ?? 0) > 0)
        #expect(session.emptyFileProblem != nil)
        await #expect(throws: AirSCPError.self) { try await session.emptyFile(server.path("du/big.bin")) }
        await #expect(throws: AirSCPError.self) { try await session.openDeletedFiles(below: server.path("du")) }
        await #expect(throws: AirSCPError.self) { try await diskScan(session, server.path("du"), asRoot: true) }
        #expect(await session.diskUsageSudo() == (false, false))
    }
}

/// S3: one flat listing, page by page (records as each page comes): a folder, a bucket, and "/" (every bucket); folder
/// markers are empty folders. No disk, no Empty File. A few thousand keys, timed.
@Test func diskUsageOnS3() async throws {
    let server = try TestS3(buckets: ["bucket", "other"])
    defer { server.stop() }
    server.pageSize = 3
    for (key, size) in [("a.txt", 5), ("dir/", 0), ("dir/x.txt", 10), ("dir/sub/y.txt", 20), ("empty/", 0), ("dir/sub/z w.txt", 7)] {
        server.put("bucket", key, Data(repeating: 65, count: size))
    }
    server.put("other", "o.bin", Data(repeating: 1, count: 100))
    let session = try await s3Session(server)
    let (folder, skipped, batches) = try await diskScan(session, "/bucket/dir")
    #expect(skipped == .init() && batches >= 2)
    #expect(folder.expected == 2 && folder.root.files == 3 && folder.root.size == 37)
    #expect(folder.root.children.map(\.name) == ["sub", "x.txt"])
    let bucket = try await diskScan(session, "/bucket").usage
    #expect(bucket.root.files == 4 && bucket.root.size == 42 && bucket.reached == 3)
    #expect(bucket.root.children.first { $0.name == "empty" }?.isFolder == true)
    let all = try await diskScan(session, "/").usage
    #expect(all.root.size == 142 && all.root.children.map(\.name) == ["other", "bucket"])
    #expect(try await session.diskSpace(of: "/bucket") == nil)
    #expect(session.emptyFileProblem != nil && session.diskUsageProblem == nil)
    await #expect(throws: AirSCPError.self) { try await session.openDeletedFiles(below: "/bucket") }

    server.pageSize = 1000
    for index in 0..<3_000 { server.put("other", "many/\(index % 30)/f\(index).bin", Data(count: 10)) }
    let started = Date()
    let many = try await diskScan(session, "/other/many").usage
    #expect(many.root.files == 3_000 && many.root.size == 30_000)
    print("S3 scan of 3,000 keys: \(String(format: "%.2f", -started.timeIntervalSinceNow)) s")
}

/// The Windows VM's OpenSSH server (AIRSCP_WINDOWS=1): the PowerShell scan of a throwaway folder, the drive's space, Empty
/// File; deleted-but-open files say why there are none. A folder whose name ends in "." (made by a Linux tool, say)
/// can't be read by Windows programs: it is passed over. (A folder an ACL denies can't serve: sshd gives the
/// administrator account its backup privilege, which reads through denials.) Then C:\Windows\System32, timed.
@Test(.enabled(if: windows() != nil)) func diskUsageOnWindows() async throws {
    let (address, password) = try #require(windows(), "AIRSCP_WINDOWS=1 needs the VM's address and credentials")
    let lab = LabRun()
    let session = try lab.session(Lab.host("porter", hostname: address, port: 22, password: true)) { prompt in
        if case .password = prompt.kind { return PromptAnswer(password) }
        return nil
    }
    try await session.connect()
    defer { Task { await session.disconnect() } }
    #expect(session.capabilities.windows && !session.capabilities.loginShell.isEmpty && session.diskUsageProblem == nil)
    let dir = RemotePath.join(session.capabilities.home, "airscp-du-" + UUID().uuidString.prefix(8))
    let folder = Session.windowsPath(dir)
    try await session.powershell("$d=\(Session.powershellLiteral(folder));New-Item -ItemType Directory -Path \"$d\\sub\\deep\",\"$d\\empty\",\"\\\\?\\$d\\bad.\" | Out-Null;"
        + "Set-Content -LiteralPath \"$d\\big.bin\" -Value ('x'*5000) -NoNewline;Set-Content -LiteralPath \"$d\\sub\\deep\\it's.txt\" -Value 'abc' -NoNewline")
    do {
        let (usage, skipped, _) = try await diskScan(session, dir)
        #expect(skipped == .init(count: 1, paths: ["bad."]), "\(skipped)")
        #expect(usage.expected == 4 && usage.reached == 4)
        #expect(usage.root.files == 2 && usage.root.size == 5_003, "\(usage.root.largestFiles(9).map { "\($0.path) \($0.size)" })")
        #expect(usage.root.children.first { $0.name == "empty" }?.isFolder == true)
        #expect(usage.root.largestFiles(2).map(\.path) == [dir + "/big.bin", dir + "/sub/deep/it's.txt"])

        let space = try #require(try await session.diskSpace(of: dir))
        #expect(space.total > 0 && space.free > 0 && space.free < space.total)
        #expect(session.emptyFileProblem == nil)
        try await session.emptyFile(dir + "/big.bin")
        #expect(try await session.list(dir).first { $0.name == "big.bin" }?.size == 0)
        await #expect(throws: AirSCPError.self) { try await session.openDeletedFiles(below: dir) }
        await #expect(throws: AirSCPError.self) { try await diskScan(session, dir + "/nothing") }
    } catch {
        Issue.record(error)
    }
    try await session.powershell("$d=\(Session.powershellLiteral(folder));cmd /c rd \"\\\\?\\$d\\bad.\";Remove-Item -LiteralPath $d -Recurse -Force")
    #expect(try await !session.exists(dir))

    let started = Date()
    let system32 = try await diskScan(session, "/C:/Windows/System32")
    print("Windows scan of C:\\Windows\\System32: \(String(format: "%.1f", -started.timeIntervalSinceNow)) s, "
          + "\(system32.usage.root.files) files, \(system32.usage.root.size >> 20) MB, \(system32.skipped.count) folders not read, "
          + "\(system32.batches) batches")
    #expect(system32.usage.root.files > 1_000)
}
