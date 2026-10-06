import AirSCPCore
import AppKit
import SwiftUI

/// One saved host in the main window: a banner while it isn't connected, the Files, Monitor and Tunnels tabs, and the
/// command log. Its ssh prompts and errors are sheets on the main window, also while another host is shown. The main
/// window makes it when the host is selected or connected and keeps it while it is connected or lists transfers.
/// BrowserContentController, MonitorController and RDPWorkspaceController use it.
@MainActor
final class HostWorkspace: NSViewController {
    let connection: HostConnection
    let model: AppModel
    weak var main: MainWindowController?
    /// The workspace's Session (replaced, with new Files and Monitor tabs, when Connect finds the host's settings edited).
    var session: Session { connection.session }
    /// The saved host as it is now (its Session keeps the settings it was made with).
    var host: SSHHost { model.host(connection.hostID) ?? session.host }
    /// The main window: this host's sheets and alerts go there.
    var window: NSWindow? { main?.window }
    private(set) var browser: BrowserContentController!
    private(set) var monitor: MonitorController!
    let tabs = NSTabViewController()
    private var tunnels: NSViewController!
    /// The host's name, state, address and route, and the server's pulse, above the tabs.
    private var header: NSHostingView<WorkspaceHeader>?
    private let split = NSSplitView()
    private var logPane: NSView?
    /// The open prompts and the window each is a sheet on.
    private var prompts: [(alert: NSAlert, on: NSWindow)] = []
    private var whenConnected: [() -> Void] = []
    /// Connects and takeovers under way, whose state change may not have arrived yet: the workspace must stay. When the
    /// last one ends, the main window may let it go (a failed connect of a host that isn't shown).
    private var starting = 0 {
        didSet { if starting == 0 { main?.workspaceChanged(self) } }
    }

    init(connection: HostConnection, model: AppModel, main: MainWindowController?) {
        self.connection = connection
        self.model = model
        self.main = main
        super.init(nibName: nil, bundle: nil)
        tabs.tabStyle = .segmentedControlOnTop
        tabs.canPropagateSelectedChildViewControllerTitle = false
        tunnels = NSHostingController(rootView: TunnelsView(tunnels: TunnelsModel(connection: connection, model: model),
                                                            connection: connection, app: model))
        makeTabs(for: connection.session)
        connection.ask = { [weak self] prompt, reply in
            guard let self else { return reply(nil) }
            self.ask(prompt, reply)
        }
        connection.onStateChange = { [weak self] state in self?.stateChanged(state) }
        connection.onNewSession = { [weak self] session in self?.makeTabs(for: session) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let header = NSHostingView(rootView: WorkspaceHeader(connection: connection, model: model, monitor: monitor.model))
        header.setContentHuggingPriority(.required, for: .vertical)
        header.sizingOptions = [.minSize, .intrinsicContentSize]
        self.header = header
        // The banner has no height while the host is connected.
        let banner = NSHostingView(rootView: ConnectionBanner(
            connection: connection, model: model,
            connect: { [weak self] in self?.connect() },
            cancel: { [weak self] in self?.disconnect() },
            details: { [weak self] error in showError(error, title: "Disconnected", on: self?.window) }))
        banner.setContentHuggingPriority(.required, for: .vertical)
        // No maximum size: while connected the banner is empty, and a maximum width of 0 would shrink the window.
        banner.sizingOptions = [.minSize, .intrinsicContentSize]
        addChild(tabs)
        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(tabs.view)  // the command log goes below, once shown
        let view = NSView()
        for part in [header, banner, split] as [NSView] {
            part.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(part)
        }
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            banner.topAnchor.constraint(equalTo: header.bottomAnchor),
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.topAnchor.constraint(equalTo: banner.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        self.view = view
    }

    // The header's pulse strip samples the server while the workspace is on screen.
    override func viewDidAppear() {
        super.viewDidAppear()
        monitor.showsPulse = true
        // The tabs' segmented control (the tab view controller adds it as the view first appears): the accent in Night
        // Harbor, Paper's black pill.
        tabs.view.subviews.lazy.compactMap { $0 as? NSSegmentedControl }.first?.selectedSegmentBezelColor = .pill
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        monitor.showsPulse = false
    }

    // MARK: For the browser, monitor and RDP code, and the main window

    /// Connects unless connecting or connected; failures are shown (not cancels). `work` runs once connected
    /// (dropped if connecting fails).
    func connect(then work: (() -> Void)? = nil) {
        if let work {
            if connection.state == .connected { return work() }
            whenConnected.append(work)
        }
        switch connection.state {
        case .connecting, .connected: return
        case .idle, .disconnected, .reconnecting: break
        }
        starting += 1
        Task {
            defer { starting -= 1 }
            do {
                try await connection.connect()
            } catch {
                connectFailed(error)
            }
        }
    }

    /// Shows an error from an operation on this host. Cancels aren't shown, nor is a lost connection: the banner
    /// says so (no stack of alerts when the network drops).
    func show(_ error: Error, title: String? = nil) {
        let kind = (error as? AirSCPError)?.kind
        guard kind != .cancelled, kind != .disconnected else { return }
        showError(error, title: title, on: window)
    }

    /// Opens Terminal (or iTerm) with ssh riding this host's connection; `directory`: "Open Terminal Here".
    func openTerminal(in directory: String? = nil) {
        openTerminal(command: directory.map(OpenSSH.shellIn))
    }

    /// Opens Terminal running `command` with a tty (Run in Terminal), or a login shell when nil.
    func openTerminal(command: String?) {
        let host = self.host
        Task {
            do {
                try await TerminalLauncher.open(host, jump: model.jump(for: host), command: command,
                                                app: model.data.settings.terminalApp,
                                                environment: connection.askpass.terminalEnvironment,
                                                log: { [weak self] in self?.connection.log.append($0) })
            } catch {
                show(error)
            }
        }
    }

    /// The Run Command sheet, with `command` filled in (and run at once when `run`); `sh`: AirSCP's own command, run
    /// by sh (`RunCommandModel.sh`).
    func showRunCommand(_ command: String = "", run: Bool = false, sh: Bool = false) {
        guard let window else { return }
        let runner = RunCommandModel(connection: connection, command: command, sh: sh)
        presentSheet(on: window) { close in
            RunCommandView(model: runner, app: model, runInTerminal: { [weak self] in self?.openTerminal(command: $0) },
                           close: close)
        }
        if run { runner.run() }
    }

    /// Every connected host's Session (this one's too), in sidebar order: the left pane's source selector for copies
    /// between servers.
    var connectedSessions: [Session] {
        main?.connectedSessions ?? (connection.state == .connected ? [session] : [])
    }

    /// The Session once connected, connecting first if needed (prompts appear as for any connect); throws why it
    /// couldn't. For an RDP entry that goes through this host.
    func connectedSession() async throws -> Session {
        starting += 1
        defer { starting -= 1 }
        try await connection.connect()
        // The state arrives on the main queue; another Connect may still be under way.
        while session.state == .connecting { try await Task.sleep(nanoseconds: 100_000_000) }
        guard session.state == .connected else {
            throw AirSCPError(.disconnected, "AirSCP couldn't connect to “\(host.displayName)”, which this desktop goes "
                + "through. Select it in the sidebar, connect it, then try the desktop again.")
        }
        return session
    }

    /// Takes over a live master left by an earlier AirSCP (launch after a crash).
    func adopt() async -> Bool {
        starting += 1
        defer { starting -= 1 }
        return await connection.adopt()
    }

    /// Disconnects (or stops connecting or reconnecting), asking first when transfers are running: they are cancelled
    /// and their partial files removed.
    func disconnect() {
        let running = runningTransferCount
        let connection = self.connection
        guard running > 0 else {
            Task { await connection.disconnect() }
            return
        }
        confirm("Disconnect “\(host.displayName)” and cancel \(transfers(running))?", info: "Partly copied files are removed.",
                button: "Disconnect", destructive: true, on: window) {
            Task { await connection.disconnect() }
        }
    }

    /// Installs a public key for this host's account (Keys window), then says how it went.
    func installKey(_ publicKey: String) {
        let name = host.displayName
        Task {
            do {
                try await connection.installKey(publicKey)
                let alert = NSAlert()
                alert.messageText = "The key was installed on “\(name)”"
                alert.informativeText = "To log in with it, edit the host and choose it under “Log in with”: "
                    + String(publicKey.dropLast(publicKey.hasSuffix(".pub") ? 4 : 0))
                alert.addOK()
                if let window { alert.beginSheetModal(for: window) { _ in } }
            } catch {
                if !connection.cancelledByUser { show(error, title: "Can't install the key on “\(name)”") }
            }
        }
    }

    /// Transfers queued, running or paused (the browser's count): Disconnect, Delete and Quit ask before cancelling them.
    var runningTransferCount: Int { browser.runningTransferCount }

    /// Idle, not starting to connect, no transfers listed, and no editor or file open in another app (they save or
    /// upload through it after a reconnect): the main window lets it go when it isn't shown.
    var isUnused: Bool {
        connection.state == .idle && starting == 0 && session.transfers.jobs.isEmpty && !browser.hasOpenFiles
    }

    func showTunnels() {
        tabs.selectedTabViewItemIndex = 2
    }

    var showsCommandLog: Bool { logPane != nil }

    /// Shows or hides the command log below the tabs. Hidden, it is taken away altogether: a SwiftUI list kept off
    /// screen would still be worked on for every command (many per second during a transfer of many files).
    func toggleCommandLog() {
        _ = view
        if let logPane {
            logPane.removeFromSuperview()
            self.logPane = nil
            return
        }
        let log = NSHostingView(rootView: CommandLogView(log: connection.log))
        log.sizingOptions = .minSize  // the split view sets its height
        split.addArrangedSubview(log)
        // A bigger window grows the tabs, not the log.
        split.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 0)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 1)
        logPane = log
        split.layoutSubtreeIfNeeded()
        split.setPosition(max(split.bounds.height - 180, 120), ofDividerAt: 0)
    }

    // MARK: Connection

    /// The Files and Monitor tabs for `session` (at first, and again when Connect made a new Session).
    private func makeTabs(for session: Session) {
        let old = browser
        browser = BrowserContentController(workspace: self, session: session)
        if let old { browser.takeOpenFiles(from: old) }
        let pulse = monitor?.showsPulse ?? false
        monitor?.showsPulse = false
        monitor = MonitorController(workspace: self, session: session)
        header?.rootView = WorkspaceHeader(connection: connection, model: model, monitor: monitor.model)
        _ = browser.view  // their stateChanged may use their views
        _ = monitor.view
        func item(_ controller: NSViewController, _ label: String) -> NSTabViewItem {
            let item = NSTabViewItem(viewController: controller)
            item.label = label
            item.toolTip = ["Files": "Browse and copy files between this Mac and the host",
                            "Monitor": "CPU, memory, disks and processes of the host (Linux)",
                            "Tunnels": "Port forwards through this connection"][label]
            return item
        }
        if tabs.tabViewItems.isEmpty {
            tabs.tabViewItems = [item(browser, "Files"), item(monitor, "Monitor"), item(tunnels, "Tunnels")]
        } else {
            // A new Session: only the Files and Monitor tabs are replaced. The Tunnels tab keeps its item (a second item
            // for the same controller makes NSTabViewController throw when that tab is the selected one).
            let selected = max(tabs.selectedTabViewItemIndex, 0)
            tabs.selectedTabViewItemIndex = 2
            for (index, new) in [item(browser, "Files"), item(monitor, "Monitor")].enumerated() {
                tabs.removeTabViewItem(tabs.tabViewItems[index])
                tabs.insertTabViewItem(new, at: index)
            }
            tabs.selectedTabViewItemIndex = selected
        }
        browser.stateChanged(session.state)
        monitor.stateChanged(session.state)
        monitor.showsPulse = pulse
    }

    private func stateChanged(_ state: Session.State) {
        browser.stateChanged(state)
        monitor.stateChanged(state)
        switch state {
        case .connected:
            let work = whenConnected
            whenConnected = []
            work.forEach { $0() }
        case .connecting:
            break
        case .idle, .disconnected, .reconnecting:
            whenConnected = []
            closePrompts()
        }
        main?.workspaceChanged(self)
    }

    private func connectFailed(_ error: Error) {
        var error = Session.namingTheHop(error as? AirSCPError ?? AirSCPError(.other, error.localizedDescription),
                                         host: host, jump: model.jump(for: host))
        if model.forgetRejectedProxyPassword(for: host, after: error) {
            error.message += " AirSCP forgot the saved proxy password: Connect asks for it again."
        }
        guard error.kind != .cancelled, !connection.cancelledByUser, let window else { return }
        let name = host.displayName
        guard error.kind == .hostKeyChanged else {
            // With the way to the debug log (PLAN.md AE), as the Disconnected banner has.
            let alert = errorAlert(error, title: "Can't connect to “\(name)”")
            alert.addOK()
            let logging = model.debugLoggingOn
            let button = alert.addButton(withTitle: logging ? DebugLogButton.showTitle : DebugLogButton.retryTitle)
            button.toolTip = logging ? DebugLogButton.showTip : DebugLogButton.retryTip
            log.error("\(alert.messageText, privacy: .public) \(alert.informativeText, privacy: .public)")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard response == .alertSecondButtonReturn, let self else { return }
                if logging { return revealDebugLog() }
                self.model.data.settings.debugLogging = true
                self.connect()
            }
            return
        }
        // ssh names the server whose key changed: through a jump host, that may be the jump host.
        var changed = name
        if let jump = model.jump(for: host), let reported = ErrorMapping.changedHostKey(in: error.details)?.name,
           reported == (jump.port.map { $0 == 22 ? jump.hostname : "[\(jump.hostname)]:\($0)" } ?? jump.hostname) {
            changed = jump.displayName
        }
        let alert = errorAlert(error, title: "The identity of “\(changed)” has changed")
        alert.addButton(withTitle: "Cancel").toolTip = "Don't connect: ask the server's administrator first"
        let remove = alert.addButton(withTitle: "Remove Old Key and Reconnect")
        remove.hasDestructiveAction = true
        remove.toolTip = host.hostKeyCheck == .acceptNew
            ? "Forget the old key and connect: this host trusts new servers automatically, so the new key is trusted "
                + "without a question"
            : "Forget the old key and connect; you'll be asked to trust the new one"
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self else { return }
            Task {
                do {
                    try await self.connection.removeOldHostKeyAndReconnect()
                } catch {
                    self.connectFailed(error)
                }
            }
        }
    }

    /// "Remember in Keychain" as the last answer had it: a question asked again (the answer was wrong) keeps it.
    private var rememberTicked = false

    /// A prompt from ssh as a sheet on the main window, or on the sheet the window shows when that is an editor (the
    /// Remote Desktop editor testing a connection through this host), where it is seen: behind it, it would wait until
    /// that sheet closes. Behind another question (an alert), it queues on the window. Cancel stops connecting; prompts
    /// ssh no longer waits for are closed when the connection attempt ends.
    private func ask(_ prompt: Prompt, _ reply: @escaping (PromptAnswer?) -> Void) {
        guard let window else { return reply(nil) }
        main?.showWindow(nil)
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        var host: SSHHost? = self.host
        if case .password = prompt.kind { host = prompt.host }  // the jump host's, or nil when it names neither
        let on = window.attachedSheet.flatMap { $0 is NSPanel ? nil : $0 } ?? window
        var shown: NSAlert?
        shown = showPrompt(prompt.kind, text: prompt.text, host: host, canRemember: prompt.canRemember, on: on,
                           retry: prompt.retry, remember: prompt.retry && rememberTicked) {
            [weak self] answer, byUser in
            self?.rememberTicked = answer?.remember ?? false
            self?.prompts.removeAll { $0.alert === shown }
            reply(answer)
            if answer == nil && byUser { self?.connection.promptCancelled() }
        }
        if let shown { prompts.append((shown, on)) }
    }

    /// Ends this host's prompt sheets, also those still queued behind another sheet.
    private func closePrompts() {
        let open = prompts
        prompts = []
        open.forEach { $0.on.endSheet($0.alert.window, returnCode: .cancel) }
    }
}

/// "1 transfer", "3 transfers".
func transfers(_ count: Int) -> String {
    count == 1 ? "1 transfer" : "\(count) transfers"
}

/// Copies the ssh command line for the host (a fresh connection, not riding AirSCP's).
func copyCommand(_ host: SSHHost, jump: SSHHost?) {
    guard copyCommandProblem(host, jump: jump) == nil else { return }
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(Runner.shellLine(OpenSSH.interactive(host, jump: jump)), forType: .string)
}

/// Why Copy ssh Command can't give a command that works in another terminal (its tooltip while it is off), else nil:
/// an HTTP proxy is reached through AirSCP's own helper, and without its jump host the command would go direct.
func copyCommandProblem(_ host: SSHHost, jump: SSHHost?) -> String? {
    if OpenSSH.missingJump(host, jump: jump) != nil { return "Its jump host no longer exists: edit the host to choose another" }
    if (jump ?? host).proxyID != nil { return "Its HTTP proxy is reached through AirSCP only: use Open Terminal (⌘T) instead" }
    return nil
}

/// The strip above a host's tabs while it isn't connected (nothing while it is): Connecting… (Cancel), Not connected
/// (Connect), Disconnected with the reason (Details, Reconnect), or Reconnecting with the time of the next try (Cancel,
/// Reconnect Now).
struct ConnectionBanner: View {
    @ObservedObject var connection: HostConnection
    /// The saved host (its name, a missing key file) may change.
    @ObservedObject var model: AppModel
    let connect: () -> Void
    let cancel: () -> Void
    let details: (AirSCPError) -> Void

    var body: some View {
        if connection.state != .connected || checksOff {
            strip
        }
    }

    /// The host's server key checks are off: the strip shows it in every state (PLAN.md U.4).
    private var checksOff: Bool { model.host(connection.hostID)?.hostKeyCheck == .off }

    /// The strip's text while connected to a host whose server key isn't checked (agents read it too).
    static let checksOffText = "Connected. Server key checks are off for this host: Host ▸ Edit…, Advanced turns them on."

    private var strip: some View {
        HStack(spacing: 10) {
            if checksOff { ChecksOffShield(ssh: true) }
            switch connection.state {
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting to \(name)…")
                Spacer()
                Button("Cancel", action: cancel).help("Stop connecting")
            case .disconnected(let error):
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).accessibilityHidden(true)
                Text("Disconnected: \(error.message)").lineLimit(2)
                Spacer()
                if !error.details.isEmpty { Button("Details…") { details(error) }.help("Show ssh's own output for this failure") }
                DebugLogButton(model: model, retry: connect)
                Button("Reconnect", action: connect).help("Try to connect again (⌘K)")
            case .reconnecting(let nextTry):
                ProgressView().controlSize(.small)
                TimelineView(.periodic(from: Date(), by: 1)) { context in
                    let seconds = max(0, Int(nextTry.timeIntervalSince(context.date).rounded(.up)))
                    Text("The connection was lost. Reconnecting… next try in \(seconds) s").lineLimit(2)
                }
                Spacer()
                Button("Cancel") { connection.session.cancelReconnect() }
                    .help("Stop reconnecting")
                Button("Reconnect Now", action: connect).help("Don't wait for the next try: connect now")
            case .connected:
                Text(Self.checksOffText).lineLimit(2)
                Spacer()
            case .idle:
                if model.host(connection.hostID).flatMap(missingKeyFile) != nil {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).accessibilityHidden(true)
                } else {
                    Image(systemName: "bolt.horizontal.circle").foregroundColor(.secondary).accessibilityHidden(true)
                }
                Text(Self.idleText(model.host(connection.hostID))).lineLimit(2)
                Spacer()
                Button("Connect", action: connect).buttonStyle(.borderedProminent).tint(Color(nsColor: .pill))
                    .help("Log in to this host; ssh may ask a question first (⌘K)")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .bar))
        .overlay(Divider(), alignment: .bottom)
    }

    private var name: String {
        model.host(connection.hostID)?.displayName ?? connection.session.host.displayName
    }

    /// The strip's text while not connected (agents read it too).
    static func idleText(_ host: SSHHost?) -> String {
        guard let key = host.flatMap(missingKeyFile) else { return "Not connected. Connect to browse this host's files." }
        return "Not connected. The key file \(key) no longer exists: edit the host to choose another."
    }
}

/// The top of a host's workspace (PLAN.md O.1): its name and state, its address, the route to it and its keep-alive,
/// and the server's pulse (CPU, memory, disk) while it is connected.
struct WorkspaceHeader: View {
    @ObservedObject var connection: HostConnection
    @ObservedObject var model: AppModel
    @ObservedObject var monitor: MonitorModel

    var body: some View {
        let host = model.host(connection.hostID) ?? connection.session.host
        let route = model.data.route(for: host)
        HStack(alignment: .center, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(host.displayName).font(.system(size: 17, weight: .bold)).lineLimit(1)
                    StatusPill(text: MainWindowController.describe(connection.state), style: state)
                }
                (Text(host.address).fontWeight(.medium).foregroundColor(.primary)
                    + Text(([route.map { "This Mac → " + $0.short.dropFirst("via ".count) + " → " + host.displayName }]
                            + [host.serverAliveInterval > 0 ? "keep-alive \(host.serverAliveInterval) s" : nil])
                        .compactMap { $0 }.map { " · " + $0 }.joined()).foregroundColor(.secondary))
                    .font(.system(size: 11.5)).monospacedDigit().lineLimit(1).truncationMode(.middle)
            }
            .frame(minWidth: 240, alignment: .leading)
            .help(route?.full ?? "Connects to \(host.address) directly")
            Spacer(minLength: 0)
            // Offered the room first: it shows as many figures as fit beside the name's 240 points.
            if connection.state == .connected { PulseStrip(monitor: monitor).layoutPriority(1) }
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var state: StatusPill.Style {
        switch connection.state {
        case .connected: return .tinted(.systemGreen)
        case .connecting, .reconnecting: return .tinted(.systemOrange)
        case .disconnected: return .tinted(.systemRed)
        case .idle: return .neutral
        }
    }
}
