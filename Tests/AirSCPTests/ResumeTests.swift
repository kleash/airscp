import Darwin
import Foundation
import Testing
@testable import AirSCP
@testable import AirSCPCore

// PLAN.md S.1: a single file that a lost connection cut off continues where it stopped when retried (sftp reget and
// reput), instead of starting again.

private func job(_ id: UUID, in queue: TransferQueue) -> TransferJob? {
    queue.jobs.first { $0.id == id }
}

private func same(_ a: String, _ b: String) -> Bool {
    FileManager.default.contentsEqual(atPath: a, andPath: b)
}

/// Starts a slow transfer, kills the master connection once its partial copy (`partial`) holds some bytes, as a
/// dropped network would, and connects again. Returns the job and how many bytes its partial copy kept.
private func cutOff(_ session: Session, _ start: () -> UUID, partial: (UUID) -> String) async throws -> (UUID, Int64) {
    let queue = session.transfers
    queue.bandwidthLimit = 16_000  // 2 MB/s: the 20 MB files below take 10 s
    let id = start()
    #expect(await eventually { (TransferQueue.localSize(partial(id)) ?? 0) > 1_000_000 }, "never saw \(partial(id)) grow")
    try await killMaster(of: session)
    await queue.waitUntilIdle()
    if case .failed(let error)? = job(id, in: queue)?.status {
        #expect(error.kind == .disconnected, "\(error)")
    } else {
        Issue.record("status: \(String(describing: job(id, in: queue)?.status))")
    }
    queue.bandwidthLimit = nil
    try await session.connect()
    return (id, TransferQueue.localSize(partial(id)) ?? 0)
}

@Test func aFileCutOffByALostConnectionContinuesWhereItStopped() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let queue = session.transfers
        let local = try server.scratch()
        try writeRandom(bytes: 20_000_000, to: server.path("down.bin"))
        try writeRandom(bytes: 20_000_000, to: local + "/new.bin")
        try writeRandom(bytes: 20_000_000, to: local + "/up.bin")
        try write("old\n", to: server.path("replaced.bin"))

        // A download keeps its part file, and the retry fetches only the rest of it (sftp reget).
        let downPart = { (id: UUID) in local + "/" + TransferQueue.partName(id) }
        let (down, downKept) = try await cutOff(session, {
            queue.download(server.path("down.bin"), to: local + "/down.bin", isFolder: false)
        }, partial: downPart)
        #expect(downKept > 1_000_000 && downKept < 20_000_000, "\(downKept)")
        queue.retry(down)
        await queue.waitUntilIdle()
        #expect(job(down, in: queue)?.status == .done)
        #expect(same(server.path("down.bin"), local + "/down.bin") && !rawExists(downPart(down)))
        #expect(job(down, in: queue)?.progress.percent == 100)  // sftp's meter, read like scp's

        // An upload keeps what reached the server, and the retry sends only the rest (sftp reput): a new file under its
        // own name, one that replaces a file as its part file (the old file stays as it was until then).
        let (new, newKept) = try await cutOff(session, {
            queue.upload(local + "/new.bin", to: server.path("new.bin"), isFolder: false)
        }, partial: { _ in server.path("new.bin") })
        #expect(newKept > 1_000_000 && newKept < 20_000_000, "\(newKept)")
        queue.retry(new)
        await queue.waitUntilIdle()
        #expect(job(new, in: queue)?.status == .done && same(local + "/new.bin", server.path("new.bin")))

        let upPart = { (id: UUID) in server.path(TransferQueue.partName(id)) }
        let (up, upKept) = try await cutOff(session, {
            queue.upload(local + "/up.bin", to: server.path("replaced.bin"), isFolder: false, replacing: true)
        }, partial: upPart)
        #expect(upKept > 1_000_000 && upKept < 20_000_000, "\(upKept)")
        #expect(read(server.path("replaced.bin")) == "old\n")
        queue.retry(up)
        await queue.waitUntilIdle()
        #expect(job(up, in: queue)?.status == .done && same(local + "/up.bin", server.path("replaced.bin")))
        #expect(!rawExists(upPart(up)))

        let commands = (await server.logEntries()).map(\.command)
        #expect(commands.filter { $0.contains("reget") && $0.contains("sftp -b -") }.count == 1, "\(commands)")
        #expect(commands.filter { $0.contains("reput") && $0.contains("sftp -b -") }.count == 2, "\(commands)")
        // Each file went once with scp (its first try) and once with sftp (the rest of it).
        for name in ["down.bin", "new.bin", "up.bin"] {
            #expect(commands.filter { $0.hasPrefix("/usr/bin/scp") && $0.contains(name) }.count == 1, "\(name): \(commands)")
        }
    }
}

/// When sftp can't continue the partial copy the retry starts afresh; a cut-off download that won't be retried leaves
/// no part file behind.
/// Retry while the host was still reconnecting failed at once with "Not connected. Click Connect…" (the banner had only
/// Cancel) and said it had resumed. The panel's Retry now waits for the connection; a retry made anyway doesn't claim to
/// resume, and the job continues by itself once reconnected.
@Test func aRetryWhileReconnectingWaitsForTheConnection() async throws {
    try await withServer { server in
        // The test proxy plays the network: while it is away the host keeps reconnecting (after a killed master it was
        // back before the retry on a busy Mac, and the retry really resumed).
        let proxy = try TestProxy()
        defer { proxy.stop() }
        let saved = proxy.saved()
        var host = server.host()
        host.autoReconnect = true
        host.proxyID = saved.id
        let session = try server.session(host)
        answer(saved, on: session.askpass)
        try await session.connect()
        let queue = session.transfers
        let local = try server.scratch()
        try writeRandom(bytes: 20_000_000, to: server.path("down.bin"))
        queue.bandwidthLimit = 16_000
        let id = queue.download(server.path("down.bin"), to: local + "/down.bin", isFolder: false)
        #expect(await eventually { (TransferQueue.localSize(local + "/" + TransferQueue.partName(id)) ?? 0) > 1_000_000 })
        proxy.away = true
        await queue.waitUntilIdle()
        queue.bandwidthLimit = nil
        #expect(await eventually { TransferCenter.shared.isReconnecting(session.host.id) })
        #expect(!TransferText.canRetry(try #require(job(id, in: queue))))  // the panel's Retry waits, and says why
        queue.retry(id)
        await queue.waitUntilIdle()
        #expect(job(id, in: queue)?.resumed == false && queue.isResumable(id), "\(String(describing: job(id, in: queue)))")
        proxy.away = false
        #expect(await eventually { job(id, in: queue)?.status == .done })
        #expect(same(server.path("down.bin"), local + "/down.bin") && !TransferCenter.shared.isReconnecting(session.host.id))
    }
}

@Test func aRetryThatCantContinueStartsAfresh() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let queue = session.transfers
        let local = try server.scratch()
        let part = { (id: UUID) in local + "/" + TransferQueue.partName(id) }
        try writeRandom(bytes: 20_000_000, to: server.path("down.bin"))
        let (down, _) = try await cutOff(session, {
            queue.download(server.path("down.bin"), to: local + "/down.bin", isFolder: false)
        }, partial: part)
        // The file on the server is now shorter than the part file: sftp can't continue it, so scp starts again.
        try writeRandom(bytes: 100_000, to: server.path("down.bin"))
        queue.retry(down)
        await queue.waitUntilIdle()
        #expect(job(down, in: queue)?.status == .done && same(server.path("down.bin"), local + "/down.bin"))
        let commands = (await server.logEntries()).map(\.command)
        #expect(commands.filter { $0.hasPrefix("/usr/bin/scp") && $0.contains("down.bin") }.count == 2, "\(commands)")

        // The kept part file is gone: the retry starts afresh, and doesn't say it continued.
        try writeRandom(bytes: 20_000_000, to: server.path("gone.bin"))
        let (gone, _) = try await cutOff(session, {
            queue.download(server.path("gone.bin"), to: local + "/gone.bin", isFolder: false)
        }, partial: part)
        unlink(part(gone))
        queue.retry(gone)
        await queue.waitUntilIdle()
        #expect(job(gone, in: queue)?.status == .done && job(gone, in: queue)?.resumed == false)
        #expect(same(server.path("gone.bin"), local + "/gone.bin"))

        // A new file's upload cut off, then given up: what arrived of it goes from the server too.
        try writeRandom(bytes: 20_000_000, to: local + "/up.bin")
        let (up, _) = try await cutOff(session, {
            queue.upload(local + "/up.bin", to: server.path("up.bin"), isFolder: false)
        }, partial: { _ in server.path("up.bin") })
        queue.remove(up)
        #expect(await eventually { !rawExists(server.path("up.bin")) })

        // Cut off, then removed from the list (or cleared, or Cancel All): its part file goes.
        try writeRandom(bytes: 20_000_000, to: server.path("other.bin"))
        let (other, kept) = try await cutOff(session, {
            queue.download(server.path("other.bin"), to: local + "/other.bin", isFolder: false)
        }, partial: part)
        #expect(kept > 0)
        queue.remove(other)
        #expect(!rawExists(part(other)) && job(other, in: queue) == nil)
        // Cut off, and the connection then closed (as quitting does): its part file goes too.
        let (third, _) = try await cutOff(session, {
            queue.download(server.path("other.bin"), to: local + "/third.bin", isFolder: false)
        }, partial: part)
        #expect(rawExists(part(third)))
        await session.disconnect()
        #expect(!rawExists(part(third)))
    }
}
