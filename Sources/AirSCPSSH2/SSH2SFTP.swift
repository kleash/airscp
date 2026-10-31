import AirSCPCore
import CSSH2
import Foundation

/// A batch line that failed, in sftp's words (they go to the error output, where `ErrorMapping` reads them).
struct SFTPFailure: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// sftp's batch mode (`sftp -b -`) over libssh2's SFTP: the commands AirSCPCore writes (cd, pwd, ls, df, mkdir, rmdir,
/// rm, rename, chmod, symlink, get, put), with sftp's output and error lines, so that RemoteFS reads them as it reads
/// sftp's.
extension Connection {
    func sftpBatch(_ lines: [String], cancellation: Cancellation) throws -> CommandResult {
        try startSFTP(cancellation)
        // Every batch starts in sftp's starting folder.
        var folder = try realPath(".", cancellation)
        var output = Data()
        var errors = ""
        for line in lines {
            output.append(Data("sftp> \(line)\n".utf8))
            let ignoreFailure = line.hasPrefix("-")
            do {
                try run(ignoreFailure ? String(line.dropFirst()) : line, in: &folder, output: &output, cancellation)
            } catch let failure as SFTPFailure {
                errors += failure.message + "\n"
                if !ignoreFailure { return CommandResult(status: 1, stdout: output, stderr: errors) }
            }
        }
        return CommandResult(status: 0, stdout: output, stderr: errors)
    }

    /// The session's SFTP channel, opened at its first use.
    func startSFTP(_ cancellation: Cancellation?) throws {
        guard sftp == nil else { return }
        guard let opened = try opened(cancellation, { libssh2_sftp_init(session) }) else {
            throw failure(libssh2_session_last_errno(session), "Starting sftp")
        }
        sftp = opened
    }

    private func run(_ line: String, in folder: inout String, output: inout Data, _ cancellation: Cancellation) throws {
        guard var words = Self.words(line) else { throw SFTPFailure("Unterminated quote") }
        guard !words.isEmpty else { return }
        let command = words.removeFirst()
        var flags = ""
        if ["ls", "get", "put", "df"].contains(command) {
            while let flag = words.first, flag.hasPrefix("-"), flag.count > 1 {
                flags += flag.dropFirst()
                words.removeFirst()
            }
        }
        let current = folder
        func path(_ index: Int) throws -> String {
            guard index < words.count else { throw SFTPFailure("\(command): missing argument") }
            let path = words[index]
            return path.hasPrefix("/") ? path : (current == "/" ? "/" : current + "/") + path
        }
        switch command {
        case "progress":
            break
        case "pwd":
            output.append(Data("Remote working directory: \(folder)\n".utf8))
        case "cd":
            let target = try realPath(try path(0), cancellation)
            guard let attributes = try attributes(target, follow: true, cancellation), isFolder(attributes) else {
                throw SFTPFailure("Can't change directory: \"\(target)\" is not a directory")
            }
            folder = target
        case "ls":
            try list(words.isEmpty ? nil : try path(0), in: folder, all: flags.contains("a"), output: &output, cancellation)
        case "df":
            try diskFree(words.isEmpty ? folder : try path(0), output: &output, cancellation)
        case "mkdir":
            let target = try path(0)
            try check(again(cancellation) { libssh2_sftp_mkdir_ex(sftp, target, UInt32(target.utf8.count), 0o777) },
                      "remote mkdir \"\(target)\"")
        case "rmdir":
            let target = try path(0)
            try check(again(cancellation) { libssh2_sftp_rmdir_ex(sftp, target, UInt32(target.utf8.count)) },
                      "remote rmdir \"\(target)\"")
        case "rm":
            let target = try path(0)
            try check(again(cancellation) { libssh2_sftp_unlink_ex(sftp, target, UInt32(target.utf8.count)) },
                      "remote delete \(target)")
        case "rename":
            let (old, new) = (try path(0), try path(1))
            // sftp renames with OpenSSH's posix-rename (it replaces what has the new name), else the plain way.
            var rc = try again(cancellation) {
                libssh2_sftp_posix_rename_ex(sftp, old, old.utf8.count, new, new.utf8.count)
            }
            if rc == LIBSSH2_ERROR_SFTP_PROTOCOL && libssh2_sftp_last_error(sftp) == LIBSSH2_FX_OP_UNSUPPORTED {
                rc = try again(cancellation) {
                    libssh2_sftp_rename_ex(sftp, old, UInt32(old.utf8.count), new, UInt32(new.utf8.count), 0)
                }
            }
            try check(rc, "remote rename \"\(old)\" to \"\(new)\"")
        case "chmod":
            guard let mode = words.first.flatMap({ UInt($0, radix: 8) }) else { throw SFTPFailure("chmod: invalid mode") }
            let target = try path(1)
            var attributes = LIBSSH2_SFTP_ATTRIBUTES()
            attributes.flags = UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS)
            attributes.permissions = mode
            try check(again(cancellation) {
                libssh2_sftp_stat_ex(sftp, target, UInt32(target.utf8.count), LIBSSH2_SFTP_SETSTAT, &attributes)
            }, "remote setstat \"\(target)\"")
        case "symlink":
            // The link's target as given (it may be relative to the link), first; the link where sftp puts it.
            guard let linkTarget = words.first else { throw SFTPFailure("symlink: missing argument") }
            let link = try path(1)
            var buffer = Array(link.utf8CString)
            try check(again(cancellation) {
                libssh2_sftp_symlink_ex(sftp, linkTarget, UInt32(linkTarget.utf8.count), &buffer, UInt32(link.utf8.count),
                                        LIBSSH2_SFTP_SYMLINK)
            }, "remote symlink \"\(linkTarget)\" to \"\(link)\"")
        case "get":
            guard words.count == 2 else { throw SFTPFailure("get: give a remote and a local file") }
            try download(try path(0), to: words[1], preserve: flags.contains("p"), cancellation)
        case "put":
            guard words.count == 2 else { throw SFTPFailure("put: give a local and a remote file") }
            try upload(words[0], to: try path(1), preserve: flags.contains("p"), cancellation)
        default:
            throw SFTPFailure("Invalid command.")
        }
    }

    // MARK: Listing

    /// sftp's `ls -l`: a folder's entries (`all`: with dot files) sorted by name, each as the server writes the line;
    /// any other item as one line ending in its path, which for a link describes what it points to (nothing for a
    /// link to nothing).
    private func list(_ path: String?, in folder: String, all: Bool, output: inout Data, _ cancellation: Cancellation) throws {
        guard let path else { return try listFolder(folder, all: all, output: &output, cancellation) }
        guard let attributes = try attributes(path, follow: true, cancellation) else {
            if try self.attributes(path, follow: false, cancellation) != nil { return }
            throw SFTPFailure("Can't ls: \"\(path)\" not found")
        }
        if isFolder(attributes) { return try listFolder(path, all: all, output: &output, cancellation) }
        // The server's line for what it is (owner and group by name), from that folder's listing, else one made here.
        let real = (try? realPath(path, cancellation)) ?? path
        let name = Data(RemotePath.name(real).utf8)
        let entry = (try? entries(of: RemotePath.parent(real), cancellation))?.first { $0.name == name }
        let line = entry.map { Data($0.line.dropLast(name.count)) + Data(path.utf8) }
        output.append((line ?? Self.line(path: Data(path.utf8), attributes)) + Data("\n".utf8))
    }

    private func listFolder(_ folder: String, all: Bool, output: inout Data, _ cancellation: Cancellation) throws {
        for entry in try entries(of: folder, cancellation).sorted(by: { $0.name.lexicographicallyPrecedes($1.name) })
        where all || entry.name.first != UInt8(ascii: ".") {
            output.append(entry.line + Data("\n".utf8))
        }
    }

    private func entries(of folder: String, _ cancellation: Cancellation) throws -> [(name: Data, line: Data)] {
        let what = "remote readdir(\"\(folder)\")"
        guard let handle = try opened(cancellation, {
            libssh2_sftp_open_ex(sftp, folder, UInt32(folder.utf8.count), 0, 0, LIBSSH2_SFTP_OPENDIR)
        }) else { throw error(Int32(libssh2_session_last_errno(session)), what) }
        defer { _ = try? again(nil) { libssh2_sftp_close_handle(handle) } }
        var entries: [(name: Data, line: Data)] = []
        var name = [CChar](repeating: 0, count: 4096), long = [CChar](repeating: 0, count: 4096)
        var attributes = LIBSSH2_SFTP_ATTRIBUTES()
        while true {
            let count = try again(cancellation) {
                libssh2_sftp_readdir_ex(handle, &name, name.count, &long, long.count, &attributes)
            }
            if count == 0 { break }
            try check(count, what)
            let entryName = Data(bytes: name, count: Int(count))
            let line = strlen(long) > 0 ? Data(bytes: long, count: strlen(long)) : Self.line(path: entryName, attributes)
            entries.append((entryName, line))
        }
        return entries
    }

    /// An `ls -l` line made from an item's attributes, as sftp makes one (owner and group as numbers).
    private static func line(path: Data, _ attributes: LIBSSH2_SFTP_ATTRIBUTES) -> Data {
        let mode = attributes.permissions
        let types: [UInt: Character] = [UInt(LIBSSH2_SFTP_S_IFDIR): "d", UInt(LIBSSH2_SFTP_S_IFLNK): "l",
                                        UInt(LIBSSH2_SFTP_S_IFCHR): "c", UInt(LIBSSH2_SFTP_S_IFBLK): "b",
                                        UInt(LIBSSH2_SFTP_S_IFIFO): "p", UInt(LIBSSH2_SFTP_S_IFSOCK): "s"]
        var text = String(types[mode & UInt(LIBSSH2_SFTP_S_IFMT)] ?? "-")
        for (index, letter) in "rwxrwxrwx".enumerated() {
            text.append(mode & (0o400 >> UInt(index)) != 0 ? letter : "-")
        }
        var time = time_t(attributes.mtime)
        var parts = tm()
        localtime_r(&time, &parts)
        var date = [CChar](repeating: 0, count: 32)
        let recent = abs(Date().timeIntervalSince1970 - Double(attributes.mtime)) < 182 * 24 * 3600
        strftime(&date, date.count, recent ? "%b %e %H:%M" : "%b %e  %Y", &parts)
        let fields = "\(text)    1 \(attributes.uid) \(attributes.gid) \(attributes.filesize) \(String(cString: date)) "
        return Data(fields.utf8) + path
    }

    private func diskFree(_ path: String, output: inout Data, _ cancellation: Cancellation) throws {
        var stats = LIBSSH2_SFTP_STATVFS()
        try check(again(cancellation) { libssh2_sftp_statvfs(sftp, path, path.utf8.count, &stats) }, "statvfs \"\(path)\"")
        let kilobytes = { (blocks: UInt64) in stats.f_frsize * blocks / 1024 }
        let capacity = stats.f_blocks == 0 ? 0 : 100 * (stats.f_blocks - stats.f_bfree) / stats.f_blocks
        func column(_ value: CustomStringConvertible, _ width: Int) -> String {
            String(repeating: " ", count: max(0, width - value.description.count)) + value.description
        }
        let header = [column("Size", 12), column("Used", 12), column("Avail", 12), column("(root)", 12), column("%Capacity", 10)]
        let values = [column(kilobytes(stats.f_blocks), 12), column(kilobytes(stats.f_blocks - stats.f_bfree), 12),
                      column(kilobytes(stats.f_bavail), 12), column(kilobytes(stats.f_bfree), 12), column(capacity, 9) + "%"]
        output.append(Data((header.joined(separator: " ") + "\n" + values.joined(separator: " ") + "\n").utf8))
    }

    // MARK: Files

    private func download(_ remote: String, to local: String, preserve: Bool, _ cancellation: Cancellation) throws {
        guard let attributes = try attributes(remote, follow: true, cancellation) else {
            throw SFTPFailure("remote stat \"\(remote)\": No such file or directory")
        }
        guard attributes.permissions & UInt(LIBSSH2_SFTP_S_IFMT) == UInt(LIBSSH2_SFTP_S_IFREG) else {
            throw SFTPFailure("Cannot download non-regular file: \(remote)")
        }
        guard let handle = try opened(cancellation, {
            libssh2_sftp_open_ex(sftp, remote, UInt32(remote.utf8.count), UInt(LIBSSH2_FXF_READ), 0, LIBSSH2_SFTP_OPENFILE)
        }) else { throw error(Int32(libssh2_session_last_errno(session)), "remote open(\"\(remote)\")") }
        defer { _ = try? again(nil) { libssh2_sftp_close_handle(handle) } }
        let file = Darwin.open(local, O_WRONLY | O_CREAT | O_TRUNC, mode_t(attributes.permissions & 0o777 | 0o200))
        guard file >= 0 else {
            throw SFTPFailure("Couldn't open local file \"\(local)\" for writing: \(String(cString: strerror(errno)))")
        }
        defer { Darwin.close(file) }
        var buffer = [CChar](repeating: 0, count: 65536)
        while true {
            let count = try again(cancellation) { libssh2_sftp_read(handle, &buffer, buffer.count) }
            if count == 0 { break }
            try check(count, "read remote \"\(remote)\"")
            var offset = 0
            while offset < count {
                let written = buffer.withUnsafeBytes { Darwin.write(file, $0.baseAddress! + offset, count - offset) }
                guard written > 0 else { throw SFTPFailure("write local \"\(local)\": \(String(cString: strerror(errno)))") }
                offset += written
            }
        }
        if preserve {
            fchmod(file, mode_t(attributes.permissions & 0o7777))
            var times = [timeval(tv_sec: time_t(attributes.atime), tv_usec: 0), timeval(tv_sec: time_t(attributes.mtime), tv_usec: 0)]
            futimes(file, &times)
        }
    }

    private func upload(_ local: String, to remote: String, preserve: Bool, _ cancellation: Cancellation) throws {
        let file = Darwin.open(local, O_RDONLY)
        guard file >= 0 else {
            throw SFTPFailure("Couldn't open local file \"\(local)\" for reading: \(String(cString: strerror(errno)))")
        }
        defer { Darwin.close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw SFTPFailure("\(local) is not a regular file") }
        let flags = UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | LIBSSH2_FXF_TRUNC)
        guard let handle = try opened(cancellation, {
            libssh2_sftp_open_ex(sftp, remote, UInt32(remote.utf8.count), flags, Int(info.st_mode & 0o777), LIBSSH2_SFTP_OPENFILE)
        }) else { throw error(Int32(libssh2_session_last_errno(session)), "remote open(\"\(remote)\")") }
        defer { _ = try? again(nil) { libssh2_sftp_close_handle(handle) } }
        var buffer = [CChar](repeating: 0, count: 65536)
        while true {
            let count = Darwin.read(file, &buffer, buffer.count)
            guard count >= 0 else { throw SFTPFailure("read local \"\(local)\": \(String(cString: strerror(errno)))") }
            if count == 0 { break }
            var offset = 0
            while offset < count {
                let written = try again(cancellation) {
                    buffer.withUnsafeBufferPointer { libssh2_sftp_write(handle, $0.baseAddress! + offset, count - offset) }
                }
                try check(written, "write remote \"\(remote)\"")
                offset += written
            }
        }
        if preserve {
            var attributes = LIBSSH2_SFTP_ATTRIBUTES()
            attributes.flags = UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS | LIBSSH2_SFTP_ATTR_ACMODTIME)
            attributes.permissions = UInt(info.st_mode & 0o7777)
            attributes.atime = UInt(info.st_atimespec.tv_sec)
            attributes.mtime = UInt(info.st_mtimespec.tv_sec)
            try check(again(cancellation) {
                libssh2_sftp_fstat_ex(handle, &attributes, 1)
            }, "remote fsetstat \"\(remote)\"")
        }
    }

    // MARK: Requests

    private func realPath(_ path: String, _ cancellation: Cancellation) throws -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = try again(cancellation) {
            libssh2_sftp_symlink_ex(sftp, path, UInt32(path.utf8.count), &buffer, UInt32(buffer.count), LIBSSH2_SFTP_REALPATH)
        }
        try check(count, "realpath \(path)")
        return String(decoding: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// An item's attributes (`follow`: a link's target's), nil when there is nothing at `path`.
    func attributes(_ path: String, follow: Bool, _ cancellation: Cancellation?) throws -> LIBSSH2_SFTP_ATTRIBUTES? {
        var attributes = LIBSSH2_SFTP_ATTRIBUTES()
        let rc = try again(cancellation) {
            libssh2_sftp_stat_ex(sftp, path, UInt32(path.utf8.count), follow ? LIBSSH2_SFTP_STAT : LIBSSH2_SFTP_LSTAT, &attributes)
        }
        if rc == LIBSSH2_ERROR_SFTP_PROTOCOL && libssh2_sftp_last_error(sftp) == LIBSSH2_FX_NO_SUCH_FILE { return nil }
        try check(rc, "remote stat \"\(path)\"")
        return attributes
    }

    private func isFolder(_ attributes: LIBSSH2_SFTP_ATTRIBUTES) -> Bool {
        attributes.permissions & UInt(LIBSSH2_SFTP_S_IFMT) == UInt(LIBSSH2_SFTP_S_IFDIR)
    }

    /// Throws for a failed request (`rc` < 0).
    func check<T: BinaryInteger>(_ rc: T, _ what: String) throws {
        if rc < 0 { throw error(Int32(rc), what) }
    }

    /// The server's answer as sftp words it ("remote mkdir "/a": Permission denied"), or the connection's failure.
    func error(_ rc: Int32, _ what: String) -> Error {
        guard rc == LIBSSH2_ERROR_SFTP_PROTOCOL else { return failure(rc, what) }
        let messages = ["Success", "End of file", "No such file or directory", "Permission denied", "Failure", "Bad message",
                        "No connection", "Connection lost", "Operation unsupported"]
        let code = Int(libssh2_sftp_last_error(sftp))
        return SFTPFailure("\(what): " + (code < messages.count ? messages[code] : "Unknown status \(code)"))
    }

    /// A batch line's words, as sftp splits them: "double" or 'single' quotes, a backslash escapes the next character
    /// (not inside single quotes). nil when a quote isn't closed.
    static func words(_ line: String) -> [String]? {
        var words: [String] = []
        var word = "", inWord = false, quote: Character?, escaped = false
        for character in line {
            if escaped {
                word.append(character)
                escaped = false
            } else if character == "\\" && quote != "'" {
                escaped = true
                inWord = true
            } else if let open = quote {
                if character == open { quote = nil } else { word.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                inWord = true
            } else if character == " " || character == "\t" {
                if inWord { words.append(word) }
                word = ""
                inWord = false
            } else {
                word.append(character)
                inWord = true
            }
        }
        guard quote == nil && !escaped else { return nil }
        if inWord { words.append(word) }
        return words
    }
}
