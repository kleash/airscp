import Darwin
import Foundation
import Testing
@testable import AirSCPCore

// Regression tests for the findings of the first break-it round (transfers, names, connections), against a throwaway
// sshd on this Mac.

private func job(_ id: UUID, in queue: TransferQueue) -> TransferJob? {
    queue.jobs.first { $0.id == id }
}

/// An app started from the Finder or the Dock has no locale variables: sftp would print every byte outside ASCII as an
/// octal escape, and those names couldn't be used. AirSCP asks for UTF-8 then.
@Test func commandsGetUTF8WithoutALocale() async throws {
    let launchd = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "SSH_AUTH_SOCK": "/tmp/x"]
    #expect(Runner.childEnvironment(launchd, [:])["LC_CTYPE"] == "C.UTF-8")
    #expect(Runner.childEnvironment(launchd.merging(["LANG": "de_DE.UTF-8"]) { $1 }, [:])["LC_CTYPE"] == nil)
    #expect(Runner.childEnvironment(launchd.merging(["LC_ALL": "C"]) { $1 }, [:])["LC_CTYPE"] == nil)

    try await withServer { server in
        let session = try await server.connectedSession()
        try rawCreate(server.path("Gr\u{FC}\u{DF}e.txt"), "hi")
        // sftp as AirSCP runs it, from an environment like launchd's: the name comes back as it is.
        func listing(_ environment: [String: String]) async -> String {
            let argv = ["/usr/bin/env", "-i"] + environment.map { "\($0.key)=\($0.value)" }.sorted()
                + OpenSSH.sftpBatch(session.host, jump: nil, socket: session.socketPath)
            return await Runner.run(argv, input: "cd \(Quote.sftp(server.home))\nls -lan\n").output
        }
        let without = await listing(launchd)
        #expect(without.contains("Gr\\303\\274\\303\\237e.txt"))  // what sftp does on its own
        let with = await listing(Runner.childEnvironment(launchd, [:]))
        #expect(Listing.parse(with, in: server.home).map(\.name).contains("Gr\u{FC}\u{DF}e.txt"))
    }
}

/// Streams go through socket pairs: when the system's pipe buffers run short (as on a Mac where another app holds
/// thousands of pipes), a pipe hands over 512 bytes per read and ssh moves streams ten times slower.
@Test func streamsMoveInBigChunks() async throws {
    let chunks = Recorder<Int64>()
    let start = Date()
    let pumped = await Runner.pump(["/bin/sh", "-c", "head -c 200000000 /dev/zero"], hostID: nil, log: nil,
                                   into: .command(["/bin/sh", "-c", "cat > /dev/null"], environment: [:], hostID: nil,
                                                  log: nil),
                                   after: nil, cancellation: Cancellation()) { chunks.append($0) }
    let rate = Double(pumped.bytes) / Date().timeIntervalSince(start) / 1e6
    let average = pumped.bytes / Int64(max(chunks.all.count, 1))
    print("PERF pump through this Mac: \(String(format: "%.0f", rate)) MB/s, \(average) bytes a read")
    #expect(pumped.bytes == 200_000_000 && pumped.consumer?.status == 0)
    #expect(average > 2048, "\(average) bytes a read")
}

/// Two downloads to the same place (two hosts run at the same time) each have a part file of their own: the second to
/// finish fails ("already exists") instead of renaming the first one's half-written part into place. A name of 250
/// bytes can be downloaded (the part name has a length of its own).
@Test func downloadsHaveTheirOwnPartFiles() async throws {
    try await withServer { server in
        let first = try await server.connectedSession()
        var other = server.host()
        other.id = UUID()
        let second = try await server.connectedSession(other)
        let local = try server.scratch()
        try writeRandom(bytes: 6_000_000, to: server.path("a.bin"))
        try writeRandom(bytes: 6_000_000, to: server.path("b.bin"))
        // The first one finishes first: it must not rename the second one's half-written part as its own.
        first.transfers.bandwidthLimit = 24_000
        second.transfers.bandwidthLimit = 16_000
        let one = first.transfers.download(server.path("a.bin"), to: local + "/same.bin", isFolder: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        let two = second.transfers.download(server.path("b.bin"), to: local + "/same.bin", isFolder: false)
        await first.transfers.waitUntilIdle()
        await second.transfers.waitUntilIdle()
        let statuses = [job(one, in: first.transfers)?.status, job(two, in: second.transfers)?.status]
        #expect(statuses[0] == .done, "\(statuses)")
        if case .failed(let error)? = statuses[1] { #expect(error.message.contains("already exists")) } else {
            Issue.record("second: \(String(describing: statuses[1]))")
        }
        #expect(FileManager.default.contentsEqual(atPath: local + "/same.bin", andPath: server.path("a.bin")))
        #expect(!names(in: local).contains { $0.hasSuffix(".part") })

        let long = String(repeating: "n", count: 246) + ".bin"
        try rawCreate(server.path(long), "long")
        let id = first.transfers.download(server.path(long), to: local + "/" + long, isFolder: false)
        await first.transfers.waitUntilIdle()
        #expect(job(id, in: first.transfers)?.status == .done && read(local + "/" + long) == "long")
    }
}

/// A folder upload cut off by a lost connection runs again cleanly (after reconnecting, Retry or the automatic retry):
/// no copy inside the partial one, no "File exists"; nothing partial is left under the folder's name meanwhile.
@Test func aRetriedFolderUploadStartsAfresh() async throws {
    // scp -r (a server without a shell): cut off half-way.
    try await withServer(TestServer.Options(sftpOnly: true)) { server in
        let session = try await server.connectedSession()
        let queue = session.transfers
        let local = try server.scratch()
        try rawMkdir(local + "/tree")
        for index in 0..<4 { try writeRandom(bytes: 3_000_000, to: local + "/tree/f\(index).bin") }
        queue.bandwidthLimit = 4_000  // 500 KB/s: still under way when cut off, however late a busy Mac notices the first file
        let id = queue.upload(local + "/tree", to: server.path("tree"), isFolder: true)
        #expect(await eventually { (job(id, in: queue)?.progress.filesDone ?? 0) >= 1 })  // (scp's progress is per file)
        try await killMaster(of: session)
        await queue.waitUntilIdle()
        #expect(await eventually { session.state != .connected })
        if case .failed? = job(id, in: queue)?.status {} else { Issue.record("status: \(String(describing: job(id, in: queue)?.status))") }
        #expect(!rawExists(server.path("tree")))
        queue.bandwidthLimit = nil
        try await session.connect()
        queue.retry(id)
        await queue.waitUntilIdle()
        #expect(job(id, in: queue)?.status == .done)
        #expect(Set(names(in: server.path("tree"))) == Set(names(in: local + "/tree")))
        #expect(!names(in: server.home).contains { $0.hasPrefix(".airscp-") })
    }
    // A tar stream: what a cut-off stream left (its partial copy) goes before the next try.
    try await withServer { server in
        let session = try await server.connectedSession()
        let queue = session.transfers
        let local = try server.scratch()
        try rawMkdir(local + "/tree")
        try rawCreate(local + "/tree/a.txt", "a")
        await session.disconnect()
        let id = queue.upload(local + "/tree", to: server.path("tree"), isFolder: true)
        await queue.waitUntilIdle()
        let partial = server.path(TransferQueue.partName(id))
        try rawMkdir(partial)
        try rawCreate(partial + "/half.bin", "half")
        try await session.connect()
        queue.retry(id)
        await queue.waitUntilIdle()
        #expect(job(id, in: queue)?.status == .done)
        #expect(names(in: server.path("tree")) == ["a.txt"])
        #expect(!rawExists(partial))
    }
}

/// Error output before the marker is login noise: a failure is explained by what the command said.
@Test func errorsLeaveLoginNoiseOut() async throws {
    try await withServer(TestServer.Options(noise: true)) { server in
        let session = try await server.connectedSession()
        try rawCreate(server.path("broken.tar.gz"), "not an archive at all")
        let entry = try #require(try await session.list(server.home).first { $0.name == "broken.tar.gz" })
        do {
            _ = try await session.extract(entry, into: .newFolder)
            Issue.record("extracted a broken archive")
        } catch let error as AirSCPError {
            #expect(!error.message.contains("AIRSCP-NOISE") && !error.details.contains("AIRSCP-NOISE"), "\(error)")
        }
        // The new folder that stayed empty is gone again.
        #expect(!rawExists(server.path("broken")))
    }
}

/// Long command lines (thousands of names) go to `sh -s` on standard input: a server takes at most 128 KB in one
/// argument, and ssh's connection sharing breaks at 256 KB ("mux_client_request_session: write packet: Broken pipe").
@Test func manyNamesFitInOneCommand() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let local = try server.scratch()
        try rawMkdir(server.path("many"))
        let names = (0..<4000).map { "a fairly long name, from the old server, number \($0) of the project backups" }
        for name in names { try rawMkdir(server.path("many/" + name)) }
        let id = session.transfers.downloadArchive(names, in: server.path("many"), to: local + "/many.tar.gz", extract: true)
        await session.transfers.waitUntilIdle()
        #expect(job(id, in: session.transfers)?.status == .done)
        #expect(AirSCPTests.names(in: local).count == names.count)
        try await session.delete(try await session.list(server.path("many")))
        #expect(AirSCPTests.names(in: server.path("many")).isEmpty)
        #expect(session.state == .connected)
    }
}

/// Files and archives with names that the tools treat specially.
@Test func archiveToolsTakeNamesAsTheyAre() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        // zip reads its standard input for a member named "-".
        try rawCreate(server.path("-"), "thirty-two bytes of real content")
        _ = try await session.compress(["-"], in: server.home, format: .zip)
        let listed = try await run(["/usr/bin/unzip", "-l", server.path("-.zip")]).output
        #expect(listed.contains("32") && listed.contains(" -\n"), "\(listed)")

        // unzip reads an archive's name as a pattern: "a[1].zip" would open a1.zip.
        try rawMkdir(server.path("w"))
        try rawCreate(server.path("w/wanted.txt"), "wanted")
        try rawCreate(server.path("w/other.txt"), "other")
        try await run(["/bin/sh", "-c", "cd \"$1\" && /usr/bin/zip -q 'a[1].zip' wanted.txt && /usr/bin/zip -q a1.zip other.txt",
                       "sh", server.path("w")])
        let entry = try #require(try await session.list(server.path("w")).first { $0.name == "a[1].zip" })
        let folder = try await session.extract(entry, into: .newFolder)
        #expect(AirSCPTests.names(in: folder) == ["wanted.txt"])
        // Extract Here finds the conflict in the right archive.
        #expect(try await session.extractConflicts(entry) == ["wanted.txt"])

        // tar in the C locale writes names outside ASCII as escapes: conflicts with them are found all the same.
        try rawMkdir(server.path("t"))
        try rawCreate(server.path("t/Gr\u{FC}\u{DF}e.txt"), "old")
        try await run(["/bin/sh", "-c", "cd \"$1\" && /usr/bin/tar -czf docs.tar.gz \"$2\"", "sh", server.path("t"),
                       "Gr\u{FC}\u{DF}e.txt"])
        let archive = try #require(try await session.list(server.path("t")).first { $0.name == "docs.tar.gz" })
        #expect(try await session.extractConflicts(archive) == ["Gr\u{FC}\u{DF}e.txt"])
    }
}

/// The editor saves through a copy next to the file, renamed over it: a failed save can't leave it half written. It
/// keeps the file's permissions, a link stays a link, a byte order mark stays, and a folder AirSCP can't write in still
/// takes the save (in place). A link's target that is too large isn't downloaded whole, nor is a file with huge lines
/// opened.
@Test func editorSavesSafely() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        try write("one\n", to: server.path("conf.ini"))
        chmod(server.path("conf.ini"), 0o640)
        try await session.writeText("two\n", to: server.path("conf.ini"))
        var info = stat()
        #expect(read(server.path("conf.ini")) == "two\n" && stat(server.path("conf.ini"), &info) == 0 && info.st_mode & 0o777 == 0o640)
        #expect(!AirSCPTests.names(in: server.home).contains { $0.hasPrefix(".airscp-") })

        try FileManager.default.createSymbolicLink(atPath: server.path("link.ini"), withDestinationPath: "conf.ini")
        try await session.writeText("three\n", to: server.path("link.ini"), isLink: true)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: server.path("link.ini"))) == "conf.ini")
        #expect(read(server.path("conf.ini")) == "three\n")

        try Data([0xEF, 0xBB, 0xBF] + Array("key=caf\u{E9}\r\n".utf8)).write(to: URL(fileURLWithPath: server.path("bom.txt")))
        let text = try await session.readText(server.path("bom.txt"))
        #expect(text.hasPrefix("\u{FEFF}"))
        try await session.writeText(text, to: server.path("bom.txt"))
        #expect(try Data(contentsOf: URL(fileURLWithPath: server.path("bom.txt"))).prefix(3) == Data([0xEF, 0xBB, 0xBF]))

        try rawMkdir(server.path("locked"))
        try write("old\n", to: server.path("locked/conf"))
        chmod(server.path("locked"), 0o555)
        defer { chmod(server.path("locked"), 0o755) }
        try await session.writeText("new\n", to: server.path("locked/conf"))
        #expect(read(server.path("locked/conf")) == "new\n")

        try zeros(500 << 20, at: server.path("big.bin"), sparse: true)
        try FileManager.default.createSymbolicLink(atPath: server.path("big-link.txt"), withDestinationPath: "big.bin")
        let local = URL(fileURLWithPath: try server.scratch() + "/fetched")
        do {
            try await session.fetch(server.path("big-link.txt"), to: local, limit: 1 << 20)
            Issue.record("fetched past the limit")
        } catch let error as AirSCPError {
            #expect(error.kind == .notText)
        }
        #expect((TransferQueue.localSize(local.path) ?? 0) < 400 << 20)
        do {
            _ = try await session.readText(server.path("big-link.txt"))
            Issue.record("read a 500 MB file")
        } catch let error as AirSCPError {
            #expect(error.kind == .notText)
        }

        try write(String(repeating: "{\"id\":12345,\"name\":\"porter\"},", count: 12_000), to: server.path("min.json"))
        do {
            _ = try await session.readText(server.path("min.json"))
            Issue.record("opened a file with a 350 KB line")
        } catch let error as AirSCPError {
            #expect(error.kind == .notText && error.message.contains("lines too long"))
        }
    }
}

/// Windows' OpenSSH (an sftp-only server to AirSCP) is told by its home folder.
@Test func windowsServersAreToldByTheirHome() {
    #expect(Session.isWindowsHome("/C:/Users/porter") && Session.isWindowsHome("/d:"))
    #expect(!Session.isWindowsHome("/home/dev") && !Session.isWindowsHome("/C:x") && !Session.isWindowsHome("/"))
}

/// A name that isn't UTF-8 shows its bad bytes as "�"; when that looks exactly like another name in the folder, it is
/// left out, so that nothing done to it can reach the other file.
@Test func namesThatArentUTF8CantStandInForOthers() {
    func line(_ name: [UInt8]) -> [UInt8] { Array("-rw-r--r--    1 1000     1000            12 Oct  2 18:39 ".utf8) + name + [0x0A] }
    let latin1 = Array("caf".utf8) + [0xE9] + Array(".txt".utf8)
    let replacement = Array("caf\u{FFFD}.txt".utf8)
    let both = Data(line(latin1) + line(replacement) + line(Array("plain".utf8)))
    let entries = Listing.parse(both, in: "/d", now: Date(), calendar: .current, linkTargets: false) ?? []
    #expect(entries.map(\.name) == ["caf\u{FFFD}.txt", "plain"] && entries[0].size == 12)
    // Alone, it is listed (anything done to it fails: no file has that name).
    let alone = Listing.parse(Data(line(latin1)), in: "/d", now: Date(), calendar: .current, linkTargets: false) ?? []
    #expect(alone.map(\.name) == ["caf\u{FFFD}.txt"])
}

/// Saved passwords go only to processes AirSCP started (or their children): another program of the same user that
/// read the askpass token from a helper's environment gets a question the user sees, not the Keychain's password.
@Test func savedPasswordsGoOnlyToAirSCPsOwnProcesses() async throws {
    _ = TestEnvironment.isolated
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let session = Session(host: SSHHost(hostname: "example.com", username: "dev"), jump: nil, askpass: askpass)
    session.savedPassword = { _ in "the saved secret" }
    let asked = Recorder<String>()
    session.onPrompt = { prompt, reply in
        asked.append(prompt.text)
        reply(PromptAnswer("typed by the user"))
    }
    let environment = askpass.environment(for: session.host.id.uuidString)
    let dir = try scratch()
    // A child of this process: the saved password.
    let child = await Runner.run([TestEnvironment.airscpBinary, "dev@example.com's password: "], environment: environment)
    #expect(child.output == "the saved secret\n")
    // Not one of ours (its parent has exited, so launchd adopted it): asked.
    let variables = environment.map { "\($0.key)=\(Quote.shell($0.value))" }.joined(separator: " ")
    _ = await Runner.run(["/bin/sh", "-c", "( sleep 1; env \(variables) \(Quote.shell(TestEnvironment.airscpBinary)) "
                          + "\"dev@example.com's password: \" > \(Quote.shell(dir + "/out")) ) >/dev/null 2>&1 & exit 0"])
    // The question goes through the main queue, which a busy suite can hold for a long time (CI's small machines).
    #expect(await eventually { read(dir + "/out") == "typed by the user\n" },
            "the other program got: \(read(dir + "/out").map { "“\($0)”" } ?? "nothing")")
    #expect(asked.all == ["dev@example.com's password: "])
}

/// A file of zeros: real blocks (tar reads them all), or with `sparse` none at all (reading it costs no disk).
private func zeros(_ bytes: Int, at path: String, sparse: Bool = false) throws {
    FileManager.default.createFile(atPath: path, contents: nil)
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    if sparse { return try handle.truncate(atOffset: UInt64(bytes)) }
    let chunk = Data(count: 1 << 20)
    for _ in 0..<(bytes >> 20) { handle.write(chunk) }
}

/// On an account without a shell: a replaced folder takes the old one's place once complete (sftp renames), and a
/// server-to-server copy lands in a hidden folder first and then takes its place, replacing what was there.
@Test func sftpOnlyServersReplaceSafelyToo() async throws {
    try await withServer { source in
        try await withServer(TestServer.Options(sftpOnly: true)) { target in
            let from = try await source.connectedSession()
            let to = try await target.connectedSession()
            #expect(!to.capabilities.shell)
            let local = try target.scratch()
            try write("new", to: local + "/site/index.html")
            try write("old", to: target.path("site/stale.html"))
            let up = to.transfers.upload(local + "/site", to: target.path("site"), isFolder: true, replacing: true)
            await to.transfers.waitUntilIdle()
            #expect(job(up, in: to.transfers)?.status == .done)
            #expect(names(in: target.path("site")) == ["index.html"] && read(target.path("site/index.html")) == "new")

            try write("from the source", to: source.path("src/notes.txt"))
            try write("deep", to: source.path("src/project/main.c"))
            try write("old notes", to: target.path("notes.txt"))
            try write("old", to: target.path("project/stale.c"))
            let copy = to.transfers.relay(["notes.txt", "project"], in: source.path("src"), from: from, to: target.home,
                                          replacing: true)
            await to.transfers.waitUntilIdle()
            #expect(job(copy, in: to.transfers)?.status == .done)
            #expect(read(target.path("notes.txt")) == "from the source" && names(in: target.path("project")) == ["main.c"])
            #expect(!names(in: target.home).contains { $0.hasPrefix(".airscp-") })
        }
    }
}
