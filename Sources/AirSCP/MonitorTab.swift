import AirSCPCore
import AppKit
import Combine
import SwiftUI

/// The host workspace's Monitor tab: CPU, load, memory and swap, uptime and system, the disks with usage bars, and
/// the process list (sortable, searchable; Kill and Force Kill, or "Kill with sudo in Terminal" when the account may
/// not) or the ports the server listens on. It refreshes every 3 s while it is on screen and the host is connected,
/// every 5 s with the ports while they are shown (reading them is costly: never otherwise); while only the workspace
/// is (its header's pulse strip), every 10 s without the processes; otherwise it runs nothing. Like
/// `BrowserContentController`, one is made per Session.
@MainActor
final class MonitorController: NSViewController {
    weak var workspace: HostWorkspace?
    let session: Session
    let model: MonitorModel
    private var timer: Timer?
    private var current: Sampling?
    private var onScreen = false
    private var watches: [AnyCancellable] = []
    /// The workspace, and with it the header's pulse strip, is on screen.
    var showsPulse = false {
        didSet { update() }
    }

    static let interval: TimeInterval = 3
    static let portsInterval: TimeInterval = 5
    static let pulseInterval: TimeInterval = 10

    /// How often to refresh, and what.
    private struct Sampling: Equatable {
        var interval: TimeInterval
        var processes = false
        var ports = false
    }

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
        // An agent at work reads the tab also while the window is covered; Processes or Ports, and Pause, change what
        // is read (after the change: @Published tells before).
        let changes = [workspace?.model.$agentActive.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
                       model.$shown.removeDuplicates().map { _ in () }.eraseToAnyPublisher(),
                       model.$paused.removeDuplicates().map { _ in () }.eraseToAnyPublisher()]
        watches = changes.compactMap { $0?.sink { [weak self] in DispatchQueue.main.async { self?.update() } } }
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

    /// Anyone can see the window (or an agent at work reads it, covered or not) of a connected host.
    private var seen: Bool {
        session.state == .connected
            && (workspace?.window?.occlusionState.contains(.visible) == true || workspace?.model.agentActive == true)
    }

    /// The tab is the one shown in its window, not only the header's pulse strip (seen or not), on a connected host.
    private var tabShown: Bool { session.state == .connected && onScreen && !view.isHiddenOrHasHiddenAncestor }

    /// What anyone can see, refreshed how often: the tab (the figures and processes, or the figures and ports, which
    /// Pause leaves as they are) or only the header's pulse strip (no processes). Nothing while the host isn't
    /// connected or the window is covered or minimised, unless an agent is at work.
    private var sampling: Sampling? {
        guard seen else { return nil }
        if tabShown {
            if model.shown == .processes { return Sampling(interval: Self.interval, processes: true) }
            return model.paused ? Sampling(interval: Self.interval) : Sampling(interval: Self.portsInterval, processes: true, ports: true)
        }
        return showsPulse ? Sampling(interval: Self.pulseInterval) : nil
    }

    /// Whether it samples now.
    var isVisible: Bool { sampling != nil }

    private func update() {
        // First: no ports are read from the moment Ports isn't shown.
        model.portsShown = tabShown && model.shown == .ports
        guard let sampling else {
            timer?.invalidate()
            timer = nil
            current = nil
            return
        }
        guard timer == nil || current != sampling else { return }
        timer?.invalidate()
        current = sampling
        model.refresh(processes: sampling.processes, ports: sampling.ports)
        timer = Timer.scheduledTimer(withTimeInterval: sampling.interval, repeats: true) { [weak self] timer in
            Task { @MainActor in
                guard let self else { return timer.invalidate() }
                if let now = self.sampling, now == self.current {
                    self.model.refresh(processes: now.processes, ports: now.ports)
                } else {
                    self.update()
                }
            }
        }
    }

    /// Kill / Force Kill after asking; when the account may not, offers `sudo kill` in Terminal.
    private func kill(_ processes: [(pid: Int, name: String)], force: Bool) {
        guard !processes.isEmpty, let window = view.window else { return }
        let what = processes.count == 1 ? "“\(processes[0].name)” (\(processes[0].pid))" : "\(processes.count) processes"
        confirm("\(force ? "Force kill" : "Kill") \(what)?",
                info: force ? "The process is stopped at once (SIGKILL), without a chance to save anything."
                    : "The process is asked to quit (SIGTERM).",
                button: force ? "Force Kill" : "Kill", destructive: true, on: window) { [self] in
            Task {
                var denied: [(pid: Int, name: String)] = []
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
                model.refresh(ports: true)
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
                    workspace?.openTerminal(command: Monitor.sudoKillCommand(denied.map { $0.pid }, force: force))
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
    /// What was asked for while a refresh ran: one more refresh reads it.
    private var wanted: (processes: Bool, ports: Bool)?
    /// The refresh under way, and whether it reads the ports.
    private var running: (task: Task<Void, Never>, ports: Bool)?
    /// The process list's search, selection and sort, as the table shows them (agents set them too).
    @Published var search = ""
    @Published var selection = Set<MonitorProcess.ID>()
    @Published var sortOrder = [KeyPathComparator(\MonitorProcess.cpuOrder, order: .reverse)]

    /// The list under the figures: the processes, or the ports (read only while they are shown). Back to the processes,
    /// the ports go: the next time, they are read afresh.
    enum Shown: String { case processes = "Processes", ports = "Ports" }
    @Published var shown = Shown.processes {
        didSet {
            guard shown != oldValue else { return }
            paused = false
            if shown == .processes { snapshot?.ports = nil }
        }
    }
    /// Ports isn't read every 5 s while paused (a person or an agent can still refresh it, or pick a port).
    @Published var paused = false
    /// The Ports view's search, sort and port (whose connections are read with the ports).
    @Published var portSearch = ""
    @Published var portSortOrder = [KeyPathComparator(\MonitorPort.port)]
    @Published var portSelection: MonitorPort.ID? {
        didSet { if portSelection != oldValue && portSelection != nil { refresh(ports: true) } }
    }
    /// The Ports view is the one shown on a connected host (the controller says): ports are read only then, and while
    /// anyone sees it. From the moment it isn't (Processes, another tab, disconnected), a read under way stops.
    var portsShown = false {
        didSet { if !portsShown && running?.ports == true { running?.task.cancel() } }
    }

    /// The processes as the table lists them: those matching the search, in the table's order.
    var rows: [MonitorProcess] {
        MonitorText.filter(snapshot?.processes ?? [], search).sorted(using: sortOrder)
    }

    /// The ports as the table lists them: those matching the search (and the port picked, which stays), in its order.
    var portRows: [MonitorPort] {
        MonitorText.filter(snapshot?.ports?.listening ?? [], portSearch, keeping: portSelection).sorted(using: portSortOrder)
    }

    /// The port picked, as last read.
    var selectedPort: MonitorPort? {
        snapshot?.ports?.listening.first { $0.id == portSelection }
    }

    init(monitor: Monitor) {
        self.monitor = monitor
        connected = monitor.session.state == .connected
    }

    /// Reads the server: the figures, the processes unless `processes` is false (the pulse strip), the ports when
    /// `ports` and the Ports view is shown (with the connections of the port picked).
    func refresh(processes: Bool = true, ports: Bool = false) {
        guard running == nil else {
            wanted = (processes || wanted?.processes == true, ports || wanted?.ports == true)
            return
        }
        let ports = ports && portsShown
        let port = ports ? selectedPort : nil
        refreshing = true
        let task = Task {
            do {
                var fresh = try await monitor.refresh(processes: processes, ports: ports, connectionsOf: port)
                if !processes {  // the processes listed last stay until the tab lists them again
                    fresh.processes = snapshot?.processes ?? []
                    fresh.processNote = snapshot?.processNote
                }
                // Not read now (paused, or not seen): the ports stay as they were, unless the view went back to processes.
                if shown != .ports { fresh.ports = nil } else if !ports { fresh.ports = snapshot?.ports }
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
            running = nil
            refreshing = false
            if let next = wanted {
                wanted = nil
                refresh(processes: next.processes, ports: next.ports)
            }
        }
        running = (task, ports)
    }

    private func share(_ used: Int64, _ total: Int64) -> Double? {
        total > 0 ? Double(used) / Double(total) : nil
    }
}

struct MonitorView: View {
    @ObservedObject var model: MonitorModel
    /// Kill or Force Kill (`true`) these processes, after asking.
    let kill: ([(pid: Int, name: String)], Bool) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var connectionSort = [KeyPathComparator(\MonitorConnection.address)]
    @State private var connectionSelection = Set<MonitorConnection.ID>()

    var body: some View {
        if let snapshot = model.snapshot {
            // The figures on the window's ground, the processes on a card (Paper; edge to edge in Night Harbor).
            VStack(alignment: .leading, spacing: 0) {
                overview(snapshot)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                if scheme == .dark { Divider() }
                list(snapshot).card()
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
                    label("CPU").help("Share of all cores in use since the last refresh (every 3 s; 5 s while the ports are shown)")
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

    // MARK: Processes and ports

    /// The processes or the ports, under a bar with the choice between them and their search and buttons.
    private func list(_ snapshot: MonitorSnapshot) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("Show", selection: $model.shown) {
                    Text("Processes").tag(MonitorModel.Shown.processes)
                    Text("Ports").tag(MonitorModel.Shown.ports)
                }
                .pickerStyle(.segmented)
                .primaryTint(Color(nsColor: .systemTeal))
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("monitor.view")
                .help("Show the processes, or the ports the server listens on (read only while they are shown)")
                if model.shown == .processes { processBar(snapshot) } else { portBar(snapshot.ports) }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .bar))
            Divider()
            if model.shown == .processes { processes(snapshot) } else { ports(snapshot.ports) }
        }
    }

    @ViewBuilder
    private func processBar(_ snapshot: MonitorSnapshot) -> some View {
        let rows = model.rows
        let chosen = rows.filter { model.selection.contains($0.id) }
        Text(rows.count == snapshot.processes.count ? "\(rows.count)" : "\(rows.count) of \(snapshot.processes.count)")
            .font(.caption).foregroundColor(.secondary)
        Spacer()
        TextField("Search name, user, command or PID", text: $model.search)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("monitor.search")
            .frame(maxWidth: 240)
            .help("Show only processes matching this")
        Button("Kill") { kill(chosen.map { ($0.pid, $0.name) }, false) }.disabled(chosen.isEmpty)
            .help(chosen.isEmpty ? "Select processes first" : "Ask the selected processes to quit (SIGTERM); asks first")
        Button("Force Kill") { kill(chosen.map { ($0.pid, $0.name) }, true) }.disabled(chosen.isEmpty)
            .help(chosen.isEmpty ? "Select processes first" : "Stop the selected processes at once (SIGKILL); asks first")
    }

    private func processes(_ snapshot: MonitorSnapshot) -> some View {
        let rows = model.rows
        return Group {
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
                .accessibilityIdentifier("monitor.processes")
                .contextMenu(forSelectionType: MonitorProcess.ID.self) { ids in
                    let picked = rows.filter { ids.contains($0.id) }.map { ($0.pid, $0.name) }
                    Button("Kill") { kill(picked, false) }.help("Ask the selected processes to quit (SIGTERM); asks first")
                    Button("Force Kill") { kill(picked, true) }.help("Stop the selected processes at once (SIGKILL); asks first")
                }
            }
        }
    }

    @ViewBuilder
    private func portBar(_ ports: MonitorPorts?) -> some View {
        let all = ports?.listening.count ?? 0, rows = model.portRows.count
        let port = model.selectedPort
        let why = port == nil ? "Select a port first" : port?.pids.isEmpty == true ? MonitorText.unseen(ports) : nil
        Text(ports == nil ? "" : (rows == all ? "\(all)" : "\(rows) of \(all)") + (model.paused ? " · paused" : ""))
            .font(.caption).foregroundColor(.secondary)
        Spacer()
        TextField("Search port, process or address", text: $model.portSearch)
            .textFieldStyle(.roundedBorder)
            .accessibilityIdentifier("monitor.portSearch")
            .frame(maxWidth: 220)
            .help("Show only the ports, and the connections, matching this")
        Button { model.refresh(ports: true) } label: { Image(systemName: "arrow.clockwise") }
            .accessibilityIdentifier("monitor.refresh")
            .accessibilityLabel("Refresh")
            .help("Read the ports again now")
        Toggle(isOn: $model.paused) { Image(systemName: model.paused ? "play.fill" : "pause.fill") }
            .toggleStyle(.button)
            .accessibilityIdentifier("monitor.pause")
            .accessibilityLabel("Pause")
            .help(model.paused ? "Read the ports every 5 s again" : "Stop reading the ports every 5 s, to look at them as they are")
        Button("Show Process") { show(port) }.disabled(why != nil)
            .help(why ?? "Show the process that has this port in the list of processes")
        Button("Kill") { kill(targets(of: port), false) }.disabled(why != nil)
            .help(why ?? "Ask the process that has this port to quit (SIGTERM); asks first")
        Button("Force Kill") { kill(targets(of: port), true) }.disabled(why != nil)
            .help(why ?? "Stop the process that has this port at once (SIGKILL); asks first")
    }

    @ViewBuilder
    private func ports(_ ports: MonitorPorts?) -> some View {
        if let ports {
            // Side by side: the tab is wide and not tall.
            HSplitView {
                listening(ports).frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
                connections(ports).frame(minWidth: 240, idealWidth: 320, maxWidth: 480, maxHeight: .infinity)
            }
        } else {
            VStack(spacing: 10) {
                if model.failure == nil { ProgressView().controlSize(.small) }
                Text(model.failure ?? "Reading the ports…").foregroundColor(.secondary).multilineTextAlignment(.center)
            }
            .padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// What the server listens on, a row a port, and why some processes aren't known.
    private func listening(_ ports: MonitorPorts) -> some View {
        let rows = model.portRows
        return VStack(spacing: 0) {
            if rows.isEmpty {
                Text(ports.note ?? (ports.listening.isEmpty ? "Nothing listens on TCP or UDP."
                                    : "No port matches “\(model.portSearch)”."))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(rows, selection: $model.portSelection, sortOrder: $model.portSortOrder) {
                    TableColumn("Protocol", value: \.protocolName) { Text($0.protocolName) }
                        .width(min: 50, ideal: 60)
                    TableColumn("Address", value: \.address) { port in
                        Text(port.address).lineLimit(1).truncationMode(.middle)
                            .help(port.address + " — " + MonitorText.reach(port.address))
                    }
                    .width(min: 70, ideal: 110)
                    TableColumn("Port", value: \.port) { Text(String($0.port)).monospacedDigit() }
                        .width(min: 40, ideal: 56)
                    TableColumn("PID", value: \.pidOrder) { port in
                        Text(port.pids.isEmpty ? "—" : port.pids.map(String.init).joined(separator: ", "))
                            .monospacedDigit().lineLimit(1)
                            .help(port.pids.isEmpty ? MonitorText.unseen(ports) : "The processes that have this port open")
                    }
                    .width(min: 44, ideal: 70)
                    TableColumn("Process", value: \.process) { port in
                        Text(port.process.isEmpty ? "—" : port.process).lineLimit(1)
                            .help(port.command.isEmpty ? MonitorText.unseen(ports) : port.command)
                    }
                    .width(min: 60, ideal: 130)
                    TableColumn("User", value: \.user) { Text($0.user).lineLimit(1) }
                        .width(min: 44, ideal: 70)
                    TableColumn("Connections", value: \.connectionOrder) { port in
                        Text(port.connections.map(String.init) ?? "—").monospacedDigit()
                            .help(port.isTCP ? "Open connections to this port" : "UDP keeps no connections")
                    }
                    .width(min: 60, ideal: 80)
                }
                .washed()
                .accessibilityIdentifier("monitor.ports")
                .contextMenu(forSelectionType: MonitorPort.ID.self) { ids in
                    if let port = rows.first(where: { ids.contains($0.id) }) {
                        let why = port.pids.isEmpty ? MonitorText.unseen(ports) : nil
                        Button("Show Process") { show(port) }.disabled(why != nil)
                            .help(why ?? "Show the process that has this port in the list of processes")
                        Button("Kill") { kill(targets(of: port), false) }.disabled(why != nil)
                            .help(why ?? "Ask the process that has this port to quit (SIGTERM); asks first")
                        Button("Force Kill") { kill(targets(of: port), true) }.disabled(why != nil)
                            .help(why ?? "Stop the process that has this port at once (SIGKILL); asks first")
                        Divider()
                        Button("Copy Address") { MonitorText.copy(MonitorText.endpoint(port.address, port.port)) }
                            .help("Copy \(MonitorText.endpoint(port.address, port.port))")
                    }
                }
            }
            if ports.othersHidden {
                Divider()
                Text(MonitorText.othersHidden)
                    .font(.caption).foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12).padding(.vertical, 4)
            }
        }
    }

    /// Who is connected to the port picked: how many from each address, and each connection.
    private func connections(_ ports: MonitorPorts) -> some View {
        let port = model.selectedPort
        let read = port != nil && ports.connectionsOf == port?.id
        let all = read ? ports.connections : []
        let shown = MonitorText.filter(all, to: port, model.portSearch).sorted(using: connectionSort)
        let message: String? = port == nil ? "Select a port to see who is connected to it."
            : port?.isTCP == false ? "UDP keeps no connections: each message comes on its own."
            : !read ? nil
            : all.isEmpty ? "Nobody is connected to port \(port?.port ?? 0) now."
            : shown.isEmpty ? "No connection matches “\(model.portSearch)”." : nil
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(port.map { "Connections to port " + String($0.port) } ?? "Connections").font(.subheadline.weight(.semibold))
                if let port, read, !all.isEmpty {
                    let summary = MonitorText.from(shown)
                    Text(MonitorText.count(shown: shown.count, read: all.count, total: port.connections ?? all.count)
                         + (summary.isEmpty ? "" : " · " + summary))
                        .font(.caption).foregroundColor(.secondary).lineLimit(1)
                        .help(MonitorText.from(shown, most: 20, separator: "\n"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color(nsColor: .bar))
            Divider()
            if let message {
                Text(message).foregroundColor(.secondary).multilineTextAlignment(.center).padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !read {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Reading who is connected…").foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(shown, selection: $connectionSelection, sortOrder: $connectionSort) {
                    TableColumn("Remote address", value: \.address) { connection in
                        Text(connection.address).lineLimit(1).truncationMode(.middle).help(connection.address)
                    }
                        .width(min: 90, ideal: 220)
                    TableColumn("Remote port", value: \.port) { Text(String($0.port)).monospacedDigit() }
                        .width(min: 60, ideal: 90)
                    TableColumn("State", value: \.state) { connection in
                        Text(connection.state).help(MonitorText.explain(connection.state))
                    }
                    .width(min: 70, ideal: 120)
                }
                .washed()
                .accessibilityIdentifier("monitor.connections")
                .contextMenu(forSelectionType: MonitorConnection.ID.self) { ids in
                    if let connection = shown.first(where: { ids.contains($0.id) }) {
                        Button("Copy Address") { MonitorText.copy(connection.address) }.help("Copy \(connection.address)")
                    }
                }
            }
        }
    }

    /// The Processes list with the port's process picked: only it is listed (its PID searched for).
    private func show(_ port: MonitorPort?) {
        guard let pid = port?.pids.first else { return }
        model.search = String(pid)
        model.selection = [pid]
        model.shown = .processes
    }

    /// The processes that have `port` open, named as ps lists them.
    private func targets(of port: MonitorPort?) -> [(pid: Int, name: String)] {
        guard let port else { return [] }
        return port.pids.map { pid in
            (pid, model.snapshot?.processes.first { $0.pid == pid }?.name ?? (port.process.isEmpty ? "PID \(pid)" : port.process))
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

/// The ports table's columns and sort keys (a process this account can't see, and UDP's connections, go last).
extension MonitorPort {
    var protocolName: String { isTCP ? "TCP" : "UDP" }
    var pidOrder: Int { pids.first ?? .max }
    var connectionOrder: Int { connections ?? -1 }
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

    /// The ports numbered `search`, or whose address, process, command or user contains it (any case); `keeping` (the
    /// port picked) stays, so that its connections can be searched.
    static func filter(_ ports: [MonitorPort], _ search: String, keeping: MonitorPort.ID? = nil) -> [MonitorPort] {
        let term = search.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return ports }
        return ports.filter { $0.id == keeping || matches($0, term) }
    }

    private static func matches(_ port: MonitorPort, _ term: String) -> Bool {
        String(port.port) == term || [endpoint(port.address, port.port), port.process, port.command, port.user].contains {
            $0.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    /// The connections from an address or port, or in a state, matching `search`; all of them when `port`, the one they
    /// are to, matches it (search for a port: who is connected to it).
    static func filter(_ connections: [MonitorConnection], to port: MonitorPort?, _ search: String) -> [MonitorConnection] {
        let term = search.trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty, !(port.map { matches($0, term) } ?? false) else { return connections }
        return connections.filter { connection in
            String(connection.port) == term
                || [connection.address, connection.state].contains { $0.range(of: term, options: .caseInsensitive) != nil }
        }
    }

    /// "203.0.113.5:443", "[2001:db8::1]:443".
    static func endpoint(_ address: String, _ port: Int) -> String {
        (address.contains(":") ? "[\(address)]" : address) + ":\(port)"
    }

    /// Who can reach a listening address.
    static func reach(_ address: String) -> String {
        if address == "0.0.0.0" { return "Every IPv4 address of the server: open to the network" }
        if address == "::" { return "Every address of the server (IPv6, and IPv4 unless the program chose not): open to the network" }
        if address.hasPrefix("127.") || address == "::1" { return "Only the server itself (loopback): not open to the network" }
        return "Only this address of the server"
    }

    static let othersHidden = "Some ports belong to other users' processes, which this account can't see: connect as root to see them."

    /// Why a port's process isn't known.
    static func unseen(_ ports: MonitorPorts?) -> String {
        ports?.othersHidden == true ? "Another user's process, which this account can't see (connect as root to see it)"
            : "No process on this server has it open (the system's own, or another container's)"
    }

    /// "15", "3 of 15", "the first 2,000 of 12,345" (only so many are read).
    static func count(shown: Int, read: Int, total: Int) -> String {
        let all = total > read ? "the first \(read.formatted()) of \(total.formatted())" : read.formatted()
        return shown == read ? all : "\(shown.formatted()) of \(all)"
    }

    /// How many of the connections come from each address, the most first.
    static func addresses(_ connections: [MonitorConnection]) -> [(address: String, count: Int)] {
        var counts: [String: Int] = [:]
        for connection in connections { counts[connection.address, default: 0] += 1 }
        return counts.map { (address: $0.key, count: $0.value) }.sorted { (a: (address: String, count: Int), b: (address: String, count: Int)) in
            a.count == b.count ? a.address < b.address : a.count > b.count
        }
    }

    /// "12 from 10.0.0.5, 3 from 10.0.0.7 and 4 more addresses": the addresses with the most connections first.
    static func from(_ connections: [MonitorConnection], most: Int = 2, separator: String = ", ") -> String {
        let ranked = addresses(connections)
        let named = ranked.prefix(most).map { "\($0.count) from \($0.address)" }
        let rest = ranked.count - named.count
        guard rest > 0 else { return named.joined(separator: separator) }
        return named.joined(separator: separator) + (separator == ", " ? " and " : separator)
            + "\(rest) more address\(rest == 1 ? "" : "es")"
    }

    /// What a TCP state means.
    static func explain(_ state: String) -> String {
        ["Established": "Open: data goes both ways",
         "SYN sent": "Opening: this server asked to connect",
         "SYN received": "Opening: the other side asked to connect, and waits for this server's answer",
         "FIN wait 1": "Closing: this server closed its end",
         "FIN wait 2": "Closing: this server closed its end and waits for the other side to close",
         "Close wait": "The other side closed; the program on this server hasn't closed its end yet",
         "Last ACK": "Closing: both ends closed, and the last acknowledgement is under way",
         "Closing": "Closing: both ends closed at the same time"][state] ?? "TCP state \(state)"
    }

    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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
