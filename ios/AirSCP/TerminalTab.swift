import AirSCPCore
import SwiftUI

/// The Terminal tab (mockup screens 10 and 11): the shown terminal, a switcher when there are several, and under it the
/// command line with the server's history as suggestions, then the key bar while the terminal has the keyboard, or the
/// Stop / Return / Type deck while the keyboard is down.
struct TerminalTab: View {
    @Environment(AppState.self) private var app
    @Environment(Terminals.self) private var terminals
    let goToServers: () -> Void
    @State private var command = ""
    @FocusState private var commandFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let terminal = terminals.shown {
                    TerminalScreenView(terminals: terminals, shell: terminal.shell)
                        .overlay(alignment: .bottom) { newLines }
                        .safeAreaInset(edge: .bottom) { bar(terminal) }
                        .background(Color(TerminalView.ground).ignoresSafeArea())
                        .navigationTitle(terminals.name(of: terminal))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar { toolbar(terminal) }
                } else {
                    NothingOpen(title: "No terminal open", systemImage: "apple.terminal",
                                description: "Open a server in Servers to type commands on it.", goToServers: goToServers)
                }
            }
        }
        .onAppear { terminals.sync(with: app) }
        .onChange(of: app.states) { terminals.sync(with: app) }
        .alert("Can't open a shell", isPresented: Binding(get: { terminals.failure != nil }, set: { if !$0 { terminals.failure = nil } }),
               presenting: terminals.failure) { _ in
            Button("OK") {}
        } message: { failure in
            Text(failure.message)
        }
    }

    @ToolbarContentBuilder private func toolbar(_ terminal: Terminals.Terminal) -> some ToolbarContent {
        if terminals.list.count > 1 {
            ToolbarItem(placement: .principal) {
                Picker("Terminal", selection: Binding(get: { terminals.shown?.id }, set: { terminals.shownID = $0 })) {
                    ForEach(terminals.list) { Text(terminals.name(of: $0)).tag(Optional($0.id)) }
                }
                .pickerStyle(.menu)
                .help("Show another terminal")
            }
        }
        if terminals.list.contains(where: { $0 !== terminal && $0.session === terminal.session }) {  // the last one stays
            ToolbarItem(placement: .topBarLeading) {
                Button("Close Terminal", systemImage: "xmark") { terminals.close(terminal) }
                    .help("Close this terminal and end its shell")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Menu("New Terminal", systemImage: "plus") {
                ForEach(app.open.filter { $0.state == .connected && $0.capabilities.shell }, id: \.host.id) { session in
                    Button(session.host.displayName) { terminals.shownID = terminals.add(on: session).id }
                        .help("Open another shell on this server")
                }
            }
            .help("Open another shell on an open server")
        }
    }

    /// "N new lines" while scrolled back: back to the newest output.
    @ViewBuilder private var newLines: some View {
        if terminals.newLines > 0 {
            Button(terminals.newLines == 1 ? "1 new line" : "\(terminals.newLines) new lines", systemImage: "arrow.down") {
                terminals.view?.showLive()
            }
            .buttonStyle(.glass)
            .padding(.bottom, 8)
            .help("Scroll down to the newest output")
        }
    }

    private func bar(_ terminal: Terminals.Terminal) -> some View {
        VStack(spacing: 8) {
            if commandFocused { suggestions(terminal) }
            HStack {
                TextField("Command", text: $command)
                    .focused($commandFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.send)
                    .onSubmit { send(terminal) }
                    .font(.body.monospaced())
                    .accessibilityIdentifier("commandLine")
                    .help("Type a command to run on the server; suggestions come from the commands run there before")
                Button("Run", systemImage: "return") { send(terminal) }
                    .labelStyle(.iconOnly)
                    .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Run the command in the shell")
            }
            .padding(12)
            .glassEffect()
            if terminals.typing {
                KeyBar(terminals: terminals)
            } else if !commandFocused {
                deck
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    /// The commands run on this server before that start with what is typed, newest first.
    @ViewBuilder private func suggestions(_ terminal: Terminals.Terminal) -> some View {
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

    /// The keyboard down: Stop, Return and Type, big for the thumb.
    private var deck: some View {
        HStack {
            Button("Stop", systemImage: "stop.fill") { terminals.press(keyCode: TerminalView.anyKey, characters: "\u{3}") }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .help("Stop the running command (Control-C)")
            Button("Return", systemImage: "return") { terminals.pressReturn() }
                .buttonStyle(.glass)
                .help("Press Return in the shell; a new shell where it ended")
            Button("Type", systemImage: "keyboard") { _ = terminals.view?.becomeFirstResponder() }
                .buttonStyle(.glass)
                .help("Show the keyboard to type in the shell")
        }
        .controlSize(.large)
        .labelStyle(.titleAndIcon)
        .frame(maxWidth: .infinity)
    }

    private func send(_ terminal: Terminals.Terminal) {
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        terminals.send(command, to: terminal)
        command = ""
    }
}

/// The keys a phone keyboard lacks, above it while the terminal has it: Escape, Ctrl (for the next key), Tab, the
/// arrows, | ~ / -, and Hide Keyboard.
struct KeyBar: View {
    @Bindable var terminals: Terminals

    var body: some View {
        HStack(spacing: 6) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    key("esc", code: 53, help: "Press Escape")
                    Toggle("ctrl", isOn: $terminals.ctrl)
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
            Button("Hide Keyboard", systemImage: "keyboard.chevron.compact.down") { _ = terminals.view?.resignFirstResponder() }
                .labelStyle(.iconOnly)
                .buttonStyle(.glass)
                .help("Hide the keyboard")
        }
        .controlSize(.regular)  // small enough to show most of the keys at once, as a keyboard's own keys
    }

    private func key(_ title: String, image: String? = nil, code: UInt16, characters: String? = nil, help: String) -> some View {
        Button { terminals.press(keyCode: code, characters: characters) } label: {
            Group {
                if let image { Label(title, systemImage: image).labelStyle(.iconOnly) } else { Text(title) }
            }
            .frame(minWidth: 20, minHeight: 28)
        }
        .buttonStyle(.glass)
        .help(help)
    }
}
