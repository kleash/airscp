import SwiftUI

extension FocusedValues {
    /// The window in front shows a place (⌘1–4, ⌘K).
    var go: GoKey.Value? {
        get { self[GoKey.self] }
        set { self[GoKey.self] = newValue }
    }

    /// The window in front opens a terminal on its server (⌘T); nil while no open server runs commands.
    var newTerminal: NewTerminalKey.Value? {
        get { self[NewTerminalKey.self] }
        set { self[NewTerminalKey.self] = newValue }
    }
}

struct GoKey: FocusedValueKey {
    typealias Value = (Place) -> Void
}

struct NewTerminalKey: FocusedValueKey {
    typealias Value = () -> Void
}

/// The app's keyboard shortcuts, in the iPad's menu bar and listed while ⌘ is held: ⌘1–4 the four places, ⌘K Search,
/// ⌘T New Terminal. Full Window (⌘⇧F) is the button of the terminal or editor it is for; the Files screen has its own.
struct AppCommands: Commands {
    @FocusedValue(\.go) private var go
    @FocusedValue(\.newTerminal) private var newTerminal

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Terminal") { newTerminal?() }
                .keyboardShortcut("t")
                .disabled(newTerminal == nil)
                .help("Open another shell on the server in front")
        }
        CommandMenu("Go") {
            place("Servers", .servers, "1", help: "Show your servers")
            place("Files", .files, "2", help: "Show the files of an open server and of this device")
            place("Terminal", .terminal, "3", help: "Type commands on an open server")
            place("Transfers", .transfers, "4", help: "Show the files being copied, and those copied")
            Divider()
            place("Search", .search, "k", help: "Find servers, snippets, commands run before, and files")
        }
    }

    private func place(_ title: String, _ place: Place, _ key: KeyEquivalent, help: String) -> some View {
        Button(title) { go?(place) }
            .keyboardShortcut(key)
            .disabled(go == nil)
            .help(help)
    }
}
