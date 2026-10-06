import AppKit
import Darwin
import Foundation
import Testing
@testable import AirSCP
@testable import AirSCPCore

// The feature cycle's round 1 (fix step): one regression test per behaviour the area testers found broken, here those
// that run without the app's windows: unit tests, and the core against a throwaway sshd. The app and agent-control
// ones are in FeatureRoundAppTests.swift, the Docker lab ones in FeatureRoundLabTests.swift.

// MARK: Units

/// An infinite number (a list row scrolled out of view has an infinite frame) made NSJSONSerialization raise an
/// Objective-C exception no Swift code catches: agent control went dead.
@MainActor @Test func agentRepliesStayJSONWhateverTheNumbers() throws {
    final class Nowhere: NSView {
        override func accessibilityFrame() -> NSRect { NSRect(x: CGFloat.infinity, y: 0, width: 10, height: CGFloat.nan) }
    }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered,
                          defer: true)
    let node = AXNode(object: Nowhere(frame: .zero)).json(relativeTo: window)
    #expect(node["frame"] == nil && node["role"] != nil)
    let reply = AgentServer.text(["frame": [Double.infinity, 1], "cpu": Double.nan, "ok": true, "nested": ["x": -Double.infinity]])
    let text = try #require((reply["content"] as? [[String: Any]])?.first?["text"] as? String)
    let json = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    #expect((json["frame"] as? [Any])?.first is NSNull && json["cpu"] is NSNull && json["ok"] as? Bool == true)
    #expect((json["nested"] as? [String: Any])?["x"] is NSNull)
}

/// Aliases in files that the config pulls in with Include are offered for import, as ssh resolves them.
@Test func configImportFollowsIncludeLines() throws {
    let folder = try scratch()
    try FileManager.default.createDirectory(atPath: folder + "/config.d", withIntermediateDirectories: true)
    try write("Host included-alias\n  HostName 127.0.0.1\n", to: folder + "/extra.conf")
    try write("Host from-glob other\n", to: folder + "/config.d/a.conf")
    try write("Include config.d/deeper.conf\n", to: folder + "/config.d/b.conf")
    try write("Host deep\n", to: folder + "/config.d/deeper.conf")
    let config = "Include \(folder)/extra.conf\nInclude config.d/*.conf\nHost web\n  HostName web.example.com\n"
    #expect(SSHConfig.aliases(in: config, folder: folder) == ["included-alias", "from-glob", "other", "deep", "web"])
    #expect(SSHConfig.aliases(in: config) == ["web"])  // without the folder, Includes aren't read
    // An Include of itself doesn't go on for ever.
    try write("Include config\nHost loop\n", to: folder + "/config")
    #expect(SSHConfig.aliases(in: "Include config\n", folder: folder) == ["loop"])
}

/// The sidebar's search matches what each row shows: user@host:port.
@MainActor @Test func sidebarSearchMatchesTheAddress() {
    let model = testModel([SSHHost(label: "min pw", hostname: "127.0.0.1", port: 42202, username: "dev"),
                           SSHHost(label: "other", hostname: "10.0.0.1")])
    for term in ["42202", "127.0.0.1:42202", "dev@127.0.0.1"] {
        #expect(AppModel.sections(model.data, search: term).flatMap(\.hosts).map(\.label) == ["min pw"], "\(term)")
    }
}

/// Two groups of one name couldn't be told apart in the host editor's Group menu.
@MainActor @Test func groupNamesAreTakenOnce() {
    let model = testModel()
    let lab = model.addGroup(named: "Lab Servers")
    #expect(model.groupNameTaken("lab servers") && model.groupNameTaken("LAB SERVERS"))
    #expect(!model.groupNameTaken("Lab Servers", except: lab.id) && !model.groupNameTaken("Lab"))
}

/// scp's "- stalled -" frames: the speed and ETA must not stay frozen at their last values.
@Test func stalledProgressSaysSo() {
    var parser = ProgressParser()
    let running = parser.feed(Data("\rbig.bin   41%  850MB  66.4MB/s   00:17 ETA".utf8))
    #expect(running && parser.progress.speed == "66.4MB/s" && parser.progress.eta == "00:17")
    let stalled = parser.feed(Data("\rbig.bin   41%  850MB  66.4MB/s - stalled -".utf8))
    #expect(stalled)
    #expect(parser.progress.percent == 41 && parser.progress.speed == "stalled" && parser.progress.eta == "")
}

/// Names a file system can't hold get a plain refusal, and Windows' device names count as names it can't store.
@Test func longNamesAndWindowsDeviceNamesAreRefused() {
    #expect(FileList.nameProblem(String(repeating: "P", count: 255)) == nil)
    #expect(FileList.nameProblem(String(repeating: "P", count: 256))?.contains("255 bytes") == true)
    #expect(FileList.nameProblem(String(repeating: "é", count: 128))?.contains("256") == true)  // 2 bytes each
    for name in ["CON", "nul", "nul.txt", "Com1", "LPT9.log", "aux.tar.gz"] {
        #expect(FileList.nameProblem(name, windows: true) != nil, "\(name)")
        #expect(FileList.nameProblem(name) == nil)
    }
    for name in ["CONSOLE", "con-tent", "com10", "nullify.txt"] { #expect(FileList.nameProblem(name, windows: true) == nil, "\(name)") }
    #expect(RDPSession.windowsName("nul") == "nul_" && RDPSession.windowsName("CON.txt") == "CON_.txt")
    #expect(RDPSession.windowsName("Minutes 10:30.txt") == "Minutes 10_30.txt" && RDPSession.windowsName("ok.txt") == "ok.txt")
}

/// The Transfers panel lists what is queued or running and the newest 100 finished jobs: its table works through every
/// row at each update, and with 500 finished ones listed half the main thread went to it during a queue.
@Test func theTransfersPanelListsTheNewestFinishedJobs() {
    func job(_ status: TransferJob.Status) -> TransferJob {
        var job = TransferJob(id: UUID(), direction: .upload, hostID: UUID(), sourceHostID: nil, source: "/a", destination: "/b",
                              names: [], isFolder: false, replacing: false, preserveTimes: false)
        job.status = status
        return job
    }
    let jobs = (0..<150).map { _ in job(.done) } + [job(.queued)] + (0..<10).map { _ in job(.cancelled) }
    let shown = TransfersPanel.shown(jobs)
    // What is queued or running first (it sat below the fold, under old finished jobs), then the newest finished first.
    #expect(shown.count == 101 && shown.first?.status == .queued && shown[1].id == jobs.last?.id && shown.last?.id == jobs[60].id)
    #expect(!shown.contains { $0.id == jobs[59].id })
    #expect(TransfersPanel.shown(Array(jobs.prefix(20))).count == 20)
}

/// While transfers run AirSCP holds an activity: App Nap slowed its own streams (folders, archives, server-to-server
/// copies) 3 to 12 times while its window wasn't shown, and the Mac may not idle-sleep in the middle.
@MainActor @Test func transfersKeepAppNapAway() async {
    let delegate = AppDelegate()
    func held() async -> Bool {
        await Runner.run(["/usr/bin/pmset", "-g", "assertions"]).output.split(separator: "\n")
            .contains { $0.contains("pid \(getpid())(") && $0.contains("Transferring files") }
    }
    delegate.holdActivity(while: true)
    #expect(await held())
    delegate.holdActivity(while: false)
    #expect(!(await held()))
}

/// Keys typed into the Windows desktop: the US keyboard's characters go as key presses (with Shift where needed).
@Test func charactersOnAUSKeyboardAreKeys() throws {
    #expect(KeyCombo.usKey("a")! == (0, false) && KeyCombo.usKey("A")! == (0, true))
    #expect(KeyCombo.usKey("!")! == (18, true) && KeyCombo.usKey("1")! == (18, false))
    #expect(KeyCombo.usKey("\"")! == (39, true) && KeyCombo.usKey("'")! == (39, false))
    #expect(KeyCombo.usKey("\n")! == (36, false) && KeyCombo.usKey(" ")! == (49, false))
    #expect(KeyCombo.usKey("é") == nil && KeyCombo.usKey("日") == nil && KeyCombo.usKey("🎉") == nil)
    #expect(try KeyCombo("capslock").keyCode == 57)
}

/// A click on the Windows desktop counts while AirSCP's window isn't the key window (an agent's always is so).
@MainActor @Test func theDesktopTakesTheFirstClick() {
    #expect(RDPDesktopView(frame: .zero).acceptsFirstMouse(for: nil))
}

/// Automatic reconnects through a jump host or proxy get a time limit (they ask nothing); ones the user starts don't.
@Test func silentReconnectsThroughAHopTimeOut() {
    let jump = SSHHost(label: "bastion", hostname: "bastion")
    var host = SSHHost(label: "target", hostname: "target")
    host.jumpHostID = jump.id
    #expect(OpenSSH.master(host, jump: jump, socket: "/s", silent: true).contains("ConnectTimeout=30"))
    #expect(!OpenSSH.master(host, jump: jump, socket: "/s").contains { $0.hasPrefix("ConnectTimeout") })
    #expect(OpenSSH.master(SSHHost(hostname: "direct"), jump: nil, socket: "/s").contains("ConnectTimeout=15"))
}

/// The login shell's pid, read from the start of a user's command's error output (for Stop), and taken out again.
@Test func theRemoteShellsPidIsReadAndLeftOut() {
    let pid = RemotePID()
    pid.read(Data("motd noise\n__AIRSCP_P".utf8))
    #expect(pid.value == nil)
    pid.read(Data("ID__=4242\nreal error\n".utf8))
    #expect(pid.value == 4242)
    #expect(RemotePID.removed(from: "motd noise\n__AIRSCP_PID__=4242\nreal error\n") == "motd noise\nreal error\n")
    #expect(RemotePID.removed(from: "__AIRSCP_PID__=1\n") == "" && RemotePID.removed(from: "plain") == "plain")
}

// MARK: Tunnels

/// A port another program listens on (on 127.0.0.1, or on all addresses) is refused, instead of being shared with it.
@Test func aTunnelOnAPortInUseIsRefused() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let busy = try listener()  // listening on 127.0.0.1 and ::1
        defer {
            close(busy.fd)
            close(busy.fd6)
        }
        let tunnel = Tunnel(kind: .local, listenPort: busy.port, targetHost: "127.0.0.1", targetPort: server.port)
        await #expect(throws: AirSCPError.self) { try await session.startTunnel(tunnel) }
        do {
            try await session.startTunnel(tunnel)
        } catch let error as AirSCPError {
            #expect(error.kind == .portInUse && error.message.contains("\(busy.port)"))
        }
        #expect(!session.activeTunnels.contains(tunnel.id))
        // A free port works, on 127.0.0.1.
        let open = try await startedTunnel(session, to: server.port)
        #expect(await eventually { Session.answers(onLoopback: open.listenPort) })
        try await session.stopTunnel(open)
    }
}

// MARK: Commands and their log

/// A shell script's own exit status is logged (not ssh's, which is that of the printf ending it), with its error
/// output after the login noise; a user's command's error output keeps its end.
@Test func theCommandLogHasTheScriptsStatusAndErrors() async throws {
    try await withServer(TestServer.Options(noise: true)) { server in
        let session = try await server.connectedSession()
        // The script goes on to print its status: ssh itself ends with 0.
        await #expect(throws: AirSCPError.self) { try await session.shell("echo nope >&2; (exit 3)") }
        #expect(try await session.shell("echo fine") == "fine\n")
        let entries = await server.logEntries()
        let failed = try #require(entries.last { $0.command.contains("echo nope") })
        #expect(failed.status == 3 && failed.stderr.contains("nope") && !failed.stderr.contains(TestServer.noiseLine))
        // A script that succeeds logs its own status 0 (ssh's own status is that of the printf ending the sentinel).
        let worked = try #require(entries.last { $0.command.contains("echo fine") })
        #expect(worked.status == 0)

        // 50 000 lines of error output: the last ones arrive (the first 64 KB used to be kept).
        let result = try await session.run("seq 1 50000 >&2")
        #expect(result.stderr.hasSuffix("49999\n50000\n") && !result.stderr.contains(RemotePID.marker), "\(result.stderr.suffix(40))")
        #expect(result.stderr.utf8.count <= 65536)
    }
}

/// Stop ends the command on the server too: without a terminal, nothing else would (a loop would run for ever).
@Test func stoppingACommandEndsItOnTheServer() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let marker = "airscp-stop-\(getpid())"
        // Its own length: a sleep that a failed run left behind doesn't count.
        let sleeper = "sleep \(100_000 + Int(Date().timeIntervalSince1970) % 100_000)"
        // As typed in the login shell, and AirSCP's own command (File ▸ Run…), which sh runs from standard input.
        for sh in [false, true] {
            let cancellation = Cancellation()
            let running = Task { try await session.run("echo started; \(sleeper) # \(marker)", sh: sh, cancellation: cancellation) }
            #expect(await eventually { (try? await run(["/usr/bin/pgrep", "-fx", sleeper]))?.output.isEmpty == false })
            cancellation.cancel()
            _ = try? await running.value
            // The shell (whose command line has the marker, unless sh read it) and its sleep are gone.
            let either = "\(marker)|^\(sleeper)$"
            let gone = await eventually { await Runner.run(["/usr/bin/pgrep", "-f", either]).status != 0 }
            #expect(gone, "sh: \(sh)")
            if !gone { _ = await Runner.run(["/usr/bin/pkill", "-fx", sleeper]) }  // nothing left behind
            #expect(try await session.run("echo after").output == "after\n")
        }

        // A Stop after the command has ended signals nothing: its pid may be another process's by then.
        let finished = Cancellation()
        _ = try await session.run("echo done", cancellation: finished)
        let before = await server.logEntries().count
        finished.cancel()
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(!(await server.logEntries()).dropFirst(before).contains { $0.command.contains("kill -TERM") })
    }
}

/// File ▸ Run…: AirSCP's own command (the file's name quoted for sh) goes to `sh -s` on standard input, so the login
/// shell's command line is only `exec sh -s` (fish, csh and tcsh mis-read POSIX quoting there); the file runs in its
/// folder with the arguments as typed, and nothing in its name runs.
@Test func runningAServerFileKeepsItsNameOffTheLoginShellsCommandLine() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let dir = server.path("d\\';touch PWNED;# dir")
        try rawMkdir(dir)
        let script = dir + "/s\\';touch PWNED;#.sh"
        try rawCreate(script, "#!/bin/sh\necho ran \"$@\" in \"$PWD\"\n")
        chmod(script, 0o755)
        let result = try await session.run(Session.executeCommand(script, arguments: "one 'two three'"), sh: true)
        #expect(result.output == "ran one two three in \(dir)\n" && result.status == 0, "\(result.output) \(result.stderr)")
        let entry = try #require(await server.logEntries().last { $0.command.contains("touch PWNED") })
        #expect(entry.command.hasSuffix(" 'exec sh -s'"), "\(entry.command)")
        #expect(!exists(server.home + "/PWNED") && !exists(dir + "/PWNED"))
    }
}

// MARK: Files on the server

/// New File and Rename check the server, not the folder's last listing: an item made since is never emptied or
/// replaced unasked.
@Test func newFilesNeverEmptyWhatIsThere() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        try write("important data\n", to: server.path("race.txt"))
        await #expect(throws: AirSCPError.self) { try await session.createFile(server.path("race.txt")) }
        #expect(read(server.path("race.txt")) == "important data\n")
        try rawMkdir(server.path("stalefolder"))
        await #expect(throws: AirSCPError.self) { try await session.createFile(server.path("stalefolder")) }
        #expect(names(in: server.path("stalefolder")).isEmpty)
        try await session.createFile(server.path("new.txt"))
        #expect(read(server.path("new.txt")) == "")
        let there = try await session.exists(server.path("race.txt")), gone = try await session.exists(server.path("gone.txt"))
        #expect(there && !gone)
        try FileManager.default.createSymbolicLink(atPath: server.path("dangling"), withDestinationPath: "nowhere")
        #expect(try await session.exists(server.path("dangling")))
    }
    // Without a shell: checked with a listing first.
    try await withServer(TestServer.Options(sftpOnly: true)) { server in
        let session = try await server.connectedSession()
        try write("keep\n", to: server.path("there.txt"))
        await #expect(throws: AirSCPError.self) { try await session.createFile(server.path("there.txt")) }
        #expect(read(server.path("there.txt")) == "keep\n")
    }
}

/// Replace in a copy within the server keeps the old item until the new one is complete: a copy that fails leaves it
/// as it was.
@Test func aFailedReplacingCopyKeepsTheOldItem() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        for dir in ["src/proj", "dst/proj"] { try FileManager.default.createDirectory(atPath: server.path(dir), withIntermediateDirectories: true) }
        try write("new", to: server.path("src/proj/a.txt"))
        try write("secret", to: server.path("src/proj/locked.txt"))
        chmod(server.path("src/proj/locked.txt"), 0)
        defer { chmod(server.path("src/proj/locked.txt"), 0o644) }
        try write("IMPORTANT old work", to: server.path("dst/proj/old-important.txt"))
        await #expect(throws: AirSCPError.self) {
            try await session.copy(server.path("src/proj"), replacing: server.path("dst/proj"), folder: true, move: false)
        }
        #expect(read(server.path("dst/proj/old-important.txt")) == "IMPORTANT old work")
        #expect(names(in: server.path("dst")) == ["proj"])  // no temporary copy left
        // When it works, the new one takes the old one's place.
        chmod(server.path("src/proj/locked.txt"), 0o644)
        try await session.copy(server.path("src/proj"), replacing: server.path("dst/proj"), folder: true, move: false)
        #expect(names(in: server.path("dst/proj")).sorted() == ["a.txt", "locked.txt"] && names(in: server.path("dst")) == ["proj"])
        // A move too, also of a file over a folder.
        try write("file", to: server.path("src/thing"))
        try rawMkdir(server.path("dst/thing"))
        try await session.copy(server.path("src/thing"), replacing: server.path("dst/thing"), folder: true, move: true)
        #expect(read(server.path("dst/thing")) == "file" && !rawExists(server.path("src/thing")))
    }
}

/// A compressed upload (or a server-to-server copy) never deletes an item that appeared after it was planned: the
/// job stops instead, and the item stays as it was.
@Test func itemsThatAppearedAreNeverReplacedUnasked() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let local = try server.scratch()
        try FileManager.default.createDirectory(atPath: local + "/stalefolder", withIntermediateDirectories: true)
        try write("mine", to: local + "/stalefolder/mine.txt")
        try write("fresh", to: local + "/fresh.txt")
        try FileManager.default.createDirectory(atPath: server.path("dest/stalefolder"), withIntermediateDirectories: true)
        try write("theirs", to: server.path("dest/stalefolder/important.txt"))  // made by someone after the listing
        let queue = session.transfers
        let id = queue.uploadCompressed(["fresh.txt", "stalefolder"], in: local, to: server.path("dest"), replacing: false)
        #expect(await eventually { job(id, in: session)?.status.isFinished == true })
        guard case .failed(let error)? = job(id, in: session)?.status else {
            Issue.record("the job didn't stop: \(String(describing: job(id, in: session)?.status))")
            return
        }
        #expect(error.message.contains("“stalefolder” appeared"), "\(error.message)")
        #expect(read(server.path("dest/stalefolder/important.txt")) == "theirs")
        #expect(!rawExists(server.path("dest/stalefolder/mine.txt")))
        #expect(names(in: server.path("dest")).allSatisfy { !$0.hasPrefix(".airscp-") })
        // Replacing (the user said Replace): it is replaced.
        let replace = queue.uploadCompressed(["stalefolder"], in: local, to: server.path("dest"), replacing: true)
        #expect(await eventually { job(replace, in: session)?.status == .done })
        #expect(read(server.path("dest/stalefolder/mine.txt")) == "mine" && !rawExists(server.path("dest/stalefolder/important.txt")))
    }
}

/// Recursive permissions don't lock a folder before what is in it, and every item is tried.
@Test func recursivePermissionsReachEverything() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        try FileManager.default.createDirectory(atPath: server.path("perm/d/e"), withIntermediateDirectories: true)
        for path in ["perm/f1", "perm/f2", "perm/d/x", "perm/d/e/y"] { try write(path, to: server.path(path)) }
        let entries = try await session.list(server.path("perm"))
        for entry in entries { try await session.setPermissions(entry, mode: 0o640, recursive: true) }
        for (path, mode) in [("perm/f1", 0o640), ("perm/f2", 0o640), ("perm/d", 0o750), ("perm/d/e", 0o750), ("perm/d/x", 0o640),
                             ("perm/d/e/y", 0o640)] {
            #expect((try FileManager.default.attributesOfItem(atPath: server.path(path))[.posixPermissions] as? Int) == mode, "\(path)")
        }
    }
}

/// Get Info on a folder AirSCP can't read whole says so (it used to say "0 items"); folder sizes are the files' sizes.
@Test func getInfoSaysWhenAFolderCantBeReadWhole() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        try rawMkdir(server.path("noread"))
        try write("s", to: server.path("noread/s.txt"))
        chmod(server.path("noread"), 0)
        defer { chmod(server.path("noread"), 0o755) }
        let entry = try #require(try await session.list(server.home).first { $0.name == "noread" })
        let info = try await session.info(entry)
        #expect(info.incomplete && info.itemCount == nil)
        chmod(server.path("noread"), 0o755)
        let readable = try await session.info(entry)
        #expect(!readable.incomplete && readable.itemCount == 1)
        // Sizes as the files' (apparent) sizes: a 1-byte file isn't a 4 KB block.
        try rawMkdir(server.path("tiny"))
        try write("x", to: server.path("tiny/one"))
        #expect((try await session.folderSizes(["tiny"], in: server.home)["tiny"] ?? 0) <= 2048)
    }
}

/// A rename in a folder whose path is longer than sftp's 2 048-byte batch line works (by the names alone).
@Test func renamesWorkInDeepFolders() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        // Each path under this Mac's 1 024 bytes (the test server is this Mac), the two in one line over 2 048.
        var deep = server.home
        while deep.utf8.count < 990 { deep += "/" + String(repeating: "d", count: min(200, max(1, 999 - deep.utf8.count))) }
        try FileManager.default.createDirectory(atPath: deep, withIntermediateDirectories: true)
        try write("deep", to: deep + "/deep.txt")
        #expect("rename \"\(deep)/deep.txt\" \"\(deep)/deep2.txt\"".utf8.count > 2010)
        try await session.rename(deep + "/deep.txt", to: deep + "/deep2.txt")
        #expect(read(deep + "/deep2.txt") == "deep" && !rawExists(deep + "/deep.txt"))
    }
}

/// Install on Host with a key file whose name holds shell syntax: nothing of it runs on this Mac.
@Test func keyNamesNeverRunAsCommands() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let keys = try server.scratch()
        // Evaluated, the name would be "kinj<user>x", which doesn't exist: the install would fail.
        let odd = keys + "/kinj$(id -un)x \"q\""
        try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "odd", "-f", odd])
        try await session.installKey(odd + ".pub")
        let installed = try #require(read(server.home + "/.ssh/authorized_keys"))
        #expect(installed.contains(" odd"))
    }
}

/// Synchronize's compare lists a whole level of the tree in one command, with a shell and on an sftp-only account (a
/// command per folder took 20 s for 301 folders, a minute 80 ms away, sftp only 5 minutes); a folder that can't be
/// listed so is listed alone, which names it.
@Test(arguments: [false, true]) func synchronizeComparesALevelOfFoldersAtOnce(sftpOnly: Bool) async throws {
    var options = TestServer.Options()
    options.sftpOnly = sftpOnly
    try await withServer(options) { server in
        let local = try server.scratch(), there = server.path("tree")
        let time = Date().timeIntervalSince1970 - 3600
        for outer in 0..<4 {
            for inner in 0..<4 {
                for root in [local, there] {
                    let path = root + "/d\(outer)/e \(inner)/same.txt"
                    try write("x", to: path)
                    var times = [timeval(tv_sec: Int(time), tv_usec: 0), timeval(tv_sec: Int(time), tv_usec: 0)]
                    _ = utimes(path, &times)
                }
            }
        }
        try write("only here", to: local + "/d3/e 3/new.txt")
        // A name with a line break is left out (the server's listing may not show it: it was uploaded at every sync).
        try write("two lines", to: local + "/d2/two\nlines.txt")
        let session = try await server.connectedSession()
        let before = await server.logEntries().count
        let comparison = try await Sync.compare(local: local, remote: there, on: session) { _ in }
        #expect(comparison.folders == 21 && comparison.differences.map(\.path) == ["d3/e 3/new.txt"] && comparison.leftOut == 1,
                "\(comparison.folders) \(comparison.differences.map(\.path)) \(comparison.leftOut)")
        let listings = (await server.logEntries()).dropFirst(before).filter { $0.command.contains("ls -lan") }
        #expect(listings.count == 3, "\(listings.count)")  // the folder, its 4 folders, and their 16

        // A folder that can't be read: listed alone, so the compare names it.
        chmod(there + "/d1/e 2", 0)
        defer { chmod(there + "/d1/e 2", 0o755) }
        do {
            _ = try await Sync.compare(local: local, remote: there, on: session) { _ in }
            Issue.record("compared a folder that can't be read")
        } catch let error as AirSCPError {
            #expect(error.message.contains("d1/e 2"), "\(error.message)")
        }
    }
}

// MARK: Prompts

/// A password asked again (the answer was refused) says so, and a cancelled Test Connection stops at the first Cancel.
@Test func aRefusedPasswordIsSaidAndACancelStopsTheTest() async throws {
    try await withServer(TestServer.Options(passwords: true)) { server in
        var host = server.host(key: "/nonexistent-key")
        host.auth = .password
        let asked = Recorder<Prompt>()
        let session = try server.session(host) { prompt in
            asked.append(prompt)
            return asked.all.count < 3 ? PromptAnswer("wrong") : nil
        }
        await #expect(throws: AirSCPError.self) { try await session.connect() }
        let passwords = asked.all.filter { if case .password = $0.kind { return true } else { return false } }
        #expect(passwords.count >= 2 && !passwords[0].retry && passwords[1].retry, "\(passwords.map(\.retry))")
    }
}

/// Cancel on one of Test Connection's questions ends the test: ssh would only ask again (6 Cancels were needed).
@MainActor @Test func cancellingTestConnectionsQuestionEndsIt() async throws {
    try await withServer(TestServer.Options(passwords: true)) { @MainActor server in
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        var host = server.host()
        host.auth = .password
        var asked = 0
        let result = await testConnection(host, jump: nil, password: nil, model: testModel([host]), askpass: askpass) { _, reply in
            asked += 1
            reply(nil)
        }
        #expect(result == nil && asked == 1)
    }
}

// MARK: Automatic reconnect setting

/// "Reconnect automatically" switched off for a live connection applies at once.
@Test func reconnectingCanBeSwitchedOffWhileConnected() async throws {
    try await withServer { server in
        var host = server.host()
        host.autoReconnect = true
        let session = try server.session(host)
        try await session.connect()
        session.autoReconnect = false
        try await killMaster(of: session)
        #expect(await eventually {
            if case .disconnected = session.state { return true }
            return false
        })
    }
}

/// A master taken over at launch isn't AirSCP's child: its end is noticed anyway, without a command or the window.
@Test func anAdoptedMastersEndIsNoticed() async throws {
    try await withServer { server in
        let host = server.host()
        let previous = try await server.connectedSession(host)
        let adopted = try server.session(host)
        #expect(await adopted.adopt())
        try await killMaster(of: previous)
        #expect(await eventually {
            if case .disconnected = adopted.state { return true }
            return false
        })
    }
}

/// A copy between two servers stopped by its source's lost connection runs again once that host has reconnected by
/// itself (it ended "The command failed (exit status 255)" and stayed so).
@Test func aServerToServerCopyRunsAgainWhenItsSourceReconnects() async throws {
    try await withServer { source in
        try await withServer { target in
            var sourceHost = source.host()
            sourceHost.autoReconnect = true
            let from = try source.session(sourceHost)
            try await from.connect()
            let to = try await target.connectedSession()
            try writeRandom(bytes: 150_000_000, to: source.path("src/big.bin"))
            try rawMkdir(target.path("dest"))
            let id = to.transfers.relay(["big.bin"], in: source.path("src"), from: from, to: target.path("dest"), replacing: false)
            #expect(await eventually { job(id, in: to)?.status == .running })
            try await killMaster(of: from)
            var failure: AirSCPError?, done = false
            let deadline = Date().addingTimeInterval(180)  // copied twice: 300 MB, on a Mac that may be busy
            while Date() < deadline && !done {
                let status = to.transfers.jobs.first { $0.id == id }?.status
                if case .failed(let error)? = status { failure = error }
                done = status == .done
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            #expect(done, "\(String(describing: to.transfers.jobs.first { $0.id == id }?.status))")
            if let failure { #expect(failure.kind == .disconnected, "\(failure)") }
            #expect(FileManager.default.contentsEqual(atPath: source.path("src/big.bin"), andPath: target.path("dest/big.bin")))
        }
    }
}
