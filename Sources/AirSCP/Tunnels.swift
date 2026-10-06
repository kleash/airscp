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

    /// "Local 8080 → db:5432", "Remote 9000 → localhost:3000", "SOCKS proxy on port 1080".
    nonisolated static func title(_ tunnel: Tunnel) -> String {
        switch tunnel.kind {
        case .local: return "Local \(tunnel.listenPort) → \(tunnel.targetHost):\(tunnel.targetPort)"
        case .remote: return "Remote \(tunnel.listenPort) → \(tunnel.targetHost):\(tunnel.targetPort)"
        case .dynamic: return "SOCKS proxy on port \(tunnel.listenPort)"
        }
    }

    nonisolated static func explanation(_ kind: Tunnel.Kind) -> String {
        switch kind {
        case .local: return "A port on this Mac that reaches a host and port as the server sees them (ssh -L)."
        case .remote: return "A port on the server that reaches a host and port as this Mac sees them (ssh -R)."
        case .dynamic: return "A SOCKS proxy on this Mac: apps set to use it reach what the server can reach (ssh -D)."
        }
    }

    /// What is wrong with a tunnel being edited, or nil. `typed`: something was typed in a port field yet.
    nonisolated static func validationError(_ tunnel: Tunnel, typed: Bool = true) -> String? {
        let ports = 1...65535
        if !typed { return "Enter the port to open." }
        if !ports.contains(tunnel.listenPort) { return "The port must be a number from 1 to 65535." }
        if tunnel.kind == .dynamic { return nil }
        if tunnel.targetHost.isEmpty || tunnel.targetHost.contains(where: { $0.isWhitespace }) { return "Enter the host to reach." }
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
            TunnelEditor(tunnel: tunnel, save: { saved in
                tunnels.save(saved)
                editing = nil
            }, cancel: { editing = nil })
        }
        .onChange(of: connection.state) { _ in tunnels.refresh() }
    }

    private func row(_ tunnel: Tunnel) -> some View {
        let on = tunnels.active.contains(tunnel.id)
        return HStack(alignment: .top) {
            // Named after the tunnel (the label is hidden): VoiceOver and agents tell the switches apart.
            Toggle(TunnelsModel.title(tunnel), isOn: Binding(get: { on }, set: { tunnels.set(tunnel, on: $0) }))
                .toggleStyle(.switch)
                .labelsHidden()
                .disabled(connection.state != .connected || tunnels.switching.contains(tunnel.id))
                .help(connection.state != .connected ? "Connect the host first to switch tunnels on"
                      : "Open or close this port; tunnels close when the connection ends")
            VStack(alignment: .leading, spacing: 2) {
                Text(TunnelsModel.title(tunnel))
                if let error = tunnels.errors[tunnel.id] {
                    Text(error.message).font(.caption).foregroundColor(.red).help(error.details)
                }
            }
            Spacer()
            // Named after their tunnel too (VoiceOver, agents): each row has its own.
            Button("Edit…") { editing = tunnel }
                .disabled(on)
                .help(on ? "Switch it off to edit it" : "Change the ports or the host it reaches")
                .accessibilityLabel("Edit \(TunnelsModel.title(tunnel))")
            Button("Remove") { tunnels.remove(tunnel) }
                .help("Forget this tunnel (switches it off first)")
                .accessibilityLabel("Remove \(TunnelsModel.title(tunnel))")
        }
    }
}

struct TunnelEditor: View {
    let save: (Tunnel) -> Void
    let cancel: () -> Void
    @State private var tunnel: Tunnel
    @State private var listenPort: String
    @State private var targetPort: String
    /// Add Tunnel… (no port yet), else Edit….
    private let isNew: Bool

    init(tunnel: Tunnel, save: @escaping (Tunnel) -> Void, cancel: @escaping () -> Void) {
        self.save = save
        self.cancel = cancel
        isNew = tunnel.listenPort == 0
        _tunnel = State(initialValue: tunnel)
        _listenPort = State(initialValue: tunnel.listenPort == 0 ? "" : String(tunnel.listenPort))
        _targetPort = State(initialValue: tunnel.targetPort == 0 ? "" : String(tunnel.targetPort))
    }

    /// "Enter the port to open." until a port is typed, then what is wrong.
    private var problem: String? {
        TunnelsModel.validationError(edited, typed: !(listenPort + targetPort).trimmingCharacters(in: .whitespaces).isEmpty)
    }

    private var edited: Tunnel {
        var edited = tunnel
        edited.listenPort = Int(listenPort.trimmingCharacters(in: .whitespaces)) ?? 0
        edited.targetPort = Int(targetPort.trimmingCharacters(in: .whitespaces)) ?? 0
        edited.targetHost = tunnel.targetHost.trimmingCharacters(in: .whitespaces)
        return edited
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? "New Tunnel" : "Edit Tunnel").font(.headline)
            Text("A port forwarded through this host's connection. Switch it on in the list.")
                .font(.callout).foregroundColor(.secondary)
            Form {
                Picker("Type:", selection: $tunnel.kind) {
                    Text("Local").tag(Tunnel.Kind.local)
                    Text("Remote").tag(Tunnel.Kind.remote)
                    Text("SOCKS proxy").tag(Tunnel.Kind.dynamic)
                }
                .pickerStyle(.segmented)
                .primaryTint()
                .accessibilityIdentifier("tunnelEditor.type")
                .help("Local: a Mac port reaches something the server can reach. Remote: a server port reaches something "
                      + "this Mac can reach. SOCKS proxy: a proxy for apps")
                Text(TunnelsModel.explanation(tunnel.kind))
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField(tunnel.kind == .remote ? "Port on the server:" : "Port on this Mac:", text: $listenPort,
                          prompt: Text("8080"))
                    .accessibilityIdentifier("tunnelEditor.listenPort")
                    .help("The port to open; 1024 and above needs no administrator rights")
                Text("Example: 8080. Ports below 1024 need root.").font(.caption).foregroundColor(.secondary)
                if tunnel.kind != .dynamic {
                    TextField("Reach host:", text: $tunnel.targetHost, prompt: Text("localhost")).accessibilityIdentifier("tunnelEditor.targetHost")
                        .help("The host to reach, as seen from the other side; localhost is the server or this Mac itself")
                    TextField("Reach port:", text: $targetPort, prompt: Text("80")).accessibilityIdentifier("tunnelEditor.targetPort")
                        .help("The port on that host, e.g. 5432 for Postgres, 80 for a web server")
                }
            }
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
        .frame(width: 440)
    }
}
