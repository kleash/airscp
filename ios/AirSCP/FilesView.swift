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
    @State private var model = FilesModel()
    let goToServers: () -> Void

    var body: some View {
        Group {
            if app.open.isEmpty {
                NothingOpen(title: "No server open", systemImage: "folder",
                            description: "Open a server in Servers to browse its files.", goToServers: goToServers)
            } else if width == .regular {
                HStack(spacing: 0) {
                    NavigationStack { SideView(model: model, index: 0, switcher: false) }
                    Divider()
                    NavigationStack { SideView(model: model, index: 1, switcher: false) }
                }
            } else {
                NavigationStack { SideView(model: model, index: model.shown, switcher: true) }.id(model.shown)
            }
        }
        .onReceive(TransferCenter.shared.$jobs) { model.jobsChanged($0) }
        .task(id: app.reveal?.id) {  // also when the tab shows again
            guard let reveal = app.reveal else { return }
            app.reveal = nil
            model.show(reveal, app)
        }
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
        .sheet(item: $model.editing) { file in
            NavigationStack {
                EditorView(file: file) { model.reload(file.session.host.id, RemotePath.parent(file.entry.path)) }
            }
        }
    }
}

/// The Files tab's sides and what they share: the questions and failures they show, and work waiting for transfers.
@MainActor @Observable final class FilesModel {
    var sides = [FileSide(), FileSide(source: .device)]
    /// The side shown on a narrow screen.
    var shown = 0
    var showHidden = false
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
    /// copy within one server runs at once (cp). Returns the queued jobs.
    @discardableResult
    func copy(_ entries: [RemoteEntry], from source: Session?, to target: Session?, into dir: String) async -> [UUID] {
        guard !entries.isEmpty else { return [] }
        let place = "“\(target == nil && dir == deviceFolder ? deviceName : RemotePath.name(dir))”"
        let sameServer = source != nil && source?.host.id == target?.host.id
        if sameServer, let looped = entries.first(where: { dir == $0.path || dir.hasPrefix($0.path + "/") }) {
            fail("Can't copy", AirSCPError(.other, "“\(looped.name)” can't go into itself."))
            return []
        }
        // Listed now: the other side's rows may be older than what is there (an item made since would be replaced unasked).
        let existing: [RemoteEntry]
        do {
            existing = try await target?.list(dir) ?? FileSide.localEntries(dir)
        } catch {
            fail("Can't copy to \(place)", error)
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
                                              move: false)
                    } else {
                        if let old = step.replaces { try await server.delete([old]) }  // another spelling: it goes first
                        try await server.copy(step.entry.path, to: path)
                    }
                }
            } catch {
                fail("Can't copy", error)
            }
            reload(server.host.id, dir)
            return []
        case (nil, nil):
            return []
        }
    }

    /// Downloads server files into a new temporary folder through the transfer queue, then hands them to `then`
    /// (Share, Save to Files); says why when one fails.
    func download(_ entries: [RemoteEntry], from session: Session, then: @escaping ([URL]) -> Void) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Downloads-" + UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return fail("Can't download", error)
        }
        let urls = entries.map { folder.appendingPathComponent($0.name) }
        let jobs = zip(entries, urls).map { entry, url in session.transfers.download(entry.path, to: url.path, isFolder: false) }
        whenDone(jobs) { [self] finished in
            for job in finished {
                if case .failed(let error) = job.status { return fail("Can't download “\(job.name)”", error) }
                if job.status != .done { return }  // cancelled
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
            List(selection: Binding(get: { side.selection }, set: { side.selection = $0 })) {
                ForEach(visible) { entry in
                    row(entry)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) { actions(entry, all: false) }
                        .contextMenu { actions(entry, all: true) }
                }
            }
            .onChange(of: scrolledTo) {
                guard let scrolledTo else { return }
                proxy.scrollTo(scrolledTo, anchor: .center)
                self.scrolledTo = nil  // the same file shown again scrolls again
            }
        }
        .overlay { placeholder }
        .refreshable { if let location { await side.load(session, location) } }
        .environment(\.editMode, Binding(get: { side.selecting ? .active : .inactive }, set: { side.selecting = $0.isEditing }))
        .navigationTitle(side.name(app))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        // A narrow screen's bottom bar takes the tab bar's place while selecting.
        .toolbar(editing && switcher ? .hidden : .visible, for: .tabBar)
        .safeAreaBar(edge: .top) {
            if let dir { PathBar(crumbs: crumbs(dir)) { side.folders[side.current(app)] = $0 } }
        }
        .task(id: "\(String(describing: location))|\(side.generation)") {
            if let location { await side.load(session, location) }
            if let revealing = side.revealing, side.listed == location { reveal(revealing) }
        }
        .onChange(of: dir) { side.selection = [] }
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
            case .success(let urls): importFiles(urls)
            case .failure(let error): model.fail("Can't import", error)
            }
        }
        .quickLookPreview($preview)
    }

    // MARK: Rows

    @ViewBuilder private func row(_ entry: RemoteEntry) -> some View {
        if editing {
            FileRow(entry: entry, busy: false)
        } else {
            Button { open(entry) } label: { FileRow(entry: entry, busy: opening == entry.path) }
                .help(entry.kind == .directory ? "Open this folder" : session == nil ? "Preview this file" : "Edit this file")
        }
    }

    /// A row's swipe actions (Send, Rename, Delete) and its context menu (`all`: also Edit, Share and Save to Files).
    @ViewBuilder private func actions(_ entry: RemoteEntry, all: Bool) -> some View {
        if all && session != nil && entry.kind != .directory {
            Button("Edit", systemImage: "pencil.line") { edit(entry) }
                .help("Edit this text file")
        }
        Button("Send", systemImage: "paperplane") { send([entry]) }
            .tint(.teal)
            .disabled(sendProblem != nil)
            .help(sendProblem ?? "Copy to the other side (\(other.name(app)))")
        Button("Rename", systemImage: "character.cursor.ibeam") { ask(.rename(entry), name: entry.name) }
            .tint(.gray)
            .help("Change this item's name")
        if all && entry.kind != .directory {
            Button("Share", systemImage: "square.and.arrow.up") { share([entry], export: false) }
                .help("Send this file with another app, such as Mail or Messages")
            if session != nil {
                Button("Save to Files", systemImage: "folder") { share([entry], export: true) }
                    .help("Save a copy of this file in the Files app")
            }
        }
        Button("Delete", systemImage: "trash", role: .destructive) { deleting = [entry] }
            .tint(.red)  // the app's teal tint would colour a swipe button's red too
            .help("Delete this item")
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
                .frame(maxWidth: 280)
                .help("Switch between the two sides: Send copies to the side not shown")
            }
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
                Button("New Folder", systemImage: "folder.badge.plus") {
                    ask(.newFolder, name: Names.unique("untitled folder", existing: side.items.map(\.name)))
                }
                .disabled(dir == nil)
                .help(dir == nil ? "Connect to the server first" : "Make a folder here")
                Menu("More", systemImage: "ellipsis") {
                    Button("Select", systemImage: "checkmark.circle") { side.selecting = true }
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
                }
                .help("Select, choose what this side shows, import, hidden files")
            }
        }
    }

    @ViewBuilder private var selectionBar: some View {
        let files = !selected.isEmpty && selected.allSatisfy { $0.kind != .directory }
        let zipProblem = session.map { $0.compressUnavailableReason(.zip) } ?? "Zip works on a server's files"
        Button("Send", systemImage: "paperplane") { send(selected) }
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
        Button("Share", systemImage: "square.and.arrow.up") { share(selected, export: false) }
            .disabled(!files)
            .help(files ? "Send the selected files with another app" : "Select files to share them (not folders)")
        Spacer()
        Button("Zip", systemImage: "doc.zipper") { zip(selected) }
            .disabled(selected.isEmpty || zipProblem != nil)
            .help(zipProblem ?? "Pack the selected items into a .zip in this folder")
        Spacer()
        Button("Delete", systemImage: "trash", role: .destructive) { deleting = selected }
            .disabled(selected.isEmpty)
            .help("Delete the selected items")
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
            present(export ? UIDocumentPickerViewController(forExporting: urls, asCopy: false)  // moves the downloaded copies there
                           : UIActivityViewController(activityItems: urls, applicationActivities: nil))
        }
        stopSelecting()
        guard let session else { return hand(entries.map { URL(fileURLWithPath: $0.path) }) }
        model.download(entries, from: session, then: hand)
    }

    private func zip(_ entries: [RemoteEntry]) {
        guard let session, let dir else { return }
        stopSelecting()
        perform("Can't zip") { _ = try await session.compress(entries.map(\.name), in: dir, format: .zip) }
    }

    /// Import from Files: uploaded into the server's folder (each file kept open to AirSCP until its upload is done), or
    /// copied into this device's (keeping both where a name is taken).
    private func importFiles(_ urls: [URL]) {
        guard let dir else { return }
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        let done = { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }
        guard let session else {
            perform("Can't import") {
                defer { done() }
                var names = side.items.map(\.name)
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

    var body: some View {
        // Colors, not .primary and .secondary: in a button's label those would be the tint's.
        Label {
            Text(entry.name)
                .foregroundStyle(entry.isHidden ? Color.secondary : Color.primary)
            Text(details)
                .font(.caption)
                .foregroundStyle(Color.secondary)
        } icon: {
            if busy {
                ProgressView()
            } else {
                Image(systemName: entry.kind == .directory ? "folder.fill" : entry.kind == .symlink ? "arrow.up.right.square" : "doc")
                    .foregroundStyle(entry.kind == .directory ? Color.teal : Color.secondary)
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

/// The folder's path, each folder a button that goes up to it.
struct PathBar: View {
    let crumbs: [(name: String, path: String)]
    let go: (String) -> Void

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
                            .help("Go up to “\(crumbs[index].name)”")
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
