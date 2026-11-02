import AirSCPCore
import Charts
import Combine
import SwiftUI

/// The Transfers tab (mockup screen 9).
struct TransfersView: View {
    var body: some View {
        NavigationStack { TransfersList().navigationTitle("Transfers") }
    }
}

/// Every open server's transfers, from Core's TransferCenter as the Mac's Transfers panel shows them: Now (running,
/// queued, paused) with a speed chart, Needs you (failed, items left out, a copy that doesn't match), Done; each with
/// Pause or Resume, Cancel, Retry (a file cut off continues where it stopped). A narrow column, with its toolbar
/// buttons, for whatever hosts it (the Transfers tab, an inspector).
struct TransfersList: View {
    @ObservedObject private var center = TransferCenter.shared
    @State private var speeds = SpeedHistory()
    private let background = BackgroundTransfers.shared

    var body: some View {
        let jobs = center.jobs
        // Still being checked counts as now; finished ones newest first.
        let now = jobs.filter { !$0.status.isFinished || $0.checksum == .wanted || $0.checksum == .checking }
        let finished = jobs.filter { job in !now.contains { $0.id == job.id } }.reversed()
        let needsYou = finished.filter { TransferText.problem($0) != nil }
        let done = finished.filter { TransferText.problem($0) == nil }
        let running = now.contains { $0.status == .running }
        Group {
            if jobs.isEmpty {
                ContentUnavailableView("No transfers", systemImage: "arrow.up.arrow.down",
                                       description: Text("Files you send or download show here with their progress."))
            } else {
                List {
                    if !now.isEmpty {
                        Section {
                            if running { SpeedChart(samples: speeds.samples) }
                            ForEach(now) { TransferRow(job: $0) }
                        } header: {
                            Text("Now")
                        } footer: {
                            if running {
                                Text("Keep AirSCP open for big transfers: iOS may pause them in the background.")
                            } else if background.stoppedByIOS {
                                Text("iOS paused these in the background. Resume continues them where they stopped.")
                            }
                        }
                    }
                    if !needsYou.isEmpty {
                        Section("Needs you") { ForEach(needsYou) { TransferRow(job: $0) } }
                    }
                    if !done.isEmpty {
                        Section("Done") { ForEach(done) { TransferRow(job: $0) } }
                    }
                }
            }
        }
        .toolbar {
            // Clear Done at the leading edge: an iPad's tabs at the top leave room for two buttons at the trailing edge,
            // and put a third in a More menu.
            ToolbarItem(placement: .topBarLeading) {
                Button("Clear Done") { done.forEach { center.remove($0.id) } }
                    .disabled(done.isEmpty)
                    .help(done.isEmpty ? "Nothing is done yet" : "Take the finished transfers off the list")
            }
            ToolbarItemGroup {
                TrayButton()
                if background.stoppedByIOS, now.contains(where: TransferText.canResume) {
                    Button("Resume All") { center.resume(Set(now.filter(TransferText.canResume).map(\.id))) }
                        .help("Continue every paused transfer")
                }
            }
        }
        .task(id: running) {
            speeds = SpeedHistory()
            while running && !Task.isCancelled {
                speeds.sample(center.currentJobs)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}

/// One transfer: what, from where to where, how far and how fast, and what can be done with it.
struct TransferRow: View {
    @Environment(AppState.self) private var app
    let job: TransferJob
    @State private var showingProblem = false

    private var center: TransferCenter { .shared }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: TransferText.symbol(job.direction))
                .font(.body.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.15), in: .circle)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(TransferText.name(job)).lineLimit(1).truncationMode(.middle)
                Text(route).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let fraction = TransferText.fraction(job), !job.status.isFinished {
                    ProgressView(value: fraction).tint(job.status == .paused ? .gray : .teal)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Image(systemName: symbol).imageScale(.small)
                    Text(status).lineLimit(3)
                }
                .font(.caption)
                .foregroundStyle(statusColor)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("transfer " + TransferText.name(job))
        .swipeActions(edge: .trailing) { actions }
        .contextMenu {
            actions
            if TransferText.problem(job) != nil {
                Button("Show Details", systemImage: "info.circle") { showingProblem = true }
                    .help("Show what went wrong, in the tools' own words")
            }
        }
        .alert(TransferText.name(job), isPresented: $showingProblem, presenting: TransferText.problem(job)) { _ in
            Button("OK") {}
        } message: { problem in
            Text(problem.message + (problem.details.isEmpty ? "" : "\n\n" + problem.details))
        }
    }

    /// Pause or Resume and Cancel while it is under way; Retry and Remove once it has finished.
    @ViewBuilder private var actions: some View {
        if job.status.isActive {
            Button("Pause", systemImage: "pause.fill") { center.pause([job.id]) }
                .tint(.orange)
                .help(job.isSingleFile ? "Stop for now; Resume continues where it stopped" : "Stop for now; Resume starts it again")
        }
        if TransferText.canResume(job) {
            Button("Resume", systemImage: "play.fill") { center.resume([job.id]) }
                .tint(.teal)
                .help("Continue this transfer")
        }
        if !job.status.isFinished {
            Button("Cancel", systemImage: "xmark", role: .destructive) { center.cancel(job.id) }
                .help("Stop this transfer; what was partly copied is removed")
        }
        if TransferText.canRetry(job) {
            Button("Retry", systemImage: "arrow.clockwise") { center.retry(job.id) }
                .tint(.teal)
                .help("Run it again; a file cut off continues where it stopped")
        }
        if job.status.isFinished {
            Button("Remove", systemImage: "trash", role: .destructive) { center.remove(job.id) }
                .help("Take this transfer off the list")
        }
    }

    /// Red for a problem, green once the copy is checked.
    private var statusColor: Color {
        if TransferText.problem(job) != nil { return .red }
        if case .verified? = job.checksum { return .green }
        return .secondary
    }

    private var tint: Color {
        TransferText.problem(job) != nil ? .red : job.status == .paused || job.status == .cancelled ? .gray : .teal
    }

    /// "web-01 → iPhone"; a server-to-server copy names both servers.
    private var route: String {
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        let host = name(job.hostID)
        switch job.direction {
        case .upload: return device + " → " + host
        case .download: return host + " → " + device
        case .relay: return name(job.sourceHostID) + " → " + host
        case .compress, .extract: return host
        }
    }

    private func name(_ id: UUID?) -> String {
        guard let id else { return "—" }
        return (app.data.hosts.first { $0.id == id } ?? app.session(for: id)?.host)?.displayName ?? "—"
    }

    /// How it is going ("Uploading · 42% · 5.8MB/s · 00:12 left"), or how it ended: "Checksums match" for a copy
    /// checked against its original.
    private var status: String {
        let progress = job.progress
        switch job.status {
        case .running where job.checksum != .checking:
            let size = ByteCountFormatter.string(fromByteCount: progress.bytes, countStyle: .file)
            let amount = TransferText.fraction(job).map { "\(Int($0 * 100))%" } ?? size
            return [TransferText.status(job), amount, progress.speed, progress.eta.isEmpty ? "" : progress.eta + " left"]
                .filter { !$0.isEmpty }.joined(separator: " · ")
        case .paused:
            return TransferText.note(job) ?? TransferText.status(job)
        case .failed where job.isSingleFile && (app.session(for: job.hostID)?.transfers.isResumable(job.id) ?? false):
            return TransferText.status(job) + " Retry continues where it stopped."
        case .done:
            if case .verified? = job.checksum { return "Checksums match" }
            if case .unchecked(let reason)? = job.checksum { return "Done, not checked: " + reason }
            return TransferText.problem(job)?.message ?? TransferText.status(job)
        default:
            return TransferText.problem(job)?.message ?? TransferText.status(job)
        }
    }

    private var symbol: String {
        if TransferText.problem(job) != nil { return "exclamationmark.triangle.fill" }
        switch job.status {
        case .queued: return "clock"
        case .paused: return "pause.circle"
        case .cancelled: return "xmark.circle"
        case .running: return job.checksum == .checking ? "checkmark.shield" : "arrow.triangle.2.circlepath"
        default:
            if case .verified? = job.checksum { return "checkmark.seal.fill" }
            return "checkmark.circle"
        }
    }
}

/// The running transfers' speed over the last minute, a sample a second.
@Observable final class SpeedHistory {
    struct Sample: Identifiable {
        let time: Date
        /// Bytes a second, every running transfer together.
        let speed: Double
        var id: Date { time }
    }

    private(set) var samples: [Sample] = []
    private var bytes: [UUID: Int64] = [:]
    private var time: Date?

    /// What the running jobs copied since the last sample (a job that started again since counts from there).
    func sample(_ jobs: [TransferJob], now: Date = Date()) {
        let running = jobs.filter { $0.status == .running }
        var copied: Int64 = 0
        for job in running {
            if let before = bytes[job.id], job.progress.bytes >= before { copied += job.progress.bytes - before }
        }
        if let time, now > time {
            samples = (samples + [Sample(time: now, speed: Double(copied) / now.timeIntervalSince(time))]).suffix(60)
        }
        bytes = Dictionary(running.map { ($0.id, $0.progress.bytes) }) { first, _ in first }
        time = now
    }
}

struct SpeedChart: View {
    let samples: [SpeedHistory.Sample]
    @Environment(\.verticalSizeClass) private var height

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(samples.last.map { Self.speed($0.speed) } ?? "Measuring speed…")
                .font(.headline.monospacedDigit())
            Chart(samples) { sample in
                AreaMark(x: .value("Time", sample.time), y: .value("Speed", sample.speed))
                    .foregroundStyle(.linearGradient(colors: [.teal.opacity(0.35), .teal.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", sample.time), y: .value("Speed", sample.speed))
                    .foregroundStyle(.teal)
            }
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: 3)) { value in
                    let speed = value.as(Double.self) ?? 0
                    AxisGridLine()
                    AxisValueLabel { Text(speed > 0 ? Self.speed(speed) : "0") }
                }
            }
            .frame(height: height == .compact ? 50 : 90)  // an iPhone on its side has little height
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Speed")
        .accessibilityValue(samples.last.map { Self.speed($0.speed) } ?? "Measuring")
        .accessibilityIdentifier("speedChart")
    }

    static func speed(_ bytes: Double) -> String {
        FileRow.size(Int64(bytes)) + "/s"  // "0 KB/s", not "Zero KB/s"
    }
}

/// The running transfer above the tab bar (the tab bar's bottom accessory, iOS 26): its name, progress and speed; a tap
/// opens Transfers. Shown while something is under way. Only that changes this modifier: the row follows the progress
/// itself (made again with every change, the accessory lost taps).
struct TransfersAccessory: ViewModifier {
    @State private var active = false
    let open: () -> Void

    func body(content: Content) -> some View {
        Group {
            if #available(iOS 26.1, *) {
                content.tabViewBottomAccessory(isEnabled: active) { AccessoryRow(open: open) }
            } else {
                content.tabViewBottomAccessory { AccessoryRow(open: open) }  // iOS 26.0 keeps it there: it says when nothing runs
            }
        }
        .onReceive(TransferCenter.shared.$jobs.map { $0.contains(where: \.status.isActive) }.removeDuplicates()) { active = $0 }
    }
}

private struct AccessoryRow: View {
    @ObservedObject private var center = TransferCenter.shared
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let open: () -> Void

    var body: some View {
        let active = center.jobs.filter(\.status.isActive)
        let job = active.first { $0.status == .running } ?? active.first
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: job.map { TransferText.symbol($0.direction) } ?? "arrow.up.arrow.down")
                    .foregroundStyle(.teal)
                if let job {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(TransferText.name(job) + (active.count > 1 ? " and \(active.count - 1) more" : ""))
                            .lineLimit(1).truncationMode(.middle)
                        if placement != .inline, let fraction = TransferText.fraction(job) {
                            ProgressView(value: fraction).tint(.teal)
                        }
                    }
                    Spacer(minLength: 4)
                    Text(job.status == .running ? job.progress.speed : TransferText.status(job))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("No transfers running").foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("transferAccessory")
        .help("Show Transfers")
    }
}

extension View {
    /// The running transfer above the tab bar; `open` shows the Transfers tab.
    func transfersAccessory(open: @escaping () -> Void) -> some View {
        modifier(TransfersAccessory(open: open))
    }
}
