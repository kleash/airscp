import Foundation
import Testing
@testable import AirSCPCore

// PuTTY's .ppk files (PLAN.md K.2). The vectors are PuTTY's own (test/cryptsuite.py, testPPKLoadSave; PuTTY is MIT
// licensed): an Ed25519 key in formats 3 and 2, plain and encrypted with "test-passphrase". AirSCP reads them all, and
// writes format 3 again byte for byte (format 2 is only read: its key derivation is SHA-1).

private let comment = "ed25519-key-20200105"
private let passphrase = "test-passphrase"
private let publicBlob = Data(hex: "0000000b7373682d65643235353139000000207242b33387688f57ff218bb639"
                              + "f6d9fd213ba54f3100d5b5cb64ca6e85247d56")!
private let salt = Data(hex: "37c3911bfefc8c1d11ec579627d2b3d9")!

private let v3Plain = """
    PuTTY-User-Key-File-3: ssh-ed25519
    Encryption: none
    Comment: ed25519-key-20200105
    Public-Lines: 2
    AAAAC3NzaC1lZDI1NTE5AAAAIHJCszOHaI9X/yGLtjn22f0hO6VPMQDVtctkym6F
    JH1W
    Private-Lines: 1
    AAAAIGvvIpl8jyqn8Xufkw6v3FnEGtXF3KWw55AP3/AGEBpY
    Private-MAC: 816c84093fc4877e8411b8e5139c5ce35d8387a2630ff087214911d67417a54d

    """

private let v3Encrypted = """
    PuTTY-User-Key-File-3: ssh-ed25519
    Encryption: aes256-cbc
    Comment: ed25519-key-20200105
    Public-Lines: 2
    AAAAC3NzaC1lZDI1NTE5AAAAIHJCszOHaI9X/yGLtjn22f0hO6VPMQDVtctkym6F
    JH1W
    Key-Derivation: Argon2id
    Argon2-Memory: 8192
    Argon2-Passes: 13
    Argon2-Parallelism: 1
    Argon2-Salt: 37c3911bfefc8c1d11ec579627d2b3d9
    Private-Lines: 1
    amviz4sVUBN64jLO3gt4HGXJosUArghc4Soi7aVVLb2Tir5Baj0OQClorycuaPRd
    Private-MAC: 6f5e588e475e55434106ec2c3569695b03f423228b44993a9e97d52ffe7be5a8

    """

private let v2Plain = """
    PuTTY-User-Key-File-2: ssh-ed25519
    Encryption: none
    Comment: ed25519-key-20200105
    Public-Lines: 2
    AAAAC3NzaC1lZDI1NTE5AAAAIHJCszOHaI9X/yGLtjn22f0hO6VPMQDVtctkym6F
    JH1W
    Private-Lines: 1
    AAAAIGvvIpl8jyqn8Xufkw6v3FnEGtXF3KWw55AP3/AGEBpY
    Private-MAC: 2a629acfcfbe28488a1ba9b6948c36406bc28422

    """

private let v2Encrypted = """
    PuTTY-User-Key-File-2: ssh-ed25519
    Encryption: aes256-cbc
    Comment: ed25519-key-20200105
    Public-Lines: 2
    AAAAC3NzaC1lZDI1NTE5AAAAIHJCszOHaI9X/yGLtjn22f0hO6VPMQDVtctkym6F
    JH1W
    Private-Lines: 1
    4/jKlTgC652oa9HLVGrMjHZw7tj0sKRuZaJPOuLhGTvb25Jzpcqpbi+Uf+y+uo+Z
    Private-MAC: 5b1f6f4cc43eb0060d2c3e181bc0129343adba2b

    """

@Test func puttysOwnTestVectorsReadAndWriteBackByteForByte() throws {
    #expect(PuTTYKey.isEncrypted(v3Plain) == false && PuTTYKey.isEncrypted(v3Encrypted) == true)
    #expect(PuTTYKey.isEncrypted(v2Encrypted) == true && PuTTYKey.isEncrypted("not a key file") == nil)
    let plain = try PuTTYKey.read(v3Plain, passphrase: "")
    #expect(plain.algorithm == "ssh-ed25519" && plain.comment == comment && plain.publicBlob == publicBlob)
    for (text, phrase) in [(v3Encrypted, passphrase), (v2Plain, ""), (v2Encrypted, passphrase)] {
        let key = try PuTTYKey.read(text, passphrase: phrase)
        #expect(key == plain, "\(text.prefix(30))")
    }
    // Windows line ends read the same.
    #expect(try PuTTYKey.read(v3Encrypted.replacingOccurrences(of: "\n", with: "\r\n"), passphrase: passphrase) == plain)

    #expect(try PuTTYKey.write(plain, passphrase: "") == v3Plain)
    #expect(try PuTTYKey.write(plain, passphrase: passphrase, salt: salt, passes: 13) == v3Encrypted)
}

// MARK: Every key type, through OpenSSH's format

/// Keys made by ssh-keygen (unencrypted, in a scratch folder), for the round trips.
private func sshKeygenKeys(in folder: String) async throws -> [(name: String, path: String)] {
    var keys: [(String, String)] = []
    for (type, bits) in [("ed25519", nil), ("ecdsa", 256), ("ecdsa", 384), ("ecdsa", 521), ("rsa", 2048)] as [(String, Int?)] {
        let name = type + (bits.map { "\($0)" } ?? "")
        let path = folder + "/" + name
        try await run(["/usr/bin/ssh-keygen", "-q", "-t", type] + (bits.map { ["-b", String($0)] } ?? [])
                      + ["-N", "", "-C", "\(name) key", "-f", path])
        keys.append((name, path))
    }
    return keys
}

/// The type and base64 of a public key line, without its comment.
private func publicPart(_ line: String) -> String {
    line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").prefix(2).joined(separator: " ")
}

@Test func everyKeyTypeRoundTripsThroughAPuTTYKey() async throws {
    let folder = try scratch()
    for (name, path) in try await sshKeygenKeys(in: folder) {
        let key = try PuTTYKey.fromOpenSSH(try #require(read(path)))
        #expect(key.comment == "\(name) key")
        #expect(PuTTYKey.publicLine(key) == (try #require(read(path + ".pub"))).trimmingCharacters(in: .whitespacesAndNewlines))
        for phrase in ["", "round trip"] {
            let ppk = try PuTTYKey.write(key, passphrase: phrase, passes: phrase.isEmpty ? nil : 2)
            #expect(ppk.hasPrefix("PuTTY-User-Key-File-3: \(key.algorithm)\nEncryption: \(phrase.isEmpty ? "none" : "aes256-cbc")"))
            #expect(PuTTYKey.isEncrypted(ppk) == !phrase.isEmpty)
            let back = try PuTTYKey.read(ppk, passphrase: phrase)
            #expect(back == key, "\(name)")
            // Back in OpenSSH's format, ssh-keygen derives the same public key from it.
            let file = folder + "/\(name)-\(phrase.isEmpty ? "plain" : "encrypted")"
            try AirSCPCore.Keys.create(file, Data(try PuTTYKey.openSSH(back).utf8), mode: 0o600)
            let derived = try await run(["/usr/bin/ssh-keygen", "-y", "-P", "", "-f", file]).output
            #expect(publicPart(derived) == publicPart(try #require(read(path + ".pub"))), "\(name)")
        }
    }
    // Keys PuTTY can't take are refused with why.
    try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "secret", "-f", folder + "/encrypted"])
    #expect(throws: AirSCPError.self) { try PuTTYKey.fromOpenSSH(read(folder + "/encrypted") ?? "") }
    #expect(throws: AirSCPError.self) { try PuTTYKey.fromOpenSSH("not a key") }
}

@Test func aWrongPassphraseOrADamagedFileIsRefused() throws {
    // Wrong passphrase: told as such (both versions).
    for text in [v3Encrypted, v2Encrypted] {
        do {
            _ = try PuTTYKey.read(text, passphrase: "wrong")
            Issue.record("read with a wrong passphrase")
        } catch let error as AirSCPError {
            #expect(error.kind == .authFailed(methods: "") && error.message.contains("passphrase isn't right"))
        }
    }
    // A changed byte: the MAC doesn't match, so the key isn't used.
    let tampered = v3Plain.replacingOccurrences(of: "AAAAIGvvIpl8", with: "AAAAIGvvIpl9")
    do {
        _ = try PuTTYKey.read(tampered, passphrase: "")
        Issue.record("read a key whose MAC doesn't match")
    } catch let error as AirSCPError {
        #expect(error.message.contains("MAC") && error.kind != .authFailed(methods: ""), "\(error.message)")
    }
    let changedComment = v2Plain.replacingOccurrences(of: "Comment: ed25519-key-20200105", with: "Comment: someone else")
    #expect(throws: AirSCPError.self) { try PuTTYKey.read(changedComment, passphrase: "") }
    // Not a PuTTY key; the oldest and a newer format; an algorithm AirSCP doesn't convert.
    for (text, words) in [("hello", "isn't a PuTTY"), ("PuTTY-User-Key-File-1: ssh-rsa\n", "oldest format"),
                          ("PuTTY-User-Key-File-4: ssh-rsa\n", "newer PuTTY"),
                          ("PuTTY-User-Key-File-3: ssh-dss\nEncryption: none\n", "DSA")] {
        do {
            _ = try PuTTYKey.read(text, passphrase: "")
            Issue.record("read \(text.prefix(30))")
        } catch let error as AirSCPError {
            #expect(error.message.contains(words), "\(error.message)")
        }
    }
    // Key derivation settings out of reason are refused before running them.
    let greedy = v3Encrypted.replacingOccurrences(of: "Argon2-Memory: 8192", with: "Argon2-Memory: 4194304")
    do {
        _ = try PuTTYKey.read(greedy, passphrase: passphrase)
        Issue.record("ran Argon2 over 4 GB")
    } catch let error as AirSCPError {
        #expect(error.message.contains("won't run"), "\(error.message)")
    }
}

// MARK: Import and export, as the Keys window runs them

/// The private temporary folders that the ssh-keygen commands in `log` worked in (other tests make theirs meanwhile).
private func keyFolders(in log: [LogEntry]) -> [String] {
    log.compactMap { entry -> String? in
        guard let range = entry.command.range(of: #"/\S*/airscp-key-[0-9A-F-]+"#, options: .regularExpression) else { return nil }
        return String(entry.command[range])
    }
}

@Test func importingAPuTTYKeyWritesAnOpenSSHKeyWithTheChosenPassphrase() async throws {
    let folder = try scratch()
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let asked = Recorder<String>(), log = Recorder<LogEntry>()
    let newPassphrase = "the new one \(UUID().uuidString.prefix(4))"
    askpass.setHandler({ request, reply in
        asked.append(request.prompt)
        reply(newPassphrase)
    }, for: "import")
    try await Keys.importPPK(v3Encrypted, passphrase: passphrase, to: folder + "/id_putty", newPassphrase: newPassphrase,
                             askpass: askpass.environment(for: "import"), log: { log.append($0) })
    #expect(asked.all.count == 2)  // ssh-keygen -p: the new passphrase, and again
    let pub = try #require(read(folder + "/id_putty.pub"))
    #expect(pub == PuTTYKey.publicLine(try PuTTYKey.read(v3Plain, passphrase: "")) + "\n")
    let derived = try await run(["/usr/bin/ssh-keygen", "-y", "-P", newPassphrase, "-f", folder + "/id_putty"]).output
    #expect(publicPart(derived) == publicPart(pub))
    #expect(await Runner.run(["/usr/bin/ssh-keygen", "-y", "-P", "", "-f", folder + "/id_putty"]).status != 0)
    var info = stat()
    #expect(lstat(folder + "/id_putty", &info) == 0 && info.st_mode & 0o777 == 0o600)
    #expect(lstat(folder + "/id_putty.pub", &info) == 0 && info.st_mode & 0o777 == 0o644)
    // No secret in a command line or the log; the unencrypted copy's folder is gone.
    await MainActor.run {}  // log entries arrive on the main queue
    #expect(log.all.contains { $0.command.contains("ssh-keygen -p") })
    for secret in [passphrase, newPassphrase] {
        #expect(!log.all.contains { $0.command.contains(secret) || $0.stderr.contains(secret) })
    }
    let used = keyFolders(in: log.all)
    #expect(used.count == 1 && used.allSatisfy { !rawExists($0) }, "\(used)")

    // Never over a key that is there; no passphrase: an unencrypted key, without asking.
    await #expect(throws: AirSCPError.self) {
        try await Keys.importPPK(v2Plain, passphrase: "", to: folder + "/id_putty", newPassphrase: "", askpass: [:])
    }
    try await Keys.importPPK(v2Plain, passphrase: "", to: folder + "/id_plain", newPassphrase: "", askpass: [:])
    #expect(asked.all.count == 2)
    try await run(["/usr/bin/ssh-keygen", "-y", "-P", "", "-f", folder + "/id_plain"])
    // A wrong passphrase leaves nothing behind.
    await #expect(throws: AirSCPError.self) {
        try await Keys.importPPK(v3Encrypted, passphrase: "wrong", to: folder + "/id_wrong", newPassphrase: "", askpass: [:])
    }
    #expect(!rawExists(folder + "/id_wrong"))
}

@Test func exportingAKeyWritesAPuTTYKeyFromADecryptedCopy() async throws {
    let folder = try scratch()
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let asked = Recorder<String>(), log = Recorder<LogEntry>()
    askpass.setHandler({ request, reply in
        asked.append(request.prompt)
        reply("key passphrase")
    }, for: "export")
    try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ecdsa", "-b", "384", "-m", "PEM", "-N", "key passphrase", "-C", "to putty",
                   "-f", folder + "/id_ecdsa"])
    let original = try #require(read(folder + "/id_ecdsa"))
    let ppk = folder + "/id_ecdsa.ppk"
    try await Keys.exportPPK(folder + "/id_ecdsa", to: ppk, passphrase: "ppk passphrase",
                             askpass: askpass.environment(for: "export"), log: { log.append($0) })
    let text = try #require(read(ppk))
    #expect(text.hasPrefix("PuTTY-User-Key-File-3: ecdsa-sha2-nistp384\nEncryption: aes256-cbc\nComment: to putty"))
    let key = try PuTTYKey.read(text, passphrase: "ppk passphrase")
    #expect(publicPart(PuTTYKey.publicLine(key)) == publicPart(try #require(read(folder + "/id_ecdsa.pub"))))
    var info = stat()
    #expect(lstat(ppk, &info) == 0 && info.st_mode & 0o777 == 0o600)
    #expect(asked.all.count == 1 && asked.all.allSatisfy { $0.lowercased().contains("passphrase") })  // the key's own
    #expect(read(folder + "/id_ecdsa") == original)  // the key itself is untouched
    await MainActor.run {}  // log entries arrive on the main queue
    #expect(log.all.filter { $0.command.contains("ssh-keygen -p -N '' -f ") }.count == 1)
    for secret in ["key passphrase", "ppk passphrase"] {
        #expect(!log.all.contains { $0.command.contains(secret) || $0.stderr.contains(secret) })
    }
    // A wrong passphrase for the key is told as such (ssh-keygen's words, naming the copy, under Details).
    askpass.setHandler({ _, reply in reply("wrong") }, for: "export")
    do {
        try await Keys.exportPPK(folder + "/id_ecdsa", to: folder + "/wrong.ppk", passphrase: "", askpass: askpass.environment(for: "export"))
        Issue.record("exported with a wrong passphrase")
    } catch let error as AirSCPError {
        #expect(error.kind == .authFailed(methods: "") && error.message == "The key's passphrase isn't right.", "\(error)")
    }
    // A cancelled passphrase question leaves no copy behind either.
    askpass.setHandler({ _, reply in reply(nil) }, for: "export")
    await #expect(throws: AirSCPError.self) {
        try await Keys.exportPPK(folder + "/id_ecdsa", to: folder + "/cancelled.ppk", passphrase: "",
                                 askpass: askpass.environment(for: "export"), log: { log.append($0) })
    }
    #expect(!rawExists(folder + "/cancelled.ppk"))
    // Every decrypted copy's folder is gone (the export's and the cancelled one's).
    await MainActor.run {}
    let used = keyFolders(in: log.all)
    #expect(used.count == 2 && used.allSatisfy { !rawExists($0) }, "\(used)")
}

// MARK: Against PuTTY's own puttygen (AIRSCP_PUTTY=1)

/// puttygen built from the official PuTTY source (testenv/putty/build-puttygen.sh, test-only), or nil (skipped).
private let puttygen: String? = {
    guard Env.value("PUTTY") == "1" else { return nil }
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let script = Process()
    script.executableURL = repo.appendingPathComponent("testenv/putty/build-puttygen.sh")
    try? script.run()
    script.waitUntilExit()
    let binary = repo.appendingPathComponent("vendor/puttygen/puttygen").path
    return script.terminationStatus == 0 && FileManager.default.isExecutableFile(atPath: binary) ? binary : nil
}()

@Test(.enabled(if: Env.value("PUTTY") == "1", "PuTTY interop: AIRSCP_PUTTY=1"))
func puttygenAndAirSCPReadEachOthersKeys() async throws {
    let puttygen = try #require(puttygen, "testenv/putty/build-puttygen.sh couldn't build puttygen")
    let folder = try scratch()
    try write("interop phrase", to: folder + "/phrase")
    try write("", to: folder + "/empty")
    for (type, bits) in [("ed25519", nil), ("ecdsa", 256), ("ecdsa", 384), ("ecdsa", 521), ("rsa", 2048)] as [(String, Int?)] {
        for version in [2, 3] {
            for encrypted in [false, true] {
                let name = "\(type)\(bits.map { "\($0)" } ?? "")-v\(version)-\(encrypted ? "encrypted" : "plain")"
                let phrase = encrypted ? "interop phrase" : ""
                // puttygen's key, read by AirSCP: the same public key as puttygen says, and a private key ssh-keygen takes.
                let theirs = folder + "/\(name).ppk"
                try await run([puttygen, "-q", "-t", type] + (bits.map { ["-b", String($0)] } ?? [])
                              + ["-C", name, "-o", theirs, "--new-passphrase", folder + (encrypted ? "/phrase" : "/empty"),
                                 "--ppk-param", "version=\(version)"])
                let their = try PuTTYKey.read(try #require(read(theirs)), passphrase: phrase)
                let expected = try await run([puttygen, theirs, "-L", "--old-passphrase", folder + (encrypted ? "/phrase" : "/empty")]).output
                #expect(publicPart(PuTTYKey.publicLine(their)) == publicPart(expected), "\(name)")
                try AirSCPCore.Keys.create(folder + "/\(name).openssh", Data(try PuTTYKey.openSSH(their).utf8), mode: 0o600)
                let derived = try await run(["/usr/bin/ssh-keygen", "-y", "-P", "", "-f", folder + "/\(name).openssh"]).output
                #expect(publicPart(derived) == publicPart(expected), "\(name)")

                // AirSCP's key, read by puttygen: the public key, and the private key as puttygen exports it to OpenSSH.
                let ours = folder + "/\(name).ours.ppk"
                try write(try PuTTYKey.write(their, passphrase: phrase), to: ours)
                let shown = try await run([puttygen, ours, "-L", "--old-passphrase", folder + (encrypted ? "/phrase" : "/empty")]).output
                #expect(publicPart(shown) == publicPart(expected), "\(name)")
                try await run([puttygen, ours, "-O", "private-openssh-new", "-o", folder + "/\(name).back",
                               "--old-passphrase", folder + (encrypted ? "/phrase" : "/empty"), "--new-passphrase", folder + "/empty"])
                let back = try await run(["/usr/bin/ssh-keygen", "-y", "-P", "", "-f", folder + "/\(name).back"]).output
                #expect(publicPart(back) == publicPart(expected), "\(name)")
                // A wrong passphrase: puttygen won't decrypt AirSCP's file, as it won't its own (the public key needs none).
                if encrypted {
                    let wrong = await Runner.run([puttygen, ours, "-O", "private-openssh-new", "-o", folder + "/\(name).wrong",
                                                  "--old-passphrase", folder + "/empty", "--new-passphrase", folder + "/empty"])
                    #expect(wrong.status != 0 && !rawExists(folder + "/\(name).wrong"), "\(name)")
                }
            }
        }
    }
}
