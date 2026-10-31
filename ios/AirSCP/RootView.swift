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
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TabView(selection: $place) {
            Tab("Servers", systemImage: "server.rack", value: .servers) {
                ServersView()
            }
            Tab("Files", systemImage: "folder", value: .files) {
                FilesView { place = .servers }
            }
            Tab("Terminal", systemImage: "apple.terminal", value: .terminal) {
                TerminalTab { place = .servers }
            }
            Tab("Transfers", systemImage: "arrow.up.arrow.down", value: .transfers) {
                TransfersView()
            }
            Tab(value: .search, role: .search) {
                SearchView { host in
                    place = .servers
                    app.connect(host)
                } run: { command, session in
                    terminals.run(command, on: session)
                    place = .terminal
                }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        // Back in front, each connection checks it is still there (iOS may have let it go in the background): a lost one
        // reconnects by itself, or says why it can't.
        .onChange(of: phase) { if phase == .active { for session in app.open { Task { _ = await session.check() } } } }
        .transfersAccessory { place = .transfers }
        .traySheet(app.tray)
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
