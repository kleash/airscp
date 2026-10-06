import Combine
import CryptoKit
import Foundation

/// Names in a folder: conflicts and "name 2".
public enum Names {
    /// The name in `names` that `name` would collide with. Equal as Unicode text (é precomposed or decomposed),
    /// and ignoring case when `caseInsensitive` (a Mac's own disks usually are).
    public static func existing(_ name: String, in names: [String], caseInsensitive: Bool = false) -> String? {
        let wanted = key(name, caseInsensitive: caseInsensitive)
        return names.first { key($0, caseInsensitive: caseInsensitive) == wanted }
    }

    /// `name` when it is free, else "name 2.ext", "name 3.ext", … (".tar.gz" and friends count as one extension;
    /// a leading dot doesn't start one).
    public static func unique(_ name: String, existing names: [String], caseInsensitive: Bool = false) -> String {
        unique(name, takenKeys: Set(names.map { key($0, caseInsensitive: caseInsensitive) }), caseInsensitive: caseInsensitive)
    }

    /// `unique`, against the `key`s of the names there (for many names in a big folder, without making them again). A
    /// name made longer than the 255 bytes file systems take ("name 2.txt", "name.zip" of a long name) is shortened
    /// before its extension.
    public static func unique(_ name: String, takenKeys taken: Set<String>, caseInsensitive: Bool) -> String {
        let (base, ext) = split(name)
        let name = fitted(base, ext)
        guard taken.contains(key(name, caseInsensitive: caseInsensitive)) else { return name }
        var number = 2
        while taken.contains(key(fitted(base, " \(number)\(ext)"), caseInsensitive: caseInsensitive)) { number += 1 }
        return fitted(base, " \(number)\(ext)")
    }

    /// `base` and `suffix`, the base shortened by whole characters to fit 255 bytes.
    static func fitted(_ base: String, _ suffix: String) -> String {
        var base = base
        while !base.isEmpty && base.utf8.count + suffix.utf8.count > 255 { base.removeLast() }
        return base + suffix
    }

    static func split(_ name: String) -> (base: String, ext: String) {
        let lower = name.lowercased()
        for compound in [".tar.gz", ".tar.bz2", ".tar.xz"] where lower.hasSuffix(compound) && name.count > compound.count {
            return (String(name.dropLast(compound.count)), String(name.suffix(compound.count)))
        }
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return (name, "") }
        return (String(name[..<dot]), String(name[dot...]))
    }

    /// What names are compared by: equal for the same Unicode text in either form, and any case when `caseInsensitive`.
    public static func key(_ name: String, caseInsensitive: Bool = false) -> String {
        let canonical = name.precomposedStringWithCanonicalMapping
        return caseInsensitive ? canonical.lowercased() : canonical
    }
}

/// How far an scp run has got, from its progress meter.
public struct TransferProgress: Equatable {
    /// The file being copied, as scp shows it (long names may be shortened).
    public var file = ""
    /// Of the current file.
    public var percent = 0
    /// Of the current file so far (as scp rounds it).
    public var bytes: Int64 = 0
    /// As scp shows it, e.g. "5.8MB/s".
    public var speed = ""
    /// "00:02", or "" once the file is done.
    public var eta = ""
    /// Files finished (in a folder transfer).
    public var filesDone = 0
    /// The whole job's size in bytes when known (an estimate for streamed jobs), else nil.
    public var total: Int64?
    /// No percentage (a streamed .tar.gz download): show `bytes`, `speed` and the time since `TransferJob.started`.
    public var indeterminate = false

    public init() {}
}

/// Reads scp's progress meter off the terminal: frames like "\rname   48%   14MB   5.8MB/s   00:02 ETA", parsed
/// from the right (names may contain anything). A file's last frame shows the elapsed time instead of the ETA and is
/// followed by a newline.
struct ProgressParser {
    /// While nothing arrives, scp shows "- stalled -" where the ETA goes.
    private static let frame = try! NSRegularExpression(pattern: #"^\s*(.*\S)\s+(\d+)%\s+(\S+)\s+(\S+/s)\s+(- stalled -|\S+)(\s+ETA)?\s*$"#)
    private var pending = Data()
    private(set) var progress = TransferProgress()

    /// Takes terminal output; true when the progress changed.
    mutating func feed(_ data: Data) -> Bool {
        pending.append(data)
        var changed = false
        while let end = pending.firstIndex(where: { $0 == 0x0D || $0 == 0x0A }) {
            let text = String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
            let newline = pending[end] == 0x0A
            pending.removeSubrange(pending.startIndex...end)
            if apply(text) { changed = true }
            if newline {
                progress.filesDone += 1
                changed = true
            }
        }
        // scp writes each frame whole but ends it only with the next one's "\r": show it now, not a second later.
        if !pending.isEmpty && apply(String(decoding: pending, as: UTF8.self)) { changed = true }
        return changed
    }

    private mutating func apply(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = ProgressParser.frame.firstMatch(in: text, range: range) else { return false }
        func group(_ index: Int) -> String { Range(match.range(at: index), in: text).map { String(text[$0]) } ?? "" }
        progress.file = group(1)
        progress.percent = Int(group(2)) ?? 0
        progress.bytes = ProgressParser.bytes(group(3))
        let stalled = group(5) == "- stalled -"
        progress.speed = stalled ? "stalled" : group(4)
        progress.eta = match.range(at: 6).location == NSNotFound || stalled ? "" : group(5)
        return true
    }

    /// "14MB" → 14 × 1024².
    static func bytes(_ text: String) -> Int64 {
        let number = Double(text.prefix { $0.isNumber || $0 == "." }) ?? 0
        let unit = text.drop { $0.isNumber || $0 == "." }.uppercased().prefix(1)
        let power: Double = ["K": 1, "M": 2, "G": 3, "T": 4, "P": 5][String(unit)] ?? 0
        return Int64(number * pow(1024.0, power))
    }
}


/// One upload, download or server-to-server copy, as the queue panel shows it.
public struct TransferJob: Identifiable, Equatable {
    /// `relay`: from another connected server (`sourceHostID`) to this job's host.
    public enum Direction: Equatable { case upload, download, relay }

    public enum Status: Equatable {
        case queued, running, done
        /// Stopped by Pause until Resume, through a lost connection and its reconnect too (`TransferQueue.pause`).
        case paused
        /// scp or tar gave up on some files (an unreadable file, a broken link) but copied the rest; the text is its
        /// error output.
        case completedWithErrors(String)
        case failed(AirSCPError)
        case cancelled

        public var isFinished: Bool {
            switch self {
            case .queued, .running, .paused: return false
            default: return true
            }
        }

        /// Queued or running: the host's queue is at it, or will be (a paused job waits for Resume).
        public var isActive: Bool { self == .queued || self == .running }
    }

    /// A single file's copy checked against the original (Verify with Checksum, or Settings ▸ Verify transfers with
    /// SHA-256): `TransferQueue.verify`.
    public enum Checksum: Equatable {
        /// Asked for: checked once the file has arrived, or (a finished job) when its host's queue gets to it.
        case wanted
        case checking
        /// The copy and the original have this SHA-256.
        case verified(String)
        /// They differ: the copy was damaged, or one of them changed since. Retry copies the file again.
        case mismatch(original: String, copy: String)
        /// It couldn't be checked: why.
        case unchecked(String)
    }

    public let id: UUID
    public let direction: Direction
    /// The host whose queue runs it (for a relay: the destination host).
    public let hostID: UUID
    /// A relay's source host.
    public let sourceHostID: UUID?
    /// The local path of an upload, the remote path of a download. Archive, compressed and relay jobs: the folder
    /// holding the items.
    public let source: String
    /// The final path: remote for an upload, local for a download (a download as archive: the .tar.gz). Compressed
    /// uploads and relays: the remote folder the items go into.
    public let destination: String
    /// The items of a download as archive, a compressed upload or a relay, in the folder `source`; empty for an scp
    /// job of `source` itself.
    public let names: [String]
    /// A folder transfer. For a download as archive: extract it after downloading (the items land next to it).
    public let isFolder: Bool
    /// Replace what is at `destination` (once the new copy is complete). A retry after a checksum mismatch replaces the
    /// copy that didn't match.
    public internal(set) var replacing: Bool
    /// scp -p.
    public let preserveTimes: Bool
    public var status = Status.queued
    public var progress = TransferProgress()
    /// When it started running.
    public var started: Date?
    /// This try continues what a lost connection left of an earlier one (sftp reget / reput) instead of starting again.
    public var resumed = false
    /// Leave-out patterns (`TransferQueue.patterns`): what matches is left out of this job's tar stream, at any depth.
    public var excluding: [String] = []
    /// The SHA-256 check of a single file's copy; nil: not checked.
    public var checksum: Checksum?

    /// The name at the destination.
    public var name: String { RemotePath.name(destination) }

    /// A single file, not a folder or a job of several items: it continues where it stopped, and its copy can be checked.
    public var isSingleFile: Bool { !isFolder && names.isEmpty }

    /// A finished single file whose copy can be checked now (none is due or under way).
    public var canVerify: Bool { status == .done && isSingleFile && checksum != .wanted && checksum != .checking }
}

/// A host's transfers, run one at a time (another host's run at the same time): files with scp on a pseudo-terminal
/// (for its progress); folders, archives and server-to-server copies as one tar stream through this Mac where the
/// server has a shell and tar (else scp -r). A job's partial copy is ".airscp-<id>.part" in the destination's folder:
/// downloads, uploads that replace something, folders and the items of a compressed upload or a relay arrive there and
/// take their places once complete, so an item being replaced stays as it was until then. A cancelled or failed job
/// leaves nothing behind (a new file uploaded under its own name is removed). Check for conflicts (`Names.existing`)
/// before adding. Jobs can be paused and resumed (`pause`), and a single file's copy checked against the original
/// (`verify`): the checks take their turns in the queue too.
public final class TransferQueue {
    weak var session: Session?
    let hostID: UUID
    /// All jobs, oldest first, on the main queue after changes (several changes in a row may arrive as one). (Every
    /// host's jobs: `TransferCenter.shared`.)
    public var onChange: (([TransferJob]) -> Void)?

    public var jobs: [TransferJob] { lock.locked { _jobs } }
    /// Test seam: a speed limit in Kbit/s (scp's and sftp's -l, the pump's for streams), so that a transfer lasts long
    /// enough to be cancelled or paused half-way.
    var bandwidthLimit: Int?
    /// Test seam: Settings ▸ Verify transfers with SHA-256 for this queue alone (the setting is every host's).
    var verifiesTransfers: Bool?
    /// scp's and sftp's -l (Kbit/s) for a job starting now: the test seam, else the Transfers panel's speed limit.
    private var limit: Int? { bandwidthLimit ?? TransferCenter.shared.speedLimit.map { max(1, $0 * 8 / 1024) } }
    /// The pump's limit (bytes a second) for a stream starting now: the test seam, else the panel's speed limit.
    private var streamLimit: Int? { bandwidthLimit.map { $0 * 1024 / 8 } ?? TransferCenter.shared.speedLimit }
    /// A job is queued, running or paused (confirm before quitting or disconnecting).
    public var isBusy: Bool { lock.locked { _jobs.contains { !$0.status.isFinished } } }

    /// Folders with at least this many entries go as one tar stream (when the server has a shell and tar) instead of
    /// scp -r, which costs round trips for every file.
    public static let streamThreshold = 200
    /// Finished jobs kept (the oldest go first), so that the history stays bounded.
    static let finishedLimit = 500

    private let lock = NSLock()
    private var _jobs: [TransferJob] = []
    private var working = false
    private var delivering = false
    private var cancellations: [UUID: Cancellation] = [:]
    private var parsers: [UUID: ProgressParser] = [:]
    private var meters: [UUID: Meter] = [:]
    private var lastProgressReport = Date.distantPast
    /// Single-file jobs whose last try a lost connection or Pause cut off: their partial copy is kept, and the retry (or
    /// Resume) continues it.
    private var resumable: Set<UUID> = []
    /// Running jobs that Pause is stopping: they end as paused, a single file keeping what it has copied.
    private var pausing: Set<UUID> = []

    /// A stream's speed: bytes at the start of the current sample, and the rate over the previous one.
    private struct Meter {
        var time: Date
        var bytes: Int64
        var rate: Double
    }

    init(hostID: UUID) {
        self.hostID = hostID
        TransferCenter.shared.register(self)
    }

    deinit { TransferCenter.shared.queueChanged() }  // its jobs leave the global list

    /// `excluding`: leave-out patterns for a folder that goes as a tar stream (scp -r copies it whole).
    @discardableResult
    public func upload(_ localPath: String, to remotePath: String, isFolder: Bool, replacing: Bool = false,
                       preserveTimes: Bool = false, excluding: [String] = []) -> UUID {
        add(TransferJob(id: UUID(), direction: .upload, hostID: hostID, sourceHostID: nil, source: localPath,
                        destination: remotePath, names: [], isFolder: isFolder, replacing: replacing,
                        preserveTimes: preserveTimes, excluding: excluding))
    }

    /// `excluding`: as for `upload`.
    @discardableResult
    public func download(_ remotePath: String, to localPath: String, isFolder: Bool, replacing: Bool = false,
                         preserveTimes: Bool = false, excluding: [String] = []) -> UUID {
        add(TransferJob(id: UUID(), direction: .download, hostID: hostID, sourceHostID: nil, source: remotePath,
                        destination: localPath, names: [], isFolder: isFolder, replacing: replacing,
                        preserveTimes: preserveTimes, excluding: excluding))
    }

    // MARK: Archive and server-to-server jobs

    /// Download as archive: `names` in the remote folder `dir`, streamed as one tar.gz (`cd <dir> && tar czf - --
    /// <names>` over the connection, no temporary space on the server) into the local file `archivePath` (written as
    /// its .airscp-<id>.part first). With `extract`, unpacked into the archive's folder (/usr/bin/tar -xzf; items already
    /// there with those names are replaced) and the archive removed: check conflicts for the item names then, else
    /// for the archive name. Shell hosts with tar only (`session.compressUnavailableReason(.tarGz)`). Progress is
    /// indeterminate. `excluding`: leave-out patterns.
    @discardableResult
    public func downloadArchive(_ names: [String], in dir: String, to archivePath: String, extract: Bool,
                                excluding: [String] = []) -> UUID {
        add(TransferJob(id: UUID(), direction: .download, hostID: hostID, sourceHostID: nil, source: dir,
                        destination: archivePath, names: names, isFolder: extract, replacing: false, preserveTimes: false,
                        excluding: excluding))
    }

    /// Upload compressed: `names` in the local folder `dir` streamed as one tar.gz (/usr/bin/tar, no ._ files; nothing
    /// is stored on either side first) into the remote folder `remoteDir`, where they replace what is there under those
    /// names once all have arrived; for Skip, leave those names out (`replacing` records that some replace). Progress
    /// is indeterminate (bytes and speed). Shell hosts with tar only (`session.compressUnavailableReason(.tarGz)`).
    /// `preserveTimes`: the items keep their modification times (Synchronize), else they get the time they arrive.
    /// `excluding`: leave-out patterns.
    @discardableResult
    public func uploadCompressed(_ names: [String], in dir: String, to remoteDir: String, replacing: Bool,
                                 preserveTimes: Bool = false, excluding: [String] = []) -> UUID {
        add(TransferJob(id: UUID(), direction: .upload, hostID: hostID, sourceHostID: nil, source: dir,
                        destination: remoteDir, names: names, isFolder: true, replacing: replacing, preserveTimes: preserveTimes,
                        excluding: excluding))
    }

    /// Server to server: `names` in the folder `dir` of the connected `source` copied into `remoteDir` on this
    /// queue's host. Streams `tar cf -` → `tar xf -` through this Mac when both have a shell and tar, else goes
    /// through a temporary local folder (scp down, scp up). Progress: bytes and speed against a du estimate.
    /// Check conflicts on this host first: as for compressed uploads, the items replace what is there under their
    /// names once all have arrived (leave skipped names out); `replacing` records that some do.
    @discardableResult
    public func relay(_ names: [String], in dir: String, from source: Session, to remoteDir: String,
                      replacing: Bool) -> UUID {
        add(TransferJob(id: UUID(), direction: .relay, hostID: hostID, sourceHostID: source.host.id, source: dir,
                        destination: remoteDir, names: names, isFolder: true, replacing: replacing, preserveTimes: false))
    }

    /// After an automatic reconnect (called by Session): the jobs that failed with `.disconnected` are queued again (a
    /// single file continues where it stopped, see `retry`); with `relaysFrom`, only copies from that host (it is the
    /// one that reconnected).
    func retryDisconnected(relaysFrom source: UUID? = nil) {
        lock.locked {
            for index in _jobs.indices {
                guard case .failed(let error) = _jobs[index].status, error.kind == .disconnected,
                      source == nil || (_jobs[index].direction == .relay && _jobs[index].sourceHostID == source) else { continue }
                _jobs[index].status = .queued
                _jobs[index].progress = TransferProgress()
            }
        }
        publish()
        startWorking()
    }

    /// Cancels a queued or paused job (a paused one's kept partial copy goes), or stops a running one (its partial files
    /// are then cleaned up).
    public func cancel(_ id: UUID) {
        let (running, dropped): (Cancellation?, [TransferJob]) = lock.locked {
            var dropped: [TransferJob] = []
            if let index = _jobs.firstIndex(where: { $0.id == id }), [.queued, .paused].contains(_jobs[index].status) {
                _jobs[index].status = .cancelled
                dropped.append(_jobs[index])
            }
            return (cancellations[id], dropped)
        }
        running?.cancel()
        discardPartials(dropped)
        publish()
    }

    /// Queues a finished job again. A single file that a lost connection cut off continues where it stopped (sftp
    /// reget / reput); anything else starts afresh. After a checksum mismatch the new copy replaces the one that didn't
    /// match, and is checked again.
    public func retry(_ id: UUID) {
        lock.locked {
            if let index = _jobs.firstIndex(where: { $0.id == id }), _jobs[index].status.isFinished {
                switch _jobs[index].checksum {
                case .mismatch?:
                    _jobs[index].replacing = true
                    _jobs[index].checksum = .wanted
                case .wanted?:
                    break  // the check of a retry that failed: still due
                default:
                    _jobs[index].checksum = nil
                }
                _jobs[index].status = .queued
                _jobs[index].progress = TransferProgress()
            }
        }
        publish()
        startWorking()
    }

    /// Pauses the queued and running jobs among `ids`, all at once (the host's next job doesn't start in between). A
    /// running one stops its scp, sftp or tar: a single file keeps what it has copied, and Resume continues it as after
    /// a lost connection (sftp reget / reput); a folder, archive or server-to-server copy is cleaned up and starts again.
    /// Paused jobs wait for `resume`, through a lost connection and its reconnect too.
    public func pause(_ ids: Set<UUID>) {
        let (running, changed): ([Cancellation], Bool) = lock.locked {
            var running: [Cancellation] = [], changed = false
            for index in _jobs.indices where ids.contains(_jobs[index].id) {
                switch _jobs[index].status {
                case .queued:
                    _jobs[index].status = .paused
                    changed = true
                case .running:
                    pausing.insert(_jobs[index].id)
                    if let cancellation = cancellations[_jobs[index].id] { running.append(cancellation) }
                default:
                    break
                }
            }
            return (running, changed)
        }
        running.forEach { $0.cancel() }
        if changed { publish() }
    }

    /// Queues the paused jobs among `ids` again: a single file continues where it stopped.
    public func resume(_ ids: Set<UUID>) {
        let changed: Bool = lock.locked {
            var changed = false
            for index in _jobs.indices where ids.contains(_jobs[index].id) && _jobs[index].status == .paused {
                _jobs[index].status = .queued
                _jobs[index].progress = TransferProgress()
                changed = true
            }
            return changed
        }
        guard changed else { return }
        publish()
        startWorking()
    }

    /// Checks the copies of the finished single files among `ids` against their originals (SHA-256: `checksum`), each
    /// in its turn after the host's queued transfers.
    public func verify(_ ids: Set<UUID>) {
        let changed: Bool = lock.locked {
            var changed = false
            for index in _jobs.indices where ids.contains(_jobs[index].id) && _jobs[index].canVerify {
                _jobs[index].checksum = .wanted
                changed = true
            }
            return changed
        }
        guard changed else { return }
        publish()
        startWorking()
    }

    public func clearFinished() {
        discardPartials(lock.locked {
            defer { _jobs.removeAll { $0.status.isFinished } }
            return _jobs.filter { $0.status.isFinished }
        })
        publish()
    }

    /// Removes a finished job from the list (a queued or running one stays: cancel it first).
    public func remove(_ id: UUID) {
        discardPartials(lock.locked {
            defer { _jobs.removeAll { $0.id == id && $0.status.isFinished } }
            return _jobs.filter { $0.id == id && $0.status.isFinished }
        })
        publish()
    }

    /// Cancels everything, paused jobs too, and returns once the running job has cleaned up (before disconnecting or
    /// quitting). Partial copies kept for a retry or Resume go too; copies waiting for their check aren't checked.
    public func cancelAll() async {
        let running: [Cancellation] = lock.locked {
            for index in _jobs.indices {
                if [.queued, .paused].contains(_jobs[index].status) { _jobs[index].status = .cancelled }
                if _jobs[index].status == .done && _jobs[index].checksum == .wanted { _jobs[index].checksum = nil }
            }
            return Array(cancellations.values)
        }
        running.forEach { $0.cancel() }
        publish()
        await waitUntilIdle()
        // A job that Pause was stopping meanwhile ended as paused: it is cancelled as well.
        lock.locked {
            for index in _jobs.indices where _jobs[index].status == .paused { _jobs[index].status = .cancelled }
        }
        publish()
        // Awaited: Disconnect and Quit close the connection next.
        let lines = removals(jobs)
        if let session, !lines.isEmpty, session.state == .connected { _ = try? await session.sftp(lines, slot: .transfer) }
    }

    /// Whether the job's partial copy is kept for its retry (a single file that a lost connection or Pause cut off): Retry,
    /// Resume, or the automatic retry after reconnecting, continues it.
    public func isResumable(_ id: UUID) -> Bool { lock.locked { resumable.contains(id) } }

    /// The jobs won't be retried: a partial copy kept for that goes, a download's part file here and an upload's
    /// partial file on the server (while connected: else it stays, as after any lost connection).
    private func discardPartials(_ jobs: [TransferJob]) {
        let lines = removals(jobs)
        if !lines.isEmpty, let session, session.state == .connected {
            Task { _ = try? await session.sftp(lines, slot: .transfer) }
        }
    }

    /// Forgets the jobs' kept partial copies: removes the downloads' part files, and returns the sftp lines that remove
    /// the uploads' (the temporary copy of one that replaces, else the cut-off file under its own name).
    private func removals(_ jobs: [TransferJob]) -> [String] {
        let kept = lock.locked { () -> [TransferJob] in
            let kept = jobs.filter { resumable.contains($0.id) }
            kept.forEach { resumable.remove($0.id) }
            return kept
        }
        for job in kept where job.direction == .download { unlink(TransferQueue.partPath(job)) }
        return kept.filter { $0.direction == .upload }
            .map { "-rm \(Quote.sftp($0.replacing ? TransferQueue.partPath($0) : $0.destination))" }
    }

    /// Returns when no job is running or queued.
    public func waitUntilIdle() async {
        while lock.locked({ working }) {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    /// The connection is gone: queued jobs fail (they can be retried after reconnecting).
    func failQueued(_ error: AirSCPError) {
        lock.locked {
            for index in _jobs.indices where _jobs[index].status == .queued { _jobs[index].status = .failed(error) }
        }
        publish()
    }

    // MARK: Running

    private func add(_ job: TransferJob) -> UUID {
        lock.locked { _jobs.append(job) }
        publish()
        startWorking()
        return job.id
    }

    private func startWorking() {
        let start = lock.locked { () -> Bool in
            if working { return false }
            working = true
            return true
        }
        guard start else { return }
        Task.detached { [self] in
            while let job = self.next() { await self.run(job) }
        }
    }

    /// The next queued job, marked running; else a finished file whose copy is to be checked (`verify`), marked checking;
    /// nil (and the worker stops) when there is neither.
    private func next() -> TransferJob? {
        let job: TransferJob? = lock.locked {
            if let index = _jobs.firstIndex(where: { $0.status == .queued }) {
                _jobs[index].status = .running
                _jobs[index].started = Date()
                _jobs[index].resumed = false
                cancellations[_jobs[index].id] = Cancellation()
                parsers[_jobs[index].id] = ProgressParser()
                return _jobs[index]
            }
            if let index = _jobs.firstIndex(where: { $0.status == .done && $0.checksum == .wanted }) {
                _jobs[index].checksum = .checking
                cancellations[_jobs[index].id] = Cancellation()
                return _jobs[index]
            }
            working = false
            return nil
        }
        if job != nil { publish() }
        return job
    }

    private func run(_ job: TransferJob) async {
        let cancellation = lock.locked { cancellations[job.id] } ?? Cancellation()
        if job.status == .done {  // only its copy to check (`verify`)
            var checksum: TransferJob.Checksum? = .unchecked(AirSCPError.disconnected.message)
            if let session { checksum = await self.checksum(job, session: session, cancellation: cancellation) }
            lock.locked { cancellations[job.id] = nil }
            setChecksum(job.id, checksum)
            return
        }
        let what = (job.direction == .relay ? "server-to-server copy" : "\(job.direction)") + " \(job.source) → \(job.destination)"
            + (job.names.isEmpty ? "" : " (\(job.names.count) items)")
        DebugLog.write("Transfer started: " + what, host: DebugLog.name(for: hostID))
        var status: TransferJob.Status
        if let session {
            switch job.direction {
            case .upload where job.names.isEmpty: status = await upload(job, session: session, cancellation: cancellation)
            case .download where job.names.isEmpty: status = await download(job, session: session, cancellation: cancellation)
            case .upload: status = await uploadCompressed(job, session: session, cancellation: cancellation)
            case .download: status = await downloadArchive(job, session: session, cancellation: cancellation)
            case .relay: status = await relay(job, session: session, cancellation: cancellation)
            }
            // scp says "lost connection" when the master went away under it: that is a disconnect (retried after
            // reconnecting), which -O check tells apart from the server refusing.
            if case .failed(let error) = status, error.kind != .disconnected, !(await session.check()) {
                status = .failed(AirSCPError(.disconnected, AirSCPError.disconnected.message, details: error.details))
            }
            // A server-to-server copy also stops when its source's connection ends (ssh exits 255): retried when that
            // host has reconnected (`TransferCenter.retryRelays`).
            if case .failed(let error) = status, error.kind != .disconnected, job.direction == .relay, let source = job.sourceHostID,
               !(await TransferCenter.shared.session(for: source)?.check() ?? false) {
                status = .failed(AirSCPError(.disconnected, TransferQueue.sourceLost, details: error.details))
            }
        } else {
            status = .failed(AirSCPError.disconnected)
        }
        // Pause stopped it (or a lost connection did, after Pause): it waits for Resume, a single file with what it had
        // copied (`keepsPartial`).
        if lock.locked({ pausing.contains(job.id) }) {
            if status == .cancelled { status = .paused }
            if case .failed(let error) = status, error.kind == .disconnected { status = .paused }
        }
        switch status {
        case .failed(let error):
            DebugLog.write("Transfer failed: \(what): \(error.message)" + (error.details.isEmpty ? "" : "\nThe tools' own words:\n"
                + error.details), host: DebugLog.name(for: hostID))
        case .completedWithErrors(let text):
            DebugLog.write("Transfer done, but some items weren't copied: \(what)\n" + text, host: DebugLog.name(for: hostID))
        default:
            DebugLog.write("Transfer \(status == .done ? "done" : status == .paused ? "paused" : "cancelled"): " + what,
                           host: DebugLog.name(for: hostID))
        }
        // A single file's copy, checked against the original when asked (Settings ▸ Verify transfers with SHA-256, or a
        // retry after a mismatch). The job runs ("Verifying") until then; Cancel or Pause leaves it done, unchecked.
        if status == .done, job.isSingleFile, job.checksum == .wanted || (verifiesTransfers ?? TransferCenter.shared.verifyTransfers),
           let session {
            setChecksum(job.id, .checking)
            setChecksum(job.id, await checksum(job, session: session, cancellation: cancellation))
        }
        // A single file that a lost connection or Pause cut off keeps its partial copy (`upload`, `download`) for the
        // retry or Resume.
        var cutOff = status == .paused
        if case .failed(let error) = status { cutOff = error.kind == .disconnected }
        cutOff = cutOff && job.isSingleFile
        let dropped: [TransferJob] = lock.locked {
            cancellations[job.id] = nil
            parsers[job.id] = nil
            pausing.remove(job.id)
            if cutOff { resumable.insert(job.id) } else { resumable.remove(job.id) }
            var completed = status == .done
            if case .completedWithErrors = status { completed = true }
            let streamed = meters.removeValue(forKey: job.id) != nil
            if let index = _jobs.firstIndex(where: { $0.id == job.id }) {
                _jobs[index].status = status
                if streamed && completed {
                    _jobs[index].progress.percent = 100
                    _jobs[index].progress.eta = ""
                }
            }
            let excess = _jobs.filter { $0.status.isFinished }.count - TransferQueue.finishedLimit
            guard excess > 0 else { return [] }
            let oldest = Array(_jobs.lazy.filter { $0.status.isFinished }.prefix(excess))
            let ids = Set(oldest.map(\.id))
            _jobs.removeAll { ids.contains($0.id) }
            return oldest
        }
        discardPartials(dropped)
        publish()
        // A copy stopped by its source's lost connection whose source has reconnected already (before this copy noticed
        // its end) runs again now: that host's `retryRelays` came too early for it. Only while this host is connected:
        // a copy to a host that is away would fail at once, again and again.
        if job.direction == .relay, case .failed(let error) = status, error.message == TransferQueue.sourceLost,
           let source = job.sourceHostID, session?.state == .connected,
           await TransferCenter.shared.session(for: source)?.check() == true {
            retryDisconnected(relaysFrom: source)
        }
    }

    /// Why a server-to-server copy stopped when its source's connection ended.
    static let sourceLost = "The connection to the server copied from was lost."

    private func upload(_ job: TransferJob, session: Session, cancellation: Cancellation) async -> TransferJob.Status {
        // A replaced item, and every folder, arrives under a temporary name in its folder and takes its place once
        // complete: a cancelled or failed upload leaves the item it was to replace as it was, and no partial folder
        // under its name. A new file goes straight to its name.
        let staged = job.replacing || job.isFolder
        let target = staged ? TransferQueue.partPath(job) : job.destination
        do {
            var errors: String?
            // A file this Mac can't read would make its tar stop there (and say only that it couldn't read it): such a
            // folder goes with scp -r, which leaves those out and copies the rest.
            let local = job.isFolder && TransferQueue.canStream(session)
                ? try TransferQueue.localEstimate(job.source, cancellation: cancellation) : nil
            if let local, local.unreadable == 0 {
                errors = try await uploadAsTar(job, into: target, session: session, cancellation: cancellation,
                                               total: local.bytes)
            } else {
                if job.isFolder {
                    try? await session.deleteFolders([target], slot: .transfer)  // an earlier try's: scp would copy into it
                } else {
                    setTotal(job.id, TransferQueue.localSize(job.source))
                }
                if try await !resume(job, into: target, session: session, cancellation: cancellation) {
                    let argv = OpenSSH.upload(job.source, to: target, folder: job.isFolder, preserveTimes: job.preserveTimes,
                                              session.host, jump: session.jump, socket: session.socketPath, limit: limit)
                    let result = try await session.runMuxed(argv, cancellation: cancellation, terminal: { self.progress(job.id, $0) })
                    if result.status != 0 {
                        guard job.isFolder && result.status == 1 && filesDone(job.id) > 0 else {
                            throw ErrorMapping.map(result.stderr, status: result.status)
                        }
                        errors = result.stderr
                    }
                }
            }
            if cancellation.isCancelled { throw AirSCPError.cancelled }
            if staged {
                try await session.moveIntoPlace(target, to: job.destination, folder: job.isFolder, replacing: job.replacing,
                                                slot: .transfer)
            }
            return errors.map { .completedWithErrors($0) } ?? .done
        } catch {
            // What this job made is partial: its temporary copy goes (an item it was to replace is untouched), and so
            // does a new file scp was writing when cancelled or when the disk filled up. A file that a lost connection
            // or Pause cut off stays for the retry or Resume to continue.
            let kind = (error as? AirSCPError)?.kind
            if job.isFolder {
                try? await session.deleteFolders([target], slot: .transfer)
            } else if !keepsPartial(job, after: error) && (staged || kind == .cancelled || kind == .diskFull) {
                _ = try? await session.sftp(["rm \(Quote.sftp(target))"], slot: .transfer)
            }
            return TransferQueue.status(for: error)
        }
    }

    /// The job's single file stopped with its partial copy intact, for the next try to continue: a lost connection cut
    /// it off, or Pause stopped it (`pausing`, set before its processes were stopped).
    private func keepsPartial(_ job: TransferJob, after error: Error) -> Bool {
        let kind = (error as? AirSCPError)?.kind
        return kind == .disconnected || kind == .cancelled && lock.locked { pausing.contains(job.id) }
    }

    /// A retry (or Resume) of a single file that a lost connection or Pause cut off: continues its partial copy `partial`
    /// (the local part file of a download, the remote file of an upload) with sftp's reget or reput, on a terminal for
    /// sftp's progress meter (scp's format). False when this job has no partial copy to continue, or sftp couldn't (it is
    /// gone, or not smaller than the source): then it starts afresh. A lost connection or a cancel throws, as for scp.
    private func resume(_ job: TransferJob, into partial: String, session: Session, cancellation: Cancellation) async throws -> Bool {
        guard !job.isFolder, lock.locked({ resumable.contains(job.id) }) else { return false }
        // A download's kept part must still be there: sftp's reget would start again from 0 into a missing one.
        if job.direction == .download && (TransferQueue.localSize(partial) ?? 0) == 0 { return false }
        try session.ensureConnected()  // (not yet reconnected: nothing resumed)
        setResumed(job.id, true)
        let command = (job.direction == .download ? "reget" : "reput") + (job.preserveTimes ? " -p" : "")
        let result = try await session.runMuxed(OpenSSH.sftpBatch(session.host, jump: session.jump, socket: session.socketPath,
                                                                  limit: limit),
                                                input: "progress\n\(command) \(Quote.sftp(job.source)) \(Quote.sftp(partial))\n",
                                                cancellation: cancellation, terminal: { self.progress(job.id, $0) })
        if result.status != 0 { setResumed(job.id, false) }
        return result.status == 0
    }

    private func setResumed(_ id: UUID, _ resumed: Bool) {
        lock.locked { if let index = _jobs.firstIndex(where: { $0.id == id }) { _jobs[index].resumed = resumed } }
        publish()
    }

    private func setChecksum(_ id: UUID, _ checksum: TransferJob.Checksum?) {
        lock.locked { if let index = _jobs.firstIndex(where: { $0.id == id }) { _jobs[index].checksum = checksum } }
        publish()
    }

    /// A single file's copy checked against the original: their SHA-256, worked out where each one is (the server's
    /// with `sha256(_:on:)`, this Mac's in AirSCP). nil when cancelled.
    private func checksum(_ job: TransferJob, session: Session, cancellation: Cancellation) async -> TransferJob.Checksum? {
        let (local, remote) = job.direction == .upload ? (job.source, job.destination) : (job.destination, job.source)
        let checksum: TransferJob.Checksum
        do {
            let server = try await TransferQueue.sha256(remote, on: session, cancellation: cancellation)
            let mac = try TransferQueue.sha256(local, cancellation: cancellation)
            let (original, copy) = job.direction == .upload ? (mac, server) : (server, mac)
            checksum = original == copy ? .verified(copy) : .mismatch(original: original, copy: copy)
        } catch {
            if cancellation.isCancelled { return nil }
            checksum = .unchecked((error as? AirSCPError)?.message ?? error.localizedDescription)
        }
        DebugLog.write("Checksum of \(job.source) → \(job.destination): \(checksum)", host: DebugLog.name(for: hostID))
        return checksum
    }

    /// A folder as one stream: this Mac's tar into tar -x on the server, in `target` (made new). Symbolic links stay
    /// links (scp copies what they point to; following them in tar would never end on a link to a folder above).
    private func uploadAsTar(_ job: TransferJob, into target: String, session: Session, cancellation: Cancellation,
                             total: Int64) async throws -> String? {
        try session.ensureConnected()
        let producer = [TransferQueue.localTar, "-c", "-f", "-", "--format", "gnutar", "--no-mac-metadata", "--no-xattrs",
                        "--no-fflags"] + TransferQueue.excludes(job.excluding) + ["-C", job.source, "."]
        let (consumer, preamble) = try TransferQueue.consumer(unpack: TransferQueue.untar(preserveTimes: job.preserveTimes),
                                                          folder: target, on: session)
        startStream(job.id, label: RemotePath.name(job.source), total: total)
        let pumped = await Runner.pump(producer, environment: ["COPYFILE_DISABLE": "1"], hostID: session.host.id,
                                       log: session.emit, into: .command(consumer, environment: [:], hostID: session.host.id,
                                                                         log: session.emit),
                                       after: nil, cancellation: cancellation, limit: streamLimit,
                                       preamble: preamble) {
            self.streamed(job.id, $0)
        }
        streamed(job.id, pumped.bytes, final: true)
        return try outcome(pumped, cancellation: cancellation, producer: nil, consumer: session)
    }

    private func download(_ job: TransferJob, session: Session, cancellation: Cancellation) async -> TransferJob.Status {
        let fileManager = FileManager.default
        let part = TransferQueue.partPath(job)
        if job.isFolder || !lock.locked({ resumable.contains(job.id) }) { try? fileManager.removeItem(atPath: part) }
        do {
            var errors: String?
            // A symbolic link comes as a folder job (what it points to isn't listed): one to a file goes as a file.
            var folder = job.isFolder
            let streams = folder && TransferQueue.canStream(session)
            let estimate = streams ? try await remoteEstimate(on: session, in: job.source, operands: ["."], clashes: true,
                                                              cancellation: cancellation) : nil
            if estimate?.folder == false { folder = false }
            if streams && folder {
                errors = try await downloadAsTar(job, part: part, session: session, cancellation: cancellation,
                                                 total: estimate?.bytes)
                if let clashes = estimate?.clashes, !clashes.isEmpty, TransferQueue.ignoresCase(RemotePath.parent(job.destination)) {
                    errors = ([errors].compactMap { $0 } + [TransferQueue.clashMessage(clashes)]).joined(separator: "\n")
                }
            } else {
                if !folder, let tooLong = TransferQueue.tooLong(job.source) { throw tooLong }
                if try await !resume(job, into: part, session: session, cancellation: cancellation) {
                    try? fileManager.removeItem(atPath: part)  // what sftp couldn't continue
                    let argv = OpenSSH.download(job.source, to: part, folder: folder, preserveTimes: job.preserveTimes,
                                                session.host, jump: session.jump, socket: session.socketPath, limit: limit)
                    let result = try await session.runMuxed(argv, cancellation: cancellation, terminal: { self.progress(job.id, $0) })
                    let partial = folder && result.status == 1 && fileManager.fileExists(atPath: part)
                    guard result.status == 0 || partial else { throw ErrorMapping.map(result.stderr, status: result.status) }
                    if partial { errors = result.stderr }
                }
            }
            try TransferQueue.moveIntoPlace(part, to: job.destination, replacing: job.replacing)
            return errors.map { .completedWithErrors($0) } ?? .done
        } catch {
            // A file that a lost connection or Pause cut off keeps what arrived, for the retry or Resume to continue
            // (`resumable`).
            if job.isFolder || !keepsPartial(job, after: error) { try? fileManager.removeItem(atPath: part) }
            return TransferQueue.status(for: error)
        }
    }

    /// A folder as one stream: tar on the server into this Mac's tar -x, in the part folder. Symbolic links stay links,
    /// as for uploads.
    private func downloadAsTar(_ job: TransferJob, part: String, session: Session, cancellation: Cancellation,
                               total: Int64?) async throws -> String? {
        guard mkdir(part, 0o755) == 0 else {
            throw AirSCPError(.other, "Can't create \(RemotePath.name(part)): \(String(cString: strerror(errno)))")
        }
        let (producer, input) = TransferQueue.remoteScript(
            TransferQueue.streamScript(in: job.source, "-cf - " + TransferQueue.remoteExcludes(job.excluding) + "."), on: session)
        let consumer = ["/bin/sh", "-c", "cd \"$1\" && " + TransferQueue.untar(preserveTimes: job.preserveTimes,
                                                                             tar: TransferQueue.localTar), "sh", part]
        startStream(job.id, label: job.name, total: total)
        let pumped = await Runner.pump(producer, input: input, hostID: session.host.id, log: session.emit,
                                       into: .command(consumer, environment: [:], hostID: session.host.id, log: session.emit),
                                       after: TransferQueue.marker, cancellation: cancellation,
                                       limit: streamLimit) { self.streamed(job.id, $0) }
        streamed(job.id, pumped.bytes, final: true)
        return try outcome(pumped, cancellation: cancellation, producer: session, consumer: nil)
    }

    private func downloadArchive(_ job: TransferJob, session: Session, cancellation: Cancellation) async -> TransferJob.Status {
        let part = TransferQueue.partPath(job)
        unlink(part)
        do {
            try TransferQueue.requireTar(session)
            guard !job.names.isEmpty else { throw AirSCPError(.other, "Nothing to download.") }
            try session.ensureConnected()
            let file = open(part, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
            guard file >= 0 else {
                throw AirSCPError(.other, "Can't create \(RemotePath.name(part)): \(String(cString: strerror(errno)))")
            }
            let (producer, input) = TransferQueue.remoteScript(TransferQueue.streamScript(
                in: job.source, "-czf - " + TransferQueue.remoteExcludes(job.excluding) + "-- " + TransferQueue.operands(job.names)),
                on: session)
            startStream(job.id, label: job.name, total: nil)
            let pumped = await Runner.pump(producer, input: input, hostID: session.host.id, log: session.emit,
                                           into: .file(file), after: TransferQueue.marker, cancellation: cancellation,
                                           limit: streamLimit) { self.streamed(job.id, $0) }
            streamed(job.id, pumped.bytes, final: true)
            var errors = try outcome(pumped, cancellation: cancellation, producer: session, consumer: nil)
            if job.isFolder {
                let clashes = try await extract(part, names: job.names, into: RemotePath.parent(job.destination), session: session,
                                                cancellation: cancellation)
                unlink(part)
                if !clashes.isEmpty { errors = ([errors].compactMap { $0 } + [TransferQueue.clashMessage(clashes)]).joined(separator: "\n") }
            } else {
                try TransferQueue.moveIntoPlace(part, to: job.destination, replacing: false)
            }
            return errors.map { .completedWithErrors($0) } ?? .done
        } catch {
            unlink(part)
            return TransferQueue.status(for: error)
        }
    }

    /// Unpacks a downloaded archive next to it: into a hidden folder first, then each item moved into place (an item
    /// already there with that name is replaced). Returns the archive's paths that another one overwrote on the way:
    /// names that differ only in case (on a disk that ignores case) or in their Unicode form (this Mac's disks don't
    /// tell those apart).
    private func extract(_ archive: String, names: [String], into dir: String, session: Session,
                         cancellation: Cancellation) async throws -> [String] {
        let staging = dir + "/.airscp-extract-" + UUID().uuidString.prefix(8)
        guard mkdir(staging, 0o700) == 0 else {
            throw AirSCPError(.other, "Can't extract in \(RemotePath.name(dir)): \(String(cString: strerror(errno)))")
        }
        defer { try? FileManager.default.removeItem(atPath: staging) }
        let result = await Runner.run([TransferQueue.localTar, "-x", "-f", archive, "-C", staging], cancellation: cancellation,
                                      hostID: session.host.id, log: session.emit)
        if cancellation.isCancelled { throw AirSCPError.cancelled }
        guard result.status == 0 else {
            throw ErrorMapping.mapLocal(result.stderr, status: result.status)
        }
        let listed = await Runner.run([TransferQueue.localTar, "-t", "-f", archive], cancellation: cancellation)
        let ignoreCase = TransferQueue.ignoresCase(dir)
        let paths = listed.output.split(separator: "\n").map { String($0.drop { $0 == "." }.drop { $0 == "/" }) }
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }.filter { !$0.isEmpty }
        let clashes = TransferQueue.clashes(paths, ignoringCase: ignoreCase)
        for name in names {
            var info = stat()
            let item = staging + "/" + name, target = dir + "/" + name
            guard lstat(item, &info) == 0 else { continue }  // tar on the server couldn't read it
            if lstat(target, &info) == 0 { try FileManager.default.removeItem(atPath: target) }
            guard rename(item, target) == 0 else {
                throw AirSCPError(.other, "Can't move \(name) into place: \(String(cString: strerror(errno)))")
            }
        }
        return clashes
    }

    /// Upload compressed: one tar.gz stream from this Mac's tar into tar -xz on the server, in a hidden folder there;
    /// the items take their places (replacing what is there) once it is complete.
    private func uploadCompressed(_ job: TransferJob, session: Session, cancellation: Cancellation) async -> TransferJob.Status {
        let staging = TransferQueue.partPath(job)
        do {
            try TransferQueue.requireTar(session)
            guard !job.names.isEmpty else { throw AirSCPError(.other, "Nothing to upload.") }
            try session.ensureConnected()
            // The names on standard input: there may be more than a command line takes.
            let producer = [TransferQueue.localTar, "-c", "-z", "-f", "-", "--format", "gnutar", "--no-mac-metadata",
                            "--no-xattrs", "--no-fflags"] + TransferQueue.excludes(job.excluding)
                + ["-C", job.source, "--null", "-T", "-"]
            let names = job.names.map { "./" + $0 + "\0" }.joined()
            let (consumer, preamble) = try TransferQueue.consumer(unpack: "tar -xz\(job.preserveTimes ? "" : "m")f - && exec cat >/dev/null",
                                                              folder: staging, on: session)
            startStream(job.id, label: TransferQueue.label(job.names), total: nil)
            let pumped = await Runner.pump(producer, input: names, environment: ["COPYFILE_DISABLE": "1"],
                                           hostID: session.host.id, log: session.emit,
                                           into: .command(consumer, environment: [:], hostID: session.host.id, log: session.emit),
                                           after: nil, cancellation: cancellation, limit: streamLimit,
                                           preamble: preamble) {
                self.streamed(job.id, $0)
            }
            streamed(job.id, pumped.bytes, final: true)
            let errors = try outcome(pumped, cancellation: cancellation, producer: nil, consumer: session)
            try await session.moveItemsIntoPlace(from: staging, replacing: job.replacing, slot: .transfer)
            return errors.map { .completedWithErrors($0) } ?? .done
        } catch {
            try? await session.deleteFolders([staging], slot: .transfer)
            return TransferQueue.status(for: error)
        }
    }

    private func relay(_ job: TransferJob, session: Session, cancellation: Cancellation) async -> TransferJob.Status {
        guard let sourceID = job.sourceHostID, let source = TransferCenter.shared.session(for: sourceID) else {
            return .failed(AirSCPError(.disconnected, "The server to copy from isn't connected."))
        }
        let master = source.masterNumber
        // Into a hidden folder on the destination first; the items take their places once all have arrived.
        let staging = TransferQueue.partPath(job)
        do {
            guard !job.names.isEmpty else { throw AirSCPError(.other, "Nothing to copy.") }
            let errors: String?
            if TransferQueue.canStream(source) && TransferQueue.canStream(session) {
                errors = try await relayAsTar(job, from: source, to: session, into: staging, cancellation: cancellation)
            } else {
                errors = try await relayThroughMac(job, from: source, to: session, into: staging, cancellation: cancellation)
            }
            if cancellation.isCancelled { throw AirSCPError.cancelled }
            try await session.moveItemsIntoPlace(from: staging, replacing: job.replacing, slot: .transfer)
            return errors.map { .completedWithErrors($0) } ?? .done
        } catch {
            try? await session.deleteFolders([staging], slot: .transfer)
            // The source's connection ended under the copy (ssh exits 255) and may be back already: a busy Mac noticed
            // the copy's end only after the host had reconnected by itself, and the copy wasn't run again.
            if (error as? AirSCPError)?.kind != .cancelled, source.masterNumber != master {
                return .failed(AirSCPError(.disconnected, TransferQueue.sourceLost, details: (error as? AirSCPError)?.details ?? ""))
            }
            return TransferQueue.status(for: error)
        }
    }

    /// Server to server as one stream through this Mac: tar on the source into tar -x on this queue's host, in
    /// `staging` (symbolic links stay links; modification times and permissions are kept).
    private func relayAsTar(_ job: TransferJob, from source: Session, to session: Session, into staging: String,
                            cancellation: Cancellation) async throws -> String? {
        let total = try await remoteEstimate(on: source, in: job.source, operands: job.names.map { "./" + $0 },
                                             clashes: false, cancellation: cancellation)?.bytes
        try source.ensureConnected()
        try session.ensureConnected()
        let (producer, input) = TransferQueue.remoteScript(
            TransferQueue.streamScript(in: job.source, "-cf - -- " + TransferQueue.operands(job.names)), on: source)
        let (consumer, preamble) = try TransferQueue.consumer(unpack: TransferQueue.untar(preserveTimes: true),
                                                          folder: staging, on: session)
        startStream(job.id, label: TransferQueue.label(job.names), total: total)
        let pumped = await Runner.pump(producer, input: input, hostID: source.host.id, log: source.emit,
                                       into: .command(consumer, environment: [:], hostID: session.host.id, log: session.emit),
                                       after: TransferQueue.marker, cancellation: cancellation,
                                       limit: streamLimit, preamble: preamble) { self.streamed(job.id, $0) }
        streamed(job.id, pumped.bytes, final: true)
        return try outcome(pumped, cancellation: cancellation, producer: source, consumer: session)
    }

    /// Server to server through a temporary folder on this Mac (one side has no shell or no tar): scp down, scp up into
    /// `staging` (-p; links become what they point to, as scp does).
    private func relayThroughMac(_ job: TransferJob, from source: Session, to session: Session, into staging: String,
                                 cancellation: Cancellation) async throws -> String? {
        let temp = FileManager.default.temporaryDirectory.path + "/airscp-relay-" + UUID().uuidString
        guard mkdir(temp, 0o700) == 0 else {
            throw AirSCPError(.other, "Can't create a temporary folder: \(String(cString: strerror(errno)))")
        }
        defer { try? FileManager.default.removeItem(atPath: temp) }
        var errors: [String] = []
        var fetched: [String] = []
        for name in job.names {
            let argv = OpenSSH.download(RemotePath.join(job.source, name), to: temp + "/" + name, folder: true,
                                        preserveTimes: true, source.host, jump: source.jump, socket: source.socketPath,
                                        limit: limit)
            let result = try await source.runMuxed(argv, cancellation: cancellation, terminal: { self.progress(job.id, $0) })
            if result.status != 0 {
                guard result.status == 1 && access(temp + "/" + name, F_OK) == 0 else {
                    throw ErrorMapping.map(result.stderr, status: result.status)
                }
                errors.append(result.stderr)
            }
            fetched.append(name)
        }
        try? await session.deleteFolders([staging], slot: .transfer)  // an earlier try's
        try await session.sftp(["mkdir \(Quote.sftp(staging))"], slot: .transfer)
        for name in fetched {
            let argv = OpenSSH.upload(temp + "/" + name, to: RemotePath.join(staging, name), folder: true, preserveTimes: true,
                                      session.host, jump: session.jump, socket: session.socketPath, limit: limit)
            let result = try await session.runMuxed(argv, cancellation: cancellation, terminal: { self.progress(job.id, $0) })
            if result.status != 0 {
                guard result.status == 1 else { throw ErrorMapping.map(result.stderr, status: result.status) }
                errors.append(result.stderr)
            }
        }
        return errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    /// What `operands` in `dir` hold, from find and du on the server: entries (each operand and everything in it),
    /// about the bytes of their tar stream (du's apparent size where it has one, plus a header per entry), and with
    /// `clashes` up to 20 paths that another one there differs from only in case. `folder` false: `dir` is no folder
    /// (a link to a file, a special file), and nothing else is known; a link to nothing throws. nil when the server
    /// couldn't tell (the stream itself then reports why).
    private func remoteEstimate(on session: Session, in dir: String, operands: [String], clashes: Bool, cancellation: Cancellation)
        async throws -> (entries: Int, bytes: Int64, clashes: [String], folder: Bool)? {
        let list = operands.map(Quote.shell).joined(separator: " "), folder = Quote.shell(dir)
        var script = "printf 'count %s\\n' \"$(find \(list) 2>/dev/null | wc -l)\"; "
            + "if du -sb /dev/null >/dev/null 2>&1; then echo 'unit 1'; du -sb -- \(list) 2>/dev/null; "
            + "else echo 'unit 1024'; du -sk -- \(list) 2>/dev/null; fi; "
        if clashes { script += "find \(list) 2>/dev/null | LC_ALL=C sort -f | uniq -di | head -n 20 | sed 's/^/clash /'; " }
        script = "if [ -d \(folder) ]; then cd \(folder) && { \(script)}; elif [ -L \(folder) ] && [ ! -e \(folder) ]; "
            + "then echo 'broken link'; else echo 'not a folder'; fi; true"
        let output = try await session.shell(script, slot: .transfer, cancellation: cancellation)
        var entries: Int?, unit: Int64 = 1024, sum: Int64 = 0, clashing: [String] = []
        for line in output.split(separator: "\n") {
            if line == "broken link" {
                // It is there (a refresh shows it again): what it points to isn't.
                throw AirSCPError(.noSuchFile, "It is a symbolic link to something that isn't there (a broken link, or links "
                                  + "that point at each other): there is nothing to copy.")
            } else if line == "not a folder" {
                return (0, 0, [], false)
            } else if line.hasPrefix("count ") {
                entries = Int(line.dropFirst(6).trimmingCharacters(in: .whitespaces))
            } else if line.hasPrefix("unit ") {
                unit = Int64(line.dropFirst(5)) ?? 1024
            } else if line.hasPrefix("clash ") {
                clashing.append(String(line.dropFirst(6)))
            } else if let number = Int64(line.prefix { $0.isASCII && $0.isNumber }) {
                sum += number
            }
        }
        guard let entries else { return nil }
        return (entries, unit == 1 ? sum + Int64(entries) * 768 : sum * 1024, clashing, true)
    }

    /// Terminal output of the running scp (on a background thread).
    private func progress(_ id: UUID, _ data: Data) {
        let report = lock.locked { () -> Bool in
            guard var parser = parsers[id] else { return false }
            let changed = parser.feed(data)
            parsers[id] = parser
            guard changed else { return false }
            if let index = _jobs.firstIndex(where: { $0.id == id }) {
                let total = _jobs[index].progress.total
                _jobs[index].progress = parser.progress
                _jobs[index].progress.total = total
            }
            // Folders of small files produce many frames; ten updates a second are plenty.
            guard Date().timeIntervalSince(lastProgressReport) >= 0.1 else { return false }
            lastProgressReport = Date()
            return true
        }
        if report { publish() }
    }

    /// A stream begins: its progress is bytes and speed, against `total` when known (else indeterminate).
    private func startStream(_ id: UUID, label: String, total: Int64?) {
        lock.locked {
            meters[id] = Meter(time: Date(), bytes: 0, rate: 0)
            if let index = _jobs.firstIndex(where: { $0.id == id }) {
                _jobs[index].progress.file = label
                _jobs[index].progress.total = total
                _jobs[index].progress.indeterminate = total == nil
            }
        }
        publish()
    }

    /// A stream has carried `bytes` so far (on a background thread, after every chunk): at most ten updates a second,
    /// and the `final` count.
    private func streamed(_ id: UUID, _ bytes: Int64, final: Bool = false) {
        let report = lock.locked { () -> Bool in
            let now = Date()
            guard final || now.timeIntervalSince(lastProgressReport) >= 0.1, var meter = meters[id],
                  let index = _jobs.firstIndex(where: { $0.id == id }) else { return false }
            lastProgressReport = now
            // The speed over the last second or so.
            let elapsed = now.timeIntervalSince(meter.time)
            if elapsed >= 1 || meter.rate == 0 && elapsed > 0.2 {
                meter = Meter(time: now, bytes: bytes, rate: Double(bytes - meter.bytes) / elapsed)
                meters[id] = meter
            }
            var progress = _jobs[index].progress
            progress.bytes = bytes
            progress.speed = meter.rate > 0 ? TransferQueue.speed(meter.rate) : ""
            if let total = progress.total, total > 0 {
                progress.percent = Int(min(99, bytes * 100 / total))
                progress.eta = meter.rate > 0 ? TransferQueue.duration(Double(max(0, total - bytes)) / meter.rate) : ""
            }
            _jobs[index].progress = progress
            return true
        }
        if report { publish() }
    }

    /// The size of a single file's transfer, known before it starts (the Size column).
    private func setTotal(_ id: UUID, _ total: Int64?) {
        lock.locked {
            if let index = _jobs.firstIndex(where: { $0.id == id }) { _jobs[index].progress.total = total }
        }
    }

    private func filesDone(_ id: UUID) -> Int {
        lock.locked { _jobs.first { $0.id == id }?.progress.filesDone ?? 0 }
    }

    /// Tells the job's owner on the main queue; changes that come while a delivery is pending go with it.
    private func publish() {
        let deliver = lock.locked { () -> Bool in
            defer { delivering = true }
            return !delivering
        }
        if deliver {
            DispatchQueue.main.async {
                let jobs = self.lock.locked { () -> [TransferJob] in
                    self.delivering = false
                    return self._jobs
                }
                self.onChange?(jobs)
            }
        }
        TransferCenter.shared.queueChanged()
    }

    // MARK: Helpers

    static let localTar = "/usr/bin/tar"
    /// Ends a remote login shell's noise before a stream (see `streamScript`).
    static let marker = Data("\n__AIRSCP__\n".utf8)

    /// A remote tar consumer that unpacks a stream into `folder`, made fresh, then runs `unpack` (a tar reading the
    /// stream on standard input). The folder comes from the server (a path the user browsed into), so it must not reach
    /// the login shell's command line: a non-POSIX login shell — fish, csh, tcsh — mis-reads even a correctly
    /// single-quoted name there and can run commands a name contains. The login shell gets only this fixed script
    /// (no backslash, "!" or newline, so every shell quotes it safely), which takes the folder as the first line of its
    /// standard input: the `read` builtin stops at that newline byte-for-byte and leaves the archive after it for tar
    /// (unlike `sh -s`, which would over-read the pipe). `preamble` is that line; the pump writes it before the stream.
    /// The marker goes first on error output (login noise before it is dropped) with `echo`, so the script holds no
    /// backslash either. Returns the ssh command and the preamble to give `Runner.pump`. A folder whose path has a line
    /// break is refused before anything runs: `read` would cut the path there, and rm -rf remove another folder.
    static func consumer(unpack: String, folder: String, on session: Session) throws -> (argv: [String], preamble: Data) {
        guard !folder.contains("\n") else {
            throw AirSCPError(.other, "AirSCP can't copy into this folder: a folder on its path has a line break in its name. "
                + "Rename that folder on the server, then try again.", details: RemotePath.parent(folder))
        }
        let script = "echo >&2; echo __AIRSCP__ >&2; IFS= read -r d && rm -rf -- \"$d\" && mkdir -- \"$d\" && cd -- \"$d\" && " + unpack
        return (OpenSSH.remote("exec sh -c " + Quote.shell(script), session.host, jump: session.jump, socket: session.socketPath),
                Data((folder + "\n").utf8))
    }

    /// ssh running a stream's `script` on `session`'s server, and what goes to its standard input: the script itself
    /// when it is too long for a command line (many names).
    static func remoteScript(_ script: String, on session: Session) -> (argv: [String], input: String?) {
        let (command, input) = OpenSSH.longScript(script)
        return (OpenSSH.remote(command, session.host, jump: session.jump, socket: session.socketPath), input)
    }

    /// The sh script of a tar stream from the server: the marker on its error output (what a login shell printed before
    /// it is noise, not why a folder can't be entered), into `dir`, the marker on its output (what came before is
    /// dropped), then tar with these arguments. bsdtar (macOS and BSD servers) writes the GNU format, like GNU tar does
    /// by default: names go as their bytes (bsdtar's own format has UTF-8 names, which this Mac's tar extracts
    /// decomposed, NFD); and on macOS without looking for Mac metadata, which is ten times slower.
    static func streamScript(in dir: String, _ arguments: String) -> String {
        "printf '\\n__AIRSCP__\\n' >&2 && cd \(Quote.shell(dir)) && printf '\\n__AIRSCP__\\n' && "
            + "case $(tar --version 2>/dev/null) in *bsdtar*) export COPYFILE_DISABLE=1; set -- --format gnutar;; "
            + "*) set --;; esac && exec tar \"$@\" \(arguments)"
    }

    /// A job's partial copy, in its destination's folder: ".airscp-<id>.part" (a download's file or folder, an upload's
    /// temporary copy, or the hidden folder a compressed upload or a relay unpacks into). Of a fixed length, so that
    /// a name of 255 bytes can still be downloaded; of its own, so that two jobs never share one.
    static func partPath(_ job: TransferJob) -> String {
        // Compressed uploads and relays name the folder their items go into; other jobs the item (or archive) itself.
        let dir = !job.names.isEmpty && job.direction != .download ? job.destination : RemotePath.parent(job.destination)
        return RemotePath.join(dir, partName(job.id))
    }

    static func partName(_ id: UUID) -> String {
        ".airscp-" + id.uuidString.prefix(8).lowercased() + ".part"
    }

    /// "a.txt", or "3 items".
    static func label(_ names: [String]) -> String {
        names.count == 1 ? names[0] : "\(names.count) items"
    }

    static func localSize(_ path: String) -> Int64? {
        var info = stat()
        return stat(path, &info) == 0 ? Int64(info.st_size) : nil
    }

    /// The SHA-256 of a file on the server, in lower-case hex: sha256sum (GNU's or BusyBox's), else shasum (Perl's, as
    /// on macOS), else the BSDs' sha256. A shell account only (`Session.shell`); the transfer slot, so a check waits for
    /// no listing and holds none up.
    static func sha256(_ path: String, on session: Session, cancellation: Cancellation) async throws -> String {
        let file = Quote.shell(path)
        let output = try await session.shell("if command -v sha256sum >/dev/null 2>&1; then sha256sum -- \(file); "
            + "elif command -v shasum >/dev/null 2>&1; then shasum -a 256 -- \(file); "
            + "elif command -v sha256 >/dev/null 2>&1; then sha256 -q -- \(file); "
            + "else echo 'The server has no sha256sum, shasum or sha256 to work out a checksum with.' >&2; exit 127; fi",
            slot: .transfer, cancellation: cancellation)
        // "<hash>  <name>" (GNU puts a "\" first when it escaped the name), or the hash alone.
        let hash = String(output.drop { $0 == "\\" }.prefix(64)).lowercased()
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else {
            throw AirSCPError(.other, "The server's checksum tool didn't answer with a checksum.", details: output)
        }
        return hash
    }

    /// The SHA-256 of a file on this Mac, in lower-case hex, read a megabyte at a time.
    static func sha256(_ path: String, cancellation: Cancellation) throws -> String {
        let file = open(path, O_RDONLY | O_CLOEXEC)
        guard file >= 0 else {
            let failure = errno
            throw AirSCPError(failure == ENOENT ? .noSuchFile : .other,
                              "Can't read \(RemotePath.name(path)) on this Mac: \(String(cString: strerror(failure))).")
        }
        defer { close(file) }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            if cancellation.isCancelled { throw AirSCPError.cancelled }
            let count = read(file, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw AirSCPError(.other, "Can't read \(RemotePath.name(path)) on this Mac: \(String(cString: strerror(errno))).")
            }
            buffer.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0.prefix(count))) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Whether names that differ only in case are one file in this Mac's folder (APFS and HFS+ as a rule).
    public static func ignoresCase(_ dir: String) -> Bool {
        let values = try? URL(fileURLWithPath: dir).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return values?.volumeSupportsCaseSensitiveNames != true
    }

    /// The paths that another one there differs from only in case (`ignoringCase`) or in its Unicode form (this Mac's
    /// disks keep one of them). Each path once, by its bytes: a Set<String> made "café" composed and decomposed one (Swift
    /// compares them as equal), and their clash went unsaid.
    static func clashes(_ paths: [String], ignoringCase: Bool) -> [String] {
        var seen = Set<Data>()
        let distinct = paths.filter { seen.insert(Data($0.utf8)).inserted }
        return Dictionary(grouping: distinct, by: { Names.key($0, caseInsensitive: ignoringCase) }).values.filter { $0.count > 1 }
            .flatMap { $0 }.sorted()
    }

    static func clashMessage(_ paths: [String]) -> String {
        "Some names differ only in case or in how an accent is stored, and this Mac's disk keeps one of each: "
            + paths.map { String($0.drop { $0 == "." }.drop { $0 == "/" }) }.joined(separator: ", ")
    }

    /// The Mac's scp and sftp cut a remote path at 1,023 bytes: a file there can't be fetched by itself.
    static func tooLong(_ path: String) -> AirSCPError? {
        guard path.utf8.count > 1023 else { return nil }
        return AirSCPError(.other, "The path of “\(RemotePath.name(path))” is longer than the 1,023 bytes this Mac's scp and "
            + "sftp take. Download its folder, or Download as .tar.gz, instead.")
    }

    /// tar -x reading a stream, which then takes in the rest of it (tar may stop at the archive's end and leave padding
    /// unread, which would make the stream's writer fail).
    static func untar(preserveTimes: Bool, tar: String = "tar") -> String {
        "\(tar) -x\(preserveTimes ? "p" : "m")f - && exec cat >/dev/null"
    }

    /// Item names as tar operands: "./" first, so that no name reads as an option (or as bsdtar's @archive).
    static func operands(_ names: [String]) -> String {
        names.map { Quote.shell("./" + $0) }.joined(separator: " ")
    }

    /// Leave-out patterns as typed in the folder-transfer sheet: separated by commas (or semicolons), without the spaces
    /// around them or a trailing "/" ("node_modules/" is the folder node_modules).
    public static func patterns(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == "," || $0 == ";" || $0.isNewline }).map { part -> String in
            var pattern = part.trimmingCharacters(in: .whitespaces)
            while pattern.count > 1 && pattern.hasSuffix("/") { pattern.removeLast() }
            return pattern
        }.filter { !$0.isEmpty }
    }

    /// Whether a name matches one of the patterns (`*`, `?`, `[ ]`, as tar's --exclude matches them).
    public static func leftOut(_ name: String, by patterns: [String]) -> Bool {
        patterns.contains { fnmatch($0, name, 0) == 0 }
    }

    /// This Mac's tar leaving out what matches the patterns, at any depth (bsdtar's --exclude, as GNU's and BusyBox's).
    static func excludes(_ patterns: [String]) -> [String] {
        patterns.flatMap { ["--exclude", $0] }
    }

    /// The same for tar on a server, as words of its command line (each followed by a space).
    static func remoteExcludes(_ patterns: [String]) -> String {
        patterns.map { "--exclude=" + Quote.shell($0) + " " }.joined()
    }

    /// The server can run tar over the connection.
    static func canStream(_ session: Session) -> Bool {
        let capabilities = session.capabilities
        return capabilities.shell && capabilities.tools.contains("tar")
    }

    static func requireTar(_ session: Session) throws {
        if let reason = session.compressUnavailableReason(.tarGz) {
            throw AirSCPError(session.capabilities.shell ? .missingTool : .sftpOnly, reason)
        }
    }

    /// A local folder's entries (the folder itself not counted), about the bytes of its tar stream, and how many of
    /// its files can't be read.
    static func localEstimate(_ folder: String, cancellation: Cancellation) throws -> (entries: Int, bytes: Int64, unreadable: Int) {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        var entries = 0, bytes: Int64 = 1024, unreadable = 0
        guard let walk = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys,
                                                        options: [], errorHandler: { _, _ in true }) else { return (0, 0, 0) }
        for case let url as URL in walk {
            entries += 1
            if entries % 1000 == 0 && cancellation.isCancelled { throw AirSCPError.cancelled }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let size = values?.isRegularFile == true ? Int64(values?.fileSize ?? 0) : 0
            if values?.isRegularFile == true && access(url.path, R_OK) != 0 { unreadable += 1 }
            bytes += 512 + (size + 511) / 512 * 512
        }
        return (entries, bytes, unreadable)
    }

    /// What a tar stream came to: nil when all went well, tar's complaints when it couldn't read some items but sent
    /// the rest (completed with errors), else the error that stopped it. A muxed command that found its master gone
    /// marks that session Disconnected.
    private func outcome(_ pumped: Runner.Pumped, cancellation: Cancellation, producer: Session?,
                         consumer: Session?) throws -> String? {
        for (result, session) in [(pumped.producer, producer), (pumped.consumer, consumer)] {
            if let result, let session, ErrorMapping.masterGone(result.stderr) {
                session.lost(AirSCPError(.disconnected, AirSCPError.disconnected.message, details: result.stderr))
            }
        }
        if cancellation.isCancelled { throw AirSCPError.cancelled }
        // Error output after the stream's marker (before it: login noise); a command on this Mac fails on this Mac.
        func failure(_ result: CommandResult, remote: Session?) -> AirSCPError {
            let text = OpenSSH.afterMarker(result.stderr)
            return remote == nil ? ErrorMapping.mapLocal(text, status: result.status) : ErrorMapping.map(text, status: result.status)
        }
        let producerFailed = !pumped.started || ![0, 1, 2].contains(pumped.producer.status)
        // The source side failed and the destination saw a cut stream: the source's error says why.
        if producerFailed && pumped.writeError == nil { throw failure(pumped.producer, remote: producer) }
        if let result = pumped.consumer, result.status != 0 { throw failure(result, remote: consumer) }
        if let failure = pumped.writeError, pumped.consumer == nil {
            throw AirSCPError(failure == ENOSPC || failure == EDQUOT ? .diskFull : .other,
                              "Can't save the download on this Mac: \(String(cString: strerror(failure))).")
        }
        if producerFailed { throw failure(pumped.producer, remote: producer) }
        return pumped.producer.status == 0 ? nil : OpenSSH.afterMarker(pumped.producer.stderr)
    }

    /// Swaps a finished download in, with rename(2): FileManager would store the name decomposed (NFD).
    static func moveIntoPlace(_ part: String, to destination: String, replacing: Bool) throws {
        var existing = stat()
        if lstat(destination, &existing) == 0 {
            guard replacing else { throw AirSCPError(.other, "\(RemotePath.name(destination)) already exists in the folder.") }
            try FileManager.default.removeItem(atPath: destination)
        }
        guard rename(part, destination) == 0 else {
            throw AirSCPError(.other, "Can't move the download into place: \(String(cString: strerror(errno)))")
        }
    }

    static func status(for error: Error) -> TransferJob.Status {
        guard let error = error as? AirSCPError else { return .failed(AirSCPError(.other, error.localizedDescription)) }
        return error.kind == .cancelled ? .cancelled : .failed(error)
    }

    /// Bytes per second as scp shows them, e.g. "5.8MB/s".
    static func speed(_ rate: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = rate, unit = 0
        while value >= 1024 && unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return String(format: "%.1f%@/s", value, units[unit])
    }

    /// "01:05", or "1:02:03" past an hour.
    static func duration(_ seconds: Double) -> String {
        let total = Int(min(seconds, 359_999).rounded())
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
            : String(format: "%02d:%02d", total / 60, total % 60)
    }
}

/// Every host's transfers in one list: the global Transfers panel, the Dock badge, the sidebar's per-host badges.
/// An ObservableObject, so any number of SwiftUI views or `$jobs` subscribers can follow it. Each Session's
/// `transfers` queue runs its own jobs (one at a time per host, hosts in parallel); this gathers them and forwards the
/// panel's actions to the queue that has the job.
public final class TransferCenter: ObservableObject {
    public static let shared = TransferCenter()

    /// All jobs of all hosts, each host's oldest first (`hostID` says whose). Updated on the main queue, at most four
    /// times a second.
    @Published public private(set) var jobs: [TransferJob] = []

    /// The same, as the queues have them now (`jobs` follows within a quarter of a second).
    public var currentJobs: [TransferJob] { queues().flatMap(\.jobs) }

    /// The host is reconnecting by itself: a retry would fail at once, and its jobs that the lost connection cut off
    /// run again once it is back (`TransferQueue.retryDisconnected`).
    public func isReconnecting(_ hostID: UUID) -> Bool {
        queues().contains { $0.hostID == hostID && $0.session?.isReconnecting == true }
    }

    private struct Entry { weak var queue: TransferQueue? }
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var scheduled = false
    private var lastPublished = Date.distantPast
    private var _speedLimit: Int?
    private var _verifyTransfers = false

    private init() {}

    /// The Transfers panel's speed limit, in bytes per second (nil: none): every host's jobs that start from now on keep
    /// to it (scp and sftp with -l, AirSCP's tar streams in the pump).
    public var speedLimit: Int? {
        get { lock.locked { _speedLimit } }
        set { lock.locked { _speedLimit = newValue.flatMap { $0 > 0 ? $0 : nil } } }
    }

    /// Settings ▸ Verify transfers with SHA-256: each single file's copy is checked against the original once it has
    /// arrived (`TransferQueue.verify`).
    public var verifyTransfers: Bool {
        get { lock.locked { _verifyTransfers } }
        set { lock.locked { _verifyTransfers = newValue } }
    }

    public func cancel(_ id: UUID) { queue(of: id)?.cancel(id) }

    public func retry(_ id: UUID) { queue(of: id)?.retry(id) }

    /// Pauses the queued and running jobs among `ids`, whichever hosts they are on (`TransferQueue.pause`).
    public func pause(_ ids: Set<UUID>) { queues().forEach { $0.pause(ids) } }

    /// Queues the paused jobs among `ids` again (`TransferQueue.resume`).
    public func resume(_ ids: Set<UUID>) { queues().forEach { $0.resume(ids) } }

    /// Checks the copies of the finished single files among `ids` against their originals (`TransferQueue.verify`).
    public func verify(_ ids: Set<UUID>) { queues().forEach { $0.verify(ids) } }

    /// Removes a finished job from the list.
    public func remove(_ id: UUID) { queue(of: id)?.remove(id) }

    public func clearFinished() { queues().forEach { $0.clearFinished() } }

    /// Cancels every host's transfers; returns once their partial files are cleaned up.
    public func cancelAll() async {
        await withTaskGroup(of: Void.self) { group in
            for queue in queues() { group.addTask { await queue.cancelAll() } }
        }
    }

    func register(_ queue: TransferQueue) {
        lock.locked {
            entries.removeAll { $0.queue == nil }
            entries.append(Entry(queue: queue))
        }
    }

    /// A queue changed: refresh `jobs` on the main queue (changes within a quarter of a second go together).
    func queueChanged() {
        let delay: TimeInterval? = lock.locked {
            guard !scheduled else { return nil }
            scheduled = true
            return max(0, 0.25 - Date().timeIntervalSince(lastPublished))
        }
        guard let delay else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.lock.locked {
                self.scheduled = false
                self.lastPublished = Date()
            }
            self.jobs = self.queues().flatMap(\.jobs)
        }
    }

    /// A host reconnected by itself: copies from it to other hosts that its lost connection stopped run again.
    func retryRelays(from hostID: UUID) {
        queues().filter { $0.hostID != hostID }.forEach { $0.retryDisconnected(relaysFrom: hostID) }
    }

    /// A host's connected session (the source of a relay), the newest if there are several.
    func session(for hostID: UUID) -> Session? {
        queues().last { $0.hostID == hostID && $0.session?.state == .connected }?.session
    }

    private func queues() -> [TransferQueue] { lock.locked { entries.compactMap(\.queue) } }

    private func queue(of id: UUID) -> TransferQueue? {
        queues().first { queue in queue.jobs.contains { $0.id == id } }
    }
}
