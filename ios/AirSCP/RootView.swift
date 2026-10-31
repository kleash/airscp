import AirSCPCore
import SwiftUI

/// The four places, and Search (on iOS 26 a round button of its own at the end of the glass tab bar).
enum Place: String {
    case servers, files, terminal, transfers, search
}

struct RootView: View {
    // The place each window was in comes back when iOS restores it (and when the Duo folds or opens).
    @SceneStorage("place") private var place = Place.servers
    @State private var app = AppState()
    @State private var terminals = Terminals()

    var body: some View {
        TabView(selection: $place) {
            Tab("Servers", systemImage: "server.rack", value: .servers) {
                ServersView()
            }
            Tab("Files", systemImage: "folder", value: .files) {
                NothingOpen(title: "No server open", systemImage: "folder",
                            description: "Open a server in Servers to browse its files.") { place = .servers }
            }
            Tab("Terminal", systemImage: "apple.terminal", value: .terminal) {
                TerminalTab { place = .servers }
            }
            Tab("Transfers", systemImage: "arrow.up.arrow.down", value: .transfers) {
                ContentUnavailableView("No transfers", systemImage: "arrow.up.arrow.down",
                                       description: Text("Files you send or download show here with their progress."))
            }
            Tab(value: .search, role: .search) {
                SearchView { host in
                    place = .servers
                    if host.s3 == nil { app.connect(host) }  // S3 storage doesn't open here yet: Servers says so when it is tapped
                } run: { command, session in
                    terminals.run(command, on: session)
                    place = .terminal
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .environment(app)
        .environment(terminals)
        // A connection's question (Trust, password, passphrase, code), whichever tab is showing.
        .sheet(item: Binding(get: { app.questions.first }, set: { if $0 == nil, let first = app.questions.first { app.answer(first, nil) } })) {
            QuestionSheet(question: $0).environment(app)
        }
        .alert("Can't connect", isPresented: Binding(get: { app.failure != nil }, set: { if !$0 { app.failure = nil } }),
               presenting: app.failure) { _ in
            Button("OK") {}
        } message: { failure in
            Text(failure.message)
        }
        .tint(.teal)  // after the sheet and alert, so they get it too
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
