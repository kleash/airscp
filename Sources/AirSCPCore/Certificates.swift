import CRDP
import CryptoKit
import Foundation

/// The Certificate Manager's model (PLAN.md AA): certificates, keys and requests read from PEM, DER, PKCS#7,
/// PKCS#12 and Java keystores (JKS), their details, and what can be made of them (PEM, DER, PKCS#12, keys with or
/// without a passphrase, public keys), each with the openssl or keytool command that does the same. OpenSSL works in
/// process (airscp_pki.c); JKS is read here. Nothing is written over an existing file by this code: callers choose new
/// paths.
public enum PKI {
    public enum Kind: Int {
        case certificate = 1, privateKey = 2, request = 3, publicKey = 4
    }

    public struct Item: Identifiable, Equatable {
        public let id = UUID()
        public let kind: Kind
        public let der: Data
        /// A PKCS#12 friendly name or a keystore alias.
        public let name: String?
        public init(kind: Kind, der: Data, name: String? = nil) {
            self.kind = kind
            self.der = der
            self.name = name
        }
        public static func == (a: Item, b: Item) -> Bool { a.kind == b.kind && a.der == b.der && a.name == b.name }
    }

    public enum ReadError: Error, Equatable {
        /// A password is needed, or the one given is wrong.
        case password
        /// Not a format AirSCP reads.
        case unknown
        /// A keystore type or cipher AirSCP doesn't read (JCEKS, RC2…).
        case unsupported(String)
        /// A keystore's key has a password of its own (not the store's): ask for it, and read again with `keyPassword`.
        case keyPassword(alias: String)
    }

    /// The items in a file's bytes, with `password` for an encrypted key, a PKCS#12 file or a keystore.
    public static func read(_ data: Data, password: String? = nil, keyPassword: String? = nil) throws -> [Item] {
        if data.prefix(4) == Data([0xFE, 0xED, 0xFE, 0xED]) { return try JKS.read(data, password: password, keyPassword: keyPassword) }
        if data.prefix(4) == Data([0xCE, 0xCE, 0xCE, 0xCE]) { throw ReadError.unsupported("JCEKS") }
        final class Found { var items: [Item] = [] }
        let found = Found()
        let count = data.withUnsafeBytes { bytes -> Int32 in
            airscp_pki_read(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, password, { kind, der, length, name, context in
                guard let der, let context, let kind = Kind(rawValue: Int(kind)) else { return }
                let found = Unmanaged<Found>.fromOpaque(context).takeUnretainedValue()
                found.items.append(Item(kind: kind, der: Data(bytes: der, count: length), name: name.map { String(cString: $0) }))
            }, Unmanaged.passUnretained(found).toOpaque())
        }
        if count == -1 { throw ReadError.password }
        if count == -3 {
            throw ReadError.unsupported("RC2-40 encryption (openssl -legacy and old Windows exports): export it again with AES or 3DES")
        }
        guard count > 0 else { throw ReadError.unknown }
        return found.items
    }

    // MARK: Details

    public struct Details: Equatable {
        public var fields: [String: [String]] = [:]
        public func first(_ name: String) -> String? { fields[name]?.first }
        public var subject: String { first("subject") ?? "" }
        public var issuer: String { first("issuer") ?? "" }
        public var sans: [String] { fields["san"] ?? [] }
        public var notBefore: Date? { first("notBefore").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } }
        public var notAfter: Date? { first("notAfter").flatMap(Double.init).map { Date(timeIntervalSince1970: $0) } }
        public var isCA: Bool { first("ca") == "yes" }
        public var selfIssued: Bool { first("selfIssued") == "yes" }
        /// "RSA 2048", "EC 256 (prime256v1)", "Ed25519".
        public var key: String {
            guard let type = first("keyType") else { return "" }
            let bits = first("keyBits").map { " " + $0 } ?? ""
            return type + (type.hasPrefix("Ed") ? "" : bits) + (first("curve").map { " (\($0))" } ?? "")
        }
        /// The common name (CN) of a subject or issuer line.
        public static func commonName(_ name: String) -> String? {
            name.components(separatedBy: ", ").first { $0.hasPrefix("CN = ") }.map { String($0.dropFirst(5)) }
        }
    }

    public static func details(_ item: Item) -> Details {
        let text: UnsafeMutablePointer<CChar>? = item.der.withUnsafeBytes { bytes in
            let pointer = bytes.bindMemory(to: UInt8.self).baseAddress
            switch item.kind {
            case .certificate: return airscp_pki_describe_certificate(pointer, bytes.count)
            case .request: return airscp_pki_describe_request(pointer, bytes.count)
            case .privateKey, .publicKey: return airscp_pki_describe_key(Int32(item.kind.rawValue), pointer, bytes.count)
            }
        }
        var details = Details()
        if let text {
            for line in String(cString: text).split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 1)
                if parts.count == 2 { details.fields[String(parts[0]), default: []].append(String(parts[1])) }
            }
            airscp_pki_free(text)
        }
        return details
    }

    /// "AB:CD:…" of the DER's SHA-256 (or SHA-1).
    public static func fingerprint(_ der: Data, sha1: Bool = false) -> String {
        let digest = sha1 ? Array(Insecure.SHA1.hash(data: der)) : Array(SHA256.hash(data: der))
        return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// The item in a line, as the list shows it: "Certificate: web.example.com", "Private key: RSA 2048".
    public static func title(_ item: Item) -> String {
        let details = details(item)
        switch item.kind {
        case .certificate:
            let name = Details.commonName(details.subject) ?? details.sans.first ?? details.subject
            return (details.isCA ? "CA certificate: " : "Certificate: ") + name
        case .request: return "Certificate request: " + (Details.commonName(details.subject) ?? details.subject)
        case .privateKey: return "Private key: " + details.key
        case .publicKey: return "Public key: " + details.key
        }
    }

    /// Days until a certificate expires (negative: since it did).
    public static func daysLeft(_ details: Details, now: Date = Date()) -> Int? {
        details.notAfter.map { Int(floor($0.timeIntervalSince(now) / 86400)) }
    }

    // MARK: Checks

    /// The public key (SubjectPublicKeyInfo DER) of a certificate, request or key.
    public static func publicKey(_ item: Item) -> Data? {
        var length = 0
        let out = item.der.withUnsafeBytes { bytes in
            airscp_pki_public_key(Int32(item.kind.rawValue), bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, &length)
        }
        guard let out else { return nil }
        defer { airscp_pki_free(out) }
        return Data(bytes: out, count: length)
    }

    /// Whether a private key belongs to a certificate (or request): the same public key.
    public static func matches(_ key: Item, _ other: Item) -> Bool {
        guard let a = publicKey(key), let b = publicKey(other) else { return false }
        return a == b
    }

    /// Whether `certificate` was signed by `issuer`'s key.
    public static func signed(_ certificate: Item, by issuer: Item) -> Bool {
        certificate.der.withUnsafeBytes { a in
            issuer.der.withUnsafeBytes { b in
                airscp_pki_signed_by(a.bindMemory(to: UInt8.self).baseAddress, a.count, b.bindMemory(to: UInt8.self).baseAddress, b.count) == 1
            }
        }
    }

    /// Certificates in chain order: each followed by its issuer (by signature), the leaf first; those that belong to no
    /// chain keep their place at the end.
    public static func chainOrder(_ certificates: [Item]) -> [Item] {
        var left = certificates.filter { $0.kind == .certificate }
        // The leaf: issued no other certificate here.
        let issuers = Set(left.indices.filter { i in left.indices.contains { j in j != i && signed(left[j], by: left[i]) } })
        guard let leafIndex = left.indices.first(where: { !issuers.contains($0) }) else { return left }
        var chain = [left.remove(at: leafIndex)]
        while let next = left.firstIndex(where: { signed(chain.last!, by: $0) && $0.der != chain.last!.der }) {
            chain.append(left.remove(at: next))
        }
        return chain + left
    }

    // MARK: Writing

    public static func pem(_ item: Item) -> String {
        let label = ["CERTIFICATE", "PRIVATE KEY", "CERTIFICATE REQUEST", "PUBLIC KEY"][item.kind.rawValue - 1]
        return pem(item.der, label: label)
    }

    public static func pem(_ der: Data, label: String) -> String {
        let base64 = der.base64EncodedString()
        var lines: [String] = []
        var index = base64.startIndex
        while index < base64.endIndex {
            let end = base64.index(index, offsetBy: 64, limitedBy: base64.endIndex) ?? base64.endIndex
            lines.append(String(base64[index..<end]))
            index = end
        }
        return "-----BEGIN \(label)-----\n" + lines.joined(separator: "\n") + "\n-----END \(label)-----\n"
    }

    /// A private key as PEM: PKCS#8 encrypted with AES-256 when `passphrase` isn't empty, else PKCS#8, or PKCS#1/SEC1
    /// (`traditional`, for older software).
    public static func keyPEM(_ key: Item, passphrase: String = "", traditional: Bool = false) -> String? {
        let text = key.der.withUnsafeBytes { bytes in
            airscp_pki_key_pem(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, passphrase, traditional ? 1 : 0)
        }
        guard let text else { return nil }
        defer { airscp_pki_free(text) }
        return String(cString: text)
    }

    /// A PKCS#12 file of a key, its certificate and the chain. `legacy`: 3DES and SHA-1, for old Java and Windows.
    public static func pkcs12(key: Item?, certificate: Item?, chain: [Item], name: String?, password: String, legacy: Bool) -> Data? {
        var length = 0
        let chainData = chain.map(\.der)
        let pointers = chainData.map { data -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(data.count, 1))
            data.copyBytes(to: pointer, count: data.count)
            return pointer
        }
        defer { pointers.forEach { $0.deallocate() } }
        let lengths = chainData.map(\.count)
        let out: UnsafeMutablePointer<UInt8>? = withOptionalBytes(key?.der) { keyBytes, keyLength in
            withOptionalBytes(certificate?.der) { certBytes, certLength in
                pointers.map { UnsafePointer($0) as UnsafePointer<UInt8>? }.withUnsafeBufferPointer { chainPointers in
                    lengths.withUnsafeBufferPointer { chainLengths in
                        airscp_pki_pkcs12(keyBytes, keyLength, certBytes, certLength, chainPointers.baseAddress, chainLengths.baseAddress,
                                          Int32(chain.count), name, password, legacy ? 1 : 0, &length)
                    }
                }
            }
        }
        guard let out else { return nil }
        defer { airscp_pki_free(out) }
        return Data(bytes: out, count: length)
    }

    private static func withOptionalBytes<T>(_ data: Data?, _ body: (UnsafePointer<UInt8>?, Int) -> T) -> T {
        guard let data else { return body(nil, 0) }
        return data.withUnsafeBytes { body($0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
    }

    // MARK: The commands that do the same

    /// The openssl (or keytool) command that does what the Certificate Manager just did, for the user to learn or reuse.
    public enum Command {
        public static func show(_ file: String, kind: Kind) -> String {
            switch kind {
            case .certificate: return "openssl x509 -in \(q(file)) -noout -text -fingerprint -sha256"
            case .request: return "openssl req -in \(q(file)) -noout -text -verify"
            case .privateKey: return "openssl pkey -in \(q(file)) -noout -text"
            case .publicKey: return "openssl pkey -pubin -in \(q(file)) -noout -text"
            }
        }
        public static func pkcs12Read(_ file: String) -> String { "openssl pkcs12 -in \(q(file)) -info -nodes" }
        public static func keystoreRead(_ file: String) -> String { "keytool -list -v -keystore \(q(file))" }
        public static func toDER(_ input: String, _ output: String) -> String { "openssl x509 -in \(q(input)) -outform DER -out \(q(output))" }
        public static func toPEM(_ input: String, _ output: String) -> String { "openssl x509 -inform DER -in \(q(input)) -out \(q(output))" }
        public static func chain(_ input: String, _ output: String) -> String { "openssl crl2pkcs7 -nocrl -certfile \(q(input)) | openssl pkcs7 -print_certs -out \(q(output))" }
        public static func key(_ input: String, _ output: String, passphrase: Bool, traditional: Bool) -> String {
            passphrase ? "openssl pkey -in \(q(input)) -aes256 -out \(q(output))"
                : traditional ? "openssl pkey -in \(q(input)) -traditional -out \(q(output))" : "openssl pkey -in \(q(input)) -out \(q(output))"
        }
        public static func publicKey(_ input: String, _ output: String) -> String { "openssl pkey -in \(q(input)) -pubout -out \(q(output))" }
        public static func pkcs12(key: String, certificate: String, output: String, legacy: Bool) -> String {
            "openssl pkcs12 -export -inkey \(q(key)) -in \(q(certificate)) -out \(q(output))" + (legacy ? " -legacy" : "")
        }
        public static func match(key: String, certificate: String) -> String {
            "diff <(openssl pkey -in \(q(key)) -pubout) <(openssl x509 -in \(q(certificate)) -noout -pubkey)"
        }
        public static func server(_ host: String, _ port: Int) -> String {
            "openssl s_client -connect \(q(host + ":\(port)")) -servername \(q(host)) -showcerts </dev/null"
        }
        public static func q(_ word: String) -> String { Quote.shellWord(word) }
    }
}

// MARK: Java keystores

/// Java's JKS keystore (read only): its trusted certificates and its private keys (with their chains), the file's
/// integrity checked with the store password and each key opened with it (Java's own key protection).
enum JKS {
    static func read(_ data: Data, password: String?, keyPassword: String?) throws -> [PKI.Item] {
        guard let password else { throw PKI.ReadError.password }
        let bytes = [UInt8](data)
        guard bytes.count > 32 else { throw PKI.ReadError.unknown }
        // The last 20 bytes: SHA-1 over the password (UTF-16BE), "Mighty Aphrodite" and the rest.
        let body = bytes.dropLast(20)
        let secret = Array(password.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })
        var hasher = Insecure.SHA1()
        hasher.update(data: secret)
        hasher.update(data: Array("Mighty Aphrodite".utf8))
        hasher.update(data: Array(body))
        guard Array(hasher.finalize()) == Array(bytes.suffix(20)) else { throw PKI.ReadError.password }
        var reader = Reader(bytes: Array(body))
        guard try reader.uint32() == 0xFEEDFEED else { throw PKI.ReadError.unknown }
        let version = try reader.uint32()
        guard version == 1 || version == 2 else { throw PKI.ReadError.unknown }
        var items: [PKI.Item] = []
        for _ in 0..<(try reader.uint32()) {
            let tag = try reader.uint32()
            let alias = try reader.utf()
            _ = try reader.bytes(8)  // date
            func certificate() throws -> Data {
                if version == 2 { _ = try reader.utf() }  // "X.509"
                return Data(try reader.bytes(Int(try reader.uint32())))
            }
            switch tag {
            case 1:  // a private key and its chain
                let sealed = try reader.bytes(Int(try reader.uint32()))
                // A key's own password, when it isn't the store's.
                let keySecret = keyPassword.map { Array($0.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }) }
                guard let key = (try? open(sealed, secret: secret)) ?? keySecret.flatMap({ try? open(sealed, secret: $0) }) else {
                    throw PKI.ReadError.keyPassword(alias: alias)
                }
                items.append(PKI.Item(kind: .privateKey, der: key, name: alias))
                for _ in 0..<(try reader.uint32()) { items.append(PKI.Item(kind: .certificate, der: try certificate(), name: alias)) }
            case 2:  // a trusted certificate
                items.append(PKI.Item(kind: .certificate, der: try certificate(), name: alias))
            default:
                throw PKI.ReadError.unknown
            }
        }
        return items
    }

    /// Java's KeyProtector: an EncryptedPrivateKeyInfo whose data is salt (20 bytes), the key XORed with a SHA-1
    /// stream of password and salt, and a SHA-1 check of password and key.
    static func open(_ sealed: [UInt8], secret: [UInt8]) throws -> Data {
        // SEQUENCE { SEQUENCE { OID, NULL }, OCTET STRING }: the octet string is the last element.
        var der = DER(bytes: sealed)
        var outer = try der.child(tag: 0x30)
        _ = try outer.child(tag: 0x30)
        let protected = try outer.child(tag: 0x04).rest
        guard protected.count > 40 else { throw PKI.ReadError.unknown }
        let salt = Array(protected.prefix(20)), check = Array(protected.suffix(20))
        let encrypted = Array(protected.dropFirst(20).dropLast(20))
        var stream: [UInt8] = [], digest = salt
        while stream.count < encrypted.count {
            digest = Array(Insecure.SHA1.hash(data: secret + digest))
            stream += digest
        }
        let key = zip(encrypted, stream).map { $0 ^ $1 }
        guard Array(Insecure.SHA1.hash(data: secret + key)) == check else { throw PKI.ReadError.password }
        return Data(key)
    }

    struct Reader {
        let bytes: [UInt8]
        var offset = 0
        mutating func bytes(_ count: Int) throws -> [UInt8] {
            guard count >= 0, offset + count <= bytes.count else { throw PKI.ReadError.unknown }
            defer { offset += count }
            return Array(bytes[offset..<(offset + count)])
        }
        mutating func uint32() throws -> UInt32 { try bytes(4).reduce(0) { $0 << 8 | UInt32($1) } }
        mutating func utf() throws -> String {
            let length = try bytes(2).reduce(0) { $0 << 8 | Int($1) }
            return String(decoding: try bytes(length), as: UTF8.self)
        }
    }

    /// Just enough DER to take apart an EncryptedPrivateKeyInfo.
    struct DER {
        var bytes: [UInt8]
        var rest: [UInt8] { bytes }
        mutating func child(tag: UInt8) throws -> DER {
            guard bytes.count >= 2, bytes[0] == tag else { throw PKI.ReadError.unknown }
            var length = Int(bytes[1]), header = 2
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count <= 4, bytes.count >= 2 + count else { throw PKI.ReadError.unknown }
                length = bytes[2..<(2 + count)].reduce(0) { $0 << 8 | Int($1) }
                header += count
            }
            guard bytes.count >= header + length else { throw PKI.ReadError.unknown }
            let child = DER(bytes: Array(bytes[header..<(header + length)]))
            bytes = Array(bytes[(header + length)...])
            return child
        }
    }
}
