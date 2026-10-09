import Darwin
import Foundation

/// What an ssh prompt asks for.
public enum PromptKind: Equatable {
    /// "Are you sure you want to continue connecting (yes/no/[fingerprint])?": answer "yes" to trust.
    case hostKey(host: String, fingerprint: String)
    /// A login password; user and host come from "user@host's password:" or "(user@host) Password:".
    case password(user: String?, host: String?)
    /// A key's passphrase, or a new one for ssh-keygen.
    case passphrase
    /// Anything else (verification codes, confirmations): show the prompt text.
    case other
}

/// A prompt from ssh, ssh-keygen or ssh-add, sent by the askpass helper.
public struct AskpassRequest {
    /// AIRSCP_HOST of the command that asked: a host id, or another id the app chose (e.g. for ssh-keygen).
    public let id: String
    public let prompt: String
    /// The process that asked (the helper's parent): a password retried by the same process was wrong.
    public let pid: Int32
    /// From an automatic reconnect (AIRSCP_SILENT), which asks nothing: only a saved password may answer.
    public var silent = false
    /// The asking process is one AirSCP started (or one of theirs): only such get saved passwords.
    public var fromAirSCP = true
    public var kind: PromptKind { Askpass.classify(prompt) }
}

/// SSH_ASKPASS support: AirSCP's own binary is the askpass program. It sends the prompt to the running app over
/// a unix socket and prints the reply.
public enum Askpass {
    /// The helper: called from main.swift when AIRSCP_ASKPASS_SOCK is set. Prints the answer and returns 0, or
    /// returns 1 when the app cancels, doesn't answer or can't be reached.
    public static func runHelper(prompt: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        guard let path = environment["AIRSCP_ASKPASS_SOCK"] else { return 1 }
        var request: [String: Any] = ["id": environment["AIRSCP_HOST"] ?? "", "prompt": prompt, "pid": Int(getppid()),
                                      "token": environment["AIRSCP_ASKPASS_TOKEN"] ?? ""]
        if environment["AIRSCP_SILENT"] != nil { request["silent"] = true }
        guard let answer = exchange(request, socket: path)?["answer"] as? String else { return 1 }
        FileHandle.standardOutput.write(Data((answer + "\n").utf8))
        return 0
    }

    /// Sends `request` to the app over the socket at `path` and returns its reply (the askpass and proxy-connect
    /// helpers, the agent bridge). nil when the app can't be reached, or (`watchParent`: ssh's helpers) the process that
    /// ran the helper has gone meanwhile.
    static func exchange(_ request: [String: Any], socket path: String, watchParent: Bool = true) -> [String: Any]? {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        guard var address = unixAddress(path), withUnsafePointer(to: &address, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }) == 0 else { return nil }
        guard let body = try? JSONSerialization.data(withJSONObject: request),
              body.withUnsafeBytes({ send(fd, $0.baseAddress, $0.count, 0) }) == body.count else { return nil }
        shutdown(fd, SHUT_WR)
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            // Wake up every second to notice when the ssh that asked has gone (cancelled connection).
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, 1000)
            if ready == 0 {
                if watchParent && getppid() == 1 { return nil }
                continue
            }
            if ready < 0 {
                if errno == EINTR { continue }
                return nil
            }
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            reply.append(contentsOf: buffer[0..<count])
        }
        return try? JSONSerialization.jsonObject(with: reply) as? [String: Any]
    }

    /// What a prompt asks for, from its text.
    public static func classify(_ prompt: String) -> PromptKind {
        let lower = prompt.lowercased()
        if lower.contains("(yes/no") || lower.contains("continue connecting") {
            return .hostKey(host: between(prompt, "authenticity of host '", "'").map(hostKeyName) ?? "",
                            fingerprint: fingerprint(in: prompt) ?? "")
        }
        if lower.contains("passphrase") { return .passphrase }
        if lower.contains("password") {
            // "user@host's password: " (password) or "(user@host) Password: " (keyboard-interactive).
            let target = between(prompt, "(", ")") ?? prompt.components(separatedBy: "'s password").first
            if let target, target.contains("@"), !target.contains(" ") {
                let at = target.lastIndex(of: "@")!
                return .password(user: String(target[..<at]), host: String(target[target.index(after: at)...]))
            }
            return .password(user: nil, host: nil)
        }
        return .other
    }

    /// The askpass variables for a command that may prompt, tagged with `id`. AIRSCP_HELPER is the AirSCP binary for
    /// a proxy's ProxyCommand (`OpenSSH.options`); AIRSCP_ASKPASS_TOKEN is the server's secret, which every request
    /// must carry.
    static func environment(helper: String, socket: String, token: String, id: String) -> [String: String] {
        ["SSH_ASKPASS": helper, "SSH_ASKPASS_REQUIRE": "force", "AIRSCP_ASKPASS_SOCK": socket, "AIRSCP_HOST": id,
         "AIRSCP_HELPER": helper, "AIRSCP_ASKPASS_TOKEN": token]
    }

    private static func between(_ text: String, _ start: String, _ end: String) -> String? {
        guard let lower = text.range(of: start), let upper = text.range(of: end, range: lower.upperBound..<text.endIndex)
        else { return nil }
        return String(text[lower.upperBound..<upper.lowerBound])
    }

    /// "[127.0.0.1]:2222 ([127.0.0.1]:2222)" → "[127.0.0.1]:2222".
    private static func hostKeyName(_ text: String) -> String {
        text.components(separatedBy: " (").first ?? text
    }

    private static func fingerprint(in text: String) -> String? {
        text.split(whereSeparator: { $0.isWhitespace }).first { $0.hasPrefix("SHA256:") || $0.hasPrefix("MD5:") }
            .map { String($0).trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
    }

    /// Whether the process at the other end of a unix socket is one this app started, or a descendant of one (ssh's
    /// askpass and ProxyCommand helpers, the jump host's ssh, ssh-copy-id's ssh).
    static func startedByThisApp(peerOf connection: Int32) -> Bool {
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(connection, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return false }
        let app = getpid()
        for _ in 0..<32 {
            var info = proc_bsdinfo()
            guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0
            else { return false }
            if pid_t(info.pbi_ppid) == app { return true }
            pid = pid_t(info.pbi_ppid)
        }
        return false
    }

    static func unixAddress(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        return address
    }
}

/// The app side of askpass: listens on a socket in a private (0700) temporary folder and hands each prompt to the
/// handler registered for the asking command's id, on the main queue. Prompts with no handler are cancelled. A request
/// must carry the server's token, which only the commands AirSCP starts get (in their environment). Another program of
/// the same user could still read the token from a helper's environment, so a request also says whether it comes from
/// a process AirSCP started or one of their descendants (`fromAirSCP`): saved passwords go only to those, anyone else
/// gets a question the user sees.
public final class AskpassServer {
    /// Called with the prompt and a reply function: pass the answer, or nil to cancel.
    public typealias Handler = (AskpassRequest, @escaping (String?) -> Void) -> Void

    /// The program ssh runs to ask (the AirSCP binary).
    public let helperPath: String
    public let socketPath: String
    /// Answers the proxy-connect helper's request for a saved proxy (`ProxyConnect`; a `{proxy: id}` message of its
    /// own, never a Session prompt), on the main queue: reply with the proxy and its password ("" when it has no user
    /// name), or nil to cancel. The app looks the proxy up, takes the password from the Keychain
    /// (`Proxy.keychainKey`) and, only when `mayAsk` (false during a silent automatic reconnect), asks "Proxy X needs
    /// a password" with Remember.
    public var proxyHandler: ProxyHandler? {
        get { lock.locked { _proxyHandler } }
        set { lock.locked { _proxyHandler = newValue } }
    }
    /// `fromAirSCP`: the asking process is one AirSCP started (a saved password may answer; see the class).
    public typealias ProxyHandler = (_ proxyID: UUID, _ mayAsk: Bool, _ fromAirSCP: Bool,
                                     _ reply: @escaping ((proxy: Proxy, password: String)?) -> Void) -> Void
    private var _proxyHandler: ProxyHandler?
    /// The token: a random secret for this launch.
    private let secret: String
    private let directory: String
    private let listener: Int32
    private let lock = NSLock()
    private var handlers: [String: Handler] = [:]
    /// Connections waiting for an answer, with the id that asked, by a token that is never reused (unlike the
    /// descriptor: a late reply to a cancelled prompt must not answer a newer one).
    private var waiting: [UInt64: (connection: Int32, id: String)] = [:]
    private var nextToken: UInt64 = 0
    private var closed = false

    public init(helperPath: String) throws {
        self.helperPath = helperPath
        var random = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&random, random.count)
        secret = random.map { String(format: "%02x", $0) }.joined()
        DebugLog.Secrets.add(secret)
        Self.removeStaleFolders()
        var template = Array("/tmp/airscp-askpass.XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else {
            throw AirSCPError(.other, "Can't create the askpass folder: \(String(cString: strerror(errno)))")
        }
        directory = String(cString: made)
        socketPath = directory + "/sock"
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = Askpass.unixAddress(socketPath) else {
            if fd >= 0 { Darwin.close(fd) }
            rmdir(directory)
            throw AirSCPError(.other, "Can't create the askpass socket.")
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            Darwin.close(fd)
            rmdir(directory)
            throw AirSCPError(.other, "Can't listen on the askpass socket: \(String(cString: strerror(errno)))")
        }
        listener = fd
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
    }

    deinit { close() }

    /// Folders that an AirSCP stopped without quitting (killed, or a test run cut off) left behind: this user's, whose
    /// socket no one listens on any more. A running AirSCP's socket answers, so its folder stays.
    static func removeStaleFolders() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: "/tmp")) ?? []
        for name in names where name.hasPrefix("airscp-askpass.") {
            let directory = "/tmp/" + name, socketPath = directory + "/sock"
            var info = stat()
            // A minute old at least: a folder just made may not have its socket yet.
            guard lstat(directory, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
                  time(nil) - info.st_mtimespec.tv_sec > 60 else { continue }
            if lstat(socketPath, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFSOCK, var address = Askpass.unixAddress(socketPath) else { continue }
                let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                guard fd >= 0 else { continue }
                let answered = withUnsafePointer(to: &address) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
                } == 0
                let refused = errno == ECONNREFUSED
                Darwin.close(fd)
                guard !answered, refused else { continue }
                unlink(socketPath)
            }
            rmdir(directory)  // only when empty
        }
    }

    /// SSH_ASKPASS and friends for a command whose prompts should go to the handler for `id`.
    public func environment(for id: String) -> [String: String] {
        Askpass.environment(helper: helperPath, socket: socketPath, token: secret, id: id)
    }

    /// The variables a Terminal session's .command script exports, so that a proxy-connect ProxyCommand started there
    /// still reaches the app (ssh itself asks in the terminal).
    public var terminalEnvironment: [String: String] {
        ["AIRSCP_ASKPASS_SOCK": socketPath, "AIRSCP_HELPER": helperPath, "AIRSCP_ASKPASS_TOKEN": secret]
    }

    /// Registers (or with nil removes) the handler for prompts from commands tagged `id`.
    public func setHandler(_ handler: Handler?, for id: String) {
        lock.locked { handlers[id] = handler }
    }

    /// Cancels every prompt from `id` that is still waiting for an answer.
    public func cancelPending(for id: String) {
        let tokens = lock.locked { waiting.filter { $0.value.id == id }.map(\.key) }
        tokens.forEach { reply($0, [:]) }
    }

    public func close() {
        let (alreadyClosed, tokens): (Bool, [UInt64]) = lock.locked {
            defer { closed = true }
            return (closed, Array(waiting.keys))
        }
        guard !alreadyClosed else { return }
        tokens.forEach { reply($0, [:]) }
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        unlink(socketPath)
        rmdir(directory)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let connection = accept(fd, nil, nil)
            if connection < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return  // closed
            }
            _ = fcntl(connection, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [weak self] in
                guard let self else {
                    Darwin.close(connection)
                    return
                }
                self.serve(connection)
            }
        }
    }

    private func serve(_ connection: Int32) {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count < 1 << 20 {
            let count = recv(connection, &buffer, buffer.count, 0)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["id"] as? String, object["token"] as? String == secret else {
            Darwin.close(connection)
            return
        }
        let fromAirSCP = Askpass.startedByThisApp(peerOf: connection)
        let (token, handler, proxyHandler): (UInt64, Handler?, ProxyHandler?) = lock.locked {
            nextToken += 1
            waiting[nextToken] = (connection, id)
            return (nextToken, handlers[id], _proxyHandler)
        }
        // The proxy-connect helper wants a saved proxy's address and credentials.
        if let proxy = object["proxy"] as? String {
            guard let proxyID = UUID(uuidString: proxy), let proxyHandler else { return reply(token, [:]) }
            let mayAsk = object["mayAsk"] as? Bool ?? true
            DispatchQueue.main.async {
                proxyHandler(proxyID, mayAsk, fromAirSCP) { [weak self] answer in
                    DebugLog.Secrets.add(answer?.password)
                    self?.reply(token, answer.map { ["host": $0.proxy.host, "port": $0.proxy.port,
                                                     "username": $0.proxy.username, "password": $0.password] } ?? [:])
                }
            }
            return
        }
        guard let prompt = object["prompt"] as? String, let handler else { return reply(token, [:]) }
        let request = AskpassRequest(id: id, prompt: prompt, pid: Int32(object["pid"] as? Int ?? 0),
                                     silent: object["silent"] as? Bool ?? false, fromAirSCP: fromAirSCP)
        DispatchQueue.main.async {
            handler(request) { [weak self] answer in self?.reply(token, answer.map { ["answer": $0] } ?? [:]) }
        }
    }

    /// Sends the reply (empty: cancelled) once and closes the connection.
    private func reply(_ token: UInt64, _ object: [String: Any]) {
        guard let connection = lock.locked({ waiting.removeValue(forKey: token) })?.connection else { return }
        if let body = try? JSONSerialization.data(withJSONObject: object) {
            _ = body.withUnsafeBytes { send(connection, $0.baseAddress, $0.count, 0) }
        }
        Darwin.close(connection)
    }
}
