import AirSCPCore
import SwiftUI

/// Open connections on top, saved servers below, and a user@host field that connects without saving.
struct ServersView: View {
    @Environment(AppState.self) private var app
    @State private var showingSettings = false
    @State private var showingNearby = false
    @State private var address = ""
    /// The server in the editor: a new one, a saved one, or a quick connect's to save.
    @State private var editing: SSHHost?

    var body: some View {
        let saved = app.data.hosts.filter { app.session(for: $0.id) == nil }
        NavigationStack {
            Group {
                if app.open.isEmpty && saved.isEmpty {
                    ContentUnavailableView {
                        Label("No servers yet", systemImage: "server.rack")
                    } description: {
                        Text("Add a server to keep it here, or type user@host above to connect without saving.")
                    } actions: {
                        Button("Add Server") { editing = SSHHost() }
                            .buttonStyle(.glassProminent)
                            .help("Add a server to log in to")
                    }
                } else {
                    List {
                        if !app.open.isEmpty {
                            Section("Open") {
                                ForEach(app.open, id: \.host.id) { session in
                                    // As saved now, so a new name shows at once; the connection uses it when it connects again.
                                    let host = app.data.hosts.first { $0.id == session.host.id } ?? session.host
                                    let state = app.states[host.id] ?? .idle
                                    Group {
                                        switch state {
                                        case .connected where host.s3 == nil:
                                            NavigationLink(value: host.id) {
                                                HostRow(host: host, state: state, monitor: app.monitor(for: session))
                                            }
                                            .help("Show this server's CPU, memory, disks and processes")
                                        case .connecting, .connected:
                                            HostRow(host: host, state: state)
                                        default:
                                            Button { app.connect(host) } label: { HostRow(host: host, state: state) }
                                                .help("Connect again")
                                        }
                                    }
                                    .swipeActions { actions(host, open: session) }
                                    .contextMenu { actions(host, open: session) }
                                }
                            }
                        }
                        if !saved.isEmpty {
                            Section("Saved") {
                                ForEach(saved) { host in
                                    Button { app.connect(host) } label: { HostRow(host: host) }
                                        .help(host.s3 == nil ? "Connect to this server" : "Open this storage")
                                        .swipeActions { actions(host, open: nil) }
                                        .contextMenu { actions(host, open: nil) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Servers")
            // A value, not a view: the screen stays while its row changes (connection lost, back again).
            .navigationDestination(for: UUID.self) { MonitorView(hostID: $0) }
            .safeAreaInset(edge: .top) {
                // Connects without saving the server.
                TextField("user@host", text: $address)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.go)
                    .padding(12)
                    .glassEffect()
                    .padding(.horizontal)
                    .accessibilityIdentifier("quickConnect")
                    .accessibilityLabel("Quick connect")
                    .help("Connect without saving: type user@host or user@host:port")
                    .onSubmit {
                        guard let host = AppState.quickHost(address) else {
                            app.failure = AirSCPError(.other, "Type the user and the server: user@host, or user@host:port.")
                            return
                        }
                        app.connect(host)
                        address = ""
                    }
            }
            .toolbar {
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    .help("Show settings: your keys and the servers you trust")
                Button("Nearby", systemImage: "dot.radiowaves.left.and.right") { showingNearby = true }
                    .help("Find servers on this network")
                Button("Add Server", systemImage: "plus") { editing = SSHHost() }
                    .help("Add a server to log in to")
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
            .sheet(isPresented: $showingNearby) {
                NearbyView { host in
                    showingNearby = false
                    editing = host
                }
            }
            .sheet(item: $editing) { host in
                HostEditor(host: host, isNew: !app.data.hosts.contains { $0.id == host.id })
            }
        }
    }

    /// A row's swipe and context menu: an open server disconnects (a quick connect's can be saved), a saved one is
    /// edited or deleted.
    @ViewBuilder private func actions(_ host: SSHHost, open session: Session?) -> some View {
        if let session {
            Button("Disconnect", systemImage: "xmark.circle") { app.disconnect(session) }
                .help("Close the connection to this server")
            if !app.data.hosts.contains(where: { $0.id == host.id }) {
                Button("Save", systemImage: "square.and.arrow.down") { editing = host }
                    .help("Save this server to connect to it again with a tap")
            }
        } else {
            Button("Edit", systemImage: "pencil") { editing = host }
                .help(host.s3 == nil ? "Change this server's name, address or login" : "Change this storage's settings or key")
            Button("Delete", systemImage: "trash", role: .destructive) { app.delete(host) }
                .tint(.red)  // the app's teal tint would colour a swipe button's red too
                .help("Forget this server and its saved password")
        }
    }
}

struct HostRow: View {
    let host: SSHHost
    /// An open connection's state; nil for a server that isn't open.
    var state: Session.State?
    /// A connected server's monitor: its CPU, memory and disk show under its state, read while the row shows.
    var monitor: HostMonitor?
    @Environment(\.scenePhase) private var phase

    var body: some View {
        Label {
            Text(host.displayName)
            if let state {
                status(state)
            } else if !host.label.isEmpty {
                Text(host.s3?.address ?? host.hostname).foregroundStyle(.secondary)
            }
            if let snapshot = monitor?.snapshot { MonitorFigures(snapshot: snapshot) }
        } icon: {
            Image(systemName: host.s3 == nil ? "server.rack" : "externaldrive.connected.to.line.below")
                .foregroundStyle(host.s3 == nil ? .teal : .orange)  // the mockups: teal servers, amber S3
        }
        .foregroundStyle(Color.primary)  // as a button's label too: a row, not a link (.primary would be the tint's)
        .task(id: monitor != nil && phase == .active) {
            if let monitor, phase == .active { await monitor.sample(processes: false) }
        }
    }

    /// A green, amber or red dot for connected, reconnecting or disconnected (with why); a spinner while connecting.
    /// Idle is a connect that failed or was cancelled (the alert said why).
    private func status(_ state: Session.State) -> some View {
        let (color, text): (Color?, String) = switch state {
        case .idle: (.gray, "Not connected")
        case .connecting: (nil, "Connecting…")
        case .connected: (.green, "Connected")
        case .reconnecting: (.orange, "Reconnecting…")
        case .disconnected(let error): (.red, "Disconnected: " + error.message)
        }
        return HStack(spacing: 6) {
            if let color {
                Image(systemName: "circle.fill").imageScale(.small).foregroundStyle(color)
            } else {
                ProgressView().controlSize(.mini)
            }
            Text(text).foregroundStyle(.secondary)
        }
        .font(.subheadline)
    }
}
