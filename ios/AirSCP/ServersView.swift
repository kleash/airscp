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
                                    Button { connect(host) } label: { HostRow(host: host) }
                                        .help(host.s3 == nil ? "Connect to this server" : "Show why S3 storage can't open here yet")
                                        .swipeActions { actions(host, open: nil) }
                                        .contextMenu { actions(host, open: nil) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Servers")
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
            if host.s3 == nil {  // S3 storage has settings of its own, not this editor's
                Button("Edit", systemImage: "pencil") { editing = host }
                    .help("Change this server's name, address or login")
            }
            Button("Delete", systemImage: "trash", role: .destructive) { app.delete(host) }
                .tint(.red)  // the app's teal tint would colour a swipe button's red too
                .help("Forget this server and its saved password")
        }
    }

    private func connect(_ host: SSHHost) {
        if host.s3 != nil {
            app.failure = AirSCPError(.other, "AirSCP can't open S3 storage on iPhone and iPad yet.")
        } else {
            app.connect(host)
        }
    }
}

struct HostRow: View {
    let host: SSHHost
    /// An open connection's state; nil for a server that isn't open.
    var state: Session.State?

    var body: some View {
        Label {
            Text(host.displayName)
            if let state {
                status(state)
            } else if !host.label.isEmpty {
                Text(host.s3?.address ?? host.hostname).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: host.s3 == nil ? "server.rack" : "externaldrive.connected.to.line.below")
                .foregroundStyle(host.s3 == nil ? .teal : .orange)  // the mockups: teal servers, amber S3
        }
        .foregroundStyle(Color.primary)  // as a button's label too: a row, not a link (.primary would be the tint's)
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

struct SearchView: View {
    let hosts: [SSHHost]
    @State private var text = ""

    private var found: [SSHHost] {
        hosts.filter { $0.displayName.localizedStandardContains(text) || $0.hostname.localizedStandardContains(text) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if text.isEmpty {
                    ContentUnavailableView("Search", systemImage: "magnifyingglass",
                                           description: Text("Type a server's name or address to find it."))
                } else if found.isEmpty {
                    ContentUnavailableView.search(text: text)
                } else {
                    List(found) { HostRow(host: $0) }
                }
            }
            .navigationTitle("Search")
        }
        .searchable(text: $text, prompt: "Servers")
    }
}
