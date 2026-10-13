import CRDP
import CryptoKit
import Foundation
import Security

/// The Certificate Manager's model: certificates, keys and requests read from PEM, DER, PKCS#7, PKCS#12 and Java
/// keystores (JKS), their details, what can be made of them (PEM, DER, PKCS#12 and JKS keystores and truststores, keys
/// with or without a passphrase, public keys), new requests and self-signed certificates, and chain checks, each with
/// the openssl or keytool command that does the same. OpenSSL works in process (airscp_pki.c); JKS is read and written
/// here. Nothing is written over an existing file by this code: callers choose new paths.
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
        withOptionalBytes(key?.der) { keyBytes, keyLength in
            withOptionalBytes(certificate?.der) { certBytes, certLength in
                withBuffers(chain.map(\.der)) { pointers, lengths in
                    output { airscp_pki_pkcs12(keyBytes, keyLength, certBytes, certLength, pointers, lengths, Int32(chain.count), name,
                                               password, legacy ? 1 : 0, &$0) }
                }
            }
        }
    }

    /// A Java keystore (JKS) of `key` with `certificate` and the chain above it, under `name` (else the certificate's
    /// common name). The key is protected with the store's password, as keytool does.
    public static func jks(key: Item, certificate: Item, chain: [Item], name: String?, password: String) -> Data {
        let given = (name ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        let alias = given.isEmpty ? aliases([certificate])[0] : given
        return JKS.write([JKS.Entry(alias: alias, key: key.der, chain: ([certificate] + chain).map(\.der))], password: password)
    }

    /// A truststore of `certificates`, each a trusted entry named as `aliases` names it: PKCS#12 (with the mark Java
    /// looks for) or JKS.
    public static func truststore(_ certificates: [Item], password: String, jks: Bool) -> Data? {
        let names = aliases(certificates)
        if jks {
            return JKS.write(zip(names, certificates).map { JKS.Entry(alias: $0, key: nil, chain: [$1.der]) }, password: password)
        }
        let strings = names.map { strdup($0) }
        defer { strings.forEach { free($0) } }
        return withBuffers(certificates.map(\.der)) { pointers, lengths in
            strings.map { UnsafePointer($0) }.withUnsafeBufferPointer { aliases in
                output { airscp_pki_truststore(pointers, lengths, aliases.baseAddress, Int32(certificates.count), password, &$0) }
            }
        }
    }

    /// Names for keystore entries: each certificate's common name in lower case (Java keeps aliases so), numbered when
    /// two are alike.
    public static func aliases(_ certificates: [Item]) -> [String] {
        var aliases: [String] = []
        for certificate in certificates {
            let base = (Details.commonName(details(certificate).subject) ?? "certificate").lowercased()
            var alias = base, number = 2
            while aliases.contains(alias) {
                alias = "\(base)-\(number)"
                number += 1
            }
            aliases.append(alias)
        }
        return aliases
    }

    /// Writes new files, never over existing ones: all of them, or none when one can't be written.
    public static func saveNew(_ files: [(path: String, data: Data, mode: mode_t)]) throws {
        var written: [String] = []
        do {
            for file in files {
                try Keys.create(file.path, file.data, mode: file.mode)
                written.append(file.path)
            }
        } catch {
            written.forEach { unlink($0) }
            throw error
        }
    }

    private static func withOptionalBytes<T>(_ data: Data?, _ body: (UnsafePointer<UInt8>?, Int) -> T) -> T {
        guard let data else { return body(nil, 0) }
        return data.withUnsafeBytes { body($0.bindMemory(to: UInt8.self).baseAddress, $0.count) }
    }

    /// `buffers` as C's arrays of pointers and lengths.
    private static func withBuffers<T>(_ buffers: [Data], _ body: (UnsafePointer<UnsafePointer<UInt8>?>?, UnsafePointer<Int>?) -> T) -> T {
        let pointers = buffers.map { data -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(data.count, 1))
            data.copyBytes(to: pointer, count: data.count)
            return pointer
        }
        defer { pointers.forEach { $0.deallocate() } }
        let lengths = buffers.map(\.count)
        return pointers.map { UnsafePointer($0) as UnsafePointer<UInt8>? }.withUnsafeBufferPointer { pointers in
            lengths.withUnsafeBufferPointer { body(pointers.baseAddress, $0.baseAddress) }
        }
    }

    /// The bytes a C function hands over (it sets the length), copied and freed.
    static func output(_ call: (inout Int) -> UnsafeMutablePointer<UInt8>?) -> Data? {
        var length = 0
        guard let pointer = call(&length) else { return nil }
        defer { airscp_pki_free(pointer) }
        return Data(bytes: pointer, count: length)
    }

    // MARK: New requests and self-signed certificates

    /// The key a new request or certificate gets (the order of airscp_pki.h's key types).
    public enum KeyType: Int32, CaseIterable, Identifiable {
        case rsa2048 = 1, rsa3072, rsa4096, ecP256, ecP384, ed25519

        public var id: Int32 { rawValue }
        public var title: String { ["RSA 2048", "RSA 3072", "RSA 4096", "EC P-256", "EC P-384", "Ed25519"][Int(rawValue) - 1] }
        var isRSA: Bool { rawValue <= 3 }
        /// openssl req's -newkey for it.
        var openssl: String {
            ["rsa:2048", "rsa:3072", "rsa:4096", "ec -pkeyopt ec_paramgen_curve:P-256", "ec -pkeyopt ec_paramgen_curve:P-384",
             "ed25519"][Int(rawValue) - 1]
        }
    }

    /// A certificate request, or a self-signed certificate for a TLS server: who it is for, the names it covers, its key.
    public struct NewCertificate: Equatable {
        public var selfSigned = false
        public var commonName = "", organization = "", unit = "", locality = "", state = "", country = ""
        /// More host names and IP addresses, between commas, spaces or lines.
        public var otherNames = ""
        public var keyType = KeyType.rsa2048
        /// How long a self-signed certificate is valid.
        public var days = 365

        public init() {}

        /// The subject's fields that are filled in, the most general first (as openssl's -subj lists them).
        var subject: [(field: String, value: String)] {
            [("C", country), ("ST", state), ("L", locality), ("O", organization), ("OU", unit), ("CN", commonName)].map {
                ($0, $1.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespaces))
            }.filter { !$0.1.isEmpty }
        }

        /// The names it is for (subject alternative names): the common name first when it is a host name or an address.
        public var names: [String] {
            let common = commonName.trimmingCharacters(in: .whitespaces)
            var names = isHostName(common) || isAddress(common) ? [common] : []
            for name in otherNames.components(separatedBy: CharacterSet(charactersIn: ", \t\r\n")) where !name.isEmpty && !names.contains(name) {
                names.append(name)
            }
            return names
        }

        /// What keeps it from being made, in plain words; nil when nothing does.
        public var problem: String? {
            if commonName.trimmingCharacters(in: .whitespaces).isEmpty { return "Type a common name: usually the server's host name" }
            let limits = [("CN", "The common name", 64), ("O", "The organization", 64), ("OU", "The unit", 64), ("L", "The city", 128),
                          ("ST", "The state", 128)]
            for (field, label, limit) in limits where (subject.first { $0.field == field }?.value.count ?? 0) > limit {
                return "\(label) has \(limit) characters at most"
            }
            if let country = subject.first(where: { $0.field == "C" })?.value, country.count != 2 || !country.allSatisfy({ $0.isASCII && $0.isLetter }) {
                return "The country is two letters, such as US or DE"
            }
            if let wrong = names.first(where: { !isHostName($0) && !isAddress($0) }) { return "“\(wrong)” isn't a host name or an IP address" }
            if selfSigned && !(1...36500).contains(days) { return "Type how many days it is valid: 1 to 36500" }
            return nil
        }

        /// The extensions, as openssl's -addext takes them: the names, and for a self-signed certificate what a TLS
        /// server's needs (not a certificate authority; signing, and for RSA key exchange; server authentication).
        var extensions: [String] {
            var lines = names.isEmpty ? [] : ["subjectAltName=" + names.map { (isAddress($0) ? "IP:" : "DNS:") + $0 }.joined(separator: ",")]
            if selfSigned {
                lines += ["basicConstraints=critical,CA:FALSE",
                          "keyUsage=critical,digitalSignature" + (keyType.isRSA ? ",keyEncipherment" : ""),
                          "extendedKeyUsage=serverAuth"]
            }
            return lines
        }

        /// openssl's -subj: "/C=US/O=Example/CN=web.example.com".
        var subjectLine: String {
            subject.map { "/\($0.field)=" + $0.value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "/", with: "\\/")
                .replacingOccurrences(of: "+", with: "\\+") }.joined()
        }

        /// A new key, and the request or certificate made with it; nil when OpenSSL refuses (`problem` says why first).
        /// An RSA 4096 key takes a moment.
        public func make() -> (key: Item, item: Item)? {
            guard problem == nil, let key = output({ airscp_pki_new_key(keyType.rawValue, &$0) }) else { return nil }
            let lines = subject.map { "\($0.field)=\($0.value)" }.joined(separator: "\n")
            let made = key.withUnsafeBytes { bytes in
                output { airscp_pki_new_certificate(bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count, lines,
                                                    extensions.joined(separator: "\n"), selfSigned ? Int32(days) : 0, &$0) }
            }
            return made.map { (Item(kind: .privateKey, der: key), Item(kind: selfSigned ? .certificate : .request, der: $0)) }
        }
    }

    /// A host name a certificate can hold: letters, digits and hyphens between dots, "*." first for a wildcard.
    static func isHostName(_ name: String) -> Bool {
        let labels = (name.hasPrefix("*.") ? String(name.dropFirst(2)) : name).split(separator: ".", omittingEmptySubsequences: false)
        return !name.isEmpty && name.count <= 253 && labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && !label.hasPrefix("-") && !label.hasSuffix("-")
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
    }

    static func isAddress(_ text: String) -> Bool {
        var bytes = [UInt8](repeating: 0, count: 16)
        return inet_pton(AF_INET, text, &bytes) == 1 || inet_pton(AF_INET6, text, &bytes) == 1
    }

    // MARK: Checking a chain

    /// What checking a certificate's chain found.
    public enum ChainCheck: Equatable {
        /// It leads to a trusted certificate authority (`authority`: that one's name).
        case valid(authority: String)
        /// It, or a certificate above it, has expired or isn't valid yet.
        case expired
        /// It doesn't lead to a trusted authority: an issuer is missing, or the top one isn't trusted.
        case unknownIssuer
        /// It isn't for the host name.
        case nameMismatch
        /// Another reason, in the system's words.
        case invalid(String)
    }

    /// Checks `certificate`, with `others` to build its chain from, against `authorities` (nil: those this Mac trusts),
    /// for `host` when one is given (as a TLS client does), at `date`. Nothing is fetched from the network.
    public static func verify(_ certificate: Item, others: [Item], authorities: [Item]?, host: String?, at date: Date = Date()) -> ChainCheck {
        let host = (host ?? "").trimmingCharacters(in: .whitespaces)
        let policy = host.isEmpty ? SecPolicyCreateBasicX509() : SecPolicyCreateSSL(true, host as CFString)
        var made: SecTrust?
        guard certificate.kind == .certificate, let leaf = SecCertificateCreateWithData(nil, certificate.der as CFData),
              SecTrustCreateWithCertificates(([leaf] + others.filter { $0.kind == .certificate && $0.der != certificate.der }
                .compactMap { SecCertificateCreateWithData(nil, $0.der as CFData) }) as CFArray, policy, &made) == errSecSuccess,
              let trust = made else {
            return .invalid("This Mac can't read the certificate")
        }
        SecTrustSetNetworkFetchAllowed(trust, false)
        SecTrustSetVerifyDate(trust, date as CFDate)
        if let authorities {
            SecTrustSetAnchorCertificates(trust, authorities.compactMap { SecCertificateCreateWithData(nil, $0.der as CFData) } as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
        }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            let top = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.last
            return .valid(authority: top.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "")
        }
        switch OSStatus(truncatingIfNeeded: error.map(CFErrorGetCode) ?? 0) {
        case errSecCertificateExpired, errSecCertificateNotValidYet: return .expired
        case errSecHostNameMismatch: return .nameMismatch
        case errSecNotTrusted, errSecCreateChainFailed: return .unknownIssuer
        default: return .invalid(error.map { CFErrorCopyDescription($0) as String } ?? "no reason given")
        }
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
        /// openssl asks for the key's passphrase itself when there is one (-nodes: none).
        public static func newCertificate(_ new: NewCertificate, key: String, output: String, passphrase: Bool) -> String {
            "openssl req " + (new.selfSigned ? "-x509 -days \(new.days)" : "-new") + " -newkey \(new.keyType.openssl) -keyout \(q(key))"
                + " -out \(q(output)) -subj \(q(new.subjectLine))" + new.extensions.map { " -addext " + q($0) }.joined()
                + (new.keyType == .ed25519 ? "" : " -sha256") + (passphrase ? "" : " -nodes")
        }
        /// A PKCS#12 file first, then keytool's conversion (keytool asks for the passwords).
        public static func jks(key: String, certificate: String, alias: String, output: String) -> String {
            "openssl pkcs12 -export -inkey \(q(key)) -in \(q(certificate)) -name \(q(alias)) -out keystore.p12 && keytool -importkeystore"
                + " -srckeystore keystore.p12 -srcstoretype PKCS12 -destkeystore \(q(output)) -deststoretype JKS"
        }
        /// One keytool import per certificate (each saved as <alias>.pem); keytool asks for the password.
        public static func truststore(aliases: [String], output: String, jks: Bool) -> String {
            aliases.map { "keytool -importcert -noprompt -alias \(q($0)) -file \(q($0 + ".pem")) -keystore \(q(output))"
                + " -storetype \(jks ? "JKS" : "PKCS12")" }.joined(separator: " && ")
        }
        /// Against `authorities` (a CA bundle), else openssl's own trusted certificates; `chain`: the other certificates.
        public static func verify(_ file: String, chain: Bool, authorities: String?, host: String?) -> String {
            "openssl verify" + (authorities.map { " -CAfile \(q($0))" } ?? "") + (chain ? " -untrusted chain.pem" : "")
                + (host.map { " -purpose sslserver -verify_hostname \(q($0))" } ?? "") + " " + q(file)
        }
        public static func q(_ word: String) -> String { Quote.shellWord(word) }
    }
}

// MARK: Java keystores

/// Java's JKS keystore: its trusted certificates and its private keys (with their chains), the file's integrity checked
/// with the store password and each key opened with it (Java's own key protection); and written the same way. The
/// format prescribes SHA-1 for both: AirSCP writes it only when asked for JKS (PKCS#12 is the modern choice).
enum JKS {
    static func read(_ data: Data, password: String?, keyPassword: String?) throws -> [PKI.Item] {
        guard let password else { throw PKI.ReadError.password }
        let bytes = [UInt8](data)
        guard bytes.count > 32 else { throw PKI.ReadError.unknown }
        // The last 20 bytes: SHA-1 over the password (UTF-16BE), "Mighty Aphrodite" and the rest.
        let body = bytes.dropLast(20)
        let secret = JKS.secret(password)
        guard digest(Array(body), secret: secret) == Array(bytes.suffix(20)) else { throw PKI.ReadError.password }
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
                let keySecret = keyPassword.map(JKS.secret)
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

    /// A password as Java turns it into bytes for the keystore: UTF-16, big-endian.
    static func secret(_ password: String) -> [UInt8] { Array(password.utf16.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }) }

    /// The integrity digest at the end of the file: SHA-1 over the password, "Mighty Aphrodite" and the rest.
    static func digest(_ body: [UInt8], secret: [UInt8]) -> [UInt8] {
        var hasher = Insecure.SHA1()
        hasher.update(data: secret)
        hasher.update(data: Array("Mighty Aphrodite".utf8))
        hasher.update(data: body)
        return Array(hasher.finalize())
    }

    /// An entry to write: a private key (PKCS#8) with its chain (its certificate first), or a trusted certificate
    /// (no key, one certificate).
    struct Entry {
        let alias: String
        let key: Data?
        let chain: [Data]
    }

    /// A version 2 keystore of `entries`, the keys protected with `password` too (as keytool does by default).
    static func write(_ entries: [Entry], password: String, date: Date = Date()) -> Data {
        let secret = JKS.secret(password)
        var out: [UInt8] = []
        func uint32(_ value: UInt32) { out += withUnsafeBytes(of: value.bigEndian, Array.init) }
        func certificate(_ der: Data) {
            utf("X.509")
            uint32(UInt32(der.count))
            out += der
        }
        // Java's writeUTF: a two-byte length, then modified UTF-8 of the UTF-16 units (no 4-byte sequences, U+0000 in two).
        func utf(_ text: String) {
            let bytes = text.utf16.flatMap { unit -> [UInt8] in
                switch unit {
                case 0x01...0x7F: return [UInt8(unit)]
                case 0...0x7FF: return [UInt8(0xC0 | unit >> 6), UInt8(0x80 | unit & 0x3F)]
                default: return [UInt8(0xE0 | unit >> 12), UInt8(0x80 | unit >> 6 & 0x3F), UInt8(0x80 | unit & 0x3F)]
                }
            }.prefix(0xFFFF)
            out += [UInt8(bytes.count >> 8), UInt8(bytes.count & 0xFF)] + bytes
        }
        uint32(0xFEEDFEED)
        uint32(2)
        uint32(UInt32(entries.count))
        let milliseconds = UInt64(max(0, date.timeIntervalSince1970 * 1000))
        for entry in entries {
            uint32(entry.key == nil ? 2 : 1)
            utf(entry.alias)
            out += withUnsafeBytes(of: milliseconds.bigEndian, Array.init)
            if let key = entry.key {
                let sealed = seal(key, secret: secret)
                uint32(UInt32(sealed.count))
                out += sealed
                uint32(UInt32(entry.chain.count))
                entry.chain.forEach(certificate)
            } else if let trusted = entry.chain.first {
                certificate(trusted)
            }
        }
        return Data(out + digest(out, secret: secret))
    }

    /// Java's KeyProtector, the other way from `open`: a random salt, the key XORed with the SHA-1 stream of password
    /// and salt, and the SHA-1 check of password and key, in an EncryptedPrivateKeyInfo with Sun's algorithm number.
    static func seal(_ key: Data, secret: [UInt8], salt: [UInt8] = (0..<20).map { _ in UInt8.random(in: 0...255) }) -> [UInt8] {
        var stream: [UInt8] = [], digest = salt
        while stream.count < key.count {
            digest = Array(Insecure.SHA1.hash(data: secret + digest))
            stream += digest
        }
        let protected = salt + zip(key, stream).map { $0 ^ $1 } + Array(Insecure.SHA1.hash(data: secret + Array(key)))
        // SEQUENCE { SEQUENCE { OID 1.3.6.1.4.1.42.2.17.1.1, NULL }, OCTET STRING }
        let algorithm: [UInt8] = [0x30, 0x0E, 0x06, 0x0A, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x2A, 0x02, 0x11, 0x01, 0x01, 0x05, 0x00]
        return DER.encode(0x30, algorithm + DER.encode(0x04, protected))
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

    /// Just enough DER to take apart and put together an EncryptedPrivateKeyInfo.
    struct DER {
        var bytes: [UInt8]
        var rest: [UInt8] { bytes }

        /// `tag`, the length (short or long form) and `body`.
        static func encode(_ tag: UInt8, _ body: [UInt8]) -> [UInt8] {
            guard body.count >= 0x80 else { return [tag, UInt8(body.count)] + body }
            let length = withUnsafeBytes(of: UInt32(body.count).bigEndian, Array.init).drop { $0 == 0 }
            return [tag, 0x80 | UInt8(length.count)] + length + body
        }

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
