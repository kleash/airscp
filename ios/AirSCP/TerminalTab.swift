import AirSCPCore
import SwiftUI

/// The Terminal tab: the shown terminal (`TerminalPane`), a switcher when there are several, New Terminal, and Close
/// Terminal for a server's second one, Disconnect for its last.
struct TerminalTab: View {
    @Environment(AppState.self) private var app
    @Environment(Terminals.self) private var terminals
    @Environment(\.horizontalSizeClass) private var width
    /// The terminal this window shows.
    @Binding var shownID: Terminals.Terminal.ID?
    let goToServers: () -> Void
    @State private var fullWindow = false

    var body: some View {
        NavigationStack {
            Group {
                if let terminal = terminals.shown(shownID) {
                    // Full Window shows it, and one view for a terminal at a time.
                    (fullWindow ? nil : TerminalPane(terminal: terminal))
                        .navigationTitle(terminals.list.count > 1 ? "" : terminals.name(of: terminal))  // else the switcher's
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { toolbar(terminal) }
                } else {
                    NothingOpen(title: "No terminal open", systemImage: "apple.terminal",
                                description: "Open a server in Servers to type commands on it.", goToServers: goToServers)
                }
            }
        }
        .fullWindow($fullWindow, escapeLeaves: false) {
            if let terminal = terminals.shown(shownID) { TerminalPane(terminal: terminal).navigationTitle(terminals.name(of: terminal)) }
        }
    }

    /// At the leading edge: the iPad's tabs take the middle of the bar.
    @ToolbarContentBuilder private func toolbar(_ terminal: Terminals.Terminal) -> some ToolbarContent {
        ToolbarItemGroup(placement: .topBarLeading) {
            if terminals.list.contains(where: { $0 !== terminal && $0.session === terminal.session }) {  // the last one stays
                Button("Close Terminal", systemImage: "xmark") {
                    shownID = terminals.list.first { $0 !== terminal && $0.session === terminal.session }?.id
                    terminals.close(terminal)
                }
                .help("Close this terminal and end its shell")
            } else {
                Button("Disconnect", systemImage: "xmark.circle") { app.disconnect(terminal.session) }
                    .help("Close the connection to this server, and its terminal")
            }
            if terminals.list.count > 1 {
                Picker("Terminal", selection: Binding(get: { terminal.id }, set: { shownID = $0 })) {
                    ForEach(terminals.list) { Text(terminals.name(of: $0)).tag($0.id) }
                }
                .pickerStyle(.menu)
                .help("Show another terminal")
            }
        }
        if width == .regular {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Full Window", systemImage: "arrow.up.left.and.arrow.down.right") { fullWindow = true }
                    .keyboardShortcut(fullWindow ? nil : KeyboardShortcut("f", modifiers: [.command, .shift]))  // then Exit's
                    .help("Give the terminal the whole window (⌘⇧F)")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu("New Terminal", systemImage: "plus") {
                ForEach(app.open.filter { $0.state == .connected && $0.capabilities.shell }, id: \.host.id) { session in
                    Button(session.host.displayName) { shownID = terminals.add(on: session).id }
                        .help("Open another shell on this server")
                }
            }
            .help("Open another shell on an open server")
        }
    }
}

/// One terminal (mockup screens 10 and 11) at any size: its screen, and under it the command line with the server's
/// history as suggestions, then the key bar while the terminal has the keyboard, or the Stop / Return / Type deck.
struct TerminalPane: View {
    @Environment(Terminals.self) private var terminals
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(WindowRequests.self) private var window
    let terminal: Terminals.Terminal
    @State private var command = ""
    @FocusState private var commandFocused: Bool
    @State private var pane = PaneView()

    var body: some View {
        TerminalScreenView(terminals: terminals, terminal: terminal, shell: terminal.shell, pane: pane)
            .id(terminal.id)  // a view of its own for each terminal
            .overlay(alignment: .bottom) { newLines }
            .safeAreaInset(edge: .bottom) { bar }
            .background(Color(TerminalView.ground).ignoresSafeArea())
    }

    /// "N new lines" while scrolled back: back to the newest output.
    @ViewBuilder private var newLines: some View {
        if terminal.newLines > 0 {
            Button(terminal.newLines == 1 ? "1 new line" : "\(terminal.newLines) new lines", systemImage: "arrow.down") {
                terminal.showLive()
            }
            .buttonStyle(.glass)
            .padding(.bottom, 8)
            .help("Scroll down to the newest output")
        }
    }

    private var bar: some View {
        VStack(spacing: 8) {
            // A phone on its side has room above the keyboard for the terminal or the command line, not both.
            let roomy = !(terminal.typing && verticalSizeClass == .compact)
            if commandFocused { suggestions } else if roomy && !terminal.fileLines.isEmpty { fileLines }
            if roomy { commandLine }
            if terminal.typing {
                KeyBar(terminal: terminal)
            } else if !commandFocused {
                ViewThatFits {  // narrow: the icons alone
                    deck.labelStyle(.titleAndIcon)
                    deck.labelStyle(.iconOnly)
                }
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var commandLine: some View {
        HStack {
            TextField("Command", text: $command)
                .focused($commandFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.send)
                .onSubmit(send)
                .font(.body.monospaced())
                .accessibilityIdentifier("commandLine")
                .help("Type a command to run on the server; suggestions come from the commands run there before")
            Button("Run", systemImage: "return", action: send)
                .labelStyle(.iconOnly)
                .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("Run the command in the shell")
        }
        .padding(12)
        .glassEffect()
    }

    /// The commands run on this server before that start with what is typed, newest first.
    @ViewBuilder private var suggestions: some View {
        let matches = terminal.history.commands.filter { $0.hasPrefix(command) && $0 != command }.prefix(5)
        if !matches.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(Array(matches), id: \.self) { match in
                        Button { command = match } label: {
                            Text(match).font(.callout.monospaced()).lineLimit(1).frame(maxWidth: 260)
                        }
                        .buttonStyle(.glass)
                        .accessibilityIdentifier("suggestion")
                        .help("Fill in this command from the server's history")
                    }
                }
            }
            .scrollClipDisabled()
        }
    }

    /// "Open file:line": the files the last command named with a line ("src/main.c:12: error", grep -n), each opening
    /// in the editor at that line.
    private var fileLines: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(Array(terminal.fileLines.enumerated()), id: \.offset) { _, place in
                    Button("\(RemotePath.name(place.path)):\(place.line)", systemImage: "doc.text") {
                        window.reveal = AppState.Reveal(hostID: terminal.session.host.id, path: place.path, line: place.line)
                    }
                    .font(.callout.monospaced())
                    .buttonStyle(.glass)
                    .accessibilityIdentifier("fileLine")
                    .help("Open \(place.path) in the editor at line \(place.line)")
                }
            }
        }
        .scrollClipDisabled()
    }

    /// The keyboard down: Stop, Return and Type, big for the thumb.
    private var deck: some View {
        HStack {
            Button("Stop", systemImage: "stop.fill") { terminals.press(terminal, keyCode: TerminalView.anyKey, characters: "\u{3}") }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .help("Stop the running command (Control-C)")
            Button("Return", systemImage: "return") { terminals.pressReturn(terminal) }
                .buttonStyle(.glass)
                .help("Press Return in the shell; a new shell where it ended")
            Button("Type", systemImage: "keyboard") { _ = pane.view?.becomeFirstResponder() }
                .buttonStyle(.glass)
                .help("Show the keyboard to type in the shell")
        }
        .controlSize(.large)
        .frame(maxWidth: .infinity)
    }

    private func send() {
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        terminals.send(command, to: terminal)
        command = ""
    }
}

/// The keys a phone keyboard lacks, above it while the terminal has it: Escape, Ctrl (for the next key), Tab, the
/// arrows, | ~ / -, and Hide Keyboard.
struct KeyBar: View {
    @Environment(Terminals.self) private var terminals
    @Bindable var terminal: Terminals.Terminal

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    key("esc", code: 53, help: "Press Escape")
                    Toggle("ctrl", isOn: $terminal.ctrl)
                        .toggleStyle(.button)
                        .buttonStyle(.glass)
                        .help("Hold Control for the next key, as for Control-C")
                    key("tab", code: 48, help: "Press Tab: the shell completes the name typed")
                    key("Left", image: "arrow.left", code: 123, help: "Press the left arrow key")
                    key("Up", image: "arrow.up", code: 126, help: "Press the up arrow key: the command before")
                    key("Down", image: "arrow.down", code: 125, help: "Press the down arrow key: the command after")
                    key("Right", image: "arrow.right", code: 124, help: "Press the right arrow key")
                    ForEach(["|", "~", "/", "-"], id: \.self) { character in
                        key(character, code: TerminalView.anyKey, characters: character, help: "Type \(character)")
                    }
                }
                .font(.body.monospaced())
            }
            .scrollClipDisabled()  // the glass keys' light goes past the bar's top and bottom: only its sides cut them
            .mask { Rectangle().padding(.vertical, -16) }
            Button("Hide Keyboard", systemImage: "keyboard.chevron.compact.down") {
                for view in terminal.views.allObjects { _ = view.resignFirstResponder() }  // in every window that shows it
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.glass)
            .help("Hide the keyboard")
        }
        .controlSize(.regular)  // small enough to show most of the keys at once, as a keyboard's own keys
    }

    private func key(_ title: String, image: String? = nil, code: UInt16, characters: String? = nil, help: String) -> some View {
        Button { terminals.press(terminal, keyCode: code, characters: characters) } label: {
            Group {
                if let image { Label(title, systemImage: image).labelStyle(.iconOnly) } else { Text(title) }
            }
            .frame(minWidth: 20, minHeight: 28)
        }
        .buttonStyle(.glass)
        .help(help)
    }
}
