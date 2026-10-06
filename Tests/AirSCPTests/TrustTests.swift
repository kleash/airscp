import CRDP
import Foundation
import Testing
@testable import AirSCPCore

// PLAN.md U.4: how a host checks its server's key (ssh's StrictHostKeyChecking, scoped to the host) and a Remote
// Desktop its server's certificate (ask, trust the first one, don't check, or a company certificate authority).

@Test func serverKeyChecksBecomeTheHostsOwnSSHOptions() throws {
    var host = SSHHost(hostname: "web")
    #expect(!OpenSSH.options(host, jump: nil).contains { $0.hasPrefix("StrictHostKeyChecking") })
    host.hostKeyCheck = .acceptNew
    #expect(OpenSSH.options(host, jump: nil).contains("StrictHostKeyChecking=accept-new"))
    host.hostKeyCheck = .off
    host.extraOptions = ["UserKnownHostsFile=/tmp/elsewhere"]
    let options = OpenSSH.options(host, jump: nil)
    #expect(options.contains("StrictHostKeyChecking=no") && options.contains("GlobalKnownHostsFile=/dev/null"))
    // Before the host's Other options: ssh takes the first value, so no known_hosts of the host's is read.
    let none = try #require(options.firstIndex(of: "UserKnownHostsFile=/dev/null"))
    #expect(none < (try #require(options.firstIndex(of: "UserKnownHostsFile=/tmp/elsewhere"))))

    // Scoped to the host: its jump host (the first hop, in the ProxyCommand) keeps its own check.
    var jump = SSHHost(hostname: "bastion")
    var target = SSHHost(hostname: "target")
    target.jumpHostID = jump.id
    target.hostKeyCheck = .off
    func proxyCommand() -> String { OpenSSH.options(target, jump: jump).first { $0.hasPrefix("ProxyCommand=") } ?? "" }
    #expect(!proxyCommand().contains("StrictHostKeyChecking"))
    jump.hostKeyCheck = .acceptNew
    #expect(proxyCommand().contains("StrictHostKeyChecking=accept-new") && !proxyCommand().contains("/dev/null"))
    // Other ssh options can't set it: the pop-up does, so the sidebar can show when checks are off.
    #expect(SSHConfig.refusal("StrictHostKeyChecking=no", routed: false)?.contains("Server key") == true)
}

@Test func hostsAndDesktopsFromAnOlderVersionAsk() throws {
    let host = try JSONDecoder().decode(SSHHost.self, from: Data(#"{"hostname": "web"}"#.utf8))
    let entry = try JSONDecoder().decode(RDPEntry.self, from: Data(#"{"hostname": "win"}"#.utf8))
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
    #expect(host.hostKeyCheck == .ask && entry.certificateCheck == .ask && entry.caFile.isEmpty)
    #expect(settings.hostKeyCheck == .ask && settings.certificateCheck == .ask && settings.keyFolder.isEmpty)
    var changed = entry
    changed.certificateCheck = .companyCA
    changed.caFile = NSHomeDirectory() + "/ca.pem"
    #expect(try JSONDecoder().decode(RDPEntry.self, from: JSONEncoder().encode(changed)) == changed)
    // An export names files in the home folder as ~/…, as it does key files.
    let exported = try Store.importHosts(from: Store.export(AirSCPData(rdpEntries: [changed])))
    #expect(exported.rdpEntries.first?.caFile == "~/ca.pem")
}

/// Against a throwaway sshd: Ask asks; Trust new servers automatically connects without a question and remembers the
/// key; a changed key is refused all the same; Don't check connects anyway and remembers nothing.
@Test func serverKeyChecksAgainstAServer() async throws {
    try await withServer { server in
        var host = server.host(trustNewHostKeys: false)
        let asked = try server.session(host)  // its question is cancelled
        await #expect(throws: AirSCPError.self) { try await asked.connect() }
        #expect(server.prompts.all.contains { if case .hostKey = $0.kind { return true } else { return false } })
        #expect(read(server.knownHosts) == nil)

        host.hostKeyCheck = .acceptNew
        let before = server.prompts.all.count
        let accepted = try await server.connectedSession(host)
        #expect(accepted.state == .connected && server.prompts.all.count == before)
        let remembered = try #require(read(server.knownHosts))
        #expect(remembered.contains("[127.0.0.1]:\(server.port)"))
        await accepted.disconnect()

        // Another key for the server than the one it has: refused, with ssh's warning.
        let impostor = try server.scratch() + "/impostor"
        try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "impostor", "-f", impostor])
        let key = try #require(read(impostor + ".pub")).split(separator: " ").prefix(2).joined(separator: " ")
        try write("[127.0.0.1]:\(server.port) \(key)\n", to: server.knownHosts)
        do {
            _ = try await server.connectedSession(host)
            Issue.record("connected although the server's key changed")
        } catch let error as AirSCPError {
            #expect(error.kind == .hostKeyChanged, "\(error.message) \(error.details)")
        }

        host.hostKeyCheck = .off
        let unchecked = try await server.connectedSession(host)
        #expect(unchecked.state == .connected && server.prompts.all.count == before)
        #expect(read(server.knownHosts) == "[127.0.0.1]:\(server.port) \(key)\n")  // nothing learned, nothing changed
    }
}

// MARK: Remote Desktop certificates

/// A certificate authority from /usr/bin/openssl: its PEM file and the subject hash OpenSSL names its copy by.
func makeCertificateAuthority(_ name: String, in folder: String) async throws -> (pem: String, hash: String) {
    let pem = folder + "/\(name).pem"
    try await run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=\(name)", "-days", "2",
                   "-keyout", folder + "/\(name).key", "-out", pem])
    let hash = try await run(["/usr/bin/openssl", "x509", "-hash", "-noout", "-in", pem]).output
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return (pem, hash)
}

/// The company certificate authority goes where FreeRDP looks (<ConfigPath>/certs, by subject hash): PEM with one or
/// more certificates, or DER; what was there before goes; a file that isn't one says so.
@Test func aCompanyCertificateAuthorityIsInstalledForFreeRDP() async throws {
    let folder = try scratch(), certs = folder + "/certs"
    let (root, rootHash) = try await makeCertificateAuthority("AirSCP Test Root", in: folder)
    let (issuing, issuingHash) = try await makeCertificateAuthority("AirSCP Test Issuing", in: folder)
    #expect(airscp_install_ca(root, certs) == 1)
    #expect(names(in: certs) == [rootHash + ".0"])
    #expect(read(certs + "/" + rootHash + ".0")?.hasPrefix("-----BEGIN CERTIFICATE-----") == true)
    var info = stat()
    #expect(lstat(certs, &info) == 0 && info.st_mode & 0o777 == 0o700)

    let bundle = folder + "/bundle.pem"
    try write(try #require(read(root)) + (try #require(read(issuing))), to: bundle)
    #expect(airscp_install_ca(bundle, certs) == 2)
    #expect(names(in: certs) == [rootHash + ".0", issuingHash + ".0"].sorted())

    let der = folder + "/issuing.cer"
    try await run(["/usr/bin/openssl", "x509", "-in", issuing, "-outform", "DER", "-out", der])
    #expect(airscp_install_ca(der, certs) == 1)
    #expect(names(in: certs) == [issuingHash + ".0"])  // the earlier ones went

    try write("not a certificate", to: folder + "/notes.txt")
    #expect(airscp_install_ca(folder + "/notes.txt", certs) == 0)
    #expect(airscp_install_ca(folder + "/missing.pem", certs) == -1)

    // A desktop that trusts a company CA keeps a FreeRDP folder of its own; the others share one.
    var entry = RDPEntry(hostname: "win")
    var options = RDPSession.Options()
    let shared = options.configDirectory
    options.checkCertificates(like: entry)
    #expect(options.configDirectory == shared && options.certificateCheck == .ask)
    entry.certificateCheck = .companyCA
    entry.caFile = "~/company-ca.pem"
    options.checkCertificates(like: entry)
    #expect(options.configDirectory.hasSuffix("/freerdp-ca/" + entry.id.uuidString))
    #expect(options.caFile == NSHomeDirectory() + "/company-ca.pem")
    #expect(RDPSession.installCompanyCA(options)?.kind == .noSuchFile)
    options.caFile = folder + "/notes.txt"
    options.configDirectory = folder + "/entry"
    #expect(RDPSession.installCompanyCA(options)?.message.contains("holds no certificate") == true)
    options.caFile = root
    #expect(RDPSession.installCompanyCA(options) == nil)
}

/// A desktop set to a company certificate authority without its file says so instead of connecting.
@Test func aCompanyCertificateAuthorityThatIsMissingStopsTheConnection() async throws {
    let port = try #require(RDPSession.freePort())
    var options = RDPSession.Options()
    options.configDirectory = try scratch() + "/freerdp"
    options.certificateCheck = .companyCA
    options.caFile = options.configDirectory + "/nothing.pem"
    do {
        try await RDPSession.testLogin(RDPSession.Target(host: "127.0.0.1", port: port, username: "u", password: "p"),
                                       options: options)
        Issue.record("connected without the certificate authority")
    } catch let error as AirSCPError {
        #expect(error.kind == .noSuchFile && error.message.contains("certificate authority file"), "\(error.message)")
    }
}

// MARK: Against the Docker lab (AIRSCP_DOCKER=1)

/// The lab's Debian target with Trust new servers automatically: a new key is taken without a question; a changed
/// one is refused; Don't check connects anyway.
@Test(.enabled(if: Lab.enabled, "Docker lab: AIRSCP_DOCKER=1")) func acceptNewAgainstTheLab() async throws {
    try await withLab { lab in
        var host = Lab.target()
        #expect(host.hostKeyCheck == .acceptNew)
        let knownHosts = try #require(host.extraOptions.first { $0.hasPrefix("UserKnownHostsFile=") })
            .dropFirst("UserKnownHostsFile=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let first = try await lab.connected(host)
        #expect(first.state == .connected && lab.prompts.all.isEmpty)
        #expect(read(knownHosts)?.contains("[127.0.0.1]:\(Lab.targetPort)") == true)
        await first.disconnect()

        let impostor = try scratch() + "/impostor"
        try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "impostor", "-f", impostor])
        let key = try #require(read(impostor + ".pub")).split(separator: " ").prefix(2).joined(separator: " ")
        try write("[127.0.0.1]:\(Lab.targetPort) \(key)\n", to: knownHosts)
        do {
            _ = try await lab.connected(host)
            Issue.record("connected although the lab target's key changed")
        } catch let error as AirSCPError {
            #expect(error.kind == .hostKeyChanged, "\(error.message) \(error.details)")
        }

        host.hostKeyCheck = .off
        let unchecked = try await lab.connected(host)
        #expect(unchecked.state == .connected && lab.prompts.all.isEmpty)
        #expect(read(knownHosts) == "[127.0.0.1]:\(Lab.targetPort) \(key)\n")
    }
}
