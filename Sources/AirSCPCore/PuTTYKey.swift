import CommonCrypto
import CRDP
import CryptoKit
import Foundation

/// PuTTY's private key files (.ppk, versions 2 and 3) and OpenSSH's own private key format, which ssh and ssh-keygen
/// read. ssh-keygen can't read or write .ppk files, so AirSCP converts between the two itself (PLAN.md K.2): RSA, ECDSA
/// (256, 384 and 521 bits) and Ed25519 keys. The formats: PuTTY's manual (appendix "PPK file format") and OpenSSH's
/// PROTOCOL.key; the tests check PuTTY's own test vectors and its puttygen. Only the unencrypted OpenSSH form is read
/// and written here: `Keys.importPPK` and `Keys.exportPPK` keep it in a private temporary folder, and ssh-keygen adds
/// or removes the passphrase.
public enum PuTTYKey {
    /// A key as both formats hold it: its public key and private fields in SSH's wire format, in PuTTY's order.
    public struct Key: Equatable {
        /// "ssh-ed25519", "ecdsa-sha2-nistp256" (384, 521) or "ssh-rsa".
        public let algorithm: String
        public let publicBlob: Data
        /// Ed25519: string(the 32-byte seed); ECDSA: mpint(d); RSA: mpint(d), mpint(p), mpint(q), mpint(iqmp).
        public let privateBlob: Data
        public var comment: String
    }

    /// The key types both formats share.
    static let algorithms: Set<String> = ["ssh-ed25519", "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384",
                                          "ecdsa-sha2-nistp521", "ssh-rsa"]

    /// PuTTY's defaults for version 3: Argon2id over 8 MB, one lane, as many passes as take about 0.1 s.
    static let argon2Memory: UInt32 = 8192

    // MARK: Reading a .ppk file

    /// Whether the .ppk text says its private key is encrypted (a passphrase is needed); nil when it isn't a .ppk file.
    public static func isEncrypted(_ text: String) -> Bool? {
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        guard lines.first?.hasPrefix("PuTTY-User-Key-File-") == true, lines.count > 1,
              lines[1].hasPrefix("Encryption: ") else { return nil }
        return lines[1] != "Encryption: none"
    }

    /// The key in a .ppk file's text: its MAC checked (with the passphrase, for an encrypted one). Throws a wrong
    /// passphrase as `.authFailed`, and says what else is wrong in plain words.
    public static func read(_ text: String, passphrase: String) throws -> Key {
        var lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\r")) }
        lines.reverse()
        func next(_ name: String) throws -> String {
            guard let line = lines.popLast(), line.hasPrefix(name + ": ") else { throw damaged("no “\(name)” line") }
            return String(line.dropFirst(name.count + 2))
        }
        func blob(_ name: String) throws -> Data {
            guard let count = Int(try next(name)), (0...1024).contains(count), lines.count >= count else {
                throw damaged("a bad “\(name)” count")
            }
            let text = (0..<count).map { _ in lines.popLast()! }.joined()
            guard let data = Data(base64Encoded: text) else { throw damaged("bad base64 after “\(name)”") }
            return data
        }

        guard let first = lines.popLast(), first.hasPrefix("PuTTY-User-Key-File-"), let colon = first.firstIndex(of: ":")
        else { throw AirSCPError(.other, "This isn't a PuTTY private key file (.ppk).") }
        let version = first[first.index(first.startIndex, offsetBy: 20)..<colon]
        guard version == "2" || version == "3" else {
            throw AirSCPError(.other, version == "1"
                ? "This PuTTY key is in PuTTY's oldest format. Open it in PuTTYgen and save it again, then import that file."
                : "This PuTTY key was saved by a newer PuTTY (format \(version)). Save it in PuTTYgen as format 3 or 2.")
        }
        let algorithm = String(first[first.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard algorithms.contains(algorithm) else { throw unsupported(algorithm) }
        let encryption = try next("Encryption")
        guard encryption == "none" || encryption == "aes256-cbc" else {
            throw AirSCPError(.other, "This PuTTY key is encrypted with “\(encryption)”, which AirSCP doesn't know.")
        }
        let encrypted = encryption != "none"
        let comment = try next("Comment")
        let publicBlob = try blob("Public-Lines")
        var argon2: (flavour: Int32, memory: UInt32, passes: UInt32, lanes: UInt32, salt: Data)?
        if version == "3" && encrypted {
            let flavours: [String: Int32] = ["Argon2d": 0, "Argon2i": 1, "Argon2id": 2]
            guard let flavour = flavours[try next("Key-Derivation")],
                  let memory = UInt32(try next("Argon2-Memory")), let passes = UInt32(try next("Argon2-Passes")),
                  let lanes = UInt32(try next("Argon2-Parallelism")), let salt = Data(hex: try next("Argon2-Salt"))
            else { throw damaged("bad key derivation settings") }
            // Within what a key file asks for in practice (PuTTY's default: 8 MB, 1 lane, about 0.1 s of passes).
            guard (8...1_048_576).contains(memory), (1...1000).contains(passes), (1...64).contains(lanes), salt.count >= 8
            else { throw damaged("key derivation settings AirSCP won't run (memory \(memory) KB, \(passes) passes)") }
            argon2 = (flavour, memory, passes, lanes, salt)
        }
        var privateBlob = try blob("Private-Lines")
        guard let mac = Data(hex: try next("Private-MAC")) else { throw damaged("a bad Private-MAC line") }

        let keys = try deriveKeys(version: version == "3" ? 3 : 2, passphrase: encrypted ? passphrase : "", encrypted: encrypted,
                                  argon2: argon2.map { ($0.flavour, $0.memory, $0.passes, $0.lanes, $0.salt) })
        if encrypted {
            guard privateBlob.count % 16 == 0 else { throw damaged("a private part of the wrong length") }
            privateBlob = try aes256CBC(decrypt: true, privateBlob, key: keys.cipher, iv: keys.iv)
        }
        let expected = Self.mac(version: version == "3" ? 3 : 2, key: keys.mac, algorithm: algorithm, encryption: encryption,
                                comment: comment, publicBlob: publicBlob, privateBlob: privateBlob)
        guard expected.count == mac.count, zip(expected, mac).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else {
            if encrypted { throw AirSCPError(.authFailed(methods: ""), "The passphrase isn't right for this PuTTY key.") }
            throw damaged("its check (MAC) doesn't match: it was changed or damaged")
        }
        let fields = try privateFields(algorithm, privateBlob)
        try check(algorithm, publicBlob)
        return Key(algorithm: algorithm, publicBlob: publicBlob, privateBlob: fields, comment: comment)
    }

    // MARK: Writing a .ppk file

    /// The key as a .ppk file in format 3, which PuTTY 0.75 and later read: encrypted with AES-256-CBC under an
    /// Argon2id key (PuTTY's defaults) when `passphrase` isn't empty. Format 2 is only read: its key derivation is
    /// SHA-1. `salt` and `passes` are for the tests (PuTTY's test vectors).
    public static func write(_ key: Key, passphrase: String, salt: Data? = nil,
                             passes: UInt32? = nil) throws -> String {
        let encrypted = !passphrase.isEmpty
        var privateBlob = key.privateBlob
        if encrypted {
            // Padded to the cipher's block with the start of the blob's SHA-1, as PuTTY does.
            let padding = (16 - privateBlob.count % 16) % 16
            privateBlob += Data(Insecure.SHA1.hash(data: key.privateBlob)).prefix(padding)
        }
        var argon2: (flavour: Int32, memory: UInt32, passes: UInt32, lanes: UInt32, salt: Data)?
        var derived: (cipher: Data, iv: Data, mac: Data)?
        if encrypted {
            let salt = salt ?? Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            if let passes {
                argon2 = (2, argon2Memory, passes, 1, salt)
            } else {
                // As PuTTY: passes growing as Fibonacci numbers until one derivation takes 0.1 s; that one is used.
                var (a, b): (UInt32, UInt32) = (1, 1)
                while true {
                    let start = Date()
                    derived = try deriveKeys(version: 3, passphrase: passphrase, encrypted: true,
                                             argon2: (2, argon2Memory, b, 1, salt))
                    if Date().timeIntervalSince(start) >= 0.1 || b >= 1000 { break }
                    (a, b) = (b, a + b)
                }
                argon2 = (2, argon2Memory, b, 1, salt)
            }
        }
        let keys = try derived ?? deriveKeys(version: 3, passphrase: passphrase, encrypted: encrypted,
                                             argon2: argon2.map { ($0.flavour, $0.memory, $0.passes, $0.lanes, $0.salt) })
        let encryption = encrypted ? "aes256-cbc" : "none"
        let comment = key.comment.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        let mac = Self.mac(version: 3, key: keys.mac, algorithm: key.algorithm, encryption: encryption, comment: comment,
                           publicBlob: key.publicBlob, privateBlob: privateBlob)
        if encrypted { privateBlob = try aes256CBC(decrypt: false, privateBlob, key: keys.cipher, iv: keys.iv) }
        var lines = ["PuTTY-User-Key-File-3: \(key.algorithm)", "Encryption: \(encryption)", "Comment: \(comment)"]
        lines += ["Public-Lines: \((key.publicBlob.count + 47) / 48)"] + base64Lines(key.publicBlob, width: 64)
        if let argon2 {
            lines += ["Key-Derivation: Argon2id", "Argon2-Memory: \(argon2.memory)", "Argon2-Passes: \(argon2.passes)",
                      "Argon2-Parallelism: \(argon2.lanes)", "Argon2-Salt: \(argon2.salt.hex)"]
        }
        lines += ["Private-Lines: \((privateBlob.count + 47) / 48)"] + base64Lines(privateBlob, width: 64)
        lines.append("Private-MAC: \(mac.hex)")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: OpenSSH's private key format (unencrypted)

    /// The key as an unencrypted OpenSSH private key file ("-----BEGIN OPENSSH PRIVATE KEY-----").
    public static func openSSH(_ key: Key) throws -> String {
        var fields = Wire.Reader(key.privateBlob)
        var section = Wire.Writer()
        let check = UInt32.random(in: 0...UInt32.max)
        section.uint32(check)
        section.uint32(check)
        section.string(Data(key.algorithm.utf8))
        var publicKey = Wire.Reader(key.publicBlob)
        _ = try publicKey.string()  // the algorithm
        switch key.algorithm {
        case "ssh-ed25519":
            let point = try publicKey.string(), seed = try fields.string()
            section.string(point)
            section.string(seed + point)
        case "ssh-rsa":
            let e = try publicKey.string(), n = try publicKey.string()
            let d = try fields.string(), p = try fields.string(), q = try fields.string(), iqmp = try fields.string()
            for value in [n, e, d, iqmp, p, q] { section.string(value) }
        default:  // ECDSA
            section.string(try publicKey.string())  // the curve
            section.string(try publicKey.string())  // the public point
            section.string(try fields.string())  // d
        }
        section.string(Data(key.comment.utf8))
        var padding: UInt8 = 1
        while section.data.count % 8 != 0 {
            section.data.append(padding)
            padding += 1
        }
        var file = Wire.Writer()
        file.data.append(contentsOf: Array("openssh-key-v1".utf8) + [0])
        file.string(Data("none".utf8))
        file.string(Data("none".utf8))
        file.string(Data())
        file.uint32(1)
        file.string(key.publicBlob)
        file.string(section.data)
        return (["-----BEGIN OPENSSH PRIVATE KEY-----"] + base64Lines(file.data, width: 70)
            + ["-----END OPENSSH PRIVATE KEY-----"]).joined(separator: "\n") + "\n"
    }

    /// The key in an unencrypted OpenSSH private key file.
    public static func fromOpenSSH(_ text: String) throws -> Key {
        let body = text.components(separatedBy: .newlines).filter { !$0.hasPrefix("-----") }.joined()
        guard text.contains("-----BEGIN OPENSSH PRIVATE KEY-----"), let data = Data(base64Encoded: body) else {
            throw AirSCPError(.other, "This isn't a private key in OpenSSH's format.")
        }
        var file = Wire.Reader(data)
        guard Array(try file.bytes(15)) == Array("openssh-key-v1".utf8) + [0] else {
            throw AirSCPError(.other, "This isn't a private key in OpenSSH's format.")
        }
        guard try file.string() == Data("none".utf8) else { throw AirSCPError(.other, "The key is still encrypted.") }
        _ = try file.string()  // kdf
        _ = try file.string()  // kdf options
        guard try file.uint32() == 1 else { throw AirSCPError(.other, "The file holds more than one key.") }
        let publicBlob = try file.string()
        var section = Wire.Reader(try file.string())
        guard try section.uint32() == section.uint32() else { throw AirSCPError(.other, "The key file is damaged.") }
        let algorithm = String(decoding: try section.string(), as: UTF8.self)
        guard algorithms.contains(algorithm) else { throw unsupported(algorithm) }
        var fields = Wire.Writer()
        switch algorithm {
        case "ssh-ed25519":
            let point = try section.string(), secret = try section.string()
            guard point.count == 32, secret.count == 64, secret.suffix(32) == point else {
                throw AirSCPError(.other, "The Ed25519 key is damaged.")
            }
            fields.string(secret.prefix(32))
        case "ssh-rsa":
            let n = try section.string(), e = try section.string(), d = try section.string(), iqmp = try section.string()
            let p = try section.string(), q = try section.string()
            _ = (n, e)
            for value in [d, p, q, iqmp] { fields.string(value) }
        default:
            _ = try section.string()  // the curve
            _ = try section.string()  // the public point
            fields.string(try section.string())
        }
        let comment = String(decoding: try section.string(), as: UTF8.self)
        try check(algorithm, publicBlob)
        return Key(algorithm: algorithm, publicBlob: publicBlob, privateBlob: fields.data, comment: comment)
    }

    /// The public key as a line for a .pub file or authorized_keys: "ssh-ed25519 AAAA… comment".
    public static func publicLine(_ key: Key) -> String {
        ([key.algorithm, key.publicBlob.base64EncodedString()] + (key.comment.isEmpty ? [] : [key.comment]))
            .joined(separator: " ")
    }

    // MARK: Helpers

    /// The fields at the start of a (padded) private blob, without the padding.
    private static func privateFields(_ algorithm: String, _ blob: Data) throws -> Data {
        var reader = Wire.Reader(blob)
        do {
            let count = algorithm == "ssh-rsa" ? 4 : 1
            for _ in 0..<count { _ = try reader.string() }
            if algorithm == "ssh-ed25519" && reader.offset != 36 { throw damaged("a bad Ed25519 secret") }
        } catch {
            throw damaged("a private part that doesn't fit its key type")
        }
        return Data(blob.prefix(reader.offset))
    }

    /// The public blob fits its algorithm: "ssh-ed25519" and a 32-byte point, "ecdsa-sha2-<curve>" and that curve's
    /// name, "ssh-rsa" and two numbers.
    private static func check(_ algorithm: String, _ publicBlob: Data) throws {
        var reader = Wire.Reader(publicBlob)
        do {
            guard String(decoding: try reader.string(), as: UTF8.self) == algorithm else { throw damaged("") }
            switch algorithm {
            case "ssh-ed25519": guard try reader.string().count == 32 else { throw damaged("") }
            case "ssh-rsa": _ = (try reader.string(), try reader.string())
            default:
                guard "ecdsa-sha2-" + String(decoding: try reader.string(), as: UTF8.self) == algorithm else { throw damaged("") }
                _ = try reader.string()
            }
        } catch {
            throw damaged("a public key that doesn't fit its key type")
        }
    }

    private static func damaged(_ what: String) -> AirSCPError {
        AirSCPError(.other, "The key file is damaged" + (what.isEmpty ? "." : ": \(what)."))
    }

    private static func unsupported(_ algorithm: String) -> AirSCPError {
        let name = algorithm == "ssh-dss" ? "DSA keys are obsolete and modern OpenSSH refuses them"
            : algorithm.hasPrefix("sk-") ? "Keys kept on a security key can't be moved between PuTTY and OpenSSH"
            : "AirSCP converts RSA, ECDSA and Ed25519 keys, not “\(algorithm)”"
        return AirSCPError(.other, name + ".")
    }

    /// The cipher key, IV and MAC key for a file version: version 3 from Argon2 (no MAC key when unencrypted), version
    /// 2 from SHA-1 (a zero IV), as that format prescribes (only read). CodeQL's swift/weak-password-hashing flags the
    /// two SHA-1 lines below; they stay, as the only way to read a legacy .ppk version 2 file (PuTTY before 0.75 and
    /// WinSCP's older exports), which AirSCP never writes: keys it exports are version 3, Argon2id. The alerts are
    /// dismissed as "won't fix" with this reason (docs/dev/release.md, launch step 3).
    private static func deriveKeys(version: Int, passphrase: String, encrypted: Bool,
                                   argon2: (flavour: Int32, memory: UInt32, passes: UInt32, lanes: UInt32, salt: Data)?)
        throws -> (cipher: Data, iv: Data, mac: Data) {
        let password = Data(passphrase.utf8)
        if version == 3 {
            guard encrypted, let argon2 else { return (Data(), Data(), Data()) }
            var out = [UInt8](repeating: 0, count: 80)
            let ok = password.withUnsafeBytes { pass in
                argon2.salt.withUnsafeBytes { salt in
                    airscp_argon2(argon2.flavour, pass.bindMemory(to: UInt8.self).baseAddress, pass.count,
                                  salt.bindMemory(to: UInt8.self).baseAddress, salt.count, argon2.memory, argon2.passes,
                                  argon2.lanes, &out, out.count)
                }
            }
            guard ok else { throw AirSCPError(.other, "AirSCP couldn't derive the key file's encryption key (Argon2).") }
            defer { out.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) } }
            return (Data(out[0..<32]), Data(out[32..<48]), Data(out[48..<80]))
        }
        var cipher = Data()
        for counter in [UInt32(0), 1] {
            var hash = Insecure.SHA1()
            hash.update(data: Data([UInt8(counter >> 24), UInt8(counter >> 16 & 0xFF), UInt8(counter >> 8 & 0xFF),
                                    UInt8(counter & 0xFF)]))
            hash.update(data: password)
            cipher += Data(hash.finalize())
        }
        var macKey = Insecure.SHA1()
        macKey.update(data: Data("putty-private-key-file-mac-key".utf8))
        macKey.update(data: password)
        return (cipher.prefix(32), Data(count: 16), Data(macKey.finalize()))
    }

    /// The Private-MAC: HMAC-SHA-256 (version 3) or HMAC-SHA-1 (version 2) of the names, the comment and both blobs.
    private static func mac(version: Int, key: Data, algorithm: String, encryption: String, comment: String,
                            publicBlob: Data, privateBlob: Data) -> Data {
        var data = Wire.Writer()
        for text in [algorithm, encryption, comment] { data.string(Data(text.utf8)) }
        data.string(publicBlob)
        data.string(privateBlob)
        let symmetric = SymmetricKey(data: key)
        return version == 3 ? Data(HMAC<SHA256>.authenticationCode(for: data.data, using: symmetric))
            : Data(HMAC<Insecure.SHA1>.authenticationCode(for: data.data, using: symmetric))
    }

    /// AES-256-CBC without padding (the data is a whole number of blocks).
    private static func aes256CBC(decrypt: Bool, _ data: Data, key: Data, iv: Data) throws -> Data {
        var out = Data(count: data.count)
        var moved = 0
        let status = out.withUnsafeMutableBytes { output in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { key in
                    iv.withUnsafeBytes { iv in
                        CCCrypt(CCOperation(decrypt ? kCCDecrypt : kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0,
                                key.baseAddress, key.count, iv.baseAddress, input.baseAddress, input.count,
                                output.baseAddress, output.count, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess, moved == data.count else { throw AirSCPError(.other, "AES failed (\(status)).") }
        return out
    }

    private static func base64Lines(_ data: Data, width: Int) -> [String] {
        let text = data.base64EncodedString()
        return stride(from: 0, to: text.count, by: width).map { start in
            let from = text.index(text.startIndex, offsetBy: start)
            return String(text[from..<(text.index(from, offsetBy: width, limitedBy: text.endIndex) ?? text.endIndex)])
        }
    }
}

/// SSH's wire format (RFC 4251): big-endian uint32s and length-prefixed strings (mpints are strings too).
enum Wire {
    struct Reader {
        private let buffer: [UInt8]
        private(set) var offset = 0

        init(_ data: Data) { buffer = Array(data) }

        mutating func bytes(_ count: Int) throws -> Data {
            guard count >= 0, offset + count <= buffer.count else { throw AirSCPError(.other, "The key data ends too soon.") }
            defer { offset += count }
            return Data(buffer[offset..<offset + count])
        }

        mutating func uint32() throws -> UInt32 {
            try bytes(4).reduce(0) { $0 << 8 | UInt32($1) }
        }

        mutating func string() throws -> Data {
            try bytes(Int(try uint32()))
        }
    }

    struct Writer {
        var data = Data()

        mutating func uint32(_ value: UInt32) {
            data.append(contentsOf: [UInt8(value >> 24), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
        }

        mutating func string(_ value: Data) {
            uint32(UInt32(value.count))
            data.append(value)
        }
    }
}

extension Data {
    /// Bytes from hex digits (an even number of them), else nil.
    init?(hex: String) {
        let digits = Array(hex.utf8)
        guard digits.count % 2 == 0 else { return nil }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: digits.count, by: 2) {
            guard let byte = UInt8(String(decoding: digits[index...index + 1], as: UTF8.self), radix: 16) else { return nil }
            bytes.append(byte)
        }
        self.init(bytes)
    }

    /// Lowercase hex digits.
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
