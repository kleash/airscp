import AirSCPCore
import CSSH2
import Foundation

/// The transfer queue's copies over libssh2's SFTP (`RemoteTransport.copy`), a step at a time on the transport's queue
/// (an open, what has arrived, a close), so that listings and commands go on in between. In a folder, symbolic links stay
/// links, as AirSCP's tar streams keep them; the item itself, when it is a link, is copied as what it points to, as scp
/// does.
extension SSH2Transport {
    public func copy(upload: Bool, local: String, remote: String, resume: Bool, preserveTimes: Bool, limit: Int?,
                     cancellation: Cancellation, progress: @escaping (TransferProgress) -> Void) async throws
        -> (resumedFrom: Int64, leftOut: [String]) {
        let target = try await onQueue { [self] in
            let target = try connection()
            try target.startSFTP(nil)
            return target
        }
        let copy = Copy(transport: self, connection: target, preserveTimes: preserveTimes, limit: limit,
                        cancellation: cancellation, report: progress)
        do {
            let resumedFrom = upload ? try await copy.upload(local, to: remote, resume: resume)
                : try await copy.download(remote, to: local, resume: resume)
            return (resumedFrom, copy.leftOut)
        } catch let failure as SFTPFailure {
            throw ErrorMapping.map(failure.message, status: 1)
        }
    }
}

/// One `copy`: how far it has got, and its steps. Within a folder, an item that fails in sftp's words is left out (and
/// named); a lost connection or a cancel stops it all.
private final class Copy {
    let transport: SSH2Transport
    let connection: Connection
    let preserveTimes: Bool
    let limit: Int?
    let cancellation: Cancellation
    let report: (TransferProgress) -> Void
    /// What a step reads or keeps in flight at most: a megabyte, or under a speed limit a quarter of a second's worth (so
    /// that progress and speed move smoothly).
    let chunk: Int
    var progress = TransferProgress()
    var leftOut: [String] = []
    /// Bytes this run has copied (not what a resumed file had), since `started`: for the speed limit.
    private var sent: Int64 = 0
    private let started = Date()

    init(transport: SSH2Transport, connection: Connection, preserveTimes: Bool, limit: Int?, cancellation: Cancellation,
         report: @escaping (TransferProgress) -> Void) {
        (self.transport, self.connection, self.preserveTimes, self.limit) = (transport, connection, preserveTimes, limit)
        (self.cancellation, self.report) = (cancellation, report)
        chunk = limit.map { min(1 << 20, max(16 << 10, $0 / 4)) } ?? 1 << 20
    }

    /// `body` on the transport's queue, while `connection` is still its connection (after a reconnect another one is,
    /// which these handles aren't of).
    private func step<T>(_ body: @escaping (Connection) throws -> T) async throws -> T {
        try await transport.onQueue { [transport, connection] in
            guard try transport.connection() === connection else { throw AirSCPError.disconnected }
            return try body(connection)
        }
    }

    private func checkCancelled() throws {
        if cancellation.isCancelled { throw AirSCPError.cancelled }
    }

    /// `count` more bytes copied: reported, then held back to the speed limit.
    private func advance(_ count: Int) async throws {
        progress.bytes += Int64(count)
        sent += Int64(count)
        report(progress)
        guard let limit, limit > 0 else { return }
        while true {
            let ahead = Double(sent) / Double(limit) - Date().timeIntervalSince(started)
            if ahead <= 0 { return }
            try checkCancelled()
            try? await Task.sleep(nanoseconds: UInt64(min(ahead, 0.1) * 1e9))
        }
    }

    /// An item of a folder: copied, or (failing in sftp's words) left out and named.
    private func item(_ body: () async throws -> Void) async throws {
        try checkCancelled()
        do {
            try await body()
        } catch let failure as SFTPFailure {
            leftOut.append(failure.message)
        }
    }

    // MARK: Uploads

    /// The item at `local` (what a link points to) to `remote`. Where a resumed file continued from.
    func upload(_ local: String, to remote: String, resume: Bool) async throws -> Int64 {
        var info = stat()
        guard stat(local, &info) == 0 else {
            throw SFTPFailure("stat local \"\(local)\": \(String(cString: strerror(errno)))")
        }
        switch info.st_mode & S_IFMT {
        case S_IFDIR:
            try await uploadFolder(local, to: remote, info)
            return 0
        case S_IFREG:
            return try await uploadFile(local, to: remote, resume: resume, single: true)
        default:
            throw SFTPFailure("\(local) is not a regular file")  // (opening a pipe would wait for a writer)
        }
    }

    private func uploadFolder(_ local: String, to remote: String, _ info: stat) async throws {
        try await step { try $0.makeFolder(remote, mode: Int(info.st_mode & 0o777)) }
        let names: [String]
        do {
            names = try FileManager.default.contentsOfDirectory(atPath: local).sorted()
        } catch {
            throw SFTPFailure("opendir local \"\(local)\": \(error.localizedDescription)")
        }
        for name in names {
            let from = local + "/" + name, to = RemotePath.join(remote, name)
            try await item {
                var info = stat()
                guard lstat(from, &info) == 0 else { throw SFTPFailure("local lstat \"\(from)\": \(String(cString: strerror(errno)))") }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    try await uploadFolder(from, to: to, info)
                case S_IFLNK:
                    guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: from) else {
                        throw SFTPFailure("readlink local \"\(from)\": \(String(cString: strerror(errno)))")
                    }
                    try await step { try $0.makeLink(to, pointingTo: target) }
                case S_IFREG:
                    _ = try await uploadFile(from, to: to, resume: false, single: false)
                default:
                    throw SFTPFailure("\(from) is not a regular file")
                }
            }
        }
        if preserveTimes {
            try await step { try $0.setAttributes(of: remote, handle: nil, info) }
        }
    }

    /// `single`: the job's only file, whose size is its total.
    private func uploadFile(_ local: String, to remote: String, resume: Bool, single: Bool) async throws -> Int64 {
        let file = open(local, O_RDONLY | O_CLOEXEC)
        guard file >= 0 else {
            throw SFTPFailure("Couldn't open local file \"\(local)\" for reading: \(String(cString: strerror(errno)))")
        }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw SFTPFailure("\(local) is not a regular file") }
        let size = Int64(info.st_size)
        // sftp's reput: the server's partial copy, when it is smaller, continues from its size.
        var offset: Int64 = 0
        if resume, let there = try await step({ try $0.attributes(remote, follow: true, nil) }),
           there.flags & UInt(LIBSSH2_SFTP_ATTR_SIZE) != 0, Int64(there.filesize) < size {
            offset = Int64(there.filesize)
            guard lseek(file, off_t(offset), SEEK_SET) == offset else {
                throw SFTPFailure("seek local \"\(local)\": \(String(cString: strerror(errno)))")
            }
        }
        let handle = try await step { [offset] in
            try $0.openFile(remote, write: true, from: offset, mode: Int(info.st_mode & 0o777))
        }
        do {
            if single { progress.total = size }
            progress.file = RemotePath.name(local)
            progress.bytes += offset
            report(progress)
            // libssh2 keeps sending what it was given and says how much the server has taken: up to a megabyte stays in
            // flight, each step passing what isn't taken yet, with more read once it runs low.
            var pending: [UInt8] = [], start = 0, ended = false
            var buffer = [UInt8](repeating: 0, count: chunk)
            while true {
                try checkCancelled()
                if !ended && pending.count - start < chunk / 2 {
                    pending.removeFirst(start)
                    start = 0
                    let count = read(file, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    guard count >= 0 else { throw SFTPFailure("read local \"\(local)\": \(String(cString: strerror(errno)))") }
                    if count == 0 { ended = true } else { pending += buffer[..<count] }
                }
                if start == pending.count {
                    if ended { break } else { continue }
                }
                let unsent = pending[start...]
                let taken = try await step { [cancellation] in try $0.write(handle, unsent, remote, cancellation) }
                start += taken
                try await advance(taken)
            }
            if preserveTimes {
                try await step { try $0.setAttributes(of: remote, handle: handle, info) }
            }
        } catch {
            _ = try? await step { try $0.closeFile(handle, remote) }
            throw error
        }
        try await step { try $0.closeFile(handle, remote) }  // a server may say only now that it couldn't write
        progress.filesDone += 1
        report(progress)
        return offset
    }

    // MARK: Downloads

    /// The item at `remote` (what a link points to) to `local`. Where a resumed file continued from.
    func download(_ remote: String, to local: String, resume: Bool) async throws -> Int64 {
        guard let attributes = try await step({ try $0.attributes(remote, follow: true, nil) }) else {
            throw SFTPFailure("remote stat \"\(remote)\": No such file or directory")
        }
        switch attributes.permissions & UInt(LIBSSH2_SFTP_S_IFMT) {
        case UInt(LIBSSH2_SFTP_S_IFDIR):
            try await downloadFolder(remote, to: local, attributes)
            return 0
        case UInt(LIBSSH2_SFTP_S_IFREG):
            progress.total = Int64(attributes.filesize)
            return try await downloadFile(remote, to: local, attributes, resume: resume, fresh: false)
        default:
            throw SFTPFailure("Cannot download non-regular file: \(remote)")
        }
    }

    private func downloadFolder(_ remote: String, to local: String, _ attributes: LIBSSH2_SFTP_ATTRIBUTES) async throws {
        guard mkdir(local, mode_t(attributes.permissions & 0o777 | 0o700)) == 0 else {
            throw SFTPFailure(errno == EEXIST ? Copy.clash(local)
                              : "Couldn't create local folder \"\(local)\": \(String(cString: strerror(errno)))")
        }
        for (name, child) in try await step({ try $0.children(of: remote) }) {
            let from = RemotePath.join(remote, name), to = local + "/" + name
            try await item {
                switch child.permissions & UInt(LIBSSH2_SFTP_S_IFMT) {
                case UInt(LIBSSH2_SFTP_S_IFDIR):
                    try await downloadFolder(from, to: to, child)
                case UInt(LIBSSH2_SFTP_S_IFLNK):
                    let target = try await step { try $0.readLink(from) }
                    guard symlink(target, to) == 0 else {
                        throw SFTPFailure(errno == EEXIST ? Copy.clash(to)
                                          : "Couldn't create local link \"\(to)\": \(String(cString: strerror(errno)))")
                    }
                case UInt(LIBSSH2_SFTP_S_IFREG):
                    _ = try await downloadFile(from, to: to, child, resume: false, fresh: true)
                default:
                    throw SFTPFailure("\(from) is not a regular file")
                }
            }
        }
        if preserveTimes { Copy.setTimes(local, attributes) }
    }

    /// `fresh`: an item of a folder, a new name there (a name that is taken differs only in case or accents, on a disk
    /// that keeps one of them).
    private func downloadFile(_ remote: String, to local: String, _ attributes: LIBSSH2_SFTP_ATTRIBUTES, resume: Bool,
                              fresh: Bool) async throws -> Int64 {
        // sftp's reget: the partial copy here, when it is smaller, continues from its size.
        var offset: Int64 = 0
        var info = stat()
        if resume, lstat(local, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size > 0,
           UInt64(info.st_size) < attributes.filesize {
            offset = Int64(info.st_size)
        }
        let flags = O_WRONLY | O_CREAT | O_CLOEXEC | (offset > 0 ? O_APPEND : O_TRUNC) | (fresh ? O_EXCL : 0)
        let file = open(local, flags, mode_t(attributes.permissions & 0o777 | 0o600))
        guard file >= 0 else {
            throw SFTPFailure(errno == EEXIST && fresh ? Copy.clash(local)
                              : "Couldn't open local file \"\(local)\" for writing: \(String(cString: strerror(errno)))")
        }
        defer { close(file) }
        let handle = try await step { [offset] in try $0.openFile(remote, write: false, from: offset) }
        do {
            progress.file = RemotePath.name(remote)
            progress.bytes += offset
            report(progress)
            while true {
                try checkCancelled()
                let data = try await step { [cancellation, chunk] in try $0.read(handle, remote, upTo: chunk, cancellation) }
                if data.isEmpty { break }
                try data.withUnsafeBytes { bytes in
                    var written = 0
                    while written < bytes.count {
                        let count = write(file, bytes.baseAddress! + written, bytes.count - written)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else {
                            throw SFTPFailure("write local \"\(local)\": \(String(cString: strerror(errno)))")
                        }
                        written += count
                    }
                }
                try await advance(data.count)
            }
        } catch {
            _ = try? await step { try $0.closeFile(handle, remote) }
            throw error
        }
        _ = try? await step { try $0.closeFile(handle, remote) }
        if preserveTimes { Copy.setTimes(local, attributes) }
        progress.filesDone += 1
        report(progress)
        return offset
    }

    /// sftp's -p here: the server's permissions and times.
    private static func setTimes(_ local: String, _ attributes: LIBSSH2_SFTP_ATTRIBUTES) {
        chmod(local, mode_t(attributes.permissions & 0o7777))
        var times = [timeval(tv_sec: time_t(attributes.atime), tv_usec: 0), timeval(tv_sec: time_t(attributes.mtime), tv_usec: 0)]
        utimes(local, &times)
    }

    private static func clash(_ local: String) -> String {
        "\(local): another item here has the same name but for case or accents, and this disk keeps only one of them"
    }
}

/// The SFTP requests of a copy (`again` and `opened` make each whole), and its reads and writes (which a cancel stops at
/// once: closing the file clears what libssh2 keeps of them).
extension Connection {
    /// A file opened for reading, or for writing (made, or emptied unless it continues `from` an offset), at `from`.
    func openFile(_ path: String, write: Bool, from offset: Int64, mode: Int = 0o644) throws -> OpaquePointer {
        let flags = write ? UInt(LIBSSH2_FXF_WRITE | LIBSSH2_FXF_CREAT | (offset > 0 ? 0 : LIBSSH2_FXF_TRUNC)) : UInt(LIBSSH2_FXF_READ)
        guard let handle = try opened(nil, {
            libssh2_sftp_open_ex(sftp, path, UInt32(path.utf8.count), flags, mode, LIBSSH2_SFTP_OPENFILE)
        }) else { throw error(Int32(libssh2_session_last_errno(session)), "remote open(\"\(path)\")") }
        if offset > 0 { libssh2_sftp_seek64(handle, UInt64(offset)) }
        return handle
    }

    func closeFile(_ handle: OpaquePointer, _ path: String) throws {
        try check(again(nil) { libssh2_sftp_close_handle(handle) }, "remote close \"\(path)\"")
    }

    /// What has arrived of the file (waiting for some), about `size` bytes at most; empty at its end. (The same `size` each
    /// time: libssh2 asks ahead for four times what a read takes.)
    func read(_ handle: OpaquePointer, _ path: String, upTo size: Int, _ cancellation: Cancellation) throws -> Data {
        var data = Data()
        var buffer = [CChar](repeating: 0, count: min(size, 256 << 10))
        while data.count < size {
            let count = libssh2_sftp_read(handle, &buffer, buffer.count)
            if count == LIBSSH2_ERROR_EAGAIN {
                if !data.isEmpty { break }
                try wait(cancellation)
                continue
            }
            try check(count, "read remote \"\(path)\"")
            if count == 0 { break }
            buffer.withUnsafeBytes { data.append(contentsOf: $0.prefix(count)) }
        }
        return data
    }

    /// Sends the start of `bytes` (what libssh2 has sent of it already it doesn't send again); how much of it the server
    /// has taken.
    func write(_ handle: OpaquePointer, _ bytes: ArraySlice<UInt8>, _ path: String, _ cancellation: Cancellation) throws -> Int {
        while true {
            let taken = bytes.withUnsafeBytes { libssh2_sftp_write(handle, $0.baseAddress!.assumingMemoryBound(to: CChar.self), $0.count) }
            if taken != LIBSSH2_ERROR_EAGAIN {
                try check(taken, "write remote \"\(path)\"")
                return taken
            }
            try wait(cancellation)
        }
    }

    /// A folder's entries (not "." and ".."), with what the server says of each (a link's own, not its target's).
    func children(of folder: String) throws -> [(name: String, attributes: LIBSSH2_SFTP_ATTRIBUTES)] {
        let what = "remote readdir(\"\(folder)\")"
        guard let handle = try opened(nil, {
            libssh2_sftp_open_ex(sftp, folder, UInt32(folder.utf8.count), 0, 0, LIBSSH2_SFTP_OPENDIR)
        }) else { throw error(Int32(libssh2_session_last_errno(session)), what) }
        defer { _ = try? again(nil) { libssh2_sftp_close_handle(handle) } }
        var children: [(name: String, attributes: LIBSSH2_SFTP_ATTRIBUTES)] = []
        var name = [CChar](repeating: 0, count: 4096)
        var attributes = LIBSSH2_SFTP_ATTRIBUTES()
        while true {
            let count = try again(nil) { libssh2_sftp_readdir_ex(handle, &name, name.count, nil, 0, &attributes) }
            if count == 0 { break }
            try check(count, what)
            let text = String(decoding: name.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if text != "." && text != ".." { children.append((text, attributes)) }
        }
        return children.sorted { $0.name < $1.name }
    }

    func readLink(_ path: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        let count = try again(nil) {
            libssh2_sftp_symlink_ex(sftp, path, UInt32(path.utf8.count), &buffer, UInt32(buffer.count), LIBSSH2_SFTP_READLINK)
        }
        try check(count, "remote readlink \"\(path)\"")
        return String(decoding: buffer.prefix(Int(count)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    func makeFolder(_ path: String, mode: Int) throws {
        try check(again(nil) { libssh2_sftp_mkdir_ex(sftp, path, UInt32(path.utf8.count), mode) }, "remote mkdir \"\(path)\"")
    }

    /// As the batch's `symlink` makes one: OpenSSH's server takes the target first.
    func makeLink(_ path: String, pointingTo target: String) throws {
        var link = Array(path.utf8CString)
        try check(again(nil) {
            libssh2_sftp_symlink_ex(sftp, target, UInt32(target.utf8.count), &link, UInt32(path.utf8.count), LIBSSH2_SFTP_SYMLINK)
        }, "remote symlink \"\(target)\" to \"\(path)\"")
    }

    /// sftp's -p there: this device's permissions and times, set through the open file's `handle` when there is one.
    func setAttributes(of path: String, handle: OpaquePointer?, _ info: stat) throws {
        var attributes = LIBSSH2_SFTP_ATTRIBUTES()
        attributes.flags = UInt(LIBSSH2_SFTP_ATTR_PERMISSIONS | LIBSSH2_SFTP_ATTR_ACMODTIME)
        attributes.permissions = UInt(info.st_mode & 0o7777)
        attributes.atime = UInt(info.st_atimespec.tv_sec)
        attributes.mtime = UInt(info.st_mtimespec.tv_sec)
        let rc = try again(nil) {
            if let handle { return libssh2_sftp_fstat_ex(handle, &attributes, 1) }
            return libssh2_sftp_stat_ex(sftp, path, UInt32(path.utf8.count), LIBSSH2_SFTP_SETSTAT, &attributes)
        }
        try check(rc, "remote setstat \"\(path)\"")
    }
}
