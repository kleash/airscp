import Darwin
import Foundation
import Testing
@testable import AirSCPCore

// PLAN.md S.2 (the feature cycle's gap review): leave-out patterns and the speed limit in the transfer queue, and what
// was fixed on the way (Run Command's marker line in the command log, a verification code asked again). The app's
// side (sheets, menus, the Transfers panel) is in S2AppTests.swift; the lab's (GNU and BusyBox tar, two-factor) below.

/// The files below a local folder, as paths relative to it, sorted (folders themselves left out).
func files(below folder: String) -> [String] {
    var result: [String] = []
    let walk = FileManager.default.enumerator(atPath: folder)
    while let path = walk?.nextObject() as? String {
        var info = stat()
        if lstat(folder + "/" + path, &info) == 0 && info.st_mode & S_IFMT != S_IFDIR { result.append(path) }
    }
    return result.sorted()
}

@Test func leaveOutPatternsAreReadAsTyped() {
    #expect(TransferQueue.patterns(" *.log, node_modules/ ;.git,, ") == ["*.log", "node_modules", ".git"])
    #expect(TransferQueue.patterns("").isEmpty && TransferQueue.patterns(" , ; ").isEmpty)
    let patterns = ["*.log", "node_modules", "[ab].txt"]
    #expect(TransferQueue.leftOut("app.log", by: patterns) && TransferQueue.leftOut("node_modules", by: patterns))
    #expect(TransferQueue.leftOut("a.txt", by: patterns) && !TransferQueue.leftOut("c.txt", by: patterns))
    #expect(!TransferQueue.leftOut("App.LOG", by: patterns))  // case as typed, as tar's --exclude matches
    #expect(!TransferQueue.leftOut("anything", by: []))
    // The tar arguments: this Mac's as separate words, a server's quoted for its shell.
    #expect(TransferQueue.excludes(["*.log", "a b"]) == ["--exclude", "*.log", "--exclude", "a b"])
    #expect(TransferQueue.remoteExcludes(["*.log", "it's"]) == "--exclude='*.log' --exclude='it'\\''s' ")
}

/// Folders leave out what matches, at any depth, both ways, as a stream and compressed. The server's tar is this Mac's
/// here (bsdtar); the lab's tests check GNU and BusyBox tar.
@Test func foldersLeaveOutWhatMatches() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let local = try server.scratch()
        for path in ["keep.txt", "debug.log", "node_modules/x/index.js", "sub/b.log", "sub/c.txt", ".git/HEAD"] {
            try write(path, to: local + "/site/" + path)
        }
        let patterns = ["*.log", "node_modules", ".git"]
        // Up as one stream, then down again leaving out another name.
        session.transfers.upload(local + "/site", to: server.path("site"), isFolder: true, excluding: patterns)
        await session.transfers.waitUntilIdle()
        #expect(files(below: server.path("site")) == ["keep.txt", "sub/c.txt"])
        let back = try server.scratch()
        session.transfers.download(server.path("site"), to: back + "/site", isFolder: true, excluding: ["c.txt"])
        await session.transfers.waitUntilIdle()
        #expect(files(below: back + "/site") == ["keep.txt"])

        // Compressed, as one .tar.gz each way.
        try rawMkdir(server.path("packed"))
        session.transfers.uploadCompressed(["site"], in: local, to: server.path("packed"), replacing: false, excluding: patterns)
        await session.transfers.waitUntilIdle()
        #expect(files(below: server.path("packed")) == ["site/keep.txt", "site/sub/c.txt"])
        let unpacked = try server.scratch()
        session.transfers.downloadArchive(["site"], in: server.path("packed"), to: unpacked + "/site.tar.gz", extract: true,
                                          excluding: ["keep.txt"])
        await session.transfers.waitUntilIdle()
        #expect(files(below: unpacked) == ["site/sub/c.txt"])
        #expect(session.transfers.jobs.allSatisfy { $0.status == .done }, "\(session.transfers.jobs.map(\.status))")
    }
}

/// The speed limit paces AirSCP's own streams (the pump) and goes to scp (and sftp) as -l, in Kbit/s.
@Test func theSpeedLimitPacesStreamsAndGoesToScp() async throws {
    // 3 MB through the pump: at once without a limit, about 3 s at 1 MB/s.
    let folder = try scratch()
    func pumped(limit: Int?) async -> (time: TimeInterval, bytes: Int64) {
        let file = open(folder + "/out", O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        var bytes: Int64 = 0
        let time = await timed {
            bytes = await Runner.pump(["/bin/sh", "-c", "head -c 3000000 /dev/zero"], hostID: nil, log: nil, into: .file(file),
                                      after: nil, cancellation: Cancellation(), limit: limit) { _ in }.bytes
        }
        return (time, bytes)
    }
    let fast = await pumped(limit: nil), slow = await pumped(limit: 1_000_000)
    #expect(fast.bytes == 3_000_000 && slow.bytes == 3_000_000)
    // A busy Mac slows both alike (3.1 s unlimited, 5.2 s limited on CI): the limit adds its 3 s.
    #expect(fast.time < slow.time - 1 && slow.time >= 2.5 && slow.time < 60, "\(fast.time) \(slow.time)")

    // scp: a limit no test's transfer comes near (the setting is every host's, and other tests run meanwhile).
    try await withServer { server in
        let session = try await server.connectedSession()
        let file = try server.scratch() + "/a.txt"
        try write("limited", to: file)
        TransferCenter.shared.speedLimit = 1000 * 1_048_576
        defer { TransferCenter.shared.speedLimit = nil }
        session.transfers.upload(file, to: server.path("a.txt"), isFolder: false)
        await session.transfers.waitUntilIdle()
        TransferCenter.shared.speedLimit = nil
        let scp = (await server.logEntries()).map(\.command).last { $0.hasPrefix(OpenSSH.scp) }
        #expect(scp?.contains(" -l 8192000 ") == true, "\(scp ?? "")")
        // Behind 64 writes in flight, a limited upload's meter showed 0 % for half of it: 8 make it follow.
        #expect(scp?.contains(" -X nrequests=8 ") == true, "\(scp ?? "")")
        #expect(read(server.path("a.txt")) == "limited")
    }
    #expect(OpenSSH.sftpBatch(SSHHost(hostname: "h"), jump: nil, socket: "/s", limit: 8192).prefix(7)
            == ["/usr/bin/sftp", "-b", "-", "-l", "8192", "-R", "8"])
    #expect(!OpenSSH.upload("/a", to: "/b", folder: false, preserveTimes: false, SSHHost(hostname: "h"), jump: nil, socket: "/s")
        .contains("-X"))
}

/// Run Command's marker line (its shell's pid, for Stop) is left out of the command log too, not only of the sheet.
@Test func theCommandLogLeavesOutRunCommandsMarker() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let result = try await session.run("echo out; echo err >&2")
        #expect(result.output == "out\n" && result.stderr == "err\n")
        let entry = (await server.logEntries()).last { $0.command.contains("echo err") }
        #expect(entry?.stderr == "err\n", "\(entry?.stderr ?? "no entry")")
    }
}

// MARK: Against the Docker lab (AIRSCP_DOCKER=1)

@Suite(.enabled(if: Lab.enabled)) struct S2LabTests {
    /// Two-factor (the lab key, then a verification code): the question comes as ssh asks it, and a wrong code is asked
    /// again marked as not accepted.
    @Test func aVerificationCodeIsAskedAndAWrongOneAgain() async throws {
        try await withLab { lab in
            let prompts = lab.prompts
            let session = try lab.session(Lab.twofactor()) { _ in
                PromptAnswer(prompts.all.count == 1 ? "wrong" : Lab.verificationCode())
            }
            try await session.connect()
            #expect(session.state == .connected)
            let asked = prompts.all
            #expect(asked.count == 2 && asked.allSatisfy { $0.kind == .other && $0.text.contains("Verification code:") },
                    "\(asked.map(\.text))")
            #expect(asked.map(\.retry) == [false, true])
            #expect(try await session.run("whoami").output == "dev\n")
        }
    }

    /// A folder downloaded with leave-out patterns from servers with GNU tar (Debian) and BusyBox tar (Alpine), and as
    /// one .tar.gz.
    @Test func foldersLeaveOutWhatMatchesWithGNUAndBusyBoxTar() async throws {
        try await withLab { lab in
            for host in [Lab.target(), Lab.minimal()] {
                let session = try await lab.connected(host)
                let folder = try await lab.folder(on: session, in: session.capabilities.home)
                _ = try await session.run("cd \(Quote.shell(folder)) && mkdir -p sub node_modules/x && echo k > keep.txt && "
                                          + "echo l > a.log && echo b > sub/b.log && echo c > sub/c.txt && echo j > node_modules/x/i.js")
                let local = try scratch()
                session.transfers.download(folder, to: local + "/got", isFolder: true, excluding: ["*.log", "node_modules"])
                session.transfers.downloadArchive([RemotePath.name(folder)], in: session.capabilities.home,
                                                  to: local + "/packed.tar.gz", extract: true, excluding: ["keep.txt", "*.log"])
                await session.transfers.waitUntilIdle()
                #expect(files(below: local + "/got") == ["keep.txt", "sub/c.txt"], "\(host.label)")
                let name = RemotePath.name(folder)
                #expect(files(below: local + "/" + name) == ["node_modules/x/i.js", "sub/c.txt"], "\(host.label)")
                #expect(session.transfers.jobs.allSatisfy { $0.status == .done }, "\(host.label): \(session.transfers.jobs.map(\.status))")
            }
        }
    }
}
