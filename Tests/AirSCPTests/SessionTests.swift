import Darwin
import Foundation
import Testing
@testable import AirSCPCore

@Test func airscpBinaryIsBuilt() {
    #expect(FileManager.default.isExecutableFile(atPath: TestEnvironment.airscpBinary),
            "swift test builds the AirSCP executable (the askpass helper) next to the tests")
}

/// Two AirSCPs with settings folders of their own and the same hosts (a copied airscp.json) use different control
/// sockets: the second took over the first one's connection at launch and ended it when it quit. One folder keeps its
/// names, so a master left by a crash is still taken over.
@Test func controlSocketsArePerSettingsFolder() {
    _ = TestEnvironment.isolated
    let id = UUID()
    let a = Session.socketPath(for: id, folder: "/tmp/a/support"), b = Session.socketPath(for: id, folder: "/tmp/b/support")
    #expect(a != b && a == Session.socketPath(for: id, folder: "/tmp/a/support"))
    #expect(Session.socketPath(for: UUID(), folder: "/tmp/a/support") != a)
    #expect(Session.socketPath(for: id) == Session.socketPath(for: id, folder: Store.directory.path))
    #expect(a.hasPrefix(Session.socketDirectory + "/") && (a as NSString).lastPathComponent.count == 12)
}

@Test func keyLoginAndCapabilityProbe() async throws {
    try await withServer { server in
        let session = try server.session()
        let states = Recorder<Session.State>()
        session.onStateChange = { states.append($0) }
        try await session.connect()
        #expect(session.state == .connected)
        #expect(FileManager.default.fileExists(atPath: session.socketPath))
        let capabilities = session.capabilities
        #expect(capabilities.shell)
        #expect(capabilities.home == server.home)
        #expect(capabilities.tools.isSuperset(of: ["zip", "unzip", "tar", "gzip"]))
        #expect(capabilities.noShellReason == nil)

        // Every command is in the log as a shell line; the master is logged when it starts.
        let commands = (await server.logEntries()).map(\.command)
        #expect(commands.contains { $0.hasPrefix("/usr/bin/ssh -M -N ") })
        #expect(commands.contains { $0.contains(" -O check ") })
        #expect((await server.logEntries()).contains { $0.command.contains("__AIRSCP__") && $0.status == 0 })

        let result = try await session.run("echo \"$((6 * 7))\"; echo oops >&2; exit 3")
        #expect(result.output == "42\n" && result.stderr == "oops\n" && result.status == 3)

        await session.disconnect()
        #expect(session.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: session.socketPath))
        #expect(await eventually { states.all.last == .idle })
        #expect(states.all.contains(.connecting) && states.all.contains(.connected))
        #expect(server.prompts.all.isEmpty)
    }
}

@Test func passphraseKeyIsAskedThroughTheAskpassSocket() async throws {
    try await withServer { server in
        let session = try server.session(server.host(key: server.encryptedKey)) { prompt in
            prompt.kind == .passphrase ? PromptAnswer(TestServer.passphrase) : nil
        }
        try await session.connect()
        #expect(session.state == .connected)
        let prompts = server.prompts.all
        #expect(prompts.count == 1)
        #expect(prompts.first?.kind == .passphrase)
        #expect(prompts.first?.text.contains("id_enc") == true)
        #expect(prompts.first?.canRemember == false)
        #expect(try await session.list(server.home).isEmpty)
    }
}

@Test func cancelledPassphraseFailsTheConnect() async throws {
    try await withServer { server in
        let session = try server.session(server.host(key: server.encryptedKey)) { _ in nil }
        await #expect(throws: AirSCPError.self) { try await session.connect() }
        #expect(session.state == .idle)
        #expect(!server.prompts.all.isEmpty)
    }
}

@Test func newHostKeyIsTrustedThroughAPrompt() async throws {
    try await withServer { server in
        let session = try server.session(server.host(trustNewHostKeys: false)) { prompt in
            if case .hostKey = prompt.kind { return .trust }
            return nil
        }
        try await session.connect()
        guard case .hostKey(let host, let fingerprint) = server.prompts.all.first?.kind else {
            Issue.record("no host key prompt: \(server.prompts.all.map(\.text))")
            return
        }
        #expect(host == "[127.0.0.1]:\(server.port)")
        #expect(fingerprint.hasPrefix("SHA256:"))
        #expect(read(server.knownHosts)?.contains("[127.0.0.1]:\(server.port)") == true)
    }
}

@Test func anOrphanedMasterIsAdopted() async throws {
    try await withServer { server in
        let host = server.host()
        let first = try await server.connectedSession(host)
        // A second AirSCP (after a crash) finds the master by its socket.
        let second = try server.session(host)
        #expect(await second.adopt())
        #expect(second.state == .connected)
        #expect(second.capabilities.shell)
        #expect(try await second.list(server.home).isEmpty)
        // connect() adopts too, without starting another master.
        let third = try server.session(host)
        try await third.connect()
        #expect(third.state == .connected)
        #expect((await server.logEntries()).filter { $0.command.hasPrefix("/usr/bin/ssh -M") && $0.status == nil }.count == 1)
        // The adopted master's loss shows up on its next command or check.
        await first.disconnect()
        #expect(await third.check() == false)
        if case .disconnected = third.state {} else { Issue.record("expected Disconnected, got \(third.state)") }
        await #expect(throws: AirSCPError.self) { try await second.list(server.home) }
        if case .disconnected = second.state {} else { Issue.record("expected Disconnected, got \(second.state)") }
    }
}

@Test func killedMasterMeansDisconnectedAndNoFallbackPrompts() async throws {
    try await withServer { server in
        // A passphrase key: a fallback login could only succeed by prompting, which BatchMode forbids.
        let session = try server.session(server.host(key: server.encryptedKey)) { prompt in
            prompt.kind == .passphrase ? PromptAnswer(TestServer.passphrase) : nil
        }
        let states = Recorder<Session.State>()
        session.onStateChange = { states.append($0) }
        try await session.connect()
        let promptsAfterConnect = server.prompts.all.count
        let master = try #require((await server.logEntries()).first { $0.command.hasPrefix("/usr/bin/ssh -M") })
        #expect(master.status == nil)

        // Kill the master outright: its socket file stays behind, so commands meet "Control socket connect".
        try await killMaster(of: session)
        #expect(await eventually {
            if case .disconnected(let error) = session.state { return error.kind == .disconnected }
            return false
        })
        // onStateChange is delivered on the main queue, after `state` has changed.
        #expect(await eventually { states.all.contains { if case .disconnected = $0 { return true } else { return false } } })

        // Commands now fail at once, without running and without prompting.
        let started = Date()
        do {
            _ = try await session.list(server.home)
            Issue.record("listing worked without a master")
        } catch let error as AirSCPError {
            #expect(error.kind == .disconnected)
        }
        #expect(Date().timeIntervalSince(started) < 10)  // at once, not a fresh login
        #expect(server.prompts.all.count == promptsAfterConnect)

        // A muxed command run behind AirSCP's back fails fast too (BatchMode) and reports the dead socket.
        let argv = OpenSSH.remote("true", session.host, jump: nil, socket: session.socketPath)
        let result = await Runner.run(argv)
        #expect(result.status != 0)
        #expect(ErrorMapping.map(result.stderr, status: result.status).kind == .disconnected)

        // Reconnect.
        try await session.connect()
        #expect(session.state == .connected)
        #expect(try await session.list(server.home).isEmpty)
    }
}

@Test func changedHostKeyIsDetectedAndRemoved() async throws {
    try await withServer { server in
        // known_hosts has another key for [127.0.0.1]:port.
        let other = server.root + "/other_key"
        try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", other])
        let fakeKey = try #require(read(other + ".pub")).split(separator: " ").prefix(2).joined(separator: " ")
        try "[127.0.0.1]:\(server.port) \(fakeKey)\n".write(toFile: server.knownHosts, atomically: true, encoding: .utf8)

        let session = try server.session(server.host(trustNewHostKeys: false)) { prompt in
            if case .hostKey = prompt.kind { return .trust }
            return nil
        }
        do {
            try await session.connect()
            Issue.record("connected despite a changed host key")
        } catch let error as AirSCPError {
            #expect(error.kind == .hostKeyChanged)
            #expect(error.details.contains("REMOTE HOST IDENTIFICATION HAS CHANGED"))
        }
        #expect(server.prompts.all.isEmpty)

        try await session.removeOldHostKey()
        #expect((await server.logEntries()).contains { $0.command.contains("ssh-keygen -R '[127.0.0.1]:\(server.port)' -f ") })
        #expect(read(server.knownHosts)?.contains(fakeKey) == false)
        try await session.connect()
        #expect(session.state == .connected)
        #expect(server.prompts.all.count == 1)  // trusting the real key
    }
}

/// Through a jump host it can be the jump host's key that changed (it was reinstalled): that entry goes, and the
/// target's own entry, still valid, stays.
@Test func aJumpHostsChangedKeyIsTheOneRemoved() async throws {
    try await withServer { server in
        var jump = server.host()
        jump.label = "Jump"
        var target = server.host()
        target.hostname = "localhost"
        target.jumpHostID = jump.id
        // Both keys go into one known_hosts file, as ~/.ssh/known_hosts holds them.
        let session = try await server.connectedSession(target, jump: jump)
        await session.disconnect()
        let lines = try #require(read(server.knownHosts)).split(separator: "\n").map(String.init)
        let targetLine = try #require(lines.first { $0.hasPrefix("[localhost]:\(server.port) ") })
        let other = server.root + "/other_key"
        try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", other])
        let fakeKey = try #require(read(other + ".pub")).split(separator: " ").prefix(2).joined(separator: " ")
        try (targetLine + "\n[127.0.0.1]:\(server.port) \(fakeKey)\n").write(toFile: server.knownHosts, atomically: true,
                                                                            encoding: .utf8)
        do {
            try await session.connect()
            Issue.record("connected despite the jump host's changed key")
        } catch let error as AirSCPError {
            #expect(error.kind == .hostKeyChanged)
            #expect(ErrorMapping.changedHostKey(in: error.details)?.name == "[127.0.0.1]:\(server.port)")
            #expect(ErrorMapping.changedHostKey(in: error.details)?.file == server.knownHosts)
        }
        try await session.removeOldHostKey()
        let known = try #require(read(server.knownHosts))
        #expect(known.contains(targetLine) && !known.contains(fakeKey))
        try await session.connect()  // the jump host is new again: its key is accepted
        #expect(session.state == .connected)
    }
}

@Test func loginNoiseDoesNotConfuseParsedOutput() async throws {
    try await withServer(TestServer.Options(noise: true)) { server in
        let session = try await server.connectedSession()
        // The noise is really there for plain commands...
        let raw = try await session.run("echo hi")
        #expect(raw.output.contains(TestServer.noiseLine) && raw.output.hasSuffix("hi\n"))
        // ...but parsed output (probe, du) is clean.
        #expect(session.capabilities.shell)
        #expect(session.capabilities.home == server.home)
        #expect(session.capabilities.tools.contains("tar"))
        try rawMkdir(server.path("folder"))
        try writeRandom(bytes: 10_000, to: server.path("folder/data"))
        let folder = try #require(try await session.list(server.home).first { $0.name == "folder" })
        #expect((try await session.folderSizes([folder.name], in: server.home)[folder.name] ?? 0) >= 8192)
        let copy = try await session.duplicate(folder)
        #expect(copy == server.path("folder 2") && exists(server.path("folder 2/data")))
    }
}

@Test func jumpHostConnection() async throws {
    try await withServer { server in
        // Hop through the test server to itself.
        var jump = server.host()
        jump.label = "Jump"
        var target = server.host()
        target.hostname = "localhost"  // a different name, so the hop is visible in known_hosts
        target.jumpHostID = jump.id
        let session = try server.session(target, jump: jump)
        try await session.connect()
        #expect(session.state == .connected)
        let master = try #require((await server.logEntries()).first { $0.command.hasPrefix("/usr/bin/ssh -M") }?.command)
        #expect(master.contains("ProxyCommand=/usr/bin/ssh -F \(TestEnvironment.sshConfig)"))
        #expect(master.contains("-W %h:%p 127.0.0.1"))
        #expect(read(server.knownHosts)?.contains("[localhost]:\(server.port)") == true)
        #expect(try await session.run("echo through").output == "through\n")
    }
}

/// A host whose jump host no longer exists is refused: it never connects to its own address directly instead.
@Test func aHostWhoseJumpHostIsGoneDoesntConnectDirectly() async throws {
    try await withServer { server in
        var target = server.host()
        target.jumpHostID = UUID()  // deleted, or not in the imported file
        let session = try server.session(target)
        do {
            try await session.connect()
            Issue.record("connected without its jump host")
        } catch let error as AirSCPError {
            #expect(error.message.hasPrefix("This host connects through a jump host that no longer exists"))
        }
        #expect(session.state == .idle)
        #expect(!(await server.logEntries()).contains { $0.command.hasPrefix("/usr/bin/ssh -M") })
        await #expect(throws: AirSCPError.self) { try await session.installKey(server.root + "/client_key.pub") }
        #expect((await server.logEntries()).isEmpty)
        #expect(OpenSSH.missingJump(target, jump: server.host()) == nil && OpenSSH.missingJump(server.host(), jump: nil) == nil)
    }
}

@Test func sftpOnlyAccount() async throws {
    try await withServer(TestServer.Options(sftpOnly: true)) { server in
        let session = try await server.connectedSession()
        let capabilities = session.capabilities
        #expect(!capabilities.shell)
        #expect(capabilities.noShellReason == "This account allows file transfers (sftp) only.")
        #expect(capabilities.home == server.home)
        // Shell-only actions are refused with the reason; sftp ones work.
        do {
            _ = try await session.run("true")
            Issue.record("ran a command on an sftp-only account")
        } catch let error as AirSCPError {
            #expect(error.kind == .sftpOnly)
        }
        #expect(session.compressUnavailableReason(.zip) == capabilities.noShellReason)
        #expect(session.extractUnavailableReason("a.zip") == capabilities.noShellReason)
        try await session.makeDirectory(server.path("tree"))
        try await session.makeDirectory(server.path("tree/sub"))
        try write("a", to: server.path("tree/a.txt"))
        try write("b", to: server.path("tree/sub/b.txt"))
        try rawCreate(server.path("tree/sub/c d"), "c")
        // Recursive chmod and delete walk the tree with sftp.
        let tree = try #require(try await session.list(server.home).first { $0.name == "tree" })
        try await session.setPermissions(tree, mode: 0o750, recursive: true)
        let sub = try #require(try await session.list(tree.path).first { $0.name == "sub" })
        #expect(sub.mode == 0o750)
        #expect(try await session.list(sub.path).allSatisfy { $0.mode == 0o750 })
        try await session.delete([tree])
        #expect(!exists(server.path("tree")))
        #expect(!(await server.logEntries()).contains { $0.command.contains("rm -rf") })
    }
}

@Test func maxSessionsTwoQueuesInsteadOfFallingBack() async throws {
    try await withServer(TestServer.Options(maxSessions: 2)) { server in
        // A passphrase key: any fallback login would fail loudly instead of quietly working.
        let session = try server.session(server.host(key: server.encryptedKey)) { prompt in
            prompt.kind == .passphrase ? PromptAnswer(TestServer.passphrase) : nil
        }
        try await session.connect()
        let local = try server.scratch()
        session.transfers.bandwidthLimit = 64_000  // 8 MB/s: the transfer is still running during the listings
        try writeRandom(bytes: 30_000_000, to: local + "/big.bin")
        // A transfer and several listings at once: one transfer + one control command = two sessions.
        let job = session.transfers.upload(local + "/big.bin", to: server.path("big.bin"), isFolder: false)
        for _ in 0..<5 { _ = try await session.list(server.home) }
        await session.transfers.waitUntilIdle()
        #expect(session.transfers.jobs.first { $0.id == job }?.status == .done)
        #expect(!(await server.logEntries()).contains { $0.stderr.contains("session request failed") })

        // Two Terminal-style sessions hold both slots: AirSCP's commands wait for a free one instead of failing.
        // (With the host's own options, so that even a fallback login could only reach the test server.)
        async let terminal = Runner.run(OpenSSH.remote("sleep 4", session.host, jump: nil, socket: session.socketPath))
        async let otherTerminal = Runner.run(OpenSSH.remote("sleep 3", session.host, jump: nil, socket: session.socketPath))
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let entries = try await session.list(server.home)
        #expect(entries.contains { $0.name == "big.bin" })
        #expect((await server.logEntries()).contains { $0.stderr.contains("session request failed") && $0.status != 0 })
        #expect(await terminal.status == 0)
        #expect(await otherTerminal.status == 0)
    }
}

@Test func tunnelsForwardCancelAndBusyPort() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let tunnel = try await startedTunnel(session, to: server.port)
        #expect(session.activeTunnels == [tunnel.id])
        #expect(canConnect(to: tunnel.listenPort))
        try await session.stopTunnel(tunnel)
        #expect(session.activeTunnels.isEmpty)
        #expect(await eventually { !canConnect(to: tunnel.listenPort) })

        // A port something else listens on (both loopback families, or ssh would just take the other).
        let busy = try listener()
        defer { close(busy.fd); close(busy.fd6) }
        do {
            try await session.startTunnel(Tunnel(kind: .local, listenPort: busy.port, targetHost: "127.0.0.1", targetPort: 22))
            Issue.record("forwarded a busy port")
        } catch let error as AirSCPError {
            #expect(error.kind == .portInUse)
        }
        // Below 1024 on this Mac: only administrators may listen there, which ssh doesn't say.
        do {
            try await session.startTunnel(Tunnel(kind: .local, listenPort: 1023, targetHost: "127.0.0.1", targetPort: 22))
            Issue.record("forwarded a privileged port")
        } catch let error as AirSCPError {
            #expect(error.kind == .permissionDenied && error.message.hasPrefix("Ports below 1024 on this Mac"))
        }
        #expect(ErrorMapping.map("Warning: remote port forwarding failed for listen port 42581", status: 0).message
            .hasPrefix("The port couldn't be opened: it may be in use, or the server doesn't allow tunnels"))
        let socks = try listener()
        close(socks.fd)
        close(socks.fd6)
        let dynamic = Tunnel(kind: .dynamic, listenPort: socks.port)
        try await session.startTunnel(dynamic)
        #expect(canConnect(to: socks.port))
        await session.disconnect()
        #expect(session.activeTunnels.isEmpty)
    }
}

/// A TCP listener on 127.0.0.1 and ::1 at the same free port.
/// A local tunnel to `targetPort`, started on a port that was free a moment before: on a busy Mac another socket may
/// take such a port meanwhile (the start then says "in use"), and another is tried.
func startedTunnel(_ session: Session, to targetPort: Int) async throws -> Tunnel {
    for _ in 0..<5 {
        let free = try listener()
        close(free.fd)
        close(free.fd6)
        let tunnel = Tunnel(kind: .local, listenPort: free.port, targetHost: "127.0.0.1", targetPort: targetPort)
        do {
            try await session.startTunnel(tunnel)
            return tunnel
        } catch let error as AirSCPError where error.kind == .portInUse {
            continue
        }
    }
    throw AirSCPError(.portInUse, "No free port for the test's tunnel.")
}

func listener() throws -> (port: Int, fd: Int32, fd6: Int32) {
    for _ in 0..<20 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Int32 in
                bind(fd, pointer, length)
                return getsockname(fd, pointer, &length)
            }
        }
        listen(fd, 4)
        let port = UInt16(bigEndian: address.sin_port)
        let fd6 = socket(AF_INET6, SOCK_STREAM, 0)
        var address6 = sockaddr_in6()
        address6.sin6_family = sa_family_t(AF_INET6)
        address6.sin6_addr = in6addr_loopback
        address6.sin6_port = port.bigEndian
        let bound = withUnsafePointer(to: &address6) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd6, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
        }
        if bound == 0 && listen(fd6, 4) == 0 { return (Int(port), fd, fd6) }
        close(fd)
        close(fd6)
    }
    throw AirSCPError(.other, "no free port")
}

func canConnect(to port: Int) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(fd) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    address.sin_port = UInt16(port).bigEndian
    return withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    } == 0
}
