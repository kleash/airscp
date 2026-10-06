import Foundation
import os

let log = Logger(subsystem: "com.kleash.airscp", category: "core")

/// How an SSH server's host key is checked (PLAN.md U.4; `OpenSSH.options`).
public enum HostKeyCheck: String, Codable, CaseIterable {
    /// A new server's key is asked about (Trust); a changed one is refused. ssh's own default.
    case ask
    /// A new server's key is trusted at once (StrictHostKeyChecking=accept-new); a changed one is still refused.
    case acceptNew
    /// No check at all: StrictHostKeyChecking=no, with no known_hosts for this host (anyone could pretend to be it).
    case off
}

/// How a Remote Desktop's server certificate is checked (PLAN.md U.4; `RDPSession.Options`).
public enum CertificateCheck: String, Codable, CaseIterable {
    /// A certificate not trusted yet, or changed, is asked about.
    case ask
    /// A new server's certificate is trusted at once and remembered; a changed one is still asked about.
    case trustNew
    /// No check at all (FreeRDP's IgnoreCertificate).
    case off
    /// Checked with a company certificate authority (a CA file); one it didn't sign is asked about.
    case companyCA
}

/// A saved server. Everything ssh needs is expressed as `-o Key=Value` options (see `OpenSSH.options`).
public struct SSHHost: Codable, Identifiable, Hashable {
    public enum Auth: String, Codable { case agent, keyFile, password }

    public var id = UUID()
    public var label = ""
    /// Host name, IP address or ~/.ssh/config alias.
    public var hostname = ""
    /// nil: ssh's default (from ~/.ssh/config, else 22).
    public var port: Int?
    /// Empty: ssh's default (from ~/.ssh/config, else the Mac user name).
    public var username = ""
    /// .agent uses the agent and the default keys.
    public var auth = Auth.agent
    /// The private key for `.keyFile`.
    public var keyFile = ""
    /// Another saved host to go through (one hop).
    public var jumpHostID: UUID?
    public var defaultRemoteDir = ""
    public var forwardAgent = false
    /// Extra "Key=Value" ssh options, one per line.
    public var extraOptions: [String] = []
    public var groupID: UUID?
    /// Colour tag name chosen in the sidebar, if any.
    public var color: String?
    /// Saved port forwards.
    public var tunnels: [Tunnel] = []
    /// The local pane's last folder for this host.
    public var lastLocalDir: String?
    /// The HTTP proxy for the connection from this Mac (`Proxy.id`). With a jump host, the jump host's own proxy is
    /// the one used (it is the first hop) and this one is ignored.
    public var proxyID: UUID?
    /// Keep-alive: the master's ServerAliveInterval, in seconds.
    public var serverAliveInterval = 15
    /// Reconnect by itself when the connection drops, if that needs no question (see `Session.State.reconnecting`).
    public var autoReconnect = true
    /// Server folders kept with Go ▸ Add to Favourites, in the order added.
    public var favourites: [String] = []
    /// The folder-transfer sheet's "Leave out" as last typed: names or patterns separated by commas
    /// (`TransferQueue.patterns`).
    public var leaveOut = ""
    /// How the server's host key is checked.
    public var hostKeyCheck = HostKeyCheck.ask

    public init(id: UUID = UUID(), label: String = "", hostname: String = "", port: Int? = nil, username: String = "",
                auth: Auth = .agent, keyFile: String = "") {
        self.id = id
        self.label = label
        self.hostname = hostname
        self.port = port
        self.username = username
        self.auth = auth
        self.keyFile = keyFile
    }

    /// Hosts saved by another version may lack keys; those keep their defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        let defaults = SSHHost()
        id = try value(.id, defaults.id)
        label = try value(.label, defaults.label)
        hostname = try value(.hostname, defaults.hostname)
        port = try container.decodeIfPresent(Int.self, forKey: .port)
        username = try value(.username, defaults.username)
        auth = try value(.auth, defaults.auth)
        keyFile = try value(.keyFile, defaults.keyFile)
        jumpHostID = try container.decodeIfPresent(UUID.self, forKey: .jumpHostID)
        defaultRemoteDir = try value(.defaultRemoteDir, defaults.defaultRemoteDir)
        forwardAgent = try value(.forwardAgent, defaults.forwardAgent)
        extraOptions = try value(.extraOptions, defaults.extraOptions)
        groupID = try container.decodeIfPresent(UUID.self, forKey: .groupID)
        color = try container.decodeIfPresent(String.self, forKey: .color)
        tunnels = try value(.tunnels, defaults.tunnels)
        lastLocalDir = try container.decodeIfPresent(String.self, forKey: .lastLocalDir)
        proxyID = try container.decodeIfPresent(UUID.self, forKey: .proxyID)
        serverAliveInterval = try value(.serverAliveInterval, defaults.serverAliveInterval)
        autoReconnect = try value(.autoReconnect, defaults.autoReconnect)
        favourites = try value(.favourites, defaults.favourites)
        leaveOut = try value(.leaveOut, defaults.leaveOut)
        hostKeyCheck = try value(.hostKeyCheck, defaults.hostKeyCheck)
    }

    /// The label, else user@host:port.
    public var displayName: String {
        if !label.isEmpty { return label }
        return (username.isEmpty ? "" : username + "@") + hostname + (port.map { ":\($0)" } ?? "")
    }
}

public struct HostGroup: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var name = ""

    public init(id: UUID = UUID(), name: String) {
        self.id = id
        self.name = name
    }
}

/// A saved command; the host is picked when it runs.
public struct Snippet: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var name = ""
    public var command = ""
    /// Run it in Terminal (with a tty, for sudo, top, …) instead of capturing its output.
    public var runInTerminal = false

    public init(id: UUID = UUID(), name: String, command: String, runInTerminal: Bool = false) {
        self.id = id
        self.name = name
        self.command = command
        self.runInTerminal = runInTerminal
    }
}

/// A saved port forward, switched on and off over the host's master connection.
public struct Tunnel: Codable, Identifiable, Hashable {
    public enum Kind: String, Codable { case local, remote, dynamic }

    public var id = UUID()
    public var kind = Kind.local
    /// The port that listens: on this Mac for .local and .dynamic (SOCKS), on the server for .remote.
    public var listenPort = 0
    /// Where connections go (unused for .dynamic).
    public var targetHost = "localhost"
    public var targetPort = 0

    public init(id: UUID = UUID(), kind: Kind, listenPort: Int, targetHost: String = "localhost", targetPort: Int = 0) {
        self.id = id
        self.kind = kind
        self.listenPort = listenPort
        self.targetHost = targetHost
        self.targetPort = targetPort
    }

    /// The ssh flag and its argument, e.g. ["-L", "127.0.0.1:8080:localhost:80"]. This Mac's end listens on 127.0.0.1
    /// only: "localhost" would let ssh take whichever of 127.0.0.1 and ::1 is free, and a busy port would go unnoticed.
    public var forwardArguments: [String] {
        let target = targetHost.contains(":") ? "[\(targetHost)]" : targetHost
        switch kind {
        case .local: return ["-L", "127.0.0.1:\(listenPort):\(target):\(targetPort)"]
        case .remote: return ["-R", "\(listenPort):\(target):\(targetPort)"]
        case .dynamic: return ["-D", "127.0.0.1:\(listenPort)"]
        }
    }
}

/// An HTTP proxy (CONNECT) that a host's first hop goes through. Its password, if any, is in the Keychain under
/// `keychainKey`.
public struct Proxy: Codable, Identifiable, Hashable {
    public var id = UUID()
    public var name = ""
    public var host = ""
    public var port = 8080
    /// Empty: the proxy needs no authentication.
    public var username = ""

    public init(id: UUID = UUID(), name: String = "", host: String = "", port: Int = 8080, username: String = "") {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
    }

    /// The name, else host:port.
    public var displayName: String { name.isEmpty ? "\(host):\(port)" : name }

    /// Its password's key in AirSCP's Keychain item (`Keychain.password(forKey:)`).
    public var keychainKey: String { "proxy:" + id.uuidString }
}

/// A saved Windows (RDP) server. Its password, if remembered, is in the Keychain under `keychainKey` ("rdp:<id>").
public struct RDPEntry: Codable, Identifiable, Hashable {
    public enum Display: Codable, Hashable {
        /// The desktop follows the size of its view (resized as the window is).
        case fit
        case fixed(width: Int, height: Int)
        case fullscreen
    }

    public var id = UUID()
    public var label = ""
    public var hostname = ""
    public var port = 3389
    public var username = ""
    public var domain = ""
    /// Through this saved SSH host: a local forward on its master connection (with its proxy and jump host).
    public var viaHostID: UUID?
    public var display = Display.fit
    /// On a Retina screen, ask the server for twice the pixels.
    public var retinaScale = true
    /// Share text on the clipboard both ways.
    public var clipboard = true
    /// ⌘ is sent as Ctrl (⌘C copies in Windows).
    public var cmdAsCtrl = true
    /// Share a Mac folder with Windows, where it is \\tsclient\AirSCP (drive redirection).
    public var shareFolder = true
    /// The shared Mac folder; empty: ~/Downloads/AirSCP RDP.
    public var sharedFolder = ""
    /// How the server's certificate is checked.
    public var certificateCheck = CertificateCheck.ask
    /// The company certificate authority's file (PEM or DER) for `.companyCA`.
    public var caFile = ""

    public init(id: UUID = UUID(), label: String = "", hostname: String = "", port: Int = 3389, username: String = "") {
        self.id = id
        self.label = label
        self.hostname = hostname
        self.port = port
        self.username = username
    }

    /// The label, else host:port (port shown when not 3389).
    public var displayName: String {
        if !label.isEmpty { return label }
        return hostname + (port == 3389 ? "" : ":\(port)")
    }

    /// Entries saved by another version may lack keys; those keep their defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T {
            try container.decodeIfPresent(T.self, forKey: key) ?? fallback
        }
        let defaults = RDPEntry()
        id = try value(.id, defaults.id)
        label = try value(.label, defaults.label)
        hostname = try value(.hostname, defaults.hostname)
        port = try value(.port, defaults.port)
        username = try value(.username, defaults.username)
        domain = try value(.domain, defaults.domain)
        viaHostID = try container.decodeIfPresent(UUID.self, forKey: .viaHostID)
        display = try value(.display, defaults.display)
        retinaScale = try value(.retinaScale, defaults.retinaScale)
        clipboard = try value(.clipboard, defaults.clipboard)
        cmdAsCtrl = try value(.cmdAsCtrl, defaults.cmdAsCtrl)
        shareFolder = try value(.shareFolder, defaults.shareFolder)
        sharedFolder = try value(.sharedFolder, defaults.sharedFolder)
        certificateCheck = try value(.certificateCheck, defaults.certificateCheck)
        caFile = try value(.caFile, defaults.caFile)
    }
}

public struct AppSettings: Codable, Equatable {
    public enum TerminalApp: String, Codable { case terminal, iTerm }
    /// Light or dark: as macOS (`system`), or always one of them.
    public enum Appearance: String, Codable { case system, light, dark }

    public var terminalApp = TerminalApp.terminal
    public var downloadFolder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first?.path
        ?? NSHomeDirectory() + "/Downloads"
    public var showHidden = false
    /// scp -p: keep modification times and modes.
    public var preserveTimes = false
    public var confirmDelete = true
    public var appearance = Appearance.system
    /// Calculate folder sizes whenever a remote folder is listed (else only on request).
    public var alwaysCalculateFolderSizes = false
    /// AI agents and scripts may control AirSCP (`AirSCP --mcp`, `AirSCP --agent`; PLAN.md T). Off by default.
    public var agentControl = false
    /// The Transfers panel's speed limit for every host's transfers, in MB/s; 0: none (PLAN.md S.2).
    public var transferSpeedLimit = 0
    /// The welcome sheet has been shown (it comes once, on a first run with no hosts; Help ▸ Welcome to AirSCP… again).
    public var welcomeShown = false
    /// How new hosts check their server's key, and new desktops their server's certificate (with `caFile` for
    /// `.companyCA`): Settings ▸ Security (PLAN.md U.4).
    public var hostKeyCheck = HostKeyCheck.ask
    public var certificateCheck = CertificateCheck.ask
    public var caFile = ""
    /// Where New Key Pair and Import Key save keys; empty: ~/.ssh (PLAN.md K.1).
    public var keyFolder = ""
    /// Settings ▸ Debug logging (`DebugLog`, PLAN.md AE). Off by default.
    public var debugLogging = false

    public init() {}

    /// Settings saved by another version may lack keys; those keep their defaults.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        terminalApp = try container.decodeIfPresent(TerminalApp.self, forKey: .terminalApp) ?? defaults.terminalApp
        downloadFolder = try container.decodeIfPresent(String.self, forKey: .downloadFolder) ?? defaults.downloadFolder
        showHidden = try container.decodeIfPresent(Bool.self, forKey: .showHidden) ?? defaults.showHidden
        preserveTimes = try container.decodeIfPresent(Bool.self, forKey: .preserveTimes) ?? defaults.preserveTimes
        confirmDelete = try container.decodeIfPresent(Bool.self, forKey: .confirmDelete) ?? defaults.confirmDelete
        appearance = try container.decodeIfPresent(Appearance.self, forKey: .appearance) ?? defaults.appearance
        alwaysCalculateFolderSizes = try container.decodeIfPresent(Bool.self, forKey: .alwaysCalculateFolderSizes)
            ?? defaults.alwaysCalculateFolderSizes
        agentControl = try container.decodeIfPresent(Bool.self, forKey: .agentControl) ?? defaults.agentControl
        transferSpeedLimit = try container.decodeIfPresent(Int.self, forKey: .transferSpeedLimit) ?? defaults.transferSpeedLimit
        welcomeShown = try container.decodeIfPresent(Bool.self, forKey: .welcomeShown) ?? defaults.welcomeShown
        hostKeyCheck = try container.decodeIfPresent(HostKeyCheck.self, forKey: .hostKeyCheck) ?? defaults.hostKeyCheck
        certificateCheck = try container.decodeIfPresent(CertificateCheck.self, forKey: .certificateCheck)
            ?? defaults.certificateCheck
        caFile = try container.decodeIfPresent(String.self, forKey: .caFile) ?? defaults.caFile
        keyFolder = try container.decodeIfPresent(String.self, forKey: .keyFolder) ?? defaults.keyFolder
        debugLogging = try container.decodeIfPresent(Bool.self, forKey: .debugLogging) ?? defaults.debugLogging
    }
}

/// Everything AirSCP saves (secrets excepted: those are in the Keychain).
/// SSHHost, AppSettings and AirSCPData load files that lack newer keys (their decoders use the defaults). New fields
/// in HostGroup, Snippet, Tunnel, Proxy or RDPEntry must be Optional, or get such a decoder: files without the key
/// must still load.
public struct AirSCPData: Codable, Equatable {
    public var hosts: [SSHHost] = []
    public var groups: [HostGroup] = []
    public var snippets: [Snippet] = []
    public var settings = AppSettings()
    public var proxies: [Proxy] = []
    public var rdpEntries: [RDPEntry] = []

    public init(hosts: [SSHHost] = [], groups: [HostGroup] = [], snippets: [Snippet] = [], settings: AppSettings = AppSettings(),
                proxies: [Proxy] = [], rdpEntries: [RDPEntry] = []) {
        self.hosts = hosts
        self.groups = groups
        self.snippets = snippets
        self.settings = settings
        self.proxies = proxies
        self.rdpEntries = rdpEntries
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hosts = try container.decodeIfPresent([SSHHost].self, forKey: .hosts) ?? []
        groups = try container.decodeIfPresent([HostGroup].self, forKey: .groups) ?? []
        snippets = try container.decodeIfPresent([Snippet].self, forKey: .snippets) ?? []
        settings = try container.decodeIfPresent(AppSettings.self, forKey: .settings) ?? AppSettings()
        proxies = try container.decodeIfPresent([Proxy].self, forKey: .proxies) ?? []
        rdpEntries = try container.decodeIfPresent([RDPEntry].self, forKey: .rdpEntries) ?? []
    }

    public func host(_ id: UUID?) -> SSHHost? {
        id.flatMap { id in hosts.first { $0.id == id } }
    }

    public func proxy(_ id: UUID?) -> Proxy? {
        id.flatMap { id in proxies.first { $0.id == id } }
    }

    /// The host's jump host, if it has one that still exists.
    public func jump(for host: SSHHost) -> SSHHost? {
        self.host(host.jumpHostID)
    }

    /// Adds exported hosts, groups, proxies and Remote Desktop entries; ones with an id that is already here replace it.
    public mutating func merge(_ other: AirSCPData) {
        func add<Item: Identifiable>(_ items: [Item], to list: inout [Item]) {
            for item in items {
                if let index = list.firstIndex(where: { $0.id == item.id }) { list[index] = item } else { list.append(item) }
            }
        }
        add(other.groups, to: &groups)
        add(other.hosts, to: &hosts)
        add(other.proxies, to: &proxies)
        add(other.rdpEntries, to: &rdpEntries)
    }
}

/// AirSCP's environment variables: AIRSCP_<name>, else PORTER_<name>, the name from before the app was renamed
/// (PLAN.md X), which this release still accepts.
public enum Env {
    public static func value(_ name: String, in environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        environment["AIRSCP_" + name] ?? environment["PORTER_" + name]
    }
}

/// airscp.json in Application Support, written atomically.
public enum Store {
    /// ~/Library/Application Support/AirSCP, or $AIRSCP_SUPPORT_DIR (for tests and smoke runs).
    public static var directory: URL {
        if let dir = Env.value("SUPPORT_DIR"), !dir.isEmpty { return URL(fileURLWithPath: dir, isDirectory: true) }
        return applicationSupport.appendingPathComponent("AirSCP", isDirectory: true)
    }

    /// The settings folder of AirSCP's first versions, which were called Porter.
    static var porterDirectory: URL { applicationSupport.appendingPathComponent("Porter", isDirectory: true) }

    private static var applicationSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Application Support")
    }

    public static var fileURL: URL { directory.appendingPathComponent("airscp.json") }

    /// AirSCP was called Porter (PLAN.md X). Its first start (no settings folder yet) takes over Porter's settings: the
    /// folder's contents (porter.json as airscp.json, the trusted Remote Desktop certificates) and the sidebar width
    /// and column layouts in Porter's defaults (com.sa.porter). Porter's own are left as they were (`Keychain` does the
    /// same with the saved passwords). An instance with a settings folder of its own (AIRSCP_SUPPORT_DIR) takes
    /// nothing.
    public static func migrateFromPorter() {
        guard (Env.value("SUPPORT_DIR") ?? "").isEmpty else { return }
        copyFromPorter(porterDirectory, to: directory, defaults: .standard, porterDomain: "com.sa.porter")
    }

    /// `migrateFromPorter` with the folders and defaults given (tests use their own). The copy is made in a temporary
    /// folder that takes the new folder's name once complete: one cut short is made again at the next start.
    static func copyFromPorter(_ old: URL, to new: URL, defaults: UserDefaults, porterDomain: String) {
        let files = FileManager.default
        guard !files.fileExists(atPath: new.path) else { return }
        let settings = defaults.persistentDomain(forName: porterDomain)
        guard settings != nil || files.fileExists(atPath: old.path) else { return }  // nothing of Porter's on this Mac
        // AppKit's autosave names (the sidebar, the panes' columns) are the same in AirSCP. Not the window frames:
        // Porter saved some taller than the screen, and AirSCP's windows open at their own sizes instead.
        for (key, value) in settings ?? [:] where !key.hasPrefix("NSWindow Frame ") { defaults.set(value, forKey: key) }
        let temporary = new.deletingLastPathComponent().appendingPathComponent("." + new.lastPathComponent + "-" + UUID().uuidString)
        do {
            try files.createDirectory(at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let names = files.fileExists(atPath: old.path) ? try files.contentsOfDirectory(atPath: old.path) : []
            // Not the agent socket or the Terminal scripts: those belong to a Porter that may still be running.
            for name in names where name != "agent" && name != "Terminal" {
                try files.copyItem(at: old.appendingPathComponent(name),
                                   to: temporary.appendingPathComponent(name == "porter.json" ? "airscp.json" : name))
            }
            try files.moveItem(at: temporary, to: new)
            log.log("took over Porter's settings from \(old.path, privacy: .public)")
        } catch {
            try? files.removeItem(at: temporary)
            log.error("couldn't take over Porter's settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The saved data; empty when there is none. An unreadable file is moved aside (airscp.json.unreadable),
    /// never overwritten.
    public static func load() -> AirSCPData {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else { return AirSCPData() }
        do {
            return try JSONDecoder().decode(AirSCPData.self, from: data)
        } catch {
            let aside = url.appendingPathExtension("unreadable")
            try? FileManager.default.removeItem(at: aside)
            try? FileManager.default.moveItem(at: url, to: aside)
            log.error("airscp.json unreadable, moved to \(aside.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return AirSCPData()
        }
    }

    public static func save(_ data: AirSCPData) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try encoded(data).write(to: fileURL, options: .atomic)
    }

    /// The hosts, groups, proxies and Remote Desktop entries as JSON for another Mac (no secrets: passwords stay in
    /// this Mac's Keychain), nothing else: no settings or snippets, no last folder on this Mac. Key files in the home
    /// folder are written as ~/…, which ssh finds in the home folder of whoever imports them.
    public static func export(_ data: AirSCPData) throws -> Data {
        var exported = AirSCPData(hosts: data.hosts, groups: data.groups, proxies: data.proxies, rdpEntries: data.rdpEntries)
        for index in exported.hosts.indices {
            exported.hosts[index].keyFile = (exported.hosts[index].keyFile as NSString).abbreviatingWithTildeInPath
            exported.hosts[index].lastLocalDir = nil
        }
        for index in exported.rdpEntries.indices {
            exported.rdpEntries[index].caFile = (exported.rdpEntries[index].caFile as NSString).abbreviatingWithTildeInPath
        }
        struct File: Encodable {
            let hosts: [SSHHost], groups: [HostGroup], proxies: [Proxy], rdpEntries: [RDPEntry]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(File(hosts: exported.hosts, groups: exported.groups, proxies: exported.proxies,
                                       rdpEntries: exported.rdpEntries))
    }

    /// The hosts, groups, proxies and Remote Desktop entries in an exported file (merge them with `AirSCPData.merge`).
    public static func importHosts(from data: Data) throws -> AirSCPData {
        let imported = try JSONDecoder().decode(AirSCPData.self, from: data)
        return AirSCPData(hosts: imported.hosts, groups: imported.groups, proxies: imported.proxies,
                          rdpEntries: imported.rdpEntries)
    }

    private static func encoded(_ data: AirSCPData) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(data)
    }
}
