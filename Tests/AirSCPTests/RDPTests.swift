import CoreGraphics
import Foundation
import Testing
@testable import AirSCPCore

// The RDP client: FreeRDP behind the C shim (Sources/CRDP) and RDPSession. Tests against real Windows run only with
// AIRSCP_WINDOWS=1 and the test VM up (testenv/windows: "Porter Test Windows"); its address comes from
// $AIRSCP_WINDOWS_HOST or `windows-vm.sh ip`, the password from $AIRSCP_WINDOWS_CREDENTIALS or
// testenv/.windows/credentials.

@Test func rdpTestLoginToAClosedPortSaysTheServerCantBeReached() async throws {
    let port = try #require(RDPSession.freePort())
    var options = RDPSession.Options()
    options.configDirectory = try scratch() + "/freerdp"
    do {
        try await RDPSession.testLogin(RDPSession.Target(host: "127.0.0.1", port: port, username: "nobody",
                                                         password: "wrong"), options: options)
        Issue.record("logged in to a closed port")
    } catch let error as AirSCPError {
        #expect(error.kind == .refused)
        #expect(error.details.contains("FreeRDP error 0x0002000"))
    }
}

@Test func rdpConnectToAClosedPortEndsDisconnected() async throws {
    let port = try #require(RDPSession.freePort())
    var options = RDPSession.Options()
    options.configDirectory = try scratch() + "/freerdp"
    let session = RDPSession(target: RDPSession.Target(host: "127.0.0.1", port: port, username: "nobody",
                                                       password: "x"), options: options)
    let states = Recorder<RDPSession.State>()
    session.onStateChange = { states.append($0) }
    session.connect()
    // (States arrive on the main queue, which the app tests keep busy at times: for a minute and more on CI.)
    #expect(await eventually(timeout: 300) { if case .disconnected = states.all.last { return true } else { return false } })
    #expect(states.all.first == .connecting)
    if case .disconnected(let error) = states.all.last { #expect(error.kind == .refused) }
    session.disconnect()  // nothing left to stop
}

/// A server that takes the connection and then says nothing: connecting (and Test Connection) gives up, as a timeout.
@Test func rdpSilentServerTimesOut() async throws {
    let listener = socket(AF_INET, SOCK_STREAM, 0)
    defer { close(listener) }
    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let bound = withUnsafeMutablePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, length) == 0 && getsockname(listener, $0, &length) == 0 }
    }
    #expect(bound && listen(listener, 4) == 0)  // the system takes connections; nobody answers them
    var options = RDPSession.Options()
    options.configDirectory = try scratch() + "/freerdp"
    do {
        let target = RDPSession.Target(host: "127.0.0.1", port: Int(UInt16(bigEndian: address.sin_port)), username: "u", password: "p")
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                let session = RDPSession(target: target, options: options)
                session.connectTimeout = 3
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    session.onStateChange = { state in
                        switch state {
                        case .disconnected(let error): continuation.resume(throwing: error)
                        case .idle: continuation.resume()
                        default: return
                        }
                        session.onStateChange = nil
                    }
                    session.connect()
                }
            }
            try await group.waitForAll()
        }
        Issue.record("connected to a server that says nothing")
    } catch let error as AirSCPError {
        // AirSCP's own limit (3 s here), not Remote Desktop's minute: checked by what ended it, not by the clock (the
        // limit is checked on the main queue, which the suite keeps busy for a minute and more on a busy Mac).
        #expect(error.kind == .timeout && error.details == "Nothing for 3 s", "\(error)")
    }
    // A connect leaves SIGPIPE ignored, as FreeRDP's own clients have it: FreeRDP writing on the connection this test's
    // listener reset as it closed ended the whole test process now and then (SIGPIPE).
    var action = sigaction()
    sigaction(SIGPIPE, nil, &action)
    #expect(unsafeBitCast(action.__sigaction_u.__sa_handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self))
}

@Test func rdpErrorsAreExplained() {
    #expect(RDPSession.error(code: 0x0002_0014, text: "logon failure").kind == .authFailed(methods: ""))
    #expect(RDPSession.error(code: 0x0002_0005, text: "").kind == .unknownHost)
    #expect(RDPSession.error(code: 0x0002_000B, text: "").kind == .cancelled)
    #expect(RDPSession.error(code: 0x0002_000B, text: "", certificateRejected: true).kind == .hostKeyRejected)
    // Windows 11 sends 0x0C for signing out and for disconnecting alike.
    #expect(RDPSession.error(code: 0x0001_000C, text: "").message.contains("signed out or disconnected"))
    #expect(RDPSession.error(code: 0x0001_0001, text: "").message.contains("another connection may have taken it over"))
    // A session that was up and then lost its transport lost its connection; it wasn't refused.
    #expect(RDPSession.error(code: 0x0002_000D, text: "").kind == .refused)
    #expect(RDPSession.error(code: 0x0002_000D, text: "", wasConnected: true).kind == .disconnected)
    #expect(RDPSession.windowsName("Invoice 03:2024.pdf") == "Invoice 03_2024.pdf" && RDPSession.windowsName("notes.") == "notes_")
    #expect(RDPSession.windowsName("back\\slash.txt") == "back_slash.txt" && RDPSession.windowsName("café ü.txt") == "café ü.txt")
    #expect(RDPSession.error(code: 0x0001_0005, text: "").message.contains("Another connection"))
    let other = RDPSession.error(code: 0x0002_0099, text: "something new")
    #expect(other.kind == .other && other.details == "something new (FreeRDP error 0x00020099)")
}

/// FreeRDP's store of certificates trusted with Always, as AirSCP reads it: a saved copy that isn't a certificate (an
/// empty file from a failed save) is damaged, so it is asked about as a changed certificate; a store that can't be
/// written is noticed before Always is answered.
@Test func rdpCertificateStoreIsReadAsFreeRDPWritesIt() throws {
    let folder = try scratch()
    #expect(RDPSession.storedCertificatePath("Win.Example:3390", in: folder) == folder + "/server/win.example_3390.pem")
    #expect(!RDPSession.storedCertificateIsDamaged("win:3389", in: folder))  // none saved yet
    #expect(RDPSession.canSaveCertificates(in: folder))
    try write("", to: folder + "/server/win_3389.pem")
    #expect(RDPSession.storedCertificateIsDamaged("win:3389", in: folder))
    try write("-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n", to: folder + "/server/win_3389.pem")
    #expect(!RDPSession.storedCertificateIsDamaged("win:3389", in: folder))
    let readOnly = try scratch()
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly) }
    #expect(!RDPSession.canSaveCertificates(in: readOnly))
}

@Test func rdpEntryFromAnOlderVersionGetsTheNewDefaults() throws {
    let json = #"{"id":"6F4A7C3A-58A4-4C49-9C77-5A1B2C3D4E5F","label":"Win","hostname":"win.example","port":3390,"#
        + #""username":"me","domain":"","display":{"fit":{}},"retinaScale":false,"clipboard":true,"cmdAsCtrl":true}"#
    let entry = try JSONDecoder().decode(RDPEntry.self, from: Data(json.utf8))
    #expect(entry.hostname == "win.example" && entry.port == 3390 && !entry.retinaScale && entry.display == .fit)
    #expect(entry.shareFolder && entry.sharedFolder.isEmpty)
    #expect(entry.keychainKey == "rdp:6F4A7C3A-58A4-4C49-9C77-5A1B2C3D4E5F")
    let again = try JSONDecoder().decode(RDPEntry.self, from: JSONEncoder().encode(entry))
    #expect(again == entry)
}

@Test func rdpClipboardListsFoldersBeforeTheirContents() throws {
    let root = try scratch()
    let folder = root + "/Ordner Café"
    try FileManager.default.createDirectory(atPath: folder + "/inner", withIntermediateDirectories: true)
    try write("hello", to: folder + "/inner/a.txt")
    try write("x", to: folder + "/.DS_Store")
    try write("12345", to: root + "/loose.txt")
    try FileManager.default.createSymbolicLink(atPath: folder + "/link", withDestinationPath: root + "/loose.txt")
    let entries = RDPSession.listing([URL(fileURLWithPath: folder), URL(fileURLWithPath: root + "/loose.txt")])
    let names = entries.map(\.name)
    #expect(names == ["Ordner Café", "Ordner Café/inner", "Ordner Café/inner/a.txt", "loose.txt"])
    #expect(names.allSatisfy { $0 == $0.precomposedStringWithCanonicalMapping })
    #expect(entries.map(\.isFolder) == [true, true, false, false])
    #expect(entries[2].size == 5 && entries[3].size == 5)
    #expect(entries[3].modified > 1_600_000_000)
    #expect(RDPSession.listing([URL(fileURLWithPath: folder)], limit: 1).isEmpty)
}

// MARK: Against the Windows test VM (AIRSCP_WINDOWS=1)

/// The Windows VM's address and the porter account's password, or nil (test skipped) unless AIRSCP_WINDOWS=1.
func windows() -> (host: String, password: String)? {
    guard Env.value("WINDOWS") == "1" else { return nil }
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().path
    let credentials = Env.value("WINDOWS_CREDENTIALS") ?? repo + "/testenv/.windows/credentials"
    let text = (try? String(contentsOfFile: credentials, encoding: .utf8)) ?? ""
    // The file windows-vm.sh wrote when it made the VM (its names are from before the rename, as the VM's are).
    let password = text.components(separatedBy: .newlines).first { $0.hasPrefix("PORTER_WIN_PASSWORD=") }
        .map { String($0.dropFirst("PORTER_WIN_PASSWORD=".count)) }
    var host = Env.value("WINDOWS_HOST")
    if host == nil {
        let pipe = Pipe(), process = Process()
        process.executableURL = URL(fileURLWithPath: repo + "/testenv/windows/windows-vm.sh")
        process.arguments = ["ip"]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        host = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard let host, !host.isEmpty, let password, !password.isEmpty else { return nil }
    return (host, password)
}

private let windowsEnabled = Env.value("WINDOWS") == "1"

/// Drives a Windows session for the VM tests: commands typed into the Run box (Win+R), and PowerShell scripts run
/// from the shared folder (`shared`, \\tsclient\AirSCP in Windows).
struct WindowsRunner {
    let session: RDPSession
    let shared: String

    /// Win+R, the command, Enter, until `done` (Windows' clipboard can be busy, and its windows slow to open). A
    /// slow start is waited for (a busy Windows can take a minute or two to start a program): the command is typed
    /// again only when `started` doesn't say it started.
    func run(_ command: String, started: @escaping () -> Bool, until done: @escaping () -> Bool) async throws -> Bool {
        for _ in 0..<2 {
            session.scancode(0x01, down: true)  // Esc: away with a dialog a failed try left
            session.scancode(0x01, down: false)
            session.scancode(0x15B, down: true)
            session.key(0x0F, down: true)  // R
            session.key(0x0F, down: false)
            session.scancode(0x15B, down: false)
            try await Task.sleep(nanoseconds: 3_000_000_000)
            for character in command {  // not faster than the Run box's autocomplete keeps up with
                session.unicode(String(character))
                try await Task.sleep(nanoseconds: 15_000_000)
            }
            try await Task.sleep(nanoseconds: 500_000_000)
            session.scancode(0x1C, down: true)
            session.scancode(0x1C, down: false)
            if await eventually(timeout: 120, { started() || done() }), await eventually({ done() }) {
                return true
            }
        }
        return false
    }

    /// Runs a PowerShell script from the shared folder (it says when it has started, retries when Windows' clipboard
    /// is busy, and logs errors to airscp.log there). In the old console host with its window hidden: Windows
    /// Terminal, Windows 11's default, can take a minute to open in a new session and takes the focus when it does.
    func powershell(_ name: String, _ script: String, until done: @escaping () -> Bool) async throws -> Bool {
        try write("Set-Content \\\\tsclient\\AirSCP\\\(name).started x\r\n$ErrorActionPreference = 'Stop'\r\n"
            + "for ($i = 0; $i -lt 20; $i++) {\r\n  try {\r\n    \(script)\r\n"
            + "    break\r\n  } catch {\r\n    Add-Content \\\\tsclient\\AirSCP\\airscp.log \"\(name): $_\"\r\n"
            + "    Start-Sleep -Milliseconds 300\r\n  }\r\n}\r\n", to: shared + "/\(name).ps1")
        return try await run("conhost powershell -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass "
                             + "-File \\\\tsclient\\AirSCP\\\(name).ps1", started: { exists(shared + "/\(name).started") },
                             until: done)
    }
}

/// One at a time: Windows gives the account one session, and a second login takes it over.
@Suite(.serialized, .enabled(if: windowsEnabled)) struct RDPWindowsTests {

@Test func rdpTestLoginToWindowsWithTheRightAndAWrongPassword() async throws {
    let (host, password) = try #require(windows(), "AIRSCP_WINDOWS=1 needs the VM's address and credentials")
    var options = RDPSession.Options()
    options.configDirectory = try scratch() + "/freerdp"
    let certificates = Recorder<RDPSession.Certificate>()
    let trustOnce: (RDPSession.Certificate, @escaping (RDPSession.Trust) -> Void) -> Void = {
        certificates.append($0)
        $1(.once)
    }
    try await RDPSession.testLogin(RDPSession.Target(host: host, port: 3389, username: "porter", password: password),
                                   options: options, onCertificate: trustOnce)
    let certificate = try #require(certificates.all.first, "Windows' self-signed certificate is asked about")
    #expect(certificate.server == "\(host):3389" && certificate.oldFingerprint == nil)
    #expect(certificate.fingerprint.count >= 64 && certificate.subject.contains("PORTER-WIN"))

    do {
        try await RDPSession.testLogin(RDPSession.Target(host: host, port: 3389, username: "porter",
                                                         password: password + "-wrong"),
                                       options: options, onCertificate: trustOnce)
        Issue.record("logged in with a wrong password")
    } catch let error as AirSCPError {
        #expect(error.kind == .authFailed(methods: ""), "\(error.message) \(error.details)")
    }

    // Untrusted: no handler means No, and nothing is sent.
    do {
        try await RDPSession.testLogin(RDPSession.Target(host: host, port: 3389, username: "porter",
                                                         password: password), options: options)
        Issue.record("connected without trusting the certificate")
    } catch let error as AirSCPError {
        #expect(error.kind == .hostKeyRejected, "\(error.message) \(error.details)")
    }
}

/// Through an SSH host: a local forward on a throwaway sshd's connection. The certificate is asked about, and
/// remembered, under the server's own name (not 127.0.0.1 and the forward's port).
@Test func rdpTestLoginThroughAnSSHHost() async throws {
    let (host, password) = try #require(windows(), "AIRSCP_WINDOWS=1 needs the VM's address and credentials")
    var options = RDPSession.Options()
    options.configDirectory = try scratch() + "/freerdp"
    try await withServer { server in
        let ssh = try await server.connectedSession()
        let certificates = Recorder<RDPSession.Certificate>()
        for trust in [RDPSession.Trust.always, .no] {
            let tunnel = try await RDPSession.forward(through: ssh, to: host, port: 3389)
            #expect(ssh.activeTunnels.contains(tunnel.id))
            try await RDPSession.testLogin(RDPSession.Target(host: host, port: 3389, username: "porter",
                                                             password: password, tunnelPort: tunnel.listenPort),
                                           options: options) {
                certificates.append($0)
                $1(trust)
            }
            try await ssh.stopTunnel(tunnel)
        }
        // Asked once: the second login, through another forward, found it trusted.
        #expect(certificates.all.map(\.server) == ["\(host):3389"])
    }
}

/// No password saved: it is asked for while connecting. A question still open when the session is stopped is
/// answered "no", and the session ends.
@Test func rdpPasswordIsAskedForAndQuestionsEndWithTheSession() async throws {
    let (host, password) = try #require(windows(), "AIRSCP_WINDOWS=1 needs the VM's address and credentials")
    var options = RDPSession.Options()
    options.configDirectory = try scratch() + "/freerdp"
    let asked = Recorder<String>()
    let session = RDPSession(target: RDPSession.Target(host: host, port: 3389, username: "porter", password: ""),
                             options: options)
    let states = Recorder<RDPSession.State>()
    session.onStateChange = { states.append($0) }
    session.onCertificate = { $1(.once) }
    session.onCredentials = { username, reply in
        asked.append(username)
        reply(RDPSession.Credentials(username: "porter", password: password))
    }
    session.connect()
    #expect(await eventually { states.all.last == .connected }, "\(states.all)")
    #expect(asked.all == ["porter"])
    session.disconnect()
    #expect(await eventually { states.all.last == .idle }, "\(states.all)")

    // The certificate question is never answered: Disconnect ends the session anyway.
    let waiting = RDPSession(target: RDPSession.Target(host: host, port: 3389, username: "porter", password: password),
                             options: options)
    let questions = Recorder<RDPSession.Certificate>(), ended = Recorder<RDPSession.State>()
    waiting.onCertificate = { certificate, _ in questions.append(certificate) }
    waiting.onStateChange = { ended.append($0) }
    waiting.connect()
    #expect(await eventually { !questions.all.isEmpty })
    waiting.disconnect()
    #expect(await eventually { ended.all.last == .idle }, "\(ended.all)")
}

/// A server whose certificate differs from the one trusted before: the question says what was trusted.
@Test func rdpChangedCertificateIsAWarning() async throws {
    let (host, password) = try #require(windows(), "AIRSCP_WINDOWS=1 needs the VM's address and credentials")
    let folder = try scratch()
    // Trusted before: another certificate, in FreeRDP's store under the server's name and port.
    try FileManager.default.createDirectory(atPath: folder + "/freerdp/server", withIntermediateDirectories: true)
    try await run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=impostor",
                   "-days", "1", "-keyout", folder + "/key.pem", "-out", folder + "/freerdp/server/\(host)_3389.pem"])
    var options = RDPSession.Options()
    options.configDirectory = folder + "/freerdp"
    let certificates = Recorder<RDPSession.Certificate>()
    do {
        try await RDPSession.testLogin(RDPSession.Target(host: host, port: 3389, username: "porter", password: password),
                                       options: options) {
            certificates.append($0)
            $1(.no)
        }
        Issue.record("connected although the certificate changed and wasn't trusted")
    } catch let error as AirSCPError {
        #expect(error.kind == .hostKeyRejected, "\(error.message) \(error.details)")
    }
    let changed = try #require(certificates.all.first)
    #expect(changed.oldFingerprint?.isEmpty == false && changed.oldFingerprint != changed.fingerprint)
}

/// Trust automatically (PLAN.md U.4): the server's first certificate is trusted and remembered without a question;
/// a changed one is still asked about, as a change, and No refuses it. Don't check asks nothing, even then.
@Test func rdpTrustAutomaticallyStillWarnsWhenTheCertificateChanges() async throws {
    let (host, password) = try #require(windows(), "AIRSCP_WINDOWS=1 needs the VM's address and credentials")
    let folder = try scratch()
    var options = RDPSession.Options()
    options.configDirectory = folder + "/freerdp"
    options.certificateCheck = .trustNew
    let target = RDPSession.Target(host: host, port: 3389, username: "porter", password: password)
    let questions = Recorder<RDPSession.Certificate>()
    let refuse: (RDPSession.Certificate, @escaping (RDPSession.Trust) -> Void) -> Void = {
        questions.append($0)
        $1(.no)
    }
    try await RDPSession.testLogin(target, options: options, onCertificate: refuse)
    let stored = RDPSession.storedCertificatePath("\(host):3389", in: options.configDirectory)
    #expect(questions.all.isEmpty && read(stored)?.contains("BEGIN CERTIFICATE") == true)
    try await RDPSession.testLogin(target, options: options, onCertificate: refuse)  // remembered: no question
    #expect(questions.all.isEmpty)

    // Another certificate remembered for the server: the one it shows has changed.
    try await run(["/usr/bin/openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=impostor",
                   "-days", "1", "-keyout", folder + "/key.pem", "-out", stored])
    let impostor = try #require(read(stored))
    do {
        try await RDPSession.testLogin(target, options: options, onCertificate: refuse)
        Issue.record("connected although the certificate changed")
    } catch let error as AirSCPError {
        #expect(error.kind == .hostKeyRejected, "\(error.message) \(error.details)")
    }
    let changed = try #require(questions.all.first, "a changed certificate is asked about under Trust automatically")
    #expect(changed.oldFingerprint?.isEmpty == false && changed.oldFingerprint != changed.fingerprint)
    #expect(read(stored) == impostor)  // refused: nothing remembered

    // Don't check: no question, though the remembered certificate isn't the server's; nothing remembered either.
    options.certificateCheck = .off
    try await RDPSession.testLogin(target, options: options, onCertificate: refuse)
    #expect(questions.all.count == 1 && read(stored) == impostor)
}

/// Trust my company's certificate authority: a certificate the authority signed, made out to the name AirSCP connects
/// by, is trusted without a question; one another authority signed is asked about. The VM's certificate is self-signed
/// (its own authority) and made out to its computer name, which this Mac can't look up: the connection goes through a
/// forward on a throwaway sshd's connection, as through an SSH host, and the server keeps that name.
@Test func rdpCompanyCertificateAuthorityTrustsWhatItSigned() async throws {
    let (host, password) = try #require(windows(), "AIRSCP_WINDOWS=1 needs the VM's address and credentials")
    let folder = try scratch()
    // The VM's certificate, as Always Trust stores it: the authority file.
    var learn = RDPSession.Options()
    learn.configDirectory = folder + "/learn"
    try await RDPSession.testLogin(RDPSession.Target(host: host, port: 3389, username: "porter", password: password),
                                   options: learn) { $1(.always) }
    let authority = RDPSession.storedCertificatePath("\(host):3389", in: learn.configDirectory)
    let subject = try await run(["/usr/bin/openssl", "x509", "-noout", "-subject", "-in", authority]).output
    let name = try #require(subject.range(of: #"CN ?= ?[^/,\n]+"#, options: .regularExpression).map {
        String(subject[$0]).replacingOccurrences(of: #"CN ?= ?"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    })
    let (other, _) = try await makeCertificateAuthority("Another Company CA", in: folder)
    try await withServer { server in
        let ssh = try await server.connectedSession()
        let tunnel = try await RDPSession.forward(through: ssh, to: host, port: 3389)
        let target = RDPSession.Target(host: name, port: 3389, username: "porter", password: password,
                                       tunnelPort: tunnel.listenPort)
        let questions = Recorder<RDPSession.Certificate>()
        let refuse: (RDPSession.Certificate, @escaping (RDPSession.Trust) -> Void) -> Void = {
            questions.append($0)
            $1(.no)
        }
        var options = RDPSession.Options()
        options.certificateCheck = .companyCA
        options.caFile = authority
        options.configDirectory = folder + "/company"
        try await RDPSession.testLogin(target, options: options, onCertificate: refuse)
        #expect(questions.all.isEmpty, "signed by the chosen authority: no question")
        #expect(names(in: options.configDirectory + "/certs").count == 1)

        // Ask, the same way in: the certificate isn't trusted yet (asked about, here refused).
        options.certificateCheck = .ask
        options.configDirectory = folder + "/ask"
        await #expect(throws: AirSCPError.self) { try await RDPSession.testLogin(target, options: options, onCertificate: refuse) }
        #expect(questions.all.count == 1)

        // Another authority: asked about, not trusted.
        options.certificateCheck = .companyCA
        options.caFile = other
        options.configDirectory = folder + "/other"
        do {
            try await RDPSession.testLogin(target, options: options, onCertificate: refuse)
            Issue.record("trusted a certificate another authority didn't sign")
        } catch let error as AirSCPError {
            #expect(error.kind == .hostKeyRejected, "\(error.message) \(error.details)")
        }
        #expect(questions.all.count == 2 && questions.all.last?.server == "\(name):3389")
        try await ssh.stopTunnel(tunnel)
    }
}

@Test func rdpDesktopFromWindowsDrawsAndSharesTheFolder() async throws {
    let (host, password) = try #require(windows(), "AIRSCP_WINDOWS=1 needs the VM's address and credentials")
    let folder = try scratch()
    var options = RDPSession.Options()
    options.configDirectory = folder + "/freerdp"
    options.sharedFolder = folder
    options.width = 1024
    options.height = 768
    let session = RDPSession(target: RDPSession.Target(host: host, port: 3389, username: "porter", password: password),
                             options: options)
    let states = Recorder<RDPSession.State>(), sizes = Recorder<CGSize>(), paints = Recorder<CGRect>()
    let shared = Recorder<Bool>()
    session.onStateChange = { states.append($0) }
    session.onResize = { sizes.append(CGSize(width: $0, height: $1)) }
    session.onPaint = { paints.append($0) }
    session.onSharedFolder = { shared.append($0) }
    session.onCertificate = { $1(.always) }
    session.connect()
    defer { session.disconnect() }
    #expect(await eventually { states.all.last == .connected }, "\(states.all)")
    #expect(sizes.all.first == CGSize(width: 1024, height: 768))
    #expect(await eventually { !paints.all.isEmpty }, "a frame arrives")
    // Something was drawn: the frame isn't one colour.
    #expect(await eventually {
        session.withFrame { frame -> Bool in
            guard let frame else { return false }
            let bytes = UnsafeRawBufferPointer(start: frame.pixels, count: frame.stride * frame.height)
            return Set(stride(from: 0, to: bytes.count, by: 4 * 997).map { bytes[$0] }).count > 1
        }
    })
    #expect(await eventually { shared.all.contains(true) }, "Windows accepted \\\\tsclient\\AirSCP")
    // Always: the certificate is in FreeRDP's store, so the next connection asks nothing.
    #expect(!((try? FileManager.default.contentsOfDirectory(atPath: folder + "/freerdp/server")) ?? []).isEmpty)

    session.disconnect()
    #expect(await eventually { states.all.last == .idle }, "\(states.all)")
}

/// Keyboard input and the clipboard both ways, end to end: AirSCP types commands into Windows' Run box (Win+R), and
/// PowerShell puts text, a file and a folder on Windows' clipboard and reads the Mac's text; Explorer pastes the Mac's
/// file and folder into a Windows folder, which PowerShell copies to \\tsclient\AirSCP, this test's folder.
@Test func rdpKeyboardClipboardAndFilesBothWays() async throws {
    let (host, password) = try #require(windows(), "AIRSCP_WINDOWS=1 needs the VM's address and credentials")
    let folder = try scratch(), shared = folder + "/shared", marker = UUID().uuidString.prefix(8)
    try FileManager.default.createDirectory(atPath: shared, withIntermediateDirectories: true)
    var options = RDPSession.Options()
    options.configDirectory = folder + "/freerdp"
    options.sharedFolder = shared
    options.width = 1280
    options.height = 800
    let session = RDPSession(target: RDPSession.Target(host: host, port: 3389, username: "porter", password: password),
                             options: options)
    let states = Recorder<RDPSession.State>(), texts = Recorder<String>(), files = Recorder<Int>()
    let paints = Recorder<CGRect>()
    session.onStateChange = { states.append($0) }
    session.onCertificate = { $1(.once) }
    session.onClipboardText = { texts.append($0) }
    session.onClipboardFiles = { count, _ in files.append(count) }
    session.onPaint = { paints.append($0) }
    session.connect()
    defer { session.disconnect() }
    #expect(await eventually { states.all.last == .connected }, "\(states.all)")
    #expect(session.passwordVerified)  // NLA checked it: Remember may save it
    #expect(await eventually { !paints.all.isEmpty })  // (a desktop that stays the same paints only once)
    try await Task.sleep(nanoseconds: 4_000_000_000)  // the desktop settles

    let windowsRunner = WindowsRunner(session: session, shared: shared)
    func run(_ command: String, started: @escaping () -> Bool, until done: @escaping () -> Bool) async throws -> Bool {
        try await windowsRunner.run(command, started: started, until: done)
    }
    func powershell(_ name: String, _ script: String, until done: @escaping () -> Bool) async throws -> Bool {
        try await windowsRunner.powershell(name, script, until: done)
    }

    // Windows starts programs in the session (one that it has just logged on to takes a while): else nothing below can
    // work, and the VM needs a restart.
    try #require(try await powershell("ready", "Set-Content \\\\tsclient\\AirSCP\\ready.txt ok") {
        read(shared + "/ready.txt") != nil
    }, "Windows didn't start PowerShell from the Run box")

    // Windows → Mac: text.
    #expect(try await powershell("text", "Set-Clipboard -Value 'airscp-text-\(marker)'") {
        texts.all.contains("airscp-text-\(marker)")
    }, "\(texts.all) \(read(shared + "/airscp.log") ?? "")")

    // Windows → Mac: a file and a folder, copied to a folder on the Mac.
    let windowsFolder = "$env:TEMP\\airscp-\(marker)"
    #expect(try await powershell("file", "New-Item -ItemType Directory -Force \(windowsFolder)\\inner | Out-Null; "
        + "Set-Content -NoNewline -Path \(windowsFolder)\\a.txt -Value 'hello from windows'; "
        + "Set-Content -NoNewline -Path \(windowsFolder)\\inner\\b.txt -Value 'b'; "
        + "Set-Clipboard -Path \(windowsFolder)\\a.txt,\(windowsFolder)\\inner") {
        files.all.last == 3
    }, "\(files.all) \(read(shared + "/airscp.log") ?? "")")
    let (_, remote) = session.remoteFiles()
    #expect(remote == [RDPSession.RemoteFile(path: "a.txt", size: 18, isFolder: false),
                       RDPSession.RemoteFile(path: "inner", size: 0, isFolder: true),
                       RDPSession.RemoteFile(path: "inner/b.txt", size: 1, isFolder: false)])
    let pasted = URL(fileURLWithPath: try scratch())
    let fetched = await withCheckedContinuation { continuation in
        session.fetchRemoteFiles(into: pasted, progress: { _ in }) { continuation.resume(returning: $0) }
    }
    let items = try fetched.get()
    #expect(items.map(\.lastPathComponent) == ["a.txt", "inner"])
    #expect(read(pasted.path + "/a.txt") == "hello from windows" && read(pasted.path + "/inner/b.txt") == "b")

    // Windows → Mac: files of 6 881 and 6 883 bytes, a range of which Windows never answered (they come in 4 KB pieces
    // then; a paste of 2 000 files with one such file failed), compared with copies through the shared folder.
    #expect(try await powershell("odd", "foreach ($n in 6881, 6883) { $b = New-Object byte[] $n; "
        + "(New-Object Random $n).NextBytes($b); [IO.File]::WriteAllBytes(\"\(windowsFolder)\\odd-$n.bin\", $b); "
        + "Copy-Item \"\(windowsFolder)\\odd-$n.bin\" \\\\tsclient\\AirSCP\\ }; "
        + "Set-Clipboard -Path \(windowsFolder)\\odd-6881.bin,\(windowsFolder)\\odd-6883.bin") {
        files.all.last == 2 && exists(shared + "/odd-6883.bin")
    }, "\(files.all) \(read(shared + "/airscp.log") ?? "")")
    let odd = URL(fileURLWithPath: try scratch())
    let oddFetched = await withCheckedContinuation { continuation in
        session.fetchRemoteFiles(into: odd, progress: { _ in }) { continuation.resume(returning: $0) }
    }
    #expect(try oddFetched.get().map(\.lastPathComponent) == ["odd-6881.bin", "odd-6883.bin"])
    for size in [6881, 6883] {
        #expect(FileManager.default.contentsEqual(atPath: odd.path + "/odd-\(size).bin", andPath: shared + "/odd-\(size).bin"))
    }

    // Mac → Windows: text, written back through the shared folder.
    session.offerText("airscp-mac-\(marker)")
    try await Task.sleep(nanoseconds: 1_000_000_000)
    #expect(try await powershell("back", "Set-Content -NoNewline -Path \\\\tsclient\\AirSCP\\text.txt "
        + "-Value (Get-Clipboard -Raw)") {
        read(shared + "/text.txt") == "airscp-mac-\(marker)"
    }, "\(read(shared + "/airscp.log") ?? "")")

    // Mac → Windows: something Windows can't take (an image) clears the Mac's last text from Windows' clipboard.
    session.offerNothing()
    try await Task.sleep(nanoseconds: 1_000_000_000)
    #expect(try await powershell("none", "Set-Content -NoNewline -Path \\\\tsclient\\AirSCP\\none.txt "
        + "-Value ('[' + (Get-Clipboard -Raw) + ']')") {
        read(shared + "/none.txt") == "[]"
    }, "\(read(shared + "/none.txt") ?? "") \(read(shared + "/airscp.log") ?? "")")

    // Mac → Windows: a file and a folder, pasted by Explorer into a Windows folder. (Explorer can't paste a folder
    // straight into \\tsclient\AirSCP: FreeRDP's drive redirection answers "file not found".)
    let upload = folder + "/airscp-upload-\(marker).txt", uploadFolder = folder + "/airscp-folder-\(marker)"
    try write("hello from mac", to: upload)
    try FileManager.default.createDirectory(atPath: uploadFolder + "/sub", withIntermediateDirectories: true)
    try write("nested", to: uploadFolder + "/sub/c.txt")
    try write("colon", to: uploadFolder + "/Minutes 10:30.txt")  // Finder shows "Minutes 10/30.txt"; Windows can't store ":"
    session.offerFiles([URL(fileURLWithPath: upload), URL(fileURLWithPath: uploadFolder)])
    try await Task.sleep(nanoseconds: 2_000_000_000)
    let target = "$env:PUBLIC\\airscp-paste-\(marker)"
    let explorer = { exists(shared + "/explorer-\(marker).txt") }
    #expect(try await run("conhost powershell -NoProfile -WindowStyle Hidden -Command \"New-Item -ItemType Directory "
                          + "-Force \(target); explorer \(target); Start-Sleep 3; "
                          + "Set-Content \\\\tsclient\\AirSCP\\explorer-\(marker).txt x\"", started: explorer, until: explorer))
    // Explorer shows the folder: Ctrl+V.
    session.scancode(0x1D, down: true)
    session.key(0x09, down: true)  // V
    session.key(0x09, down: false)
    session.scancode(0x1D, down: false)
    try await Task.sleep(nanoseconds: 5_000_000_000)
    // Once Explorer's paste has arrived (it is slow when the Mac is busy); copying the items again on a retry
    // overwrites, rather than nests, them.
    #expect(try await powershell("copy", "$until = (Get-Date).AddSeconds(15); "
        + "while (-not (Test-Path \(target)\\airscp-folder-\(marker)\\sub\\c.txt) -and (Get-Date) -lt $until) { "
        + "Start-Sleep -Milliseconds 300 }; "
        + "New-Item -ItemType Directory -Force \\\\tsclient\\AirSCP\\pasted-\(marker) | Out-Null; "
        + "Copy-Item -Recurse -Force \(target)\\* \\\\tsclient\\AirSCP\\pasted-\(marker)") {
        read(shared + "/pasted-\(marker)/airscp-upload-\(marker).txt") == "hello from mac"
            && read(shared + "/pasted-\(marker)/airscp-folder-\(marker)/sub/c.txt") == "nested"
            && read(shared + "/pasted-\(marker)/airscp-folder-\(marker)/Minutes 10_30.txt") == "colon"
    }, "\(read(shared + "/airscp.log") ?? "")")
    // Close Explorer (Alt+F4) and remove what the test made in Windows.
    session.scancode(0x38, down: true)
    session.scancode(0x3E, down: true)
    session.scancode(0x3E, down: false)
    session.scancode(0x38, down: false)
    try await Task.sleep(nanoseconds: 1_000_000_000)
    _ = try await powershell("cleanup", "Remove-Item -Recurse -Force \(target), \(windowsFolder); "
        + "Set-Content \\\\tsclient\\AirSCP\\cleaned.txt done") { read(shared + "/cleaned.txt") != nil }

    session.disconnect()
    #expect(await eventually { states.all.last == .idle }, "\(states.all)")
}

/// Cancel while connecting (the bar's Cancel) ends the attempt, also while a question waits for its answer (here the
/// certificate's, never answered), and the next connect goes ahead.
@Test func rdpCancelWhileConnecting() async throws {
    let (host, password) = try #require(windows(), "AIRSCP_WINDOWS=1 needs the VM's address and credentials")
    var options = RDPSession.Options()
    options.configDirectory = try scratch() + "/freerdp"
    options.width = 1280
    options.height = 800
    let session = RDPSession(target: RDPSession.Target(host: host, port: 3389, username: "porter", password: password),
                             options: options)
    let states = Recorder<RDPSession.State>(), asked = Recorder<Int>()
    session.onStateChange = { states.append($0) }
    session.onCertificate = { _, _ in asked.append(1) }  // never answered
    session.connect()
    defer { session.disconnect() }
    #expect(await eventually { !asked.all.isEmpty }, "\(states.all)")
    session.disconnect()
    #expect(await eventually { states.all.last == .idle }, "\(states.all)")
    try await Task.sleep(nanoseconds: 2_000_000_000)
    #expect(states.all.last == .idle && !states.all.contains(.connected), "\(states.all)")
    session.onCertificate = { $1(.once) }
    session.connect()
    #expect(await eventually(timeout: 120) { states.all.last == .connected }, "\(states.all)")
    session.disconnect()
    #expect(await eventually { states.all.last == .idle }, "\(states.all)")
}

/// Clipboard sharing switched off (the entry's "Share the clipboard"): what Windows copies doesn't reach the Mac, and
/// what the Mac offers doesn't reach Windows (Windows' own copy stays on its clipboard).
@Test func rdpClipboardSwitchedOffSharesNothing() async throws {
    let (host, password) = try #require(windows(), "AIRSCP_WINDOWS=1 needs the VM's address and credentials")
    let folder = try scratch(), shared = folder + "/shared", marker = UUID().uuidString.prefix(8)
    try FileManager.default.createDirectory(atPath: shared, withIntermediateDirectories: true)
    var options = RDPSession.Options()
    options.configDirectory = folder + "/freerdp"
    options.sharedFolder = shared
    options.width = 1280
    options.height = 800
    options.clipboard = false
    let session = RDPSession(target: RDPSession.Target(host: host, port: 3389, username: "porter", password: password),
                             options: options)
    let states = Recorder<RDPSession.State>(), texts = Recorder<String>(), files = Recorder<Int>()
    let paints = Recorder<CGRect>()
    session.onStateChange = { states.append($0) }
    session.onCertificate = { $1(.once) }
    session.onClipboardText = { texts.append($0) }
    session.onClipboardFiles = { count, _ in files.append(count) }
    session.onPaint = { paints.append($0) }
    session.connect()
    defer { session.disconnect() }
    #expect(await eventually { states.all.last == .connected }, "\(states.all)")
    #expect(await eventually { !paints.all.isEmpty })
    try await Task.sleep(nanoseconds: 4_000_000_000)  // the desktop settles
    let runner = WindowsRunner(session: session, shared: shared)
    try #require(try await runner.powershell("ready", "Set-Content \\\\tsclient\\AirSCP\\ready.txt ok") {
        read(shared + "/ready.txt") != nil
    }, "Windows didn't start PowerShell from the Run box")

    // Windows → Mac: nothing comes.
    #expect(try await runner.powershell("copy", "Set-Clipboard -Value 'airscp-off-\(marker)'; "
        + "Set-Content \\\\tsclient\\AirSCP\\copied.txt x") { read(shared + "/copied.txt") != nil })
    try await Task.sleep(nanoseconds: 3_000_000_000)
    #expect(texts.all.isEmpty && files.all.isEmpty, "\(texts.all) \(files.all)")

    // Mac → Windows: Windows still has its own text.
    session.offerText("airscp-mac-\(marker)")
    try await Task.sleep(nanoseconds: 1_000_000_000)
    // (The file is there before its text: wait for the text.)
    #expect(try await runner.powershell("paste", "Set-Content -NoNewline -Path \\\\tsclient\\AirSCP\\pasted.txt "
        + "-Value (Get-Clipboard -Raw)") { read(shared + "/pasted.txt")?.isEmpty == false },
            "\(read(shared + "/airscp.log") ?? "")")
    #expect(read(shared + "/pasted.txt") == "airscp-off-\(marker)", "\(read(shared + "/pasted.txt") ?? "")")

    session.disconnect()
    #expect(await eventually { states.all.last == .idle }, "\(states.all)")
}

}
