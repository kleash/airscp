import AirSCPCore
import AppKit
import SwiftUI

/// Colour tags: (menu title, stored name).
let colorTags: [(title: String, name: String)] = [
    ("Red", "red"), ("Orange", "orange"), ("Yellow", "yellow"), ("Green", "green"), ("Blue", "blue"),
    ("Purple", "purple"), ("Grey", "gray"),
]

/// System colours: they have light and dark variants.
func tagColor(_ name: String?) -> Color? {
    switch name {
    case "red": return .red
    case "orange": return .orange
    case "yellow": return .yellow
    case "green": return .green
    case "blue": return .blue
    case "purple": return .purple
    case "gray": return .gray
    default: return nil
    }
}

/// The status dot: orange while connecting or reconnecting, green when connected, red when the connection was lost.
func statusDot(_ state: Session.State?) -> (color: Color, help: String)? {
    switch state {
    case .connecting?: return (.orange, "Connecting")
    case .reconnecting?: return (.orange, "Reconnecting")
    case .connected?: return (.green, "Connected")
    case .disconnected?: return (.red, "Disconnected")
    case .idle?, nil: return nil
    }
}

func statusDot(_ state: RDPSession.State?) -> (color: Color, help: String)? {
    switch state {
    case .connecting?: return (.orange, "Connecting")
    case .connected?: return (.green, "Connected")
    case .disconnected?: return (.red, "Disconnected")
    case .idle?, nil: return nil
    }
}

/// The main window's sidebar: the Connected section (hosts and desktops that aren't idle, in the order they connected,
/// numbered for ⌘1…⌘9, with each host's transfer count), the saved hosts by group, the RDP entries, and the Proxies
/// button. The toolbar's search narrows the hosts and entries. Double-clicking a host connects it and shows its files;
/// double-clicking an RDP entry connects its desktop.
struct Sidebar: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: SidebarState
    unowned let controller: MainWindowController

    var body: some View {
        VStack(spacing: 0) {
            if model.data.hosts.isEmpty && model.data.groups.isEmpty && model.data.rdpEntries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack").font(.system(size: 40, weight: .light)).foregroundColor(.secondary)
                        .accessibilityHidden(true)
                    Text("No hosts yet").font(.headline)
                    Text("A host is a server you log in to over SSH. Add one, or import the ones in your ~/.ssh/config. "
                         + "For a Windows computer, add a Remote Desktop.")
                        .multilineTextAlignment(.center)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("New Host…") { controller.newHost() }
                        .help(MenuHelp.tips[#selector(AppDelegate.newHost(_:))] ?? "")
                    Button("Import from ~/.ssh/config…") {
                        NSApp.sendAction(#selector(AppDelegate.importSSHConfig(_:)), to: nil, from: nil)
                    }
                    .help(MenuHelp.tips[#selector(AppDelegate.importSSHConfig(_:))] ?? "")
                    Button("New Remote Desktop…") { controller.newRemoteDesktop() }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help(MenuHelp.tips[#selector(AppDelegate.newRemoteDesktop(_:))] ?? "")
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
            Divider()
            VStack(alignment: .leading, spacing: 7) {
                Button { controller.showProxies() } label: {
                    HStack(spacing: 8) {
                        Chip(symbol: "network", hue: .orange)
                        Text("Proxies").fontWeight(.semibold)
                    }
                }
                .buttonStyle(.borderless)
                .foregroundColor(.primary)
                .help("HTTP proxies a host's connection can go through; most people need none")
                if model.agentControlOn { AgentIndicator(model: model) }
                if model.debugLoggingOn {
                    Button(action: revealDebugLog) {
                        Label("Debug logging on", systemImage: "ladybug").font(.caption).foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                    .help("Debug logging is on (Settings ▸ Advanced). Click to show AirSCP-debug.log in Finder")
                    .accessibilityIdentifier("debugLog.indicator")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .background(Wash())
    }

    private var list: some View {
        List(selection: $state.selection) {
            let connected = AppModel.connectedRows(model.data, connected: model.connected, search: state.search)
            if !connected.isEmpty {
                Section {
                    ForEach(connected, id: \.id) { row in connectedRow(row.id, number: row.number) }
                } header: {
                    Text("Connected").help("Hosts and desktops that are connected now; ⌘1–⌘9 switch between them")
                }
            }
            ForEach(AppModel.sections(model.data, search: state.search)) { section in
                Section {
                    ForEach(section.hosts) { host in
                        HostRow(host: host, state: model.states[host.id], route: model.data.route(for: host),
                                selected: state.selection == .host(host.id))
                            .tag(SidebarItem.host(host.id))
                    }
                    if section.hosts.isEmpty {
                        Text("No hosts in this group yet. Edit a host and choose this group under Group.")
                            .font(.caption).foregroundColor(.secondary)
                    }
                } header: {
                    header(section)
                }
            }
            let entries = AppModel.rdpEntries(model.data, search: state.search)
            if !entries.isEmpty {
                Section {
                    ForEach(entries) { entry in
                        RDPRow(entry: entry, state: model.rdpStates[entry.id], route: model.data.route(for: entry),
                               selected: state.selection == .rdp(entry.id))
                            .tag(SidebarItem.rdp(entry.id))
                    }
                } header: {
                    Text("Remote Desktop").help("Saved Windows desktops, opened in AirSCP's own Remote Desktop client")
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: SidebarItem.self) { items in
            if let item = items.first { menu(item) }
        } primaryAction: { items in
            // A double-click connects and shows the host's files (Terminal stays on ⌘T and the context menu).
            guard let item = items.first else { return }
            if model.host(item.id) != nil {
                controller.open(item.id)
            } else if model.rdpEntry(item.id) != nil {
                controller.connectDesktop(item.id)
            }
        }
        .onDeleteCommand {
            if let item = state.selection { controller.delete(item) }
        }
    }

    @ViewBuilder
    private func connectedRow(_ id: UUID, number: Int) -> some View {
        if let host = model.host(id) {
            HostRow(host: host, state: model.states[id], route: model.data.route(for: host),
                    transfers: model.activeTransfers[id] ?? 0, number: number, selected: state.selection == .connected(id))
                .tag(SidebarItem.connected(id))
        } else if let entry = model.rdpEntry(id) {
            RDPRow(entry: entry, state: model.rdpStates[id], route: model.data.route(for: entry), number: number,
                   selected: state.selection == .connected(id))
                .tag(SidebarItem.connected(id))
        }
    }

    @ViewBuilder
    private func header(_ section: AppModel.Section) -> some View {
        if let group = section.group {
            Text(group.name)
                .help("A group of hosts. Right-click to rename or delete it")
                .contextMenu {
                    Button("Rename Group…") { controller.renameGroup(group) }
                        .help(tip(#selector(MainWindowController.renameGroupItem(_:))))
                    Button("Delete Group…") { controller.deleteGroup(group) }
                        .help(tip(#selector(MainWindowController.deleteGroupItem(_:))))
                }
        } else {
            Text(section.title).help("Saved SSH servers. Double-click one to connect; right-click for more")
        }
    }

    @ViewBuilder
    private func menu(_ item: SidebarItem) -> some View {
        if let host = model.host(item.id) {
            Button("Connect") { controller.open(host.id) }.help(tip(#selector(MainWindowController.connectHost(_:))))
            Button("Open Terminal") { controller.openTerminal(for: host.id) }
                .help(tip(#selector(MainWindowController.openTerminal(_:))))
            if model.states[host.id] != nil {
                Button("Disconnect") { controller.disconnect(host.id) }.help(tip(#selector(MainWindowController.disconnectHost(_:))))
            }
            Divider()
            Button("Edit…") { controller.edit(item) }.help(tip(#selector(MainWindowController.editHost(_:))))
            Button("Duplicate") { controller.duplicate(item) }.help(tip(#selector(MainWindowController.duplicateHost(_:))))
            let problem = copyCommandProblem(host, jump: model.jump(for: host))
            Button("Copy ssh Command") { copyCommand(host, jump: model.jump(for: host)) }
                .help(problem ?? tip(#selector(MainWindowController.copySSHCommand(_:))))
                .disabled(problem != nil)
            Picker("Colour Tag", selection: Binding(get: { host.color }, set: { color in
                model.updateHost(host.id) { $0.color = color }
            })) {
                Text("None").tag(String?.none)
                ForEach(colorTags, id: \.name) { tag in Text(tag.title).tag(Optional(tag.name)) }
            }
            .help(tip(#selector(MainWindowController.setColorTag(_:))))
            Divider()
            Button("Delete…") { controller.delete(item) }.help(tip(#selector(MainWindowController.deleteHost(_:))))
        } else if model.rdpEntry(item.id) != nil {
            Button("Connect") { controller.connectDesktop(item.id) }.help(tip(#selector(MainWindowController.connectHost(_:))))
            if model.rdpStates[item.id] == .connected || model.rdpStates[item.id] == .connecting {
                Button("Disconnect") { controller.disconnect(item.id) }.help(tip(#selector(MainWindowController.disconnectHost(_:))))
            }
            Divider()
            Button("Edit…") { controller.edit(item) }.help(tip(#selector(MainWindowController.editHost(_:))))
            Button("Duplicate") { controller.duplicate(item) }.help(tip(#selector(MainWindowController.duplicateHost(_:))))
            Divider()
            Button("Delete…") { controller.delete(item) }.help(tip(#selector(MainWindowController.deleteHost(_:))))
        }
    }

    private func tip(_ action: Selector) -> String { MenuHelp.tips[action] ?? "" }
}

struct HostRow: View {
    let host: SSHHost
    let state: Session.State?
    /// Through a jump host or proxy: shown under the name instead of the address (PLAN.md U.1).
    var route: Route?
    /// Queued and running transfers (shown in the Connected section).
    var transfers = 0
    /// Its place in the Connected section: ⌘1…⌘9.
    var number: Int?
    var selected = false

    var body: some View {
        HStack(spacing: 9) {
            Chip(symbol: "server.rack", hue: tagColor(host.color) ?? .blue, tagged: host.color != nil, selected: selected)
            VStack(alignment: .leading, spacing: 1) {
                Text(host.displayName).fontWeight(.semibold).lineLimit(1)
                if missingKey != nil {
                    Text("key file missing").font(.caption).foregroundColor(selected ? .onPillCaption : .red).lineLimit(1)
                } else if let route {
                    RouteLine(route: route, selected: selected)
                } else if !host.label.isEmpty {
                    Text(address).font(.caption).foregroundColor(selected ? .onPillCaption : .secondary).lineLimit(1)
                }
            }
            // The rest of the row: a Spacer would add a gap of its own and cut the route short beside a badge and ⌘1.
            .frame(maxWidth: .infinity, alignment: .leading)
            if host.hostKeyCheck == .off { ChecksOffShield(ssh: true) }
            if transfers > 0 {
                CountBadge(count: transfers, help: transfers == 1 ? "1 transfer queued or running"
                           : "\(transfers) transfers queued or running", selected: selected)
            }
            ShortcutLabel(number: number)
            if let dot = statusDot(state) {
                StatusDot(color: dot.color, help: dot.help)
            } else if let key = missingKey {
                StatusDot(color: .orange, help: "The key file \(key) no longer exists: edit the host to choose another")
            } else {
                StatusDot(color: Color(nsColor: selected ? .onPill : .tertiaryLabelColor).opacity(selected ? 0.45 : 1),
                          help: "Not connected", glows: false)
            }
        }
        .foregroundColor(selected ? Color(nsColor: .onPill) : nil)
        .help(tooltip)
        .modifier(SidebarSelection(selected: selected))
    }

    private var address: String { host.address }

    private var missingKey: String? { missingKeyFile(host) }

    private var tooltip: String {
        let name = host.label.isEmpty ? address : "\(host.displayName) (\(address))"
        return name + " — double-click to connect, right-click for actions" + (route.map { "\n" + $0.full } ?? "")
            + (missingKey.map { "\nThe key file \($0) no longer exists: edit the host to choose another" } ?? "")
            + (host.hostKeyCheck == .off ? "\n" + ChecksOffShield.help(ssh: true) : "")
    }
}

/// A Connected row's count of queued and running transfers: the pill's colours, swapped on the selected row.
struct CountBadge: View {
    let count: Int
    let help: String
    var selected = false

    var body: some View {
        Text("\(count)")
            .font(.system(size: 10, weight: .bold).monospacedDigit())
            .foregroundColor(Color(nsColor: selected ? .labelColor : .onPill))
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 16)
            .background(Capsule().fill(Color(nsColor: selected ? .onPill : .pill)))
            .drawingGroup()
            .help(help)
    }
}

/// "⑂ via corp-proxy → bastion" under a host's name: red when a hop no longer exists.
struct RouteLine: View {
    let route: Route
    var selected = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch").accessibilityHidden(true)
            Text(route.short).lineLimit(1).truncationMode(.middle)
        }
        .font(.caption)
        .foregroundColor(selected ? .onPillCaption : route.missing ? .red : .secondary)
    }
}

struct RDPRow: View {
    let entry: RDPEntry
    let state: RDPSession.State?
    /// Through an SSH host: shown under the name.
    var route: Route?
    var number: Int?
    var selected = false

    var body: some View {
        HStack(spacing: 9) {
            Chip(symbol: "display", hue: .purple, selected: selected)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.displayName).fontWeight(.semibold).lineLimit(1)
                if let route {
                    RouteLine(route: route, selected: selected)
                } else if !entry.label.isEmpty {
                    Text((entry.username.isEmpty ? "" : entry.username + "@") + entry.hostname).font(.caption)
                        .foregroundColor(selected ? .onPillCaption : .secondary).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if entry.certificateCheck == .off { ChecksOffShield(ssh: false) }
            ShortcutLabel(number: number)
            if let dot = statusDot(state) {
                StatusDot(color: dot.color, help: dot.help)
            } else {
                StatusDot(color: Color(nsColor: selected ? .onPill : .tertiaryLabelColor).opacity(selected ? 0.45 : 1),
                          help: "Not connected", glows: false)
            }
        }
        .foregroundColor(selected ? Color(nsColor: .onPill) : nil)
        .help(tooltip)
        .modifier(SidebarSelection(selected: selected))
    }

    private var tooltip: String {
        let address = entry.hostname + (entry.port == 3389 ? "" : ":\(entry.port)")
        return "Windows desktop \(address) — double-click to connect" + (route.map { "\n" + $0.full } ?? "")
            + (entry.certificateCheck == .off ? "\n" + ChecksOffShield.help(ssh: false) : "")
    }
}

/// "⌘1"…"⌘9" in a Connected row.
private struct ShortcutLabel: View {
    let number: Int?

    var body: some View {
        if let number, number <= 9 {
            Text("⌘\(number)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                .help("Press ⌘\(number) to switch to this one")
        }
    }
}

// MARK: Agent control (PLAN.md U.2)

/// The footer's "Agent control on": the dot pulses while an agent acts, and the text then names the agent and its last
/// action. Hover: the state, who is connected, the last action and how many there were; click: the recent actions,
/// with Turn Off Agent Control and Settings….
struct AgentIndicator: View {
    @ObservedObject var model: AppModel
    @State private var showing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button { showing.toggle() } label: {
            HStack(spacing: 7) {
                // The agent's pink dot (a picture of its own, not the sidebar's vibrant colours); while an agent acts, its
                // own shadow grows and fades every 2.4 s.
                TimelineView(.animation(minimumInterval: 1 / 30, paused: !model.agentActive || reduceMotion)) { context in
                    let phase = model.agentActive && !reduceMotion
                        ? context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.4) / 2.4 : 1
                    ZStack {
                        Circle().fill(Color(nsColor: .systemPink).opacity(0.55 * (1 - phase))).frame(width: 7 + 12 * phase, height: 7 + 12 * phase)
                        Circle().fill(Color(nsColor: .systemPink)).frame(width: 7, height: 7)
                    }
                    .frame(width: 19, height: 19)
                    .drawingGroup()
                    .padding(-6)
                }
                footer.font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
            }
        }
        .buttonStyle(.borderless)
        .help(AgentStatus.summary(model) + "\nClick for the recent actions.")
        .accessibilityIdentifier("agent.indicator")
        // From the label's end, so that the popover opens inside the window rather than past its left edge.
        .popover(isPresented: $showing, attachmentAnchor: .point(.topTrailing), arrowEdge: .top) { AgentActivityView(model: model) }
    }

    /// "Agent control on · claude-code", or while it acts "Agent: claude-code — Pressed “Trust”…".
    private var footer: Text {
        if model.agentActive, let last = model.agentActions.last { return Text("Agent: \(last.client) — \(last.text)") }
        guard let client = model.agentClient else { return Text("Agent control on") }
        return Text("Agent control on · ") + Text(client.name).fontWeight(.semibold).foregroundColor(.primary)
    }
}

/// The agent indicator's words.
@MainActor
enum AgentStatus {
    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    /// The state now: acting, connected (and since when) or idle.
    static func state(_ model: AppModel) -> String {
        if model.agentActive { return "An agent is acting now" + (model.agentClient.map { ": " + $0.name } ?? ".") }
        if let client = model.agentClient { return "An agent is connected: \(client.name), since \(time.string(from: client.since))." }
        return "Idle: no agent is connected."
    }

    /// The tooltip: what agent control is, the state, the last action and how many there were.
    static func summary(_ model: AppModel) -> String {
        var lines = ["Agent control is on (Settings): AI agents and scripts may drive AirSCP as you would; they never "
                     + "see saved passwords.", state(model)]
        if let last = model.agentActions.last {
            lines.append("Last: \(last.text) in \(last.target), at \(time.string(from: last.date)).")
        }
        lines.append("Actions so far: \(model.agentActionCount).")
        return lines.joined(separator: "\n")
    }

    static func time(_ date: Date) -> String { time.string(from: date) }
}

/// The indicator's popover: the last 20 actions, newest first, and Turn Off Agent Control / Settings….
struct AgentActivityView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Agent control").font(.headline)
            Text(AgentStatus.state(model)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.agentActions.isEmpty {
                Text("No actions yet. An MCP client (Claude Code, Codex…) connects with the command in Settings ▸ Allow "
                     + "AI agents to control AirSCP.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.agentActions.reversed()) { action in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(AgentStatus.time(action.date)).font(.caption.monospacedDigit()).foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(action.text).fixedSize(horizontal: false, vertical: true)
                                    Text("\(action.client) · \(action.target)").font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
            }
            HStack {
                Button("Settings…") { NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil) }
                    .help("Open Settings, where agent control is switched on and off and the command to connect an agent is")
                Spacer()
                Button("Turn Off Agent Control") {
                    NSApp.sendAction(#selector(AppDelegate.turnOffAgentControl(_:)), to: nil, from: nil)
                }
                .help("Close agent control's socket now: agents can't drive AirSCP until it is switched on again in Settings")
            }
        }
        .padding(14)
        .frame(width: 360)
    }
}
