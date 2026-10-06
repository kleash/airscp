import AirSCPCore
import SwiftUI

/// A host's saved port forwards (its workspace's Tunnels tab): add, edit, remove, and switch them on and off over the
/// master connection (ssh -O forward / -O cancel). AirSCP keeps the on/off state; all go off when the connection ends
/// (an automatic reconnect switches them on again).
@MainActor
final class TunnelsModel: ObservableObject {
    @Published private(set) var active: Set<UUID> = []
    /// Being switched on or off.
    @Published private(set) var switching: Set<UUID> = []
    /// Why switching failed (e.g. the port is in use), shown under the tunnel.
    @Published private(set) var errors: [UUID: AirSCPError] = [:]
    let connection: HostConnection
    let model: AppModel

    init(connection: HostConnection, model: AppModel) {
        self.connection = connection
        self.model = model
        refresh()
    }

    var tunnels: [Tunnel] { model.host(connection.hostID)?.tunnels ?? [] }

    /// The host's name, as the routes and the editor's sentences say it.
    var server: String { model.host(connection.hostID)?.displayName ?? "the server" }

    func refresh() {
        active = connection.session.state == .connected ? connection.session.activeTunnels : []
    }

    func set(_ tunnel: Tunnel, on: Bool) {
        guard !switching.contains(tunnel.id) else { return }
        switching.insert(tunnel.id)
        errors[tunnel.id] = nil
        let session = connection.session
        Task {
            do {
                if on { try await session.startTunnel(tunnel) } else { try await session.stopTunnel(tunnel) }
            } catch {
                errors[tunnel.id] = error as? AirSCPError ?? AirSCPError(.other, error.localizedDescription)
            }
            switching.remove(tunnel.id)
            refresh()
        }
    }

    /// Adds the tunnel, or replaces the saved one with its id.
    func save(_ tunnel: Tunnel) {
        model.updateHost(connection.hostID) { host in
            if let index = host.tunnels.firstIndex(where: { $0.id == tunnel.id }) {
                host.tunnels[index] = tunnel
            } else {
                host.tunnels.append(tunnel)
            }
        }
    }

    /// Removes the tunnel, switching it off first.
    func remove(_ tunnel: Tunnel) {
        if active.contains(tunnel.id) { set(tunnel, on: false) }
        errors[tunnel.id] = nil
        model.updateHost(connection.hostID) { $0.tunnels.removeAll { $0.id == tunnel.id } }
    }

    /// The route in the editor's words: "localhost:8080 on this Mac → web → localhost:80 on web (the server itself)",
    /// "localhost:9000 on web → this Mac → localhost:3000 on this Mac". The list's row, its switch's name (VoiceOver,
    /// agents) and the editor's preview, where a port or host not typed yet is "…".
    nonisolated static func title(_ tunnel: Tunnel, server: String) -> String {
        func port(_ port: Int) -> String { (1...65535).contains(port) ? String(port) : "…" }
        let host = tunnel.targetHost.isEmpty ? "…" : tunnel.targetHost.contains(":") ? "[\(tunnel.targetHost)]" : tunnel.targetHost
        let target = host + ":" + port(tunnel.targetPort), itself = isItself(tunnel.targetHost)
        switch tunnel.kind {
        case .local:
            return "localhost:\(port(tunnel.listenPort)) on this Mac → \(server) → \(target)"
                + (itself ? " on \(server) (the server itself)" : "")
        case .remote:
            return "localhost:\(port(tunnel.listenPort)) on \(server) → this Mac → \(target)" + (itself ? " on this Mac" : "")
        case .dynamic:
            return "localhost:\(port(tunnel.listenPort)) on this Mac (SOCKS proxy) → \(server) → any address \(server) can reach"
        }
    }

    /// Whether the host to reach is the far end itself (ssh looks it up there): the server for Local, this Mac for
    /// Remote.
    nonisolated static func isItself(_ host: String) -> Bool {
        ["localhost", "127.0.0.1", "::1"].contains(host.lowercased())
    }

    /// What such a tunnel is for, and ssh's name for it.
    nonisolated static func explanation(_ kind: Tunnel.Kind) -> String {
        switch kind {
        case .local: return "For example: open the server's web admin page, or a database only the server can reach, on your Mac (ssh -L)."
        case .remote: return "For example: let the server reach a dev server that runs on your Mac (ssh -R)."
        case .dynamic: return "For example: set it as your browser's SOCKS proxy to browse as if you were on the server (ssh -D)."
        }
    }

    /// What is wrong with a tunnel being edited, or nil. `typed`: something was typed in a port field yet.
    nonisolated static func validationError(_ tunnel: Tunnel, typed: Bool = true) -> String? {
        let ports = 1...65535
        if !typed { return "Enter the port to open." }
        if !ports.contains(tunnel.listenPort) { return "The port must be a number from 1 to 65535." }
        // As Session.startTunnel refuses it: this Mac's end listens on its loopback, root only below 1024.
        if tunnel.kind != .remote && tunnel.listenPort < 1024 { return "Choose 1024 or higher: lower ports need administrator rights." }
        if tunnel.kind == .dynamic { return nil }
        if tunnel.targetHost.isEmpty || tunnel.targetHost.contains(where: { $0.isWhitespace }) {
            return "Enter the other machine's name or address."
        }
        if !ports.contains(tunnel.targetPort) { return "The port to reach must be a number from 1 to 65535." }
        return nil
    }
}

/// The Tunnels tab of a host's workspace.
struct TunnelsView: View {
    @ObservedObject var tunnels: TunnelsModel
    @ObservedObject var connection: HostConnection
    /// The saved tunnels are in the model: redraw when they change.
    @ObservedObject var app: AppModel
    @State private var editing: Tunnel?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(connection.state == .connected
                 ? "A tunnel opens a port on this Mac (or on the server) that reaches the other side through this "
                    + "connection. Switch one on to open its port."
                 : "Connect to switch tunnels on.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List {
                ForEach(tunnels.tunnels) { tunnel in row(tunnel) }
                if tunnels.tunnels.isEmpty {
                    Text("No tunnels yet. A tunnel opens a port on this Mac that reaches something the server can reach (a "
                         + "database, an internal site), or the other way round.")
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .washed()
            .card(EdgeInsets())
            HStack {
                Button("Add Tunnel…") { editing = Tunnel(kind: .local, listenPort: 0) }
                    .help("Add a port forward: local, remote or a SOCKS proxy")
                Spacer()
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $editing) { tunnel in
            TunnelEditor(tunnel: tunnel, server: tunnels.server, save: { saved in
                tunnels.save(saved)
                editing = nil
            }, cancel: { editing = nil })
        }
        .onChange(of: connection.state) { _ in tunnels.refresh() }
    }

    private func row(_ tunnel: Tunnel) -> some View {
        let on = tunnels.active.contains(tunnel.id), title = TunnelsModel.title(tunnel, server: tunnels.server)
        return HStack(alignment: .top) {
            // Named after the tunnel (the label is hidden): VoiceOver and agents tell the switches apart.
            Toggle(title, isOn: Binding(get: { on }, set: { tunnels.set(tunnel, on: $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(connection.state != .connected || tunnels.switching.contains(tunnel.id))
                .help(connection.state != .connected ? "Connect the host first to switch tunnels on"
                      : "Open or close this port; tunnels close when the connection ends")
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let error = tunnels.errors[tunnel.id] {
                    Text(error.message).font(.caption).foregroundColor(.red).help(error.details)
                }
            }
            Spacer()
            // Named after their tunnel too (VoiceOver, agents): each row has its own.
            Button("Edit…") { editing = tunnel }
                .disabled(on)
                .help(on ? "Switch it off to edit it" : "Change the ports or where it leads")
                .accessibilityLabel("Edit \(title)")
            Button("Remove") { tunnels.remove(tunnel) }
                .help("Forget this tunnel (switches it off first)")
                .accessibilityLabel("Remove \(title)")
        }
    }
}

/// Add Tunnel… and Edit…: the tunnel as a sentence ("Open port 8080 on this Mac → through web → to the server itself,
/// port 80") and its route under it, as the list will show it. It saves the same `Tunnel` (ssh's -L, -R or -D).
struct TunnelEditor: View {
    /// The host's name.
    let server: String
    let save: (Tunnel) -> Void
    let cancel: () -> Void
    @State private var tunnel: Tunnel
    @State private var listenPort: String
    @State private var targetPort: String
    /// Connections go to the far end itself ("localhost" there: the server for Local, this Mac for Remote), else to
    /// the machine typed in.
    @State private var toItself: Bool
    /// The port to reach is the port to open until it is typed in (a new tunnel's).
    @State private var samePort: Bool
    /// Add Tunnel… (no port yet), else Edit….
    private let isNew: Bool

    init(tunnel: Tunnel, server: String, save: @escaping (Tunnel) -> Void, cancel: @escaping () -> Void) {
        self.server = server
        self.save = save
        self.cancel = cancel
        isNew = tunnel.listenPort == 0
        _tunnel = State(initialValue: tunnel)
        _listenPort = State(initialValue: tunnel.listenPort == 0 ? "" : String(tunnel.listenPort))
        _targetPort = State(initialValue: tunnel.targetPort == 0 ? "" : String(tunnel.targetPort))
        _toItself = State(initialValue: TunnelsModel.isItself(tunnel.targetHost))
        _samePort = State(initialValue: isNew)
    }

    /// "Enter the port to open." until a port is typed, then what is wrong.
    private var problem: String? {
        TunnelsModel.validationError(edited, typed: !(listenPort + targetPort).trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var edited: Tunnel {
        var edited = tunnel
        edited.listenPort = Int(listenPort.trimmingCharacters(in: .whitespaces)) ?? 0
        edited.targetPort = Int(reachPort.wrappedValue.trimmingCharacters(in: .whitespaces)) ?? 0
        edited.targetHost = tunnel.targetHost.trimmingCharacters(in: .whitespaces)
        return edited
    }

    /// The port to reach: the port to open until it is typed in (a SOCKS proxy has none).
    private var reachPort: Binding<String> {
        Binding(get: { samePort && tunnel.kind != .dynamic ? listenPort : targetPort }, set: {
            targetPort = $0
            samePort = false
        })
    }

    /// The far end itself is "localhost"; another machine starts with an empty field.
    private var destination: Binding<Bool> {
        Binding(get: { toItself }, set: { itself in
            guard itself != toItself else { return }
            toItself = itself
            tunnel.targetHost = itself ? "localhost" : ""
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "New Tunnel" : "Edit Tunnel").font(.headline)
            Picker("Type:", selection: $tunnel.kind) {
                Text("Local").tag(Tunnel.Kind.local)
                Text("Remote").tag(Tunnel.Kind.remote)
                Text("SOCKS proxy").tag(Tunnel.Kind.dynamic)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .primaryTint()
            .accessibilityIdentifier("tunnelEditor.type")
            .help("Open a port on this Mac (Local, ssh -L) or on the server (Remote, ssh -R), or a SOCKS proxy (ssh -D)")
            VStack(alignment: .leading, spacing: 10) { sentence }
            route
            HStack {
                HelpButton(.tunnels)
                Text(problem ?? "").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).help("Close without saving")
                Button("Save") { save(edited) }
                    .keyboardShortcut(.defaultAction).primaryTint()
                    .disabled(problem != nil)
                    .help("Save the tunnel; switch it on in the list")
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    /// "Open port [8080] on this Mac → through web → to [The server itself] port [80]"; Remote's and SOCKS's in their
    /// own words.
    @ViewBuilder private var sentence: some View {
        HStack(spacing: 6) {
            Text(tunnel.kind == .dynamic ? "Use port" : "Open port")
            field(tunnel.kind == .remote ? "Port on the server" : "Port on this Mac", $listenPort,
                  prompt: tunnel.kind == .dynamic ? "1080" : "8080")
                .frame(width: 64)
                .accessibilityIdentifier("tunnelEditor.listenPort")
                .help(tunnel.kind == .remote ? "The port to open on \(server); below 1024 needs a root login there"
                      : "The port to open on this Mac: 1024 or higher")
            tunnel.kind == .remote ? Text("on ") + Text(server).bold() : Text("on this Mac")
        }
        switch tunnel.kind {
        case .local:
            step { Text("through ") + Text(server).bold() }
            destinationSteps
        case .remote:
            step { Text("back through the tunnel") }
            destinationSteps
        case .dynamic:
            step { Text("as a SOCKS proxy that browses from ") + Text(server).bold() }
        }
    }

    /// "→ to [The server itself] port [80]"; another machine's name goes on a line of its own, under the menu.
    @ViewBuilder private var destinationSteps: some View {
        let local = tunnel.kind == .local
        step {
            Text("to")
            Picker("To", selection: destination) {
                Text(local ? "The server itself" : "This Mac").tag(true)
                Text(local ? "Another machine the server can reach" : "Another machine this Mac can reach").tag(false)
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("tunnelEditor.destination")
            .help(local ? "Where \(server) sends what arrives: to itself (localhost), or another machine it can reach"
                  : "Where this Mac sends what arrives: to itself (localhost), or another machine it can reach")
            if toItself { portToReach }
        }
        if !toItself {
            step(arrow: false) {
                Text("to").hidden()
                field("Other machine", $tunnel.targetHost, prompt: local ? "10.0.0.5 or db.internal" : "192.168.1.20 or nas.local")
                    .accessibilityIdentifier("tunnelEditor.targetHost")
                    .help(local ? "Its name or address as \(server) knows it: \(server) looks it up, not this Mac"
                          : "Its name or address as this Mac knows it")
                portToReach
            }
        }
    }

    @ViewBuilder private var portToReach: some View {
        Text("port")
        field("Port to reach", reachPort, prompt: "8080")
            .frame(width: 64)
            .accessibilityIdentifier("tunnelEditor.targetPort")
            .help("The port there, e.g. 80 for a web page or 5432 for Postgres; the port to open until you change it")
    }

    /// A field of the sentence, named for VoiceOver and agents (the words around it are its label on screen).
    private func field(_ name: String, _ text: Binding<String>, prompt: String) -> some View {
        TextField(name, text: text, prompt: Text(prompt)).labelsHidden().accessibilityLabel(name)
    }

    /// A line of the sentence after the first: "→ through web".
    private func step<Content: View>(arrow: Bool = true, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 6) {
            Text("→").foregroundColor(.secondary).opacity(arrow ? 1 : 0).accessibilityHidden(true)
            content()
        }
        .padding(.leading, 14)
    }

    /// The route as the list will show it, what such a tunnel is for, and for Remote who else can use the server's port.
    private var route: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(TunnelsModel.title(edited, server: server))
                .fixedSize(horizontal: false, vertical: true)
            Text(TunnelsModel.explanation(tunnel.kind))
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if tunnel.kind == .remote {
                Text("Other machines reach this port on \(server) only if its SSH server allows it (GatewayPorts).")
                    .font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }
}
