import AppKit
import Darwin
import Foundation
import Testing
@testable import AirSCP
@testable import AirSCPCore

// The feature cycle's round 1 (fix step) against the Docker lab (AIRSCP_DOCKER=1): what needs a Linux server (names
// that differ only in case or in their Unicode form are different files there).

@Suite(.enabled(if: Lab.enabled, "Docker lab: AIRSCP_DOCKER=1 ./test.sh"))
struct FeatureRoundLabTests {
    /// Download as .tar.gz with Extract: names that differ only in case overwrote each other on this Mac's disk and the
    /// job still said Done.
    @Test func anExtractedArchiveSaysWhichNamesOverwroteEachOther() async throws {
        try await withLab { lab in
            let session = try await lab.connected(Lab.target())
            let dir = try await lab.folder(on: session, in: "/home/dev")
            try await session.shell("cd \(Quote.shell(dir)) && mkdir -p ctw/inner && echo upper > ctw/README && echo lower > ctw/readme "
                                    + "&& echo A > ctw/inner/A.txt && echo a > ctw/inner/a.txt && echo x > ctw/other.txt "
                                    + "&& echo nfc > \(Quote.shell("ctw/caf\u{E9}.txt")) && echo nfd > \(Quote.shell("ctw/cafe\u{301}.txt"))")
            let local = try scratch()
            let id = session.transfers.downloadArchive(["ctw"], in: dir, to: local + "/ctw.tar.gz", extract: true)
            await session.transfers.waitUntilIdle()
            guard case .completedWithErrors(let text)? = job(id, in: session)?.status else {
                Issue.record("status: \(String(describing: job(id, in: session)?.status))")
                return
            }
            #expect(text.contains("differ only in case") && text.contains("ctw/README") && text.contains("ctw/inner/A.txt"), "\(text)")
            // Names that differ only in their Unicode form too (one Set<String> made them one, and their clash went unsaid).
            let bytes = Data(text.utf8)
            #expect(bytes.range(of: Data("ctw/caf\u{E9}.txt".utf8)) != nil && bytes.range(of: Data("ctw/cafe\u{301}.txt".utf8)) != nil,
                    "\(text)")
            #expect(read(local + "/ctw/other.txt") == "x\n" && !rawExists(local + "/ctw.tar.gz"))
        }
    }

    /// Round 1's files and transfers testers, on GNU and BusyBox servers: a link to a file downloads as the file (it was
    /// taken for a folder, and its cd failed); a pipe says it can't be copied; a file over six months old lists as its
    /// day (it showed midnight UTC as a local time of day); a selection's permissions change in one command.
    @Test func linksOldDatesAndPermissionsOnLinux() async throws {
        try await withLab { lab in
            for host in [Lab.target(), Lab.minimal()] {
                let session = try await lab.connected(host)
                let dir = try await lab.folder(on: session, in: "/home/dev")
                try await session.shell("cd \(Quote.shell(dir)) && echo hello > plain.txt && touch -d '2021-06-15 12:00' plain.txt && "
                                        + "ln -s plain.txt tofile && mkdir sub && echo in > sub/in.txt && ln -s sub tofolder && mkfifo pipe")
                let local = try scratch()
                let pipe = session.transfers.download(dir + "/pipe", to: local + "/pipe", isFolder: true)
                for name in ["tofile", "tofolder"] { session.transfers.download(dir + "/" + name, to: local + "/" + name, isFolder: true) }
                await session.transfers.waitUntilIdle()
                #expect(read(local + "/tofile") == "hello\n" && read(local + "/tofolder/in.txt") == "in\n", "\(host.port)")
                guard case .failed(let error)? = job(pipe, in: session)?.status else {
                    Issue.record("\(host.port): \(String(describing: job(pipe, in: session)?.status))")
                    continue
                }
                #expect(error.message.contains("a pipe, a socket or a device") && !rawExists(local + "/pipe"), "\(host.port): \(error)")
                let entries = try await session.list(dir)
                let plain = try #require(entries.first { $0.name == "plain.txt" })
                #expect(plain.dateOnly && plain.modified == Date(timeIntervalSince1970: 1_623_715_200), "\(host.port): \(plain)")
                let changed = entries.filter { $0.kind == .file || $0.kind == .other }
                try await session.setPermissions(changed) { _ in 0o600 }
                #expect(try await session.list(dir).filter { $0.kind == .file || $0.kind == .other }.allSatisfy { $0.mode == 0o600 },
                        "\(host.port)")
            }
        }
    }

    /// Synchronize's compare lists a level of folders in one command with GNU ls and with BusyBox's; a folder BusyBox
    /// shows with "?" in a name is left to be listed alone (through sftp, which shows it right).
    @Test func foldersAreListedTogetherWithGNUAndBusyBox() async throws {
        try await withLab { lab in
            for host in [Lab.target(), Lab.minimal()] {
                let session = try await lab.connected(host)
                let dir = try await lab.folder(on: session, in: "/home/dev")
                try await session.shell("cd \(Quote.shell(dir)) && mkdir -p 'a b/x' c d && echo 1 > 'a b/one' && echo 2 > c/two "
                                        + "&& echo 3 > \(Quote.shell("d/caf\u{E9}"))")
                let listed = try await session.listings([dir + "/a b", dir + "/c", dir + "/d", dir + "/missing"])
                #expect(listed.count == 4 && listed[0]?.map(\.name).sorted() == ["one", "x"] && listed[1]?.map(\.name) == ["two"],
                        "\(host.port) \(listed.map { $0?.map(\.name) })")
                let busybox = host.port == Lab.minimalPort
                #expect((listed[2]?.map(\.name) == ["caf\u{E9}"]) == !busybox && (listed[2] == nil) == busybox && listed[3] == nil)
            }
            // 301 folders (the testers' tree took 20 s, a command per folder).
            let session = try await lab.connected(Lab.target())
            let dir = try await lab.folder(on: session, in: "/home/dev")
            try await session.shell("cd \(Quote.shell(dir)) && for a in $(seq 1 15); do for b in $(seq 1 19); do mkdir -p d$a/e$b; done; done")
            let local = try scratch()
            for a in 1...15 {
                for b in 1...19 { try FileManager.default.createDirectory(atPath: local + "/d\(a)/e\(b)", withIntermediateDirectories: true) }
            }
            let started = Date()
            let comparison = try await Sync.compare(local: local, remote: dir, on: session) { _ in }
            let seconds = Date().timeIntervalSince(started)
            print("PERF Synchronize compare of 301 folders on the lab target: \(String(format: "%.2f", seconds)) s")
            #expect(comparison.folders == 301 && comparison.differences.isEmpty && seconds < 10)
        }
    }

    /// On Linux "café" composed (NFC) and decomposed (NFD) are two names: an agent selects exactly the one it names
    /// (both were selected), and Rename to the other spelling renames (it did nothing).
    @MainActor @Test func namesInTheirOtherUnicodeFormAreOtherNames() async throws {
        _ = NSApplication.shared
        try await withLab { @MainActor lab in
            let session = try await lab.connected(Lab.target())
            let dir = try await lab.folder(on: session, in: "/home/dev")
            let nfc = "caf\u{E9}", nfd = "cafe\u{301}"
            try await session.shell("cd \(Quote.shell(dir)) && echo composed > \(Quote.shell(nfc + ".txt")) "
                                    + "&& echo decomposed > \(Quote.shell(nfd + ".txt")) && mkdir \(Quote.shell(nfd + " folder"))")
            await session.disconnect()
            var host = Lab.target()
            host.label = "target"
            host.defaultRemoteDir = dir
            let model = testModel([host])
            let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
            defer { askpass.close() }
            let (main, agent, _) = try agentWindow(model, askpass)
            defer {
                agent.close()
                main.window?.orderOut(nil)
            }
            _ = await call(agent, "select", ["pane": "sidebar", "names": ["target"]])
            _ = await call(agent, "menu", ["path": "Host > Connect"])
            #expect(await call(agent, "wait", ["until": "connected", "timeout": 30]).error == nil)
            #expect(await call(agent, "wait", ["until": "listed", "pane": "right", "text": nfd + " folder", "timeout": 30]).error == nil)
            var reply = await call(agent, "select", ["pane": "right", "names": [nfc + ".txt"]])
            let selected = ((reply["pane"] as? [String: Any])?["selected"] as? [String]) ?? []
            #expect(selected.map { Array($0.utf8) } == [Array((nfc + ".txt").utf8)], "\(selected.map { Array($0.utf8) })")
            // The decomposed folder renamed to its composed spelling.
            _ = await call(agent, "select", ["pane": "right", "names": [nfd + " folder"]])
            reply = await call(agent, "menu", ["path": "File > Rename…"])
            #expect(sheet(reply)?["title"] != nil, "\(reply.error ?? "")")
            _ = await call(agent, "set", ["id": "prompt.name", "value": nfc + " folder"])
            _ = await call(agent, "press", ["title": "Rename"])
            #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 10]).error == nil)
            let check = try await lab.connected(Lab.target())
            let names = try await check.shell("cd \(Quote.shell(dir)) && ls -d *folder | od -An -c | tr -d ' \\n'")
            #expect(names.contains("c a f 303 251".replacingOccurrences(of: " ", with: "")) && !names.contains("314201"), "\(names)")
            _ = await call(agent, "menu", ["path": "Host > Disconnect"])
            _ = await call(agent, "wait", ["until": "disconnected", "timeout": 20])
        }
    }
}
