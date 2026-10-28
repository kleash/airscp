import CryptoKit
import Foundation

/// The transfer queue's jobs for an S3 connection, over HTTPS: files as one PUT or a multipart upload (Pause keeps its
/// parts, Resume continues it), downloads into ".airscp-<id>.part" with Range to continue, folders object by object,
/// copies with another server through a temporary folder on this Mac, and zips made and unpacked on this Mac (ditto,
/// tar, gzip). A file uploaded to S3 appears whole or not at all, so uploads need no temporary name there.
extension TransferQueue {
    /// Bytes done by the steps before the current one, for one job's progress.
    final class Progress {
        var done: Int64 = 0
    }

    func runS3(_ job: TransferJob, session: Session, s3: S3Client, cancellation: Cancellation) async -> TransferJob.Status {
        let meter = Progress()
        let progress: (Int64) -> Void = { [weak self] bytes in self?.streamed(job.id, meter.done + bytes) }
        let part = TransferQueue.partPath(job)
        var temp: String?
        defer { if let temp { try? FileManager.default.removeItem(atPath: temp) } }
        do {
            var errors: [String] = []
            switch job.direction {
            case .upload where job.names.isEmpty:
                if !job.isFolder && isResumable(job.id) && s3.keepsUpload(of: job.id) { setResumed(job.id, true) }
                errors = try await sendS3(job.source, to: job.destination, session: session, job: job, replacing: job.replacing,
                                          meter: meter, progress: progress, cancellation: cancellation)
            case .download where job.names.isEmpty:
                if job.isFolder || !isResumable(job.id) { try? FileManager.default.removeItem(atPath: part) }
                errors = try await fetchS3(job.source, into: part, session: session, job: job, meter: meter, progress: progress,
                                           cancellation: cancellation)
                try TransferQueue.moveIntoPlace(part, to: job.destination, replacing: job.replacing)
            case .download:
                // Download as .zip: the items into a private folder, zipped there, the zip kept.
                startStream(job.id, label: job.name, total: nil)
                let folder = try TransferQueue.temporaryFolder()
                temp = folder
                for name in job.names {
                    errors += try await fetchS3(RemotePath.join(job.source, name), into: folder + "/items/" + name, session: session,
                                                job: nil, meter: meter, progress: progress, cancellation: cancellation)
                }
                try await TransferQueue.zip(folder + "/items", to: part, cancellation: cancellation)
                try TransferQueue.moveIntoPlace(part, to: job.destination, replacing: false)
            case .upload:
                throw AirSCPError(.other, Session.s3NoShell)  // compressed uploads unpack on the server
            case .relay:
                guard let sourceID = job.sourceHostID, let source = TransferCenter.shared.session(for: sourceID) else {
                    return .failed(AirSCPError(.disconnected, "The server to copy from isn't connected."))
                }
                startStream(job.id, label: TransferQueue.label(job.names), total: nil)
                let folder = try TransferQueue.temporaryFolder()
                temp = folder
                errors = try await fetchForRelay(job, from: source, into: folder, meter: meter, cancellation: cancellation)
                meter.done = 0
                for name in job.names where access(folder + "/" + name, F_OK) == 0 {
                    errors += try await sendS3(folder + "/" + name, to: RemotePath.join(job.destination, name), session: session,
                                               job: nil, replacing: job.replacing, meter: meter, progress: progress,
                                               cancellation: cancellation)
                }
            case .compress:
                // The items into a private folder, zipped there, the zip uploaded next to them.
                startStream(job.id, label: TransferQueue.label(job.names), total: nil)
                let folder = try TransferQueue.temporaryFolder()
                temp = folder
                for name in job.names {
                    errors += try await fetchS3(RemotePath.join(job.source, name), into: folder + "/items/" + name, session: session,
                                                job: nil, meter: meter, progress: progress, cancellation: cancellation)
                }
                try await TransferQueue.zip(folder + "/items", to: folder + "/archive.zip", cancellation: cancellation)
                let existing = try await session.list(job.destination).map(\.name)
                let name = Names.unique((job.names.count == 1 ? job.names[0] : "Archive") + ".zip", existing: existing)
                meter.done = 0
                errors += try await sendS3(folder + "/archive.zip", to: RemotePath.join(job.destination, name), session: session,
                                           job: nil, replacing: false, meter: meter, progress: progress, cancellation: cancellation)
            case .extract:
                // The archive into a private folder, unpacked there, its items uploaded: into a new folder when asked,
                // or when an item of the same name is there (nothing is replaced unasked).
                guard let archive = job.names.first, let kind = ArchiveKind(name: archive) else {
                    throw AirSCPError(.other, "\(job.names.first ?? "It") isn't an archive AirSCP can extract.")
                }
                startStream(job.id, label: archive, total: nil)
                let folder = try TransferQueue.temporaryFolder()
                temp = folder
                errors = try await fetchS3(RemotePath.join(job.source, archive), into: folder + "/archive", session: session, job: nil,
                                           meter: meter, progress: progress, cancellation: cancellation)
                var items = try await TransferQueue.unpack(folder + "/archive", kind: kind, name: archive, into: folder + "/items",
                                                           cancellation: cancellation)
                // An archive's symbolic links may point at anything on this Mac: uploading one would upload what it
                // points to. They stay out.
                errors += TransferQueue.removeLinks(in: folder + "/items").map { "\($0): a symbolic link, not uploaded" }
                items = items.filter { access(folder + "/items/" + $0, F_OK) == 0 }
                let existing = try await session.list(job.destination).map(\.name)
                var target = job.destination
                if job.isFolder || items.contains(where: { Names.existing($0, in: existing) != nil }) {
                    target = RemotePath.join(job.destination, Names.unique(ArchiveKind.baseName(archive), existing: existing))
                }
                meter.done = 0
                for item in items {
                    errors += try await sendS3(folder + "/items/" + item, to: RemotePath.join(target, item), session: session,
                                               job: nil, replacing: false, meter: meter, progress: progress, cancellation: cancellation)
                }
            }
            if cancellation.isCancelled { throw AirSCPError.cancelled }
            streamed(job.id, meter.done, final: true)  // the size of the last step (a compressed job's: its .zip)
            return errors.isEmpty ? .done : .completedWithErrors(errors.joined(separator: "\n"))
        } catch {
            // Offline, the abort couldn't reach the storage anyway: keep the parts for a retry (removing the job drops them).
            let offline = [.noRoute, .timeout].contains((error as? AirSCPError)?.kind)
            if !keepsPartial(job, after: error) && !offline {
                if job.direction == .download { try? FileManager.default.removeItem(atPath: part) }
                await s3.abandon(job.id)
            }
            return TransferQueue.status(for: error)
        }
    }

    /// Uploads this Mac's file or folder to `path` (a folder: every file under it, an empty folder as its marker; Leave
    /// out patterns skip names at any depth). `replacing` a folder: what was in the old one and isn't in the new one goes
    /// once the new one is complete. Files this Mac can't read are left out and named in what is returned.
    func sendS3(_ local: String, to path: String, session: Session, job: TransferJob?, replacing: Bool, meter: Progress,
                progress: @escaping (Int64) -> Void, cancellation: Cancellation) async throws -> [String] {
        guard let s3 = session.s3 else { throw AirSCPError(.other, Session.s3NoShell) }
        let (bucket, key) = try session.s3Item(path)
        guard TransferQueue.isLocalFolder(local) else {
            let size = TransferQueue.localSize(local) ?? 0
            if let job { startStream(job.id, label: job.name, total: size) }
            try await s3.upload(URL(fileURLWithPath: local), size: size, to: bucket, key, job: job?.id, progress: progress,
                                limit: streamLimit, cancellation: cancellation)
            meter.done += size
            return []
        }
        var errors: [String] = [], files: [(relative: String, size: Int64)] = [], folders: [String] = []
        let walk = FileManager.default.enumerator(atPath: local)
        while let relative = walk?.nextObject() as? String {
            let full = local + "/" + relative
            let folder = TransferQueue.isLocalFolder(full)
            if TransferQueue.leftOut(RemotePath.name(relative), by: job?.excluding ?? []) {
                if folder { walk?.skipDescendants() }
                continue
            }
            if folder, (try? FileManager.default.destinationOfSymbolicLink(atPath: full)) != nil {
                // The walk doesn't go into a link to a folder: an empty folder in its place would read as uploaded.
                errors.append("\(relative): a link to a folder, not uploaded")
            } else if folder {
                folders.append(relative)
            } else if let size = TransferQueue.localSize(full) {  // a link to nothing has none
                files.append((relative, size))
            } else {
                errors.append("\(relative): a link to something that isn't there")
            }
        }
        if let job { startStream(job.id, label: job.name, total: files.reduce(0) { $0 + $1.size }) }
        var sent = Set<String>()
        for file in files {
            if cancellation.isCancelled { throw AirSCPError.cancelled }
            let url = URL(fileURLWithPath: local + "/" + file.relative), target = key + "/" + file.relative
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                errors.append("\(file.relative): AirSCP may not read it on this Mac")
                continue
            }
            try await s3.upload(url, size: file.size, to: bucket, target, progress: progress, limit: streamLimit,
                                cancellation: cancellation)
            sent.insert(target)
            meter.done += file.size
        }
        // Empty folders exist on S3 only as their markers. The folders holding a file at any depth, in one pass (a big
        // tree's folders each checked against every file would take minutes).
        var filled: Set<String> = files.isEmpty ? [] : [""]
        for file in files {
            var folder = Substring(file.relative)
            while let slash = folder.lastIndex(of: "/") {
                folder = folder[..<slash]
                if !filled.insert(String(folder)).inserted { break }  // its parents are in already
            }
        }
        for folder in [""] + folders where !filled.contains(folder) {
            let marker = key + "/" + (folder.isEmpty ? "" : folder + "/")
            try await s3.put(bucket, marker, body: .data(Data()), digest: Data(SHA256.hash(data: Data())), cancellation: cancellation)
            sent.insert(marker)
        }
        if replacing {
            let old = try await s3.list(bucket, prefix: key + "/", delimiter: nil, cancellation: cancellation).objects.map(\.key)
            let stale = old.filter { !sent.contains($0) }
            if !stale.isEmpty { try await s3.delete(bucket, keys: stale, cancellation: cancellation) }
        }
        return errors
    }

    /// Downloads the file or folder at `path` to `local` on this Mac (a folder: every object under it; Leave out
    /// patterns skip names at any depth). `job`: a single file's own download, which continues what an earlier try left
    /// in `local` (Range), unless the file changed meanwhile. Objects whose names this Mac can't hold are left out and
    /// named in what is returned.
    func fetchS3(_ path: String, into local: String, session: Session, job: TransferJob?, meter: Progress,
                 progress: @escaping (Int64) -> Void, cancellation: Cancellation) async throws -> [String] {
        guard let s3 = session.s3 else { throw AirSCPError(.other, Session.s3NoShell) }
        let (bucket, key) = try session.s3Item(path)
        let objects = try await s3.list(bucket, prefix: key + "/", delimiter: nil, cancellation: cancellation).objects
        guard !objects.isEmpty else {
            try FileManager.default.createDirectory(atPath: RemotePath.parent(local), withIntermediateDirectories: true)
            try await fetchFileS3(bucket, key, into: local, s3: s3, resume: job.map { isResumable($0.id) } ?? false, job: job,
                                  preserveTimes: job?.preserveTimes ?? false, meter: meter, progress: progress,
                                  cancellation: cancellation)
            return []
        }
        var errors: [String] = []
        try FileManager.default.createDirectory(atPath: local, withIntermediateDirectories: true)
        if let job { startStream(job.id, label: job.name, total: objects.reduce(0) { $0 + $1.size }) }
        for object in objects {
            if cancellation.isCancelled { throw AirSCPError.cancelled }
            let relative = String(object.key.dropFirst(key.count + 1))
            let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let names = relative.hasSuffix("/") ? parts.dropLast() : parts[...]
            if names.contains(where: { TransferQueue.leftOut($0, by: job?.excluding ?? []) }) { continue }
            guard !names.isEmpty, names.allSatisfy(Session.usable) else {
                if !relative.isEmpty { errors.append("\(relative): a name this Mac can't hold") }
                continue
            }
            let target = local + "/" + names.joined(separator: "/")
            let folder = relative.hasSuffix("/") ? target : RemotePath.parent(target)
            guard (try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)) != nil,
                  relative.hasSuffix("/") || FileManager.default.createFile(atPath: target, contents: nil) else {
                errors.append("\(relative): AirSCP can't write it on this Mac")
                continue
            }
            if !relative.hasSuffix("/") {
                try await fetchFileS3(bucket, object.key, into: target, s3: s3, resume: false, job: nil,
                                      preserveTimes: job?.preserveTimes ?? false, meter: meter, progress: progress,
                                      cancellation: cancellation)
            }
        }
        return errors
    }

    /// One object into the file `local`, continuing it with Range when `resume` (as long as the object hasn't changed);
    /// `preserveTimes`: the file gets the object's date (Synchronize then finds the two the same).
    private func fetchFileS3(_ bucket: String, _ key: String, into local: String, s3: S3Client, resume: Bool, job: TransferJob?,
                             preserveTimes: Bool, meter: Progress, progress: @escaping (Int64) -> Void,
                             cancellation: Cancellation) async throws {
        let headers = try await s3.head(bucket, key)
        let size = Int64(headers["content-length"] ?? "") ?? 0
        if let job { startStream(job.id, label: job.name, total: size) }
        var offset = resume ? TransferQueue.localSize(local) ?? 0 : 0
        if offset > size { offset = 0 }
        if offset > 0, let job { setResumed(job.id, true) }
        if offset == 0 && !FileManager.default.createFile(atPath: local, contents: nil) {
            throw AirSCPError(.permissionDenied, "AirSCP may not write \(RemotePath.name(local)) on this Mac.")
        }
        guard let file = FileHandle(forWritingAtPath: local) else {
            throw AirSCPError(.permissionDenied, "AirSCP may not write \(RemotePath.name(local)) on this Mac.")
        }
        defer { try? file.close() }
        if offset < size {
            do {
                try file.seekToEnd()
                try await s3.get(bucket, key, into: file, offset: offset, etag: offset > 0 ? headers["etag"] : nil,
                                 progress: { progress(offset + $0) }, limit: streamLimit, cancellation: cancellation)
            } catch let error as AirSCPError where offset > 0 && error.details.contains("PreconditionFailed") {
                // It changed since the part was made: all of it again.
                try file.truncate(atOffset: 0)
                try await s3.get(bucket, key, into: file, progress: progress, limit: streamLimit, cancellation: cancellation)
            }
        }
        if preserveTimes, let date = headers["last-modified"].flatMap(S3Dates.http) {
            try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: local)
        }
        meter.done += size
    }

    /// A relay's first half: each item of the source server copied into `temp` on this Mac (scp, or the source's S3).
    func fetchForRelay(_ job: TransferJob, from source: Session, into temp: String, meter: Progress,
                       cancellation: Cancellation) async throws -> [String] {
        var errors: [String] = []
        if source.s3 != nil { startStream(job.id, label: TransferQueue.label(job.names), total: nil) }
        for name in job.names {
            if source.s3 != nil {
                errors += try await fetchS3(RemotePath.join(job.source, name), into: temp + "/" + name, session: source, job: nil,
                                            meter: meter, progress: { [weak self] in self?.streamed(job.id, meter.done + $0) },
                                            cancellation: cancellation)
                continue
            }
            let (argv, input) = try copy(upload: false, temp + "/" + name, RemotePath.join(job.source, name), folder: true,
                                         preserveTimes: true, session: source)
            let result = try await source.runMuxed(argv, input: input, cancellation: cancellation,
                                                   terminal: { self.progress(job.id, $0) })
            if result.status != 0 {
                guard result.status == 1 && access(temp + "/" + name, F_OK) == 0 else {
                    throw ErrorMapping.map(result.stderr, status: result.status)
                }
                errors.append(result.stderr)
            }
        }
        return errors
    }

    /// Verify for an S3 file: its SHA-256 here against the one the storage keeps (for a file uploaded in parts, the
    /// SHA-256 of the parts' SHA-256s). nil when cancelled.
    func checksumS3(_ job: TransferJob, session: Session, s3: S3Client, cancellation: Cancellation) async -> TransferJob.Checksum? {
        let (local, remote) = job.direction == .upload ? (job.source, job.destination) : (job.destination, job.source)
        do {
            let (bucket, key) = try session.s3Item(remote)
            guard let stored = try await s3.head(bucket, key)["x-amz-checksum-sha256"] else {
                return .unchecked("The storage keeps no SHA-256 for this file, so the copy can't be checked against it.")
            }
            let mine: String
            if stored.contains("-") {
                let partSize = Int64(try await s3.head(bucket, key, part: 1)["content-length"] ?? "") ?? 0
                mine = try S3Client.compositeSHA256(URL(fileURLWithPath: local), partSize: max(1, partSize))
            } else {
                mine = try S3Client.sha256(URL(fileURLWithPath: local), cancellation: cancellation).base64EncodedString()
            }
            // As hex, like the servers' (a checksum of parts stays as the storage writes it).
            func shown(_ value: String) -> String { Data(base64Encoded: value).map { SigV4.hex($0) } ?? value }
            let (original, copy) = job.direction == .upload ? (shown(mine), shown(stored)) : (shown(stored), shown(mine))
            return original == copy ? .verified(copy) : .mismatch(original: original, copy: copy)
        } catch {
            if cancellation.isCancelled { return nil }
            return .unchecked((error as? AirSCPError)?.message ?? error.localizedDescription)
        }
    }

    /// Removes the symbolic links in `folder`, at any depth, and returns their paths in it.
    static func removeLinks(in folder: String) -> [String] {
        var removed: [String] = []
        let walk = FileManager.default.enumerator(atPath: folder)
        while let relative = walk?.nextObject() as? String {
            var info = stat()
            if lstat(folder + "/" + relative, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK && unlink(folder + "/" + relative) == 0 {
                removed.append(relative)
            }
        }
        return removed
    }

    /// A folder on this Mac, or a link to one.
    static func isLocalFolder(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    /// A folder of this Mac's own for a job's temporary files (only this user may read it).
    static func temporaryFolder() throws -> String {
        let path = FileManager.default.temporaryDirectory.path + "/airscp-s3-" + UUID().uuidString
        guard mkdir(path, 0o700) == 0 else {
            throw AirSCPError(.other, "Can't create a temporary folder: \(String(cString: strerror(errno)))")
        }
        return path
    }

    /// What is in `folder`, as a .zip at `archive` (ditto: no Mac-only extras, so it opens anywhere).
    static func zip(_ folder: String, to archive: String, cancellation: Cancellation) async throws {
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        unlink(archive)
        let result = await Runner.run(["/usr/bin/ditto", "-c", "-k", "--norsrc", "--noextattr", "--noqtn", "--noacl", folder, archive],
                                      cancellation: cancellation)
        if cancellation.isCancelled { throw AirSCPError.cancelled }
        guard result.status == 0 else { throw ErrorMapping.mapLocal(result.stderr, status: result.status) }
    }

    /// Unpacks an archive on this Mac into `folder` (made here): a zip with ditto, a tar with tar, a .gz with gzip.
    /// Returns the names at its top.
    static func unpack(_ archive: String, kind: ArchiveKind, name: String, into folder: String,
                       cancellation: Cancellation) async throws -> [String] {
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let argv: [String]
        switch kind {
        case .zip: argv = ["/usr/bin/ditto", "-x", "-k", archive, folder]
        case .tar: argv = [localTar, "-x", "-f", archive, "-C", folder]
        case .gzip: argv = ["/bin/sh", "-c", "/usr/bin/gzip -dc -- \"$1\" > \"$2\"", "sh", archive,
                            folder + "/" + ArchiveKind.baseName(name)]
        }
        let result = await Runner.run(argv, cancellation: cancellation)
        if cancellation.isCancelled { throw AirSCPError.cancelled }
        guard result.status == 0 else { throw ErrorMapping.mapLocal(result.stderr, status: result.status) }
        return try FileManager.default.contentsOfDirectory(atPath: folder).filter { $0 != "__MACOSX" }.sorted()
    }
}
