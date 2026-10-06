import AirSCPCore
import SwiftUI

/// Import from ~/.ssh/config: its Host aliases (patterns skipped), each shown with what `ssh -G` makes of it. The
/// chosen ones become hosts whose host name is the alias, so ssh keeps applying the config to them (AirSCP never
/// writes the file).
@MainActor
final class ConfigImport: ObservableObject {
    struct Row: Identifiable {
        let alias: String
        /// "user@host:port" from ssh -G (nil until resolved).
        var summary: String?
        /// A host with this name is saved already.
        let added: Bool
        var chosen: Bool
        var id: String { alias }
        /// Why it can't be imported at all, else nil.
        var refused: String? { alias.hasPrefix("-") ? "A name starting with “-” can't be used: ssh would read it as an option" : nil }
    }

    @Published var rows: [Row]

    init(aliases: [String], model: AppModel) {
        rows = aliases.map { alias in
            let added = model.hasHost(named: alias)
            return Row(alias: alias, summary: nil, added: added, chosen: !added && !alias.hasPrefix("-"))
        }
    }

    var chosen: [String] { rows.filter { $0.chosen && !$0.added && $0.refused == nil }.map(\.alias) }

    func resolve() async {
        for index in rows.indices {
            let resolved = await SSHConfig.resolve(SSHHost(hostname: rows[index].alias))
            rows[index].summary = resolved.map(Self.summary) ?? "ssh can't read its settings"
        }
    }

    static func summary(_ resolved: SSHConfig.Resolved) -> String {
        var text = (resolved.user.isEmpty ? "" : resolved.user + "@") + resolved.hostname
            + (resolved.port == 22 ? "" : ":\(resolved.port)")
        if let jump = resolved.proxyJump {
            text += " via " + jump
        } else if resolved.proxyCommand != nil {
            text += " through a proxy command"
        }
        return text
    }
}

struct ConfigImportView: View {
    @ObservedObject var importer: ConfigImport
    let importChosen: ([String]) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from ~/.ssh/config").font(.headline)
            Text("Each chosen alias becomes a host. ssh keeps reading its settings from your config, so later changes "
                 + "there apply in AirSCP too.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List($importer.rows) { $row in
                Toggle(isOn: $row.chosen) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(row.alias)
                        Text(row.added ? "Already in AirSCP" : row.refused ?? row.summary ?? "…")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .disabled(row.added || row.refused != nil)
                .help(row.added ? "A host with this name is in AirSCP already" : row.refused ?? "Import this alias as a host")
            }
            .frame(height: 260)
            HStack {
                HelpButton(.importConfig)
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction).help("Close without importing")
                Button("Import") {
                    importChosen(importer.chosen)
                    close()
                }
                .keyboardShortcut(.defaultAction).primaryTint()
                .disabled(importer.chosen.isEmpty)
                .help(importer.chosen.isEmpty ? "Tick the aliases to import first" : "Save the ticked aliases as hosts")
            }
        }
        .padding(20)
        .frame(width: 460)
        .task { await importer.resolve() }
    }
}
