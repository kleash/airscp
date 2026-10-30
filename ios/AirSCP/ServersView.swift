import AirSCPCore
import SwiftUI

struct ServersView: View {
    let hosts: [SSHHost]
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if hosts.isEmpty {
                    ContentUnavailableView("No servers yet", systemImage: "server.rack",
                                           description: Text("Servers you add show here, ready to browse and type on."))
                } else {
                    List(hosts) { HostRow(host: $0) }
                }
            }
            .navigationTitle("Servers")
            .toolbar {
                Button("Settings", systemImage: "gearshape") { showingSettings = true }
                    .help("Show settings: the servers you trust")
            }
            .sheet(isPresented: $showingSettings) { SettingsView() }
        }
    }
}

struct HostRow: View {
    let host: SSHHost

    var body: some View {
        Label {
            Text(host.displayName)
            if !host.label.isEmpty { Text(host.hostname).foregroundStyle(.secondary) }
        } icon: {
            Image(systemName: host.s3 == nil ? "server.rack" : "externaldrive.connected.to.line.below")
                .foregroundStyle(host.s3 == nil ? .teal : .orange)  // the mockups: teal servers, amber S3
        }
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
