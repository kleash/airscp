import Darwin
import Foundation
import Security
import Testing
@testable import AirSCPCore

/// Runs the AirSCP binary the way ssh runs it as SSH_ASKPASS, and returns what it printed and its status.
private func askpassHelper(_ prompt: String, environment: [String: String]) async -> (output: String, status: Int32) {
    let result = await Runner.run([TestEnvironment.airscpBinary, prompt], environment: environment)
    return (result.output, result.status)
}

@Test func generatedKeysAskForTheirPassphraseThroughAskpass() async throws {
    _ = TestEnvironment.isolated
    let folder = TestEnvironment.root + "/keys-" + UUID().uuidString.prefix(8)
    try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: folder) }
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let prompts = Recorder<String>()
    askpass.setHandler({ request, reply in
        prompts.append(request.prompt)
        reply(request.kind == .passphrase ? "a generated passphrase" : nil)
    }, for: "keys")

    let path = folder + "/id_new"
    try await Keys.generate(.ed25519, path: path, comment: "airscp test", askpass: askpass.environment(for: "keys"))
    #expect(prompts.all.count == 2)  // the passphrase, then again to confirm
    #expect(prompts.all.first?.contains("(empty for no passphrase)") == true)
    // Nothing secret in the command line, and the key really has that passphrase.
    try await run(["/usr/bin/ssh-keygen", "-y", "-P", "a generated passphrase", "-f", path])
    let wrong = await Runner.run(["/usr/bin/ssh-keygen", "-y", "-P", "wrong", "-f", path])
    #expect(wrong.status != 0)
    // Never over an existing key.
    await #expect(throws: AirSCPError.self) {
        try await Keys.generate(.ed25519, path: path, comment: "again", askpass: askpass.environment(for: "keys"))
    }

    try write("not a key pair on its own", to: folder + "/notes.txt")
    let pairs = await Keys.list(in: folder)
    #expect(pairs.count == 1)
    #expect(pairs.first?.privateKey == path && pairs.first?.publicKey == path + ".pub")
    #expect(pairs.first?.type == "ED25519" && pairs.first?.comment == "airscp test" && pairs.first?.bits == 256)
    #expect(pairs.first?.fingerprint.hasPrefix("SHA256:") == true)
}

@Test func installKeyWithSSHCopyIDOnAKeyHost() async throws {
    try await withServer { server in
        // A new key without a passphrase (empty answers).
        let newKey = server.root + "/keys dir/id_new"
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        askpass.setHandler({ _, reply in reply("") }, for: "keys")
        try await Keys.generate(.ed25519, path: newKey, comment: "new key", askpass: askpass.environment(for: "keys"))

        // The host already logs in with a key file: ssh-copy-id needs -f, or its probe would log in with that key
        // and skip the new one as "already installed".
        let session = try server.session()
        try await session.installKey(newKey + ".pub")
        #expect((await server.logEntries()).contains { $0.command.hasPrefix("/usr/bin/ssh-copy-id -f -i ") })
        // ssh-copy-id appended it to the account's ~/.ssh/authorized_keys (the test server's HOME).
        let installed = try #require(read(server.path(".ssh/authorized_keys")))
        #expect(installed.contains(try #require(read(newKey + ".pub")).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(server.prompts.all.isEmpty)
        // ...and it works: log in with only the new key.
        let withNewKey = try await server.connectedSession(server.host(key: newKey))
        #expect(withNewKey.state == .connected)
        // ssh-copy-id's scratch folder went into the test HOME, and is gone again.
        #expect(names(in: TestEnvironment.root + "/local-home/.ssh").isEmpty)
    }
}

@Test func installKeyOnAnSFTPOnlyAccount() async throws {
    try await withServer(TestServer.Options(sftpOnly: true)) { server in
        let newKey = server.root + "/keys dir/id_new"
        try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "sftp only", "-f", newKey])
        let session = try await server.connectedSession()
        #expect(!session.capabilities.shell)
        // No ~/.ssh yet: a failed "get authorized_keys" counts as empty, and the folder is made (0700).
        try await session.installKey(newKey + ".pub")
        let key = try #require(read(newKey + ".pub"))
        #expect(read(server.path(".ssh/authorized_keys")) == key)
        let folder = try FileManager.default.attributesOfItem(atPath: server.path(".ssh"))
        let file = try FileManager.default.attributesOfItem(atPath: server.path(".ssh/authorized_keys"))
        #expect((folder[.posixPermissions] as? Int) == 0o700 && (file[.posixPermissions] as? Int) == 0o600)
        // A second key is appended (a missing final newline gets one first).
        try "ssh-ed25519 AAAAexisting".write(toFile: server.path(".ssh/authorized_keys"), atomically: true, encoding: .utf8)
        try await session.installKey(newKey + ".pub")
        #expect(read(server.path(".ssh/authorized_keys")) == "ssh-ed25519 AAAAexisting\n" + key)
        #expect(!(await server.logEntries()).contains { $0.command.contains("ssh-copy-id") })
        let withNewKey = try await server.connectedSession(server.host(key: newKey))
        #expect(withNewKey.state == .connected)
    }
}

@Test func sshDashGResolvesAliasesFromTheConfig() async throws {
    _ = TestEnvironment.isolated
    let text = try String(contentsOfFile: TestEnvironment.sshConfig)
    #expect(SSHConfig.aliases(in: text) == ["airscp-alias", "other-alias"])
    let resolved = try #require(await SSHConfig.resolve(SSHHost(hostname: "other-alias")))
    #expect(resolved.hostname == "127.0.0.1" && resolved.port == 2222 && resolved.user == "airscp-test")
    #expect(resolved.knownHostsFiles == [TestEnvironment.root + "/alias_known_hosts"])
    // A saved host's own options win over the config, as they do when AirSCP runs ssh.
    let overridden = try #require(await SSHConfig.resolve(SSHHost(hostname: "airscp-alias", port: 2200, username: "me")))
    #expect(overridden.port == 2200 && overridden.user == "me")
    let plain = try #require(await SSHConfig.resolve(SSHHost(hostname: "203.0.113.9")))
    #expect(plain.hostname == "203.0.113.9" && plain.port == 22)
}

@Test func savedPasswordAnswersOnlyTheFirstAttemptAndRememberWaitsForTheConnection() async throws {
    try await withServer { server in
        // The master asks for a key passphrase; meanwhile password prompts arrive through the same helper (as a
        // server asking for a password would). Each process gets the saved password once; a repeat means it was
        // wrong, so the user is asked, and "Remember" saves the new one only once the connection is up.
        let host = server.host(key: server.encryptedKey)
        let session = try server.session(host)
        let saved = Recorder<String>()
        let helperOutput = Recorder<String>()
        let shown = Recorder<Prompt>()
        session.savedPassword = { $0.id == host.id ? "saved-pw-7Q" : nil }
        session.savePassword = { owner, password in
            #expect(owner.id == host.id)
            #expect(session.state == .connected)
            saved.append(password)
        }
        let environment = session.askpass.environment(for: host.id.uuidString)
        session.onPrompt = { prompt, reply in
            shown.append(prompt)
            switch prompt.kind {
            case .passphrase:
                Task {
                    for _ in 0..<2 {
                        let (output, status) = await askpassHelper("sa@127.0.0.1's password: ", environment: environment)
                        helperOutput.append(status == 0 ? output : "failed")
                    }
                    #expect(saved.all.isEmpty)
                    reply(PromptAnswer(TestServer.passphrase))
                }
            case .password:
                #expect(prompt.canRemember && prompt.host?.id == host.id)
                reply(PromptAnswer("typed password", remember: true))
            default:
                reply(nil)
            }
        }
        try await session.connect()
        #expect(helperOutput.all == ["saved-pw-7Q\n", "typed password\n"])
        #expect(shown.all.map(\.kind) == [.passphrase, .password(user: "sa", host: "127.0.0.1")])
        #expect(saved.all == ["typed password"])

        // Prompts for an id without a handler, or a cancelled one, make the helper fail (ssh then gives up).
        #expect(await askpassHelper("Password:", environment: session.askpass.environment(for: "nobody")).status == 1)
        session.onPrompt = { _, reply in reply(nil) }
        #expect(await askpassHelper("Verification code:", environment: environment).status == 1)
        var unreachable = environment
        unreachable["AIRSCP_ASKPASS_SOCK"] = server.root + "/no-such-socket"
        #expect(await askpassHelper("Password:", environment: unreachable).status == 1)
    }
}

@Test func runningCommandsCanBeCancelled() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let cancellation = Cancellation()
        let started = Date()
        Task {
            try await Task.sleep(nanoseconds: 500_000_000)
            cancellation.cancel()
        }
        do {
            _ = try await session.run("sleep 30", cancellation: cancellation)
            Issue.record("the command wasn't cancelled")
        } catch let error as AirSCPError {
            #expect(error.kind == .cancelled)
        }
        #expect(Date().timeIntervalSince(started) < 25)  // stopped, not the sleep's 30 s (18 s on a very busy Mac)
        // The control lane is free again.
        #expect(try await session.run("echo after").output == "after\n")
    }
}

@Test func keysAreFoundByTheirPrivateKeyHeader() async throws {
    let folder = try scratch()
    // A pair; a private key without its .pub; an encrypted PEM key without one (unreadable without its passphrase).
    try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "pair key", "-f", folder + "/id_pair"])
    try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "a passphrase", "-C", "lonely", "-f", folder + "/id_lonely"])
    try FileManager.default.removeItem(atPath: folder + "/id_lonely.pub")
    try await run(["/usr/bin/ssh-keygen", "-q", "-t", "rsa", "-b", "2048", "-m", "PEM", "-N", "a passphrase", "-f",
                   folder + "/legacy.pem"])
    try FileManager.default.removeItem(atPath: folder + "/legacy.pem.pub")
    // Not keys: a ".pub" next to a file that isn't a private key, config, known_hosts, a folder.
    try write("not a key\n", to: folder + "/notes")
    try write("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINotAKey notes\n", to: folder + "/notes.pub")
    try write("Host *\n", to: folder + "/config")
    try write("[h]:22 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINotAKey\n", to: folder + "/known_hosts")
    try FileManager.default.createDirectory(atPath: folder + "/keys.d", withIntermediateDirectories: true)

    let log = Recorder<LogEntry>()
    let keys = await Keys.list(in: folder, log: { log.append($0) })
    #expect(keys.map { RemotePath.name($0.privateKey) } == ["id_lonely", "id_pair", "legacy.pem"])
    let pair = keys[1], lonely = keys[0], legacy = keys[2]
    #expect(pair.type == "ED25519" && pair.comment == "pair key" && pair.bits == 256 && pair.publicKey == pair.privateKey + ".pub")
    // Described from the private key itself: no comment in it without the passphrase, and no .pub.
    #expect(lonely.type == "ED25519" && lonely.comment == "" && lonely.fingerprint.hasPrefix("SHA256:"))
    #expect(!FileManager.default.fileExists(atPath: lonely.publicKey))
    #expect(legacy.type == "type unknown" && legacy.bits == 0 && legacy.fingerprint.isEmpty)
    // One ssh-keygen -l per key, in the log (which arrives on the main queue).
    await MainActor.run {}
    #expect(log.all.map(\.command).filter { $0.hasPrefix("/usr/bin/ssh-keygen -l -f ") }.count == 3)
}

@Test func aMissingKeyFileIsNoticed() async throws {
    try await withServer { server in
        let gone = server.root + "/keys dir/id_gone"
        // Connecting with it says so, not just "permission denied".
        let session = try server.session(server.host(key: gone))
        do {
            try await session.connect()
            Issue.record("connected without a key")
        } catch let error as AirSCPError {
            #expect(error.kind == .authFailed(methods: "publickey"))
            #expect(error.message == "The key file \(gone) doesn't exist (any more). Choose another key in the host's settings.")
        }
    }
}

/// A Keychain read that fails (the user chose Deny, or the keychain is locked) isn't taken for "no saved passwords":
/// nothing is cached, and a save doesn't write its one password over all the others.
/// (This test and the next replace the Keychain's stand-ins: on the main actor, without waiting, they never overlap.)
@MainActor @Test func anUnreadableKeychainIsNeverOverwritten() throws {
    _ = TestEnvironment.isolated
    let (read, write, memoryOnly) = (Keychain.readItem, Keychain.writeItem, Keychain.memoryOnly)
    defer {
        Keychain.readItem = read
        Keychain.writeItem = write
        Keychain.memoryOnly = memoryOnly
        Keychain.cache = nil
    }
    Keychain.memoryOnly = false
    var stored = try JSONEncoder().encode(["host": "secret", "proxy:1": "proxy secret"])
    var status = errSecAuthFailed
    var writes = 0
    Keychain.cache = nil
    Keychain.readItem = { service in service == Keychain.service ? (status, status == errSecSuccess ? stored : nil) : (errSecItemNotFound, nil) }
    Keychain.writeItem = { data in
        writes += 1
        stored = data
        return errSecSuccess
    }
    #expect(Keychain.password(forKey: "host") == nil)
    Keychain.setPassword("new", forKey: "other")
    #expect(writes == 0)
    // Allowed the next time: everything is still there, and a save keeps it.
    status = errSecSuccess
    #expect(Keychain.password(forKey: "host") == "secret")
    Keychain.setPassword("new", forKey: "other")
    #expect(writes == 1)
    #expect(try JSONDecoder().decode([String: String].self, from: stored) == ["host": "secret", "proxy:1": "proxy secret", "other": "new"])
    // No item yet: a save makes one with just that password.
    Keychain.cache = nil
    status = errSecItemNotFound
    Keychain.setPassword("first", forKey: "only")
    #expect(try JSONDecoder().decode([String: String].self, from: stored) == ["only": "first"])
    #expect(OpenSSH.addToAgent("/t/k") == ["/usr/bin/ssh-add", "--apple-use-keychain", "/t/k"])

    // A throwaway AirSCP (its own settings folder: tests, smoke runs, agents' instances) never reads or writes the
    // login Keychain: a password saved with "Remember" stays in memory, and ssh-add leaves the Keychain alone.
    #expect(Keychain.isThrowaway(["AIRSCP_SUPPORT_DIR": "/tmp/airscp-x"]) && !Keychain.isThrowaway([:])
            && !Keychain.isThrowaway(["AIRSCP_SUPPORT_DIR": ""]))
    var touched = 0
    Keychain.readItem = { _ in touched += 1; return (errSecSuccess, stored) }
    Keychain.writeItem = { _ in touched += 1; return errSecSuccess }
    Keychain.memoryOnly = true
    Keychain.cache = nil
    Keychain.setPassword("remembered", forKey: "host")
    #expect(Keychain.password(forKey: "host") == "remembered" && Keychain.password(forKey: "only") == nil && touched == 0)
    #expect(OpenSSH.addToAgent("/t/k") == ["/usr/bin/ssh-add", "/t/k"])
}

/// AirSCP was called Porter (PLAN.md X): until AirSCP has a Keychain item of its own, the passwords Porter saved (its
/// item, com.sa.porter) answer, and go into AirSCP's item at once. Porter's item is only read, never written or
/// removed.
@MainActor @Test func portersSavedPasswordsMoveIntoAirSCPsItem() throws {
    _ = TestEnvironment.isolated
    let (read, write, memoryOnly) = (Keychain.readItem, Keychain.writeItem, Keychain.memoryOnly)
    defer {
        Keychain.readItem = read
        Keychain.writeItem = write
        Keychain.memoryOnly = memoryOnly
        Keychain.cache = nil
    }
    Keychain.memoryOnly = false
    var items = [Keychain.porterService: try JSONEncoder().encode(["host": "porter secret", "proxy:1": "proxy secret"])]
    var porterStatus = errSecAuthFailed
    var reads: [String] = []
    Keychain.readItem = { service in
        reads.append(service)
        if service == Keychain.porterService, porterStatus != errSecSuccess { return (porterStatus, nil) }
        return items[service].map { (errSecSuccess, $0) } ?? (errSecItemNotFound, nil)
    }
    Keychain.writeItem = { data in
        items[Keychain.service] = data
        return errSecSuccess
    }
    func saved(_ service: String) throws -> [String: String]? {
        try items[service].map { try JSONDecoder().decode([String: String].self, from: $0) }
    }
    // Porter's item can't be read (the user chose Deny): no password, and a save makes no item that would hide it.
    Keychain.cache = nil
    #expect(Keychain.password(forKey: "host") == nil)
    Keychain.setPassword("new", forKey: "other")
    #expect(items[Keychain.service] == nil && reads == [Keychain.service, Keychain.porterService, Keychain.service, Keychain.porterService])
    // Allowed: Porter's passwords answer and are in AirSCP's item now; Porter's item is as it was.
    porterStatus = errSecSuccess
    #expect(Keychain.password(forKey: "host") == "porter secret")
    #expect(try saved(Keychain.service) == ["host": "porter secret", "proxy:1": "proxy secret"])
    #expect(try saved(Keychain.porterService) == ["host": "porter secret", "proxy:1": "proxy secret"])
    // From then on only AirSCP's item is read and written.
    Keychain.cache = nil
    reads = []
    Keychain.setPassword("airscp secret", forKey: "host")
    #expect(reads == [Keychain.service] && Keychain.password(forKey: "proxy:1") == "proxy secret")
    #expect(try saved(Keychain.service) == ["host": "airscp secret", "proxy:1": "proxy secret"])
    #expect(try saved(Keychain.porterService) == ["host": "porter secret", "proxy:1": "proxy secret"])
}

/// The askpass socket answers only requests that carry the server's token, which AirSCP puts in the environment of the
/// commands it starts. Another program of the same user can reach the socket (and read the host and proxy ids in
/// airscp.json), but gets neither a saved password nor a proxy's credentials from it.
@Test func askpassAnswersOnlyRequestsWithItsToken() async throws {
    _ = TestEnvironment.isolated
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    askpass.setHandler({ _, reply in reply("saved secret") }, for: "host")
    let proxy = Proxy(name: "p", host: "proxy.example", port: 3128, username: "me")
    askpass.proxyHandler = { _, _, _, reply in reply((proxy, "proxy secret")) }
    let environment = askpass.environment(for: "host")
    #expect(await askpassHelper("me@h's password: ", environment: environment) == ("saved secret\n", 0))
    var noToken = environment
    noToken["AIRSCP_ASKPASS_TOKEN"] = nil
    #expect(await askpassHelper("me@h's password: ", environment: noToken).status == 1)
    var wrongToken = environment
    wrongToken["AIRSCP_ASKPASS_TOKEN"] = String(repeating: "0", count: 64)
    #expect(await askpassHelper("me@h's password: ", environment: wrongToken).status == 1)
    // The same by hand, as any program could: nothing comes back.
    let request: [String: Any] = ["id": "host", "prompt": "Password:", "pid": 1]
    #expect(Askpass.exchange(request, socket: askpass.socketPath) == nil)
    let proxyRequest: [String: Any] = ["id": "host", "proxy": proxy.id.uuidString, "mayAsk": false]
    #expect(Askpass.exchange(proxyRequest, socket: askpass.socketPath) == nil)
    var withToken = proxyRequest
    withToken["token"] = environment["AIRSCP_ASKPASS_TOKEN"]
    #expect(Askpass.exchange(withToken, socket: askpass.socketPath)?["password"] as? String == "proxy secret")
}
