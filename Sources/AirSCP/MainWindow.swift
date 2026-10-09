import AirSCPCore
import AppKit
import Combine
import SwiftUI

/// A row of the sidebar: a host or RDP entry in the Connected section, or in its own section.
enum SidebarItem: Hashable {
    case connected(UUID)
    case host(UUID)
    case rdp(UUID)

    var id: UUID {
        switch self {
        case .connected(let id), .host(let id), .rdp(let id): return id
        }
    }
}

/// The sidebar's selection and search, shared by the window's toolbar and the sidebar list.
@MainActor
final class SidebarState: ObservableObject {
    @Published var selection: SidebarItem? {
        didSet { if selection != oldValue { onSelect?() } }
    }
    @Published var search = ""
    var onSelect: (() -> Void)?
}

/// AirSCP's window. The sidebar lists what is connected (⌘1…⌘9), the saved hosts in groups, the RDP entries and the
/// Proxies button; the right side shows the selected host's workspace or RDP entry's desktop above the Transfers queue
/// of all hosts. A connected host's workspace stays alive while another one is shown; one that is idle goes when it
/// isn't shown and lists no transfers. The toolbar and the Host menu act on the selected host. All prompts and sheets
/// appear on this window.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation,
    NSMenuItemValidation {

    let model: AppModel
    let askpass: AskpassServer
    let sidebar = SidebarState()
    /// By host id.
    private(set) var workspaces: [UUID: HostWorkspace] = [:]
    /// By RDP entry id.
    private(set) var desktops: [UUID: RDPWorkspaceController] = [:]
    private let detail: DetailController
    private var searchItem: NSSearchToolbarItem?
    private var titles: AnyCancellable?

    init(model: AppModel, askpass: AskpassServer) {
        self.model = model
        self.askpass = askpass
        detail = DetailController(model: model)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 760, height: 460)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.isExcludedFromWindowsMenu = true  // Window ▸ AirSCP (⌘0) and the connected hosts (⌘1…⌘9) stand for it
        window.toolbarStyle = .unified
        super.init(window: window)
        let split = NSSplitViewController()
        let sidebarView = NSHostingController(rootView: Sidebar(model: model, state: sidebar, controller: self))
        // The split view and the window set its size: with no hosts, its empty state would grow the window past the
        // screen's height.
        sidebarView.sizingOptions = []
        let list = NSSplitViewItem(sidebarWithViewController: sidebarView)
        list.minimumThickness = 210
        list.maximumThickness = 400
        split.splitViewItems = [list, NSSplitViewItem(viewController: detail)]
        split.splitView.autosaveName = layoutName("Sidebar")
        window.contentViewController = split
        window.delegate = self
        let toolbar = NSToolbar(identifier: "Main")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.open(size: NSSize(width: 1100, height: 700), autosave: layoutName("Main"))
        sidebar.onSelect = { [weak self] in self?.selectionChanged() }
        titles = model.$data.sink { [weak self] data in self?.updateTitle(data) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// The selected host (also when selected in the Connected section).
    var selectedHost: SSHHost? { model.host(sidebar.selection?.id) }

    var selectedWorkspace: HostWorkspace? { selectedHost.flatMap { workspaces[$0.id] } }

    /// The selected RDP entry (also when selected in the Connected section).
    var selectedEntry: RDPEntry? { model.rdpEntry(sidebar.selection?.id) }

    /// What View ▸ Enter Full Screen shows full screen instead of the window: the desktop that fills the screen now
    /// (whatever the sidebar selects), else the connected desktop shown.
    var fullScreenDesktop: RDPWorkspaceController? {
        desktops.values.first { $0.isFullScreen }
            ?? selectedEntry.flatMap { desktops[$0.id] }.flatMap { $0.state == .connected ? $0 : nil }
    }

    /// The connected hosts' Sessions, in the Connected section's order.
    var connectedSessions: [Session] {
        model.connected.compactMap { workspaces[$0] }.filter { $0.connection.state == .connected }.map(\.session)
    }

    // MARK: Workspaces and desktops

    /// The host's workspace, made if there is none.
    func workspace(for id: UUID) -> HostWorkspace? {
        if let workspace = workspaces[id] { return workspace }
        guard let host = model.host(id) else { return nil }
        let workspace = HostWorkspace(connection: HostConnection(host: host, model: model, askpass: askpass), model: model,
                                      main: self)
        workspaces[id] = workspace
        return workspace
    }

    /// The RDP entry's desktop, made if there is none.
    private func desktop(for id: UUID) -> RDPWorkspaceController? {
        if let desktop = desktops[id] { return desktop }
        guard model.rdpEntry(id) != nil else { return nil }
        let desktop = RDPWorkspaceController(entryID: id, model: model, sshSession: { [weak self] hostID in
            guard let self else { throw AirSCPError(.cancelled, "Cancelled.") }
            return try await self.connectedSession(for: hostID)
        })
        desktop.mainWindow = { [weak self] in self?.window }
        desktop.onStateChange = { [weak self, weak desktop] state in
            guard let self, let desktop, self.desktops[id] === desktop else { return }
            self.model.rdpStates[id] = state == .idle ? nil : state
            self.prune()
            self.updateTitle(self.model.data)
        }
        desktops[id] = desktop
        return desktop
    }

    /// A connected Session of the host, for an RDP entry that goes through it: connects first if needed (its prompts
    /// appear as for any connect) and throws why it couldn't.
    func connectedSession(for hostID: UUID) async throws -> Session {
        guard let workspace = workspace(for: hostID) else {
            throw AirSCPError(.other, "The SSH host this connection goes through no longer exists.")
        }
        return try await workspace.connectedSession()
    }

    /// After every state change of a workspace's connection.
    func workspaceChanged(_ workspace: HostWorkspace) {
        prune()
        if workspace === selectedWorkspace { updateTitle(model.data) }
    }

    /// Lets go of the workspaces and desktops that are idle and not shown (a workspace also keeps its finished
    /// transfers listed until they are cleared).
    private func prune() {
        let shown = sidebar.selection?.id
        for (id, workspace) in workspaces where id != shown && workspace.isUnused { workspaces[id] = nil }
        for (id, desktop) in desktops where id != shown && desktop.state == .idle { desktops[id] = nil }
    }

    private func selectionChanged() {
        let id = sidebar.selection?.id
        if let id, model.host(id) != nil {
            detail.show(workspace(for: id))
        } else if let id, model.rdpEntry(id) != nil {
            detail.show(desktop(for: id))
        } else {
            detail.show(nil)
        }
        prune()
        updateTitle(model.data)
    }

    /// Masters left running by an AirSCP that crashed: their sockets answer `ssh -O check`. Their hosts show as
    /// connected; dead sockets are removed (and their workspaces let go).
    func adoptRunningMasters() {
        for host in model.data.hosts where access(Session.socketPath(for: host.id), F_OK) == 0 {
            guard let workspace = workspace(for: host.id) else { continue }
            Task {
                if await workspace.adopt() { log.log("took over the running connection to \(host.displayName, privacy: .public)") }
            }
        }
    }

    // MARK: Hosts and entries (sidebar, menus, other windows)

    /// Shows the host (selecting it) and connects; `work` runs once connected.
    func open(_ id: UUID, then work: ((HostWorkspace) -> Void)? = nil) {
        guard model.host(id) != nil else { return }
        showWindow(nil)
        if sidebar.selection?.id != id { sidebar.selection = model.connected.contains(id) ? .connected(id) : .host(id) }
        workspace(for: id)?.connect(then: work.map { work in { [weak self] in
            if let workspace = self?.workspaces[id] { work(workspace) }
        } })
    }

    /// Opens Terminal (or iTerm) with ssh to the host, riding its connection when it has one.
    func openTerminal(for id: UUID, command: String? = nil) {
        if let workspace = workspaces[id] { return workspace.openTerminal(command: command) }
        guard let host = model.host(id) else { return }
        let model = self.model, askpass = self.askpass
        Task {
            do {
                try await TerminalLauncher.open(host, jump: model.jump(for: host), command: command,
                                                app: model.data.settings.terminalApp, environment: askpass.terminalEnvironment)
            } catch {
                showError(error, title: "Can't open a terminal for “\(host.displayName)”", on: window)
            }
        }
    }

    /// Shows the RDP entry's desktop (selecting it) and connects it.
    func connectDesktop(_ id: UUID) {
        guard model.rdpEntry(id) != nil else { return }
        showWindow(nil)
        if sidebar.selection?.id != id { sidebar.selection = model.connected.contains(id) ? .connected(id) : .rdp(id) }
        desktop(for: id)?.connect()
    }

    /// Disconnects the host, or ends the RDP entry's desktop (asking first while Windows copies into its shared folder).
    func disconnect(_ id: UUID) {
        workspaces[id]?.disconnect()
        if let desktop = desktops[id] { desktop.confirmCopies { Task { await desktop.disconnect() } } }
    }

    /// ⌘1…⌘9: the Connected section's item at `index` (from 0).
    func selectConnected(_ index: Int) {
        guard model.connected.indices.contains(index) else { return }
        showWindow(nil)
        sidebar.selection = .connected(model.connected[index])
    }

    /// A new host and desktop check their servers as Settings ▸ Security says.
    func newHost() {
        var host = SSHHost()
        host.hostKeyCheck = model.data.settings.hostKeyCheck
        editHost(host, isNew: true)
    }

    func newRemoteDesktop() {
        var entry = RDPEntry()
        entry.certificateCheck = model.data.settings.certificateCheck
        entry.caFile = model.data.settings.caFile
        editEntry(entry, isNew: true)
    }

    func newGroup() {
        guard let window else { return }
        showWindow(nil)
        askText("New Group", button: "Create", on: window) { [weak self] name in
            guard let self else { return }
            if self.model.groupNameTaken(name) { return self.groupNameTaken(name) }
            _ = self.model.addGroup(named: name)
        }
    }

    private func groupNameTaken(_ name: String) {
        guard let window else { return }
        showError(AirSCPError(.other, "A group called “\(name)” already exists: choose another name."), title: nil, on: window)
    }

    func edit(_ item: SidebarItem) {
        if let host = model.host(item.id) {
            editHost(host)
        } else if let entry = model.rdpEntry(item.id) {
            editEntry(entry)
        }
    }

    func duplicate(_ item: SidebarItem) {
        if let copy = model.duplicate(item.id) {
            sidebar.selection = .host(copy.id)
        } else if let copy = model.duplicateRDPEntry(item.id) {
            sidebar.selection = .rdp(copy.id)
        }
    }

    /// Deletes a host (refused while other hosts or RDP entries go through it) or an RDP entry, after asking.
    func delete(_ item: SidebarItem) {
        guard let window else { return }
        if let host = model.host(item.id) {
            let dependents = model.dependents(of: host.id)
            guard dependents.isEmpty else {
                let alert = NSAlert()
                alert.messageText = "“\(host.displayName)” is in use"
                alert.informativeText = "\(dependents.joined(separator: ", ")) \(dependents.count == 1 ? "goes" : "go") through it. "
                    + "Choose another jump host or SSH host for \(dependents.count == 1 ? "it" : "them") first."
                alert.addOK()
                alert.beginSheetModal(for: window)
                return
            }
            let running = workspaces[host.id]?.runningTransferCount ?? 0
            confirm("Delete “\(host.displayName)”?", info: "AirSCP forgets its settings, tunnels and saved password."
                    + (running > 0 ? " Its \(transfers(running)) are cancelled." : ""),
                    button: "Delete", destructive: true, on: window) { [weak self] in self?.remove(item) }
        } else if let entry = model.rdpEntry(item.id) {
            confirm("Delete “\(entry.displayName)”?", info: "AirSCP forgets its settings and saved password.",
                    button: "Delete", destructive: true, on: window) { [weak self] in self?.remove(item) }
        }
    }

    /// Deletes a host (disconnecting it) or an RDP entry (ending its desktop) without asking.
    func remove(_ item: SidebarItem) {
        let id = item.id
        if let workspace = workspaces.removeValue(forKey: id) {
            let connection = workspace.connection
            Task { await connection.disconnect() }
        }
        if let desktop = desktops.removeValue(forKey: id) { Task { await desktop.disconnect() } }
        model.rdpStates[id] = nil
        if sidebar.selection?.id == id { sidebar.selection = nil }
        if model.host(id) != nil { model.delete(id) } else { model.deleteRDPEntry(id) }
    }

    func renameGroup(_ group: HostGroup) {
        guard let window else { return }
        askText("Rename the group “\(group.name)”", initial: group.name, button: "Rename", on: window) { [weak self] name in
            guard let self else { return }
            if self.model.groupNameTaken(name, except: group.id) { return self.groupNameTaken(name) }
            self.model.renameGroup(group.id, to: name)
        }
    }

    /// Host ▸ Rename Group ▸ <group> and Host ▸ Delete Group ▸ <group> (the item's representedObject is the group's id).
    @objc func renameGroupItem(_ sender: NSMenuItem) {
        if let group = model.data.groups.first(where: { $0.id == sender.representedObject as? UUID }) { renameGroup(group) }
    }

    @objc func deleteGroupItem(_ sender: NSMenuItem) {
        if let group = model.data.groups.first(where: { $0.id == sender.representedObject as? UUID }) { deleteGroup(group) }
    }

    func deleteGroup(_ group: HostGroup) {
        confirm("Delete the group “\(group.name)”?", info: "Its hosts are kept, without a group.", button: "Delete Group",
                on: window) { [weak self] in self?.model.deleteGroup(group.id) }
    }

    func showProxies() {
        guard let window else { return }
        showWindow(nil)
        presentSheet(on: window) { close in ProxiesView(model: model, close: close) }
    }

    private func editHost(_ host: SSHHost, isNew: Bool = false) {
        guard let window else { return }
        showWindow(nil)
        presentSheet(on: window) { close in
            HostEditorView(model: model, host: host, isNew: isNew, askpass: askpass, window: { [weak window] in window?.attachedSheet },
                           close: { [weak self] saved in
                close()
                guard let self, let saved else { return }
                // A Session keeps the settings it was made with: stop its automatic reconnect (an attempt under way
                // too), so that no master with the old settings comes up for the next Connect, which makes a new one.
                // "Reconnect automatically" is AirSCP's own: it applies to the live connection at once.
                self.workspaces[saved]?.session.cancelReconnect()
                if let host = self.model.host(saved) { self.workspaces[saved]?.session.autoReconnect = host.autoReconnect }
                if isNew { self.sidebar.selection = .host(saved) }
            })
        }
    }

    /// The RDP entry editor. Its Test Connection goes through the entry's SSH host, connecting it first as Connect does
    /// (the host's questions are sheets on the editor then: `HostWorkspace.ask`).
    private func editEntry(_ entry: RDPEntry, isNew: Bool = false) {
        guard let window else { return }
        showWindow(nil)
        presentSheet(on: window) { close in
            RDPEditorView(model: model, entry: entry, isNew: isNew, sshSession: { [weak self] hostID in
                guard let self else { throw AirSCPError(.cancelled, "Cancelled.") }
                return try await self.connectedSession(for: hostID)
            }, window: { [weak window] in window?.attachedSheet }, close: { [weak self] saved in
                close()
                if isNew, let saved { self?.sidebar.selection = .rdp(saved) }
            })
        }
    }

    // MARK: Actions (toolbar, Host, View and Edit menus)

    @objc func connectHost(_ sender: Any?) {
        if let host = selectedHost { open(host.id) } else if let entry = selectedEntry { connectDesktop(entry.id) }
    }
    @objc func openTerminal(_ sender: Any?) { selectedHost.map { openTerminal(for: $0.id) } }
    @objc func disconnectHost(_ sender: Any?) { sidebar.selection.map { disconnect($0.id) } }
    @objc func runCommand(_ sender: Any?) { selectedHost.map { open($0.id) { $0.showRunCommand() } } }
    @objc func showTunnels(_ sender: Any?) { selectedWorkspace?.showTunnels() }
    @objc func showTerminal(_ sender: Any?) { selectedWorkspace?.showTerminal() }
    @objc func copySSHCommand(_ sender: Any?) { selectedHost.map { copyCommand($0, in: model.data) } }
    @objc func editHost(_ sender: Any?) { sidebar.selection.map(edit) }
    @objc func duplicateHost(_ sender: Any?) { sidebar.selection.map(duplicate) }
    @objc func deleteHost(_ sender: Any?) { sidebar.selection.map(delete) }
    @objc func showProxies(_ sender: Any?) { showProxies() }
    @objc func toggleCommandLog(_ sender: Any?) { selectedWorkspace?.toggleCommandLog() }
    @objc func toggleTransfers(_ sender: Any?) { detail.toggleTransfers() }
    @objc func find(_ sender: Any?) { searchItem?.beginSearchInteraction() }

    /// Host ▸ Colour Tag: the menu item's representedObject is the colour name (none: no tag).
    @objc func setColorTag(_ sender: NSMenuItem) {
        guard let id = selectedHost?.id else { return }
        model.updateHost(id) { $0.color = sender.representedObject as? String }
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        sidebar.search = sender.stringValue
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        let (enabled, reason) = check(item.action)
        let tip = Self.toolbarTips[item.itemIdentifier]
        if item.toolTip != (enabled ? tip : reason ?? tip) { item.toolTip = enabled ? tip : reason ?? tip }
        return enabled
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(setColorTag(_:)):
            item.state = selectedHost.map { $0.color == item.representedObject as? String } == true ? .on : .off
        case #selector(toggleCommandLog(_:)):
            item.title = selectedWorkspace?.showsCommandLog == true ? "Hide Command Log" : "Show Command Log"
        case #selector(toggleTransfers(_:)):
            item.title = detail.showsTransfers ? "Hide Transfers" : "Show Transfers"
        default:
            break
        }
        let (enabled, reason) = check(item.action)
        item.explain(enabled: enabled, reason: reason)
        return enabled
    }

    /// Whether a toolbar or menu command can run now, and why not.
    private func check(_ action: Selector?) -> (Bool, String?) {
        // Menu shortcuts still reach a window with a sheet.
        guard window?.attachedSheet == nil else { return (false, "A sheet is open in AirSCP's window: answer or close it first.") }
        let state = selectedWorkspace?.connection.state ?? .idle
        let desktop = selectedEntry.flatMap { desktops[$0.id]?.state } ?? .idle
        let desktopActive = desktop == .connected || desktop == .connecting
        let nothing = "Nothing is selected in the sidebar: select a host or desktop first."
        let noHost = selectedEntry != nil ? "This is for SSH hosts: a Remote Desktop has no shell." : nothing
        switch action {
        case #selector(connectHost(_:)):
            if selectedEntry != nil { return (!desktopActive, desktopActive ? "Already connected." : nil) }
            guard selectedHost != nil else { return (false, nothing) }
            return (state != .connected && state != .connecting, state == .connected ? "Already connected." : "Connecting already.")
        case #selector(disconnectHost(_:)):
            if selectedEntry != nil { return (desktopActive, "Not connected.") }
            guard sidebar.selection != nil else { return (false, nothing) }
            return (state != .idle, "Not connected.")
        case #selector(runCommand(_:)):
            guard selectedHost != nil else { return (false, noHost) }
            let capabilities = selectedWorkspace?.session.capabilities
            guard state == .connected, capabilities?.shell != true else { return (true, nil) }
            return (false, capabilities?.noShellReason ?? "This server doesn't run commands.")
        case #selector(copySSHCommand(_:)):
            guard let host = selectedHost else { return (false, noHost) }
            let problem = copyCommandProblem(host, in: model.data)
            return (problem == nil, problem)
        case #selector(openTerminal(_:)), #selector(showTunnels(_:)), #selector(showTerminal(_:)), #selector(toggleCommandLog(_:)),
             #selector(setColorTag(_:)):
            return (selectedHost != nil, noHost)
        case #selector(editHost(_:)), #selector(duplicateHost(_:)), #selector(deleteHost(_:)):
            return (selectedHost != nil || model.rdpEntry(sidebar.selection?.id) != nil, nothing)
        default:
            return (true, nil)
        }
    }

    // MARK: Toolbar

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .flexibleSpace, .add, .sidebarTrackingSeparator,
         .connect, .terminal, .runCommand, .commandLog, .disconnect, .flexibleSpace, .search]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    /// The toolbar items' tooltips (while one is off: why).
    static let toolbarTips: [NSToolbarItem.Identifier: String] = [
        .toggleSidebar: "Hide or show the list of hosts (⌃⌘S)",
        .add: "Add a server (SSH), a Windows desktop, or a group for the sidebar",
        .connect: "Connect to the selected host or desktop (⌘K)",
        .terminal: "Open an ssh session to this host in Terminal (⌘T)",
        .runCommand: "Run one command on this host and read its output here (⇧⌘R)",
        .commandLog: "Show or hide the commands AirSCP ran on this host, with their results (⌥⌘L)",
        .disconnect: "Close the connection to this host or desktop (⌘E)",
        .search: "Narrow the sidebar to hosts and desktops whose name, address, jump host or proxy contains this",
    ]

    /// AppKit makes the sidebar button itself: its tooltip is set as it comes.
    func toolbarWillAddItem(_ notification: Notification) {
        guard let item = notification.userInfo?["item"] as? NSToolbarItem, let tip = Self.toolbarTips[item.itemIdentifier] else { return }
        item.toolTip = tip
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case .search:
            let item = NSSearchToolbarItem(itemIdentifier: id)
            item.searchField.placeholderString = "Search Hosts"
            item.toolTip = Self.toolbarTips[id]
            item.searchField.toolTip = Self.toolbarTips[id]
            item.searchField.sendsSearchStringImmediately = true
            item.searchField.target = self
            item.searchField.action = #selector(searchChanged(_:))
            searchItem = item
            return item
        case .add:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New")
            item.label = "New"
            item.toolTip = Self.toolbarTips[id]
            item.showsIndicator = false
            item.menu = NSMenu()
            // The item's button is a pull-down, whose first item is its title and never listed: without this empty one,
            // New Host… was missing from the menu.
            item.menu.addItem(withTitle: "", action: nil, keyEquivalent: "")
            for (title, action) in [("New Host…", #selector(AppDelegate.newHost(_:))),
                                    ("New Remote Desktop…", #selector(AppDelegate.newRemoteDesktop(_:))),
                                    ("New Group…", #selector(AppDelegate.newGroup(_:)))] {
                item.menu.addItem(withTitle: title, action: action, keyEquivalent: "").toolTip = MenuHelp.tips[action]
            }
            return item
        default:
            let specs: [NSToolbarItem.Identifier: (label: String, symbol: String, action: Selector)] = [
                .connect: ("Connect", "bolt.horizontal", #selector(connectHost(_:))),
                .terminal: ("Open Terminal", "terminal", #selector(openTerminal(_:))),
                .runCommand: ("Run Command", "chevron.left.forwardslash.chevron.right", #selector(runCommand(_:))),
                .commandLog: ("Command Log", "list.bullet.rectangle", #selector(toggleCommandLog(_:))),
                .disconnect: ("Disconnect", "eject", #selector(disconnectHost(_:))),
            ]
            guard let spec = specs[id] else { return nil }
            let item = NSToolbarItem(itemIdentifier: id)
            item.label = spec.label
            item.toolTip = Self.toolbarTips[id]
            item.image = NSImage(systemSymbolName: spec.symbol, accessibilityDescription: spec.label)
            item.action = spec.action
            item.isBordered = true
            return item
        }
    }

    // MARK: Window

    private func updateTitle(_ data: AirSCPData) {
        guard let window else { return }
        let id = sidebar.selection?.id
        // The route goes with the state: "Connected · via corp-proxy → bastion" (PLAN.md U.1).
        if let host = data.host(id) {
            window.title = host.displayName
            window.subtitle = ([Self.describe(workspaces[host.id]?.connection.state ?? .idle)]
                               + [data.route(for: host)?.short].compactMap { $0 }).joined(separator: " · ")
        } else if let entry = data.rdpEntries.first(where: { $0.id == id }) {
            window.title = entry.displayName
            window.subtitle = ([Self.describe(desktops[entry.id]?.state ?? .idle)]
                               + [data.route(for: entry)?.short].compactMap { $0 }).joined(separator: " · ")
        } else {
            window.title = "AirSCP"
            window.subtitle = ""
        }
    }

    static func describe(_ state: Session.State) -> String {
        switch state {
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .reconnecting: return "Reconnecting…"
        case .disconnected: return "Disconnected"
        }
    }

    static func describe(_ state: RDPSession.State) -> String {
        switch state {
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .connected: return "Connected"
        case .disconnected: return "Disconnected"
        }
    }

    /// Masters taken over at launch aren't AirSCP's children: ask whether they are still there.
    func windowDidBecomeKey(_ notification: Notification) {
        for workspace in workspaces.values {
            let connection = workspace.connection
            Task { await connection.checkAdopted() }
        }
    }
}

// MARK: Window sizes

extension NSWindow {
    /// Opens in the middle of the screen at `size` (of its content), made smaller on a small screen: at most 85 % of
    /// its width and 80 % of its height. With an autosave name, at the size and place it had when last used instead, as
    /// long as that frame still fits on a screen: one from a display that has gone, or one taller than the screen
    /// (Porter, before the rename, saved such frames), is dropped, and the window opens at `size`.
    func open(size: NSSize, autosave name: String? = nil) {
        setContentSize(size)
        if let visible = NSScreen.main?.visibleFrame {
            setFrame(NSRect(origin: frame.origin, size: WindowFrame.fitted(frame.size, minimum: minSize, on: visible)), display: false)
        }
        center()
        guard let name else { return }
        let key = "NSWindow Frame " + name
        if let saved = UserDefaults.standard.string(forKey: key), !WindowFrame.fits(saved, on: NSScreen.screens.map(\.visibleFrame)) {
            UserDefaults.standard.removeObject(forKey: key)
            log.log("dropped the \(name, privacy: .public) window's saved frame, off the screen: \(saved, privacy: .public)")
        }
        setFrameAutosaveName(name)
    }
}

/// The name under which AppKit saves a window's frame, the sidebar's width or a pane's columns in AirSCP's defaults;
/// nil (nothing read or saved) in a throwaway AirSCP (its own settings folder: tests, smoke runs, agents' instances),
/// which shares those defaults with the user's AirSCP and would change the user's sizes.
func layoutName(_ name: String) -> String? {
    Keychain.isThrowaway(ProcessInfo.processInfo.environment) ? nil : name
}

enum WindowFrame {
    /// `size`, at most 85 % of the screen's width and 80 % of its height (never below the window's `minimum`).
    static func fitted(_ size: NSSize, minimum: NSSize, on visible: NSRect) -> NSSize {
        NSSize(width: max(minimum.width, min(size.width, (visible.width * 0.85).rounded(.down))),
               height: max(minimum.height, min(size.height, (visible.height * 0.8).rounded(.down))))
    }

    /// Whether a frame AppKit saved ("x y width height", then its screen's) lies on one of the screens: within its
    /// visible frame (without the menu bar and the Dock).
    static func fits(_ saved: String, on screens: [NSRect]) -> Bool {
        let numbers = saved.split(separator: " ").compactMap { Double($0) }
        guard numbers.count >= 4 else { return false }
        let frame = NSRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
        return frame.width > 0 && frame.height > 0 && screens.contains { $0.contains(frame) }
    }
}

extension NSToolbarItem.Identifier {
    static let add = Self("add")
    static let connect = Self("connect")
    static let terminal = Self("terminal")
    static let runCommand = Self("runCommand")
    static let commandLog = Self("commandLog")
    static let disconnect = Self("disconnect")
    static let search = Self("search")
}

/// The right side of the main window: the selected host's workspace or RDP entry's desktop (a hint when nothing is
/// selected) above the Transfers queue of every host.
@MainActor
final class DetailController: NSViewController, NSSplitViewDelegate {
    private let model: AppModel
    private let split = SurfaceSplitView()
    private let container = NSView()
    private let hint = NSTextField(wrappingLabelWithString: "")
    /// The Transfers panel; nil while hidden (a SwiftUI table kept off screen would still be worked on at every update).
    private var transfers: NSView?
    /// The panel's height as the divider last left it: what it gets back when a window made small grows again.
    private var queueHeight: CGFloat = 150
    private(set) var current: NSViewController?
    private var hintText: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        hint.textColor = .secondaryLabelColor
        hint.alignment = .center
        hint.preferredMaxLayoutWidth = 360
        hint.translatesAutoresizingMaskIntoConstraints = false
        // What to do next: select a host, or (with none) add one.
        hintText = model.$data.map { $0.hosts.isEmpty && $0.rdpEntries.isEmpty }.removeDuplicates().sink { [weak self] none in
            self?.hint.stringValue = none ? "Add a host with the + button or File ▸ New Host…"
                : "Select a host in the sidebar to browse its files. Drag files between the two panes to copy them."
        }
        container.addSubview(hint)
        // The split view starts from these heights: the queue a few rows high, the rest for the workspace.
        container.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        split.isVertical = false
        split.dividerStyle = .thin
        split.delegate = self
        split.addArrangedSubview(container)
        // A bigger window grows the workspace, not the queue.
        split.setHoldingPriority(NSLayoutConstraint.Priority(250), forSubviewAt: 0)
        addTransfers()
        split.translatesAutoresizingMaskIntoConstraints = false
        let view = SurfaceView(.ground)  // the window's ground: around Paper's cards, under the toolbar
        view.addSubview(split)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            hint.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            // Below the toolbar: the window's content reaches under it.
            split.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            split.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        self.view = view
    }

    /// Shows a workspace or desktop (nil: the hint); the one shown before is kept by its owner.
    func show(_ controller: NSViewController?) {
        guard controller !== current else { return }
        _ = view
        if let current {
            current.view.removeFromSuperview()
            current.removeFromParent()
        }
        current = controller
        hint.isHidden = controller != nil
        guard let controller else { return }
        addChild(controller)
        let shown = controller.view
        shown.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(shown)
        NSLayoutConstraint.activate([
            shown.topAnchor.constraint(equalTo: container.topAnchor),
            shown.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            shown.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            shown.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
    }

    /// A bigger window gives the room to the workspace; a smaller one takes it from the workspace while that keeps 400
    /// points (the panes about eight rows), then from the queue (down to a few rows). At the window's minimum size the
    /// queue had kept its own height and left the panes three rows each.
    func splitView(_ splitView: NSSplitView, resizeSubviewsWithOldSize oldSize: NSSize) {
        guard let transfers, splitView.subviews.count == 2 else { return splitView.adjustSubviews() }
        let total = splitView.bounds.height - splitView.dividerThickness
        let queue = min(max(90, queueHeight), max(90, total - 400))
        let width = splitView.bounds.width
        container.frame = NSRect(x: 0, y: 0, width: width, height: max(0, total - queue))
        transfers.frame = NSRect(x: 0, y: total - queue + splitView.dividerThickness, width: width, height: queue)
    }

    /// The divider dragged (the split view asks only then): the queue's new height is the one to keep.
    func splitView(_ splitView: NSSplitView, constrainSplitPosition proposedPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        queueHeight = max(90, splitView.bounds.height - splitView.dividerThickness - proposedPosition)
        return proposedPosition
    }

    var showsTransfers: Bool { isViewLoaded && transfers != nil }

    func toggleTransfers() {
        _ = view
        if let transfers {
            transfers.removeFromSuperview()
            self.transfers = nil
            return
        }
        addTransfers()
        split.layoutSubtreeIfNeeded()
        split.setPosition(max(split.bounds.height - split.dividerThickness - queueHeight, 120), ofDividerAt: 0)
    }

    private func addTransfers() {
        let transfers = NSHostingView(rootView: TransfersPanel(model: model))
        transfers.sizingOptions = .minSize  // the split view sets its height
        transfers.frame = NSRect(x: 0, y: 0, width: 800, height: 150)
        split.addArrangedSubview(transfers)
        split.setHoldingPriority(NSLayoutConstraint.Priority(260), forSubviewAt: 1)
        self.transfers = transfers
    }
}
