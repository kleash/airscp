import Foundation

/// Disk Usage: what takes the room below a folder, on a server or on this Mac. A scan sends what it finds as it goes
/// (`Record`s), and the tree grows with it: sizes show while it runs, and going into a folder, the largest files and
/// taking deleted items off then need no other command. Not thread-safe: add to it on one thread (the main one).
public final class DiskUsage {
    /// One item found: its path below the scanned folder ("a/b.txt") and, for a file, its size.
    public struct Record: Equatable {
        public let path: String
        public let size: Int64
        /// false from du, which doesn't say: a record of a folder that has items is then its total, passed over.
        public let folder: Bool
    }

    /// A file or folder found. A folder's size is the sum of its files' sizes (apparent sizes, as the panes show them).
    public final class Item: Identifiable {
        public let name: String
        public private(set) var size: Int64 = 0
        public private(set) var isFolder: Bool
        /// The files at every level below (1 for a file).
        public private(set) var files = 0
        public private(set) weak var parent: Item?
        fileprivate var byName: [String: Item] = [:]
        /// The scanned folder's path; nil below it.
        fileprivate var top: String?

        init(name: String, isFolder: Bool, parent: Item?) {
            self.name = name
            self.isFolder = isFolder
            self.parent = parent
        }

        public var path: String { top ?? RemotePath.join(parent?.path ?? "", name) }

        /// Largest first (then by name).
        public var children: [Item] {
            byName.values.sorted { $0.size != $1.size ? $0.size > $1.size : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        fileprivate func child(_ name: String, folder: Bool) -> Item {
            if let item = byName[name] { return item }
            let item = Item(name: name, isFolder: folder, parent: self)
            byName[name] = item
            return item
        }

        /// Adds to this folder and every folder above it.
        fileprivate func grow(_ size: Int64, files: Int) {
            var item: Item? = self
            while let folder = item {
                folder.size += size
                folder.files += files
                item = folder.parent
            }
        }

        /// The files at any depth below, largest first; at most `count`.
        public func largestFiles(_ count: Int) -> [Item] {
            var found: [Item] = [], smallest = Int64.min
            var folders = [self]
            while let folder = folders.popLast() {
                for child in folder.byName.values {
                    if child.isFolder {
                        folders.append(child)
                    } else if child.size > smallest || found.count < count {
                        found.append(child)
                        // Kept short as it goes: a big tree has hundreds of thousands of files.
                        if found.count >= 2 * count {
                            found = Array(found.sorted { $0.size > $1.size }.prefix(count))
                            smallest = found[found.count - 1].size
                        }
                    }
                }
            }
            return Array(found.sorted { $0.size > $1.size }.prefix(count))
        }

        /// An emptied file: 0 bytes, its old size out of every folder above; it stays listed.
        public func empty() {
            guard !isFolder else { return }
            grow(-size, files: 0)
        }

        /// Takes a deleted item off: out of its folder, and its size and files out of every folder above.
        public func remove() {
            guard let parent else { return }
            parent.byName[name] = nil
            parent.grow(-size, files: -files)
            self.parent = nil
        }
    }

    public let root: Item
    /// The scanned folder's own items: how many there are (0 until the scan says) and how many have been reached.
    public var expected = 0
    public private(set) var reached = 0
    /// The path of the item added last: where the scan is.
    public private(set) var latest = ""

    public init(path: String) {
        root = Item(name: RemotePath.name(path), isFolder: true, parent: nil)
        root.top = path
    }

    public func add(_ records: [Record]) {
        for record in records {
            let parts = record.path.split(separator: "/").map(String.init)
            guard let last = parts.last else { continue }
            var folder = root
            for part in parts.dropLast() { folder = folder.child(part, folder: true) }
            if parts.count == 1 { reached += 1 }
            latest = record.path
            if folder.byName[last] != nil { continue }  // du's total of a folder whose items came first
            // shortcut: from du an empty folder reads as a file of its own size; find -type d would tell them apart.
            let item = folder.child(last, folder: record.folder)
            if !record.folder { item.grow(record.size, files: 1) }
        }
    }

    /// du's output from `Session.duAll`, records ending in `separator`: the size (in `unit`s), a tab and "./path".
    static func parse(_ output: Data, unit: Int64, separator: UInt8) -> [Record] {
        output.split(separator: separator).compactMap { bytes in
            let line = String(decoding: bytes, as: UTF8.self)
            guard let tab = line.firstIndex(of: "\t"), let amount = Int64(line[..<tab]) else { return nil }
            let path = line[line.index(after: tab)...]
            guard path.hasPrefix("./") else { return nil }
            return Record(path: String(path.dropFirst(2)), size: amount * unit, folder: false)
        }
    }

    /// Scans this Mac's folder at `path`: every item below it on its own volume (other disks mounted inside are left
    /// out), packages included. `found` gets the records in batches, with how many items the folder itself holds.
    /// Cancelling the calling task stops it. Folders that can't be read are passed over and returned (paths relative to
    /// `path`, as records have them).
    @discardableResult public static func scan(_ path: String, found: ([Record], Int) -> Void) throws -> Skipped {
        let manager = FileManager.default
        let expected = (try? manager.contentsOfDirectory(atPath: path).count) ?? 0
        guard let walk = manager.enumerator(atPath: path) else { return Skipped() }
        let volume = (try? manager.attributesOfItem(atPath: path))?[.systemNumber] as? Int
        var batch: [Record] = [], sent = Date(), skipped = Skipped()
        while let relative = walk.nextObject() as? String {
            let attributes = walk.fileAttributes ?? [:]
            let folder = attributes[.type] as? FileAttributeType == .typeDirectory
            if folder, let volume, attributes[.systemNumber] as? Int != volume {
                walk.skipDescendants()
                continue
            }
            // The enumerator passes over a folder it can't open without a word: opendir tells (privacy-protected folders
            // too, which access() calls readable).
            if folder {
                if let handle = opendir(path + "/" + relative) { closedir(handle) } else { skipped.add(relative) }
            }
            batch.append(Record(path: relative, size: folder ? 0 : (attributes[.size] as? NSNumber)?.int64Value ?? 0, folder: folder))
            if batch.count == 5_000 || sent.timeIntervalSinceNow < -0.2 {
                try Task.checkCancellation()
                found(batch, expected)
                batch = []
                sent = Date()
            }
        }
        found(batch, expected)
        return skipped
    }

    /// What a scan passed over: folders it couldn't read (permission), how many, and the first few paths (≤ 20),
    /// relative to the scanned folder as `Record.path` is ("" for the folder itself).
    public struct Skipped: Equatable {
        public var count = 0
        public var paths: [String] = []
        public init(count: Int = 0, paths: [String] = []) { self.count = count; self.paths = paths }

        mutating func add(_ path: String) {
            count += 1
            if paths.count < 20 { paths.append(path) }
        }
    }

    /// A disk's (file system's / volume's / drive's) size and free bytes; used = total - free.
    public struct Space: Equatable {
        public let total: Int64
        public let free: Int64
        public init(total: Int64, free: Int64) { self.total = total; self.free = free }
    }

    /// A file deleted while a process still holds it open: its room is freed only when the process closes it.
    public struct OpenDeleted: Equatable {
        public let pid: Int
        public let process: String
        public let user: String
        public let path: String
        public let size: Int64
        public init(pid: Int, process: String, user: String, path: String, size: Int64) {
            self.pid = pid; self.process = process; self.user = user; self.path = path; self.size = size
        }
    }

    /// This Mac's volume holding `path` (free: what Finder calls available, purgeable space included).
    public static func localSpace(of path: String) -> Space? {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                                              .volumeAvailableCapacityForImportantUsageKey])
        guard let total = values?.volumeTotalCapacity, let free = values?.volumeAvailableCapacityForImportantUsage else { return nil }
        return Space(total: Int64(total), free: free)
    }

    /// This Mac: files deleted but open (lsof +L1), those whose path was below `path` ("/" for all). This user's
    /// processes only (lsof sees no others').
    public static func localOpenDeleted(below path: String) async throws -> [OpenDeleted] {
        let result = await Runner.run(["/usr/sbin/lsof", "-nP", "+L1", "-FpcLsn"])
        if result.status == 127 { throw AirSCPError(.missingTool, "lsof isn't on this Mac.", details: result.stderr) }
        // lsof names files by their real path (/private/tmp/…); it exits 1 when it finds nothing.
        let real = realpath(path, nil).map { pointer in defer { free(pointer) }; return String(cString: pointer) } ?? path
        return openDeleted(fromLsof: String(decoding: result.stdout, as: UTF8.self), below: real)
    }

    /// This Mac: truncates the file to 0 bytes (a link: the file it points to).
    public static func emptyLocalFile(_ path: String) throws {
        guard truncate(path, 0) == 0 else {
            let reason = String(cString: strerror(errno))
            throw AirSCPError(errno == EACCES || errno == EPERM ? .permissionDenied : .other,
                              "Can't empty “\(RemotePath.name(path))”: \(reason).")
        }
    }

    // MARK: Parsing what servers print

    /// The path in one of du's complaints, relative to the scanned folder ("." is ""): GNU's "du: cannot read directory
    /// './a': Permission denied", BusyBox's "du: can't open './a': …", BSD's "du: ./a: Permission denied".
    static func skippedPath(_ line: String) -> String? {
        guard line.hasPrefix("du: ") else { return nil }
        var text = Substring(line.dropFirst(4))
        for lead in ["cannot read directory ", "cannot access ", "cannot open directory ", "can't open ", "cannot open "]
        where text.hasPrefix(lead) {
            text = text.dropFirst(lead.count)
            break
        }
        guard let colon = text.range(of: ": ", options: .backwards) else { return nil }
        text = text[..<colon.lowerBound]
        if let first = text.first, let last = text.last, text.count >= 2, "'‘\"".contains(first), "'’\"".contains(last) {
            text = text.dropFirst().dropLast()
        }
        if text == "." { return "" }
        guard text.hasPrefix("./") else { return nil }
        return String(text.dropFirst(2))
    }

    /// What `Session.diskUsage`'s awk left on the error output: du's first complaints, then "__AIRSCP_SKIPPED__<count>".
    static func skipped(fromDu stderr: String) -> Skipped {
        var skipped = Skipped()
        for line in stderr.split(separator: "\n") {
            if line.hasPrefix("__AIRSCP_SKIPPED__") {
                skipped.count = Int(line.dropFirst(18)) ?? skipped.count
            } else if let path = skippedPath(String(line)), skipped.paths.count < 20 {
                skipped.paths.append(path)
            }
        }
        skipped.count = max(skipped.count, skipped.paths.count)
        return skipped
    }

    /// The disk in `df -Pk`'s last line: "Filesystem 1024-blocks Used Available Capacity Mounted-on" (the name and the
    /// mount point may hold spaces: found by the Capacity column, the one ending in %).
    static func space(fromDf output: String) -> Space? {
        guard let line = output.split(separator: "\n").last(where: { $0.contains("%") }) else { return nil }
        let words = line.split(separator: " ")
        guard let capacity = words.firstIndex(where: { $0.hasSuffix("%") }), capacity >= 3,
              let total = Int64(words[capacity - 3]), let free = Int64(words[capacity - 1]) else { return nil }
        return Space(total: total * 1024, free: free * 1024)
    }

    /// The disk in sftp's `df`: a header with Size … Avail, then the figures in KiB.
    static func space(fromSFTPDf output: String) -> Space? {
        let lines = output.split(separator: "\n").map { $0.split(separator: " ") }
        guard let header = lines.firstIndex(where: { $0.first == "Size" && $0.contains("Avail") }), header + 1 < lines.count,
              let avail = lines[header].firstIndex(of: "Avail"), lines[header + 1].count > avail,
              let total = Int64(lines[header + 1][0]), let free = Int64(lines[header + 1][avail]) else { return nil }
        return Space(total: total * 1024, free: free * 1024)
    }

    /// Lines "pid TAB process TAB user TAB size TAB path (deleted)" from `Session.openDeletedScript` on Linux.
    static func openDeleted(fromProc output: String, below dir: String) -> [OpenDeleted] {
        unique(output.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\t", maxSplits: 4, omittingEmptySubsequences: false)
            guard fields.count == 5, let pid = Int(fields[0]), let size = Int64(fields[3]) else { return nil }
            return OpenDeleted(pid: pid, process: String(fields[1]), user: String(fields[2]),
                               path: deletedName(fields[4]), size: size)
        }, below: dir)
    }

    /// lsof -F's lines (p pid, c command, L login, u uid, f fd, s size, n name): one file at each n.
    static func openDeleted(fromLsof output: String, below dir: String) -> [OpenDeleted] {
        var found: [OpenDeleted] = [], pid = 0, process = "", user = "", size: Int64 = 0
        for line in output.split(separator: "\n") {
            let value = String(line.dropFirst())
            switch line.first {
            case "p": pid = Int(value) ?? 0; process = ""; user = ""
            case "c": process = value
            case "L": user = value
            case "u": if user.isEmpty { user = value }
            case "f": size = 0
            case "s": size = Int64(value) ?? 0
            case "n": found.append(OpenDeleted(pid: pid, process: process, user: user, path: deletedName(Substring(value)), size: size))
            default: break
            }
        }
        return unique(found, below: dir)
    }

    private static func deletedName(_ name: Substring) -> String {
        String(name.hasSuffix(" (deleted)") ? name.dropLast(10) : name)
    }

    /// Files below `dir`, each once per process (several descriptors may hold one file); not memory-only ones (memfd,
    /// System V shared memory), which take no disk room.
    private static func unique(_ files: [OpenDeleted], below dir: String) -> [OpenDeleted] {
        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
        var seen = Set<String>()
        return files.filter { file in
            file.path.hasPrefix("/") && !file.path.hasPrefix("/memfd:") && !file.path.hasPrefix("/SYSV")
                && (file.path == dir || file.path.hasPrefix(prefix)) && seen.insert("\(file.pid) \(file.path)").inserted
        }
    }

    /// A Windows scan's lines (`Session.windowsScan`): "count=N", "D TAB 0 TAB a/b" for a folder, "F TAB size TAB a/b"
    /// for a file, "S TAB a/b" for a folder it couldn't read, "skipped=N" at the end.
    static func parseWindows(_ text: Substring, expected: inout Int, skipped: inout Skipped) -> [Record] {
        text.split(whereSeparator: \.isNewline).compactMap { line in  // "\r\n" is one Character
            if line.hasPrefix("count=") { expected = Int(line.dropFirst(6)) ?? 0 }
            if line.hasPrefix("skipped=") { skipped.count = Int(line.dropFirst(8)) ?? 0 }
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            if fields.count == 2, fields[0] == "S" { skipped.paths.append(String(fields[1])) }
            guard fields.count == 3, fields[0] == "D" || fields[0] == "F", let size = Int64(fields[1]) else { return nil }
            return Record(path: String(fields[2]), size: size, folder: fields[0] == "D")
        }
    }
}

extension Session {
    /// One scan of `dir` on any server kind: du on POSIX shells, PowerShell on Windows, the listings over sftp on servers
    /// without a shell, the listings on S3. `found` gets the records as they come (on a background thread), with how
    /// many items the folder itself holds. Returns what it passed over (paths relative to `dir`). `asRoot`: POSIX only,
    /// through sudo; `password` for sudo when `sudo -n` isn't enough (sent on standard input, never in argv, logs or the
    /// command log, never kept). Cancelling the calling task stops it.
    @discardableResult
    public func diskUsage(of dir: String, asRoot: Bool = false, password: String? = nil,
                          found: @escaping ([DiskUsage.Record], Int) -> Void) async throws -> DiskUsage.Skipped {
        if s3 != nil { return try await diskUsageS3(dir, found: found) }
        guard capabilities.shell else {
            if asRoot { throw AirSCPError(.other, Self.rootNeedsShell) }
            if capabilities.windows && !capabilities.loginShell.isEmpty { return try await windowsScan(dir, found: found) }
            return try await diskUsageOverSFTP(dir, found: found)
        }
        return try await duScan(dir, asRoot: asRoot, password: password, found: found)
    }

    static let rootNeedsShell = "Scanning as root needs a server with a POSIX shell and sudo."

    /// `du -a` on the folder's file system (other disks mounted inside are left out), NUL-separated where du is GNU's
    /// (so any name comes through), else one per line. du's complaints go to awk, which keeps the first 20 and counts.
    // shortcut: the output is also kept whole while du runs (~100 bytes an item); fine below millions of files.
    private func duScan(_ dir: String, asRoot: Bool, password: String?,
                        found: @escaping ([DiskUsage.Record], Int) -> Void) async throws -> DiskUsage.Skipped {
        // The folder's own items counted by the shell's glob: one per name, whatever is in it.
        let count = "n=0; for f in * .[!.]* ..?*; do if [ -e \"$f\" ] || [ -L \"$f\" ]; then n=$((n+1)); fi; done; echo \"count=$n\";"
        let script = "cd \(Quote.shell(dir)) && { \(Session.duAll) \(count) echo \"unit=$unit\"; { $du . 2>&1 >&3 3>&- | "
            + "awk 'NR<=20 {print} END {print \"__AIRSCP_SKIPPED__\" NR}' >&2; } 3>&1; true; }"
        var pending = Data(), started = false, expected = 0, unit: Int64 = 0
        let output: (Data) -> Void = { chunk in
            pending.append(chunk)
            if !started, let marker = pending.range(of: Data("\n__AIRSCP__\n".utf8)) {
                pending = pending.subdata(in: marker.upperBound..<pending.endIndex)
                started = true
            }
            // The two lines before du's: count= and unit=.
            while started && unit == 0, let newline = pending.firstIndex(of: 0x0A) {
                let line = String(decoding: pending[..<newline], as: UTF8.self)
                let value = line.drop { $0 != "=" }.dropFirst().trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("count=") { expected = Int(value) ?? 0 } else { unit = Int64(value) ?? 1024 }
                pending = pending.subdata(in: (newline + 1)..<pending.endIndex)
            }
            // GNU's du (unit 1) ends each record with a NUL, the others with a line feed.
            let separator: UInt8 = unit == 1 ? 0 : 0x0A
            guard unit > 0, let end = pending.lastIndex(of: separator) else { return }
            found(DiskUsage.parse(pending[..<end], unit: unit, separator: separator), expected)
            pending = pending.subdata(in: (end + 1)..<pending.endIndex)
        }
        let (_, status, stderr) = try await cancellable { cancellation in
            asRoot ? try await rootShell(script, password: password, cancellation: cancellation, output: output)
                : try await sentinelShell(script, cancellation: cancellation, output: output)
        }
        guard status == 0 else { throw ErrorMapping.map(stderr, status: status) }
        return DiskUsage.skipped(fromDu: stderr)
    }

    /// Sets $du to `du -a -x` for every file and folder of one file system, sizes as `du` (above) takes them.
    static let duAll = "if du --version 2>/dev/null | grep -q GNU; then du='du -a -x -0 --apparent-size --block-size=1'; unit=1; "
        + "else case $(uname -s) in Darwin|*BSD) du='env LC_CTYPE=UTF-8 du -a -x -A -k';; *) du='du -a -x -k';; esac; unit=1024; fi;"

    /// A sentinel-wrapped `script` as root: `sudo -n`, or with `password` `sudo -S`, which reads it as the first line of
    /// standard input. The script comes on the command line (`viaSh`), so a sudo that doesn't ask leaves the line unread
    /// rather than running it; the input is kept out of the logs (`secretInput`).
    // shortcut: Swift can't wipe a String; the password's copies live until they are freed.
    func rootShell(_ script: String, password: String?, cancellation: Cancellation? = nil,
                   output: ((Data) -> Void)? = nil) async throws -> (Data, Int32, String) {
        try requireShell()
        let command = OpenSSH.viaSh(OpenSSH.sentinelScript(script), sudo: password == nil ? "sudo -n " : "sudo -S -p '' ")
        let result = try await remote(command, input: password.map { $0 + "\n" }, secretInput: true, cancellation: cancellation,
                                      standardOutput: output)
        guard let (stdout, status) = OpenSSH.parseSentinel(result.stdout) else {
            throw Session.sudoError(result.stderr, status: result.status)
        }
        return (stdout, status, OpenSSH.afterMarker(result.stderr))
    }

    /// What sudo said when it didn't run the script, in plain words.
    static func sudoError(_ stderr: String, status: Int32) -> AirSCPError {
        if stderr.contains("incorrect password") || stderr.contains("Sorry, try again") {
            return AirSCPError(.permissionDenied, "sudo refused the password.", details: stderr)
        }
        if stderr.contains("password is required") {
            return AirSCPError(.permissionDenied, "sudo needs this account's password.", details: stderr)
        }
        if stderr.contains("sudoers") || stderr.contains("not allowed to") || stderr.contains("may not run sudo") {
            return AirSCPError(.permissionDenied, "This account may not use sudo on the server.", details: stderr)
        }
        if stderr.contains("sudo") && stderr.contains("not found") {
            return AirSCPError(.missingTool, "This server has no sudo.", details: stderr)
        }
        return ErrorMapping.map(stderr, status: status == 0 ? 1 : status)
    }

    /// Whether Scan as Root can work: a POSIX shell with sudo; `needsPassword` when `sudo -n true` fails (also for an
    /// account that may not use sudo at all: sudo only says so once it has the password).
    public func diskUsageSudo() async -> (available: Bool, needsPassword: Bool) {
        guard s3 == nil, capabilities.shell else { return (false, false) }
        let script = "if sudo -n true 2>/dev/null; then echo ok; elif command -v sudo >/dev/null 2>&1; then echo password; fi"
        guard let (output, _, _) = try? await sentinelShell(script, asLoginUser: true) else { return (false, false) }
        let answer = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return (answer == "ok" || answer == "password", answer == "password")
    }

    /// The disk holding `dir`: df -Pk on POSIX, the drive on Windows, sftp's statvfs (`df` in sftp) without a shell;
    /// nil where there is none (S3) or it can't tell.
    public func diskSpace(of dir: String) async throws -> DiskUsage.Space? {
        if s3 != nil { return nil }
        if capabilities.shell {
            return DiskUsage.space(fromDf: try await shell("df -Pk -- \(Quote.shell(dir)) 2>/dev/null; true"))
        }
        if capabilities.windows && !capabilities.loginShell.isEmpty, let drive = Session.windowsPath(dir).first {
            let output = try await powershell("$d=[IO.DriveInfo]::new('\(drive)');\"$($d.TotalSize) $($d.AvailableFreeSpace)\"")
            let figures = output.split(whereSeparator: \.isWhitespace).compactMap { Int64($0) }
            return figures.count == 2 ? DiskUsage.Space(total: figures[0], free: figures[1]) : nil
        }
        do {
            return DiskUsage.space(fromSFTPDf: try await sftp(["df \(Quote.sftp(dir))"]).output)
        } catch let error as AirSCPError where error.kind != .cancelled && error.kind != .disconnected {
            return nil  // a server without the statvfs@openssh.com extension
        }
    }

    /// Deleted-but-open files whose path was below `dir` (all for "/"): /proc/*/fd on Linux (only the account's own
    /// processes unless asRoot), lsof +L1 on macOS/BSD servers; throws a plain-language AirSCPError where it can't
    /// tell (Windows, sftp-only, S3, a server without /proc and lsof).
    public func openDeletedFiles(below dir: String, asRoot: Bool = false, password: String? = nil) async throws -> [DiskUsage.OpenDeleted] {
        if s3 != nil { throw AirSCPError(.sftpOnly, "S3 storage has no programs that could hold a file open.") }
        if capabilities.windows {
            throw AirSCPError(.other, "Windows doesn't let a file that a program has open be deleted, so there are none to find.")
        }
        guard capabilities.shell else {
            throw AirSCPError(.sftpOnly, "Finding deleted files that are still open needs shell commands, which this server "
                              + "doesn't run (sftp only).")
        }
        // The folder's real path first (/var/log is /private/var/log on a Mac): the open files are named by theirs.
        let script = "(cd -- \(Quote.shell(dir)) 2>/dev/null && pwd -P); " + Session.openDeletedScript
        let (output, status, stderr) = try await cancellable { cancellation in
            asRoot ? try await rootShell(script, password: password, cancellation: cancellation)
                : try await sentinelShell(script, cancellation: cancellation)
        }
        guard status == 0 else { throw ErrorMapping.map(stderr, status: status) }
        var text = String(decoding: output, as: UTF8.self)
        let real = String(text.prefix { $0 != "\n" })
        text = String(text.dropFirst(real.count + 1))
        let below = real.hasPrefix("/") ? real : dir
        if text.hasPrefix("__NONE__") {
            throw AirSCPError(.missingTool, "This server can't tell which deleted files are still open: it has neither "
                              + "/proc nor lsof.")
        }
        if text.hasPrefix("__LSOF__") { return DiskUsage.openDeleted(fromLsof: String(text.dropFirst(9)), below: below) }
        return DiskUsage.openDeleted(fromProc: text, below: below)
    }

    /// Linux: `ls -l` of every /proc/<pid>/fd it may read, its " (deleted)" links with the size (stat -L follows the
    /// link to the open file), the process name and the owner; elsewhere lsof +L1 (open files with no name left).
    static let openDeletedScript = "if [ \"$(uname -s)\" = Linux ] && [ -d /proc/self/fd ]; then "
        + "ls -l /proc/[0-9]*/fd 2>/dev/null | while IFS= read -r l; do case $l in /proc/*:) d=${l%:};; "
        + "*' (deleted)') t=${l#* -> }; n=${l%% -> *}; n=${n##* }; set -f; set -- $l; p=${d#/proc/}; p=${p%/fd}; "
        + "s=$(stat -L -c %s \"$d/$n\" 2>/dev/null) || continue; c=$(cat \"/proc/$p/comm\" 2>/dev/null); "
        + "printf '%s\\t%s\\t%s\\t%s\\t%s\\n' \"$p\" \"$c\" \"$3\" \"$s\" \"$t\";; esac; done; "
        + "elif command -v lsof >/dev/null 2>&1; then echo __LSOF__; lsof -nP +L1 -FpcLsn 2>/dev/null; else echo __NONE__; fi; true"

    /// Truncates a file to 0 bytes: `: > file` through sh, which truncates the file a link points to (and only when
    /// that is a file: `[ -f ]` first, so a link to nothing isn't made a new empty file); Clear-Content on Windows;
    /// throws with the reason elsewhere (`emptyFileProblem`).
    public func emptyFile(_ path: String) async throws {
        if let problem = emptyFileProblem { throw AirSCPError(.sftpOnly, problem) }
        if capabilities.shell {
            let p = Quote.shell(path)
            if try await shell("if [ -f \(p) ]; then : > \(p); else echo __NOT_A_FILE__; fi").contains("__NOT_A_FILE__") {
                throw AirSCPError(.other, "Only a file can be emptied: “\(RemotePath.name(path))” isn't one.")
            }
        } else {
            try await powershell("try{Clear-Content -LiteralPath \(Session.powershellLiteral(Session.windowsPath(path))) -Force "
                                 + "-ErrorAction Stop}catch{$_.Exception.Message;exit 1}")
        }
    }

    /// Why Disk Usage can't run on this server (nil: it can), for disabled controls' tooltips: only a host browsed as
    /// another user whose sudo doesn't work.
    public var diskUsageProblem: String? { capabilities.sudoProblem }

    /// Why Empty File can't run on this server (nil: it can).
    public var emptyFileProblem: String? {
        if s3 != nil { return "S3 storage can't change a file in place." }
        if capabilities.shell || capabilities.windows && !capabilities.loginShell.isEmpty { return nil }
        return "Emptying a file needs shell commands, which this server doesn't run (sftp only)."
    }

    // MARK: Windows, sftp-only servers and S3

    /// A Windows OpenSSH path ("/C:/Users/name") as Windows writes it ("C:\\Users\\name"; a drive's root "C:\\").
    static func windowsPath(_ path: String) -> String {
        let windows = path.split(separator: "/").joined(separator: "\\")
        return windows.hasSuffix(":") ? windows + "\\" : windows
    }

    /// A PowerShell single-quoted string (its quote characters doubled: PowerShell reads ‘ ’ ‚ ‛ as ').
    static func powershellLiteral(_ text: String) -> String {
        "'" + text.map { "'‘’‚‛".contains($0) ? "\($0)\($0)" : "\($0)" }.joined() + "'"
    }

    /// The PowerShell walk: folder by folder with .NET (quicker than Get-ChildItem), not into reparse points (links,
    /// junctions, other disks mounted inside), lines as `DiskUsage.parseWindows` reads them, written in batches.
    static func windowsScanScript(_ dir: String) -> String {
        "$r=[IO.DirectoryInfo]::new(\(powershellLiteral(windowsPath(dir))));$L=$r.FullName.TrimEnd('\\').Length+1;"
            + "$o=[Console]::Out;$b=[Text.StringBuilder]::new();$k=0;$s=@();$t=[Collections.Stack]::new();$t.Push($r);"
            + "while($t.Count){$d=$t.Pop();try{$a=$d.GetFileSystemInfos()}catch{if($d -eq $r){$o.Write($_.Exception.GetBaseException()"
            + ".Message);exit 1};$k++;if($k -le 20){$s+=$d.FullName.Substring($L)};continue};"
            + "if($d -eq $r){$o.Write(\"count=$($a.Count)`n\")};foreach($i in $a){$p=$i.FullName.Substring($L).Replace('\\','/');"
            + "if($i -is [IO.DirectoryInfo]){[void]$b.Append(\"D`t0`t$p`n\");if(!($i.Attributes -band 1024)){$t.Push($i)}}"
            + "else{[void]$b.Append(\"F`t$($i.Length)`t$p`n\")};if($b.Length -gt 65536){$o.Write($b.ToString());$o.Flush();"
            + "[void]$b.Clear()}}};$o.Write($b.ToString());$s|%{$o.Write(\"S`t$($_.Replace('\\','/'))`n\")};"
            + "$o.Write(\"skipped=$k`n\");$o.Flush()"
    }

    private func windowsScan(_ dir: String, found: @escaping ([DiskUsage.Record], Int) -> Void) async throws -> DiskUsage.Skipped {
        var pending = Data(), expected = 0, skipped = DiskUsage.Skipped()
        let result = try await cancellable { cancellation in
            try await remote(OpenSSH.powershell(Session.windowsScanScript(dir)), cancellation: cancellation, standardOutput: { chunk in
                pending.append(chunk)
                guard let end = pending.lastIndex(of: 0x0A) else { return }
                let text = String(decoding: pending[..<end], as: UTF8.self)
                pending = pending.subdata(in: (end + 1)..<pending.endIndex)
                let records = DiskUsage.parseWindows(Substring(text), expected: &expected, skipped: &skipped)
                if !records.isEmpty || expected > 0 { found(records, expected) }
            })
        }
        guard result.status == 0 else {
            let printed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            throw AirSCPError(.other, "Can't read “\(RemotePath.name(dir))”" + (printed.isEmpty ? "." : ": " + printed),
                              details: printed + result.stderr)
        }
        return skipped
    }

    /// A level of the tree at a time, 200 folders a command (`listings`); a folder that one can't list is listed alone,
    /// which says why: then it is passed over (the scanned folder itself throws).
    private func diskUsageOverSFTP(_ dir: String, found: @escaping ([DiskUsage.Record], Int) -> Void) async throws -> DiskUsage.Skipped {
        let prefix = dir.hasSuffix("/") ? dir : dir + "/"
        var level = [dir], expected = -1, skipped = DiskUsage.Skipped()
        while !level.isEmpty {
            var next: [String] = []
            for start in stride(from: 0, to: level.count, by: 200) {
                try Task.checkCancellation()
                let chunk = Array(level[start..<min(start + 200, level.count)])
                var records: [DiskUsage.Record] = []
                for (folder, listed) in zip(chunk, try await listings(chunk)) {
                    var entries = listed
                    if entries == nil {
                        do {
                            entries = try await list(folder)
                        } catch let error as AirSCPError where error.kind != .cancelled && error.kind != .disconnected && folder != dir {
                            skipped.add(String(folder.dropFirst(prefix.count)))
                            continue
                        }
                    }
                    if expected < 0 { expected = entries?.count ?? 0 }
                    for entry in entries ?? [] {
                        let folder = entry.kind == .directory
                        records.append(DiskUsage.Record(path: String(entry.path.dropFirst(prefix.count)), size: folder ? 0 : entry.size,
                                                        folder: folder))
                        if folder { next.append(entry.path) }
                    }
                }
                found(records, max(expected, 0))
            }
            level = next
        }
        return skipped
    }

    /// One flat listing (every key with its size, a page of 1,000 at a time) instead of a listing per folder; at "/"
    /// each bucket's.
    private func diskUsageS3(_ dir: String, found: @escaping ([DiskUsage.Record], Int) -> Void) async throws -> DiskUsage.Skipped {
        guard let s3 else { return DiskUsage.Skipped() }
        let expected = try await listS3(dir).count
        let places: [(bucket: String, key: String, shown: String)]
        if let (bucket, key) = Session.s3Location(dir) {
            places = [(bucket, key.isEmpty ? "" : key + "/", "")]
        } else {
            places = try await listS3("/").map { ($0.name, "", $0.name + "/") }
            found(places.map { DiskUsage.Record(path: $0.bucket, size: 0, folder: true) }, expected)
        }
        for place in places {
            _ = try await cancellable { cancellation in
                try await s3.list(place.bucket, prefix: place.key, delimiter: nil, cancellation: cancellation) { objects in
                    found(objects.compactMap { object in
                        let path = place.shown + object.key.dropFirst(place.key.count)
                        guard path != place.shown else { return nil }  // the folder's own marker
                        return path.hasSuffix("/") ? DiskUsage.Record(path: String(path.dropLast()), size: 0, folder: true)
                            : DiskUsage.Record(path: path, size: object.size, folder: false)
                    }, expected)
                }
            }
        }
        return DiskUsage.Skipped()
    }
}
