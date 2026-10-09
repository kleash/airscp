import AppKit
import Darwin
import Foundation
import SwiftUI
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

    /// A compare of 5,000 files in 50 folders stays fast (beside a node_modules of 2,000 that Leave out keeps it from
    /// listing), and so does the sheet that lists the 5,000 uploads: drawn, one item unticked, Select None.
    @MainActor @Test func aCompareOf5000FilesStaysFast() async throws {
        _ = NSApplication.shared
        try await withLab { @MainActor lab in
            let session = try await lab.connected(Lab.target())
            let dir = try await lab.folder(on: session, in: "/home/dev")
            // The server's copies are older and smaller: every Mac file is an upload.
            try await session.shell("cd \(Quote.shell(dir)) && for a in $(seq 1 50); do mkdir d$a && (cd d$a && seq -f 'f%g.txt' 1 100 "
                                    + "| xargs touch -t 202001011200); done && for a in $(seq 1 20); do mkdir -p node_modules/m$a "
                                    + "&& (cd node_modules/m$a && seq -f 'f%g.js' 1 100 | xargs touch); done")
            let local = try scratch()
            for (folder, count, ext) in [("d", 50, "txt"), ("node_modules/m", 20, "js")] {
                for a in 1...count {
                    try FileManager.default.createDirectory(atPath: local + "/\(folder)\(a)", withIntermediateDirectories: true)
                    for b in 1...100 { FileManager.default.createFile(atPath: local + "/\(folder)\(a)/f\(b).\(ext)", contents: Data("mac".utf8)) }
                }
            }
            var comparison = Sync.Comparison()
            let seconds = try await timed {
                comparison = try await Sync.compare(local: local, remote: dir, on: session, leavingOut: ["node_modules", "*.log"]) { _ in }
            }
            print("PERF Synchronize compare of 5,000 files in 51 folders on the lab target: \(String(format: "%.2f", seconds)) s")
            #expect(comparison.folders == 51 && comparison.differences.count == 5_000 && seconds < 10,
                    "\(comparison.folders) \(comparison.differences.count) \(seconds)")

            // The sheet with its 5,000 rows, shown as the app shows it.
            let model = SyncModel(session: session, localDir: local, remoteDir: dir, leaveOut: "node_modules, *.log")
            model.compare()
            #expect(await eventually { model.comparison != nil })
            let parent = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 700), styleMask: [.titled],
                                  backing: .buffered, defer: false)
            parent.orderFront(nil)
            @MainActor func drawn(_ change: () -> Void) -> TimeInterval {
                let start = Date()
                change()
                parent.attachedSheet?.contentView?.layoutSubtreeIfNeeded()
                parent.attachedSheet?.display()
                return Date().timeIntervalSince(start)
            }
            let shown = drawn { presentSheet(on: parent) { _ in SyncView(model: model, close: {}, synchronize: { _ in }) } }
            let window = try #require(parent.attachedSheet)
            let unticked = drawn { model.unticked.insert("d7/f42.txt") }
            let none = drawn { model.unticked = Set(model.plan.steps.map(\.path)) }
            print("PERF Synchronize sheet with 5,000 rows: drawn \(String(format: "%.2f", shown)) s, one unticked "
                  + "\(String(format: "%.2f", unticked)) s, Select None \(String(format: "%.2f", none)) s")
            #expect(model.plan.steps.count == 5_000 && model.chosen.steps.isEmpty && max(shown, unticked, none) < 10)
            model.unticked = ["d7/f42.txt"]
            #expect(model.summary.hasPrefix("\(4_999.formatted()) uploads (\(FileList.size(4_999 * 3)))\n1 unticked"), "\(model.summary)")
            parent.endSheet(window)
            parent.orderOut(nil)
        }
    }

    /// Unticked items are neither copied nor deleted, and what matches Leave out isn't either (inside a new folder too,
    /// where it goes as a stream: GNU and BusyBox tar; an sftp-only account copies a new folder whole, as the sheet
    /// says).
    @MainActor @Test func untickedItemsAreNeitherCopiedNorDeleted() async throws {
        _ = NSApplication.shared
        try await withLab { @MainActor lab in
            for (host, home) in [(Lab.target(), "/home/dev"), (Lab.minimal(), "/home/dev"), (Lab.target("sftponly"), "/upload")] {
                let local = try scratch()
                for path in ["keep.txt", "skip.txt", "app.log", "newdir/a.txt", "newdir/b.log", "skipdir/x.txt"] {
                    try write("mac", to: local + "/" + path)
                }
                var saved = host
                saved.lastLocalDir = local
                let session = try await lab.connected(saved)
                let dir = try await lab.folder(on: session, in: home)
                for name in ["stale.txt", "gone.txt", "old.log"] { try await session.writeText("server\n", to: dir + "/" + name) }
                let browser = BrowserContentController(workspace: nil, session: session)
                _ = browser.view
                browser.stateChanged(session.state)

                let model = SyncModel(session: session, localDir: local, remoteDir: dir, leaveOut: "*.log")
                model.delete = true
                model.compare()
                #expect(await eventually { model.comparison != nil })
                #expect(model.plan.steps.map(\.path) == ["gone.txt", "keep.txt", "newdir", "skip.txt", "skipdir", "stale.txt"],
                        "\(host.label): \(model.plan.steps.map(\.path))")
                model.unticked = ["skip.txt", "skipdir", "stale.txt"]
                let streams = host.username != "sftponly"  // GNU and BusyBox tar
                #expect(model.leaveOutNote.hasSuffix(streams ? "wherever it is." : "(this server can't run tar)."), "\(host.label)")
                browser.apply(model.chosen, on: session, excluding: model.patterns)
                await session.transfers.waitUntilIdle()
                #expect(session.transfers.jobs.allSatisfy { $0.status == .done }, "\(host.label): \(session.transfers.jobs.map(\.status))")
                var names: [String] = []
                #expect(await eventually {
                    names = (try? await session.list(dir).map(\.name).sorted()) ?? []
                    return !names.contains("gone.txt")
                }, "\(host.label): \(names)")
                #expect(names == ["keep.txt", "newdir", "old.log", "stale.txt"], "\(host.label): \(names)")
                let inside = try await session.list(dir + "/newdir").map(\.name).sorted()
                #expect(inside == (streams ? ["a.txt"] : ["a.txt", "b.log"]), "\(host.label): \(inside)")
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
