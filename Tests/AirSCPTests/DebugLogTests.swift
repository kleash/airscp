import Darwin
import Foundation
import Testing
@testable import AirSCPCore

// PLAN.md AE: the debug log. Off by default and then nothing is written; on, a host's commands run with ssh's -vv and
// everything they and the proxy helper say goes into the file (the rest of AirSCP sees the same error output as without),
// with the questions asked, the states, the transfers and FreeRDP's log; no secret is ever written; the file is rotated
// at 10 MB. Against the Docker lab (AIRSCP_DOCKER=1): each broken proxy and jump-host chain names the hop that failed.
//
// The log is one for the whole test process: these tests run one at a time, and each reads only its own host's lines
// (other suites' sessions, which may run meanwhile, write under their own names, and they run as they would anyway).
// Other tests' passwords are secrets too ("wrong", "typed"): the names here contain none of them.

@Suite(.serialized) struct DebugLogTests {
    @Test func offByDefaultWritesNothing() async throws {
        #expect(!AppSettings().debugLogging)
        #expect(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).debugLogging == false)
        #expect(!DebugLog.enabled && !DebugLog.forced)  // AIRSCP_DEBUG isn't set for the tests
        try await withServer { server in
            let before = logSize()
            var host = server.host()
            host.label = "ae-off-" + UUID().uuidString.prefix(6)
            let session = try server.session(host)
            try await session.connect()
            #expect(try await session.run("echo to stderr >&2").stderr == "to stderr\n")
            await session.disconnect()
            #expect(logSize() == before)
            #expect(!(await server.logEntries()).contains { $0.command.contains("-vv") })
        }
    }

    /// A throwaway AirSCP (AIRSCP_SSH_DIR; the tests are one) never offers the user's own keys: every command gets
    /// IdentityFile=none, so a host without a key file of its own reads nothing under the real ~/.ssh (ssh's -vv names
    /// each identity file it loads: id_rsa, id_ed25519… were read before), while a host's own key file still logs in.
    @Test func aThrowawayNeverReadsTheUsersOwnKeys() async throws {
        let realKeys = String(cString: getpwuid(getuid())!.pointee.pw_dir) + "/.ssh/"
        try await withServer { server in
            try await withDebugLog {
                var host = server.host()
                host.label = "ae-keys-" + UUID().uuidString.prefix(6)
                host.auth = .agent
                host.keyFile = ""
                let session = try server.session(host)
                await #expect(throws: AirSCPError.self) { try await session.connect() }
                let lines = debugLines(host.label)
                #expect(lines.contains { $0.contains("-o IdentityFile=none") })
                #expect(!lines.contains { $0.contains(realKeys) }, "\(lines.filter { $0.contains(realKeys) })")
                #expect(server.prompts.all.isEmpty)  // no passphrase of a key of the user's asked for
                var own = server.host()
                own.label = host.label + "-own"
                try await server.session(own).connect()
            }
        }
    }

    /// At 10 MB (here 100 KB: the log is on for every test running meanwhile) the file becomes AirSCP-debug.1.log,
    /// replacing the one before, and a new file starts.
    @Test func rotatesAtTenMegabytesKeepingOnePreviousFile() throws {
        #expect(DebugLog.sizeLimit == 10 << 20)
        DebugLog.sizeLimit = 100_000
        defer { DebugLog.sizeLimit = 10 << 20 }
        withDebugLog {
            let line = String(repeating: "x", count: 1000)
            for _ in 0..<250 { DebugLog.write(line, host: "ae-rotation") }
            DebugLog.flush()
            #expect(size(DebugLog.previousFileURL) >= 100_000 && logSize() < 100_000)
            let files = names(in: DebugLog.fileURL.deletingLastPathComponent().path).filter { $0.hasPrefix("AirSCP-debug") }
            #expect(Set(files).isSubset(of: ["AirSCP-debug.1.log", "AirSCP-debug.log"]), "\(files)")
            // A file removed meanwhile (the user deleted it) is made again.
            try? FileManager.default.removeItem(at: DebugLog.fileURL)
            DebugLog.write("after the file was removed", host: "ae-rotation")
            #expect(debugLines("ae-rotation").last?.hasSuffix("after the file was removed") == true)
        }
    }

    /// ssh's -vv output goes into the log only: what AirSCP shows and maps stays as without it.
    @Test func debugOutputStaysInTheLog() async throws {
        // Chunks cut anywhere, debug lines of each tool, an unfinished last line.
        let lines = DebugLog.ErrorOutput(["/usr/bin/scp"], input: nil, pid: 1, hostID: nil)
        var kept = Data()
        for chunk in ["debug1: Reading configuration data /etc/ssh/ssh_config\nscp: debug2: Remote ve",
                      "rsion: 3\n/usr/bin/scp: deb", "ug1: stat remote: No such file or directory\nscp: /x: No such",
                      " file or directory\nAuthenticated to h ([1.2.3.4]:22) using \"publickey\".\n\ndebug1: proxy-connect: x\n",
                      "Transferred: sent 1, received 2 bytes\nBytes per second: sent 1.0, received 2.0\nlast words"] {
            kept += lines.pass(Data(chunk.utf8))
        }
        kept += lines.finish()
        #expect(String(decoding: kept, as: UTF8.self) == "scp: /x: No such file or directory\n\nlast words")
        #expect(DebugLog.isDebugOutput("sftp: debug1: x") && !DebugLog.isDebugOutput("Permission denied (publickey)."))
        // Lines end as ssh ends them (\r\n), each with the time and the host.
        withDebugLog {
            DebugLog.write("one\r\ntwo\nthree", host: "ae-lines")
            let written = debugLines("ae-lines").suffix(3).map { $0.components(separatedBy: " [ae-lines] ").last }
            #expect(written == ["one", "two", "three"])
        }
        // A window adjust per packet (55 000 lines for 2 GB) pushed everything else out of the log: those aren't kept.
        #expect(DebugLog.isWindowAdjust("debug2: channel 0: rcvd adjust 16384"))
        #expect(DebugLog.isWindowAdjust("debug2: channel 2: window 1966080 sent adjust 131072"))
        #expect(!DebugLog.isWindowAdjust("debug2: channel 0: open confirm rwindow 0 rmax 32768"))

        // -vv goes before the options: the tools' own flags stay first, and a jump host's ssh gets it too.
        let host = SSHHost(hostname: "target"), jump = SSHHost(hostname: "bastion")
        let master = OpenSSH.verbose(OpenSSH.master(host, jump: jump, socket: "/s"))
        #expect(master.prefix(4) == ["/usr/bin/ssh", "-M", "-N", "-vv"])
        #expect(master.contains { $0.hasPrefix("ProxyCommand=/usr/bin/ssh -vv ") })
        #expect(OpenSSH.verbose(OpenSSH.upload("/a", to: "/b", folder: true, preserveTimes: false, host, jump: nil, socket: "/s"))
            .prefix(3) == ["/usr/bin/scp", "-r", "-vv"])
        #expect(OpenSSH.verbose(["/usr/bin/ssh-keygen", "-l", "-f", "/k"]) == ["/usr/bin/ssh-keygen", "-l", "-f", "/k"])

        try await withServer { server in
            var host = server.host()
            host.label = "ae-quiet-" + UUID().uuidString.prefix(6)
            let session = try server.session(host)
            let result = try await withDebugLog {
                try await session.connect()
                return try await session.run("echo to stderr >&2")
            }
            #expect(result.stderr == "to stderr\n")
            let logged = debugLines(host.label)
            #expect(logged.contains { $0.contains("] ssh[") && $0.contains(": debug1: ") }, "\(logged)")
            #expect(logged.contains { $0.contains(": to stderr") })
            let shell = session.capabilities.loginShell
            #expect(logged.contains { $0.hasSuffix("State: connected (login shell \(shell), home \(server.home))") })
            // The command log shows the commands as AirSCP builds them.
            #expect(!(await server.logEntries()).contains { $0.command.contains("-vv") })
        }
    }

    /// No password, passphrase, proxy password, token or file content reaches the file, whichever way it would go. (The
    /// log is on only while connecting and copying: it is on for every test running meanwhile.)
    @Test func noSecretReachesTheLog() async throws {
        let typed = "Typed-S3cret-pw", saved = "Saved-S3cret-pw", proxyPassword = "Proxy-S3cret-pw"
        let rdpPassword = "Rdp-S3cret-pw", content = "File-S3cret-content"
        // Asked and typed (refused by the test server, which can't check passwords: asked again), then saved.
        try await withServer(TestServer.Options(passwords: true)) { server in
            var host = server.host(key: "/nonexistent-key")
            host.auth = .password
            host.label = "ae-password-" + UUID().uuidString.prefix(6)
            let asked = Recorder<Prompt>()
            let session = try server.session(host) { prompt in
                asked.append(prompt)
                return asked.all.count < 3 ? PromptAnswer(typed) : nil
            }
            let again = try server.session(host) { _ in nil }
            again.savedPassword = { _ in saved }
            await withDebugLog {
                await #expect(throws: AirSCPError.self) { try await session.connect() }
                await #expect(throws: AirSCPError.self) { try await again.connect() }
            }
            let logged = debugLines(host.label).joined(separator: "\n")
            #expect(logged.contains("password:”: asked") && logged.contains("password:”: answered"), "\(logged)")
            // "… with the saved password of …" (a word may be blanked out: other tests' passwords are secrets too)
            #expect(logged.contains("password:”: answered with the "))
            #expect(logged.contains("password:”: cancelled"))
        }
        try await withServer { server in
            // Through a proxy with a password: what the proxy answered, never the password or its header.
            let proxy = try TestProxy(user: "porter", password: proxyPassword)
            defer { proxy.stop() }
            let savedProxy = proxy.saved(user: "porter")
            var host = server.host()
            host.label = "ae-secrets-" + UUID().uuidString.prefix(6)
            host.proxyID = savedProxy.id
            let session = try server.session(host)
            answer(savedProxy, password: proxyPassword, on: session.askpass)
            let token = try #require(session.askpass.environment(for: "x")["AIRSCP_ASKPASS_TOKEN"])
            let local = try server.scratch()
            try write(content, to: local + "/secret.txt")
            try await withDebugLog {
                try await session.connect()
                // A command that prints secrets on its error output: the askpass token, a password typed before.
                _ = try await session.run("echo token \(token) password \(typed) >&2")
                // A file's contents never: transfers and command output aren't logged.
                session.transfers.upload(local + "/secret.txt", to: server.path("secret.txt"), isFolder: false)
                await session.transfers.waitUntilIdle()
                #expect(try await session.run("cat " + Quote.shell(server.path("secret.txt"))).output == content)
            }
            let logged = debugLines(host.label).joined(separator: "\n")
            #expect(logged.contains("debug1: proxy-connect: the proxy 127.0.0.1:\(proxy.port) (user porter) answered CONNECT "
                + "127.0.0.1:\(server.port) with “HTTP/1.1 200 Connection established”: connected"), "\(logged)")
            #expect(logged.contains("] (line left out: it held a password or token)") && !logged.contains(": token "))
            #expect(logged.contains("Transfer started: upload ") && logged.contains("Transfer done: upload "))
            for secret in [token, Data("porter:\(proxyPassword)".utf8).base64EncodedString()] {
                #expect(!logged.contains(secret))
            }
        }
        // Remote Desktop: FreeRDP's own log comes in too, without the password.
        let closed = try listener()
        close(closed.fd)
        close(closed.fd6)
        await withDebugLog {
            await #expect(throws: AirSCPError.self) {
                try await RDPSession.testLogin(RDPSession.Target(host: "127.0.0.1", port: closed.port, username: "porter",
                                                                 password: rdpPassword))
            }
            // An HTTP authorization header, whatever printed it.
            DebugLog.write("CONNECT x:22 HTTP/1.1\nProxy-Authorization: Basic cG9ydGVyOnNlY3JldA==", host: "ae-header")
        }
        let rdp = debugLines("127.0.0.1").joined(separator: "\n")
        #expect(rdp.contains("Remote Desktop: connecting to 127.0.0.1:\(closed.port) as porter") && rdp.contains("FreeRDP "),
                "\(rdp)")
        #expect(debugLines("ae-header").last?.hasSuffix("Proxy-Authorization: [redacted]") == true)
        let file = (read(DebugLog.previousFileURL.path) ?? "") + (read(DebugLog.fileURL.path) ?? "")
        for secret in [typed, saved, proxyPassword, rdpPassword, content, "cG9ydGVyOnNlY3JldA=="] {
            #expect(!file.contains(secret), "\(secret) is in the debug log")
        }
    }

    /// A line that holds a secret is left out whole: "[redacted]" in its place would say which text the secret was where
    /// a reader can guess it (a password that is also the user name). A secret counts only on its own, so a short code
    /// doesn't take out numbers it is part of. Many typed secrets don't slow the log down.
    @Test func linesWithASecretAreLeftOutWhole() {
        DebugLog.Secrets.add(String(NSString(string: "vagrant-7Kq")))  // typed into a secure field: a bridged NSString
        DebugLog.Secrets.add("000000")
        #expect(DebugLog.redacted("Authenticating to 127.0.0.1:42552 as 'vagrant-7Kq'\n-o User=vagrant-7Kq\nthe end")
            == "(line left out: it held a password or token)\n(line left out: it held a password or token)\nthe end")
        #expect(DebugLog.redacted("debug2: compat 0x04000000 and vagrant-7Kqx") == "debug2: compat 0x04000000 and vagrant-7Kqx")
        #expect(DebugLog.redacted("code: 000000.") == "(line left out: it held a password or token)")
        #expect(DebugLog.redacted("é000000") == "é000000" && DebugLog.redacted("") == "")
        for index in 0..<30 { DebugLog.Secrets.add(String(NSString(string: "Typed-Secret-\(index)-ae"))) }
        let chunk = String(repeating: "debug1: channel 0: new [client-session] on a busy connection\n", count: 20_000)
        let started = Date()
        #expect(DebugLog.redacted(chunk) == chunk)
        #expect(Date().timeIntervalSince(started) < 10, "\(Date().timeIntervalSince(started)) s for 1.2 MB")  // it was minutes
    }

    /// Where a failed connect stopped, in words, from ssh's and the proxy helper's error output.
    @Test func theFailedHopIsNamed() {
        var bastion = SSHHost(label: "bastion", hostname: "10.0.0.5", port: 2200, username: "jump")
        let target = SSHHost(label: "db", hostname: "db.internal", username: "dev")
        func hop(_ errors: String, jump: SSHHost?) -> String { Session.failedHop(errors, host: target, jump: jump) }
        #expect(hop("AirSCP proxy: HTTP/1.1 407 Proxy Authentication Required", jump: bastion)
            == "at the HTTP proxy, on the way to the jump host “bastion” (jump@10.0.0.5:2200)")
        #expect(hop("AirSCP proxy: HTTP/1.1 502 Bad Gateway", jump: nil) == "at the HTTP proxy, on the way to “db” (dev@db.internal:22)")
        #expect(hop("ssh: connect to host 10.0.0.5 port 2200: Connection refused\r\nConnection closed by UNKNOWN port 65535",
                    jump: bastion)
            == "at the jump host “bastion” (jump@10.0.0.5:2200)")
        #expect(hop("jump@10.0.0.5: Permission denied (publickey).", jump: bastion) == "at the jump host “bastion” (jump@10.0.0.5:2200)")
        #expect(hop("No ED25519 host key is known for [10.0.0.5]:2200 and you have requested strict checking.\r\n"
            + "Host key verification failed.", jump: bastion) == "at the jump host “bastion” (jump@10.0.0.5:2200)")
        #expect(hop("channel 0: open failed: connect failed: Connection refused\r\nstdio forwarding failed", jump: bastion)
            == "at “db” (dev@db.internal:22): the jump host “bastion” couldn't open a connection to it")
        #expect(hop("dev@db.internal: Permission denied (publickey,password).", jump: bastion)
            == "at “db” (dev@db.internal:22), behind the jump host “bastion”")
        bastion.label = ""
        #expect(hop("ssh: Could not resolve hostname 10.0.0.5: nodename nor servname provided", jump: bastion)
            == "at the jump host jump@10.0.0.5:2200")
        #expect(hop("Connection refused", jump: nil) == "at “db” (dev@db.internal:22)")
        // The connect error people see says it too, when the jump host or the way past it was where it stopped.
        bastion.label = "bastion"
        let refused = AirSCPError(.refused, "The server refused the connection.",
                                  details: "ssh: connect to host 10.0.0.5 port 2200: Connection refused\r\nConnection closed by UNKNOWN port 65535")
        #expect(Session.namingTheHop(refused, host: target, jump: bastion).message
            == "It stopped at the jump host “bastion” (jump@10.0.0.5:2200). The server refused the connection.")
        let behind = AirSCPError(.refused, "The server refused the connection.",
                                 details: "channel 0: open failed: connect failed: Connection refused\r\nstdio forwarding failed")
        #expect(Session.namingTheHop(behind, host: target, jump: bastion).message.hasPrefix("It stopped at “db” (dev@db.internal:22): "
            + "the jump host “bastion” couldn't open a connection to it. The server refused"))
        let login = AirSCPError(.authFailed(methods: "publickey"), "The server didn't accept the login.",
                                details: "dev@db.internal: Permission denied (publickey).")
        #expect(Session.namingTheHop(login, host: target, jump: bastion) == login)  // the host itself: as it was
        #expect(Session.namingTheHop(refused, host: target, jump: nil) == refused)
    }

    // MARK: Broken chains against the Docker lab

    /// Proxy (wrong password) → bastion → private: the proxy's 407, and the hop named.
    @Test(.enabled(if: Lab.enabled, "Docker lab: AIRSCP_DOCKER=1 ./test.sh"))
    func aProxyThatRefusesThePasswordIsNamed() async throws {
        let logged = try await brokenChain("ae-proxy407", proxy: (Lab.proxy, "not the password"))
        #expect(logged.contains("debug1: proxy-connect: the proxy 127.0.0.1:42280 (user porter) answered CONNECT bastion:22 "
            + "with “HTTP/1.0 407 Proxy Authentication Required”: no connection"), "\(logged)")
        #expect(logged.contains("Couldn't connect: it stopped at the HTTP proxy, on the way to the jump host “ae-proxy407 bastion” "
            + "(jump@bastion:22): The proxy rejected the user name or password."), "\(logged)")
    }

    /// Open proxy → bastion → private with a key private doesn't know: the bastion was logged in to, private refused.
    @Test(.enabled(if: Lab.enabled, "Docker lab: AIRSCP_DOCKER=1 ./test.sh"))
    func aWrongKeyBehindTheOpenProxyAndTheBastionIsNamed() async throws {
        let folder = try scratch()
        try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "unknown", "-f", folder + "/id_unknown"])
        let open = Proxy(name: "Lab open proxy", host: "127.0.0.1", port: 42281)
        let logged = try await brokenChain("ae-key", proxy: (open, ""), key: folder + "/id_unknown")
        #expect(logged.contains("debug1: proxy-connect: the proxy 127.0.0.1:42281 answered CONNECT bastion:22 with “HTTP/1.1 200 "
            + "Connection established”: connected"),
                "\(logged)")
        #expect(logged.contains("Authenticated to bastion (via proxy)"), "\(logged)")
        #expect(logged.contains("dev@private's password:”: cancelled"), "\(logged)")
        #expect(logged.contains("Couldn't connect: it stopped at “ae-key private” (dev@private:22), behind the jump host "
            + "“ae-key bastion”: The server didn't accept the"), "\(logged)")
    }

    /// A jump host nothing answers for (a stopped bastion): named as the jump host.
    @Test(.enabled(if: Lab.enabled, "Docker lab: AIRSCP_DOCKER=1 ./test.sh"))
    func anUnreachableJumpHostIsNamed() async throws {
        let closed = try listener()
        close(closed.fd)
        close(closed.fd6)
        let logged = try await brokenChain("ae-nobastion", bastionAt: ("127.0.0.1", closed.port))
        #expect(logged.contains("Couldn't connect: it stopped at the jump host “ae-nobastion bastion” (jump@127.0.0.1:\(closed.port)): "
            + "The server refused the connection."), "\(logged)")
    }

    /// Bastion → a port nothing listens on behind it: the bastion couldn't open the connection.
    @Test(.enabled(if: Lab.enabled, "Docker lab: AIRSCP_DOCKER=1 ./test.sh"))
    func aRefusedPortBehindTheBastionIsNamed() async throws {
        let logged = try await brokenChain("ae-refused", target: ("target", 2222))
        #expect(logged.contains("Authenticated to 127.0.0.1 ([127.0.0.1]:42203)"), "\(logged)")
        #expect(logged.contains("Couldn't connect: it stopped at “ae-refused private” (dev@target:2222): the jump host "
            + "“ae-refused bastion” couldn't open a connection to it: The server refused the connection."), "\(logged)")
    }

    /// Proxy → bastion → private that works: every hop is in the log.
    @Test(.enabled(if: Lab.enabled, "Docker lab: AIRSCP_DOCKER=1 ./test.sh"))
    func aWorkingChainShowsEveryHop() async throws {
        try await withDebugLog {
            try await withLab { lab in
                let (bastion, target) = chain("ae-chain", proxy: Lab.proxy)
                let session = try lab.session(target, jump: bastion)
                session.askpass.proxyHandler = { id, _, _, reply in reply(id == Lab.proxy.id ? (Lab.proxy, Lab.proxyPassword) : nil) }
                try await session.connect()
                #expect(try await session.run("hostname").output.hasSuffix("private\n"))
                let logged = debugLines(target.label).joined(separator: "\n")
                #expect(logged.contains("Connecting: This Mac → HTTP proxy → jump host “ae-chain bastion” (jump@bastion:22) → "
                    + "“ae-chain private” (dev@private:22)"), "\(logged)")
                #expect(logged.contains("debug1: proxy-connect: the proxy 127.0.0.1:42280 (user porter) answered CONNECT bastion:22 "
                    + "with “HTTP/1.1 200 Connection established”: connected"), "\(logged)")
                #expect(logged.contains("Authenticated to bastion (via proxy)") && logged.contains("Authenticated to private (via proxy)"))
                #expect(logged.contains("State: connected"))
                #expect(!logged.contains(Lab.proxyPassword))
            }
        }
    }
}

// MARK: Helpers

/// Runs `body` with the debug log on.
private func withDebugLog<T>(_ body: () async throws -> T) async rethrows -> T {
    _ = TestEnvironment.isolated
    DebugLog.enabled = true
    defer { DebugLog.enabled = false }
    return try await body()
}

private func withDebugLog<T>(_ body: () throws -> T) rethrows -> T {
    _ = TestEnvironment.isolated
    DebugLog.enabled = true
    defer { DebugLog.enabled = false }
    return try body()
}

/// The lines about `host` in the log and the one before it.
private func debugLines(_ host: String) -> [String] {
    DebugLog.flush()
    return ((read(DebugLog.previousFileURL.path) ?? "") + (read(DebugLog.fileURL.path) ?? "")).components(separatedBy: "\n")
        .filter { $0.contains(" [\(host)] ") }
}

private func size(_ url: URL) -> Int {
    ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
}

private func logSize() -> Int {
    DebugLog.flush()
    return size(DebugLog.fileURL)
}

/// The lab's bastion and private host (reachable only through it) as saved hosts named "<name> bastion" and
/// "<name> private", the bastion through `proxy`, or at `bastionAt` instead of the lab's.
private func chain(_ name: String, proxy: Proxy? = nil, bastionAt: (String, Int)? = nil, target: (String, Int) = ("private", 22),
                   key: String? = nil) -> (SSHHost, SSHHost) {
    var bastion = bastionAt.map { Lab.host("jump", hostname: $0.0, port: $0.1) }
        ?? (proxy == nil ? Lab.bastion() : Lab.host("jump", hostname: "bastion", port: 22))
    bastion.label = name + " bastion"
    bastion.proxyID = proxy?.id
    var private_ = Lab.host("dev", hostname: target.0, port: target.1)
    private_.label = name + " private"
    private_.jumpHostID = bastion.id
    if let key { private_.keyFile = key }
    return (bastion, private_)
}

/// Connects through a chain that must fail (its questions cancelled), with the debug log on; the target's lines.
private func brokenChain(_ name: String, proxy: (Proxy, String)? = nil, bastionAt: (String, Int)? = nil,
                         target: (String, Int) = ("private", 22), key: String? = nil) async throws -> String {
    try await withDebugLog {
        var logged = ""
        try await withLab { lab in
            let (bastion, private_) = chain(name, proxy: proxy?.0, bastionAt: bastionAt, target: target, key: key)
            let session = try lab.session(private_, jump: bastion)
            if let (saved, password) = proxy {
                session.askpass.proxyHandler = { id, _, _, reply in reply(id == saved.id ? (saved, password) : nil) }
            }
            await #expect(throws: AirSCPError.self) { try await session.connect() }
            logged = debugLines(private_.label).joined(separator: "\n")
        }
        return logged
    }
}
