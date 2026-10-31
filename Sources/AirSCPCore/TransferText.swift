import Foundation

/// What a Transfers list shows for a job (the Mac's panel, the iPhone and iPad app's tab).
public enum TransferText {
    /// "3 running, 2 queued, 1 paused, 1 with problems".
    public static func summary(_ jobs: [TransferJob]) -> String {
        let running = jobs.filter { $0.status == .running }.count
        let queued = jobs.filter { $0.status == .queued }.count
        let paused = jobs.filter { $0.status == .paused }.count
        let failed = jobs.filter { problem($0) != nil }.count
        return [running > 0 ? "\(running) running" : nil, queued > 0 ? "\(queued) queued" : nil,
                paused > 0 ? "\(paused) paused" : nil, failed > 0 ? "\(failed) with problems" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    /// The item, or for an archive or server-to-server job its items ("3 items").
    public static func name(_ job: TransferJob) -> String {
        switch job.names.count {
        case 0: return job.name
        case 1: return job.names[0]
        default: return "\(job.names.count) items"
        }
    }

    /// Under the name: the file being copied in a folder and how many are done, or the archive's name.
    public static func detail(_ job: TransferJob) -> String? {
        if job.status == .running, job.isFolder, job.names.isEmpty, !job.progress.file.isEmpty {
            return job.progress.file + (job.progress.filesDone > 0 ? " · \(job.progress.filesDone) done" : "")
        }
        if !job.names.isEmpty && job.direction == .download { return "as " + job.name }
        return nil
    }

    /// "/Users/me/a.txt → /srv/www/a.txt".
    public static func route(_ job: TransferJob) -> String {
        let source = job.names.count == 1 ? RemotePath.join(job.source, job.names[0]) : job.source
        return source + " → " + job.destination
    }

    public static func symbol(_ direction: TransferJob.Direction) -> String {
        switch direction {
        case .upload: return "arrow.up"
        case .download: return "arrow.down"
        case .relay: return "arrow.left.arrow.right"
        case .compress: return "doc.zipper"
        case .extract: return "shippingbox"
        }
    }

    public static func direction(_ direction: TransferJob.Direction) -> String {
        switch direction {
        case .upload: return "Upload"
        case .download: return "Download"
        case .relay: return "Server to server"
        case .compress: return "Zip on S3 storage (through this Mac)"
        case .extract: return "Extract on S3 storage (through this Mac)"
        }
    }

    /// 0…1 (a paused job: where it stopped), or nil for a streamed job (no percentage) and a job that hasn't started.
    public static func fraction(_ job: TransferJob) -> Double? {
        switch job.status {
        case .done: return 1
        case .running where !job.progress.indeterminate, .paused where !job.progress.indeterminate && job.progress.percent > 0:
            return Double(min(max(job.progress.percent, 0), 100)) / 100
        default: return nil
        }
    }

    /// The time left (scp's ETA), or for a streamed job the time since it started.
    public static func eta(_ job: TransferJob, now: Date = Date()) -> String {
        guard job.status == .running else { return "" }
        if job.progress.indeterminate, let started = job.started {
            return duration(now.timeIntervalSince(started)) + " elapsed"
        }
        return job.progress.eta
    }

    /// "0:42", "12:05", "1:02:03".
    public static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    public static func status(_ job: TransferJob) -> String {
        switch job.status {
        case .queued: return "Queued"
        case .running:
            if job.checksum == .checking { return "Verifying" }
            switch job.direction {
            case .upload: return "Uploading"
            case .download: return "Downloading"
            case .relay: return "Copying"
            case .compress: return "Compressing"
            case .extract: return "Extracting"
            }
        case .paused: return "Paused"
        case .done:
            switch job.checksum {
            case nil: return "Done"
            case .wanted?: return "Waiting to verify"
            case .checking?: return "Verifying"
            case .verified?: return "Verified"
            case .mismatch?: return "Mismatch"
            case .unchecked?: return "Not verified"
            }
        case .completedWithErrors: return "Completed with errors"
        case .failed(let error): return "Failed: " + error.message
        case .cancelled: return "Cancelled"
        }
    }

    /// What the status means, where it needs saying (the status pill's tooltip): how a paused job goes on, a check's
    /// outcome.
    public static func note(_ job: TransferJob) -> String? {
        switch (job.status, job.checksum) {
        case (.paused, _):
            return job.isSingleFile ? "Paused: Resume continues where it stopped"
                : "Paused: Resume starts it again (only single files continue where they stopped)"
        case (.running, .checking?), (.done, .checking?), (.done, .wanted?):
            return "Comparing the SHA-256 checksum of the copy with the original's"
        case (.done, .verified(let hash)?):
            return "Verified: the copy and the original have the same SHA-256 checksum, " + hash
        case (.done, .unchecked(let reason)?):
            return "Not verified: " + reason
        default:
            return nil
        }
    }

    /// What went wrong, with the tools' output as details.
    public static func problem(_ job: TransferJob) -> AirSCPError? {
        switch job.status {
        case .done:
            guard case .mismatch(let original, let copy)? = job.checksum else { return nil }
            return AirSCPError(.other, "The copy's SHA-256 checksum differs from the original's: the copy is damaged, or "
                               + "one of them changed since. Retry copies the file again, in place of this copy.",
                               details: "Original: \(original)\nCopy:     \(copy)")
        case .completedWithErrors(let output):
            return AirSCPError(.other, "Some items couldn't be copied; the rest were. Details names them; Retry runs the "
                               + "transfer again.", details: output)
        case .failed(let error):
            return error
        default:
            return nil
        }
    }

    public static func canRetry(_ job: TransferJob) -> Bool {
        switch job.status {
        case .failed, .cancelled, .completedWithErrors: return !waitsForReconnect(job)
        case .done:
            guard case .mismatch? = job.checksum else { return false }
            return !waitsForReconnect(job)
        default: return false
        }
    }

    /// A paused job whose host isn't reconnecting by itself (resumed then, it would fail at once: Resume it once the host
    /// is back).
    public static func canResume(_ job: TransferJob) -> Bool {
        job.status == .paused && !TransferCenter.shared.isReconnecting(job.hostID)
    }

    /// A finished job whose host is reconnecting by itself: a retry would fail at once ("Not connected"), and what the
    /// lost connection cut off runs again once it is back.
    public static func waitsForReconnect(_ job: TransferJob) -> Bool {
        job.status.isFinished && TransferCenter.shared.isReconnecting(job.hostID)
    }
}
