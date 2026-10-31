import AirSCPCore
import CSSH2
import Foundation

/// A terminal on the server (`SSH2Transport.shell`): a channel with a pty that runs a command, as `ssh -t host command`
/// does. It shares the connection's libssh2 session with the other calls, so it is served on the transport's queue
/// (`Connection.serveShells`): when the socket has something while no call runs, and each time a call waits. Each
/// libssh2 call there is non-blocking: what would block goes on at the next turn (libssh2 1.11 refuses, with "again", a
/// packet of one channel while another's is half sent, so the channels can't mix up their packets).
final class Shell: RemoteShell {
    let channel: OpaquePointer
    let output: (Data) -> Void
    let ended: (Int32) -> Void
    /// Serves the shells on the transport's queue.
    let wake: () -> Void
    /// The size the server has (the queue's own).
    var sentSize: (columns: Int, rows: Int)
    /// Our close went out (the queue's own).
    var closeSent = false
    private let lock = NSLock()
    // What the app asked for, from any thread.
    private var typed = Data()
    private var size: (columns: Int, rows: Int)
    private var closing = false

    init(channel: OpaquePointer, columns: Int, rows: Int, output: @escaping (Data) -> Void,
         ended: @escaping (Int32) -> Void, wake: @escaping () -> Void) {
        self.channel = channel
        self.output = output
        self.ended = ended
        self.wake = wake
        size = (columns, rows)
        sentSize = size
    }

    func write(_ data: Data) {
        lock.withLock { typed.append(data) }
        wake()
    }

    func resize(columns: Int, rows: Int) {
        lock.withLock { size = (columns, rows) }
        wake()
    }

    func close() {
        lock.withLock { closing = true }
        wake()
    }

    /// What the app asks for now: the keys not sent yet, the size, and whether to end.
    var asked: (typed: Data, size: (columns: Int, rows: Int), closing: Bool) { lock.withLock { (typed, size, closing) } }

    /// `count` of the typed bytes went out.
    func sent(_ count: Int) { lock.withLock { typed.removeFirst(count) } }
}

extension Connection {
    /// Opens a terminal running `command` (see `Shell`); the queue's watch on the socket starts with the first one.
    func openShell(_ command: String, columns: Int, rows: Int, queue: DispatchQueue, output: @escaping (Data) -> Void,
                   ended: @escaping (Int32) -> Void) throws -> Shell {
        guard let channel = try opened(nil, {
            libssh2_channel_open_ex(session, "session", 7, 2 * 1024 * 1024, UInt32(LIBSSH2_CHANNEL_PACKET_DEFAULT), nil, 0)
        }) else { throw failure(libssh2_session_last_errno(session), "Opening a channel") }
        do {
            // As macOS's ssh sends it (SendEnv LANG); the server takes it only if it accepts it (AcceptEnv).
            _ = try again(nil) { libssh2_channel_setenv_ex(channel, "LANG", 4, "en_US.UTF-8", 11) }
            let pty = try again(nil) {
                libssh2_channel_request_pty_ex(channel, "xterm-256color", 14, nil, 0, Int32(columns), Int32(rows), 0, 0)
            }
            guard pty == 0 else { throw failure(pty, "Opening a terminal") }
            let started = try again(nil) {
                libssh2_channel_process_startup(channel, "exec", 4, command, UInt32(command.utf8.count))
            }
            guard started == 0 else { throw failure(started, "Starting the shell") }
        } catch {
            _ = try? again(nil) { libssh2_channel_free(channel) }
            throw error
        }
        let shell = Shell(channel: channel, columns: columns, rows: rows, output: output, ended: ended) { [weak self] in
            queue.async { self?.serveShells() }
        }
        shells.append(shell)
        if shellWatch == nil {
            // On a copy of the socket, closed once the watch has stopped: the connection may close its own before that.
            let watched = dup(fd)
            let watch = DispatchSource.makeReadSource(fileDescriptor: watched, queue: queue)
            watch.setEventHandler { [weak self] in self?.serveShells() }
            watch.setCancelHandler { Darwin.close(watched) }
            watch.resume()
            shellWatch = watch
        }
        return shell
    }

    /// Serves each terminal once, without waiting (see `Shell`). A send left half done goes on a moment later, when
    /// nothing else would wake the queue.
    func serveShells() {
        guard !shells.isEmpty else { return }
        shells.removeAll { serve($0) }
        if shells.isEmpty {
            shellWatch?.cancel()
            shellWatch = nil
        } else if libssh2_session_block_directions(session) & LIBSSH2_SESSION_BLOCK_OUTBOUND != 0, let shell = shells.first {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { shell.wake() }
        }
    }

    /// The connection is closing: its terminals end as ssh's would when it is lost (their channels go with the session).
    func endShells() {
        shellWatch?.cancel()
        shellWatch = nil
        for shell in shells { shell.ended(255) }
        shells = []
    }

    /// One turn of `shell`: what was typed, a new size, what came, and its end. True once it has ended (and is freed).
    private func serve(_ shell: Shell) -> Bool {
        let channel = shell.channel
        let asked = shell.asked
        do {
            if !asked.closing {
                var typed = asked.typed[...]
                while !typed.isEmpty {
                    let written = typed.withUnsafeBytes {
                        libssh2_channel_write_ex(channel, 0, $0.bindMemory(to: CChar.self).baseAddress, $0.count)
                    }
                    if written == LIBSSH2_ERROR_EAGAIN || written == 0 { break }  // 0: the server's window is full
                    guard written > 0 else { throw failure(written, "Typing in the terminal") }
                    shell.sent(written)
                    typed = typed.dropFirst(written)
                }
                if asked.size != shell.sentSize {
                    let rc = libssh2_channel_request_pty_size_ex(channel, Int32(asked.size.columns), Int32(asked.size.rows), 0, 0)
                    if rc != LIBSSH2_ERROR_EAGAIN { shell.sentSize = asked.size }  // done, or refused: not again
                }
            }
            var data = Data()
            var buffer = [CChar](repeating: 0, count: 32768)
            while data.count < 1 << 20 {
                let count = libssh2_channel_read_ex(channel, 0, &buffer, buffer.count)
                if count == LIBSSH2_ERROR_EAGAIN || count == 0 { break }  // 0: at its end
                guard count > 0 else { throw failure(count, "Reading the terminal") }
                data.append(Data(bytes: buffer, count: count))
            }
            if !data.isEmpty { shell.output(data) }
            if data.count >= 1 << 20 { shell.wake() }  // more waits in libssh2's buffer, which the socket's watch can't see
            guard asked.closing || libssh2_channel_eof(channel) == 1 else { return false }
            if !shell.closeSent {
                if libssh2_channel_close(channel) == LIBSSH2_ERROR_EAGAIN { return false }
                shell.closeSent = true
            }
            // The exit status comes before the server's close; a terminal closed here doesn't wait for it.
            if !asked.closing && libssh2_channel_wait_closed(channel) == LIBSSH2_ERROR_EAGAIN { return false }
            var signal: UnsafeMutablePointer<CChar>?
            var length = 0
            if libssh2_channel_get_exit_signal(channel, &signal, &length, nil, nil, nil, nil) == 0, let signal {
                libssh2_free(session, signal)
                shell.ended(255)  // as ssh exits when a signal ended the command
            } else {
                shell.ended(libssh2_channel_get_exit_status(channel))
            }
        } catch {
            shell.ended(255)  // the connection was lost
        }
        _ = libssh2_channel_free(channel)
        return true
    }
}
