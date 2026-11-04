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

/// A window: tabs on an iPhone; on a regular or wide window (an iPad, the Duo open) the same tabs as a sidebar that
/// also lists the open servers, each with its workspace. The layout follows the window's width, not the device, so
/// Split View, Stage Manager and the Duo's fold come out right; what it shows lives in models, not in the layout. An
/// iPad has several windows: the servers, connections, transfers, tray and terminals are the app's (AirSCPApp), what a
/// window shows of them is its own (here).
struct RootView: View {
    // The place each window was in comes back when iOS restores it (and when the Duo folds or opens).
    @SceneStorage("place") private var place = Place.servers
    @Environment(AppState.self) private var app
    @Environment(Terminals.self) private var terminals
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
    /// The server whose workspace this window opened for (Open in New Window); nil once shown.
    @Binding var server: UUID?
    /// The Files tab's two sides, and each workspace's.
    @State private var files = FilesModel()
    @State private var workspaceFiles = WorkspaceFiles()
    /// The terminal this window shows: in the Terminal tab, and in a workspace's drawer when it is that server's.
    @State private var shownTerminal: Terminals.Terminal.ID?
    @State private var requests = WindowRequests()
    /// The workspace that showed when the window narrowed: the Files tab shows its sides until it widens again.
    @State private var narrowed: UUID?
    /// Whether the open servers' tabs are listed: `showsWorkspaces`, but going a moment later. Gone in the same change as
    /// the tab bar's style while one showed (folding a Duo), UIKit stopped the app; by then the handler below has moved
    /// the window to Files.
    @State private var listsWorkspaces = false
    @Environment(\.horizontalSizeClass) private var widthClass
    @Environment(\.verticalSizeClass) private var heightClass
    @Environment(\.scenePhase) private var phase

    /// An iPad-sized window (an iPad, the Duo open) lists the open servers' workspaces in its sidebar. A phone's tabs
    /// stay as they are: there the workspaces' tabs, even hidden, made a More tab in place of Search.
    private var showsWorkspaces: Bool { widthClass == .regular && heightClass == .regular }

    var body: some View {
        tabs
            .tabViewStyle(.sidebarAdaptable)
            .tabBarMinimizeBehavior(.onScrollDown)
            // Back in front, each connection checks it is still there (iOS may have let it go in the background): a lost
            // one reconnects by itself, or says why it can't.
            .onChange(of: phase) { if phase == .active { for session in app.open { Task { _ = await session.check() } } } }
            .transfersAccessory { place = .transfers }
            .traySheet($requests.tray)
            .modifier(WideWindow())
            // The menu bar's shortcuts (AppCommands) act on this window.
            .focusedSceneValue(\.go, go)
            .focusedSceneValue(\.newTerminal, terminalServer.map { session in { newTerminal(on: session) } })
            // A server closed while its workspace shows (or restored from before: its connection isn't): Servers instead.
            .onChange(of: app.open.map(\.host.id), initial: true) { _, open in
                if case .server(let id) = place, !open.contains(id) { place = .servers }
            }
            // Folded or narrowed: a workspace's files go on in the Files tab; widened again, the workspace is back.
            .onChange(of: showsWorkspaces) { _, shown in
                if !shown, case .server(let id) = place {
                    narrowed = id
                    place = .files
                } else if shown, let id = narrowed {
                    narrowed = nil
                    if place == .files, app.session(for: id) != nil { place = .server(id) }
                }
            }
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
            .environment(requests)
            .tint(.teal)  // after the sheet and alerts, so they get it too
    }

    private var tabs: some View {
        TabView(selection: $place) {
            Tab("Servers", systemImage: "server.rack", value: .servers) {
                ServersView()
            }
            Tab("Files", systemImage: "folder", value: .files) {
                FilesView(model: narrowed.map(workspaceFiles.model) ?? files) { place = .servers }
            }
            Tab("Terminal", systemImage: "apple.terminal", value: .terminal) {
                TerminalTab(shownID: $shownTerminal) { place = .servers }
            }
            Tab("Transfers", systemImage: "arrow.up.arrow.down", value: .transfers) {
                TransfersView()
            }
            // Before Search: after it, an open server's tab made an iPad's Search field let go of every key typed (iOS 27).
            openServers
            Tab(value: .search, role: .search) {
                SearchView { host in
                    place = .servers
                    app.connect(host)
                } run: { command, session in
                    shownTerminal = terminals.run(command, on: session, shown: terminals.shown(shownTerminal)).id
                    place = .terminal
                }
            }
        }
        // Search's or the terminal's file: shown in this window's Files tab (though workspaces have Files views too).
        .onChange(of: requests.reveal) {
            guard let reveal = requests.reveal else { return }
            requests.reveal = nil
            (narrowed.map(workspaceFiles.model) ?? files).show(reveal, app)
            place = .files
        }
        .onChange(of: showsWorkspaces, initial: true) { _, shown in
            if shown { listsWorkspaces = true } else { Task { listsWorkspaces = false } }
        }
        // Opened for a server: its workspace, or on a narrow window its files in the Files tab.
        .onAppear {
            guard let id = server else { return }
            server = nil
            if showsWorkspaces { place = .server(id) } else { (narrowed, place) = (id, .files) }
        }
    }

    /// Each open server's workspace, in the sidebar.
    private var openServers: some TabContent<Place> {
        TabSection("Open") {
            ForEach(listsWorkspaces ? app.open : [], id: \.host.id) { session in
                Tab(app.data.hosts.first { $0.id == session.host.id }?.displayName ?? session.host.displayName,
                    systemImage: "server.rack", value: Place.server(session.host.id)) {
                    WorkspaceView(session: session, files: workspaceFiles.model(session.host.id), shownID: $shownTerminal)
                }
                .accessibilityIdentifier("workspace")
                .contextMenu {
                    if supportsMultipleWindows {
                        Button("Open in New Window", systemImage: "macwindow.badge.plus") { openWindow(value: session.host.id) }
                            .help("Show this server in a window of its own, next to this one")
                    }
                    Button("Disconnect", systemImage: "xmark.circle") { app.disconnect(session) }
                        .help("Close the connection to this server")
                }
            }
        }
        .defaultVisibility(.hidden, for: .tabBar)  // the sidebar's: in an iPad's tabs at the top it paged out Servers
    }

    private func go(_ place: Place) {
        self.place = place
    }

    /// The server ⌘T opens a terminal on: the workspace's, else the shown terminal's, else the newest open one; nil
    /// while none runs commands.
    private var terminalServer: Session? {
        let shells = app.open.filter { app.states[$0.host.id] == .connected && $0.capabilities.shell }
        if case .server(let id) = place { return shells.first { $0.host.id == id } }
        return shells.first { $0 === terminals.shown(shownTerminal)?.session } ?? shells.last
    }

    /// New Terminal (⌘T): shown in the workspace's drawer, else in the Terminal tab.
    private func newTerminal(on session: Session) {
        shownTerminal = terminals.add(on: session).id
        if case .server = place { return }
        place = .terminal
    }
}

/// What a window's views ask of the window (one for each, kept by RootView, which does it).
@Observable final class WindowRequests {
    /// Show a server's file or folder in the Files tab: Search's files found, the terminal's file:line.
    var reveal: AppState.Reveal?
    /// Show the tray's sheet, with the folder each open server shows in Files (Send puts the items there).
    var tray: [UUID: String]?
}

/// `\.wide` for the window's views: 1100 pt or more across. Its own state, not RootView's: RootView's body made again
/// during an iPad's turn left the turn never finishing its animation (XCUITest waited on it in vain).
private struct WideWindow: ViewModifier {
    @State private var wide = false

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: Bool.self) { $0.size.width >= 1100 } action: { wide = $0 }
            .environment(\.wide, wide)
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
