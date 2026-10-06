import Darwin
import Foundation

/// SSH key pairs (the Keys window). Passphrases are asked through askpass: pass the environment from
/// `AskpassServer.environment(for:)`; nothing secret goes into a command line.
public enum Keys {
    public struct KeyPair: Identifiable, Equatable {
        public var id: String { privateKey }
        public let privateKey: String
        /// privateKey + ".pub". It may not exist: a private key found by its header alone has no public key file.
        public let publicKey: String
        /// From `ssh-keygen -l`: e.g. 256, "SHA256:…", "me@mac", "ED25519" ("type unknown" when it can't tell).
        public let bits: Int
        public let fingerprint: String
        public let comment: String
        public let type: String
    }

    /// The private keys in `folder` (~/.ssh): files whose first line is a private-key header (OpenSSH or PEM), each
    /// described by `ssh-keygen -l` (of its ".pub" when there is one). Never asks for a passphrase; a key ssh-keygen
    /// can't read without one (an encrypted PEM key with no .pub) is listed as "type unknown". Sorted by name.
    public static func list(in folder: String = NSHomeDirectory() + "/.ssh", log: ((LogEntry) -> Void)? = nil) async -> [KeyPair] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
        var pairs: [KeyPair] = []
        for name in names.sorted() where !name.hasSuffix(".pub") && isPrivateKey(folder + "/" + name) {
            pairs.append(await describe(folder + "/" + name, log: log))
        }
        return pairs
    }

    /// One private key (anywhere, e.g. chosen with "Other Key File…"), described as `list` describes them.
    public static func describe(_ privateKey: String, log: ((LogEntry) -> Void)? = nil) async -> KeyPair {
        let publicKey = privateKey + ".pub"
        let described = FileManager.default.fileExists(atPath: publicKey) ? publicKey : privateKey
        let result = await Runner.run(OpenSSH.fingerprint(described), environment: ["SSH_ASKPASS_REQUIRE": "never"], log: log)
        let parsed = result.status == 0 ? parseFingerprint(result.output) : nil
        return KeyPair(privateKey: privateKey, publicKey: publicKey, bits: parsed?.bits ?? 0, fingerprint: parsed?.fingerprint ?? "",
                       comment: parsed?.comment ?? "", type: parsed?.type ?? "type unknown")
    }

    /// A regular file starting with "-----BEGIN … PRIVATE KEY-----" (OpenSSH, RSA, EC, DSA, PKCS#8, encrypted PKCS#8).
    static func isPrivateKey(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var info = stat()
        var head = [UInt8](repeating: 0, count: 64)
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return false }
        let count = read(fd, &head, head.count)
        guard count > 0 else { return false }
        let line = String(decoding: head[0..<count].prefix { $0 != 10 && $0 != 13 }, as: UTF8.self)
        return line.hasPrefix("-----BEGIN ") && line.hasSuffix("PRIVATE KEY-----")
    }

    /// "256 SHA256:abc… me@mac (ED25519)" → its parts.
    public static func parseFingerprint(_ line: String) -> (bits: Int, fingerprint: String, comment: String, type: String)? {
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = text.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2, let bits = Int(parts[0]), text.hasSuffix(")"), let open = text.lastIndex(of: "(") else { return nil }
        let type = String(text[text.index(after: open)..<text.index(before: text.endIndex)])
        var comment = parts.count == 3 ? parts[2] : ""
        if let typeStart = comment.range(of: " (" + type + ")", options: .backwards) {
            comment = String(comment[..<typeStart.lowerBound])
        } else if comment == "(\(type))" {
            comment = ""
        }
        return (bits, parts[1], comment == "no comment" ? "" : comment, type)  // ssh-keygen's words for none
    }

    // MARK: New key pairs (PLAN.md K.1)

    /// A type and size in New Key Pair's menu.
    public struct Kind: Hashable, Identifiable {
        /// ssh-keygen's -t.
        public let type: String
        /// ssh-keygen's -b; nil: the type's one size.
        public let bits: Int?
        public let title: String
        /// When you'd choose it, in one line.
        public let explanation: String

        public var id: String { type + (bits.map { "-\($0)" } ?? "") }
        /// ssh-keygen's usual file name for it: id_ed25519, id_ecdsa, id_rsa, id_ed25519_sk, id_ecdsa_sk.
        public var fileName: String { "id_" + type.replacingOccurrences(of: "-", with: "_") }
        /// Kept on a hardware security key (FIDO): ssh-keygen needs one to make it.
        public var onSecurityKey: Bool { type.hasSuffix("-sk") }
        /// Its private key comes in OpenSSH's format only (ssh-keygen writes Ed25519 and security keys no other way).
        public var openSSHOnly: Bool { type.hasPrefix("ed25519") || onSecurityKey }

        public static let ed25519 = Kind(type: "ed25519", bits: nil, title: "Ed25519 (recommended)",
                                         explanation: "Modern, short and fast; every current server takes it.")
        public static let all: [Kind] = {
            var kinds = [ed25519]
            for bits in [256, 384, 521] {
                let size = bits == 256 ? " is plenty." : " is stronger, a little slower."
                kinds.append(Kind(type: "ecdsa", bits: bits, title: "ECDSA \(bits)",
                                  explanation: "Elliptic curve, for servers or rules that ask for ECDSA. \(bits) bits" + size))
            }
            for bits in [2048, 3072, 4096] {
                let size = bits == 2048 ? "; the smallest still accepted (3072 or more recommended)." : "."
                kinds.append(Kind(type: "rsa", bits: bits, title: "RSA \(bits)",
                                  explanation: "For old servers and appliances that don't take Ed25519" + size))
            }
            kinds.append(Kind(type: "ed25519-sk", bits: nil, title: "Ed25519-SK (security key)",
                              explanation: "The private key stays on a hardware security key such as a YubiKey: touch it "
                                + "to log in."))
            kinds.append(Kind(type: "ecdsa-sk", bits: nil, title: "ECDSA-SK (security key)",
                              explanation: "As Ed25519-SK, for security keys that only do ECDSA."))
            return kinds
        }()

        /// The kinds this Mac's ssh-keygen can make: security keys only when it can use one.
        public static var available: [Kind] { all.filter { !$0.onSecurityKey || securityKeysSupported } }
    }

    /// Whether ssh-keygen can make keys on a hardware security key. macOS's own OpenSSH has no FIDO support built in,
    /// so then only with a FIDO provider library named by $SSH_SK_PROVIDER.
    public static let securityKeysSupported: Bool = {
        if let provider = ProcessInfo.processInfo.environment["SSH_SK_PROVIDER"], !provider.isEmpty { return true }
        guard let helper = FileManager.default.contents(atPath: "/usr/libexec/ssh-sk-helper") else { return false }
        return helper.range(of: Data("internal security key support not enabled".utf8)) == nil
    }()

    /// How a private key is written (ssh-keygen -m).
    public enum PrivateFormat: String, CaseIterable {
        case openSSH, pem, pkcs8

        var option: String? { self == .openSSH ? nil : self == .pem ? "PEM" : "PKCS8" }
    }

    /// How a public key is shown for copying (ssh-keygen -e -m): OpenSSH's one line, SSH2 (RFC 4716), or PEM (PKCS#8).
    public enum PublicFormat: String, CaseIterable {
        case openSSH, rfc4716, pkcs8

        /// The formats a key of `type` (as `KeyPair.type` says it) comes in: no PEM for Ed25519 and security keys.
        public static func formats(forType type: String) -> [PublicFormat] {
            ["RSA", "ECDSA", "DSA"].contains(type) ? allCases : [.openSSH, .rfc4716]
        }
    }

    /// Creates a key pair at `path` (+ ".pub"). Refuses to overwrite. ssh-keygen asks for the passphrase (empty
    /// for none) and its confirmation through askpass (and a security key's PIN, if it has one).
    public static func generate(_ kind: Kind = .ed25519, format: PrivateFormat = .openSSH, path: String, comment: String,
                                askpass environment: [String: String], log: ((LogEntry) -> Void)? = nil) async throws {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: path), !fileManager.fileExists(atPath: path + ".pub") else {
            throw AirSCPError(.other, "A key named \(RemotePath.name(path)) already exists.")
        }
        let argv = OpenSSH.generateKey(kind, format: kind.openSSHOnly ? .openSSH : format, path: path, comment: comment)
        let result = await Runner.run(argv, environment: environment, log: log)
        guard result.status == 0 else {
            let error = ErrorMapping.map(result.stderr, status: result.status)
            guard kind.onSecurityKey else { throw error }
            throw AirSCPError(.other, "The security key didn't make a key. Plug it in, touch it when it blinks, and try "
                              + "again.", details: error.details)
        }
    }

    /// The public key of `privateKey` in `format`: its .pub file's line, or ssh-keygen's conversion of it.
    public static func publicKey(of privateKey: String, format: PublicFormat, log: ((LogEntry) -> Void)? = nil) async throws -> String {
        let publicKey = privateKey + ".pub"
        guard format != .openSSH else {
            guard let text = try? String(contentsOfFile: publicKey, encoding: .utf8) else {
                throw AirSCPError(.noSuchFile, "Can't read \((publicKey as NSString).abbreviatingWithTildeInPath).")
            }
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let result = await Runner.run(OpenSSH.exportPublicKey(publicKey, format: format == .rfc4716 ? "RFC4716" : "PKCS8"),
                                      environment: ["SSH_ASKPASS_REQUIRE": "never"], log: log)
        guard result.status == 0 else { throw ErrorMapping.map(result.stderr, status: result.status) }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: PuTTY keys (PLAN.md K.2)

    /// Imports a PuTTY key (.ppk text) as an OpenSSH key pair at `path` and `path`.pub, never over an existing file.
    /// The .ppk's MAC is checked with `passphrase` (wrong: `.authFailed`). The key is written unencrypted only in a
    /// private temporary folder, where ssh-keygen gives it `newPassphrase` (asked through askpass: answer it with that
    /// passphrase) unless that is empty; the folder is wiped afterwards.
    public static func importPPK(_ text: String, passphrase: String, to path: String, newPassphrase: String,
                                 askpass environment: [String: String], log: ((LogEntry) -> Void)? = nil) async throws {
        let key = try PuTTYKey.read(text, passphrase: passphrase)
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: path), !fileManager.fileExists(atPath: path + ".pub") else {
            throw AirSCPError(.other, "A key named \(RemotePath.name(path)) already exists.")
        }
        try await withPrivateFolder { folder in
            let temporary = folder + "/key"
            try create(temporary, Data(try PuTTYKey.openSSH(key).utf8), mode: 0o600)
            if !newPassphrase.isEmpty {
                let result = await Runner.run(OpenSSH.changePassphrase(temporary, removing: false), environment: environment,
                                              log: log)
                guard result.status == 0 else { throw keygenError(result) }
            }
            try create(path, try Data(contentsOf: URL(fileURLWithPath: temporary)), mode: 0o600)
            do {
                try create(path + ".pub", Data((PuTTYKey.publicLine(key) + "\n").utf8), mode: 0o644)
            } catch {
                unlink(path)
                throw error
            }
        }
    }

    /// Exports an OpenSSH private key (in any format ssh-keygen reads) as a PuTTY key file at `destination` (version 3,
    /// for PuTTY 0.75 and later), encrypted with `passphrase` unless it is empty. ssh-keygen decrypts a copy of the
    /// key in a private temporary folder (asking its passphrase through askpass); the folder is wiped afterwards.
    public static func exportPPK(_ privateKey: String, to destination: String, passphrase: String,
                                 askpass environment: [String: String], log: ((LogEntry) -> Void)? = nil) async throws {
        try await withPrivateFolder { folder in
            let temporary = folder + "/key"
            guard let source = FileManager.default.contents(atPath: privateKey) else {
                throw AirSCPError(.noSuchFile, "Can't read \((privateKey as NSString).abbreviatingWithTildeInPath).")
            }
            try create(temporary, source, mode: 0o600)
            let result = await Runner.run(OpenSSH.changePassphrase(temporary, removing: true), environment: environment, log: log)
            guard result.status == 0 else { throw keygenError(result) }
            var key = try PuTTYKey.fromOpenSSH(try String(contentsOfFile: temporary, encoding: .utf8))
            // The comment as the .pub file has it: a PEM key keeps none, and ssh-keygen then names the copy's path.
            let line = (try? String(contentsOfFile: privateKey + ".pub", encoding: .utf8)) ?? ""
            let words = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2)
            if words.count == 3 {
                key.comment = String(words[2])
            } else if key.comment.isEmpty || key.comment.contains(folder) {
                key.comment = RemotePath.name(privateKey)
            }
            let text = try PuTTYKey.write(key, passphrase: passphrase)
            let fd = open(destination, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
            guard fd >= 0 else {
                throw AirSCPError(.permissionDenied, "Can't write \((destination as NSString).abbreviatingWithTildeInPath): "
                                  + String(cString: strerror(errno)))
            }
            defer { close(fd) }
            fchmod(fd, 0o600)
            let bytes = Array(text.utf8)
            guard write(fd, bytes, bytes.count) == bytes.count else {
                throw AirSCPError(.diskFull, "Can't write \((destination as NSString).abbreviatingWithTildeInPath).")
            }
        }
    }

    /// ssh-keygen's failure with a key's passphrase, in plain words (its own words, which name the temporary copy, go
    /// under Details).
    static func keygenError(_ result: CommandResult) -> AirSCPError {
        let text = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.contains("incorrect passphrase") {
            return AirSCPError(.authFailed(methods: ""), "The key's passphrase isn't right.", details: text)
        }
        if text.contains("invalid format") || text.contains("not a key") || text.contains("unsupported") {
            return AirSCPError(.other, "ssh-keygen can't read this key.", details: text)
        }
        return ErrorMapping.map(text, status: result.status)
    }

    /// Runs `body` with a new folder only this user can open (0700) in the temporary folder; afterwards every file in
    /// it is overwritten with zeros and removed, and the folder too.
    static func withPrivateFolder<T>(_ body: (String) async throws -> T) async throws -> T {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("airscp-key-" + UUID().uuidString).path
        guard mkdir(folder, 0o700) == 0 else {
            throw AirSCPError(.permissionDenied, "Can't make a temporary folder: \(String(cString: strerror(errno)))")
        }
        defer {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? [] {
                let path = folder + "/" + name
                let fd = open(path, O_WRONLY | O_CLOEXEC | O_NOFOLLOW)
                if fd >= 0 {
                    var info = stat()
                    if fstat(fd, &info) == 0 && info.st_size > 0 {
                        let zeros = [UInt8](repeating: 0, count: Int(info.st_size))
                        _ = write(fd, zeros, zeros.count)
                        fsync(fd)
                    }
                    close(fd)
                }
                unlink(path)
            }
            rmdir(folder)
        }
        return try await body(folder)
    }

    /// Writes a new file (never over one that exists) with `mode`.
    static func create(_ path: String, _ data: Data, mode: mode_t) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard fd >= 0 else {
            let name = (path as NSString).abbreviatingWithTildeInPath
            throw errno == EEXIST ? AirSCPError(.other, "\(name) already exists.")
                : AirSCPError(.permissionDenied, "Can't write \(name): \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        fchmod(fd, mode)  // whatever the umask
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else {
            unlink(path)
            throw AirSCPError(.diskFull, "Can't write \((path as NSString).abbreviatingWithTildeInPath).")
        }
    }

    /// Adds a key to the agent and its passphrase to the login Keychain (ssh-add --apple-use-keychain).
    public static func addToAgent(_ privateKey: String, askpass environment: [String: String],
                                  log: ((LogEntry) -> Void)? = nil) async throws {
        let result = await Runner.run(OpenSSH.addToAgent(privateKey), environment: environment, log: log)
        guard result.status == 0 else { throw ErrorMapping.map(result.stderr, status: result.status) }
    }
}
