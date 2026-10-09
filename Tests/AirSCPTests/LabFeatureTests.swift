import Darwin
import Foundation
import Testing
@testable import AirSCPCore

// Rev-3 features against the Docker lab (testenv/): proxy chains, remote copy/move/execute, compressed transfers, Get
// Info and folder sizes, and the monitor.

@Suite(.enabled(if: Lab.enabled, "Docker lab: AIRSCP_DOCKER=1 ./test.sh"))
struct LabFeatureTests {
    @Test func proxyThenBastionThenTarget() async throws {
        try await withLab { lab in
            func answerProxy(_ session: Session, password: String = Lab.proxyPassword) {
                session.askpass.proxyHandler = { id, _, _, reply in
                    reply(id == Lab.proxy.id ? (Lab.proxy, password) : nil)
                }
            }
            // The proxy alone, to the target by its name inside the lab.
            var behindProxy = Lab.host("dev", hostname: "target", port: 22)
            behindProxy.proxyID = Lab.proxy.id
            let direct = try lab.session(behindProxy)
            answerProxy(direct)
            try await direct.connect()
            #expect(try await direct.run("hostname").output.hasSuffix("target\n"))

            // Proxy → bastion → target: the bastion's first hop goes through the proxy.
            var bastion = Lab.host("jump", hostname: "bastion", port: 22)
            bastion.proxyID = Lab.proxy.id
            var target = Lab.host("dev", hostname: "target", port: 22)
            target.jumpHostID = bastion.id
            let chained = try lab.session(target, jump: bastion)
            answerProxy(chained)
            try await chained.connect()
            let master = (await lab.logEntries()).last { $0.command.hasPrefix("/usr/bin/ssh -M") }?.command ?? ""
            #expect(master.contains("--proxy-connect") && master.contains("-W"))
            #expect(try await chained.list("/home/dev").contains { $0.name == "perf" })
            let dir = try await lab.folder(on: chained, in: "/home/dev")
            let local = try scratch()
            try writeRandom(bytes: 3_000_000, to: local + "/up.bin")
            chained.transfers.upload(local + "/up.bin", to: dir + "/up.bin", isFolder: false)
            chained.transfers.download(dir + "/up.bin", to: local + "/back.bin", isFolder: false)
            await chained.transfers.waitUntilIdle()
            #expect(chained.transfers.jobs.allSatisfy { $0.status == .done })
            #expect(FileManager.default.contentsEqual(atPath: local + "/up.bin", andPath: local + "/back.bin"))
            #expect(lab.prompts.all.isEmpty)

            // A wrong proxy password: the proxy's 407, in words.
            var refusedHost = Lab.host("dev", hostname: "target", port: 22)
            refusedHost.proxyID = Lab.proxy.id
            let refused = try lab.session(refusedHost)
            answerProxy(refused, password: "not the password")
            do {
                try await refused.connect()
                Issue.record("connected through the proxy with a wrong password")
            } catch let error as AirSCPError {
                #expect(error.message.localizedCaseInsensitiveContains("proxy"), "\(error.message)")
                #expect(error.details.contains("407"), "\(error.details)")
            }
        }
    }

    @Test func remoteCopyMoveAndExecute() async throws {
        try await withLab { lab in
            let session = try await lab.connected(Lab.target())
            let dir = try await lab.folder(on: session, in: "/home/dev")
            try await session.makeDirectory(dir + "/src dir")
            try await session.makeDirectory(dir + "/src dir/sub")
            try await session.writeText("copy me\n", to: dir + "/src dir/it's.txt")
            try await session.writeText("deep\n", to: dir + "/src dir/sub/x.txt")

            try await session.copy(dir + "/src dir", to: dir + "/copy dir")
            try await session.copy(dir + "/src dir/it's.txt", to: dir + "/single copy.txt")
            #expect(try await session.readText(dir + "/copy dir/sub/x.txt") == "deep\n")
            #expect(try await session.readText(dir + "/single copy.txt") == "copy me\n")
            #expect(try await session.readText(dir + "/src dir/it's.txt") == "copy me\n")

            try await session.move(dir + "/copy dir", to: dir + "/moved [1] dir")
            #expect(Set(try await session.list(dir).map(\.name)) == ["src dir", "single copy.txt", "moved [1] dir"])
            // Onto another file system (/dev/shm is a tmpfs) and back: mv copies.
            let away = "/dev/shm/porter-lab-" + UUID().uuidString.prefix(8)
            try await session.move(dir + "/moved [1] dir", to: away)
            try await session.move(away, to: dir + "/back dir")
            #expect(try await session.readText(dir + "/back dir/it's.txt") == "copy me\n")
            #expect(!(try await session.list("/dev/shm")).contains { $0.path == away })

            // Run a script in its folder, with arguments as typed (the shell expands them).
            let script = dir + "/src dir/run me.sh"
            try await session.writeText("#!/bin/sh\nprintf 'args:'; for a in \"$@\"; do printf ' [%s]' \"$a\"; done; echo; pwd\n",
                                        to: script)
            let entry = try #require(try await session.list(dir + "/src dir").first { $0.name == "run me.sh" })
            try await session.setPermissions(entry, mode: entry.mode | 0o111)
            let result = try await session.run(Session.executeCommand(script, arguments: "one 'two three' \"$HOME\""), sh: true)
            #expect(result.status == 0)
            #expect(result.output.hasSuffix("args: [one] [two three] [/home/dev]\n\(dir)/src dir\n"), "\(result.output)")

            // sftp only: no copy; a move is a rename, which can't cross file systems.
            let sftp = try await lab.connected(Lab.target("sftponly"))
            let upload = try await lab.folder(on: sftp, in: "/upload")
            try await sftp.writeText("a\n", to: upload + "/a.txt")
            do {
                try await sftp.copy(upload + "/a.txt", to: upload + "/b.txt")
                Issue.record("copied on an sftp-only account")
            } catch let error as AirSCPError {
                #expect(error.kind == .sftpOnly)
            }
            try await sftp.move(upload + "/a.txt", to: upload + "/b.txt")
            #expect(try await sftp.list(upload).map(\.name) == ["b.txt"])
            do {
                try await sftp.move(upload + "/b.txt", to: "/upload/other-disk/b.txt")
                Issue.record("renamed across file systems")
            } catch let error as AirSCPError {
                #expect(error.message.localizedCaseInsensitiveContains("file system"), "\(error.message)")
            }
            #expect(try await sftp.list(upload).map(\.name) == ["b.txt"])
        }
    }

    @Test func compressedUploadAndArchiveDownload() async throws {
        try await withLab { lab in
            let session = try await lab.connected(Lab.target())
            let dir = try await lab.folder(on: session, in: "/home/dev")
            let local = try scratch()
            try write("alpha\n", to: local + "/up/a.txt")
            try write("bravo\n", to: local + "/up/sub/b.txt")
            try write("quoted\n", to: local + "/up/it's here.txt")
            for index in 0..<300 { try write("small \(index)\n", to: local + "/up/many/f\(index).txt") }
            // Mac metadata, which a plain macOS tar would pack as ._ files.
            for path in [local + "/up/a.txt", local + "/up/sub"] {
                #expect(setxattr(path, "com.apple.metadata:airscp-test", "lab", 3, 0, 0) == 0)
            }
            let items = ["a.txt", "sub", "many", "it's here.txt"]

            func finished(_ id: UUID, on session: Session) async -> TransferJob.Status? {
                await session.transfers.waitUntilIdle()
                return job(id, in: session)?.status
            }

            #expect(await finished(session.transfers.uploadCompressed(items, in: local + "/up", to: dir, replacing: false),
                                   on: session) == .done)
            #expect(Set(try await session.list(dir).map(\.name)) == Set(items))  // no ._ files, no leftover archive
            #expect(try await session.run("find \(Quote.shell(dir)) -name '._*' | wc -l").output.hasSuffix("0\n"))
            #expect(try await session.readText(dir + "/sub/b.txt") == "bravo\n")
            #expect(try await session.list(dir + "/many").count == 300)
            // Replace: the file that is there is overwritten.
            try write("alpha 2\n", to: local + "/up/a.txt")
            #expect(await finished(session.transfers.uploadCompressed(["a.txt"], in: local + "/up", to: dir, replacing: true),
                                   on: session) == .done)
            #expect(try await session.readText(dir + "/a.txt") == "alpha 2\n")

            // BusyBox tar unpacks it too.
            let minimal = try await lab.connected(Lab.minimal())
            let small = try await lab.folder(on: minimal, in: "/home/dev")
            #expect(await finished(minimal.transfers.uploadCompressed(["sub", "many"], in: local + "/up", to: small,
                                                                      replacing: false), on: minimal) == .done)
            #expect(Set(try await minimal.list(small).map(\.name)) == ["sub", "many"])
            #expect(try await minimal.readText(small + "/many/f299.txt") == "small 299\n")

            // Download as archive: one streamed .tar.gz, with indeterminate progress.
            try FileManager.default.createDirectory(atPath: local + "/down", withIntermediateDirectories: true)
            let archive = local + "/down/items.tar.gz"
            let down = session.transfers.downloadArchive(["sub", "many", "it's here.txt"], in: dir, to: archive, extract: false)
            #expect(await finished(down, on: session) == .done)
            let progress = try #require(job(down, in: session)?.progress)
            #expect(progress.indeterminate && progress.bytes > 0)
            let members = try await run(["/usr/bin/tar", "-tzf", archive]).output
            #expect(members.contains("sub/b.txt") && members.contains("many/f299.txt") && members.contains("it's here.txt"))
            #expect(names(in: local + "/down") == ["items.tar.gz"])
            // With "Extract after download" the items land in the folder and the archive goes.
            try FileManager.default.createDirectory(atPath: local + "/unpacked", withIntermediateDirectories: true)
            #expect(await finished(session.transfers.downloadArchive(["sub", "many"], in: dir,
                                                                     to: local + "/unpacked/items.tar.gz", extract: true),
                                   on: session) == .done)
            #expect(names(in: local + "/unpacked") == ["many", "sub"])
            #expect(read(local + "/unpacked/sub/b.txt") == "bravo\n" && names(in: local + "/unpacked/many").count == 300)
        }
    }

    @Test func folderSizesAndGetInfo() async throws {
        try await withLab { lab in
            let session = try await lab.connected(Lab.target())
            let dir = try await lab.folder(on: session, in: "/home/dev")
            let folders = ["a b": 20_000, "it's": 30_000, "-dash": 40_000, "\u{FC}ber": 50_000, "box": 100_000]
            var script = "cd \(Quote.shell(dir))"
            for (name, bytes) in folders {
                script += " && mkdir \(Quote.shell("./" + name)) && head -c \(bytes) /dev/urandom > \(Quote.shell("./" + name + "/data"))"
            }
            script += " && mkdir box/inner && printf 'b\\n' > box/inner/b.txt && printf 'hello\\n' > notes.txt && ln -s notes.txt link"
            #expect(try await session.run(script).status == 0)

            let sizes = try await session.folderSizes(Array(folders.keys) + ["missing"], in: dir)
            for (name, bytes) in folders {
                #expect((sizes[name] ?? 0) >= Int64(bytes), "\(name): \(String(describing: sizes[name]))")
            }
            #expect(sizes["missing"] == nil)

            let listing = try await session.list(dir)
            let notesEntry = try #require(listing.first { $0.name == "notes.txt" })
            let notes = try await session.info(notesEntry)
            #expect(notes.path == dir + "/notes.txt" && notes.kind == "ASCII text" && notes.size == 6 && notes.itemCount == nil)
            #expect(notes.mode == notesEntry.mode && notes.owner == "dev" && notes.group == "dev" && notes.linkTarget == nil)
            #expect(notes.modified != nil && notes.accessed != nil && notes.changed != nil)
            let box = try await session.info(try #require(listing.first { $0.name == "box" }))
            #expect(box.kind == "directory" && box.itemCount == 3 && (box.size ?? 0) >= 100_000)
            #expect(try await session.info(try #require(listing.first { $0.name == "link" })).linkTarget == "notes.txt")

            // BusyBox stat.
            let minimal = try await lab.connected(Lab.minimal())
            let small = try await lab.folder(on: minimal, in: "/home/dev")
            try await minimal.writeText("hello\n", to: small + "/notes.txt")
            let written = try #require(try await minimal.list(small).first)
            let busybox = try await minimal.info(written)
            #expect(busybox.size == 6 && busybox.owner == "dev" && busybox.mode == written.mode && busybox.modified != nil)

            // sftp only: what the listing shows, and no folder sizes.
            let sftp = try await lab.connected(Lab.target("sftponly"))
            let upload = try await lab.folder(on: sftp, in: "/upload")
            try await sftp.makeDirectory(upload + "/folder")
            try await sftp.writeText("hello\n", to: upload + "/notes.txt")
            let entries = try await sftp.list(upload)
            let file = try #require(entries.first { $0.name == "notes.txt" })
            let info = try await sftp.info(file)
            #expect(info.size == 6 && info.mode == file.mode && info.owner == file.owner && info.modified == file.modified)
            #expect(info.kind == nil && info.itemCount == nil && info.accessed == nil && info.changed == nil && info.linkTarget == nil)
            #expect(try await sftp.info(try #require(entries.first { $0.name == "folder" })).size == nil)
            do {
                _ = try await sftp.folderSizes(["folder"], in: upload)
                Issue.record("measured folders on an sftp-only account")
            } catch let error as AirSCPError {
                #expect(error.kind == .sftpOnly)
            }
        }
    }

    @Test func monitorOnDebianAndBusyBoxWithKill() async throws {
        try await withLab { lab in
            for host in [Lab.target(), Lab.minimal()] {
                let session = try await lab.connected(host)
                let monitor = Monitor(session: session)
                let first = try await monitor.refresh()
                #expect(first.cpu == nil && first.load.count == 3 && first.uptime > 0)
                #expect(first.memoryTotal > 0 && first.memoryUsed > 0 && first.memoryUsed <= first.memoryTotal)
                #expect(first.disks.contains { $0.mountPoint == "/" && $0.size > 0 })
                #expect(first.processes.contains { $0.name == "sshd" && $0.user == "root" })
                let second = try await monitor.refresh()
                #expect(second.cpu.map { (0...100).contains($0) } == true)
                if host.port == Lab.targetPort {
                    #expect(second.system.contains("Debian"))
                    // GNU ps: every column; the lab's long-running process is there.
                    #expect(second.processes.contains { $0.name == "porter-busy" && $0.user == "dev" && $0.cpu != nil })
                } else {
                    #expect(second.system.contains("Alpine"))
                    // BusyBox ps: no %CPU; %MEM from RSS.
                    #expect(!second.processes.isEmpty && second.processes.allSatisfy { $0.cpu == nil && $0.memory != nil })
                }
                // Not its own probe: ps lists the script's shell ("sh -s", which prints its pid first) and the ps it
                // runs; the table lists neither.
                let raw = try await session.shell(Monitor.script(.unknown))
                let rows = raw.split(separator: "\n").map { $0.split(separator: " ").map(String.init) }
                let shell = try #require(rows.firstIndex(of: ["@@sh"]).flatMap { rows.dropFirst($0 + 1).first?.first })
                #expect(rows.contains { $0.first == shell && $0.suffix(2) == ["sh", "-s"] })
                #expect(rows.contains { $0.count > 1 && $0[1] == shell && $0.contains("ps") })
                let table = Monitor.parse(raw).snapshot.processes
                #expect(!table.isEmpty && !table.contains { "\($0.pid)" == shell || "\($0.ppid)" == shell })

                // Kill (TERM) and Force Kill (KILL) a process of this account; another account's is refused.
                for force in [false, true] {
                    let seconds = 600 + Int.random(in: 0..<1000)
                    _ = try await session.run("sleep \(seconds) </dev/null >/dev/null 2>&1 &")
                    var victim: MonitorProcess?
                    #expect(await eventually(timeout: 10) {
                        victim = try? await monitor.refresh().processes.first { $0.command == "sleep \(seconds)" }
                        return victim != nil
                    })
                    guard let victim else { continue }
                    #expect(victim.user == "dev")
                    try await monitor.kill(victim.pid, force: force)
                    #expect(await eventually(timeout: 10) {
                        (try? await monitor.refresh().processes.contains { $0.pid == victim.pid }) == false
                    })
                }
                let root = try #require(second.processes.first { $0.name == "sshd" && $0.user == "root" })
                do {
                    try await monitor.kill(root.pid, force: false)
                    Issue.record("killed root's sshd")
                } catch let error as AirSCPError {
                    #expect(error.kind == .permissionDenied)
                }
                // "Kill with sudo in Terminal" only where there is sudo: not on the BusyBox server.
                #expect(await monitor.hasSudo() == (host.port == Lab.targetPort))
                // Names that aren't ASCII come as they are, not as "?" for each byte.
                _ = try await session.run("sh -c 'sleep 701; echo café-✓' </dev/null >/dev/null 2>&1 &")
                #expect(await eventually(timeout: 10) {
                    (try? await monitor.refresh().processes.contains { $0.command.contains("café-✓") }) == true
                })
                _ = try? await session.run("pkill -f 'sleep 701' || true")
            }

            // sftp only: nothing to run ps with.
            let sftp = try await lab.connected(Lab.target("sftponly"))
            do {
                _ = try await Monitor(session: sftp).refresh()
                Issue.record("monitored an sftp-only account")
            } catch let error as AirSCPError {
                #expect(error.kind == .sftpOnly)
            }
        }
    }

    /// Monitor ▸ Ports on the Debian server (neither ss nor netstat) and the BusyBox one: a listener of this account's
    /// with a connection to it (python3; BusyBox nc) is listed with its process, user and connection, from 127.0.0.1;
    /// root's sshd with its user but not its process; Kill stops the listener.
    @Test func portsOnDebianAndBusyBox() async throws {
        try await withLab { lab in
            for host in [Lab.target(), Lab.minimal()] {
                let session = try await lab.connected(host)
                let monitor = Monitor(session: session)
                let number = 47900 + Int.random(in: 0..<90)
                let debian = host.port == Lab.targetPort
                // Each ends by itself in 5 minutes.
                _ = try await session.run(debian
                    ? "python3 -c 'import socket, time; s = socket.socket(); s.bind((\"0.0.0.0\", \(number))); s.listen(); "
                        + "c = socket.create_connection((\"127.0.0.1\", \(number))); a = s.accept(); time.sleep(300)' "
                        + "</dev/null >/dev/null 2>&1 &"
                    : "nc -lk -p \(number) -e sleep 300 </dev/null >/dev/null 2>&1 & sleep 1; "
                        + "timeout 300 nc 127.0.0.1 \(number) </dev/null >/dev/null 2>&1 &")
                var ports = MonitorPorts()
                #expect(await eventually(timeout: 20) {
                    ports = (try? await monitor.refresh(ports: true).ports) ?? MonitorPorts()
                    return ports.listening.contains { $0.port == number && $0.connections ?? 0 > 0 }
                }, "\(ports)")
                let listener = try #require(ports.listening.first { $0.port == number })
                #expect(listener.isTCP && listener.user == "dev" && listener.pids.count == 1)
                #expect(listener.process == (debian ? "python3" : "nc") && listener.command.contains(String(number)))
                // root's sshd: not this account's to see.
                let ssh = try #require(ports.listening.first { $0.port == 22 })
                #expect(ssh.user == "root" && ssh.pids.isEmpty && ports.othersHidden)

                let connected = try #require(try await monitor.refresh(ports: true, connectionsOf: listener).ports)
                #expect(connected.connectionsOf == listener.id && connected.connections.contains { $0.address == "127.0.0.1" },
                        "\(connected.connections)")

                try await monitor.kill(listener.pids[0], force: false)
                #expect(await eventually(timeout: 20) {
                    (try? await monitor.refresh(ports: true).ports?.listening.contains { $0.port == number }) == false
                })
                _ = try? await session.run("pkill -f '127.0.0.1 \(number)' || true")
            }
        }
    }

    /// Tunnels as the editor saves them carry traffic through a real server: Local to the server itself ("localhost",
    /// looked up on the server: its own sshd) and to a machine only the server reaches ("private", inside the lab), and
    /// Remote from a port on the server back to this Mac ("localhost" here).
    @Test func localAndRemoteTunnelsCarryTraffic() async throws {
        try await withLab { lab in
            let session = try await lab.connected(Lab.target())
            let targetBanner = try banner(port: Lab.targetPort)
            for host in ["localhost", "private"] {
                let tunnel = try await startedTunnel(session, to: 22, host: host)
                let line = try banner(port: tunnel.listenPort)
                #expect(host == "localhost" ? line == targetBanner : line.hasPrefix("SSH-2.0-"), "\(host): \(line)")
                try await session.stopTunnel(tunnel)
            }

            // Remote: a port on the server that leads to a listener on this Mac, which answers.
            let mac = try listener()
            defer {
                close(mac.fd)
                close(mac.fd6)
            }
            answerOnce(mac, with: "hello from the Mac")
            var remote: Tunnel?, failure: Error?
            for _ in 0..<5 where remote == nil {
                let tunnel = Tunnel(kind: .remote, listenPort: Int.random(in: 40_000..<60_000), targetHost: "localhost",
                                    targetPort: mac.port)
                do {
                    try await session.startTunnel(tunnel)
                    remote = tunnel
                } catch {
                    failure = error  // a port something else holds on the server: try another
                }
            }
            let tunnel = try #require(remote, "\(String(describing: failure))")
            let result = try await session.run("exec 3<>/dev/tcp/127.0.0.1/\(tunnel.listenPort) && head -c 18 <&3")
            #expect(result.output.hasSuffix("hello from the Mac"), "\(result.output) \(result.stderr)")
            try await session.stopTunnel(tunnel)
        }
    }
}

/// The first line a server sends on 127.0.0.1:`port` (an SSH server's version), within 30 s.
private func banner(port: Int) throws -> String {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var timeout = timeval(tv_sec: 30, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = UInt16(port).bigEndian
    let connected = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard connected == 0 else { throw AirSCPError(.other, "Nothing listens on port \(port).") }
    var line = Data(), byte: UInt8 = 0
    while read(fd, &byte, 1) == 1 && byte != UInt8(ascii: "\n") { line.append(byte) }
    return String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Answers the first connection to `listener` (on 127.0.0.1 or ::1) with `text`, on a thread of its own.
private func answerOnce(_ listener: (port: Int, fd: Int32, fd6: Int32), with text: String) {
    Thread.detachNewThread {
        var fds = [pollfd(fd: listener.fd, events: Int16(POLLIN), revents: 0), pollfd(fd: listener.fd6, events: Int16(POLLIN), revents: 0)]
        guard poll(&fds, 2, 120_000) > 0, let ready = fds.first(where: { $0.revents & Int16(POLLIN) != 0 }) else { return }
        let connection = accept(ready.fd, nil, nil)
        guard connection >= 0 else { return }
        _ = Array(text.utf8).withUnsafeBytes { write(connection, $0.baseAddress, $0.count) }
        close(connection)
    }
}
