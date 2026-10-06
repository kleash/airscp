import CryptoKit
import Darwin
import Foundation
import Network

/// What the server can do, found right after connecting.
public struct Capabilities: Equatable {
    /// Shell commands work (false: an sftp-only account, or a server without a POSIX shell such as Windows).
    public var shell = false
    /// The home folder: $HOME, or sftp's starting folder when there is no shell.
    public var home = "/"
    /// Which of zip, unzip, tar, gzip and python3 the server has.
    public var tools: Set<String> = []
    /// Why shell-only actions are unavailable (nil when `shell`).
    public var noShellReason: String?
    /// A Windows server (its home is like /C:/Users/name): names can't have \\ / : * ? " < > | or end in "." or " ".
    public var windows = false
    /// Names that differ only in case are the same file (Windows, and macOS servers' disks as a rule).
    public var caseInsensitive = false
    /// The account's login shell ("bash", "fish"), when it has a shell.
    public var loginShell = ""

    public init() {}
}

/// A question for the user from ssh (host key, password, passphrase, verification code).
public struct Prompt {
    public let kind: PromptKind
    /// ssh's own wording; show it for `.passphrase` and `.other`.
    public let text: String
    /// The saved host a password is for: this host, or its jump host when the prompt names that one.
    public let host: SSHHost?
    /// The same ssh asks again: the answer it got (typed, or saved in the Keychain) wasn't accepted.
    public var retry = false

    /// Offer "Remember in Keychain": a password for a known saved host.
    public var canRemember: Bool {
        if case .password = kind { return host != nil }
        return false
    }
}

public struct PromptAnswer {
    public var text: String
    /// Save the password in the Keychain once the connection is up (replacing a saved one that was wrong).
    public var remember: Bool

    public init(_ text: String, remember: Bool = false) {
        self.text = text
        self.remember = remember
    }

    /// The answer that trusts a new host key.
    public static let trust = PromptAnswer("yes")
}

/// One host's connection: a master ssh that every other command rides on (ControlPath socket), the capability
/// probe, and the commands AirSCP runs over it. File operations are in RemoteFS.swift, transfers in
/// Transfer.swift. Callbacks arrive on the main queue; the async methods may be called from anywhere.
public final class Session {
    public enum State: Equatable {
        case idle
        /// Connecting (also each attempt of an automatic reconnect, which asks nothing: see `.reconnecting`).
        case connecting
        case connected
        /// The connection dropped and `host.autoReconnect` is on: the next silent attempt starts at `nextTry`
        /// (backoff 2, 5, 15, 30 s, then every 60 s for up to 10 minutes). Banner: "Reconnecting… next try in N s"
        /// with Cancel (`cancelReconnect()`); `connect()` tries at once, asking as usual. Ends in `.connected`, or
        /// `.disconnected` when an attempt would need a question or the time is up.
        case reconnecting(nextTry: Date)
        /// The master connection ended on its own: show the Disconnected banner with Reconnect.
        case disconnected(AirSCPError)
    }

    /// Where the control sockets live (checked to be private to this user). Tests point it elsewhere.
    public static var socketDirectory = "/tmp/airscp-\(getuid())"

    /// The control socket for a saved host: keyed on its id, since %C would mix up hosts that differ only in
    /// their jump host or options, and on the settings folder: two AirSCPs with folders of their own
    /// (AIRSCP_SUPPORT_DIR) and the same hosts (a copied airscp.json) took over and ended each other's connections.
    public static func socketPath(for id: UUID, folder: String = Store.directory.path) -> String {
        let digest = SHA256.hash(data: Data((folder + "\n" + id.uuidString).utf8))
        return socketDirectory + "/" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    public let host: SSHHost
    public let jump: SSHHost?
    public let socketPath: String
    /// The transfer queue (one transfer at a time).
    public let transfers: TransferQueue

    public var onStateChange: ((State) -> Void)?
    /// Every command run for this host, when it finishes (the master also when it starts).
    public var onLog: ((LogEntry) -> Void)?
    /// A prompt to show (as a sheet on the host's window); reply with the answer, or nil to cancel.
    public var onPrompt: ((Prompt, @escaping (PromptAnswer?) -> Void) -> Void)?
    /// Saved passwords. The Keychain; tests replace them.
    public var savedPassword: (SSHHost) -> String? = { Keychain.password(for: $0.id) }
    public var savePassword: (SSHHost, String) -> Void = { Keychain.setPassword($1, for: $0.id) }

    public var state: State { lock.locked { _state } }
    /// The masters started so far: a different number after a command than before it means the connection under it
    /// was lost meanwhile (it may be back already: an automatic reconnect).
    public var masterNumber: Int { lock.locked { masterGeneration } }
    /// Reconnecting by itself: waiting for its next try, or trying (`.connecting` without asking).
    public var isReconnecting: Bool {
        lock.locked {
            if case .reconnecting = _state { return true }
            return _state == .connecting && openingSilently
        }
    }
    /// Reconnect by itself after a lost connection: the host's setting, changed in place when the host is edited (it is
    /// AirSCP's own, not ssh's: no new connection needed).
    public var autoReconnect: Bool {
        get { lock.locked { _autoReconnect } }
        set { lock.locked { _autoReconnect = newValue } }
    }
    public internal(set) var capabilities: Capabilities {
        get { lock.locked { _capabilities } }
        set { lock.locked { _capabilities = newValue } }
    }
    /// The tunnels switched on (all go off when the connection ends; an automatic reconnect switches them on again).
    public var activeTunnels: Set<UUID> { lock.locked { Set(_activeTunnels.keys) } }

    let askpass: AskpassServer
    private let lock = NSLock()
    private var _state = State.idle
    private var _capabilities = Capabilities()
    private var _activeTunnels: [UUID: Tunnel] = [:]
    /// The tunnels that were on when the connection was lost: the automatic reconnect that works switches them on again.
    private var tunnelsToRestore: [Tunnel] = []
    private var _autoReconnect: Bool
    private var masterPID: pid_t = 0
    /// Counts the masters started: a replaced master's late exit or output must not count for the current one.
    private var masterGeneration = 0
    private var masterExit: Int32?
    private var masterErrors = ""
    private var tearingDown = false
    /// Automatic reconnecting (`lost` starts it when the host has `autoReconnect`): the loop, its attempt count
    /// (for the delay), since when (it gives up after `reconnectWindow`), and the error that ended the connection.
    private var reconnectTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var reconnectSince = Date()
    private var reconnectError = AirSCPError.disconnected
    /// The connect under way is an automatic one; it refused a prompt (so it needs the user).
    private var openingSilently = false
    private var silentRefused = false
    private var networkUpdates = 0
    private var wakes = 0
    /// How long automatic attempts go on (tests shorten it).
    var reconnectWindow: TimeInterval = 600
    /// Seconds before each automatic attempt; the last one repeats.
    static let reconnectDelays: [TimeInterval] = [2, 5, 15, 30, 60]
    /// Processes that got a saved password: if one asks again, the saved password was wrong.
    private var answeredFromKeychain: Set<Int32> = []
    /// The questions answered so far, by asking process and question (a second time means the answer was refused).
    private var answeredPrompts: Set<String> = []
    private var rememberedPasswords: [UUID: String] = [:]
    private var running: [Cancellation] = []
    private let controlLane = Lane()
    /// Watches an adopted master's process (see `watch(adopted:)`).
    private var adoptedWatch: DispatchSourceProcess?

    public init(host: SSHHost, jump: SSHHost?, askpass: AskpassServer) {
        self.host = host
        self.jump = jump
        self.askpass = askpass
        _autoReconnect = host.autoReconnect
        socketPath = Session.socketPath(for: host.id)
        transfers = TransferQueue(hostID: host.id)
        transfers.session = self
        DebugLog.name(host)
        askpass.setHandler({ [weak self] request, reply in
            guard let self else { return reply(nil) }
            self.handlePrompt(request, reply: reply)
        }, for: host.id.uuidString)
    }

    deinit {
        // The askpass handler stays registered: it cancels prompts once this session is gone, and removing it here
        // would remove the handler of a newer Session for the same host (a window closed and opened again).
        reconnectTask?.cancel()
        if masterPID > 0 { kill(-masterPID, SIGTERM) }
    }

    // MARK: Connecting

    /// Opens the master connection (prompts go to `onPrompt`), then probes what the server can do. A live master
    /// for this host left by an earlier AirSCP is adopted instead. Throws a mapped error when ssh gives up.
    /// While reconnecting by itself, this stops that and tries at once, asking as usual.
    public func connect() async throws {
        await stopReconnecting()
        try await open(silent: false)
    }

    /// `connect`, or with `silent` one automatic attempt, which starts only while `.reconnecting`, asks nothing
    /// (a saved password may answer once) and leaves the state to `reconnectFailed` when it fails.
    private func open(silent: Bool) async throws {
        let start: Bool = lock.locked {
            switch _state {
            case .connecting, .connected:
                return false
            case .idle, .disconnected:
                if silent { return false }
            case .reconnecting:
                break
            }
            _state = .connecting
            tearingDown = false
            answeredFromKeychain = []
            answeredPrompts = []
            rememberedPasswords = [:]
            openingSilently = silent
            silentRefused = false
            return true
        }
        guard start else { return }
        defer { lock.locked { openingSilently = false } }
        notifyState()
        if DebugLog.enabled {
            let attempt = lock.locked { reconnectAttempt } + 1
            DebugLog.write((silent ? "Reconnecting by itself (attempt \(attempt)): " : "Connecting: ") + route, host: host.displayName)
        }
        do {
            try Session.prepareSocketDirectory()
            if access(socketPath, F_OK) == 0 {
                if let pid = await runningMaster() {
                    log.log("adopted the running master for \(self.host.id, privacy: .public)")
                    try finishConnecting()
                    watch(adopted: pid)
                    await probe()
                    notifyState()
                    return
                }
                unlink(socketPath)  // left by a master that was killed; ssh -M won't replace it
            }
            if let error = OpenSSH.missingJump(host, jump: jump) { throw error }
            try startMaster(silent: silent)
            try await waitForMaster()
            try finishConnecting()
        } catch {
            if DebugLog.enabled, let error = error as? AirSCPError {
                DebugLog.write(error.kind == .cancelled ? "Connecting was cancelled"
                    : "Couldn't connect: it stopped \(Session.failedHop(error.details, host: host, jump: jump)): \(error.message)"
                        + (error.details.isEmpty ? "" : "\nssh's own words:\n" + error.details), host: host.displayName)
            }
            let pid = lock.locked { () -> pid_t in
                if _state == .connecting {
                    _state = silent ? .disconnected(error as? AirSCPError ?? AirSCPError.disconnected) : .idle
                }
                return masterPID
            }
            if pid > 0 { kill(-pid, SIGTERM) }
            if !silent { notifyState() }
            throw error
        }
        saveRememberedPasswords()
        await probe()
        if silent {  // before Connected is shown: the Tunnels tab then shows them on
            for tunnel in lock.locked({ tunnelsToRestore }) { try? await startTunnel(tunnel) }
            lock.locked { tunnelsToRestore = [] }
        }
        notifyState()
    }

    /// Adopts a live master left by an earlier AirSCP (after a crash), without starting one.
    /// Returns false (and removes a dead socket) when there is none.
    public func adopt() async -> Bool {
        switch state {
        case .connected: return true
        case .connecting: return false
        case .idle, .disconnected, .reconnecting: break
        }
        guard access(socketPath, F_OK) == 0 else { return false }
        guard let pid = await runningMaster() else {
            unlink(socketPath)
            return false
        }
        lock.locked { _state = .connected }
        watch(adopted: pid)
        await probe()
        notifyState()
        return true
    }

    /// A master left by an earlier AirSCP isn't AirSCP's child, so its end isn't reported: the system tells when that
    /// process exits, and the session then finds out what happened (Disconnected, or reconnecting by itself).
    private func watch(adopted pid: pid_t) {
        guard pid > 0 else { return }  // ssh didn't say: noticed when a command finds it gone
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler { [weak self, weak source] in
            source?.cancel()
            guard let self else { return }
            Task { _ = await self.check() }
        }
        lock.locked {
            adoptedWatch?.cancel()
            adoptedWatch = source
        }
        source.resume()
    }

    /// The pid of the master answering at the socket ("Master running (pid=…)"; 0 if it doesn't say), nil when none
    /// answers.
    private func runningMaster() async -> pid_t? {
        let result = await Runner.run(OpenSSH.control("check", host, jump: jump, socket: socketPath), hostID: host.id, log: emit)
        guard result.status == 0 else { return nil }
        let digits = result.stderr.components(separatedBy: "pid=").dropFirst().first?.prefix { $0.isNumber } ?? ""
        return pid_t(digits) ?? 0
    }

    /// Cancels the transfers (cleaning up their partial files while the connection is still there, and the partial
    /// copies kept for retrying after a lost connection) and any running command, then closes the master (ssh -O exit).
    /// Also stops reconnecting.
    public func disconnect() async {
        await stopReconnecting()
        let wasConnected = lock.locked { () -> Bool in
            tearingDown = true
            return _state == .connected
        }
        await transfers.cancelAll()
        let cancellations = lock.locked { running }
        cancellations.forEach { $0.cancel() }
        askpass.cancelPending(for: host.id.uuidString)
        if wasConnected {
            _ = await Runner.run(OpenSSH.control("exit", host, jump: jump, socket: socketPath), hostID: host.id, log: emit)
        }
        let pid = lock.locked { masterPID }
        if pid > 0 {
            if !wasConnected { kill(-pid, SIGTERM) }  // still connecting
            for _ in 0..<30 where lock.locked({ masterPID }) != 0 {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            if lock.locked({ masterPID }) != 0 { kill(-pid, SIGTERM) }
        }
        lock.locked {
            _state = .idle
            _activeTunnels = [:]
        }
        notifyState()
    }

    /// Asks the master whether it is still there; marks the session Disconnected when it isn't. AirSCP sees its own
    /// master exit, but not an adopted one: call this now and then (e.g. when the window becomes active).
    public func check() async -> Bool {
        guard state == .connected else { return false }
        if await masterAlive() { return true }
        lost(AirSCPError.disconnected)
        return false
    }

    // MARK: Automatic reconnect

    /// Stops reconnecting (the banner's Cancel, or the host was edited): `.reconnecting` becomes `.disconnected`.
    public func cancelReconnect() {
        let (task, changed) = lock.locked { () -> (Task<Void, Never>?, Bool) in
            defer { reconnectTask = nil }
            switch _state {
            case .reconnecting: break
            case .connecting where openingSilently: tearingDown = true  // abort the attempt under way
            default: return (reconnectTask, false)
            }
            _state = .disconnected(reconnectError)
            return (reconnectTask, true)
        }
        task?.cancel()
        if changed { notifyState() }
    }

    /// The Mac woke from sleep (NSWorkspace.didWakeNotification; the app calls this for every session). After 2 s:
    /// a connected session checks its master; one that is reconnecting tries again with the backoff reset.
    /// (Network changes are watched inside AirSCPCore with NWPathMonitor.)
    public func didWake() {
        let wake = lock.locked { () -> Int in
            wakes += 1
            return wakes
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            let connected = self.lock.locked { () -> Bool in
                guard self.wakes == wake else { return false }  // a later wake starts its own 2 s
                if case .reconnecting = self._state {
                    self.reconnectAttempt = 0
                    self.reconnectSince = Date()
                    self._state = .reconnecting(nextTry: Date())
                }
                return self._state == .connected
            }
            if connected { Task { _ = await self.check() } }
        }
    }

    /// The loop behind `.reconnecting`: waits for each attempt's time (which a working network again or a wake brings
    /// forward), then tries once, until connected, given up or stopped. NWPathMonitor runs only meanwhile.
    private func startReconnecting() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in self?.networkChanged(satisfied: path.status == .satisfied) }
        let task = Task.detached(priority: .utility) { [weak self] in
            monitor.start(queue: DispatchQueue.global(qos: .utility))
            defer { monitor.cancel() }
            while !Task.isCancelled {
                guard let wait = self?.reconnectWait() else { return }
                if wait > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(min(wait, 0.25) * 1_000_000_000))
                } else if await self?.reconnectOnce() != true {
                    return
                }
            }
        }
        lock.locked {
            reconnectTask?.cancel()
            reconnectTask = task
        }
    }

    /// Seconds until the next automatic attempt; nil when not reconnecting.
    private func reconnectWait() -> TimeInterval? {
        lock.locked {
            if case .reconnecting(let next) = _state { return next.timeIntervalSinceNow }
            return nil
        }
    }

    /// One automatic attempt; true when another should follow. After it worked, the transfers that failed because the
    /// connection was lost run again.
    private func reconnectOnce() async -> Bool {
        do {
            try await open(silent: true)
        } catch {
            return reconnectFailed(error as? AirSCPError ?? AirSCPError(.other, error.localizedDescription))
        }
        if state == .connected {
            transfers.retryDisconnected()
            TransferCenter.shared.retryRelays(from: host.id)
        }
        return false
    }

    /// After a failed attempt: give up (`.disconnected`) when logging in needs the user or the time is up, else wait
    /// for the next delay.
    private func reconnectFailed(_ error: AirSCPError) -> Bool {
        let (again, changed) = lock.locked { () -> (Bool, Bool) in
            // Stopped by Cancel, Connect or Disconnect, which set the state themselves.
            guard !Task.isCancelled, case .disconnected = _state else { return (false, false) }
            let needsUser: Bool
            switch error.kind {
            case .authFailed, .tooManyAuthFailures, .hostKeyChanged, .hostKeyRejected, .cancelled: needsUser = true
            default: needsUser = silentRefused
            }
            if needsUser || Date().timeIntervalSince(reconnectSince) >= reconnectWindow {
                let message = needsUser ? "The connection to the server was lost. Logging in again needs you: click Reconnect."
                    : AirSCPError.disconnected.message
                let details = [error.message, error.details].filter { !$0.isEmpty }.joined(separator: "\n")
                _state = .disconnected(AirSCPError(.disconnected, message, details: details))
                return (false, true)
            }
            reconnectAttempt += 1
            let delay = Session.reconnectDelays[min(reconnectAttempt, Session.reconnectDelays.count - 1)]
            _state = .reconnecting(nextTry: Date().addingTimeInterval(delay))
            return (true, true)
        }
        if changed { notifyState() }
        return again
    }

    /// Ends automatic reconnecting before Connect or Disconnect, aborting an attempt under way.
    private func stopReconnecting() async {
        let task = lock.locked { () -> Task<Void, Never>? in
            if openingSilently, case .connecting = _state { tearingDown = true }
            defer { reconnectTask = nil }
            return reconnectTask
        }
        task?.cancel()
        await task?.value
    }

    /// A network path report while reconnecting (the first is how it is now): when the network works, try now, with
    /// the backoff and the time allowed starting again, as after a wake.
    func networkChanged(satisfied: Bool) {
        lock.locked {
            networkUpdates += 1
            guard networkUpdates > 1, satisfied, case .reconnecting = _state else { return }
            reconnectAttempt = 0
            reconnectSince = Date()
            _state = .reconnecting(nextTry: Date())
        }
    }

    /// After a "host key changed" error: removes the old keys of the server ssh refused from known_hosts (ssh-keygen -R),
    /// so that the next connect asks to trust the new key. That server and the file are the ones ssh named (through a
    /// jump host, it may be the jump host whose key changed); failing that, this host under "[host]:port" for ports
    /// other than 22, with the host name and file that `ssh -G` reports.
    public func removeOldHostKey() async throws {
        let changed = ErrorMapping.changedHostKey(in: lock.locked { masterErrors })
        var name = changed?.name, knownHosts = changed?.file
        if name == nil || knownHosts == nil {
            guard let resolved = await SSHConfig.resolve(host, jump: jump, log: emit), let file = resolved.knownHostsFiles.first else {
                throw AirSCPError(.other, "ssh couldn't tell which known_hosts file to change.")
            }
            name = name ?? resolved.hostKeyAlias ?? (resolved.port == 22 ? resolved.hostname : "[\(resolved.hostname)]:\(resolved.port)")
            knownHosts = knownHosts ?? file
        }
        let result = await Runner.run(OpenSSH.removeHostKey(name!, knownHosts: knownHosts!), hostID: host.id, log: emit)
        guard result.status == 0 else { throw ErrorMapping.map(result.stderr, status: result.status) }
    }

    // MARK: Commands

    /// Runs a command typed by the user (or a snippet) in the login shell, as typed; with `sh`, a command AirSCP wrote
    /// (`executeCommand`: a server's file name in POSIX quoting) goes to `sh -s` on standard input instead, as every
    /// script does (`OpenSSH.longScript`), so that the login shell never reads the name. The result carries its
    /// output, error output and exit status; it throws only when it couldn't run (disconnected, cancelled, …).
    /// `output` and `errorOutput` get them as they come (on a background thread; the error output starts with the
    /// shell's pid, which `RemotePID.removed` takes out), so that what a stopped command printed can be shown.
    public func run(_ command: String, sh: Bool = false, cancellation: Cancellation? = nil, output: ((Data) -> Void)? = nil,
                    errorOutput: ((Data) -> Void)? = nil) async throws -> CommandResult {
        try requireShell()
        // sshd starts the login shell in a process group of its own, and without a terminal no hangup reaches it when ssh
        // ends: the shell's pid comes first on the error output, and a cancel ends that whole group on the server too.
        // (Not under fish, whose $$ isn't the pid; sh, which the login shell becomes with exec, has its pid.)
        guard sh || capabilities.loginShell != "fish" else {
            return try await runControl(OpenSSH.remote(command, host, jump: jump, socket: socketPath), cancellation: cancellation,
                                        standardOutput: output, errorOutput: errorOutput)
        }
        let cancellation = cancellation ?? Cancellation()
        let pid = RemotePID()
        cancellation.onCancel { [weak self] in
            // Not once the command has ended: its pid may be another process's by then.
            guard !pid.ended else { return }
            Task {
                // The pid may still be on its way here (error output is read as it comes).
                for _ in 0..<40 where pid.value == nil { try? await Task.sleep(nanoseconds: 50_000_000) }
                guard let self, let group = pid.value else { return }
                _ = try? await self.shell("kill -TERM -\(group) 2>/dev/null || kill -TERM \(group) 2>/dev/null; true", slot: .transfer)
            }
        }
        let marked = "echo \(RemotePID.marker)$$ >/dev/stderr; " + command
        let (remote, input) = sh ? OpenSSH.longScript(marked) : (marked, nil)
        defer { pid.end() }
        var result = try await runControl(OpenSSH.remote(remote, host, jump: jump, socket: socketPath), input: input,
                                          cancellation: cancellation, standardOutput: output,
                                          errorOutput: { pid.read($0); errorOutput?($0) })
        result.stderr = RemotePID.removed(from: result.stderr)
        return result
    }

    /// Switches a saved tunnel on (ssh -O forward over the master). A busy port throws `.portInUse`.
    public func startTunnel(_ tunnel: Tunnel) async throws {
        try ensureConnected()
        if tunnel.kind != .remote && tunnel.listenPort < 1024 {  // ssh listens on this Mac's loopback: root only
            throw AirSCPError(.permissionDenied, "Ports below 1024 on this Mac need administrator rights, so ssh can't open "
                + "port \(tunnel.listenPort). Choose 1024 or higher in the tunnel's settings.")
        }
        // ssh listens with SO_REUSEADDR, so it would share a port another program already listens on (on all addresses,
        // say) and connections would go to either: ask whether anything answers there first.
        if tunnel.kind != .remote && Session.answers(onLoopback: tunnel.listenPort) {
            throw AirSCPError(.portInUse, "The port \(tunnel.listenPort) is already in use on this Mac: another program or "
                + "tunnel listens on it. Choose another port in the tunnel's settings.")
        }
        try await forward("forward", tunnel)
        lock.locked { _activeTunnels[tunnel.id] = tunnel }
    }

    /// Whether something on this Mac accepts connections on 127.0.0.1:`port`.
    static func answers(onLoopback port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0, (1...65535).contains(port) else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }

    /// Switches a tunnel off (ssh -O cancel).
    public func stopTunnel(_ tunnel: Tunnel) async throws {
        defer {
            lock.locked {
                _activeTunnels[tunnel.id] = nil
                tunnelsToRestore.removeAll { $0.id == tunnel.id }  // switched off while reconnecting (a desktop's)
            }
        }
        guard state == .connected else { return }
        try await forward("cancel", tunnel)
    }

    private func forward(_ command: String, _ tunnel: Tunnel) async throws {
        let argv = OpenSSH.control(command, host, jump: jump, socket: socketPath, forward: tunnel.forwardArguments)
        let result = await Runner.run(argv, hostID: host.id, log: emit)
        guard result.status == 0 else {
            let error = ErrorMapping.map(result.stderr, status: result.status)
            if error.kind == .disconnected { lost(error) }
            throw error
        }
    }

    /// Installs a public key for this account: ssh-copy-id (it logs in by itself, so prompts may come), or for an
    /// sftp-only account (known once connected) by appending to ~/.ssh/authorized_keys over sftp.
    public func installKey(_ publicKeyPath: String) async throws {
        if let error = OpenSSH.missingJump(host, jump: jump) { throw error }  // ssh-copy-id logs in afresh
        if state == .connected && !capabilities.shell {
            try await installKeyOverSFTP(publicKeyPath)
            return
        }
        // ssh-copy-id evaluates the key file's name as shell words ($(…) in a name would run here): it gets links with
        // plain names to the key pair instead.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("airscp-key-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = folder.appendingPathComponent("key").path
        let privateKey = publicKeyPath.hasSuffix(".pub") ? String(publicKeyPath.dropLast(4)) : publicKeyPath
        guard symlink(publicKeyPath, link + ".pub") == 0 else {
            throw AirSCPError(.noSuchFile, "Can't read \(publicKeyPath): \(String(cString: strerror(errno)))")
        }
        if access(privateKey, F_OK) == 0 { symlink(privateKey, link) }  // ssh-copy-id's "already installed?" test uses it
        let result = await Runner.run(OpenSSH.copyID(link + ".pub", host, jump: jump),
                                      environment: askpass.environment(for: host.id.uuidString), hostID: host.id, log: emit)
        guard result.status == 0 else { throw ErrorMapping.map(result.stderr, status: result.status) }
        saveRememberedPasswords()  // a password typed with "Remember" worked
    }

    // MARK: Running over the master (used by RemoteFS and Transfer)

    /// Which of the host's two concurrent sessions a command uses: the control lane, or the transfer queue's
    /// (whose clean-up commands run between its scp runs).
    enum Slot { case control, transfer }

    /// sftp batch lines (one invocation: the first failure stops it and is thrown, unless the line starts with "-").
    @discardableResult
    func sftp(_ lines: [String], slot: Slot = .control, cancellation: Cancellation? = nil) async throws -> CommandResult {
        let result = try await runOver(slot, OpenSSH.sftpBatch(host, jump: jump, socket: socketPath),
                                       input: lines.joined(separator: "\n") + "\n", cancellation: cancellation)
        guard result.status == 0 else { throw ErrorMapping.map(result.stderr, status: result.status) }
        return result
    }

    /// A one-line POSIX sh script on the server; its output, throwing when it exits non-zero.
    @discardableResult
    func shell(_ script: String, slot: Slot = .control, cancellation: Cancellation? = nil) async throws -> String {
        String(decoding: try await shellBytes(script, slot: slot, cancellation: cancellation), as: UTF8.self)
    }

    /// `shell`, its output as the bytes that came. `output` gets them as they come too (the sentinel's markers
    /// included: see `sentinelScript`), on a background thread.
    func shellBytes(_ script: String, slot: Slot = .control, cancellation: Cancellation? = nil,
                    output: ((Data) -> Void)? = nil) async throws -> Data {
        try requireShell()
        let (output, status, stderr) = try await sentinelShell(script, slot: slot, cancellation: cancellation, output: output)
        guard status == 0 else { throw ErrorMapping.map(stderr, status: status) }
        return output
    }

    func requireShell() throws {
        let capabilities = self.capabilities
        guard capabilities.shell else {
            throw AirSCPError(.sftpOnly, capabilities.noShellReason ?? "This server doesn't run shell commands.")
        }
    }

    /// Runs over the master in the control lane: one command at a time per host, next to at most one transfer
    /// (two sessions, which even MaxSessions 2 allows).
    func runControl(_ argv: [String], input: String? = nil, cancellation: Cancellation? = nil,
                    standardOutput: ((Data) -> Void)? = nil, errorOutput: ((Data) -> Void)? = nil) async throws -> CommandResult {
        try await controlLane.run {
            try await runMuxed(argv, input: input, cancellation: cancellation, standardOutput: standardOutput, errorOutput: errorOutput)
        }
    }

    private func runOver(_ slot: Slot, _ argv: [String], input: String? = nil, cancellation: Cancellation? = nil,
                         standardOutput: ((Data) -> Void)? = nil) async throws -> CommandResult {
        switch slot {
        case .control: return try await runControl(argv, input: input, cancellation: cancellation, standardOutput: standardOutput)
        case .transfer: return try await runMuxed(argv, input: input, cancellation: cancellation, standardOutput: standardOutput)
        }
    }

    /// Runs over the master. A missing socket or "Control socket connect" means the master is gone: Disconnected,
    /// no fallback. "session request failed" means the server is out of sessions: wait and retry.
    func runMuxed(_ argv: [String], input: String? = nil, cancellation: Cancellation? = nil, terminal: ((Data) -> Void)? = nil,
                  standardOutput: ((Data) -> Void)? = nil, errorOutput: ((Data) -> Void)? = nil) async throws -> CommandResult {
        let cancellation = cancellation ?? Cancellation()
        lock.locked { running.append(cancellation) }
        defer { lock.locked { running.removeAll { $0 === cancellation } } }
        var attempts = 0
        while true {
            try ensureConnected()
            let result: CommandResult
            if let terminal {
                result = await Runner.runOnTerminal(argv, input: input, cancellation: cancellation, hostID: host.id, log: emit,
                                                    output: terminal)
            } else {
                result = await Runner.run(argv, input: input, cancellation: cancellation, hostID: host.id, log: emit,
                                          standardOutput: standardOutput, errorOutput: errorOutput)
            }
            if cancellation.isCancelled { throw AirSCPError.cancelled }
            if ErrorMapping.masterGone(result.stderr) {
                let error = AirSCPError(.disconnected, AirSCPError.disconnected.message, details: result.stderr)
                lost(error)
                throw error
            }
            if result.status != 0 && result.stderr.contains("session request failed") && attempts < 20 {
                attempts += 1
                try? await Task.sleep(nanoseconds: 500_000_000)
                continue
            }
            // A command cut off by the master's end exits 255 (scp 1: "lost connection") without saying why.
            if result.status == 255 || result.stderr.contains("lost connection") {
                let alive = state == .connected ? await masterAlive() : false
                if !alive {
                    let error = AirSCPError(.disconnected, AirSCPError.disconnected.message, details: result.stderr)
                    lost(error)
                    throw error
                }
            }
            return result
        }
    }

    /// The sentinel-wrapped script's output, status (of the script, not of ssh) and error output (after the login
    /// noise). A long script (many names) goes to `sh -s` on standard input: a server takes a command line of at most
    /// 128 KB, and ssh's connection sharing even less.
    private func sentinelShell(_ script: String, slot: Slot = .control, cancellation: Cancellation? = nil,
                               output: ((Data) -> Void)? = nil) async throws -> (Data, Int32, String) {
        let (command, input) = OpenSSH.longScript(OpenSSH.sentinelScript(script))
        let argv = OpenSSH.remote(command, host, jump: jump, socket: socketPath)
        let result = try await runOver(slot, argv, input: input, cancellation: cancellation, standardOutput: output)
        guard let (output, status) = OpenSSH.parseSentinel(result.stdout) else {
            // No shell ran it. ("This service allows sftp connections only." comes on standard output.)
            throw ErrorMapping.map(result.stderr + result.output, status: result.status == 0 ? 1 : result.status)
        }
        return (output, status, OpenSSH.afterMarker(result.stderr))
    }

    func ensureConnected() throws {
        switch state {
        case .connected:
            guard access(socketPath, F_OK) == 0 else {
                // A master that ends removes its socket; then ssh would quietly log in afresh.
                lost(AirSCPError.disconnected)
                throw AirSCPError.disconnected
            }
        case .disconnected(let error):
            throw error
        case .reconnecting:
            throw AirSCPError.disconnected
        case .idle, .connecting:
            throw AirSCPError(.disconnected, "Not connected. Click Connect in the banner first.")
        }
    }

    func emit(_ entry: LogEntry) {
        onLog?(entry)
    }

    // MARK: Internals

    private static func prepareSocketDirectory() throws {
        let dir = socketDirectory
        if mkdir(dir, 0o700) != 0 && errno != EEXIST {
            throw AirSCPError(.other, "Can't create \(dir): \(String(cString: strerror(errno)))")
        }
        var info = stat()
        guard lstat(dir, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw AirSCPError(.other, "\(dir) must be a folder that only you can use. Remove it and try again.")
        }
    }

    private func startMaster(silent: Bool) throws {
        let argv = OpenSSH.master(host, jump: jump, socket: socketPath, silent: silent)
        var environment = askpass.environment(for: host.id.uuidString)
        if silent { environment["AIRSCP_SILENT"] = "1" }  // the helpers then ask nothing (prompts, proxy password)
        let line = Runner.shellLine(argv)
        let id = host.id
        DispatchQueue.main.async { self.emit(LogEntry(date: Date(), hostID: id, command: line, status: nil, stderr: "")) }
        let (generation, previous) = lock.locked { () -> (Int, pid_t) in
            masterGeneration += 1
            masterExit = nil
            masterErrors = ""
            defer { masterPID = 0 }
            return (masterGeneration, masterPID)
        }
        if previous > 0 { kill(-previous, SIGTERM) }  // still running but unreachable (its socket was removed)
        let pid = try Runner.start(argv, environment: environment, hostID: host.id, stderr: { [weak self] text in
            guard let self else { return }
            self.lock.locked {
                if self.masterGeneration == generation { self.masterErrors = String((self.masterErrors + text).suffix(32768)) }
            }
        }, exited: { [weak self] status in
            self?.masterExited(status, line: line, generation: generation)
        })
        lock.locked { masterPID = pid }
    }

    private func masterExited(_ status: Int32, line: String, generation: Int) {
        let (current, wasConnected, errors, userInitiated) = lock.locked { () -> (Bool, Bool, String, Bool) in
            guard generation == masterGeneration else { return (false, false, "", false) }
            masterPID = 0
            masterExit = status
            return (true, _state == .connected, masterErrors, tearingDown)
        }
        let entry = LogEntry(date: Date(), hostID: host.id, command: line, status: status, stderr: errors)
        DispatchQueue.main.async { self.emit(entry) }
        if current && wasConnected && !userInitiated {
            var error = ErrorMapping.map(errors, status: status)
            if error.kind != .disconnected { error = AirSCPError(.disconnected, AirSCPError.disconnected.message, details: error.details) }
            lost(error)
        }
    }

    /// Waits until the master answers -O check, or throws what made it exit.
    private func waitForMaster() async throws {
        while true {
            let (exit, errors, cancelled) = lock.locked { (masterExit, masterErrors, tearingDown) }
            if cancelled { throw AirSCPError.cancelled }
            if let exit { throw ErrorMapping.map(errors, status: exit, keyFiles: keyFiles) }
            // The master creates the socket once it has logged in.
            if access(socketPath, F_OK) == 0, await masterAlive() { return }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// The key files this host and its jump host log in with (full paths).
    private var keyFiles: [String] {
        [host, jump].compactMap { $0 }.filter { $0.auth == .keyFile && !$0.keyFile.isEmpty }
            .map { ($0.keyFile as NSString).expandingTildeInPath }
    }

    /// Connected (announced once the probe has run, so that `capabilities` are known by then).
    private func finishConnecting() throws {
        let cancelled = lock.locked { () -> Bool in
            if tearingDown { return true }
            _state = .connected
            return false
        }
        if cancelled { throw AirSCPError.cancelled }
    }

    private func masterAlive() async -> Bool {
        await Runner.run(OpenSSH.control("check", host, jump: jump, socket: socketPath), hostID: host.id, log: emit).status == 0
    }

    /// The master is gone: Disconnected, or with `autoReconnect` reconnecting by itself; tunnels off (an automatic
    /// reconnect switches them on again), queued transfers failed (with Retry; an automatic reconnect retries them),
    /// prompts cancelled.
    func lost(_ error: AirSCPError) {
        let (changed, reconnect) = lock.locked { () -> (Bool, Bool) in
            guard _state == .connected else { return (false, false) }
            let wereOn = Array(_activeTunnels.values)
            _activeTunnels = [:]
            guard _autoReconnect && !tearingDown else {
                _state = .disconnected(error)
                return (true, false)
            }
            tunnelsToRestore = wereOn
            _state = .reconnecting(nextTry: Date().addingTimeInterval(Session.reconnectDelays[0]))
            reconnectAttempt = 0
            reconnectSince = Date()
            reconnectError = error
            networkUpdates = 0
            return (true, true)
        }
        guard changed else { return }
        notifyState()
        transfers.failQueued(error)
        askpass.cancelPending(for: host.id.uuidString)
        if reconnect { startReconnecting() }
    }

    private func notifyState() {
        let state = self.state
        if DebugLog.enabled { DebugLog.write("State: " + describe(state), host: host.displayName) }
        DispatchQueue.main.async { self.onStateChange?(state) }
    }

    // MARK: Debug log (PLAN.md AE)

    /// The way to the server: "This Mac → HTTP proxy → jump host “bastion” (jump@bastion:22) → “private” (dev@private:22)".
    private var route: String {
        let proxied = (jump ?? host).proxyID != nil  // with a jump host, its proxy is the first hop's
        return (["This Mac"] + (proxied ? ["HTTP proxy"] : []) + (jump.map { ["jump host " + Session.named($0)] } ?? [])
                + [Session.named(host)]).joined(separator: " → ")
    }

    /// “bastion” (jump@bastion:22), or the address alone for a host without a label.
    static func named(_ host: SSHHost) -> String {
        let address = (host.username.isEmpty ? "" : host.username + "@") + host.hostname + ":\(host.port ?? 22)"
        return host.label.isEmpty ? address : "“\(host.label)” (\(address))"
    }

    /// `error` saying first where it stopped, when that was the jump host or the server behind it: its message alone
    /// reads as if this host had refused (the connect error people see).
    public static func namingTheHop(_ error: AirSCPError, host: SSHHost, jump: SSHHost?) -> AirSCPError {
        guard let jump, error.kind != .cancelled else { return error }
        let hop = failedHop(error.details, host: host, jump: jump)
        guard hop.hasPrefix("at the jump host") || hop.hasSuffix("couldn't open a connection to it") else { return error }
        var named = error
        named.message = "It stopped " + hop + ". " + error.message
        return named
    }

    /// Where on its way a connect that failed stopped, in words, from the error output of ssh and the proxy helper: at
    /// the HTTP proxy of the first hop, at the jump host, or at the server itself.
    static func failedHop(_ errors: String, host: SSHHost, jump: SSHHost?) -> String {
        if errors.contains("AirSCP proxy: ") {
            return "at the HTTP proxy, on the way to " + (jump.map { "the jump host " + named($0) } ?? named(host))
        }
        guard let jump else { return "at " + named(host) }
        // Through a jump host AirSCP's ssh connects nowhere itself: the jump host's ssh does, and says whether it couldn't
        // reach the server behind it, or reach or log in to the jump host (naming it).
        if errors.contains("open failed") || errors.contains("stdio forwarding failed") {
            return "at " + named(host) + ": the jump host “\(jump.displayName)” couldn't open a connection to it"
        }
        let name = jump.hostname.lowercased()
        let key = jump.port.map { $0 == 22 ? name : "[\(name)]:\($0)" } ?? name
        let lower = errors.lowercased()
        if ["@\(name): ", "host \(name) port", "hostname \(name):", "known for \(key) ", "host key for \(key) "].contains(where: lower.contains) {
            return "at the jump host " + named(jump)
        }
        return "at " + named(host) + ", behind the jump host “\(jump.displayName)”"
    }

    private func describe(_ state: State) -> String {
        switch state {
        case .idle: return "not connected"
        case .connecting: return "connecting"
        case .connected:
            let capabilities = self.capabilities
            return "connected" + (capabilities.shell ? " (login shell \(capabilities.loginShell), home \(capabilities.home))"
                : " (\(capabilities.noShellReason ?? "no shell"))")
        case .reconnecting(let next):
            return "the connection was lost; reconnecting by itself, next try in \(max(0, Int(next.timeIntervalSinceNow.rounded()))) s"
        case .disconnected(let error):
            return "disconnected: \(error.message)" + (error.details.isEmpty ? "" : "\n" + error.details)
        }
    }

    /// What can run here: a POSIX shell (with $HOME and which archive tools), else sftp's starting folder.
    private func probe() async {
        let script = "printf '%s\\n' \"$HOME\" \"$(uname -s 2>/dev/null)\" \"$SHELL\"; for t in zip unzip tar gzip python3; do "
            + "command -v \"$t\" >/dev/null 2>&1 && printf '%s\\n' \"$t\"; done; true"
        var found = Capabilities()
        do {
            let (output, status, _) = try await sentinelShell(script)
            if status == 0 {
                let lines = String(decoding: output, as: UTF8.self).components(separatedBy: "\n")
                found.shell = true
                found.home = lines.first.flatMap { $0.isEmpty ? nil : $0 } ?? "/"
                found.caseInsensitive = lines.dropFirst().first == "Darwin"
                found.loginShell = ((lines.dropFirst(2).first ?? "") as NSString).lastPathComponent
                found.tools = Set(lines.dropFirst(3).filter { !$0.isEmpty })
            }
        } catch let error as AirSCPError {
            if error.kind == .disconnected { return }
            found.noShellReason = error.kind == .sftpOnly
                ? "This account allows file transfers (sftp) only."
                : "The server doesn't run shell commands (\(error.message))"
        } catch {}
        if !found.shell {
            found.noShellReason = found.noShellReason ?? "The server doesn't run shell commands."
            if let result = try? await sftp(["pwd"]),
               let line = result.output.components(separatedBy: "\n").first(where: { $0.hasPrefix("Remote working directory: ") }) {
                found.home = String(line.dropFirst("Remote working directory: ".count))
            }
            found.windows = Session.isWindowsHome(found.home)
            found.caseInsensitive = found.windows
            if found.windows {  // cmd.exe's own words ("The system cannot find the path specified") explain nothing
                found.noShellReason = "This Windows SSH server has no POSIX shell: AirSCP uses file transfers (sftp) only here."
            }
        }
        capabilities = found
    }

    /// Windows' OpenSSH names its folders like "/C:/Users/name".
    static func isWindowsHome(_ home: String) -> Bool {
        home.range(of: "^/[A-Za-z]:(/|$)", options: .regularExpression) != nil
    }

    // MARK: Prompts

    /// Answers a password from the Keychain the first time each ssh process asks for it; everything else goes to
    /// `onPrompt`, or during an automatic reconnect is refused.
    private func handlePrompt(_ request: AskpassRequest, reply: @escaping (String?) -> Void) {
        let kind = request.kind
        // Which question and how it was answered, never the answer.
        let name = host.displayName
        func note(_ what: String) {
            DebugLog.write("ssh (process \(request.pid)) asks “\(request.prompt.trimmingCharacters(in: .whitespacesAndNewlines))”: \(what)",
                           host: name)
        }
        var target: SSHHost?
        // A password, passphrase or other answer (a verification code) the same process asks for again: the last
        // answer was wrong.
        let question: String?
        switch kind {
        case .password(let user, let hostname): question = "\(request.pid) password \(user ?? "")@\(hostname ?? "")"
        case .passphrase: question = "\(request.pid) passphrase \(request.prompt)"
        case .other: question = "\(request.pid) other \(request.prompt)"
        case .hostKey: question = nil
        }
        let retry = question.map { question in lock.locked { !answeredPrompts.insert(question).inserted } } ?? false
        if case .password(let user, let hostname) = kind {
            target = promptTarget(user: user, host: hostname)
            // Saved passwords go only to the ssh processes AirSCP started (see `AskpassServer`).
            if request.fromAirSCP, let target, let saved = savedPassword(target),
               lock.locked({ answeredFromKeychain.insert(request.pid).inserted }) {
                DebugLog.Secrets.add(saved)
                note("answered with the saved password of “\(target.displayName)”")
                reply(saved)
                return
            }
        }
        // An automatic reconnect asks nothing: it gives up instead (the Disconnected banner offers Reconnect).
        if request.silent {
            lock.locked { silentRefused = true }
            note("not answered: an automatic reconnect asks nothing")
            return reply(nil)
        }
        guard let onPrompt else {
            note("cancelled: nothing shows questions now")
            return reply(nil)
        }
        note(retry ? "asked again (the answer before wasn't accepted)" : "asked")
        onPrompt(Prompt(kind: kind, text: request.prompt, host: target, retry: retry)) { [weak self] answer in
            DebugLog.Secrets.add(answer?.text)
            note(answer == nil ? "cancelled" : "answered")
            if let answer, answer.remember, let target, let self {
                self.lock.locked { self.rememberedPasswords[target.id] = answer.text }
            }
            reply(answer?.text)
        }
    }

    /// The saved host a password prompt is for. Without a jump host, this one. With one, the host whose
    /// user@host the prompt names (a jump host's prompt must not get this host's password); nil if neither.
    func promptTarget(user: String?, host hostname: String?) -> SSHHost? {
        guard let jump else { return host }
        func named(_ candidate: SSHHost) -> Bool {
            guard let user, let hostname else { return false }
            return (candidate.username.isEmpty ? NSUserName() : candidate.username) == user
                && candidate.hostname.caseInsensitiveCompare(hostname) == .orderedSame
        }
        if named(jump) { return jump }
        if named(host) { return host }
        return nil
    }

    private func saveRememberedPasswords() {
        let remembered = lock.locked { () -> [UUID: String] in
            defer { rememberedPasswords = [:] }
            return rememberedPasswords
        }
        for (id, password) in remembered {
            if let owner = id == host.id ? host : jump { savePassword(owner, password) }
        }
    }

    private func installKeyOverSFTP(_ publicKeyPath: String) async throws {
        guard var key = try? String(contentsOfFile: publicKeyPath, encoding: .utf8) else {
            throw AirSCPError(.noSuchFile, "Can't read \(publicKeyPath).")
        }
        if !key.hasSuffix("\n") { key += "\n" }
        let dir = RemotePath.join(capabilities.home, ".ssh")
        let file = RemotePath.join(dir, "authorized_keys")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("airscp-keys-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temp) }
        // A missing authorized_keys counts as empty.
        var keys = (try? await sftp(["get \(Quote.sftp(file)) \(Quote.sftp(temp.path))"])) != nil
            ? (try? String(contentsOf: temp, encoding: .utf8)) ?? "" : ""
        if !keys.isEmpty && !keys.hasSuffix("\n") { keys += "\n" }
        try Data((keys + key).utf8).write(to: temp)
        _ = try? await sftp(["mkdir \(Quote.sftp(dir))"])  // fails when it exists
        try await sftp(["chmod 700 \(Quote.sftp(dir))", "put \(Quote.sftp(temp.path)) \(Quote.sftp(file))",
                        "chmod 600 \(Quote.sftp(file))"])
    }
}

/// One operation at a time, in arrival order.
final class Lane {
    private let lock = NSLock()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func run<T>(_ body: () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    private func acquire() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let free = lock.locked { () -> Bool in
                if busy {
                    waiters.append(continuation)
                    return false
                }
                busy = true
                return true
            }
            if free { continuation.resume() }
        }
    }

    private func release() {
        let next = lock.locked { () -> CheckedContinuation<Void, Never>? in
            if waiters.isEmpty {
                busy = false
                return nil
            }
            return waiters.removeFirst()
        }
        next?.resume()
    }
}

/// The pid of the login shell running a user's command (Session.run), read from the start of its error output.
public final class RemotePID {
    static let marker = "__AIRSCP_PID__="
    private let lock = NSLock()
    private var head = Data()
    private var pid: Int32?
    private var done = false
    private var finished = false

    var value: Int32? { lock.locked { pid } }
    /// Whether the command's run here has ended (`end`).
    var ended: Bool { lock.locked { finished } }
    func end() { lock.locked { finished = true } }

    /// A chunk of error output; the marker's line is among the first (after a login shell's own noise).
    func read(_ chunk: Data) {
        lock.locked {
            guard !done else { return }
            head.append(chunk)
            let text = String(decoding: head, as: UTF8.self)
            if let range = text.range(of: Self.marker), let end = text[range.upperBound...].firstIndex(of: "\n") {
                pid = Int32(text[range.upperBound..<end])
                done = true
            } else if head.count > 64 << 10 {
                done = true
            }
        }
    }

    /// The error output without the marker's line.
    public static func removed(from stderr: String) -> String {
        guard let range = stderr.range(of: marker) else { return stderr }
        let start = stderr[..<range.lowerBound].lastIndex(of: "\n").map { stderr.index(after: $0) } ?? stderr.startIndex
        let end = stderr[range.upperBound...].firstIndex(of: "\n").map { stderr.index(after: $0) } ?? stderr.endIndex
        return String(stderr[..<start] + stderr[end...])
    }
}
