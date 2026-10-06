import Foundation
import Testing
@testable import AirSCPCore

// PLAN.md K.1: New Key Pair's types, sizes and formats, made by ssh-keygen in a scratch folder (never ~/.ssh), and
// the public key in each format Copy Public Key offers.

/// An askpass server whose "kinds" commands get `answer` for every question; what they asked is recorded.
private func answering(_ answer: String) throws -> (AskpassServer, Recorder<String>) {
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    let asked = Recorder<String>()
    askpass.setHandler({ request, reply in
        asked.append(request.prompt)
        reply(answer)
    }, for: "kinds")
    return (askpass, asked)
}

private func header(_ path: String) -> String {
    (read(path) ?? "").components(separatedBy: "\n").first ?? ""
}

/// The type and base64 of a public key line ("ssh-ed25519 AAAA… comment" without the comment).
private func publicKey(_ line: String) -> String {
    line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ").prefix(2).joined(separator: " ")
}

@Test func everyKeyTypeSizeAndFormatRoundTrips() async throws {
    let folder = try scratch()
    let (askpass, _) = try answering("")
    defer { askpass.close() }
    #expect(Keys.Kind.all.map(\.title).prefix(7) == ["Ed25519 (recommended)", "ECDSA 256", "ECDSA 384", "ECDSA 521",
                                                      "RSA 2048", "RSA 3072", "RSA 4096"])
    #expect(!Keys.Kind.all.contains { $0.type.contains("dsa") && !$0.type.contains("ecdsa") })  // no DSA
    for kind in Keys.Kind.all where !kind.onSecurityKey {
        for format in kind.openSSHOnly ? [.openSSH] : Keys.PrivateFormat.allCases {
            let path = folder + "/\(kind.id)-\(format.rawValue)"
            try await Keys.generate(kind, format: format, path: path, comment: "round trip", askpass: askpass.environment(for: "kinds"))
            let expected = switch (format, kind.type) {
            case (.openSSH, _): "-----BEGIN OPENSSH PRIVATE KEY-----"
            case (.pem, "rsa"): "-----BEGIN RSA PRIVATE KEY-----"
            case (.pem, _): "-----BEGIN EC PRIVATE KEY-----"
            case (.pkcs8, _): "-----BEGIN PRIVATE KEY-----"
            }
            #expect(header(path) == expected, "\(kind.id) \(format)")
            // ssh-keygen -l: the type and size asked for.
            let described = await Keys.describe(path)
            #expect(described.type == kind.type.uppercased() && described.bits == (kind.bits ?? 256), "\(described)")
            #expect(described.comment == "round trip")
            // ssh-keygen -y: the private key gives the public key next to it.
            let derived = try await run(["/usr/bin/ssh-keygen", "-y", "-P", "", "-f", path]).output
            #expect(publicKey(derived) == publicKey(try #require(read(path + ".pub"))), "\(kind.id) \(format)")
        }
    }
    // Security keys only when ssh-keygen can make them (macOS's own can't, without a FIDO provider).
    #expect(Keys.Kind.available.contains { $0.onSecurityKey } == Keys.securityKeysSupported)
}

@Test func everyPublicKeyFormatConvertsBack() async throws {
    let folder = try scratch()
    let (askpass, _) = try answering("")
    defer { askpass.close() }
    for kind in [Keys.Kind.ed25519] + Keys.Kind.all.filter({ $0.bits == 256 || $0.bits == 2048 }) {
        let path = folder + "/" + kind.fileName
        try await Keys.generate(kind, path: path, comment: "formats", askpass: askpass.environment(for: "kinds"))
        let original = publicKey(try #require(read(path + ".pub")))
        let type = await Keys.describe(path).type
        let formats = Keys.PublicFormat.formats(forType: type)
        #expect(formats == (kind.type == "ed25519" ? [.openSSH, .rfc4716] : Keys.PublicFormat.allCases))
        for format in formats {
            let text = try await Keys.publicKey(of: path, format: format)
            switch format {
            case .openSSH: #expect(publicKey(text) == original)
            case .rfc4716: #expect(text.hasPrefix("---- BEGIN SSH2 PUBLIC KEY ----"))
            case .pkcs8: #expect(text.hasPrefix("-----BEGIN PUBLIC KEY-----"))
            }
            guard format != .openSSH else { continue }
            // ssh-keygen -i reads it back as the same key.
            let file = folder + "/converted.\(format.rawValue)"
            try write(text + "\n", to: file)
            let back = try await run(["/usr/bin/ssh-keygen", "-i", "-m", format == .rfc4716 ? "RFC4716" : "PKCS8", "-f", file]).output
            #expect(publicKey(back) == original, "\(kind.id) \(format)")
        }
        if kind.type == "ed25519" {
            await #expect(throws: AirSCPError.self) { _ = try await Keys.publicKey(of: path, format: .pkcs8) }
        }
    }
}

/// The passphrase goes to ssh-keygen through askpass only: never into a command line or the log.
@Test func aNewKeysPassphraseNeverReachesTheCommandLine() async throws {
    let folder = try scratch()
    let secret = "a passphrase \(UUID().uuidString.prefix(6))"
    let (askpass, asked) = try answering(secret)
    defer { askpass.close() }
    let log = Recorder<LogEntry>()
    let kind = try #require(Keys.Kind.all.first { $0.type == "rsa" && $0.bits == 3072 })
    try await Keys.generate(kind, format: .pkcs8, path: folder + "/id_secret", comment: "secret", askpass: askpass.environment(for: "kinds"),
                            log: { log.append($0) })
    #expect(asked.all.count == 2)  // the passphrase, and again
    await MainActor.run {}  // log entries arrive on the main queue
    #expect(!log.all.isEmpty && !log.all.contains { $0.command.contains(secret) || $0.stderr.contains(secret) })
    #expect(header(folder + "/id_secret") == "-----BEGIN ENCRYPTED PRIVATE KEY-----")
    try await run(["/usr/bin/ssh-keygen", "-y", "-P", secret, "-f", folder + "/id_secret"])
    #expect(await Runner.run(["/usr/bin/ssh-keygen", "-y", "-P", "", "-f", folder + "/id_secret"]).status != 0)
    // Never over a key that is there.
    await #expect(throws: AirSCPError.self) {
        try await Keys.generate(.ed25519, path: folder + "/id_secret", comment: "again", askpass: askpass.environment(for: "kinds"))
    }
}
