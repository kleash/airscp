import AirSCPCore
import Observation
import SwiftUI

/// The Terminal tab's shells (2e): AirSCP's own shell on each open server, as the Mac's Terminal tab starts it (bash and
/// zsh mark their commands), over the server's connection: no second login. New Terminal adds more. The commands run
/// go into the server's history (Core's `CommandHistory`), which the command line and Search offer again.
@MainActor @Observable final class Terminals {
    @MainActor @Observable final class Terminal: Identifiable {
        let id = UUID()
        let session: Session
        let history: CommandHistory
        /// The shell, once it has started; a new one after Return in one that ended.
        fileprivate(set) var shell: TerminalSession?
        /// A command to type once the shell waits at its prompt (Run on, the command line while it starts).
        fileprivate var pending: String?
        fileprivate var starting = false

        init(session: Session, history: CommandHistory) {
            self.session = session
            self.history = history
        }
    }

    private(set) var list: [Terminal] = []
    var shownID: Terminal.ID?
    var shown: Terminal? { list.first { $0.id == shownID } ?? list.first }
    /// The key bar's Ctrl, for the next key.
    var ctrl = false
    /// The terminal has the keyboard (the key bar shows, not the Stop / Return / Type deck).
    var typing = false
    /// Lines that came while the terminal is scrolled back.
    var newLines = 0
    /// Why a shell couldn't start.
    var failure: AirSCPError?
    @ObservationIgnored weak var view: TerminalView?
    /// One history per server, shared by its terminals (each would otherwise write over the others' file).
    @ObservationIgnored private var histories: [UUID: CommandHistory] = [:]

    /// One terminal for each connected server that runs commands; those of servers no longer open go.
    func sync(with app: AppState) {
        let gone = list.filter { terminal in !app.open.contains { $0 === terminal.session } }
        for terminal in gone { terminal.shell?.close() }
        list.removeAll { terminal in gone.contains { $0 === terminal } }
        for session in app.open where session.state == .connected && session.capabilities.shell
            && !list.contains(where: { $0.session === session }) {
            _ = add(on: session)
        }
    }

    /// New Terminal: another shell on `session`'s server, shown.
    @discardableResult func add(on session: Session) -> Terminal {
        let terminal = Terminal(session: session, history: history(for: session.host.id))
        list.append(terminal)
        start(terminal)
        return terminal
    }

    /// Close Terminal: the shown one, while its server has another.
    func close(_ terminal: Terminal) {
        terminal.shell?.close()
        list.removeAll { $0 === terminal }
        if shownID == terminal.id { shownID = list.first { $0.session === terminal.session }?.id }
    }

    func history(for host: UUID) -> CommandHistory {
        if let history = histories[host] { return history }
        let history = CommandHistory(host: host)
        histories[host] = history
        return history
    }

    /// The switcher's name of a terminal: its server's, numbered when the server has several.
    func name(of terminal: Terminal) -> String {
        let siblings = list.filter { $0.session === terminal.session }
        let name = terminal.session.host.displayName
        guard siblings.count > 1, let index = siblings.firstIndex(where: { $0 === terminal }) else { return name }
        return "\(name) (\(index + 1))"
    }

    // MARK: Shells

    /// Starts `terminal`'s shell in the size the view has, as the Mac's Terminal tab does: a new mark token for each.
    private func start(_ terminal: Terminal) {
        guard !terminal.starting, let transport = terminal.session.transport else { return }
        terminal.starting = true
        let size = view?.gridSize ?? (columns: 80, rows: 24)
        let screen = TerminalScreen(columns: size.columns, rows: size.rows)
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        screen.markToken = token
        let history = terminal.history
        screen.onCommand = { history.add($0) }
        Task {
            defer { terminal.starting = false }
            do {
                let shell = try await TerminalSession(transport: transport, command: OpenSSH.terminalShell(in: nil, token: token),
                                                      screen: screen)
                shell.onChange = { [weak self, weak terminal] in terminal.map { self?.changed($0) } }
                shell.onExit = { [weak self, weak terminal] status in terminal.map { self?.ended($0, status) } }
                terminal.shell?.close()
                terminal.shell = shell
                // Only bash and zsh say when they wait at their prompt: other shells get a command at once.
                if !["bash", "zsh"].contains(terminal.session.capabilities.loginShell), let pending = terminal.pending {
                    terminal.pending = nil
                    type(pending, in: terminal)
                }
            } catch {
                failure = error as? AirSCPError ?? AirSCPError(.other, error.localizedDescription)
            }
        }
    }

    private func changed(_ terminal: Terminal) {
        if let pending = terminal.pending, let shell = terminal.shell, shell.running, shell.screen.waitsAtPrompt {
            terminal.pending = nil
            type(pending, in: terminal)
        }
        if terminal === shown { view?.screenChanged() }
    }

    private func ended(_ terminal: Terminal, _ status: Int32) {
        terminal.shell?.screen.feed("\r\n\u{1B}[0;2m[The shell ended" + (status == 0 ? "" : " (exit status \(status))")
                                    + ". Press Return for a new one.]\u{1B}[0m\r\n")
        changed(terminal)
        // 255: as when the connection was lost, which the session learns at its next call: one now, so Servers says so.
        if status == 255 { Task { _ = try? await terminal.session.run(":") } }
    }

    /// Return in a shell that ended: a new one in its place, while the server is connected.
    func restart(_ terminal: Terminal) {
        guard terminal.shell?.running != true, terminal.session.state == .connected else { return }
        start(terminal)
    }

    // MARK: Typing

    /// A key from the key bar or the deck, as the Mac names its keys (`TerminalSession.keys`), with Ctrl when it is on.
    func press(keyCode: UInt16, characters: String? = nil) {
        guard let shell = shown?.shell, shell.running else { return }
        let control = ctrl
        ctrl = false
        guard let keys = TerminalSession.keys(keyCode: keyCode, characters: characters, control: control, option: false,
                                              shift: false, applicationCursor: shell.screen.applicationCursorKeys) else { return }
        view?.showLive()
        shell.send(keys)
    }

    /// The deck's Return: Return for the shell, or a new shell where it ended.
    func pressReturn() {
        guard let terminal = shown else { return }
        if terminal.shell?.running == true { press(keyCode: TerminalView.returnKey) } else { restart(terminal) }
    }

    /// The command line's Return: `command` typed in the shell and run, and kept in the server's history. A shell that
    /// ended starts again first.
    func send(_ command: String, to terminal: Terminal) {
        if terminal.shell?.running == true {
            type(command, in: terminal)
        } else {
            terminal.pending = command
            restart(terminal)
        }
    }

    /// Search's Run on: `command` at an empty prompt of a terminal on `session`'s server (the shown one first), else in a
    /// new terminal there once its shell waits at its prompt, as the Mac's Run in Terminal never types into a program.
    func run(_ command: String, on session: Session) {
        let ready = ((shown.map { [$0] } ?? []) + list).first {
            $0.session === session && $0.shell?.running == true && $0.shell?.screen.waitsAtPrompt == true
        }
        let terminal = ready ?? add(on: session)
        shownID = terminal.id
        if ready != nil { type(command, in: terminal) } else { terminal.pending = command }
    }

    private func type(_ command: String, in terminal: Terminal) {
        terminal.history.add(command)
        if terminal === shown { view?.showLive() }
        terminal.shell?.send(command + "\r")
    }
}
