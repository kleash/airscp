import AirSCPCore
import SwiftUI

@main
struct AirSCPApp: App {
    /// What every window shows (an iPad has several): the saved servers, the open connections with their questions and
    /// the tray, and the terminals. What a window shows of them is its own (RootView).
    @State private var app = AppState()
    @State private var terminals = Terminals()

    init() {
        // known_hosts and airscp.json live here; libssh2 writes known_hosts but doesn't make its folder.
        try? FileManager.default.createDirectory(at: Store.directory, withIntermediateDirectories: true)
        // Each file's copy is checked against its original (SHA-256): a transfer ends with "Checksums match".
        TransferCenter.shared.verifyTransfers = true
        // UI tests: transfers slow enough to watch (bytes a second).
        TransferCenter.shared.speedLimit = Int(ProcessInfo.processInfo.environment["AIRSCP_TEST_SPEED_LIMIT"] ?? "")
        BackgroundTransfers.shared.start()
    }

    var body: some Scene {
        // A window that Open in New Window opened for a server has its id (nil once shown, and for the others).
        WindowGroup(for: UUID.self) { $server in
            RootView(server: $server)
                .environment(app)
                .environment(terminals)
        }
        .commands { AppCommands() }
    }
}

/// The trusted servers' keys (`SSH2Transport`'s known_hosts, OpenSSH's format).
let knownHostsPath = Store.directory.appendingPathComponent("known_hosts").path
