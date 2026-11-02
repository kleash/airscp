import AirSCPCore
import CSSH2
import Foundation

/// SSH over libssh2: the iPhone and iPad app's `RemoteTransport` (iOS has no ssh), which the Mac tests run too.
/// One libssh2 session per host, blocking while it logs in and non-blocking after, so that a call waits on its socket
/// and notices a cancel; calls run one at a time on `queue`. Through a jump host, the jump host's session opens a
/// direct-tcpip channel that a `Pump` carries to a socket pair: the target's session talks over the other end.
/// Unlike ssh: no ssh config, agent, certificates, FIDO keys or GSSAPI, and no proxy; known hosts are `knownHosts`
/// (OpenSSH's format).
public final class SSH2Transport: RemoteTransport {
    let host: SSHHost
    let jump: SSHHost?
    let knownHosts: String
    /// A `.keyFile` host's private key, by the host (this one or its jump host), when the keys aren't files: the iOS
    /// app keeps them in the Keychain (`keyFile` is then the key's name). nil: not there. Throws to stop logging in
    /// (Face ID cancelled). Without it, `keyFile` is a path.
    let privateKey: ((SSHHost) throws -> Data?)?
    private let queue = DispatchQueue(label: "AirSCP libssh2")
    private let lock = NSLock()
    private var target: Connection?
    private var hop: Connection?
    private var pump: Pump?

    public init(host: SSHHost, jump: SSHHost?, knownHosts: String, privateKey: ((SSHHost) throws -> Data?)? = nil) {
        self.host = host
        self.jump = jump
        self.knownHosts = knownHosts
        self.privateKey = privateKey
    }

    deinit { close() }

    public func open(ask: @escaping (String) async -> String?) async throws {
        // libssh2 asks from inside its calls, on `queue`: wait there for the answer.
        let asker = { (prompt: String) -> String? in
            let answer = Answer()
            Task {
                answer.text = await ask(prompt)
                answer.done.signal()
            }
            answer.done.wait()
            return answer.text
        }
        try await onQueue { [self] in
            close()  // a reconnect: the lost connection's sessions go
            if !host.sudoUser.isEmpty {
                throw AirSCPError(.other, "Browsing as another user (sudo) isn't available on iPhone and iPad yet.")
            }
            let fd: Int32
            if let jump {
                let hop = try Connection(fd: Connection.connect(jump.hostname, jump.port ?? 22), host: jump, ask: asker,
                                         privateKey: privateKey)
                lock.withLock { self.hop = hop }
                try hop.logIn(knownHosts: knownHosts)
                let pump = try Pump(hop, to: host.hostname, port: host.port ?? 22)
                lock.withLock { self.pump = pump }
                fd = pump.fd
            } else {
                fd = try Connection.connect(host.hostname, host.port ?? 22)
            }
            let target = try Connection(fd: fd, host: host, ask: asker, privateKey: privateKey)
            lock.withLock { self.target = target }
            try target.logIn(knownHosts: knownHosts)
            libssh2_session_set_blocking(target.session, 0)
        }
    }

    public func exec(_ command: String, input: String?, cancellation: Cancellation, standardOutput: ((Data) -> Void)?,
                     errorOutput: ((Data) -> Void)?) async throws -> CommandResult {
        try await onQueue { [self] in
            try connection().exec(command, input: input, cancellation: cancellation, standardOutput: standardOutput,
                                  errorOutput: errorOutput)
        }
    }

    public func sftp(_ lines: [String], cancellation: Cancellation) async throws -> CommandResult {
        try await onQueue { [self] in try connection().sftpBatch(lines, cancellation: cancellation) }
    }

    public func shell(_ command: String, columns: Int, rows: Int, output: @escaping (Data) -> Void,
                      ended: @escaping (Int32) -> Void) async throws -> RemoteShell {
        try await onQueue { [self] in
            try connection().openShell(command, columns: columns, rows: rows, queue: queue, output: output, ended: ended)
        }
    }

    /// Ends the connection: its socket at once (a call waiting on it fails), the sessions once no call runs.
    public func close() {
        let (target, pump, hop) = lock.withLock { () -> (Connection?, Pump?, Connection?) in
            defer { (self.target, self.pump, self.hop) = (nil, nil, nil) }
            return (self.target, self.pump, self.hop)
        }
        if let target { shutdown(target.fd, SHUT_RDWR) }
        guard target != nil || hop != nil else { return }
        queue.async {
            target?.close()
            pump?.stop()
            hop?.close()
        }
    }

    func connection() throws -> Connection {
        guard let target = lock.withLock({ target }), !target.dead else { throw AirSCPError.disconnected }
        return target
    }

    func onQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: body)) }
        }
    }
}

private final class Answer {
    var text: String?
    let done = DispatchSemaphore(value: 0)
}

/// One libssh2 session over a connected socket: logging in, and the calls of `SSH2Transport` (sftp in SSH2SFTP.swift).
final class Connection {
    private static let initialized: Void = { libssh2_init(0) }()

    let session: OpaquePointer
    let fd: Int32
    let host: SSHHost
    let ask: (String) -> String?
    let privateKey: ((SSHHost) throws -> Data?)?
    /// The connection is gone (a socket error): every later call throws `.disconnected`.
    var dead = false
    var sftp: OpaquePointer?
    /// The open terminals (SSH2Shell.swift), and what wakes the transport's queue for them when no call runs.
    var shells: [Shell] = []
    var shellWatch: DispatchSourceRead?
    /// A keyboard-interactive question was cancelled.
    private var cancelledQuestion = false

    init(fd: Int32, host: SSHHost, ask: @escaping (String) -> String?, privateKey: ((SSHHost) throws -> Data?)? = nil) throws {
        _ = Connection.initialized
        guard let session = libssh2_session_init_ex(nil, nil, nil, nil) else {
            Darwin.close(fd)
            throw AirSCPError(.other, "AirSCP couldn't start an SSH session.")
        }
        self.session = session
        self.fd = fd
        self.host = host
        self.ask = ask
        self.privateKey = privateKey
        libssh2_session_abstract(session).pointee = Unmanaged.passUnretained(self).toOpaque()
        libssh2_session_set_blocking(session, 1)
        let rc = libssh2_session_handshake(session, libssh2_socket_t(fd))
        if rc != 0 {
            let details = lastError
            close()
            throw AirSCPError(.other, "The SSH handshake with the server failed.", details: details)
        }
    }

    func close() {
        endShells()
        if let sftp { libssh2_sftp_shutdown(sftp) }
        sftp = nil
        libssh2_session_set_blocking(session, 1)
        libssh2_session_set_timeout(session, 2000)
        libssh2_session_disconnect_ex(session, SSH_DISCONNECT_BY_APPLICATION, "", "")
        libssh2_session_free(session)
        Darwin.close(fd)
    }

    /// A TCP connection to the server, as ssh makes it (each of the name's addresses in turn).
    /// shortcut: the system's connect timeout (about 75 s); time out sooner if waiting that long shows up on iOS.
    static func connect(_ hostname: String, _ port: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let rc = getaddrinfo(hostname, String(port), &hints, &list)
        guard rc == 0 else {
            throw ErrorMapping.map("ssh: Could not resolve hostname \(hostname): \(String(cString: gai_strerror(rc)))", status: 255)
        }
        defer { freeaddrinfo(list) }
        var failure = ECONNREFUSED
        var next = list
        while let address = next?.pointee {
            next = address.ai_next
            let fd = socket(address.ai_family, address.ai_socktype, address.ai_protocol)
            guard fd >= 0 else { continue }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // A server that stops answering (the network dropped the connection while iOS kept the app in the background)
            // fails the next call within 45 s, as ssh's keep-alive gives up (15 s × 3), not after minutes of resending.
            var seconds: Int32 = 45
            setsockopt(fd, IPPROTO_TCP, TCP_RXT_CONNDROPTIME, &seconds, socklen_t(MemoryLayout<Int32>.size))
            if Darwin.connect(fd, address.ai_addr, address.ai_addrlen) == 0 { return fd }
            failure = errno
            Darwin.close(fd)
        }
        throw ErrorMapping.map("ssh: connect to host \(hostname) port \(port): \(String(cString: strerror(failure)))", status: 255)
    }

    var lastError: String {
        var message: UnsafeMutablePointer<CChar>?
        var length: Int32 = 0
        libssh2_session_last_error(session, &message, &length, 0)
        return message.map { String(cString: $0) } ?? ""
    }

    // MARK: Logging in

    /// The host key check, then the login methods ssh would try: the key file, then keyboard-interactive or a password
    /// (asked for, three times at most); the server may want several (a key, then a verification code).
    func logIn(knownHosts: String) throws {
        try checkHostKey(knownHosts: knownHosts)
        let user = host.username.isEmpty ? NSUserName() : host.username
        var notes = ""
        var triedKey = false
        while libssh2_userauth_authenticated(session) == 0 {
            // nil: the "none" method logged in, or the server ended the connection.
            guard let list = libssh2_userauth_list(session, user, UInt32(user.utf8.count)) else {
                if libssh2_userauth_authenticated(session) == 1 { return }
                throw failure(libssh2_session_last_errno(session), "Logging in")
            }
            let methods = String(cString: list)
            let offered = Set(methods.split(separator: ",").map(String.init))
            if host.auth == .keyFile && !triedKey && offered.contains("publickey") {
                triedKey = true
                try logInWithKey(user, notes: &notes)
            } else if offered.contains("keyboard-interactive") {
                try keyboardInteractive(user, notes: &notes)
            } else if offered.contains("password") {
                try password(user, notes: &notes)
            } else {
                throw ErrorMapping.map(notes + "\(user)@\(host.hostname): Permission denied (\(methods)).", status: 255,
                                       keyFiles: [host.keyFile])
            }
        }
    }

    /// As ssh checks it (`HostKeyCheck`): a known key goes on, a changed one is refused, a new one is asked about
    /// (with ssh's words) or trusted at once, then added to `knownHosts`.
    private func checkHostKey(knownHosts: String) throws {
        var length = 0
        var type: Int32 = 0
        guard let key = libssh2_session_hostkey(session, &length, &type) else {
            throw AirSCPError(.other, "The server sent no host key.", details: lastError)
        }
        guard host.hostKeyCheck != .off else { return }
        guard let hosts = libssh2_knownhost_init(session) else { throw failure(libssh2_session_last_errno(session), "Known hosts") }
        defer { libssh2_knownhost_free(hosts) }
        _ = libssh2_knownhost_readfile(hosts, knownHosts, LIBSSH2_KNOWNHOST_FILE_OPENSSH)  // none yet: nothing known
        let port = host.port ?? 22
        let name = port == 22 ? host.hostname : "[\(host.hostname)]:\(port)"
        let kinds = [LIBSSH2_HOSTKEY_TYPE_RSA: ("RSA", LIBSSH2_KNOWNHOST_KEY_SSHRSA),
                     LIBSSH2_HOSTKEY_TYPE_DSS: ("DSA", LIBSSH2_KNOWNHOST_KEY_SSHDSS),
                     LIBSSH2_HOSTKEY_TYPE_ECDSA_256: ("ECDSA", LIBSSH2_KNOWNHOST_KEY_ECDSA_256),
                     LIBSSH2_HOSTKEY_TYPE_ECDSA_384: ("ECDSA", LIBSSH2_KNOWNHOST_KEY_ECDSA_384),
                     LIBSSH2_HOSTKEY_TYPE_ECDSA_521: ("ECDSA", LIBSSH2_KNOWNHOST_KEY_ECDSA_521),
                     LIBSSH2_HOSTKEY_TYPE_ED25519: ("ED25519", LIBSSH2_KNOWNHOST_KEY_ED25519)]
        let (kind, keyBit) = kinds[type] ?? ("UNKNOWN", LIBSSH2_KNOWNHOST_KEY_UNKNOWN)
        let plain = LIBSSH2_KNOWNHOST_TYPE_PLAIN | LIBSSH2_KNOWNHOST_KEYENC_RAW | keyBit
        switch libssh2_knownhost_checkp(hosts, host.hostname, Int32(port), key, length, plain, nil) {
        case LIBSSH2_KNOWNHOST_CHECK_MATCH:
            return
        case LIBSSH2_KNOWNHOST_CHECK_MISMATCH:
            throw ErrorMapping.map("@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\nHost key for \(name) has changed "
                                   + "and you have requested strict checking.\nOffending \(kind) key in \(knownHosts)", status: 255)
        default:
            let hash = Data(bytes: libssh2_hostkey_hash(session, LIBSSH2_HOSTKEY_HASH_SHA256), count: 32)
            let fingerprint = "SHA256:" + hash.base64EncodedString().replacingOccurrences(of: "=", with: "")
            if host.hostKeyCheck == .ask {
                let answer = ask("The authenticity of host '\(name)' can't be established.\n\(kind) key fingerprint is "
                                 + "\(fingerprint).\nAre you sure you want to continue connecting (yes/no/[fingerprint])? ")
                guard answer == "yes" || answer == fingerprint else {
                    throw ErrorMapping.map("Host key verification failed.", status: 255)
                }
            }
            let added = libssh2_knownhost_addc(hosts, name, nil, key, length, nil, 0,
                                               LIBSSH2_KNOWNHOST_TYPE_PLAIN | LIBSSH2_KNOWNHOST_KEYENC_RAW | keyBit, nil)
            if added != 0 || libssh2_knownhost_writefile(hosts, knownHosts, LIBSSH2_KNOWNHOST_FILE_OPENSSH) != 0 {
                throw AirSCPError(.other, "AirSCP couldn't save the server's host key in \(knownHosts).", details: lastError)
            }
        }
    }

    private func logInWithKey(_ user: String, notes: inout String) throws {
        let path = host.keyFile
        guard let key = try privateKey.map({ try $0(host) }) ?? FileManager.default.contents(atPath: path) else {
            notes += "no such identity: \(path): No such file or directory\n"
            return
        }
        func attempt(_ passphrase: String?) -> Int32 {
            key.withUnsafeBytes { bytes in
                libssh2_userauth_publickey_frommemory(session, user, user.utf8.count, nil, 0,
                                                      bytes.bindMemory(to: CChar.self).baseAddress, key.count, passphrase)
            }
        }
        // libssh2 can't read an encrypted key without its passphrase (nor with a wrong one).
        var rc = attempt(nil)
        var tries = 0
        while rc == LIBSSH2_ERROR_FILE && tries < 3 {
            tries += 1
            guard let passphrase = ask("Enter passphrase for key '\(path)': ") else { throw AirSCPError.cancelled }
            rc = attempt(passphrase)
        }
        if rc == LIBSSH2_ERROR_FILE { notes += "Load key \"\(path)\": incorrect passphrase supplied to decrypt private key\n" }
    }

    private func password(_ user: String, notes: inout String) throws {
        for _ in 0..<3 {
            guard let password = ask("\(user)@\(host.hostname)'s password: ") else { throw AirSCPError.cancelled }
            let rc = libssh2_userauth_password_ex(session, user, UInt32(user.utf8.count), password,
                                                  UInt32(password.utf8.count), nil)
            if rc == 0 { return }
            guard rc == LIBSSH2_ERROR_AUTHENTICATION_FAILED else { throw failure(rc, "Logging in") }
            notes += "Permission denied, please try again.\n"
        }
    }

    private func keyboardInteractive(_ user: String, notes: inout String) throws {
        for _ in 0..<3 {
            cancelledQuestion = false
            let rc = libssh2_userauth_keyboard_interactive_ex(session, user, UInt32(user.utf8.count), { _, _, _, _, count, prompts, responses, abstract in
                guard let me = abstract?.pointee, let prompts, let responses else { return }
                Unmanaged<Connection>.fromOpaque(me).takeUnretainedValue().answer(Int(count), prompts, responses)
            })
            if cancelledQuestion { throw AirSCPError.cancelled }
            if rc == 0 || libssh2_userauth_authenticated(session) == 1 { return }
            // A partial success (the server wants another method too) isn't a wrong answer.
            guard rc == LIBSSH2_ERROR_AUTHENTICATION_FAILED else { throw failure(rc, "Logging in") }
            notes += "Permission denied, please try again.\n"
        }
    }

    /// keyboard-interactive's questions, in ssh's words ("(user@host) Password: ").
    private func answer(_ count: Int, _ prompts: UnsafePointer<LIBSSH2_USERAUTH_KBDINT_PROMPT>,
                        _ responses: UnsafeMutablePointer<LIBSSH2_USERAUTH_KBDINT_RESPONSE>) {
        let user = host.username.isEmpty ? NSUserName() : host.username
        for index in 0..<count {
            let prompt = prompts[index]
            let text = prompt.text.map { String(decoding: UnsafeBufferPointer(start: $0, count: prompt.length), as: UTF8.self) } ?? ""
            let answer = cancelledQuestion ? nil : ask("(\(user)@\(host.hostname)) " + text)
            if answer == nil { cancelledQuestion = true }
            responses[index].text = strdup(answer ?? "")  // libssh2 frees it
            responses[index].length = UInt32((answer ?? "").utf8.count)
        }
    }

    // MARK: Commands

    /// `command` with `input` on its standard input, both outputs read as they come; the exit status as `Runner`
    /// gives it (128 + the signal's number when a signal ended it).
    func exec(_ command: String, input: String?, cancellation: Cancellation, standardOutput: ((Data) -> Void)?,
              errorOutput: ((Data) -> Void)?) throws -> CommandResult {
        guard let channel = try opened(cancellation, {
            // LIBSSH2_CHANNEL_WINDOW_DEFAULT, which Swift doesn't import.
            libssh2_channel_open_ex(session, "session", 7, 2 * 1024 * 1024, UInt32(LIBSSH2_CHANNEL_PACKET_DEFAULT), nil, 0)
        }) else { throw failure(libssh2_session_last_errno(session), "Opening a channel") }
        defer { _ = try? again(nil) { libssh2_channel_free(channel) } }
        let started = try again(cancellation) {
            libssh2_channel_process_startup(channel, "exec", 4, command, UInt32(command.utf8.count))
        }
        guard started == 0 else { throw failure(started, "Running a command") }
        var pending = Array((input ?? "").utf8)[...]
        var eofSent = false
        var stdout = Data(), stderr = Data()
        var buffer = [CChar](repeating: 0, count: 32768)
        var signalled: Bool?  // a cancel's signal: nil not sent, false half sent
        while true {
            var progress = false
            if !pending.isEmpty {
                let written = pending.withUnsafeBufferPointer { bytes in
                    bytes.withMemoryRebound(to: CChar.self) { libssh2_channel_write_ex(channel, 0, $0.baseAddress, $0.count) }
                }
                if written > 0 {
                    pending = pending.dropFirst(written)
                    progress = true
                } else if written != LIBSSH2_ERROR_EAGAIN {
                    throw failure(Int32(written), "Sending the command's input")
                }
            } else if !eofSent {
                let rc = libssh2_channel_send_eof(channel)
                if rc == 0 { eofSent = true } else if rc != LIBSSH2_ERROR_EAGAIN { throw failure(rc, "Sending the command's input") }
            }
            for (stream, handler) in [(Int32(0), standardOutput), (SSH_EXTENDED_DATA_STDERR, errorOutput)] {
                let count = libssh2_channel_read_ex(channel, stream, &buffer, buffer.count)
                if count > 0 {
                    let chunk = Data(bytes: buffer, count: count)
                    if stream == 0 { stdout.append(chunk) } else { stderr.append(chunk) }
                    handler?(chunk)
                    progress = true
                } else if count < 0 && count != LIBSSH2_ERROR_EAGAIN {
                    throw failure(Int32(count), "Reading the command's output")
                }
            }
            if !progress {
                // Cancelled: the command is signalled on the server (sshd ends its process group) and read to its end,
                // as the channel's close waits for that anyway. Only once our input and EOF have gone, and a signal half
                // sent goes on till it has: libssh2 takes no other packet meanwhile (it says "again").
                let ended = libssh2_channel_eof(channel) == 1
                if cancellation.isCancelled, pending.isEmpty, eofSent, signalled == false || signalled == nil && !ended {
                    signalled = libssh2_channel_signal_ex(channel, "TERM", 4) != LIBSSH2_ERROR_EAGAIN
                }
                if ended && signalled != false { break }
                try wait(nil)
            }
        }
        _ = try again(cancellation) { libssh2_channel_close(channel) }
        _ = try again(cancellation) { libssh2_channel_wait_closed(channel) }
        var status = libssh2_channel_get_exit_status(channel)
        var signal: UnsafeMutablePointer<CChar>?
        var length = 0
        if libssh2_channel_get_exit_signal(channel, &signal, &length, nil, nil, nil, nil) == 0, let signal {
            let numbers = ["HUP": 1, "INT": 2, "QUIT": 3, "ABRT": 6, "KILL": 9, "SEGV": 11, "PIPE": 13, "TERM": 15]
            status = 128 + Int32(numbers[String(cString: signal)] ?? 0)
            libssh2_free(session, signal)
        }
        return CommandResult(status: status, stdout: stdout, stderr: String(decoding: stderr, as: UTF8.self))
    }

    // MARK: Waiting (non-blocking calls)

    /// Calls `body` until it stops saying "again", waiting for the socket in between. A cancel stops it before it starts,
    /// never half-way: libssh2 keeps a started request in the session (an open, a stat, a readdir, a channel), and the
    /// next request of its kind, a transfer's between a listing's, would take that one's answer. (Reading and writing a
    /// file stop half-way: closing the file clears what they keep.)
    func again<T: BinaryInteger>(_ cancellation: Cancellation?, _ body: () -> T) throws -> T {
        if cancellation?.isCancelled == true { throw AirSCPError.cancelled }
        while true {
            let rc = body()
            if rc != LIBSSH2_ERROR_EAGAIN { return rc }
            try wait(nil)
        }
    }

    /// `again` for a call that returns a pointer: nil when it failed.
    func opened(_ cancellation: Cancellation?, _ body: () -> OpaquePointer?) throws -> OpaquePointer? {
        if cancellation?.isCancelled == true { throw AirSCPError.cancelled }
        while true {
            if let pointer = body() { return pointer }
            guard libssh2_session_last_errno(session) == LIBSSH2_ERROR_EAGAIN else { return nil }
            try wait(nil)
        }
    }

    /// Waits (up to 0.1 s) until the socket can go on the way libssh2 needs it to.
    func wait(_ cancellation: Cancellation?) throws {
        if cancellation?.isCancelled == true { throw AirSCPError.cancelled }
        let directions = libssh2_session_block_directions(session)
        var events: Int32 = 0
        if directions & LIBSSH2_SESSION_BLOCK_INBOUND != 0 { events |= POLLIN }
        if directions & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0 { events |= POLLOUT }
        var descriptor = pollfd(fd: fd, events: Int16(events == 0 ? POLLIN : events), revents: 0)
        _ = poll(&descriptor, 1, 100)
        serveShells()  // after the poll: what it reads for the caller's channel waits there for the caller
    }

    /// A libssh2 error: the connection lost (as ssh's own end would show), or what `what` couldn't do.
    func failure<T: BinaryInteger>(_ rc: T, _ what: String) -> AirSCPError {
        let lost = [LIBSSH2_ERROR_SOCKET_NONE, LIBSSH2_ERROR_SOCKET_SEND, LIBSSH2_ERROR_SOCKET_RECV,
                    LIBSSH2_ERROR_SOCKET_DISCONNECT, LIBSSH2_ERROR_SOCKET_TIMEOUT, LIBSSH2_ERROR_BAD_SOCKET,
                    LIBSSH2_ERROR_TIMEOUT, LIBSSH2_ERROR_KEX_FAILURE]
        if lost.contains(Int32(rc)) {
            dead = true
            return AirSCPError(.disconnected, AirSCPError.disconnected.message, details: lastError)
        }
        if rc == LIBSSH2_ERROR_CHANNEL_FAILURE {  // as ssh says when the server allows no more sessions (MaxSessions)
            return ErrorMapping.map("channel: session request failed\n" + lastError, status: 255)
        }
        return AirSCPError(.other, "\(what) failed: \(lastError)", details: lastError)
    }
}

/// Carries a jump host's direct-tcpip channel to and from one end of a socket pair; the target's session uses the
/// other end as its socket. Runs on a thread of its own, the jump host's session's only user once it has logged in.
final class Pump {
    let fd: Int32
    private let outer: Int32
    private let hop: Connection
    private let channel: OpaquePointer
    private let lock = NSLock()
    private var stopped = false
    private let ended = DispatchSemaphore(value: 0)

    init(_ hop: Connection, to hostname: String, port: Int) throws {
        guard let channel = libssh2_channel_direct_tcpip_ex(hop.session, hostname, Int32(port), "127.0.0.1", 0) else {
            // ssh's words: "channel 0: open failed: connect failed: …".
            throw ErrorMapping.map("channel 0: open failed: \(hop.lastError)", status: 255)
        }
        var pair: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0 else {
            libssh2_channel_free(channel)
            throw AirSCPError(.other, "AirSCP couldn't make a socket pair: \(String(cString: strerror(errno)))")
        }
        var on: Int32 = 1
        for end in pair { setsockopt(end, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) }
        (fd, outer, self.hop, self.channel) = (pair[0], pair[1], hop, channel)
        _ = fcntl(outer, F_SETFL, fcntl(outer, F_GETFL) | O_NONBLOCK)
        libssh2_session_set_blocking(hop.session, 0)
        Thread { [self] in run() }.start()
    }

    /// Stops the thread (after the target's session has closed its end) and waits for it.
    func stop() {
        lock.withLock { stopped = true }
        _ = ended.wait(timeout: .now() + 2)
    }

    private func run() {
        var buffer = [CChar](repeating: 0, count: 32768)
        var pending: ArraySlice<CChar> = []
        loop: while !lock.withLock({ stopped }) {
            var progress = false
            if pending.isEmpty {
                let count = read(outer, &buffer, buffer.count)
                if count > 0 {
                    pending = buffer[..<count]
                    progress = true
                } else if count == 0 || errno != EAGAIN {
                    break  // the target's session closed its end
                }
            }
            if !pending.isEmpty {
                let written = pending.withUnsafeBufferPointer { libssh2_channel_write_ex(channel, 0, $0.baseAddress, $0.count) }
                if written > 0 {
                    pending = pending.dropFirst(written)
                    progress = true
                } else if written != LIBSSH2_ERROR_EAGAIN {
                    break
                }
            }
            let count = libssh2_channel_read_ex(channel, 0, &buffer, buffer.count)
            if count > 0 {
                var offset = 0
                while offset < count {
                    let written = buffer.withUnsafeBytes { write(outer, $0.baseAddress! + offset, count - offset) }
                    if written > 0 {
                        offset += written
                    } else if errno == EAGAIN {
                        var descriptor = pollfd(fd: outer, events: Int16(POLLOUT), revents: 0)
                        _ = poll(&descriptor, 1, 100)
                    } else {
                        break loop
                    }
                }
                progress = true
            } else if count < 0 && count != LIBSSH2_ERROR_EAGAIN {
                break
            }
            if libssh2_channel_eof(channel) == 1 { break }
            if !progress {
                var descriptors = [pollfd(fd: outer, events: Int16(POLLIN), revents: 0),
                                   pollfd(fd: hop.fd, events: Int16(POLLIN), revents: 0)]
                _ = poll(&descriptors, 2, 50)
            }
        }
        close(outer)  // the target's session sees its connection end
        // Not freed after 0.2 s (a dead jump host): freeing the jump host's session frees it.
        var tries = 0
        while tries < 20 && libssh2_channel_free(channel) == LIBSSH2_ERROR_EAGAIN {
            tries += 1
            usleep(10_000)
        }
        ended.signal()
    }
}
