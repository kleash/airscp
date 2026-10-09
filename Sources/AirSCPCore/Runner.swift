import CPTY
import Darwin
import Foundation

/// What a finished command produced.
public struct CommandResult {
    /// The exit status; 128 + the signal number when a signal ended it, 127 when it couldn't start.
    public var status: Int32
    public var stdout: Data
    public var stderr: String

    public init(status: Int32, stdout: Data = Data(), stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    public var output: String { String(decoding: stdout, as: UTF8.self) }
}

/// One line of the command log: what ran (as a shell line that can be copied and pasted), how it ended.
public struct LogEntry: Identifiable {
    public let id = UUID()
    public let date: Date
    /// The host the command was for (nil for local tools such as ssh-keygen).
    public let hostID: UUID?
    public let command: String
    /// nil while the command is still running (the master connection is logged when it starts).
    public let status: Int32?
    public let stderr: String
}

/// Stops a running command (SIGTERM to its process group; both commands of a `Runner.pump`), or keeps a queued one
/// from starting.
public final class Cancellation {
    private let lock = NSLock()
    private var pids: Set<pid_t> = []
    private var cancelled = false
    private var cancelActions: [() -> Void] = []

    public init() {}

    public var isCancelled: Bool { lock.locked { cancelled } }

    public func cancel() {
        let actions = lock.locked { () -> [() -> Void] in
            cancelled = true
            for pid in pids { kill(-pid, SIGTERM) }
            defer { cancelActions = [] }
            return cancelActions
        }
        actions.forEach { $0() }
    }

    /// Runs `action` when this is cancelled (at once if it already is), after the processes were signalled.
    public func onCancel(_ action: @escaping () -> Void) {
        let now = lock.locked { () -> Bool in
            if !cancelled { cancelActions.append(action) }
            return cancelled
        }
        if now { action() }
    }

    /// Records a started process; kills it at once if the cancellation came first.
    fileprivate func attach(_ pid: pid_t) {
        lock.locked {
            pids.insert(pid)
            if cancelled { kill(-pid, SIGTERM) }
        }
    }

    /// The process has exited (not yet reaped): its process group id may not be signalled any more.
    fileprivate func detach(_ pid: pid_t) {
        lock.locked { _ = pids.remove(pid) }
    }
}

/// Runs the OpenSSH tools. posix_spawn, not Foundation's Process: Process turns arguments into decomposed
/// Unicode (NFD), which would make a server's precomposed (NFC) file names unreachable.
public enum Runner {
    /// Test seam: environment variables set for every command (e.g. HOME for ssh-copy-id's scratch folder).
    public static var environmentOverrides: [String: String] = [:]

    /// Runs `argv` to its end. `input` is written to its standard input (an sftp batch), else /dev/null.
    /// `log` is called on the main queue when it has finished. `standardOutput` and `errorOutput` get each part of the
    /// output and the error output as it comes (on a background thread), which the result also has.
    public static func run(_ argv: [String], input: String? = nil, environment: [String: String] = [:],
                           cancellation: Cancellation? = nil, hostID: UUID? = nil, log: ((LogEntry) -> Void)? = nil,
                           standardOutput: ((Data) -> Void)? = nil, errorOutput: ((Data) -> Void)? = nil) async -> CommandResult {
        await withCheckedContinuation { continuation in
            run(argv, input: input.map(Input.text) ?? .none, output: .collect(standardOutput), environment: environment,
                hostID: hostID, cancellation: cancellation, errorOutput: errorOutput) { result in
                report(argv, input: input, hostID: hostID, result: result, to: log)
                continuation.resume(returning: result)
            }
        }
    }

    /// Runs `argv` with a pseudo-terminal as its standard output (scp and sftp only report progress to a terminal) and
    /// hands that output to `output` as it arrives, on a background thread. `input` as for `run`. The result's stdout
    /// is empty.
    public static func runOnTerminal(_ argv: [String], input: String? = nil, environment: [String: String] = [:],
                                     cancellation: Cancellation? = nil, hostID: UUID? = nil,
                                     log: ((LogEntry) -> Void)? = nil,
                                     output: @escaping (Data) -> Void) async -> CommandResult {
        await withCheckedContinuation { continuation in
            run(argv, input: input.map(Input.text) ?? .none, output: .terminal(output), environment: environment,
                hostID: hostID, cancellation: cancellation) { result in
                report(argv, input: input, hostID: hostID, result: result, to: log)
                continuation.resume(returning: result)
            }
        }
    }

    /// Where `pump` copies to.
    enum Sink {
        /// An open file, e.g. a download's part file; the pump closes it once nothing more will be written.
        case file(Int32)
        /// The standard input of a second command, started next to the first (logged with its own host).
        case command([String], environment: [String: String], hostID: UUID?, log: ((LogEntry) -> Void)?)
    }

    /// How a `pump` went.
    struct Pumped {
        var producer: CommandResult
        /// nil for a file sink.
        var consumer: CommandResult?
        /// Copied into the sink (the marker and what came before it not counted).
        var bytes: Int64
        /// The stream began: the marker was seen (always true without one).
        var started: Bool
        /// The sink stopped taking data (errno): the consumer ended early, or the disk is full. The producer was
        /// stopped then.
        var writeError: Int32?
    }

    /// Runs `producer` and copies its standard output into `sink` in chunks of up to 64 KB, through this process, so
    /// that the bytes can be counted: `progress` gets the total so far after each chunk, on a background thread.
    /// Output up to and including `marker` is dropped first (a remote login shell's noise before the stream).
    /// `input` goes to the producer's standard input (a script for `sh -s`, names for tar -T). A sink that stops taking
    /// data stops the producer (its output is closed); `cancellation` stops both commands. `limit`: at most this many
    /// bytes a second (the producer waits meanwhile). `preamble` (a command sink only) is written to the consumer's
    /// standard input before the stream, so a remote consumer can read a value there with the `read` builtin rather
    /// than take it on its command line (`TransferQueue.consumer`). Returns once both have ended and everything read
    /// was written.
    static func pump(_ producer: [String], input: String? = nil, environment: [String: String] = [:], hostID: UUID?,
                     log: ((LogEntry) -> Void)?, into sink: Sink, after marker: Data?, cancellation: Cancellation,
                     limit: Int? = nil, preamble: Data? = nil, progress: @escaping (Int64) -> Void) async -> Pumped {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            let group = DispatchGroup()
            var pumped = Pumped(producer: CommandResult(status: 0), consumer: nil, bytes: 0, started: marker == nil,
                                writeError: nil)
            var skipped = Data()
            var began: Date?
            let target: Int32
            switch sink {
            case .file(let fd):
                target = fd
            case .command(let argv, let consumerEnvironment, let consumerHostID, let consumerLog):
                var fds: [Int32] = [-1, -1]
                guard makePipe(&fds) else {
                    let failure = CommandResult(status: 127, stderr: "Can't start \(argv[0]): \(String(cString: strerror(errno)))")
                    continuation.resume(returning: Pumped(producer: failure, consumer: failure, bytes: 0, started: false,
                                                          writeError: nil))
                    return
                }
                _ = fcntl(fds[1], F_SETNOSIGPIPE, 1)  // a consumer that exits early must not take the app down
                target = fds[1]
                group.enter()
                run(argv, input: .descriptor(fds[0]), output: .collect(nil), environment: consumerEnvironment,
                    hostID: consumerHostID, cancellation: cancellation) { result in
                    report(argv, input: nil, hostID: consumerHostID, result: result, to: consumerLog)
                    lock.locked { pumped.consumer = result }
                    group.leave()
                }
                close(fds[0])  // the consumer has its own copy
            }
            // Called by the producer's output thread only, one chunk at a time.
            func write(_ chunk: Data) -> Bool {
                if cancellation.isCancelled { return false }
                var payload = chunk
                if !lock.locked({ pumped.started }) {
                    skipped.append(chunk)
                    guard let marker, let found = skipped.range(of: marker) else {
                        return skipped.count < 1 << 20  // that much noise and no marker: this is no stream
                    }
                    payload = skipped.subdata(in: found.upperBound..<skipped.endIndex)
                    skipped = Data()
                    lock.locked { pumped.started = true }
                }
                if payload.isEmpty { return true }
                guard payload.withUnsafeBytes({ writeAll(target, $0) }) else {
                    let failure = errno
                    lock.locked { pumped.writeError = failure }
                    return false
                }
                let total = lock.locked { () -> Int64 in
                    pumped.bytes += Int64(payload.count)
                    return pumped.bytes
                }
                progress(total)
                if let limit, limit > 0 {
                    // Not ahead of the limit: wait until these bytes are due (the producer's output waits in its pipe).
                    let start = began ?? Date()
                    began = start
                    let due = start.addingTimeInterval(Double(total) / Double(limit))
                    while !cancellation.isCancelled {
                        let wait = due.timeIntervalSinceNow
                        guard wait > 0 else { break }
                        usleep(UInt32(min(wait, 0.2) * 1_000_000))
                    }
                }
                return true
            }
            // The consumer's stdin starts with the preamble (e.g. the target folder for a `read`), before the stream.
            // It is small (a path), the pipe buffer holds it, and the producer hasn't started, so it lands first.
            if let preamble, case .command = sink {
                _ = preamble.withUnsafeBytes { writeAll(target, $0) }
            }
            group.enter()
            run(producer, input: input.map(Input.text) ?? .none, output: .stream(chunk: write, end: { close(target) }),
                environment: environment, hostID: hostID, cancellation: cancellation) { result in
                report(producer, input: input, hostID: hostID, result: result, to: log)
                lock.locked { pumped.producer = result }
                group.leave()
            }
            // A queue of its own, not a global one: those can run out of threads (e.g. AppKit's file promises waiting for
            // their downloads), and then a finished stream would never be reported.
            group.notify(queue: pumpDone) {
                continuation.resume(returning: lock.locked { pumped })
            }
        }
    }

    /// Starts a long-running process (the master connection) with /dev/null as its input and output.
    /// `stderr` gets its error output as it arrives and `exited` its status, both on background threads. `hostID`: the
    /// host it is for (its debug output goes into the debug log, as for `run`).
    static func start(_ argv: [String], environment: [String: String], hostID: UUID? = nil,
                      stderr: @escaping (String) -> Void, exited: @escaping (Int32) -> Void) throws -> pid_t {
        var errPipe: [Int32] = [-1, -1]
        guard makePipe(&errPipe) else { throw AirSCPError(.other, "Can't start \(argv[0]): \(String(cString: strerror(errno)))") }
        let devNull = open("/dev/null", O_RDWR | O_CLOEXEC)
        defer { close(devNull) }
        let logged = DebugLog.enabled && hostID != nil
        let pid: pid_t
        do {
            pid = try spawn(logged ? OpenSSH.verbose(argv) : argv, environment: environment, debug: logged, stdin: devNull,
                            stdout: devNull, stderr: errPipe[1])
        } catch {
            close(errPipe[0])
            close(errPipe[1])
            throw error
        }
        close(errPipe[1])
        let lines = logged ? DebugLog.ErrorOutput(argv, input: nil, pid: pid, hostID: hostID) : nil
        let drained = DispatchSemaphore(value: 0)
        drain(errPipe[0], chunk: {
            let data = lines?.pass($0) ?? $0
            if !data.isEmpty { stderr(String(decoding: data, as: UTF8.self)) }
            return true
        }, done: {
            if let rest = lines?.finish(), !rest.isEmpty { stderr(String(decoding: rest, as: UTF8.self)) }
            drained.signal()
        })
        Thread.detachNewThread {
            let status = reap(pid, cancellation: nil)
            // Its last error output first (what made it exit). A child it started may keep the pipe open: not long.
            _ = drained.wait(timeout: .now() + 2)
            lines?.exited(status)
            exited(status)
        }
        return pid
    }

    /// The command as a line for a shell, with its input (an sftp batch, a script, NUL-separated names) piped in.
    public static func shellLine(_ argv: [String], input: String? = nil) -> String {
        let command = argv.map(Quote.shellWord).joined(separator: " ")
        guard let input else { return command }
        let separator: Character = input.contains("\0") ? "\0" : "\n"
        let lines = input.split(separator: separator, omittingEmptySubsequences: true).map { Quote.shell(String($0)) }
        return "printf '%s\\\(separator == "\0" ? "0" : "n")' " + lines.joined(separator: " ") + " | " + command
    }

    // MARK: Internals

    private static func report(_ argv: [String], input: String?, hostID: UUID?, result: CommandResult,
                               to log: ((LogEntry) -> Void)?) {
        guard let log else { return }
        // A sentinel-wrapped script: its own status (ssh's is that of the printf ending it) and the error output
        // after the login noise.
        var status = result.status, stderr = RemotePID.removed(from: result.stderr)  // Session.run's marker isn't news
        if let parsed = OpenSSH.parseSentinel(result.stdout) {
            status = parsed.status
            stderr = OpenSSH.afterMarker(stderr)
        }
        let entry = LogEntry(date: Date(), hostID: hostID, command: shellLine(argv, input: input), status: status, stderr: stderr)
        DispatchQueue.main.async { log(entry) }
    }

    /// A command's standard input.
    private enum Input {
        /// /dev/null.
        case none
        /// Written to a pipe (an sftp batch).
        case text(String)
        /// This descriptor; the caller closes its own copy once the command has started.
        case descriptor(Int32)
    }

    /// Where a command's standard output goes.
    private enum Output {
        /// Into the result (and to the handler, as it arrives).
        case collect(((Data) -> Void)?)
        /// A pseudo-terminal, handed on as it arrives.
        case terminal((Data) -> Void)
        /// A pipe, handed on as it arrives. `chunk` returns false to stop reading (the pipe is closed, so the command
        /// gets EPIPE); `end` runs once nothing more will be read, before the result is reported (unless cancelled).
        case stream(chunk: (Data) -> Bool, end: () -> Void)
    }

    /// Error output kept per command, its end (a tar of a big tree can complain about every file); the rest is dropped.
    private static let errorLimit = 65536
    private static let pumpDone = DispatchQueue(label: "com.kleash.airscp.pump")

    /// Spawns, collects output, reaps; `completion` runs on a background thread. While the debug log is on, a host's
    /// commands run with the tools' debug output on, and their error output goes into the log (`DebugLog.ErrorOutput`:
    /// the result's stays as it would be without).
    private static func run(_ argv: [String], input: Input, output: Output, environment: [String: String], hostID: UUID?,
                            cancellation: Cancellation?, errorOutput: ((Data) -> Void)? = nil,
                            completion: @escaping (CommandResult) -> Void) {
        var streamEnd: (() -> Void)?
        if case .stream(_, let end) = output { streamEnd = end }
        if cancellation?.isCancelled == true {
            streamEnd?()
            completion(CommandResult(status: 128 + SIGTERM, stderr: "Cancelled"))
            return
        }
        let devNull = open("/dev/null", O_RDWR | O_CLOEXEC)
        defer { close(devNull) }
        var errPipe: [Int32] = [-1, -1], outPipe: [Int32] = [-1, -1], inPipe: [Int32] = [-1, -1]
        var text: String?
        if case .text(let value) = input { text = value }
        var onTerminal = false
        if case .terminal = output { onTerminal = true }
        guard makePipe(&errPipe), onTerminal || makePipe(&outPipe), text == nil || makePipe(&inPipe) else {
            (errPipe + outPipe + inPipe).filter { $0 >= 0 }.forEach { close($0) }
            streamEnd?()
            completion(CommandResult(status: 127, stderr: "Can't start \(argv[0]): \(String(cString: strerror(errno)))"))
            return
        }
        let stdinFD: Int32
        switch input {
        case .none: stdinFD = devNull
        case .text: stdinFD = inPipe[0]
        case .descriptor(let fd): stdinFD = fd
        }
        var master: Int32 = -1
        let started: Result<pid_t, Error>
        let logged = DebugLog.enabled && hostID != nil
        let spawned = logged ? OpenSSH.verbose(argv) : argv
        if onTerminal {
            let (cArgs, cEnv) = cStrings(spawned, environment: environment, debug: logged)
            let pid = cpty_spawn(argv[0], cArgs, cEnv, stdinFD, errPipe[1], 512, 24, &master)
            let failure = errno
            freeCStrings(cArgs, cEnv)
            if master >= 0 { _ = fcntl(master, F_SETFD, FD_CLOEXEC) }
            started = pid > 0 ? .success(pid) : .failure(AirSCPError(.other, "Can't start \(argv[0]): \(String(cString: strerror(failure)))"))
        } else {
            started = Result {
                try spawn(spawned, environment: environment, debug: logged, stdin: stdinFD, stdout: outPipe[1], stderr: errPipe[1])
            }
        }
        // The child has its own copies of these.
        [errPipe[1], outPipe[1], inPipe[0]].filter { $0 >= 0 }.forEach { close($0) }
        let pid: pid_t
        switch started {
        case .success(let value):
            pid = value
        case .failure(let error):
            [errPipe[0], outPipe[0], inPipe[1], master].filter { $0 >= 0 }.forEach { close($0) }
            streamEnd?()
            completion(CommandResult(status: 127, stderr: error.localizedDescription))
            return
        }
        cancellation?.attach(pid)
        let lines = logged ? DebugLog.ErrorOutput(argv, input: text, pid: pid, hostID: hostID) : nil
        if let text {
            let data = Array(text.utf8)
            let writer = inPipe[1]
            _ = fcntl(writer, F_SETNOSIGPIPE, 1)  // a command that exits early must not take the app down
            Thread.detachNewThread {
                _ = data.withUnsafeBytes { writeAll(writer, $0) }
                close(writer)
            }
        }
        let lock = NSLock()
        var out = Data(), err = Data()
        let streams = DispatchGroup()
        streams.enter()
        streams.enter()
        switch output {
        case .collect(let handler):
            drain(outPipe[0], chunk: { data in
                handler?(data)
                lock.locked { out.append(data) }
                return true
            }, done: { streams.leave() })
        case .terminal(let handler):
            drain(master, chunk: { handler($0); return true }, done: { streams.leave() })
        case .stream(let chunk, let end):
            drain(outPipe[0], chunk: chunk, done: {
                end()
                streams.leave()
            })
        }
        func keep(_ data: Data) {
            guard !data.isEmpty else { return }
            errorOutput?(data)
            // The end is kept: a command's last words say how it ended (a tar of a big tree complains about every file).
            lock.locked {
                err.append(data)
                if err.count > 2 * errorLimit { err = err.suffix(errorLimit) }
            }
        }
        drain(errPipe[0], chunk: { data in
            keep(lines?.pass(data) ?? data)
            return true
        }, done: {
            if let lines { keep(lines.finish()) }
            streams.leave()
        })
        Thread.detachNewThread {
            let status = reap(pid, cancellation: cancellation)
            if streamEnd != nil {
                // A stream's last chunks may still be on their way into the sink: wait for them, unless cancelled.
                while streams.wait(timeout: .now() + 0.2) == .timedOut && cancellation?.isCancelled != true {}
            } else {
                // Output still buffered in the pipes arrives right after the exit. Something else may hold them open
                // (the master keeps a muxed command's pipes until the remote side ends): don't wait long for that,
                // and hardly at all after a cancel.
                _ = streams.wait(timeout: .now() + (cancellation?.isCancelled == true ? 0.2 : 2))
            }
            let result = lock.locked { () -> CommandResult in
                var kept = err
                if kept.count > errorLimit {  // from the start of a line
                    kept = kept.suffix(errorLimit)
                    if let newline = kept.firstIndex(of: 0x0A) { kept = kept[(newline + 1)...] }
                }
                return CommandResult(status: status, stdout: out, stderr: String(decoding: kept, as: UTF8.self))
            }
            lines?.exited(status)
            completion(result)
        }
    }

    /// A connected pair of sockets, used like a pipe ([0] reads, [1] writes), whose ends are not inherited by children
    /// that don't ask for them. Not a pipe: when the system's pipe buffers run short (another app holding thousands of
    /// pipes is enough), each pipe read returns 512 bytes, and ssh then moves streams ten times slower.
    private static func makePipe(_ fds: inout [Int32]) -> Bool {
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { return false }
        fds.forEach { _ = fcntl($0, F_SETFD, FD_CLOEXEC) }
        return true
    }

    private static func spawn(_ argv: [String], environment: [String: String], debug: Bool = false, stdin: Int32,
                              stdout: Int32, stderr: Int32) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdin, 0)
        posix_spawn_file_actions_adddup2(&actions, stdout, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr, 2)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the three descriptors above are inherited (the app's other pipes and sockets are not), the child
        // gets default signal handling, and it leads a process group of its own so cancelling reaches its children.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP
                                                     | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var all = sigset_t()
        sigfillset(&all)
        posix_spawnattr_setsigdefault(&attributes, &all)
        var none = sigset_t()
        sigemptyset(&none)
        posix_spawnattr_setsigmask(&attributes, &none)
        let (cArgs, cEnv) = cStrings(argv, environment: environment, debug: debug)
        defer { freeCStrings(cArgs, cEnv) }
        var pid: pid_t = 0
        let rc = posix_spawn(&pid, argv[0], &actions, &attributes, cArgs, cEnv)
        guard rc == 0 else {
            throw AirSCPError(.other, "Can't start \(argv[0]): \(String(cString: strerror(rc)))")
        }
        return pid
    }

    /// Waits for the process to exit, tells `cancellation` before the pid can be reused, then reaps it.
    private static func reap(_ pid: pid_t, cancellation: Cancellation?) -> Int32 {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1 && errno == EINTR {}
        cancellation?.detach(pid)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    /// Reads `fd` to its end (or until `chunk` returns false) on a thread of its own, then closes it.
    private static func drain(_ fd: Int32, chunk: @escaping (Data) -> Bool, done: @escaping () -> Void) {
        Thread.detachNewThread {
            var buffer = [UInt8](repeating: 0, count: 65536)
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    if !chunk(Data(buffer[0..<count])) { break }
                } else if count < 0 && errno == EINTR {
                    continue
                } else {
                    break  // end of file, or EIO from a terminal whose other side has closed
                }
            }
            close(fd)
            done()
        }
    }

    private static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }

    private static func cStrings(_ argv: [String], environment: [String: String], debug: Bool)
        -> ([UnsafeMutablePointer<CChar>?], [UnsafeMutablePointer<CChar>?]) {
        let env = childEnvironment(ProcessInfo.processInfo.environment, environment, debug: debug)
        return (argv.map { strdup($0) } + [nil], env.map { strdup("\($0.key)=\($0.value)") } + [nil])
    }

    /// A command's environment: this app's, with `extra` and the overrides. An app started from the Finder or the Dock
    /// has no locale variables, and sftp then prints every byte of a name outside ASCII as an octal escape: UTF-8 is
    /// asked for when nothing says otherwise. AIRSCP_DEBUG=1 exactly when the command's error output is logged
    /// (`debug`): the proxy helper ssh may start then says what it does (`ProxyConnect`).
    static func childEnvironment(_ base: [String: String], _ extra: [String: String], debug: Bool = false) -> [String: String] {
        var env = base
        env.merge(extra) { $1 }
        env.merge(environmentOverrides) { $1 }
        if env["LC_ALL"] == nil && env["LC_CTYPE"] == nil && env["LANG"] == nil { env["LC_CTYPE"] = "C.UTF-8" }
        env["PORTER_DEBUG"] = nil
        env["AIRSCP_DEBUG"] = debug ? "1" : nil
        return env
    }

    /// Starts `argv` on a new pseudo-terminal of `columns` × `rows` (its standard input, output and error), for AirSCP's
    /// own terminal: returns the child's pid and the terminal's master side (close-on-exec), which the caller reads,
    /// writes, resizes (`cpty_resize`), closes and waits for.
    public static func spawnOnTerminal(_ argv: [String], environment: [String: String], columns: Int, rows: Int) throws
        -> (pid: pid_t, master: Int32) {
        let (cArgs, cEnv) = cStrings(argv, environment: environment, debug: false)
        var master: Int32 = -1
        let pid = cpty_spawn(argv[0], cArgs, cEnv, -1, -1, UInt16(clamping: columns), UInt16(clamping: rows), &master)
        let failure = errno
        freeCStrings(cArgs, cEnv)
        guard pid > 0, master >= 0 else {
            throw AirSCPError(.other, "Can't start \(argv[0]): \(String(cString: strerror(failure)))")
        }
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
        return (pid, master)
    }

    private static func freeCStrings(_ args: [UnsafeMutablePointer<CChar>?], _ env: [UnsafeMutablePointer<CChar>?]) {
        (args + env).forEach { free($0) }
    }
}

extension NSLock {
    func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
