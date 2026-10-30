import AirSCPCore
import SwiftUI

@main
struct AirSCPApp: App {
    init() {
        // known_hosts and airscp.json live here; libssh2 writes known_hosts but doesn't make its folder.
        try? FileManager.default.createDirectory(at: Store.directory, withIntermediateDirectories: true)
    }

    var body: some Scene {
        WindowGroup { RootView() }
    }
}

/// The trusted servers' keys (`SSH2Transport`'s known_hosts, OpenSSH's format).
let knownHostsPath = Store.directory.appendingPathComponent("known_hosts").path
