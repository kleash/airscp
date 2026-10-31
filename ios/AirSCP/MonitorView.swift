import AirSCPCore
import Charts
import SwiftUI

/// One open server's system monitor (Core's `Monitor`: Linux only), shared by its Monitor screen and its figures in
/// Servers. It reads the server only while one of them shows and AirSCP is in front (each runs `sample` in its
/// `.task`), as the Mac's Monitor tab and pulse strip do: every 3 s with the processes, every 10 s without.
@MainActor @Observable final class HostMonitor {
    struct Sample: Identifiable {
        let time: Date
        /// Percent of all cores.
        let cpu: Double
        var id: Date { time }
    }

    let session: Session
    @ObservationIgnored let monitor: Monitor
    private(set) var snapshot: MonitorSnapshot?
    /// Why there is no snapshot: not Linux, an account without a shell, a read that failed.
    private(set) var failure: AirSCPError?
    /// The CPU of the reads in a row (none more than 30 s after the one before), over the last 15 minutes: iOS doesn't let
    /// AirSCP read the server in the background, so a pause starts it again.
    private(set) var history: [Sample] = []
    /// The last read, and whether it listed the processes.
    @ObservationIgnored private var last: (time: Date, processes: Bool)?
    @ObservationIgnored private var reading = false

    init(session: Session) {
        self.session = session
        monitor = Monitor(session: session)
    }

    /// Reads the server until the calling task is cancelled (its view went away, or AirSCP left the front). A read a
    /// moment old, made for another view, does: one sampler per server.
    func sample(processes: Bool) async {
        let interval: TimeInterval = processes ? 3 : 10
        while !Task.isCancelled {
            let fresh = last.map { Date().timeIntervalSince($0.time) < interval - 1 && ($0.processes || !processes) } ?? false
            if !fresh { await read(processes: processes) }
            // The CPU needs two reads (the share of the time between them): the second comes soon.
            try? await Task.sleep(for: .seconds(snapshot != nil && snapshot?.cpu == nil ? 2 : interval))
        }
    }

    /// One read now, unless one is under way. Not connected, the figures go (they would look current, with Kill on).
    func read(processes: Bool = true) async {
        guard !reading else { return }
        guard session.state == .connected else {
            (snapshot, history, last) = (nil, [], nil)
            return
        }
        reading = true
        defer { reading = false }
        do {
            var fresh = try await monitor.refresh(processes: processes)
            if !processes { (fresh.processes, fresh.processNote) = (snapshot?.processes ?? [], snapshot?.processNote) }
            (snapshot, failure) = (fresh, nil)
            let now = Date()
            last = (now, processes)
            if let cpu = fresh.cpu {
                if let previous = history.last, now.timeIntervalSince(previous.time) > 30 { history = [] }
                history = history.filter { now.timeIntervalSince($0.time) <= 15 * 60 } + [Sample(time: now, cpu: cpu)]
            }
        } catch let error as AirSCPError {
            // Lost or cancelled: the session says so (Servers), or the view went.
            if error.kind != .cancelled && error.kind != .disconnected { (snapshot, failure) = (nil, error) }
        } catch {
            (snapshot, failure) = (nil, AirSCPError(.other, error.localizedDescription))
        }
    }
}

extension MonitorSnapshot {
    /// Memory in use, 0…1.
    var memoryShare: Double? { memoryTotal > 0 ? Double(memoryUsed) / Double(memoryTotal) : nil }
    /// The disk at /, else the first.
    var mainDisk: MonitorDisk? { disks.first { $0.mountPoint == "/" } ?? disks.first }
}

extension MonitorDisk {
    var share: Double { size > 0 ? Double(used) / Double(size) : 0 }
}

/// A share's colour, as the Mac's usage bars: `normal` below 80 %, orange from 80 %, red from 90 %.
func usageColor(_ fraction: Double?, normal: Color = .teal) -> Color {
    guard let fraction else { return normal }
    return fraction >= 0.9 ? .red : fraction >= 0.8 ? .orange : normal
}

/// "12%".
func percent(_ fraction: Double?) -> String {
    fraction.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—"
}

/// The Monitor screen (mockup 12) of an open server: CPU, memory and disk as rings, the CPU while the screen shows (up to
/// 15 minutes), the disks, and the busiest processes with Kill (asked first, as the Mac asks).
struct MonitorView: View {
    @Environment(AppState.self) private var app
    @Environment(\.scenePhase) private var phase
    @Environment(\.verticalSizeClass) private var height
    let hostID: UUID
    @State private var search = ""
    @State private var killing: (process: MonitorProcess, force: Bool)?
    @State private var failure: (title: String, message: String)?

    private var session: Session? { app.session(for: hostID) }
    private var name: String { app.data.hosts.first { $0.id == hostID }?.displayName ?? session?.host.displayName ?? "" }

    var body: some View {
        content
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            // Reads while it shows and AirSCP is in front; the connection that is open now (it may be a new one).
            .task(id: "\(session.map { "\(ObjectIdentifier($0))" } ?? "")|\(phase == .active)") {
                if let session, phase == .active { await app.monitor(for: session).sample(processes: true) }
            }
            .alert(killTitle, isPresented: Binding(get: { killing != nil }, set: { if !$0 { killing = nil } }),
                   presenting: killing) { target in
                Button(target.force ? "Force Kill" : "Kill", role: .destructive) { kill(target.process, force: target.force) }
                Button("Cancel", role: .cancel) {}
            } message: { target in
                Text(target.force ? "The process is stopped at once (SIGKILL), without a chance to save anything."
                     : "The process is asked to quit (SIGTERM).")
            }
            .alert(failure?.title ?? "", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
                   presenting: failure) { _ in
                Button("OK") {}
            } message: { failure in
                Text(failure.message)
            }
    }

    /// The figures, or what stands in for them: connecting, not connected, why the system can't be read, reading.
    @ViewBuilder private var content: some View {
        let monitor = session.map { app.monitor(for: $0) }
        if let session, app.states[hostID] != .connected {
            switch app.states[hostID] ?? .idle {
            case .connecting, .reconnecting:
                ProgressView("Connecting…")
            default:
                ContentUnavailableView {
                    Label("Not connected", systemImage: "bolt.horizontal.circle")
                } description: {
                    Text("Connect to \(name) again to see its CPU, memory, disks and processes.")
                } actions: {
                    Button("Connect") { app.connect(app.data.hosts.first { $0.id == hostID } ?? session.host) }
                        .help("Connect to this server again")
                }
            }
        } else if let monitor, let snapshot = monitor.snapshot {
            figures(snapshot, monitor)
        } else if let error = monitor?.failure {
            ContentUnavailableView {
                Label("Can't read the system", systemImage: "gauge.with.dots.needle.0percent")
            } description: {
                Text(Self.explained(error))
            }
        } else if monitor != nil {
            ProgressView("Reading the system…")
        } else {
            ContentUnavailableView("Not open", systemImage: "server.rack",
                                   description: Text("Open \(name) in Servers to see its CPU, memory, disks and processes."))
        }
    }

    private func figures(_ snapshot: MonitorSnapshot, _ monitor: HostMonitor) -> some View {
        List {
            Section {
                rings(snapshot)
            } footer: {
                Text(Self.summary(snapshot))
            }
            Section {
                chart(monitor.history)
            } header: {
                Text("CPU")
            } footer: {
                Text("While AirSCP shows this server, up to 15 minutes: iOS doesn't let it read servers in the background.")
            }
            processes(snapshot)
            if snapshot.disks.count > 1 { disks(snapshot.disks) }  // one alone: its ring says it all
        }
        .searchable(text: $search, prompt: "Name, user, command or PID")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
    }

    // MARK: Figures

    private func rings(_ snapshot: MonitorSnapshot) -> some View {
        let disk = snapshot.mainDisk
        return HStack(alignment: .top) {
            ring("CPU", snapshot.cpu.map { $0 / 100 }, detail: snapshot.load.first.map { String(format: "load %.2f", $0) } ?? "",
                 help: "CPU in use, of all cores, since the read before (every 3 s)", id: "monitor.cpu")
            ring("Memory", snapshot.memoryShare, detail: "\(FileRow.size(snapshot.memoryUsed)) of \(FileRow.size(snapshot.memoryTotal))",
                 help: "Memory in use of the total, without caches", id: "monitor.memory")
            ring(disk.map { "Disk " + $0.mountPoint } ?? "Disk", disk?.share,
                 detail: disk.map { "\(FileRow.size($0.available)) free" } ?? "",
                 help: "How full the disk at \(disk?.mountPoint ?? "/") is", id: "monitor.disk")
        }
        .padding(.vertical, 6)
    }

    private func ring(_ title: String, _ fraction: Double?, detail: String, help: String, id: String) -> some View {
        VStack(spacing: 6) {
            Gauge(value: min(max(fraction ?? 0, 0), 1)) {
                Text(title)
            } currentValueLabel: {
                Text(percent(fraction)).monospacedDigit()
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(usageColor(fraction))
            Text(title).font(.caption.weight(.semibold)).lineLimit(1)
            Text(detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(percent(fraction) + (detail.isEmpty ? "" : ", " + detail))
        .accessibilityIdentifier(id)
        .help(help)
    }

    @ViewBuilder private func chart(_ history: [HostMonitor.Sample]) -> some View {
        if history.count < 2 {
            Text("Measuring…").foregroundStyle(.secondary)
        } else {
            Chart(history) { sample in
                AreaMark(x: .value("Time", sample.time), y: .value("CPU", sample.cpu))
                    .foregroundStyle(.linearGradient(colors: [.teal.opacity(0.35), .teal.opacity(0.05)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", sample.time), y: .value("CPU", sample.cpu))
                    .foregroundStyle(.teal)
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine()
                    AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%") }
                }
            }
            .frame(height: height == .compact ? 70 : 120)  // an iPhone on its side has little height
            .padding(.vertical, 4)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("CPU")
            .accessibilityValue("Now \(percent((history.last?.cpu ?? 0) / 100)), at most \(percent((history.map(\.cpu).max() ?? 0) / 100))")
            .accessibilityIdentifier("monitor.chart")
        }
    }

    private func disks(_ disks: [MonitorDisk]) -> some View {
        Section("Disks") {
            ForEach(disks) { disk in
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent(disk.mountPoint) {
                        Text("\(FileRow.size(disk.available)) free of \(FileRow.size(disk.size))").monospacedDigit()
                    }
                    ProgressView(value: disk.share).tint(usageColor(disk.share))
                }
                .help("\(disk.mountPoint) (\(disk.filesystem)): \(percent(disk.share)) used")
            }
        }
    }

    // MARK: Processes

    /// The busiest ten (most CPU, then memory), or every one matching the search.
    @ViewBuilder private func processes(_ snapshot: MonitorSnapshot) -> some View {
        let term = search.trimmingCharacters(in: .whitespaces)
        let busiest = snapshot.processes.sorted { ($0.cpu ?? -1, $0.rss) > ($1.cpu ?? -1, $1.rss) }
        let shown = term.isEmpty ? Array(busiest.prefix(10)) : busiest.filter { process in
            String(process.pid) == term || [process.name, process.user, process.command].contains { $0.localizedCaseInsensitiveContains(term) }
        }
        Section {
            if let note = snapshot.processNote, snapshot.processes.isEmpty {
                Text(note).foregroundStyle(.secondary)
            } else if shown.isEmpty {
                Text("No process matches “\(term)”.").foregroundStyle(.secondary)
            }
            ForEach(shown) { process in
                ProcessRow(process: process)
                    .swipeActions {
                        Button("Kill", systemImage: "xmark.octagon", role: .destructive) { killing = (process, false) }
                            .tint(.red)  // the app's teal tint would colour a swipe button's red too
                            .help("Ask this process to quit (SIGTERM); asks first")
                    }
                    .contextMenu {
                        Button("Kill", systemImage: "xmark.octagon", role: .destructive) { killing = (process, false) }
                            .help("Ask this process to quit (SIGTERM); asks first")
                        Button("Force Kill", systemImage: "bolt.slash", role: .destructive) { killing = (process, true) }
                            .help("Stop this process at once (SIGKILL); asks first")
                    }
            }
        } header: {
            Text(term.isEmpty ? "Busiest processes" : "Processes")
        } footer: {
            if term.isEmpty && snapshot.processes.count > shown.count {
                Text("The \(shown.count) busiest of \(snapshot.processes.count). Search to find any other.")
            }
        }
    }

    private var killTitle: String {
        guard let killing else { return "" }
        return "\(killing.force ? "Force kill" : "Kill") “\(killing.process.name)” (\(killing.process.pid))?"
    }

    private func kill(_ process: MonitorProcess, force: Bool) {
        guard let session else { return }
        let monitor = app.monitor(for: session)
        Task {
            do {
                try await monitor.monitor.kill(process.pid, force: force)
            } catch let error as AirSCPError where error.kind == .permissionDenied {
                failure = ("You may not kill “\(process.name)”", "The process belongs to another user. To stop it as an administrator, "
                           + "type \(Monitor.sudoKillCommand([process.pid], force: force)) in Terminal.")
            } catch {
                failure = ("Can't kill “\(process.name)”", (error as? AirSCPError)?.message ?? error.localizedDescription)
            }
            await monitor.read()
        }
    }

    /// "Debian GNU/Linux 13 (trixie) · up 3d 4h · load 0.42 0.30 0.25".
    static func summary(_ snapshot: MonitorSnapshot) -> String {
        let up = Duration.seconds(snapshot.uptime).formatted(.units(allowed: [.days, .hours, .minutes], width: .abbreviated,
                                                                     maximumUnitCount: 2))
        let load = snapshot.load.map { String(format: "%.2f", $0) }.joined(separator: " ")
        return [snapshot.system, "up " + up, load.isEmpty ? "" : "load " + load].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Core's words, with what still works here (the Mac's name its own tabs).
    static func explained(_ error: AirSCPError) -> String {
        if error.kind == .sftpOnly { return error.message + " AirSCP can't read its system: Files works as usual." }
        return error.message.replacingOccurrences(of: "The Files and Tunnels tabs work as usual.", with: "Files and Terminal work as usual.")
    }
}

/// A process: its name, PID, user and command line; its CPU and memory.
private struct ProcessRow: View {
    let process: MonitorProcess

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(process.name).lineLimit(1)
                // Verbatim: a PID has no thousands separator, and a command line isn't markdown.
                Text(verbatim: "\(process.pid) · \(process.user) · \(process.command.isEmpty ? process.name : process.command)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(process.cpu.map { String(format: "%.1f%%", $0) } ?? "—")
                Text(FileRow.size(process.rss)).font(.caption).foregroundStyle(.secondary)
            }
            .monospacedDigit()
        }
        .accessibilityElement(children: .combine)
        .help(process.command)
    }
}

/// A connected server's CPU, memory and disk under its name in Servers (mockups 1–2).
struct MonitorFigures: View {
    let snapshot: MonitorSnapshot

    var body: some View {
        HStack(spacing: 14) {
            figure("CPU", snapshot.cpu.map { $0 / 100 })
            figure("Memory", snapshot.memoryShare)
            figure("Disk", snapshot.mainDisk?.share)
        }
        .font(.caption.monospacedDigit())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("figures")
    }

    private func figure(_ name: String, _ fraction: Double?) -> some View {
        HStack(spacing: 4) {
            Text(name).foregroundStyle(Color.secondary)
            Text(percent(fraction)).fontWeight(.semibold).foregroundStyle(usageColor(fraction, normal: .primary))
        }
        .help("\(name) in use")
    }
}
