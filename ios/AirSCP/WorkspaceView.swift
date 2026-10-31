import AirSCPCore
import Combine
import SwiftUI

extension EnvironmentValues {
    /// The window is about 1100 pt across or more (an iPad or the Duo open, on its side): the editor opens as a column
    /// next to the files, not as a sheet, and a server's workspace shows Transfers on its own while one runs.
    @Entry var wide = false
}

/// An open server's workspace (mockup 14), listed in the sidebar of a regular or wide window: the two Files sides (the
/// server's, and this device's), the server's terminal in a drawer pulled up under them, and Transfers in an inspector
/// on the right, which a wide window shows on its own while a transfer runs. Full Window gives the terminal the window.
struct WorkspaceView: View {
    @Environment(AppState.self) private var app
    @Environment(Terminals.self) private var terminals
    @Environment(\.wide) private var wide
    let session: Session
    /// The sides, kept here while the window turns or changes size (the server's side first).
    @State private var files: FilesModel
    @State private var drawerOpen = false
    @State private var drawerHeight: CGFloat = 320
    /// The drawer's height when a drag on its bar started.
    @State private var dragStart: CGFloat?
    @State private var height: CGFloat = 0
    @State private var showingTransfers = false
    @State private var fullWindow = false

    init(session: Session) {
        self.session = session
        _files = State(initialValue: FilesModel(server: session.host.id))
    }

    /// The terminal the drawer shows: the one Terminal shows if it is this server's, else this server's first.
    private var terminal: Terminals.Terminal? {
        terminals.shown.flatMap { $0.session === session ? $0 : nil } ?? terminals.list.first { $0.session === session }
    }

    var body: some View {
        VStack(spacing: 0) {
            FilesView(model: files) {}  // its "nothing open" never shows: this server is open
            bar(terminal)
            // Not while Full Window shows the terminal: one view for it at a time.
            if drawerOpen, !fullWindow, let terminal {
                TerminalPane(terminal: terminal)
                    .frame(height: min(drawerHeight, maxDrawer))
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .inspector(isPresented: $showingTransfers) {
            TransfersView()
                .inspectorColumnWidth(min: 300, ideal: 340, max: 440)
        }
        .fullWindow($fullWindow, escapeLeaves: false) {
            if let terminal { TerminalPane(terminal: terminal).navigationTitle(terminals.name(of: terminal)) }
        }
        .onAppear { terminals.sync(with: app) }
        .onChange(of: app.states) { terminals.sync(with: app) }
        // New Terminal (⌘T) on this server: in the drawer.
        .onChange(of: terminals.shownID) { if terminals.shown?.session === session { drawerOpen = true } }
        .onReceive(TransferCenter.shared.$jobs.map { $0.contains(where: \.status.isActive) }.removeDuplicates()) { active in
            if active && wide { showingTransfers = true }
        }
    }

    /// Why the drawer has no terminal.
    private func noTerminal(_ state: Session.State) -> String {
        switch state {
        case .connected: session.capabilities.shell ? "Starting…" : "This server doesn't run commands"
        case .connecting, .reconnecting: "Connecting…"
        default: "Not connected"
        }
    }

    /// The drawer's height at most: the files keep some room.
    private var maxDrawer: CGFloat { max(height - 220, 160) }

    /// The drawer's bar, under the files: pulls the terminal up (a tap, or a drag that also sets its height), and the
    /// workspace's buttons: New Terminal, Full Window, Transfers.
    private func bar(_ terminal: Terminals.Terminal?) -> some View {
        let state = app.states[session.host.id] ?? .idle
        let shell = state == .connected && session.capabilities.shell
        return HStack(spacing: 16) {
            Button {
                drawerOpen.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: drawerOpen ? "chevron.down" : "chevron.up")
                    Label("Terminal", systemImage: "apple.terminal")
                    Text(terminal.map { terminals.name(of: $0) } ?? noTerminal(state))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(.rect)
            }
            .disabled(terminal == nil)
            .accessibilityIdentifier("drawer")
            .help(drawerOpen ? "Push the terminal down" : "Pull up the terminal of this server")
            if let terminal, terminals.list.filter({ $0.session === session }).count > 1 {
                Picker("Terminal", selection: Binding(get: { terminal.id }, set: { terminals.shownID = $0 })) {
                    ForEach(terminals.list.filter { $0.session === session }) { Text(terminals.name(of: $0)).tag($0.id) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .help("Show another terminal of this server")
            }
            Spacer(minLength: 0)
            Button("New Terminal", systemImage: "plus") { terminals.shownID = terminals.add(on: session).id }
                .disabled(!shell)
                .help(shell ? "Open another shell on this server" : "Connect to a server that runs commands first")
            Button("Full Window", systemImage: "arrow.up.left.and.arrow.down.right") { fullWindow = true }
                .disabled(terminal == nil)
                // The editor's while it is open in a column (it gets the window then); Exit Full Window's while that shows.
                .keyboardShortcut(fullWindow || (wide && files.editing != nil) ? nil : KeyboardShortcut("f", modifiers: [.command, .shift]))
                .help("Give the terminal the whole window (⌘⇧F)")
            Toggle("Transfers", systemImage: "arrow.up.arrow.down", isOn: $showingTransfers)
                .toggleStyle(.button)
                .accessibilityIdentifier("showTransfers")
                .help(showingTransfers ? "Hide Transfers" : "Show Transfers on the right")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(.horizontal)
        .frame(minHeight: 48)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .gesture(DragGesture(minimumDistance: 8).onChanged { drag in
            guard terminal != nil else { return }
            let start = dragStart ?? (drawerOpen ? min(drawerHeight, maxDrawer) : 0)
            dragStart = start
            let pulled = start - drag.translation.height
            drawerOpen = pulled > 80
            if drawerOpen { drawerHeight = min(max(pulled, 160), maxDrawer) }
        }.onEnded { _ in dragStart = nil })
    }
}

extension View {
    /// Full Window: `content` fills the window, over the sidebar, the tab bar and the inspector, until Exit Full Window
    /// (its button, ⌘⇧F, or Escape where `escapeLeaves`: not in a terminal, whose Escape is the shell's).
    func fullWindow<Content: View>(_ isPresented: Binding<Bool>, escapeLeaves: Bool = true,
                                   @ViewBuilder content: @escaping () -> Content) -> some View {
        fullScreenCover(isPresented: isPresented) {
            NavigationStack {
                content()
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Exit Full Window", systemImage: "arrow.down.right.and.arrow.up.left") { isPresented.wrappedValue = false }
                                .keyboardShortcut("f", modifiers: [.command, .shift])
                                .help(escapeLeaves ? "Show the rest of the window again (⌘⇧F or Escape)" : "Show the rest of the window again (⌘⇧F)")
                        }
                    }
            }
            // Escape as a key command of its own (the button has ⌘⇧F), whatever has the keyboard.
            .background {
                if escapeLeaves {
                    Button("Exit Full Window") { isPresented.wrappedValue = false }
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .accessibilityHidden(true)
                }
            }
        }
    }
}
