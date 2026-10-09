import Foundation
import Testing
@testable import AirSCP
@testable import AirSCPCore

// MARK: The Certificate Manager (PLAN.md AA): interop with openssl and keytool, test-only

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

/// A CA, a server certificate it signed (SANs, key usages), their keys, a request, and containers of them, made by
/// openssl in a scratch folder.
private func fixtures() throws -> String {
    let folder = try scratch(), o = try #require(openssl)
    func s(_ arguments: String) throws { try run(o, arguments.components(separatedBy: " "), in: folder) }
    try "basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\n".write(toFile: folder + "/ca.ext", atomically: true, encoding: .utf8)
    try "subjectAltName=DNS:web.example.com,DNS:www.example.com,IP:10.0.0.5\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth,clientAuth\n"
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
    #expect(details.sans == ["DNS:web.example.com", "DNS:www.example.com", "IP:10.0.0.5"])
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

@Test(.enabled(if: openssl != nil && tool("keytool") != nil, "needs openssl and keytool (test-only)"))
func certificateManagerReadsJavaKeystores() throws {
    let f = try fixtures(), keytool = try #require(tool("keytool"))
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
