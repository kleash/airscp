import AppKit
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import AirSCP
@testable import AirSCPCore

// 1.1.0: transfers pause and resume (a single file continues where it stopped, with sftp's reget and reput as after a
// lost connection; anything else starts again), and a single file's copy is checked against the original with SHA-256
// (Verify with Checksum, Settings ▸ Verify transfers with SHA-256).

private func job(_ id: UUID, in queue: TransferQueue) -> TransferJob? {
    queue.jobs.first { $0.id == id }
}

private func same(_ a: String, _ b: String) -> Bool {
    FileManager.default.contentsEqual(atPath: a, andPath: b)
}

private func sha256(_ path: String) -> String {
    SHA256.hash(data: FileManager.default.contents(atPath: path) ?? Data()).map { String(format: "%02x", $0) }.joined()
}

/// Turns one byte of a file into another, in place, as a damaged disk or copy would.
private func corrupt(_ path: String, at offset: UInt64) throws {
    let handle = try FileHandle(forUpdating: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    try handle.seek(toOffset: offset)
    let byte = try handle.read(upToCount: 1)?.first ?? 0
    try handle.seek(toOffset: offset)
    try handle.write(contentsOf: Data([byte ^ 0xFF]))
}

/// Pauses a slow single-file transfer once its partial copy holds some bytes, and waits until it has stopped: it is
/// paused, and keeps its partial copy for Resume. Returns how many bytes that holds.
private func pauseMidway(_ queue: TransferQueue, _ id: UUID, partial: String) async -> Int64 {
    #expect(await eventually { (TransferQueue.localSize(partial) ?? 0) > 1_000_000 }, "never saw \(partial) grow")
    queue.pause([id])
    await queue.waitUntilIdle()
    #expect(job(id, in: queue)?.status == .paused && queue.isResumable(id), "\(String(describing: job(id, in: queue)))")
    return TransferQueue.localSize(partial) ?? 0
}

// MARK: Pause and resume

@Test func aPausedFileContinuesWhereItStoppedWhenResumed() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let queue = session.transfers
        let local = try server.scratch()
        try writeRandom(bytes: 20_000_000, to: server.path("down.bin"))
        try writeRandom(bytes: 20_000_000, to: local + "/new.bin")
        try writeRandom(bytes: 20_000_000, to: local + "/up.bin")
        try write("old\n", to: server.path("replaced.bin"))
        queue.bandwidthLimit = 16_000  // 2 MB/s: 10 s a file

        // A download keeps its part file, and Resume fetches the rest of it (sftp reget). Paused again during that, the
        // part file is still good up to where it stopped, and the next Resume goes on from there.
        let down = queue.download(server.path("down.bin"), to: local + "/down.bin", isFolder: false)
        let part = local + "/" + TransferQueue.partName(down)
        let kept = await pauseMidway(queue, down, partial: part)
        #expect(kept > 1_000_000 && kept < 20_000_000, "\(kept)")
        #expect(TransferText.status(try #require(job(down, in: queue))) == "Paused")
        queue.resume([down])
        #expect(await eventually { (TransferQueue.localSize(part) ?? 0) > kept + 1_000_000 }, "the resumed download didn't go on")
        queue.pause([down])
        await queue.waitUntilIdle()
        #expect(job(down, in: queue)?.status == .paused && job(down, in: queue)?.resumed == true && queue.isResumable(down))
        queue.bandwidthLimit = nil
        queue.resume([down])
        await queue.waitUntilIdle()
        #expect(job(down, in: queue)?.status == .done && job(down, in: queue)?.progress.percent == 100)
        #expect(same(server.path("down.bin"), local + "/down.bin") && !rawExists(part))

        // An upload keeps what reached the server: a new file under its own name, one that replaces a file as its part
        // file (the old file stays as it was until then). Resume sends the rest (sftp reput).
        queue.bandwidthLimit = 16_000
        let new = queue.upload(local + "/new.bin", to: server.path("new.bin"), isFolder: false)
        let newKept = await pauseMidway(queue, new, partial: server.path("new.bin"))
        #expect(newKept < 20_000_000, "\(newKept)")
        let up = queue.upload(local + "/up.bin", to: server.path("replaced.bin"), isFolder: false, replacing: true)
        _ = await pauseMidway(queue, up, partial: server.path(TransferQueue.partName(up)))
        #expect(read(server.path("replaced.bin")) == "old\n")
        queue.bandwidthLimit = nil
        queue.resume([new, up])
        await queue.waitUntilIdle()
        #expect(job(new, in: queue)?.status == .done && same(local + "/new.bin", server.path("new.bin")))
        #expect(job(up, in: queue)?.status == .done && same(local + "/up.bin", server.path("replaced.bin")))
        #expect(!rawExists(server.path(TransferQueue.partName(up))))

        // Each file went once with scp (its first try), then with sftp for the rest of it.
        let commands = (await server.logEntries()).map(\.command)
        #expect(commands.filter { $0.contains("reget") && $0.contains("sftp -b -") }.count == 2, "\(commands)")
        #expect(commands.filter { $0.contains("reput") && $0.contains("sftp -b -") }.count == 2, "\(commands)")
        for name in ["down.bin", "new.bin", "up.bin"] {
            #expect(commands.filter { $0.hasPrefix("/usr/bin/scp") && $0.contains(name) }.count == 1, "\(name): \(commands)")
        }
    }
}

/// Paused jobs (one paused while running, one while queued) stay paused through a lost connection and the reconnect,
/// with the kept part file; Cancel, and Disconnect, throw a paused job's part file away.
@Test func pausedJobsWaitThroughALostConnection() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let queue = session.transfers
        let local = try server.scratch()
        try writeRandom(bytes: 20_000_000, to: server.path("a.bin"))
        try write("b\n", to: server.path("b.txt"))
        queue.bandwidthLimit = 16_000
        let a = queue.download(server.path("a.bin"), to: local + "/a.bin", isFolder: false)
        let b = queue.download(server.path("b.txt"), to: local + "/b.txt", isFolder: false)
        let part = local + "/" + TransferQueue.partName(a)
        #expect(await eventually { (TransferQueue.localSize(part) ?? 0) > 1_000_000 })
        TransferCenter.shared.pause([a, b])  // as Pause All does, for these two
        await queue.waitUntilIdle()
        #expect(job(a, in: queue)?.status == .paused && job(b, in: queue)?.status == .paused)
        #expect(TransferText.summary(queue.jobs) == "2 paused" && !queue.jobs.contains { $0.status.isActive })

        try await killMaster(of: session)
        #expect(await eventually {
            if case .disconnected = session.state { return true }
            return false
        })
        #expect(job(a, in: queue)?.status == .paused && job(b, in: queue)?.status == .paused && rawExists(part))
        try await session.connect()
        #expect(job(a, in: queue)?.status == .paused && queue.isResumable(a))
        queue.bandwidthLimit = nil
        TransferCenter.shared.resume([a, b])  // as Resume All does
        await queue.waitUntilIdle()
        #expect(job(a, in: queue)?.status == .done && job(a, in: queue)?.resumed == true && job(b, in: queue)?.status == .done)
        #expect(same(server.path("a.bin"), local + "/a.bin") && read(local + "/b.txt") == "b\n" && !rawExists(part))

        // Cancel throws a paused download's part file away; Disconnect too.
        queue.bandwidthLimit = 16_000
        let c = queue.download(server.path("a.bin"), to: local + "/c.bin", isFolder: false)
        _ = await pauseMidway(queue, c, partial: local + "/" + TransferQueue.partName(c))
        queue.cancel(c)
        #expect(job(c, in: queue)?.status == .cancelled && !queue.isResumable(c) && !rawExists(local + "/" + TransferQueue.partName(c)))
        let d = queue.download(server.path("a.bin"), to: local + "/d.bin", isFolder: false)
        _ = await pauseMidway(queue, d, partial: local + "/" + TransferQueue.partName(d))
        await session.disconnect()
        #expect(job(d, in: queue)?.status == .cancelled && !rawExists(local + "/" + TransferQueue.partName(d)))
    }
}

/// A folder (a tar stream) that is paused leaves nothing behind, either way, and starts again when resumed.
@Test func aPausedFolderStartsAgainWhenResumed() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let queue = session.transfers
        let local = try server.scratch()
        try write("<p>\n", to: local + "/site/index.html")
        try writeZeros(bytes: 400 << 20, to: local + "/site/zeros")
        let up = queue.upload(local + "/site", to: server.path("site"), isFolder: true)
        #expect(await eventually { (job(up, in: queue)?.progress.bytes ?? 0) > 0 })
        queue.pause([up])
        await queue.waitUntilIdle()
        #expect(job(up, in: queue)?.status == .paused && !queue.isResumable(up))
        #expect(!rawExists(server.path("site")) && !names(in: server.home).contains { $0.hasPrefix(".airscp-") })
        #expect(TransferText.note(try #require(job(up, in: queue)))?.contains("starts it again") == true)
        queue.resume([up])
        await queue.waitUntilIdle()
        #expect(job(up, in: queue)?.status == .done && read(server.path("site/index.html")) == "<p>\n")
        #expect(TransferQueue.localSize(server.path("site/zeros")) == 400 << 20)

        let down = queue.download(server.path("site"), to: local + "/back", isFolder: true)
        #expect(await eventually { (job(down, in: queue)?.progress.bytes ?? 0) > 0 })
        queue.pause([down])
        await queue.waitUntilIdle()
        #expect(job(down, in: queue)?.status == .paused)
        #expect(!rawExists(local + "/back") && !names(in: local).contains { $0.hasPrefix(".airscp-") })
        queue.resume([down])
        await queue.waitUntilIdle()
        #expect(job(down, in: queue)?.status == .done && TransferQueue.localSize(local + "/back/zeros") == 400 << 20)
    }
}

// MARK: Checksums

@Test func copiesAreCheckedWithSHA256AndAMismatchIsCopiedAgain() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let queue = session.transfers
        let local = try server.scratch()
        try writeRandom(bytes: 3_000_000, to: local + "/up.bin")
        try writeRandom(bytes: 3_000_000, to: server.path("down.bin"))

        // Settings ▸ Verify transfers with SHA-256: each file's copy is checked once it has arrived.
        queue.verifiesTransfers = true
        let up = queue.upload(local + "/up.bin", to: server.path("up.bin"), isFolder: false)
        let down = queue.download(server.path("down.bin"), to: local + "/down.bin", isFolder: false)
        await queue.waitUntilIdle()
        #expect(job(up, in: queue)?.checksum == .verified(sha256(local + "/up.bin")))
        #expect(job(down, in: queue)?.checksum == .verified(sha256(server.path("down.bin"))))
        #expect(TransferText.status(try #require(job(up, in: queue))) == "Verified" && job(up, in: queue)?.status == .done)
        queue.verifiesTransfers = false

        // A damaged copy, on the server and on this Mac: Verify with Checksum finds it, and Retry copies the file again
        // in its place and checks the new copy.
        try corrupt(server.path("up.bin"), at: 1_000_000)
        try corrupt(local + "/down.bin", at: 2_000_000)
        queue.verify([up, down])
        await queue.waitUntilIdle()
        #expect(job(up, in: queue)?.checksum == .mismatch(original: sha256(local + "/up.bin"), copy: sha256(server.path("up.bin"))))
        #expect(job(down, in: queue)?.checksum
                == .mismatch(original: sha256(server.path("down.bin")), copy: sha256(local + "/down.bin")))
        let mismatch = try #require(job(up, in: queue))
        #expect(TransferText.status(mismatch) == "Mismatch" && TransferText.canRetry(mismatch))
        #expect(TransferText.problem(mismatch)?.details.contains(sha256(local + "/up.bin")) == true)
        // The panel's Retry, with a file that is fine selected too: only the mismatches are copied again.
        try write("fine\n", to: local + "/fine.txt")
        let fine = queue.upload(local + "/fine.txt", to: server.path("fine.txt"), isFolder: false)
        await queue.waitUntilIdle()
        let ids = [up, down, fine]
        await MainActor.run {
            TransfersPanel.actions(for: TransferCenter.shared.currentJobs.filter { ids.contains($0.id) })
                .first { $0.title == "Retry" }?.run()
        }
        await queue.waitUntilIdle()
        #expect(job(fine, in: queue)?.status == .done && job(fine, in: queue)?.checksum == nil)
        #expect(job(up, in: queue)?.checksum == .verified(sha256(local + "/up.bin")) && same(local + "/up.bin", server.path("up.bin")))
        #expect(job(down, in: queue)?.checksum == .verified(sha256(server.path("down.bin"))))
        #expect(same(server.path("down.bin"), local + "/down.bin"))
        let commands = (await server.logEntries()).map(\.command)
        #expect(commands.contains { $0.contains("sha256sum") }, "\(commands)")
        #expect(commands.filter { $0.hasPrefix("/usr/bin/scp") && $0.contains("fine.txt") }.count == 1, "\(commands)")

        // A copy that can't be checked says why (the file on this Mac has gone); a folder isn't checked.
        unlink(local + "/down.bin")
        queue.verify([down])
        await queue.waitUntilIdle()
        if case .unchecked(let reason)? = job(down, in: queue)?.checksum {
            #expect(reason.contains("Can't read down.bin on this Mac"), "\(reason)")
        } else {
            Issue.record("\(String(describing: job(down, in: queue)?.checksum))")
        }
        try write("x\n", to: local + "/folder/x.txt")
        let folder = queue.upload(local + "/folder", to: server.path("folder"), isFolder: true)
        await queue.waitUntilIdle()
        #expect(job(folder, in: queue)?.canVerify == false)
        queue.verify([folder])
        await queue.waitUntilIdle()
        #expect(job(folder, in: queue)?.checksum == nil)
    }
}

/// An sftp-only account runs no commands, so its server can't work out a checksum: the job says so.
@Test func anSFTPOnlyAccountsCopiesSayWhyTheyArentChecked() async throws {
    try await withServer(TestServer.Options(sftpOnly: true)) { server in
        let session = try await server.connectedSession()
        let queue = session.transfers
        let local = try server.scratch()
        try write("hello\n", to: local + "/a.txt")
        queue.verifiesTransfers = true
        let id = queue.upload(local + "/a.txt", to: server.path("a.txt"), isFolder: false)
        await queue.waitUntilIdle()
        #expect(job(id, in: queue)?.status == .done)
        if case .unchecked(let reason)? = job(id, in: queue)?.checksum {
            #expect(reason.contains("sftp"), "\(reason)")
        } else {
            Issue.record("\(String(describing: job(id, in: queue)?.checksum))")
        }
        #expect(TransferText.status(try #require(job(id, in: queue))) == "Not verified")
    }
}

/// What the Transfers panel shows for paused jobs and checks.
@MainActor @Test func pausedAndCheckedJobsInTheirOwnWords() {
    func job(_ status: TransferJob.Status, folder: Bool = false, checksum: TransferJob.Checksum? = nil,
             percent: Int = 0) -> TransferJob {
        var job = TransferJob(id: UUID(), direction: .upload, hostID: UUID(), sourceHostID: nil, source: "/Users/me/a.bin",
                              destination: "/srv/a.bin", names: [], isFolder: folder, replacing: false, preserveTimes: false)
        job.status = status
        job.checksum = checksum
        job.progress.percent = percent
        return job
    }
    let paused = job(.paused, percent: 40)
    #expect(TransferText.status(paused) == "Paused" && TransferText.fraction(paused) == 0.4)
    #expect(TransferText.note(paused) == "Paused: Resume continues where it stopped" && TransferText.canResume(paused))
    #expect(TransferText.note(job(.paused, folder: true))?.contains("starts it again") == true)
    #expect(TransferText.fraction(job(.paused)) == nil && !TransferText.canRetry(paused) && !paused.status.isFinished)
    #expect(TransferText.summary([paused, job(.running), job(.queued)]) == "1 running, 1 queued, 1 paused")
    #expect(AppModel.activeTransferCounts([paused]).isEmpty)  // no badge, no App Nap held off

    #expect(TransferText.status(job(.running, checksum: .checking)) == "Verifying")
    #expect(TransferText.status(job(.done, checksum: .wanted)) == "Waiting to verify")
    let verified = job(.done, checksum: .verified(String(repeating: "a", count: 64)))
    #expect(TransferText.status(verified) == "Verified" && TransferText.problem(verified) == nil && !TransferText.canRetry(verified))
    #expect(TransferText.note(verified)?.hasSuffix(String(repeating: "a", count: 64)) == true && verified.canVerify)
    let mismatch = job(.done, checksum: .mismatch(original: "1", copy: "2"))
    #expect(TransferText.status(mismatch) == "Mismatch" && TransferText.canRetry(mismatch))
    #expect(TransferText.problem(mismatch)?.details == "Original: 1\nCopy:     2")
    #expect(TransferText.summary([mismatch]) == "1 with problems")
    let unchecked = job(.done, checksum: .unchecked("Not today."))
    #expect(TransferText.status(unchecked) == "Not verified" && TransferText.note(unchecked) == "Not verified: Not today.")
    #expect(!job(.done, checksum: .checking).canVerify && !job(.done, folder: true).canVerify && job(.done).canVerify)
    // The context menu's commands for a running job, and for a finished one.
    let running = TransfersPanel.actions(for: [job(.running)]), done = TransfersPanel.actions(for: [job(.done)])
    #expect(running.filter(\.enabled).map(\.title) == ["Pause", "Cancel"])
    #expect(done.filter(\.enabled).map(\.title) == ["Remove", "Verify with Checksum"])
    #expect(TransfersPanel.actions(for: [paused]).filter(\.enabled).map(\.title) == ["Resume", "Cancel"])
    #expect(TransfersPanel.actions(for: [mismatch]).filter(\.enabled).map(\.title)
            == ["Retry", "Remove", "Verify with Checksum", "Show Details…"])
}

// MARK: Agent control

/// An agent pauses, resumes and checks a download through the Transfers panel's context menu: the snapshot says Paused
/// (and how it goes on) and Verified (with the SHA-256), and a wait for the transfers returns while one is paused. (Pause
/// All and Resume All aren't pressed: they would reach the other tests' transfers.)
@MainActor @Test func agentPausesResumesAndVerifiesATransfer() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        var host = server.host()
        host.label = "lab"
        let local = try server.scratch()
        host.lastLocalDir = local
        try writeRandom(bytes: 20_000_000, to: server.path("agent-pause.bin"))
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
        #expect(await call(agent, "wait", ["until": "connected", "timeout": 20]).error == nil)
        let session = try #require(main.selectedWorkspace?.session)
        // 250 KB/s: still running however long a busy Mac takes for the agent's requests (80 s for the file).
        session.transfers.bandwidthLimit = 2_000
        _ = await call(agent, "wait", ["until": "listed", "pane": "right", "text": "agent-pause.bin", "timeout": 20])
        _ = await call(agent, "select", ["pane": "right", "names": ["agent-pause.bin"]])
        let reply = await call(agent, "drop", ["from": "right", "to": "local:" + local])
        let id = try #require(((reply["jobs"] as? [[String: Any]])?.first?["id"] as? String).flatMap { UUID(uuidString: $0) },
                              "\(reply.json) \(reply.error ?? "")")
        #expect(await eventually { (TransferQueue.localSize(local + "/" + TransferQueue.partName(id)) ?? 0) > 100_000 })
        func job() async -> [String: Any]? {
            let transfers = await call(agent, "snapshot", ["include": ["transfers"]])["transfers"] as? [String: Any]
            return (transfers?["jobs"] as? [[String: Any]])?.first { $0["id"] as? String == id.uuidString }
        }

        #expect(await call(agent, "select", ["pane": "transfers", "ids": [id.uuidString]]).error == nil)
        #expect(await call(agent, "menu", ["path": "context > Pause", "pane": "transfers"]).error == nil)
        #expect(await call(agent, "wait", ["until": "transfers_done", "host": "lab", "timeout": 60]).error == nil)
        var now = await job()
        #expect(now?["status"] as? String == "Paused" && now?["resumable"] as? Bool == true, "\(now ?? [:])")
        #expect(now?["note"] as? String == "Paused: Resume continues where it stopped", "\(now ?? [:])")
        let elements = await call(agent, "snapshot", ["include": ["elements"]])["elements"] as? [[String: Any]] ?? []
        let resumeAll = elements.first { $0["id"] as? String == "transfers.resumeAll" }
        #expect(resumeAll?["enabled"] as? Bool == true && resumeAll?["help"] as? String == "Continue every paused transfer")

        session.transfers.bandwidthLimit = nil
        #expect(await call(agent, "menu", ["path": "context > Resume", "pane": "transfers"]).error == nil)
        #expect(await call(agent, "wait", ["until": "transfers_done", "host": "lab", "timeout": 60]).error == nil)
        now = await job()
        #expect(now?["status"] as? String == "Done" && now?["resumed"] as? Bool == true, "\(now ?? [:])")
        #expect(same(server.path("agent-pause.bin"), local + "/agent-pause.bin"))

        #expect(await call(agent, "menu", ["path": "context > Verify with Checksum", "pane": "transfers"]).error == nil)
        #expect(await call(agent, "wait", ["until": "transfers_done", "host": "lab", "timeout": 60]).error == nil)
        now = await job()
        #expect(now?["status"] as? String == "Verified" && now?["sha256"] as? String == sha256(local + "/agent-pause.bin"),
                "\(now ?? [:])")
        _ = await call(agent, "menu", ["path": "Host > Disconnect"])
        #expect(await call(agent, "wait", ["until": "disconnected", "timeout": 20]).error == nil)
    }
}

// MARK: The Docker lab (AIRSCP_DOCKER=1)

@Suite(.enabled(if: Lab.enabled, "Docker lab: AIRSCP_DOCKER=1 ./test.sh"))
struct PauseAndVerifyLabTests {
    /// Paused, then resumed: an upload and a download continue where they stopped on Debian, on Alpine (BusyBox) and on
    /// the sftp-only account (sftp reput and reget), and the download comes back the same as what went up.
    @Test func pausedTransfersContinueOnLinuxBusyBoxAndOverSFTPOnly() async throws {
        try await withLab { lab in
            let local = try scratch()
            try writeRandom(bytes: 12_000_000, to: local + "/big.bin")
            for (host, home) in [(Lab.target(), "/home/dev"), (Lab.minimal(), "/home/dev"), (Lab.target("sftponly"), "/upload")] {
                let session = try await lab.connected(host)
                let dir = try await lab.folder(on: session, in: home)
                let queue = session.transfers
                let back = local + "/back-\(host.username)-\(host.port ?? 22).bin"
                for download in [false, true] {
                    queue.bandwidthLimit = 16_000  // 2 MB/s: 6 s for the file
                    let id = download ? queue.download(dir + "/big.bin", to: back, isFolder: false)
                        : queue.upload(local + "/big.bin", to: dir + "/big.bin", isFolder: false)
                    #expect(await eventually { (job(id, in: queue)?.progress.bytes ?? 0) > 2_000_000 }, "\(host.label)")
                    queue.pause([id])
                    await queue.waitUntilIdle()
                    #expect(job(id, in: queue)?.status == .paused && queue.isResumable(id), "\(host.label): \(String(describing: job(id, in: queue)))")
                    queue.bandwidthLimit = nil
                    queue.resume([id])
                    await queue.waitUntilIdle()
                    #expect(job(id, in: queue)?.status == .done && job(id, in: queue)?.resumed == true,
                            "\(host.label): \(String(describing: job(id, in: queue)))")
                }
                #expect(same(local + "/big.bin", back), "\(host.label)")
            }
            let commands = (await lab.logEntries()).map(\.command)
            #expect(commands.filter { $0.contains("reput") }.count == 3 && commands.filter { $0.contains("reget") }.count == 3,
                    "\(commands.filter { $0.contains("sftp -b -") })")
        }
    }

    /// Copies are checked with GNU's sha256sum (Debian) and BusyBox's (Alpine), both ways; a copy damaged on the server
    /// is found by Verify with Checksum, and Retry copies the file again. The name has a backslash, which GNU's sha256sum
    /// escapes (its line then starts with one). The sftp-only account says why it can't check.
    @Test func copiesAreCheckedWithGNUAndBusyBoxSha256sum() async throws {
        try await withLab { lab in
            let local = try scratch()
            try writeRandom(bytes: 2_000_000, to: local + "/up.bin")
            // A known byte where the server's copy gets damaged below, so that the damage changes it.
            let handle = try FileHandle(forUpdating: URL(fileURLWithPath: local + "/up.bin"))
            try handle.seek(toOffset: 1000)
            try handle.write(contentsOf: Data([0]))
            try handle.close()
            let original = sha256(local + "/up.bin")
            for host in [Lab.target(), Lab.minimal()] {
                let session = try await lab.connected(host)
                let dir = try await lab.folder(on: session, in: "/home/dev")
                let queue = session.transfers
                queue.verifiesTransfers = true
                let remote = dir + "/up\\load.bin"
                let up = queue.upload(local + "/up.bin", to: remote, isFolder: false)
                await queue.waitUntilIdle()
                #expect(job(up, in: queue)?.checksum == .verified(original), "\(host.label): \(String(describing: job(up, in: queue)))")
                let back = local + "/back-\(host.port ?? 22).bin"
                let down = queue.download(remote, to: back, isFolder: false)
                await queue.waitUntilIdle()
                #expect(job(down, in: queue)?.checksum == .verified(original), "\(host.label)")
                queue.verifiesTransfers = false

                try await session.shell("printf X | dd of=\(Quote.shell(remote)) bs=1 seek=1000 conv=notrunc 2>/dev/null")
                queue.verify([up])
                await queue.waitUntilIdle()
                if case .mismatch(let before, let copy)? = job(up, in: queue)?.checksum {
                    #expect(before == original && copy != original && copy.count == 64, "\(host.label)")
                } else {
                    Issue.record("\(host.label): \(String(describing: job(up, in: queue)?.checksum))")
                }
                queue.retry(up)
                await queue.waitUntilIdle()
                #expect(job(up, in: queue)?.status == .done && job(up, in: queue)?.checksum == .verified(original), "\(host.label)")
            }
            let commands = (await lab.logEntries()).map(\.command)
            #expect(commands.filter { $0.contains("sha256sum") }.count >= 8, "\(commands.count) commands")

            let sftp = try await lab.connected(Lab.target("sftponly"))
            let dir = try await lab.folder(on: sftp, in: "/upload")
            sftp.transfers.verifiesTransfers = true
            let id = sftp.transfers.upload(local + "/up.bin", to: dir + "/up.bin", isFolder: false)
            await sftp.transfers.waitUntilIdle()
            if case .unchecked(let reason)? = job(id, in: sftp.transfers)?.checksum {
                #expect(reason.contains("sftp"), "\(reason)")
            } else {
                Issue.record("\(String(describing: job(id, in: sftp.transfers)))")
            }
        }
    }
}
