import AirSCPCore
import AppKit

/// A pane's file operations: the context menu, the File / View / Go menu items and the checks that enable them.
/// Each runs as one command (sftp, or a shell command where the plan says so), shows a status while it runs, shows
/// errors in the window and lists the folder again afterwards. Copies between the panes, the editor, Get Info and the
/// Open-with watch are the BrowserContentController's.
extension FilePane {
    // MARK: Opening

    /// Return, double-click: a folder (or a link to one) opens in the pane; files open in their apps (a server's
    /// files are downloaded first and watched, so that AirSCP can offer to upload changes).
    @objc func openItems(_ sender: Any?) {
        let targets = targets(sender)
        guard !targets.isEmpty, dir != nil else { return }
        if targets.count == 1, let item = targets.first {
            switch item.kind {
            case .directory:
                Task { await open(item.path) }
                return
            case .symlink where isRemote:
                // A link to a folder lists it; anything else opens as a file.
                Task { if await !open(item.path, quiet: true) { openFiles([item]) } }
                return
            case .symlink where FileList.isLocalFolder(item.path):
                Task { await open(item.path) }
                return
            default:
                break
            }
        }
        openFiles(targets.filter { $0.kind != .directory })
    }

    private func openFiles(_ files: [FileItem]) {
        guard !files.isEmpty else { return }
        if let session {
            browser?.openWithDefaultApp(files, on: session, from: self)
        } else {
            files.forEach { NSWorkspace.shared.open(URL(fileURLWithPath: $0.path)) }
        }
    }

    /// The built-in text editor.
    @objc func editItem(_ sender: Any?) {
        guard let session, let item = targets(sender).first else { return }
        browser?.edit(item, on: session, from: self)
    }

    @objc func getInfo(_ sender: Any?) {
        guard let session, let item = targets(sender).first else { return }
        browser?.showInfo(item, on: session, from: self)
    }

    @objc func revealInFinder(_ sender: Any?) {
        let targets = targets(sender)
        if targets.isEmpty, let dir {
            NSWorkspace.shared.open(URL(fileURLWithPath: dir, isDirectory: true))
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(targets.map { URL(fileURLWithPath: $0.path) })
        }
    }

    // MARK: New, rename, delete

    @objc func newFolder(_ sender: Any?) {
        guard let dir, let window = view.window else { return }
        let name = Names.unique("untitled folder", existing: items.map(\.name), caseInsensitive: ignoresCase)
        askName("New folder in “\(displayName(dir))”", initial: name, button: "Create", on: window, windows: isWindows) { [self] name in
            Task {
                guard checkFree(name, in: dir) else { return }
                let path = RemotePath.join(dir, name)
                let made = await perform("Creating “\(name)”…", failure: "Can't create the folder “\(name)”") {
                    if let session {
                        try await session.makeDirectory(path)
                    } else if mkdir(path, 0o755) != 0 {
                        throw AirSCPError(.other, String(cString: strerror(errno)))
                    }
                }
                if made { await relist(dir, select: [name]) }
            }
        }
    }

    /// An empty file on the server.
    @objc func newFile(_ sender: Any?) {
        guard let session, let dir, let window = view.window else { return }
        let name = Names.unique("untitled.txt", existing: items.map(\.name), caseInsensitive: ignoresCase)
        askName("New file in “\(displayName(dir))”", initial: name, button: "Create", on: window, windows: isWindows) { [self] name in
            Task {
                guard checkFree(name, in: dir) else { return }
                let made = await perform("Creating “\(name)”…", failure: "Can't create the file “\(name)”") {
                    try await session.createFile(RemotePath.join(dir, name))
                }
                if made { await relist(dir, select: [name]) }
            }
        }
    }

    /// Lists `dir` again with `names` selected, if the pane still shows it: an operation that took a while mustn't take
    /// the pane back from where the user went meanwhile.
    private func relist(_ dir: String, select names: [String]) async {
        guard self.dir == dir else { return }
        await open(dir, select: names, record: false)
    }

    /// Names that differ only in case are one file here: this Mac's disks, Windows and macOS servers.
    var ignoresCase: Bool { session?.capabilities.caseInsensitive ?? true }

    var isWindows: Bool { session?.capabilities.windows ?? false }

    /// False (and says so) when the folder shown already has the name.
    private func checkFree(_ name: String, in dir: String) -> Bool {
        guard let existing = Names.existing(name, in: items.map(\.name), caseInsensitive: ignoresCase), dir == self.dir else {
            return true
        }
        report(AirSCPError(.other, "“\(existing)” already exists in “\(displayName(dir))”."), title: "Choose another name")
        return false
    }

    @objc func renameItem(_ sender: Any?) {
        guard let item = targets(sender).first, let dir, let window = view.window else { return }
        askName("Rename “\(item.name)”", initial: item.name, button: "Rename", on: window, selectBaseName: true,
                windows: isWindows) { [self] name in
            // By the bytes: "café" composed and decomposed are two names on a Linux server.
            guard !name.utf8.elementsEqual(item.name.utf8) else { return }
            Task { await rename(item, to: name, in: dir) }
        }
    }

    /// Renames within the folder; an existing name asks Replace / Keep Both (a different case or Unicode form of the
    /// same name is just a rename).
    func rename(_ item: FileItem, to name: String, in dir: String) async {
        var others = items.filter { $0.path != item.path }
        // The listing may be older than the server: a name taken since (checked now) brings a fresh listing, so that
        // the question below asks about it instead of replacing it unasked.
        if let session, Names.existing(name, in: others.map(\.name), caseInsensitive: ignoresCase) == nil,
           Names.key(name, caseInsensitive: ignoresCase) != Names.key(item.name, caseInsensitive: ignoresCase),
           (try? await session.exists(RemotePath.join(dir, name))) == true,
           let fresh = try? await session.list(dir) {
            others = fresh.map(FileItem.init).filter { $0.path != item.path }
        }
        var target = name
        var replaced: FileItem?
        if let existing = Names.existing(name, in: others.map(\.name), caseInsensitive: ignoresCase) {
            let other = others.first { $0.name == existing }
            guard let choice = await browser?.askConflicts([existing], in: "“\(displayName(dir))”", keepBoth: true, detail: { _ in
                other.map { FileList.comparison(new: item, existing: $0) }
            })?[existing], choice != .skip else { return }
            if choice == .keepBoth {
                target = Names.unique(name, existing: others.map(\.name), caseInsensitive: ignoresCase)
            } else {
                replaced = others.first { $0.name == existing }
            }
        }
        let path = RemotePath.join(dir, target)
        let renamed = await perform("Renaming “\(item.name)”…", failure: "Can't rename “\(item.name)”") {
            if let session {
                if let entry = replaced?.entry { try await session.delete([entry]) }
                try await session.rename(item.path, to: path)
            } else {
                if let replaced { try FileManager.default.trashItem(at: URL(fileURLWithPath: replaced.path), resultingItemURL: nil) }
                if Darwin.rename(item.path, path) != 0 { throw AirSCPError(.other, String(cString: strerror(errno))) }
            }
        }
        if renamed || isRemote { await relist(dir, select: [target]) }
    }

    /// ⌫ / ⌘⌫: a server's items are deleted (after asking, unless Settings say not to; folders with everything in
    /// them); this Mac's go to the Trash.
    @objc func deleteItems(_ sender: Any?) {
        let targets = targets(sender)
        guard !targets.isEmpty, let dir, isConnected else { return }
        guard let session else {
            Task {
                await perform("Moving to the Trash…", failure: "Can't move to the Trash") {
                    // Off the main thread: thousands of items take a while.
                    try await Task.detached(priority: .userInitiated) {
                        for item in targets { try FileManager.default.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil) }
                    }.value
                }
                await reload()
            }
            return
        }
        let delete: () -> Void = { [self] in
            Task {
                await perform("Deleting…", failure: "Can't delete") {
                    try await session.delete(targets.compactMap(\.entry))
                }
                if self.dir == dir { await reload() }
            }
        }
        guard browser?.settings.confirmDelete ?? true else { return delete() }
        let names = targets.prefix(8).map { "“\($0.name)”" }.joined(separator: ", ")
            + (targets.count > 8 ? " and \(targets.count - 8) more" : "")
        let folders = targets.contains { $0.isFolder }
        let host = " on “\(session.host.displayName)”"  // the window may show another host by the time it's answered
        confirm(targets.count == 1 ? "Delete “\(targets[0].name)”\(host)?" : "Delete \(FileList.items(targets.count))\(host)?",
                info: (targets.count == 1 ? "" : names + "\n\n") + (folders ? "Folders are deleted with everything in them. " : "")
                    + "This can't be undone.",
                button: "Delete", destructive: true, on: view.window, action: delete)
    }

    // MARK: Server operations

    @objc func duplicateItems(_ sender: Any?) {
        guard let session, let dir else { return }
        let entries = targets(sender).compactMap(\.entry)
        Task {
            var copies: [String] = []
            await perform("Duplicating…", failure: "Can't duplicate") {
                for entry in entries { copies.append(RemotePath.name(try await session.duplicate(entry))) }
            }
            await relist(dir, select: copies)
        }
    }

    @objc func makeExecutable(_ sender: Any?) {
        guard let session, let dir else { return }
        let entries = targets(sender).compactMap(\.entry)
        Task {
            await perform("Changing permissions…", failure: "Can't make it executable") {
                try await session.setPermissions(entries.filter { $0.mode & 0o111 != 0o111 }) { $0.mode | 0o111 }
            }
            await relist(dir, select: entries.map(\.name))
        }
    }

    /// The permissions sheet: rwx boxes and octal, for every selected item (folders: also what they hold).
    @objc func editPermissions(_ sender: Any?) {
        guard let session, let dir, let window = view.window else { return }
        let entries = targets(sender).compactMap(\.entry)
        guard let first = entries.first else { return }
        let title = entries.count == 1 ? "Permissions of “\(first.name)”" : "Permissions of \(FileList.items(entries.count))"
        presentSheet(on: window) { close in
            PermissionsSheet(title: title, mode: first.mode & 0o7777, hasFolders: entries.contains { $0.kind == .directory },
                             close: close) { [self] mode, recursive in
                Task {
                    // In one go: each item whatever happened to the one before, what failed in one sheet.
                    await perform("Changing permissions…", failure: "Can't change the permissions") {
                        try await session.setPermissions(entries, recursive: recursive) { _ in mode }
                    }
                    await relist(dir, select: entries.map(\.name))
                }
            }
        }
    }

    @objc func compressItems(_ sender: Any?) {
        guard let session, let dir, let window = view.window else { return }
        let names = targets(sender).map(\.name)
        guard !names.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = names.count == 1 ? "Compress “\(names[0])”" : "Compress \(FileList.items(names.count))"
        alert.informativeText = "The archive is made in “\(displayName(dir))” on the server."
        let formats = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
        formats.setAccessibilityIdentifier("compress.format")
        formats.toolTip = "zip opens anywhere, Windows included; .tar.gz keeps permissions and is smaller for text"
        formats.autoenablesItems = false
        var reasons: [String] = []
        for format in [ArchiveFormat.zip, .tarGz] {
            formats.addItem(withTitle: format == .zip ? "ZIP archive (.zip)" : "Gzipped tar archive (.tar.gz)")
            formats.lastItem?.representedObject = format.rawValue
            if let reason = session.compressUnavailableReason(format) {
                formats.lastItem?.isEnabled = false
                reasons.append(reason)
            }
        }
        if let enabled = formats.itemArray.first(where: \.isEnabled) { formats.select(enabled) }
        if !reasons.isEmpty { alert.informativeText += "\n\n" + Set(reasons).sorted().joined(separator: " ") }
        alert.accessoryView = formats
        let compress = alert.addButton(withTitle: "Compress")
        compress.isEnabled = formats.itemArray.contains(where: \.isEnabled)
        compress.toolTip = "Make the archive on the server, next to the items"
        alert.addButton(withTitle: "Cancel").toolTip = "Don't compress"
        alert.addHelp(.compress)
        alert.beginSheetModal(for: window) { [self] response in
            guard response == .alertFirstButtonReturn,
                  let format = (formats.selectedItem?.representedObject as? String).flatMap(ArchiveFormat.init) else { return }
            Task {
                var archive = ""
                await perform("Compressing…", failure: "Can't compress") {
                    archive = try await session.compress(names, in: dir, format: format)
                }
                await relist(dir, select: archive.isEmpty ? [] : [RemotePath.name(archive)])
            }
        }
    }

    @objc func extractHere(_ sender: Any?) { extract(sender, into: .here) }

    @objc func extractToFolder(_ sender: Any?) { extract(sender, into: .newFolder) }

    /// Extract Here first asks about items that are there already: replace them, or extract into a new folder.
    private func extract(_ sender: Any?, into destination: ExtractDestination) {
        guard let session, let dir, let entry = targets(sender).first?.entry else { return }
        Task {
            var destination = destination
            if destination == .here {
                var existing: [String] = []
                guard await perform("Reading “\(entry.name)”…", failure: "Can't extract “\(entry.name)”", {
                    existing = try await session.extractConflicts(entry)
                }) else { return }
                if !existing.isEmpty {
                    guard let choice = await askExtract(replacing: existing, in: dir) else { return }
                    destination = choice
                }
            }
            var folder = ""
            await perform("Extracting “\(entry.name)”…", failure: "Can't extract “\(entry.name)”") {
                folder = try await session.extract(entry, into: destination)
            }
            await relist(dir, select: folder.isEmpty || folder == dir ? [] : [RemotePath.name(folder)])
        }
    }

    /// Extracting here would replace `names`: into a new folder (the default), Replace, or nil for Cancel.
    private func askExtract(replacing names: [String], in dir: String) async -> ExtractDestination? {
        guard let window = view.window else { return nil }
        let alert = NSAlert()
        alert.messageText = names.count == 1 ? "“\(names[0])” already exists in “\(displayName(dir))”."
            : "\(names.count) items of the archive already exist in “\(displayName(dir))”."
        alert.informativeText = names.count == 1 ? "Extract the archive into a new folder, or replace it?"
            : "Extract the archive into a new folder, or replace them? (\(names.prefix(5).joined(separator: ", "))"
                + (names.count > 5 ? ", …)" : ")")
        alert.addButton(withTitle: "Extract to New Folder").toolTip = "Unpack into a new folder named after the archive"
        let replace = alert.addButton(withTitle: "Replace")
        replace.hasDestructiveAction = true
        replace.toolTip = "Unpack here, replacing the items of the same names"
        alert.addButton(withTitle: "Cancel").toolTip = "Don't extract"
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        switch response {
        case .alertFirstButtonReturn: return .newFolder
        case .alertSecondButtonReturn: return .here
        default: return nil
        }
    }

    /// Run an executable file: its output in the Run Command sheet, or in Terminal (for sudo and anything interactive).
    @objc func runItem(_ sender: Any?) {
        guard let item = targets(sender).first, let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = "Run “\(item.name)”"
        alert.informativeText = "Runs in its folder. Run shows the output here; Run in Terminal for programs that ask "
            + "questions or need sudo. Arguments are passed as typed (the shell expands them)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
        field.placeholderString = "Arguments (optional)"
        field.toolTip = "Words to pass to the program, as you would type them after its name"
        field.setAccessibilityIdentifier("run.arguments")
        alert.accessoryView = field
        alert.addButton(withTitle: "Run").toolTip = "Run it and show its output in AirSCP"
        alert.addButton(withTitle: "Run in Terminal").toolTip = "Run it in Terminal, for programs that ask questions or need sudo"
        alert.addButton(withTitle: "Cancel").toolTip = "Don't run it"
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [self] response in
            let command = Session.executeCommand(item.path, arguments: field.stringValue)
            switch response {
            // sh runs it, never the login shell (fish, csh and tcsh mis-read the name's quoting): `Session.run(_:sh:)`.
            case .alertFirstButtonReturn: browser?.workspace?.showRunCommand(command, run: true, sh: true)
            case .alertSecondButtonReturn: browser?.workspace?.openTerminal(command: OpenSSH.viaSh(command))
            default: break
            }
        }
    }

    @objc func openTerminalHere(_ sender: Any?) {
        let folder = targets(sender).first { $0.isFolder }?.path ?? dir
        if let folder { browser?.workspace?.openTerminal(in: folder) }
    }

    /// Find Files: names matching a pattern anywhere below the server folder shown; Show (or a double-click) goes to one.
    @objc func findFiles(_ sender: Any?) {
        guard let session, let dir, let window = view.window else { return }
        let model = FindModel(session: session, dir: dir)
        presentSheet(on: window) { close in
            FindView(model: model, show: { [weak self] path in
                model.stop()
                close()
                self?.reveal(path)
            }, close: {
                model.stop()
                close()
            })
        }
    }

    /// The item at `path` selected in its folder (hidden files are shown if it is one).
    func reveal(_ path: String) {
        let name = RemotePath.name(path)
        if name.hasPrefix(".") && !showHidden { toggleHiddenFiles(nil) }
        let term = filter.trimmingCharacters(in: .whitespaces)
        if !term.isEmpty && name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) == nil {
            clearFilter()  // it would hide the item
        }
        Task {
            guard await open(RemotePath.parent(path), select: [name]),
                  let row = rows.firstIndex(where: { $0.name == name }) else { return }
            table.scrollRowToVisible(row)
            view.window?.makeFirstResponder(table)
        }
    }

    // MARK: Favourites (PLAN.md S.2)

    /// The favourite folders of the server this pane shows (Go ▸ Favourites), as saved.
    var favourites: [String] {
        session.flatMap { session in browser?.workspace?.model.host(session.host.id)?.favourites } ?? []
    }

    /// Go ▸ Add to Favourites: the server folder shown, kept for its host.
    @objc func addToFavourites(_ sender: Any?) {
        guard let session, let dir else { return }
        browser?.workspace?.model.updateHost(session.host.id) { if !$0.favourites.contains(dir) { $0.favourites.append(dir) } }
    }

    /// Go ▸ Favourites ▸ <folder> (the item's representedObject).
    @objc func openFavourite(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        Task { await open(path) }
    }

    /// Go ▸ Favourites ▸ Remove ▸ <folder>.
    @objc func removeFavourite(_ sender: NSMenuItem) {
        guard let session, let path = sender.representedObject as? String else { return }
        browser?.workspace?.model.updateHost(session.host.id) { $0.favourites.removeAll { $0 == path } }
    }

    /// Go ▸ Favourites, filled by the pane that gets Go ▸ Add to Favourites when the Go menu's items are checked (as it
    /// opens): this pane's server's favourites (choosing one goes there), and Remove ▸ each. Their actions come to this
    /// pane through the responder chain, as the Go menu's others do.
    func fillFavourites(_ menu: NSMenu) {
        menu.removeAllItems()
        func entry(_ path: String, _ action: Selector) -> NSMenuItem {
            let item = NSMenuItem(title: path, action: action, keyEquivalent: "")
            item.representedObject = path
            item.toolTip = MenuHelp.tips[action]
            return item
        }
        guard !favourites.isEmpty else {
            let none = NSMenuItem(title: "No Favourites", action: nil, keyEquivalent: "")
            none.toolTip = isRemote ? "Go ▸ Add to Favourites keeps the folder shown here, to come back to it from this menu."
                : "Favourites keep a server's folders: focus a pane that shows a server."
            return menu.addItem(none)
        }
        favourites.forEach { menu.addItem(entry($0, #selector(openFavourite(_:)))) }
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove", action: nil, keyEquivalent: "")
        remove.toolTip = MenuHelp.submenus["Remove"]
        remove.submenu = NSMenu(title: "Remove")
        favourites.forEach { remove.submenu?.addItem(entry($0, #selector(removeFavourite(_:)))) }
        menu.addItem(remove)
    }

    /// Synchronize this Mac's folder with the server's in the other pane (PLAN.md S.1).
    @objc func synchronize(_ sender: Any?) {
        browser?.synchronize()
    }

    /// du for the folders shown; going to another folder stops it.
    @objc func calculateFolderSizes(_ sender: Any?) {
        guard let session, let dir else { return }
        let names = items.filter(\.isFolder).map(\.name)
        guard !names.isEmpty else { return }
        folderSizesTask?.cancel()
        folderSizesTask = Task {
            var sizes: [String: Int64] = [:]
            await perform("Calculating folder sizes…", failure: "Can't calculate the folder sizes") {
                sizes = try await session.folderSizes(names, in: dir)
            }
            if self.dir == dir && !Task.isCancelled { setFolderSizes(sizes) }
        }
    }

    // MARK: Copying

    /// The transfer button and its menu item: Upload, Download or Copy into the other pane's folder.
    @objc func copyToOtherPane(_ sender: Any?) {
        let targets = targets(sender)
        guard !targets.isEmpty else { return }
        browser?.copyToOtherPane(targets, from: self)
    }

    /// Choose files on this Mac to upload into the folder shown.
    @objc func chooseUpload(_ sender: Any?) {
        guard let dir, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Upload"
        panel.message = "Upload to “\(displayName(dir))” on \(session?.host.displayName ?? "the server")"
        Panels.run(panel, on: window) { [self] urls in browser?.upload(urls, to: self, into: dir) }
    }

    /// Download into a folder chosen on this Mac.
    @objc func downloadTo(_ sender: Any?) {
        let targets = targets(sender)
        guard !targets.isEmpty, let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Download"
        panel.message = "Download " + (targets.count == 1 ? "“\(targets[0].name)”" : FileList.items(targets.count))
            + " from \(session?.host.displayName ?? "the server") into the folder you choose"
        panel.directoryURL = URL(fileURLWithPath: browser?.settings.downloadFolder ?? NSHomeDirectory(), isDirectory: true)
        Panels.run(panel, on: window) { [self] urls in
            guard let folder = urls.first else { return }
            browser?.transfer(targets, from: source, to: .local, into: folder.path, move: false)
        }
    }

    /// The items as one .tar.gz streamed from the server (optionally unpacked here).
    @objc func downloadArchive(_ sender: Any?) {
        let targets = targets(sender)
        guard !targets.isEmpty else { return }
        browser?.downloadArchive(targets, from: self)
    }

    /// This Mac's items packed into one .tar.gz, uploaded and unpacked into the other pane's folder.
    @objc func uploadCompressed(_ sender: Any?) {
        let targets = targets(sender)
        guard !targets.isEmpty else { return }
        browser?.uploadCompressed(targets, from: self)
    }

    @objc func copy(_ sender: Any?) {
        browser?.copyToClipboard(targets(sender), from: self, cut: false)
    }

    @objc func cut(_ sender: Any?) {
        browser?.copyToClipboard(targets(sender), from: self, cut: true)
    }

    @objc func paste(_ sender: Any?) {
        browser?.paste(into: self)
    }

    /// The paths of the items (or of the folder shown), one per line.
    @objc func copyPath(_ sender: Any?) {
        let paths = targets(sender).map(\.path)
        let text = paths.isEmpty ? dir ?? "" : paths.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Menus

    /// The context menu for these rows (none: the folder's own menu). nil entries are separators.
    func contextMenu(for targets: [FileItem]) -> [(String, Selector)?] {
        let single = targets.count == 1 ? targets[0] : nil
        var entries: [(String, Selector)?] = []
        if targets.isEmpty {
            entries += [("New Folder…", #selector(newFolder(_:)))]
            if isRemote { entries += [("New File…", #selector(newFile(_:))), ("Upload…", #selector(chooseUpload(_:)))] }
            entries += [nil, ("Paste", #selector(paste(_:))), ("Copy Path", #selector(copyPath(_:))), nil]
            if isRemote {
                entries += [("Open Terminal Here", #selector(openTerminalHere(_:))),
                            ("Calculate Folder Sizes", #selector(calculateFolderSizes(_:))), ("Find Files…", #selector(findFiles(_:)))]
            } else {
                entries += [("Show in Finder", #selector(revealInFinder(_:)))]
            }
            entries += [("Synchronize…", #selector(synchronize(_:)))]
            entries += [(showHidden ? "Hide Hidden Files" : "Show Hidden Files", #selector(toggleHiddenFiles(_:))),
                        ("Refresh", #selector(refresh(_:)))]
            return entries
        }
        entries += [("Open", #selector(openItems(_:)))]
        if isRemote, single?.isFolder == false { entries += [("Edit in AirSCP", #selector(editItem(_:)))] }
        entries += [("Quick Look", #selector(quickLook(_:)))]
        entries += isRemote ? [("Get Info", #selector(getInfo(_:)))] : [("Show in Finder", #selector(revealInFinder(_:)))]
        entries.append(nil)
        if let title = browser?.transferTitle(for: self).menu { entries += [(title, #selector(copyToOtherPane(_:)))] }
        if isRemote {
            entries += [("Download To…", #selector(downloadTo(_:))), ("Download as .tar.gz…", #selector(downloadArchive(_:)))]
        } else if browser?.otherPane(of: self).isRemote == true {
            entries += [("Upload Compressed", #selector(uploadCompressed(_:)))]
        }
        if isRemote {
            entries.append(nil)
            if single?.kind == .file { entries += [("Run…", #selector(runItem(_:)))] }
            entries += [("Make Executable", #selector(makeExecutable(_:))), ("Permissions…", #selector(editPermissions(_:)))]
            if single?.isFolder == true { entries += [("Open Terminal Here", #selector(openTerminalHere(_:)))] }
        }
        entries += [nil, ("Rename…", #selector(renameItem(_:)))]
        if isRemote {
            entries += [("Duplicate", #selector(duplicateItems(_:))), ("Compress…", #selector(compressItems(_:)))]
            if let single, Session.isArchive(single.name) {
                entries += [("Extract Here", #selector(extractHere(_:))), ("Extract to New Folder", #selector(extractToFolder(_:)))]
            }
        }
        entries += [nil]
        if isRemote { entries += [("Cut", #selector(cut(_:)))] }
        entries += [("Copy", #selector(copy(_:))), ("Copy Path", #selector(copyPath(_:))), nil,
                    (isRemote ? "Delete…" : "Move to Trash", #selector(deleteItems(_:)))]
        return entries
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(addToFavourites(_:)), let favourites = item.menu?.item(withTitle: "Favourites")?.submenu {
            fillFavourites(favourites)
        }
        let (enabled, reason) = check(item.action, for: targets(item))
        if item.action == #selector(toggleHiddenFiles(_:)) { item.state = showHidden ? .on : .off }
        if item.action == #selector(toggleColumnNamed(_:)) {
            item.state = hiddenColumns.contains(item.representedObject as? String ?? "") ? .off : .on
        }
        if item.action == #selector(copyToOtherPane(_:)), item.menu !== table.menu,
           let title = browser?.transferTitle(for: self).menu {
            item.title = title
        }
        item.explain(enabled: enabled, reason: reason)
        return enabled
    }

    /// Whether `action` can run on `targets` now, and why not when that isn't obvious.
    func check(_ action: Selector?, for targets: [FileItem]) -> (Bool, String?) {
        // Menu shortcuts still reach the window.
        guard view.window?.attachedSheet == nil else { return (false, "A sheet is open: answer or close it first.") }
        let single = targets.count == 1 ? targets[0] : nil
        let shellReason = isRemote && !hasShell ? session?.capabilities.noShellReason : nil
        let listed = dir != nil && isConnected
        // Off with `reason`, unless the folder isn't there yet: that comes first.
        func need(_ ok: Bool, _ reason: String) -> (Bool, String?) {
            ok ? (true, nil) : (false, !isConnected ? "Not connected: connect the host first." : dir == nil ? "Open a folder first." : reason)
        }
        let serverOnly = "Works in a server pane."
        switch action {
        case #selector(goBack(_:)): return need(!back.isEmpty && isConnected, "Nothing to go back to: this is the first folder shown here.")
        case #selector(goForward(_:)): return need(!forward.isEmpty && isConnected, "Nothing to go forward to: Go ▸ Back first.")
        case #selector(goUp(_:)): return need(listed && dir != "/", "This is the top folder (/).")
        case #selector(goHome(_:)), #selector(goToFolder(_:)), #selector(refresh(_:)), #selector(newFolder(_:)),
             #selector(copyPath(_:)):
            return need(listed, "")
        case #selector(find(_:)), #selector(toggleHiddenFiles(_:)), #selector(toggleColumnNamed(_:)):
            return (true, nil)
        case #selector(openItems(_:)), #selector(quickLook(_:)), #selector(copy(_:)):
            return need(listed && !targets.isEmpty, "Select something first.")
        case #selector(revealInFinder(_:)):
            return isRemote ? (false, "Works in the This Mac pane.") : need(dir != nil, "")
        case #selector(editItem(_:)):
            return need(listed && isRemote && single.map { !$0.isFolder } == true, "Select one server file.")
        case #selector(getInfo(_:)):
            return need(listed && isRemote && single != nil, "Select one server item.")
        case #selector(renameItem(_:)):
            return need(listed && single != nil, "Select one item.")
        case #selector(deleteItems(_:)):
            return need(listed && !targets.isEmpty, "Select something first.")
        case #selector(newFile(_:)), #selector(chooseUpload(_:)):
            return isRemote ? need(listed, "") : (false, serverOnly)
        case #selector(downloadTo(_:)), #selector(cut(_:)):
            return isRemote ? need(listed && !targets.isEmpty, "Select server items first.") : (false, serverOnly)
        case #selector(paste(_:)):
            let problem = browser.map { $0.pasteProblem(into: self) } ?? "Copy items first (in AirSCP, or files in Finder)."
            return need(listed && problem == nil, problem ?? "")
        case #selector(copyToOtherPane(_:)):
            let other = browser?.otherPane(of: self)
            return need(listed && !targets.isEmpty && other?.dir != nil && other?.isConnected == true
                        && (isRemote || other?.isRemote == true), "Select something, and show a folder in the other pane.")
        case #selector(makeExecutable(_:)), #selector(editPermissions(_:)):
            guard isRemote else { return (false, serverOnly) }
            // Windows' OpenSSH answers chmod with success and changes nothing.
            if isWindows { return (false, "A Windows server has no Unix permissions: set them in Windows (the file's Properties ▸ Security).") }
            // A link's own permissions are 777, and chmod changes its target's: change them on the target.
            let link = targets.contains { $0.kind == .symlink }
            return need(listed && !targets.isEmpty && !link,
                        link ? "A symbolic link's permissions are its target's: change them on the target." : "Select server items first.")
        case #selector(duplicateItems(_:)):
            guard isRemote else { return (false, serverOnly) }
            return need(listed && hasShell && !targets.isEmpty, shellReason ?? "Select something first.")
        case #selector(runItem(_:)):
            guard isRemote else { return (false, serverOnly) }
            return need(listed && hasShell && isThisHost && single?.kind == .file,
                        shellReason ?? (isThisHost ? "Select one server file to run." : "Run works on the host whose workspace this is."))
        case #selector(openTerminalHere(_:)):
            guard isRemote else { return (false, serverOnly) }
            return need(listed && hasShell && isThisHost, shellReason ?? "Opens on this workspace's host only.")
        case #selector(calculateFolderSizes(_:)):
            guard isRemote else { return (false, serverOnly) }
            return need(listed && hasShell && items.contains(where: \.isFolder), shellReason ?? "There are no folders here to measure.")
        case #selector(findFiles(_:)):
            return isRemote ? need(listed, "") : (false, "Find Files searches a server's folders.")
        case #selector(addToFavourites(_:)):
            guard isRemote else { return (false, "Favourites keep a server's folders: focus a pane that shows a server.") }
            let kept = dir.map(favourites.contains) ?? false
            return need(listed && !kept, "This folder is in Go ▸ Favourites already.")
        case #selector(openFavourite(_:)), #selector(removeFavourite(_:)):
            return isRemote ? need(listed, "") : (false, "Favourites keep a server's folders: focus a pane that shows a server.")
        case #selector(synchronize(_:)):
            let other = browser?.otherPane(of: self)
            return (browser?.synchronizedPanes != nil, isRemote && other?.isRemote == true
                    ? "Synchronize compares a folder on this Mac with one on a server: show this Mac in the other pane."
                    : "Synchronize needs a folder on this Mac in one pane and a connected server's folder in the other.")
        case #selector(compressItems(_:)):
            guard isRemote else { return (false, serverOnly) }
            let reason = session.flatMap { session in
                [ArchiveFormat.zip, .tarGz].allSatisfy { session.compressUnavailableReason($0) != nil }
                    ? session.compressUnavailableReason(.tarGz) : nil
            }
            return need(listed && !targets.isEmpty && reason == nil, reason ?? "Select server items first.")
        case #selector(extractHere(_:)), #selector(extractToFolder(_:)):
            guard isRemote else { return (false, serverOnly) }
            let reason = single.flatMap { item in session?.extractUnavailableReason(item.name) }
            return need(listed && single.map { Session.isArchive($0.name) } == true && reason == nil,
                        reason ?? "Select one archive (.zip, .tar.gz, .tgz, .gz…).")
        case #selector(downloadArchive(_:)):
            guard isRemote else { return (false, serverOnly) }
            let reason = session?.compressUnavailableReason(.tarGz)
            return need(listed && !targets.isEmpty && reason == nil, reason ?? "Select server items first.")
        case #selector(uploadCompressed(_:)):
            guard !isRemote else { return (false, "Works in the This Mac pane, with a server's folder in the other pane.") }
            let other = browser?.otherPane(of: self)
            let reason = other?.session?.compressUnavailableReason(.tarGz)
            let serverShown = other?.isRemote == true && other?.dir != nil && other?.isConnected == true
            return need(listed && !targets.isEmpty && serverShown && reason == nil,
                        reason ?? (serverShown ? "Select items on this Mac first." : "Show a connected server's folder in the other pane."))
        default:
            return (true, nil)
        }
    }

    /// This pane shows the workspace's own host (Run and Terminal go to that host).
    var isThisHost: Bool {
        guard let session, let browser else { return false }
        return session.host.id == browser.session.host.id
    }
}

/// Asks for a file name in a sheet; `done` gets it as typed, unless cancelled. Names that can't be files are refused
/// with a message (`windows`: also those a Windows server can't store). `selectBaseName`: the part before the
/// extension is selected, as Finder does when renaming.
@MainActor
func askName(_ message: String, initial: String, button: String, on window: NSWindow, selectBaseName: Bool = false,
             windows: Bool = false, done: @escaping (String) -> Void) {
    let alert = NSAlert()
    alert.messageText = message
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
    field.stringValue = initial
    field.setAccessibilityIdentifier("prompt.name")
    field.toolTip = "Type the name"
    alert.accessoryView = field
    alert.addButton(withTitle: button).toolTip = message
    alert.addButton(withTitle: "Cancel").toolTip = "Close without doing anything"
    alert.window.initialFirstResponder = field
    alert.beginSheetModal(for: window) { response in
        guard response == .alertFirstButtonReturn else { return }
        let name = field.stringValue
        if let problem = FileList.nameProblem(name, windows: windows) {
            let refusal = NSAlert()
            refusal.messageText = "“\(name)” can't be used as a name"
            refusal.informativeText = problem
            refusal.addOK()
            refusal.beginSheetModal(for: window)
        } else {
            done(name)
        }
    }
    if selectBaseName {
        let base = (initial as NSString).deletingPathExtension
        DispatchQueue.main.async {
            field.currentEditor()?.selectedRange = NSRange(location: 0, length: (base.isEmpty ? initial : base).utf16.count)
        }
    }
}
