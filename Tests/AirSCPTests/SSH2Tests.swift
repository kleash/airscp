#if canImport(AirSCPSSH2)
import AirSCPSSH2
import Darwin
import Foundation
import Testing
@testable import AirSCPCore

// libssh2 (AirSCPSSH2: the iPhone and iPad app's SSH) against a throwaway sshd: a Session over it must do what it does
// over macOS's ssh. Built when scripts/build-libssh2.sh has made vendor/ssh2.

extension TestServer {
    /// A session over libssh2, with the same host, key and known_hosts as `session`'s.
    func ssh2Session(_ host: SSHHost? = nil, answer: ((Prompt) -> PromptAnswer?)? = nil) throws -> Session {
        let host = host ?? self.host()
        return try session(host, transport: SSH2Transport(host: host, jump: nil, knownHosts: knownHosts), answer: answer)
    }

    /// A folder with what listings must get right: spaces, non-ASCII and dot names, a link, a subfolder.
    func makeSampleFolder() throws -> String {
        let folder = path("sample")
        try write("one\n", to: folder + "/a file.txt")
        try write("two\n", to: folder + "/Grüße – ✓.txt")
        try write("", to: folder + "/.hidden")
        try write("deep\n", to: folder + "/sub/inner.txt")
        symlink("a file.txt", folder + "/link")
        chmod(folder + "/a file.txt", 0o640)
        return folder
    }
}

@Test func overLibssh2CommandsAndScriptsRunAsOverSSH() async throws {
    try await withServer { server in
        let folder = try server.makeSampleFolder()
        let ssh = try await server.connectedSession()
        let ssh2 = try server.ssh2Session()
        try await ssh2.connect()
        #expect(ssh2.capabilities == ssh.capabilities)
        #expect(ssh2.capabilities.shell && ssh2.capabilities.home == server.home)

        let result = try await ssh2.run("printf out; printf err >&2; exit 3")
        #expect(result.status == 3 && result.output == "out" && result.stderr == "err")
        let input = try await ssh2.run("wc -c", sh: true)
        #expect(input.status == 0 && input.output.trimmingCharacters(in: .whitespaces).hasPrefix("0"))

        #expect(try await ssh2.list(folder) == ssh.list(folder))
        await ssh2.disconnect()
        #expect(ssh2.state == .idle)
    }
}

@Test func overLibssh2AnSFTPOnlyAccountIsBrowsedAsOverSSH() async throws {
    try await withServer(TestServer.Options(sftpOnly: true)) { server in
        let folder = try server.makeSampleFolder()
        let ssh = try await server.connectedSession()
        let ssh2 = try server.ssh2Session()
        try await ssh2.connect()
        #expect(ssh2.capabilities == ssh.capabilities)
        #expect(!ssh2.capabilities.shell && ssh2.capabilities.home == server.home)

        // What sftp prints: listings, one item, disk space.
        #expect(try await ssh2.list(folder) == ssh.list(folder))
        #expect(try await ssh2.listings([folder, folder + "/sub", folder + "/gone"]) == ssh.listings([folder, folder + "/sub", folder + "/gone"]))
        for name in ["a file.txt", "link", "sub", "gone"] {
            let ours = try await ssh2.item(folder + "/" + name), theirs = try await ssh.item(folder + "/" + name)
            #expect(ours?.kind == theirs?.kind && ours?.mode == theirs?.mode && ours?.owner == theirs?.owner,
                    "\(name): \(String(describing: ours)) vs ssh's \(String(describing: theirs))")
        }
        let there = try await ssh2.exists(folder + "/link"), gone = try await ssh2.exists(folder + "/gone")
        #expect(there && !gone)
        #expect(try await ssh2.diskFree(folder).size == ssh.diskFree(folder).size)

        // What sftp changes.
        try await ssh2.makeDirectory(folder + "/made")
        try await ssh2.createFile(folder + "/made/empty")
        try await ssh2.rename(folder + "/made/empty", to: folder + "/made/renamed")
        #expect(names(in: folder + "/made") == ["renamed"])
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("airscp-ssh2-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: local) }
        try Data("payload ✓\n".utf8).write(to: local)
        try await ssh2.store(local, to: folder + "/made/stored.txt")
        #expect(read(folder + "/made/stored.txt") == "payload ✓\n")
        try FileManager.default.removeItem(at: local)
        try await ssh2.fetch(folder + "/a file.txt", to: local)
        #expect(try String(contentsOf: local) == "one\n")
        let stored = try await ssh2.list(folder + "/made").first { $0.name == "stored.txt" }!
        try await ssh2.setPermissions(stored, mode: 0o600)
        #expect(try await ssh2.item(stored.path)?.mode == 0o600)
        try await ssh2.makeLink(folder + "/made/back", to: "../a file.txt")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: folder + "/made/back") == "../a file.txt")
        try await ssh2.delete(ssh2.list(folder + "/made"))
        #expect(names(in: folder + "/made").isEmpty)

        // sftp's own words for what isn't there.
        await #expect(throws: AirSCPError.self) { try await ssh2.rename(folder + "/gone", to: folder + "/still-gone") }
        do {
            try await ssh2.makeDirectory(folder + "/gone/deeper")
            Issue.record("made a folder in one that isn't there")
        } catch let error as AirSCPError {
            #expect(error.kind == .noSuchFile, "\(error.details)")
        }
    }
}

@Test func overLibssh2ANewHostKeyIsAskedAboutAndAChangedOneRefused() async throws {
    try await withServer { server in
        let fingerprint = String(try await run(["/usr/bin/ssh-keygen", "-lf", server.root + "/host_key.pub"]).output
            .split(separator: " ")[1])
        let ssh2 = try server.ssh2Session(server.host(trustNewHostKeys: false)) { _ in .trust }
        try await ssh2.connect()
        #expect(server.prompts.all.count == 1)
        if case .hostKey(let host, let shown) = server.prompts.all.first?.kind {
            #expect(host == "[127.0.0.1]:\(server.port)" && shown == fingerprint)
        } else {
            Issue.record("asked \(server.prompts.all)")
        }
        await ssh2.disconnect()
        try await ssh2.connect()  // known now: nothing asked
        #expect(server.prompts.all.count == 1)
        await ssh2.disconnect()
        // ssh takes the key libssh2 saved.
        _ = try await server.connectedSession(server.host(trustNewHostKeys: false))

        let other = server.root + "/other_key"
        _ = try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", other])
        let key = try String(contentsOfFile: other + ".pub").split(separator: " ").prefix(2).joined(separator: " ")
        try "[127.0.0.1]:\(server.port) \(key)\n".write(toFile: server.knownHosts, atomically: true, encoding: .utf8)
        do {
            try await ssh2.connect()
            Issue.record("connected to a server whose key changed")
        } catch let error as AirSCPError {
            #expect(error.kind == .hostKeyChanged)
        }
        #expect(server.prompts.all.count == 1)
    }
}

@Test func aTrustedKeyIsListedWithItsFingerprintAndForgotten() async throws {
    try await withServer { server in
        let fingerprint = String(try await run(["/usr/bin/ssh-keygen", "-lf", server.root + "/host_key.pub"]).output
            .split(separator: " ")[1])
        let ssh2 = try server.ssh2Session(server.host(trustNewHostKeys: false)) { _ in .trust }
        try await ssh2.connect()
        await ssh2.disconnect()
        let entries = KnownHosts.entries(server.knownHosts)
        #expect(entries.map(\.host) == ["[127.0.0.1]:\(server.port)"] && entries.map(\.fingerprint) == [fingerprint],
                "\(entries)")

        try KnownHosts.forget(entries[0], in: server.knownHosts)
        #expect(KnownHosts.entries(server.knownHosts).isEmpty)
        try await ssh2.connect()  // asked again
        #expect(server.prompts.all.count == 2)
    }
}

@Test func overLibssh2AnEncryptedKeyAsksForItsPassphrase() async throws {
    try await withServer { server in
        let ssh2 = try server.ssh2Session(server.host(key: server.encryptedKey)) { _ in
            PromptAnswer(server.prompts.all.count == 1 ? "wrong" : TestServer.passphrase)
        }
        try await ssh2.connect()
        #expect(server.prompts.all.map(\.kind) == [.passphrase, .passphrase])
        #expect(server.prompts.all.last?.retry == true)
        #expect(try await ssh2.run("printf ok").output == "ok")
    }
}

@Test func overLibssh2ADroppedConnectionShowsAsDisconnected() async throws {
    try await withServer { server in
        let ssh2 = try server.ssh2Session()
        try await ssh2.connect()
        // sshd's process for this connection ends, as when the server goes away.
        let sshd = try String(contentsOfFile: server.root + "/sshd.pid").trimmingCharacters(in: .whitespacesAndNewlines)
        try await run(["/usr/bin/pkill", "-P", sshd])
        await #expect(throws: AirSCPError.self) { try await ssh2.run("true") }
        if case .disconnected = ssh2.state {} else { Issue.record("state \(ssh2.state)") }
    }
}

/// The lab's logins and routes over libssh2.
@Suite(.enabled(if: Lab.enabled)) struct SSH2LabTests {
    func session(_ lab: LabRun, _ host: SSHHost, jump: SSHHost? = nil,
                 answer: @escaping (Prompt) -> PromptAnswer?) throws -> Session {
        let knownHosts = TestEnvironment.root + "/ssh2_known_hosts." + UUID().uuidString.prefix(8)
        return try lab.session(host, jump: jump, transport: SSH2Transport(host: host, jump: jump, knownHosts: knownHosts),
                               answer: answer)
    }

    /// PAM's password (keyboard-interactive) and the two-factor server's code come as ssh asks them, a wrong code again.
    @Test func passwordsAndVerificationCodesAreAskedAsSSHAsksThem() async throws {
        try await withLab { lab in
            let target = try session(lab, Lab.target(password: true)) { _ in PromptAnswer(Lab.devPassword) }
            try await target.connect()
            #expect(lab.prompts.all.map(\.kind) == [.password(user: "dev", host: "127.0.0.1")])
            #expect(try await target.run("whoami").output.hasSuffix("dev\n"))

            let prompts = lab.prompts
            let twofactor = try session(lab, Lab.twofactor()) { _ in
                PromptAnswer(prompts.all.count == 2 ? "wrong" : Lab.verificationCode())
            }
            try await twofactor.connect()
            let asked = prompts.all.dropFirst()
            #expect(asked.count == 2 && asked.allSatisfy { $0.kind == .other && $0.text.contains("Verification code:") },
                    "\(asked.map(\.text))")
            #expect(asked.map(\.retry) == [false, true])
            #expect(try await twofactor.run("whoami").output == "dev\n")
        }
    }

    /// The target through the bastion (a direct-tcpip channel), and the chrooted sftp-only account.
    @Test func aJumpHostIsGoneThroughAndAnSFTPOnlyAccountBrowsed() async throws {
        try await withLab { lab in
            let target = try session(lab, Lab.host("dev", hostname: "target", port: 22), jump: Lab.bastion(password: true)) {
                $0.kind == .password(user: "jump", host: "127.0.0.1") ? PromptAnswer(Lab.jumpPassword) : nil
            }
            try await target.connect()
            #expect(try await target.run("hostname").output.hasSuffix("target\n"))
            #expect(try await !target.list("/etc").isEmpty)

            let sftp = try session(lab, Lab.target("sftponly", password: true)) { _ in PromptAnswer(Lab.sftpPassword) }
            try await sftp.connect()
            #expect(!sftp.capabilities.shell)
            #expect(try await sftp.list("/upload").contains { $0.name == "other-disk" })
        }
    }
}
#endif
