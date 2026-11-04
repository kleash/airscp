#if canImport(AirSCPSSH2)
import AirSCPSSH2
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import AirSCPCore

// The transfer queue over libssh2 (the iPhone and iPad app's): files and folders over SFTP a step at a time, with the
// progress, part files, resume, pause, SHA-256 checks and server-to-server copies the queue has over ssh.

/// Each path under `root` and what it is: "file <content>", "dir", or "link <target>".
private func tree(_ root: String) -> [String: String] {
    var items: [String: String] = [:]
    for relative in (try? FileManager.default.subpathsOfDirectory(atPath: root)) ?? [] {
        let path = root + "/" + relative
        if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) {
            items[relative] = "link " + target
        } else if FileManager.default.isDirectory(path) {
            items[relative] = "dir"
        } else {
            items[relative] = "file " + (read(path) ?? "?")
        }
    }
    return items
}

private extension FileManager {
    func isDirectory(_ path: String) -> Bool {
        var folder: ObjCBool = false
        return fileExists(atPath: path, isDirectory: &folder) && folder.boolValue
    }
}

private func sha256(_ path: String) -> String {
    SHA256.hash(data: FileManager.default.contents(atPath: path) ?? Data()).map { String(format: "%02x", $0) }.joined()
}

private func same(_ a: String, _ b: String) -> Bool {
    FileManager.default.contentsEqual(atPath: a, andPath: b)
}

@Suite struct SSH2TransferTests {
    /// Uploads and downloads of a file (a new one, one that replaces, one checked with SHA-256) and of a folder with
    /// awkward names, a dot file and a link, which stays a link.
    @Test func filesAndFoldersGoBothWays() async throws {
        try await withServer { server in
            let session = try server.ssh2Session()
            try await session.connect()
            let queue = session.transfers
            let local = try server.scratch()
            try writeRandom(bytes: 3_000_000, to: local + "/up.bin")
            try write("old\n", to: server.path("replaced.txt"))
            chmod(server.path("replaced.txt"), 0o640)
            try write("new\n", to: local + "/replacing.txt")

            queue.verifiesTransfers = true
            let up = queue.upload(local + "/up.bin", to: server.path("up.bin"), isFolder: false)
            let replace = queue.upload(local + "/replacing.txt", to: server.path("replaced.txt"), isFolder: false, replacing: true)
            let down = queue.download(server.path("up.bin"), to: local + "/down.bin", isFolder: false)
            await queue.waitUntilIdle()
            let hash = sha256(local + "/up.bin")
            for id in [up, down] {
                let done = try #require(job(id, in: session))
                #expect(done.status == .done && done.checksum == .verified(hash), "\(done)")
                #expect(done.progress.percent == 100 && done.progress.total == 3_000_000 && done.progress.bytes == 3_000_000,
                        "\(done.progress)")
            }
            #expect(same(local + "/up.bin", server.path("up.bin")) && same(local + "/up.bin", local + "/down.bin"))
            #expect(job(replace, in: session)?.status == .done && read(server.path("replaced.txt")) == "new\n")
            #expect(try FileManager.default.attributesOfItem(atPath: server.path("replaced.txt"))[.posixPermissions] as? Int == 0o640)
            queue.verifiesTransfers = false

            let sample = try server.makeSampleFolder()
            let upFolder = queue.upload(sample, to: server.path("copy"), isFolder: true)
            await queue.waitUntilIdle()
            #expect(job(upFolder, in: session)?.status == .done, "\(String(describing: job(upFolder, in: session)))")
            // Counted first: "3 of 4 files done, 1 to go" while it ran, and a percentage (the link isn't a file).
            #expect(job(upFolder, in: session)?.progress.filesTotal == 4 && job(upFolder, in: session)?.progress.percent == 100)
            #expect(tree(server.path("copy")) == tree(sample) && tree(sample)["link"] == "link a file.txt", "\(tree(server.path("copy")))")
            let downFolder = queue.download(server.path("copy"), to: local + "/copy", isFolder: true)
            await queue.waitUntilIdle()
            let folder = try #require(job(downFolder, in: session))
            #expect(folder.status == .done && folder.progress.filesDone == 4 && folder.progress.filesTotal == 4, "\(folder)")
            #expect(folder.progress.total == folder.progress.bytes && folder.progress.percent == 100, "\(folder.progress)")
            #expect(tree(local + "/copy") == tree(sample))
            #expect(!names(in: local).contains { $0.hasPrefix(".airscp-") } && !names(in: server.home).contains { $0.hasPrefix(".airscp-") })
        }
    }

    /// A file that can't be read is left out of a folder's copy and named; the rest is copied.
    @Test func anUnreadableFileIsLeftOutOfAFolderAndNamed() async throws {
        try await withServer { server in
            let session = try server.ssh2Session()
            try await session.connect()
            let local = try server.scratch()
            try write("fine\n", to: local + "/folder/fine.txt")
            try write("secret\n", to: local + "/folder/secret.txt")
            chmod(local + "/folder/secret.txt", 0o000)
            defer { chmod(local + "/folder/secret.txt", 0o644) }
            let id = session.transfers.upload(local + "/folder", to: server.path("folder"), isFolder: true)
            await session.transfers.waitUntilIdle()
            if case .completedWithErrors(let text)? = job(id, in: session)?.status {
                #expect(text.contains("secret.txt") && text.contains("Permission denied"), "\(text)")
            } else {
                Issue.record("\(String(describing: job(id, in: session)?.status))")
            }
            #expect(names(in: server.path("folder")) == ["fine.txt"])
        }
    }

    /// Paused, a file keeps its part (a download's here, an upload's on the server) and Resume continues it; a lost
    /// connection does the same for Retry. Listings go on while a transfer runs. Cancel throws the part away.
    @Test func aPausedOrCutOffFileContinuesFromItsPart() async throws {
        try await withServer { server in
            let session = try server.ssh2Session()
            try await session.connect()
            let queue = session.transfers
            let local = try server.scratch()
            try writeRandom(bytes: 20_000_000, to: server.path("down.bin"))
            try writeRandom(bytes: 20_000_000, to: local + "/up.bin")
            try write("old\n", to: server.path("replaced.bin"))
            queue.bandwidthLimit = 16_000  // 2 MB/s: 10 s a file

            let down = queue.download(server.path("down.bin"), to: local + "/down.bin", isFolder: false)
            let part = local + "/" + TransferQueue.partName(down)
            #expect(await eventually { (TransferQueue.localSize(part) ?? 0) > 1_000_000 }, "never saw \(part) grow")
            // The same connection lists a folder meanwhile: the transfer goes a step at a time.
            #expect(try await session.list(server.home).contains { $0.name == "down.bin" })
            #expect(job(down, in: session)?.status == .running)
            queue.pause([down])
            await queue.waitUntilIdle()
            let kept = TransferQueue.localSize(part) ?? 0
            #expect(job(down, in: session)?.status == .paused && queue.isResumable(down) && kept > 1_000_000 && kept < 20_000_000)
            queue.bandwidthLimit = nil
            queue.resume([down])
            await queue.waitUntilIdle()
            #expect(job(down, in: session)?.status == .done && job(down, in: session)?.resumed == true)
            #expect(same(server.path("down.bin"), local + "/down.bin") && !rawExists(part))

            // An upload that replaces a file keeps its part on the server, the old file as it was until the end.
            queue.bandwidthLimit = 16_000
            let up = queue.upload(local + "/up.bin", to: server.path("replaced.bin"), isFolder: false, replacing: true)
            let upPart = server.path(TransferQueue.partName(up))
            #expect(await eventually { (TransferQueue.localSize(upPart) ?? 0) > 1_000_000 }, "never saw \(upPart) grow")
            queue.pause([up])
            await queue.waitUntilIdle()
            #expect(job(up, in: session)?.status == .paused && read(server.path("replaced.bin")) == "old\n")
            queue.bandwidthLimit = nil
            queue.resume([up])
            await queue.waitUntilIdle()
            #expect(job(up, in: session)?.status == .done && job(up, in: session)?.resumed == true)
            #expect(same(local + "/up.bin", server.path("replaced.bin")) && !rawExists(upPart))

            // A lost connection: the new file uploaded under its own name stays as far as it got, and Retry sends the rest.
            queue.bandwidthLimit = 16_000
            let new = queue.upload(local + "/up.bin", to: server.path("new.bin"), isFolder: false)
            #expect(await eventually { (TransferQueue.localSize(server.path("new.bin")) ?? 0) > 1_000_000 })
            let sshd = try String(contentsOfFile: server.root + "/sshd.pid").trimmingCharacters(in: .whitespacesAndNewlines)
            try await run(["/usr/bin/pkill", "-P", sshd])
            await queue.waitUntilIdle()
            if case .failed(let error)? = job(new, in: session)?.status {
                #expect(error.kind == .disconnected, "\(error)")
            } else {
                Issue.record("\(String(describing: job(new, in: session)?.status))")
            }
            #expect(queue.isResumable(new))
            queue.bandwidthLimit = nil
            try await session.connect()
            queue.retry(new)
            await queue.waitUntilIdle()
            #expect(job(new, in: session)?.status == .done && job(new, in: session)?.resumed == true)
            #expect(same(local + "/up.bin", server.path("new.bin")))

            // Cancel: the part goes.
            queue.bandwidthLimit = 16_000
            let cancelled = queue.download(server.path("down.bin"), to: local + "/again.bin", isFolder: false)
            let cancelledPart = local + "/" + TransferQueue.partName(cancelled)
            #expect(await eventually { (TransferQueue.localSize(cancelledPart) ?? 0) > 1_000_000 })
            queue.cancel(cancelled)
            await queue.waitUntilIdle()
            #expect(job(cancelled, in: session)?.status == .cancelled && !rawExists(cancelledPart) && !rawExists(local + "/again.bin"))
        }
    }

    /// Server to server through a temporary folder here: a file and a folder (its link a link still) into a hidden
    /// folder first, then into place, replacing what is there; an sftp-only account as the destination too.
    @Test func aCopyBetweenServersGoesThroughThisDevice() async throws {
        try await withServer { source in
            try await withServer(TestServer.Options(sftpOnly: true)) { target in
                let from = try source.ssh2Session()
                try await from.connect()
                let to = try target.ssh2Session()
                try await to.connect()
                let sample = try source.makeSampleFolder()
                try write("from the source\n", to: source.path("notes.txt"))
                try write("old notes\n", to: target.path("notes.txt"))
                let id = to.transfers.relay(["notes.txt", "sample"], in: source.home, from: from, to: target.home, replacing: true)
                await to.transfers.waitUntilIdle()
                let copy = try #require(job(id, in: to))
                #expect(copy.status == .done && copy.progress.bytes > 0, "\(copy)")
                #expect(read(target.path("notes.txt")) == "from the source\n" && tree(target.path("sample")) == tree(sample))
                #expect(!names(in: target.home).contains { $0.hasPrefix(".airscp-") })
            }
        }
    }
}

/// The same against the lab's Debian target and its sftp-only account, in folders of their own (removed afterwards).
@Suite(.enabled(if: Lab.enabled, "Docker lab: AIRSCP_DOCKER=1 ./test.sh"))
struct SSH2TransferLabTests {
    @Test func filesGoBothWaysCheckedAndResumed() async throws {
        try await withLab { lab in
            let local = try scratch()
            try writeRandom(bytes: 12_000_000, to: local + "/big.bin")
            let hash = sha256(local + "/big.bin")
            for (host, home) in [(Lab.target(), "/home/dev"), (Lab.target("sftponly"), "/upload")] {
                let knownHosts = TestEnvironment.root + "/ssh2_known_hosts." + UUID().uuidString.prefix(8)
                let session = try lab.session(host, transport: SSH2Transport(host: host, jump: nil, knownHosts: knownHosts))
                try await session.connect()
                let dir = try await lab.folder(on: session, in: home)
                let queue = session.transfers
                queue.verifiesTransfers = true
                let back = local + "/back-\(host.username).bin"
                for download in [false, true] {
                    queue.bandwidthLimit = 16_000  // 2 MB/s: 6 s for the file
                    let id = download ? queue.download(dir + "/big.bin", to: back, isFolder: false)
                        : queue.upload(local + "/big.bin", to: dir + "/big.bin", isFolder: false)
                    #expect(await eventually { (job(id, in: session)?.progress.bytes ?? 0) > 2_000_000 }, "\(host.label)")
                    queue.pause([id])
                    await queue.waitUntilIdle()
                    #expect(job(id, in: session)?.status == .paused && queue.isResumable(id), "\(host.label)")
                    queue.bandwidthLimit = nil
                    queue.resume([id])
                    await queue.waitUntilIdle()
                    let done = try #require(job(id, in: session))
                    #expect(done.status == .done && done.resumed, "\(host.label): \(done)")
                    // The sftp-only account runs no sha256sum: it says why it can't check.
                    if host.username == "sftponly" {
                        if case .unchecked? = done.checksum {} else { Issue.record("\(host.label): \(String(describing: done.checksum))") }
                    } else {
                        #expect(done.checksum == .verified(hash), "\(host.label): \(String(describing: done.checksum))")
                    }
                }
                #expect(same(local + "/big.bin", back), "\(host.label)")
            }
        }
    }
}
#endif
