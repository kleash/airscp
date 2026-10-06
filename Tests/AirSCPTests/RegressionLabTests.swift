import Darwin
import Foundation
import Testing
@testable import AirSCPCore

// Regression tests for the first break-it round against the Docker lab (AIRSCP_DOCKER=1): Linux servers' tools (GNU
// tar, BusyBox ls), their limits, case-sensitive disks, and jump hosts.

@Suite(.enabled(if: Lab.enabled, "Docker lab: AIRSCP_DOCKER=1 ./test.sh"))
struct RegressionLabTests {
    /// BusyBox's ls lists the folder in one round trip (sftp needs one per 100 entries); where it can't print a name
    /// (anything outside ASCII, in the C locale) the listing comes from sftp, exactly.
    @Test func busyBoxFoldersAreListedWithLs() async throws {
        try await withLab { lab in
            let session = try await lab.connected(Lab.minimal())
            let dir = try await lab.folder(on: session, in: "/home/dev")
            try await session.shell("cd \(Quote.shell(dir)) && touch plain.txt 'with space' && ln -s plain.txt link")
            let before = await lab.logEntries().count
            #expect(Set(try await session.list(dir).map(\.name)) == ["plain.txt", "with space", "link"])
            let commands = (await lab.logEntries()).dropFirst(before).map(\.command)
            #expect(!commands.contains { $0.hasPrefix("printf") && $0.contains("/usr/bin/sftp") }, "\(commands)")

            try await session.shell("cd \(Quote.shell(dir)) && touch \(Quote.shell("caf\u{E9}.txt"))")
            #expect(try await session.list(dir).contains { $0.name == "caf\u{E9}.txt" })
        }
    }

    /// GNU tar in the C locale writes names outside ASCII as escapes: Extract Here still finds them as conflicts.
    @Test func extractConflictsWithNamesOutsideASCII() async throws {
        try await withLab { lab in
            let session = try await lab.connected(Lab.target())
            let dir = try await lab.folder(on: session, in: "/home/dev")
            let names = ["r\u{E9}sum\u{E9}.txt", "Gr\u{FC}\u{DF}e"]
            try await session.shell("cd \(Quote.shell(dir)) && for n in \(names.map(Quote.shell).joined(separator: " ")); do "
                                    + "echo OLD > \"$n\"; done && tar -czf docs.tar.gz -- \(names.map(Quote.shell).joined(separator: " "))")
            let archive = try #require(try await session.list(dir).first { $0.name == "docs.tar.gz" })
            #expect(try await session.extractConflicts(archive) == names.sorted())
        }
    }

    /// A Linux folder holding names that differ only in case keeps one of each on this Mac's disk: the download says so
    /// instead of reporting Done.
    @Test func caseClashesOnTheWayToTheMacAreReported() async throws {
        try await withLab { lab in
            let session = try await lab.connected(Lab.target())
            let dir = try await lab.folder(on: session, in: "/home/dev")
            try await session.shell("cd \(Quote.shell(dir)) && mkdir tree && echo lower > tree/readme.txt "
                                    + "&& echo UPPER > tree/README.txt && echo x > tree/other.txt")
            let local = try scratch()
            let id = session.transfers.download(dir + "/tree", to: local + "/tree", isFolder: true)
            await session.transfers.waitUntilIdle()
            guard case .completedWithErrors(let text)? = session.transfers.jobs.first(where: { $0.id == id })?.status else {
                Issue.record("status: \(String(describing: session.transfers.jobs.first { $0.id == id }?.status))")
                return
            }
            #expect(text.contains("differ only in case") && text.lowercased().contains("readme.txt"), "\(text)")
        }
    }

    /// Thousands of selected names: a server takes at most 128 KB in one argument. They go to `sh -s` on standard
    /// input instead of a command line.
    @Test func thousandsOfNamesOnLinux() async throws {
        try await withLab { lab in
            let session = try await lab.connected(Lab.target())
            let dir = try await lab.folder(on: session, in: "/home/dev")
            try await session.shell("cd \(Quote.shell(dir)) && i=0; while [ $i -lt 3000 ]; do "
                                    + "mkdir \"Project backup folder from the old server number $i\"; i=$((i+1)); done")
            let names = (0..<3000).map { "Project backup folder from the old server number \($0)" }
            let local = try scratch()
            let id = session.transfers.downloadArchive(names, in: dir, to: local + "/all.tar.gz", extract: true)
            await session.transfers.waitUntilIdle()
            #expect(session.transfers.jobs.first { $0.id == id }?.status == .done)
            #expect(AirSCPTests.names(in: local).count == 3000)
            try await session.delete(try await session.list(dir))
            #expect(try await session.list(dir).isEmpty)
            #expect(session.state == .connected)
        }
    }

    /// Through a jump host, the master's connect timeout would also run while the user answers the jump host's password
    /// prompt: an answer after 17 s connects.
    @Test func aJumpHostsPasswordMayTakeItsTime() async throws {
        try await withLab { lab in
            let bastion = Lab.bastion(password: true)
            var target = Lab.host("dev", hostname: "target", port: 22)
            target.jumpHostID = bastion.id
            let session = try lab.session(target, jump: bastion)
            session.onPrompt = { prompt, reply in
                guard prompt.host?.id == bastion.id else { return reply(nil) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 17) { reply(PromptAnswer(Lab.jumpPassword)) }
            }
            let start = Date()
            try await session.connect()
            #expect(session.state == .connected && Date().timeIntervalSince(start) > 16)
        }
    }
}
