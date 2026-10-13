import AirSCPCore
import AppIntents
import AppKit
import CoreSpotlight

// AirSCP's actions in Shortcuts, Siri and Spotlight: `AirSCPActions`, the code the menus and Ask
// run, no second implementation. Intents run in the app (it opens when needed). Their metadata is made by Xcode's App Intents
// processor (build.sh runs it when Xcode is installed); a build with the Command Line Tools alone has the code but
// Shortcuts doesn't list it.

/// The saved hosts and desktops: the app's, else airscp.json (an intent can ask before the app has started).
@MainActor
private var savedData: AirSCPData { (NSApp.delegate as? AppDelegate)?.model?.data ?? Store.load() }

struct HostEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Host"
    static let defaultQuery = HostQuery()
    let id: UUID
    let name: String
    let address: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(address)") }

    init(_ host: SSHHost) {
        id = host.id
        name = host.displayName
        address = (host.username.isEmpty ? "" : host.username + "@") + host.hostname
    }
}

struct HostQuery: EntityStringQuery {
    @MainActor func entities(for identifiers: [UUID]) async throws -> [HostEntity] {
        savedData.hosts.filter { identifiers.contains($0.id) }.map(HostEntity.init)
    }

    @MainActor func entities(matching string: String) async throws -> [HostEntity] {
        savedData.hosts.filter { $0.displayName.localizedCaseInsensitiveContains(string) || $0.hostname.localizedCaseInsensitiveContains(string) }
            .map(HostEntity.init)
    }

    @MainActor func suggestedEntities() async throws -> [HostEntity] { savedData.hosts.map(HostEntity.init) }
}

struct DesktopEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Remote Desktop"
    static let defaultQuery = DesktopQuery()
    let id: UUID
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct DesktopQuery: EntityStringQuery {
    @MainActor private func all() -> [DesktopEntity] { savedData.rdpEntries.map { DesktopEntity(id: $0.id, name: $0.displayName) } }
    @MainActor func entities(for identifiers: [UUID]) async throws -> [DesktopEntity] { all().filter { identifiers.contains($0.id) } }
    @MainActor func entities(matching string: String) async throws -> [DesktopEntity] {
        all().filter { $0.name.localizedCaseInsensitiveContains(string) }
    }
    @MainActor func suggestedEntities() async throws -> [DesktopEntity] { all() }
}

struct SnippetEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Snippet"
    static let defaultQuery = SnippetQuery()
    let id: UUID
    let name: String
    let command: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)", subtitle: "\(command)") }
}

struct SnippetQuery: EntityStringQuery {
    @MainActor private func all() -> [SnippetEntity] {
        savedData.snippets.map { SnippetEntity(id: $0.id, name: $0.name, command: $0.command) }
    }
    @MainActor func entities(for identifiers: [UUID]) async throws -> [SnippetEntity] { all().filter { identifiers.contains($0.id) } }
    @MainActor func entities(matching string: String) async throws -> [SnippetEntity] {
        all().filter { $0.name.localizedCaseInsensitiveContains(string) || $0.command.localizedCaseInsensitiveContains(string) }
    }
    @MainActor func suggestedEntities() async throws -> [SnippetEntity] { all() }
}

/// A server folder kept with Go ▸ Add to Favourites; its id is the host's id and the path.
struct FavouriteEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Favourite Folder"
    static let defaultQuery = FavouriteQuery()
    let id: String
    let hostID: UUID
    let path: String
    let hostName: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(path)", subtitle: "\(hostName)") }

    init(host: SSHHost, path: String) {
        id = host.id.uuidString + "|" + path
        hostID = host.id
        self.path = path
        hostName = host.displayName
    }
}

struct FavouriteQuery: EntityStringQuery {
    @MainActor private func all() -> [FavouriteEntity] {
        savedData.hosts.flatMap { host in host.favourites.map { FavouriteEntity(host: host, path: $0) } }
    }
    @MainActor func entities(for identifiers: [String]) async throws -> [FavouriteEntity] { all().filter { identifiers.contains($0.id) } }
    @MainActor func entities(matching string: String) async throws -> [FavouriteEntity] {
        all().filter { $0.path.localizedCaseInsensitiveContains(string) || $0.hostName.localizedCaseInsensitiveContains(string) }
    }
    @MainActor func suggestedEntities() async throws -> [FavouriteEntity] { all() }
}

/// A host's saved tunnel; its id is the host's id and the tunnel's.
struct TunnelEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Tunnel"
    static let defaultQuery = TunnelQuery()
    let id: String
    let hostID: UUID
    let tunnelID: UUID
    let title: String
    let hostName: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)", subtitle: "\(hostName)") }

    init(host: SSHHost, tunnel: Tunnel) {
        id = host.id.uuidString + "|" + tunnel.id.uuidString
        hostID = host.id
        tunnelID = tunnel.id
        title = TunnelsModel.title(tunnel, server: host.displayName)
        hostName = host.displayName
    }
}

struct TunnelQuery: EntityStringQuery {
    @MainActor private func all() -> [TunnelEntity] {
        savedData.hosts.flatMap { host in host.tunnels.map { TunnelEntity(host: host, tunnel: $0) } }
    }
    @MainActor func entities(for identifiers: [String]) async throws -> [TunnelEntity] { all().filter { identifiers.contains($0.id) } }
    @MainActor func entities(matching string: String) async throws -> [TunnelEntity] {
        all().filter { $0.title.localizedCaseInsensitiveContains(string) || $0.hostName.localizedCaseInsensitiveContains(string) }
    }
    @MainActor func suggestedEntities() async throws -> [TunnelEntity] { all() }
}

struct ConnectHostIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect to Host"
    static let description = IntentDescription("Opens AirSCP and connects to a saved host, showing its files.")
    static let openAppWhenRun = true

    @Parameter(title: "Host") var host: HostEntity

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try AirSCPActions.open(host: host.id)
        return .result(dialog: "Connecting to \(host.name).")
    }
}

struct OpenTerminalTabIntent: AppIntent {
    static let title: LocalizedStringResource = "Open a Shell on Host"
    static let description = IntentDescription("Connects to a saved host and shows its Terminal tab in AirSCP.")
    static let openAppWhenRun = true

    @Parameter(title: "Host") var host: HostEntity

    @MainActor func perform() async throws -> some IntentResult {
        try AirSCPActions.open(host: host.id) { $0.showTerminal() }
        return .result()
    }
}

struct OpenDesktopIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Remote Desktop"
    static let description = IntentDescription("Opens AirSCP and connects to a saved Windows desktop.")
    static let openAppWhenRun = true

    @Parameter(title: "Remote Desktop") var desktop: DesktopEntity

    @MainActor func perform() async throws -> some IntentResult {
        try AirSCPActions.openDesktop(desktop.id)
        return .result()
    }
}

struct DisconnectAllIntent: AppIntent {
    static let title: LocalizedStringResource = "Disconnect All"
    static let description = IntentDescription("Disconnects every host and desktop AirSCP is connected to (it asks first while Windows copies files).")

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let count = AirSCPActions.disconnectAll()
        return .result(dialog: count == 0 ? "Nothing was connected." : "Disconnected \(count) connection\(count == 1 ? "" : "s").")
    }
}

struct TransferStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Transfer Status"
    static let description = IntentDescription("Says how AirSCP's transfers are going: how many run, wait, finished or failed.")

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let text = AirSCPActions.transferStatus()
        return .result(value: text, dialog: "\(text)")
    }
}

struct UploadFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Upload Files"
    static let description = IntentDescription("Uploads files and folders from this Mac to a server folder, asking before it replaces anything.")
    static let openAppWhenRun = true

    @Parameter(title: "Files") var files: [IntentFile]
    @Parameter(title: "Host") var host: HostEntity
    @Parameter(title: "Server Folder", description: "Optional: the folder the host's pane shows when empty") var folder: String?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        let (paths, temporary) = try Self.paths(of: files)
        try await AirSCPActions.upload(host: host.id, localPaths: paths, remoteDir: folder, temporary: temporary)
        return .result(dialog: "Uploading to \(host.name).")
    }

    /// The files' paths on this Mac: files Shortcuts hands over as data only are written to a temporary folder first
    /// (`temporary`, removed once they are uploaded).
    static func paths(of files: [IntentFile]) throws -> (paths: [String], temporary: URL?) {
        var temporary: URL?
        let paths = try files.map { file in
            if let url = file.fileURL { return url.path }
            if temporary == nil {
                temporary = FileManager.default.temporaryDirectory.appendingPathComponent("AirSCP-Upload-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: temporary!, withIntermediateDirectories: true)
            }
            // Its name only: "/" or ".." in what Shortcuts hands over would lead out of the folder.
            let name = (file.filename as NSString).lastPathComponent
            let url = temporary!.appendingPathComponent(["", ".", "..", "/"].contains(name) ? "file" : name)
            try file.data.write(to: url)
            return url.path
        }
        return (paths, temporary)
    }
}

struct DownloadFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Download Files"
    static let description = IntentDescription("Downloads files and folders from a server to a folder on this Mac, asking before it replaces anything.")
    static let openAppWhenRun = true

    @Parameter(title: "Host") var host: HostEntity
    @Parameter(title: "Server Paths") var paths: [String]
    @Parameter(title: "Mac Folder", description: "Optional: Settings' download folder when empty") var folder: String?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try await AirSCPActions.download(host: host.id, remotePaths: paths, localDir: folder)
        return .result(dialog: "Downloading from \(host.name).")
    }
}

struct FindFilesIntent: AppIntent {
    static let title: LocalizedStringResource = "Find Files"
    static let description = IntentDescription("Finds files and folders on a server whose names match a pattern (* and ? as in Finder searches), and returns their paths.")
    static let openAppWhenRun = true

    @Parameter(title: "Host") var host: HostEntity
    @Parameter(title: "Folder", default: "~") var folder: String
    @Parameter(title: "Name Pattern", default: "*.log") var pattern: String

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<[String]> & ProvidesDialog {
        let found = try await AirSCPActions.find(host: host.id, folder: folder, pattern: pattern)
        return .result(value: found, dialog: "Found \(found.count) item\(found.count == 1 ? "" : "s").")
    }
}

struct RunSnippetIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Snippet"
    static let description = IntentDescription("Runs a saved snippet on a host and shows its output in AirSCP.")
    static let openAppWhenRun = true

    @Parameter(title: "Snippet") var snippet: SnippetEntity
    @Parameter(title: "Host") var host: HostEntity

    @MainActor func perform() async throws -> some IntentResult {
        try AirSCPActions.runSnippet(snippet.id, host: host.id)
        return .result()
    }
}

struct StartTunnelIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Tunnel"
    static let description = IntentDescription("Switches a host's saved tunnel on, connecting to the host first if needed.")
    static let openAppWhenRun = true

    @Parameter(title: "Tunnel") var tunnel: TunnelEntity

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try await AirSCPActions.setTunnel(host: tunnel.hostID, tunnel: tunnel.tunnelID, on: true)
        return .result(dialog: "On: \(tunnel.title).")
    }
}

struct StopTunnelIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop Tunnel"
    static let description = IntentDescription("Switches a host's saved tunnel off.")
    static let openAppWhenRun = true

    @Parameter(title: "Tunnel") var tunnel: TunnelEntity

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        try await AirSCPActions.setTunnel(host: tunnel.hostID, tunnel: tunnel.tunnelID, on: false)
        return .result(dialog: "Off: \(tunnel.title).")
    }
}

struct OpenFavouriteFolderIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Favourite Folder"
    static let description = IntentDescription("Connects to a host and shows one of its favourite folders.")
    static let openAppWhenRun = true

    @Parameter(title: "Favourite Folder") var favourite: FavouriteEntity

    @MainActor func perform() async throws -> some IntentResult {
        try await AirSCPActions.openFavourite(host: favourite.hostID, path: favourite.path)
        return .result()
    }
}

/// A host chosen in Spotlight: shown and connected.
struct OpenHostIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Host"
    static let isDiscoverable = false
    @Parameter(title: "Host") var target: HostEntity

    @MainActor func perform() async throws -> some IntentResult {
        try AirSCPActions.open(host: target.id)
        return .result()
    }
}

/// A desktop chosen in Spotlight: connected.
struct OpenDesktopEntityIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Desktop"
    static let isDiscoverable = false
    @Parameter(title: "Remote Desktop") var target: DesktopEntity

    @MainActor func perform() async throws -> some IntentResult {
        try AirSCPActions.openDesktop(target.id)
        return .result()
    }
}

// MARK: Spotlight (macOS 15 and later): saved hosts and desktops, found by name

@available(macOS 15, *) extension HostEntity: IndexedEntity {}
@available(macOS 15, *) extension DesktopEntity: IndexedEntity {}

@MainActor
enum SpotlightIndex {
    private static var pending: Task<Void, Never>?

    /// Indexes the saved hosts and desktops (again), a moment after the last change. A throwaway AirSCP
    /// (AIRSCP_SUPPORT_DIR) leaves the user's Spotlight alone unless AIRSCP_SPOTLIGHT=1 (lab.yml's intents job).
    static func update(_ data: AirSCPData) {
        guard #available(macOS 15, *), enabled else { return }
        pending?.cancel()
        let hosts = data.hosts.map(HostEntity.init)
        let desktops = data.rdpEntries.map { DesktopEntity(id: $0.id, name: $0.displayName) }
        pending = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            let index = CSSearchableIndex.default()
            try? await index.deleteAppEntities(ofType: HostEntity.self)
            try? await index.deleteAppEntities(ofType: DesktopEntity.self)
            try? await index.indexAppEntities(hosts)
            try? await index.indexAppEntities(desktops)
        }
    }

    /// Takes a throwaway instance's entries out again, as it quits (waiting up to 2 s for Spotlight).
    nonisolated static func removeThrowaway() {
        guard #available(macOS 15, *), enabled, Env.value("SUPPORT_DIR") != nil else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let index = CSSearchableIndex.default()
            try? await index.deleteAppEntities(ofType: HostEntity.self)
            try? await index.deleteAppEntities(ofType: DesktopEntity.self)
            done.signal()
        }
        _ = done.wait(timeout: .now() + 2)
    }

    nonisolated private static var enabled: Bool { Env.value("SUPPORT_DIR") == nil || Env.value("SPOTLIGHT") == "1" }
}

struct AirSCPShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ConnectHostIntent(), phrases: ["Connect to \(\.$host) with \(.applicationName)",
                                                          "Open \(\.$host) in \(.applicationName)"],
                    shortTitle: "Connect to Host", systemImageName: "server.rack")
        AppShortcut(intent: OpenTerminalTabIntent(), phrases: ["Open a shell on \(\.$host) with \(.applicationName)"],
                    shortTitle: "Shell on Host", systemImageName: "terminal")
        AppShortcut(intent: OpenDesktopIntent(), phrases: ["Open \(\.$desktop) with \(.applicationName)"],
                    shortTitle: "Remote Desktop", systemImageName: "display")
        AppShortcut(intent: UploadFilesIntent(), phrases: ["Upload to \(\.$host) with \(.applicationName)"],
                    shortTitle: "Upload Files", systemImageName: "arrow.up.doc")
        AppShortcut(intent: RunSnippetIntent(), phrases: ["Run \(\.$snippet) with \(.applicationName)"],
                    shortTitle: "Run Snippet", systemImageName: "text.and.command.macwindow")
        AppShortcut(intent: StartTunnelIntent(), phrases: ["Start \(\.$tunnel) with \(.applicationName)"],
                    shortTitle: "Start Tunnel", systemImageName: "point.3.connected.trianglepath.dotted")
        AppShortcut(intent: DisconnectAllIntent(), phrases: ["Disconnect all in \(.applicationName)"],
                    shortTitle: "Disconnect All", systemImageName: "eject")
        AppShortcut(intent: TransferStatusIntent(), phrases: ["How are my \(.applicationName) transfers"],
                    shortTitle: "Transfer Status", systemImageName: "arrow.up.arrow.down")
    }
}
