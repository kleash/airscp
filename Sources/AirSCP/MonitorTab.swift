import AirSCPCore
import AppKit
import Combine
import SwiftUI

/// The host workspace's Monitor tab: CPU, load, memory and swap, uptime and system, the disks with usage bars, and
/// the process list (sortable, searchable; Kill and Force Kill, or "Kill with sudo in Terminal" when the account may
/// not). It refreshes every 3 s while it is on screen and the host is connected; while only the workspace is (its
/// header's pulse strip), every 10 s without the processes; otherwise it runs nothing. Like
/// `BrowserContentController`, one is made per Session.
@MainActor
final class MonitorController: NSViewController {
    weak var workspace: HostWorkspace?
    let session: Session
    let model: MonitorModel
    private var timer: Timer?
    private var timerInterval: TimeInterval = 0
    private var onScreen = false
    private var agentWatch: AnyCancellable?
    /// The workspace, and with it the header's pulse strip, is on screen.
    var showsPulse = false {
        didSet { update() }
    }

    static let interval: TimeInterval = 3
    static let pulseInterval: TimeInterval = 10

    /// `workspace` nil (tests): Kill with sudo has no Terminal to open.
    init(workspace: HostWorkspace?, session: Session) {
        self.workspace = workspace
        self.session = session
        model = MonitorModel(monitor: Monitor(session: session))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        view = NSHostingView(rootView: MonitorView(model: model) { [weak self] processes, force in
            self?.kill(processes, force: force)
        })
        NotificationCenter.default.addObserver(self, selector: #selector(windowOcclusionChanged(_:)),
                                               name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        // An agent at work reads the tab also while the window is covered (after the change: @Published tells before).
        agentWatch = workspace?.model.$agentActive.removeDuplicates().sink { [weak self] _ in
            DispatchQueue.main.async { self?.update() }
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        onScreen = true
        update()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        onScreen = false
        update()
    }

    /// Every state change of `session`: refreshing stops when it isn't `.connected`, and the last figures go (they
    /// would look current, with Kill on).
    func stateChanged(_ state: Session.State) {
        model.connected = state == .connected
        if state != .connected { model.snapshot = nil }
        update()
    }

    @objc private func windowOcclusionChanged(_ notification: Notification) {
        if notification.object as? NSWindow === workspace?.window { update() }
    }

    /// What anyone can see, refreshed how often: the tab (everything) or only the header's pulse strip (no processes).
    /// Nothing while the host isn't connected or the window is covered or minimised, unless an agent is at work (it
    /// reads the tab whether or not it is covered).
    private var sampling: (interval: TimeInterval, processes: Bool)? {
        guard session.state == .connected,
              workspace?.window?.occlusionState.contains(.visible) == true || workspace?.model.agentActive == true else { return nil }
        if onScreen && !view.isHiddenOrHasHiddenAncestor { return (Self.interval, true) }
        return showsPulse ? (Self.pulseInterval, false) : nil
    }

    /// Whether it samples now.
    var isVisible: Bool { sampling != nil }

    private func update() {
        guard let sampling else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard timer == nil || timerInterval != sampling.interval else { return }
        timer?.invalidate()
        timerInterval = sampling.interval
        model.refresh(processes: sampling.processes)
        timer = Timer.scheduledTimer(withTimeInterval: sampling.interval, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { return timer.invalidate() }
                if let now = self.sampling, now.interval == self.timerInterval {
                    self.model.refresh(processes: now.processes)
                } else {
                    self.update()
                }
            }
        }
    }

    /// Kill / Force Kill after asking; when the account may not, offers `sudo kill` in Terminal.
    private func kill(_ processes: [MonitorProcess], force: Bool) {
        guard !processes.isEmpty, let window = view.window else { return }
        let what = processes.count == 1 ? "“\(processes[0].name)” (\(processes[0].pid))" : "\(processes.count) processes"
        confirm("\(force ? "Force kill" : "Kill") \(what)?",
                info: force ? "The process is stopped at once (SIGKILL), without a chance to save anything."
                    : "The process is asked to quit (SIGTERM).",
                button: force ? "Force Kill" : "Kill", destructive: true, on: window) { [self] in
            Task {
                var denied: [MonitorProcess] = []
                var failures: [(name: String, error: Error)] = []
                for process in processes {
                    do {
                        try await model.monitor.kill(process.pid, force: force)
                    } catch let error as AirSCPError where error.kind == .permissionDenied {
                        denied.append(process)
                    } catch {
                        failures.append(("\(process.name) (\(process.pid))", error))
                    }
                }
                // One sheet for all of them.
                workspace?.browser.showFailures(failures, verb: "kill")
                model.refresh()
                guard !denied.isEmpty else { return }
                let title = "You may not kill \(denied.count == 1 ? "“\(denied[0].name)”" : "\(denied.count) of them")"
                guard await model.monitor.hasSudo() else {
                    showError(AirSCPError(.permissionDenied, "The process belongs to another user, and the server has no "
                                          + "sudo to kill it as an administrator."), title: title, on: view.window)
                    return
                }
                confirm(title,
                        info: "The process belongs to another user. Kill it with sudo in Terminal? Terminal asks for "
                            + "your password on the server.",
                        button: "Kill with sudo in Terminal", on: view.window) { [self] in
                    workspace?.openTerminal(command: Monitor.sudoKillCommand(denied.map(\.pid), force: force))
                }
            }
        }
    }
}

/// The Monitor tab's data: the latest snapshot (one refresh at a time) or why there is none, and the last few CPU,
/// memory and disk figures for the header's pulse strip.
@MainActor
final class MonitorModel: ObservableObject {
    let monitor: Monitor
    @Published var snapshot: MonitorSnapshot? {
        didSet { if snapshot == nil { pulse = [] } }
    }
    @Published private(set) var failure: String?
    @Published private(set) var refreshing = false
    @Published var connected = false
    /// Used shares (0…1) of CPU, memory and the root disk, oldest first: the pulse strip's sparklines.
    @Published private(set) var pulse: [(cpu: Double?, memory: Double?, disk: Double?)] = []
    /// A refresh with the processes was asked for while one without them ran.
    private var processesWanted = false
    /// The process list's search, selection and sort, as the table shows them (agents set them too).
    @Published var search = ""
    @Published var selection = Set<MonitorProcess.ID>()
    @Published var sortOrder = [KeyPathComparator(\MonitorProcess.cpuOrder, order: .reverse)]

    /// The processes as the table lists them: those matching the search, in the table's order.
    var rows: [MonitorProcess] {
        MonitorText.filter(snapshot?.processes ?? [], search).sorted(using: sortOrder)
    }

    init(monitor: Monitor) {
        self.monitor = monitor
        connected = monitor.session.state == .connected
    }

    func refresh(processes: Bool = true) {
        guard !refreshing else {
            processesWanted = processesWanted || processes
            return
        }
        refreshing = true
        Task {
            do {
                var fresh = try await monitor.refresh(processes: processes)
                if !processes {  // the processes listed last stay until the tab lists them again
                    fresh.processes = snapshot?.processes ?? []
                    fresh.processNote = snapshot?.processNote
                }
                snapshot = fresh
                failure = nil
                let disk = fresh.disks.first { $0.mountPoint == "/" } ?? fresh.disks.first
                pulse = (pulse + [(fresh.cpu.map { $0 / 100 }, share(fresh.memoryUsed, fresh.memoryTotal),
                                   disk.flatMap { share($0.used, $0.size) })]).suffix(12)
            } catch let error as AirSCPError {
                if error.kind != .cancelled && error.kind != .disconnected { failure = error.message }
            } catch {
                failure = error.localizedDescription
            }
            refreshing = false
            if processesWanted {
                processesWanted = false
                refresh()
            }
        }
    }

    private func share(_ used: Int64, _ total: Int64) -> Double? {
        total > 0 ? Double(used) / Double(total) : nil
    }
}

struct MonitorView: View {
    @ObservedObject var model: MonitorModel
    let kill: ([MonitorProcess], Bool) -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let snapshot = model.snapshot {
            // The figures on the window's ground, the processes on a card (Paper; edge to edge in Night Harbor).
            VStack(alignment: .leading, spacing: 0) {
                overview(snapshot)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                if scheme == .dark { Divider() }
                processes(snapshot).card()
            }
        } else {
            VStack(spacing: 10) {
                if model.refreshing { ProgressView().controlSize(.small) }
                Text(model.failure.map(MonitorText.explained) ?? (model.connected ? (model.refreshing ? "Reading the system…" : "")
                     : "Not connected. Connect to see CPU, memory, disks and processes."))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: Overview

    private func overview(_ snapshot: MonitorSnapshot) -> some View {
        HStack(alignment: .top, spacing: 24) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 7) {
                GridRow {
                    label("CPU").help("Share of all cores in use since the last refresh (every 3 s)")
                    usage(snapshot.cpu.map { $0 / 100 }, text: snapshot.cpu.map { String(format: "%.0f %%", $0) } ?? "…")
                }
                GridRow {
                    label("Memory").help("Memory in use of the total, without caches")
                    usage(fraction(snapshot.memoryUsed, snapshot.memoryTotal),
                          text: "\(FileList.size(snapshot.memoryUsed)) of \(FileList.size(snapshot.memoryTotal))")
                }
                GridRow {
                    label("Swap").help("Memory moved to disk; much swap means the server is short of memory")
                    usage(fraction(snapshot.swapUsed, snapshot.swapTotal), text: snapshot.swapTotal == 0 ? "None"
                          : "\(FileList.size(snapshot.swapUsed)) of \(FileList.size(snapshot.swapTotal))")
                }
                GridRow {
                    label("Load").help("Load average over 1, 5 and 15 minutes")
                    Text(snapshot.load.map { String(format: "%.2f", $0) }.joined(separator: "  ")).monospacedDigit()
                        .help("Load average over 1, 5 and 15 minutes")
                }
                GridRow {
                    label("Up").help("Time since the server started")
                    Text(MonitorText.uptime(snapshot.uptime))
                }
                GridRow {
                    label("System").help("The operating system, from /etc/os-release")
                    Text(snapshot.system).lineLimit(1).textSelection(.enabled)
                }
            }
            .frame(minWidth: 280, maxWidth: 380, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                Text("Disks").font(.subheadline.weight(.semibold)).help("Each mounted file system: how full it is")
                ScrollView {
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                        ForEach(snapshot.disks) { disk in
                            GridRow {
                                // A long mount point is shortened in the middle, not its usage text.
                                Text(disk.mountPoint).lineLimit(1).truncationMode(.middle)
                                    .frame(maxWidth: 150, alignment: .leading).help(disk.mountPoint + " (" + disk.filesystem + ")")
                                usage(fraction(disk.used, disk.size),
                                      text: "\(FileList.size(disk.available)) free of \(FileList.size(disk.size))")
                            }
                        }
                    }
                }
                .frame(height: min(150, CGFloat(snapshot.disks.count) * 22))
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).foregroundColor(.secondary).gridColumnAlignment(.trailing)
    }

    private func fraction(_ used: Int64, _ total: Int64) -> Double? {
        total > 0 ? Double(used) / Double(total) : nil
    }

    private func usage(_ fraction: Double?, text: String) -> some View {
        HStack(spacing: 8) {
            UsageBar(fraction: fraction ?? 0).frame(width: 110, height: 7)
            Text(text).monospacedDigit().lineLimit(1).fixedSize()
        }
    }

    // MARK: Processes

    private func processes(_ snapshot: MonitorSnapshot) -> some View {
        let rows = model.rows
        let chosen = rows.filter { model.selection.contains($0.id) }
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Processes").font(.subheadline.weight(.semibold))
                Text(rows.count == snapshot.processes.count ? "\(rows.count)" : "\(rows.count) of \(snapshot.processes.count)")
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                TextField("Search name, user, command or PID", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("monitor.search")
                    .frame(maxWidth: 240)
                    .help("Show only processes matching this")
                Button("Kill") { kill(chosen, false) }.disabled(chosen.isEmpty)
                    .help(chosen.isEmpty ? "Select processes first" : "Ask the selected processes to quit (SIGTERM); asks first")
                Button("Force Kill") { kill(chosen, true) }.disabled(chosen.isEmpty)
                    .help(chosen.isEmpty ? "Select processes first" : "Stop the selected processes at once (SIGKILL); asks first")
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .bar))
            Divider()
            if let note = snapshot.processNote, snapshot.processes.isEmpty {
                Text(note).foregroundColor(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(rows, selection: $model.selection, sortOrder: $model.sortOrder) {
                    TableColumn("PID", value: \.pid) { Text(String($0.pid)).monospacedDigit() }
                        .width(min: 44, ideal: 56)
                    TableColumn("User", value: \.user) { Text($0.user).lineLimit(1) }
                        .width(min: 50, ideal: 80)
                    TableColumn("% CPU", value: \.cpuOrder) { process in
                        Text(process.cpu.map { String(format: "%.1f", $0) } ?? "—").monospacedDigit()
                    }
                    .width(min: 56, ideal: 64)
                    TableColumn("% Mem", value: \.memoryOrder) { process in
                        Text(process.memory.map { String(format: "%.1f", $0) } ?? "—").monospacedDigit()
                    }
                    .width(min: 56, ideal: 64)
                    TableColumn("Memory", value: \.rss) { Text(FileList.size($0.rss)).monospacedDigit() }
                        .width(min: 56, ideal: 72)
                    TableColumn("Time", value: \.elapsedOrder) { process in
                        Text(process.elapsed.map(MonitorText.elapsed) ?? "—").monospacedDigit()
                    }
                    .width(min: 50, ideal: 76)
                    TableColumn("State", value: \.state) { Text($0.state) }
                        .width(min: 36, ideal: 44)
                    TableColumn("Command", value: \.command) { process in
                        Text(process.command.isEmpty ? process.name : process.command).lineLimit(1).truncationMode(.tail)
                            .help(process.command)
                    }
                    .width(min: 120, ideal: 420)
                }
                .washed()
                .contextMenu(forSelectionType: MonitorProcess.ID.self) { ids in
                    let picked = rows.filter { ids.contains($0.id) }
                    Button("Kill") { kill(picked, false) }.help("Ask the selected processes to quit (SIGTERM); asks first")
                    Button("Force Kill") { kill(picked, true) }.help("Stop the selected processes at once (SIGKILL); asks first")
                }
            }
        }
    }
}

/// A usage bar: teal in Night Harbor, labelColor in Paper; orange from 80 % and red from 90 % full.
struct UsageBar: View {
    let fraction: Double
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(nsColor: .quaternaryLabelColor))
                Capsule().fill(Self.color(fraction, normal: scheme == .dark ? Color(nsColor: .systemTeal) : .primary))
                    .frame(width: geometry.size.width * min(max(fraction, 0), 1))
            }
        }
        .help(String(format: "%.0f %% used", fraction * 100))
    }

    /// `normal` below 80 %, orange from 80 % and red from 90 %.
    static func color(_ fraction: Double, normal: Color) -> Color {
        fraction >= 0.9 ? Color(nsColor: .systemRed) : fraction >= 0.8 ? Color(nsColor: .systemOrange) : normal
    }
}

/// The server's pulse in the workspace header: CPU, memory and the root disk from the Monitor tab's sampler, hidden
/// until it has figures and where it can't read the system (not Linux, sftp only). Night Harbor shows rings in the
/// lab's teal, Remote Desktop's purple and the proxies' orange; Paper heavy figures, a small status chip and a
/// monochrome sparkline.
struct PulseStrip: View {
    @ObservedObject var monitor: MonitorModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let snapshot = monitor.snapshot, monitor.failure == nil {
            // As many of the three as there is room for: the window's narrowest leaves the host's name and route room.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { cpu(snapshot); memory(snapshot); disk(snapshot) }
                HStack(spacing: 8) { cpu(snapshot); memory(snapshot) }
                cpu(snapshot)
                EmptyView()
            }
        }
    }

    private func cpu(_ snapshot: MonitorSnapshot) -> some View {
        cell("CPU", fraction: snapshot.cpu.map { $0 / 100 }, hue: .systemTeal, history: monitor.pulse.map(\.cpu),
             value: snapshot.cpu.map { String(format: "%.0f%%", $0) } ?? "—",
             detail: snapshot.load.first.map { String(format: "load %.2f", $0) } ?? "", chip: cpuChange,
             help: "CPU in use, of all cores; load average " + snapshot.load.map { String(format: "%.2f", $0) }
                .joined(separator: " ") + " over 1, 5 and 15 minutes. The Monitor tab shows more")
    }

    private func memory(_ snapshot: MonitorSnapshot) -> some View {
        let used = monitor.pulse.last?.memory, total = Self.figure(snapshot.memoryTotal)
        return cell("Memory", fraction: used, hue: .systemPurple, history: monitor.pulse.map(\.memory),
                    value: Self.figure(snapshot.memoryUsed).number, detail: "of \(total.number) \(total.unit)",
                    chip: used.map { String(format: "%.0f%%", $0 * 100) } ?? "",
                    help: "Memory in use: \(FileList.size(snapshot.memoryUsed)) of \(FileList.size(snapshot.memoryTotal)), "
                        + "without caches")
    }

    @ViewBuilder
    private func disk(_ snapshot: MonitorSnapshot) -> some View {
        if let disk = snapshot.disks.first(where: { $0.mountPoint == "/" }) ?? snapshot.disks.first {
            let used = Double(disk.used) / Double(max(disk.size, 1)), free = Self.figure(disk.available)
            cell("Disk " + disk.mountPoint, fraction: used, hue: .systemOrange, history: monitor.pulse.map(\.disk),
                 value: scheme == .dark ? String(format: "%.0f%%", used * 100) : free.number,
                 detail: "\(free.number) \(free.unit) free", chip: free.unit,
                 help: "The disk at \(disk.mountPoint): \(FileList.size(disk.available)) free of "
                    + FileList.size(disk.size) + String(format: " (%.0f %% used)", used * 100))
        }
    }

    /// CPU points since the previous figure: "−4", "+2".
    private var cpuChange: String {
        let figures = monitor.pulse.compactMap(\.cpu).suffix(2)
        guard figures.count == 2, let last = figures.last, let first = figures.first else { return "" }
        let change = Int(((last - first) * 100).rounded())
        return change > 0 ? "+\(change)" : change < 0 ? "−\(-change)" : "0"
    }

    /// A figure for the strip and its unit: "38" GB, "4.9" GB, "1.8" TB.
    static func figure(_ bytes: Int64) -> (number: String, unit: String) {
        let gigabytes = Double(bytes) / 1e9
        if gigabytes >= 1000 { return (String(format: "%.1f", gigabytes / 1000), "TB") }
        return (String(format: gigabytes >= 10 ? "%.0f" : "%.1f", gigabytes), "GB")
    }

    private func cell(_ key: String, fraction: Double?, hue: NSColor, history: [Double?], value: String, detail: String,
                      chip: String, help: String) -> some View {
        HStack(spacing: 8) {
            if scheme == .dark { PulseRing(fraction: fraction ?? 0, hue: Color(nsColor: hue)) }
            VStack(alignment: .leading, spacing: 1) {
                Text(key).textCase(.uppercase).font(.system(size: 10, weight: .bold)).tracking(0.6).foregroundStyle(.tertiary)
                    .lineLimit(1)
                if scheme == .dark {
                    (Text(value).font(.system(size: 13, weight: .bold))
                        + Text(" " + detail).font(.system(size: 10.5, weight: .medium)).foregroundColor(.secondary))
                        .monospacedDigit().lineLimit(1)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(value).font(.system(size: 17, weight: .heavy)).monospacedDigit().fixedSize()
                        if !chip.isEmpty {
                            let level = UsageBar.color(fraction ?? 0, normal: Color(nsColor: .systemGreen))
                            Text(chip).font(.system(size: 10, weight: .bold)).monospacedDigit().fixedSize()
                                .foregroundColor(Color(nsColor: .readable(Self.status(fraction ?? 0))))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4).fill(level.opacity(0.14)))
                        }
                    }
                }
            }
            if scheme == .light { Sparkline(values: history.compactMap { $0 }).frame(width: 46, height: 20) }
        }
        .fixedSize()
        .padding(EdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 10))
        .frame(minWidth: 112, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(scheme == .dark ? Color.primary.opacity(0.04) : Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(scheme == .dark ? 0.07 : 0.1)))
        .help(help)
        .accessibilityElement(children: .combine)
    }

    /// Green below 80 %, orange from 80 %, red from 90 %.
    private static func status(_ fraction: Double) -> NSColor {
        fraction >= 0.9 ? .systemRed : fraction >= 0.8 ? .systemOrange : .systemGreen
    }
}

/// A 28 pt ring: the share in the hue over labelColor at 10 %.
private struct PulseRing: View {
    let fraction: Double
    let hue: Color

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.1), lineWidth: 3)
            Circle().trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(hue, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(2)
        .frame(width: 28, height: 28)
    }
}

/// The last figures as a line in labelColor, with a faint area under it and a dot at the newest.
private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geometry in
            let points = values.enumerated().map { index, value in
                CGPoint(x: values.count < 2 ? geometry.size.width : geometry.size.width * CGFloat(index) / CGFloat(values.count - 1),
                        y: 2 + (geometry.size.height - 4) * (1 - CGFloat(min(max(value, 0), 1))))
            }
            if let last = points.last, points.count > 1 {
                Path { path in
                    path.addLines(points)
                    path.addLine(to: CGPoint(x: last.x, y: geometry.size.height))
                    path.addLine(to: CGPoint(x: 0, y: geometry.size.height))
                }
                .fill(Color.primary.opacity(0.08))
                Path { $0.addLines(points) }.stroke(Color.primary, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                Circle().fill(Color.primary).frame(width: 3.6, height: 3.6).position(last)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Sort keys for the process table (BusyBox has no %CPU: those go last).
extension MonitorProcess {
    var cpuOrder: Double { cpu ?? -1 }
    var memoryOrder: Double { memory ?? -1 }
    var elapsedOrder: Double { elapsed ?? -1 }
}

enum MonitorText {
    /// A failure with what still works: an sftp-only account can't be read, but its Files tab works.
    static func explained(_ failure: String) -> String {
        failure.hasPrefix("This account allows file transfers (sftp) only")
            ? "This account allows file transfers (sftp) only, so AirSCP can't read the system. The Files tab works." : failure
    }

    /// The processes whose name, user, command or PID contains `search` (any case).
    static func filter(_ processes: [MonitorProcess], _ search: String) -> [MonitorProcess] {
        let term = search.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return processes }
        return processes.filter { process in
            String(process.pid) == term || [process.name, process.user, process.command].contains {
                $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
    }

    /// "12 days, 3:04", "3:04", "4 min".
    static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86400, hours = total / 3600 % 24, minutes = total / 60 % 60
        let clock = hours > 0 ? String(format: "%d:%02d", hours, minutes) : "\(minutes) min"
        return days > 0 ? "\(days) day\(days == 1 ? "" : "s"), " + clock : clock
    }

    /// ps etime style: "05:07", "1:02:03", "2-03:04:05".
    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let days = total / 86400, hours = total / 3600 % 24, minutes = total / 60 % 60, rest = total % 60
        if days > 0 { return String(format: "%d-%02d:%02d:%02d", days, hours, minutes, rest) }
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, rest) }
        return String(format: "%02d:%02d", minutes, rest)
    }
}
