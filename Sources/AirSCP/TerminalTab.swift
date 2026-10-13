import AirSCPCore
import AppKit

/// The workspace's Terminal tab: a shell on the host inside AirSCP, riding its connection (no second login), that
/// knows files and commands. Paths in the output are taken by a right-click (Show in Files, Download, Edit in AirSCP,
/// Get Info, Copy Path); with bash and zsh each command is marked: its exit status and time beside it, Copy Output,
/// Copy Command and Run Again on a right-click, ⌘↑ ⌘↓ between them. ⌘F finds text, Follow in Files keeps the Files
/// tab's server pane in the shell's folder, snippets are typed at the prompt, and Finder files dropped on it are
/// uploaded into the shell's folder through the transfer queue, their names typed at the prompt. The shell starts when
/// the tab is first shown on a connected host, and again with Return after it ended.
@MainActor
final class TerminalController: NSViewController, NSMenuDelegate, NSSearchFieldDelegate {
    weak var workspace: HostWorkspace?
    private(set) var session: TerminalSession?
    let terminal = TerminalView()
    private let note = NSTextField(wrappingLabelWithString: "")
    /// The shell may start (the tab has been shown).
    private var wanted = false
    // The bar above the terminal.
    let snippetButton = NSPopUpButton(frame: .zero, pullsDown: true)
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
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        snippetButton.controlSize = .small
        snippetButton.font = small
        snippetButton.addItem(withTitle: "Insert Snippet")
        snippetButton.menu?.delegate = self  // the snippets, as they are when it opens
        snippetButton.autoenablesItems = false
        snippetButton.setAccessibilityIdentifier("terminal.snippets")
        followBox.controlSize = .small
        followBox.font = small
        followBox.target = self
        followBox.action = #selector(followChanged(_:))
        followBox.setAccessibilityIdentifier("terminal.follow")
        for (button, symbol, label, action, id) in [
            (previousButton, "chevron.up", "Previous prompt", #selector(TerminalView.previousPrompt(_:)), "terminal.previousPrompt"),
            (nextButton, "chevron.down", "Next prompt", #selector(TerminalView.nextPrompt(_:)), "terminal.nextPrompt"),
            (findButton, "magnifyingglass", "Find", #selector(find(_:)), "terminal.find"),
        ] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            button.bezelStyle = .recessed
            button.controlSize = .small
            button.action = action
            button.target = button === findButton ? self : terminal
            button.setAccessibilityIdentifier(id)
        }
        findButton.toolTip = "Find text in the terminal (⌘F)"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let controls = NSStackView(views: [snippetButton, followBox, spacer, previousButton, nextButton, findButton])
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
        let stack = NSStackView(views: [FilePane.bar(controls), FilePane.separator(), findBar, terminal])
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

    /// A new shell, in `directory` (else the login folder).
    func start(in directory: String?) {
        guard let workspace else { return }
        session?.close()
        let size = terminal.gridSize
        let screen = TerminalScreen(columns: size.columns, rows: size.rows)
        // A new token for each shell: its marks are told from output that imitates them.
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        screen.markToken = token
        let host = workspace.session.host
        let argv = OpenSSH.terminal(host, jump: workspace.model.jump(for: host), socket: workspace.session.socketPath,
                                    command: OpenSSH.terminalShell(in: directory, token: token))
        do {
            let session = try TerminalSession(argv, environment: workspace.connection.askpass.terminalEnvironment, screen: screen)
            session.onChange = { [weak self] in self?.screenChanged() }
            session.onExit = { [weak self] status in self?.ended(status) }
            self.session = session
            terminal.session = session
            followed = nil
            screenChanged()
        } catch {
            showError(error, title: "Can't open a shell", on: workspace.window)
        }
        showNote()
    }

    private func ended(_ status: Int32) {
        guard let screen = session?.screen else { return }
        screen.feed("\r\n\u{1B}[0;2m[The shell ended" + (status == 0 ? "" : " (exit status \(status))")
                    + ". Press Return for a new one.]\u{1B}[0m\r\n")
        screenChanged()
        showNote()
    }

    /// Return after the shell ended: a new one, if the host is connected.
    func restartIfEnded() -> Bool {
        guard session?.running != true else { return false }
        if workspace?.session.state == .connected { start(in: nil) }
        return true
    }

    /// Opens a shell in `directory` here (the Files pane's Open Terminal Here, when Settings sends it to this tab): a new
    /// one, or `cd` typed into the one running. That waits at its prompt (bash and zsh say so), else the user says when.
    func openShell(in directory: String) {
        wanted = true
        guard let session, session.running else { return start(in: directory) }
        // cd goes in as keys: a control character in a server's folder name (⌃U, ⌃C…) would act as that key, and a shell
        // that doesn't mark its commands isn't bash or zsh, whose quoting cd is written in (fish reads a \ inside quotes,
        // csh a !). Such a path isn't typed: the rest of the name could run as commands there.
        if directory.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
            || !session.screen.marksCommands && directory.contains(where: { $0 == "\\" || $0 == "!" }) {
            return showError(AirSCPError(.other, "The path of “\(RemotePath.name(directory))” has characters this shell may "
                                         + "not read as part of a name: type cd yourself."),
                             title: "Can't type cd into the Terminal tab", on: workspace?.window)
        }
        // A space first: shells that keep such lines out of their history do so (HISTCONTROL=ignorespace).
        let cd = " cd " + Quote.shell(directory) + "\r"
        terminal.showLive()
        if session.screen.waitsAtPrompt { return session.send(cd) }
        // Typed into an editor or a running command, cd may do harm there: destructive, so an agent's press waits for
        // the person at the Mac too.
        confirm("Type cd into the Terminal tab?", info: "Its shell may be busy: make sure it waits at a prompt (not in an "
                + "editor or a running command), then continue.", button: "Type cd", destructive: true,
                on: workspace?.window) { [weak self] in
            self?.session?.send(cd)
        }
    }

    /// What the shell printed changed.
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

    /// The bar's controls as the shell is now; a control that can't be used says why.
    private func updateBar() {
        let running = session?.running == true, screen = session?.screen
        let following = screen?.directory != nil || followBox.state == .on, marks = screen?.marksCommands == true
        // Only when something changed: this runs for every piece of output.
        guard isViewLoaded, barState.map({ $0 != (running, following, marks) }) ?? true else { return }
        barState = (running, following, marks)
        snippetButton.isEnabled = running
        snippetButton.toolTip = running ? "Type a saved snippet at the prompt; it runs when you press Return"
            : "The shell isn't running: connect, or press Return in the terminal for a new one"
        followBox.isEnabled = following
        followBox.toolTip = following ? "Move the Files tab's server pane to the shell's folder each time the shell changes folder"
            : "Works with bash and zsh, which say their folder at each prompt: this shell doesn't"
        previousButton.isEnabled = marks
        nextButton.isEnabled = marks
        previousButton.toolTip = marks ? "Scroll up to the prompt of the command before (⌘↑)" : Self.noMarks
        nextButton.toolTip = marks ? "Scroll down to the next command's prompt (⌘↓)" : Self.noMarks
    }

    /// What the bar showed last: the shell running, Follow in Files usable, commands marked.
    private var barState: (Bool, Bool, Bool)?

    static let noMarks = "Works with bash and zsh, which mark their commands: this shell doesn't"

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
/// its exit status and time (a failed one in red, with a red bar along it).
@MainActor
final class TerminalView: NSView, NSMenuItemValidation, NSMenuDelegate {
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

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let at = position(of: event)
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
        let at = position(of: event)
        let start = selection?.start ?? at
        selection = (start, at)
        autoscroll(with: event)
        needsDisplay = true
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
                                         ("Download", .download, "Download it to the Files tab's Mac folder, through the transfer queue"),
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
