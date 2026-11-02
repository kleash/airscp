import AirSCPCore
import SwiftUI

/// Search (2f, mockup screen 4): one field over the saved servers, the snippets, every saved server's command history,
/// and the files on an open server (Core's Find Files). A server opens; a snippet or a command runs on an open server,
/// typed in its terminal (as the Mac's Run Command runs a snippet in Terminal).
struct SearchView: View {
    @Environment(AppState.self) private var app
    /// Opens a saved server: connects, and shows Servers.
    let open: (SSHHost) -> Void
    /// Runs a command on an open server, in its terminal (shown).
    let run: (String, Session) -> Void
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var text = ""
    /// Every saved server's history, read each time Search shows.
    @State private var histories: [(host: SSHHost, commands: [String])] = []

    var body: some View {
        let servers = app.data.hosts.filter { $0.displayName.localizedStandardContains(text) || $0.hostname.localizedStandardContains(text) }
        let snippets = app.data.snippets.filter { $0.name.localizedStandardContains(text) || $0.command.localizedStandardContains(text) }
        let commands = histories.flatMap { history in
            history.commands.filter { $0.localizedStandardContains(text) }.map { (host: history.host, command: $0) }
        }
        let shells = app.open.filter { $0.state == .connected && $0.capabilities.shell }
        NavigationStack {
            Group {
                if text.isEmpty {
                    ContentUnavailableView("Search", systemImage: "magnifyingglass",
                                           description: Text("Type to find a server, a snippet, a command you ran before, or "
                                                             + "files on an open server."))
                } else if servers.isEmpty && snippets.isEmpty && commands.isEmpty && !app.open.contains(where: { $0.state == .connected }) {
                    ContentUnavailableView.search(text: text)
                } else {
                    List {
                        if !servers.isEmpty {
                            Section("Servers") {
                                ForEach(servers) { host in
                                    Button { open(host) } label: { HostRow(host: host) }
                                        .help("Open this server")
                                }
                            }
                        }
                        if !snippets.isEmpty {
                            Section("Snippets") {
                                ForEach(snippets) { snippet in
                                    row(snippet.name.isEmpty ? snippet.command : snippet.name, detail: snippet.command) {
                                        if snippet.usesPlaceholders {
                                            Image(systemName: "play").foregroundStyle(.tertiary)
                                                .help("Can't run it here: it has {file}, {name}, {files} or {folder}, for "
                                                      + "the files picked in AirSCP on a Mac")
                                        } else {
                                            runOn(snippet.command, shells: shells)
                                        }
                                    }
                                }
                            }
                        }
                        if !commands.isEmpty {
                            Section("History") {
                                ForEach(Array(commands.enumerated()), id: \.offset) { _, found in
                                    row(found.command, detail: found.host.displayName, monospaced: true) {
                                        // The server it ran on first.
                                        runOn(found.command, shells: shells.filter { $0.host.id == found.host.id }
                                                + shells.filter { $0.host.id != found.host.id })
                                    }
                                }
                            }
                        }
                        Section("Files") {
                            ForEach(app.open.filter { $0.state == .connected }, id: \.host.id) { session in
                                NavigationLink("Find “\(text)” in \(session.host.displayName)") {
                                    FoundFiles(session: session, text: text)
                                }
                                .help("List the files and folders on this server whose names hold the text")
                            }
                            if !app.open.contains(where: { $0.state == .connected }) {
                                Text("Open a server to find files on it.").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Search")
        }
        // The iPad would show only a search button in its bar: the field itself, under the title.
        .searchable(text: $text, placement: horizontalSizeClass == .regular ? .navigationBarDrawer(displayMode: .always) : .automatic,
                    prompt: "Servers, snippets, commands, files")
        .textInputAutocapitalization(.never)  // commands and names, not sentences
        .autocorrectionDisabled()
        .onAppear { histories = app.data.hosts.map { (host: $0, commands: CommandHistory(host: $0.id).commands) } }
    }

    private func row<Action: View>(_ title: String, detail: String, monospaced: Bool = false,
                                   @ViewBuilder action: () -> Action) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(monospaced ? .body.monospaced() : .body).lineLimit(2)
                Text(detail).font(monospaced ? .subheadline : .subheadline.monospaced()).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            action()
        }
    }

    /// Run on: the open servers that run commands; the command is typed in the chosen one's terminal.
    private func runOn(_ command: String, shells: [Session]) -> some View {
        Menu("Run on", systemImage: "play") {
            ForEach(shells, id: \.host.id) { session in
                Button(session.host.displayName) { run(command, session) }
                    .help("Run it in this server's terminal")
            }
        }
        .labelStyle(.iconOnly)
        .disabled(shells.isEmpty)
        .help(shells.isEmpty ? "Open a server first: it runs in that server's terminal" : "Run it on an open server, in its terminal")
    }
}

/// Find Files on an open server (Core's `Session.find`): what is below the home folder whose name holds the text. One
/// opens in Files: a folder shown, a file selected in its folder.
struct FoundFiles: View {
    @Environment(WindowRequests.self) private var window
    let session: Session
    let text: String
    @State private var found: [FoundItem]?
    @State private var failure: String?

    var body: some View {
        Group {
            if let failure {
                ContentUnavailableView("Can't search", systemImage: "exclamationmark.triangle", description: Text(failure))
            } else if let found, found.isEmpty {
                ContentUnavailableView.search(text: text)
            } else if let found {
                List(found, id: \.path) { item in
                    Button {
                        window.reveal = AppState.Reveal(hostID: session.host.id, path: item.path, isFolder: item.isFolder)
                    } label: {
                        Label(item.path, systemImage: item.isFolder ? "folder" : "doc").foregroundStyle(Color.primary)
                    }
                    .help(item.isFolder ? "Open this folder in Files" : "Show this file in Files, selected in its folder")
                    .contextMenu {
                        Button("Copy Path", systemImage: "doc.on.doc") { UIPasteboard.general.string = item.path }
                            .help("Copy this path to paste it elsewhere")
                    }
                }
            } else {
                ProgressView("Searching \(session.capabilities.home)…")
            }
        }
        .navigationTitle("“\(text)” in \(session.host.displayName)")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                found = try await session.find("*\(text)*", in: session.capabilities.home).items
            } catch {
                failure = (error as? AirSCPError)?.message ?? error.localizedDescription
            }
        }
    }
}
