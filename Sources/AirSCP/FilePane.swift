import AirSCPCore
import AppKit
import Quartz
import UniformTypeIdentifiers

/// One side of the Files tab: a folder on this Mac or on a connected server, as a sortable table with a path bar
/// (click a folder to go there, ⇧⌘G to type a path), back / forward / up / home / refresh, a filter, hidden files on
/// request and a status line (items, selection and its size, free space). Listing, sorting and filtering run off the
/// main thread, so a folder of 50 000 entries never blocks the window. The file operations are in FileActions.swift;
/// copies between the two panes go through `BrowserContentController.transfer`.
@MainActor
final class FilePane: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate,
    NSMenuItemValidation, NSTextFieldDelegate, NSFilePromiseProviderDelegate, QLPreviewPanelDataSource,
    QLPreviewPanelDelegate {

    enum Source {
        case local
        case remote(Session)

        var session: Session? {
            if case .remote(let session) = self { return session }
            return nil
        }

        /// Both on this Mac, or both on the same server.
        func isSame(as other: Source) -> Bool {
            switch (self, other) {
            case (.local, .local): return true
            case (.remote(let a), .remote(let b)): return a.host.id == b.host.id
            default: return false
            }
        }
    }

    static let columns: [(id: String, title: String, width: CGFloat)] = [
        ("name", "Name", 200), ("size", "Size", 72), ("modified", "Date Modified", 166), ("permissions", "Permissions", 88),
        ("owner", "Owner", 70), ("group", "Group", 70), ("kind", "Kind", 130),
    ]

    private(set) var source: Source
    /// The left pane chooses its source (this Mac or a connected server); the right one is the workspace's host.
    let choosesSource: Bool
    weak var browser: BrowserContentController?
    /// The folder shown (nil until the first listing).
    private(set) var dir: String?
    /// The folder's entries, as listed.
    private(set) var items: [FileItem] = []
    /// What the table shows: `items` sorted, without hidden files (unless shown) and filtered.
    private(set) var rows: [FileItem] = [] {
        didSet { rowsShown += 1 }
    }
    /// Calculated folder sizes by name (Calculate Folder Sizes).
    private(set) var folderSizes: [String: Int64] = [:]
    private(set) var showHidden: Bool
    /// The last error (also shown in the window); for the tests.
    private(set) var lastError: Error?
    /// Rows dragged out of this table, for a drop on the other pane.
    private(set) var draggedItems: [FileItem] = []

    private var sortedItems: [FileItem] = []
    private var selectionCache: (indexes: IndexSet, rows: Int, items: [FileItem])?
    /// Counts the times `rows` changed.
    private var rowsShown = 0
    /// The listing under way, and Calculate Folder Sizes for the folder shown: going elsewhere stops them (remote ones
    /// hold the server's command lane, which every other listing waits for).
    private var listing: Task<Listed, Error>?
    var folderSizesTask: Task<Void, Never>?
    private typealias Listed = (items: [FileItem], sorted: [FileItem], rows: [FileItem], selection: IndexSet)
    private(set) var filter = ""
    private(set) var back: [String] = []
    private(set) var forward: [String] = []
    private var pathTargets: [String] = []
    private var listGeneration = 0
    private var rowsGeneration = 0
    /// The rows are being sorted and filtered again off the main thread: those shown are about to change (agents wait).
    private(set) var rebuilding = false
    private(set) var activities: [String] = []
    private var freeSpace: String?
    private var placeholderText = ""
    /// The folder's rows went when the connection ended; `dir` stays, listed again once connected (agents don't take
    /// the pane as listed meanwhile).
    private(set) var unlisted = false
    /// The connection's state in a word or two, for the status line while there is no folder ("Not connected").
    private var stateText = ""
    /// The host's start folder this pane opened at its last connect: an edited one applies at the next.
    private var startedIn: String?
    /// The folder shown instead of a start folder that couldn't be opened, and why, for the status line.
    private var startNote: (dir: String, text: String)?
    private var menuTargets: [FileItem]?

    let table = FileTableView()
    private let sourceButton = NSPopUpButton(frame: .zero, pullsDown: false)
    private let titleLabel = NSTextField(labelWithString: "")
    private let history = NSSegmentedControl()
    private let pathControl = NSPathControl()
    private let pathField = NSTextField()
    let filterField = NSSearchField()
    let statusLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let placeholder = NSTextField(wrappingLabelWithString: "")
    /// Under the placeholder of a server pane whose connection ended after it showed a folder.
    private let reconnectButton = NSButton(title: "Reconnect", target: nil, action: nil)
    private var hiddenButton: NSButton!
    private var sizesButton: NSButton!
    private var transferButton: NSButton!

    // Quick Look and file promises
    private var previewItems: [URL] = []
    private var previewFiles: [String: URL] = [:]
    private var controlsPreview = false

    private static var icons: [String: NSImage] = [:]
    private static var symbols: [String: (image: NSImage, color: NSColor)] = [:]
    /// The path bar's icons and the startup disk's name, looked up once.
    private static let pathIcons: (folder: NSImage, server: NSImage?, disk: NSImage, diskName: String) = {
        func small(_ image: NSImage?) -> NSImage? {
            let copy = image?.copy() as? NSImage
            copy?.size = NSSize(width: 14, height: 14)
            return copy
        }
        return (small(NSWorkspace.shared.icon(for: .folder))!, small(NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)),
                small(NSWorkspace.shared.icon(forFile: "/"))!, FileManager.default.displayName(atPath: "/"))
    }()
    private static let dates: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    init(source: Source, choosesSource: Bool, showHidden: Bool) {
        self.source = source
        self.choosesSource = choosesSource
        self.showHidden = showHidden
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: State for the other parts

    var session: Session? { source.session }
    var isRemote: Bool { session != nil }
    /// Commands can run: this Mac, or a connected server.
    var isConnected: Bool { session.map { $0.state == .connected } ?? true }
    var hasShell: Bool { session?.capabilities.shell ?? false }

    /// The selected rows (made once per selection: menus ask for them for every item they validate).
    var selectedItems: [FileItem] {
        let indexes = table.selectedRowIndexes
        if let cached = selectionCache, cached.indexes == indexes, cached.rows == rowsShown { return cached.items }
        let items = indexes.compactMap { $0 < rows.count ? rows[$0] : nil }
        selectionCache = (indexes, rowsShown, items)
        return items
    }

    /// The rows an action is for: a context menu's rows, else the selection.
    func targets(_ sender: Any?) -> [FileItem] {
        if let item = sender as? NSMenuItem, item.menu === table.menu, let menuTargets { return menuTargets }
        return selectedItems
    }

    /// The name shown for a folder of this pane: "dev" for /home/dev.
    func displayName(_ path: String) -> String {
        path == "/" ? (session?.host.displayName ?? "/") : RemotePath.name(path)
    }

    // MARK: Listing

    /// Shows another source (the left pane's Local / server choice), starting in its usual folder.
    func setSource(_ newSource: Source, startIn start: String) {
        listGeneration += 1  // a listing still running is for the old source
        listing?.cancel()
        folderSizesTask?.cancel()
        source = newSource
        dir = nil
        items = []
        rows = []
        sortedItems = []
        folderSizes = [:]
        back = []
        forward = []
        freeSpace = nil
        table.reloadData()
        updateSourceButton()
        updatePath()
        updatePlaceholder()
        updateStatus()
        browser?.otherPane(of: self).updateStatus()
        Task { await open(start) }
    }

    /// Lists `path` and shows it (a failed listing keeps the folder shown). `select`: names to select;
    /// `record`: add the folder left to the Back list; `quiet`: no error sheet; `failed`: gets the error (an agent's
    /// go answers with it). Returns whether it worked.
    @discardableResult
    func open(_ path: String, select: [String] = [], record: Bool = true, quiet: Bool = false,
              failed: ((Error) -> Void)? = nil) async -> Bool {
        listGeneration += 1
        let generation = listGeneration
        let source = self.source
        let sort = sortOrder, showHidden = self.showHidden
        let newFolder = path != dir
        let filter = newFolder ? "" : self.filter
        let keep = newFolder ? select : (select.isEmpty ? selectedItems.map(\.name) : select)
        begin("Loading…")
        defer { end() }
        listing?.cancel()  // its folder isn't wanted any more
        if newFolder { folderSizesTask?.cancel() }
        let task = Task.detached(priority: .userInitiated) { () -> Listed in
            let items: [FileItem]
            switch source {
            case .local: items = try FileList.local(path)
            case .remote(let session): items = try await session.list(path).map(FileItem.init)
            }
            let sorted = FileList.sorted(items, by: sort.key, ascending: sort.ascending, folderSizes: [:])
            let rows = FileList.visible(sorted, filter: filter, showHidden: showHidden)
            return (items, sorted, rows, FileList.indexes(of: keep, in: rows))
        }
        listing = task
        let listed: Listed
        do {
            listed = try await task.value
        } catch {
            if generation == listGeneration { failed?(error) }
            if generation == listGeneration && !quiet {
                // Not "Refresh the list": a folder typed or chosen that isn't there.
                var shown = error as? AirSCPError
                if shown?.kind == .noSuchFile { shown?.message = "“\(path)” doesn't exist (any more)." }
                report(shown ?? error, title: "Can't open “\(displayName(path))”")
            }
            return false
        }
        guard generation == listGeneration else { return false }
        if record, let dir, newFolder {
            back.append(dir)
            forward = []
        }
        if newFolder {
            self.filter = ""
            filterField.stringValue = ""
            freeSpace = nil
            previewFiles = [:]
        }
        dir = path
        unlisted = false
        items = listed.items
        sortedItems = listed.sorted
        folderSizes = [:]
        rowsGeneration += 1  // a rebuild still running is for the old listing
        rebuilding = false
        show(listed.rows, selecting: listed.selection, scroll: newFolder)
        updatePath()
        didList(path)
        return true
    }

    /// Lists the folder again, keeping the selection.
    func reload() async {
        guard let dir else { return }
        await openNearest(dir, record: false)
    }

    /// Opens `path`, or when it is gone (deleted on the server, say) the nearest folder above it that is there: the
    /// rows of a deleted folder stayed, and Refresh and Enclosing Folder only failed.
    @discardableResult
    func openNearest(_ path: String, select: [String] = [], record: Bool) async -> Bool {
        if await open(path, select: select, record: record, quiet: true) { return true }
        var nearest = path
        while nearest != "/", await isGone(nearest) { nearest = RemotePath.parent(nearest) }
        return await open(nearest, select: nearest == path ? select : [], record: record)
    }

    private func isGone(_ path: String) async -> Bool {
        guard let session else { return !FileManager.default.fileExists(atPath: path) }
        return (try? await session.exists(path)) == false
    }

    /// After a listing: free space, the local pane's folder for next time, folder sizes if always wanted.
    private func didList(_ path: String) {
        browser?.otherPane(of: self).updateStatus()  // its transfer button names this folder
        switch source {
        case .local:
            // The volume's free space counts purgeable space, which can take a while to work out: off the main thread.
            Task {
                let free = await Task.detached(priority: .utility) {
                    (try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                        .volumeAvailableCapacityForImportantUsage
                }.value
                guard let free, dir == path else { return }
                freeSpace = FileList.size(free) + " available"
                updateStatus()
            }
            if choosesSource { browser?.localFolderChanged(path) }
        case .remote(let session):
            Task {
                guard let free = try? await session.diskFree(path), dir == path else { return }
                freeSpace = FileList.size(free.available) + " available"
                updateStatus()
            }
            if browser?.settings.alwaysCalculateFolderSizes == true && hasShell { calculateFolderSizes(nil) }
        }
    }

    /// Sorts and filters `items` again off the main thread (`resort` false: the sorted list is still right).
    func rebuildRows(resort: Bool) {
        rowsGeneration += 1
        rebuilding = true
        let generation = rowsGeneration
        let items = self.items, cached = resort ? nil : sortedItems
        let sort = sortOrder, sizes = folderSizes, filter = self.filter, showHidden = self.showHidden
        let keep = selectedItems.map(\.name)
        Task {
            let (sorted, rows, selection) = await Task.detached(priority: .userInitiated) { () -> ([FileItem], [FileItem], IndexSet) in
                let sorted = cached ?? FileList.sorted(items, by: sort.key, ascending: sort.ascending, folderSizes: sizes)
                let rows = FileList.visible(sorted, filter: filter, showHidden: showHidden)
                return (sorted, rows, FileList.indexes(of: keep, in: rows))
            }.value
            guard generation == rowsGeneration else { return }
            sortedItems = sorted
            rebuilding = false
            show(rows, selecting: selection, scroll: false)
        }
    }

    /// `scroll`: another folder, so show its top (or the selection); a refresh keeps the scroll position.
    private func show(_ newRows: [FileItem], selecting indexes: IndexSet, scroll: Bool) {
        rows = newRows
        table.reloadData()
        table.selectRowIndexes(indexes, byExtendingSelection: false)
        if scroll { table.scrollRowToVisible(indexes.first ?? 0) }
        updatePlaceholder()
        updateStatus()
    }

    var sortOrder: (key: String, ascending: Bool) {
        let sort = table.sortDescriptors.first
        return (sort?.key ?? "name", sort?.ascending ?? true)
    }

    /// Stores calculated folder sizes and shows them.
    func setFolderSizes(_ sizes: [String: Int64]) {
        folderSizes.merge(sizes) { $1 }
        if sortOrder.key == "size" {
            rebuildRows(resort: true)
        } else {
            table.reloadData()
            updateStatus()
        }
    }

    /// The connection of a remote pane changed: list the start folder once connected, again after a reconnect.
    func connectionChanged(_ state: Session.State, startIn start: @autoclosure () -> String) {
        switch state {
        case .connected:
            let start = start()
            if let dir, start == startedIn {
                Task { await openNearest(dir, record: false) }  // (deleted meanwhile: the nearest folder above it)
            } else {
                startedIn = start
                Task {
                    // Home only when this listing failed, not when another took its place (a second state change).
                    let generation = listGeneration + 1
                    if await !open(start, quiet: true), generation == listGeneration, let home = session?.capabilities.home,
                       home != start {
                        await open(home)
                        startNote = (home, "the start folder \(start) can't be opened")
                        updateStatus()
                    }
                }
            }
        case .connecting: setPlaceholder("Connecting…")
        case .reconnecting: setPlaceholder("Reconnecting…")
        case .idle, .disconnected:
            // Its rows would be stale, and acting on them fails: they go. The folder stays, listed again once connected.
            forgetRows()
            if let dir {
                setPlaceholder("Disconnected. Reconnect to come back to \(dir).")
            } else if state == .idle {
                setPlaceholder("Not connected. Click Connect above to browse this host.")
            } else {
                setPlaceholder("Disconnected. Click Reconnect above.")
            }
        }
        stateText = MainWindowController.describe(state)
        updateStatus()
    }

    private func setPlaceholder(_ text: String) {
        placeholderText = text
        updatePlaceholder()
    }

    /// The rows of a server pane whose connection ended (a listing under way stops).
    private func forgetRows() {
        unlisted = dir != nil
        listGeneration += 1
        listing?.cancel()
        folderSizesTask?.cancel()
        items = []
        sortedItems = []
        folderSizes = [:]
        freeSpace = nil
        rowsGeneration += 1
        rebuilding = false
        show([], selecting: [], scroll: false)
    }

    /// No folder to show: none listed yet, or its rows went when the connection ended (until it is listed again): the
    /// placeholder and the status line say why.
    private var showsNoFolder: Bool { dir == nil || unlisted }

    /// The text over the table when it has no rows: why (not connected yet, an empty folder, the filter) and what to do;
    /// Reconnect once a folder was shown and the connection has ended.
    private func updatePlaceholder() {
        let text: String
        if showsNoFolder {
            text = placeholderText
        } else if rows.isEmpty {
            let term = filter.trimmingCharacters(in: .whitespaces)
            text = items.isEmpty ? (isRemote ? "Empty folder. Drag files here from Finder or the other pane to upload them."
                                    : "Empty folder.")
                : !term.isEmpty ? "Nothing matches “\(term)”." : "Only hidden files here: ⇧⌘. shows them."
        } else {
            text = ""
        }
        placeholder.stringValue = text
        placeholder.isHidden = text.isEmpty
        switch session?.state {
        case .idle?, .disconnected?: reconnectButton.isHidden = !unlisted
        default: reconnectButton.isHidden = true
        }
    }

    @objc private func reconnect(_ sender: Any?) {
        browser?.workspace?.connect()
    }

    // MARK: Activity and errors

    /// Shows `text` with a spinner until the matching `end()`.
    func begin(_ text: String) {
        activities.append(text)
        spinner.startAnimation(nil)
        spinner.isHidden = false
        updateStatus()
    }

    func end() {
        if !activities.isEmpty { activities.removeLast() }
        if activities.isEmpty {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
        updateStatus()
    }

    /// Runs remote or local work with a status text; errors are shown (not cancels or a lost connection).
    @discardableResult
    func perform(_ activity: String, failure title: String, _ work: () async throws -> Void) async -> Bool {
        begin(activity)
        defer { end() }
        do {
            try await work()
            return true
        } catch {
            report(error, title: title)
            return false
        }
    }

    func report(_ error: Error, title: String) {
        if (error as? AirSCPError)?.kind == .cancelled { return }  // stopped on purpose (e.g. the folder was left)
        lastError = error
        if let browser {
            browser.show(error, title: title, from: self)
        } else {
            log.error("\(title, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Navigation (Go menu, buttons, path bar)

    @objc func goBack(_ sender: Any?) {
        guard let previous = back.last, let dir else { return }
        Task {
            if await open(previous, record: false) {
                back.removeLast()
                forward.append(dir)
            }
        }
    }

    @objc func goForward(_ sender: Any?) {
        guard let next = forward.last, let dir else { return }
        Task {
            if await open(next, record: false) {
                forward.removeLast()
                back.append(dir)
            }
        }
    }

    @objc func goUp(_ sender: Any?) {
        guard let dir, dir != "/" else { return }
        Task { await openNearest(RemotePath.parent(dir), select: [RemotePath.name(dir)], record: true) }
    }

    @objc func goHome(_ sender: Any?) {
        Task { await open(home) }
    }

    var home: String {
        session.map { $0.capabilities.home } ?? NSHomeDirectory()
    }

    @objc func refresh(_ sender: Any?) {
        Task { await reload() }
    }

    @objc private func historyClicked(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? goBack(sender) : goForward(sender)
    }

    @objc private func pathClicked(_ sender: NSPathControl) {
        guard let item = sender.clickedPathItem, let index = sender.pathItems.firstIndex(of: item),
              index < pathTargets.count, let dir else { return }
        let target = pathTargets[index]
        if target == dir { return }
        // Going up selects the folder that was shown (or the one on the way to it).
        let below = dir.hasPrefix(target == "/" ? "/" : target + "/")
            ? String(dir.dropFirst(target == "/" ? 1 : target.count + 1)).split(separator: "/").first.map(String.init) : nil
        Task { await open(target, select: below.map { [$0] } ?? []) }
    }

    /// ⇧⌘G: the path bar becomes a field to type a folder into.
    @objc func goToFolder(_ sender: Any?) {
        guard dir != nil || !isRemote else { return }
        pathField.stringValue = dir ?? home
        pathField.isHidden = false
        pathControl.isHidden = true
        view.window?.makeFirstResponder(pathField)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard control === pathField else { return false }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            let typed = pathField.stringValue
            endGoTo(refocus: true)
            if let target = resolve(typed) { Task { await open(target) } }
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            endGoTo(refocus: true)
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if notification.object as? NSTextField === pathField { endGoTo(refocus: false) }
    }

    /// Back to the path bar; `refocus` (Return, Escape): back to the table too.
    private func endGoTo(refocus: Bool) {
        guard !pathField.isHidden else { return }
        pathField.isHidden = true
        pathControl.isHidden = false
        if refocus { view.window?.makeFirstResponder(table) }
    }

    /// A typed path as a folder of this pane: ~ is the home folder, relative paths start in the folder shown.
    func resolve(_ typed: String) -> String? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // A Windows server's path as Windows writes it ("C:\\Windows"): sftp's is "/C:/Windows".
        if isWindows {
            text = text.replacingOccurrences(of: "\\", with: "/")
            if text.range(of: "^[A-Za-z]:", options: .regularExpression) != nil { text = "/" + text }
        }
        if text == "~" {
            text = home
        } else if text.hasPrefix("~/") {
            text = RemotePath.join(home, String(text.dropFirst(2)))
        }
        if !text.hasPrefix("/") { text = RemotePath.join(dir ?? home, text) }
        return Self.normalized(text)
    }

    /// "/a/./b/../c/" → "/a/c" (by name: links aren't followed).
    static func normalized(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == ".." {
                _ = parts.popLast()
            } else {
                parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// ⌘F: the filter field.
    @objc func find(_ sender: Any?) {
        view.window?.makeFirstResponder(filterField)
    }

    @objc private func filterChanged(_ sender: NSSearchField) {
        guard sender.stringValue != filter else { return }
        filter = sender.stringValue
        rebuildRows(resort: false)
    }

    /// No filter (Find Files' Show of an item it would hide).
    func clearFilter() {
        filterField.stringValue = ""
        filter = ""
        rebuildRows(resort: false)
    }

    /// ⇧⌘.: hidden files on or off, for this pane.
    @objc func toggleHiddenFiles(_ sender: Any?) {
        showHidden.toggle()
        hiddenButton.state = showHidden ? .on : .off
        hiddenButton.image = NSImage(systemSymbolName: showHidden ? "eye" : "eye.slash", accessibilityDescription: "Hidden files")
        rebuildRows(resort: false)
    }

    @objc private func sourceChosen(_ sender: NSPopUpButton) {
        let session = sender.selectedItem?.representedObject as? Session
        browser?.chooseSource(session.map(Source.remote) ?? .local, for: self)
    }

    // MARK: Layout

    override func loadView() {
        for spec in Self.columns {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(spec.id))
            column.title = spec.title
            column.headerToolTip = Self.columnTips[spec.id]
            column.width = spec.width
            column.minWidth = spec.id == "name" ? 120 : 40
            column.sortDescriptorPrototype = NSSortDescriptor(key: spec.id, ascending: true)
            if spec.id == "size" { column.headerCell.alignment = .right }
            table.addTableColumn(column)
        }
        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        table.style = .fullWidth
        // Clear, on the pane's surface (Night Harbor's wash shows through); the rows draw the zebra stripes and the
        // selection (FileRowView), with hairlines between them.
        table.backgroundColor = .clear
        table.gridStyleMask = .solidHorizontalGridLineMask
        table.allowsMultipleSelection = true
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        // The names from before the rename (PLAN.md X): the column layouts copied from Porter's defaults still apply.
        table.autosaveName = layoutName(choosesSource ? "Porter.LeftPane" : "Porter.RightPane")
        // Only with a name: without one AppKit saves the columns under "(null)" in the user's defaults.
        table.autosaveTableColumns = table.autosaveName != nil
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked(_:))
        table.setDraggingSourceOperationMask([.copy, .move], forLocal: true)
        table.setDraggingSourceOperationMask(.copy, forLocal: false)
        table.registerForDraggedTypes([.fileURL] + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) })
        table.draggingDestinationFeedbackStyle = .regular
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let headerMenu = NSMenu()
        headerMenu.delegate = self
        table.headerView?.menu = headerMenu

        let scroll = FileScrollView()
        scroll.automaticallyAdjustsContentInsets = false  // its insets are FileScrollView's
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true

        sourceButton.controlSize = .small
        sourceButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        sourceButton.target = self
        sourceButton.action = #selector(sourceChosen(_:))
        sourceButton.menu?.delegate = self
        sourceButton.autoenablesItems = false  // its items have no action of their own
        sourceButton.isHidden = !choosesSource
        sourceButton.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.font = .boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.isHidden = choosesSource
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        history.segmentCount = 2
        history.trackingMode = .momentary
        history.segmentStyle = .separated
        history.controlSize = .small
        for (index, (symbol, label, tip)) in [("chevron.left", "Back", "Go back to the folder shown before (⌘[)"),
                                              ("chevron.right", "Forward", "Go forward again (⌘])")].enumerated() {
            history.setImage(NSImage(systemSymbolName: symbol, accessibilityDescription: label), forSegment: index)
            history.setWidth(22, forSegment: index)
            history.setToolTip(tip, forSegment: index)
        }
        history.toolTip = "Back and forward through the folders shown"
        history.target = self
        history.action = #selector(historyClicked(_:))
        let up = smallButton("arrow.up", "Enclosing folder", #selector(goUp(_:)), tip: "Go up one folder (⌘↑)")
        let homeButton = smallButton("house", "Home folder", #selector(goHome(_:)), tip: "Go to the home folder (⇧⌘H)")
        let refresh = smallButton("arrow.clockwise", "Refresh", #selector(refresh(_:)), tip: "List the folder again (⌘R)")
        filterField.placeholderString = "Filter by name"
        filterField.toolTip = "Show only names containing this; ⌘F focuses it"
        filterField.controlSize = .small
        filterField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        filterField.sendsSearchStringImmediately = true
        filterField.target = self
        filterField.action = #selector(filterChanged(_:))
        filterField.widthAnchor.constraint(lessThanOrEqualToConstant: 170).isActive = true
        filterField.widthAnchor.constraint(greaterThanOrEqualToConstant: 70).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let top = NSStackView(views: [sourceButton, titleLabel, history, up, homeButton, refresh, spacer, filterField])
        top.spacing = 6
        top.setHuggingPriority(.defaultLow, for: .horizontal)
        top.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)

        pathControl.pathStyle = .standard
        pathControl.controlSize = .small
        pathControl.focusRingType = .none
        pathControl.target = self
        pathControl.action = #selector(pathClicked(_:))
        pathControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        pathControl.setContentHuggingPriority(.init(1), for: .horizontal)
        pathControl.toolTip = "Click a folder to go there; ⇧⌘G to type a path"
        pathField.controlSize = .small
        pathField.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        pathField.delegate = self
        pathField.isHidden = true
        pathField.placeholderString = "Type a path (~ is home), then Return"
        pathField.toolTip = "Return goes there, Escape cancels"
        pathField.setContentHuggingPriority(.init(1), for: .horizontal)
        let pathRow = NSView()
        for field in [pathControl, pathField] as [NSView] {
            field.translatesAutoresizingMaskIntoConstraints = false
            pathRow.addSubview(field)
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: pathRow.leadingAnchor, constant: 8),
                field.trailingAnchor.constraint(equalTo: pathRow.trailingAnchor, constant: -8),
                field.centerYAnchor.constraint(equalTo: pathRow.centerYAnchor),
            ])
        }
        pathRow.heightAnchor.constraint(equalToConstant: 22).isActive = true

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.isHidden = true
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.toolTip = "Items shown of the items in the folder, the selection and its size, and the free space"
        titleLabel.toolTip = "This host's files"
        sizesButton = smallButton("sum", "Calculate folder sizes", #selector(calculateFolderSizes(_:)),
                                  tip: "Work out each folder's size (du); Settings can do it always")
        hiddenButton = smallButton(showHidden ? "eye" : "eye.slash", "Hidden files", #selector(toggleHiddenFiles(_:)),
                                   tip: "Show or hide files whose names start with a dot (⇧⌘.)")
        hiddenButton.setButtonType(.pushOnPushOff)
        hiddenButton.state = showHidden ? .on : .off
        // The pane's primary button: the accent in Night Harbor, Paper's black pill.
        transferButton = NSButton(title: "", target: self, action: #selector(copyToOtherPane(_:)))
        transferButton.bezelStyle = .push
        transferButton.bezelColor = .pill
        transferButton.controlSize = .small
        transferButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .semibold)
        transferButton.imagePosition = choosesSource ? .imageTrailing : .imageLeading
        transferButton.image = NSImage(systemSymbolName: choosesSource ? "chevron.right" : "chevron.left", accessibilityDescription: nil)
        let bottomSpacer = NSView()
        bottomSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bottom = NSStackView(views: [spinner, statusLabel, bottomSpacer, sizesButton, hiddenButton, transferButton])
        bottom.spacing = 6
        bottom.setHuggingPriority(.defaultLow, for: .horizontal)
        bottom.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)

        // The controls and the status line on the pane's bars, hairlines under the controls and the path.
        let stack = NSStackView(views: [Self.bar(top), Self.separator(), pathRow, Self.separator(), scroll, Self.separator(),
                                        Self.bar(bottom)])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        // No size of its own: the pane takes whatever room its container gives it.
        stack.setHuggingPriority(.init(1), for: .vertical)
        stack.setHuggingPriority(.init(1), for: .horizontal)
        scroll.setContentHuggingPriority(.init(1), for: .vertical)
        scroll.setContentHuggingPriority(.init(1), for: .horizontal)

        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.isSelectable = false
        placeholder.isHidden = true
        reconnectButton.target = self
        reconnectButton.action = #selector(reconnect(_:))
        reconnectButton.toolTip = "Connect to this host again and show this folder (⌘K)"
        reconnectButton.isHidden = true
        reconnectButton.translatesAutoresizingMaskIntoConstraints = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        // Wrapped to fit the narrowest pane (260): in one line, a server folder's hint was wider than a pane of the default
        // window, and cut off at both ends.
        placeholder.preferredMaxLayoutWidth = 240
        // A card in Paper, 10 points from the window's edges and 5 from the divider; edge to edge in Night Harbor.
        let card = SurfaceView(.content, card: true)
        let view = CardHolder(card: card, paperInsets: NSEdgeInsets(top: 10, left: choosesSource ? 10 : 5, bottom: 10,
                                                                    right: choosesSource ? 5 : 10))
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        card.addSubview(placeholder)
        card.addSubview(reconnectButton)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            placeholder.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            placeholder.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            placeholder.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            reconnectButton.centerXAnchor.constraint(equalTo: placeholder.centerXAnchor),
            reconnectButton.topAnchor.constraint(equalTo: placeholder.bottomAnchor, constant: 10),
            view.widthAnchor.constraint(greaterThanOrEqualToConstant: 260),
        ])
        self.view = view
        // Stable names for agents (PLAN.md T): "left.filter", "right.refresh", …
        let side = choosesSource ? "left." : "right."
        let named: [(NSView, String)] = [(table, "table"), (sourceButton, "source"), (history, "history"), (up, "up"),
                                          (homeButton, "home"), (refresh, "refresh"), (filterField, "filter"),
                                          (pathControl, "path"), (pathField, "goTo"), (sizesButton, "sizes"),
                                          (hiddenButton, "hidden"), (transferButton, "transfer"),
                                          (reconnectButton, "reconnect")]
        for (control, name) in named { control.setAccessibilityIdentifier(side + name) }
        updateSourceButton()
        updateStatus()
    }

    /// `content` on a pane bar, 6 points above and below it.
    private static func bar(_ content: NSView) -> NSView {
        let bar = SurfaceView(.bar)
        content.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: bar.topAnchor, constant: 6),
            content.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -6),
            content.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
        ])
        return bar
    }

    private static func separator() -> NSView {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    private func smallButton(_ symbol: String, _ label: String, _ action: Selector, tip: String) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label) ?? NSImage(),
                              target: self, action: action)
        button.bezelStyle = .recessed
        button.controlSize = .small
        button.toolTip = tip
        return button
    }

    /// The column headers' tooltips (right-click a header to choose the columns).
    static let columnTips = [
        "name": "Click to sort by name; right-click to choose the columns",
        "size": "File size; folders show — until View ▸ Calculate Folder Sizes",
        "modified": "When the item last changed",
        "permissions": "Who may read (r), write (w) and run (x) it: owner, group, others",
        "owner": "The account that owns it; point at one to see its user ID",
        "group": "The group that owns it; point at one to see its group ID",
        "kind": "What kind of item it is",
    ]

    private func updateSourceButton() {
        titleLabel.stringValue = session?.host.displayName ?? "This Mac"
        guard choosesSource else { return }
        let title = session?.host.displayName ?? "This Mac"
        sourceButton.removeAllItems()
        sourceButton.addItem(withTitle: title)
        sourceButton.lastItem?.representedObject = session
        sourceButton.lastItem?.image = NSImage(systemSymbolName: isRemote ? "server.rack" : "laptopcomputer",
                                               accessibilityDescription: nil)
        sourceButton.toolTip = "Show this Mac's files or another connected server's here"
    }

    /// The source menu lists this Mac and the connected servers when it opens.
    private func fillSourceMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        let local = NSMenuItem(title: "This Mac", action: nil, keyEquivalent: "")
        local.image = NSImage(systemSymbolName: "laptopcomputer", accessibilityDescription: nil)
        local.toolTip = "Show this Mac's files in this pane"
        menu.addItem(local)
        for session in browser?.connectedSessions ?? [] {
            let item = NSMenuItem(title: session.host.displayName, action: nil, keyEquivalent: "")
            item.representedObject = session
            item.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
            item.toolTip = "Show this server's files in this pane: copies then go server to server"
            menu.addItem(item)
        }
        let current = menu.items.first { ($0.representedObject as? Session) === session } ?? local
        sourceButton.select(current)
    }

    func updatePath() {
        guard let dir else {
            pathControl.pathItems = []
            pathTargets = []
            history.setEnabled(false, forSegment: 0)
            history.setEnabled(false, forSegment: 1)
            return
        }
        var targets: [String] = ["/"]
        for part in dir.split(separator: "/") { targets.append(RemotePath.join(targets.last!, String(part))) }
        let items = targets.map { target -> NSPathControlItem in
            let item = NSPathControlItem()
            if target != "/" {
                item.title = RemotePath.name(target)
                item.image = Self.pathIcons.folder
            } else if let session {
                item.title = session.host.displayName
                item.image = Self.pathIcons.server
            } else {
                item.title = Self.pathIcons.diskName
                item.image = Self.pathIcons.disk
            }
            return item
        }
        pathControl.pathItems = items
        pathTargets = targets
        history.setEnabled(!back.isEmpty, forSegment: 0)
        history.setEnabled(!forward.isEmpty, forSegment: 1)
    }

    /// "1,234 items, 3 selected (4.2 MB) — 12 GB available", or what is going on.
    func updateStatus() {
        if let activity = activities.last {
            statusLabel.stringValue = activity
        } else if showsNoFolder {
            statusLabel.stringValue = stateText
        } else {
            var text = FileList.items(rows.count)
            if rows.count != items.count { text = "\(rows.count.formatted()) of \(FileList.items(items.count))" }
            let selected = selectedItems
            if !selected.isEmpty {
                text += ", \(selected.count.formatted()) selected"
                let size = selected.reduce(Int64(0)) { $0 + ($1.isFolder ? folderSizes[$1.name] ?? 0 : $1.size) }
                if size > 0 { text += " (\(FileList.size(size)))" }
            }
            if let freeSpace { text += " — " + freeSpace }
            if let startNote, startNote.dir == dir { text += " — " + startNote.text }
            if !isConnected { text += " — not connected" }
            statusLabel.stringValue = text
        }
        if transferButton != nil {
            let titles = browser?.transferTitle(for: self) ?? BrowserContentController.TransferTitles()
            transferButton.title = titles.button
            transferButton.setAccessibilityLabel(titles.button)  // not the arrow's "Left" or "Right"
            transferButton.toolTip = selectedItems.isEmpty ? "Select items first, then this copies them: "
                + (titles.tip ?? "").prefix(1).lowercased() + (titles.tip ?? "").dropFirst() : titles.tip
            transferButton.isHidden = titles.button.isEmpty
            sizesButton.isHidden = !isRemote
        }
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier, row < rows.count else { return nil }
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? makeCell(id)
        let item = rows[row]
        let text: String
        var tip: String?
        switch id.rawValue {
        case "name":
            text = item.name
            let symbol = Self.symbol(for: item)
            cell.imageView?.image = symbol.image
            (cell as? FileCellView)?.tint = symbol.color
            cell.textField?.textColor = item.isHidden ? .secondaryLabelColor : .labelColor
        case "size":
            if item.isFolder {
                text = folderSizes[item.name].map(FileList.size) ?? "—"
            } else {
                text = item.kind == .file ? FileList.size(item.size) : "—"
            }
        case "modified": text = item.modified.map { item.dateOnly ? FileList.day($0) : Self.dates.string(from: $0) } ?? "—"
        case "permissions": text = item.permissions
        case "owner":
            text = item.owner
            tip = Self.idTip(item.owner, item.ownerID, "user")
        case "group":
            text = item.group
            tip = Self.idTip(item.group, item.groupID, "group")
        default: text = FileList.kind(of: item)
        }
        cell.textField?.stringValue = text
        cell.toolTip = tip
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { FileRowView() }

    /// An Owner or Group cell's tooltip: the name (the column may cut it off) with its number, "dev (user ID 1000)"; the
    /// number alone when the server has no name for it.
    static func idTip(_ name: String, _ id: Int?, _ kind: String) -> String? {
        id.map { name == String($0) ? "\(kind.capitalized) ID \($0)" : "\(name) (\(kind) ID \($0))" }
    }

    private func makeCell(_ id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = FileCellView()
        cell.identifier = id
        let text = NSTextField(labelWithString: "")
        text.lineBreakMode = id.rawValue == "name" ? .byTruncatingMiddle : .byTruncatingTail
        text.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(text)
        cell.textField = text
        var leading = cell.leadingAnchor
        if id.rawValue == "name" {
            let image = NSImageView()
            image.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(image)
            cell.imageView = image
            NSLayoutConstraint.activate([
                image.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                image.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant: 16),
                image.heightAnchor.constraint(equalToConstant: 16),
            ])
            leading = image.trailingAnchor
        } else {
            text.textColor = .secondaryLabelColor
        }
        if id.rawValue == "size" {
            text.alignment = .right
            text.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        } else if id.rawValue == "permissions" {
            text.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        }
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: leading, constant: 4),
            text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
            text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    /// The type's icon (Get Info), made once per kind of file.
    static func icon(for item: FileItem) -> NSImage {
        let type = FileList.type(of: item)
        if let icon = icons[type.identifier] { return icon }
        let icon = NSWorkspace.shared.icon(for: type)
        icons[type.identifier] = icon
        return icon
    }

    /// The item's symbol in its kind's colour (PLAN.md O.1): Night Harbor gives folders, scripts, code, data, settings,
    /// text and secrets each their hue; Paper draws them in labelColor (folders) and labelColor at 62 %.
    static func symbol(for item: FileItem) -> (image: NSImage, color: NSColor) {
        let name = item.name.lowercased(), ext = (name as NSString).pathExtension
        let kind: (symbol: String, hue: NSColor?)
        switch item.kind {
        case .directory: kind = ("folder.fill", .systemBlue)
        case .symlink: kind = ("link", nil)
        case .other: kind = ("doc", nil)
        case .file:
            if name.hasPrefix(".env") || name.hasPrefix("id_") || ["pem", "key", "ppk", "p12", "pfx"].contains(ext) {
                kind = ("lock.doc", .systemYellow)
            } else if ["sh", "bash", "zsh", "command"].contains(ext) || (ext.isEmpty && item.mode & 0o111 != 0) {
                kind = ("doc.text", .systemGreen)
            } else if ["php", "js", "mjs", "ts", "jsx", "tsx", "py", "rb", "go", "rs", "swift", "java", "kt", "c", "h", "cpp",
                        "cs", "html", "htm", "css", "scss", "vue", "pl", "lua"].contains(ext) {
                kind = ("doc.text", .systemPurple)
            } else if ["json", "xml", "yml", "yaml", "toml", "csv", "sql"].contains(ext) {
                kind = ("doc.text", .systemOrange)
            } else if ["conf", "cfg", "ini", "service"].contains(ext) {
                kind = ("doc", .systemTeal)
            } else if ["md", "txt", "log", "rst"].contains(ext) {
                kind = ("doc", .systemCyan)
            } else {
                kind = ("doc", nil)
            }
        }
        let key = kind.symbol + "\u{0}" + (kind.hue.map { "\($0)" } ?? "")
        if let cached = symbols[key] { return cached }
        let image = NSImage(systemSymbolName: kind.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular)) ?? NSImage()
        let folder = item.kind == .directory
        let color = NSColor(name: nil) { appearance in
            appearance.isDark ? kind.hue ?? NSColor.labelColor.withAlphaComponent(0.6)
                : folder ? .labelColor : NSColor.labelColor.withAlphaComponent(0.62)
        }
        symbols[key] = (image, color)
        return (image, color)
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        rebuildRows(resort: true)
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        row < rows.count ? rows[row].name : nil
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateStatus()
        if controlsPreview && QLPreviewPanel.shared().isVisible { preparePreview { QLPreviewPanel.shared().reloadData() } }
    }

    @objc private func doubleClicked(_ sender: NSTableView) {
        if sender.clickedRow >= 0 { openItems(sender) }
    }

    // MARK: Context menus

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === sourceButton.menu { return fillSourceMenu(menu) }
        menu.removeAllItems()
        if menu === table.headerView?.menu {
            for column in table.tableColumns where column.identifier.rawValue != "name" {
                let item = NSMenuItem(title: column.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.toolTip = MenuHelp.tips[#selector(toggleColumn(_:))]
                item.target = self
                item.representedObject = column
                item.state = column.isHidden ? .off : .on
                menu.addItem(item)
            }
            return
        }
        let clicked = table.clickedRow
        if clicked >= 0 && clicked < rows.count {
            menuTargets = table.selectedRowIndexes.contains(clicked) ? selectedItems : [rows[clicked]]
        } else {
            menuTargets = []
        }
        for entry in contextMenu(for: menuTargets ?? []) {
            guard let (title, action) = entry else {
                if menu.items.last?.isSeparatorItem == false { menu.addItem(.separator()) }
                continue
            }
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            item.toolTip = MenuHelp.tips[action]
            menu.addItem(item)
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.numberOfItems - 1) }
    }

    @objc func toggleColumn(_ sender: NSMenuItem) {
        (sender.representedObject as? NSTableColumn)?.isHidden.toggle()
    }

    /// View ▸ Columns ▸ <column> (the item's representedObject is the column's id): shows or hides it in this pane, as
    /// the header's menu does.
    @objc func toggleColumnNamed(_ sender: NSMenuItem) {
        table.tableColumns.first { $0.identifier.rawValue == sender.representedObject as? String }?.isHidden.toggle()
    }

    /// The ids of the columns hidden in this pane.
    var hiddenColumns: [String] { table.tableColumns.filter(\.isHidden).map(\.identifier.rawValue) }

    // MARK: Drag and drop

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < rows.count, isConnected else { return nil }
        let item = rows[row]
        guard let session else { return NSURL(fileURLWithPath: item.path) }
        // To Finder (and other apps): a file promise, kept by downloading the item where it was dropped. AppKit takes a
        // file's or a folder's type only (a link's or a special file's raises): those promise plain data.
        let type: UTType = item.kind == .directory ? .folder : item.kind == .file ? FileList.type(of: item) : .data
        let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: self)
        provider.userInfo = PromisedFile(session: session, path: item.path, name: item.name, isFolder: item.kind != .file,
                                         preserveTimes: browser?.settings.preserveTimes ?? false)
        return provider
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, willBeginAt screenPoint: NSPoint,
                   forRowIndexes rowIndexes: IndexSet) {
        draggedItems = rowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil }
    }

    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession, endedAt screenPoint: NSPoint,
                   operation: NSDragOperation) {
        draggedItems = []
    }

    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        guard let browser, isConnected, let target = dropTarget(row: row, operation: dropOperation, info: info) else { return [] }
        if target.wholeTable { tableView.setDropRow(-1, dropOperation: .on) }
        if let from = browser.pane(dragging: info) {
            return BrowserContentController.dropOperation(from.draggedItems, from: from.source, to: source, into: target.dir,
                                                          mask: info.draggingSourceOperationMask)
        }
        return isRemote && !fileURLs(info).isEmpty ? .copy : []
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo, row: Int,
                   dropOperation: NSTableView.DropOperation) -> Bool {
        guard let browser, let target = dropTarget(row: row, operation: dropOperation, info: info) else { return false }
        if let from = browser.pane(dragging: info) {
            let operation = BrowserContentController.dropOperation(from.draggedItems, from: from.source, to: source,
                                                                   into: target.dir, mask: info.draggingSourceOperationMask)
            guard !operation.isEmpty else { return false }
            browser.transfer(from.draggedItems, from: from.source, to: source, into: target.dir, move: operation == .move)
            return true
        }
        let dropped = fileURLs(info)
        guard isRemote, !dropped.isEmpty else { return false }
        browser.upload(dropped, to: self, into: target.dir)
        return true
    }

    /// The folder a drop goes into: the folder row under the pointer, else the folder shown (the whole table lights up).
    private func dropTarget(row: Int, operation: NSTableView.DropOperation, info: NSDraggingInfo)
        -> (dir: String, wholeTable: Bool)? {
        if operation == .on, row >= 0, row < rows.count, rows[row].isFolder,
           !(browser?.pane(dragging: info)?.draggedItems.contains { $0.path == rows[row].path } ?? false) {
            return (rows[row].path, false)
        }
        return dir.map { ($0, true) }
    }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    // MARK: File promises (drag to Finder)

    /// What a dragged server item promises: a download into the folder it is dropped on.
    final class PromisedFile {
        let session: Session
        let path: String
        let name: String
        let isFolder: Bool
        let preserveTimes: Bool

        init(session: Session, path: String, name: String, isFolder: Bool, preserveTimes: Bool) {
            self.session = session
            self.path = path
            self.name = name
            self.isFolder = isFolder
            self.preserveTimes = preserveTimes
        }
    }

    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        (provider.userInfo as? PromisedFile)?.name ?? "Untitled"
    }

    nonisolated func operationQueue(for provider: NSFilePromiseProvider) -> OperationQueue { filePromiseQueue }

    /// On `promiseQueue`: queues a normal download to exactly where Finder wants the item (Finder may have renamed it)
    /// and returns when that transfer has ended (Finder shows the item then).
    nonisolated func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL,
                                         completionHandler: @escaping (Error?) -> Void) {
        guard let promise = provider.userInfo as? PromisedFile else { return completionHandler(nil) }
        let queue = promise.session.transfers
        let id = queue.download(promise.path, to: url.path, isFolder: promise.isFolder, preserveTimes: promise.preserveTimes)
        var job: TransferJob?
        repeat {
            Thread.sleep(forTimeInterval: 0.2)
            job = queue.jobs.first { $0.id == id }
        } while job.map { !$0.status.isFinished } ?? false
        switch job?.status {
        case .done?, .completedWithErrors?: completionHandler(nil)
        case .failed(let error)?: completionHandler(error)
        default: completionHandler(CocoaError(.userCancelled))
        }
    }

    // MARK: Quick Look

    /// Space, ⌘Y: the preview panel on or off. Files on a server are downloaded for it first (up to 100 MB each).
    @objc func quickLook(_ sender: Any?) {
        if QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible {
            QLPreviewPanel.shared().orderOut(nil)
        } else if !selectedItems.isEmpty {
            preparePreview { QLPreviewPanel.shared().makeKeyAndOrderFront(nil) }
        }
    }

    static let previewLimit: Int64 = 100 << 20

    /// Sets `previewItems` for the selection (downloading server files not fetched yet), then calls `done`.
    private func preparePreview(then done: @escaping () -> Void) {
        let selected = selectedItems
        guard let session else {
            previewItems = selected.map { URL(fileURLWithPath: $0.path) }
            return done()
        }
        let files = selected.filter { $0.kind != .directory }
        let small = files.filter { $0.size <= Self.previewLimit }  // a link's own size: its target's is checked as it comes
        guard !small.isEmpty else {
            if !files.isEmpty { statusLabel.stringValue = "Quick Look shows files up to \(FileList.size(Self.previewLimit)) from a server." }
            return
        }
        // Keyed by size and date too, so a changed file is fetched again.
        func key(_ item: FileItem) -> String { "\(item.path)\u{0}\(item.size)\u{0}\(item.modified?.timeIntervalSince1970 ?? 0)" }
        let missing = small.filter { previewFiles[key($0)] == nil }
        Task {
            if !missing.isEmpty, let folder = browser?.temporaryFolder() {
                await perform("Preparing the preview…", failure: "Can't preview the file") {
                    for item in missing {
                        let local = folder.appendingPathComponent(item.name)
                        try await session.fetch(item.path, to: local, limit: Self.previewLimit,
                                                tooLarge: "Quick Look shows files up to \(FileList.size(Self.previewLimit)) from a server.")
                        previewFiles[key(item)] = local
                    }
                }
            }
            previewItems = small.compactMap { previewFiles[key($0)] }
            if !previewItems.isEmpty { done() }
        }
    }

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        controlsPreview = true
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        controlsPreview = false
        panel.dataSource = nil
        panel.delegate = nil
    }

    // Quick Look asks on the main thread.
    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { previewItems.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        MainActor.assumeIsolated { previewItems[index] } as NSURL
    }

    /// Arrow keys in the panel move the table's selection, so the preview follows it. Delete doesn't delete from there.
    nonisolated func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode != 51, event.keyCode != 117 else { return false }
        return MainActor.assumeIsolated {
            table.keyDown(with: event)
            return true
        }
    }
}

/// File promises are kept on this queue, one at a time: each waits for its download to end, and the host's downloads
/// run one at a time anyway. (Waiting operations of their own would take a thread each: dragging 64 items would use up
/// the threads that everything else's work needs, and wait forever.)
private let filePromiseQueue: OperationQueue = {
    let queue = OperationQueue()
    queue.qualityOfService = .userInitiated
    queue.maxConcurrentOperationCount = 1
    return queue
}()

/// The file table: Return opens, Space previews, Delete deletes a server's items (it asks first; this Mac's go to the
/// Trash with ⌘⌫, as in Finder), ⇧⌘. shows hidden files; the actions go up the responder chain to the pane (also while
/// the Quick Look panel forwards its keys here).
final class FileTableView: NSTableView {
    /// Hairlines between the rows there are, not down the empty space below them.
    override func drawGrid(inClipRect clipRect: NSRect) {
        guard numberOfRows > 0 else { return }
        super.drawGrid(inClipRect: clipRect.intersection(rect(ofRow: 0).union(rect(ofRow: numberOfRows - 1))))
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        var action: Selector?
        if modifiers.isEmpty {
            switch event.keyCode {
            case 49: action = #selector(FilePane.quickLook(_:))       // Space
            case 36, 76: action = #selector(FilePane.openItems(_:))   // Return, Enter
            case 51, 117:  // Delete, Forward Delete
                if (delegate as? FilePane)?.isRemote == true { action = #selector(FilePane.deleteItems(_:)) }
            default: break
            }
        } else if modifiers == [.command, .shift] && event.keyCode == 47 {  // ⇧⌘.
            action = #selector(FilePane.toggleHiddenFiles(_:))
        }
        if let action, NSApp.sendAction(action, to: delegate, from: self) { return }
        super.keyDown(with: event)
    }
}

/// A file table's scroll view. Overlay scroll bars (System Settings ▸ Appearance ▸ Show scroll bars: automatically, or
/// when scrolling) lie over the rows, and the horizontal one hid the last row's text: the rows get the bar's height of
/// room below them, so that scrolled to the end the last row is above the bar. Legacy scroll bars (Always) have room of
/// their own.
final class FileScrollView: NSScrollView {
    override func tile() {
        let bar = scrollerStyle == .overlay && hasHorizontalScroller
            ? NSScroller.scrollerWidth(for: horizontalScroller?.controlSize ?? .regular, scrollerStyle: .overlay) : 0
        if contentInsets.bottom != bar {
            contentInsets.bottom = bar
            scrollerInsets.bottom = -bar
        }
        super.tile()
    }
}

/// A file table's row: zebra stripes on the pane's surface (the table is clear, so Night Harbor's wash shows), and in
/// Paper the black pill as the selection (labelColor; unemphasized grey in the pane without the focus).
final class FileRowView: NSTableRowView {
    override func drawBackground(in dirtyRect: NSRect) {
        guard let table = superview as? NSTableView, table.row(for: self) % 2 == 1 else { return }
        NSColor.alternatingContentBackgroundColors[1].setFill()
        dirtyRect.fill(using: .sourceOver)
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard !effectiveAppearance.isDark else { return super.drawSelection(in: dirtyRect) }
        (isEmphasized ? NSColor.labelColor : NSColor.unemphasizedSelectedContentBackgroundColor).setFill()
        bounds.fill(using: .sourceOver)
    }
}

/// A file table's cell: the name's symbol takes its kind's colour, and the text colour on a selection.
final class FileCellView: NSTableCellView {
    var tint: NSColor? {
        didSet { updateTint() }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateTint() }
    }

    private func updateTint() {
        imageView?.contentTintColor = backgroundStyle == .emphasized ? nil : tint
    }
}
