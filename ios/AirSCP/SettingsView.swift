import AirSCPSSH2
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var trusted = KnownHosts.entries(knownHostsPath)
    @State private var failure: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if trusted.isEmpty {
                        Text("None yet").foregroundStyle(.secondary)
                    }
                    ForEach(trusted) { entry in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.host)
                            Text("\(entry.type)  \(entry.fingerprint)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .onDelete(perform: forget)
                } header: {
                    Text("Trusted servers")
                } footer: {
                    Text("AirSCP asks before it trusts a server the first time. Remove one to be asked again.")
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                Button("Done", systemImage: "checkmark") { dismiss() }
                    .help("Close settings")
            }
            .alert("Can't remove the server", isPresented: .constant(failure != nil)) {
                Button("OK") { failure = nil }
            } message: {
                Text(failure ?? "")
            }
        }
    }

    private func forget(_ offsets: IndexSet) {
        do {
            for entry in offsets.map({ trusted[$0] }) { try KnownHosts.forget(entry, in: knownHostsPath) }
        } catch {
            failure = error.localizedDescription
        }
        trusted = KnownHosts.entries(knownHostsPath)
    }
}
