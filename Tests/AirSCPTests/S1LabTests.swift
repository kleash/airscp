import AppKit
import Darwin
import Foundation
import Testing
@testable import AirSCP
@testable import AirSCPCore

// PLAN.md S.1 against the Docker lab (AIRSCP_DOCKER=1): Find Files with GNU and BusyBox find and over sftp only,
// Synchronize with each listing (GNU ls, BusyBox ls, sftp's), and resuming over an sftp-only account.

private func touch(_ path: String, _ time: TimeInterval) {
    var times = [timeval(tv_sec: Int(time), tv_usec: 0), timeval(tv_sec: Int(time), tv_usec: 0)]
    _ = lutimes(path, &times)
}

@Suite(.enabled(if: Lab.enabled, "Docker lab: AIRSCP_DOCKER=1 ./test.sh"))
struct S1LabTests {
    /// The same tree on Debian (GNU find), Alpine (BusyBox find) and the sftp-only chroot (walked with the listing).
    @Test func findFilesOnLinuxBusyBoxAndSFTPOnly() async throws {
        try await withLab { lab in
            for (host, home) in [(Lab.target(), "/home/dev"), (Lab.minimal(), "/home/dev"), (Lab.target("sftponly"), "/upload")] {
                let session = try await lab.connected(host)
                let dir = try await lab.folder(on: session, in: home)
                for folder in ["logs", "logs/2024", "Logs Archive"] { try await session.makeDirectory(dir + "/" + folder) }
                for file in ["logs/app.log", "logs/2024/APP.LOG", "logs/readme.txt", "Logs Archive/old app.log",
                             "r\u{E9}sum\u{E9} app.log"] {
                    try await session.writeText("x\n", to: dir + "/" + file)
                }
                let (found, truncated) = try await session.find("*app*", in: dir)
                #expect(Set(found.map { String($0.path.dropFirst(dir.count + 1)) })
                        == ["logs/2024/APP.LOG", "logs/app.log", "Logs Archive/old app.log", "r\u{E9}sum\u{E9} app.log"],
                        "\(host.label): \(found)")
                #expect(!truncated && !found.contains(where: \.isFolder))
                #expect(try await session.find("logs", in: dir).items.map(\.isFolder) == [true], "\(host.label)")
            }
        }
    }

    /// Synchronize up, then compare again: nothing left, with times read from GNU ls, BusyBox ls and sftp (an old file
    /// whose time the listing shows only to the day included); a change on the server then comes down both ways.
    @MainActor @Test func synchronizeFindsNothingAfterwardsWithEveryListing() async throws {
        _ = NSApplication.shared
        try await withLab { @MainActor lab in
            for (host, home) in [(Lab.target(), "/home/dev"), (Lab.minimal(), "/home/dev"), (Lab.target("sftponly"), "/upload")] {
                let local = try scratch()
                try write("one", to: local + "/one.txt")
                try write("ancient", to: local + "/ancient.txt")
                touch(local + "/ancient.txt", 1_579_096_510)  // 2020-01-15 13:55:10 UTC: listed as "Jan 15  2020"
                try write("deep", to: local + "/sub/deeper/deep.txt")
                try write("caf\u{E9}", to: local + "/caf\u{E9}.txt")
                var saved = host
                saved.lastLocalDir = local
                let session = try await lab.connected(saved)
                let dir = try await lab.folder(on: session, in: home)
                try await session.makeDirectory(dir + "/sub")

                let browser = BrowserContentController(workspace: nil, session: session)
                _ = browser.view
                browser.stateChanged(session.state)
                let first = try await Sync.compare(local: local, remote: dir, on: session) { _ in }
                let plan = Sync.plan(first.differences, direction: .upload, delete: false)
                #expect(Set(plan.steps.map(\.path)) == ["ancient.txt", "caf\u{E9}.txt", "one.txt", "sub/deeper"], "\(host.label)")
                browser.apply(plan, on: session)
                await session.transfers.waitUntilIdle()
                #expect(session.transfers.jobs.allSatisfy { $0.status == .done }, "\(host.label): \(session.transfers.jobs.map(\.status))")
                let again = try await Sync.compare(local: local, remote: dir, on: session) { _ in }
                #expect(again.differences.isEmpty, "\(host.label): \(again.differences.map(\.path))")

                // Changed on the server since (this Mac's copy is from two minutes ago): both ways brings it down.
                touch(local + "/one.txt", Date().timeIntervalSince1970 - 120)
                try await session.writeText("newer on the server\n", to: dir + "/one.txt")
                let changed = try await Sync.compare(local: local, remote: dir, on: session) { _ in }
                let both = Sync.plan(changed.differences, direction: .both, delete: false)
                #expect(both.steps.map(\.action) == [.download] && both.steps.map(\.path) == ["one.txt"], "\(host.label)")
                browser.apply(both, on: session)
                await session.transfers.waitUntilIdle()
                #expect(read(local + "/one.txt") == "newer on the server\n", "\(host.label)")
                session.transfers.clearFinished()
            }
        }
    }

    /// Resuming works over sftp alone: a download and an upload cut off on the chroot account continue there.
    @Test func cutOffTransfersContinueOnAnSFTPOnlyAccount() async throws {
        try await withLab { lab in
            let session = try await lab.connected(Lab.target("sftponly"))
            let dir = try await lab.folder(on: session, in: "/upload")
            let local = try scratch()
            try writeRandom(bytes: 12_000_000, to: local + "/big.bin")
            let queue = session.transfers
            for download in [false, true] {
                queue.bandwidthLimit = 16_000  // 2 MB/s
                let id = download ? queue.download(dir + "/big.bin", to: local + "/back.bin", isFolder: false)
                    : queue.upload(local + "/big.bin", to: dir + "/big.bin", isFolder: false)
                // A download's part file is on this Mac; scp's meter for an upload to the lab lags, so that one gets 2 s
                // (about 4 of its 12 MB).
                let part = local + "/" + TransferQueue.partName(id)
                if download {
                    #expect(await eventually { (TransferQueue.localSize(part) ?? 0) > 1_000_000 })
                } else {
                    try await Task.sleep(nanoseconds: 2_000_000_000)
                    #expect(queue.jobs.first { $0.id == id }?.status == .running)
                }
                try await killMaster(of: session)
                await queue.waitUntilIdle()
                if case .failed(let error)? = queue.jobs.first(where: { $0.id == id })?.status {
                    #expect(error.kind == .disconnected)
                } else {
                    Issue.record("status: \(String(describing: queue.jobs.first { $0.id == id }?.status))")
                }
                queue.bandwidthLimit = nil
                try await session.connect()
                queue.retry(id)
                await queue.waitUntilIdle()
                #expect(queue.jobs.first { $0.id == id }?.status == .done)
            }
            #expect(FileManager.default.contentsEqual(atPath: local + "/big.bin", andPath: local + "/back.bin"))
            let commands = (await lab.logEntries()).map(\.command)
            #expect(commands.contains { $0.contains("reput") } && commands.contains { $0.contains("reget") })
        }
    }
}
