import AirSCPCore
import Combine
import Foundation
import os

let log = Logger(subsystem: "com.kleash.airscp", category: "app")

/// The folder AirSCP treats as ~/.ssh: the Keys window's key pairs, the host editor's key menu, and the config that
/// Import reads. $AIRSCP_SSH_DIR replaces it for testing; every ssh command then also gets `-F $AIRSCP_SSH_DIR/config`
/// (AppDelegate), so nothing reads the real ~/.ssh/config.
let sshDirectory: String = {
    if let dir = Env.value("SSH_DIR"), !dir.isEmpty { return dir }
    return NSHomeDirectory() + "/.ssh"
}()

/// What the windows share: the saved hosts, groups, snippets, proxies, RDP entries and settings (airscp.json, written
/// on every change), and what is connected, for the sidebar.
@MainActor
final class AppModel: ObservableObject {
    @Published var data: AirSCPData {
        didSet {
            guard data != oldValue else { return }
            do {
                try store(data)
                onSaved?()
            } catch {
                log.error("can't save airscp.json: \(error.localizedDescription, privacy: .public)")
                onSaveError?(error)
            }
        }
    }
    /// Hosts whose connection isn't idle: connecting, connected, reconnecting, or disconnected by a failure.
    @Published var states: [UUID: Session.State] = [:] {
        didSet { updateConnected() }
    }
    /// RDP entries whose desktop isn't idle.
    @Published var rdpStates: [UUID: RDPSession.State] = [:] {
        didSet { updateConnected() }
    }
    /// The ids in `states` and `rdpStates`, in the order they started connecting: the sidebar's Connected section and
    /// ⌘1…⌘9.
    @Published private(set) var connected: [UUID] = []
    /// Queued and running transfers per host: the sidebar's badges. Published only when a count changes, not on progress.
    @Published private(set) var activeTransfers: [UUID: Int] = [:]
    var onSaveError: ((Error) -> Void)?
    var onSaved: (() -> Void)?
    /// Agent control is listening (the sidebar's indicator).
    @Published var agentControlOn = false
    /// The debug log is on (`DebugLog.enabled`: the setting or AIRSCP_DEBUG=1): the sidebar's hint, the failure banners'
    /// Show Debug Log.
    @Published var debugLoggingOn = false
    /// An agent's request came in within the last 5 seconds (the indicator's dot).
    @Published private(set) var agentActive = false
    private var agentQuiet: DispatchWorkItem?
    /// The agent that drives AirSCP now (the MCP client's name, or "AirSCP --agent") and since when; nil once its
    /// process has gone (PLAN.md U.2).
    @Published private(set) var agentClient: (name: String, since: Date)?
    /// What agents did, in plain words (newest last, at most 20), and how many actions since AirSCP started.
    @Published private(set) var agentActions: [AgentAction] = []
    @Published private(set) var agentActionCount = 0
    /// The processes that made requests and still run, by pid: an MCP client's bridge stays named while a one-off
    /// `AirSCP --agent` comes and goes.
    private var agentClients: [pid_t: (name: String, since: Date, last: Date, watch: DispatchSourceProcess)] = [:]
    /// The Transfers panel's selected jobs (its own object: a selection change doesn't redraw the sidebar).
    let transferSelection = TransferSelection()
    /// Saved passwords by Keychain key: a host's id, `RDPEntry.keychainKey` or `Proxy.keychainKey` (tests replace these
    /// two).
    var savedPassword: (String) -> String? = { Keychain.password(forKey: $0) }
    var setSavedPassword: (String, String?) -> Void = { Keychain.setPassword($1, forKey: $0) }

    private let store: (AirSCPData) throws -> Void
    private var transferCounts: AnyCancellable?

    init(data: AirSCPData, store: @escaping (AirSCPData) throws -> Void = Store.save) {
        self.data = data
        self.store = store
        transferCounts = TransferCenter.shared.$jobs.map(Self.activeTransferCounts).removeDuplicates()
            .sink { [weak self] counts in self?.activeTransfers = counts }
    }

    /// Queued and running jobs per host (a relay counts for its destination; a paused job waits, and keeps no Mac awake).
    nonisolated static func activeTransferCounts(_ jobs: [TransferJob]) -> [UUID: Int] {
        jobs.reduce(into: [:]) { counts, job in
            if job.status.isActive { counts[job.hostID, default: 0] += 1 }
        }
    }

    /// An agent's action (the request's tool and target in plain words, never a secret), from the process `pid` of
    /// `client`: the indicator lists it and names the client while that process runs (the one that asked last, of those
    /// still running).
    func agentActed(_ text: String?, target: String, client: String, pid: pid_t) {
        agentRequested()
        if pid > 0 {
            if let known = agentClients[pid] {
                agentClients[pid] = (client, known.since, Date(), known.watch)
            } else {
                let watch = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
                watch.setEventHandler { [weak self] in
                    guard let self, let gone = self.agentClients.removeValue(forKey: pid) else { return }
                    gone.watch.cancel()
                    self.nameLatestAgentClient()
                }
                watch.resume()
                agentClients[pid] = (client, Date(), Date(), watch)
            }
            nameLatestAgentClient()
        }
        guard let text else { return }
        agentActionCount += 1
        agentActions.append(AgentAction(date: Date(), text: text, target: target, client: client))
        if agentActions.count > 20 { agentActions.removeFirst(agentActions.count - 20) }
    }

    private func nameLatestAgentClient() {
        let latest = agentClients.values.max { $0.last < $1.last }
        if latest?.name != agentClient?.name || latest?.since != agentClient?.since { agentClient = latest.map { ($0.name, $0.since) } }
    }

    /// An agent's request: the indicator lights for 5 s.
    func agentRequested() {
        agentActive = true
        agentQuiet?.cancel()
        let quiet = DispatchWorkItem { [weak self] in self?.agentActive = false }
        agentQuiet = quiet
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: quiet)
    }

    private func updateConnected() {
        let active = Set(states.keys).union(rdpStates.keys)
        var order = connected.filter(active.contains)
        order += active.subtracting(order).sorted { $0.uuidString < $1.uuidString }
        if order != connected { connected = order }
    }

    /// Removes a saved password, reading first: most hosts never had one, and writing would rewrite the Keychain item.
    private func forgetPassword(_ key: String) {
        if savedPassword(key) != nil { setSavedPassword(key, nil) }
    }

    // MARK: Hosts

    func host(_ id: UUID?) -> SSHHost? { data.host(id) }

    func jump(for host: SSHHost) -> SSHHost? { data.jump(for: host) }

    /// Adds the host, or replaces the saved one with its id.
    func save(_ host: SSHHost) {
        if let index = data.hosts.firstIndex(where: { $0.id == host.id }) {
            data.hosts[index] = host
        } else {
            data.hosts.append(host)
        }
    }

    func updateHost(_ id: UUID, _ change: (inout SSHHost) -> Void) {
        guard let index = data.hosts.firstIndex(where: { $0.id == id }) else { return }
        change(&data.hosts[index])
    }

    /// A copy of the host ("name copy", its own id, tunnels and saved password), right after it.
    @discardableResult
    func duplicate(_ id: UUID) -> SSHHost? {
        guard let index = data.hosts.firstIndex(where: { $0.id == id }) else { return nil }
        let original = data.hosts[index]
        var copy = original
        copy.id = UUID()
        copy.label = original.displayName + " copy"
        copy.tunnels = original.tunnels.map { tunnel in
            var tunnel = tunnel
            tunnel.id = UUID()
            return tunnel
        }
        data.hosts.insert(copy, at: index + 1)
        if original.auth == .password, let password = savedPassword(original.id.uuidString) {
            setSavedPassword(copy.id.uuidString, password)
        }
        return copy
    }

    /// The hosts that go through `id` as their jump host.
    func hostsJumping(through id: UUID) -> [SSHHost] {
        data.hosts.filter { $0.jumpHostID == id }
    }

    /// What else needs the host: hosts that jump through it and RDP entries that go through it. It can't be deleted
    /// while there are any.
    func dependents(of id: UUID) -> [String] {
        hostsJumping(through: id).map(\.displayName) + data.rdpEntries.filter { $0.viaHostID == id }.map(\.displayName)
    }

    /// Deletes the host and its saved password. (Check `dependents(of:)` first.)
    func delete(_ id: UUID) {
        data.hosts.removeAll { $0.id == id }
        forgetPassword(id.uuidString)
    }

    /// The hosts `host` may go through (one hop only): the others that have no jump host of their own, plus the
    /// one it already uses. Only that one when other hosts go through `host`: anything else would make a chain.
    func jumpCandidates(for host: SSHHost) -> [SSHHost] {
        let open = hostsJumping(through: host.id).isEmpty
        return data.hosts.filter { $0.id == host.jumpHostID || (open && $0.id != host.id && $0.jumpHostID == nil) }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    // MARK: Groups

    @discardableResult
    /// Whether another group has this name (any case): two groups of the same name couldn't be told apart.
    func groupNameTaken(_ name: String, except id: UUID? = nil) -> Bool {
        data.groups.contains { $0.id != id && $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }
    }

    func addGroup(named name: String) -> HostGroup {
        let group = HostGroup(name: name)
        data.groups.append(group)
        return group
    }

    func renameGroup(_ id: UUID, to name: String) {
        guard let index = data.groups.firstIndex(where: { $0.id == id }) else { return }
        data.groups[index].name = name
    }

    /// Deletes the group; its hosts stay, without a group.
    func deleteGroup(_ id: UUID) {
        var changed = data
        changed.groups.removeAll { $0.id == id }
        for index in changed.hosts.indices where changed.hosts[index].groupID == id { changed.hosts[index].groupID = nil }
        data = changed
    }

    // MARK: RDP entries

    func rdpEntry(_ id: UUID?) -> RDPEntry? {
        id.flatMap { id in data.rdpEntries.first { $0.id == id } }
    }

    /// Adds the entry, or replaces the saved one with its id.
    func save(_ entry: RDPEntry) {
        if let index = data.rdpEntries.firstIndex(where: { $0.id == entry.id }) {
            data.rdpEntries[index] = entry
        } else {
            data.rdpEntries.append(entry)
        }
    }

    /// A copy of the entry ("name copy", its own id and saved password), right after it.
    @discardableResult
    func duplicateRDPEntry(_ id: UUID) -> RDPEntry? {
        guard let index = data.rdpEntries.firstIndex(where: { $0.id == id }) else { return nil }
        let original = data.rdpEntries[index]
        var copy = original
        copy.id = UUID()
        copy.label = original.displayName + " copy"
        data.rdpEntries.insert(copy, at: index + 1)
        if let password = savedPassword(original.keychainKey) { setSavedPassword(copy.keychainKey, password) }
        return copy
    }

    /// Deletes the entry and its saved password.
    func deleteRDPEntry(_ id: UUID) {
        guard let entry = rdpEntry(id) else { return }
        data.rdpEntries.removeAll { $0.id == id }
        forgetPassword(entry.keychainKey)
    }

    // MARK: Proxies

    /// Adds the proxy, or replaces the saved one with its id.
    func save(_ proxy: Proxy) {
        if let index = data.proxies.firstIndex(where: { $0.id == proxy.id }) {
            data.proxies[index] = proxy
        } else {
            data.proxies.append(proxy)
        }
    }

    /// The hosts set to connect through the proxy (one with a jump host goes through the jump host's proxy instead).
    func hostsUsing(proxy id: UUID) -> [SSHHost] {
        data.hosts.filter { $0.proxyID == id && $0.jumpHostID == nil }
    }

    /// After a failed connect: when the proxy of the host's first hop (its jump host's, when it has one) rejected the
    /// saved password (HTTP 407), that password is forgotten, so that the next Connect asks for it instead of failing
    /// the same way. True when one was.
    @discardableResult
    func forgetRejectedProxyPassword(for host: SSHHost, after error: AirSCPError) -> Bool {
        let proxyID = jump(for: host).map(\.proxyID) ?? host.proxyID
        guard error.details.range(of: #"AirSCP proxy: HTTP/[0-9.]+ 407"#, options: .regularExpression) != nil,
              let proxy = data.proxy(proxyID), savedPassword(proxy.keychainKey) != nil else { return false }
        setSavedPassword(proxy.keychainKey, nil)
        return true
    }

    /// Deletes the proxy and its saved password. (Check `hostsUsing(proxy:)` first.)
    func deleteProxy(_ id: UUID) {
        guard let proxy = data.proxy(id) else { return }
        data.proxies.removeAll { $0.id == id }
        forgetPassword(proxy.keychainKey)
    }

    // MARK: Sidebar

    struct Section: Identifiable, Equatable {
        /// nil: the hosts in no group.
        let group: HostGroup?
        let hosts: [SSHHost]
        var id: UUID? { group?.id }
        var title: String { group?.name ?? "Hosts" }
    }

    /// The sidebar: hosts without a group first, then the groups by name, each sorted by name. A search keeps the
    /// hosts whose name, address, user name, jump host or proxy contains it, and only the groups that have such hosts.
    static func sections(_ data: AirSCPData, search: String) -> [Section] {
        let term = search.trimmingCharacters(in: .whitespaces)
        let hosts = data.hosts.filter {
            matches([$0.displayName, $0.hostname, $0.username, $0.address] + data.routeNames(for: $0), term)
        }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        let groupIDs = Set(data.groups.map(\.id))
        var sections: [Section] = []
        let loose = hosts.filter { $0.groupID.map { !groupIDs.contains($0) } ?? true }
        if !loose.isEmpty { sections.append(Section(group: nil, hosts: loose)) }
        for group in data.groups.sorted(by: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) {
            let members = hosts.filter { $0.groupID == group.id }
            if !members.isEmpty || term.isEmpty { sections.append(Section(group: group, hosts: members)) }
        }
        return sections
    }

    /// The sidebar's Connected rows the search matches (all without one), each with its number for ⌘1…⌘9: unfiltered,
    /// many connected hosts would push the matching ones below the fold.
    static func connectedRows(_ data: AirSCPData, connected: [UUID], search: String) -> [(number: Int, id: UUID)] {
        let rows = connected.enumerated().map { (number: $0.offset + 1, id: $0.element) }
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else { return rows }
        let matching = Set(sections(data, search: search).flatMap(\.hosts).map(\.id))
            .union(rdpEntries(data, search: search).map(\.id))
        return rows.filter { matching.contains($0.id) }
    }

    /// The sidebar's Remote Desktop section: the entries by name, searched like the hosts.
    static func rdpEntries(_ data: AirSCPData, search: String) -> [RDPEntry] {
        let term = search.trimmingCharacters(in: .whitespaces)
        return data.rdpEntries.filter {
            matches([$0.displayName, $0.hostname, $0.username] + (data.host($0.viaHostID).map { [$0.displayName] } ?? []), term)
        }
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    private static func matches(_ fields: [String], _ term: String) -> Bool {
        // "dev@127.0.0.1:42202" or a part of it, as the row shows the address.
        term.isEmpty || fields.contains { $0.localizedStandardContains(term) }
    }

    // MARK: Importing

    /// Whether a saved host already has this ~/.ssh/config alias as its host name.
    func hasHost(named alias: String) -> Bool {
        data.hosts.contains { $0.hostname == alias }
    }

    /// Saves a host for each alias that has none yet. Its host name is the alias, so ssh applies the config's
    /// settings for it whenever AirSCP connects.
    @discardableResult
    func importAliases(_ aliases: [String]) -> [SSHHost] {
        var seen = Set<String>()
        let added = aliases.filter { !hasHost(named: $0) && !$0.hasPrefix("-") && seen.insert($0).inserted }
            .map { alias -> SSHHost in
                var host = SSHHost(hostname: alias)
                host.hostKeyCheck = data.settings.hostKeyCheck  // as new hosts (Settings ▸ Security)
                return host
            }
        data.hosts += added
        return added
    }

    /// Adds the hosts, groups, proxies and Remote Desktop entries of an exported file (same id: replaced). Hosts whose
    /// name starts with "-" are skipped: ssh would read such a name as an option. Returns the names of the hosts
    /// imported and of those skipped.
    @discardableResult
    func importHosts(_ imported: AirSCPData) -> (imported: [String], skipped: [String]) {
        var imported = imported
        let skipped = imported.hosts.filter { $0.hostname.hasPrefix("-") }.map(\.displayName)
        imported.hosts.removeAll { $0.hostname.hasPrefix("-") }
        data.merge(imported)
        return (imported.hosts.map(\.displayName), skipped)
    }
}

extension SSHHost {
    /// "user@host:port" as the sidebar shows it (no user or port when the host has none).
    var address: String {
        (username.isEmpty ? "" : username + "@") + hostname + (port.map { ":\($0)" } ?? "")
    }
}

/// One of the agent indicator's recent actions.
struct AgentAction: Identifiable {
    let id = UUID()
    let date: Date
    /// "Pressed “Trust”", "Chose Host ▸ Connect".
    let text: String
    /// The sheet or window it was in, or the host shown.
    let target: String
    let client: String
}

/// How a host's (or desktop's) connection goes, for the sidebar, the window's subtitle and agents (PLAN.md U.1).
struct Route: Equatable {
    /// "via bastion", "via proxy corp-proxy", "via corp-proxy → bastion" (the first hop first).
    let short: String
    /// Every hop with its user@host:port, for the tooltip.
    let full: String
    /// A jump host, proxy or SSH host it names no longer exists.
    let missing: Bool
}

extension AirSCPData {
    /// The route of a host through its jump host and the HTTP proxy of its first hop (with a jump host, the jump
    /// host's own proxy); nil for a host that connects directly.
    func route(for host: SSHHost) -> Route? {
        guard let hops = hops(for: host) else { return Self.optionRoute(host) }
        return Self.route(hops, target: host.address, verb: "Connects to")
    }

    /// The route of a Remote Desktop through its SSH host (and that host's own route); nil when it connects directly.
    func route(for entry: RDPEntry) -> Route? {
        guard let id = entry.viaHostID else { return nil }
        let target = entry.hostname + (entry.port == 3389 ? "" : ":\(entry.port)")
        guard let ssh = host(id) else {
            return Route(short: "via a missing SSH host", full: "Goes through an SSH host that no longer exists: edit the "
                         + "desktop to choose another, or none.", missing: true)
        }
        let hops = (self.hops(for: ssh) ?? []) + [(ssh.displayName, "the SSH host \(ssh.displayName) (\(Self.hop(ssh)))")]
        return Self.route(hops, target: target, verb: "Opens the desktop")
    }

    /// The names a sidebar search finds a host by besides its own: its jump host's and proxy's.
    func routeNames(for host: SSHHost) -> [String] {
        let jump = self.host(host.jumpHostID)
        return [jump?.displayName, proxy(jump.map(\.proxyID) ?? host.proxyID)?.displayName].compactMap { $0 }
    }

    /// The hops before `host`, each with its short name and its description (nil name: it no longer exists).
    private func hops(for host: SSHHost) -> [(name: String?, text: String)]? {
        guard host.jumpHostID != nil || host.proxyID != nil else { return nil }
        let jump = self.host(host.jumpHostID)
        var hops: [(name: String?, text: String)] = []
        let proxyID = host.jumpHostID == nil ? host.proxyID : jump?.proxyID
        if let proxyID {
            if let proxy = proxy(proxyID) {
                let login = proxy.username.isEmpty ? "" : proxy.username + "@"
                hops.append(("proxy " + proxy.displayName, "the HTTP proxy \(proxy.displayName) (\(login)\(proxy.host):\(proxy.port))"))
            } else {
                hops.append((nil, "an HTTP proxy that no longer exists (edit the host to choose another)"))
            }
        }
        if host.jumpHostID != nil {
            if let jump {
                hops.append((jump.displayName, "the jump host \(jump.displayName) (\(Self.hop(jump)))"))
            } else {
                hops.append((nil, "a jump host that no longer exists (edit the host to choose another)"))
            }
        }
        return hops
    }

    /// The route a host's Other options give it (ProxyCommand, ProxyJump), which would look direct otherwise; nil
    /// without one. (A jump host or proxy of its own wins: ssh is then given those, and the option is refused.)
    private static func optionRoute(_ host: SSHHost) -> Route? {
        for option in host.extraOptions {
            let parts = option.split(maxSplits: 1, whereSeparator: { $0 == "=" || $0 == " " })
            guard parts.count == 2 else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            switch parts[0].lowercased() {
            case "proxycommand" where value.lowercased() != "none":
                return Route(short: "via a proxy command", full: "Connects to \(host.address) through the command in its "
                             + "Other options: ProxyCommand \(value)", missing: false)
            case "proxyjump" where value.lowercased() != "none":
                return Route(short: "via " + value, full: "Connects to \(host.address) through \(value) (ProxyJump in its "
                             + "Other options).", missing: false)
            default: continue
            }
        }
        return nil
    }

    private static func hop(_ host: SSHHost) -> String {
        (host.username.isEmpty ? "" : host.username + "@") + host.hostname + ":\(host.port ?? 22)"
    }

    private static func route(_ hops: [(name: String?, text: String)], target: String, verb: String) -> Route {
        let full = "\(verb) \(target) through " + hops.map(\.text).joined(separator: ", then ") + "."
        if let gone = hops.first(where: { $0.name == nil }) {
            let what = gone.text.hasPrefix("an HTTP proxy") ? "proxy" : "jump host"
            return Route(short: "via a missing \(what)", full: full, missing: true)
        }
        // "via proxy corp-proxy" alone; "via corp-proxy → bastion" with a hop after it.
        var names = hops.compactMap(\.name)
        if names.count > 1, names[0].hasPrefix("proxy ") { names[0].removeFirst("proxy ".count) }
        return Route(short: "via " + names.joined(separator: " → "), full: full, missing: false)
    }
}
