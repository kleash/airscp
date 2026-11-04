import AirSCPCore
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// This device's own files (the Files tab's "On iPhone" side): the app's Documents folder, which the Files app shows too
/// (On My iPhone ▸ AirSCP). A throwaway instance (AIRSCP_SUPPORT_DIR, as the tests run it) has its own.
let deviceFolder: String = {
    let url = Keychain.memoryOnly ? Store.directory.appendingPathComponent("Documents") : URL.documentsDirectory
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}()

@MainActor let deviceName = UIDevice.current.userInterfaceIdiom == .pad ? "On iPad" : "On iPhone"

/// The Files tab: two sides, each an open server's folders or this device's own files, one at a time with a switcher, or
/// side by side where there is room. Send copies to the other side through the servers' transfer queues, as the Mac's
/// panes do; New Folder, Rename and Delete run at once.
struct FilesView: View {
    @Environment(AppState.self) private var app
    @Environment(\.horizontalSizeClass) private var width
    @Environment(\.wide) private var wide
    /// Kept by the view that shows the sides (RootView for the Files tab, a server's workspace), so that a change of
    /// layout keeps the folders and the selection.
    @Bindable var model: FilesModel
    let goToServers: () -> Void
    @State private var editorFullWindow = false
    /// A wide window shows the editor in a column, in the second side's place, not in a sheet. State, not the
    /// environment's value: when a turn of the iPad dismisses the sheet, its binding reads this as it is now.
    @State private var editorInColumn = false

    private var editorColumn: EditedFile? { editorInColumn ? model.editing : nil }

    var body: some View {
        Group {
            if app.open.isEmpty {
                NothingOpen(title: "No server open", systemImage: "folder",
                            description: "Open a server in Servers to browse its files.", goToServers: goToServers)
            } else {
                // Each side in a place of its own: the one shown keeps its scroll position when the window narrows to
                // one side with a switcher, or widens again.
                HStack(spacing: 0) {
                    if width == .regular || model.shown == 0 { side(0) }
                    if width == .regular { Divider() }
                    if let file = editorColumn, !editorFullWindow {  // one view for the editor at a time
                        NavigationStack {
                            editor(file).toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button("Full Window", systemImage: "arrow.up.left.and.arrow.down.right") { editorFullWindow = true }
                                        .keyboardShortcut("f", modifiers: [.command, .shift])
                                        .help("Give the editor the whole window (⌘⇧F)")
                                }
                            }
                        }
                    } else if width == .regular || model.shown == 1 {
                        side(1)
                    }
                }
            }
        }
        .onReceive(TransferCenter.shared.$jobs) { model.jobsChanged($0) }
        .alert(model.failure?.title ?? "", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } }),
               presenting: model.failure) { _ in
            Button("OK") {}
        } message: { failure in
            Text(failure.message)
        }
        // Names that are there already, for Send and Import: one answer for them all.
        .alert(model.question?.title ?? "", isPresented: Binding(get: { model.question != nil }, set: { shown in
            // After a button's own answer, which wins.
            if !shown { DispatchQueue.main.async { model.answer(nil) } }
        }), presenting: model.question) { question in
            Button("Replace", role: .destructive) { model.answer(.replace) }
                .help("Put the new items in place of the ones there")
            if question.keepBoth {
                Button("Keep Both") { model.answer(.keepBoth) }
                    .help("Keep both: the new ones get a number")
            }
            Button("Skip") { model.answer(.skip) }
                .help("Leave the ones there as they are; don't copy those items")
            Button("Cancel", role: .cancel) { model.answer(nil) }
                .help("Stop: copy nothing")
        } message: { question in
            Text(question.keepBoth ? "Replace, keep both (the new ones get a number), or skip?" : "Replace, or skip?")
        }
        // A sheet unless a column or the whole window shows it.
        .sheet(item: Binding(get: { !editorInColumn && !editorFullWindow ? model.editing : nil },
                             set: { if !editorInColumn && !editorFullWindow { model.editing = $0 } })) { file in
            NavigationStack { editor(file) }
        }
        .fullWindow(Binding(get: { editorFullWindow && model.editing != nil }, set: { editorFullWindow = $0 })) {
            if let file = model.editing { editor(file) }
        }
        .onChange(of: wide && width == .regular, initial: true) { _, column in editorInColumn = column }
    }

    private func side(_ index: Int) -> some View {
        // iOS 27 gives a NavigationStack's content the window's safe area even on edges the stack doesn't reach (the
        // iPhone Duo's rail on the right), so the side's list stopped that far short of the divider: those edges get none.
        GeometryReader { outside in
            NavigationStack {
                SideView(model: model, index: index, switcher: width != .regular)
                    .ignoresSafeArea(.container, edges: [outside.safeAreaInsets.leading == 0 ? .leading : [],
                                                         outside.safeAreaInsets.trailing == 0 ? .trailing : []])
            }
        }
    }

    private func editor(_ file: EditedFile) -> some View {
        EditorView(file: file) {
            model.reload(file.session.host.id, RemotePath.parent(file.entry.path))
        } close: {
            editorFullWindow = false
            model.editing = nil
        }
    }
}

/// The Files tab's sides and what they share: the questions and failures they show, and work waiting for transfers.
@MainActor @Observable final class FilesModel {
    var sides: [FileSide]
    /// The side shown on a narrow screen.
    var shown = 0
    var showHidden = false
    /// The side the keyboard's shortcuts work on while both show: the one last used (a folder opened, rows selected, a
    /// drop).
    var active = 0
    /// Items copied with ⌘C, for ⌘V (AirSCP's own: other apps never see a server's paths).
    var copied: (session: Session?, entries: [RemoteEntry])?
    /// The rows being dragged in AirSCP, and where from (one drag at a time; for every window, as a drag can end in another).
    static var dragged: (side: FileSide, session: Session?, entries: [RemoteEntry])?
    var failure: (title: String, message: String)?
    var question: Question?
    var editing: EditedFile?
    /// Work waiting for transfers to finish (Share's downloads, Import's uploads), with the jobs it waits for.
    private var waiting: [(jobs: Set<UUID>, then: ([TransferJob]) -> Void)] = []
    private var finished: Set<UUID> = []
    /// Folders that finished transfers put items into: listed again once their host has no transfer left (a batch of
    /// uploads lists a big folder once, not once per file).
    private var landed: [(hostID: UUID, download: Bool, dir: String)] = []

    enum Choice { case replace, keepBoth, skip }

    struct Question {
        let title: String
        /// The copy can give the new items other names (not between two servers: the stream keeps them).
        let keepBoth: Bool
        let reply: (Choice?) -> Void
    }

    /// `server`: a server's workspace, whose first side shows that server; else the newest open one.
    init(server: UUID? = nil) {
        sides = [FileSide(source: server.map(FileSide.Source.server)), FileSide(source: .device)]
    }

    func fail(_ title: String, _ error: Error) {
        failure = (title, (error as? AirSCPError)?.message ?? error.localizedDescription)
    }

    func answer(_ choice: Choice?) {
        guard let question else { return }
        self.question = nil
        question.reply(choice)
    }

    /// Search's or the terminal's item: on the side that shows its server (else the one shown), in its folder, then once
    /// that is listed the item selected, or edited at its line (`SideView.reveal`). A hidden file shows hidden files.
    func show(_ reveal: AppState.Reveal, _ app: AppState) {
        let source = FileSide.Source.server(reveal.hostID)
        shown = sides.firstIndex { $0.current(app) == source } ?? shown
        let side = sides[shown]
        side.source = source
        side.folders[source] = reveal.isFolder ? reveal.path : RemotePath.parent(reveal.path)
        side.revealing = reveal.isFolder ? nil : reveal
        if !reveal.isFolder && RemotePath.name(reveal.path).hasPrefix(".") { showHidden = true }
        side.generation += 1  // listed again, also when it shows that folder already
    }

    /// Lists the folder again on the sides that show it (nil: on this device).
    func reload(_ hostID: UUID?, _ dir: String) {
        let source = hostID.map(FileSide.Source.server) ?? .device
        for side in sides where side.listed == FileSide.Location(source: source, dir: dir) { side.generation += 1 }
    }

    /// Runs `then` with the jobs once they are all finished (or gone from the list).
    func whenDone(_ jobs: [UUID], then: @escaping ([TransferJob]) -> Void) {
        guard !jobs.isEmpty else { return then([]) }
        waiting.append((Set(jobs), then))
    }

    func jobsChanged(_ jobs: [TransferJob]) {
        let byID = Dictionary(jobs.map { ($0.id, $0) }) { first, _ in first }
        for (index, wait) in waiting.enumerated().reversed() where wait.jobs.allSatisfy({ byID[$0]?.status.isFinished ?? true }) {
            waiting.remove(at: index)
            wait.then(wait.jobs.compactMap { byID[$0] })
        }
        // Each finished job once (a retried one again when it finishes again).
        let done = Set(jobs.filter(\.status.isFinished).map(\.id))
        for job in jobs where done.contains(job.id) && !finished.contains(job.id) {
            switch job.status {
            case .done, .completedWithErrors: break
            default: continue
            }
            // Relays name the folder they copy into; the others the item itself.
            let download = job.direction == .download
            let dir = !download && !job.names.isEmpty ? job.destination : RemotePath.parent(job.destination)
            landed.append((job.hostID, download, dir))
        }
        finished = done
        let busy = Set(jobs.filter(\.status.isActive).map(\.hostID))
        for place in landed where !busy.contains(place.hostID) { reload(place.download ? nil : place.hostID, place.dir) }
        landed.removeAll { !busy.contains($0.hostID) }
    }

    /// Asks once about the names that are there already; nil: cancelled.
    private func ask(_ names: [String], in place: String, keepBoth: Bool) async -> Choice? {
        await withCheckedContinuation { continuation in
            let what = names.count == 1 ? "“\(names[0])” already exists" : "\(names.count) items already exist"
            question = Question(title: "\(what) in \(place).", keepBoth: keepBoth) { continuation.resume(returning: $0) }
        }
    }

    /// Copies `entries` from `source` (nil: this device) into `dir` on `target` (nil: this device), as the Mac's panes
    /// do: asks first about the names there, then queues a transfer for each item (one for all between two servers); a
    /// copy within one server runs at once (cp), and so does a `move` there (rows dropped onto a folder of their path).
    /// Returns the queued jobs.
    @discardableResult
    func copy(_ entries: [RemoteEntry], from source: Session?, to target: Session?, into dir: String, move: Bool = false) async -> [UUID] {
        guard !entries.isEmpty else { return [] }
        let verb = move ? "move" : "copy"
        let place = "“\(target == nil && dir == deviceFolder ? deviceName : RemotePath.name(dir))”"
        let sameServer = source != nil && source?.host.id == target?.host.id
        if sameServer, let looped = entries.first(where: { dir == $0.path || dir.hasPrefix($0.path + "/") }) {
            fail("Can't \(verb)", AirSCPError(.other, "“\(looped.name)” can't go into itself."))
            return []
        }
        // Listed now: the other side's rows may be older than what is there (an item made since would be replaced unasked).
        let existing: [RemoteEntry]
        do {
            existing = try await target?.list(dir) ?? FileSide.localEntries(dir)
        } catch {
            fail("Can't \(verb) to \(place)", error)
            return []
        }
        let ignoreCase = target?.capabilities.caseInsensitive ?? TransferQueue.ignoresCase(dir)
        func there(_ name: String) -> RemoteEntry? {
            Names.existing(name, in: existing.map(\.name), caseInsensitive: ignoreCase).flatMap { old in existing.first { $0.name == old } }
        }
        let relay = source != nil && target != nil && !sameServer
        var choice = Choice.replace
        let conflicts = entries.filter { there($0.name) != nil }.map(\.name)
        if sameServer && RemotePath.parent(entries[0].path) == dir {
            choice = .keepBoth  // into their own folder: copies, like Duplicate
        } else if !conflicts.isEmpty {
            guard let answer = await ask(conflicts, in: place, keepBoth: !relay) else { return [] }
            choice = answer
        }
        var taken = existing.map(\.name)
        var planned: [(entry: RemoteEntry, name: String, replaces: RemoteEntry?)] = []
        for entry in entries {
            guard let old = there(entry.name) else {
                planned.append((entry, entry.name, nil))
                continue
            }
            switch choice {
            case .skip: continue
            case .replace: planned.append((entry, entry.name, old))
            case .keepBoth:
                let name = Names.unique(entry.name, existing: taken, caseInsensitive: ignoreCase)
                taken.append(name)
                planned.append((entry, name, nil))
            }
        }
        guard !planned.isEmpty else { return [] }
        switch (source, target) {
        case (nil, let server?):
            // Replaced items of another kind (a file over a folder), or under another spelling of the name, go first:
            // the copy would go into the old folder, or next to the old name.
            let stale = planned.compactMap { step in
                step.replaces.flatMap { old in old.name != step.name || (old.kind == .directory) != (step.entry.kind == .directory) ? old : nil }
            }
            if !stale.isEmpty {
                do {
                    try await server.delete(stale)
                } catch {
                    fail("Can't replace the old items", error)
                    return []
                }
            }
            return planned.map { step in
                server.transfers.upload(step.entry.path, to: RemotePath.join(dir, step.name), isFolder: step.entry.kind == .directory,
                                        replacing: step.replaces != nil)
            }
        case (let server?, nil):
            return planned.map { step in
                server.transfers.download(step.entry.path, to: RemotePath.join(dir, step.name), isFolder: step.entry.kind != .file,
                                          replacing: step.replaces != nil)
            }
        case (let from?, let to?) where !sameServer:
            return [to.transfers.relay(planned.map(\.entry.name), in: RemotePath.parent(planned[0].entry.path), from: from, to: dir,
                                       replacing: planned.contains { $0.replaces != nil })]
        case (_, let server?):
            do {
                for step in planned {
                    let path = RemotePath.join(dir, step.name)
                    if let old = step.replaces, old.name == step.name {
                        // The old item stays until the new one is complete.
                        try await server.copy(step.entry.path, replacing: path, folder: step.entry.kind == .directory || old.kind == .directory,
                                              move: move)
                    } else {
                        if let old = step.replaces { try await server.delete([old]) }  // another spelling: it goes first
                        if move {
                            try await server.move(step.entry.path, to: path)
                        } else {
                            try await server.copy(step.entry.path, to: path)
                        }
                    }
                }
            } catch {
                fail("Can't \(verb)", error)
            }
            reload(server.host.id, dir)
            if move { reload(server.host.id, RemotePath.parent(entries[0].path)) }
            return []
        case (nil, nil):
            return []
        }
    }

    /// Downloads server files into a new temporary folder through the transfer queue, then hands them to `then`
    /// (Share, Save to Files, a drag to another app); nil, once it has said why, when one fails or is cancelled.
    func download(_ entries: [RemoteEntry], from session: Session, then: @escaping ([URL]?) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Downloads-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            fail("Can't download", error)
            return then(nil)
        }
        let urls = entries.map { folder.appendingPathComponent($0.name) }
        let jobs = zip(entries, urls).map { entry, url in session.transfers.download(entry.path, to: url.path, isFolder: false) }
        whenDone(jobs) { [self] finished in
            for job in finished {
                if case .failed(let error) = job.status {
                    fail("Can't download “\(job.name)”", error)
                    return then(nil)
                }
                if job.status != .done { return then(nil) }  // cancelled
            }
            then(urls)
        }
    }
}

/// One side of the Files tab: an open server's folders, or this device's own files.
@MainActor @Observable final class FileSide {
    enum Source: Hashable { case server(UUID), device }

    struct Location: Equatable {
        let source: Source
        let dir: String
    }

    /// What the side shows; nil: the newest open server.
    var source: Source?
    /// Each source's folder, kept while the side shows another (none yet: a server's home, this device's own folder).
    var folders: [Source: String] = [:]
    /// The folder's entries, folders first.
    private(set) var items: [RemoteEntry] = []
    private(set) var error: AirSCPError?
    /// What `items` (or `error`) are of.
    private(set) var listed: Location?
    /// Changed to list the folder again.
    var generation = 0
    /// Select mode, and the items selected (paths): kept when the layout changes (rotating, the Duo folding).
    var selecting = false
    var selection = Set<String>()
    /// A file to select (or edit) once its folder is listed (`FilesModel.show`).
    var revealing: AppState.Reveal?

    init(source: Source? = nil) {
        self.source = source
    }

    /// The source shown now: a server closed since gives way to the newest open one.
    func current(_ app: AppState) -> Source {
        if source == .device { return .device }
        if case .server(let id)? = source, app.session(for: id) != nil { return .server(id) }
        return app.open.last.map { .server($0.host.id) } ?? .device
    }

    /// The server shown; nil for this device.
    func session(_ app: AppState) -> Session? {
        guard case .server(let id) = current(app) else { return nil }
        return app.session(for: id)
    }

    /// The folder shown: as chosen, else a server's home once it is connected (nil before), or this device's own.
    func dir(_ app: AppState) -> String? {
        let source = current(app)
        if let dir = folders[source] { return dir }
        guard let session = session(app) else { return deviceFolder }
        return app.states[session.host.id] == .connected ? session.capabilities.home : nil
    }

    func name(_ app: AppState) -> String {
        guard let session = session(app) else { return deviceName }
        return app.data.hosts.first { $0.id == session.host.id }?.displayName ?? session.host.displayName
    }

    func load(_ session: Session?, _ location: Location) async {
        do {
            var entries = try await session?.list(location.dir) ?? Self.localEntries(location.dir)
            guard !Task.isCancelled else { return }
            entries.sort { a, b in
                (a.kind == .directory) != (b.kind == .directory) ? a.kind == .directory : a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
            (items, error, listed) = (entries, nil, location)
        } catch {
            let error = error as? AirSCPError ?? AirSCPError(.other, error.localizedDescription)
            guard !Task.isCancelled, error.kind != .cancelled else { return }
            (items, self.error, listed) = ([], error, location)
        }
    }

    /// A folder on this device, as a server's listing reads.
    nonisolated static func localEntries(_ dir: String) throws -> [RemoteEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        return try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: Array(keys))
            .map(localEntry)
    }

    nonisolated static func localEntry(_ url: URL) -> RemoteEntry {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
        return RemoteEntry(name: url.lastPathComponent, path: url.path, kind: values?.isDirectory == true ? .directory : .file,
                           size: Int64(values?.fileSize ?? 0), modified: values?.contentModificationDate)
    }
}

/// One side: the folder's path, its list with swipe actions and context menus, and in Select mode a bar of actions. It
/// fits any width, in a navigation stack of its container's.
struct SideView: View {
    @Environment(AppState.self) private var app
    @Bindable var model: FilesModel
    let index: Int
    /// The two sides share the screen: a switcher at the top shows one or the other.
    let switcher: Bool
    @State private var naming: Naming?
    @State private var name = ""
    @State private var deleting: [RemoteEntry] = []
    @State private var importing = false
    @State private var preview: URL?
    /// The file being read for the editor.
    @State private var opening: String?
    /// A revealed file's row, to scroll to.
    @State private var scrolledTo: String?
    /// What a drag is over: a row or a folder of the path bar (its path), or this side's empty folder (the folder's path).
    /// A folder lights up; over a file row or the empty folder, the whole side does (the drop goes into the folder shown).
    @State private var dropTarget: String?
    /// The server whose Monitor screen shows.
    @State private var monitoring: UUID?

    private enum Naming {
        case newFolder, rename(RemoteEntry)
    }

    private var side: FileSide { model.sides[index] }
    private var other: FileSide { model.sides[1 - index] }
    private var session: Session? { side.session(app) }
    private var dir: String? { side.dir(app) }
    private var location: FileSide.Location? { dir.map { FileSide.Location(source: side.current(app), dir: $0) } }
    private var visible: [RemoteEntry] { side.listed == location ? side.items.filter { model.showHidden || !$0.isHidden } : [] }
    private var selected: [RemoteEntry] { visible.filter { side.selection.contains($0.path) } }
    private var editing: Bool { side.selecting }

    var body: some View {
        ScrollViewReader { proxy in
            List(selection: Binding(get: { side.selection }, set: {
                side.selection = $0
                model.active = index
            })) {
                ForEach(visible) { entry in
                    row(entry)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) { actions(entry, all: false) }
                        .contextMenu { actions(entry, all: true) }
                        .onDrag { dragItem(entry) }
                        // Each row takes drops from elsewhere (the list's own drop handling refuses them): a folder into
                        // itself, a file into the folder shown. The list keeps its own rows' drags to itself, so a row
                        // can't be dropped onto a folder row of the same side: the path bar's folders take those.
                        .onDrop(of: [.item], delegate: drop(into: entry.kind == .directory ? entry.path : dir, over: entry.path))
                        .listRowBackground(dropTarget == entry.path && entry.kind == .directory ? Color.teal.opacity(0.25) : nil)
                }
            }
            .onChange(of: scrolledTo) {
                guard let scrolledTo else { return }
                proxy.scrollTo(scrolledTo, anchor: .center)
                self.scrolledTo = nil  // the same file shown again scrolls again
            }
        }
        .overlay { placeholder.onDrop(of: [.item], delegate: drop(into: dir, over: dir ?? "")) }
        .overlay {
            if let dropTarget, dropTarget == dir || visible.contains(where: { $0.path == dropTarget && $0.kind != .directory }) {
                RoundedRectangle(cornerRadius: 12).strokeBorder(Color.teal, lineWidth: 3).padding(4).allowsHitTesting(false)
            }
        }
        .background { shortcuts.hidden() }
        .refreshable { if let location { await side.load(session, location) } }
        .environment(\.editMode, Binding(get: { side.selecting ? .active : .inactive }, set: { side.selecting = $0.isEditing }))
        .navigationTitle(side.name(app))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        // A narrow screen's bottom bar takes the tab bar's place while selecting.
        .toolbar(editing && switcher ? .hidden : .visible, for: .tabBar)
        .safeAreaBar(edge: .top) {
            if let dir {
                HStack(spacing: 0) {
                    if session != nil && app.open.count > 1 { serverMenu }
                    PathBar(crumbs: crumbs(dir), targeted: dropTarget) { side.folders[side.current(app)] = $0 } drop: { drop(into: $0, over: $0) }
                }
            }
        }
        .task(id: "\(String(describing: location))|\(side.generation)") {
            if let location { await side.load(session, location) }
            if let revealing = side.revealing, side.listed == location { reveal(revealing) }
        }
        .onChange(of: dir) {
            side.selection = []
            model.active = index  // a folder opened here: the keyboard works here now
        }
        // `presenting`: the buttons get what was asked about, even once dismissing the alert has reset it.
        .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } }), presenting: naming) { naming in
            TextField("Name", text: $name)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button(namingButton) { commit(naming) }
            Button("Cancel", role: .cancel) {}
        }
        .alert(deleteTitle, isPresented: Binding(get: { !deleting.isEmpty }, set: { if !$0 { deleting = [] } }),
               presenting: deleting) { entries in
            Button("Delete", role: .destructive) { delete(entries) }
            Button("Cancel", role: .cancel) {}
        } message: { entries in
            Text(entries.contains { $0.kind == .directory } ? "Folders are deleted with everything in them. This can't be undone."
                 : "This can't be undone.")
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): if let dir { importFiles(urls, into: dir) }
            case .failure(let error): model.fail("Can't import", error)
            }
        }
        .quickLookPreview($preview)
        .navigationDestination(item: $monitoring) { MonitorView(hostID: $0) }
    }

    /// The open server this side shows, to choose another, while more than one is open (More ▸ Show does it too).
    private var serverMenu: some View {
        Menu {
            Picker("Server", selection: Binding(get: { side.current(app) }, set: { side.source = $0 })) {
                ForEach(app.open, id: \.host.id) { session in
                    Text(app.data.hosts.first { $0.id == session.host.id }?.displayName ?? session.host.displayName)
                        .tag(FileSide.Source.server(session.host.id))
                }
            }
        } label: {
            HStack(spacing: 2) {
                Text(side.name(app)).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.leading)
        .accessibilityIdentifier("server")
        .help("Choose which open server this side shows")
    }

    // MARK: Rows

    @ViewBuilder private func row(_ entry: RemoteEntry) -> some View {
        let tint = session?.s3 == nil ? Color.teal : .orange  // the mockups: teal servers, amber S3
        if editing {
            FileRow(entry: entry, busy: false, tint: tint)
        } else {
            Button { open(entry) } label: { FileRow(entry: entry, busy: opening == entry.path, tint: tint) }
                .help(entry.kind == .directory ? "Open this folder" : session == nil ? "Preview this file" : "Edit this file")
        }
    }

    /// A row's swipe actions (Send, Rename, Delete) and its context menu (`all`: also Edit, Share and Save to Files).
    @ViewBuilder private func actions(_ entry: RemoteEntry, all: Bool) -> some View {
        if all && session != nil && entry.kind != .directory {
            Button("Edit", systemImage: "pencil.line") { edit(entry) }
                .help("Edit this text file")
        }
        Button(sendWords.title, systemImage: sendWords.image) { send([entry]) }
            .tint(.teal)
            .disabled(sendProblem != nil)
            .help(sendProblem ?? "Copy to the other side (\(other.name(app)))")
        Button("Rename", systemImage: "character.cursor.ibeam") { ask(.rename(entry), name: entry.name) }
            .tint(.gray)
            .help("Change this item's name")
        // A server's file is shared once downloaded; this device's files and folders also go to the Files app from here
        // (a server's are downloaded here first, not straight to the Files app).
        if all && (session == nil || entry.kind != .directory) {
            Button("Share", systemImage: "square.and.arrow.up") { share([entry], export: false) }
                .help("Send this item with another app, such as Mail or Messages")
        }
        if all && session == nil {
            Button("Save to Files", systemImage: "folder") { share([entry], export: true) }
                .help("Save a copy of this item in the Files app, outside AirSCP")
        }
        Button("Delete", systemImage: "trash", role: .destructive) { deleting = [entry] }
            .tint(.red)  // the app's teal tint would colour a swipe button's red too
            .help("Delete this item")
    }

    /// Send's name: from a server to this device it downloads, the other way it uploads, between two servers it sends.
    private var sendWords: (title: String, image: String) {
        switch (session == nil, other.session(app) == nil) {
        case (false, true): ("Download", "arrow.down.circle")
        case (true, false): ("Upload", "arrow.up.circle")
        default: ("Send", "paperplane")
        }
    }

    /// Why Send can't copy to the other side now; nil when it can.
    private var sendProblem: String? {
        if session == nil && other.session(app) == nil {
            return "Both sides show this device: show a server on the other side to send to it"
        }
        if other.dir(app) == nil { return "The other side's server isn't connected yet" }
        return nil
    }

    /// The text over the list when it has no rows: connecting, listing, why a folder can't be shown, an empty folder.
    @ViewBuilder private var placeholder: some View {
        if let session, dir == nil {
            switch app.states[session.host.id] ?? .idle {
            case .connecting, .reconnecting:
                ProgressView("Connecting…")
            default:
                ContentUnavailableView {
                    Label("Not connected", systemImage: "bolt.horizontal.circle")
                } description: {
                    Text("Connect to \(side.name(app)) again to see its files.")
                } actions: {
                    Button("Connect") { app.connect(app.data.hosts.first { $0.id == session.host.id } ?? session.host) }
                        .help("Connect to this server again")
                }
            }
        } else if side.listed != location {
            ProgressView()
        } else if let error = side.error {
            ContentUnavailableView {
                Label("Can't show “\(RemotePath.name(dir ?? ""))”", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error.message)
            } actions: {
                Button("Try Again") { side.generation += 1 }
                    .help("List this folder again")
            }
        } else if visible.isEmpty {
            ContentUnavailableView {
                Label(side.items.isEmpty ? "Empty folder" : "Only hidden files", systemImage: "folder")
            } description: {
                Text(side.items.isEmpty ? (session == nil
                        ? "Send files here from a server, or add them in the Files app (On My \(UIDevice.current.model) ▸ AirSCP)."
                        : "Send files here from the other side, or import them from the Files app.")
                     : "Show Hidden Files in the menu shows them.")
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if switcher {
            ToolbarItem(placement: .principal) {
                Picker("Side", selection: $model.shown) {
                    Text(model.sides[0].name(app)).tag(0)
                    Text(model.sides[1].name(app)).tag(1)
                }
                .pickerStyle(.segmented)
                // Its own width, up to what a phone's bar has room for next to its buttons: sized by the bar, it kept
                // the width the bar had while the Duo folded, and cut “On iPhone” short.
                .frame(maxWidth: 200)
                .fixedSize()
                .help("Switch between the two sides: Send copies to the side not shown")
            }
        } else if session == nil {
            // This device's side next to the other: its path starts with its name ("On iPhone"), which a title said
            // again where the bar had room for one (an iPad, the Duo open on its side). A hidden title, not none: with
            // no title the bar went, and on the Duo the buttons it had put in the rail.
            ToolbarItem(placement: .principal) { Text(side.name(app)).hidden() }
        }
        if editing {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done", action: stopSelecting)
                    .help("Stop selecting")
            }
            ToolbarItemGroup(placement: .bottomBar) { selectionBar }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if !app.tray.items.isEmpty {
                    // The tray sends to the folder each server shows here (this side's first).
                    TrayButton(folders: Dictionary([side, other].compactMap { side in
                        side.session(app).flatMap { session in side.dir(app).map { (session.host.id, $0) } }
                    }) { first, _ in first })
                }
                Button("New Folder", systemImage: "folder.badge.plus", action: newFolder)
                    .disabled(dir == nil)
                    .help(dir == nil ? "Connect to the server first" : "Make a folder here")
                Menu("More", systemImage: "ellipsis") {
                    Button("Select", systemImage: "checkmark.circle") {
                        side.selecting = true
                        model.active = index
                    }
                    .help("Select items to send, share or delete together")
                    Picker(selection: Binding(get: { side.current(app) }, set: { side.source = $0 })) {
                        ForEach(app.open, id: \.host.id) { session in
                            Text(app.data.hosts.first { $0.id == session.host.id }?.displayName ?? session.host.displayName)
                                .tag(FileSide.Source.server(session.host.id))
                        }
                        Text(deviceName).tag(FileSide.Source.device)
                    } label: {
                        Label("Show", systemImage: "rectangle.2.swap")
                    }
                    .pickerStyle(.menu)
                    .help("Choose what this side shows: an open server, or the files on this device")
                    Button("Import from Files", systemImage: "square.and.arrow.down") { importing = true }
                        .disabled(dir == nil)
                        .help(session == nil ? "Copy files from the Files app here" : "Upload files from the Files app into this folder")
                    Toggle("Show Hidden Files", systemImage: "eye", isOn: $model.showHidden)
                        .help("Show the files and folders whose names start with a dot")
                    if let session, session.s3 == nil {
                        Button("Monitor", systemImage: "gauge.with.dots.needle.33percent") { monitoring = session.host.id }
                            .help("Show this server's CPU, memory, disks and processes")
                    }
                }
                .help("Select, choose what this side shows, import, hidden files")
            }
        }
    }

    @ViewBuilder private var selectionBar: some View {
        let files = !selected.isEmpty && selected.allSatisfy { $0.kind != .directory }
        // S3 storage's items are zipped with this device's ditto, which iOS doesn't let an app run.
        let zipProblem = session?.s3 != nil ? "Zip works on a server's files, not on S3 storage"
            : session.map { $0.compressUnavailableReason(.zip) } ?? "Zip works on a server's files"
        Button(sendWords.title, systemImage: sendWords.image) { send(selected) }
            .disabled(selected.isEmpty || sendProblem != nil)
            .help(sendProblem ?? "Copy the selected items to the other side (\(other.name(app)))")
        Spacer()
        Button("Add to Tray", systemImage: "tray.and.arrow.down") {
            let host = session?.host.id
            app.tray.add(selected.map { Tray.Item(hostID: host, path: $0.path, isFolder: $0.kind == .directory) })
            stopSelecting()
        }
        .disabled(selected.isEmpty)
        .help("Put the selected items in the tray, to take them to another place together")
        Spacer()
        // This device's folders too; a server's files only (each is downloaded first).
        let shareable = !selected.isEmpty && (session == nil || files)
        Button("Share", systemImage: "square.and.arrow.up") { share(selected, export: false) }
            .disabled(!shareable)
            .help(shareable ? "Send the selected items with another app, or save them in the Files app"
                            : "Select files to share them (not a server's folders)")
        Spacer()
        Button("Zip", systemImage: "doc.zipper") { zip(selected) }
            .disabled(selected.isEmpty || zipProblem != nil)
            .help(zipProblem ?? "Pack the selected items into a .zip in this folder")
        Spacer()
        Button("Delete", systemImage: "trash", role: .destructive) { deleting = selected }
            .disabled(selected.isEmpty)
            .help("Delete the selected items")
    }

    // MARK: Keyboard

    /// The keyboard's shortcuts (listed while ⌘ is held), on the side shown, or last used where both show. Not while
    /// the editor or a name is being typed: those keys are the text's then (a sheet's keys fall through to its presenter).
    @ViewBuilder private var shortcuts: some View {
        if (switcher || model.active == index) && model.editing == nil && naming == nil {
            Button("Refresh") { side.generation += 1 }
                .keyboardShortcut("r")
                .help("List the folder again")
            Button("New Folder", action: newFolder)
                .keyboardShortcut("n")
                .disabled(dir == nil)
                .help("Make a folder here")
            Button("Delete") { deleting = selected }
                .keyboardShortcut(.delete)
                .disabled(selected.isEmpty)
                .help("Delete the selected items (asks first)")
            Button("Select All") { side.selection = Set(visible.map(\.path)) }
                .keyboardShortcut("a")
                .disabled(!editing)
                .help("Select everything in this folder")
            Button("Open", action: openSelected)
                .keyboardShortcut(.return, modifiers: [])
                .disabled(selected.count != 1)
                .help("Open the selected folder or file")
            Button("Open Selection", action: openSelected)  // ⌘↓, as on the Mac
                .keyboardShortcut(.downArrow)
                .disabled(selected.count != 1)
                .help("Open the selected folder or file")
            Button("Enclosing Folder") { if let up { side.folders[side.current(app)] = up } }
                .keyboardShortcut(.upArrow)
                .disabled(up == nil)
                .help("Go up one folder")
            Button("Copy") { model.copied = (session, selected) }
                .keyboardShortcut("c")
                .disabled(selected.isEmpty)
                .help("Copy the selected items, to paste them on the other side")
            Button("Paste", action: paste)
                .keyboardShortcut("v")
                .disabled(!canPaste)
                .help("Copy the items copied with ⌘C into this folder")
        }
    }

    /// Opens the one item selected, out of Select.
    private func openSelected() {
        guard selected.count == 1 else { return }
        let entry = selected[0]
        stopSelecting()
        open(entry)
    }

    /// The folder above the one shown: up to / on a server, and to this device's own folder.
    private var up: String? {
        guard let dir, dir != (session == nil ? deviceFolder : "/") else { return nil }
        return RemotePath.parent(dir)
    }

    private var canPaste: Bool {
        guard let copied = model.copied, dir != nil else { return false }
        if let from = copied.session { return app.open.contains { $0 === from } }  // closed since: nothing to copy from
        return session != nil  // from this device to this device: as Send, no
    }

    private func paste() {
        guard let copied = model.copied, let dir else { return }
        Task { await model.copy(copied.entries, from: copied.session, to: session, into: dir) }
    }

    // MARK: Drag and drop

    /// A row's drag. Within AirSCP it carries the row, or the selection the row is in (`FilesModel.dragged`); other apps
    /// get the file itself (a server's is downloaded through the queue once they ask for it), never a server's path.
    /// Folders and several rows only go to AirSCP's sides.
    private func dragItem(_ entry: RemoteEntry) -> NSItemProvider {
        let entries = editing && side.selection.contains(entry.path) ? selected : [entry]
        FilesModel.dragged = (side, session, entries)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(for: .airscpRows, visibility: .ownProcess) { done in
            done(Data(), nil)
            return nil
        }
        guard entries.count == 1, entry.kind != .directory else { return provider }
        provider.suggestedName = entry.name
        let (session, model) = (session, model)
        let type = UTType(filenameExtension: (entry.name as NSString).pathExtension, conformingTo: .data) ?? .data
        provider.registerFileRepresentation(for: type, visibility: .all) { done in
            guard let session else {
                done(URL(fileURLWithPath: entry.path), false, nil)
                return nil
            }
            Task { @MainActor in
                model.download([entry], from: session) { urls in
                    if let url = urls?.first { done(url, false, nil) } else { done(nil, false, CocoaError(.fileReadUnknown)) }
                }
            }
            return nil
        }
        return provider
    }

    /// Dropping into `target` (the folder this side shows, nil before there is one, or a folder row's) while over `key`.
    private func drop(into target: String?, over key: String) -> FileDrop {
        FileDrop(targeted: Binding(get: { dropTarget == key }, set: { on in
            if on { dropTarget = key } else if dropTarget == key { dropTarget = nil }
        })) { info in
            dropOperation(info, into: target)
        } perform: { info in
            guard let target else { return }
            model.active = index
            guard info.hasItemsConforming(to: [.airscpRows]) else { return receive(info.itemProviders(for: [.item]), into: target) }
            guard let dragged = FilesModel.dragged else { return }
            dragged.side.selecting = false  // as Send does
            dragged.side.selection = []
            Task { await model.copy(dragged.entries, from: dragged.session, to: session, into: target, move: dragged.side === side) }
        }
    }

    /// What a drop into `target` does: copy (from the other side, as Send, or from another app), move (rows of a server's
    /// side onto a folder of its path, as the Mac moves within a server) or nothing.
    private func dropOperation(_ info: DropInfo, into target: String?) -> DropOperation {
        guard let target, let dir else { return .forbidden }
        guard info.hasItemsConforming(to: [.airscpRows]) else { return .copy }
        guard let dragged = FilesModel.dragged else { return .forbidden }
        if dragged.side === side {
            return session != nil && target != dir && !dragged.entries.contains { $0.path == target } ? .move : .forbidden
        }
        return dragged.session == nil && session == nil ? .forbidden : .copy  // this device on both sides: as Send, no
    }

    /// Files dropped from another app: taken out of the drop (iOS deletes its copies at once), then uploaded into
    /// `target` on a server or copied there on this device, as Import from Files does.
    private func receive(_ providers: [NSItemProvider], into target: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Dropped-" + UUID().uuidString)
        Task {
            var urls: [URL] = []
            for provider in providers {
                do {
                    urls.append(try await provider.file(in: folder))
                } catch {
                    model.fail("Can't add “\(provider.suggestedName ?? "an item")” from the other app", error)
                }
            }
            importFiles(urls, into: target) { try? FileManager.default.removeItem(at: folder) }
        }
    }

    // MARK: Path

    /// The folders from the top down to `dir`: a server's from /, this device's from its own folder.
    private func crumbs(_ dir: String) -> [(name: String, path: String)] {
        var path = session == nil ? deviceFolder : ""
        let rest = session == nil ? String(dir.dropFirst(deviceFolder.count)) : dir
        let top = session == nil ? (deviceName, deviceFolder) : ("/", "/")
        return [top] + rest.split(separator: "/").map { name in
            path += "/" + name
            return (String(name), path)
        }
    }

    // MARK: Actions

    private func open(_ entry: RemoteEntry) {
        if entry.kind == .directory { return side.folders[side.current(app)] = entry.path }
        guard let session else { return preview = URL(fileURLWithPath: entry.path) }
        guard entry.kind == .symlink else { return edit(entry) }
        // A link to a folder lists it; anything else opens as a file.
        Task {
            if (try? await session.list(entry.path)) != nil {
                side.folders[side.current(app)] = entry.path
            } else {
                edit(entry)
            }
        }
    }

    /// Search's or the terminal's file, once its folder is listed: selected and scrolled to, or edited at its line.
    private func reveal(_ target: AppState.Reveal) {
        side.revealing = nil
        guard let entry = side.items.first(where: { $0.path == target.path }) else {
            if side.error != nil { return }  // the folder says why already
            return model.fail("Can't find “\(RemotePath.name(target.path))”",
                              AirSCPError(.noSuchFile, "There is no “\(target.path)” on \(side.name(app))."))
        }
        if let line = target.line, entry.kind != .directory { return edit(entry, line: line) }
        side.selecting = true
        side.selection = [entry.path]
        scrolledTo = entry.path
    }

    /// The editor, for a text file of up to 4 MB; at `line` when given.
    private func edit(_ entry: RemoteEntry, line: Int? = nil) {
        guard let session else { return }
        let title = "Can't edit “\(entry.name)”"
        guard entry.size <= 4 << 20 else {
            return model.fail(title, AirSCPError(.notText, "The file is larger than \(FileRow.size(4 << 20)): open it in another app instead."))
        }
        opening = entry.path
        Task {
            defer { opening = nil }
            do {
                model.editing = EditedFile(session: session, entry: entry, text: try await session.readText(entry.path), line: line)
            } catch let error as AirSCPError where error.kind == .notText {
                // Core's words name the Mac's Open; here Share hands a file to another app.
                model.fail(title, AirSCPError(.notText, error.message.replacingOccurrences(of: "Use Open to open it in its app.",
                                                                                           with: "Share it to open it in another app.")))
            } catch {
                model.fail(title, error)
            }
        }
    }

    private func send(_ entries: [RemoteEntry]) {
        guard let target = other.dir(app) else { return }
        let from = session, to = other.session(app)
        stopSelecting()
        Task { await model.copy(entries, from: from, to: to, into: target) }
    }

    /// Share (the share sheet) or Save to Files (`export`): a server's files are downloaded first, through the queue.
    private func share(_ entries: [RemoteEntry], export: Bool) {
        let hand: ([URL]) -> Void = { urls in
            // A server's downloaded copies are moved there; this device's own items are copied, and stay here too.
            present(export ? UIDocumentPickerViewController(forExporting: urls, asCopy: session == nil)
                           : UIActivityViewController(activityItems: urls, applicationActivities: nil))
        }
        stopSelecting()
        guard let session else { return hand(entries.map { URL(fileURLWithPath: $0.path) }) }
        model.download(entries, from: session) { if let urls = $0 { hand(urls) } }
    }

    private func zip(_ entries: [RemoteEntry]) {
        guard let session, let dir else { return }
        stopSelecting()
        perform("Can't zip") { _ = try await session.compress(entries.map(\.name), in: dir, format: .zip) }
    }

    /// Import from Files, and files dropped from another app: uploaded into `dir` on the server (each file kept open to
    /// AirSCP until its upload is done), or copied there on this device (keeping both where a name is taken); `then` once
    /// they are copied.
    private func importFiles(_ urls: [URL], into dir: String, then: @escaping () -> Void = {}) {
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        let done = {
            scoped.forEach { $0.stopAccessingSecurityScopedResource() }
            then()
        }
        guard let session else {
            perform("Can't import") {
                defer { done() }
                var names = try FileSide.localEntries(dir).map(\.name)
                for url in urls {
                    let name = Names.unique(url.lastPathComponent, existing: names, caseInsensitive: TransferQueue.ignoresCase(dir))
                    names.append(name)
                    try FileManager.default.copyItem(at: url, to: URL(fileURLWithPath: RemotePath.join(dir, name)))
                }
            }
            return
        }
        Task {
            let jobs = await model.copy(urls.map(FileSide.localEntry), from: nil, to: session, into: dir)
            model.whenDone(jobs) { _ in done() }
        }
    }

    private func delete(_ entries: [RemoteEntry]) {
        stopSelecting()
        perform("Can't delete") {
            if let session {
                try await session.delete(entries)
            } else {
                for entry in entries { try FileManager.default.removeItem(atPath: entry.path) }
            }
        }
    }

    private func stopSelecting() {
        side.selecting = false
        side.selection = []
    }

    private func ask(_ naming: Naming, name: String) {
        self.name = name
        self.naming = naming
    }

    private func newFolder() {
        ask(.newFolder, name: Names.unique("untitled folder", existing: side.items.map(\.name)))
    }

    private var namingTitle: String {
        switch naming {
        case .rename(let entry)?: "Rename “\(entry.name)”"
        default: "New folder in “\(dir.map(RemotePath.name) ?? "")”"
        }
    }

    private var namingButton: String {
        if case .rename = naming { return "Rename" }
        return "Create"
    }

    private var deleteTitle: String {
        let what = deleting.count == 1 ? "“\(deleting[0].name)”" : "\(deleting.count) items"
        return session == nil ? "Delete \(what) from this \(UIDevice.current.model)?" : "Delete \(what) on “\(side.name(app))”?"
    }

    /// New Folder and Rename, once named: the name is checked first, and the folder listed again after.
    private func commit(_ naming: Naming) {
        guard let dir else { return }
        let name = self.name
        if let problem = Self.nameProblem(name) {
            return model.failure = ("“\(name)” can't be used as a name", problem)
        }
        let ignoreCase = session?.capabilities.caseInsensitive ?? TransferQueue.ignoresCase(dir)
        let path = RemotePath.join(dir, name)
        let taken = AirSCPError(.other, "“\(name)” already exists in “\(RemotePath.name(dir))”.")
        switch naming {
        case .newFolder:
            guard Names.existing(name, in: side.items.map(\.name), caseInsensitive: ignoreCase) == nil else {
                return model.fail("Choose another name", taken)
            }
            perform("Can't create the folder “\(name)”") {
                if let session {
                    try await session.makeDirectory(path)
                } else {
                    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
                }
            }
        case .rename(let entry):
            // By the bytes: "café" composed and decomposed are two names on a Linux server.
            guard !name.utf8.elementsEqual(entry.name.utf8) else { return }
            let others = side.items.filter { $0.path != entry.path }.map(\.name)
            guard Names.existing(name, in: others, caseInsensitive: ignoreCase) == nil else { return model.fail("Choose another name", taken) }
            let session = self.session
            perform("Can't rename “\(entry.name)”") {
                guard let session else { return try FileManager.default.moveItem(atPath: entry.path, toPath: path) }
                // The listing may be older than the server, and sftp's rename replaces what is there.
                if Names.key(name, caseInsensitive: ignoreCase) != Names.key(entry.name, caseInsensitive: ignoreCase),
                   try await session.exists(path) {
                    throw taken
                }
                try await session.rename(entry.path, to: path)
            }
        }
    }

    /// Runs a file operation, says why when it fails, then lists the folder again.
    private func perform(_ failure: String, _ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
            } catch {
                model.fail(failure, error)
            }
            side.generation += 1
        }
    }

    /// Why `name` can't be a file's name (the Mac's rules), or nil.
    static func nameProblem(_ name: String) -> String? {
        if name.isEmpty { return "Type a name." }
        if name == "." || name == ".." { return "“.” and “..” stand for folders." }
        if name.contains("/") { return "A name can't contain “/”." }
        if name.contains(where: \.isNewline) || name.contains("\u{0}") { return "A name can't contain line breaks." }
        if name.utf8.count > 255 { return "A name can be at most 255 bytes long (this one has \(name.utf8.count))." }
        return nil
    }
}

/// A file or folder: its name, then its size and date as the Mac's panes show them.
struct FileRow: View {
    let entry: RemoteEntry
    /// Being opened: a spinner in place of the icon.
    let busy: Bool
    /// A folder's colour: its server's kind.
    var tint = Color.teal

    var body: some View {
        // Colors, not .primary and .secondary: in a button's label those would be the tint's.
        Label {
            Text(entry.name)
                .foregroundStyle(entry.isHidden ? Color.secondary : Color.primary)
            if !details.isEmpty {  // an S3 folder has neither size nor date
                Text(details)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
            }
        } icon: {
            if busy {
                ProgressView()
            } else {
                Image(systemName: entry.kind == .directory ? "folder.fill" : entry.kind == .symlink ? "arrow.up.right.square" : "doc")
                    .foregroundStyle(entry.kind == .directory ? tint : Color.secondary)
            }
        }
    }

    private var details: String {
        [entry.kind == .file ? Self.size(entry.size) : nil, Self.date(entry)].compactMap { $0 }.joined(separator: " · ")
    }

    /// When it was modified, as the Mac's panes show it: a date-only entry as its day.
    static func date(_ entry: RemoteEntry) -> String? {
        entry.modified.map { entry.dateOnly ? day.string(from: $0) : dates.string(from: $0) }
    }

    private static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false  // "0 KB", not "Zero KB"
        return formatter
    }()

    static func size(_ count: Int64) -> String { bytes.string(fromByteCount: count) }

    private static let dates: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    /// A date-only entry's day (its `modified` is that day's midnight in UTC), without the time the listing didn't give.
    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()
}

/// The folder's path, each folder a button that goes up to it, and takes drops (moves this side's rows up into it).
struct PathBar: View {
    let crumbs: [(name: String, path: String)]
    /// The folder a drag is over: it lights up.
    let targeted: String?
    let go: (String) -> Void
    let drop: (String) -> FileDrop

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(crumbs.indices, id: \.self) { index in
                    if index > 0 {
                        Image(systemName: "chevron.compact.right").foregroundStyle(.tertiary)
                    }
                    if index == crumbs.count - 1 {
                        Text(crumbs[index].name).fontWeight(.semibold)
                    } else {
                        Button(crumbs[index].name) { go(crumbs[index].path) }
                            .help("Go up to “\(crumbs[index].name)”; drop items on it to move them there")
                            .background(targeted == crumbs[index].path ? Color.teal.opacity(0.25) : .clear, in: .rect(cornerRadius: 4))
                            .onDrop(of: [.item], delegate: drop(crumbs[index].path))
                    }
                }
            }
            .font(.subheadline)
            .padding(.horizontal)
            .padding(.vertical, 6)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.trailing)
        .accessibilityIdentifier("path")
    }
}

/// A drop onto a side or one of its folders: the badge shows what it does (copy, move, or not here), the place lights
/// up, and dropping does it.
struct FileDrop: DropDelegate {
    @Binding var targeted: Bool
    let operation: (DropInfo) -> DropOperation
    let perform: (DropInfo) -> Void

    func validateDrop(info: DropInfo) -> Bool { operation(info) != .forbidden }
    func dropEntered(info: DropInfo) { targeted = true }
    func dropExited(info: DropInfo) { targeted = false }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: operation(info)) }

    func performDrop(info: DropInfo) -> Bool {
        targeted = false
        perform(info)
        return true
    }
}

extension UTType {
    /// Rows dragged between the Files tab's sides: AirSCP's own type (Info.plist), never shown to other apps.
    static let airscpRows = UTType(exportedAs: "com.kleash.airscp.rows")
}

extension NSItemProvider {
    /// The dropped item as a file of AirSCP's own, in a new folder in `folder` (a file's own type before a folder's).
    func file(in folder: URL) async throws -> URL {
        let type = registeredContentTypes.first { $0.conforms(to: .data) }
            ?? registeredContentTypes.first { $0.conforms(to: .directory) } ?? .item
        return try await withCheckedThrowingContinuation { continuation in
            _ = loadFileRepresentation(for: type, openInPlace: false) { url, _, error in
                // Moved away before returning: iOS deletes the file once this handler returns.
                do {
                    guard let url else { throw error ?? CocoaError(.fileReadUnknown) }
                    let file = folder.appendingPathComponent(UUID().uuidString).appendingPathComponent(url.lastPathComponent)
                    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.moveItem(at: url, to: file)
                    continuation.resume(returning: file)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Shows a system view controller (the share sheet, the document picker) over whatever is showing.
@MainActor func present(_ controller: UIViewController) {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
    guard var top = scene?.keyWindow?.rootViewController else { return }
    while let presented = top.presentedViewController { top = presented }
    // iPad shows the share sheet as a popover: from the middle of the screen.
    controller.popoverPresentationController?.sourceView = top.view
    controller.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
    top.present(controller, animated: true)
}
