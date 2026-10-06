import CryptoKit
import Darwin
import Foundation
import Testing
@testable import AirSCPCore

/// AirSCP's Docker test lab (testenv/: target, minimal, bastion and proxy, on 127.0.0.1), started by testenv/up.sh.
/// Its tests run with AIRSCP_DOCKER=1 (./test.sh then starts the lab first). Like the other tests, they keep ssh away
/// from ~/.ssh and the agent: every lab host names its key (or a missing one) and a known_hosts file of its own.
enum Lab {
    static let enabled = Env.value("DOCKER") == "1"

    /// testenv/.keys/id_lab, made by up.sh: every account in the lab takes it.
    static let key = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("testenv/.keys/id_lab").path

    // docker-compose.yml's published ports, and the passwords the images set (the lab keeps the names it was built
    // with before the app was renamed: changing them means rebuilding the images).
    static let targetPort = 42201, minimalPort = 42202, bastionPort = 42203, twofactorPort = 42204, proxyPort = 42280
    static let devPassword = "porter-dev", sftpPassword = "porter-sftp", minimalPassword = "porter-min"
    static let jumpPassword = "porter-jump", proxyPassword = "porter-proxy"

    /// The lab's HTTP proxy, saved as AirSCP would save it.
    static let proxy = Proxy(name: "Lab proxy", host: "127.0.0.1", port: proxyPort, username: "porter")

    /// An account on the Debian target: "dev" (bash, sudo, noisy .bashrc) or "sftponly" (chroot, sftp only).
    static func target(_ user: String = "dev", password: Bool = false) -> SSHHost {
        host(user, port: targetPort, password: password)
    }

    /// dev on the Alpine server (BusyBox; no zip, unzip or python3).
    static func minimal(password: Bool = false) -> SSHHost {
        host("dev", port: minimalPort, password: password)
    }

    /// jump on the bastion.
    static func bastion(password: Bool = false) -> SSHHost {
        host("jump", port: bastionPort, password: password)
    }

    /// dev on the two-factor server: the lab key, then a verification code (`verificationCode`).
    static func twofactor() -> SSHHost {
        host("dev", port: twofactorPort)
    }

    /// The two-factor server's code at `date` (RFC 6238: HMAC-SHA1 of the 30 s step, 6 digits; its secret is the bytes
    /// "12345678901234567890", testenv/twofactor/Dockerfile).
    static func verificationCode(at date: Date = Date()) -> String {
        var step = UInt64(date.timeIntervalSince1970 / 30).bigEndian
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: Data(bytes: &step, count: 8),
                                                               using: SymmetricKey(data: Data("12345678901234567890".utf8))))
        let offset = Int(mac[19] & 0x0f)
        let number = UInt32(mac[offset] & 0x7f) << 24 | UInt32(mac[offset + 1]) << 16 | UInt32(mac[offset + 2]) << 8
            | UInt32(mac[offset + 3])
        return String(format: "%06d", number % 1_000_000)
    }

    /// A saved host for a lab account, logging in with the lab key or (`password`) its password. Inside the lab the
    /// servers are "target" and "bastion" on port 22: reached through a jump host or the proxy.
    static func host(_ user: String, hostname: String = "127.0.0.1", port: Int, password: Bool = false) -> SSHHost {
        _ = TestEnvironment.isolated
        var host = SSHHost(label: "\(user)@\(hostname):\(port)", hostname: hostname, port: port, username: user,
                           auth: password ? .password : .keyFile, keyFile: password ? "" : key)
        host.autoReconnect = false
        let knownHosts = TestEnvironment.root + "/lab_known_hosts." + UUID().uuidString.prefix(8)
        host.extraOptions = ["UserKnownHostsFile=\(Quote.configValue(knownHosts))", "IdentityAgent=none"]
        host.hostKeyCheck = .acceptNew
        // Without an IdentityFile, ssh would read the default keys in ~/.ssh.
        if password { host.extraOptions.append("IdentityFile=\(Quote.configValue(TestEnvironment.root + "/no-key"))") }
        return host
    }
}

/// One test's sessions on the lab, with their prompts and commands recorded, and the folders it made on the servers.
/// `withLab` removes the folders and disconnects at the end.
final class LabRun {
    let prompts = Recorder<Prompt>()
    let log = Recorder<LogEntry>()
    private var sessions: [Session] = []
    private var folders: [(session: Session, path: String)] = []

    /// A session whose prompts are recorded and answered by `answer` (nil cancels). No saved passwords and nothing is
    /// saved, unless the test sets `savedPassword` and `savePassword`.
    func session(_ host: SSHHost, jump: SSHHost? = nil, answer: ((Prompt) -> PromptAnswer?)? = nil) throws -> Session {
        let session = Session(host: host, jump: jump, askpass: try AskpassServer(helperPath: TestEnvironment.airscpBinary))
        session.savedPassword = { _ in nil }
        session.savePassword = { _, _ in }
        let prompts = self.prompts, log = self.log
        session.onPrompt = { prompt, reply in
            prompts.append(prompt)
            reply(answer?(prompt))
        }
        session.onLog = { log.append($0) }
        sessions.append(session)
        return session
    }

    func connected(_ host: SSHHost, jump: SSHHost? = nil) async throws -> Session {
        let session = try session(host, jump: jump)
        try await session.connect()
        return session
    }

    /// A new empty folder in `dir` on the session's server.
    func folder(on session: Session, in dir: String) async throws -> String {
        let path = RemotePath.join(dir, "porter-lab-" + UUID().uuidString.prefix(8))
        try await session.makeDirectory(path)
        folders.append((session, path))
        return path
    }

    /// The command log so far (entries arrive on the main queue).
    func logEntries() async -> [LogEntry] {
        await MainActor.run {}
        return log.all
    }

    fileprivate func finish() async {
        for (session, path) in folders.reversed() {
            if session.state != .connected { try? await session.connect() }
            if let entry = try? await session.list(RemotePath.parent(path)).first(where: { $0.path == path }) {
                try? await session.delete([entry])
            }
        }
        for session in sessions {
            await session.disconnect()
            session.askpass.close()
        }
    }
}

/// Runs `body` with a `LabRun` and always cleans up after it.
func withLab(_ body: (LabRun) async throws -> Void) async throws {
    let lab = LabRun()
    do {
        try await body(lab)
    } catch {
        await lab.finish()
        throw error
    }
    await lab.finish()
}

/// Plain scp or sftp to dev on the target with the lab key (no AirSCP, no master connection), to compare speeds with.
func plain(_ tool: String, _ arguments: [String], input: String? = nil) async throws {
    let knownHosts = TestEnvironment.root + "/lab_known_hosts." + UUID().uuidString.prefix(8)
    let result = await Runner.run([tool, "-F", "/dev/null", "-P", String(Lab.targetPort), "-o", "BatchMode=yes",
                                   "-o", "IdentityFile=" + Lab.key, "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
                                   "-o", "UserKnownHostsFile=" + knownHosts, "-o", "StrictHostKeyChecking=accept-new"]
                                  + arguments, input: input)
    guard result.status == 0 else { throw AirSCPError(.other, "\(tool) failed (\(result.status)): \(result.stderr)") }
}

/// How long `body` took, in seconds.
func timed(_ body: () async throws -> Void) async rethrows -> TimeInterval {
    let start = Date()
    try await body()
    return Date().timeIntervalSince(start)
}

/// A job of the queue by id.
func job(_ id: UUID, in session: Session) -> TransferJob? {
    session.transfers.jobs.first { $0.id == id }
}
