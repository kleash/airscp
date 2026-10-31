import AirSCPCore
import SwiftUI

/// The four places, Search (on iOS 26 a round button of its own at the end of the glass tab bar), and each open server's
/// workspace, which the sidebar of a regular or wide window lists.
enum Place: Hashable, RawRepresentable {
    case servers, files, terminal, transfers, search
    case server(UUID)

    init?(rawValue: String) {
        guard let place = [Place.servers, .files, .terminal, .transfers, .search].first(where: { $0.rawValue == rawValue })
                ?? UUID(uuidString: rawValue).map(Place.server) else { return nil }
        self = place
    }

    var rawValue: String {
        switch self {
        case .servers: "servers"
        case .files: "files"
        case .terminal: "terminal"
        case .transfers: "transfers"
        case .search: "search"
        case .server(let id): id.uuidString
        }
    }
}

/// The window: tabs on an iPhone; on a regular or wide window (an iPad, the Duo open) the same tabs as a sidebar that
/// also lists the open servers, each with its workspace. The layout follows the window's width, not the device, so
/// Split View, Stage Manager and the Duo's fold come out right; what it shows lives in models, not in the layout.
struct RootView: View {
    // The place each window was in comes back when iOS restores it (and when the Duo folds or opens).
    @SceneStorage("place") private var place = Place.servers
    @State private var app = AppState()
    @State private var terminals = Terminals()
    /// The Files tab's two sides.
    @State private var files = FilesModel()
    @State private var wide = false

    var body: some View {
        tabs
            .tabViewStyle(.sidebarAdaptable)
            .tabBarMinimizeBehavior(.onScrollDown)
            .transfersAccessory { place = .transfers }
            .traySheet(app.tray)
            .onGeometryChange(for: Bool.self) { $0.size.width >= 1100 } action: { wide = $0 }
            .environment(\.wide, wide)
            // The menu bar's shortcuts (AppCommands) act on this window.
            .focusedSceneValue(\.go, go)
            .focusedSceneValue(\.newTerminal, terminalServer.map { session in { newTerminal(on: session) } })
            // A server closed while its workspace shows (or restored from before: its connection isn't): Servers instead.
            .onChange(of: app.open.map(\.host.id), initial: true) { _, open in
                if case .server(let id) = place, !open.contains(id) { place = .servers }
            }
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
            // A terminal's, in its tab or a workspace's drawer.
            .alert("Can't open a shell", isPresented: Binding(get: { terminals.failure != nil }, set: { if !$0 { terminals.failure = nil } }),
                   presenting: terminals.failure) { _ in
                Button("OK") {}
            } message: { failure in
                Text(failure.message)
            }
            .tint(.teal)  // after the sheet and alerts, so they get it too
    }

    private var tabs: some View {
        TabView(selection: $place) {
            Tab("Servers", systemImage: "server.rack", value: .servers) {
                ServersView()
            }
            Tab("Files", systemImage: "folder", value: .files) {
                FilesView(model: files) { place = .servers }
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
                    if host.s3 == nil { app.connect(host) }  // S3 storage doesn't open here yet: Servers says so when it is tapped
                } run: { command, session in
                    terminals.run(command, on: session)
                    place = .terminal
                }
            }
            openServers
        }
    }

    /// Each open server's workspace, in the sidebar.
    private var openServers: some TabContent<Place> {
        TabSection("Open") {
            ForEach(app.open, id: \.host.id) { session in
                Tab(app.data.hosts.first { $0.id == session.host.id }?.displayName ?? session.host.displayName,
                    systemImage: "server.rack", value: Place.server(session.host.id)) {
                    WorkspaceView(session: session)
                }
                .accessibilityIdentifier("workspace")
                .contextMenu {
                    Button("Disconnect", systemImage: "xmark.circle") { app.disconnect(session) }
                        .help("Close the connection to this server")
                }
            }
        }
        .defaultVisibility(.hidden, for: .tabBar)  // the sidebar's: an iPhone's tabs stay as they are
    }

    private func go(_ place: Place) {
        self.place = place
    }

    /// The server ⌘T opens a terminal on: the workspace's, else the shown terminal's, else the newest open one; nil
    /// while none runs commands.
    private var terminalServer: Session? {
        let shells = app.open.filter { app.states[$0.host.id] == .connected && $0.capabilities.shell }
        if case .server(let id) = place { return shells.first { $0.host.id == id } }
        return shells.first { $0 === terminals.shown?.session } ?? shells.last
    }

    /// New Terminal (⌘T): shown in the workspace's drawer, else in the Terminal tab.
    private func newTerminal(on session: Session) {
        terminals.shownID = terminals.add(on: session).id
        if case .server = place { return }
        place = .terminal
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
