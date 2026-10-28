import CryptoKit
import Foundation

/// Get Info's facts of an S3 object.
public struct S3Info: Equatable {
    public var etag = ""
    public var storageClass = ""
    public var contentType = ""
    /// The x-amz-meta-… headers, by name (without the prefix).
    public var metadata: [String: String] = [:]
    /// Its SHA-256 checksum (base64; "-N" after it for one uploaded in N parts), where the storage keeps one.
    public var checksum: String?
}

/// An S3 connection's files as the panes show them: "/" lists the buckets, "/bucket/a/b" is the folder (prefix "a/b/")
/// or the file (key "a/b"). Folders are the listing's common prefixes and the empty "name/" objects that keep an empty
/// folder. Names a folder can't hold ("", ".", "..") are left out. The Session's file operations come here when it has
/// `s3`.
extension Session {
    public static let s3NoShell = "This is S3 storage: files only, without commands, a terminal or tunnels."
    static let noBuckets = "AirSCP doesn't make, rename or delete buckets: do that in your storage provider's console."

    /// The bucket and key of a path: "/photos/2024/a.jpg" is ("photos", "2024/a.jpg"); nil for "/".
    public static func s3Location(_ path: String) -> (bucket: String, key: String)? {
        let parts = path.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
        guard let bucket = parts.first else { return nil }
        return (String(bucket), parts.count > 1 ? String(parts[1]) : "")
    }

    /// The bucket and key of a path below a bucket (an object or a folder, never a bucket itself).
    func s3Item(_ path: String) throws -> (bucket: String, key: String) {
        guard let location = Self.s3Location(path), !location.key.isEmpty else { throw AirSCPError(.other, Self.noBuckets) }
        return location
    }

    /// Connecting: the keys from the Keychain, checked by listing the buckets (or the bucket to open at).
    func checkS3() async throws -> Capabilities {
        guard let s3, let settings = host.s3 else { throw AirSCPError(.other, "This isn't an S3 connection.") }
        guard let secret = savedPassword(host), !secret.isEmpty else {
            throw AirSCPError(.authFailed(methods: ""), "The secret access key isn't saved. Edit the connection and type it.")
        }
        let token = savedS3Token(host)
        DebugLog.Secrets.add(secret)  // never in the debug log, whatever line might carry it
        DebugLog.Secrets.add(token)
        s3.credentials = S3Client.Credentials(accessKeyID: settings.accessKeyID, secret: secret, token: token)
        do {
            if settings.bucket.isEmpty {
                _ = try await s3.listBuckets()
            } else {
                _ = try await s3.list(settings.bucket, prefix: "", maxKeys: 1)
            }
        } catch let error as AirSCPError where error.kind == .permissionDenied && settings.bucket.isEmpty {
            throw AirSCPError(.permissionDenied, "This access key may not list the buckets. Edit the connection and type the "
                              + "bucket to open (Bucket).", details: error.details)
        }
        var capabilities = Capabilities()
        capabilities.home = settings.bucket.isEmpty ? "/" : "/" + settings.bucket
        capabilities.noShellReason = Self.s3NoShell
        return capabilities
    }

    /// A folder's entries: the buckets at "/" (only the bucket to open at, when the keys may not list them), else the
    /// folders and files at that level. A folder that has nothing in it and no marker doesn't exist.
    func listS3(_ dir: String) async throws -> [RemoteEntry] {
        guard let s3 else { return [] }
        func entry(_ name: String, folder: Bool, size: Int64 = 0, modified: Date? = nil) -> RemoteEntry {
            RemoteEntry(name: name, path: RemotePath.join(dir, name), kind: folder ? .directory : .file, size: size,
                        modified: modified, permissions: "", mode: 0, owner: "", group: "")
        }
        guard let (bucket, key) = Self.s3Location(dir) else {
            do {
                return try await s3.listBuckets().map { entry($0.name, folder: true, modified: $0.created) }
            } catch let error as AirSCPError where error.kind == .permissionDenied && !(host.s3?.bucket ?? "").isEmpty {
                return [entry(host.s3?.bucket ?? "", folder: true)]
            }
        }
        let prefix = key.isEmpty ? "" : key + "/"
        let listed = try await cancellable { try await s3.list(bucket, prefix: prefix, cancellation: $0) }
        if listed.objects.isEmpty && listed.prefixes.isEmpty && !key.isEmpty { _ = try await s3.head(bucket, prefix) }
        let folders = listed.prefixes.map { String($0.dropFirst(prefix.count).dropLast()) }.filter(Self.usable)
            .map { entry($0, folder: true) }
        let files = listed.objects.filter { $0.key != prefix }
            .compactMap { object -> RemoteEntry? in
                let name = String(object.key.dropFirst(prefix.count))
                return Self.usable(name) ? entry(name, folder: false, size: object.size, modified: object.modified) : nil
            }
        return folders + files
    }

    /// A name a folder on this Mac can hold too.
    static func usable(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// Every object at `path`: the file itself, and everything in the folder of that name (its marker too).
    func s3Objects(at path: String, cancellation: Cancellation? = nil) async throws -> [S3Object] {
        guard let s3 else { return [] }
        let (bucket, key) = try s3Item(path)
        var objects = try await s3.list(bucket, prefix: key + "/", delimiter: nil, cancellation: cancellation).objects
        if let headers = try? await s3.head(bucket, key) {
            objects.insert(S3Object(key: key, size: Int64(headers["content-length"] ?? "") ?? 0, modified: nil,
                                    etag: headers["etag"] ?? "", storageClass: ""), at: 0)
        }
        return objects
    }

    /// How many files the folders at `paths` hold, at any depth (their markers not counted): renaming, moving, copying
    /// or deleting them goes file by file.
    public func s3FileCount(_ paths: [String]) async throws -> Int {
        var count = 0
        for path in paths { count += try await s3Objects(at: path).filter { !$0.key.hasSuffix("/") }.count }
        return count
    }

    func makeDirectoryS3(_ path: String) async throws {
        let (bucket, key) = try s3Item(path)
        try await s3?.put(bucket, key + "/", body: .data(Data()), digest: Data(SHA256.hash(data: Data())))
    }

    func existsS3(_ path: String) async throws -> Bool {
        guard let s3, let (bucket, key) = Self.s3Location(path) else { return true }
        do {
            if key.isEmpty {
                _ = try await s3.list(bucket, prefix: "", maxKeys: 1)
                return true
            }
            if (try? await s3.head(bucket, key)) != nil { return true }
            return try await !s3.list(bucket, prefix: key + "/", delimiter: nil, maxKeys: 1).objects.isEmpty
        } catch let error as AirSCPError where error.kind == .noSuchFile {
            return false
        }
    }

    /// Copies (`keep`) or moves a file or folder: each object copied on the storage (CopyObject), then the originals
    /// deleted. What is at `newPath` already is overwritten.
    func copyS3(_ path: String, to newPath: String, keep: Bool) async throws {
        guard let s3 else { return }
        let from = try s3Item(path), to = try s3Item(newPath)
        let objects = try await cancellable { try await s3Objects(at: path, cancellation: $0) }
        guard !objects.isEmpty else { throw AirSCPError(.noSuchFile, "“\(RemotePath.name(path))” doesn't exist (any more).") }
        for object in objects {
            if Task.isCancelled { throw AirSCPError.cancelled }
            try await s3.copy(from.bucket, object.key, size: object.size, to: to.bucket, to.key + object.key.dropFirst(from.key.count))
        }
        if !keep { try await s3.delete(from.bucket, keys: objects.map(\.key)) }
    }

    /// `copy(_:replacing:)`: the copy goes over what is there, then what was there and isn't overwritten goes.
    func replaceS3(_ path: String, with source: String, move: Bool) async throws {
        let old = try await s3Objects(at: path)
        let (bucket, key) = try s3Item(path), sourceKey = try s3Item(source).key
        // Listed before the copy: a move deletes the source.
        let new = Set(try await s3Objects(at: source).map { key + $0.key.dropFirst(sourceKey.count) })
        try await copyS3(source, to: path, keep: !move)
        let stale = old.map(\.key).filter { !new.contains($0) && $0 != key + "/" }
        if !stale.isEmpty { try await s3?.delete(bucket, keys: stale) }
    }

    func deleteS3(_ entries: [RemoteEntry]) async throws {
        guard let s3 else { return }
        var keys: [String: [String]] = [:]
        for entry in entries {
            let (bucket, key) = try s3Item(entry.path)
            if entry.kind == .directory {
                keys[bucket, default: []] += try await cancellable {
                    try await s3.list(bucket, prefix: key + "/", delimiter: nil, cancellation: $0).objects.map(\.key)
                }
            } else {
                keys[bucket, default: []].append(key)
            }
        }
        for (bucket, keys) in keys where !keys.isEmpty { try await s3.delete(bucket, keys: keys) }
    }

    func createFileS3(_ path: String) async throws {
        if try await existsS3(path) {
            throw AirSCPError(.failure, "“\(RemotePath.name(path))” already exists in that folder (it was made after the "
                              + "folder was listed). Choose another name.")
        }
        try await putS3(Data(), to: path)
    }

    func putS3(_ data: Data, to path: String) async throws {
        let (bucket, key) = try s3Item(path)
        try await s3?.put(bucket, key, body: .data(data), digest: Data(SHA256.hash(data: data)))
    }

    func storeS3(_ local: URL, to path: String) async throws {
        let (bucket, key) = try s3Item(path)
        try await s3?.upload(local, size: TransferQueue.localSize(local.path) ?? 0, to: bucket, key)
    }

    func fetchS3(_ path: String, to local: URL, limit: Int64?, tooLarge: String) async throws {
        let (bucket, key) = try s3Item(path)
        guard FileManager.default.createFile(atPath: local.path, contents: nil), let file = FileHandle(forWritingAtPath: local.path) else {
            throw AirSCPError(.permissionDenied, "AirSCP can't write a temporary copy on this Mac.")
        }
        defer { try? file.close() }
        do {
            try await cancellable { try await s3?.get(bucket, key, into: file, maxBody: limit, cancellation: $0) }
        } catch let error as AirSCPError where error.kind == .notText {
            throw AirSCPError(.notText, tooLarge)
        }
    }

    func infoS3(_ entry: RemoteEntry) async throws -> RemoteInfo {
        guard let s3 else { throw AirSCPError(.other, Self.s3NoShell) }
        var info = RemoteInfo(path: entry.path, kind: nil, size: nil, itemCount: nil, mode: 0, owner: "", group: "",
                              modified: entry.modified, accessed: nil, changed: nil, linkTarget: nil)
        guard let (bucket, key) = Self.s3Location(entry.path) else { return info }
        if entry.kind == .directory {
            let objects = try await cancellable {
                try await s3.list(bucket, prefix: key.isEmpty ? "" : key + "/", delimiter: nil, cancellation: $0).objects
            }
            let files = objects.filter { !$0.key.hasSuffix("/") }
            info.size = files.reduce(0) { $0 + $1.size }
            info.itemCount = files.count
            return info
        }
        let headers = try await s3.head(bucket, key)
        info.size = Int64(headers["content-length"] ?? "") ?? entry.size
        info.modified = headers["last-modified"].flatMap(S3Dates.http) ?? entry.modified
        var details = S3Info(etag: headers["etag"] ?? "", storageClass: headers["x-amz-storage-class"] ?? "STANDARD",
                             contentType: headers["content-type"] ?? "", checksum: headers["x-amz-checksum-sha256"])
        for (name, value) in headers where name.hasPrefix("x-amz-meta-") { details.metadata[String(name.dropFirst(11))] = value }
        info.s3 = details
        return info
    }

    /// Copy Link's presigned https URL for a file: anyone with it may download the file until it expires.
    public func presignS3(_ path: String, expires: Int) async throws -> URL {
        guard let s3 else { throw AirSCPError(.other, "Presigned links are for S3 storage.") }
        let (bucket, key) = try s3Item(path)
        return try await s3.presign(bucket, key, expires: expires)
    }

    /// "s3://bucket/key" (a folder's with "/" at the end).
    public static func s3URI(_ path: String, folder: Bool) -> String {
        let trimmed = path.hasPrefix("/") ? String(path.dropFirst()) : path
        return "s3://" + trimmed + (folder && !trimmed.isEmpty && !trimmed.hasSuffix("/") ? "/" : "")
    }
}
