import Combine
import Darwin
import Foundation
import Testing
@testable import AirSCPCore

private func job(_ id: UUID, in queue: TransferQueue) -> TransferJob? {
    queue.jobs.first { $0.id == id }
}

/// Everything below `folder` (links not followed) as relative path → "dir", "link → target" or the file's contents.
private func contents(_ folder: String) -> [String: String] {
    var result: [String: String] = [:]
    for case let relative as String in FileManager.default.enumerator(atPath: folder) ?? FileManager.DirectoryEnumerator() {
        let path = folder + "/" + relative
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            result[relative] = "link → " + target
        } else {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
            result[relative] = isDirectory.boolValue ? "dir" : (read(path) ?? "?")
        }
    }
    return result
}

/// Writes `bytes` of zeros (real blocks, not a sparse file, so that tar reads them all).
private func writeZeros(bytes: Int, to path: String) throws {
    FileManager.default.createFile(atPath: path, contents: nil)
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    let chunk = Data(count: 1 << 20)
    for _ in 0..<(bytes >> 20) { handle.write(chunk) }
}

/// Starts a job, cancels it once bytes flow, and returns its final status.
private func cancelOnceUnderWay(_ queue: TransferQueue, _ start: () -> UUID) async -> TransferJob.Status? {
    let id = start()
    let flowing = await eventually { (job(id, in: queue)?.progress.bytes ?? 0) > 0 }
    #expect(flowing, "no bytes moved")
    queue.cancel(id)
    await queue.waitUntilIdle()
    return job(id, in: queue)?.status
}

private func leftovers(in folder: String, _ prefix: String) -> [String] {
    names(in: folder).filter { $0.hasPrefix(prefix) }
}

@Test func foldersOfManyFilesGoAsOneTarStream() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let queue = session.transfers
        let local = try server.scratch()
        // 10 000 small files in 100 folders, names that need care, an empty folder, links (they stay links, also one to
        // the folder above, which tar must not follow).
        try rawMkdir(local + "/many")
        for folder in 0..<100 {
            try rawMkdir(local + "/many/d\(folder)")
            for file in 0..<100 { try rawCreate(local + "/many/d\(folder)/f\(file)", "\(folder)-\(file)\n") }
        }
        for name in specialNames { try rawCreate(local + "/many/" + name, name) }
        try rawMkdir(local + "/many/empty")
        try FileManager.default.createSymbolicLink(atPath: local + "/many/link", withDestinationPath: "d0/f0")
        try FileManager.default.createSymbolicLink(atPath: local + "/many/d1/up", withDestinationPath: "..")
        try rawMkdir(local + "/few")
        try rawCreate(local + "/few/one", "1")

        // The global list follows at most four times a second, however busy the queues are (all tests' queues count).
        let updates = Recorder<Date>()
        let subscription = TransferCenter.shared.$jobs.sink { _ in updates.append(Date()) }
        var start = Date()
        let up = queue.upload(local + "/many", to: server.path("many"), isFolder: true)
        await queue.waitUntilIdle()
        let elapsed = Date().timeIntervalSince(start)
        subscription.cancel()
        print("PERF uploading 10000 small files as one tar stream: \(String(format: "%.2f", elapsed)) s, "
              + "\(updates.all.count) updates of the global list")
        #expect(Double(updates.all.count) <= elapsed * 4 + 3)
        let uploaded = try #require(job(up, in: queue))
        #expect(uploaded.status == .done)
        #expect(uploaded.progress.percent == 100 && uploaded.progress.bytes > 10_000 * 512 && (uploaded.progress.total ?? 0) > 0)
        let expected = contents(local + "/many")
        #expect(expected["link"] == "link → d0/f0" && expected["d1/up"] == "link → ..")
        #expect(contents(server.path("many")) == expected)
        #expect(Set(rawNames(in: server.path("many")).filter { $0.count > 3 }) == Set(rawNames(in: local + "/many").filter { $0.count > 3 }))
        var commands = (await server.logEntries()).map(\.command)
        #expect(commands.contains { $0.hasPrefix("/usr/bin/tar -c -f - ") } && !commands.contains { $0.contains("/many") && $0.hasPrefix("/usr/bin/scp") })

        start = Date()
        let down = queue.download(server.path("many"), to: local + "/many back", isFolder: true)
        await queue.waitUntilIdle()
        print("PERF downloading 10000 small files as one tar stream: \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
        #expect(job(down, in: queue)?.status == .done)
        #expect(contents(local + "/many back") == expected)
        #expect(!names(in: local).contains { $0.hasSuffix(".part") })
        commands = (await server.logEntries()).map(\.command)
        #expect(commands.contains { $0.contains("-cf - .") })

        // A folder of a few files goes as a stream too (scp -r is for servers without a shell or tar).
        let few = queue.upload(local + "/few", to: server.path("few"), isFolder: true)
        await queue.waitUntilIdle()
        #expect(job(few, in: queue)?.status == .done && read(server.path("few/one")) == "1")
        #expect(!(await server.logEntries()).contains { $0.command.hasPrefix("/usr/bin/scp -r ") })

        // Replace: the new copy takes the old one's place once complete.
        try rawCreate(server.path("many/stale"), "old")
        let again = queue.upload(local + "/many", to: server.path("many"), isFolder: true, replacing: true)
        await queue.waitUntilIdle()
        #expect(job(again, in: queue)?.status == .done && !rawExists(server.path("many/stale")))
        #expect(!names(in: server.home).contains { $0.hasPrefix(".airscp-") })

        // Cancelling cleans up, both ways; a folder being replaced stays as it was.
        try writeZeros(bytes: 400 << 20, to: local + "/many/zeros")
        #expect(await cancelOnceUnderWay(queue) { queue.upload(local + "/many", to: server.path("partial"), isFolder: true) } == .cancelled)
        #expect(!rawExists(server.path("partial")))
        try rawCreate(server.path("many/stale"), "old")
        #expect(await cancelOnceUnderWay(queue) {
            queue.upload(local + "/many", to: server.path("many"), isFolder: true, replacing: true)
        } == .cancelled)
        #expect(read(server.path("many/stale")) == "old" && read(server.path("many/d0/f0")) == "0-0\n")
        #expect(!names(in: server.home).contains { $0.hasPrefix(".airscp-") })
        try writeZeros(bytes: 400 << 20, to: server.path("many/zeros"))
        #expect(await cancelOnceUnderWay(queue) { queue.download(server.path("many"), to: local + "/partial", isFolder: true) } == .cancelled)
        #expect(!rawExists(local + "/partial") && !names(in: local).contains { $0.hasSuffix(".part") })
    }
}

/// A tar-stream upload into a destination folder whose name a non-POSIX login shell would mis-read (a single quote, a
/// backslash, a space, glob characters): the consumer reads the folder from standard input with `read` instead of
/// taking it on the login shell's command line, so it still unpacks there. (The data flows through `sh` whatever the
/// login shell is; this proves the folder, the one server-supplied value, is handled as data end to end.)
@Test func tarStreamUnpacksIntoAnAwkwardlyNamedFolder() async throws {
    try await withServer(TestServer.Options(noise: true)) { server in
        let session = try await server.connectedSession()
        let queue = session.transfers
        let local = try server.scratch()
        try rawMkdir(local + "/src")
        for name in specialNames { try rawCreate(local + "/src/" + name, name) }
        let dest = server.path("sq'uote back\\slash star* dir")
        let up = queue.upload(local + "/src", to: dest, isFolder: true)
        await queue.waitUntilIdle()
        #expect(job(up, in: queue)?.status == .done)
        #expect(Set(rawNames(in: dest)) == Set(specialNames.map { Array($0.utf8) }))
        #expect(contents(dest) == contents(local + "/src"))
        #expect(!rawNames(in: server.home).contains { String(decoding: $0, as: UTF8.self).hasPrefix(".airscp-") })
        // A compressed upload (its own consumer) into the same awkward folder, replacing it.
        let packed = queue.uploadCompressed(specialNames, in: local + "/src", to: dest, replacing: true)
        await queue.waitUntilIdle()
        #expect(job(packed, in: queue)?.status == .done)
        #expect(Set(rawNames(in: dest)) == Set(specialNames.map { Array($0.utf8) }))
    }
}

/// A destination whose path has a line break: the consumer would read the folder as one line (`read`), cut at the
/// break, and rm -rf another folder (a sibling named as the first line, or the parent of a name that starts with the
/// break). It is refused before anything runs, for a folder upload and a compressed one; nothing else changes.
@Test func aDestinationWithALineBreakIsRefusedAndNothingElseRemoved() async throws {
    try await withServer(TestServer.Options(noise: true)) { server in
        let session = try await server.connectedSession()
        let queue = session.transfers
        let local = try server.scratch()
        try rawMkdir(local + "/src")
        try rawCreate(local + "/src/new.txt", "new")
        let parent = server.path("nl")
        for folder in ["", "/a", "/a\nb", "/\nevil"] { try rawMkdir(parent + folder) }
        try rawCreate(parent + "/a/keep.txt", "keep")
        try rawCreate(parent + "/important.txt", "important")
        let before = contents(parent)
        for dest in [parent + "/a\nb", parent + "/\nevil"] {
            for start in [{ queue.upload(local + "/src", to: dest + "/src", isFolder: true) },
                          { queue.uploadCompressed(["new.txt"], in: local + "/src", to: dest, replacing: false) }] {
                let id = start()
                await queue.waitUntilIdle()
                guard case .failed(let error) = job(id, in: queue)?.status else {
                    Issue.record("not refused: \(String(describing: job(id, in: queue)?.status))")
                    continue
                }
                #expect(error.message.contains("line break"))
                #expect(contents(parent) == before)
            }
        }
    }
}

@Test func downloadAsArchive() async throws {
    try await withServer(TestServer.Options(noise: true)) { server in
        let session = try await server.connectedSession()
        let queue = session.transfers
        let local = try server.scratch()
        try rawMkdir(server.path("project"))
        try rawMkdir(server.path("project/src"))
        try rawCreate(server.path("project/src/main.c"), "int main;\n")
        try rawCreate(server.path("notes.txt"), "new notes\n")
        try rawCreate(server.path("-it's *"), "odd\n")

        // Login noise on the way doesn't get into the archive.
        let items = ["project", "notes.txt", "-it's *"]
        let id = queue.downloadArchive(items, in: server.home, to: local + "/Archive.tar.gz", extract: false)
        await queue.waitUntilIdle()
        let finished = try #require(job(id, in: queue))
        #expect(finished.status == .done && finished.progress.indeterminate && finished.progress.bytes > 0)
        let listing = try await run(["/usr/bin/tar", "-tzf", local + "/Archive.tar.gz"]).output
        #expect(Set(listing.split(separator: "\n").map(String.init))
            == ["./project/", "./project/src/", "./project/src/main.c", "./notes.txt", "./-it's *"])
        #expect(!names(in: local).contains { $0.hasSuffix(".part") })

        // Extract: the items land next to it (replacing what is there), no archive or scratch folder stays.
        try rawMkdir(local + "/x")
        try rawCreate(local + "/x/notes.txt", "old notes\n")
        try rawCreate(local + "/x/keep.txt", "keep\n")
        let extracted = queue.downloadArchive(items, in: server.home, to: local + "/x/Archive.tar.gz", extract: true)
        await queue.waitUntilIdle()
        #expect(job(extracted, in: queue)?.status == .done)
        #expect(Set(names(in: local + "/x")) == ["project", "notes.txt", "-it's *", "keep.txt"])
        #expect(read(local + "/x/notes.txt") == "new notes\n" && read(local + "/x/project/src/main.c") == "int main;\n")

        // An archive name that is taken is not overwritten.
        let taken = queue.downloadArchive(["notes.txt"], in: server.home, to: local + "/Archive.tar.gz", extract: false)
        await queue.waitUntilIdle()
        if case .failed? = job(taken, in: queue)?.status {} else { Issue.record("overwrote an archive") }

        // Cancelled half-way: no part file stays.
        try writeRandom(bytes: 60_000_000, to: server.path("random.bin"))
        #expect(await cancelOnceUnderWay(queue) {
            queue.downloadArchive(["random.bin"], in: server.home, to: local + "/big.tar.gz", extract: false)
        } == .cancelled)
        #expect(!names(in: local).contains { $0.hasSuffix(".part") } && !rawExists(local + "/big.tar.gz"))

        // Without tar: the job says why.
        session.capabilities.tools.remove("tar")
        let refused = queue.downloadArchive(["notes.txt"], in: server.home, to: local + "/n.tar.gz", extract: false)
        await queue.waitUntilIdle()
        if case .failed(let error)? = job(refused, in: queue)?.status {
            #expect(error.kind == .missingTool)
        } else {
            Issue.record("downloaded without tar")
        }
    }
}

@Test func uploadCompressed() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let queue = session.transfers
        let local = try server.scratch()
        try rawMkdir(local + "/site")
        try rawMkdir(local + "/site/css")
        try rawCreate(local + "/site/css/a.css", "a{}\n")
        try rawCreate(local + "/site/index.html", "<p>\n")
        try await run(["/usr/bin/xattr", "-w", "com.example.airscp", "meta", local + "/site/index.html"])
        try rawCreate(local + "/readme.txt", "readme\n")
        try rawCreate(local + "/@not an archive", "at\n")
        try rawMkdir(server.path("dest"))

        let items = ["site", "readme.txt", "@not an archive"]
        let id = queue.uploadCompressed(items, in: local, to: server.path("dest"), replacing: false)
        await queue.waitUntilIdle()
        let finished = try #require(job(id, in: queue))
        #expect(finished.status == .done && finished.progress.indeterminate && finished.progress.bytes > 0)
        #expect(contents(server.path("dest")) == contents(local).filter { key, _ in items.contains { key == $0 || key.hasPrefix($0 + "/") } })
        // No AppleDouble files; one stream, so no archive or scratch folder on either side.
        #expect(!contents(server.path("dest")).keys.contains { RemotePath.name($0).hasPrefix("._") })
        #expect(leftovers(in: server.path("dest"), ".airscp-").isEmpty)
        #expect(leftovers(in: FileManager.default.temporaryDirectory.path, "airscp-upload-").isEmpty)

        // Replace: the new copies take the old ones' places once all have arrived (Skip: the caller leaves those
        // names out).
        try rawCreate(server.path("dest/site/stale.html"), "old")
        let replaced = queue.uploadCompressed(["site"], in: local, to: server.path("dest"), replacing: true)
        await queue.waitUntilIdle()
        #expect(job(replaced, in: queue)?.status == .done && !rawExists(server.path("dest/site/stale.html")))
        #expect(read(server.path("dest/site/index.html")) == "<p>\n")

        // Cancelled while sending: nothing new stays on the server, and what it was to replace is untouched.
        try rawCreate(server.path("dest/site/stale.html"), "old")
        try writeRandom(bytes: 150_000_000, to: local + "/site/random.bin")
        #expect(await cancelOnceUnderWay(queue) {
            queue.uploadCompressed(["site"], in: local, to: server.path("dest"), replacing: true)
        } == .cancelled)
        #expect(read(server.path("dest/site/stale.html")) == "old" && !rawExists(server.path("dest/site/random.bin")))
        #expect(leftovers(in: server.path("dest"), ".airscp-").isEmpty)

        // Many names: they go to tar on its standard input, not on a command line.
        try rawMkdir(local + "/many")
        let many = (0..<3000).map { "a fairly long file name, number \($0), as cameras and exports make them.txt" }
        for name in many { try rawCreate(local + "/many/" + name, name) }
        try rawMkdir(server.path("many"))
        let lots = queue.uploadCompressed(many, in: local + "/many", to: server.path("many"), replacing: false)
        await queue.waitUntilIdle()
        #expect(job(lots, in: queue)?.status == .done)
        #expect(names(in: server.path("many")).count == many.count)

        // A server without a shell can't unpack.
        session.capabilities.shell = false
        let refused = queue.uploadCompressed(["readme.txt"], in: local, to: server.path("dest"), replacing: false)
        await queue.waitUntilIdle()
        if case .failed(let error)? = job(refused, in: queue)?.status {
            #expect(error.kind == .sftpOnly)
        } else {
            Issue.record("uploaded compressed without a shell")
        }
    }
}

@Test func serverToServerCopies() async throws {
    try await withServer { source in
        try await withServer { target in
            let from = try await source.connectedSession()
            let to = try await target.connectedSession()
            let queue = to.transfers
            try rawMkdir(source.path("src"))
            try rawMkdir(source.path("src/project"))
            try rawCreate(source.path("src/project/main.c"), "int main;\n")
            try rawCreate(source.path("src/notes.txt"), "notes\n")
            for name in specialNames { try rawCreate(source.path("src/" + name), name) }
            try rawMkdir(target.path("dest"))
            let items = ["project", "notes.txt"] + specialNames

            // Each host's queue runs by itself: transfers to two hosts run at the same time.
            let local = try source.scratch()
            try writeRandom(bytes: 4_000_000, to: local + "/slow.bin")
            from.transfers.bandwidthLimit = 8_000
            to.transfers.bandwidthLimit = 8_000
            let first = from.transfers.upload(local + "/slow.bin", to: source.path("slow.bin"), isFolder: false)
            let second = queue.upload(local + "/slow.bin", to: target.path("slow.bin"), isFolder: false)
            #expect(await eventually {
                job(first, in: from.transfers)?.status == .running && job(second, in: queue)?.status == .running
            })
            from.transfers.cancel(first)
            queue.cancel(second)
            await from.transfers.waitUntilIdle()
            await queue.waitUntilIdle()
            from.transfers.bandwidthLimit = nil
            to.transfers.bandwidthLimit = nil

            // Both have tar: one stream through this Mac.
            let id = queue.relay(items, in: source.path("src"), from: from, to: target.path("dest"), replacing: false)
            await queue.waitUntilIdle()
            let finished = try #require(job(id, in: queue))
            #expect(finished.status == .done && finished.direction == .relay && finished.sourceHostID == from.host.id)
            #expect(finished.progress.bytes > 0 && finished.progress.percent == 100 && finished.progress.total != nil)
            #expect(contents(target.path("dest")) == contents(source.path("src")))
            #expect(Set(rawNames(in: target.path("dest"))) == Set(rawNames(in: source.path("src"))))
            #expect((await source.logEntries()).contains { $0.command.contains("-cf - --") })
            #expect((await target.logEntries()).contains { $0.command.contains("tar -xpf -") })

            // Replace: old copies go first.
            try rawCreate(target.path("dest/project/stale.c"), "old")
            let replaced = queue.relay(["project"], in: source.path("src"), from: from, to: target.path("dest"), replacing: true)
            await queue.waitUntilIdle()
            #expect(job(replaced, in: queue)?.status == .done && !rawExists(target.path("dest/project/stale.c")))

            // One side without tar: through a temporary folder on this Mac, scp down and up.
            to.capabilities.tools.remove("tar")
            try rawMkdir(target.path("dest2"))
            let fallback = queue.relay(items, in: source.path("src"), from: from, to: target.path("dest2"), replacing: false)
            await queue.waitUntilIdle()
            #expect(job(fallback, in: queue)?.status == .done)
            #expect(contents(target.path("dest2")) == contents(source.path("src")))
            #expect((await target.logEntries()).contains { $0.command.hasPrefix("/usr/bin/scp -r -p ") })
            #expect(leftovers(in: FileManager.default.temporaryDirectory.path, "airscp-relay-").isEmpty)
            to.capabilities.tools.insert("tar")

            // Cancelled: nothing partial stays on the destination.
            try writeZeros(bytes: 400 << 20, to: source.path("src/zeros"))
            #expect(await cancelOnceUnderWay(queue) {
                queue.relay(["zeros"], in: source.path("src"), from: from, to: target.path("dest"), replacing: false)
            } == .cancelled)
            #expect(await eventually {
                !rawExists(target.path("dest/zeros")) && leftovers(in: target.path("dest"), ".airscp-").isEmpty
            })

            // The source must be connected.
            await from.disconnect()
            let orphan = queue.relay(["notes.txt"], in: source.path("src"), from: from, to: target.path("dest"), replacing: true)
            await queue.waitUntilIdle()
            if case .failed(let error)? = job(orphan, in: queue)?.status {
                #expect(error.kind == .disconnected)
            } else {
                Issue.record("copied from a disconnected server")
            }
        }
    }
}

@Test func jobsLostWithTheConnectionAreRetriedAfterReconnecting() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let queue = session.transfers
        let local = try server.scratch()
        queue.bandwidthLimit = 16_000
        try writeRandom(bytes: 20_000_000, to: local + "/huge.bin")
        try write("small\n", to: server.path("small.txt"))
        let running = queue.upload(local + "/huge.bin", to: server.path("huge.bin"), isFolder: false)
        let queued = queue.download(server.path("small.txt"), to: local + "/small.txt", isFolder: false)
        #expect(await eventually { (job(running, in: queue)?.progress.bytes ?? 0) > 0 })
        try await killMaster(of: session)
        await queue.waitUntilIdle()
        if case .failed(let error)? = job(queued, in: queue)?.status { #expect(error.kind == .disconnected) } else {
            Issue.record("queued job: \(String(describing: job(queued, in: queue)?.status))")
        }
        queue.bandwidthLimit = nil
        try await session.connect()
        queue.retryDisconnected()
        await queue.waitUntilIdle()
        #expect(job(queued, in: queue)?.status == .done && read(local + "/small.txt") == "small\n")
        #expect(job(running, in: queue)?.status == .done)
        #expect(FileManager.default.contentsEqual(atPath: local + "/huge.bin", andPath: server.path("huge.bin")))
        // The cut-off upload continued where it stopped (the log's entries come on the main queue: its turn first).
        await MainActor.run {}
        #expect((await server.logEntries()).contains { $0.command.contains("reput") })
    }
}

@Test func finishedJobsAreBoundedAndTheGlobalListFollows() async throws {
    let queue = TransferQueue(hostID: UUID())  // no session: every job fails at once
    for index in 0..<(TransferQueue.finishedLimit + 50) { queue.upload("/tmp/x\(index)", to: "/x", isFolder: false) }
    await queue.waitUntilIdle()
    #expect(queue.jobs.count == TransferQueue.finishedLimit)
    #expect(queue.jobs.first?.source == "/tmp/x50")  // the oldest went
    #expect(await eventually { await MainActor.run { TransferCenter.shared.jobs.filter { $0.hostID == queue.hostID }.count }
        == TransferQueue.finishedLimit })
    queue.clearFinished()
    #expect(await eventually { await MainActor.run { !TransferCenter.shared.jobs.contains { $0.hostID == queue.hostID } } })
}

@Test func streamProgressText() {
    #expect(TransferQueue.speed(512) == "512.0B/s")
    #expect(TransferQueue.speed(5.8 * 1024 * 1024) == "5.8MB/s")
    #expect(TransferQueue.speed(1.5 * 1024 * 1024 * 1024) == "1.5GB/s")
    #expect(TransferQueue.duration(65) == "01:05" && TransferQueue.duration(3723) == "1:02:03")
    #expect(TransferQueue.operands(["a b", "-x", "it's"]) == #"'./a b' './-x' './it'\''s'"#)
}

/// PLAN.md S: big files go at plain scp speed (scp writes to the file itself; AirSCP only reads its progress meter).
/// Moves 3 GB through the disk, so it runs only with AIRSCP_BIG=1 (./test.sh with that set).
@Test(.enabled(if: Env.value("BIG") == "1"))
func oneGigabyteFileAtScpSpeed() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let queue = session.transfers
        let local = try server.scratch()
        let source = local + "/gigabyte.bin"
        FileManager.default.createFile(atPath: source, contents: nil)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: source))
        var block = [UInt8](repeating: 0, count: 8 << 20)
        for _ in 0..<128 {
            arc4random_buf(&block, block.count)
            handle.write(Data(block))
        }
        try handle.close()

        var start = Date()
        let up = queue.upload(source, to: server.path("gigabyte.bin"), isFolder: false)
        await queue.waitUntilIdle()
        let airscpUp = Date().timeIntervalSince(start)
        #expect(job(up, in: queue)?.status == .done && job(up, in: queue)?.progress.percent == 100)
        start = Date()
        let down = queue.download(server.path("gigabyte.bin"), to: local + "/back.bin", isFolder: false)
        await queue.waitUntilIdle()
        let airscpDown = Date().timeIntervalSince(start)
        #expect(job(down, in: queue)?.status == .done)
        #expect(FileManager.default.contentsEqual(atPath: source, andPath: local + "/back.bin"))
        try FileManager.default.removeItem(atPath: local + "/back.bin")

        // The same file with scp itself, over the same connection.
        start = Date()
        let plain = await Runner.run(OpenSSH.upload(source, to: server.path("plain.bin"), folder: false, preserveTimes: false,
                                                    session.host, jump: nil, socket: session.socketPath))
        let plainUp = Date().timeIntervalSince(start)
        #expect(plain.status == 0)
        print("PERF 1 GB: AirSCP upload \(String(format: "%.2f", airscpUp)) s, download \(String(format: "%.2f", airscpDown)) s; "
              + "plain scp upload \(String(format: "%.2f", plainUp)) s")
        #expect(airscpUp < plainUp * 1.5 + 2, "AirSCP took \(airscpUp) s, scp \(plainUp) s")
    }
}
