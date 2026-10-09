import CPTY
import Darwin
import Foundation

/// A program on a pseudo-terminal, shown by a `TerminalScreen`: AirSCP's own terminal (PLAN.md W) runs ssh there,
/// riding the host's master connection (no second login). What the program writes goes to the screen on the main
/// queue; keys and pastes go back with `send`. The screen's answers (cursor position…) go back by themselves.
public final class TerminalSession {
    public let screen: TerminalScreen
    /// Called on the main queue after the screen changed.
    public var onChange: () -> Void = {}
    /// Called on the main queue once the program has ended, with its exit status.
    public var onExit: (Int32) -> Void = { _ in }
    public private(set) var running = false
    public let pid: pid_t

    private let master: Int32
    private let reader: DispatchSourceRead
    private let exitWatch: DispatchSourceProcess
    private let queue = DispatchQueue(label: "AirSCP terminal")

    /// Starts `argv` on a terminal of the screen's size. Throws when it can't start.
    public init(_ argv: [String], environment: [String: String], screen: TerminalScreen) throws {
        self.screen = screen
        var environment = environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        (pid, master) = try Runner.spawnOnTerminal(argv, environment: environment, columns: screen.columns, rows: screen.rows)
        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        running = true
        reader = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        exitWatch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        let fd = master
        reader.setEventHandler { [weak self] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            var data = Data()
            while true {
                let count = read(fd, &buffer, buffer.count)
                if count > 0 {
                    data.append(contentsOf: buffer[0..<count])
                    if data.count >= 1 << 20 { break }
                } else {
                    break
                }
            }
            guard !data.isEmpty else { return }
            DispatchQueue.main.async {
                guard let self else { return }
                self.screen.feed(data)
                self.onChange()
            }
        }
        let child = pid
        exitWatch.setEventHandler { [weak self] in
            var status: Int32 = 0
            waitpid(child, &status, 0)
            let code = (status & 0x7F) == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
            DispatchQueue.main.async {
                guard let self, self.running else { return }
                self.running = false
                self.onExit(code)
            }
            self?.exitWatch.cancel()
        }
        screen.respond = { [weak self] data in self?.send(data) }
        reader.resume()
        exitWatch.resume()
    }

    deinit { close() }

    /// Writes keys, a paste or an answer to the program.
    public func send(_ data: Data) {
        guard running, !data.isEmpty else { return }
        let fd = master
        queue.async {
            var offset = 0
            data.withUnsafeBytes { bytes in
                var waits = 0
                while offset < bytes.count {
                    let written = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
                    if written > 0 {
                        offset += written
                    } else if written < 0 && (errno == EAGAIN || errno == EINTR) && waits < 2000 {
                        waits += 1
                        usleep(1000)  // the program reads slower than a big paste comes
                    } else {
                        return
                    }
                }
            }
        }
    }

    public func send(_ text: String) { send(Data(text.utf8)) }

    /// A paste: between the bracketed-paste marks when the program asked for them, and without escape characters (a
    /// pasted ESC [201~ would end the paste early and run the rest as typed).
    public func paste(_ text: String) {
        let clean = text.replacingOccurrences(of: "\u{1B}", with: "").replacingOccurrences(of: "\r\n", with: "\r")
            .replacingOccurrences(of: "\n", with: "\r")
        send(screen.bracketedPaste ? "\u{1B}[200~" + clean + "\u{1B}[201~" : clean)
    }

    /// A new size for the screen and the terminal (the program gets SIGWINCH).
    public func resize(columns: Int, rows: Int) {
        screen.resize(columns: columns, rows: rows)
        guard running else { return }
        _ = cpty_resize(master, UInt16(clamping: screen.columns), UInt16(clamping: screen.rows))
    }

    /// Ends the program (a hangup, as closing a terminal window does) and lets the terminal go.
    public func close() {
        guard !reader.isCancelled else { return }
        if running { kill(pid, SIGHUP) }
        reader.cancel()
        Darwin.close(master)
    }
}

extension TerminalSession {
    /// The keys a Mac key press sends to a terminal program, nil for one it doesn't take (⌘ shortcuts are the app's).
    /// `characters` is what the key types; `applicationCursor`: arrows as ESC O A… (the screen's DECCKM).
    public static func keys(keyCode: UInt16, characters: String?, control: Bool, option: Bool, shift: Bool,
                            applicationCursor: Bool) -> String? {
        let arrows: [UInt16: String] = [126: "A", 125: "B", 124: "C", 123: "D"]
        if let arrow = arrows[keyCode] {
            let modifier = (shift ? 1 : 0) + (option ? 2 : 0) + (control ? 4 : 0)
            if modifier > 0 { return "\u{1B}[1;\(modifier + 1)\(arrow)" }
            return (applicationCursor ? "\u{1B}O" : "\u{1B}[") + arrow
        }
        switch keyCode {
        case 36, 76: return "\r"  // Return, Enter
        case 48: return shift ? "\u{1B}[Z" : "\t"
        case 51: return option ? "\u{1B}\u{7F}" : "\u{7F}"  // Delete (backspace); ⌥ deletes a word
        case 53: return "\u{1B}"
        case 117: return "\u{1B}[3~"  // forward delete
        case 115: return applicationCursor ? "\u{1B}OH" : "\u{1B}[H"  // Home
        case 119: return applicationCursor ? "\u{1B}OF" : "\u{1B}[F"  // End
        case 116: return "\u{1B}[5~"  // Page Up
        case 121: return "\u{1B}[6~"  // Page Down
        default: break
        }
        let functionKeys: [UInt16: String] = [122: "\u{1B}OP", 120: "\u{1B}OQ", 99: "\u{1B}OR", 118: "\u{1B}OS",
                                              96: "\u{1B}[15~", 97: "\u{1B}[17~", 98: "\u{1B}[18~", 100: "\u{1B}[19~",
                                              101: "\u{1B}[20~", 109: "\u{1B}[21~", 103: "\u{1B}[23~", 111: "\u{1B}[24~"]
        if let function = functionKeys[keyCode] { return function }
        guard let characters, !characters.isEmpty else { return nil }
        if control, let scalar = characters.lowercased().unicodeScalars.first {
            // Ctrl+A…Z and Ctrl+@ [ \ ] ^ _ (and Ctrl+Space, Ctrl+/ as most terminals send them).
            switch scalar.value {
            case 0x61...0x7A: return String(UnicodeScalar(UInt8(scalar.value - 0x60)))
            case 0x40, 0x20, 0x32: return "\u{0}"
            case 0x5B, 0x33: return "\u{1B}"
            case 0x5C, 0x34: return "\u{1C}"
            case 0x5D, 0x35: return "\u{1D}"
            case 0x5E, 0x36: return "\u{1E}"
            case 0x5F, 0x2F, 0x37: return "\u{1F}"
            default: break
            }
        }
        return characters
    }
}
