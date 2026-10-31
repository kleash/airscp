import AirSCPCore
import SwiftUI

@main
struct AirSCPApp: App {
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
        WindowGroup { RootView() }
            .commands { AppCommands() }
    }
}

/// The trusted servers' keys (`SSH2Transport`'s known_hosts, OpenSSH's format).
let knownHostsPath = Store.directory.appendingPathComponent("known_hosts").path
