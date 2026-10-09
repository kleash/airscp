import AirSCPCore
import AppIntents
import AppKit

// AirSCP's actions in Shortcuts, Siri and Spotlight (PLAN.md AD): the same code the menus and agent control run, no
// second implementation. Intents run in the app (it opens when needed). Their metadata is made by Xcode's App Intents
// processor (build.sh runs it when Xcode is installed); a build with the Command Line Tools alone has the code but
// Shortcuts doesn't list it.

/// The running app's delegate: intents act through it.
@MainActor
private var app: AppDelegate? { NSApp.delegate as? AppDelegate }

/// The saved hosts and desktops: the app's, else airscp.json (an intent can ask before the app has started).
@MainActor
private var savedData: AirSCPData { app?.model?.data ?? Store.load() }

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

struct ConnectHostIntent: AppIntent {
    static let title: LocalizedStringResource = "Connect to Host"
    static let description = IntentDescription("Opens AirSCP and connects to a saved host, showing its files.")
    static let openAppWhenRun = true

    @Parameter(title: "Host") var host: HostEntity

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let app, app.model.host(host.id) != nil else { throw AirSCPError(.other, "AirSCP has no host “\(host.name)” any more.") }
        app.main.open(host.id)
        return .result(dialog: "Connecting to \(host.name).")
    }
}

struct OpenTerminalTabIntent: AppIntent {
    static let title: LocalizedStringResource = "Open a Shell on Host"
    static let description = IntentDescription("Connects to a saved host and shows its Terminal tab in AirSCP.")
    static let openAppWhenRun = true

    @Parameter(title: "Host") var host: HostEntity

    @MainActor func perform() async throws -> some IntentResult {
        guard let app, app.model.host(host.id) != nil else { throw AirSCPError(.other, "AirSCP has no host “\(host.name)” any more.") }
        app.main.open(host.id) { $0.showTerminal() }
        return .result()
    }
}

struct OpenDesktopIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Remote Desktop"
    static let description = IntentDescription("Opens AirSCP and connects to a saved Windows desktop.")
    static let openAppWhenRun = true

    @Parameter(title: "Remote Desktop") var desktop: DesktopEntity

    @MainActor func perform() async throws -> some IntentResult {
        guard let app, app.model.rdpEntry(desktop.id) != nil else { throw AirSCPError(.other, "AirSCP has no desktop “\(desktop.name)” any more.") }
        app.main.connectDesktop(desktop.id)
        return .result()
    }
}

struct DisconnectAllIntent: AppIntent {
    static let title: LocalizedStringResource = "Disconnect All"
    static let description = IntentDescription("Disconnects every host and desktop AirSCP is connected to (it asks first while Windows copies files).")

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let app else { return .result(dialog: "AirSCP isn't running: nothing is connected.") }
        let connected = app.model.connected
        connected.forEach { app.main.disconnect($0) }
        return .result(dialog: connected.isEmpty ? "Nothing was connected." : "Disconnected \(connected.count) connection\(connected.count == 1 ? "" : "s").")
    }
}

struct TransferStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Transfer Status"
    static let description = IntentDescription("Says how AirSCP's transfers are going: how many run, wait, finished or failed.")

    @MainActor func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let jobs = TransferCenter.shared.jobs
        let text = jobs.isEmpty ? "No transfers." : TransferText.summary(jobs)
        return .result(value: text, dialog: "\(text)")
    }
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
        AppShortcut(intent: DisconnectAllIntent(), phrases: ["Disconnect all in \(.applicationName)"],
                    shortTitle: "Disconnect All", systemImageName: "eject")
        AppShortcut(intent: TransferStatusIntent(), phrases: ["How are my \(.applicationName) transfers"],
                    shortTitle: "Transfer Status", systemImageName: "arrow.up.arrow.down")
    }
}
