import AppKit
import Foundation
import Testing
@testable import AirSCP
@testable import AirSCPCore

// MARK: The Certificate Manager: interop with openssl and keytool, test-only

/// A tool on this Mac (test-only: the app uses neither), nil when it isn't there.
private func tool(_ name: String, versionContains: String? = nil) -> String? {
    for folder in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", (ProcessInfo.processInfo.environment["JAVA_HOME"] ?? "") + "/bin",
                   NSHomeDirectory() + "/.sdkman/candidates/java/current/bin"] {
        let path = folder + "/" + name
        guard FileManager.default.isExecutableFile(atPath: path) else { continue }
        if let versionContains {
            guard (try? run(path, ["version"]))?.contains(versionContains) == true else { continue }
        }
        return path
    }
    return nil
}

@discardableResult
private func run(_ path: String, _ arguments: [String], in folder: String? = nil) throws -> String {
    let process = Process(), pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    if let folder { process.currentDirectoryURL = URL(fileURLWithPath: folder) }
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw AirSCPError(.other, "\(path) \(arguments.joined(separator: " ")): \(output)") }
    return output
}

private let openssl = tool("openssl", versionContains: "OpenSSL 3")

/// keytool, when a Java runtime is there: without one, macOS's /usr/bin/keytool is only a stub that asks to install one.
private let keytool = tool("keytool").flatMap { path in
    path != "/usr/bin/keytool" || (try? run("/usr/libexec/java_home", [])) != nil ? path : nil
}

/// A CA, a server certificate it signed (SANs, key usages), their keys, a request, and containers of them, made by
/// openssl in a scratch folder.
private func fixtures() throws -> String {
    let folder = try scratch(), o = try #require(openssl)
    func s(_ arguments: String) throws { try run(o, arguments.components(separatedBy: " "), in: folder) }
    try "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n".write(toFile: folder + "/ca.ext", atomically: true, encoding: .utf8)
    try "subjectAltName=DNS:web.example.com,DNS:www.example.com,IP:10.0.0.5,IP:2001:db8::1\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth\n"
        .write(toFile: folder + "/leaf.ext", atomically: true, encoding: .utf8)
    try s("genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out ca.key")
    try s("req -new -x509 -key ca.key -subj /O=Example/CN=Example-Root-CA -days 3650 -out ca.pem -addext basicConstraints=critical,CA:TRUE,pathlen:0 -addext keyUsage=critical,keyCertSign,cRLSign")
    try s("genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out leaf.key")
    try s("req -new -key leaf.key -subj /O=Example/CN=web.example.com -addext subjectAltName=DNS:web.example.com -out leaf.csr")
    try s("x509 -req -in leaf.csr -CA ca.pem -CAkey ca.key -set_serial 0x1234 -days 30 -extfile leaf.ext -out leaf.pem")
    try s("x509 -in leaf.pem -outform DER -out leaf.der")
    try s("crl2pkcs7 -nocrl -certfile leaf.pem -certfile ca.pem -out chain.p7b")
    try s("pkcs12 -export -inkey leaf.key -in leaf.pem -certfile ca.pem -name web -passout pass:secret -out leaf.p12")
    try s("pkcs12 -export -inkey leaf.key -in leaf.pem -certfile ca.pem -name web -passout pass:secret -legacy -out legacy.p12")
    try s("pkey -in ca.key -aes256 -passout pass:keypass -out ca-encrypted.key")
    try s("pkey -in ca.key -traditional -out ca-rsa.key")
    try s("genpkey -algorithm ED25519 -out ed.key")
    try s("pkey -in ed.key -pubout -out ed.pub")
    // A bundle: the CA after the leaf, in one file with a key, as servers often keep them.
    let bundle = try String(contentsOfFile: folder + "/ca.pem") + "\n" + String(contentsOfFile: folder + "/leaf.pem")
    try bundle.write(toFile: folder + "/bundle.pem", atomically: true, encoding: .utf8)
    return folder
}

private func items(_ path: String, password: String? = nil) throws -> [PKI.Item] {
    try PKI.read(try Data(contentsOf: URL(fileURLWithPath: path)), password: password)
}

@Test(.enabled(if: openssl != nil, "needs OpenSSL 3's openssl (test-only)"))
func certificateManagerReadsEveryFormat() throws {
    let f = try fixtures()
    // PEM, with its details.
    let leaf = try #require(try items(f + "/leaf.pem").first)
    let details = PKI.details(leaf)
    #expect(PKI.Details.commonName(details.subject) == "web.example.com" && PKI.Details.commonName(details.issuer) == "Example-Root-CA")
    #expect(details.sans == ["DNS:web.example.com", "DNS:www.example.com", "IP:10.0.0.5", "IP:2001:db8:0:0:0:0:0:1"])
    #expect(details.first("serial") == "1234" && details.key == "EC 256 (prime256v1)" && !details.isCA && !details.selfIssued)
    #expect(details.first("keyUsage") == "Digital Signature, Key Encipherment")
    #expect(details.first("extendedKeyUsage") == "TLS Server, TLS Client")
    #expect(details.first("signature") == "sha256WithRSAEncryption")
    #expect((PKI.daysLeft(details) ?? 0) >= 29 && (PKI.daysLeft(details) ?? 0) <= 30)
    let fingerprint = try run(try #require(openssl), ["x509", "-in", f + "/leaf.pem", "-noout", "-fingerprint", "-sha256"])
    #expect(fingerprint.contains(PKI.fingerprint(leaf.der)))
    #expect(PKI.title(leaf) == "Certificate: web.example.com")
    let ca = try #require(try items(f + "/ca.pem").first)
    #expect(PKI.details(ca).isCA && PKI.details(ca).selfIssued && PKI.details(ca).first("pathLength") == "0")
    #expect(PKI.title(ca) == "CA certificate: Example-Root-CA")
    // DER, PKCS#7, a bundle in the wrong order: chain order puts the leaf first.
    #expect(try items(f + "/leaf.der") == [leaf])
    #expect(try items(f + "/chain.p7b").map(\.der) == [leaf.der, ca.der])
    let bundle = try items(f + "/bundle.pem")
    #expect(bundle.map(\.der) == [ca.der, leaf.der] && PKI.chainOrder(bundle).map(\.der) == [leaf.der, ca.der])
    #expect(PKI.signed(leaf, by: ca) && !PKI.signed(ca, by: leaf))
    // PKCS#12, modern and legacy: a password, then the key, its certificate (with its friendly name) and the chain.
    // openssl -legacy's RC2-40 (OpenSSL here is built without the legacy provider): said so, not taken for a bad password.
    #expect(throws: PKI.ReadError.password) { try items(f + "/legacy.p12", password: "wrong") }
    #expect { try items(f + "/legacy.p12", password: "secret") } throws: { error in
        if case PKI.ReadError.unsupported(let what) = error { return what.hasPrefix("RC2-40") }
        return false
    }
    try run(try #require(openssl), ["pkcs12", "-export", "-inkey", f + "/leaf.key", "-in", f + "/leaf.pem", "-certfile", f + "/ca.pem",
                                     "-name", "web", "-passout", "pass:secret", "-legacy", "-certpbe", "PBE-SHA1-3DES", "-out", f + "/3des.p12"])
    for file in ["leaf.p12", "3des.p12"] {
        #expect(throws: PKI.ReadError.password) { try items(f + "/" + file) }
        #expect(throws: PKI.ReadError.password) { try items(f + "/" + file, password: "wrong") }
        let inside = try items(f + "/" + file, password: "secret")
        #expect(inside.map(\.kind) == [.privateKey, .certificate, .certificate], "\(file)")
        #expect(inside[1].der == leaf.der && inside[1].name == "web" && inside[2].der == ca.der)
        #expect(PKI.matches(inside[0], leaf) && !PKI.matches(inside[0], ca))
    }
    // Keys: encrypted PKCS#8, PKCS#1, Ed25519 and its public key; a request.
    #expect(throws: PKI.ReadError.password) { try items(f + "/ca-encrypted.key") }
    let caKey = try #require(try items(f + "/ca-encrypted.key", password: "keypass").first)
    #expect(caKey.kind == .privateKey && PKI.details(caKey).key == "RSA 2048" && PKI.matches(caKey, ca))
    #expect(try items(f + "/ca-rsa.key").first?.der == caKey.der)
    let edPublic = try #require(try items(f + "/ed.pub").first), edKey = try #require(try items(f + "/ed.key").first)
    #expect(edPublic.kind == .publicKey && PKI.matches(edKey, edPublic) && PKI.title(edKey) == "Private key: Ed25519")
    let request = try #require(try items(f + "/leaf.csr").first)
    #expect(request.kind == .request && PKI.details(request).first("verified") == "yes" && PKI.details(request).sans == ["DNS:web.example.com"])
    let leafKey = try #require(try items(f + "/leaf.key").first)
    #expect(PKI.matches(leafKey, request))
    // Not a certificate file.
    #expect(throws: PKI.ReadError.unknown) { try PKI.read(Data("hello".utf8)) }
}

@Test(.enabled(if: openssl != nil, "needs OpenSSL 3's openssl (test-only)"))
func certificateManagerWritesWhatOpensslReads() throws {
    let f = try fixtures(), o = try #require(openssl)
    let leaf = try #require(try items(f + "/leaf.pem").first), ca = try #require(try items(f + "/ca.pem").first)
    let key = try #require(try items(f + "/leaf.key").first)
    // PEM and DER of a certificate.
    try PKI.pem(leaf).write(toFile: f + "/out.pem", atomically: true, encoding: .utf8)
    #expect(try run(o, ["x509", "-in", f + "/out.pem", "-noout", "-subject"]).contains("web.example.com"))
    // PKCS#12, modern and legacy, read back by openssl with the chain and the name.
    for legacy in [false, true] {
        let p12 = try #require(PKI.pkcs12(key: key, certificate: leaf, chain: [ca], name: "web", password: "pw", legacy: legacy))
        try p12.write(to: URL(fileURLWithPath: f + "/out.p12"))
        let dump = try run(o, ["pkcs12", "-in", f + "/out.p12", "-passin", "pass:pw", "-nodes", "-info"] + (legacy ? ["-legacy"] : []))
        #expect(dump.contains("friendlyName: web") && dump.contains("Example-Root-CA") && dump.contains("PRIVATE KEY"), "\(dump)")
        #expect(dump.contains(legacy ? "pbeWithSHA1And3-KeyTripleDES-CBC" : "AES-256-CBC"), "\(dump)")
        // A MAC proves the password and that nothing changed: SHA-1 for older systems (1.1.0 wrote theirs without one).
        #expect(dump.contains(legacy ? "MAC: sha1, Iteration 2048" : "MAC: sha256, Iteration 2048"), "\(dump)")
        #expect(try PKI.read(p12, password: "pw").count == 3)
    }
    // Keys: encrypted PKCS#8, PKCS#8, traditional; public key.
    let encrypted = try #require(PKI.keyPEM(key, passphrase: "kp"))
    #expect(encrypted.hasPrefix("-----BEGIN ENCRYPTED PRIVATE KEY-----"))
    try encrypted.write(toFile: f + "/out.key", atomically: true, encoding: .utf8)
    #expect(try run(o, ["pkey", "-in", f + "/out.key", "-passin", "pass:kp", "-noout", "-text"]).contains("prime256v1"))
    #expect(PKI.keyPEM(key)?.hasPrefix("-----BEGIN PRIVATE KEY-----") == true)
    #expect(PKI.keyPEM(key, traditional: true)?.hasPrefix("-----BEGIN EC PRIVATE KEY-----") == true)
    let publicKey = PKI.pem(try #require(PKI.publicKey(leaf)), label: "PUBLIC KEY")
    let expected = try run(o, ["x509", "-in", f + "/leaf.pem", "-noout", "-pubkey"])
    #expect(publicKey == expected)
    // The command shown for each action names the files, quoted.
    #expect(PKI.Command.pkcs12(key: "my key.pem", certificate: "c.pem", output: "o.p12", legacy: true)
            == "openssl pkcs12 -export -inkey 'my key.pem' -in c.pem -out o.p12 -legacy")
}

@Test(.enabled(if: openssl != nil && keytool != nil, "needs openssl and keytool (test-only)"))
func certificateManagerReadsJavaKeystores() throws {
    let f = try fixtures(), keytool = try #require(keytool)
    try run(keytool, ["-importkeystore", "-srckeystore", f + "/leaf.p12", "-srcstoretype", "PKCS12", "-srcstorepass", "secret",
                      "-destkeystore", f + "/store.jks", "-deststoretype", "JKS", "-deststorepass", "storepass", "-noprompt"])
    try run(keytool, ["-importcert", "-alias", "root", "-file", f + "/ca.pem", "-keystore", f + "/store.jks", "-storepass",
                      "storepass", "-noprompt"])
    #expect(throws: PKI.ReadError.password) { try items(f + "/store.jks") }
    #expect(throws: PKI.ReadError.password) { try items(f + "/store.jks", password: "nope") }
    // The key kept the PKCS#12 file's password, as keytool does unless told otherwise: asked for, by its alias.
    #expect(throws: PKI.ReadError.keyPassword(alias: "web")) { try items(f + "/store.jks", password: "storepass") }
    let inside = try PKI.read(try Data(contentsOf: URL(fileURLWithPath: f + "/store.jks")), password: "storepass", keyPassword: "secret")
    let leaf = try #require(try items(f + "/leaf.pem").first), key = try #require(try items(f + "/leaf.key").first)
    let byAlias = Dictionary(grouping: inside, by: { $0.name ?? "" })
    #expect(Set(byAlias.keys) == ["web", "root"], "\(inside.map { ($0.name ?? "", $0.kind) })")
    let stored = try #require(byAlias["web"]?.first)
    #expect(stored.kind == .privateKey && PKI.matches(stored, leaf))
    #expect(byAlias["web"]?.contains { $0.der == leaf.der } == true && byAlias["root"]?.first?.kind == .certificate)
    #expect(PKI.details(stored).key == PKI.details(key).key)
}

/// View Server Certificate: the chain a TLS server sends (here openssl's s_server on this Mac, with the test CA's
/// certificate for web.example.com), and this Mac's verdict (it doesn't trust that CA, nor the name 127.0.0.1).
@MainActor @Test(.enabled(if: openssl != nil, "needs OpenSSL 3's openssl (test-only)"))
func certificateManagerShowsAServersChain() async throws {
    let f = try fixtures(), o = try #require(openssl)
    let port = Int.random(in: 40000...49000)
    let server = Process()
    server.executableURL = URL(fileURLWithPath: o)
    server.arguments = ["s_server", "-accept", "127.0.0.1:\(port)", "-cert", f + "/leaf.pem", "-key", f + "/leaf.key",
                        "-cert_chain", f + "/ca.pem", "-quiet", "-naccept", "1"]
    server.standardOutput = FileHandle.nullDevice
    server.standardError = FileHandle.nullDevice
    try server.run()
    defer { server.terminate() }
    try await Task.sleep(nanoseconds: 500_000_000)
    let (certificates, trust) = try await CertificateModel.serverChain(host: "127.0.0.1", port: port)
    let leaf = try #require(try items(f + "/leaf.pem").first), ca = try #require(try items(f + "/ca.pem").first)
    #expect(certificates == [leaf.der, ca.der])
    #expect(trust.hasPrefix("This Mac doesn't trust it"), "\(trust)")
    #expect(CertificateManagerView.hostAndPort("ldap.example.com:636") == ("ldap.example.com", 636))
    #expect(CertificateManagerView.hostAndPort("https://example.com/path") == ("example.com", 443))
    #expect(CertificateManagerView.hostAndPort("[::1]:8443") == ("::1", 8443) && CertificateManagerView.hostAndPort("example.com") == ("example.com", 443))
}

// MARK: New requests and certificates, keystores, truststores and chain checks

/// LibreSSL's openssl, which every Mac has: enough to check what AirSCP makes.
private let libressl = FileManager.default.isExecutableFile(atPath: "/usr/bin/openssl") ? "/usr/bin/openssl" : nil

/// A test certificate authority and a server certificate it signed for web.example.com (30 days), from a request made
/// here: LibreSSL signs it as an authority would.
private func signedByATestAuthority() throws -> (folder: String, ca: PKI.Item, leaf: PKI.Item, key: PKI.Item) {
    let folder = try scratch(), o = try #require(libressl)
    try run(o, ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", "ca.key", "-out", "ca.pem", "-subj", "/O=Example/CN=Example-Root-CA",
                "-days", "3650", "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign"], in: folder)
    var new = PKI.NewCertificate()
    new.commonName = "web.example.com"
    new.keyType = .ecP256
    let (key, request) = try #require(new.make())
    try PKI.pem(request).write(toFile: folder + "/web.csr", atomically: true, encoding: .utf8)
    try "subjectAltName=DNS:web.example.com\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\n"
        .write(toFile: folder + "/web.ext", atomically: true, encoding: .utf8)
    try run(o, ["x509", "-req", "-in", "web.csr", "-CA", "ca.pem", "-CAkey", "ca.key", "-CAcreateserial", "-days", "30", "-extfile", "web.ext",
                "-out", "web.pem"], in: folder)
    return (folder, try #require(try items(folder + "/ca.pem").first), try #require(try items(folder + "/web.pem").first), key)
}

@Test(.enabled(if: libressl != nil, "needs /usr/bin/openssl (test-only)"))
func newRequestsAndSelfSignedCertificatesHaveWhatWasAskedFor() throws {
    let f = try scratch(), o = try #require(libressl)
    var new = PKI.NewCertificate()
    new.commonName = " web.example.com "
    new.organization = "Example / Test+Lab"
    new.country = "DE"
    new.otherNames = "www.example.com, 10.0.0.5\n2001:db8::1 www.example.com"
    new.keyType = .ecP256
    // A request: signed by its own key, which goes with it; the subject and the names (the common name first) in it.
    let (key, request) = try #require(new.make())
    #expect(request.kind == .request && key.kind == .privateKey && PKI.matches(key, request))
    let asked = PKI.details(request)
    #expect(asked.first("verified") == "yes" && asked.first("signature") == "ecdsa-with-SHA256")
    #expect(asked.subject == "C = DE, O = \"Example / Test+Lab\", CN = web.example.com", "\(asked.subject)")
    #expect(asked.sans == ["DNS:web.example.com", "DNS:www.example.com", "IP:10.0.0.5", "IP:2001:db8:0:0:0:0:0:1"])
    #expect(PKI.details(key).key == "EC 256 (prime256v1)")
    try PKI.pem(request).write(toFile: f + "/web.csr", atomically: true, encoding: .utf8)
    #expect(try run(o, ["req", "-in", f + "/web.csr", "-noout", "-verify"]).contains("verify OK"))
    // A self-signed certificate for a TLS server: its names, not an authority, signing and key exchange, server use.
    new.selfSigned = true
    new.days = 30
    new.keyType = .rsa2048
    let (rsaKey, certificate) = try #require(new.make())
    let made = PKI.details(certificate)
    #expect(certificate.kind == .certificate && PKI.matches(rsaKey, certificate) && PKI.signed(certificate, by: certificate))
    #expect(made.selfIssued && !made.isCA && made.sans == asked.sans && made.first("signature") == "sha256WithRSAEncryption")
    #expect(made.first("keyUsage") == "Digital Signature, Key Encipherment" && made.first("extendedKeyUsage") == "TLS Server")
    #expect((29...30).contains(PKI.daysLeft(made) ?? 0) && PKI.title(certificate) == "Certificate: web.example.com")
    try PKI.pem(certificate).write(toFile: f + "/web.crt", atomically: true, encoding: .utf8)
    let text = try run(o, ["x509", "-in", f + "/web.crt", "-noout", "-text"])
    #expect(text.contains("X509v3 Basic Constraints: critical") && text.contains("CA:FALSE") && text.contains("X509v3 Key Usage: critical"))
    #expect(text.contains("Version: 3 (0x2)") && text.contains("Subject: C=DE, O=Example / Test+Lab, CN=web.example.com"), "\(text)")
    // Every key type; EC and Ed25519 keys only sign.
    for type in PKI.KeyType.allCases {
        new.keyType = type
        let (key, certificate) = try #require(new.make(), "\(type)")
        #expect(PKI.details(key).key.hasPrefix(type.title.components(separatedBy: " ")[0]), "\(type)")
        #expect(PKI.matches(key, certificate) && PKI.signed(certificate, by: certificate), "\(type)")
        #expect(PKI.details(certificate).first("keyUsage") == (type.title.hasPrefix("RSA") ? "Digital Signature, Key Encipherment" : "Digital Signature"))
    }
    #expect(PKI.details(try #require(new.make()).key).key == "Ed25519")
    // The command that does the same names the files, and never a passphrase.
    new.keyType = .ecP384
    #expect(PKI.Command.newCertificate(new, key: "web.key", output: "web crt.pem", passphrase: true)
            == "openssl req -x509 -days 30 -newkey ec -pkeyopt ec_paramgen_curve:P-384 -keyout web.key -out 'web crt.pem' -subj "
            + "'/C=DE/O=Example \\/ Test\\+Lab/CN=web.example.com' -addext "
            + "subjectAltName=DNS:web.example.com,DNS:www.example.com,IP:10.0.0.5,IP:2001:db8::1 -addext basicConstraints=critical,CA:FALSE "
            + "-addext keyUsage=critical,digitalSignature -addext extendedKeyUsage=serverAuth -sha256")
    new.selfSigned = false
    new.keyType = .ed25519
    #expect(PKI.Command.newCertificate(new, key: "k", output: "r.csr", passphrase: false).hasSuffix("-newkey ed25519 -keyout k -out r.csr -subj "
            + "'/C=DE/O=Example \\/ Test\\+Lab/CN=web.example.com' -addext "
            + "subjectAltName=DNS:web.example.com,DNS:www.example.com,IP:10.0.0.5,IP:2001:db8::1 -nodes"))
}

@Test func aNewCertificateSaysWhatIsMissingOrWrong() {
    var new = PKI.NewCertificate()
    #expect(new.problem == "Type a common name: usually the server's host name")
    new.commonName = "My Test Server"
    #expect(new.problem == nil && new.names.isEmpty)  // not a host name: it doesn't become one
    new.commonName = String(repeating: "a", count: 65)
    #expect(new.problem == "The common name has 64 characters at most")
    new.commonName = "*.example.com"
    #expect(new.problem == nil && new.names == ["*.example.com"])
    new.country = "Germany"
    #expect(new.problem == "The country is two letters, such as US or DE")
    new.country = "de"
    new.otherNames = "intranet, bad_name.example.com"
    #expect(new.problem == "“bad_name.example.com” isn't a host name or an IP address")
    new.otherNames = "-bad.example.com"
    #expect(new.problem == "“-bad.example.com” isn't a host name or an IP address")
    new.otherNames = "intranet 192.168.1.1 ::1"
    #expect(new.problem == nil && new.names == ["*.example.com", "intranet", "192.168.1.1", "::1"])
    new.selfSigned = true
    new.days = 0
    #expect(new.problem == "Type how many days it is valid: 1 to 36500")
    #expect(new.make() == nil)
}

@Test(.enabled(if: libressl != nil, "needs /usr/bin/openssl (test-only)"))
func newFilesAreSavedTogetherAndNeverOverAnother() throws {
    let f = try scratch()
    var new = PKI.NewCertificate()
    new.commonName = "web.example.com"
    new.keyType = .ecP256
    let (key, request) = try #require(new.make())
    let keyFile = f + "/web.key", requestFile = f + "/web.csr"
    try PKI.saveNew([(keyFile, Data(try #require(PKI.keyPEM(key, passphrase: "secret phrase")).utf8), 0o600),
                     (requestFile, Data(PKI.pem(request).utf8), 0o644)])
    #expect((try FileManager.default.attributesOfItem(atPath: keyFile)[.posixPermissions] as? Int) == 0o600)
    #expect(try items(keyFile, password: "secret phrase").first?.der == key.der)
    #expect(try items(requestFile).first == request)
    // A file that is there already stops both, and nothing is replaced or left behind.
    let other = f + "/other.key"
    #expect(throws: AirSCPError.self) {
        try PKI.saveNew([(other, Data("new".utf8), 0o600), (requestFile, Data("new".utf8), 0o644)])
    }
    let kept = try items(requestFile).first
    #expect(!FileManager.default.fileExists(atPath: other) && kept == request)
}

/// A key or keystore saved through a Save panel is its owner's alone from the moment the file exists, also in place of a
/// file that was there: someone who had that one open reads its old bytes, never the key.
@MainActor @Test func keysAndKeystoresAreSavedForTheirOwnerOnly() throws {
    _ = NSApplication.shared
    let folder = try scratch()
    let model = CertificateModel()
    defer {
        Panels.agentChoice = nil
        Panels.agentReplacing = nil
    }
    func mode(_ path: String) -> Int? { (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int }
    for name in ["private.key", "certificate.p12", "keystore.jks", "certificate.pem"] {
        let path = folder + "/" + name
        try write("old", to: path)
        chmod(path, 0o644)
        let earlier = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))  // opened before, as anyone on this Mac could
        defer { try? earlier.close() }
        Panels.agentChoice = [URL(fileURLWithPath: path)]
        model.save(name, types: [.data], command: { $0 }, from: nil) { Data("secret".utf8) }
        try #require(Panels.agentReplacing, "\(name)").save()  // the panel's Replace
        #expect(read(path) == "secret" && model.status == "Saved \(name)", "\(name): \(model.status ?? "")")
        if name != "certificate.pem" {
            #expect(mode(path) == 0o600 && String(decoding: earlier.readDataToEndOfFile(), as: UTF8.self) == "old", "\(name)")
        }
    }
    Panels.agentChoice = [URL(fileURLWithPath: folder + "/new.key")]
    model.save("new.key", types: [.data], command: { $0 }, from: nil) { Data("secret".utf8) }
    #expect(read(folder + "/new.key") == "secret" && mode(folder + "/new.key") == 0o600)
}

@Test(.enabled(if: libressl != nil, "needs /usr/bin/openssl (test-only)"))
func keystoresAndTruststoresRoundTrip() throws {
    let (f, ca, leaf, key) = try signedByATestAuthority()
    // PKCS#12: the key, its certificate and the chain come back as they went in.
    let p12 = try #require(PKI.pkcs12(key: key, certificate: leaf, chain: [ca], name: "web", password: "pw", legacy: false))
    #expect(try PKI.read(p12, password: "pw") == [PKI.Item(kind: .privateKey, der: key.der, name: "web"),
                                                  PKI.Item(kind: .certificate, der: leaf.der, name: "web"), PKI.Item(kind: .certificate, der: ca.der)])
    #expect(throws: PKI.ReadError.password) { try PKI.read(p12, password: "wrong") }
    // JKS: magic, version 2, the key entry with its chain; the integrity digest is checked with the password.
    let jks = PKI.jks(key: key, certificate: leaf, chain: [ca], name: "Web", password: "storepass")
    #expect(jks.prefix(8) == Data([0xFE, 0xED, 0xFE, 0xED, 0, 0, 0, 2]))
    #expect(try PKI.read(jks, password: "storepass") == [PKI.Item(kind: .privateKey, der: key.der, name: "web"),
                                                         PKI.Item(kind: .certificate, der: leaf.der, name: "web"),
                                                         PKI.Item(kind: .certificate, der: ca.der, name: "web")])
    #expect(throws: PKI.ReadError.password) { try PKI.read(jks, password: "wrong") }
    var damaged = jks
    damaged[40] ^= 1
    #expect(throws: PKI.ReadError.password) { try PKI.read(damaged, password: "storepass") }
    // Java's key protection, both ways, with a long key (more than one SHA-1 block of the stream) and a non-ASCII password.
    let sealed = JKS.seal(key.der, secret: JKS.secret("pässwörd"))
    #expect(try JKS.open(sealed, secret: JKS.secret("pässwörd")) == key.der)
    #expect(throws: PKI.ReadError.password) { try JKS.open(sealed, secret: JKS.secret("password")) }
    // Truststores: trusted entries named after their certificates, in JKS and in PKCS#12.
    let store = try #require(PKI.truststore([ca, leaf], password: "changeit", jks: true))
    #expect(try PKI.read(store, password: "changeit") == [PKI.Item(kind: .certificate, der: ca.der, name: "example-root-ca"),
                                                          PKI.Item(kind: .certificate, der: leaf.der, name: "web.example.com")])
    let trust12 = try #require(PKI.truststore([ca, leaf], password: "changeit", jks: false))
    #expect(try PKI.read(trust12, password: "changeit").map(\.der) == [ca.der, leaf.der])
    #expect(PKI.aliases([ca, ca, leaf]) == ["example-root-ca", "example-root-ca-2", "web.example.com"])
    // LibreSSL reads both PKCS#12 files: the MAC, the names.
    try trust12.write(to: URL(fileURLWithPath: f + "/trust.p12"))
    let dump = try run(try #require(libressl), ["pkcs12", "-in", f + "/trust.p12", "-passin", "pass:changeit", "-nokeys", "-info"])
    #expect(dump.contains("MAC Iteration 2048") && dump.contains("friendlyName: example-root-ca") && dump.contains("friendlyName: web.example.com"),
            "\(dump)")
    #expect(PKI.Command.truststore(aliases: ["root ca"], output: "t.jks", jks: true)
            == "keytool -importcert -noprompt -alias 'root ca' -file 'root ca.pem' -keystore t.jks -storetype JKS")
}

@Test(.enabled(if: libressl != nil && keytool != nil, "needs /usr/bin/openssl and a Java runtime's keytool (test-only)"))
func keytoolReadsTheKeystoresAndTruststoresAirSCPWrites() throws {
    let (f, ca, leaf, key) = try signedByATestAuthority(), keytool = try #require(keytool)
    try PKI.jks(key: key, certificate: leaf, chain: [ca], name: "web", password: "storepass").write(to: URL(fileURLWithPath: f + "/web.jks"))
    let listed = try run(keytool, ["-list", "-v", "-keystore", f + "/web.jks", "-storetype", "JKS", "-storepass", "storepass"])
    #expect(listed.contains("Alias name: web") && listed.contains("PrivateKeyEntry") && listed.contains("Certificate chain length: 2"), "\(listed)")
    // keytool opens the key with the password (its own key protection) to copy it into a PKCS#12 file.
    try run(keytool, ["-importkeystore", "-srckeystore", f + "/web.jks", "-srcstoretype", "JKS", "-srcstorepass", "storepass",
                      "-destkeystore", f + "/web.p12", "-deststoretype", "PKCS12", "-deststorepass", "otherpass", "-noprompt"])
    let back = try PKI.read(try Data(contentsOf: URL(fileURLWithPath: f + "/web.p12")), password: "otherpass")
    #expect(back.contains { $0.kind == .privateKey && $0.der == key.der } || back.contains { $0.kind == .privateKey && PKI.matches($0, leaf) })
    for jks in [true, false] {
        let file = f + (jks ? "/trust.jks" : "/trust.p12")
        try #require(PKI.truststore([ca, leaf], password: "changeit", jks: jks)).write(to: URL(fileURLWithPath: file))
        let entries = try run(keytool, ["-list", "-keystore", file, "-storepass", "changeit"])
        #expect(entries.contains("Your keystore contains 2 entries") && entries.contains("example-root-ca")
                && entries.components(separatedBy: "trustedCertEntry").count == 3, "\(entries)")
    }
}

@Test(.enabled(if: libressl != nil, "needs /usr/bin/openssl (test-only)"))
func chainsAreCheckedAgainstAChosenAuthorityOrThisMacs() throws {
    let (_, ca, leaf, _) = try signedByATestAuthority()
    #expect(PKI.verify(leaf, others: [], authorities: [ca], host: nil) == .valid(authority: "Example-Root-CA"))
    #expect(PKI.verify(leaf, others: [ca], authorities: [ca], host: "web.example.com") == .valid(authority: "Example-Root-CA"))
    #expect(PKI.verify(leaf, others: [], authorities: [ca], host: "mail.example.com") == .nameMismatch)
    #expect(PKI.verify(leaf, others: [], authorities: [ca], host: nil, at: Date().addingTimeInterval(60 * 86400)) == .expired)
    // This Mac doesn't trust the test authority, even when its certificate is open beside the server's.
    #expect(PKI.verify(leaf, others: [ca], authorities: nil, host: "web.example.com") == .unknownIssuer)
    // Another authority's bundle.
    var other = PKI.NewCertificate()
    other.commonName = "other.example.com"
    other.selfSigned = true
    other.keyType = .ecP256
    let (_, otherCertificate) = try #require(other.make())
    #expect(PKI.verify(leaf, others: [], authorities: [otherCertificate], host: nil) == .unknownIssuer)
    // A self-signed certificate made here is valid where it is trusted itself.
    #expect(PKI.verify(otherCertificate, others: [], authorities: [otherCertificate], host: "other.example.com")
            == .valid(authority: "other.example.com"))
    #expect(PKI.Command.verify("web.pem", chain: true, authorities: "ca bundle.pem", host: "web.example.com")
            == "openssl verify -CAfile 'ca bundle.pem' -untrusted chain.pem -purpose sslserver -verify_hostname web.example.com web.pem")
}

/// The command shown for New… makes a certificate with the same subject, names, usages and key as AirSCP's.
@Test(.enabled(if: openssl != nil, "needs OpenSSL 3's openssl (test-only)"))
func theCommandShownForANewCertificateMakesTheSame() throws {
    let f = try scratch(), o = try #require(openssl)
    var new = PKI.NewCertificate()
    new.commonName = "web.example.com"
    new.organization = "Example"
    new.otherNames = "10.0.0.5"
    new.keyType = .ecP256
    for selfSigned in [true, false] {
        new.selfSigned = selfSigned
        let (_, ours) = try #require(new.make())
        let file = selfSigned ? "web.crt" : "web.csr", key = selfSigned ? "web.key" : "request.key"
        let path = URL(fileURLWithPath: o).deletingLastPathComponent().path
        try run("/bin/sh", ["-c", "PATH=\(Quote.shellWord(path)):$PATH " + PKI.Command.newCertificate(new, key: key, output: file, passphrase: false)],
                in: f)
        let theirs = try #require(try items(f + "/" + file).first), a = PKI.details(ours), b = PKI.details(theirs)
        #expect(theirs.kind == ours.kind)
        for field in ["subject", "san", "keyUsage", "extendedKeyUsage", "ca", "signature", "keyType", "keyBits", "selfIssued", "verified"] {
            #expect(a.fields[field] == b.fields[field], "\(file) \(field)")
        }
    }
}

// MARK: The window, as people and agents use it

extension FeatureRoundAppTests {
    /// The Certificate Manager explains itself (every control and the new sheets' fields have help, disabled ones say
    /// why), and an agent makes a self-signed certificate, a keystore, a truststore and a chain check with the ids the
    /// guide names.
    @MainActor @Test func theCertificateManagerSaysWhatEachControlDoesAndAgentsUseIt() async throws {
        _ = NSApplication.shared
        let folder = try scratch()
        var new = PKI.NewCertificate()
        new.commonName = "web.example.com"
        new.selfSigned = true
        new.keyType = .ecP256
        let (key, certificate) = try #require(new.make())
        try PKI.pem(certificate).write(toFile: folder + "/web.pem", atomically: true, encoding: .utf8)
        try #require(PKI.keyPEM(key)).write(toFile: folder + "/web.key", atomically: true, encoding: .utf8)
        let controller = CertificateManagerWindowController()
        let window = try #require(controller.window)
        window.setFrameOrigin(NSPoint(x: -24000, y: -21000))  // off the screen, as the tests' other windows
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let agent = try AgentServer(main: nil, model: testModel(), directory: URL(fileURLWithPath: try scratch() + "/agent"),
                                    windows: { [window] })
        defer { agent.close() }
        var missing: [String] = [], checked = 0
        func check(_ what: String) async {
            try? await Task.sleep(nanoseconds: 300_000_000)  // SwiftUI's controls, a moment after a change
            missing += unexplained(window, checked: &checked).map { what + " — " + $0 }
        }
        func sheet(_ open: String, _ what: String, then: () async -> Void = {}) async {
            _ = await call(agent, "press", ["title": open, "in": "window:Certificate Manager"])
            #expect(await call(agent, "wait", ["until": "sheet", "timeout": 10]).error == nil, "\(what)")
            await check(what)
            await then()
            _ = await call(agent, "press", ["title": "Cancel", "in": "sheet"])
            #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 10]).error == nil, "\(what)")
        }
        await check("nothing open")
        #expect(await call(agent, "press", ["id": "certificates.open", "files": [folder + "/web.pem", folder + "/web.key"]]).error == nil)
        #expect(controller.model.allItems.map(\.kind) == [.certificate, .privateKey])
        controller.model.selection = controller.model.allItems.first?.id
        await check("a certificate")
        await sheet("PKCS#12…", "PKCS#12")
        await sheet("JKS…", "JKS")
        await sheet("Truststore…", "truststore")
        await sheet("Verify…", "verify", then: {
            _ = await call(agent, "set", ["id": "certificates.verifyAgainst", "value": "A CA bundle file"])
            await check("verify against a bundle")
        })
        await sheet("New…", "a new request", then: {
            _ = await call(agent, "set", ["id": "certificates.newKind", "value": "Self-signed certificate"])
            await check("a new self-signed certificate")
        })
        controller.model.selection = controller.model.allItems.last?.id
        await check("a key")
        await sheet("Save Key…", "save a key")
        #expect(missing.isEmpty, "Without a tooltip or help:\n\(missing.joined(separator: "\n"))")
        #expect(checked > 40, "only \(checked) controls were looked at")

        // An agent, as the guide says: a self-signed certificate and its key, saved as new files.
        _ = await call(agent, "press", ["id": "certificates.new", "in": "window:Certificate Manager"])
        #expect(await call(agent, "wait", ["until": "sheet", "timeout": 10]).error == nil)
        for (id, value) in [("certificates.newKind", "Self-signed certificate"), ("certificates.commonName", "intranet.example.com"),
                            ("certificates.names", "10.1.2.3"), ("certificates.keyType", "EC P-256"), ("certificates.days", "30"),
                            ("certificates.newPassphrase", "a passphrase")] {
            #expect(await call(agent, "set", ["id": id, "value": value]).error == nil, "\(id)")
        }
        #expect(await call(agent, "press", ["title": "Create…", "in": "sheet", "file": folder + "/intranet.crt"]).error == nil)
        #expect(await eventually(timeout: 60) { FileManager.default.fileExists(atPath: folder + "/intranet.crt") })
        let made = try #require(try items(folder + "/intranet.crt").first)
        #expect(PKI.details(made).sans == ["DNS:intranet.example.com", "IP:10.1.2.3"] && (29...30).contains(PKI.daysLeft(PKI.details(made)) ?? 0))
        #expect(throws: PKI.ReadError.password) { try items(folder + "/intranet.key") }
        #expect(PKI.matches(try #require(try items(folder + "/intranet.key", password: "a passphrase").first), made))
        let command = try #require(controller.model.command)
        #expect(command.hasPrefix("openssl req -x509 -days 30 -newkey ec") && !command.contains("passphrase") && !command.contains("-nodes"))
        // Asked again with the same name: nothing is replaced.
        let before = try Data(contentsOf: URL(fileURLWithPath: folder + "/intranet.key"))
        _ = await call(agent, "press", ["id": "certificates.new", "in": "window:Certificate Manager"])
        #expect(await call(agent, "wait", ["until": "sheet", "timeout": 10]).error == nil)
        _ = await call(agent, "set", ["id": "certificates.commonName", "value": "intranet.example.com"])
        _ = await call(agent, "press", ["title": "Create…", "in": "sheet", "file": folder + "/intranet.csr"])
        #expect(await eventually(timeout: 60) { controller.model.status?.hasPrefix("Nothing saved") == true }, "\(controller.model.status ?? "")")
        #expect(try Data(contentsOf: URL(fileURLWithPath: folder + "/intranet.key")) == before
                && !FileManager.default.fileExists(atPath: folder + "/intranet.csr"))

        // A truststore of the selected certificate, then its check against itself as the CA bundle.
        #expect(controller.model.selected?.der == made.der)
        _ = await call(agent, "press", ["title": "Truststore…", "in": "window:Certificate Manager"])
        #expect(await call(agent, "wait", ["until": "sheet", "timeout": 10]).error == nil)
        _ = await call(agent, "set", ["id": "certificates.trustFormat", "value": "Java keystore (.jks)"])
        _ = await call(agent, "set", ["id": "certificates.trustPassword", "value": "changeit"])
        #expect(await call(agent, "press", ["title": "Save…", "in": "sheet", "file": folder + "/trust.jks"]).error == nil)
        let store = try PKI.read(try Data(contentsOf: URL(fileURLWithPath: folder + "/trust.jks")), password: "changeit")
        #expect(store.contains { $0.der == made.der && $0.name == "intranet.example.com" })
        _ = await call(agent, "press", ["title": "Verify…", "in": "window:Certificate Manager"])
        #expect(await call(agent, "wait", ["until": "sheet", "timeout": 10]).error == nil)
        _ = await call(agent, "set", ["id": "certificates.verifyAgainst", "value": "A CA bundle file"])
        #expect(await call(agent, "press", ["id": "certificates.chooseBundle", "file": folder + "/intranet.crt"]).error == nil)
        _ = await call(agent, "set", ["id": "certificates.verifyHost", "value": "10.1.2.3"])
        _ = await call(agent, "press", ["title": "Verify", "in": "sheet"])
        let selected = try #require(controller.model.selected)
        #expect(await eventually(timeout: 60) { controller.model.checks[selected.id] != nil })
        #expect(controller.model.checks[selected.id]?.valid == true, "\(controller.model.checks[selected.id]?.text ?? "")")
        let verify = try #require(controller.model.command)
        #expect(verify.hasPrefix("openssl verify -CAfile ") && verify.contains("/intranet.crt -untrusted chain.pem")
                && verify.hasSuffix(" -purpose sslserver -verify_hostname 10.1.2.3 intranet.example.com.pem"), "\(verify)")
    }
}
