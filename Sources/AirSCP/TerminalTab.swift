import AirSCPCore
import AppKit

/// The workspace's Terminal tab: shells on the host inside AirSCP, one per tab of its strip, each riding the host's
/// connection (no second login), that know files and commands. Paths in the output are taken by a right-click (Show in
/// Files, Download, Edit in AirSCP, Get Info, Copy Path) or dragged to Finder once selected; with bash and zsh each
/// command is marked: its exit status and time beside it, Copy Output, Copy Command and Run Again on a right-click,
/// ⌘↑ ⌘↓ between them, and it goes into the host's history (History…). ⌘F finds text, Follow in Files keeps the Files
/// tab's server pane in the shell's folder, snippets are typed at the prompt, Insert Path… (⌥⇥) types a name from the
/// server's folder, and Finder files dropped on it are uploaded into the shell's folder through the transfer queue,
/// their names typed at the prompt. The first shell starts when the tab is first shown on a connected host, and a
/// tab's shell again with Return after it ended.
@MainActor
final class TerminalController: NSViewController, NSMenuDelegate, NSSearchFieldDelegate, NSMenuItemValidation {
    weak var workspace: HostWorkspace?
    /// The tabs' shells, left to right, and the tab shown.
    private(set) var sessions: [TerminalSession] = []
    private(set) var current = 0
    /// The shell of the tab shown.
    var session: TerminalSession? { sessions.indices.contains(current) ? sessions[current] : nil }
    let terminal = TerminalView()
    private let note = NSTextField(wrappingLabelWithString: "")
    /// The shell may start (the tab has been shown).
    private var wanted = false
    /// The host's command history, read when first needed.
    private(set) lazy var history = CommandHistory(host: hostID)
    private let hostID: UUID
    // The strip of tabs, and the bar above the terminal.
    let tabStrip = NSSegmentedControl()
    private let newTabButton = NSButton(), closeTabButton = NSButton()
    let snippetButton = NSPopUpButton(frame: .zero, pullsDown: true)
    let historyButton = NSButton(title: "History…", target: nil, action: nil)
    let pathButton = NSButton(title: "Insert Path…", target: nil, action: nil)
    let followBox = NSButton(checkboxWithTitle: "Follow in Files", target: nil, action: nil)
    private let previousButton = NSButton(), nextButton = NSButton(), findButton = NSButton()
    // The find bar (⌘F), shown when asked for.
    private let findBar = NSStackView()
    let findField = NSSearchField()
    private let findArrows = NSSegmentedControl()
    let findCount = NSTextField(labelWithString: "")
    /// The folder Follow in Files moved the Files tab to last.
    private var followed: String?
    /// Find again after new output, a moment after it stops coming.
    private var findAgain: DispatchWorkItem?

    init(workspace: HostWorkspace) {
        self.workspace = workspace
        hostID = workspace.connection.hostID
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        tabStrip.controlSize = .small
        tabStrip.font = small
        tabStrip.trackingMode = .selectOne
        tabStrip.selectedSegmentBezelColor = .pill  // as the workspace's own tabs above
        tabStrip.target = self
        tabStrip.action = #selector(tabChosen(_:))
        tabStrip.toolTip = "The shells open on this host: click one to show it (⇧⌘[ and ⇧⌘] go through them)"
        tabStrip.setAccessibilityIdentifier("terminal.tabs")
        snippetButton.controlSize = .small
        snippetButton.font = small
        snippetButton.addItem(withTitle: "Insert Snippet")
        snippetButton.menu?.delegate = self  // the snippets, as they are when it opens
        snippetButton.autoenablesItems = false
        snippetButton.setAccessibilityIdentifier("terminal.snippets")
        for (button, action, id) in [(historyButton, #selector(showHistory(_:)), "terminal.history"),
                                     (pathButton, #selector(insertPath(_:)), "terminal.insertPath")] {
            button.controlSize = .small
            button.font = small
            button.bezelStyle = .recessed
            button.target = self
            button.action = action
            button.setAccessibilityIdentifier(id)
        }
        followBox.controlSize = .small
        followBox.font = small
        followBox.target = self
        followBox.action = #selector(followChanged(_:))
        followBox.setAccessibilityIdentifier("terminal.follow")
        for (button, symbol, label, action, id) in [
            (newTabButton, "plus", "New Terminal Tab", #selector(newTab(_:)), "terminal.newTab"),
            (closeTabButton, "xmark", "Close Terminal Tab", #selector(closeTab(_:)), "terminal.closeTab"),
            (previousButton, "chevron.up", "Previous prompt", #selector(TerminalView.previousPrompt(_:)), "terminal.previousPrompt"),
            (nextButton, "chevron.down", "Next prompt", #selector(TerminalView.nextPrompt(_:)), "terminal.nextPrompt"),
            (findButton, "magnifyingglass", "Find", #selector(find(_:)), "terminal.find"),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.bezelStyle = .recessed
            button.controlSize = .small
            button.action = action
            button.target = [previousButton, nextButton].contains(button) ? terminal : self
            button.setAccessibilityIdentifier(id)
        }
        findButton.toolTip = "Find text in the terminal (⌘F)"
        let tabSpacer = NSView(), spacer = NSView()
        tabSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let tabs = NSStackView(views: [tabStrip, newTabButton, closeTabButton, tabSpacer])
        tabs.spacing = 6
        tabs.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        let controls = NSStackView(views: [snippetButton, historyButton, pathButton, followBox, spacer, previousButton, nextButton,
                                           findButton])
        controls.spacing = 8
        controls.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)

        findField.placeholderString = "Find in the terminal"
        findField.toolTip = "Find this text in the output and the scrollback; Return goes up to the one before, ⇧Return down"
        findField.controlSize = .small
        findField.font = small
        findField.sendsSearchStringImmediately = true
        findField.target = self
        findField.action = #selector(findChanged(_:))
        findField.delegate = self
        findField.setAccessibilityIdentifier("terminal.findText")
        findField.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        findArrows.segmentCount = 2
        findArrows.trackingMode = .momentary
        findArrows.segmentStyle = .separated
        findArrows.controlSize = .small
        for (index, (symbol, label, tip)) in [("chevron.up", "Previous match", "Show the match before, higher up (Return)"),
                                              ("chevron.down", "Next match", "Show the match after, further down (⇧Return)")].enumerated() {
            findArrows.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: label), forSegment: index)
            findArrows.setWidth(22, forSegment: index)
            findArrows.setToolTip(tip, forSegment: index)
        }
        findArrows.toolTip = "Go through the matches"
        findArrows.target = self
        findArrows.action = #selector(findArrowClicked(_:))
        findArrows.setAccessibilityIdentifier("terminal.findArrows")
        findCount.font = small
        findCount.textColor = .secondaryLabelColor
        findCount.toolTip = "Which match is shown, of how many"
        findCount.setAccessibilityIdentifier("terminal.findCount")
        let done = NSButton(title: "Done", target: self, action: #selector(closeFind(_:)))
        done.controlSize = .small
        done.font = small
        done.bezelStyle = .recessed
        done.toolTip = "Close the find bar (Escape)"
        done.setAccessibilityIdentifier("terminal.findDone")
        let findSpacer = NSView()
        findSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let findControls = NSStackView(views: [findField, findArrows, findCount, findSpacer, done])
        findControls.spacing = 8
        findControls.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        findBar.orientation = .vertical
        findBar.alignment = .width
        findBar.spacing = 0
        findBar.addArrangedSubview(FilePane.bar(findControls))
        findBar.addArrangedSubview(FilePane.separator())
        findBar.isHidden = true

        terminal.controller = self
        terminal.setContentHuggingPriority(.init(1), for: .vertical)
        let stack = NSStackView(views: [FilePane.bar(tabs), FilePane.separator(), FilePane.bar(controls), FilePane.separator(), findBar,
                                        terminal])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.distribution = .fill  // the terminal takes the room the bars leave
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        note.translatesAutoresizingMaskIntoConstraints = false
        note.alignment = .center
        note.textColor = .secondaryLabelColor
        note.isHidden = true
        let view = NSView()
        view.addSubview(stack)
        view.addSubview(note)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            note.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            note.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            note.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        self.view = view
        updateBar()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        wanted = true
        startIfConnected()
        view.window?.makeFirstResponder(terminal)
    }

    func stateChanged(_ state: Session.State) {
        guard isViewLoaded else { return }
        if state == .connected { startIfConnected() }
        showNote()
    }

    /// The note over the (empty) terminal while the host isn't connected. The terminal stays in its place below the bar.
    private func showNote() {
        let connected = workspace?.session.state == .connected
        note.isHidden = connected || session?.running == true
        note.stringValue = "Connect to the host to open a shell here. It uses the same connection: no second login."
        updateBar()
    }

    private func startIfConnected() {
        guard wanted, session?.running != true, let workspace, workspace.session.state == .connected else {
            showNote()
            return
        }
        start(in: nil)
    }

    /// A new shell in `directory` (else the login folder), or `command` with a terminal (Run in Terminal), in a new tab
    /// or in place of the tab shown's.
    func start(in directory: String?, command: String? = nil, newTab: Bool = false) {
        guard let workspace else { return }
        let size = terminal.gridSize
        let screen = TerminalScreen(columns: size.columns, rows: size.rows)
        // A new token for each shell: its marks are told from output that imitates them.
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        screen.markToken = token
        screen.onCommand = { [weak self] in self?.history.add($0) }
        let host = workspace.session.host
        let argv = OpenSSH.terminal(host, jump: workspace.model.jump(for: host), socket: workspace.session.socketPath,
                                    command: command ?? OpenSSH.terminalShell(in: directory, token: token))
        do {
            let session = try TerminalSession(argv, environment: workspace.connection.askpass.terminalEnvironment, screen: screen)
            session.onChange = { [weak self, weak session] in session.map { self?.changed($0) } }
            session.onExit = { [weak self, weak session] status in session.map { self?.ended($0, status) } }
            if newTab || sessions.isEmpty {
                sessions.append(session)
                showTab(sessions.count - 1)
            } else {
                sessions[current].close()
                sessions[current] = session
                showTab(current)
            }
        } catch {
            showError(error, title: "Can't open a shell", on: workspace.window)
        }
        showNote()
    }

    private func ended(_ session: TerminalSession, _ status: Int32) {
        session.screen.feed("\r\n\u{1B}[0;2m[The shell ended" + (status == 0 ? "" : " (exit status \(status))")
                            + ". Press Return for a new one.]\u{1B}[0m\r\n")
        changed(session)
        showNote()
    }

    /// Return after the shell ended: a new one in its tab, if the host is connected.
    func restartIfEnded() -> Bool {
        guard session?.running != true else { return false }
        if workspace?.session.state == .connected { start(in: nil) }
        return true
    }

    /// Types `line` and Return into the tab shown when its shell waits at an empty prompt (bash and zsh say so; a line
    /// typed into an editor or a running command could do harm there), unless the line holds a control character, which
    /// would act as its key (⌃C, a line break). False when it isn't typed.
    private func typeAtPrompt(_ line: String) -> Bool {
        guard let session, session.running, session.screen.waitsAtPrompt,
              !line.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return false }
        terminal.showLive()
        session.send(line + "\r")
        return true
    }

    /// Open Terminal Here, when Settings sends it to this tab: `cd` typed at the shown tab's empty prompt, else a new
    /// shell in `directory`, in a new tab while the shown one's shell runs (busy, or not one that says it waits).
    func openShell(in directory: String) {
        wanted = true
        // A space first: shells that keep such lines out of their history do so (HISTCONTROL=ignorespace), as AirSCP's does.
        if typeAtPrompt(" cd " + Quote.shell(directory)) { return }
        start(in: directory, newTab: session?.running == true)
    }

    /// Run in Terminal, when Settings sends it to this tab: `command` typed at the shown tab's empty prompt, else run with a
    /// terminal in a new tab (in place of a shell that ended). `sh`: written for sh (AirSCP's own, with a server's names in
    /// it), typed only into bash and zsh, which read it alike; on its own it goes to sh unread by the login shell
    /// (`OpenSSH.viaSh`).
    func run(_ command: String, sh: Bool) {
        wanted = true
        if typeAtPrompt(command) { return }
        start(in: nil, command: sh ? OpenSSH.viaSh(command) : command, newTab: session?.running == true)
    }

    // MARK: Tabs

    /// Shows tab `index`: its shell in the terminal, with the bar, Follow in Files and find going with it.
    func showTab(_ index: Int) {
        guard sessions.indices.contains(index) else { return }
        current = index
        terminal.session = session
        followed = nil
        updateStrip()
        screenChanged()
        if !findBar.isHidden { runFind(keep: false) }
        showNote()
    }

    @objc private func tabChosen(_ sender: NSSegmentedControl) {
        showTab(sender.selectedSegment)
        view.window?.makeFirstResponder(terminal)
    }

    /// The tab before or after the one shown (`step` -1 or 1), round at the ends: ⌘{ ⌘}.
    func showTab(step: Int) {
        guard !sessions.isEmpty else { return }
        showTab((current + step + sessions.count) % sessions.count)
        view.window?.makeFirstResponder(terminal)
    }

    /// New Terminal Tab (⇧⌘T, +): another shell on the host, in the folder the shown one said it is in (else the login
    /// folder).
    @objc func newTab(_ sender: Any?) {
        wanted = true
        guard workspace?.session.state == .connected else { return }
        start(in: session?.screen.directory, newTab: true)
        view.window?.makeFirstResponder(terminal)
    }

    /// Close Terminal Tab (×): the tab shown and its shell, after asking while a command runs there. The last tab stays.
    @objc func closeTab(_ sender: Any?) {
        guard sessions.count > 1, let session else { return }
        let close = { [weak self, weak session] in
            guard let self, let session, let index = self.sessions.firstIndex(where: { $0 === session }) else { return }
            session.close()
            self.sessions.remove(at: index)
            self.showTab(min(index, self.sessions.count - 1))
        }
        guard let running = Self.running(in: session) else { return close() }
        confirm("Close this terminal tab?", info: running + " is still running in it: closing the tab ends it.",
                button: "Close Tab", destructive: true, on: view.window, action: close)
    }

    /// What runs in `session`'s shell, as far as AirSCP can see: the command it marked (bash, zsh), a full-screen program.
    static func running(in session: TerminalSession) -> String? {
        guard session.running else { return nil }
        if let block = session.screen.blocks.last, block.running { return "“\(block.text)”" }
        return session.screen.alternateScreen ? "A full-screen program" : nil
    }

    /// A tab's title: what the shell or a program set (OSC 0 or 2), else the name of the shell's folder (~ for the home
    /// folder), else "Shell".
    func title(of session: TerminalSession) -> String {
        let screen = session.screen
        if !screen.title.isEmpty { return screen.title }
        guard let directory = screen.directory else { return "Shell" }
        return directory == workspace?.session.capabilities.home ? "~" : RemotePath.name(directory)
    }

    /// The strip as the tabs are now: each one's title (cut short) and, in its tooltip, its folder or that its shell ended.
    private func updateStrip() {
        guard isViewLoaded else { return }
        let labels = sessions.map { session -> String in
            let title = title(of: session)
            return title.count > 24 ? String(title.prefix(23)) + "…" : title
        }
        let tips = sessions.enumerated().map { index, session in
            session.running ? "Show shell \(index + 1)" + (session.screen.directory.map { ", in " + $0 } ?? "")
                : "Show tab \(index + 1): its shell ended (press Return in it for a new one)"
        }
        // Only when something changed: this runs for every piece of output.
        let segments = 0..<tabStrip.segmentCount
        guard labels != segments.map({ tabStrip.label(forSegment: $0) ?? "" }) || tips != segments.map({ tabStrip.toolTip(forSegment: $0) ?? "" })
                || tabStrip.selectedSegment != current else { return }
        tabStrip.segmentCount = sessions.count
        for index in sessions.indices {
            tabStrip.setLabel(labels[index], forSegment: index)
            tabStrip.setWidth(0, forSegment: index)  // as wide as its label
            tabStrip.setToolTip(tips[index], forSegment: index)
        }
        tabStrip.selectedSegment = current
        updateBar()
    }

    /// What the bar showed last: the shell running, Follow in Files usable, commands marked, connected, tabs.
    private var barState: (Bool, Bool, Bool, Bool, Int)?

    /// The bar's controls as the shell is now; a control that can't be used says why.
    private func updateBar() {
        let running = session?.running == true, screen = session?.screen
        let following = screen?.directory != nil || followBox.state == .on, marks = screen?.marksCommands == true
        let connected = workspace?.session.state == .connected
        // Only when something changed: this runs for every piece of output.
        guard isViewLoaded, barState.map({ $0 != (running, following, marks, connected, sessions.count) }) ?? true else { return }
        barState = (running, following, marks, connected, sessions.count)
        newTabButton.isEnabled = connected
        newTabButton.toolTip = connected ? "Open another shell on this host in a new tab (⇧⌘T)" : Self.notConnected
        closeTabButton.isEnabled = sessions.count > 1
        closeTabButton.toolTip = sessions.count > 1 ? "Close this tab and its shell; it asks first while a command runs in it"
            : Self.lastTab
        let notRunning = "The shell isn't running: connect, or press Return in the terminal for a new one"
        snippetButton.isEnabled = running
        snippetButton.toolTip = running ? "Type a saved snippet at the prompt; it runs when you press Return" : notRunning
        historyButton.isEnabled = running
        historyButton.toolTip = running ? "Type a command you ran on this host before at the prompt, from a list you can search"
            : notRunning
        pathButton.isEnabled = running
        pathButton.toolTip = running ? "Type a file or folder name from the server at the prompt, picked from a list (⌥⇥)"
            : notRunning
        followBox.isEnabled = following
        followBox.toolTip = following ? "Move the Files tab's server pane to the shell's folder each time the shell changes folder"
            : "Works with bash and zsh, which say their folder at each prompt: this shell doesn't"
        previousButton.isEnabled = marks
        nextButton.isEnabled = marks
        previousButton.toolTip = marks ? "Scroll up to the prompt of the command before (⌘↑)" : Self.noMarks
        nextButton.toolTip = marks ? "Scroll down to the next command's prompt (⌘↓)" : Self.noMarks
    }

    static let noMarks = "Works with bash and zsh, which mark their commands: this shell doesn't"
    static let notConnected = "Connect to the host first: each tab is a shell on its connection"
    static let lastTab = "The last tab stays: type exit in it to end its shell"

    /// What a shell printed changed: its tab's title may have, and the terminal shows it when its tab is the one shown.
    private func changed(_ session: TerminalSession) {
        updateStrip()
        if session === self.session { screenChanged() }
    }

    /// What the shown shell printed changed.
    private func screenChanged() {
        terminal.screenChanged()
        updateBar()
        followShell()
        if !findBar.isHidden && !findField.stringValue.isEmpty && findAgain == nil {
            let work = DispatchWorkItem { [weak self] in
                self?.findAgain = nil
                self?.runFind(keep: true)
            }
            findAgain = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        }
    }

    // MARK: Follow in Files

    @objc private func followChanged(_ sender: NSButton) {
        followed = nil
        followShell()
        updateBar()
    }

    /// With Follow in Files on, the Files tab's server pane goes to the folder the shell said it is in (OSC 7) when
    /// that is a new one. Quietly: a folder it can't list stays out.
    private func followShell() {
        guard followBox.state == .on, let directory = session?.screen.directory, directory != followed,
              let pane = workspace?.browser?.right else { return }
        followed = directory
        Task { await pane.open(directory, quiet: true) }
    }

    // MARK: Snippets

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === snippetButton.menu else { return }
        while menu.items.count > 1 { menu.removeItem(at: 1) }  // the first is the pull-down's title
        addSnippets(to: menu)
    }

    /// The saved snippets, each typed at the prompt when chosen (not run), then Edit Snippets….
    func addSnippets(to menu: NSMenu) {
        let snippets = workspace?.model.data.snippets ?? []
        let running = session?.running == true
        for snippet in snippets {
            let item = NSMenuItem(title: snippet.name.isEmpty ? snippet.command : snippet.name,
                                  action: #selector(insertSnippet(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = snippet.command
            // Without bracketed paste a line break would run the line before it.
            let lines = snippet.command.trimmingCharacters(in: .newlines).contains { $0.isNewline }
            let pastes = session?.screen.bracketedPaste == true
            item.isEnabled = running && (!lines || pastes)
            let command = snippet.command.count > 50 ? String(snippet.command.prefix(50)) + "…" : snippet.command
            item.toolTip = !running ? "The shell isn't running: connect, or press Return in the terminal for a new one"
                : lines && !pastes ? "It has several lines and this shell would run each one as it comes: use Run Command"
                : "Type “\(command)” at the prompt; press Return to run it"
            menu.addItem(item)
        }
        if snippets.isEmpty {
            let none = NSMenuItem(title: "No Snippets Yet", action: nil, keyEquivalent: "")
            none.isEnabled = false
            none.toolTip = "Save commands you use often in Window ▸ Snippets"
            menu.addItem(none)
        }
        menu.addItem(.separator())
        let edit = NSMenuItem(title: "Edit Snippets…", action: #selector(AppDelegate.showSnippets(_:)), keyEquivalent: "")
        edit.toolTip = "Add or change snippets (Window ▸ Snippets)"
        menu.addItem(edit)
    }

    /// Types the snippet at the prompt, as a paste: the person reads it, changes it if need be, and presses Return.
    @objc func insertSnippet(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String, let session, session.running else { return }
        terminal.showLive()
        session.paste(command.trimmingCharacters(in: .newlines))
        view.window?.makeFirstResponder(terminal)
    }

    // MARK: History and Insert Path

    /// History…: the host's commands, newest first, filtered as you type; the one chosen is typed at the prompt (not run).
    @objc func showHistory(_ sender: Any?) {
        guard let workspace, let window = workspace.window, let session, session.running else { return }
        let history = self.history
        TerminalPicker.present("Commands run on \(workspace.host.displayName)",
                               items: history.commands.map { ($0.replacingOccurrences(of: "\n", with: " ⏎ "), $0) },
                               empty: "None yet. The commands you run here in bash or zsh are kept for this host, newest "
                                   + "first (not those typed after a space).",
                               clear: { history.clear() }, on: window) { [weak self, weak session] command in
            if let session { self?.insert(command, into: session) }
        }
    }

    /// Insert Path… (⌥⇥): the names in the folder of the word before the cursor (from /, ~ or the shell's folder), as the
    /// Files pane lists them (over sftp too), filtered as you type; the one chosen takes the word's place, quoted for the
    /// shell where it needs it. For shells that complete nothing, and long names.
    @objc func insertPath(_ sender: Any?) {
        guard let workspace, let window = workspace.window, let session, session.running else { return }
        let (word, typed) = Quote.lastWord(in: session.screen.typedBeforeCursor)
        let folder = word.lastIndex(of: "/").map { String(word[...$0]) } ?? ""
        Task { [self, session] in
            guard let path = await resolve(folder.isEmpty ? "." : folder) else {
                return showError(AirSCPError(.other, "AirSCP can't tell which folder the shell is in: type a path that "
                                             + "starts with / or ~/ first."), title: "Can't list the folder", on: window)
            }
            let entries: [RemoteEntry]
            do {
                entries = try await workspace.session.list(path)
            } catch {
                return workspace.show(error, title: "Can't list “\(path)”")
            }
            // A control character would act as its key at the prompt (a line feed runs the line): such names aren't offered.
            let items = entries.filter { !$0.name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F } }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map { entry -> TerminalPicker.Item in
                    let name = entry.name + (entry.kind == .directory ? "/" : "")
                    return (name, Self.typed(folder + name))
                }
            TerminalPicker.present("Insert a name from \(path)", items: items, filter: String(word.dropFirst(folder.count)),
                                   empty: "This folder is empty.", on: window) { [weak self, weak session] text in
                if let session { self?.insert(text, erasing: typed, into: session) }
            }
        }
    }

    /// A path as Insert Path types it: bare where no shell misreads it, else quoted; a ~/ in front stays bare (quoted it
    /// isn't the home folder), and a name with = in front is quoted (zsh would take it for a program's path).
    static func typed(_ path: String) -> String {
        let home = path.hasPrefix("~/") ? "~/" : "", rest = String(path.dropFirst(home.count))
        return home + (rest.hasPrefix("=") ? Quote.shell(rest) : Quote.shellWord(rest))
    }

    /// Types `text` at `session`'s prompt as a paste, in place of the `erasing` characters before the cursor (Delete keys).
    /// A line break or other control character only where the shell takes pastes as such: else it would act as its key.
    private func insert(_ text: String, erasing: Int = 0, into session: TerminalSession) {
        guard session.running else { return }
        guard session.screen.bracketedPaste || !text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else {
            return showError(AirSCPError(.other, "It has several lines, and this shell would run each one as it comes: type it "
                                         + "yourself."), title: "Can't type it at the prompt", on: workspace?.window)
        }
        if session === self.session { terminal.showLive() }
        session.send(String(repeating: "\u{7F}", count: erasing))
        session.paste(text)
        view.window?.makeFirstResponder(terminal)
    }

    /// History… and Insert Path… in the context menu: while the shell runs.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(showHistory(_:)) || item.action == #selector(insertPath(_:)) else { return true }
        if session?.running != true { item.toolTip = "The shell isn't running: connect, or press Return in the terminal for a new one" }
        return session?.running == true
    }

    // MARK: Find

    /// The find bar: the button, the context menu, and Edit ▸ Filter (⌘F) while the terminal or the find bar has the
    /// keyboard (this controller comes before the window's own Filter in the responder chain).
    @objc func find(_ sender: Any?) {
        findBar.isHidden = false
        view.window?.makeFirstResponder(findField)
        runFind(keep: false)
    }

    @objc func closeFind(_ sender: Any?) {
        findBar.isHidden = true
        findAgain?.cancel()
        findAgain = nil
        terminal.setMatches([], keep: false)
        view.window?.makeFirstResponder(terminal)
    }

    @objc private func findChanged(_ sender: NSSearchField) { runFind(keep: false) }

    @objc private func findArrowClicked(_ sender: NSSegmentedControl) {
        terminal.showMatch(sender.selectedSegment == 0 ? -1 : 1)
        updateFindCount()
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            // Up first: the newest output is at the bottom, where the search starts.
            terminal.showMatch(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? 1 : -1)
            updateFindCount()
        case #selector(NSResponder.cancelOperation(_:)): closeFind(nil)
        default: return false
        }
        return true
    }

    /// Finds the text again; `keep`: the match shown stays, if it is still there (new output came).
    private func runFind(keep: Bool) {
        terminal.setMatches(session?.screen.find(findField.stringValue) ?? [], keep: keep)
        updateFindCount()
    }

    private func updateFindCount() {
        let count = terminal.matches.count
        findCount.stringValue = findField.stringValue.isEmpty ? "" : count == 0 ? "Not found"
            : "\((terminal.currentMatch ?? 0) + 1) of \(count)"
        findArrows.isEnabled = count > 1
    }

    // MARK: Files

    /// The shell's current folder on the server: what it last said (OSC 7), else its process's folder there (Linux's
    /// /proc, else lsof), else nil.
    func currentDirectory() async -> String? {
        guard let session, let workspace else { return nil }
        if let directory = session.screen.directory { return directory }
        guard let pid = session.screen.shellPID else { return nil }
        let result = try? await workspace.session.run(OpenSSH.processDirectory(pid))
        let path = result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.hasPrefix("/") ? path : nil
    }

    /// `word` (from the output) as a path on the server: absolute, from the home folder (~), or in the shell's folder.
    func resolve(_ word: String) async -> String? {
        if word.hasPrefix("/") { return RemotePath.normalized(word) }
        if word == "~" || word.hasPrefix("~/"), let home = workspace?.session.capabilities.home {
            return RemotePath.normalized(home + word.dropFirst())
        }
        guard let directory = await currentDirectory() else { return nil }
        return RemotePath.normalized(RemotePath.join(directory, word))
    }

    /// The server's item at `path`, nil when there is none.
    func item(at path: String) async -> FileItem? {
        guard let workspace, path != "/" else { return nil }
        let entries = try? await workspace.session.list(RemotePath.parent(path))
        return entries?.first { $0.name == RemotePath.name(path) }.map(FileItem.init)
    }

    /// The server's item that `word` (from the output) names, nil when there is none.
    func item(named word: String) async -> FileItem? {
        guard let path = await resolve(word) else { return nil }
        return await item(at: path)
    }

    enum Action { case show, download, edit, info, copy }

    /// A right-click's action on a path from the output.
    func act(_ action: Action, on word: String) {
        guard let workspace else { return }
        Task {
            guard let path = await resolve(word) else {
                return showError(AirSCPError(.noSuchFile, "AirSCP can't tell which folder “\(word)” is in: the shell "
                                             + "didn't say. Use its full path."), title: "Can't find “\(word)”", on: workspace.window)
            }
            if action == .copy {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
                return
            }
            guard let item = await item(at: path) else {
                return showError(AirSCPError(.noSuchFile, "There is no “\(path)” on \(workspace.host.displayName)."),
                                 title: "Can't find “\(word)”", on: workspace.window)
            }
            let browser = workspace.browser!
            switch action {
            case .show:
                workspace.tabs.selectedTabViewItemIndex = 0
                browser.right.reveal(path)
            case .download:
                guard let left = browser.left, let dir = left.dir else { return }
                if case .local = left.source {
                    browser.transfer([item], from: browser.right.source, to: .local, into: dir, move: false)
                } else {
                    browser.transfer([item], from: browser.right.source, to: .local, into: workspace.model.data.settings.downloadFolder, move: false)
                }
            case .edit: browser.edit(item, on: workspace.session, from: browser.right)
            case .info: browser.showInfo(item, on: workspace.session, from: browser.right)
            case .copy: break
            }
        }
    }

    /// Finder files dropped on the terminal: uploaded into the shell's folder, their names typed at the prompt.
    func upload(_ urls: [URL]) {
        guard let workspace, let session, session.running else { return }
        Task {
            guard let directory = await currentDirectory() else {
                return showError(AirSCPError(.other, "AirSCP can't tell which folder the shell is in, so it doesn't know "
                                             + "where to upload. Drop the files on the Files tab's server pane instead."),
                                 title: "Can't upload here", on: workspace.window)
            }
            workspace.browser.upload(urls, to: workspace.browser.right, into: directory)
            session.send(urls.map { Quote.shell($0.lastPathComponent) }.joined(separator: " ") + " ")
        }
    }
}

/// The terminal's text, drawn cell by cell in a monospaced font, with the cursor, a selection, scrollback (the scroll
/// wheel) and the keyboard going to the shell. Over the text: find's matches, and beside each command the shell marked,
/// its exit status and time (a failed one in red, with a red bar along it). A selected path dragged out goes to Finder.
@MainActor
final class TerminalView: NSView, NSMenuItemValidation, NSMenuDelegate, NSDraggingSource {
    typealias Match = (start: TerminalScreen.Position, end: TerminalScreen.Position)

    weak var controller: TerminalController?
    var session: TerminalSession? {
        didSet {
            scrollOffset = 0
            selection = nil
            matches = []
            currentMatch = nil
            highlight = nil
            jumped = nil
            pressed = nil
            // A tab's shell kept its size while another was shown.
            let size = gridSize
            session?.resize(columns: size.columns, rows: size.rows)
            needsDisplay = true
        }
    }
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private lazy var boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    /// The font's own advance, not rounded: a run of text is drawn as one string at that advance, and the cells (the
    /// cursor, the selection, find's matches) must stay under its characters along a whole line.
    private lazy var cellWidth = ("M" as NSString).size(withAttributes: [.font: font]).width
    private lazy var cellHeight = ceil(font.ascender - font.descender + font.leading) + 2
    private let inset: CGFloat = 6
    /// Lines up from the bottom of the scrollback that the view shows (0: the live screen).
    private var scrollOffset = 0
    /// From and to, as (line in `allLines`, column).
    private var selection: (start: (Int, Int), end: (Int, Int))?
    private var dropping = false
    /// Find's matches, oldest first, and the one shown.
    private(set) var matches: [Match] = []
    private(set) var currentMatch: Int?
    /// The lines of the command that the context menu or a jump (⌘↑ ⌘↓) is about: they are tinted.
    private var highlight: ClosedRange<Int>?
    /// The prompt line ⌘↑ ⌘↓ went to last.
    private(set) var jumped: Int?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Terminal")
        setAccessibilityIdentifier("terminal")
        toolTip = "A shell on the host: right-click a command or a file name for its actions; drop Finder files to upload"
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }

    /// Columns and rows that fit.
    var gridSize: (columns: Int, rows: Int) {
        let width = bounds.width > 0 ? bounds.width : 800, height = bounds.height > 0 ? bounds.height : 400
        return (max(Int((width - 2 * inset) / cellWidth), 20), max(Int((height - 2 * inset) / cellHeight), 5))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        let size = gridSize
        session?.resize(columns: size.columns, rows: size.rows)
        needsDisplay = true
    }

    func screenChanged() {
        needsDisplay = true
        NSAccessibility.post(element: self, notification: .valueChanged)
    }

    override func accessibilityValue() -> Any? { session?.screen.text }

    /// The live screen again, nothing tinted.
    func showLive() {
        scrollOffset = 0
        jumped = nil
        highlight = nil
        needsDisplay = true
    }

    // MARK: Drawing

    private var visibleLines: (lines: [TerminalScreen.Line], first: Int) {
        guard let screen = session?.screen else { return ([], 0) }
        let all = screen.allLines
        let end = max(all.count - scrollOffset, 0), start = max(end - screen.rows, 0)
        return (Array(all[start..<end]), start)
    }

    override func draw(_ dirtyRect: NSRect) {
        Self.background.setFill()
        bounds.fill()
        guard let session else { return }
        let screen = session.screen
        let (lines, first) = visibleLines
        let cursorLine = screen.scrollback.count + screen.cursorY
        func rowRect(_ line: Int, from: Int = 0, to: Int? = nil) -> NSRect {
            let to = to ?? screen.columns
            return NSRect(x: inset + CGFloat(from) * cellWidth, y: inset + CGFloat(line - first) * cellHeight,
                          width: CGFloat(to - from) * cellWidth, height: cellHeight)
        }
        if let highlight {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            for line in first..<(first + lines.count) where highlight.contains(line) {
                rowRect(line).insetBy(dx: -inset, dy: 0).fill()
            }
        }
        for (row, line) in lines.enumerated() {
            let y = inset + CGFloat(row) * cellHeight
            var x = 0
            while x < line.cells.count {
                // A run of cells that look alike, drawn as one string (the font is monospaced).
                let cell = line.cells[x]
                var run = String(cell.character), end = x + 1
                let ascii = cell.character.isASCII
                while ascii, end < line.cells.count, line.cells[end].attributes == cell.attributes,
                      line.cells[end].character.isASCII, !line.cells[end].continuation {
                    run.append(line.cells[end].character)
                    end += 1
                }
                let wide = end < line.cells.count && line.cells[end].continuation
                if wide { end += 1 }
                draw(run, attributes: cell.attributes, at: NSRect(x: inset + CGFloat(x) * cellWidth, y: y,
                                                                  width: CGFloat(end - x) * cellWidth, height: cellHeight),
                     selected: isSelected(line: first + row, from: x, to: end - 1))
                x = end
            }
            // The cursor: a block while the terminal has the keyboard, an outline otherwise.
            if first + row == cursorLine, screen.cursorVisible, scrollOffset == 0 || cursorLine >= first {
                let rect = NSRect(x: inset + CGFloat(screen.cursorX) * cellWidth, y: y, width: cellWidth, height: cellHeight)
                NSColor.controlAccentColor.withAlphaComponent(0.8).set()
                if window?.firstResponder === self && window?.isKeyWindow == true {
                    rect.fill(using: .sourceOver)
                } else {
                    NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
                }
            }
        }
        // Find's matches, the one shown stronger.
        let last = first + lines.count - 1
        for (index, match) in matches.enumerated() where match.end.line >= first && match.start.line <= last {
            (index == currentMatch ? NSColor.systemOrange.withAlphaComponent(0.55) : NSColor.systemYellow.withAlphaComponent(0.35)).setFill()
            for line in max(match.start.line, first)...min(match.end.line, last) {
                let from = line == match.start.line ? match.start.column : 0
                let to = line == match.end.line ? match.end.column : screen.columns
                if to > from { rowRect(line, from: from, to: to).fill(using: .sourceOver) }
            }
        }
        if !screen.alternateScreen { drawCommands(screen, first: first, last: last, rowRect: rowRect) }
        if dropping {
            NSColor.controlAccentColor.set()
            let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            frame.lineWidth = 3
            frame.stroke()
        }
    }

    /// Beside each finished command on screen: its exit status and time at the right of its command line (where that
    /// is blank), and a red bar along a failed one.
    private func drawCommands(_ screen: TerminalScreen, first: Int, last: Int, rowRect: (Int, Int, Int?) -> NSRect) {
        let all = screen.allLines
        for block in screen.blocks where !block.running && block.lastLine >= first && block.prompt <= last {
            let failed = (block.status ?? 0) != 0
            let color = failed ? NSColor.readable(.systemRed) : NSColor.secondaryLabelColor
            if failed {
                color.setFill()
                let top = max(block.prompt, first), bottom = min(block.lastLine, last)
                NSRect(x: 1, y: rowRect(top, 0, nil).minY, width: 3, height: CGFloat(bottom - top + 1) * cellHeight).fill()
            }
            guard let command = block.command else { continue }
            var line = command.line
            while line < all.count - 1 && all[line].wrapped { line += 1 }
            guard line >= first && line <= last else { continue }
            let label = NSAttributedString(string: Self.summary(of: block), attributes: [.font: Self.badgeFont, .foregroundColor: color])
            let size = label.size()
            let needed = Int(ceil((size.width + 16) / cellWidth))
            guard needed < screen.columns / 2,
                  all[line].cells.suffix(needed).allSatisfy({ $0.character == " " && $0.attributes.background == .standard })
            else { continue }
            let row = rowRect(line, 0, nil)
            let pill = NSRect(x: row.maxX - size.width - 10, y: row.midY - size.height / 2, width: size.width + 8, height: size.height)
            color.withAlphaComponent(0.14).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            label.draw(at: NSPoint(x: pill.minX + 4, y: pill.minY))
        }
    }

    private static let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium)

    /// "✓ 0.4 s", "✗ exit 1 · 2 min 5 s": how a command ended and how long it took (what the shell said of them).
    static func summary(of block: TerminalScreen.Block) -> String {
        var parts: [String] = []
        if let status = block.status { parts.append(status == 0 ? "✓" : "✗ exit \(status)") }
        if let duration = block.duration { parts.append(Self.duration(duration)) }
        return parts.joined(separator: parts.first == "✓" ? " " : " · ")
    }

    /// "0.4 s", "12 s", "2 min 5 s", "1 h 3 min".
    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 10 { return String(format: "%.1f s", max(seconds, 0)) }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        if total < 3600 { return "\(total / 60) min \(total % 60) s" }
        return "\(total / 3600) h \(total % 3600 / 60) min"
    }

    private func draw(_ text: String, attributes: TerminalScreen.Attributes, at rect: NSRect, selected: Bool) {
        var foreground = Self.color(attributes.foreground, foreground: true, bold: attributes.bold)
        var background = attributes.background == .standard ? nil : Self.color(attributes.background, foreground: false, bold: false)
        if attributes.inverse {
            let swapped = background ?? Self.background
            background = foreground
            foreground = swapped
        }
        if selected { background = NSColor.selectedTextBackgroundColor }
        if let background {
            background.setFill()
            rect.fill()
        }
        if attributes.dim { foreground = foreground.withAlphaComponent(0.6) }
        guard text.contains(where: { $0 != " " }) || attributes.underline else { return }
        var fontToUse = attributes.bold ? boldFont : font
        if attributes.italic { fontToUse = NSFontManager.shared.convert(fontToUse, toHaveTrait: .italicFontMask) }
        var drawing: [NSAttributedString.Key: Any] = [.font: fontToUse, .foregroundColor: foreground]
        if attributes.underline { drawing[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        (text as NSString).draw(at: NSPoint(x: rect.minX, y: rect.minY + 1), withAttributes: drawing)
    }

    static let background = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.99, alpha: 1)
    }

    /// The 16 colours, as Terminal.app's Basic profile has them (lighter in dark mode), then xterm's cube and greys.
    static func color(_ color: TerminalScreen.Color, foreground: Bool, bold: Bool) -> NSColor {
        switch color {
        case .standard: return foreground ? .textColor : background
        case .rgb(let r, let g, let b):
            return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        case .indexed(let index):
            let index = Int(index)
            if index < 16 {
                let palette: [NSColor] = [.black, .systemRed, .systemGreen, .systemYellow, .systemBlue, .systemPurple,
                                          .systemCyan, NSColor(white: 0.75, alpha: 1), .systemGray, .systemRed, .systemGreen,
                                          .systemYellow, .systemBlue, .systemPink, .systemTeal, .white]
                let chosen = palette[bold && index < 8 ? index + 8 : index]
                // Black and white text stay readable on the other appearance's ground.
                if index == 0 || index == 15 || index == 7 {
                    return NSColor(name: nil) { appearance in
                        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                        if index == 0 { return dark ? NSColor(white: 0.35, alpha: 1) : .black }
                        return dark ? chosen : NSColor(white: index == 15 ? 0.2 : 0.35, alpha: 1)
                    }
                }
                return chosen
            }
            if index < 232 {
                let cube = index - 16, levels: [CGFloat] = [0, 95, 135, 175, 215, 255]
                return NSColor(srgbRed: levels[cube / 36] / 255, green: levels[cube / 6 % 6] / 255, blue: levels[cube % 6] / 255, alpha: 1)
            }
            return NSColor(white: (8 + CGFloat(index - 232) * 10) / 255, alpha: 1)
        }
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        guard let session else { return }
        if !session.running {
            if event.keyCode == 36 || event.keyCode == 76, controller?.restartIfEnded() == true { return }
            return
        }
        let flags = event.modifierFlags
        // ⌥⇥: Insert Path… (Tab alone is the shell's own completion).
        if event.keyCode == 48, flags.intersection([.command, .control, .option, .shift]) == .option {
            controller?.insertPath(nil)
            return
        }
        guard let keys = TerminalSession.keys(keyCode: event.keyCode, characters: event.characters,
                                              control: flags.contains(.control), option: flags.contains(.option),
                                              shift: flags.contains(.shift), applicationCursor: session.screen.applicationCursorKeys)
        else { return }
        showLive()
        selection = nil
        session.send(keys)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        // ⌘↑ ⌘↓: between the commands' prompts.
        if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command, [125, 126].contains(event.keyCode) {
            event.keyCode == 126 ? previousPrompt(nil) : nextPrompt(nil)
            return true
        }
        // Ctrl combinations are the shell's while the terminal has the keyboard (⌘ ones stay the menus').
        guard event.modifierFlags.contains(.control), !event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        keyDown(with: event)
        return true
    }

    @objc func copy(_ sender: Any?) {
        guard let text = selectedText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        showLive()
        session?.paste(text)
    }

    override func selectAll(_ sender: Any?) {
        guard let screen = session?.screen else { return }
        let all = screen.allLines
        selection = ((0, 0), (all.count - 1, screen.columns - 1))
        needsDisplay = true
    }

    @objc func clearScrollback(_ sender: Any?) {
        session?.screen.feed("\u{1B}[3J")
        showLive()
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            item.toolTip = selection == nil ? "Select text first: drag over it" : "Copy the selected text"
            return selection != nil
        case #selector(paste(_:)): return session?.running == true
        case #selector(runAgain(_:)):
            let problem = runAgainProblem(item.representedObject as? TerminalScreen.Block)
            item.toolTip = problem ?? "Type this command at the prompt and run it again"
            return problem == nil
        case #selector(previousPrompt(_:)), #selector(nextPrompt(_:)):
            let marks = session?.screen.marksCommands == true
            item.toolTip = !marks ? TerminalController.noMarks : item.action == #selector(previousPrompt(_:))
                ? "Scroll up to the prompt of the command before" : "Scroll down to the next command's prompt"
            return marks
        default: return true
        }
    }

    // MARK: Commands (bash and zsh mark them)

    /// Why Run Again can't type `block` now, else nil.
    private func runAgainProblem(_ block: TerminalScreen.Block?) -> String? {
        guard let block, let session, session.running else { return "The shell isn't running: press Return in it for a new one" }
        guard block.output != nil else {
            return "This shell doesn't say where a command starts (bash before 4.4): Copy Command, then paste it"
        }
        // bash's command is read off the screen: a continuation prompt ("> ") it didn't mark would come with it, and
        // typed again it would be a redirection that empties a file.
        guard !block.text.contains("\n") else {
            return "It has several lines: Copy Command, check it, then paste it at the prompt"
        }
        guard session.screen.waitsAtPrompt else {
            return "The shell is busy, or something is typed at its prompt: wait for an empty prompt"
        }
        return nil
    }

    @objc func copyCommand(_ sender: NSMenuItem) {
        guard let block = sender.representedObject as? TerminalScreen.Block else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(block.text, forType: .string)
    }

    @objc func copyOutput(_ sender: NSMenuItem) {
        guard let block = sender.representedObject as? TerminalScreen.Block, let screen = session?.screen else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(screen.output(of: block), forType: .string)
    }

    /// Types the command at the prompt and presses Return: its line as the shell said it when it ran (never what the
    /// screen shows now, which later output may have drawn over).
    @objc func runAgain(_ sender: NSMenuItem) {
        guard let block = sender.representedObject as? TerminalScreen.Block, runAgainProblem(block) == nil, let session else { return }
        showLive()
        session.paste(block.text)
        session.send("\r")
    }

    @objc func previousPrompt(_ sender: Any?) { jump(up: true) }
    @objc func nextPrompt(_ sender: Any?) { jump(up: false) }

    /// Scrolls to the prompt of the command before or after the one jumped to last (at first: the cursor's), its lines
    /// tinted; after the last one, the live screen again.
    private func jump(up: Bool) {
        guard let screen = session?.screen, !screen.alternateScreen else { return }
        let blocks = screen.blocks, from = jumped ?? screen.cursorPosition.line
        guard let target = up ? blocks.last(where: { $0.prompt < from }) : blocks.first(where: { $0.prompt > from }) else {
            if !up { showLive() }
            return
        }
        jumped = target.prompt
        highlight = target.prompt...target.lastLine
        scrollOffset = min(max(screen.allLines.count - (target.prompt + screen.rows), 0), screen.scrollback.count)
        needsDisplay = true
    }

    // MARK: Find

    /// New matches; `keep`: the one shown stays when it is still there, else the newest (lowest) is shown.
    func setMatches(_ found: [Match], keep: Bool) {
        let shown = keep ? currentMatch.map { matches[$0].start } : nil
        matches = found
        currentMatch = shown.flatMap { start in found.firstIndex { $0.start == start } } ?? (found.isEmpty ? nil : found.count - 1)
        if !keep { revealMatch() }
        needsDisplay = true
    }

    /// The match `step` places on (-1: up, the one before), round at the ends.
    func showMatch(_ step: Int) {
        guard !matches.isEmpty else { return }
        currentMatch = ((currentMatch ?? matches.count - 1) + step + matches.count) % matches.count
        revealMatch()
    }

    /// Scrolls the match shown into the middle, unless it is on screen.
    private func revealMatch() {
        needsDisplay = true
        guard let currentMatch, let screen = session?.screen else { return }
        let line = matches[currentMatch].start.line, top = visibleLines.first
        guard line < top || line >= top + screen.rows else { return }
        scrollOffset = min(max(screen.allLines.count - (line + screen.rows / 2), 0), screen.scrollback.count)
    }

    // MARK: Mouse

    private func position(of event: NSEvent) -> (line: Int, column: Int) {
        let point = convert(event.locationInWindow, from: nil)
        let row = max(Int((point.y - inset) / cellHeight), 0)
        let column = min(max(Int((point.x - inset) / cellWidth), 0), (session?.screen.columns ?? 1) - 1)
        return (visibleLines.first + row, column)
    }

    /// A press in the selection: dragged, the server item named there (as a right-click takes it) goes to Finder, which
    /// downloads it. The item is looked up as the press begins (`item` is nil until then, and when it names none).
    private var pressed: (word: String, item: FileItem?)?

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let at = position(of: event)
        pressed = nil
        if event.clickCount == 1, isSelected(line: at.line, from: at.column, to: at.column), let controller,
           let word = session?.screen.path(atLine: at.line, column: at.column) {
            pressed = (word, nil)
            Task {
                let item = await controller.item(named: word)
                if pressed?.word == word { pressed?.item = item }
            }
            return
        }
        if event.clickCount == 2, let screen = session?.screen, at.line < screen.allLines.count {
            // A word.
            let cells = screen.allLines[at.line].cells
            var start = at.column, end = at.column
            while start > 0, cells[start - 1].character != " " { start -= 1 }
            while end < cells.count - 1, cells[end + 1].character != " " { end += 1 }
            selection = ((at.line, start), (at.line, end))
        } else if event.clickCount == 3, let screen = session?.screen {
            selection = ((at.line, 0), (at.line, screen.columns - 1))
        } else {
            selection = nil
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        if let pressed {
            // Once the item is known (a moment): a selection that names none stays as it is.
            if let item = pressed.item {
                self.pressed = nil
                drag(item, with: event)
            }
            return
        }
        let at = position(of: event)
        let start = selection?.start ?? at
        selection = (start, at)
        autoscroll(with: event)
        needsDisplay = true
    }

    /// A click in the selection that didn't drag: the selection goes, as for any click.
    override func mouseUp(with event: NSEvent) {
        guard pressed != nil else { return }
        pressed = nil
        selection = nil
        needsDisplay = true
    }

    /// Drags `item` out as the Files pane drags a row: a file promise, kept by downloading the item through the transfer
    /// queue where it is dropped.
    private func drag(_ item: FileItem, with event: NSEvent) {
        guard let workspace = controller?.workspace, let pane = workspace.browser?.right else { return }
        let dragged = NSDraggingItem(pasteboardWriter: pane.filePromise(for: item, on: workspace.session))
        let point = convert(event.locationInWindow, from: nil)
        dragged.setDraggingFrame(NSRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32),
                                 contents: NSWorkspace.shared.icon(for: FileList.type(of: item)))
        beginDraggingSession(with: [dragged], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    override func scrollWheel(with event: NSEvent) {
        guard let screen = session?.screen, !screen.alternateScreen else {
            // Full-screen programs (less, vim) take the wheel as arrow keys.
            if let session, event.scrollingDeltaY != 0 {
                session.send(String(repeating: event.scrollingDeltaY > 0 ? (session.screen.applicationCursorKeys ? "\u{1B}OA" : "\u{1B}[A")
                                    : (session.screen.applicationCursorKeys ? "\u{1B}OB" : "\u{1B}[B"), count: 3))
            }
            return
        }
        let lines = Int((event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / cellHeight : event.scrollingDeltaY * 3).rounded())
        scrollOffset = min(max(scrollOffset + lines, 0), screen.scrollback.count)
        needsDisplay = true
    }

    private func ordered() -> ((Int, Int), (Int, Int))? {
        guard let selection else { return nil }
        let (a, b) = (selection.start, selection.end)
        return a.0 < b.0 || (a.0 == b.0 && a.1 <= b.1) ? (a, b) : (b, a)
    }

    private func isSelected(line: Int, from: Int, to: Int) -> Bool {
        guard let (start, end) = ordered() else { return false }
        if line < start.0 || line > end.0 { return false }
        let low = line == start.0 ? start.1 : 0, high = line == end.0 ? end.1 : Int.max
        return to >= low && from <= high
    }

    func selectedText() -> String? {
        guard let (start, end) = ordered(), let screen = session?.screen else { return nil }
        return screen.text(from: .init(line: start.0, column: start.1), to: .init(line: end.0, column: end.1 + 1))
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.delegate = self
        let at = position(of: event)
        func add(_ title: String, _ action: Selector, _ tip: String, key: String = "", represented: Any? = nil, target: AnyObject? = nil) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = target ?? self
            item.toolTip = tip
            item.representedObject = represented
            menu.addItem(item)
        }
        if let word = session?.screen.path(atLine: at.line, column: at.column), let controller {
            let shown = word.count > 40 ? String(word.prefix(18)) + "…" + String(word.suffix(18)) : word
            let title = NSMenuItem(title: "“\(shown)”", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            TerminalMenuTarget.shared.controller = controller
            for (label, action, tip) in [("Show in Files", TerminalController.Action.show, "Show it in the Files tab's server pane"),
                                         ("Download", .download, "Download it to the Files tab's Mac folder (or select it and drag it to Finder)"),
                                         ("Edit in AirSCP", .edit, "Open it in AirSCP's text editor; Save puts it back on the server"),
                                         ("Get Info", .info, "Its size, owner, permissions and dates"),
                                         ("Copy Path", .copy, "Copy its full path on the server")] {
                add(label, #selector(TerminalMenuTarget.act(_:)), tip, represented: TerminalMenuTarget.Choice(action: action, word: word),
                    target: TerminalMenuTarget.shared)
            }
            menu.addItem(.separator())
        }
        // The command under the pointer (bash and zsh mark them), tinted while the menu is open.
        if let screen = session?.screen, !screen.alternateScreen, let block = screen.blocks.last(where: { $0.contains(at.line) }) {
            let line = block.text.components(separatedBy: "\n").first ?? ""
            let shown = line.count > 40 ? String(line.prefix(39)) + "…" : line
            let summary = Self.summary(of: block)
            let title = NSMenuItem(title: "“\(shown)”" + (summary.isEmpty ? "" : "  " + summary), action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            add("Copy Output", #selector(copyOutput(_:)), "Copy what this command printed", represented: block)
            add("Copy Command", #selector(copyCommand(_:)), "Copy this command's line", represented: block)
            add("Run Again", #selector(runAgain(_:)), "Type this command at the prompt and run it again", represented: block)
            menu.addItem(.separator())
            highlight = block.prompt...block.lastLine
            needsDisplay = true
        }
        add("Copy", #selector(copy(_:)), "Copy the selected text")
        add("Paste", #selector(paste(_:)), "Paste the clipboard's text at the prompt")
        add("Select All", #selector(selectAll(_:)), "Select the whole scrollback")
        if let controller {
            let snippets = NSMenuItem(title: "Insert Snippet", action: nil, keyEquivalent: "")
            snippets.toolTip = "Type a saved snippet at the prompt; it runs when you press Return"
            snippets.submenu = NSMenu(title: "Insert Snippet")
            snippets.submenu?.autoenablesItems = false
            controller.addSnippets(to: snippets.submenu!)
            menu.addItem(snippets)
            add("Insert Path…", #selector(TerminalController.insertPath(_:)),
                "Type a file or folder name from the server at the prompt, picked from a list", key: "\t", target: controller)
            menu.items.last?.keyEquivalentModifierMask = .option
            add("History…", #selector(TerminalController.showHistory(_:)), "Type a command you ran on this host before at the "
                + "prompt, from a list you can search", target: controller)
        }
        menu.addItem(.separator())
        add("Find…", #selector(TerminalController.find(_:)), "Find text in the terminal (⌘F)", key: "f", target: controller)
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!), down = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        add("Previous Prompt", #selector(previousPrompt(_:)), "Scroll up to the prompt of the command before", key: up)
        add("Next Prompt", #selector(nextPrompt(_:)), "Scroll down to the next command's prompt", key: down)
        menu.addItem(.separator())
        add("Clear Scrollback", #selector(clearScrollback(_:)), "Forget the lines that scrolled off the top")
        return menu
    }

    /// The tint goes back to the command jumped to, if any.
    func menuDidClose(_ menu: NSMenu) {
        highlight = jumped.flatMap { line in session?.screen.blocks.first { $0.prompt == line }.map { $0.prompt...$0.lastLine } }
        needsDisplay = true
    }

    // MARK: Dropping Finder files

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard session?.running == true, !fileURLs(sender).isEmpty else { return [] }
        dropping = true
        needsDisplay = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropping = false
        needsDisplay = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        dropping = false
        needsDisplay = true
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return false }
        controller?.upload(urls)
        return true
    }
}

/// The target of the path items in the terminal's context menu.
@MainActor
final class TerminalMenuTarget: NSObject {
    static let shared = TerminalMenuTarget()
    weak var controller: TerminalController?

    final class Choice: NSObject {
        let action: TerminalController.Action
        let word: String
        init(action: TerminalController.Action, word: String) {
            self.action = action
            self.word = word
        }
    }

    @objc func act(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? Choice else { return }
        controller?.act(choice.action, on: choice.word)
    }
}

/// A list to choose from in a sheet, filtered as you type (↑ ↓ choose, Return types the entry, Escape closes): the
/// Terminal tab's History… and Insert Path…. `choose` gets the entry's value.
@MainActor
final class TerminalPicker: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    /// What a row shows, and what choosing it types.
    typealias Item = (title: String, value: String)
    private var items: [Item]
    private(set) var shown: [Item] = []
    private let heading: String, empty: String
    private let clear: (() -> Void)?
    private let choose: (String) -> Void
    let filter = NSSearchField()
    let table = NSTableView()
    private let note = NSTextField(wrappingLabelWithString: "")
    private let insertButton = NSButton(title: "Insert", target: nil, action: nil)

    /// Shows the list as a sheet on `window`, filtered by `filter` at first. `clear`: a Clear History button.
    static func present(_ heading: String, items: [Item], filter: String = "", empty: String, clear: (() -> Void)? = nil,
                        on window: NSWindow, choose: @escaping (String) -> Void) {
        let picker = TerminalPicker(heading: heading, items: items, empty: empty, clear: clear, choose: choose)
        let sheet = NSWindow(contentViewController: picker)
        sheet.isReleasedWhenClosed = false  // held by ARC, as presentSheet's
        picker.filter.stringValue = filter
        picker.refilter()
        window.beginSheet(sheet)
        sheet.makeFirstResponder(picker.filter)
    }

    private init(heading: String, items: [Item], empty: String, clear: (() -> Void)?, choose: @escaping (String) -> Void) {
        self.heading = heading
        self.items = items
        self.empty = empty
        self.clear = clear
        self.choose = choose
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// What Insert types: the value of the entry chosen.
    var chosen: String? { shown.indices.contains(table.selectedRow) ? shown[table.selectedRow].value : nil }

    override func loadView() {
        let title = NSTextField(labelWithString: heading)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)  // a long path is cut short in the middle
        filter.placeholderString = "Filter"
        filter.toolTip = "Show only the entries with this text in them; ↑ and ↓ choose one, Return types it"
        filter.sendsSearchStringImmediately = true
        filter.target = self
        filter.action = #selector(filterChanged(_:))
        filter.delegate = self
        filter.setAccessibilityIdentifier("terminal.pickFilter")
        table.addTableColumn(NSTableColumn(identifier: .init("entry")))
        table.headerView = nil
        table.rowHeight = 20
        table.dataSource = self
        table.delegate = self
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.heightAnchor.constraint(equalToConstant: 260).isActive = true
        note.textColor = .secondaryLabelColor
        let clearButton = NSButton(title: "Clear History", target: self, action: #selector(clearHistory(_:)))
        clearButton.toolTip = "Forget every command kept for this host (the server's own shell history stays)"
        clearButton.setAccessibilityIdentifier("terminal.clearHistory")
        clearButton.isHidden = clear == nil
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        cancel.toolTip = "Close without typing anything"
        insertButton.target = self
        insertButton.action = #selector(insert(_:))
        insertButton.keyEquivalent = "\r"
        insertButton.setAccessibilityIdentifier("terminal.pickInsert")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [clearButton, spacer, cancel, insertButton])
        let stack = NSStackView(views: [title, filter, scroll, note, buttons])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.widthAnchor.constraint(equalToConstant: 440),
            title.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        self.view = view
    }

    /// The entries with the filter's text in them, the first one chosen.
    func refilter() {
        _ = view
        let text = filter.stringValue
        shown = text.isEmpty ? items : items.filter { $0.title.localizedCaseInsensitiveContains(text) }
        table.reloadData()
        if !shown.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
        note.stringValue = items.isEmpty ? empty : shown.isEmpty ? "Nothing here has “\(text)” in it." : ""
        note.isHidden = note.stringValue.isEmpty
        insertButton.isEnabled = !shown.isEmpty
        insertButton.toolTip = shown.isEmpty ? "There is nothing to choose: change the filter" : "Type the entry chosen at the prompt (Return)"
    }

    @objc private func filterChanged(_ sender: NSSearchField) { refilter() }

    @objc func insert(_ sender: Any?) {
        guard let value = chosen else { return }
        close()
        choose(value)
    }

    @objc private func cancel(_ sender: Any?) { close() }

    @objc private func clearHistory(_ sender: Any?) {
        clear?()
        items = []
        refilter()
    }

    private func close() {
        if let sheet = view.window { sheet.sheetParent?.endSheet(sheet) }
    }

    /// The filter keeps the keyboard: ↑ and ↓ move through the list, Return types the entry, Escape closes.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveDown(_:)):
            guard !shown.isEmpty else { return true }
            let row = min(max(table.selectedRow + (selector == #selector(NSResponder.moveUp(_:)) ? -1 : 1), 0), shown.count - 1)
            table.selectRowIndexes([row], byExtendingSelection: false)
            table.scrollRowToVisible(row)
        case #selector(NSResponder.insertNewline(_:)): insert(nil)
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = tableView.makeView(withIdentifier: .init("entry"), owner: nil) as? NSTextField ?? {
            let label = NSTextField(labelWithString: "")
            label.identifier = .init("entry")
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.lineBreakMode = .byTruncatingMiddle
            return label
        }()
        label.stringValue = shown[row].title
        return label
    }
}
