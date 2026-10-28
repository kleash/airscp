import AirSCPCore
import AppKit

/// The file panes' everyday commands: select by pattern, compare the two folders, move or
/// copy within a server, make a symbolic link, copy the names, and go to the other pane's folder.
extension FilePane {
    // MARK: Selection

    @objc func selectByPattern(_ sender: Any?) { askPattern(select: true) }

    @objc func deselectByPattern(_ sender: Any?) { askPattern(select: false) }

    private func askPattern(select: Bool) {
        guard let window = view.window else { return }
        askText(select ? "Select by Pattern" : "Deselect by Pattern", info: "Names or patterns, separated by commas: * ? and [ ] "
                + "work, case doesn't matter (for example *.log, report-??.pdf).", initial: "",
                placeholder: "*.log, *.tmp", button: select ? "Select" : "Deselect", id: "select.pattern", on: window) { [self] text in
            let indexes = Self.rows(matching: text, in: rows)
            if select {
                table.selectRowIndexes(indexes, byExtendingSelection: true)
            } else {
                indexes.forEach(table.deselectRow)
            }
            table.window?.makeFirstResponder(table)
        }
    }

    /// The rows whose names match one of the patterns (commas between them), in any case.
    static func rows(matching text: String, in rows: [FileItem]) -> IndexSet {
        let patterns = TransferQueue.patterns(text.lowercased())
        return IndexSet(rows.indices.filter { TransferQueue.leftOut(rows[$0].name.lowercased(), by: patterns) })
    }

    /// Selects every row with the focused row's extension (files without one: other files without one).
    @objc func selectSameKind(_ sender: Any?) {
        guard let item = selectedItems.first else { return }
        let ext = (item.name as NSString).pathExtension.lowercased()
        let same = IndexSet(rows.indices.filter {
            rows[$0].isFolder == item.isFolder && ($0 == table.selectedRow || (rows[$0].name as NSString).pathExtension.lowercased() == ext)
        })
        table.selectRowIndexes(same, byExtendingSelection: false)
    }

    @objc func invertSelection(_ sender: Any?) {
        let selected = table.selectedRowIndexes
        table.selectRowIndexes(IndexSet(rows.indices).subtracting(selected), byExtendingSelection: false)
    }

    // MARK: Compare Folders

    /// Marks, in both panes, the items that differ between this Mac's folder and the server's (one level: the folders
    /// themselves, as Synchronize compares them). The marks stay until a pane lists again.
    @objc func compareFolders(_ sender: Any?) {
        guard let (local, remote) = browser?.synchronizedPanes, let session = remote.session, let localDir = local.dir,
              let remoteDir = remote.dir else { return }
        let patterns = TransferQueue.patterns(browser?.workspace?.model.host(session.host.id)?.leaveOut ?? session.host.leaveOut)
        Task {
            var comparison = Sync.Comparison()
            let compared = await perform("Comparing…", failure: "Can't compare the folders") {
                comparison = try await Sync.compare(local: localDir, remote: remoteDir, on: session, leavingOut: patterns, deep: false) { _ in }
            }
            guard compared else { return }
            let (here, there) = Self.marks(comparison.differences, server: session.host.displayName)
            local.marks = here
            remote.marks = there
            if here.isEmpty && there.isEmpty {
                showError(AirSCPError(.other, "Both folders hold the same files (by size and modification time; folders "
                                      + "by name)."), title: "No differences", on: view.window)
            }
        }
    }

    /// The marks for this Mac's pane and the server's pane, by name.
    static func marks(_ differences: [Sync.Difference], server: String) -> (local: [String: String], remote: [String: String]) {
        var local: [String: String] = [:], remote: [String: String] = [:]
        for difference in differences {
            switch (difference.local, difference.remote) {
            case (let mine?, nil): local[mine.name] = "Only here: not on \(server)"
            case (nil, let theirs?): remote[theirs.name] = "Only here: not on this Mac"
            case (let mine?, let theirs?):
                if mine.isFolder != theirs.isFolder {
                    local[mine.name] = "A \(mine.isFolder ? "folder" : "file") here, a \(theirs.isFolder ? "folder" : "file") on \(server)"
                    remote[theirs.name] = "A \(theirs.isFolder ? "folder" : "file") here, a \(mine.isFolder ? "folder" : "file") on this Mac"
                    continue
                }
                switch Sync.order(mine.modified, theirs.modified, dateOnly: theirs.dateOnly) {
                case .orderedDescending:
                    local[mine.name] = "Newer here"
                    remote[theirs.name] = "Older here: newer on this Mac"
                case .orderedAscending:
                    local[mine.name] = "Older here: newer on \(server)"
                    remote[theirs.name] = "Newer here"
                case .orderedSame:
                    local[mine.name] = "Another size on \(server), same time"
                    remote[theirs.name] = "Another size on this Mac, same time"
                }
            case (nil, nil): break
            }
        }
        return (local, remote)
    }

    // MARK: Move To, Copy To, New Symbolic Link

    @objc func moveTo(_ sender: Any?) { transferTo(sender, move: true) }

    @objc func copyTo(_ sender: Any?) { transferTo(sender, move: false) }

    /// Asks for a folder on this server (the other pane's, when it shows this server, else this one's) and moves or
    /// copies the items there, asking about name conflicts as a drag does.
    private func transferTo(_ sender: Any?, move: Bool) {
        let targets = targets(sender)
        guard let session, let dir, let window = view.window, !targets.isEmpty else { return }
        let other = browser?.otherPane(of: self)
        let initial = other?.session?.host.id == session.host.id ? other?.dir ?? dir : dir
        let what = targets.count == 1 ? "“\(targets[0].name)”" : FileList.items(targets.count)
        askText("\(move ? "Move" : "Copy") \(what) to", info: "A folder on \(session.host.displayName): its full path, or one "
                + "relative to “\(displayName(dir))”.", initial: initial, placeholder: "/var/www", button: move ? "Move" : "Copy",
                id: "transfer.folder", on: window) { [self] text in
            // As Go to Folder takes it: ~ is the home folder, "." and ".." are worked out (a quoted ~ would be a name).
            guard let path = resolve(text) else { return }
            browser?.transfer(targets, from: .remote(session), to: .remote(session), into: path, move: move)
        }
    }

    /// A symbolic link to the selected item (or to a path typed), in the folder shown.
    @objc func newSymbolicLink(_ sender: Any?) {
        guard let session, let dir, let window = view.window else { return }
        let target = targets(sender).first
        let name = Names.unique((target?.name ?? "link") + (target == nil ? "" : " link"), existing: items.map(\.name),
                                caseInsensitive: ignoresCase)
        askText("New Symbolic Link in “\(displayName(dir))”", info: "Its name, then what it points to: a path on "
                + "\(session.host.displayName), absolute or relative to this folder.", initial: name, placeholder: "name",
                button: "Next", id: "link.name", on: window) { [self] name in
            if let problem = FileList.nameProblem(name, windows: isWindows) {
                return report(AirSCPError(.other, problem), title: "“\(name)” can't be used as a name")
            }
            askText("“\(name)” points to", info: "Relative paths are kept as typed: the link then works wherever the folder goes.",
                    initial: target.map { RemotePath.parent($0.path) == dir ? $0.name : $0.path } ?? "",
                    placeholder: "../shared/config.yml", button: "Create", id: "link.target", on: window) { [self] destination in
                Task {
                    let made = await perform("Creating “\(name)”…", failure: "Can't create the link “\(name)”") {
                        try await session.makeLink(RemotePath.join(dir, name), to: destination)
                    }
                    if made, self.dir == dir { await open(dir, select: [name], record: false) }
                }
            }
        }
    }

    // MARK: Snippets on the selected items

    /// The snippets with placeholders, for the server pane's Run Snippet menu.
    var fileSnippets: [Snippet] { browser?.workspace?.model.data.snippets.filter(\.usesPlaceholders) ?? [] }

    /// The Run Snippet submenu for the context menu (nil when no snippet has a placeholder, or this isn't a server pane).
    func runSnippetMenu() -> NSMenuItem? {
        guard isRemote, !fileSnippets.isEmpty else { return nil }
        let menu = NSMenu(title: "Run Snippet")
        for snippet in fileSnippets {
            let item = NSMenuItem(title: snippet.name.isEmpty ? "Untitled" : snippet.name, action: #selector(runSnippetOnItems(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = snippet.id
            item.toolTip = "Run “\(snippet.command)” with the selected items in place of its placeholders"
            menu.addItem(item)
        }
        let item = NSMenuItem(title: "Run Snippet", action: nil, keyEquivalent: "")
        item.submenu = menu
        item.toolTip = "Run a snippet that has {file}, {files}, {name} or {folder} on the selection"
        return item
    }

    @objc func runSnippetOnItems(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID, let snippet = fileSnippets.first(where: { $0.id == id }),
              let dir, let workspace = browser?.workspace else { return }
        // The items' names are the server's, quoted for POSIX sh (`Snippet.expanded`): the command runs through sh, as
        // File ▸ Run does, so a login shell that reads POSIX quoting differently (fish, csh, tcsh) can't run commands a
        // name contains.
        let command = snippet.expanded(paths: targets(sender).map(\.path), folder: dir)
        if snippet.runInTerminal {
            workspace.openTerminal(command: command, sh: true)
        } else {
            workspace.showRunCommand(command, run: true, sh: true) { [weak self] in
                Task { @MainActor in if self?.dir == dir { await self?.reload() } }
            }
        }
    }

    /// Why a snippet can't run on these items now, or nil.
    func snippetProblem(_ snippet: Snippet, for targets: [FileItem]) -> String? {
        if !hasShell { return session?.capabilities.noShellReason ?? "This server doesn't run commands." }
        if !isThisHost { return "Snippets run on the host whose workspace this is." }
        if snippet.needsFiles && targets.isEmpty { return "Select the items to run it on first." }
        return nil
    }

    // MARK: Find Files' results

    /// The server's entries at `paths` (each folder listed once); a path that is gone is left out.
    func entries(at paths: [String]) async throws -> [RemoteEntry] {
        guard let session else { return [] }
        var byFolder: [String: [RemoteEntry]] = [:]
        var found: [RemoteEntry] = []
        for path in paths {
            let parent = RemotePath.parent(path)
            if byFolder[parent] == nil { byFolder[parent] = try await session.list(parent) }
            if let entry = byFolder[parent]?.first(where: { $0.name == RemotePath.name(path) }) { found.append(entry) }
        }
        return found
    }

    /// Download… in Find Files: a folder on this Mac chosen, then the results downloaded there as a drag does.
    func downloadFound(_ paths: [String]) {
        guard let session, let sheet = view.window?.attachedSheet ?? view.window, !paths.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Download"
        panel.message = "Download " + (paths.count == 1 ? "“\(RemotePath.name(paths[0]))”" : FileList.items(paths.count))
            + " from \(session.host.displayName) into the folder you choose"
        panel.directoryURL = URL(fileURLWithPath: browser?.settings.downloadFolder ?? NSHomeDirectory(), isDirectory: true)
        Panels.run(panel, on: sheet) { [self] urls in
            guard let folder = urls.first else { return }
            Task {
                do {
                    let items = try await entries(at: paths).map(FileItem.init)
                    browser?.transfer(items, from: .remote(session), to: .local, into: folder.path, move: false)
                } catch {
                    report(error, title: "Can't download")
                }
            }
        }
    }

    /// Delete… in Find Files: asks (naming the host), deletes, takes them off the list and lists the pane again.
    func deleteFound(_ paths: [String], from model: FindModel) {
        guard let session, let sheet = view.window?.attachedSheet ?? view.window, !paths.isEmpty else { return }
        let names = paths.prefix(8).map { "“\(RemotePath.name($0))”" }.joined(separator: ", ")
            + (paths.count > 8 ? " and \(paths.count - 8) more" : "")
        confirm(paths.count == 1 ? "Delete “\(RemotePath.name(paths[0]))” on “\(session.host.displayName)”?"
                    : "Delete \(FileList.items(paths.count)) on “\(session.host.displayName)”?",
                info: (paths.count == 1 ? paths[0] : names) + "\n\nFolders are deleted with everything in them. This can't be undone.",
                button: "Delete", destructive: true, on: sheet) { [self] in
            Task {
                let deleted = await perform("Deleting…", failure: "Can't delete") {
                    try await session.delete(try await entries(at: paths))
                }
                if deleted { model.removeResults(Set(paths)) }
                await reload()
            }
        }
    }

    // MARK: Copy Names, the other pane's folder

    /// The names of the items, one per line.
    @objc func copyNames(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(targets(sender).map(\.name).joined(separator: "\n"), forType: .string)
    }

    /// Shows the folder the other pane shows (both on this Mac, or both on the same server).
    @objc func goToOtherPanesFolder(_ sender: Any?) {
        guard let other = browser?.otherPane(of: self), let path = other.dir else { return }
        Task { await open(path) }
    }

    /// Whether these commands can run, and why not (`check` asks first).
    func habitCheck(_ action: Selector?, for targets: [FileItem]) -> (Bool, String?)? {
        let listed = dir != nil && isConnected
        func need(_ ok: Bool, _ reason: String) -> (Bool, String?) {
            ok ? (true, nil) : (false, !isConnected ? "Not connected: connect the host first." : dir == nil ? "Open a folder first." : reason)
        }
        switch action {
        case #selector(selectByPattern(_:)), #selector(deselectByPattern(_:)), #selector(invertSelection(_:)):
            return need(listed && !rows.isEmpty, "The folder shown is empty.")
        case #selector(selectSameKind(_:)):
            return need(listed && !targets.isEmpty, "Select an item first: its kind (extension) is chosen.")
        case #selector(compareFolders(_:)):
            return (browser?.synchronizedPanes != nil,
                    "Compare Folders needs a folder on this Mac in one pane and a connected server's folder in the other.")
        case #selector(moveTo(_:)):
            guard isRemote else { return (false, "Works on a server's items: on this Mac, use Finder.") }
            return need(listed && !targets.isEmpty, "Select server items first.")
        case #selector(copyTo(_:)):
            guard isRemote else { return (false, "Works on a server's items: on this Mac, use Finder.") }
            if !hasShell && !isS3 { return (false, session?.capabilities.noShellReason ?? "This server can't copy files within itself.") }
            return need(listed && !targets.isEmpty, "Select server items first.")
        case #selector(newSymbolicLink(_:)):
            guard isRemote else { return (false, "Works in a server pane: on this Mac, use Finder or Terminal.") }
            if isWindows { return (false, "A Windows server's OpenSSH can't make symbolic links.") }
            if isS3 { return (false, "S3 storage has no symbolic links.") }
            return need(listed && targets.count <= 1, "Select one item (or none) to link to.")
        case #selector(copyNames(_:)):
            return need(listed && !targets.isEmpty, "Select something first.")
        case #selector(goToOtherPanesFolder(_:)):
            let other = browser?.otherPane(of: self)
            let same = other.map { source.isSame(as: $0.source) } ?? false
            return need(listed && same && other?.dir != nil && other?.dir != dir,
                        !same ? "The other pane shows another computer: this works between two panes of this Mac or of one server."
                            : "Both panes show the same folder already.")
        default:
            return nil
        }
    }
}

/// A one-line question with a text field (a path, a pattern); `done` gets what was typed, unless it is empty.
@MainActor
func askText(_ message: String, info: String, initial: String, placeholder: String, button: String, id: String,
             on window: NSWindow, done: @escaping (String) -> Void) {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = info
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
    field.stringValue = initial
    field.placeholderString = placeholder
    field.setAccessibilityIdentifier(id)
    field.toolTip = info
    alert.accessoryView = field
    alert.addButton(withTitle: button).toolTip = message
    alert.addButton(withTitle: "Cancel").toolTip = "Close without doing anything"
    alert.window.initialFirstResponder = field
    alert.beginSheetModal(for: window) { response in
        let text = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard response == .alertFirstButtonReturn, !text.isEmpty else { return }
        done(text)
    }
}
