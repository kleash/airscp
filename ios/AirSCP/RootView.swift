import AirSCPCore
import SwiftUI

/// The four places, and Search (on iOS 26 a round button of its own at the end of the glass tab bar).
enum Place: String {
    case servers, files, terminal, transfers, search
}

struct RootView: View {
    // The place each window was in comes back when iOS restores it (and when the Duo folds or opens).
    @SceneStorage("place") private var place = Place.servers
    @State private var hosts = Store.load().hosts

    var body: some View {
        TabView(selection: $place) {
            Tab("Servers", systemImage: "server.rack", value: .servers) {
                ServersView(hosts: hosts)
            }
            Tab("Files", systemImage: "folder", value: .files) {
                NothingOpen(title: "No server open", systemImage: "folder",
                            description: "Open a server in Servers to browse its files.") { place = .servers }
            }
            Tab("Terminal", systemImage: "apple.terminal", value: .terminal) {
                NothingOpen(title: "No terminal open", systemImage: "apple.terminal",
                            description: "Open a server in Servers to type commands on it.") { place = .servers }
            }
            Tab("Transfers", systemImage: "arrow.up.arrow.down", value: .transfers) {
                ContentUnavailableView("No transfers", systemImage: "arrow.up.arrow.down",
                                       description: Text("Files you send or download show here with their progress."))
            }
            Tab(value: .search, role: .search) {
                SearchView(hosts: hosts)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .tint(.teal)
    }
}

/// A tab with nothing to show until a server is open: says so, and goes to Servers.
struct NothingOpen: View {
    let title: String, systemImage: String, description: String
    let goToServers: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        } actions: {
            Button("Go to Servers", action: goToServers)
                .buttonStyle(.glassProminent)
                .help("Show your servers")
        }
    }
}
