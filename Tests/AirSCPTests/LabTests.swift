import Darwin
import Foundation
import Testing
@testable import AirSCPCore

// What the throwaway user-mode sshd can't play, against the Docker lab (testenv/): PAM and password logins with
// Remember, a jump host into a private network, a chroot sftp-only account, login noise, BusyBox, and the performance
// targets of PLAN.md S (a 50 000-entry folder; multi-GB files at plain scp speed).

@Suite(.enabled(if: Lab.enabled, "Docker lab: AIRSCP_DOCKER=1 ./test.sh"))
struct LabTests {
    @Test func pamPasswordIsAskedRememberedAndReused() async throws {
        // Debian with PAM: the password comes as a keyboard-interactive prompt.
        try await checkPasswordLogin(Lab.target(password: true), password: Lab.devPassword,
                                     prompt: "(dev@127.0.0.1) Password: ")
    }

    @Test func passwordMethodIsAskedRememberedAndReused() async throws {
        // Alpine without PAM: ssh's "password" method.
        try await checkPasswordLogin(Lab.minimal(password: true), password: Lab.minimalPassword,
                                     prompt: "dev@127.0.0.1's password: ")
        try await withLab { lab in
            // Cancelling the prompt fails the connection.
            let session = try lab.session(Lab.minimal(password: true)) { _ in nil }
            await #expect(throws: AirSCPError.self) { try await session.connect() }
            #expect(session.state == .idle && !lab.prompts.all.isEmpty)
        }
    }

    @Test func jumpHostChainGivesEachHostItsOwnPassword() async throws {
        try await withLab { lab in
            let bastion = Lab.bastion(password: true)
            var target = Lab.host("dev", hostname: "target", port: 22, password: true)  // only inside the lab
            target.jumpHostID = bastion.id
            let saved = Recorder<String>()
            let session = try lab.session(target, jump: bastion) { prompt in
                if prompt.host?.id == bastion.id { return PromptAnswer(Lab.jumpPassword, remember: true) }
                if prompt.host?.id == target.id { return PromptAnswer(Lab.devPassword, remember: true) }
                return nil
            }
            session.savePassword = { owner, password in saved.append(owner.username + "=" + password) }
            try await session.connect()
            let asked = lab.prompts.all
            #expect(asked.map(\.text) == ["jump@127.0.0.1's password: ", "(dev@target) Password: "])
            #expect(asked.map(\.kind) == [.password(user: "jump", host: "127.0.0.1"), .password(user: "dev", host: "target")])
            #expect(asked.map { $0.host?.id } == [bastion.id, target.id])
            #expect(Set(saved.all) == ["jump=\(Lab.jumpPassword)", "dev=\(Lab.devPassword)"])
            #expect(try await session.run("hostname").output.hasSuffix("target\n"))

            // A transfer rides the chain too.
            let dir = try await lab.folder(on: session, in: "/home/dev")
            let local = try scratch()
            try writeRandom(bytes: 2_000_000, to: local + "/up.bin")
            session.transfers.upload(local + "/up.bin", to: dir + "/up.bin", isFolder: false)
            session.transfers.download(dir + "/up.bin", to: local + "/back.bin", isFolder: false)
            await session.transfers.waitUntilIdle()
            #expect(session.transfers.jobs.allSatisfy { $0.status == .done })
            #expect(FileManager.default.contentsEqual(atPath: local + "/up.bin", andPath: local + "/back.bin"))

            // With both passwords saved, nothing is asked: each went to its own host.
            let again = try lab.session(target, jump: bastion)
            again.savedPassword = { $0.id == bastion.id ? Lab.jumpPassword : $0.id == target.id ? Lab.devPassword : nil }
            await session.disconnect()
            try await again.connect()
            #expect(again.state == .connected && lab.prompts.all.count == 2)
        }
    }

    @Test func sftpOnlyAccountInAChroot() async throws {
        try await withLab { lab in
            let session = try await lab.connected(Lab.target("sftponly"))
            let capabilities = session.capabilities
            #expect(!capabilities.shell && capabilities.home == "/upload")
            #expect(capabilities.noShellReason == "This account allows file transfers (sftp) only.")
            #expect(session.compressUnavailableReason(.tarGz) == capabilities.noShellReason)
            await #expect(throws: AirSCPError.self) { try await session.run("id") }
            // The chroot is all it sees.
            #expect(try await session.list("/").map(\.name) == ["upload"])
            do {
                _ = try await session.list("/etc")
                Issue.record("listed /etc outside the chroot")
            } catch let error as AirSCPError {
                #expect(error.kind == .noSuchFile)
            }

            // Files, transfers, and folders deleted by walking them with sftp.
            let dir = try await lab.folder(on: session, in: "/upload")
            try await session.makeDirectory(dir + "/sub")
            try await session.writeText("hello\n", to: dir + "/sub/a.txt")
            let local = try scratch()
            try write("up\n", to: local + "/up.txt")
            session.transfers.upload(local + "/up.txt", to: dir + "/sub/up.txt", isFolder: false)
            session.transfers.download(dir + "/sub", to: local + "/down", isFolder: true)
            await session.transfers.waitUntilIdle()
            #expect(session.transfers.jobs.allSatisfy { $0.status == .done })
            #expect(read(local + "/down/a.txt") == "hello\n" && read(local + "/down/up.txt") == "up\n")
            let sub = try #require(try await session.list(dir).first { $0.name == "sub" })
            try await session.delete([sub])
            #expect(try await session.list(dir).isEmpty)
            #expect(!(await lab.logEntries()).contains { $0.command.contains("rm -rf") })
        }
    }

    @Test func loginNoiseAndEachServersTools() async throws {
        try await withLab { lab in
            // Debian: dev's .bashrc prints to both outputs; parsed output stays clean.
            let target = try await lab.connected(Lab.target())
            #expect(target.capabilities.shell && target.capabilities.home == "/home/dev")
            #expect(target.capabilities.tools.isSuperset(of: ["zip", "unzip", "tar", "gzip", "python3"]))
            let raw = try await target.run("echo hi")
            #expect(raw.output.contains(".bashrc noise") && raw.output.hasSuffix("hi\n"))
            #expect(raw.stderr.contains(".bashrc noise on standard error"))
            let dir = try await lab.folder(on: target, in: "/home/dev")
            try await target.writeText(String(repeating: "x", count: 10_000), to: dir + "/data.txt")
            let data = try #require(try await target.list(dir).first)
            #expect((try await target.folderSizes([data.name], in: dir)[data.name] ?? 0) >= 8192)
            #expect(try await target.duplicate(data) == dir + "/data 2.txt")

            // Alpine: BusyBox tar and gzip only.
            let minimal = try await lab.connected(Lab.minimal())
            #expect(minimal.capabilities.shell && minimal.capabilities.home == "/home/dev")
            #expect(minimal.capabilities.tools.isSuperset(of: ["tar", "gzip"]))
            #expect(minimal.capabilities.tools.isDisjoint(with: ["zip", "unzip", "python3"]))
            #expect(minimal.compressUnavailableReason(.zip) == "The server has no zip command.")
            #expect(minimal.extractUnavailableReason("a.zip") == "The server has neither unzip nor python3.")
            let small = try await lab.folder(on: minimal, in: "/home/dev")
            try await minimal.makeDirectory(small + "/-dash dir")
            try await minimal.writeText("busybox\n", to: small + "/-dash dir/f.txt")
            #expect(try await minimal.compress(["-dash dir"], in: small, format: .tarGz) == small + "/-dash dir.tar.gz")
            let archive = try #require(try await minimal.list(small).first { $0.name == "-dash dir.tar.gz" })
            let unpacked = try await minimal.extract(archive, into: .newFolder)
            #expect(try await minimal.readText(unpacked + "/-dash dir/f.txt") == "busybox\n")
        }
    }

    @Test func listingFiftyThousandEntries() async throws {
        try await withLab { lab in
            let session = try await lab.connected(Lab.target())
            let folder = "/home/dev/perf/many"
            // Each in both orders, the better time counts: the first listing of a pair pays for the cold cache.
            func sftp() async throws -> TimeInterval {
                try await timed { try await plain(OpenSSH.sftp, ["-b", "-", "dev@127.0.0.1"], input: "cd \(folder)\nls -lan\n") }
            }
            var entries: [RemoteEntry] = []
            func airscp() async throws -> TimeInterval { try await timed { entries = try await session.list(folder) } }
            let first = try await sftp(), second = try await airscp(), third = try await airscp(), fourth = try await sftp()
            let plainTime = min(first, fourth), time = min(second, third)
            print("Lab: listed \(entries.count) entries in \(String(format: "%.2f", time)) s "
                  + "(plain sftp: \(String(format: "%.2f", plainTime)) s)")
            #expect(entries.count == 50_000)
            #expect(entries.first { $0.name == "file-50000.txt" }?.size == 17)  // "small file 50000\n"
            // PLAN.md S: such a folder shows within about 2 s (on a quiet Mac; the other tests run alongside).
            #expect(time < plainTime * 2 + 1 && time < 10)
        }
    }

    @Test func largeFilesMoveAtPlainScpSpeed() async throws {
        try await withLab { lab in
            let session = try await lab.connected(Lab.target())
            let local = try scratch()
            defer { try? FileManager.default.removeItem(atPath: local) }
            let updates = Recorder<Date>()
            session.transfers.onChange = { _ in updates.append(Date()) }

            typealias Times = (plain: TimeInterval, airscp: TimeInterval)

            /// Plain scp, then the same with AirSCP's queue (scp on a pseudo-terminal, progress parsed), or
            /// (`airscpFirst`) the other way round: the first copy of a pair pays for cold caches.
            func race(airscpFirst: Bool, plain plainRun: () async throws -> Void, airscp start: () -> UUID) async throws -> Times {
                var plainTime: TimeInterval = 0
                if !airscpFirst { plainTime = try await timed(plainRun) }
                let before = updates.all.count
                var id = UUID()
                let airscpTime = await timed {
                    id = start()
                    await session.transfers.waitUntilIdle()
                }
                #expect(job(id, in: session)?.status == .done)
                // Progress reaches the panel at most about ten times a second.
                let count = updates.all.count - before
                #expect(Double(count) <= 10 * airscpTime + 5, "\(count) updates in \(airscpTime) s")
                if airscpFirst { plainTime = try await timed(plainRun) }
                return (plainTime, airscpTime)
            }

            /// As fast as plain scp, give or take what the tests running alongside cost: measured in both orders, the
            /// better time of each counts (so the numbers printed compare like with like).
            func check(_ name: String, bytes: Double, _ measure: (_ airscpFirst: Bool) async throws -> Times) async throws {
                let one = try await measure(false), other = try await measure(true)
                let plainTime = min(one.plain, other.plain), airscpTime = min(one.airscp, other.airscp)
                func rate(_ time: TimeInterval) -> String { String(format: "%.0f MB/s", bytes / time / 1e6) }
                print("Lab: \(name): scp \(rate(plainTime)), AirSCP \(rate(airscpTime))")
                #expect(airscpTime <= plainTime * 1.5 + 3, "\(name)")
            }

            // Download 2 GiB (a sparse file on the server) into a file here.
            let source = "/home/dev/perf/2g.bin"
            try await check("2 GiB down", bytes: 2_147_483_648) { airscpFirst in
                let times = try await race(airscpFirst: airscpFirst, plain: {
                    try await plain(OpenSSH.scp, ["--", "dev@127.0.0.1:" + source, local + "/plain.bin"])
                    try FileManager.default.removeItem(atPath: local + "/plain.bin")
                }, airscp: { session.transfers.download(source, to: local + "/airscp.bin", isFolder: false) })
                let size = try FileManager.default.attributesOfItem(atPath: local + "/airscp.bin")[.size] as? Int
                #expect(size == 1 << 31)
                try FileManager.default.removeItem(atPath: local + "/airscp.bin")
                return times
            }

            // Upload 1 GiB (a sparse file here) to /dev/null there, so that the server's disk plays no part.
            let big = local + "/up.bin"
            let fd = open(big, O_CREAT | O_WRONLY, 0o644)
            #expect(fd >= 0 && ftruncate(fd, 1 << 30) == 0)
            close(fd)
            try await check("1 GiB up", bytes: 1_073_741_824) { airscpFirst in
                try await race(airscpFirst: airscpFirst,
                               plain: { try await plain(OpenSSH.scp, ["--", big, "dev@127.0.0.1:/dev/null"]) },
                               airscp: { session.transfers.upload(big, to: "/dev/null", isFolder: false) })
            }
        }
    }
}

/// Typed with Remember: saved once the connection is up. Saved: no question. A wrong saved password: tried once, then
/// asked for, and the typed one replaces it.
private func checkPasswordLogin(_ host: SSHHost, password: String, prompt text: String) async throws {
    try await withLab { lab in
        let saved = Recorder<String>()
        let typed = try lab.session(host) { _ in PromptAnswer(password, remember: true) }
        typed.savePassword = { owner, password in
            #expect(owner.id == host.id && typed.state == .connected)
            saved.append(password)
        }
        try await typed.connect()
        let asked = lab.prompts.all
        #expect(asked.map(\.text) == [text])
        #expect(asked.first?.kind == .password(user: host.username, host: "127.0.0.1"))
        #expect(asked.first?.canRemember == true && asked.first?.host?.id == host.id)
        #expect(saved.all == [password])
        #expect(typed.capabilities.shell)
        await typed.disconnect()

        let remembered = try lab.session(host)
        remembered.savedPassword = { $0.id == host.id ? password : nil }
        try await remembered.connect()
        #expect(remembered.state == .connected && lab.prompts.all.count == 1)
        await remembered.disconnect()

        let wrong = try lab.session(host) { _ in PromptAnswer(password, remember: true) }
        wrong.savedPassword = { _ in "not the password" }
        wrong.savePassword = { _, password in saved.append(password) }
        try await wrong.connect()
        #expect(wrong.state == .connected && lab.prompts.all.count == 2)
        #expect(saved.all == [password, password])
    }
}
