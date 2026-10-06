import Darwin
import Foundation
import Testing
@testable import AirSCPCore

/// Every state the queue reported, for checking what the panel would have shown.
private func watch(_ queue: TransferQueue) -> Recorder<[TransferJob]> {
    let snapshots = Recorder<[TransferJob]>()
    queue.onChange = { snapshots.append($0) }
    return snapshots
}

private func job(_ id: UUID, in queue: TransferQueue) -> TransferJob? {
    queue.jobs.first { $0.id == id }
}

/// Everything below `folder` as relative path → "dir" or the file's contents.
private func tree(_ folder: String) -> [String: String] {
    var result: [String: String] = [:]
    for case let relative as String in FileManager.default.enumerator(atPath: folder) ?? FileManager.DirectoryEnumerator() {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: folder + "/" + relative, isDirectory: &isDirectory)
        result[relative] = isDirectory.boolValue ? "dir" : (read(folder + "/" + relative) ?? "?")
    }
    return result
}

private func makeTree(at folder: String) throws {
    try write("alpha\n", to: folder + "/a.txt")
    try write("bravo\n", to: folder + "/sub/b.txt")
    try write("", to: folder + "/sub/zero")
    try FileManager.default.createDirectory(atPath: folder + "/empty", withIntermediateDirectories: true)
}

@Test func uploadAndDownloadFilesAndFolders() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let local = try server.scratch()
        let queue = session.transfers
        let snapshots = watch(queue)
        try writeRandom(bytes: 8_000_000, to: local + "/big.bin")
        try makeTree(at: local + "/tree")

        let up = queue.upload(local + "/big.bin", to: server.path("big.bin"), isFolder: false)
        let upFolder = queue.upload(local + "/tree", to: server.path("tree"), isFolder: true)
        await queue.waitUntilIdle()
        #expect(job(up, in: queue)?.status == .done)
        #expect(job(upFolder, in: queue)?.status == .done)
        #expect(FileManager.default.contentsEqual(atPath: local + "/big.bin", andPath: server.path("big.bin")))
        #expect(tree(server.path("tree")) == tree(local + "/tree"))
        // Progress came from scp's frames.
        let finished = try #require(job(up, in: queue))
        #expect(finished.progress.percent == 100 && finished.progress.filesDone == 1 && finished.progress.file == "big.bin")
        #expect(finished.progress.bytes > 7_000_000)
        #expect(job(upFolder, in: queue)?.progress.percent == 100)  // a folder goes as one tar stream
        // The owner heard about every change (changes that come close together arrive as one report, on the main queue:
        // 60 s while the suite's windows keep it busy).
        #expect(finished.started != nil)
        #expect(await eventually { snapshots.all.last?.allSatisfy { $0.status == .done } == true })

        let down = queue.download(server.path("big.bin"), to: local + "/copy.bin", isFolder: false)
        let downFolder = queue.download(server.path("tree"), to: local + "/tree copy", isFolder: true)
        await queue.waitUntilIdle()
        #expect(job(down, in: queue)?.status == .done)
        #expect(job(downFolder, in: queue)?.status == .done)
        #expect(FileManager.default.contentsEqual(atPath: local + "/big.bin", andPath: local + "/copy.bin"))
        #expect(tree(local + "/tree copy") == tree(local + "/tree"))
        #expect(!names(in: local).contains { $0.hasSuffix(".part") })

        // One at a time, in order.
        for snapshot in snapshots.all {
            #expect(snapshot.filter { $0.status == .running }.count <= 1)
        }
        queue.clearFinished()
        #expect(queue.jobs.isEmpty && !queue.isBusy)
    }
}

@Test func cancellingCleansUpPartialFiles() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let local = try server.scratch()
        let queue = session.transfers
        queue.bandwidthLimit = 16_000  // 2 MB/s: these 20 MB transfers would take 10 s each
        try writeRandom(bytes: 20_000_000, to: server.path("huge.bin"))
        try writeRandom(bytes: 20_000_000, to: local + "/huge.bin")
        try writeRandom(bytes: 9_000_000, to: server.path("victim.bin"))
        let victim = try Data(contentsOf: URL(fileURLWithPath: server.path("victim.bin")))

        /// Starts a transfer, cancels it once its partial file is there, and returns its final status.
        func cancelMidway(_ start: () -> UUID, whileExists partial: (UUID) -> String) async -> TransferJob.Status? {
            let id = start()
            let started = await eventually { (job(id, in: queue)?.progress.bytes ?? 0) > 0 && rawExists(partial(id)) }
            #expect(started, "never saw \(partial(id))")
            queue.cancel(id)
            await queue.waitUntilIdle()
            #expect(!rawExists(partial(id)))
            return job(id, in: queue)?.status
        }

        #expect(await cancelMidway({ queue.download(server.path("huge.bin"), to: local + "/dl.bin", isFolder: false) },
                                   whileExists: { local + "/" + TransferQueue.partName($0) }) == .cancelled)
        #expect(!rawExists(local + "/dl.bin"))

        #expect(await cancelMidway({ queue.upload(local + "/huge.bin", to: server.path("up.bin"), isFolder: false) },
                                   whileExists: { _ in server.path("up.bin") }) == .cancelled)
        #expect(!rawExists(server.path("up.bin")))

        // Replacing: the new copy goes to a temporary name, so the old file is untouched by a cancel.
        #expect(await cancelMidway({ queue.upload(local + "/huge.bin", to: server.path("victim.bin"), isFolder: false, replacing: true) },
                                   whileExists: { server.path(TransferQueue.partName($0)) }) == .cancelled)
        #expect((try? Data(contentsOf: URL(fileURLWithPath: server.path("victim.bin")))) == victim)

        // A queued job is just dropped.
        let first = queue.upload(local + "/huge.bin", to: server.path("first.bin"), isFolder: false)
        let second = queue.upload(local + "/huge.bin", to: server.path("second.bin"), isFolder: false)
        queue.cancel(second)
        #expect(job(second, in: queue)?.status == .cancelled)
        // Disconnecting cancels the running one and cleans up before the connection closes.
        #expect(await eventually { rawExists(server.path("first.bin")) })
        await session.disconnect()
        #expect(job(first, in: queue)?.status == .cancelled)
        #expect(!rawExists(server.path("first.bin")) && !rawExists(server.path("second.bin")))
    }
}

/// A replaced file keeps its permissions; a failed upload leaves nothing (a new file's partial copy goes) and the item
/// it was to replace as it was.
@Test func replacedFilesKeepTheirPermissionsAndFailuresLeaveNothing() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let queue = session.transfers
        let local = try server.scratch()
        try write("new\n", to: local + "/script.sh")
        chmod(local + "/script.sh", 0o644)
        try write("old\n", to: server.path("script.sh"))
        chmod(server.path("script.sh"), 0o750)
        let id = queue.upload(local + "/script.sh", to: server.path("script.sh"), isFolder: false, replacing: true)
        await queue.waitUntilIdle()
        #expect(job(id, in: queue)?.status == .done && read(server.path("script.sh")) == "new\n")
        var info = stat()
        #expect(stat(server.path("script.sh"), &info) == 0 && info.st_mode & 0o777 == 0o750)
        #expect(job(id, in: queue)?.progress.total == 4)  // the Size column shows the file's size

        // The swap fails (a folder took the name meanwhile): the old item stays, no temporary copy is left.
        try rawMkdir(server.path("taken"))
        try write("keep\n", to: server.path("taken/inside.txt"))
        let refused = queue.upload(local + "/script.sh", to: server.path("taken"), isFolder: false, replacing: true)
        await queue.waitUntilIdle()
        if case .failed? = job(refused, in: queue)?.status {} else { Issue.record("replaced a folder with a file") }
        #expect(read(server.path("taken/inside.txt")) == "keep\n")
        #expect(!names(in: server.home).contains { $0.hasPrefix(".airscp-") })
    }
}

@Test func brokenLinkInAFolderCompletesWithErrors() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let local = try server.scratch()
        // A folder goes as one tar stream: a broken link stays a (broken) link.
        try makeTree(at: local + "/tree")
        try FileManager.default.createSymbolicLink(atPath: local + "/tree/broken", withDestinationPath: "/nonexistent/target")
        let id = session.transfers.upload(local + "/tree", to: server.path("tree"), isFolder: true)
        await session.transfers.waitUntilIdle()
        #expect(job(id, in: session.transfers)?.status == .done)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: server.path("tree/broken"))) == "/nonexistent/target")

        // A file this Mac can't read: this Mac's tar would stop there, so scp -r copies the rest.
        try makeTree(at: local + "/locked")
        try write("secret\n", to: local + "/locked/a-locked.txt")
        chmod(local + "/locked/a-locked.txt", 0)
        defer { chmod(local + "/locked/a-locked.txt", 0o644) }
        let locked = session.transfers.upload(local + "/locked", to: server.path("locked"), isFolder: true)
        await session.transfers.waitUntilIdle()
        guard case .completedWithErrors(let errors)? = job(locked, in: session.transfers)?.status else {
            Issue.record("status: \(String(describing: job(locked, in: session.transfers)?.status))")
            return
        }
        #expect(errors.contains("a-locked.txt"))
        #expect(read(server.path("locked/sub/b.txt")) == "bravo\n" && read(server.path("locked/a.txt")) == "alpha\n")

        // The same on the way back: the folder arrives under its final name.
        chmod(server.path("tree/sub"), 0)
        defer { chmod(server.path("tree/sub"), 0o755) }
        let back = session.transfers.download(server.path("tree"), to: local + "/back", isFolder: true)
        await session.transfers.waitUntilIdle()
        if case .completedWithErrors? = job(back, in: session.transfers)?.status {} else {
            Issue.record("status: \(String(describing: job(back, in: session.transfers)?.status))")
        }
        #expect(read(local + "/back/a.txt") == "alpha\n" && !names(in: local).contains { $0.hasSuffix(".part") })
    }
}

/// A server link to nothing, or links that point at each other, downloaded as the panes send links (a folder job: the
/// listing doesn't say what a link points to), says so: "doesn't exist (any more), refresh" was wrong, the link is
/// there. A folder that went since its listing still says that.
@Test func aBrokenLinkSaysItLeadsNowhere() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let local = try server.scratch()
        symlink("nowhere", server.path("dangling"))
        symlink("loop-b", server.path("loop-a"))
        symlink("loop-a", server.path("loop-b"))
        for name in ["dangling", "loop-a", "gone"] {
            let id = session.transfers.download(server.path(name), to: local + "/" + name, isFolder: true)
            await session.transfers.waitUntilIdle()
            guard case .failed(let error)? = job(id, in: session.transfers)?.status else {
                Issue.record("\(name): \(String(describing: job(id, in: session.transfers)?.status))")
                continue
            }
            #expect(error.kind == .noSuchFile)
            #expect(error.message.contains(name == "gone" ? "Refresh" : "symbolic link to something that isn't there"),
                    "\(name): \(error.message)")
        }
        #expect(names(in: local).isEmpty)  // no part files left
    }
}

@Test func replaceAndKeepBoth() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let queue = session.transfers
        let local = try server.scratch()
        try write("new\n", to: local + "/report.txt")
        try write("old\n", to: server.path("report.txt"))
        try makeTree(at: local + "/site")
        try write("stale\n", to: server.path("site/stale.html"))

        // Conflicts come from the destination listing; "Keep both" uploads as "report 2.txt".
        let existing = try await session.list(server.home).map(\.name)
        #expect(Names.existing("report.txt", in: existing) == "report.txt")
        queue.upload(local + "/report.txt", to: server.path(Names.unique("report.txt", existing: existing)), isFolder: false)
        // Replace: a file is overwritten; a folder's old copy goes first (scp would copy into it).
        queue.upload(local + "/report.txt", to: server.path("report.txt"), isFolder: false, replacing: true)
        queue.upload(local + "/site", to: server.path("site"), isFolder: true, replacing: true)
        await queue.waitUntilIdle()
        #expect(queue.jobs.allSatisfy { $0.status == .done })
        #expect(read(server.path("report.txt")) == "new\n" && read(server.path("report 2.txt")) == "new\n")
        #expect(tree(server.path("site")) == tree(local + "/site"))

        // Downloads: replacing swaps the finished copy in; otherwise an existing file stays untouched.
        try write("local edit\n", to: local + "/notes.txt")
        try write("server\n", to: server.path("notes.txt"))
        let kept = queue.download(server.path("notes.txt"), to: local + "/notes.txt", isFolder: false)
        await queue.waitUntilIdle()
        if case .failed? = job(kept, in: queue)?.status {} else { Issue.record("overwrote without replacing") }
        #expect(read(local + "/notes.txt") == "local edit\n" && !names(in: local).contains { $0.hasSuffix(".part") })
        let replaced = queue.download(server.path("notes.txt"), to: local + "/notes.txt", isFolder: false, replacing: true)
        await queue.waitUntilIdle()
        #expect(job(replaced, in: queue)?.status == .done)
        #expect(read(local + "/notes.txt") == "server\n")
        // The Mac's disk ignores case, so a local conflict check should too.
        #expect(Names.existing("NOTES.txt", in: names(in: local), caseInsensitive: true) == "notes.txt")
    }
}

@Test func failedTransfersCanBeRetried() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let queue = session.transfers
        let local = try server.scratch()
        let id = queue.download(server.path("later.txt"), to: local + "/later.txt", isFolder: false)
        await queue.waitUntilIdle()
        guard case .failed(let error)? = job(id, in: queue)?.status else {
            Issue.record("status: \(String(describing: job(id, in: queue)?.status))")
            return
        }
        #expect(error.kind == .noSuchFile)
        #expect(!names(in: local).contains { $0.hasSuffix(".part") })
        try write("here now\n", to: server.path("later.txt"))
        queue.retry(id)
        await queue.waitUntilIdle()
        #expect(job(id, in: queue)?.status == .done)
        #expect(read(local + "/later.txt") == "here now\n")
        // Uploading where the server refuses: the mapped error.
        try rawMkdir(server.path("locked"))
        chmod(server.path("locked"), 0o555)
        defer { chmod(server.path("locked"), 0o755) }
        let refused = queue.upload(local + "/later.txt", to: server.path("locked/later.txt"), isFolder: false)
        await queue.waitUntilIdle()
        if case .failed(let error)? = job(refused, in: queue)?.status {
            #expect(error.kind == .permissionDenied)
        } else {
            Issue.record("status: \(String(describing: job(refused, in: queue)?.status))")
        }
    }
}

@Test func specialNamesInTransfers() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let queue = session.transfers
        let local = try server.scratch()
        try rawMkdir(local + "/up")
        try rawMkdir(local + "/down")
        try rawMkdir(server.path("remote"))
        for name in specialNames {
            try rawCreate(local + "/up/" + name, "local " + name)
            try rawCreate(server.path("remote/" + name), "remote " + name)
        }
        for name in specialNames {
            queue.upload(local + "/up/" + name, to: server.path(name), isFolder: false)
            queue.download(server.path("remote/" + name), to: local + "/down/" + name, isFolder: false)
        }
        // Folders too: their names are operands as well.
        queue.upload(local + "/up", to: server.path("caf\u{E9} up [1]*"), isFolder: true)
        queue.download(server.path("remote"), to: local + "/d\u{F6}wn 'all'", isFolder: true)
        await queue.waitUntilIdle()
        for job in queue.jobs where job.status != .done {
            Issue.record("\(job.direction) \(job.source): \(job.status)")
        }
        let exact = Set(specialNames.map { Array($0.utf8) })
        #expect(Set(rawNames(in: server.home)) == exact.union([Array("remote".utf8), Array("caf\u{E9} up [1]*".utf8)]))
        #expect(Set(rawNames(in: local + "/down")) == exact)
        #expect(Set(rawNames(in: server.path("caf\u{E9} up [1]*"))) == exact)
        #expect(Set(rawNames(in: local + "/d\u{F6}wn 'all'")) == exact)
        for name in specialNames {
            #expect(read(server.path(name)) == "local " + name)
            #expect(read(local + "/down/" + name) == "remote " + name)
        }
    }
}

@Test func lostConnectionFailsQueuedTransfers() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let queue = session.transfers
        queue.bandwidthLimit = 16_000
        let local = try server.scratch()
        try writeRandom(bytes: 20_000_000, to: local + "/huge.bin")
        try write("small\n", to: local + "/small.txt")
        let running = queue.upload(local + "/huge.bin", to: server.path("huge.bin"), isFolder: false)
        let queued = queue.upload(local + "/small.txt", to: server.path("small.txt"), isFolder: false)
        #expect(await eventually { (job(running, in: queue)?.progress.bytes ?? 0) > 0 })
        try await killMaster(of: session)
        await queue.waitUntilIdle()
        #expect(await eventually { if case .disconnected = session.state { return true } else { return false } })
        if case .failed(let error)? = job(queued, in: queue)?.status {
            #expect(error.kind == .disconnected)
        } else {
            Issue.record("queued job: \(String(describing: job(queued, in: queue)?.status))")
        }
        if case .failed? = job(running, in: queue)?.status {} else {
            Issue.record("running job: \(String(describing: job(running, in: queue)?.status))")
        }
        // After reconnecting, Retry works.
        try await session.connect()
        queue.retry(queued)
        await queue.waitUntilIdle()
        #expect(job(queued, in: queue)?.status == .done)
        #expect(read(server.path("small.txt")) == "small\n")
    }
}
