import AirSCPCore
import SwiftUI

/// Files gathered while browsing, to carry together to a third place (mockup screen 7): an open server's folder, the
/// Files app or the share sheet (`TraySheet`). Items come from any open server, or from this device.
@Observable final class Tray {
    struct Item: Hashable, Identifiable {
        /// The server it is on; nil: this device.
        let hostID: UUID?
        let path: String
        let isFolder: Bool
        var id: Self { self }
        var name: String { RemotePath.name(path) }
    }

    private(set) var items: [Item] = []

    /// Adds the items that aren't in the tray yet.
    func add(_ new: [Item]) {
        for item in new where !items.contains(item) { items.append(item) }
    }

    func remove(_ gone: [Item]) {
        items.removeAll { gone.contains($0) }
    }
}
