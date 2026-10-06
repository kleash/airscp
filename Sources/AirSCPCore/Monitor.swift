import Foundation

/// A Linux server at one moment, for the Monitor tab.
public struct MonitorSnapshot: Equatable {
    /// CPU busy %, over the time since the previous refresh (/proc/stat); nil on the first one.
    public var cpu: Double?
    /// Load averages over 1, 5 and 15 minutes.
    public var load: [Double] = []
    /// In bytes, from /proc/meminfo (used = MemTotal − MemAvailable).
    public var memoryUsed: Int64 = 0
    public var memoryTotal: Int64 = 0
    public var swapUsed: Int64 = 0
    public var swapTotal: Int64 = 0
    public var uptime: TimeInterval = 0
    /// PRETTY_NAME from /etc/os-release, e.g. "Debian GNU/Linux 13 (trixie)", else `uname -sr`.
    public var system = ""
    /// `df -kP`, without empty file systems and those mounted under /dev, /proc, /run, /sys and /snap (memory,
    /// kernel and snap package file systems); a device mounted at several places (bind mounts) only at its first.
    public var disks: [MonitorDisk] = []
    public var processes: [MonitorProcess] = []
    /// Why `processes` is empty, e.g. "The server has no ps command."
    public var processNote: String?
    /// The ports, read only while Monitor ▸ Ports is shown (`refresh(ports:)`): nil otherwise.
    public var ports: MonitorPorts?
}

/// Monitor ▸ Ports: what the server listens on, from the kernel's own tables (/proc/net/tcp, tcp6, udp and udp6, which
/// every Linux has, unlike ss and netstat), and who is connected to one of those ports.
public struct MonitorPorts: Equatable {
    public var listening: [MonitorPort] = []
    /// The connections to `connectionsOf`, at most `Monitor.connectionLimit` (its `connections` says how many there are).
    public var connections: [MonitorConnection] = []
    public var connectionsOf: MonitorPort.ID?
    /// Some ports belong to processes of other users, which this account (not root) can't see.
    public var othersHidden = false
    /// Why nothing is listed although something may listen: the server has no /proc/net tables.
    public var note: String?
}

/// A listening TCP socket or a bound UDP one; several on one address and port (SO_REUSEPORT) are one.
public struct MonitorPort: Equatable, Identifiable {
    public var id: String { "\(table) \(address) \(port)" }
    /// The /proc/net table it is in: tcp, tcp6, udp or udp6.
    public var table: String
    /// "0.0.0.0" or "::" (every address of the server), "127.0.0.1", "::1"…
    public var address: String
    public var port: Int
    /// The processes that have it open, lowest first (a server that forks shares it); none when they are other
    /// users' and this account isn't root.
    public var pids: [Int] = []
    /// The first of `pids` that ps listed: its name and command line.
    public var process = ""
    public var command = ""
    /// The socket's owner: the name of its uid, else the number.
    public var user: String
    /// Open connections to it (TCP; nil for UDP, which has none).
    public var connections: Int?

    public var isTCP: Bool { table.hasPrefix("tcp") }
}

/// A connection to a listening port: the other end and the TCP state ("Established", "Close wait"…).
public struct MonitorConnection: Equatable, Identifiable {
    /// Both ends, as /proc/net prints them.
    public var id: String
    public var address: String
    public var port: Int
    public var state: String
}

/// A mounted file system (`df -kP`), sizes in bytes.
public struct MonitorDisk: Equatable, Identifiable {
    public var id: String { mountPoint }
    public var filesystem: String
    public var mountPoint: String
    public var size: Int64
    public var used: Int64
    public var available: Int64
}

/// A process. GNU ps gives every column; BusyBox ps has no %CPU (`cpu` is nil) and `memory` comes from RSS / MemTotal.
public struct MonitorProcess: Equatable, Identifiable {
    public var id: Int { pid }
    public var pid: Int
    public var ppid: Int
    public var user: String
    /// Percent; nil with BusyBox ps.
    public var cpu: Double?
    /// Percent of the memory.
    public var memory: Double?
    /// Resident memory in bytes.
    public var rss: Int64
    /// Running time in seconds (ps etime); nil when ps's format isn't understood.
    public var elapsed: TimeInterval?
    /// ps STAT, e.g. "Ss".
    public var state: String
    /// The command name (comm).
    public var name: String
    /// The full command line (args).
    public var command: String
}

/// A host's system monitor (PLAN.md I, as cut in Q): Linux only, over the host's connection. One per Monitor tab; it
/// keeps the previous CPU sample and which ps the server has (GNU, else BusyBox), decided on the first refresh.
public final class Monitor {
    public let session: Session

    private let lock = NSLock()
    /// The previous refresh's CPU times: the CPU % is the busy share of the time between two refreshes.
    private var previousCPU: CPUTimes?
    private(set) var ps = PSKind.unknown
    /// Set once the server turned out not to be Linux; later refreshes throw it without asking the server again.
    private var unsupported: AirSCPError?

    public init(session: Session) {
        self.session = session
    }

    /// A snapshot from one sentinel-wrapped shell command: /proc/stat, meminfo, loadavg and uptime, /etc/os-release
    /// (else uname), `df -kP` and ps (GNU `ps -eo pid,ppid,user,pcpu,pmem,rss,etime,stat,comm,args`, else BusyBox
    /// `ps -o pid,ppid,user,rss,etime,stat,comm,args`). `processes` false leaves ps out (the workspace header's pulse
    /// strip). `ports` adds what the server listens on (`portsScript`), and the connections to `connectionsOf`.
    /// Throws `.sftpOnly` without a shell, and an error saying so on a server that isn't Linux. Cancelling the calling
    /// task stops the command (`.cancelled`).
    public func refresh(processes: Bool = true, ports: Bool = false, connectionsOf port: MonitorPort? = nil)
        async throws -> MonitorSnapshot {
        let (ps, unsupported) = lock.locked { (self.ps, self.unsupported) }
        if let unsupported { throw unsupported }
        let cancellation = Cancellation()
        let output = try await withTaskCancellationHandler {
            try await session.shell(Monitor.script(processes ? ps : .none, ports: ports, connectionsOf: port),
                                    cancellation: cancellation)
        } onCancel: {
            cancellation.cancel()
        }
        var snapshot = try record(Monitor.parse(output), processes: processes)
        snapshot.ports?.connectionsOf = port?.id
        return snapshot
    }

    /// Takes in a refresh's output: the CPU % against the previous refresh, and (when it listed `processes`) which ps
    /// to run from now on. A server that isn't Linux throws, now and on every later refresh.
    func record(_ reading: Reading, processes: Bool = true) throws -> MonitorSnapshot {
        try lock.locked {
            guard reading.linux else {
                let error = AirSCPError(.other, "The system monitor works only on Linux servers"
                    + (reading.uname.isEmpty ? "." : " (this one runs \(reading.uname)).") + " The Files and Tunnels tabs work as usual.")
                unsupported = error
                throw error
            }
            var snapshot = reading.snapshot
            if let now = reading.cpu {
                if let previous = previousCPU { snapshot.cpu = now.busy(since: previous) }
                previousCPU = now
            }
            if processes && ps == .unknown { ps = reading.ps }
            return snapshot
        }
    }

    /// Kill (TERM) or Force Kill (`force`: KILL). Throws `.permissionDenied` when the account may not (offer "Kill with
    /// sudo in Terminal": `sudoKillCommand(pid, force:)` through the workspace's `openTerminal(command:)`), and says so
    /// when the process has already ended.
    public func kill(_ pid: Int, force: Bool) async throws {
        guard pid > 0 else { throw AirSCPError(.other, "There is no process \(pid).") }
        do {
            try await session.shell("kill -\(Monitor.signal(force)) \(pid)")
        } catch let error as AirSCPError where error.kind == .permissionDenied {
            throw AirSCPError(.permissionDenied, "This account may not stop process \(pid).", details: error.details)
        } catch let error as AirSCPError where error.details.contains("No such process") {
            throw AirSCPError(.other, "Process \(pid) has already ended.", details: error.details)
        }
    }

    /// Whether the server has sudo, before "Kill with sudo in Terminal" is offered (minimal servers often have none).
    public func hasSudo() async -> Bool {
        (try? await session.shell("command -v sudo")) != nil
    }

    /// "Kill with sudo in Terminal": `sudo kill -TERM <pids>` (-KILL for `force`), run with a terminal so that sudo
    /// can ask for the password.
    public static func sudoKillCommand(_ pids: [Int], force: Bool) -> String {
        "sudo kill -\(signal(force)) " + pids.map(String.init).joined(separator: " ")
    }

    private static func signal(_ force: Bool) -> String { force ? "KILL" : "TERM" }

    // MARK: The command and its output (internal for the tests)

    /// Which ps the server has. `.unknown` tries GNU ps, then BusyBox's.
    enum PSKind { case unknown, gnu, busybox, none }

    /// The CPU line of /proc/stat: all time and idle time (idle + iowait) since boot, in clock ticks.
    struct CPUTimes: Equatable {
        var total: UInt64
        var idle: UInt64

        func busy(since previous: CPUTimes) -> Double? {
            guard total > previous.total, idle >= previous.idle else { return nil }
            let elapsed = total - previous.total
            return Double(elapsed - min(idle - previous.idle, elapsed)) / Double(elapsed) * 100
        }
    }

    /// One run of `script`, parsed.
    struct Reading {
        /// `uname -sr`, e.g. "Linux 6.12.48-1-amd64".
        var uname = ""
        var linux = false
        /// Everything but the CPU %, which needs the previous refresh.
        var snapshot = MonitorSnapshot()
        var cpu: CPUTimes?
        /// Which ps answered (`.unknown` when none did; `.none` when the server has none or none was run).
        var ps = PSKind.unknown
    }

    static let noPS = "The server has no ps command, so processes can't be listed. The figures above still update."
    // C.UTF-8: the C locale's numbers, with names as they are (in plain C, GNU ps prints each non-ASCII byte as "?").
    static let gnuPS = "LC_ALL=C.UTF-8 ps -ww -eo pid,ppid,user,pcpu,pmem,rss,etime,stat,comm,args 2>&1"
    static let busyboxPS = "LC_ALL=C.UTF-8 ps -o pid,ppid,user,rss,etime,stat,comm,args 2>&1"

    /// One line of POSIX sh, without backslashes or "!" (csh and fish login shells would change them on the way to the
    /// sentinel's sh): `uname -sr`, then on Linux each source after a line "@@<name>", the first being the shell's own pid
    /// ($$), so that the process list can leave out this shell and the ps it runs. The C locale keeps the numbers and
    /// columns plain ASCII (ps keeps its names in UTF-8: the parser reads bytes). df comes last: a mount point is the only
    /// text in the output that a user could fill with lines of their own, and only the first "@@<name>" line counts.
    static func script(_ ps: PSKind, ports: Bool = false, connectionsOf port: MonitorPort? = nil) -> String {
        let list: String
        switch ps {
        case .unknown: list = "echo @@ps; \(gnuPS) || \(busyboxPS); "
        case .gnu: list = "echo @@ps; \(gnuPS); "
        case .busybox: list = "echo @@ps; \(busyboxPS); "
        case .none: list = ""
        }
        return "LC_ALL=C; export LC_ALL; s=$(uname -sr); echo \"$s\"; case $s in Linux*) echo @@sh; echo $$; "
            + "echo @@stat; head -n 1 /proc/stat; echo @@loadavg; cat /proc/loadavg; echo @@uptime; cat /proc/uptime; "
            + "echo @@meminfo; cat /proc/meminfo; echo @@os; cat /etc/os-release; " + list
            + (ports ? portsScript(connectionsOf: port) : "") + "echo @@df; df -kP;; esac 2>/dev/null; true"
    }

    /// The most connections to one port that are read (a busy server has tens of thousands).
    public static let connectionLimit = 2000

    /// Monitor ▸ Ports' part of `script`, run only while it is shown: reading every process's open files (`ls -l` of
    /// /proc/<pid>/fd, as ss -p and netstat -p do) is the costly part. "@@uid": this account's. "@@ports": from the
    /// /proc/net tables there are, "L <table> <address:port> <uid> <inode>" for each listening TCP socket and bound UDP
    /// one, and "N <table> <port> <count>" for each such TCP port with open connections (not those in TIME-WAIT, which
    /// are closed already); "none" without the tables. "@@owners": "/proc/<pid>/fd: socket:[<inode>]" for each process
    /// with one of those sockets open (an account sees its own processes, root every one). "@@users": /etc/passwd's
    /// "name:uid". "@@connections" (`connectionsOf`, a TCP port): its first `connectionLimit` connections, "<local>
    /// <remote> <state>". Addresses and ports in hex, as the kernel prints them.
    static func portsScript(connectionsOf port: MonitorPort?) -> String {
        // From each table's header line on, `t` is its name: "tcp6".
        let listening = #"FNR == 1 {t = FILENAME; sub(".*/", "", t); next} {split($2, a, ":"); k = t " " a[2]} "#
            + #"t ~ /tcp/ && $4 == "0A" || t ~ /udp/ && $4 == "07" {print "L", t, $2, $8, $10; s[k] = 1; next} "#
            + #"t ~ /udp/ || $4 == "06" || $4 == "07" {next} {c[k]++} END {for (k in c) if (k in s) print "N", k, c[k]}"#
        // The L lines first, then ls's: "/proc/<pid>/fd:" before each process's files.
        let owners = #"$1 == "L" {k["socket:[" $5 "]"] = 1; next} /^.proc/ {p = $1; next} ($NF in k) {print p, $NF}"#
        var script = "echo @@uid; id -u; echo @@ports; f=; for n in tcp tcp6 udp udp6; do [ -r /proc/net/$n ] && "
            + "f=\"$f /proc/net/$n\"; done; [ -n \"$f\" ] || echo none; l=; [ -n \"$f\" ] && l=$(awk '\(listening)' $f); "
            + "echo \"$l\"; echo @@owners; [ -n \"$l\" ] && { echo \"$l\"; ls -l /proc/[0-9]*/fd 2>/dev/null; } "
            + "| awk '\(owners)'; echo @@users; cut -d: -f1,3 /etc/passwd; "
        if let port, port.isTCP {
            script += "echo @@connections; awk -v p=\(String(format: "%04X", port.port)) "
                + #"'FNR == 1 || $4 == "0A" || $4 == "06" || $4 == "07" {next} {split($2, a, ":"); "#
                + "if (a[2] == p && n++ < \(connectionLimit)) print $2, $3, $4}' /proc/net/\(port.table); "
        }
        return script
    }

    private static let sections: Set<String> = ["sh", "stat", "loadavg", "uptime", "meminfo", "os", "ps", "uid", "ports",
                                                "owners", "users", "connections", "df"]

    static func parse(_ output: String) -> Reading {
        // Bytes, not Characters: ps's columns are byte positions, and it is the bulk of the output.
        let bytes = Array(output.utf8)
        // The lines, and the line each section starts at (only the first "@@<name>" counts).
        var lines: [Range<Int>] = []
        var starts: [(name: String, line: Int)] = [("uname", 0)]
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            var start = 0
            while start < buffer.count {
                let end = memchr(base + start, Int32(newline), buffer.count - start)
                    .map { base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) } ?? buffer.count
                let line = start..<end
                start = end + 1
                if line.count > 2 && base[line.lowerBound] == at && base[line.lowerBound + 1] == at {
                    let name = String(decoding: buffer[(line.lowerBound + 2)..<end], as: UTF8.self)
                    if sections.contains(name) && !starts.contains(where: { $0.name == name }) {
                        starts.append((name, lines.count))
                        continue
                    }
                }
                lines.append(line)
            }
        }
        func section(_ name: String) -> ArraySlice<Range<Int>>? {
            guard let index = starts.firstIndex(where: { $0.name == name }) else { return nil }
            return lines[starts[index].line..<(index + 1 < starts.count ? starts[index + 1].line : lines.count)]
        }
        func text(_ name: String) -> [String] {
            (section(name) ?? []).map { String(decoding: bytes[$0], as: UTF8.self) }
        }

        var reading = Reading()
        reading.uname = text("uname").first { !$0.isEmpty } ?? ""
        reading.linux = reading.uname.hasPrefix("Linux")
        guard reading.linux else { return reading }

        let cpu = text("stat").first.map(words) ?? []
        if cpu.first == "cpu" {
            // user nice system idle iowait irq softirq steal (guest and guest_nice are already in user and nice)
            let ticks = cpu.dropFirst().prefix(8).map { UInt64($0) ?? 0 }
            reading.cpu = CPUTimes(total: ticks.reduce(0, &+), idle: ticks.dropFirst(3).prefix(2).reduce(0, &+))
        }
        var snapshot = MonitorSnapshot()
        snapshot.load = text("loadavg").first.map { words($0).prefix(3).compactMap(number) } ?? []
        snapshot.uptime = text("uptime").first.flatMap { words($0).first }.flatMap(number) ?? 0

        var memory: [String: Int64] = [:]
        for line in text("meminfo") {
            let parts = words(line)
            if parts.count >= 2, parts[0].hasSuffix(":"), let value = byteSize(kilobytes: parts[1]) {
                memory[String(parts[0].dropLast())] = value
            }
        }
        snapshot.memoryTotal = memory["MemTotal"] ?? 0
        // MemAvailable is missing before Linux 3.14.
        let available = memory["MemAvailable"]
            ?? (memory["MemFree"] ?? 0) + (memory["Buffers"] ?? 0) + (memory["Cached"] ?? 0)
        snapshot.memoryUsed = max(0, snapshot.memoryTotal - available)
        snapshot.swapTotal = memory["SwapTotal"] ?? 0
        snapshot.swapUsed = max(0, snapshot.swapTotal - (memory["SwapFree"] ?? 0))

        snapshot.system = text("os").lazy.compactMap(prettyName).first ?? reading.uname
        // A device or share mounted at several places (bind mounts) once; never one called tmpfs, overlay or none: distinct
        // file systems share such names, and empty ones of one size have the same figures too.
        for disk in text("df").compactMap(disk) where !(disk.filesystem.contains("/") && snapshot.disks.contains(where: {
            ($0.filesystem, $0.size, $0.used, $0.available) == (disk.filesystem, disk.size, disk.used, disk.available)
        })) {
            snapshot.disks.append(disk)
        }
        if let ps = section("ps") {
            (snapshot.processes, reading.ps, snapshot.processNote)
                = processes(bytes, ps, memoryTotal: snapshot.memoryTotal, probe: text("sh").first.flatMap { Int($0) })
        } else {
            (reading.ps, snapshot.processNote) = (.none, noPS)
        }
        if section("ports") != nil { snapshot.ports = ports(text, processes: snapshot.processes) }
        reading.snapshot = snapshot
        return reading
    }

    static let noPortTables = "This server has no /proc/net tables, so AirSCP can't list what it listens on."
    private static let tables: Set<Substring> = ["tcp", "tcp6", "udp", "udp6"]

    /// `portsScript`'s sections: the listening sockets with their processes (`processes`: ps's of the same refresh),
    /// users and connection counts, and the connections read.
    static func ports(_ text: (String) -> [String], processes: [MonitorProcess]) -> MonitorPorts {
        var ports = MonitorPorts()
        let lines = text("ports")
        if lines.contains("none") { ports.note = noPortTables }
        var users: [Int: String] = [:]
        for line in text("users") {
            let parts = line.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count == 2, let uid = Int(parts[1]), users[uid] == nil { users[uid] = String(parts[0]) }
        }
        // "/proc/123/fd: socket:[4567]"
        var owners: [Substring: [Int]] = [:]
        for line in text("owners") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, parts[0].hasPrefix("/proc/"), parts[1].hasPrefix("socket:["), parts[1].hasSuffix("]"),
                  let pid = Int(parts[0].dropFirst(6).prefix { $0 != "/" }) else { continue }
            owners[parts[1].dropFirst(8).dropLast(), default: []].append(pid)
        }
        var counts: [String: Int] = [:]
        var rows: [MonitorPort] = [], uids: [MonitorPort.ID: Int] = [:]
        for line in lines {
            let parts = line.split(separator: " ")
            if parts.count == 4, parts[0] == "N", let port = Int(parts[2], radix: 16), let count = Int(parts[3]) {
                counts["\(parts[1]) \(port)"] = count
            }
            guard parts.count == 5, parts[0] == "L", tables.contains(parts[1]), let (address, port) = endpoint(parts[2]),
                  let uid = Int(parts[3]) else { continue }
            let pids = owners[parts[4]] ?? []
            var row = MonitorPort(table: String(parts[1]), address: address, port: port, user: users[uid] ?? String(uid))
            if let index = rows.firstIndex(where: { $0.id == row.id }) {
                rows[index].pids += pids
            } else {
                row.pids = pids
                rows.append(row)
                uids[row.id] = uid
            }
        }
        let names = Dictionary(processes.map { ($0.pid, $0) }) { first, _ in first }
        for index in rows.indices {
            rows[index].pids = Array(Set(rows[index].pids)).sorted()
            if let process = rows[index].pids.lazy.compactMap({ names[$0] }).first {
                (rows[index].process, rows[index].command) = (process.name, process.command)
            }
            if rows[index].isTCP { rows[index].connections = counts["\(rows[index].table) \(rows[index].port)"] ?? 0 }
        }
        ports.listening = rows.sorted { ($0.port, $0.table, $0.address) < ($1.port, $1.table, $1.address) }
        let me = text("uid").first.flatMap { Int($0) }
        ports.othersHidden = me != 0 && rows.contains { $0.pids.isEmpty && uids[$0.id] != me }
        for line in text("connections") {
            let parts = line.split(separator: " ")
            guard parts.count == 3, let (address, port) = endpoint(parts[1]) else { continue }
            ports.connections.append(MonitorConnection(id: "\(parts[0]) \(parts[1])", address: address, port: port,
                                                       state: state(parts[2])))
        }
        return ports
    }

    /// /proc/net's "0100007F:1F90" → ("127.0.0.1", 8080). The address is the kernel's 32-bit words as hex numbers, so
    /// each word's bytes come in the CPU's order: little-endian on the x86 and ARM servers of today. An IPv4 address in
    /// an IPv6 table (::ffff:10.0.0.5: IPv4 on a socket that takes both) shows as IPv4.
    static func endpoint(_ text: Substring) -> (address: String, port: Int)? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, [8, 32].contains(parts[0].count), parts[1].count == 4,
              (parts[0] + parts[1]).allSatisfy(\.isHexDigit), let port = Int(parts[1], radix: 16) else { return nil }
        var bytes: [UInt8] = []
        var start = parts[0].startIndex
        while start < parts[0].endIndex {
            let end = parts[0].index(start, offsetBy: 8)
            guard let word = UInt32(parts[0][start..<end], radix: 16) else { return nil }
            bytes += [UInt8(word & 0xff), UInt8(word >> 8 & 0xff), UInt8(word >> 16 & 0xff), UInt8(word >> 24)]
            start = end
        }
        if bytes.count == 16 && bytes.prefix(10).allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            bytes.removeFirst(12)
        }
        var name = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        guard inet_ntop(bytes.count == 4 ? AF_INET : AF_INET6, bytes, &name, socklen_t(name.count)) != nil else { return nil }
        return (String(cString: name), port)
    }

    /// A TCP state as /proc/net numbers it, in words.
    static func state(_ code: Substring) -> String {
        ["01": "Established", "02": "SYN sent", "03": "SYN received", "04": "FIN wait 1", "05": "FIN wait 2",
         "08": "Close wait", "09": "Last ACK", "0B": "Closing", "0C": "SYN received"][String(code)] ?? String(code)
    }

    private static let newline = UInt8(ascii: "\n"), space = UInt8(ascii: " "), at = UInt8(ascii: "@")

    private static func words(_ line: String) -> [Substring] {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" })
    }

    /// A finite, non-negative number (whatever a server prints, nothing later can trap on it).
    private static func number(_ text: Substring) -> Double? {
        Double(text).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    /// KiB as bytes: ps's, df's and meminfo's whole numbers, or BusyBox ps's four characters scaled by 1024 ("9999",
    /// "12m", "1.5g"). nil for anything else and for more than an exbibyte, so that adding a few can't overflow.
    static func byteSize(kilobytes text: Substring) -> Int64? {
        var digits = text
        var scale = 1.0
        if let unit = text.last, let power = ["m", "g", "t"].firstIndex(of: unit) {
            digits = text.dropLast()
            scale = pow(1024, Double(power + 1))
        }
        guard digits.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }), let value = number(digits),
              value * scale <= 0x1p50 else { return nil }
        return Int64(value * scale * 1024)
    }

    /// PRETTY_NAME="Debian GNU/Linux 13 (trixie)", quoted or not.
    static func prettyName(_ line: String) -> String? {
        guard line.hasPrefix("PRETTY_NAME=") else { return nil }
        var value = line.dropFirst("PRETTY_NAME=".count)
        if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
            value = value.dropFirst().dropLast()
        }
        return value.isEmpty ? nil : String(value)
    }

    // Filesystem, 1024-blocks, Used, Available, Capacity ("37%", or "-" when there are no blocks), Mounted on.
    private static let diskLine = try! NSRegularExpression(
        pattern: #"^(.+?)\s+(\d+)\s+(\d+)\s+(\d+)\s+(?:\d+%|-)\s+(.+)$"#)
    private static let hiddenMounts = ["/dev", "/proc", "/run", "/sys", "/snap"]

    static func disk(_ line: String) -> MonitorDisk? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = diskLine.firstMatch(in: line, range: range) else { return nil }
        func group(_ index: Int) -> Substring { Range(match.range(at: index), in: line).map { line[$0] } ?? "" }
        let mountPoint = String(group(5))
        guard let size = byteSize(kilobytes: group(2)), size > 0,
              !hiddenMounts.contains(where: { mountPoint == $0 || mountPoint.hasPrefix($0 + "/") }) else { return nil }
        return MonitorDisk(filesystem: String(group(1)), mountPoint: mountPoint, size: size,
                           used: byteSize(kilobytes: group(3)) ?? 0, available: byteSize(kilobytes: group(4)) ?? 0)
    }

    /// ps's output: a header naming the columns ("PID PPID USER %CPU %MEM RSS ELAPSED STAT COMMAND COMMAND" from GNU
    /// ps, BusyBox's without %CPU and %MEM), then a row per process. Each column is one word except the last two, comm
    /// and args, which may hold spaces: args starts where its header does, as both ps's pad the columns before it (GNU
    /// ps takes an overlong value out of the padding that follows; when that wasn't enough, comm is the first word).
    /// `probe`: the pid of the shell that ran ps, left out with its children (ps itself).
    static func processes(_ bytes: [UInt8], _ lines: ArraySlice<Range<Int>>, memoryTotal: Int64, probe: Int?)
        -> (processes: [MonitorProcess], ps: PSKind, note: String?) {
        func string(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
        func words(in line: Range<Int>, limit: Int = .max) -> (words: [Range<Int>], rest: Int) {
            var words: [Range<Int>] = []
            var index = line.lowerBound
            while words.count < limit {
                while index < line.upperBound && bytes[index] == space { index += 1 }
                let start = index
                while index < line.upperBound && bytes[index] != space { index += 1 }
                if start == index { break }
                words.append(start..<index)
            }
            while index < line.upperBound && bytes[index] == space { index += 1 }
            return (words, index)
        }

        guard let headerIndex = lines.firstIndex(where: { words(in: $0, limit: 1).words.first.map(string) == "PID" }) else {
            let output = lines.map(string).filter { !$0.isEmpty }
            if output.contains(where: { $0.contains("not found") }) { return ([], .none, noPS) }
            return ([], .unknown, "AirSCP couldn't list the processes" + (output.first.map { ": \($0)" } ?? "."))
        }
        let header = lines[headerIndex]
        let columns = words(in: header).words
        let names = columns.map(string)
        guard names.count > 2, names[names.count - 2] == "COMMAND", names[names.count - 1] == "COMMAND",
              let pidColumn = names.firstIndex(of: "PID") else {
            return ([], .unknown, "AirSCP couldn't read ps's columns: \(string(header))")
        }
        let fixed = names.count - 2
        let argsOffset = columns[names.count - 1].lowerBound - header.lowerBound
        func column(_ name: String) -> Int? { names.firstIndex(of: name) }
        let (ppidColumn, userColumn, stateColumn) = (column("PPID"), column("USER"), column("STAT"))
        let (cpuColumn, memoryColumn, rssColumn, elapsedColumn) = (column("%CPU"), column("%MEM"), column("RSS"),
                                                                   column("ELAPSED"))

        var processes: [MonitorProcess] = []
        processes.reserveCapacity(lines.endIndex - headerIndex)
        for line in lines[(headerIndex + 1)...] {
            let (fields, commStart) = words(in: line, limit: fixed)
            guard fields.count == fixed, let pid = Int(string(fields[pidColumn])) else { continue }
            func field(_ column: Int?) -> Substring? { column.map { Substring(string(fields[$0])) } }
            var commEnd = line.lowerBound + argsOffset
            if !(commEnd > commStart && commEnd < line.upperBound && bytes[commEnd - 1] == space) {
                commEnd = commStart
                while commEnd < line.upperBound && bytes[commEnd] != space { commEnd += 1 }
            }
            var argsStart = commEnd
            while argsStart < line.upperBound && bytes[argsStart] == space { argsStart += 1 }
            while commEnd > commStart && bytes[commEnd - 1] == space { commEnd -= 1 }
            let rss = field(rssColumn).flatMap { byteSize(kilobytes: $0) } ?? 0
            var memory = field(memoryColumn).flatMap(number)
            if memoryColumn == nil && memoryTotal > 0 { memory = Double(rss) / Double(memoryTotal) * 100 }
            processes.append(MonitorProcess(
                pid: pid, ppid: field(ppidColumn).flatMap { Int($0) } ?? 0,
                user: field(userColumn).map(String.init) ?? "", cpu: field(cpuColumn).flatMap(number),
                memory: memory, rss: rss, elapsed: field(elapsedColumn).flatMap(seconds),
                state: field(stateColumn).map(String.init) ?? "", name: string(commStart..<commEnd),
                command: string(argsStart..<line.upperBound)))
        }
        // Not AirSCP's own probe (this very refresh: its sh and what that runs, ps included). Its command line is only
        // "sh -s" (the script comes on standard input), so the shell is known by its pid.
        if let probe { processes.removeAll { $0.pid == probe || $0.ppid == probe } }
        return (processes, cpuColumn == nil ? .busybox : .gnu, nil)
    }

    /// ps etime: GNU "[[days-]hours:]minutes:seconds", e.g. "05:09", "1:02:03", "12-01:02:03"; BusyBox "5:09",
    /// "16h05" (hours, minutes), "1d16" (days, hours) or "123d".
    static func seconds(_ text: Substring) -> TimeInterval? {
        // At most 9 digits each, so that the sums can't overflow.
        func whole(_ part: Substring) -> Int? {
            part.count <= 9 && part.allSatisfy({ $0.isASCII && $0.isNumber }) ? Int(part) : nil
        }
        for (unit, first, second) in [("h", 3600, 60), ("d", 86400, 3600)] {
            let parts = text.split(separator: Character(unit), omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            guard let big = whole(parts[0]), let small = parts[1].isEmpty ? 0 : whole(parts[1]) else { return nil }
            return TimeInterval(big * first + small * second)
        }
        let dash = text.split(separator: "-", omittingEmptySubsequences: false)
        let parts = (dash.last ?? "").split(separator: ":", omittingEmptySubsequences: false).map(whole)
        guard dash.count <= 2, let days = dash.count == 2 ? whole(dash[0]) : 0, (2...3).contains(parts.count),
              !parts.contains(nil) else { return nil }
        return TimeInterval(days * 86400 + parts.reduce(0) { $0 * 60 + $1! })
    }
}
