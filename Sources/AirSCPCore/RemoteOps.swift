import CryptoKit
import Foundation

/// Get Info for a remote item. Shell hosts fill in everything; sftp-only hosts only what the listing shows (`kind`,
/// `itemCount`, `accessed`, `changed` and `linkTarget` stay nil there, and a folder's `size` too).
public struct RemoteInfo: Equatable {
    public var path: String
    /// `file -b`, e.g. "ASCII text" or "directory".
    public var kind: String?
    /// In bytes: the file's size, or for a folder everything in it (du -sk).
    public var size: Int64?
    /// What a folder holds at every level (find | wc -l, the folder itself not counted); nil for files.
    public var itemCount: Int?
    /// Permission bits, e.g. 0o755 (setuid, setgid and sticky included).
    public var mode: Int
    public var owner: String
    public var group: String
    public var modified: Date?
    public var accessed: Date?
    /// The status change time (ctime).
    public var changed: Date?
    /// Where a symlink points (readlink).
    public var linkTarget: String?
    /// Some of a folder couldn't be read: `size` counts only what could, and `itemCount` is nil.
    public var incomplete = false
    /// An S3 object's own facts.
    public var s3: S3Info?
}

/// What Find Files found.
public struct FoundItem: Equatable {
    public let path: String
    public let isFolder: Bool
}

/// Copy, move and run within a host, Get Info, folder sizes and Find Files. Paths are absolute.
/// Conflicts are checked by the caller first (`Names.existing` against the destination's listing), as for `rename`.
extension Session {
    /// Find Files: what is below `dir`, at any depth, whose name matches `pattern` (* ? [ ] as in the shell, in any
    /// case), sorted by path; at most `limit` of them (`truncated`: there were more). Shell hosts run one `find -iname`
    /// that prints each match with its kind, NUL-separated (so any name comes through), its output cut at 2 MB (which
    /// also ends a search for everything early); hosts without a shell are walked with the listing. Folders that can't
    /// be read are passed over. `found` gets the matches as they come (unsorted, on a background thread), so that a long
    /// search shows them, and keeps them when it is stopped. Cancelling the calling task stops it.
    public func find(_ pattern: String, in dir: String, limit: Int = 10_000,
                     found report: (([FoundItem]) -> Void)? = nil) async throws -> (items: [FoundItem], truncated: Bool) {
        var found: [FoundItem] = [], truncated = false
        // Each match is "d./path" or "f./path" (a folder or anything else) and a NUL.
        func item(_ record: Data.SubSequence) -> FoundItem? {
            guard record.count > 3, record.dropFirst().starts(with: [0x2E, 0x2F]) else { return nil }
            return FoundItem(path: RemotePath.join(dir, String(decoding: record.dropFirst(3), as: UTF8.self)),
                             isFolder: record.first == UInt8(ascii: "d"))
        }
        if capabilities.shell {
            let cap = 2 << 20
            let kinds = "for p do if [ -d \"$p\" ] && [ ! -L \"$p\" ]; then printf 'd%s\\0' \"$p\"; else printf 'f%s\\0' \"$p\"; fi; done"
            let script = "cd \(Quote.shell(dir)) && { find . -iname \(Quote.shell(pattern)) -exec sh -c \(Quote.shell(kinds)) sh {} + "
                + "2>/dev/null; true; } | head -c \(cap)"
            // As it comes: what follows the sentinel's marker, up to the last NUL so far.
            var pending = Data(), started = false
            let output = try await cancellable { cancellation in
                try await shellBytes(script, cancellation: cancellation, output: report.map { report in { chunk in
                    pending.append(chunk)
                    if !started, let marker = pending.range(of: Data("\n__AIRSCP__\n".utf8)) {
                        pending = pending.subdata(in: marker.upperBound..<pending.endIndex)
                        started = true
                    }
                    guard started, let end = pending.lastIndex(of: 0) else { return }
                    report(pending[..<end].split(separator: 0, omittingEmptySubsequences: false).compactMap(item))
                    pending = pending.subdata(in: (end + 1)..<pending.endIndex)
                } })
            }
            truncated = output.count >= cap
            // What follows the last NUL is nothing, or a match cut off.
            found = output.split(separator: 0, omittingEmptySubsequences: false).dropLast().compactMap(item)
        } else {
            var folders = [dir]
            walk: while let folder = folders.popLast() {
                try Task.checkCancellation()
                let entries: [RemoteEntry]
                do {
                    entries = try await list(folder)
                } catch let error as AirSCPError where folder != dir && error.kind != .cancelled && error.kind != .disconnected {
                    continue  // can't be read
                }
                let before = found.count
                for entry in entries {
                    if fnmatch(pattern, entry.name, FNM_CASEFOLD) == 0 {
                        found.append(FoundItem(path: entry.path, isFolder: entry.kind == .directory))
                        if found.count > limit { break walk }
                    }
                    if entry.kind == .directory { folders.append(entry.path) }
                }
                if found.count > before { report?(Array(found[before...])) }
            }
        }
        if found.count > limit {
            truncated = true
            found.removeLast(found.count - limit)
        }
        return (found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }, truncated)
    }

    /// Copies a file or folder to `newPath` (cp -R), across folders. Nothing may be at `newPath`: for Replace, delete
    /// what is there first (`delete`); for Keep both, use `Names.unique`. Shell hosts only (else `.sftpOnly`).
    public func copy(_ path: String, to newPath: String) async throws {
        if s3 != nil { return try await copyS3(path, to: newPath, keep: true) }
        do {
            try await unlessExists(newPath, "cp -R -- \(Quote.shell(path)) \(Quote.shell(newPath))")
        } catch let error as AirSCPError where error.kind != .failure && error.kind != .disconnected && error.kind != .cancelled {
            try? await deleteFolders([newPath], slot: .control)  // what cp copied before it failed
            throw error
        }
    }

    /// Copies (or moves) `path` over `newPath`, which is there (Replace): into a temporary copy in its folder first,
    /// which takes its place once complete, so that a copy that fails leaves the old item as it was. `folder`: either
    /// of them is a folder.
    public func copy(_ path: String, replacing newPath: String, folder: Bool, move: Bool) async throws {
        if s3 != nil { return try await replaceS3(newPath, with: path, move: move) }
        let part = RemotePath.join(RemotePath.parent(newPath), TransferQueue.partName(UUID()))
        if move { try await self.move(path, to: part) } else { try await copy(path, to: part) }
        do {
            try await moveIntoPlace(part, to: newPath, folder: folder, replacing: true, slot: .control)
        } catch {
            if move { try? await self.move(part, to: path) } else { try? await deleteFolders([part], slot: .control) }
            throw error
        }
    }

    public enum ChecksumAlgorithm: String, CaseIterable, Sendable {
        case sha256 = "SHA-256", sha1 = "SHA-1", md5 = "MD5"
    }

    /// A file's checksum in lower-case hex (Get Info): worked out on the server with whichever tool it
    /// has (GNU's or BusyBox's sha256sum/sha1sum/md5sum, Perl's shasum, the BSDs' sha256/sha1/md5); without a shell, from
    /// a temporary copy downloaded to this Mac (deleted afterwards). Cancelling the calling task stops it.
    public func checksum(_ path: String, _ algorithm: ChecksumAlgorithm) async throws -> String {
        if capabilities.shell {
            let file = Quote.shell(path)
            let (gnu, perl, bsd, length): (String, String, String, Int) = {
                switch algorithm {
                case .sha256: return ("sha256sum", "shasum -a 256", "sha256", 64)
                case .sha1: return ("sha1sum", "shasum -a 1", "sha1", 40)
                case .md5: return ("md5sum", "", "md5", 32)
                }
            }()
            var script = "if command -v \(gnu) >/dev/null 2>&1; then \(gnu) -- \(file); "
            if !perl.isEmpty { script += "elif command -v shasum >/dev/null 2>&1; then \(perl) -- \(file); " }
            script += "elif command -v \(bsd) >/dev/null 2>&1; then \(bsd) -q -- \(file); "
                + "else echo 'The server has no \(gnu) or \(bsd) to work out a checksum with.' >&2; exit 127; fi"
            let output = try await cancellable { cancellation in try await self.shell(script, cancellation: cancellation) }
            let hash = String(output.drop { $0 == "\\" }.prefix(length)).lowercased()
            guard hash.count == length, hash.allSatisfy(\.isHexDigit) else {
                throw AirSCPError(.other, "The server's checksum tool didn't answer with a checksum.", details: output)
            }
            return hash
        }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("AirSCP-checksum-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: copy) }
        if s3 != nil {
            try await fetchS3(path, to: copy, limit: nil, tooLarge: "")
        } else {
            _ = try await cancellable { cancellation in
                try await self.sftp(["get \(Quote.sftp(path)) \(Quote.sftp(copy.path))"], slot: .transfer, cancellation: cancellation)
            }
        }
        guard let file = FileHandle(forReadingAtPath: copy.path) else {
            throw AirSCPError(.other, "Can't read the temporary copy of \(RemotePath.name(path)).")
        }
        defer { try? file.close() }
        // A megabyte at a time: the file may be bigger than the memory.
        func digest<H: HashFunction>(_ hash: H) throws -> String {
            var hash = hash
            while let chunk = try file.read(upToCount: 1 << 20), !chunk.isEmpty { hash.update(data: chunk) }
            return hash.finalize().map { String(format: "%02x", $0) }.joined()
        }
        switch algorithm {
        case .sha256: return try digest(SHA256())
        case .sha1: return try digest(Insecure.SHA1())
        case .md5: return try digest(Insecure.MD5())
        }
    }

    /// A symbolic link at `path` to `target` (as typed: relative to the link's folder, or absolute). Nothing may be at
    /// `path`. `ln -s` on shell hosts, sftp's symlink without one.
    public func makeLink(_ path: String, to target: String) async throws {
        if capabilities.shell {
            try await unlessExists(path, "ln -s -- \(Quote.shell(target)) \(Quote.shell(path))")
        } else {
            guard try await !exists(path) else { throw AirSCPError(.failure, "\(RemotePath.name(path)) already exists there.") }
            try await sftp(["symlink \(Quote.sftp(target)) \(Quote.sftp(path))"])
        }
    }

    /// Moves a file or folder to `newPath`, which must not exist (as for `copy`): `mv` on shell hosts (also across
    /// file systems), sftp rename on sftp-only ones, where the server's "Failure" for another file system becomes
    /// "can't move across file systems".
    public func move(_ path: String, to newPath: String) async throws {
        if s3 != nil { return try await copyS3(path, to: newPath, keep: false) }
        if capabilities.shell {
            try await unlessExists(newPath, "mv -- \(Quote.shell(path)) \(Quote.shell(newPath))")
            return
        }
        do {
            try await rename(path, to: newPath)
        } catch let error as AirSCPError where error.kind == .failure {
            throw AirSCPError(.failure, "Can't move \(RemotePath.name(path)) there: this server can't move items across "
                + "file systems.", details: error.details)
        }
    }

    /// The command that runs a file in its folder: `cd <folder> && ./<name> <arguments>`, the arguments as typed (the
    /// shell expands them). For Run (`run(_:)`, whose sheet shows output, errors and exit status) and Run in Terminal.
    /// "Make executable" is `setPermissions(entry, mode: entry.mode | 0o111)`.
    public static func executeCommand(_ path: String, arguments: String = "") -> String {
        let command = "cd \(Quote.shell(RemotePath.parent(path))) && ./\(Quote.shell(RemotePath.name(path)))"
        return arguments.allSatisfy(\.isWhitespace) ? command : command + " " + arguments
    }

    /// Get Info. Shell hosts: GNU `stat -c` (else BSD `stat -f`), `file -b` (a link is described as a link), for
    /// folders `du -sk` and `find | wc -l`, for links `readlink`; sftp-only hosts: the entry's listing details.
    /// Cancelling the calling task stops it.
    public func info(_ entry: RemoteEntry) async throws -> RemoteInfo {
        if s3 != nil { return try await infoS3(entry) }
        guard capabilities.shell else {
            return RemoteInfo(path: entry.path, kind: nil, size: entry.kind == .directory ? nil : entry.size, itemCount: nil,
                              mode: entry.mode, owner: entry.owner, group: entry.group, modified: entry.modified,
                              accessed: nil, changed: nil, linkTarget: nil)
        }
        // One labelled line per fact. Owner and group get lines of their own (names may have spaces); stat is GNU or
        // BusyBox (-c) when it understands -c, else BSD (-f).
        let script = "p=\(Quote.shell(entry.path)); if [ ! -e \"$p\" ] && [ ! -L \"$p\" ]; then "
            + "printf '%s: No such file or directory\\n' \"$p\" >&2; false; else "
            + "printf 'kind=%s\\n' \"$(file -b -h -- \"$p\" 2>/dev/null)\"; "
            + "if stat -c %s / >/dev/null 2>&1; then "
            + "printf 'stat=%s\\n' \"$(stat -c '%a %s %Y %X %Z' -- \"$p\")\"; "
            + "printf 'owner=%s\\n' \"$(stat -c %U -- \"$p\")\"; printf 'group=%s\\n' \"$(stat -c %G -- \"$p\")\"; "
            + "else printf 'stat=%s\\n' \"$(stat -f '%Mp%Lp %z %m %a %c' -- \"$p\")\"; "
            + "printf 'owner=%s\\n' \"$(stat -f %Su -- \"$p\")\"; printf 'group=%s\\n' \"$(stat -f %Sg -- \"$p\")\"; fi; "
            + "if [ -L \"$p\" ]; then printf 'link=%s\\n' \"$(readlink -- \"$p\")\"; "
            + "elif [ -d \"$p\" ]; then \(Session.du) if k=$($du -- \"$p\" 2>/dev/null); then :; else echo partial=1; fi; "
            + "printf 'du=%s %s\\n' \"${k%%[!0-9]*}\" \"$unit\"; "
            + "printf 'count=%s\\n' \"$(find \"$p\" 2>/dev/null | wc -l)\"; fi; fi"
        let output = try await cancellable { try await shell(script, cancellation: $0) }
        var facts: [String: String] = [:]
        for line in output.split(separator: "\n") {
            guard let equals = line.firstIndex(of: "="), facts[String(line[..<equals])] == nil else { continue }
            facts[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        let stat = (facts["stat"] ?? "").split(separator: " ").map(String.init)
        guard stat.count == 5, let mode = Int(stat[0], radix: 8) else {
            throw AirSCPError(.other, "The server didn't describe \(entry.name).", details: output)
        }
        func date(_ text: String) -> Date? { Int64(text).map { Date(timeIntervalSince1970: TimeInterval($0)) } }
        let du = (facts["du"] ?? "").split(separator: " ").compactMap { Int64($0) }
        let folderBytes = du.count == 2 ? du[0] * du[1] : nil
        let incomplete = facts["partial"] == "1"
        let count = incomplete ? nil : facts["count"].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        var info = RemoteInfo(path: entry.path, kind: facts["kind"].flatMap { $0.isEmpty ? nil : $0 },
                              size: facts["count"] != nil ? folderBytes : Int64(stat[1]), itemCount: count.map { max(0, $0 - 1) },
                              mode: mode, owner: facts["owner"] ?? entry.owner, group: facts["group"] ?? entry.group,
                              modified: date(stat[2]), accessed: date(stat[3]), changed: date(stat[4]),
                              linkTarget: facts["link"])
        info.incomplete = incomplete
        return info
    }

    /// Calculate Folder Sizes: bytes per name, for the folders `names` in `dir` (`cd <dir> && du -sk -- 'n1' 'n2' …`
    /// with the names from the listing, never a glob). Names du couldn't measure are left out. Shell hosts only (else
    /// `.sftpOnly`). Many names go in several commands (a command line has a size limit); cancelling the calling task
    /// stops it.
    public func folderSizes(_ names: [String], in dir: String) async throws -> [String: Int64] {
        try requireShell()
        var sizes: [String: Int64] = [:]
        var batch: [String] = [], length = 0
        for (index, name) in names.enumerated() {
            batch.append(Quote.shell(name))
            length += Quote.shell(batch[batch.count - 1]).utf8.count  // quoted again by the sentinel
            guard length > 60_000 || index == names.count - 1 else { continue }
            let script = "cd \(Quote.shell(dir)) && { \(Session.du) echo \"unit=$unit\"; $du -- \(batch.joined(separator: " ")) 2>/dev/null; true; }"
            let output = try await cancellable { try await shell(script, cancellation: $0) }
            var unit: Int64 = 1024
            for line in output.split(separator: "\n") {
                if line.hasPrefix("unit=") { unit = Int64(line.dropFirst(5)) ?? 1024 }
                guard let tab = line.firstIndex(of: "\t"), let amount = Int64(line[..<tab]) else { continue }
                sizes[String(line[line.index(after: tab)...])] = amount * unit
            }
            batch = []
            length = 0
        }
        return sizes
    }

    /// Sets $du to a du command for one total per operand, of the files' sizes where du can tell them (GNU: bytes; BSD:
    /// kilobytes, -A), like a selection's status line adds them up; else (BusyBox) their space on disk in kilobytes.
    /// $unit is bytes per unit.
    /// BSD du gets a UTF-8 locale: without one (as over ssh) macOS 27's prints "é" as one Latin-1 byte.
    static let du = "if du --version 2>/dev/null | grep -q GNU; then du='du -s --apparent-size --block-size=1'; unit=1; "
        + "else case $(uname -s) in Darwin|*BSD) du='env LC_CTYPE=UTF-8 du -s -A -k';; *) du='du -s -k';; esac; unit=1024; fi;"

    /// Runs `command` unless something is at `path` (cp and mv would put the item inside a folder that is there).
    private func unlessExists(_ path: String, _ command: String) async throws {
        let target = Quote.shell(path)
        do {
            try await shell("if [ -e \(target) ] || [ -L \(target) ]; then echo '__AIRSCP_EXISTS__' >&2; false; "
                + "else \(command); fi")
        } catch let error as AirSCPError where error.details.contains("__AIRSCP_EXISTS__") {
            throw AirSCPError(.failure, "\(RemotePath.name(path)) already exists there.")
        }
    }
}
