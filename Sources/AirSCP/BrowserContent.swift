import AirSCPCore
import AppKit
import Combine

/// The host workspace's Files tab: two panes side by side. The left one shows this Mac or any connected server (its
/// source menu), the right one this host. Items go between them by drag and drop, the transfer buttons or copy and
/// paste: uploads and downloads (queued, in the Transfers panel), copies and moves within a server, and copies
/// between two servers. Name conflicts are asked about first. Also here: the built-in editor, Get Info, and files
/// opened in other apps, which are watched so that changes can be uploaded. One is made per Session, so `session`
/// never changes for the life of this object.
@MainActor
final class BrowserContentController: NSViewController {
    /// The host's workspace: `connect(then:)`, `show(_:title:)`, `openTerminal(in:)`, `openTerminal(command:)`,
    /// `showRunCommand(_:run:)`, `connectedSessions`, `host`, `model.data.settings`, `model.updateHost(_:_:)` (e.g. the
    /// local pane's `lastLocalDir`).
    weak var workspace: HostWorkspace?
    let session: Session
    /// This Mac, or any connected server.
    private(set) var left: FilePane!
    /// This host.
    private(set) var right: FilePane!

    private let split = SurfaceSplitView()
    private var placedDivider = false
    private var clipboard: Clipboard?
    private var editors: [String: RemoteEditor] = [:]
    private var watched: [WatchedFile] = []
    /// Files for "Open" that download through the transfer queue, by job: opened once there.
    private var opening: [UUID: WatchedFile] = [:]
    private var watchTimer: Timer?
    private var askingToUpload = false
    /// Finished jobs whose folder was listed again (or that had finished before this tab existed).
    private var handledJobs: Set<UUID> = []
    /// Folders of finished jobs, listed again once their host has no transfer left (a batch lists a folder once), or
    /// after 10 s.
    private var pendingReloads: [(hostID: UUID, local: Bool, dir: String, since: Date)] = []
    /// Copies being prepared (the destination listed, conflicts asked) before their jobs are queued: agent control's
    /// `wait transfers_done` waits for these too.
    private(set) var planning = 0
    private var subscriptions: Set<AnyCancellable> = []
    /// Downloads for Quick Look and "Open with"; removed when this goes away.
    private let temporaryRoot = FileManager.default.temporaryDirectory.appendingPathComponent("AirSCP-" + UUID().uuidString)

    /// Copied (or cut) server items; valid while the pasteboard is still what was written then.
    private struct Clipboard {
        let session: Session
        let items: [FileItem]
        let cut: Bool
        let changeCount: Int
    }

    /// A server file opened in another app: its download is watched for changes.
    private struct WatchedFile {
        var session: Session
        let remotePath: String
        let local: URL
        var modified: Date
    }

    /// `workspace` nil (tests): no window to show errors in, and the settings' defaults.
    init(workspace: HostWorkspace?, session: Session) {
        self.workspace = workspace
        self.session = session
        super.init(nibName: nil, bundle: nil)
        // deinit doesn't run when AirSCP quits: the downloads went with nothing to remove them.
        NotificationCenter.default.addObserver(self, selector: #selector(removeTemporaryFiles),
                                               name: NSApplication.willTerminateNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    @objc private func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    override func loadView() {
        let showHidden = settings.showHidden
        left = FilePane(source: .local, choosesSource: true, showHidden: showHidden)
        right = FilePane(source: .remote(session), choosesSource: false, showHidden: showHidden)
        split.isVertical = true
        split.dividerStyle = .thin
        for (index, pane) in [left!, right!].enumerated() {
            pane.browser = self
            addChild(pane)
            split.addArrangedSubview(pane.view)
            split.setHoldingPriority(.defaultLow, forSubviewAt: index)  // both panes grow with the window
        }
        view = split
        left.setSource(.local, startIn: localStart)
        right.connectionChanged(session.state, startIn: remoteStart(session))
        handledJobs = Set(TransferCenter.shared.jobs.filter(\.status.isFinished).map(\.id))
        TransferCenter.shared.$jobs
            .sink { [weak self] jobs in self?.jobsChanged(jobs) }
            .store(in: &subscriptions)
        workspace?.model.$states
            .sink { [weak self] states in self?.statesChanged(states) }
            .store(in: &subscriptions)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        if !placedDivider && split.bounds.width > 0 {
            placedDivider = true
            split.setPosition((split.bounds.width / 2).rounded(), ofDividerAt: 0)
        }
    }

    /// Every state change of `session`, after the banner was updated. On `.connected`, `session.capabilities` is
    /// known: the remote pane starts in `workspace.host.defaultRemoteDir`, else `capabilities.home`.
    func stateChanged(_ state: Session.State) {
        _ = view  // loads it
        right.connectionChanged(state, startIn: remoteStart(session))
    }

    /// Transfers queued or running: Close and Quit ask before cancelling them.
    var runningTransferCount: Int {
        session.transfers.jobs.filter { !$0.status.isFinished }.count
    }

    // MARK: For the panes

    var settings: AppSettings { workspace?.model.data.settings ?? AppSettings() }

    var connectedSessions: [Session] { workspace?.connectedSessions ?? [] }

    func otherPane(of pane: FilePane) -> FilePane { pane === left ? right : left }

    /// The pane whose table a drag comes from.
    func pane(dragging info: NSDraggingInfo) -> FilePane? {
        guard let table = info.draggingSource as? NSTableView else { return nil }
        return [left, right].first { $0?.table === table } ?? nil
    }

    func show(_ error: Error, title: String, from pane: FilePane) {
        workspace?.show(error, title: title)
    }

    /// The left pane's source menu.
    func chooseSource(_ source: FilePane.Source, for pane: FilePane) {
        guard !source.isSame(as: pane.source) else { return }
        switch source {
        case .local: pane.setSource(.local, startIn: localStart)
        case .remote(let session): pane.setSource(source, startIn: remoteStart(session))
        }
    }

    /// The local pane's folder is remembered per host.
    func localFolderChanged(_ dir: String) {
        workspace?.model.updateHost(session.host.id) { $0.lastLocalDir = dir }
    }

    private var localStart: String {
        if let dir = (workspace?.host ?? session.host).lastLocalDir, FileList.isLocalFolder(dir) { return dir }
        return NSHomeDirectory()
    }

    /// The server's "Remote folder" setting (~ and relative to the home folder allowed), else its home folder.
    private func remoteStart(_ session: Session) -> String {
        let home = session.capabilities.home
        let saved = (session === self.session ? workspace?.host.defaultRemoteDir : nil) ?? session.host.defaultRemoteDir
        let typed = saved.trimmingCharacters(in: .whitespaces)
        if typed.isEmpty { return home }
        if typed == "~" { return home }
        let path = typed.hasPrefix("~/") ? RemotePath.join(home, String(typed.dropFirst(2)))
            : typed.hasPrefix("/") ? typed : RemotePath.join(home, typed)
        return FilePane.normalized(path)
    }

    /// A fresh folder for downloads that Quick Look and other apps open.
    func temporaryFolder() -> URL? {
        let folder = temporaryRoot.appendingPathComponent(UUID().uuidString.prefix(8).lowercased(), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            workspace?.show(error, title: "AirSCP can't make a temporary folder")
            return nil
        }
    }

    /// The server shown on the left was disconnected: back to this Mac.
    private func statesChanged(_ states: [UUID: Session.State]) {
        guard let left, case .remote(let shown) = left.source, states[shown.host.id] != .connected else { return }
        left.setSource(.local, startIn: localStart)
    }

    // MARK: Copying between the panes

    struct TransferTitles {
        var button = ""
        var menu: String?
        var tip: String?
    }

    /// The transfer button's title and its menu item's, for copying `pane`'s selection into the other pane.
    func transferTitle(for pane: FilePane) -> TransferTitles {
        let other = otherPane(of: pane)
        guard let dir = other.dir else { return TransferTitles() }
        let place = "“\(other.displayName(dir))”"
        switch (pane.source, other.source) {
        case (.local, .remote(let server)):
            return TransferTitles(button: "Upload", menu: "Upload to \(place)",
                                  tip: "Upload the selection to \(dir) on \(server.host.displayName)")
        case (.remote, .local):
            return TransferTitles(button: "Download", menu: "Download to \(place)", tip: "Download the selection to \(dir)")
        case (.remote(let from), .remote(let to)):
            let target = from.host.id == to.host.id ? place : "\(to.host.displayName) \(place)"
            return TransferTitles(button: "Copy", menu: "Copy to \(target)", tip: "Copy the selection to \(dir) on \(to.host.displayName)")
        case (.local, .local):
            return TransferTitles()
        }
    }

    func copyToOtherPane(_ items: [FileItem], from pane: FilePane) {
        let other = otherPane(of: pane)
        guard let dir = other.dir else { return }
        transfer(items, from: pane.source, to: other.source, into: dir, move: false)
    }

    /// What a drop of `items` would do: copy, move (within one server, unless ⌥ is held) or nothing.
    static func dropOperation(_ items: [FileItem], from source: FilePane.Source, to destination: FilePane.Source, into dir: String,
                       mask: NSDragOperation) -> NSDragOperation {
        guard !items.isEmpty else { return [] }
        switch (source, destination) {
        case (.local, .local):
            return []
        case (.remote(let from), .remote(let to)) where from.host.id == to.host.id:
            if items.contains(where: { dir == $0.path || dir.hasPrefix($0.path + "/") }) { return [] }
            if mask.contains(.move) { return items.allSatisfy { RemotePath.parent($0.path) == dir } ? [] : .move }
            // A copy within the server is cp: not on an account without a shell (a move is sftp's rename).
            return mask.contains(.copy) && from.capabilities.shell ? .copy : []
        default:
            return mask.contains(.copy) ? .copy : []
        }
    }

    /// Copies (or, within one server, moves) `items` into `dir`: an upload, a download, a copy within the server or
    /// a copy between two servers. Name conflicts are asked about first; transfers then run in the queue.
    func transfer(_ items: [FileItem], from source: FilePane.Source, to destination: FilePane.Source, into dir: String,
                  move: Bool) {
        guard !items.isEmpty else { return }
        planning += 1
        Task {
            defer { planning -= 1 }
            switch (source, destination) {
            case (.local, .remote(let server)):
                await upload(items, to: server, into: dir)
            case (.remote(let server), .local):
                await download(items, from: server, into: dir)
            case (.remote(let from), .remote(let to)) where from.host.id == to.host.id:
                await copyWithin(items, on: to, into: dir, move: move)
            case (.remote(let from), .remote(let to)):
                await relay(items, from: from, to: to, into: dir)
            case (.local, .local):
                break
            }
        }
    }

    /// `compress`: Upload Compressed (nil: asked about for folders and many items).
    private func upload(_ items: [FileItem], to server: Session, into dir: String, compress forced: Bool? = nil) async {
        guard isConnected(server), namesFit(items, on: server) else { return }
        let place = name(of: dir, on: server)
        guard let existing = await entries(of: dir, on: server, failure: "Can't upload to \(place)") else { return }
        var compress = forced ?? false, leaveOut: [String] = []
        let folders = items.filter { FileList.isLocalFolder($0.path) }.count
        if forced == nil && (folders > 0 || items.count >= TransferQueue.streamThreshold) {
            guard let choice = await askFolderTransfer(items.count, folders: folders, verb: "Upload", into: place, server: server)
            else { return }
            (compress, leaveOut) = choice
        }
        let items = items.filter { !TransferQueue.leftOut($0.name, by: leaveOut) }  // the picked items too
        // A name with a line break isn't in a listing (ls prints it on two lines): the server is asked about those.
        var unlisted: [String] = []
        for item in items where item.name.contains(where: \.isNewline) {
            if (try? await server.exists(RemotePath.join(dir, item.name))) == true { unlisted.append(item.name) }
        }
        guard !items.isEmpty,
              let plan = await plan(items, existing: existing.map(\.name) + unlisted, pending: pendingNames(in: dir, on: server),
                                    caseInsensitive: server.capabilities.caseInsensitive, in: place, keepBoth: !compress,
                                    destination: Self.item(in: existing)) else { return }
        // Replaced items of another kind (a file over a folder), or under another spelling of the name, go first:
        // scp would copy into the old folder, and tar would add the new name next to the old one.
        let byName = Dictionary(existing.map { ($0.name, $0) }) { first, _ in first }
        let stale = zip(items, plan).compactMap { item, step -> RemoteEntry? in
            guard let old = step?.replaces, let entry = byName[old] else { return nil }
            let differs = (entry.kind == .directory) != FileList.isLocalFolder(item.path) || (compress && old != item.name)
            return differs ? entry : nil
        }
        if !stale.isEmpty {
            let deleted = await pane(showing: server).perform("Replacing…", failure: "Can't replace the old items") {
                try await server.delete(stale)
            }
            guard deleted else { return }
        }
        let chosen = zip(items, plan).compactMap { item, step in step.map { (item: item, step: $0) } }
        if compress {
            // One archive per folder on this Mac that the items are in (Finder drops can mix folders).
            let groups = Dictionary(grouping: chosen) { RemotePath.parent($0.item.path) }
            for (folder, group) in groups.sorted(by: { $0.key < $1.key }) {
                server.transfers.uploadCompressed(group.map(\.item.name), in: folder, to: dir,
                                                  replacing: group.contains { $0.step.replaces != nil }, excluding: leaveOut)
            }
        } else {
            for (item, step) in chosen {
                server.transfers.upload(item.path, to: RemotePath.join(dir, step.name), isFolder: FileList.isLocalFolder(item.path),
                                        replacing: step.replaces != nil, preserveTimes: settings.preserveTimes, excluding: leaveOut)
            }
        }
    }

    private func download(_ items: [FileItem], from server: Session, into dir: String) async {
        guard isConnected(server) else { return }
        let existing = await Task.detached(priority: .userInitiated) { FileList.localNames(dir) }.value
        let place = "“\(RemotePath.name(dir))”"
        var compress = false, leaveOut: [String] = []
        let folders = items.filter(\.isFolder).count
        if folders > 0 || items.count >= TransferQueue.streamThreshold {
            guard let choice = await askFolderTransfer(items.count, folders: folders, verb: "Download", into: place, server: server)
            else { return }
            (compress, leaveOut) = choice
        }
        let items = items.filter { !TransferQueue.leftOut($0.name, by: leaveOut) }  // the picked items too
        guard let plan = await plan(items, existing: existing, pending: pendingNames(in: dir, on: nil), caseInsensitive: true,
                                    in: place, keepBoth: !compress, destination: { FileList.localItem(RemotePath.join(dir, $0)) })
        else { return }
        let chosen = zip(items, plan).compactMap { item, step in step.map { (item: item, step: $0) } }
        guard !chosen.isEmpty else { return }
        if compress {
            // Unpacking merges into what is there: replaced items go to the Trash first, so Replace replaces.
            let replaced = chosen.compactMap(\.step.replaces).map { URL(fileURLWithPath: RemotePath.join(dir, $0)) }
            do {
                for url in replaced { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            } catch {
                return workspace?.show(error, title: "Can't move the old items to the Trash") ?? ()
            }
            let base = chosen.count == 1 ? chosen[0].item.name : "Archive"
            let archive = Names.unique(base + ".tar.gz", existing: existing, caseInsensitive: true)
            server.transfers.downloadArchive(chosen.map(\.item.name), in: RemotePath.parent(chosen[0].item.path),
                                             to: RemotePath.join(dir, archive), extract: true, excluding: leaveOut)
        } else {
            for (item, step) in chosen {
                server.transfers.download(item.path, to: RemotePath.join(dir, step.name), isFolder: item.kind != .file,
                                          replacing: step.replaces != nil, preserveTimes: settings.preserveTimes, excluding: leaveOut)
            }
        }
    }

    /// Server to server: one job in the destination's queue (a tar stream through this Mac where both allow it).
    private func relay(_ items: [FileItem], from source: Session, to server: Session, into dir: String) async {
        guard isConnected(source), isConnected(server), namesFit(items, on: server) else { return }
        let place = name(of: dir, on: server)
        guard let existing = await entries(of: dir, on: server, failure: "Can't copy to \(place)"),
              let plan = await plan(items, existing: existing.map(\.name), pending: pendingNames(in: dir, on: server),
                                    caseInsensitive: server.capabilities.caseInsensitive, in: place, keepBoth: false,
                                    destination: Self.item(in: existing))
        else { return }
        let chosen = zip(items, plan).compactMap { item, step in step.map { (item: item, step: $0) } }
        guard !chosen.isEmpty else { return }
        server.transfers.relay(chosen.map(\.item.name), in: RemotePath.parent(chosen[0].item.path), from: source, to: dir,
                               replacing: chosen.contains { $0.step.replaces != nil })
    }

    /// Within one server: cp -R or a move, item by item, in the control lane (no queue job).
    private func copyWithin(_ items: [FileItem], on server: Session, into dir: String, move: Bool) async {
        guard isConnected(server) else { return }
        if let looped = items.first(where: { dir == $0.path || dir.hasPrefix($0.path + "/") }) {
            return workspace?.show(AirSCPError(.other, "“\(looped.name)” can't go into itself."),
                                   title: move ? "Can't move" : "Can't copy") ?? ()
        }
        let moving = move ? items.filter { RemotePath.parent($0.path) != dir } : items
        let place = name(of: dir, on: server)
        guard !moving.isEmpty,
              let existing = await entries(of: dir, on: server, failure: "Can't \(move ? "move" : "copy") to \(place)"),
              // Copies into their own folder keep both without asking, like Finder's Duplicate.
              let plan = await plan(moving, existing: existing.map(\.name), caseInsensitive: server.capabilities.caseInsensitive,
                                    in: place, keepBoth: true,
                                    keepingBoth: Set(moving.filter { RemotePath.parent($0.path) == dir }.map(\.name)),
                                    destination: Self.item(in: existing))
        else { return }
        let byName = Dictionary(existing.map { ($0.name, $0) }) { first, _ in first }
        await pane(showing: server, dir).perform(move ? "Moving…" : "Copying…", failure: move ? "Can't move" : "Can't copy") {
            for (item, step) in zip(moving, plan) {
                guard let step else { continue }
                let target = RemotePath.join(dir, step.name)
                if let old = step.replaces, let entry = byName[old] {
                    // The old item stays until the new one is complete (and stays as it was if the copy fails).
                    if old != step.name { try await server.delete([entry]) }  // another spelling: it goes first
                    else {
                        try await server.copy(item.path, replacing: target, folder: item.isFolder || entry.kind == .directory,
                                              move: move)
                        continue
                    }
                }
                if move {
                    try await server.move(item.path, to: target)
                } else {
                    try await server.copy(item.path, to: target)
                }
            }
        }
        for pane in [left!, right!] where pane.session?.host.id == server.host.id { await pane.reload() }
    }

    /// The pane showing `dir` on the server, else one showing the server: where its work shows a spinner.
    private func pane(showing server: Session, _ dir: String? = nil) -> FilePane {
        let panes = [right!, left!].filter { $0.session?.host.id == server.host.id }
        return panes.first { $0.dir == dir } ?? panes.first ?? right
    }

    private func isConnected(_ server: Session) -> Bool {
        guard server.state != .connected else { return true }
        workspace?.show(AirSCPError(.other, "“\(server.host.displayName)” isn't connected. Select it in the sidebar and "
                                    + "click Connect, then copy again."), title: "Can't copy")
        return false
    }

    /// A Windows server can't store some names (a ":" would even hide the data in a stream of a file named up to it):
    /// say which, instead of copying.
    private func namesFit(_ items: [FileItem], on server: Session) -> Bool {
        guard server.capabilities.windows else { return true }
        let refused = items.map(\.name).filter { FileList.windowsNameProblem($0) != nil }
        guard !refused.isEmpty else { return true }
        let shown: [String] = refused.prefix(5).map { "“" + $0 + "”" }
        let list = shown.joined(separator: ", ") + (refused.count > 5 ? ", …" : "")
        let message = "Windows can't store " + (refused.count == 1 ? "this name: " : "these names: ") + list + ". "
        workspace?.show(AirSCPError(.other, message + FileList.windowsRule), title: "Rename the items first")
        return false
    }

    /// “dev” on the server (its name when that is /).
    private func name(of dir: String, on server: Session) -> String {
        "“\(dir == "/" ? server.host.displayName : RemotePath.name(dir))”"
    }

    /// The item named so among a server folder's entries (a conflict's existing item).
    private static func item(in entries: [RemoteEntry]) -> (String) -> FileItem? {
        { name in entries.first { $0.name == name }.map(FileItem.init) }
    }

    /// A server folder's entries for a conflict check, listed now: a pane's rows may be older than what is there (an
    /// item someone made since would be overwritten without a question).
    private func entries(of dir: String, on server: Session, failure: String) async -> [RemoteEntry]? {
        do {
            return try await server.list(dir)
        } catch {
            workspace?.show(error, title: failure)
            return nil
        }
    }

    /// The names that unfinished transfers put into `dir` on `server` (nil: on this Mac). They aren't there yet, but a
    /// copy of the same name would collide with them: it copied everything and only then failed.
    private func pendingNames(in dir: String, on server: Session?) -> [String] {
        TransferCenter.shared.currentJobs.filter { !$0.status.isFinished }.flatMap { job -> [String] in
            let download = job.direction == .download
            guard server.map({ !download && job.hostID == $0.host.id }) ?? download else { return [] }
            // Compressed uploads, relays and unpacked archives put their items into a folder; the others one item.
            let items = !job.names.isEmpty && (!download || job.isFolder)
            let folder = items && !download ? job.destination : RemotePath.parent(job.destination)
            return folder != dir ? [] : items ? job.names : [job.name]
        }
    }

    /// Asks about the names that exist at the destination (`keepingBoth`: those keep both without asking), or that
    /// `pending` transfers put there, then plans each item: nil for a skipped one. The name comparisons run off the main
    /// thread (folders can be huge). `destination` gives the item there by its name, for the question's line about
    /// both (sizes and dates).
    private func plan(_ items: [FileItem], existing: [String], pending: [String] = [], caseInsensitive: Bool, in place: String,
                      keepBoth: Bool, keepingBoth: Set<String> = [],
                      destination: @escaping (String) -> FileItem?) async -> [FileList.Planned?]? {
        let names = items.map(\.name), existing = existing + pending
        let found = await Task.detached(priority: .userInitiated) {
            FileList.existingNames(for: names, existing: existing, caseInsensitive: caseInsensitive)
        }.value
        let conflicts = names.filter { found[$0] != nil && !keepingBoth.contains($0) }
        guard var choices = await askConflicts(conflicts, in: place, keepBoth: keepBoth, detail: { name in
            guard let item = items.first(where: { $0.name == name }), let old = found[name] else { return nil }
            if let there = destination(old) { return FileList.comparison(new: item, existing: there) }
            return pending.contains(old) ? "A transfer that is queued or running puts an item of that name there." : nil
        }) else { return nil }
        for name in keepingBoth { choices[name] = .keepBoth }
        let decided = choices
        return await Task.detached(priority: .userInitiated) {
            FileList.plan(names, existing: existing, caseInsensitive: caseInsensitive, choices: decided)
        }.value
    }

    /// Uploads files from Finder (a drop, Paste, or the Upload panel) into a server pane's folder.
    func upload(_ urls: [URL], to pane: FilePane, into dir: String) {
        planning += 1
        Task {
            defer { planning -= 1 }
            let items = await Task.detached(priority: .userInitiated) { FileList.localItems(urls) }.value
            transfer(items, from: .local, to: pane.source, into: dir, move: false)
        }
    }

    // MARK: Sheets

    /// Replace / Keep Both / Skip for each name, with "Apply to all"; nil when cancelled. `keepBoth` false: the
    /// transfer can't rename (archives and server-to-server copies). `detail`: a name's line about both items.
    func askConflicts(_ names: [String], in place: String, keepBoth: Bool,
                      detail: (String) -> String? = { _ in nil }) async -> [String: FileList.Choice]? {
        var choices: [String: FileList.Choice] = [:]
        var forAll: FileList.Choice?
        for (index, name) in names.enumerated() {
            if let forAll {
                choices[name] = forAll
                continue
            }
            let alert = NSAlert()
            alert.messageText = "“\(name)” already exists in \(place)."
            alert.informativeText = [detail(name), keepBoth ? "Replace it, keep both (the new one gets a number), or skip it?"
                : "Replace it, or skip it?"].compactMap { $0 }.joined(separator: "\n")
            let replace = alert.addButton(withTitle: "Replace")
            replace.hasDestructiveAction = true
            replace.toolTip = "Put the new item in place of the existing one"
            if keepBoth { alert.addButton(withTitle: "Keep Both").toolTip = "Keep both: the new one gets a number" }
            alert.addButton(withTitle: "Skip").toolTip = "Leave the existing one as it is; don't copy this item"
            alert.addButton(withTitle: "Cancel").toolTip = "Stop: copy nothing"
            let others = names.count - index - 1
            if others > 0 {
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = others == 1 ? "Do the same for the other conflict"
                    : "Do the same for the other \(others) conflicts"
                alert.suppressionButton?.toolTip = "Answer the other conflicts the same way, without asking"
            }
            alert.addHelp(.conflicts)
            let response = await run(alert)
            let buttons: [FileList.Choice] = keepBoth ? [.replace, .keepBoth, .skip] : [.replace, .skip]
            let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard index >= 0, index < buttons.count else { return nil }
            choices[name] = buttons[index]
            if alert.suppressionButton?.state == .on { forAll = buttons[index] }
        }
        return choices
    }

    /// The sheet before copying folders, or many items (each would be a transfer of its own: one stream is much
    /// faster): what goes where, symbolic links, "Compress during transfer" (on by default where the server has tar)
    /// and "Leave out" (names or patterns, remembered for the server). nil: cancelled; else whether to compress and the
    /// patterns.
    private func askFolderTransfer(_ count: Int, folders: Int, verb: String, into place: String,
                                   server: Session) async -> (compress: Bool, leaveOut: [String])? {
        let reason = server.compressUnavailableReason(.tarGz)
        let alert = NSAlert()
        let what = count == folders ? (folders == 1 ? "1 folder" : "\(folders) folders") : FileList.items(count)
        alert.messageText = "\(verb) \(what) to \(place)?"
        alert.informativeText = [
            folders == 0 ? nil : reason == nil ? "Each folder goes as one stream; the symbolic links in it stay links."
                : "This server can't send folders as one stream: symbolic links are copied as the files they point to.",
            reason.map { "Compressing isn't possible here: \($0)" }
                ?? "Compressing packs everything into one .tar.gz stream: faster on slow connections and for many small "
                    + "files, slower on fast ones.",
        ].compactMap { $0 }.joined(separator: "\n\n")
        alert.addButton(withTitle: verb).toolTip = "Start the transfer; it runs in the Transfers queue"
        alert.addButton(withTitle: "Cancel").toolTip = "Don't copy anything"
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Compress during transfer — faster on slow links and for many small files"
        alert.suppressionButton?.toolTip = reason ?? "One .tar.gz stream: faster on slow connections and for many small "
            + "files, slower on fast ones"
        // On by default for many loose files (else each would be a transfer of its own); folders stream anyway.
        alert.suppressionButton?.state = reason == nil && count - folders >= TransferQueue.streamThreshold ? .on : .off
        alert.suppressionButton?.isEnabled = reason == nil
        let saved = workspace?.model.host(server.host.id)?.leaveOut ?? server.host.leaveOut
        let streams = server.capabilities.shell && server.capabilities.tools.contains("tar")
        let field = NSTextField(string: saved)
        field.placeholderString = "*.log, node_modules, .git"
        field.setAccessibilityIdentifier("transfer.leaveOut")
        field.toolTip = "Optional. Names or patterns to leave out of the copy, wherever they are: * ? and [ ] work, commas "
            + "separate them. Remembered for this server."
        let caption = NSTextField(wrappingLabelWithString: streams
            ? "Optional: names or patterns separated by commas (* ? [ ] work), left out wherever they are. Remembered for "
                + "this server."
            : "Optional: names or patterns separated by commas. This server copies folders whole (with scp), so only the "
                + "items picked are left out.")
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        caption.preferredMaxLayoutWidth = 300
        let stack = NSStackView(views: [NSTextField(labelWithString: "Leave out:"), field, caption])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
        stack.setFrameSize(stack.fittingSize)
        alert.accessoryView = stack
        alert.addHelp(.folderTransfer)
        guard await run(alert) == .alertFirstButtonReturn else { return nil }
        if field.stringValue != saved { workspace?.model.updateHost(server.host.id) { $0.leaveOut = field.stringValue } }
        return (alert.suppressionButton?.state == .on, TransferQueue.patterns(field.stringValue))
    }

    /// Shows the alert as a sheet and returns the button chosen (Cancel without a window).
    private func run(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window = view.window else { return .cancel }
        return await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
    }

    // MARK: Archive transfers

    /// Download as .tar.gz: the server streams one archive (no space needed there); "Extract after download"
    /// unpacks it here.
    func downloadArchive(_ items: [FileItem], from pane: FilePane) {
        guard let server = pane.session, let sourceDir = pane.dir else { return }
        let other = otherPane(of: pane)
        let dir = !other.isRemote ? other.dir ?? settings.downloadFolder : settings.downloadFolder
        planning += 1
        Task {
            defer { planning -= 1 }
            let alert = NSAlert()
            alert.messageText = items.count == 1 ? "Download “\(items[0].name)” as a .tar.gz archive?"
                : "Download \(FileList.items(items.count)) as one .tar.gz archive?"
            alert.informativeText = "Into “\(RemotePath.name(dir))”. The server packs it as it sends it, so the progress "
                + "shows the bytes received rather than a percentage."
            alert.addButton(withTitle: "Download").toolTip = "Start the download; it runs in the Transfers queue"
            alert.addButton(withTitle: "Cancel").toolTip = "Don't download"
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Unpack it after the download (the archive is removed)"
            alert.suppressionButton?.toolTip = "Off by default: you get the .tar.gz. On, its items land in the folder instead"
            alert.suppressionButton?.state = .off
            alert.addHelp(.downloadArchive)
            guard await run(alert) == .alertFirstButtonReturn else { return }
            let extract = alert.suppressionButton?.state == .on
            let existing = await Task.detached(priority: .userInitiated) { FileList.localNames(dir) }.value
            var names = items.map(\.name)
            if extract {
                guard let plan = await plan(items, existing: existing, pending: pendingNames(in: dir, on: nil), caseInsensitive: true,
                                            in: "“\(RemotePath.name(dir))”", keepBoth: false,
                                            destination: { FileList.localItem(RemotePath.join(dir, $0)) })
                else { return }
                names = zip(items, plan).compactMap { item, step in step == nil ? nil : item.name }
                guard !names.isEmpty else { return }
            }
            let base = names.count == 1 ? names[0] : "Archive"
            let archive = Names.unique(base + ".tar.gz", existing: existing, caseInsensitive: true)
            server.transfers.downloadArchive(names, in: sourceDir, to: RemotePath.join(dir, archive), extract: extract)
        }
    }

    /// Upload Compressed: this Mac's items packed into one .tar.gz, uploaded and unpacked into the other pane's
    /// server folder (Replace or Skip for names that exist there).
    func uploadCompressed(_ items: [FileItem], from pane: FilePane) {
        let other = otherPane(of: pane)
        guard let server = other.session, let dir = other.dir, pane.dir != nil, isConnected(server) else { return }
        planning += 1
        Task {
            defer { planning -= 1 }
            await upload(items, to: server, into: dir, compress: true)
        }
    }

    // MARK: Synchronize

    /// A Synchronize plan's files of one folder go as one stream from this many on.
    static let syncStreamThreshold = 20

    /// The panes Synchronize compares: one showing a folder on this Mac, the other one on a connected server.
    var synchronizedPanes: (local: FilePane, remote: FilePane)? {
        guard let left, let right else { return nil }
        let panes = [left, right]
        guard let local = panes.first(where: { !$0.isRemote && $0.dir != nil }),
              let remote = panes.first(where: { $0.isRemote && $0.dir != nil && $0.isConnected }) else { return nil }
        return (local, remote)
    }

    /// Synchronize (PLAN.md S.1): compares the two panes' folders, shows what would be copied or deleted, and on
    /// Synchronize queues it.
    func synchronize() {
        guard let window = view.window, let (local, remote) = synchronizedPanes, let server = remote.session,
              let localDir = local.dir, let remoteDir = remote.dir else { return }
        let saved = workspace?.model.host(server.host.id)?.leaveOut ?? server.host.leaveOut
        let model = SyncModel(session: server, localDir: localDir, remoteDir: remoteDir, leaveOut: saved)
        presentSheet(on: window) { close in
            SyncView(model: model, close: {
                model.cancel()
                close()
            }, synchronize: { [weak self] plan in
                close()
                // Remembered for the server, as the folder-transfer sheet does.
                if model.leaveOut != saved { self?.workspace?.model.updateHost(server.host.id) { $0.leaveOut = model.leaveOut } }
                self?.apply(plan, on: server, excluding: model.patterns)
            })
        }
        if !model.waitsForCompare { model.compare() }
    }

    /// Queues a Synchronize plan's copies (times kept, whatever Settings say: the next compare must find them the same)
    /// and runs its deletions: Delete on the server, Move to Trash on this Mac. `patterns`: the Leave out patterns the
    /// plan was made with, which a folder copied whole as a stream leaves out inside it.
    func apply(_ plan: Sync.Plan, on server: Session, excluding patterns: [String] = []) {
        // Many files of one folder go as one stream (a job per file costs a round trip or two each); times are kept.
        var streamed = Set<String>()
        if server.compressUnavailableReason(.tarGz) == nil {
            let loose = plan.steps.filter { step in
                [.upload, .download].contains(step.action) && !step.item.isFolder
                    && RemotePath.name(step.destination) == step.item.name  // the same spelling on both sides
            }
            let groups = Dictionary(grouping: loose) { step in
                "\(step.action == .upload ? "up" : "down")\0\(RemotePath.parent(step.item.path))\0\(RemotePath.parent(step.destination))"
            }
            for group in groups.values.sorted(by: { $0[0].path < $1[0].path }) where group.count >= Self.syncStreamThreshold {
                let from = RemotePath.parent(group[0].item.path), to = RemotePath.parent(group[0].destination)
                let names = group.map(\.item.name)
                if group[0].action == .upload {
                    server.transfers.uploadCompressed(names, in: from, to: to, replacing: group.contains(where: \.replaces),
                                                      preserveTimes: true)
                } else {
                    let archive = Names.unique("Synchronize.tar.gz", existing: FileList.localNames(to), caseInsensitive: true)
                    server.transfers.downloadArchive(names, in: from, to: RemotePath.join(to, archive), extract: true)
                }
                streamed.formUnion(group.map(\.item.path))
            }
        }
        for step in plan.steps where !streamed.contains(step.item.path) {
            switch step.action {
            case .upload:
                server.transfers.upload(step.item.path, to: step.destination, isFolder: step.item.isFolder,
                                        replacing: step.replaces, preserveTimes: true, excluding: patterns)
            case .download:
                server.transfers.download(step.item.path, to: step.destination, isFolder: step.item.isFolder,
                                          replacing: step.replaces, preserveTimes: true, excluding: patterns)
            case .deleteHere, .deleteThere:
                break
            }
        }
        let there = plan.steps.filter { $0.action == .deleteThere }.compactMap(\.item.entry)
        let here = plan.steps.filter { $0.action == .deleteHere }.map(\.item.path)
        guard !there.isEmpty || !here.isEmpty else { return }
        Task {
            if !there.isEmpty {
                let pane = pane(showing: server)
                await pane.perform("Deleting…", failure: "Can't delete") { try await server.delete(there) }
                await pane.reload()
            }
            if !here.isEmpty, let local = synchronizedPanes?.local {
                await local.perform("Moving to the Trash…", failure: "Can't move to the Trash") {
                    try await Task.detached(priority: .userInitiated) {
                        for path in here { try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil) }
                    }.value
                }
                await local.reload()
            }
        }
    }

    // MARK: Clipboard

    /// Copy / Cut: a server's items are kept for Paste (their paths go on the pasteboard as text); this Mac's go on
    /// the pasteboard as files, as Finder does.
    func copyToClipboard(_ items: [FileItem], from pane: FilePane, cut: Bool) {
        guard !items.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let server = pane.session {
            pasteboard.setString(items.map(\.path).joined(separator: "\n"), forType: .string)
            clipboard = Clipboard(session: server, items: items, cut: cut, changeCount: pasteboard.changeCount)
        } else {
            pasteboard.writeObjects(items.map { NSURL(fileURLWithPath: $0.path) })
            clipboard = nil
        }
    }

    private var currentClipboard: Clipboard? {
        guard let clipboard, clipboard.changeCount == NSPasteboard.general.changeCount else { return nil }
        return clipboard
    }

    /// Why Paste can't put anything into `pane` now, or nil when it can. Server items copied before go anywhere (cut
    /// ones only within their server); files copied in Finder go to a server pane.
    func pasteProblem(into pane: FilePane) -> String? {
        if let clipboard = currentClipboard {
            // Within the server: a move (sftp rename), or a copy (cp, which needs a shell).
            if pane.session?.host.id == clipboard.session.host.id {
                guard !clipboard.cut, !clipboard.session.capabilities.shell else { return nil }
                return (clipboard.session.capabilities.noShellReason ?? "This server doesn't run shell commands.")
                    + " Copying on the server needs a shell: Cut and Paste moves the items instead."
            }
            return clipboard.cut ? "Cut items move within their own server: Copy them to copy them somewhere else." : nil
        }
        guard NSPasteboard.general.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            return "Copy items first (in AirSCP, or files in Finder)."
        }
        return pane.isRemote ? nil : "Paste copies to or from a server: between folders on this Mac, use Finder."
    }

    func paste(into pane: FilePane) {
        guard let dir = pane.dir, pasteProblem(into: pane) == nil else { return }
        if let clipboard = currentClipboard {
            transfer(clipboard.items, from: .remote(clipboard.session), to: pane.source, into: dir, move: clipboard.cut)
            if clipboard.cut { self.clipboard = nil }
        } else {
            let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                as? [URL] ?? []
            upload(urls, to: pane, into: dir)
        }
    }

    // MARK: Editor, Get Info, other apps

    /// The built-in editor (one window per file) for a text file up to a few MB.
    func edit(_ item: FileItem, on server: Session, from pane: FilePane) {
        let key = server.host.id.uuidString + "\u{0}" + item.path
        if let editor = editors[key] { return editor.showWindow(nil) }
        guard item.size <= RemoteEditor.limit else {
            return workspace?.show(AirSCPError(.notText, "The file is larger than \(FileList.size(Int64(RemoteEditor.limit))): "
                                                + "open it in another app instead."), title: "Can't edit “\(item.name)”") ?? ()
        }
        Task {
            var text = ""
            let read = await pane.perform("Opening “\(item.name)”…", failure: "Can't edit “\(item.name)”") {
                text = try await server.readText(item.path, limit: RemoteEditor.limit)
            }
            guard read else { return }
            if let editor = editors[key] { return editor.showWindow(nil) }
            let editor = RemoteEditor(session: server, path: item.path, text: text, isLink: item.kind == .symlink)
            hook(editor, key: key)
            editors[key] = editor
            editor.showWindow(nil)
        }
    }

    private func hook(_ editor: RemoteEditor, key: String) {
        editor.onSaved = { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.reloadPanes(showing: RemotePath.parent(editor.path), on: editor.session)
        }
        editor.onClose = { [weak self] in self?.editors[key] = nil }
    }

    /// Open editors and files open in other apps: the workspace is kept while there are any.
    var hasOpenFiles: Bool { !editors.isEmpty || !watched.isEmpty || !opening.isEmpty }

    /// Connect made a new Session (the host was edited): the editors and the files open in other apps of the tab it
    /// replaces carry on here, with the new Session.
    func takeOpenFiles(from old: BrowserContentController) {
        for (key, editor) in old.editors {
            if editor.session.host.id == session.host.id { editor.session = session }
            hook(editor, key: key)
            editors[key] = editor
        }
        watched = old.watched.map { file in
            var file = file
            if file.session.host.id == session.host.id { file.session = session }
            return file
        }
        opening = old.opening
        old.editors = [:]
        old.watched = []
        old.opening = [:]
        old.watchTimer?.invalidate()
        if !watched.isEmpty { startWatching() }
    }

    func showInfo(_ item: FileItem, on server: Session, from pane: FilePane) {
        guard let entry = item.entry, let window = view.window else { return }
        let info = InfoModel(session: server, entry: entry)
        info.onChange = { [weak pane] in Task { await pane?.reload() } }
        presentSheet(on: window) { close in
            InfoView(model: info, close: {
                info.cancel()
                close()
            })
        }
        info.load()
    }

    /// Files bigger than this download through the transfer queue for "Open" (progress and Cancel, and the browsing
    /// goes on meanwhile); smaller ones at once.
    static let openDirectlyLimit = Int64(RemoteEditor.limit)
    /// Opens a downloaded file in its app (tests replace it).
    var openFile: (URL) -> Void = { NSWorkspace.shared.open($0) }

    /// Opens server files in their apps: each is downloaded to a temporary folder and watched; when it changes,
    /// AirSCP offers to upload it.
    func openWithDefaultApp(_ files: [FileItem], on server: Session, from pane: FilePane) {
        Task {
            var failures: [(name: String, error: Error)] = []
            for item in files {
                guard let folder = temporaryFolder() else { return }
                let file = WatchedFile(session: server, remotePath: item.path, local: folder.appendingPathComponent(item.name),
                                       modified: .distantPast)
                if item.size > Self.openDirectlyLimit {
                    opening[server.transfers.download(item.path, to: file.local.path, isFolder: false)] = file
                    continue
                }
                pane.begin("Opening “\(item.name)”…")
                do {
                    try await server.fetch(item.path, to: file.local)
                    open(file)
                } catch {
                    try? FileManager.default.removeItem(at: folder)  // nothing in it to keep
                    // A link to nothing (or to itself) can't be fetched: it isn't gone, and a refresh doesn't help.
                    var failure = error
                    if item.kind == .symlink, let error = error as? AirSCPError, error.kind == .noSuchFile {
                        failure = AirSCPError(.noSuchFile, "It is a symbolic link to something that isn't there (a broken link).",
                                              details: error.details)
                    }
                    failures.append((item.name, failure))
                }
                pane.end()
            }
            showFailures(failures, verb: "open")
        }
    }

    /// One sheet for an operation's failures, however many items failed (cancels and lost connections aren't shown).
    func showFailures(_ failures: [(name: String, error: Error)], verb: String) {
        let shown = failures.filter { ![.cancelled, .disconnected].contains(($0.error as? AirSCPError)?.kind) }
        guard let first = shown.first else { return }
        guard shown.count > 1 else { return workspace?.show(first.error, title: "Can't \(verb) “\(first.name)”") ?? () }
        let messages = shown.map { ($0.error as? AirSCPError)?.message ?? $0.error.localizedDescription }
        let lines = zip(shown, messages).map { "\($0.name): \($1)" }
        let message = Set(messages).count == 1 ? messages[0] : "Each one for its own reason (see Details)."
        workspace?.show(AirSCPError(.other, message, details: lines.joined(separator: "\n")),
                        title: "Can't \(verb) \(shown.count) items")
    }

    /// Opens a downloaded file in its app and watches it for changes.
    private func open(_ file: WatchedFile) {
        var file = file
        file.modified = modified(file.local)
        watched.removeAll { $0.session === file.session && $0.remotePath == file.remotePath }
        watched.append(file)
        openFile(file.local)
        startWatching()
    }

    private func startWatching() {
        guard watchTimer == nil || watchTimer?.isValid == false else { return }
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            Task { @MainActor in self.checkWatched() }
        }
    }

    private func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
    }

    /// Every 2 s while files are open elsewhere: one that was saved since gets an "Upload the changes?" sheet.
    private func checkWatched() {
        guard !askingToUpload, let window = view.window, window.attachedSheet == nil,
              let index = watched.firstIndex(where: { modified($0.local) > $0.modified }) else { return }
        let file = watched[index]
        watched[index].modified = modified(file.local)
        askingToUpload = true
        let alert = NSAlert()
        alert.messageText = "Upload the changes to “\(file.local.lastPathComponent)”?"
        alert.informativeText = "It was changed in another app since AirSCP downloaded it from \(file.session.host.displayName) "
            + "(\(file.remotePath))."
        alert.addButton(withTitle: "Upload").toolTip = "Upload the changed file to the server now"
        alert.addButton(withTitle: "Not Now").toolTip = "Keep the change on this Mac only, for now"
        alert.beginSheetModal(for: window) { [self] response in
            askingToUpload = false
            guard response == .alertFirstButtonReturn else { return }
            Task {
                let pane = [right!, left!].first { $0.session?.host.id == file.session.host.id } ?? right!
                let stored = await pane.perform("Uploading “\(file.local.lastPathComponent)”…",
                                                failure: "Can't upload “\(file.local.lastPathComponent)”") {
                    try await file.session.store(file.local, to: file.remotePath)
                }
                if stored { reloadPanes(showing: RemotePath.parent(file.remotePath), on: file.session) }
            }
        }
    }

    private func reloadPanes(showing dir: String, on server: Session) {
        for pane in [left!, right!] where pane.session?.host.id == server.host.id && pane.dir == dir {
            Task { await pane.reload() }
        }
    }

    // MARK: Finished transfers refresh their folder

    /// The list arrives after the fact (a quick job may be done the first time it is seen): each finished job is
    /// handled once, and again if it is retried. Its folder is listed again once its host has no transfer left (a
    /// batch of uploads lists a big folder once, not once per file), or after 10 s.
    private func jobsChanged(_ jobs: [TransferJob]) {
        guard let left, let right else { return }
        handledJobs.formIntersection(jobs.map(\.id))
        for job in jobs {
            guard job.status.isFinished else {
                handledJobs.remove(job.id)
                continue
            }
            guard handledJobs.insert(job.id).inserted else { continue }
            if let file = opening[job.id] {
                // A file to open, downloaded through the queue (a failed one may be retried).
                if job.status == .done { open(file) }
                if job.status == .done || job.status == .cancelled { opening[job.id] = nil }
                continue
            }
            switch job.status {
            case .done, .completedWithErrors: break
            default: continue
            }
            // Compressed uploads and relays name the folder they unpack into; other jobs the item itself.
            let local = job.direction == .download
            let dir = !local && !job.names.isEmpty ? job.destination : RemotePath.parent(job.destination)
            pendingReloads.append((job.hostID, local, dir, Date()))
        }
        let busy = Set(jobs.filter { !$0.status.isFinished }.map(\.hostID))
        let due = pendingReloads.filter { !busy.contains($0.hostID) || Date().timeIntervalSince($0.since) > 10 }
        guard !due.isEmpty else { return }
        pendingReloads.removeAll { !busy.contains($0.hostID) || Date().timeIntervalSince($0.since) > 10 }
        var reload: [FilePane] = []
        for item in due {
            for pane in [left, right] where pane.dir == item.dir && !reload.contains(where: { $0 === pane }) {
                if item.local ? !pane.isRemote : pane.session?.host.id == item.hostID { reload.append(pane) }
            }
        }
        for pane in reload { Task { await pane.reload() } }
    }

    // MARK: Menu bar

    /// The browser's menu commands, added by AppDelegate once the menu bar is built: file commands in File, Show
    /// Hidden Files, Calculate Folder Sizes and Refresh in View, and a Go menu. Their actions reach the focused pane
    /// through the responder chain; Cut, Copy, Paste and Find are the Edit menu's.
    static func addMenuItems(to mainMenu: NSMenu) {
        func item(_ title: String, _ action: Selector, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.toolTip = MenuHelp.tips[action]
            return item
        }
        func submenu(_ title: String, after previous: String) -> NSMenu {
            if let menu = mainMenu.item(withTitle: title)?.submenu { return menu }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            let index = mainMenu.indexOfItem(withTitle: previous)
            mainMenu.insertItem(item, at: index >= 0 ? index + 1 : mainMenu.numberOfItems)
            return item.submenu!
        }
        let backspace = String(UnicodeScalar(NSBackspaceCharacter)!)
        let up = String(UnicodeScalar(NSUpArrowFunctionKey)!), down = String(UnicodeScalar(NSDownArrowFunctionKey)!)

        let file = submenu("File", after: "AirSCP")
        let fileItems = [
            item("New Folder…", #selector(FilePane.newFolder(_:)), "N"),
            item("New File…", #selector(FilePane.newFile(_:)), "n", [.command, .option]),
            item("Open", #selector(FilePane.openItems(_:)), "o"),
            item("Edit in AirSCP", #selector(FilePane.editItem(_:))),
            item("Quick Look", #selector(FilePane.quickLook(_:)), "y"),
            item("Get Info", #selector(FilePane.getInfo(_:)), "i"),
            item("Find Files…", #selector(FilePane.findFiles(_:)), "F"),
            .separator(),
            item("Copy to Other Pane", #selector(FilePane.copyToOtherPane(_:))),
            item("Upload…", #selector(FilePane.chooseUpload(_:))),
            item("Download To…", #selector(FilePane.downloadTo(_:))),
            item("Download as .tar.gz…", #selector(FilePane.downloadArchive(_:))),
            item("Upload Compressed", #selector(FilePane.uploadCompressed(_:))),
            item("Synchronize…", #selector(FilePane.synchronize(_:))),
            .separator(),
            item("Rename…", #selector(FilePane.renameItem(_:))),
            item("Duplicate", #selector(FilePane.duplicateItems(_:)), "d"),
            item("Compress…", #selector(FilePane.compressItems(_:))),
            item("Extract Here", #selector(FilePane.extractHere(_:))),
            item("Extract to New Folder", #selector(FilePane.extractToFolder(_:))),
            item("Permissions…", #selector(FilePane.editPermissions(_:))),
            item("Make Executable", #selector(FilePane.makeExecutable(_:))),
            item("Run…", #selector(FilePane.runItem(_:))),
            .separator(),
            item("Copy Path", #selector(FilePane.copyPath(_:)), "c", [.command, .option]),
            item("Open Terminal Here", #selector(FilePane.openTerminalHere(_:)), "t", [.command, .option]),
            item("Show in Finder", #selector(FilePane.revealInFinder(_:))),
            .separator(),
            item("Delete…", #selector(FilePane.deleteItems(_:)), backspace),
        ]
        // Before Close (and the separator above it), else at the end.
        var index = file.items.firstIndex { $0.action == #selector(NSWindow.performClose(_:)) } ?? file.numberOfItems
        if index > 0 && file.items[index - 1].isSeparatorItem { index -= 1 }
        for entry in [NSMenuItem.separator()] + fileItems {
            file.insertItem(entry, at: index)
            index += 1
        }

        let view = submenu("View", after: "Edit")
        view.addItem(.separator())
        view.addItem(item("Show Hidden Files", #selector(FilePane.toggleHiddenFiles(_:)), ".", [.command, .shift]))
        view.addItem(item("Calculate Folder Sizes", #selector(FilePane.calculateFolderSizes(_:))))
        view.addItem(item("Refresh", #selector(FilePane.refresh(_:)), "r"))
        // The header's right-click menu, for the keyboard (and agents): the focused pane's columns.
        let columns = NSMenuItem(title: "Columns", action: nil, keyEquivalent: "")
        columns.toolTip = MenuHelp.submenus["Columns"]
        columns.submenu = NSMenu(title: "Columns")
        for column in FilePane.columns where column.id != "name" {
            let entry = item(column.title, #selector(FilePane.toggleColumnNamed(_:)))
            entry.representedObject = column.id
            columns.submenu?.addItem(entry)
        }
        view.addItem(columns)

        let go = submenu("Go", after: "View")
        // A server's favourite folders (PLAN.md S.2): the focused pane fills the submenu (`FilePane.fillFavourites`).
        let favourites = NSMenuItem(title: "Favourites", action: nil, keyEquivalent: "")
        favourites.toolTip = MenuHelp.submenus["Favourites"]
        favourites.submenu = NSMenu(title: "Favourites")
        for entry in [
            item("Back", #selector(FilePane.goBack(_:)), "["),
            item("Forward", #selector(FilePane.goForward(_:)), "]"),
            item("Enclosing Folder", #selector(FilePane.goUp(_:)), up),
            item("Open Selection", #selector(FilePane.openItems(_:)), down),
            .separator(),
            item("Home", #selector(FilePane.goHome(_:)), "H"),
            item("Go to Folder…", #selector(FilePane.goToFolder(_:)), "G"),
            .separator(),
            item("Add to Favourites", #selector(FilePane.addToFavourites(_:))),
            favourites,
        ] { go.addItem(entry) }
    }
}
