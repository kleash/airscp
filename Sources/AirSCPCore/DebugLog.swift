import Darwin
import Foundation

/// The debug log (PLAN.md AE): while it is on (Settings ▸ Debug logging, or AIRSCP_DEBUG=1), what happens on the way
/// to a server goes into one plain-text file a user can attach to a problem report: each host's commands with ssh's
/// own debug output (-vv, added by `Runner`), the HTTP proxy helper's answers, the questions ssh asked (never the
/// answers), connection states and reconnects, transfers, and Remote Desktop's FreeRDP log. Each line has the time and
/// the host. A line that holds a known secret (a password, passphrase, the helpers' tokens) is left out, and nothing is
/// sent anywhere. The file is ~/Library/Logs/AirSCP/AirSCP-debug.log (a throwaway AirSCP's is in its
/// AIRSCP_SUPPORT_DIR); at 10 MB it becomes AirSCP-debug.1.log, replacing the one before, and a new file starts.
public enum DebugLog {
    /// AIRSCP_DEBUG=1: on whatever Settings say (tests and agents; the app turns it on at launch).
    public static let forced = Env.value("DEBUG") == "1"

    /// Commands started from now on are logged (an ssh connection's own debug output from its next connect). Turning it
    /// on writes a first line, so the file is there at once.
    public static var enabled: Bool {
        get { lock.locked { _enabled } }
        set {
            guard newValue != enabled else { return }
            if !newValue { write("Debug logging off") }
            lock.locked { _enabled = newValue }
            if newValue { write("Debug logging on: \(about)") }
        }
    }

    public static var fileURL: URL {
        if let dir = Env.value("SUPPORT_DIR"), !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("AirSCP-debug.log")
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/AirSCP/AirSCP-debug.log")
    }

    /// The file before the current one.
    static var previousFileURL: URL { fileURL.deletingLastPathComponent().appendingPathComponent("AirSCP-debug.1.log") }

    /// At this size the file becomes the previous one (the tests make it smaller).
    static var sizeLimit = 10 << 20

    /// "AirSCP 1.0.0, macOS 26.5.0".
    public static var about: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "(development build)"
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return "AirSCP \(version), macOS \(system.majorVersion).\(system.minorVersion).\(system.patchVersion)"
    }

    /// Writes `text` (each of its lines) with the time and the host: "2026-10-05 14:03:12.345 [web-01] text". Nothing
    /// while the log is off.
    public static func write(_ text: String, host: String? = nil) {
        guard enabled else { return }
        let date = Date()
        queue.async { append(text, host: host, date: date) }
    }

    /// The passwords, passphrases and tokens that must never be in the log: a line that would hold one is left out
    /// (`redacted`). A type of its own because CodeQL takes any text handed to a function of a "…Log" type for logged
    /// text (swift/cleartext-logging), and these are only looked for.
    public enum Secrets {
        /// Shorter than 4 characters isn't looked for (it would leave out lines with ordinary words).
        public static func add(_ value: String?) {
            guard let value, value.count >= 4 else { return }
            // Its bytes: searched in every line written, which must stay quick (a typed password is a bridged
            // NSString, whose comparisons with each line took most of the time while ssh wrote fast).
            let bytes = Array(value.utf8)
            lock.locked {
                if !secrets.contains(bytes) { secrets.append(bytes) }
            }
        }
    }

    /// A saved host's name for the lines of its commands (`Session` gives its host).
    static func name(_ host: SSHHost) {
        lock.locked { names[host.id] = host.displayName }
    }

    static func name(for id: UUID?) -> String? {
        id.flatMap { id in lock.locked { names[id] } }
    }

    /// Waits until everything written so far is in the file.
    public static func flush() {
        queue.sync {}
    }

    /// The file's last `count` lines (Help ▸ Copy Diagnostics).
    public static func tail(_ count: Int = 500) -> String {
        flush()
        guard let file = try? FileHandle(forReadingFrom: fileURL) else { return "" }
        defer { try? file.close() }
        let end = (try? file.seekToEnd()) ?? 0
        try? file.seek(toOffset: end > 512 << 10 ? end - (512 << 10) : 0)
        let text = String(decoding: (try? file.readToEnd()) ?? Data(), as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(count + 1).joined(separator: "\n")
    }

    /// `text` without the lines that hold a known secret (each left out with a note), and with any HTTP authorization
    /// header blanked out. The whole line goes: a marker in the secret's place would show which text it was where a
    /// reader can guess it (a password that is also the user name). A secret counts only on its own, not inside a
    /// longer run of letters and digits (a code 000000 isn't in "0x04000000").
    static func redacted(_ text: String) -> String {
        var text = text
        let secrets = lock.locked { self.secrets }
        if !secrets.isEmpty, holdsSecret(Substring(text), secrets) {
            text = text.split(separator: "\n", omittingEmptySubsequences: false)
                .map { holdsSecret($0, secrets) ? "(line left out: it held a password or token)" : String($0) }
                .joined(separator: "\n")
        }
        guard text.range(of: "authorization:", options: .caseInsensitive) != nil else { return text }
        return authorization.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                      withTemplate: "$1: [redacted]")
    }

    /// Whether `text` holds one of `secrets` (UTF-8) on its own: not with a letter or digit just before or after it,
    /// where the secret itself starts or ends with one.
    private static func holdsSecret(_ text: Substring, _ secrets: [[UInt8]]) -> Bool {
        var text = text
        return text.withUTF8 { haystack in
            guard let base = haystack.baseAddress else { return false }
            return secrets.contains { secret in
                var from = 0
                while from + secret.count <= haystack.count,
                      let found = memmem(base + from, haystack.count - from, secret, secret.count) {
                    let start = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(found)), end = start + secret.count
                    if !(isWordByte(secret[0]) && start > 0 && isWordByte(haystack[start - 1]))
                        && !(isWordByte(secret[secret.count - 1]) && end < haystack.count && isWordByte(haystack[end])) {
                        return true
                    }
                    from = start + 1
                }
                return false
            }
        }
    }

    /// A letter or digit, or a byte of a non-ASCII character.
    private static func isWordByte(_ byte: UInt8) -> Bool {
        byte >= 0x80 || (0x30...0x39).contains(byte) || (0x61...0x7A).contains(byte | 0x20)
    }

    private static let authorization = try! NSRegularExpression(pattern: #"(?i)\b((proxy-)?authorization):[ \t]*\S+([ \t]+\S+)?"#)

    /// ssh's, scp's and sftp's debug output (-vv), and the proxy helper's ("debug1: proxy-connect: …"): what they say
    /// only because the debug log is on.
    static func isDebugOutput(_ line: String) -> Bool {
        var line = Substring(line)
        // scp and sftp put their own name first ("/usr/bin/scp: debug2: Remote version: 3").
        if let colon = line.range(of: ": "), line[..<colon.lowerBound].hasSuffix("scp") || line[..<colon.lowerBound].hasSuffix("sftp") {
            line = line[colon.upperBound...]
        }
        return ["debug1: ", "debug2: ", "debug3: ", "Authenticated to ", "Authenticated using ", "Transferred: sent ",
                "Bytes per second: ", "Executing: program ", "OpenSSH_"].contains { line.hasPrefix($0) }
    }

    /// ssh's note of each window adjust ("debug2: channel 0: rcvd adjust 16384"): some 55 000 for a 2 GB transfer,
    /// which pushed everything before them out of the log (and its one older file). Left out of the log.
    static func isWindowAdjust(_ line: String) -> Bool {
        line.hasPrefix("debug2: channel ") && (line.contains(": rcvd adjust ") || line.contains(" sent adjust "))
    }

    /// One logged process's error output (`Runner`), read by one thread: each whole line goes into the log, and what
    /// isn't debug output is handed back, so the rest of AirSCP sees the same error output as with the log off.
    final class ErrorOutput {
        private let host: String?
        /// "ssh[4321]".
        private let process: String
        private var partial = Data()

        /// Logs that `argv` (with `input`, as the command log shows it) started as `pid`.
        init(_ argv: [String], input: String?, pid: pid_t, hostID: UUID?) {
            host = DebugLog.name(for: hostID)
            process = "\(((argv.first ?? "") as NSString).lastPathComponent)[\(pid)]"
            DebugLog.write("\(process) started: \(Runner.shellLine(argv, input: input))", host: host)
        }

        /// The whole lines of `chunk` that aren't debug output; the start of an unfinished line waits for its end.
        func pass(_ chunk: Data) -> Data {
            partial.append(chunk)
            guard let end = partial.lastIndex(of: 0x0A) else {
                return partial.count > 65536 ? finish() : Data()  // no line end at all: not to be held for ever
            }
            let whole = partial.prefix(through: end)
            partial = Data(partial.suffix(from: end + 1))
            return pass(lines: whole)
        }

        /// What is left at the end of the output.
        func finish() -> Data {
            defer { partial = Data() }
            return partial.isEmpty ? Data() : pass(lines: partial)
        }

        func exited(_ status: Int32) {
            DebugLog.write("\(process) exited with status \(status)", host: host)
        }

        private func pass(lines data: Data) -> Data {
            var lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            let ended = data.last == 0x0A  // else the last line is the end of the output, without a line end
            if ended { lines.removeLast() }
            var kept = Data(), logged: [String] = []
            for (index, line) in lines.enumerated() {
                let text = String(decoding: line, as: UTF8.self).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
                if !DebugLog.isWindowAdjust(text) { logged.append("\(process): \(text)") }
                guard !DebugLog.isDebugOutput(text) else { continue }
                kept += line
                if ended || index < lines.count - 1 { kept.append(0x0A) }
            }
            if !logged.isEmpty { DebugLog.write(logged.joined(separator: "\n"), host: host) }
            return kept
        }
    }

    // MARK: Internals

    private static let lock = NSLock()
    private static var _enabled = false
    private static var secrets: [[UInt8]] = []
    private static var names: [UUID: String] = [:]
    /// The file, and the bytes in it; only on `queue`.
    private static let queue = DispatchQueue(label: "com.kleash.airscp.debuglog")
    private static var file: Int32 = -1
    private static var size = 0
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    private static func append(_ text: String, host: String?, date: Date) {
        let prefix = formatter.string(from: date) + (host.map { " [\($0)]" } ?? "") + " "
        let text = redacted(text).trimmingCharacters(in: .newlines)
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map { line -> String in
            guard line.count > 16_000 else { return prefix + line }
            return prefix + line.prefix(8000) + " … (\(line.count - 16_000) characters left out) … " + line.suffix(8000)
        }
        let data = Data((lines.joined(separator: "\n") + "\n").utf8)
        // A file removed meanwhile (the user deleted it) is made again.
        var info = stat()
        if file >= 0, fstat(file, &info) != 0 || info.st_nlink == 0 {
            close(file)
            file = -1
        }
        if file < 0 {
            let url = fileURL
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            file = open(url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600)
            guard file >= 0 else { return }
            size = fstat(file, &info) == 0 ? Int(info.st_size) : 0
        }
        let written = data.withUnsafeBytes { Darwin.write(file, $0.baseAddress, $0.count) }
        size += max(0, written)
        if size >= sizeLimit {
            close(file)
            file = -1
            rename(fileURL.path, previousFileURL.path)
        }
    }
}
