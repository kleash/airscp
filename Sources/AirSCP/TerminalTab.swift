import AirSCPCore
import AppKit

/// The workspace's Terminal tab (PLAN.md W): a shell on the host inside AirSCP, riding its connection (no second
/// login), that knows files. Paths in the output are taken by a right-click (Show in Files, Download, Edit in AirSCP,
/// Get Info, Copy Path), Finder files dropped on it are uploaded into the shell's folder through the transfer queue
/// and their names typed at the prompt. The shell starts when the tab is first shown on a connected host, and again
/// with Return after it ended.
@MainActor
final class TerminalController: NSViewController {
    weak var workspace: HostWorkspace?
    private(set) var session: TerminalSession?
    let terminal = TerminalView()
    private let note = NSTextField(wrappingLabelWithString: "")
    /// The shell may start (the tab has been shown).
    private var wanted = false

    init(workspace: HostWorkspace) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let view = NSView()
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.controller = self
        note.translatesAutoresizingMaskIntoConstraints = false
        note.alignment = .center
        note.textColor = .secondaryLabelColor
        note.isHidden = true
        view.addSubview(terminal)
        view.addSubview(note)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: view.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            terminal.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            note.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            note.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            note.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        self.view = view
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

    private func showNote() {
        let connected = workspace?.session.state == .connected
        note.isHidden = connected || session?.running == true
        note.stringValue = "Connect to the host to open a shell here. It uses the same connection: no second login."
        terminal.isHidden = !note.isHidden && session == nil
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
        let host = workspace.session.host
        let argv = OpenSSH.terminal(host, jump: workspace.model.jump(for: host), socket: workspace.session.socketPath,
                                    command: OpenSSH.terminalShell(in: directory))
        do {
            let session = try TerminalSession(argv, environment: workspace.connection.askpass.terminalEnvironment, screen: screen)
            session.onChange = { [weak self] in self?.terminal.screenChanged() }
            session.onExit = { [weak self] status in self?.ended(status) }
            self.session = session
            terminal.session = session
            terminal.screenChanged()
        } catch {
            showError(error, title: "Can't open a shell", on: workspace.window)
        }
        showNote()
    }

    private func ended(_ status: Int32) {
        guard let screen = session?.screen else { return }
        screen.feed("\r\n\u{1B}[0;2m[The shell ended" + (status == 0 ? "" : " (exit status \(status))")
                    + ". Press Return for a new one.]\u{1B}[0m\r\n")
        terminal.screenChanged()
        showNote()
    }

    /// Return after the shell ended: a new one, if the host is connected.
    func restartIfEnded() -> Bool {
        guard session?.running != true else { return false }
        if workspace?.session.state == .connected { start(in: nil) }
        return true
    }

    /// Opens a shell in `directory` here (the Files pane's Open Terminal Here, when the Terminal tab is preferred).
    func openShell(in directory: String) {
        wanted = true
        if session?.running == true {
            session?.send("cd " + Quote.shell(directory) + "\r")
        } else {
            start(in: directory)
        }
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
/// wheel) and the keyboard going to the shell.
@MainActor
final class TerminalView: NSView, NSMenuItemValidation {
    weak var controller: TerminalController?
    var session: TerminalSession? {
        didSet {
            scrollOffset = 0
            selection = nil
        }
    }
    let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    private lazy var boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
    private lazy var cellWidth = ceil(("M" as NSString).size(withAttributes: [.font: font]).width)
    private lazy var cellHeight = ceil(font.ascender - font.descender + font.leading) + 2
    private let inset: CGFloat = 6
    /// Lines up from the bottom of the scrollback that the view shows (0: the live screen).
    private var scrollOffset = 0
    /// From and to, as (line in `allLines`, column).
    private var selection: (start: (Int, Int), end: (Int, Int))?
    private var dropping = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        setAccessibilityRole(.textArea)
        setAccessibilityLabel("Terminal")
        setAccessibilityIdentifier("terminal")
        toolTip = "A shell on the host: right-click a file name for its actions, drop Finder files to upload them here"
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
        if dropping {
            NSColor.controlAccentColor.set()
            let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            frame.lineWidth = 3
            frame.stroke()
        }
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
        scrollOffset = 0
        selection = nil
        session.send(keys)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Ctrl combinations are the shell's while the terminal has the keyboard (⌘ ones stay the menus').
        guard window?.firstResponder === self, event.modifierFlags.contains(.control),
              !event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
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
        scrollOffset = 0
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
        scrollOffset = 0
        needsDisplay = true
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(copy(_:)):
            item.toolTip = selection == nil ? "Select text first: drag over it" : "Copy the selected text"
            return selection != nil
        case #selector(paste(_:)): return session?.running == true
        default: return true
        }
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
        let all = screen.allLines
        var text = ""
        for line in start.0...min(end.0, all.count - 1) {
            let cells = all[line].cells
            let low = line == start.0 ? start.1 : 0, high = line == end.0 ? min(end.1, cells.count - 1) : cells.count - 1
            guard low <= high else { continue }
            var part = String(cells[low...high].filter { !$0.continuation }.map(\.character))
            if !all[line].wrapped || line == end.0 { while part.last == " " { part.removeLast() } }
            text += part + (all[line].wrapped || line == end.0 ? "" : "\n")
        }
        return text
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let at = position(of: event)
        if let word = session?.screen.path(atLine: at.line, column: at.column), let controller {
            let shown = word.count > 40 ? String(word.prefix(18)) + "…" + String(word.suffix(18)) : word
            let title = NSMenuItem(title: "“\(shown)”", action: nil, keyEquivalent: "")
            title.isEnabled = false
            menu.addItem(title)
            for (label, action, tip) in [("Show in Files", TerminalController.Action.show, "Show it in the Files tab's server pane"),
                                         ("Download", .download, "Download it to the Files tab's Mac folder, through the transfer queue"),
                                         ("Edit in AirSCP", .edit, "Open it in AirSCP's text editor; Save puts it back on the server"),
                                         ("Get Info", .info, "Its size, owner, permissions and dates"),
                                         ("Copy Path", .copy, "Copy its full path on the server")] {
                let item = NSMenuItem(title: label, action: #selector(TerminalMenuTarget.act(_:)), keyEquivalent: "")
                item.toolTip = tip
                item.representedObject = TerminalMenuTarget.Choice(action: action, word: word)
                item.target = TerminalMenuTarget.shared
                TerminalMenuTarget.shared.controller = controller
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }
        for (title, action, tip) in [("Copy", #selector(copy(_:)), "Copy the selected text"),
                                     ("Paste", #selector(paste(_:)), "Paste the clipboard's text at the prompt"),
                                     ("Select All", #selector(selectAll(_:)), "Select the whole scrollback"),
                                     ("Clear Scrollback", #selector(clearScrollback(_:)), "Forget the lines that scrolled off the top")] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.toolTip = tip
            menu.addItem(item)
        }
        return menu
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
