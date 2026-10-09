import Darwin
import Foundation
import Security
import Testing
@testable import AirSCPCore

/// Test-wide isolation, set up once: AirSCP's commands get `-F <test ssh_config>` (not ~/.ssh/config), a scratch HOME
/// (ssh-copy-id makes its scratch folder in $HOME/.ssh), no agent, and their own control-socket folder. Every host
/// in the tests names its key file and known_hosts explicitly, so nothing under the real ~/.ssh is used.
enum TestEnvironment {
    /// Everything the tests create (short, because unix socket paths are limited to 104 bytes).
    static let root: String = {
        // Folders of earlier runs whose test process has gone (the name carries its pid).
        for name in (try? FileManager.default.contentsOfDirectory(atPath: "/tmp")) ?? [] where name.hasPrefix("airscp-test.") {
            let pid = name.split(separator: ".").dropFirst().first.flatMap { Int32($0) } ?? 0
            if pid <= 0 || (kill(pid, 0) == -1 && errno == ESRCH) { try? FileManager.default.removeItem(atPath: "/tmp/" + name) }
        }
        var template = Array("/tmp/airscp-test.\(getpid()).XXXXXX".utf8CString)
        // The real path (/private/tmp/…), as sftp reports it.
        return String(cString: realpath(mkdtemp(&template)!, nil))
    }()

    /// The ssh_config every test command gets with -F: only an alias for the ssh -G test, matching no test host.
    static var sshConfig: String { root + "/ssh_config" }

    static let isolated: Void = {
        try? """
            Host airscp-alias other-alias
              HostName 127.0.0.1
              Port 2222
              User airscp-test
              UserKnownHostsFile \(root)/alias_known_hosts
            Host *.airscp-wild
              User nobody
            """.write(toFile: sshConfig, atomically: true, encoding: .utf8)
        OpenSSH.configFile = sshConfig
        Session.socketDirectory = root + "/sockets"
        let home = root + "/local-home"
        try? FileManager.default.createDirectory(atPath: home + "/.ssh", withIntermediateDirectories: true)
        Runner.environmentOverrides = ["HOME": home, "SSH_AUTH_SOCK": ""]
        // No window animations (windows zooming in, fading out): while the Mac's screen is locked they don't run, and a
        // window freed while one was under way crashed the test process later (-[_NSWindowTransformAnimation dealloc]).
        UserDefaults.standard.register(defaults: ["NSAutomaticWindowAnimationsEnabled": false, "NSWindowResizeTime": 0.001])
        // Nothing the panes and windows saved in an earlier run (sort order, columns, frames): a run stopped half-way
        // left the right pane sorted backwards for every test after it.
        UserDefaults.standard.removePersistentDomain(forName: ProcessInfo.processInfo.processName)
        // Never the real settings folder either (a Remote Desktop connection makes its freerdp folder there, and a real
        // ~/Library/Application Support/AirSCP would keep AirSCP's first start from taking over Porter's settings).
        setenv("AIRSCP_SUPPORT_DIR", root + "/support", 1)
        // Never the login Keychain (reading it may wait for the user: with the screen locked, for ever): an empty item,
        // and writes kept in memory only.
        Keychain.readItem = { _ in (errSecItemNotFound, nil) }
        Keychain.writeItem = { _ in errSecSuccess }
        // These stand-ins are the tests' Keychain, whatever AIRSCP_SUPPORT_DIR a test sets (it would make it memory-only).
        Keychain.memoryOnly = false
    }()

    /// The AirSCP executable (askpass helper), built next to the test bundle by `swift test`.
    static var airscpBinary: String {
        Bundle(for: Marker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("AirSCP").path
    }
}

final class Marker {}

/// A thread-safe list.
final class Recorder<Item> {
    private let lock = NSLock()
    private var items: [Item] = []

    func append(_ item: Item) { lock.locked { items.append(item) } }
    var all: [Item] { lock.locked { items } }
}

/// Polls until `condition` holds or `timeout` passes. 120 s: what holds at once on an idle Mac took tens of seconds on
/// CI's three-core runners under the whole suite (whose main queue stalls there for a minute at times), and over a
/// minute on a Mac with twice as many busy threads as cores. Only a failing test waits that long.
func eventually(timeout: TimeInterval = 120, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }
    return await condition()
}

/// A throwaway sshd on 127.0.0.1, run as this user with its own config, host key, authorized_keys, HOME and sftp
/// starting folder (all in a temporary folder). A watchdog shell kills it, and every ssh started for the tests,
/// if the test process dies.
final class TestServer {
    struct Options {
        /// ForceCommand internal-sftp.
        var sftpOnly = false
        var maxSessions: Int?
        /// A Banner, and a login shell startup file that prints to stdout and stderr.
        var noise = false
        /// Password logins allowed. sshd, run as this user, can't check a password: each one is refused, and ssh asks
        /// again (the prompts are what such a test is after).
        var passwords = false
        /// `uname -sr` says Linux (a script first in PATH): the Monitor reads this Mac as a Linux server, which has no
        /// /proc, so its figures and ports stay empty, but every refresh runs its command.
        var linux = false
    }

    static let passphrase = "airscp test passphrase"
    static let noiseLine = "AIRSCP-NOISE: welcome to the test server"

    let root: String
    /// The remote HOME and sftp's starting folder.
    let home: String
    let port: Int
    let plainKey: String
    /// Protected with `passphrase`.
    let encryptedKey: String
    let knownHosts: String
    /// Commands run by every session made with `session(…)`.
    let log = Recorder<LogEntry>()
    /// Prompts shown by every session made with `session(…)`.
    let prompts = Recorder<Prompt>()
    private let watchdog: pid_t
    private var sessions: [Session] = []

    private init(root: String, home: String, port: Int, plainKey: String, encryptedKey: String, knownHosts: String,
                 watchdog: pid_t) {
        self.root = root
        self.home = home
        self.port = port
        self.plainKey = plainKey
        self.encryptedKey = encryptedKey
        self.knownHosts = knownHosts
        self.watchdog = watchdog
    }

    deinit { stopServer() }

    static func start(_ options: Options = Options()) async throws -> TestServer {
        _ = TestEnvironment.isolated
        var template = Array((TestEnvironment.root + "/server.XXXXXX").utf8CString)
        let root = String(cString: mkdtemp(&template)!)
        let home = root + "/home", keys = root + "/keys dir"
        for dir in [home, keys] { try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }
        let plainKey = keys + "/id_plain", encryptedKey = keys + "/id_enc"
        try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "host", "-f", root + "/host_key"])
        try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "plain", "-f", plainKey])
        try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", passphrase, "-C", "encrypted", "-f", encryptedKey])
        let authorized = try String(contentsOfFile: plainKey + ".pub") + String(contentsOfFile: encryptedKey + ".pub")
        try authorized.write(toFile: root + "/authorized_keys", atomically: true, encoding: .utf8)
        var environment = "SetEnv HOME=\(home)"
        var extra = ""
        if options.noise {
            // zsh reads .zshenv; bash run by sshd reads .bashrc (and skips BASH_ENV), as for CI's bash login shell.
            let noise = "echo '\(noiseLine)'\necho 'AIRSCP-NOISE on stderr' >&2\n"
            for file in [".zshenv", ".bashrc"] { try noise.write(toFile: home + "/" + file, atomically: true, encoding: .utf8) }
            try "Hello from the banner\n".write(toFile: root + "/banner", atomically: true, encoding: .utf8)
            environment += " BASH_ENV=\(home)/.zshenv"
            extra += "Banner \(root)/banner\n"
        }
        if options.linux {
            try FileManager.default.createDirectory(atPath: root + "/bin", withIntermediateDirectories: true)
            try "#!/bin/sh\n[ \"$*\" = -sr ] && exec echo Linux 6.12.0-test\nexec /usr/bin/uname \"$@\"\n"
                .write(toFile: root + "/bin/uname", atomically: true, encoding: .utf8)
            chmod(root + "/bin/uname", 0o755)
            environment += " PATH=\(root)/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        if let maxSessions = options.maxSessions { extra += "MaxSessions \(maxSessions)\n" }
        if options.sftpOnly { extra += "ForceCommand internal-sftp -d \(home)\n" }

        for _ in 0..<5 {
            let port = freePort()
            let config = """
                Port \(port)
                ListenAddress 127.0.0.1
                HostKey \(root)/host_key
                AuthorizedKeysFile \(root)/authorized_keys \(home)/.ssh/authorized_keys
                PidFile \(root)/sshd.pid
                UsePAM no
                StrictModes no
                PasswordAuthentication \(options.passwords ? "yes" : "no")
                KbdInteractiveAuthentication no
                PermitUserRC no
                PermitUserEnvironment no
                \(environment)
                Subsystem sftp internal-sftp -d \(home)
                \(extra)
                """
            try config.write(toFile: root + "/sshd_config", atomically: true, encoding: .utf8)
            let logFile = root + "/sshd.log"
            try? FileManager.default.removeItem(atPath: logFile)
            let script = """
                /usr/sbin/sshd -D -f "$1" -E "$2" &
                sshd=$!
                trap 'kill $sshd 2>/dev/null; exit 0' TERM
                while kill -0 "$3" 2>/dev/null && kill -0 $sshd 2>/dev/null; do sleep 1; done
                kill $sshd 2>/dev/null
                kill -0 "$3" 2>/dev/null || pkill -f "$4"
                """
            let watchdog = try Runner.start(["/bin/sh", "-c", script, "sh", root + "/sshd_config", logFile,
                                             String(getpid()), TestEnvironment.root],
                                            environment: [:], stderr: { _ in }, exited: { _ in })
            let server = TestServer(root: root, home: home, port: port, plainKey: plainKey, encryptedKey: encryptedKey,
                                    knownHosts: root + "/known_hosts", watchdog: watchdog)
            let ready = await eventually {
                let text = (try? String(contentsOfFile: logFile)) ?? ""
                return text.contains("Server listening") || text.contains("Bind to port") || text.contains("fatal")
            }
            if ready, ((try? String(contentsOfFile: logFile)) ?? "").contains("Server listening") { return server }
            server.stopServer()
        }
        throw AirSCPError(.other, "The test sshd didn't start; see \(root)/sshd.log")
    }

    /// A host for this server: key-file login, its own known_hosts, no agent. No automatic reconnect: the tests expect
    /// a lost connection to stay Disconnected (reconnect tests switch it on).
    func host(key: String? = nil, trustNewHostKeys: Bool = true) -> SSHHost {
        var host = SSHHost(label: "Test server", hostname: "127.0.0.1", port: port, auth: .keyFile, keyFile: key ?? plainKey)
        host.autoReconnect = false
        host.extraOptions = ["UserKnownHostsFile=\(Quote.configValue(knownHosts))", "IdentityAgent=none"]
        if trustNewHostKeys { host.hostKeyCheck = .acceptNew }
        return host
    }

    /// A session whose prompts are recorded in `prompts` and answered by `answer` (nil cancels). Disconnected by
    /// `shutdown`.
    func session(_ host: SSHHost? = nil, jump: SSHHost? = nil, answer: ((Prompt) -> PromptAnswer?)? = nil) throws -> Session {
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        let session = Session(host: host ?? self.host(), jump: jump, askpass: askpass)
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

    func connectedSession(_ host: SSHHost? = nil, jump: SSHHost? = nil) async throws -> Session {
        let session = try session(host, jump: jump)
        try await session.connect()
        return session
    }

    /// Disconnects the sessions, stops sshd and deletes the server's folder.
    func shutdown() async {
        for session in sessions {
            await session.disconnect()
            session.askpass.close()
        }
        sessions = []
        stopServer()
        _ = await eventually(timeout: 5) { !rawExists(self.root + "/sshd.pid") }  // sshd removes it when it exits
        chmodTree(root)
        try? FileManager.default.removeItem(atPath: root)
    }

    /// Makes everything under `path` writable again, so that tests that locked folders don't block deleting.
    private func chmodTree(_ path: String) {
        for case let relative as String in FileManager.default.enumerator(atPath: path) ?? FileManager.DirectoryEnumerator() {
            var info = stat()
            if lstat(path + "/" + relative, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR { chmod(path + "/" + relative, 0o755) }
        }
    }

    private func stopServer() {
        if let text = try? String(contentsOfFile: root + "/sshd.pid"),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            kill(pid, SIGTERM)
        }
        kill(watchdog, SIGTERM)
    }

    /// The command log so far. Entries arrive on the main queue: running a block there first lets every entry
    /// sent before it arrive.
    func logEntries() async -> [LogEntry] {
        await MainActor.run {}
        return log.all
    }

    /// A path in the remote home.
    func path(_ relative: String) -> String { home + "/" + relative }

    /// A fresh local folder, deleted with the server.
    func scratch() throws -> String {
        let path = root + "/local-" + UUID().uuidString.prefix(8)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Int32 in
                bind(fd, pointer, length)
                return getsockname(fd, pointer, &length)
            }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

/// Runs a tool and throws if it fails.
@discardableResult
func run(_ argv: [String], environment: [String: String] = [:]) async throws -> CommandResult {
    let result = await Runner.run(argv, environment: environment)
    guard result.status == 0 else {
        throw AirSCPError(.other, "\(argv.joined(separator: " ")) failed (\(result.status)): \(result.stderr)")
    }
    return result
}

/// Kills a session's master connection outright (SIGKILL: its socket file stays behind), as a crash or a dropped
/// network would end it.
func killMaster(of session: Session) async throws {
    let pids = try await run(["/usr/bin/pgrep", "-f", "ssh -M -N .*ControlPath=\(session.socketPath)"]).output
    for pid in pids.split(separator: "\n").compactMap({ Int32($0) }) { kill(pid, SIGKILL) }
}

/// Starts a test server, runs `body` and always shuts the server (and its sessions) down.
func withServer(_ options: TestServer.Options = TestServer.Options(), _ body: (TestServer) async throws -> Void) async throws {
    let server = try await TestServer.start(options)
    do {
        try await body(server)
    } catch {
        await server.shutdown()
        throw error
    }
    await server.shutdown()
}

/// Writes a local file, creating its folder.
func write(_ text: String, to path: String) throws {
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try text.write(toFile: path, atomically: false, encoding: .utf8)
}

func writeRandom(bytes: Int, to path: String) throws {
    var data = [UInt8](repeating: 0, count: bytes)
    arc4random_buf(&data, bytes)
    try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try Data(data).write(to: URL(fileURLWithPath: path))
}

/// Writes `bytes` of zeros (real blocks, not a sparse file, so that tar reads them all).
func writeZeros(bytes: Int, to path: String) throws {
    FileManager.default.createFile(atPath: path, contents: nil)
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
    defer { try? handle.close() }
    let chunk = Data(count: 1 << 20)
    for _ in 0..<(bytes >> 20) { handle.write(chunk) }
}

func read(_ path: String) -> String? {
    try? String(contentsOfFile: path, encoding: .utf8)
}

/// Whether anything (even a dangling link) is at `path`.
func exists(_ path: String) -> Bool {
    (try? FileManager.default.attributesOfItem(atPath: path)) != nil
}

/// The names in a local folder, as raw strings (no normalisation).
func names(in folder: String) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).sorted()
}

/// A fresh local scratch folder for one test.
func scratch() throws -> String {
    _ = TestEnvironment.isolated
    let path = TestEnvironment.root + "/local-" + UUID().uuidString.prefix(8)
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

// Byte-exact file helpers: Foundation's path APIs may turn names into decomposed Unicode (NFD).

/// Creates a file at exactly these bytes of `path`.
func rawCreate(_ path: String, _ text: String = "") throws {
    let fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
    guard fd >= 0 else { throw AirSCPError(.other, "can't create \(path): \(String(cString: strerror(errno)))") }
    defer { close(fd) }
    _ = Array(text.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
}

func rawMkdir(_ path: String) throws {
    guard mkdir(path, 0o755) == 0 else { throw AirSCPError(.other, "can't mkdir \(path): \(String(cString: strerror(errno)))") }
}

/// The names in a folder as their exact bytes.
func rawNames(in folder: String) -> [[UInt8]] {
    guard let dir = opendir(folder) else { return [] }
    defer { closedir(dir) }
    var result: [[UInt8]] = []
    while let entry = readdir(dir) {
        let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
            Array(raw.prefix(Int(entry.pointee.d_namlen)).map { $0 })
        }
        if name != [0x2E] && name != [0x2E, 0x2E] { result.append(name) }
    }
    return result.sorted { $0.lexicographicallyPrecedes($1) }
}

func rawExists(_ path: String) -> Bool {
    var info = stat()
    return lstat(path, &info) == 0
}
