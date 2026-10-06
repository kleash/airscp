import AirSCPCore
import AppKit
import SwiftUI

/// The global Transfers queue at the bottom of the main window: every host's jobs from `TransferCenter.shared`
/// (host, name, direction, size, progress, speed, ETA, status) with Cancel, Retry, Remove, Clear Finished and
/// Cancel All. It redraws at most four times a second however fast the transfers report (TransferCenter publishes
/// no more often). The main window shows it below the selected workspace.
struct TransfersPanel: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var list = TransferCenter.shared
    @ObservedObject private var selected: TransferSelection
    @Environment(\.colorScheme) private var scheme

    init(model: AppModel) {
        self.model = model
        selected = model.transferSelection
    }

    private var center: TransferCenter { .shared }
    private var selection: Set<UUID> { selected.ids }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if list.jobs.isEmpty {
                Text("No transfers yet. Drag files between the panes, or from Finder onto a server, to copy them. They "
                     + "queue here and run in the background.")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                table
            }
        }
        .card()
        .frame(minHeight: 90)
    }

    private var header: some View {
        let selected = list.jobs.filter { selection.contains($0.id) }
        let active = list.jobs.filter { !$0.status.isFinished }
        return HStack(spacing: 8) {
            Text("Transfers").font(.system(size: 12.5, weight: .bold)).fixedSize()
                .help("Uploads and downloads of every host run here, one at a time per host")
            if !active.isEmpty {
                StatusPill(text: "\(active.count) active", style: scheme == .dark ? .tinted(.controlAccentColor) : .pill)
                    .fixedSize()
                    .help(TransferText.summary(list.jobs))
            }
            Spacer()
            // A menu with its heading, the current limit ticked (agents choose it with set, as a pop-up).
            Menu {
                Picker("Per transfer, every host", selection: $model.data.settings.transferSpeedLimit) {
                    ForEach(Self.speedLimits, id: \.self) { Text(Self.speedTitle($0)).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Text("Speed: " + Self.speedTitle(model.data.settings.transferSpeedLimit)).fontWeight(.semibold)
            }
            .fixedSize()
            .accessibilityIdentifier("transfers.speedLimit")
            .help("The most each transfer that starts from now on may use, for every host (Unlimited by default). A limit "
                  + "leaves room for others on a shared or slow connection; transfers already running keep their speed.")
            let cancellable = selected.contains { !$0.status.isFinished }, retryable = selected.contains { TransferText.canRetry($0) }
            let waiting = selected.contains(where: TransferText.waitsForReconnect)
            let removable = selected.contains { $0.status.isFinished }, finished = list.jobs.contains { $0.status.isFinished }
            Button("Cancel") { selected.forEach { center.cancel($0.id) } }
                .disabled(!cancellable)
                .accessibilityIdentifier("transfers.cancel")
                .help(cancellable ? "Stop the selected transfers; partly copied files are removed" : "Select a running or queued transfer")
            Button("Retry") { selected.forEach { center.retry($0.id) } }
                .disabled(!retryable)
                .accessibilityIdentifier("transfers.retry")
                .help(retryable ? "Run the selected failed or cancelled transfers again; a cut-off file continues"
                      : waiting ? "Their host is reconnecting: what the lost connection cut off runs again by itself then"
                      : "Select a failed or cancelled transfer")
            Button("Remove") { selected.forEach { center.remove($0.id) } }
                .disabled(!removable)
                .accessibilityIdentifier("transfers.remove")
                .help(removable ? "Take the selected finished transfers off the list" : "Select a finished transfer")
            Button("Clear Finished") { center.clearFinished() }
                .disabled(!finished)
                .accessibilityIdentifier("transfers.clearFinished")
                .help(finished ? "Take every finished transfer off the list" : "Nothing has finished yet")
            Button("Cancel All") { cancelAll(active.count) }
                .disabled(active.isEmpty)
                .accessibilityIdentifier("transfers.cancelAll")
                .help(active.isEmpty ? "Nothing is running" : "Stop every running and queued transfer (asks first)")
        }
        .controlSize(.small)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color(nsColor: .bar))
    }

    /// The speed limits offered, in MB/s (0: none; `AppSettings.transferSpeedLimit`).
    static let speedLimits = [0, 1, 5, 10, 50]

    static func speedTitle(_ megabytes: Int) -> String { megabytes > 0 ? "\(megabytes) MB/s" : "Unlimited" }

    /// Finished jobs listed at most (the newest): the table works through every row at each update, several a second.
    static let finishedShown = 100

    /// The jobs listed: those queued or running first (a new transfer sat below the fold, under old finished ones), then
    /// the newest finished ones, newest first.
    static func shown(_ jobs: [TransferJob]) -> [TransferJob] {
        jobs.filter { !$0.status.isFinished } + jobs.filter(\.status.isFinished).suffix(finishedShown).reversed()
    }

    private var shown: [TransferJob] { Self.shown(list.jobs) }

    private var table: some View {
        Table(shown, selection: $selected.ids) {
            TableColumn("Host") { job in
                HStack(spacing: 6) {
                    // Night Harbor: the host's hue (its colour tag, else the hosts' blue); Paper: green while it works.
                    Circle().fill(hostDot(job)).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(hostName(job)).fontWeight(.medium).lineLimit(1)
                }
                .help(hostName(job))
            }
            .width(min: 60, ideal: 90)
            TableColumn("Name") { job in
                VStack(alignment: .leading, spacing: 0) {
                    Text(TransferText.name(job)).lineLimit(1).truncationMode(.middle)
                    if let detail = TransferText.detail(job) {
                        Text(detail).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                }
                .help(TransferText.route(job))
            }
            .width(min: 120, ideal: 210)
            TableColumn("Way") { job in
                Image(systemName: TransferText.symbol(job.direction)).foregroundColor(.secondary)
                    .help(TransferText.direction(job.direction))
                    .accessibilityLabel(TransferText.direction(job.direction))
            }
            .width(34)
            TableColumn("Size") { job in
                Text(TransferText.size(job)).monospacedDigit().foregroundColor(.secondary)
            }
            .width(min: 60, ideal: 80)
            TableColumn("Progress") { job in
                progress(job)
            }
            .width(min: 70, ideal: 110)
            // Before Speed and ETA: in a narrow window those are cut off, not the status and its error button.
            TableColumn("Status") { job in
                status(job)
            }
            .width(min: 110, ideal: 170)
            TableColumn("Speed") { job in
                Text(job.status == .running ? job.progress.speed : "").monospacedDigit()
            }
            .width(min: 50, ideal: 64)
            TableColumn("ETA") { job in
                Text(TransferText.eta(job)).monospacedDigit()
            }
            .width(min: 50, ideal: 70)
        }
        .washed()
        .contextMenu(forSelectionType: UUID.self) { ids in
            let actions = Self.actions(for: list.jobs.filter { ids.contains($0.id) })
            ForEach(actions.indices, id: \.self) { index in
                Button(actions[index].title, action: actions[index].run).disabled(!actions[index].enabled)
                    .help(Self.actionTips[actions[index].title] ?? "")
            }
        }
    }

    static let actionTips = [
        "Cancel": "Stop the selected transfers; partly copied files are removed",
        "Retry": "Run the selected failed or cancelled transfers again; a cut-off file continues",
        "Remove": "Take the selected finished transfers off the list",
        "Show Details…": "Show the tools' output for this transfer",
        "Show in Finder": "Show the downloaded item in Finder",
    ]

    /// Shows items in Finder (tests replace it: Finder opens on the user's screen).
    static var showInFinder: ([URL]) -> Void = { NSWorkspace.shared.activateFileViewerSelecting($0) }

    /// The jobs' context menu (agents choose from it with `menu "context > …" pane=transfers`).
    static func actions(for jobs: [TransferJob]) -> [(title: String, enabled: Bool, run: () -> Void)] {
        let center = TransferCenter.shared
        var actions: [(title: String, enabled: Bool, run: () -> Void)] = [
            ("Cancel", jobs.contains { !$0.status.isFinished }, { jobs.forEach { center.cancel($0.id) } }),
            ("Retry", jobs.contains { TransferText.canRetry($0) }, { jobs.forEach { center.retry($0.id) } }),
            ("Remove", jobs.contains { $0.status.isFinished }, { jobs.forEach { center.remove($0.id) } }),
        ]
        if jobs.count == 1, let job = jobs.first {
            if TransferText.problem(job) != nil { actions.append(("Show Details…", true, { showDetails(job) })) }
            if job.direction == .download && job.status == .done {
                actions.append(("Show in Finder", true, { showInFinder([URL(fileURLWithPath: job.destination)]) }))
            }
        }
        return actions
    }

    /// A 6 pt capsule and the percentage: running, done (green) or failed where it stopped (red).
    @ViewBuilder
    private func progress(_ job: TransferJob) -> some View {
        let failed = TransferText.problem(job) != nil && job.progress.percent > 0 && !job.progress.indeterminate
        if let fraction = TransferText.fraction(job) ?? (failed ? Double(min(job.progress.percent, 100)) / 100 : nil) {
            HStack(spacing: 8) {
                CapsuleBar(fraction: fraction, state: job.status == .done ? .done : failed ? .failed : .running)
                Text("\(Int(fraction * 100))%").font(.system(size: 11)).foregroundColor(.secondary).monospacedDigit().fixedSize()
            }
        } else {
            Text(job.status == .running ? "Streaming" : "").foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func status(_ job: TransferJob) -> some View {
        HStack(spacing: 4) {
            StatusPill(text: TransferText.status(job), symbol: Self.statusSymbol(job), style: statusStyle(job))
                .help(TransferText.problem(job)?.message ?? TransferText.status(job))
            if TransferText.problem(job) != nil {
                Button { showDetails(job) } label: { Image(systemName: "info.circle") }
                    .buttonStyle(.borderless)
                    .help("Show the error output")
            }
        }
    }

    /// Running: the pill (Paper) or the accent's tint; done green; problems red; queued and cancelled grey.
    private func statusStyle(_ job: TransferJob) -> StatusPill.Style {
        if TransferText.problem(job) != nil { return .tinted(.systemRed) }
        switch job.status {
        case .running: return scheme == .dark ? .tinted(.controlAccentColor) : .pill
        case .done: return .tinted(.systemGreen)
        default: return .neutral
        }
    }

    private static func statusSymbol(_ job: TransferJob) -> String? {
        if TransferText.problem(job) != nil { return "exclamationmark.triangle" }
        switch job.status {
        case .queued: return "clock"
        case .done: return "checkmark"
        default: return nil
        }
    }

    private func hostDot(_ job: TransferJob) -> Color {
        guard scheme == .dark else {
            return job.status.isFinished ? Color.primary.opacity(0.3) : Color(nsColor: .systemGreen)
        }
        return model.data.host(job.hostID).flatMap { tagColor($0.color) } ?? .blue
    }

    private func hostName(_ job: TransferJob) -> String {
        let host = model.data.host(job.hostID)?.displayName ?? "—"
        guard job.direction == .relay else { return host }
        return (model.data.host(job.sourceHostID)?.displayName ?? "—") + " → " + host
    }

    private static func showDetails(_ job: TransferJob) {
        guard let problem = TransferText.problem(job) else { return }
        showError(problem, title: TransferText.name(job) + ": " + TransferText.status(job), on: NSApp.keyWindow)
    }

    private func showDetails(_ job: TransferJob) { Self.showDetails(job) }

    private func cancelAll(_ count: Int) {
        confirm("Cancel \(transfers(count))?", info: "Partly copied files are removed.", button: "Cancel Transfers",
                destructive: true, on: NSApp.keyWindow) {
            Task { await TransferCenter.shared.cancelAll() }
        }
    }
}

/// The Transfers panel's selected jobs.
@MainActor
final class TransferSelection: ObservableObject {
    @Published var ids = Set<UUID>()
}

/// What the Transfers panel shows for a job.
enum TransferText {
    /// "3 running, 2 queued, 1 failed".
    static func summary(_ jobs: [TransferJob]) -> String {
        let running = jobs.filter { $0.status == .running }.count
        let queued = jobs.filter { $0.status == .queued }.count
        let failed = jobs.filter { problem($0) != nil }.count
        return [running > 0 ? "\(running) running" : nil, queued > 0 ? "\(queued) queued" : nil,
                failed > 0 ? "\(failed) with problems" : nil].compactMap { $0 }.joined(separator: ", ")
    }

    /// The item, or for an archive or server-to-server job its items ("3 items").
    static func name(_ job: TransferJob) -> String {
        switch job.names.count {
        case 0: return job.name
        case 1: return job.names[0]
        default: return "\(job.names.count) items"
        }
    }

    /// Under the name: the file being copied in a folder and how many are done, or the archive's name.
    static func detail(_ job: TransferJob) -> String? {
        if job.status == .running, job.isFolder, job.names.isEmpty, !job.progress.file.isEmpty {
            return job.progress.file + (job.progress.filesDone > 0 ? " · \(job.progress.filesDone) done" : "")
        }
        if !job.names.isEmpty && job.direction == .download { return "as " + job.name }
        return nil
    }

    /// "/Users/me/a.txt → /srv/www/a.txt".
    static func route(_ job: TransferJob) -> String {
        let source = job.names.count == 1 ? RemotePath.join(job.source, job.names[0]) : job.source
        return source + " → " + job.destination
    }

    static func symbol(_ direction: TransferJob.Direction) -> String {
        switch direction {
        case .upload: return "arrow.up"
        case .download: return "arrow.down"
        case .relay: return "arrow.left.arrow.right"
        }
    }

    static func direction(_ direction: TransferJob.Direction) -> String {
        switch direction {
        case .upload: return "Upload"
        case .download: return "Download"
        case .relay: return "Server to server"
        }
    }

    /// The job's size when known, else what has arrived so far.
    static func size(_ job: TransferJob) -> String {
        let progress = job.progress
        if progress.indeterminate {
            guard progress.bytes > 0 else { return "—" }
            return FileList.size(progress.bytes) + (progress.total.map { " of ~" + FileList.size($0) } ?? "")
        }
        if let total = progress.total { return FileList.size(total) }
        // scp -r's meter (a folder without a stream, a copy through this Mac) counts each file anew: no size of the whole.
        if job.isFolder || !job.names.isEmpty { return "—" }
        return progress.bytes > 0 ? FileList.size(progress.bytes) : "—"
    }

    /// 0…1, or nil for a streamed job (no percentage) and a job that hasn't started.
    static func fraction(_ job: TransferJob) -> Double? {
        switch job.status {
        case .done: return 1
        case .running where !job.progress.indeterminate: return Double(min(max(job.progress.percent, 0), 100)) / 100
        default: return nil
        }
    }

    /// The time left (scp's ETA), or for a streamed job the time since it started.
    static func eta(_ job: TransferJob, now: Date = Date()) -> String {
        guard job.status == .running else { return "" }
        if job.progress.indeterminate, let started = job.started {
            return duration(now.timeIntervalSince(started)) + " elapsed"
        }
        return job.progress.eta
    }

    /// "0:42", "12:05", "1:02:03".
    static func duration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        let (hours, minutes, rest) = (total / 3600, total / 60 % 60, total % 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }

    static func status(_ job: TransferJob) -> String {
        switch job.status {
        case .queued: return "Queued"
        case .running:
            switch job.direction {
            case .upload: return "Uploading"
            case .download: return "Downloading"
            case .relay: return "Copying"
            }
        case .done: return "Done"
        case .completedWithErrors: return "Completed with errors"
        case .failed(let error): return "Failed: " + error.message
        case .cancelled: return "Cancelled"
        }
    }

    /// What went wrong, with the tools' output as details.
    static func problem(_ job: TransferJob) -> AirSCPError? {
        switch job.status {
        case .completedWithErrors(let output):
            return AirSCPError(.other, "Some items couldn't be copied; the rest were. Details names them; Retry runs the "
                               + "transfer again.", details: output)
        case .failed(let error):
            return error
        default:
            return nil
        }
    }

    static func canRetry(_ job: TransferJob) -> Bool {
        switch job.status {
        case .failed, .cancelled, .completedWithErrors: return !waitsForReconnect(job)
        default: return false
        }
    }

    /// A finished job whose host is reconnecting by itself: a retry would fail at once ("Not connected"), and what the
    /// lost connection cut off runs again once it is back.
    static func waitsForReconnect(_ job: TransferJob) -> Bool {
        job.status.isFinished && TransferCenter.shared.isReconnecting(job.hostID)
    }
}
