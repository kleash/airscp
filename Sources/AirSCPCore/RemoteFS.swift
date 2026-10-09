import Foundation

/// Remote paths: POSIX paths kept as text (never through URL, which would normalise them).
public enum RemotePath {
    public static func join(_ dir: String, _ name: String) -> String {
        dir.hasSuffix("/") ? dir + name : dir + "/" + name
    }

    public static func parent(_ path: String) -> String {
        let trimmed = trimmingSlashes(path)
        guard let slash = trimmed.lastIndex(of: "/") else { return "." }
        return slash == trimmed.startIndex ? "/" : String(trimmed[..<slash])
    }

    public static func name(_ path: String) -> String {
        let trimmed = trimmingSlashes(path)
        guard let slash = trimmed.lastIndex(of: "/") else { return trimmed }
        return String(trimmed[trimmed.index(after: slash)...])
    }

    /// An absolute path without "." and ".." parts or doubled slashes ("/a/./b/../c" → "/a/c").
    public static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { _ = parts.popLast() } else { parts.append(part) }
        }
        return "/" + parts.joined(separator: "/")
    }

    private static func trimmingSlashes(_ path: String) -> String {
        var trimmed = path
        while trimmed.count > 1 && trimmed.hasSuffix("/") { trimmed.removeLast() }
        return trimmed
    }
}

/// A file, folder or link on the server, from `ls -la` (a shell's or sftp's).
public struct RemoteEntry: Hashable, Identifiable {
    public enum Kind: Hashable { case file, directory, symlink, other }

    public var id: String { path }
    public let name: String
    public let path: String
    public let kind: Kind
    public let size: Int64
    /// To the minute (ls shows no more); for a `dateOnly` entry that day's midnight in UTC.
    public let modified: Date?
    /// As ls shows them, e.g. "rwxr-xr-x".
    public let permissions: String
    /// The permission bits, e.g. 0o755 (setuid, setgid and sticky included).
    public let mode: Int
    /// Names, as ls shows them (a number when the server has no name for it).
    public let owner: String
    public let group: String
    /// The listing gave the day only (ls and sftp do for a time over six months ago, or after the server's clock): show
    /// it as a day, and compare it by the day.
    public var dateOnly = false
    /// The owner's and group's numbers (uid and gid), where the server told them: listings with a shell.
    public var ownerID: Int?
    public var groupID: Int?

    public var isHidden: Bool { name.hasPrefix(".") }
}

/// `ls -la` output.
public enum Listing {
    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// Dates as a shell's `ls` prints them for AirSCP (TZ=UTC0). A new one each time: parses run on many threads.
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// The entries of `dir` in sftp's `ls -la` output, without "." and ".." and sftp's echoed commands. A name with
    /// a newline in it spills onto the next line; such entries are left out (the line before the spill parses, but
    /// with a cut-off name). So is a name with "/" in it, which no file can have: only a hostile server sends one,
    /// to make a download land outside the folder chosen for it. Reads the bytes directly (no regular expression): a
    /// 50 000-entry folder parses in a fraction of a second.
    public static func parse(_ output: String, in dir: String, now: Date = Date()) -> [RemoteEntry] {
        parse(output, in: dir, now: now, calendar: .current, linkTargets: false) ?? []
    }

    /// `linkTargets`: the output of a shell's `ls -la`, where a link's line ends in " -> <target>" (and dates are in
    /// `calendar`'s time zone). nil when such a line has " -> " more than once: its name can't be told then.
    static func parse(_ output: String, in dir: String, now: Date, calendar: Calendar, linkTargets: Bool) -> [RemoteEntry]? {
        parse(Data(output.utf8), in: dir, now: now, calendar: calendar, linkTargets: linkTargets)
    }

    /// From the bytes as they came: a name that isn't UTF-8 (a legacy Latin-1 one) shows its bad bytes as "�". Its
    /// path then reaches no file, unless another name there really is spelled that way: such a name is left out, so
    /// that nothing done to it can reach the other file.
    static func parse(_ output: Data, in dir: String, now: Date, calendar: Calendar, linkTargets: Bool) -> [RemoteEntry]? {
        output.withUnsafeBytes { raw -> [RemoteEntry]? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var entries: [RemoteEntry] = []
            var valid: [Bool] = []
            var afterEntry = false
            var ambiguous = false
            var start = 0
            while start < bytes.count {
                var end = start
                while end < bytes.count && bytes[end] != 0x0A { end += 1 }
                let line = UnsafeBufferPointer(rebasing: bytes[start..<end])
                start = end + 1
                if line.starts(with: "sftp> ".utf8) { continue }
                var utf8 = true
                if let entry = entry(line, in: dir, calendar: calendar, now: now, linkTargets: linkTargets,
                                     ambiguous: &ambiguous, utf8: &utf8) {
                    let skipped = entry.name == "." || entry.name == ".." || entry.name.contains("/")
                    if !skipped {
                        entries.append(entry)
                        valid.append(utf8)
                    }
                    afterEntry = !skipped
                } else {
                    if ambiguous { return nil }
                    if afterEntry {
                        entries.removeLast()
                        valid.removeLast()
                    }
                    afterEntry = false
                }
            }
            guard valid.contains(false) else { return entries }
            let spelled = Set(zip(entries, valid).filter(\.1).map(\.0.name))
            return zip(entries, valid).filter { $0.1 || !spelled.contains($0.0.name) }.map(\.0)
        }
    }

    /// One line: type and permissions (anything may follow them, e.g. "+" or "@"), links, owner and group (names, the
    /// group maybe with spaces), size, month, day, time or year, one space, the name (to the end of the line). Owner
    /// and group end at the first words that read as size and date followed by a name.
    static func entry(_ line: UnsafeBufferPointer<UInt8>, in dir: String, calendar: Calendar, now: Date,
                      linkTargets: Bool = false, ambiguous: inout Bool) -> RemoteEntry? {
        var utf8 = true
        return entry(line, in: dir, calendar: calendar, now: now, linkTargets: linkTargets, ambiguous: &ambiguous, utf8: &utf8)
    }

    /// `utf8` is set to false when the name isn't valid UTF-8.
    static func entry(_ line: UnsafeBufferPointer<UInt8>, in dir: String, calendar: Calendar, now: Date,
                      linkTargets: Bool = false, ambiguous: inout Bool, utf8: inout Bool) -> RemoteEntry? {
        let count = line.count
        guard count > 10 else { return nil }
        let kind: RemoteEntry.Kind
        switch line[0] {
        case UInt8(ascii: "d"): kind = .directory
        case UInt8(ascii: "-"): kind = .file
        case UInt8(ascii: "l"): kind = .symlink
        case UInt8(ascii: "c"), UInt8(ascii: "b"), UInt8(ascii: "p"), UInt8(ascii: "s"): kind = .other
        default: return nil
        }
        for index in 1...9 where !"-rwxsStT".utf8.contains(line[index]) { return nil }
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || (byte >= 0x09 && byte <= 0x0D) }
        func text(_ range: Range<Int>) -> String { String(decoding: UnsafeBufferPointer(rebasing: line[range]), as: UTF8.self) }
        func digits(_ range: Range<Int>) -> Bool { !range.isEmpty && range.allSatisfy { line[$0] >= 0x30 && line[$0] <= 0x39 } }
        func number(_ range: Range<Int>) -> Int { range.reduce(0) { $0 &* 10 &+ Int(line[$1] &- 0x30) } }

        var position = 10
        while position < count && !isSpace(line[position]) { position += 1 }  // after the permissions
        // Words from here: links, owner, group…, size, month, day, time or year; then the name.
        var words: [Range<Int>] = []
        while true {
            while position < count && isSpace(line[position]) { position += 1 }
            guard position < count else { return nil }
            let wordStart = position
            while position < count && !isSpace(line[position]) { position += 1 }
            words.append(wordStart..<position)
            let last = words.count - 1
            guard last >= 5 else { continue }  // size must come after links and at least one owner word
            let (size, month, day, time) = (words[last - 3], words[last - 2], words[last - 1], words[last])
            guard position + 1 < count, line[position] == 0x20, digits(size), month.count == 3,
                  line[month.lowerBound] >= 0x41 && line[month.lowerBound] <= 0x5A,
                  line[month.lowerBound + 1] >= 0x61 && line[month.lowerBound + 1] <= 0x7A,
                  line[month.lowerBound + 2] >= 0x61 && line[month.lowerBound + 2] <= 0x7A,
                  digits(day), day.count <= 2 else { continue }
            var hour: Int?, minute = 0, year: Int?
            if time.count == 4 && digits(time) {
                year = number(time)
            } else if let colon = time.firstIndex(where: { line[$0] == UInt8(ascii: ":") }),
                      colon > time.lowerBound, colon - time.lowerBound <= 2, time.upperBound - colon == 3,
                      digits(time.lowerBound..<colon), digits(colon + 1..<time.upperBound) {
                hour = number(time.lowerBound..<colon)
                minute = number(colon + 1..<time.upperBound)
            } else {
                continue
            }
            var name = text(position + 1..<count)
            utf8 = name.utf8.elementsEqual(UnsafeBufferPointer(rebasing: line[(position + 1)..<count]))
            if linkTargets && kind == .symlink {
                let parts = name.components(separatedBy: " -> ")
                guard parts.count == 2 else {
                    ambiguous = true
                    return nil
                }
                name = parts[0]
            }
            let permissions = text(1..<10)
            let monthIndex = months.firstIndex(of: text(month))
            return RemoteEntry(name: name, path: RemotePath.join(dir, name), kind: kind,
                               size: Int64(text(size)) ?? 0,
                               modified: monthIndex.flatMap { date(month: $0 + 1, day: number(day), hour: hour, minute: minute,
                                                                    year: year, calendar: calendar, now: now) },
                               permissions: permissions, mode: mode(permissions),
                               owner: text(words[1]), group: words[2..<(last - 3)].map(text).joined(separator: " "),
                               dateOnly: year != nil)
        }
    }

    /// "Oct  2 18:39" (`hour` and `minute`) is within the last six months (so last year if that would be in the
    /// future); "Oct  2  2025" (`year`) is older, or after the server's clock: a day, as its midnight in UTC (whatever
    /// time zone the listing was in), so that it shows as that day everywhere.
    static func date(month: Int, day: Int, hour: Int?, minute: Int, year: Int?, calendar: Calendar, now: Date) -> Date? {
        var components = DateComponents(month: month, day: day)
        if let hour {
            components.hour = hour
            components.minute = minute
            components.year = calendar.component(.year, from: now)
            if let date = calendar.date(from: components), date > now.addingTimeInterval(86400) {
                components.year! -= 1
            }
            return calendar.date(from: components)
        }
        components.year = year
        return calendar.date(from: components).map { $0.addingTimeInterval(TimeInterval(calendar.timeZone.secondsFromGMT(for: $0))) }
    }

    /// "rwsr-x--T" → 0o4750 | 0o1000.
    static func mode(_ permissions: String) -> Int {
        var mode = 0
        for (index, character) in permissions.enumerated() where index < 9 {
            let bit = 1 << (8 - index)
            let special = index == 2 ? 0o4000 : index == 5 ? 0o2000 : 0o1000
            switch character {
            case "r", "w", "x": mode |= bit
            case "s", "t": mode |= bit | special
            case "S", "T": mode |= special
            default: break
            }
        }
        return mode
    }
}

public enum ArchiveFormat: String, CaseIterable {
    case zip, tarGz

    public var fileExtension: String { self == .zip ? ".zip" : ".tar.gz" }
}

public enum ExtractDestination {
    /// Into the archive's folder (existing files with the same names are replaced, as the tools do: ask first, with
    /// `Session.extractConflicts`).
    case here
    /// Into a new folder named after the archive ("name 2" when that exists).
    case newFolder
}

/// How an archive is extracted, from its name.
enum ArchiveKind {
    case zip, tar, gzip

    private static let tarSuffixes = [".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tbz2", ".tar.xz", ".txz"]

    init?(name: String) {
        let lower = name.lowercased()
        if lower.hasSuffix(".zip") {
            self = .zip
        } else if ArchiveKind.tarSuffixes.contains(where: lower.hasSuffix) {
            self = .tar
        } else if lower.hasSuffix(".gz") {
            self = .gzip
        } else {
            return nil
        }
    }

    /// The name without the archive extension ("logs.tar.gz" → "logs").
    static func baseName(_ name: String) -> String {
        let lower = name.lowercased()
        let suffix = ([".zip", ".gz"] + tarSuffixes).filter { lower.hasSuffix($0) }.max { $0.count < $1.count }
        let base = suffix.map { String(name.dropLast($0.count)) } ?? name
        return base.isEmpty ? name : base
    }
}

/// sftp's `df` on the server, in bytes (shown like this Mac's sizes).
public struct DiskFree: Equatable {
    public var size: Int64
    public var used: Int64
    public var available: Int64
    public var capacity: String
}

/// File operations on the server. sftp ones work everywhere; shell ones need `capabilities.shell` and throw
/// `.sftpOnly` (with the reason) without it. Paths are absolute.
extension Session {
    /// A folder's entries, owners and groups by name. With a shell whose ls prints names exactly as they are (GNU and
    /// BSD ls; not BusyBox's), `cd <dir> && ls -la`: one round trip, where sftp needs one per 100 entries (500 for a
    /// 50 000-entry folder). Else one sftp invocation of `cd "<dir>"` and `ls -la` (unlike `ls "<dir>"`, that doesn't
    /// glob, so names with {braces} work). A symlink to a folder lists the folder; anything else throws. Cancelling the
    /// calling task stops it (a huge folder the user has left).
    public func list(_ dir: String) async throws -> [RemoteEntry] {
        try await list(dir, slot: .control)
    }

    func list(_ dir: String, slot: Slot) async throws -> [RemoteEntry] {
        if capabilities.shell {
            do {
                if let entries = try await listWithShell(dir, slot: slot) { return entries }
            } catch let error as AirSCPError where error.kind != .cancelled && error.kind != .disconnected {
                // sftp tells what is wrong in its own words (or lists what ls couldn't, e.g. a folder holding an
                // entry ls may not look at).
            }
        }
        let batch = "cd \(Quote.sftp(dir))\nls -la\n"
        let argv = OpenSSH.sftpBatch(host, jump: jump, socket: socketPath)
        let result = try await cancellable { cancellation in
            slot == .control ? try await runControl(argv, input: batch, cancellation: cancellation)
                : try await runMuxed(argv, input: batch, cancellation: cancellation)
        }
        // sftp exits 0 when it can go into a folder but not read it ("remote readdir(…): Permission denied").
        guard result.status == 0, !result.stderr.contains("remote readdir(") else {
            throw ErrorMapping.map(result.stderr, status: result.status)
        }
        return Listing.parse(result.stdout, in: dir, now: Date(), calendar: .current, linkTargets: false) ?? []
    }

    /// `ls -la` in a shell (`lsFunction`), then the owners' and groups' numbers (ls prints names or numbers, not both):
    /// the folder listed again with `-n`, of which awk keeps a line for each pair of numbers.
    /// nil for another ls, BusyBox's listing with a "?", or when a link's line can't be split into name and target.
    private func listWithShell(_ dir: String, slot: Slot) async throws -> [RemoteEntry]? {
        let marker = "__AIRSCP_IDS_\(UUID().uuidString.prefix(8))__"
        let script = "cd \(Quote.shell(dir)) && { \(Session.lsFunction) l && { echo \(marker); "
            + "l -n | awk '$NF != \".\" && $NF != \"..\" && !s[$3 \" \" $4]++' 2>/dev/null; true; }; }"
        let output = try await cancellable { try await shellBytes(script, slot: slot, cancellation: $0) }
        guard let split = output.range(of: Data(("\n" + marker + "\n").utf8)) else { return Session.shellListing(output, in: dir) }
        return Session.shellListing(output[..<split.lowerBound], in: dir).map {
            Session.numbered($0, samples: Session.shellListing(output[split.upperBound...], in: dir) ?? [])
        }
    }

    /// `entries` with their owners' and groups' numbers, from `samples`: entries of the same folder listed with numbers.
    /// A name's number is that of a sample with the name of an entry that has it.
    static func numbered(_ entries: [RemoteEntry], samples: [RemoteEntry]) -> [RemoteEntry] {
        var wanted = Dictionary(samples.map { ($0.name, $0) }) { first, _ in first }
        var owners: [String: Int] = [:], groups: [String: Int] = [:]
        for entry in entries where !wanted.isEmpty {
            // Exactly that name: "café" composed and decomposed are two files on Linux, and equal Strings.
            guard let sample = wanted[entry.name], sample.name.utf8.elementsEqual(entry.name.utf8) else { continue }
            wanted[entry.name] = nil
            owners[entry.owner] = Int(sample.owner)
            groups[entry.group] = Int(sample.group)
        }
        guard !owners.isEmpty else { return entries }
        return entries.map { entry in
            var entry = entry
            entry.ownerID = owners[entry.owner]
            entry.groupID = groups[entry.group]
            return entry
        }
    }

    /// Several folders listed in one command (Synchronize compares a level of the tree at a time: a command per folder
    /// made trees with many folders slow, on a distant server very slow). nil for a folder that this can't list: list
    /// it alone, which says why (or, with a shell, uses sftp).
    public func listings(_ dirs: [String]) async throws -> [[RemoteEntry]?] {
        guard dirs.count > 1 else { return dirs.map { _ in nil } }
        guard capabilities.shell else { return try await sftpListings(dirs) }
        var result: [[RemoteEntry]?] = []
        let marker = "__AIRSCP_LISTED_\(UUID().uuidString.prefix(8))__"
        while result.count < dirs.count {
            // Up to 64 KB of paths per command: a server takes 128 KB in one argument.
            var chunk: [String] = [], length = 0
            for dir in dirs[result.count...] {
                if !chunk.isEmpty && length + dir.utf8.count >= 64 << 10 { break }
                chunk.append(dir)
                length += dir.utf8.count + 3
            }
            let script = Session.lsFunction + " for d in " + chunk.map(Quote.shell).joined(separator: " ")
                + "; do (cd \"$d\" && l) 2>/dev/null; s=$?; echo; echo \"\(marker) $s\"; done"
            let output = try await cancellable { try await shellBytes(script, cancellation: $0) }
            // Each folder's listing, then a line with the marker and ls's status.
            var listed: [[RemoteEntry]?] = [], rest = output[...]
            let separator = Data(("\n" + marker + " ").utf8)
            while let found = rest.range(of: separator), let end = rest[found.upperBound...].firstIndex(of: 0x0A) {
                let ok = rest[found.upperBound..<end].elementsEqual("0".utf8)
                listed.append(ok ? Session.shellListing(Data(rest[..<found.lowerBound]), in: chunk[listed.count]) : nil)
                rest = rest[(end + 1)...]
                if listed.count == chunk.count { break }
            }
            result += listed.count == chunk.count ? listed : chunk.map { _ in nil }
        }
        return result
    }

    /// `listings` without a shell: one sftp batch going into each folder and listing it, 200 folders at a time. A folder
    /// it can't go into ends the batch there: that one and the rest of the batch are nil.
    private func sftpListings(_ dirs: [String]) async throws -> [[RemoteEntry]?] {
        var result: [[RemoteEntry]?] = []
        while result.count < dirs.count {
            let chunk = Array(dirs[result.count...].prefix(200))
            let batch = chunk.map { "cd \(Quote.sftp($0))\nls -la\n" }.joined()
            let run = try await cancellable { cancellation in
                try await runControl(OpenSSH.sftpBatch(host, jump: jump, socket: socketPath), input: batch, cancellation: cancellation)
            }
            // sftp echoes each command: a folder's part starts at the line echoing its cd. (It exits 0 when it can go
            // into a folder but not read it: then none of these is used.)
            let output = run.stdout, echo = Data("\nsftp> cd ".utf8)
            var starts = output.starts(with: echo.dropFirst()) ? [output.startIndex] : [], from = output.startIndex
            while let found = output.range(of: echo, in: from..<output.endIndex) {
                starts.append(found.lowerBound + 1)
                from = found.upperBound
            }
            var parts = zip(starts, starts.dropFirst() + [output.endIndex]).map { output[$0..<$1] }
            if run.status != 0 { parts = parts.dropLast() }
            if run.stderr.contains("remote readdir(") { parts = [] }
            let listed = zip(chunk, parts).map { Listing.parse(Data($1), in: $0, now: Date(), calendar: .current, linkTargets: false) }
            result += listed + Array(repeating: nil, count: chunk.count - listed.count)
        }
        return result
    }

    /// Defines the shell function `l`: `ls -la` (and its arguments, e.g. `-n`) in the C locale with dates in UTC; GNU ls
    /// also told to print names literally, sizes in bytes and dates the classic way, whatever the environment says.
    /// BusyBox's ls turns every byte it can't print (in the C locale: all outside ASCII) into "?": its listing says so
    /// first. Another ls says only that it isn't one of these.
    static let lsFunction = "if ls --version 2>/dev/null | grep -q GNU; then "
        + "l() { LC_ALL=C TZ=UTC0 ls -la \"$@\" --quoting-style=literal --time-style=locale --block-size=1; }; "
        + "else case $(uname -s) in Darwin|*BSD) l() { LC_ALL=C TZ=UTC0 ls -la \"$@\"; };; *) if ls --help 2>&1 | grep -q BusyBox; "
        + "then l() { echo __AIRSCP_BUSYBOX__; LC_ALL=C TZ=UTC0 ls -la \"$@\"; }; else l() { echo __AIRSCP_NO_LS__; }; fi;; esac; fi;"

    /// The entries in what `l` printed for `dir`; nil when it can't be used: another ls, BusyBox's listing with a "?"
    /// in it, or a link's line that can't be split into name and target.
    static func shellListing(_ output: Data, in dir: String) -> [RemoteEntry]? {
        var output = output
        if output.starts(with: Data("__AIRSCP_NO_LS__".utf8)) { return nil }
        let busybox = Data("__AIRSCP_BUSYBOX__\n".utf8)
        if output.starts(with: busybox) {
            if output.contains(UInt8(ascii: "?")) { return nil }
            output = output.dropFirst(busybox.count)
        }
        return Listing.parse(Data(output), in: dir, now: Date(), calendar: Listing.utc, linkTargets: true)
    }

    /// Runs `body` with a Cancellation that the calling task's cancellation sets off.
    func cancellable<T>(_ body: (Cancellation) async throws -> T) async throws -> T {
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await body(cancellation)
        } onCancel: {
            cancellation.cancel()
        }
    }

    public func makeDirectory(_ path: String) async throws {
        try await sftp(["mkdir \(Quote.sftp(path))"])
    }

    /// Renames or moves. An existing file at `to` is replaced (check with `exists` first). sftp cuts a batch line at
    /// 2 048 bytes: a rename within a folder whose path is longer goes there first and renames by the names alone.
    public func rename(_ path: String, to newPath: String) async throws {
        let line = "rename \(Quote.sftp(path)) \(Quote.sftp(newPath))"
        let dir = RemotePath.parent(path)
        guard line.utf8.count > 2000, RemotePath.parent(newPath) == dir else {
            try await sftp([line])
            return
        }
        try await sftp(["cd \(Quote.sftp(dir))",
                        "rename \(Quote.sftp(RemotePath.name(path))) \(Quote.sftp(RemotePath.name(newPath)))"])
    }

    /// Whether the server has something (a file, folder or link) at `path` now: a folder's listing may be older. With
    /// a shell one test; without, a listing of its folder (sftp has no stat).
    public func exists(_ path: String) async throws -> Bool {
        if capabilities.shell {
            let name = Quote.shell(path)
            return try await shell("if [ -e \(name) ] || [ -L \(name) ]; then echo yes; fi").contains("yes")
        }
        let name = RemotePath.name(path), caseInsensitive = capabilities.caseInsensitive
        return Names.existing(name, in: try await list(RemotePath.parent(path)).map(\.name), caseInsensitive: caseInsensitive) != nil
    }

    /// Deletes files and links (`rm -f`, or where there is no shell sftp's rm) and folders with everything in them:
    /// `rm -rf`, or where there is no shell a walk with sftp (list, remove the files, recurse, rmdir).
    public func delete(_ entries: [RemoteEntry]) async throws {
        try await delete(entries, slot: .control)
    }

    func delete(_ entries: [RemoteEntry], slot: Slot) async throws {
        let others = entries.filter { $0.kind != .directory }
        if !others.isEmpty && capabilities.shell {
            // One command for them all: sftp's rm takes two round trips a file (50 files, half a minute over a slow
            // link). Every chunk is tried; what failed is thrown at the end.
            let commands = Session.chunks(others.map { Quote.shell($0.path) }).map { "rm -f -- \($0) || s=1; " }
            try await shell("s=0; " + commands.joined() + "[ $s = 0 ]", slot: slot)
        } else if !others.isEmpty {
            try await sftp(others.map { "rm \(Quote.sftp($0.path))" }, slot: slot)
        }
        let folders = entries.filter { $0.kind == .directory }.map(\.path)
        if !folders.isEmpty { try await deleteFolders(folders, slot: slot) }
    }

    /// Folders with everything in them: rm -rf, or a walk with sftp where there is no shell.
    func deleteFolders(_ paths: [String], slot: Slot) async throws {
        if capabilities.shell {
            try await shell("rm -rf -- " + paths.map(Quote.shell).joined(separator: " "), slot: slot)
        } else {
            for path in paths { try await deleteBySFTP(path, slot: slot) }
        }
    }

    /// Sets permissions (octal `mode`). `recursive` on a folder: everything in it too (links skipped, as chmod -R
    /// does), folders with `folderMode(mode)` so that they stay open where they can be read; the files first, the
    /// folders from the bottom up (a folder losing its search permission first would shut everything in it away).
    public func setPermissions(_ entry: RemoteEntry, mode: Int, recursive: Bool = false) async throws {
        try await setPermissions([entry], recursive: recursive) { _ in mode }
    }

    /// `setPermissions` for many items at once (Permissions… and Make Executable on a selection), each its `mode`: with
    /// a shell one command (a chmod per mode, finds for the folders' contents), else one sftp batch (and a walk per
    /// folder). A command per item took minutes for a few thousand, hours over a slow link. Every item is tried; what
    /// failed is thrown at the end, the tools' words for each under Details.
    public func setPermissions(_ entries: [RemoteEntry], recursive: Bool = false, mode: (RemoteEntry) -> Int) async throws {
        let folders = recursive ? entries.filter { $0.kind == .directory } : []
        let others = recursive ? entries.filter { $0.kind != .directory } : entries
        func octal(_ mode: Int) -> String { String(mode, radix: 8) }
        guard capabilities.shell else {
            if !others.isEmpty {
                // "-": each line runs whatever happened to the one before; a refusal is said on the error output.
                let refused = try await sftp(others.map { "-chmod \(octal(mode($0))) \(Quote.sftp($0.path))" }).stderr
                if !refused.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ErrorMapping.map(refused, status: 1) }
            }
            for folder in folders {
                try await chmodBySFTP(folder.path, octal: octal(mode(folder)), folders: octal(Session.folderMode(mode(folder))))
            }
            return
        }
        var commands: [String] = []
        for (value, group) in Dictionary(grouping: others, by: mode) {
            // The paths are absolute: none reads as an option (and BSD's chmod takes "--" only before the mode).
            commands += Session.chunks(group.map { Quote.shell($0.path) }).map { "chmod \(octal(value)) \($0)" }
        }
        for (value, group) in Dictionary(grouping: folders, by: mode) {
            for paths in Session.chunks(group.map { Quote.shell($0.path) }) {
                commands += ["find \(paths) ! -type d ! -type l -exec chmod \(octal(value)) {} +",
                             "find \(paths) -depth -type d -exec chmod \(octal(Session.folderMode(value))) {} +"]
            }
        }
        guard !commands.isEmpty else { return }
        try await shell("s=0; " + commands.map { $0 + " || s=1; " }.joined() + "[ $s = 0 ]")
    }

    /// Shell words joined into pieces of at most 64 KB, a command line each (a server takes 128 KB in one argument).
    static func chunks(_ words: [String]) -> [String] {
        var chunks: [String] = [], chunk = ""
        for word in words {
            if !chunk.isEmpty && chunk.utf8.count + word.utf8.count >= 64 << 10 {
                chunks.append(chunk)
                chunk = ""
            }
            chunk += (chunk.isEmpty ? "" : " ") + word
        }
        return chunk.isEmpty ? chunks : chunks + [chunk]
    }

    /// A recursive change's mode for folders: `mode` with search (x) wherever it reads (r), as chmod's "X" does for
    /// folders. 640 makes files rw-r----- and folders rwxr-x---.
    public static func folderMode(_ mode: Int) -> Int {
        mode | ((mode & 0o444) >> 2)
    }

    /// Puts `part`, a finished copy in the same folder, in the place of `path` (an upload's temporary copy). A file
    /// replaces what is there at once (sftp's rename is rename(2)) and keeps the replaced file's permissions;
    /// a folder that replaces one moves the old one aside first, removes it once the new one is in place, and puts it
    /// back if that fails.
    func moveIntoPlace(_ part: String, to path: String, folder: Bool, replacing: Bool, slot: Slot) async throws {
        let rename = "rename \(Quote.sftp(part)) \(Quote.sftp(path))"
        if !folder {
            let old = replacing ? try? await item(path, slot: slot) : nil
            let keep = old.map { ["-chmod \(String($0.mode, radix: 8)) \(Quote.sftp(part))"] }
            try await sftp((keep ?? []) + [rename], slot: slot)
            return
        }
        guard replacing else {
            try await sftp([rename], slot: slot)
            return
        }
        let aside = part.hasSuffix(".part") ? String(part.dropLast(5)) + ".old" : part + ".old"
        try? await deleteFolders([aside], slot: slot)  // an earlier try's
        do {
            try await sftp(["-rename \(Quote.sftp(path)) \(Quote.sftp(aside))", rename], slot: slot)
        } catch {
            _ = try? await sftp(["rename \(Quote.sftp(aside)) \(Quote.sftp(path))"], slot: slot)
            throw error
        }
        try? await deleteFolders([aside], slot: slot)
    }

    /// Moves everything in `staging` (a hidden folder, made in the folder the items belong in) into that folder and
    /// removes `staging`. With `replacing`, an item there under the same name is replaced; without, nothing there is
    /// touched: an item that appeared since the job was planned stops it (that item's new copy goes with `staging`).
    func moveItemsIntoPlace(from staging: String, replacing: Bool = true, slot: Slot) async throws {
        let appeared = { (name: String, details: String) in
            AirSCPError(.failure, "“\(name)” appeared in the folder after the transfer was planned: it was left as it is, "
                        + "and its new copy wasn't put in its place.", details: details)
        }
        if capabilities.shell {
            let taken = replacing ? "rm -rf -- \"../$n\" || exit 1" : "printf '__AIRSCP_EXISTS__%s\\n' \"$n\" >&2; exit 1"
            do {
                try await shell("cd \(Quote.shell(staging)) && for n in * .[!.]* ..?*; do "
                                + "if [ -e \"$n\" ] || [ -L \"$n\" ]; then "
                                + "if [ -e \"../$n\" ] || [ -L \"../$n\" ]; then \(taken); fi; "
                                + "mv -- \"$n\" \"../$n\" || exit 1; fi; done; cd .. && rmdir -- \(Quote.shell(RemotePath.name(staging)))",
                                slot: slot)
            } catch let error as AirSCPError where error.details.contains("__AIRSCP_EXISTS__") {
                let name = error.details.components(separatedBy: "__AIRSCP_EXISTS__").last?.components(separatedBy: "\n").first ?? ""
                throw appeared(name, error.details)
            }
            return
        }
        let dir = RemotePath.parent(staging)
        let there = replacing ? [] : try await list(dir, slot: slot).map(\.name)
        for entry in try await list(staging, slot: slot) {
            let target = RemotePath.join(dir, entry.name)
            if !replacing, Names.existing(entry.name, in: there, caseInsensitive: capabilities.caseInsensitive) != nil {
                throw appeared(entry.name, "")
            }
            if entry.kind == .directory { try? await deleteFolders([target], slot: slot) }  // a file is replaced by the rename
            try await sftp(["rename \(Quote.sftp(entry.path)) \(Quote.sftp(target))"], slot: slot)
        }
        try await sftp(["rmdir \(Quote.sftp(staging))"], slot: slot)
    }

    /// One item as sftp's `ls -l` shows it (so without a shell too; a link shows what it points to): its kind,
    /// permission bits and owner (as sftp names it). nil when it isn't there.
    func item(_ path: String, slot: Slot = .control) async throws -> (kind: RemoteEntry.Kind, mode: Int, owner: String)? {
        let result: CommandResult
        do {
            result = try await sftp(["ls -l \(Quote.sftp(path))"], slot: slot)
        } catch let error as AirSCPError where error.kind == .noSuchFile {
            return nil
        }
        for line in result.output.split(separator: "\n") where line.hasSuffix(" " + path) && !line.hasPrefix("sftp> ") {
            let words = line.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard words.count == 5, words[0].count >= 10 else { continue }
            let kind: RemoteEntry.Kind = line.first == "-" ? .file : line.first == "l" ? .symlink : line.first == "d" ? .directory : .other
            return (kind, Listing.mode(String(words[0].dropFirst().prefix(9))) & 0o7777, String(words[2]))
        }
        return nil
    }

    /// Creates an empty file, only where nothing has the name (made since the folder was listed, perhaps): with a
    /// shell in one step (noclobber: the shell creates it exclusively), else after checking (then puts an empty file).
    public func createFile(_ path: String) async throws {
        let exists = AirSCPError(.failure, "“\(RemotePath.name(path))” already exists in that folder (it was made after "
                                 + "the folder was listed). Choose another name.")
        if capabilities.shell {
            do {
                try await shell("set -C && : > \(Quote.shell(path))")
            } catch let error as AirSCPError where error.details.contains("exist") || error.details.contains("Is a directory") {
                throw AirSCPError(exists.kind, exists.message, details: error.details)
            }
            return
        }
        if try await self.exists(path) { throw exists }
        let empty = try temporaryFile(Data())
        defer { try? FileManager.default.removeItem(at: empty) }
        try await sftp(["put \(Quote.sftp(empty.path)) \(Quote.sftp(path))"])
    }

    /// Disk space of the file system holding `path` (sftp df, in kilobytes).
    public func diskFree(_ path: String) async throws -> DiskFree {
        let result = try await sftp(["df \(Quote.sftp(path))"])
        let rows = result.output.components(separatedBy: "\n").filter { !$0.hasPrefix("sftp> ") && !$0.isEmpty }
        guard let values = rows.last?.split(whereSeparator: { $0.isWhitespace }).map(String.init), values.count >= 4,
              values.last?.hasSuffix("%") == true, let size = Int64(values[0]), let used = Int64(values[1]),
              let available = Int64(values[2]) else {
            throw AirSCPError(.other, "The server didn't report its disk space.", details: result.output)
        }
        return DiskFree(size: size * 1024, used: used * 1024, available: available * 1024, capacity: values[values.count - 1])
    }

    /// Copies a file or folder next to itself as "name 2" (cp -R) and returns the copy's path.
    public func duplicate(_ entry: RemoteEntry) async throws -> String {
        try requireShell()
        let dir = RemotePath.parent(entry.path)
        let copy = RemotePath.join(dir, Names.unique(entry.name, existing: try await list(dir).map(\.name)))
        try await shell("cp -R -- \(Quote.shell(entry.path)) \(Quote.shell(copy))")
        return copy
    }

    /// Why `format` can't be made on this server, or nil when it can.
    public func compressUnavailableReason(_ format: ArchiveFormat) -> String? {
        let capabilities = self.capabilities
        if !capabilities.shell { return capabilities.noShellReason ?? "This server doesn't run shell commands." }
        let tool = format == .zip ? "zip" : "tar"
        return capabilities.tools.contains(tool) ? nil : "The server has no \(tool) command."
    }

    /// Why the named archive can't be extracted on this server (nil when it can, or when it is no archive AirSCP
    /// knows: check `isArchive`).
    public func extractUnavailableReason(_ name: String) -> String? {
        let capabilities = self.capabilities
        if !capabilities.shell { return capabilities.noShellReason }
        switch ArchiveKind(name: name) {
        case .zip?:
            let tools = capabilities.tools
            return tools.contains("unzip") || tools.contains("python3") ? nil : "The server has neither unzip nor python3."
        case .tar?:
            return capabilities.tools.contains("tar") ? nil : "The server has no tar command."
        case .gzip?:
            return capabilities.tools.contains("gzip") ? nil : "The server has no gzip command."
        case nil:
            return nil
        }
    }

    /// Whether AirSCP can extract a file with this name (zip, tar, tar.gz/tgz/bz2/xz, gz).
    public static func isArchive(_ name: String) -> Bool {
        ArchiveKind(name: name) != nil
    }

    /// Packs `names` (in `dir`) into dir/name.zip or name.tar.gz ("Archive" for several, "name 2" when taken)
    /// and returns the archive's path.
    public func compress(_ names: [String], in dir: String, format: ArchiveFormat) async throws -> String {
        if let reason = compressUnavailableReason(format) { throw AirSCPError(.missingTool, reason) }
        let base = names.count == 1 ? names[0] : "Archive"
        let archive = RemotePath.join(dir, Names.unique(base + format.fileExtension, existing: try await list(dir).map(\.name)))
        // "./name": zip reads its standard input for a member named "-", even after "--".
        let members = names.map { Quote.shell("./" + $0) }.joined(separator: " ")
        let pack = format == .zip ? "zip -r -q \(Quote.shell(archive)) -- \(members)" : "tar -czf \(Quote.shell(archive)) -- \(members)"
        try await shell("cd \(Quote.shell(dir)) && \(pack) || { rm -f \(Quote.shell(archive)); false; }")
        return archive
    }

    /// The names in the archive's folder that extracting it `.here` would replace: its top-level items that are there
    /// already (a .gz gets a free name, so none). Ask before replacing them, or extract into a new folder.
    public func extractConflicts(_ entry: RemoteEntry) async throws -> [String] {
        guard let kind = ArchiveKind(name: entry.name), kind != .gzip else { return [] }
        if let reason = extractUnavailableReason(entry.name) { throw AirSCPError(.missingTool, reason) }
        let archive = Quote.shell(entry.path)
        let paths: [Substring]
        if kind == .tar {
            // GNU tar in the C locale writes every byte outside ASCII as \ooo; others are asked for UTF-8.
            paths = try await shell("case $(tar --version 2>/dev/null) in *GNU*) tar --quoting-style=literal -tf \(archive);; "
                                    + "*) LC_ALL=C.UTF-8 tar -tf \(archive);; esac").split(separator: "\n")
        } else if capabilities.tools.contains("unzip") {
            // unzip -l, Info-ZIP's and BusyBox's alike: between two lines of dashes, a line per item: size, date, time,
            // three spaces, name.
            let lines = try await shell(Session.unzip("-l", entry.path)).split(separator: "\n", omittingEmptySubsequences: false)
            let dashes = lines.indices.filter { lines[$0].hasPrefix("---------") }
            paths = dashes.count < 2 ? [] : lines[(dashes[0] + 1)..<dashes[1]].compactMap { line in
                line.range(of: #"[0-9]{2}:[0-9]{2}   "#, options: .regularExpression).map { line[$0.upperBound...] }
            }
        } else {
            paths = try await shell("python3 -c 'import sys, zipfile; print(\"\\n\".join(zipfile.ZipFile(sys.argv[1]).namelist()))' "
                                    + archive).split(separator: "\n")
        }
        // The items' first path components ("./a/b" and "a/" are "a"), as they are named in the folder.
        let tops = Set(paths.compactMap { $0.split(separator: "/").first { $0 != "." }.map(String.init) })
        let existing = Dictionary(try await list(RemotePath.parent(entry.path)).map { (Names.key($0.name), $0.name) }) { first, _ in first }
        return tops.compactMap { existing[Names.key($0)] }.sorted()
    }

    /// Extracts a zip (unzip, else python3 -m zipfile), tar (any compression tar knows) or .gz (gzip -dc) and
    /// returns the folder it went into.
    public func extract(_ entry: RemoteEntry, into destination: ExtractDestination) async throws -> String {
        guard let kind = ArchiveKind(name: entry.name) else {
            throw AirSCPError(.other, "\(entry.name) isn't an archive AirSCP can extract.")
        }
        if let reason = extractUnavailableReason(entry.name) { throw AirSCPError(.missingTool, reason) }
        let dir = RemotePath.parent(entry.path)
        let base = ArchiveKind.baseName(entry.name)
        var existing = try await list(dir).map(\.name)
        var target = dir
        var script = ""
        if destination == .newFolder {
            target = RemotePath.join(dir, Names.unique(base, existing: existing))
            existing = []
            script = "mkdir \(Quote.shell(target)) && "
        }
        let archive = Quote.shell(entry.path)
        var extract: String
        switch kind {
        case .zip:
            extract = capabilities.tools.contains("unzip")
                ? Session.unzip("-q -o", entry.path, "-d \(Quote.shell(target))")
                : "python3 -m zipfile -e \(archive) \(Quote.shell(target))"
        case .tar:
            extract = "tar -xf \(archive) -C \(Quote.shell(target))"
        case .gzip:
            let output = RemotePath.join(target, Names.unique(base, existing: existing))
            extract = "gzip -dc \(archive) > \(Quote.shell(output))"
        }
        // A new folder that stayed empty (the archive is broken) goes again.
        if destination == .newFolder { extract = "{ \(extract); } || { rmdir \(Quote.shell(target)) 2>/dev/null; false; }" }
        try await shell(script + extract)
        return target
    }

    /// unzip with `options` on the archive at `path`, in its folder. Info-ZIP's unzip reads the archive's name as a
    /// pattern ("a[1].zip" would open a1.zip): there [, * and ? are written as [[], [*] and [?]. BusyBox's takes the
    /// name as it is.
    static func unzip(_ options: String, _ path: String, _ after: String = "") -> String {
        "cd \(Quote.shell(RemotePath.parent(path))) && z=\(Quote.shell("./" + RemotePath.name(path))) && "
            + "case $(unzip -v 2>/dev/null) in *UnZip*) z=$(printf '%s\\n' \"$z\" | sed 's/[[*?]/[&]/g');; esac && "
            + "unzip \(options) \"$z\" \(after)"
    }

    /// A text file's contents for the editor (sftp get; works without a shell), byte for byte (a byte order mark is
    /// kept, and written back). Throws `.notText` for files that aren't UTF-8, that are larger than `limit` bytes (the
    /// download stops there: a link's listing doesn't tell how big its target is), or that have a line longer than
    /// `lineLimit` bytes (minified code: the editor would take minutes to lay it out).
    public func readText(_ path: String, limit: Int = 4 << 20, lineLimit: Int = 256 << 10) async throws -> String {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("airscp-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: local) }
        try await fetch(path, to: local, limit: Int64(limit), tooLarge: RemoteFSText.tooLarge)
        let data = try Data(contentsOf: local)
        guard data.count <= limit else { throw AirSCPError(.notText, RemoteFSText.tooLarge) }
        guard String(data: data, encoding: .utf8) != nil else {
            throw AirSCPError(.notText, "The file isn't plain text (UTF-8), so AirSCP's editor can't open "
                + "it. Use Open to open it in its app.")
        }
        var longest = 0, start = 0
        for (index, byte) in data.enumerated() where byte == 0x0A {
            longest = max(longest, index - start)
            start = index + 1
        }
        guard max(longest, data.count - start) <= lineLimit else {
            throw AirSCPError(.notText, "The file has lines too long to edit here (minified code?): open it in another app instead.")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// Saves the editor's text over the file. It is written next to it and renamed over it, so that a full disk or a
    /// lost connection can't leave it half written, and keeps its permissions. It is written in place (as an sftp put
    /// into it, which keeps everything about it) when renaming would change more than its contents: for a symbolic
    /// link (`isLink`: sftp can't tell), a file of another owner, or one in a folder AirSCP may not write in.
    public func writeText(_ text: String, to path: String, isLink: Bool = false) async throws {
        let local = try temporaryFile(Data(text.utf8))
        defer { try? FileManager.default.removeItem(at: local) }
        guard !isLink, let old = try? await item(path), old.kind == .file else { return try await store(local, to: path) }
        let part = RemotePath.join(RemotePath.parent(path), TransferQueue.partName(UUID()))
        let new: (kind: RemoteEntry.Kind, mode: Int, owner: String)?
        do {
            try await sftp(["put \(Quote.sftp(local.path)) \(Quote.sftp(part))"])
            new = try? await item(part)
        } catch let error as AirSCPError where error.kind == .permissionDenied {
            return try await store(local, to: path)
        } catch {
            _ = try? await sftp(["rm \(Quote.sftp(part))"])
            throw error
        }
        guard new?.owner == old.owner else {
            _ = try? await sftp(["rm \(Quote.sftp(part))"])
            return try await store(local, to: path)
        }
        do {
            try await moveIntoPlace(part, to: path, folder: false, replacing: true, slot: .control)
        } catch {
            _ = try? await sftp(["rm \(Quote.sftp(part))"])
            throw error
        }
    }

    /// Downloads one file with sftp (for the editor, Quick Look and "Open with"): small files, no progress. With
    /// `limit`, the download stops once more bytes than that have arrived and `.notText` with `tooLarge` is thrown.
    public func fetch(_ path: String, to local: URL, limit: Int64? = nil, tooLarge: String = "The file is too large.")
        async throws {
        if let tooLong = TransferQueue.tooLong(path) { throw tooLong }
        let get = "get \(Quote.sftp(path)) \(Quote.sftp(local.path))"
        guard let limit else {
            try await sftp([get])
            return
        }
        let cancellation = Cancellation()
        let watch = Task.detached {
            while !Task.isCancelled && !cancellation.isCancelled {
                if (TransferQueue.localSize(local.path) ?? 0) > limit { return cancellation.cancel() }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
        defer { watch.cancel() }
        do {
            try await withTaskCancellationHandler {
                _ = try await sftp([get], cancellation: cancellation)
            } onCancel: {
                cancellation.cancel()
            }
        } catch let error as AirSCPError where error.kind == .cancelled && (TransferQueue.localSize(local.path) ?? 0) > limit {
            throw AirSCPError(.notText, tooLarge)
        }
        if (TransferQueue.localSize(local.path) ?? 0) > limit { throw AirSCPError(.notText, tooLarge) }
    }

    /// Uploads one file with sftp ("Upload changes" after editing in another app).
    public func store(_ local: URL, to path: String) async throws {
        try await sftp(["put \(Quote.sftp(local.path)) \(Quote.sftp(path))"])
    }

    // MARK: sftp walks (servers without a shell)

    private func deleteBySFTP(_ dir: String, slot: Slot) async throws {
        let entries = try await list(dir, slot: slot)
        for entry in entries where entry.kind == .directory { try await deleteBySFTP(entry.path, slot: slot) }
        try await sftp(entries.filter { $0.kind != .directory }.map { "rm \(Quote.sftp($0.path))" } + ["rmdir \(Quote.sftp(dir))"],
                       slot: slot)
    }

    private func chmodBySFTP(_ dir: String, octal: String, folders: String) async throws {
        try await sftp(["chmod \(folders) \(Quote.sftp(dir))"])
        let entries = try await list(dir)
        let files = entries.filter { $0.kind == .file || $0.kind == .other }
        if !files.isEmpty { try await sftp(files.map { "chmod \(octal) \(Quote.sftp($0.path))" }) }
        for entry in entries where entry.kind == .directory { try await chmodBySFTP(entry.path, octal: octal, folders: folders) }
    }

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("airscp-\(UUID().uuidString)")
        try data.write(to: url)
        return url
    }
}

enum RemoteFSText {
    static let tooLarge = "The file is over 4 MB, too large for AirSCP's editor. Use Open to open it in its app."
}
