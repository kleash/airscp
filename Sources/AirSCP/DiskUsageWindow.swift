import AirSCPCore
import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

/// Disk Usage of a folder on a server (`Session.diskUsage`) or on this Mac (`DiskUsage.scan`): what takes the room,
/// largest first, as rings and a list that grow while the scan runs, folder by folder; the largest files below; totals
/// by type; what grew since the last scan; files deleted but still open.
@MainActor
final class DiskUsageModel: ObservableObject {
    /// One arc of the rings: an item, its ring (0: the folder shown's own items) and its share of the circle (0…1).
    struct Segment {
        let item: DiskUsage.Item
        let depth: Int
        let start: Double
        let end: Double
        /// The colour of the folder shown's item it is in.
        let hue: Double
    }

    /// A row of Contents, Largest Files and Changes.
    struct Row: Identifiable {
        let item: DiskUsage.Item
        /// The name, or for Largest Files and Changes the path below the folder shown.
        let name: String
        let size: Int64
        let files: Int
        /// Since the last scan; nil: not known.
        let change: Int64?
        var id: DiskUsage.Item.ID { item.id }
        var growth: Int64 { change ?? 0 }
    }

    /// A row of By Type: the files with one extension ("" for none).
    struct TypeRow: Identifiable {
        let type: String
        let size: Int64
        let files: Int
        var id: String { type }
        var title: String { type.isEmpty ? "No extension" : "." + type }
    }

    /// A row of Open but Deleted.
    struct OpenRow: Identifiable {
        let file: DiskUsage.OpenDeleted
        var id: String { "\(file.pid)\u{0}\(file.path)" }
        var process: String { file.process }
        var pid: Int { file.pid }
        var user: String { file.user }
        var path: String { file.path }
        var size: Int64 { file.size }
    }

    enum Shown: String, CaseIterable {
        case contents = "Contents", largest = "Largest Files", types = "By Type", changes = "Changes", openDeleted = "Open but Deleted"
    }

    /// nil: this Mac.
    let session: Session?
    let dir: String
    /// Where the scan's record is kept, for Changes.
    let recordFile: URL
    @Published private(set) var usage: DiskUsage?
    /// The folder whose items show.
    @Published private(set) var folder: DiskUsage.Item?
    @Published var shown = Shown.contents { didSet { shownChanged(from: oldValue) } }
    /// Largest Files of one type only (By Type's choice); nil: all.
    @Published var onlyType: String? { didSet { refresh() } }
    @Published var search = "" { didSet { refresh() } }
    @Published var sortOrder = [KeyPathComparator(\Row.size, order: .reverse)] { didSet { refresh() } }
    @Published var typeOrder = [KeyPathComparator(\TypeRow.size, order: .reverse)] { didSet { refresh() } }
    @Published var openOrder = [KeyPathComparator(\OpenRow.size, order: .reverse)] { didSet { refresh() } }
    @Published private(set) var rows: [Row] = []
    @Published private(set) var types: [TypeRow] = []
    @Published private(set) var segments: [Segment] = []
    /// The colour of each of the folder shown's items in the rings.
    @Published private(set) var hues: [DiskUsage.Item.ID: Double] = [:]
    /// The item pointed at, in the rings or the list: lit in both.
    @Published var pointed: DiskUsage.Item.ID?
    /// The files the scan found last, newest first, while it runs.
    @Published private(set) var discovered: [DiskUsage.Record] = []
    @Published var selection: Set<DiskUsage.Item.ID> = []
    @Published var typeSelection: Set<String> = []
    @Published var openSelection: Set<String> = []
    @Published private(set) var scanning = false
    @Published private(set) var status = ""
    /// The folders the last scan couldn't read.
    @Published private(set) var skipped = DiskUsage.Skipped()
    @Published private(set) var asRoot = false
    /// Whether Scan as Root can work here (nil: not asked yet).
    @Published private(set) var sudo: (available: Bool, needsPassword: Bool)?
    /// The disk the folder is on (nil: not known, or S3).
    @Published private(set) var space: DiskUsage.Space?
    /// The record of the scan before the last one, and how much each item grew since.
    @Published private(set) var previous: DiskUsageRecord?
    private var changes: [DiskUsage.Item.ID: Int64] = [:]
    /// Open but Deleted: what was found (nil: not looked yet), or why it can't tell.
    @Published private(set) var openDeleted: [DiskUsage.OpenDeleted]?
    @Published private(set) var openRows: [OpenRow] = []
    @Published private(set) var openProblem: String?
    @Published private(set) var lookingForOpen = false
    /// The folders shown before, for Back.
    @Published private(set) var back: [DiskUsage.Item] = []
    private var scan: Task<Void, Never>?
    private var generation = 0
    private var refreshed = Date.distantPast
    private var started = Date()
    /// The most files Largest Files lists.
    static let largestCount = 200
    /// The most rows Changes lists.
    static let changesCount = 500
    /// The rings drawn around the middle.
    static let rings = 3

    init(session: Session?, dir: String, records: URL = Store.directory) {
        self.session = session
        self.dir = dir
        recordFile = DiskUsageRecord.file(host: session?.host.id, dir: dir, folder: records)
    }

    /// The folder scanned, as the window names it.
    var title: String { dir == "/" ? "/" : RemotePath.name(dir) }
    /// Where it is: the server's name, or This Mac.
    var place: String { session?.host.displayName ?? "This Mac" }

    /// Measures everything below the folder; `asRoot` through sudo (`password` when sudo asks for one: passed on, not kept).
    func start(asRoot: Bool = false, password: String? = nil) {
        scan?.cancel()
        let usage = DiskUsage(path: dir)
        self.usage = usage
        folder = usage.root
        back = []
        discovered = []
        skipped = DiskUsage.Skipped()
        changes = [:]
        self.asRoot = asRoot
        refresh()
        scanning = true
        status = "Scanning…"
        started = Date()
        generation += 1
        let generation = self.generation, session = self.session, dir = self.dir
        let found: ([DiskUsage.Record], Int) -> Void = { [weak self] records, expected in
            DispatchQueue.main.async { self?.add(records, expected: expected, from: generation) }
        }
        Task { await readSpace() }
        scan = Task { [self] in
            let outcome: String, skipped: DiskUsage.Skipped?
            do {
                if let session {
                    skipped = try await session.diskUsage(of: dir, asRoot: asRoot, password: password, found: found)
                } else {
                    // Off the main thread: a home folder has hundreds of thousands of files.
                    let work = Task.detached(priority: .userInitiated) { try DiskUsage.scan(dir, found: found) }
                    skipped = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
                }
                guard !Task.isCancelled else { return }
                outcome = "Scanned \(usage.root.files.formatted()) files in \(Self.elapsed(Date().timeIntervalSince(started)))"
                    + (asRoot ? " as root." : ".")
            } catch {
                guard !Task.isCancelled else { return }
                outcome = (error as? AirSCPError)?.message ?? error.localizedDescription
                skipped = nil
            }
            // After the last batch: the main queue runs them in order.
            DispatchQueue.main.async { [self] in
                guard self.generation == generation else { return }
                scanning = false
                status = usage.root.files == 0 && skipped != nil ? "No files below “\(title)”." : outcome
                self.skipped = skipped ?? DiskUsage.Skipped()
                if skipped != nil { compareAndKeep(usage) }
                withAnimation(.easeInOut(duration: 0.25)) { refresh() }
                if self.skipped.count > 0 && sudo == nil { Task { await askSudo() } }
            }
        }
    }

    /// "0.4 s", "12 s", "3 min 5 s".
    static func elapsed(_ seconds: TimeInterval) -> String {
        if seconds < 10 { return String(format: "%.1f s", seconds) }
        let whole = Int(seconds.rounded())
        return whole < 60 ? "\(whole) s" : "\(whole / 60) min \(whole % 60) s"
    }

    private func readSpace() async {
        if let session {
            space = try? await session.diskSpace(of: dir)
        } else {
            let dir = self.dir
            space = await Task.detached { DiskUsage.localSpace(of: dir) }.value
        }
    }

    func askSudo() async {
        guard let session else { return }
        sudo = await session.diskUsageSudo()
    }

    /// A finished scan: compared with the one before (Changes), then kept in its place.
    private func compareAndKeep(_ usage: DiskUsage) {
        previous = DiskUsageRecord.load(from: recordFile)
        if let previous { changes = previous.changes(of: usage.root) }
        let record = DiskUsageRecord(of: usage.root), file = recordFile
        Task.detached(priority: .utility) { record.save(to: file) }
    }

    /// What the scan under way found: into the tree; the rings and the list follow a few times a second, as sizes grow.
    private func add(_ records: [DiskUsage.Record], expected: Int, from scan: Int) {
        guard scanning, scan == generation, let usage else { return }
        usage.expected = expected
        usage.add(records)
        let files = records.reversed().lazy.filter { !$0.folder }.prefix(8)
        discovered = Array((Array(files) + discovered).prefix(8))
        // Largest Files and By Type go through the whole tree: less often.
        guard Date().timeIntervalSince(refreshed) > ([.largest, .types].contains(shown) ? 1.5 : 0.3) else { return }
        status = "Scanning… \(usage.root.files.formatted()) files, \(FileList.size(usage.root.size))"
        withAnimation(.easeInOut(duration: 0.25)) { refresh() }
    }

    /// How far the scan is: the scanned folder's own items reached; nil before it knows how many there are.
    var progress: Double? {
        guard let usage, usage.expected > 0 else { return nil }
        return min(Double(usage.reached) / Double(usage.expected), 1)
    }

    /// Stops a scan under way; what it measured so far stays.
    func stop() {
        scan?.cancel()
        scan = nil
        if scanning {
            scanning = false
            generation += 1
            status = "Stopped: the sizes are of what was scanned so far."
            refresh()
        }
    }

    // MARK: Going around

    /// Double-click: a folder's items show; false for a file (it is shown in the pane instead).
    @discardableResult
    func open(_ item: DiskUsage.Item) -> Bool {
        guard item.isFolder, item !== folder else { return item.isFolder }
        go(to: item)
        return true
    }

    func goUp() {
        if let parent = folder?.parent { go(to: parent) }
    }

    func goBack() {
        guard let last = back.popLast() else { return }
        folder = last
        reset()
    }

    /// Shows `item`'s contents (a folder), Back returning to the folder shown now.
    func go(to item: DiskUsage.Item) {
        if let folder { back.append(folder) }
        folder = item
        if shown != .changes { shown = .contents }
        reset()
    }

    private func reset() {
        search = ""
        refresh()
    }

    /// The folders from the one scanned to the one shown.
    var trail: [DiskUsage.Item] {
        var items: [DiskUsage.Item] = [], item = folder
        while let current = item {
            items.insert(current, at: 0)
            item = current.parent
        }
        return items
    }

    /// By Type's choice: its largest files.
    func showLargest(ofType type: String) {
        onlyType = type
        shown = .largest
    }

    private func shownChanged(from old: Shown) {
        if old == .largest && shown != .largest { onlyType = nil }
        // Changes lists the biggest growth first; the others the largest.
        if shown == .changes {
            sortOrder = [KeyPathComparator(\Row.growth, order: .reverse)]
        } else if old == .changes {
            sortOrder = [KeyPathComparator(\Row.size, order: .reverse)]
        }
        if shown == .openDeleted && openDeleted == nil && !lookingForOpen { lookForOpen() }
        refresh()
    }

    // MARK: Changing things

    /// A short activity in the status line (Deleting…), then back to what it said.
    func note(_ text: String) { status = text }

    /// Items deleted (off the tree) or emptied (kept at 0 bytes): their sizes out of the folders above.
    func removed(_ items: [DiskUsage.Item], emptied: Bool = false) {
        items.forEach { emptied ? $0.empty() : $0.remove() }
        if let previous, let usage { changes = previous.changes(of: usage.root) }
        refresh()
    }

    /// Open but Deleted: looks for them (as root through sudo when `asRoot`).
    func lookForOpen(asRoot: Bool = false, password: String? = nil) {
        lookingForOpen = true
        openProblem = nil
        let session = self.session, dir = self.dir
        Task {
            do {
                if let session {
                    openDeleted = try await session.openDeletedFiles(below: dir, asRoot: asRoot, password: password)
                } else {
                    openDeleted = try await DiskUsage.localOpenDeleted(below: dir)
                }
            } catch {
                openDeleted = []
                openProblem = (error as? AirSCPError)?.message ?? error.localizedDescription
            }
            lookingForOpen = false
            if sudo == nil { await askSudo() }
            refresh()
        }
    }

    // MARK: The rows

    var selectedItems: [DiskUsage.Item] { rows.filter { selection.contains($0.id) }.map(\.item) }

    func items(_ ids: Set<DiskUsage.Item.ID>) -> [DiskUsage.Item] { rows.filter { ids.contains($0.id) }.map(\.item) }

    var selectedOpen: [DiskUsage.OpenDeleted] { openRows.filter { openSelection.contains($0.id) }.map(\.file) }

    /// Below the folder shown ("logs/app.log"), for Largest Files and Changes.
    func relative(_ item: DiskUsage.Item) -> String {
        guard let folder else { return item.name }
        let prefix = folder.path == "/" ? "/" : folder.path + "/"
        return item.path.hasPrefix(prefix) ? String(item.path.dropFirst(prefix.count)) : item.path
    }

    /// How much `item` grew since the last scan (nil: not known).
    func change(of item: DiskUsage.Item) -> Int64? { changes[item.id] }

    private func refresh() {
        refreshed = Date()
        let term = search.trimmingCharacters(in: .whitespaces)
        func matches(_ text: String) -> Bool { term.isEmpty || text.localizedCaseInsensitiveContains(term) }
        let items: [DiskUsage.Item]
        switch shown {
        case .largest:
            if let folder, let onlyType {
                items = largest(in: folder, ofType: onlyType)
            } else {
                items = folder?.largestFiles(Self.largestCount) ?? []
            }
        case .changes:
            items = changedItems()
        case .contents, .types, .openDeleted:
            items = folder?.children ?? []
        }
        let relative = shown == .largest || shown == .changes
        rows = items.map { item in
            Row(item: item, name: relative ? self.relative(item) : item.name, size: item.size, files: item.files, change: changes[item.id])
        }
        .filter { matches($0.name) }
        .sorted(using: sortOrder)
        types = shown == .types ? (folder.map(Self.types) ?? []).filter { matches($0.title) }.sorted(using: typeOrder) : []
        openRows = (openDeleted ?? []).map(OpenRow.init).filter { matches($0.path) || matches($0.process) }.sorted(using: openOrder)
        segments = folder.map(Self.segments) ?? []
        hues = Dictionary(segments.filter { $0.depth == 0 }.map { ($0.item.id, $0.hue) }, uniquingKeysWith: { first, _ in first })
        selection.formIntersection(rows.map(\.id))
        typeSelection.formIntersection(types.map(\.id))
        openSelection.formIntersection(openRows.map(\.id))
    }

    /// Changes: the items below the folder shown that grew or shrank since the last scan, the biggest growth first.
    private func changedItems() -> [DiskUsage.Item] {
        guard let folder else { return [] }
        let prefix = folder.path == "/" ? "/" : folder.path + "/"
        var found: [(DiskUsage.Item, Int64)] = []
        Self.walk(folder) { item in
            if let change = changes[item.id], item.path.hasPrefix(prefix) { found.append((item, change)) }
        }
        return found.sorted { $0.1 > $1.1 }.prefix(Self.changesCount).map(\.0)
    }

    /// Every item below `folder`, folders before what is in them.
    static func walk(_ folder: DiskUsage.Item, _ body: (DiskUsage.Item) -> Void) {
        for child in folder.children {
            body(child)
            if child.isFolder { walk(child, body) }
        }
    }

    /// The largest files of one type below `folder`.
    private func largest(in folder: DiskUsage.Item, ofType type: String) -> [DiskUsage.Item] {
        var found: [DiskUsage.Item] = []
        Self.walk(folder) { item in
            if !item.isFolder && Self.type(of: item.name) == type { found.append(item) }
        }
        return Array(found.sorted { $0.size > $1.size }.prefix(Self.largestCount))
    }

    /// A file name's extension, in lower case ("" for none; a name starting with a dot alone has none).
    static func type(of name: String) -> String {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex, name.index(after: dot) != name.endIndex else { return "" }
        return name[name.index(after: dot)...].lowercased()
    }

    /// By Type: the files below `folder` added up by extension, largest first.
    static func types(of folder: DiskUsage.Item) -> [TypeRow] {
        var totals: [String: (size: Int64, files: Int)] = [:]
        walk(folder) { item in
            guard !item.isFolder else { return }
            let type = Self.type(of: item.name)
            totals[type, default: (0, 0)].size += item.size
            totals[type, default: (0, 0)].files += 1
        }
        return totals.map { TypeRow(type: $0.key, size: $0.value.size, files: $0.value.files) }.sorted { $0.size > $1.size }
    }

    // MARK: Export

    /// The view shown as CSV (RFC 4180): a header row, then path, size in bytes, files and share of the folder shown.
    func csv() -> String {
        let total = max(folder?.size ?? 0, 1)
        func share(_ size: Int64) -> String { String(format: "%.4f", Double(size) / Double(total)) }
        var lines: [[String]]
        switch shown {
        case .types:
            lines = [["Type", "Size (bytes)", "Files", "Share"]] + types.map { [$0.title, String($0.size), String($0.files), share($0.size)] }
        case .openDeleted:
            lines = [["Process", "PID", "User", "Path", "Size (bytes)"]]
                + openRows.map { [$0.process, String($0.pid), $0.user, $0.path, String($0.size)] }
        case .changes:
            lines = [["Path", "Size (bytes)", "Files", "Share", "Change (bytes)"]]
                + rows.map { [$0.item.path, String($0.size), String($0.files), share($0.size), String($0.growth)] }
        case .contents, .largest:
            lines = [["Path", "Size (bytes)", "Files", "Share"]] + rows.map { [$0.item.path, String($0.size), String($0.files), share($0.size)] }
        }
        return lines.map { $0.map(Self.csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }

    /// One CSV field: in double quotes (doubled inside) when it has a comma, a quote or a line break.
    static func csvField(_ text: String) -> String {
        guard text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline }) else { return text }
        return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: Rings

    /// The rings of `folder`: its items, then theirs, each arc its share of the one it is in; arcs too thin to see are
    /// left out.
    static func segments(of folder: DiskUsage.Item) -> [Segment] {
        var segments: [Segment] = []
        func add(_ item: DiskUsage.Item, depth: Int, start: Double, span: Double, hue: Double?) {
            guard depth < rings, item.size > 0 else { return }
            var at = start
            for (index, child) in item.children.enumerated() {
                let width = span * Double(child.size) / Double(item.size)
                guard width >= 0.003 else { break }  // largest first: the rest are thinner still
                let tint = hue ?? Double(index % 10) / 10
                segments.append(Segment(item: child, depth: depth, start: at, end: at + width, hue: tint))
                if child.isFolder { add(child, depth: depth + 1, start: at, span: width, hue: tint) }
                at += width
            }
        }
        add(folder, depth: 0, start: 0, span: 1, hue: nil)
        return segments
    }
}

/// The last finished scan of a folder, for Changes: the sizes of its folders and of its files of 1 MB and more (the
/// largest 50 000, so that the file stays small), by their paths below it ("" for the folder itself). Kept in the
/// settings folder, disk-usage/<host id, or this-mac>/<SHA-256 of the folder's path>.json, one per folder; deleting
/// the host deletes its records.
struct DiskUsageRecord: Codable, Equatable {
    var date: Date
    var sizes: [String: Int64]

    /// Smaller files aren't kept.
    static let smallest: Int64 = 1 << 20
    static let limit = 50_000

    init(date: Date = Date(), sizes: [String: Int64]) {
        self.date = date
        self.sizes = sizes
    }

    init(of root: DiskUsage.Item, date: Date = Date()) {
        var all: [(String, Int64)] = []
        func walk(_ folder: DiskUsage.Item, _ prefix: String) {
            for child in folder.children {
                let path = prefix + child.name
                if child.isFolder {
                    all.append((path, child.size))
                    walk(child, path + "/")
                } else if child.size >= Self.smallest {
                    all.append((path, child.size))
                }
            }
        }
        walk(root, "")
        if all.count > Self.limit { all = Array(all.sorted { $0.1 > $1.1 }.prefix(Self.limit)) }
        var sizes = Dictionary(all, uniquingKeysWith: { first, _ in first })
        sizes[""] = root.size
        self.init(date: date, sizes: sizes)
    }

    /// How much each of `root`'s items grew since this record (the folder itself too). An item of the kinds kept that
    /// isn't in it counts from 0: it is new, or was a file under 1 MB then.
    func changes(of root: DiskUsage.Item) -> [DiskUsage.Item.ID: Int64] {
        // A record cut at the limit leaves out items that were there: those aren't known.
        let complete = sizes.count <= Self.limit
        var found: [DiskUsage.Item.ID: Int64] = [:]
        if let old = sizes[""], old != root.size { found[root.id] = root.size - old }
        func walk(_ folder: DiskUsage.Item, _ prefix: String) {
            for child in folder.children {
                let path = prefix + child.name
                let kept = child.isFolder || child.size >= Self.smallest
                if let old = sizes[path] ?? (kept && complete ? 0 : nil), old != child.size { found[child.id] = child.size - old }
                if child.isFolder { walk(child, path + "/") }
            }
        }
        walk(root, "")
        return found
    }

    static func file(host: UUID?, dir: String, folder: URL = Store.directory) -> URL {
        let hash = SHA256.hash(data: Data(dir.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder.appendingPathComponent("disk-usage", isDirectory: true)
            .appendingPathComponent(host?.uuidString ?? "this-mac", isDirectory: true)
            .appendingPathComponent(hash + ".json")
    }

    static func load(from file: URL) -> DiskUsageRecord? {
        (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    /// In place of the one before (folder 0700, file 0600, as other per-host files).
    func save(to file: URL) {
        let files = FileManager.default
        try? files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        guard (try? JSONEncoder().encode(self).write(to: file, options: .atomic)) != nil else { return }
        try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// A deleted host's records.
    static func forget(host: UUID, folder: URL = Store.directory) {
        try? FileManager.default.removeItem(at: file(host: host, dir: "", folder: folder).deletingLastPathComponent())
    }
}

// MARK: The window

/// Disk Usage's window, one per server folder (Disk Usage of the same folder again brings it forward); the panes stay
/// usable while it scans. Closing it stops a scan under way.
@MainActor
final class DiskUsageWindow: NSWindowController, NSWindowDelegate {
    /// The windows open, by host and folder.
    private(set) static var open: [String: DiskUsageWindow] = [:]
    let model: DiskUsageModel
    /// The Files tab it was opened from: Show in Pane and Download go there, and its panes list again after a change.
    private weak var browser: BrowserContentController?

    private static func key(_ session: Session?, _ dir: String) -> String { (session?.host.id.uuidString ?? "this-mac") + "\u{0}" + dir }

    /// The window of `dir` on `session`'s server (nil: this Mac): the one open, or a new one, which starts scanning.
    @discardableResult
    static func show(_ dir: String, on session: Session?, from browser: BrowserContentController?) -> DiskUsageWindow {
        let key = key(session, dir)
        if let window = open[key] {
            window.showWindow(nil)
            return window
        }
        let window = DiskUsageWindow(DiskUsageModel(session: session, dir: dir), browser: browser)
        open[key] = window
        window.showWindow(nil)
        window.model.start()
        return window
    }

    init(_ model: DiskUsageModel, browser: BrowserContentController?) {
        self.model = model
        self.browser = browser
        let size = NSSize(width: 1120, height: 740)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 900, height: 560)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.title = "Disk Usage — \(model.title) on \(model.place)"
        super.init(window: window)
        let hosting = NSHostingController(rootView: DiskUsageView(model: model, actions: self))
        hosting.sizingOptions = []  // the window's size is the person's, not SwiftUI's
        window.contentViewController = hosting
        window.delegate = self
        window.open(size: size)
        // SwiftUI gives the Filter field the keyboard at once; the list should have it (arrows, Return).
        DispatchQueue.main.async { window.makeFirstResponder(AgentServer.views(NSTableView.self, in: window.contentView).first) }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func windowWillClose(_ notification: Notification) {
        model.stop()
        Self.open[Self.key(model.session, model.dir)] = nil
    }

    // MARK: Actions

    /// The Files tab's panes that show this server (or this Mac).
    private var panes: [FilePane] {
        guard let browser else { return [] }
        return [browser.left as FilePane?, browser.right].compactMap { $0 }.filter { pane in
            model.session.map { pane.session === $0 } ?? !pane.isRemote
        }
    }

    /// Why Show in Pane can't go to an item now (nil: it can).
    var paneProblem: String? {
        guard browser?.workspace != nil else { return "Its Files tab was closed: open Disk Usage again from a pane" }
        return panes.isEmpty ? "No pane shows \(model.session == nil ? "this Mac" : "“\(model.place)”") now" : nil
    }

    /// The item selected in the pane, which shows its folder.
    func show(_ path: String) {
        guard let browser, let workspace = browser.workspace, let pane = panes.first else { return }
        let main = browser.view.window?.windowController as? MainWindowController
        main?.open(workspace.host.id) { workspace in
            workspace.tabs.selectedTabViewItemIndex = 0
            pane.reveal(path)
        }
    }

    func showInFinder(_ items: [DiskUsage.Item]) {
        NSWorkspace.shared.activateFileViewerSelecting(items.map { URL(fileURLWithPath: $0.path) })
    }

    /// Why Download as .tar.gz (or .zip from S3) can't run (nil: it can).
    var downloadProblem: String? {
        guard let session = model.session else { return "These are this Mac's files already" }
        if let reason = session.compressUnavailableReason(session.s3 != nil ? .zip : .tarGz) { return reason }
        return browser?.workspace == nil ? "Its Files tab was closed: open Disk Usage again from a pane" : nil
    }

    /// Download as .tar.gz (from S3, .zip): the Files tab's command, for items that may be in different folders (the
    /// archive holds their paths below the folder they share).
    func download(_ items: [DiskUsage.Item]) {
        guard let session = model.session, let browser, let pane = panes.first ?? browser.left, !items.isEmpty else { return }
        let common = Self.commonFolder(items.map(\.path))
        let prefix = common == "/" ? "/" : common + "/"
        let files = items.map { item in
            FileItem(local: String(item.path.dropFirst(prefix.count)), path: item.path, kind: item.isFolder ? .directory : .file,
                     size: item.size, modified: nil, mode: 0, owner: "", group: "")
        }
        browser.downloadArchive(files, in: common, from: session, near: pane, asking: window)
    }

    /// The deepest folder all `paths` are in.
    static func commonFolder(_ paths: [String]) -> String {
        var parts = RemotePath.parent(paths[0]).split(separator: "/", omittingEmptySubsequences: false)
        for path in paths.dropFirst() {
            let other = RemotePath.parent(path).split(separator: "/", omittingEmptySubsequences: false)
            parts = Array(zip(parts, other).prefix { $0 == $1 }.map(\.0))
        }
        let joined = parts.joined(separator: "/")
        return joined.isEmpty ? "/" : joined
    }

    /// Delete…: asks (naming the server, or the Trash on this Mac), deletes, takes them off the sizes and lists the panes again.
    func delete(_ items: [DiskUsage.Item]) {
        guard let window, !items.isEmpty else { return }
        let paths = items.map(\.path)
        let names = items.prefix(8).map { "“\($0.name)”" }.joined(separator: ", ") + (items.count > 8 ? " and \(items.count - 8) more" : "")
        let what = items.count == 1 ? "“\(items[0].name)”" : FileList.items(items.count)
        let size = FileList.size(items.reduce(0) { $0 + $1.size })
        guard let session = model.session else {
            return confirm("Move \(what) to the Trash?", info: (items.count == 1 ? paths[0] : names) + "\n\n\(size). Empty the Trash to free the space.",
                           button: "Move to Trash", on: window) { [self] in
                act("Moving to the Trash…", failure: "Can't move to the Trash", items) {
                    try await Task.detached(priority: .userInitiated) {
                        for path in paths { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
                    }.value
                }
            }
        }
        confirm("Delete \(what) on “\(session.host.displayName)”?",
                info: (items.count == 1 ? paths[0] : names) + "\n\n\(size). Folders are deleted with everything in them. This can't be undone.",
                button: "Delete", destructive: true, on: window) { [self] in
            act("Deleting…", failure: "Can't delete", items) {
                try await session.delete(try await FilePane.entries(at: paths, on: session))
            }
        }
    }

    /// Why Empty File… can't run on these items (nil: it can).
    func emptyProblem(_ items: [DiskUsage.Item]) -> String? {
        if items.isEmpty { return "Select files first" }
        if items.contains(where: \.isFolder) { return "Select files only: a folder can't be emptied" }
        if model.scanning { return "Wait for the scan to end, or stop it" }
        return model.session?.emptyFileProblem
    }

    /// Empty File…: asks (with what it frees), then truncates each file to 0 bytes.
    func empty(_ items: [DiskUsage.Item]) {
        guard let window, emptyProblem(items) == nil else { return }
        let what = items.count == 1 ? "“\(items[0].name)”" : FileList.items(items.count)
        let size = FileList.size(items.reduce(0) { $0 + $1.size })
        confirm("Empty \(what)\(model.session.map { " on “\($0.host.displayName)”" } ?? "")?",
                info: "Frees \(size) at once: \(items.count == 1 ? "the file stays, with nothing in it" : "the files stay, with nothing in them"). "
                    + "This can't be undone.",
                button: "Empty", destructive: true, on: window) { [self] in
            let session = model.session, paths = items.map(\.path)
            act("Emptying…", failure: "Can't empty", items, emptied: true) {
                for path in paths {
                    if let session { try await session.emptyFile(path) } else { try DiskUsage.emptyLocalFile(path) }
                }
            }
        }
    }

    /// Runs a change, then takes the items off the sizes (when it worked) and lists the panes again.
    private func act(_ activity: String, failure: String, _ items: [DiskUsage.Item], emptied: Bool = false,
                     _ work: @escaping () async throws -> Void) {
        let model = self.model, before = model.status
        model.note(activity)
        Task {
            do {
                try await work()
                model.removed(items, emptied: emptied)
                model.note(before)
            } catch {
                model.note(before)
                if (error as? AirSCPError)?.kind != .cancelled { showError(error, title: failure, on: window) }
            }
            for pane in panes { await pane.reload() }
        }
    }

    /// Export as CSV…: the view shown, in a file chosen in a Save panel.
    func exportCSV() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Disk Usage of \(model.title == "/" ? model.place : model.title).csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.isExtensionHidden = false
        let text = model.csv()
        Panels.run(panel, on: window) { [weak self] urls in
            guard let url = urls.first else { return }
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
            } catch {
                showError(error, title: "Can't save “\(url.lastPathComponent)”", on: self?.window)
            }
        }
    }

    /// Scan as Root… (or Open but Deleted as root): asks for the sudo password only when sudo needs one; it goes to
    /// Core and is dropped after.
    func asRoot(_ run: @escaping (String?) -> Void) {
        guard let window, let sudo = model.sudo, sudo.available else { return }
        guard sudo.needsPassword else { return run(nil) }
        let alert = NSAlert()
        alert.messageText = "Password for sudo on “\(model.place)”"
        alert.informativeText = "Your account's password, for sudo: it goes to the server only, and AirSCP doesn't keep it."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 22))
        field.placeholderString = "Password"
        field.toolTip = "Type your password on the server: it goes to sudo only, never into a command line"
        field.setAccessibilityIdentifier("diskUsage.sudoPassword")
        alert.accessoryView = field
        alert.addButton(withTitle: "Scan as Root").toolTip = "Run it through sudo with this password"
        alert.addButton(withTitle: "Cancel").toolTip = "Don't run it as root"
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            run(field.stringValue)
            field.stringValue = ""
        }
    }
}

// MARK: The view

struct DiskUsageView: View {
    @ObservedObject var model: DiskUsageModel
    weak var actions: DiskUsageWindow?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 10)
            if model.skipped.count > 0 && !model.scanning {
                skippedNotice.padding(.horizontal, 16).padding(.bottom, 8)
            }
            if scheme == .dark { Divider() }
            VStack(spacing: 0) {
                navigation
                Divider()
                HStack(alignment: .top, spacing: 0) {
                    if [.contents, .largest, .changes].contains(model.shown) {
                        DiskUsageRings(model: model)
                            .frame(width: 300)
                            .padding(12)
                        Divider()
                    }
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if model.scanning {
                    Divider()
                    feed
                }
                Divider()
                actionBar
            }
            .card()
        }
        .background(Color(nsColor: .ground))
        .frame(minWidth: 880, minHeight: 520)
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "chart.pie.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(scheme == .dark ? Color(nsColor: .systemTeal) : .primary)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 9).fill((scheme == .dark ? Color(nsColor: .systemTeal) : .primary).opacity(scheme == .dark ? 0.18 : 0.07)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(model.title).font(.title3.weight(.semibold)).lineLimit(1)
                    StatusPill(text: model.place, symbol: model.session == nil ? "laptopcomputer" : "network", style: .neutral)
                        .help(model.session == nil ? "This folder is on this Mac" : "The server the folder is on")
                    if model.asRoot { StatusPill(text: "as root", symbol: "lock.open", style: .tinted(.systemOrange)).help("Scanned through sudo") }
                }
                Text(model.dir).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                    .help("The folder scanned")
            }
            .frame(minWidth: 180, alignment: .leading)
            Spacer(minLength: 12)
            spaceView.frame(maxWidth: 380)
            Spacer(minLength: 12)
            Button(model.scanning ? "Stop" : "Scan Again") { model.scanning ? model.stop() : model.start() }
                .accessibilityIdentifier("diskUsage.scan")
                .help(model.scanning ? "Stop the scan; what it measured stays" : "Measure everything again")
            HelpButton(.diskUsage)
        }
    }

    /// The disk's bar: the folder scanned, the rest used, and free; the figures in words.
    private var spaceView: some View {
        let size = model.usage?.root.size ?? 0
        return VStack(alignment: .leading, spacing: 5) {
            if let space = model.space, space.total > 0 {
                DiskBar(space: space, folder: size)
                    .frame(height: 8)
                    .help("The disk “\(model.title)” is on: this folder, the rest used, and free")
                Text("This folder: \(FileList.size(size)) of \(FileList.size(space.total - space.free)) used, \(FileList.size(space.free)) free")
                    .font(.caption).foregroundColor(.secondary).lineLimit(1).monospacedDigit()
            } else {
                Text("This folder: \(FileList.size(size))").font(.callout.weight(.medium)).monospacedDigit()
                if model.session?.s3 != nil {
                    Text("S3 storage has no disk size").font(.caption).foregroundColor(.secondary)
                }
            }
            if let previous = model.previous, let usage = model.usage, let change = model.change(of: usage.root) {
                Text("\(Self.signed(change)) since \(previous.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundColor(change > 0 ? Color(nsColor: .readable(.systemOrange)) : .secondary)
                    .help("How much this folder grew since the last scan that finished")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("diskUsage.space")
    }

    /// "+1.2 GB", "−300 MB".
    static func signed(_ change: Int64) -> String {
        (change >= 0 ? "+" : "−") + FileList.size(abs(change))
    }

    private var skippedNotice: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(Color(nsColor: .systemOrange)).accessibilityHidden(true)
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.skipped.paths.map { $0.isEmpty ? model.dir : RemotePath.join(model.dir, $0) }, id: \.self) { Text($0).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle) }
                    if model.skipped.count > model.skipped.paths.count {
                        Text("and \(model.skipped.count - model.skipped.paths.count) more").font(.caption).foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            } label: {
                Text("\(model.skipped.count) \(model.skipped.count == 1 ? "folder" : "folders") couldn't be read, so "
                     + "\(model.skipped.count == 1 ? "it counts" : "they count") as empty")
                    .fontWeight(.medium)
            }
            .accessibilityIdentifier("diskUsage.skipped")
            .help("Show the folders the scan couldn't read (no permission)")
            if model.session != nil {
                let sudo = model.sudo
                Button("Scan as Root…") { actions?.asRoot { model.start(asRoot: true, password: $0) } }
                    .disabled(sudo?.available != true)
                    .accessibilityIdentifier("diskUsage.asRoot")
                    .help(sudo == nil ? "Checking whether your account can use sudo…"
                          : sudo?.available == true ? "Scan again through sudo, to read every folder" + (sudo?.needsPassword == true ? " (asks for your password)" : "")
                          : "Your account can't use sudo on this server")
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .systemOrange).opacity(0.1)))
    }

    // MARK: Navigation

    private var navigation: some View {
        HStack(spacing: 6) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(model.back.isEmpty)
                .accessibilityIdentifier("diskUsage.back")
                .accessibilityLabel("Back")
                .help(model.back.isEmpty ? "No folder was shown before this one" : "Go back to the folder shown before")
            Button { model.goUp() } label: { Image(systemName: "chevron.up") }
                .disabled(model.folder?.parent == nil)
                .accessibilityIdentifier("diskUsage.up")
                .accessibilityLabel("Up")
                .help(model.folder?.parent == nil ? "This is the folder scanned" : "Go up one folder")
            breadcrumb
            Spacer(minLength: 8)
            Picker("Show", selection: $model.shown) {
                ForEach(DiskUsageModel.Shown.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .primaryTint(Color(nsColor: .systemTeal))
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("diskUsage.show")
            .help("Contents: this folder by size. Largest Files, By Type, Changes since the last scan, files deleted but still open")
            TextField("Filter", text: $model.search)
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .accessibilityIdentifier("diskUsage.filter")
                .help("Show only the rows whose name has this")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .bar))
    }

    /// The folders from the one scanned to the one shown: a click goes to one.
    private var breadcrumb: some View {
        let trail = model.trail
        return HStack(spacing: 2) {
            ForEach(Array(trail.enumerated()), id: \.element.id) { index, item in
                if index > 0 { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundColor(.secondary) }
                let name = index == 0 ? model.title : item.name
                if index == trail.count - 1 {
                    Text(name).fontWeight(.semibold).lineLimit(1)
                } else {
                    Button(name) { model.go(to: item) }
                        .buttonStyle(.plain)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .help("Go to “\(name)”")
                }
            }
        }
        .truncationMode(.middle)
        .accessibilityIdentifier("diskUsage.path")
    }

    // MARK: Lists

    @ViewBuilder
    private var content: some View {
        switch model.shown {
        case .contents, .largest, .changes: DiskUsageList(model: model, actions: actions)
        case .types: typesList
        case .openDeleted: openList
        }
    }

    private var typesList: some View {
        let total = max(model.folder?.size ?? 0, 1)
        return Table(model.types, selection: $model.typeSelection, sortOrder: $model.typeOrder) {
            TableColumn("Type", value: \.title) { Text($0.title).lineLimit(1) }.width(min: 90, ideal: 160)
            TableColumn("Size", value: \.size) { Text(FileList.size($0.size)).monospacedDigit() }.width(min: 60, ideal: 80)
            TableColumn("Share", value: \.size) { ShareBar(size: $0.size, total: total) }.width(min: 110, ideal: 150)
            TableColumn("Files", value: \.files) { Text($0.files.formatted()).monospacedDigit().foregroundColor(.secondary) }
                .width(min: 50, ideal: 70)
        }
        .washed()
        .accessibilityIdentifier("diskUsage.types")
        .contextMenu(forSelectionType: String.self, menu: { ids in
            if let type = ids.first, ids.count == 1 {
                Button("Show Largest Files") { model.showLargest(ofType: type) }.help("List the largest files of this type")
            }
        }, primaryAction: { ids in
            if let type = ids.first { model.showLargest(ofType: type) }
        })
        .overlay { if model.types.isEmpty { empty(model.scanning ? "Adding up the types…" : "No files here.") } }
    }

    private var openList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.session == nil
                 ? "Files deleted while an app still has them open: their room is freed only when the app closes them. Quit or restart the app."
                 : "Files deleted while a program still has them open: their room is freed only when the program closes them. "
                 + "Restart or stop the program (the Monitor tab can stop a process).")
                .font(.caption).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            Table(model.openRows, selection: $model.openSelection, sortOrder: $model.openOrder) {
                TableColumn("Process", value: \.process) { Text($0.process).lineLimit(1) }.width(min: 70, ideal: 120)
                TableColumn("PID", value: \.pid) { Text(String($0.pid)).monospacedDigit() }.width(min: 40, ideal: 60)
                TableColumn("User", value: \.user) { Text($0.user).lineLimit(1) }.width(min: 50, ideal: 80)
                TableColumn("File", value: \.path) { Text($0.path).lineLimit(1).truncationMode(.middle).help($0.path) }.width(min: 150, ideal: 380)
                TableColumn("Size", value: \.size) { Text(FileList.size($0.size)).monospacedDigit() }.width(min: 60, ideal: 80)
            }
            .washed()
            .accessibilityIdentifier("diskUsage.openDeleted")
            .overlay {
                if model.lookingForOpen {
                    empty("Looking for files deleted but still open…")
                } else if let problem = model.openProblem {
                    empty(problem)
                } else if model.openRows.isEmpty, model.openDeleted != nil {
                    empty("No deleted files are held open below “\(model.title)”.")
                }
            }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).foregroundColor(.secondary).multilineTextAlignment(.center).padding(30)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
    }

    /// While it runs: how far it is, and the files it has just found, with their sizes.
    private var feed: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let progress = model.progress {
                CapsuleBar(fraction: progress, state: .running).help("How many of “\(model.title)”'s own items the scan has measured")
            } else {
                ProgressView().progressViewStyle(.linear).controlSize(.small).help("Counting “\(model.title)”'s items")
            }
            ForEach(model.discovered.prefix(5), id: \.path) { record in
                HStack {
                    Label(record.path, systemImage: "doc").lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text(FileList.size(record.size)).monospacedDigit()
                }
                .font(.caption)
                .foregroundColor(.secondary)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 112, alignment: .top)
        .clipped()
        .accessibilityIdentifier("diskUsage.discovered")
    }

    // MARK: Buttons

    private var actionBar: some View {
        HStack(spacing: 8) {
            if model.scanning { ProgressView().controlSize(.small) }
            Text(model.status).foregroundColor(.secondary).lineLimit(1).truncationMode(.tail)
                .accessibilityIdentifier("diskUsage.status")
            Spacer(minLength: 8)
            switch model.shown {
            case .contents, .largest, .changes: itemButtons
            case .types:
                let one = model.typeSelection.count == 1 ? model.typeSelection.first : nil
                Button("Show Largest Files") { one.map(model.showLargest(ofType:)) }
                    .disabled(one == nil)
                    .accessibilityIdentifier("diskUsage.showType")
                    .help(one == nil ? "Select one type first" : "List the largest files of this type")
            case .openDeleted: openButtons
            }
            Button("Export as CSV…") { actions?.exportCSV() }
                .disabled(model.scanning)
                .accessibilityIdentifier("diskUsage.export")
                .help(model.scanning ? "Wait for the scan to end, or stop it" : "Save this list as a CSV file (path, size in bytes, files, share)")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .bar))
    }

    @ViewBuilder
    private var itemButtons: some View {
        let items = model.selectedItems
        let none = items.isEmpty
        let single = items.count == 1 ? items[0] : nil
        Button("Open") { if let single { model.open(single) } }
            .disabled(single?.isFolder != true)
            .accessibilityIdentifier("diskUsage.open")
            .help(single?.isFolder == true ? "Show what is in the folder, by size" : "Select one folder first")
        Button("Show in Pane") { single.map { actions?.show($0.path) } }
            .disabled(single == nil || actions?.paneProblem != nil)
            .accessibilityIdentifier("diskUsage.showInPane")
            .help(single == nil ? "Select one item first" : actions?.paneProblem ?? "Go to the item in the Files tab's pane")
        if model.session == nil {
            Button("Show in Finder") { actions?.showInFinder(items) }
                .disabled(none)
                .accessibilityIdentifier("diskUsage.showInFinder")
                .help(none ? "Select items first" : "Show the selected items in a Finder window")
        }
        Button("Copy Paths") { FindView.copy(items.map(\.path)) }
            .disabled(none)
            .accessibilityIdentifier("diskUsage.copyPaths")
            .help(none ? "Select items first" : "Copy the selected items' full paths, one per line")
        if model.session != nil {
            let zip = model.session?.s3 != nil
            Button(zip ? "Download as .zip…" : "Download as .tar.gz…") { actions?.download(items) }
                .disabled(none || actions?.downloadProblem != nil)
                .accessibilityIdentifier("diskUsage.download")
                .help(none ? "Select items first" : actions?.downloadProblem ?? "Download the selected items as one archive, to keep a copy before deleting")
        }
        Button("Empty File…") { actions?.empty(items) }
            .disabled(actions?.emptyProblem(items) != nil)
            .accessibilityIdentifier("diskUsage.empty")
            .help(actions?.emptyProblem(items) ?? "Make the selected files 0 bytes: frees their room at once, even while a program writes to them (asks first)")
        Button("Delete…") { actions?.delete(items) }
            .disabled(none || model.scanning)
            .accessibilityIdentifier("diskUsage.delete")
            .help(none ? "Select items first" : model.scanning ? "Wait for the scan to end, or stop it" : deleteHelp)
    }

    @ViewBuilder
    private var openButtons: some View {
        let chosen = model.selectedOpen
        Button("Copy Paths") { FindView.copy(chosen.map(\.path)) }
            .disabled(chosen.isEmpty)
            .accessibilityIdentifier("diskUsage.copyOpenPaths")
            .help(chosen.isEmpty ? "Select files first" : "Copy the selected files' paths, one per line")
        if model.session != nil {
            let sudo = model.sudo
            Button("Look as Root…") { actions?.asRoot { model.lookForOpen(asRoot: true, password: $0) } }
                .disabled(sudo?.available != true || model.lookingForOpen)
                .accessibilityIdentifier("diskUsage.openAsRoot")
                .help(sudo?.available == true ? "Look again through sudo, to see every user's programs" : "Your account can't use sudo on this server")
        }
        Button("Look Again") { model.lookForOpen(asRoot: false) }
            .disabled(model.lookingForOpen)
            .accessibilityIdentifier("diskUsage.lookAgain")
            .help(model.lookingForOpen ? "Looking now" : "Look again for files deleted but still open")
    }

    private var deleteHelp: String {
        model.session == nil ? "Move the selected items to the Trash (asks first)" : "Delete the selected items on the server (asks first)"
    }
}

/// Contents, Largest Files and Changes: name, size, share, files and the change since the last scan.
struct DiskUsageList: View {
    @ObservedObject var model: DiskUsageModel
    weak var actions: DiskUsageWindow?

    var body: some View {
        let total = max(model.folder?.size ?? 0, 1)
        let compared = model.previous != nil
        Table(model.rows, selection: $model.selection, sortOrder: $model.sortOrder) {
            TableColumn("Name", value: \.name) { row in name(row) }.width(min: 160, ideal: 300)
            TableColumn("Size", value: \.size) { row in
                Text(FileList.size(row.size)).monospacedDigit().frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 76)
            TableColumn("Share", value: \.size) { row in ShareBar(size: row.size, total: total) }.width(min: 100, ideal: 140)
            TableColumn("Files", value: \.files) { row in
                Text(row.item.isFolder ? row.files.formatted() : "").monospacedDigit().foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 44, ideal: 64)
            TableColumn("Change", value: \.growth) { row in
                Text(row.change.map(DiskUsageView.signed) ?? "")
                    .monospacedDigit()
                    .foregroundColor(row.growth > 0 ? Color(nsColor: .readable(.systemOrange)) : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(model.previous.map { "Since the scan of \($0.date.formatted(date: .abbreviated, time: .shortened))" } ?? "")
            }
            .width(min: 50, ideal: compared ? 80 : 56)
        }
        .washed()
        .accessibilityIdentifier("diskUsage.list")
        .contextMenu(forSelectionType: DiskUsage.Item.ID.self, menu: { ids in menu(model.items(ids)) }, primaryAction: { ids in
            if let item = model.items(ids).first, !model.open(item), actions?.paneProblem == nil { actions?.show(item.path) }
        })
        .overlay { if let text = emptyText { Text(text).foregroundColor(.secondary).multilineTextAlignment(.center).padding(30).allowsHitTesting(false) } }
    }

    private func name(_ row: DiskUsageModel.Row) -> some View {
        let lit = model.pointed == row.id
        return HStack(spacing: 6) {
            Circle()
                .fill(model.hues[row.id].map { Color(hue: $0, saturation: 0.55, brightness: 0.88) } ?? Color.secondary.opacity(0.3))
                .frame(width: lit ? 10 : 8, height: lit ? 10 : 8)
                .frame(width: 10)
                .accessibilityHidden(true)
            Image(systemName: row.item.isFolder ? "folder" : "doc").foregroundColor(.secondary).accessibilityHidden(true)
            Text(row.name).fontWeight(lit ? .semibold : .regular).lineLimit(1).truncationMode(.middle)
        }
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { model.pointed = row.id } else if model.pointed == row.id { model.pointed = nil }
        }
        .help(row.item.isFolder ? "Double-click to see what is in the folder" : "Double-click to go to the file in the pane")
    }

    @ViewBuilder
    private func menu(_ items: [DiskUsage.Item]) -> some View {
        if items.count == 1, items[0].isFolder {
            Button("Open") { model.open(items[0]) }.help("Show what is in the folder, by size")
        }
        if items.count == 1, actions?.paneProblem == nil {
            Button("Show in Pane") { actions?.show(items[0].path) }.help("Go to the item in the Files tab's pane")
        }
        if model.session == nil {
            Button("Show in Finder") { actions?.showInFinder(items) }.help("Select the items in a Finder window")
        }
        Button("Copy Paths") { FindView.copy(items.map(\.path)) }.help("Copy the full paths, one per line")
        if model.session != nil, actions?.downloadProblem == nil {
            Button(model.session?.s3 != nil ? "Download as .zip…" : "Download as .tar.gz…") { actions?.download(items) }
                .help("Download the items as one archive, to keep a copy before deleting")
        }
        Divider()
        Button("Empty File…") { actions?.empty(items) }
            .disabled(actions?.emptyProblem(items) != nil)
            .help(actions?.emptyProblem(items) ?? "Make the files 0 bytes: frees their room at once (asks first)")
        Button("Delete…") { actions?.delete(items) }
            .disabled(model.scanning)
            .help(model.scanning ? "Wait for the scan to end, or stop it" : "Delete the items (asks first)")
    }

    private var emptyText: String? {
        guard model.rows.isEmpty else { return nil }
        if !model.search.isEmpty { return "Nothing here has “\(model.search)” in its name." }
        switch model.shown {
        case .changes:
            if model.scanning { return "Changes show when the scan ends." }
            guard let previous = model.previous else {
                return "Nothing to compare with yet: this was the first full scan of “\(model.title)” here. "
                    + "Scan again later to see what grew since."
            }
            return "Nothing changed here since \(previous.date.formatted(date: .abbreviated, time: .shortened))."
        case .largest:
            return model.scanning ? "Looking for the largest files…" : "No files below this folder."
        default:
            return model.scanning ? "Scanning…" : "This folder is empty. Choose Scan Again to measure it again."
        }
    }
}

/// A share of the folder shown: a bar and its percentage.
struct ShareBar: View {
    let size: Int64
    let total: Int64

    var body: some View {
        let fraction = Double(min(size, total)) / Double(max(total, 1))
        HStack(spacing: 6) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(Color(nsColor: .pill).opacity(0.75)).frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 6)
            Text(fraction.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().foregroundColor(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
        .help("Its share of the folder shown")
    }
}

/// The disk: the folder scanned (the pill's colour), the rest used (grey) and free (empty).
struct DiskBar: View {
    let space: DiskUsage.Space
    let folder: Int64

    var body: some View {
        GeometryReader { geometry in
            let total = Double(max(space.total, 1)), width = geometry.size.width
            let used = Double(max(space.total - space.free, 0)) / total, mine = min(Double(folder) / total, used)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(Color.primary.opacity(0.28)).frame(width: width * used)
                Capsule().fill(Color(nsColor: .pill)).frame(width: max(width * mine, mine > 0 ? 3 : 0))
            }
        }
    }
}

/// The rings: the folder shown in the middle, its items around it, theirs further out, each arc as wide as its share.
/// Pointing at an arc names it; clicking a folder's arc goes into it, a file's selects it, the middle goes up. The item
/// pointed at, here or in the list, and those selected are lit.
struct DiskUsageRings: View {
    @ObservedObject var model: DiskUsageModel

    var body: some View {
        let pointed = model.pointed.flatMap { id in model.segments.first { $0.item.id == id }?.item }
        VStack(spacing: 6) {
            GeometryReader { geometry in
                let side = min(geometry.size.width, geometry.size.height)
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                let inner = side * 0.16, ring = (side / 2 - inner) / CGFloat(DiskUsageModel.rings)
                let lit = model.selection.union(model.pointed.map { [$0] } ?? [])
                Canvas { context, _ in
                    for segment in model.segments {
                        let from = inner + CGFloat(segment.depth) * ring
                        var path = Path()
                        path.addArc(center: center, radius: from + ring - 1, startAngle: .degrees(segment.start * 360 - 90),
                                    endAngle: .degrees(segment.end * 360 - 90), clockwise: false)
                        path.addArc(center: center, radius: from, startAngle: .degrees(segment.end * 360 - 90),
                                    endAngle: .degrees(segment.start * 360 - 90), clockwise: true)
                        path.closeSubpath()
                        let on = lit.contains(segment.item.id)
                        let color = Color(hue: segment.hue, saturation: segment.item.isFolder ? 0.55 - 0.12 * Double(segment.depth) : 0.12,
                                          brightness: on ? 1 : 0.88 - 0.06 * Double(segment.depth))
                        context.fill(path, with: .color(color))
                        context.stroke(path, with: .color(on ? Color.primary : Color(nsColor: .windowBackgroundColor)), lineWidth: on ? 1.5 : 0.5)
                    }
                }
                .overlay {
                    VStack(spacing: 2) {
                        Text(model.folder.map { FileList.size($0.size) } ?? "—").font(.headline).monospacedDigit()
                        Text(model.folder.map { "\($0.files.formatted()) files" } ?? "").font(.caption2).foregroundColor(.secondary)
                    }
                    .frame(width: inner * 1.8)
                    .allowsHitTesting(false)
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    if case .active(let point) = phase { model.pointed = hit(point, center, inner, ring)?.item.id } else { model.pointed = nil }
                }
                .onTapGesture(coordinateSpace: .local) { point in
                    let distance = hypot(point.x - center.x, point.y - center.y)
                    if distance < inner { return model.goUp() }
                    guard let item = hit(point, center, inner, ring)?.item, !model.open(item) else { return }
                    model.selection = [item.id]
                }
            }
            Text(pointed.map { "\($0.name): \(FileList.size($0.size))" } ?? " ")
                .font(.caption).lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Disk usage rings of \(model.folder?.name ?? model.title)")
        .accessibilityIdentifier("diskUsage.rings")
        .help("Point at an arc to see what it is; click a folder's arc to go into it, the middle to go up")
    }

    /// The arc under `point`, if any.
    private func hit(_ point: CGPoint, _ center: CGPoint, _ inner: CGFloat, _ ring: CGFloat) -> DiskUsageModel.Segment? {
        let distance = hypot(point.x - center.x, point.y - center.y)
        guard distance >= inner else { return nil }
        let depth = Int((distance - inner) / ring)
        // 0 at the top, going clockwise, as the arcs are drawn.
        var turn = (atan2(point.y - center.y, point.x - center.x) / (2 * .pi) + 0.25)
        if turn < 0 { turn += 1 }
        return model.segments.first { $0.depth == depth && $0.start <= turn && turn < $0.end }
    }
}
