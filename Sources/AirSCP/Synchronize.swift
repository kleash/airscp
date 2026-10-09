import AirSCPCore
import AppKit
import SwiftUI

/// Synchronize (PLAN.md S.1): a folder on this Mac against a folder on a server, compared recursively, then made the
/// same one way or both ways with ordinary transfer jobs (times kept, so the next compare finds the copies the same)
/// and, on request, deletions on the destination.
enum Sync {
    enum Direction: Hashable { case upload, download, both }

    /// An item that isn't the same on both sides: what this Mac's folder and the server's folder (both there) hold
    /// under its name. `path` is below the two folders compared ("sub/name").
    struct Difference {
        let localFolder: String
        let remoteFolder: String
        let local: FileItem?
        let remote: FileItem?
        let path: String
    }

    struct Comparison {
        var differences: [Difference] = []
        /// Symbolic links, special files, names that only differ in case on a side that tells them apart, and (for a
        /// Windows server) names it can't store: never copied or deleted.
        var leftOut = 0
        var folders = 0
    }

    struct Step {
        enum Action { case upload, download, deleteHere, deleteThere }
        let action: Action
        /// What is copied, or deleted.
        let item: FileItem
        /// Where a copy goes; "" for a deletion.
        let destination: String
        let replaces: Bool
        let path: String
    }

    struct Plan {
        var steps: [Step] = []
        /// Files left as they are: newer on the destination (one way), the same time with another size (both ways), or
        /// a file against a folder.
        var leftAsIs = 0
    }

    /// Compares `localDir` with `remoteDir` on `session`, descending into the folders that are on both sides (a folder
    /// on one side only is copied or deleted whole). Names are matched as conflicts are (`Names.key`). `.DS_Store`,
    /// AirSCP's own `.airscp-*` items and what matches `patterns` (the host's Leave out, at any depth: a folder that
    /// matches isn't even listed) are left out. A folder that can't be listed throws: going on without it could delete
    /// what is in it on the other side. `progress` gets the folders compared so far.
    static func compare(local localDir: String, remote remoteDir: String, on session: Session, leavingOut patterns: [String] = [],
                        progress: @escaping (Int) -> Void) async throws -> Comparison {
        let ignoreCase = TransferQueue.ignoresCase(localDir) || session.capabilities.caseInsensitive
        let windows = session.capabilities.windows
        func wanted(_ item: FileItem) -> Bool {
            item.name != ".DS_Store" && !item.name.hasPrefix(".airscp-") && !TransferQueue.leftOut(item.name, by: patterns)
        }
        func matchKey(_ item: FileItem) -> String { Names.key(item.name, caseInsensitive: ignoreCase) }
        var result = Comparison()
        var level = [(local: localDir, remote: remoteDir, path: "")]
        // A level of the tree at a time: one command lists its folders on a server with a shell.
        while !level.isEmpty {
            var next: [(local: String, remote: String, path: String)] = []
            let listed = try await session.listings(level.map(\.remote))
            for ((localFolder, remoteFolder, path), batch) in zip(level, listed) {
                try Task.checkCancellation()
                // A folder that can't be listed is named: in a big tree, the user must find what stops the comparison.
                func named<T>(_ side: String, _ list: () async throws -> T) async throws -> T {
                    do {
                        return try await list()
                    } catch let error as AirSCPError where error.kind != .cancelled && error.kind != .disconnected {
                        let folder = path.isEmpty ? RemotePath.name(side == "this Mac" ? localDir : remoteDir) : path
                        throw AirSCPError(error.kind, "Can't list “\(folder)” on \(side): \(error.message)", details: error.details)
                    }
                }
                let here = Dictionary(grouping: try await named("this Mac") { try FileList.local(localFolder) }.filter(wanted),
                                      by: matchKey)
                let there = Dictionary(grouping: try await named(session.host.displayName) {
                    if let batch { return batch }
                    return try await session.list(remoteFolder)
                }.map(FileItem.init).filter(wanted), by: matchKey)
                result.folders += 1
                progress(result.folders)
                for key in Set(here.keys).union(there.keys) {
                    let locals = here[key] ?? [], remotes = there[key] ?? []
                    guard locals.count <= 1, remotes.count <= 1, let name = (locals.first ?? remotes.first)?.name else {
                        result.leftOut += locals.count + remotes.count
                        continue
                    }
                    let local = locals.first, remote = remotes.first
                    // A name with a line break: not every listing shows it (the compare would never settle).
                    if name.contains(where: \.isNewline)
                        || [local?.kind, remote?.kind].contains(where: { $0 == .symlink || $0 == .other })
                        || (windows && remote == nil && FileList.windowsNameProblem(name) != nil) {
                        result.leftOut += 1
                        continue
                    }
                    let sub = path.isEmpty ? name : path + "/" + name
                    if let local, let remote {
                        if local.isFolder && remote.isFolder {
                            next.append((local.path, remote.path, sub))
                            continue
                        }
                        if !local.isFolder && !remote.isFolder && local.size == remote.size
                            && order(local.modified, remote.modified, dateOnly: remote.dateOnly) == .orderedSame { continue }
                    }
                    result.differences.append(Difference(localFolder: localFolder, remoteFolder: remoteFolder, local: local,
                                                         remote: remote, path: sub))
                }
            }
            level = next
        }
        result.differences.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return result
    }

    /// What to do about `differences`. One way copies what is missing or newer on the source, or of another size at the
    /// same time, and with `delete` deletes what is only on the destination; both ways copies the newer file, and what
    /// is missing on each side.
    static func plan(_ differences: [Difference], direction: Direction, delete: Bool, now: Date = Date()) -> Plan {
        var plan = Plan()
        for difference in differences {
            let path = difference.path
            switch (difference.local, difference.remote) {
            case (let local?, nil):
                if direction != .download {
                    let destination = RemotePath.join(difference.remoteFolder, local.name)
                    plan.steps.append(Step(action: .upload, item: local, destination: destination, replaces: false, path: path))
                } else if delete {
                    plan.steps.append(Step(action: .deleteHere, item: local, destination: "", replaces: false, path: path))
                }
            case (nil, let remote?):
                if direction != .upload {
                    let destination = RemotePath.join(difference.localFolder, remote.name)
                    plan.steps.append(Step(action: .download, item: remote, destination: destination, replaces: false, path: path))
                } else if delete {
                    plan.steps.append(Step(action: .deleteThere, item: remote, destination: "", replaces: false, path: path))
                }
            case (let local?, let remote?):
                guard !local.isFolder && !remote.isFolder else {
                    plan.leftAsIs += 1  // a file against a folder
                    continue
                }
                var order = Sync.order(local.modified, remote.modified, dateOnly: remote.dateOnly)
                // ls and sftp give a recent day with its year for a time after the server's clock: the server's file of
                // that day (of another size) is the newer. Taken for midnight, it lost to the older Mac copy, which replaced it.
                if order == .orderedSame, remote.dateOnly, let theirs = remote.modified, theirs > now.addingTimeInterval(-181 * 86400) {
                    order = .orderedAscending
                }
                if direction != .download && (order == .orderedDescending || order == .orderedSame && direction == .upload) {
                    plan.steps.append(Step(action: .upload, item: local, destination: remote.path, replaces: true, path: path))
                } else if direction != .upload && (order == .orderedAscending || order == .orderedSame && direction == .download) {
                    plan.steps.append(Step(action: .download, item: remote, destination: local.path, replaces: true, path: path))
                } else {
                    plan.leftAsIs += 1
                }
            case (nil, nil):
                break
            }
        }
        return plan
    }

    /// How a Mac file's time (`local`, to the second) compares with the server's from its listing (`remote`), as far as
    /// the listing tells: to the minute, or for a `dateOnly` entry (over six months ago, or after the server's clock) by
    /// the day (`remote` is its midnight in UTC; the day is UTC's in a shell's listing, this Mac's in sftp's, so either
    /// counts). `.orderedDescending`: the Mac's is newer. Unknown times count as the same.
    static func order(_ local: Date?, _ remote: Date?, dateOnly: Bool = false) -> ComparisonResult {
        guard let local, let remote else { return .orderedSame }
        let mine = local.timeIntervalSince1970, theirs = remote.timeIntervalSince1970
        if dateOnly {
            let here = theirs - Double(TimeZone.current.secondsFromGMT(for: remote))  // that day's midnight here
            if mine >= min(theirs, here) && mine < max(theirs, here) + 86400 { return .orderedSame }
        } else if (mine / 60).rounded(.down) * 60 == theirs {
            return .orderedSame
        }
        return mine > theirs ? .orderedDescending : .orderedAscending
    }
}

/// The Synchronize sheet's state: comparing (cancellable, and again when Leave out changes), then the plan for the
/// direction chosen, of which the ticked steps are done.
@MainActor
final class SyncModel: ObservableObject {
    let session: Session
    let localDir: String
    let remoteDir: String
    @Published var direction = Sync.Direction.upload {
        didSet { replan() }
    }
    @Published var delete = false {
        didSet { replan() }
    }
    /// The host's Leave out patterns as typed (the folder-transfer sheet's): left out of the comparison and the copies.
    @Published var leaveOut: String {
        didSet { if TransferQueue.patterns(leaveOut) != patterns { leaveOutChanged() } }
    }
    /// The patterns of the comparison shown, or under way.
    private(set) var patterns: [String]
    /// The steps unticked in the list, by path: left as they are (also after the direction changes).
    @Published var unticked: Set<String> = []
    @Published private(set) var comparison: Sync.Comparison?
    @Published private(set) var plan = Sync.Plan()
    @Published private(set) var folders = 0
    @Published private(set) var failure: String?
    /// The comparison has been started (a home folder's waits for Compare: it can take minutes).
    @Published private(set) var started = false
    private var comparing: Task<Void, Never>?

    init(session: Session, localDir: String, remoteDir: String, leaveOut: String = "") {
        self.session = session
        self.localDir = localDir
        self.remoteDir = remoteDir
        self.leaveOut = leaveOut
        patterns = TransferQueue.patterns(leaveOut)
    }

    /// One of the folders is a home folder (this Mac's, or the account's on the server): its comparison can take
    /// minutes, so it waits for Compare instead of starting as the sheet opens.
    var waitsForCompare: Bool {
        localDir == NSHomeDirectory() || remoteDir == session.capabilities.home || localDir == "/" || remoteDir == "/"
    }

    func compare() {
        guard !started else { return }
        started = true
        comparing = Task { await run() }
    }

    /// The comparison with `patterns`, in the task `comparing` (a cancelled one shows nothing).
    private func run() async {
        do {
            let comparison = try await Sync.compare(local: localDir, remote: remoteDir, on: session,
                                                    leavingOut: patterns) { [weak self] count in
                Task { @MainActor in self?.folders = count }
            }
            guard !Task.isCancelled else { return }
            self.comparison = comparison
            replan()
        } catch {
            if !Task.isCancelled {
                failure = ((error as? AirSCPError)?.message ?? error.localizedDescription) + " Nothing was copied or "
                    + "deleted. Add that folder to Leave out to compare without it, or fix it (its permissions, say) and "
                    + "compare again."
            }
        }
    }

    /// Other patterns: the plan shown no longer holds (Synchronize is off), and the folders are compared again once
    /// typing pauses. A home folder's comparison that waits for Compare just takes them.
    private func leaveOutChanged() {
        patterns = TransferQueue.patterns(leaveOut)
        guard started else { return }
        comparing?.cancel()
        comparison = nil
        failure = nil
        folders = 0
        plan = Sync.Plan()
        comparing = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            await self?.run()
        }
    }

    func cancel() {
        comparing?.cancel()
    }

    private func replan() {
        guard let comparison else { return }
        plan = Sync.plan(comparison.differences, direction: direction, delete: delete && direction != .both)
    }

    /// The plan's ticked steps: what Synchronize does.
    var chosen: Sync.Plan {
        var chosen = plan
        if !unticked.isEmpty { chosen.steps.removeAll { unticked.contains($0.path) } }
        return chosen
    }

    var server: String { session.host.displayName }

    /// Under the Leave out field: that the patterns apply, and where they don't reach.
    var leaveOutNote: String {
        "The same list as for folder transfers to \(server): what matches is left out of the compare and the copies, "
            + (session.capabilities.shell && session.capabilities.tools.contains("tar") ? "wherever it is."
                : "but a folder that is only on one side is copied whole (this server can't run tar).")
    }

    /// "3 uploads (1.2 MB), 1 download (5 KB), 2 deletions on this Mac (3 KB)" for the ticked steps, then what is
    /// unticked, left as it is and left out.
    var summary: String {
        guard let comparison else { return "" }
        let ticked = chosen.steps
        func count(_ action: Sync.Step.Action, _ one: String, _ many: String) -> String? {
            let steps = ticked.filter { $0.action == action }
            guard !steps.isEmpty else { return nil }
            let files = steps.filter { !$0.item.isFolder }, folders = steps.count - files.count
            let total = [files.isEmpty ? nil : FileList.size(files.reduce(0) { $0 + $1.item.size }),
                         folders == 0 ? nil : folders == 1 ? "1 folder" : "\(folders.formatted()) folders"]
            return (steps.count == 1 ? "1 \(one)" : "\(steps.count.formatted()) \(many)")
                + " (" + total.compactMap { $0 }.joined(separator: " and ") + ")"
        }
        var parts = [count(.upload, "upload", "uploads"), count(.download, "download", "downloads"),
                     count(.deleteHere, "deletion on this Mac", "deletions on this Mac"),
                     count(.deleteThere, "deletion on \(server)", "deletions on \(server)")].compactMap { $0 }
        if parts.isEmpty {
            parts = [comparison.differences.isEmpty ? "The folders are the same."
                     : plan.steps.isEmpty ? "Nothing to copy this way." : "Nothing ticked."]
        }
        var text = parts.joined(separator: ", ")
        let skipped = plan.steps.count - ticked.count
        if skipped > 0 { text += "\n\(skipped.formatted()) unticked: left as \(skipped == 1 ? "it is" : "they are")." }
        if plan.leftAsIs > 0 {
            text += "\n\(plan.leftAsIs.formatted()) left as \(plan.leftAsIs == 1 ? "it is" : "they are"): "
                + (direction == .both ? "the same time on both sides but another size, or a file against a folder."
                   : "newer on \(direction == .upload ? server : "this Mac"), or a file against a folder.")
        }
        if comparison.leftOut > 0 {
            text += "\n\(comparison.leftOut.formatted()) left out: symbolic links, special files, names with line breaks, "
                + "names that differ only in case"
                + (session.capabilities.windows ? ", and names Windows can't store." : ".")
        }
        return text
    }
}

struct SyncView: View {
    @ObservedObject var model: SyncModel
    let close: () -> Void
    let synchronize: (Sync.Plan) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Synchronize Folders").font(.headline)
            Text("Compares “\(model.localDir)” on this Mac with “\(model.remoteDir)” on \(model.server), folder by folder, and "
                 + "lists what would be copied.")
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Direction", selection: $model.direction) {
                Text("This Mac → \(model.server)").tag(Sync.Direction.upload)
                Text("\(model.server) → This Mac").tag(Sync.Direction.download)
                Text("Both ways").tag(Sync.Direction.both)
            }
            .pickerStyle(.segmented)
            .primaryTint()
            .labelsHidden()
            .accessibilityIdentifier("sync.direction")
            .help("Which way files go: new and newer files from one side to the other; Both ways copies the newer file each way")
            // Shown off for Both ways, which never deletes (it was greyed out but still ticked).
            Toggle("Delete what is only on \(model.direction == .download ? "this Mac" : model.server)",
                   isOn: model.direction == .both ? .constant(false) : $model.delete)
                .disabled(model.direction == .both)
                .accessibilityIdentifier("sync.delete")
                .help(model.direction == .both ? "Not for Both ways: there, what is only on one side is copied to the other"
                      : "Off by default. On also removes what the other side doesn't have: to the Trash on this Mac, "
                        + "deleted on the server")
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text("Leave out:")
                    TextField("Optional: *.log, node_modules, .git", text: $model.leaveOut)
                        .accessibilityIdentifier("sync.leaveOut")
                        .help(Text(verbatim: "Names or patterns to leave alone wherever they are (* ? [ ] work; commas "
                                   + "separate them), remembered for this server"))  // not Markdown
                }
                Text(model.leaveOutNote).font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.comparison != nil {
                List(model.plan.steps.indices, id: \.self) { index in
                    let step = model.plan.steps[index]
                    HStack {
                        Toggle(step.path, isOn: Binding(get: { !model.unticked.contains(step.path) }, set: { ticked in
                            if ticked { model.unticked.remove(step.path) } else { model.unticked.insert(step.path) }
                        }))
                        .labelsHidden()
                        Image(systemName: Self.symbol(step.action))
                            .foregroundColor([.upload, .download].contains(step.action) ? .accentColor : Color(nsColor: .systemRed))
                            .frame(width: 16)
                        Text(step.path + (step.item.isFolder ? "/" : "")).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(step.item.isFolder ? "" : FileList.size(step.item.size)).foregroundColor(.secondary)
                    }
                    .help(Self.describe(step) + "; untick to leave it as it is")  // the box's too
                }
                .frame(minHeight: 260)
                if !model.plan.steps.isEmpty {
                    HStack {
                        Button("Select All") { model.unticked = [] }.help("Tick every item in the list")
                        Button("Select None") { model.unticked = Set(model.plan.steps.map(\.path)) }
                            .help("Untick every item, to tick just the ones to do")
                    }
                }
                Text(model.summary).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let failure = model.failure {
                Text(failure).foregroundColor(Color(nsColor: .systemRed)).fixedSize(horizontal: false, vertical: true)
            } else if !model.started {
                HStack {
                    Text("A home folder holds a lot: comparing it can take minutes. Nothing is copied until you press "
                         + "Synchronize.")
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Compare") { model.compare() }
                        .help("Compare the two folders now and list what would be copied")
                }
                .frame(minHeight: 60)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Comparing… (\(model.folders.formatted()) \(model.folders == 1 ? "folder" : "folders"))")
                        .foregroundColor(.secondary)
                }
                .frame(minHeight: 260)  // the list's: the sheet keeps its size while Leave out is typed
            }
            Text("Copies keep their modification times, so that a second compare finds them the same.")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                HelpButton(.synchronize)
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction).help("Close without copying anything")
                Button("Synchronize") { synchronize(model.chosen) }
                    .keyboardShortcut(.defaultAction).primaryTint()
                    .disabled(model.chosen.steps.isEmpty)
                    .help(model.comparison == nil ? "Compare first" : model.plan.steps.isEmpty ? "Nothing to do this way"
                          : model.chosen.steps.isEmpty ? "Nothing is ticked: tick the items to do"
                          : "Queue the ticked copies in Transfers and run the ticked deletions now")
            }
        }
        .padding(20)
        .frame(width: 600)
    }

    static func symbol(_ action: Sync.Step.Action) -> String {
        switch action {
        case .upload: return "arrow.up"
        case .download: return "arrow.down"
        case .deleteHere, .deleteThere: return "trash"
        }
    }

    static func describe(_ step: Sync.Step) -> String {
        switch step.action {
        case .upload: return step.replaces ? "Upload, replacing the server's older copy" : "Upload"
        case .download: return step.replaces ? "Download, replacing this Mac's older copy" : "Download"
        case .deleteHere: return "Move to the Trash on this Mac"
        case .deleteThere: return "Delete on the server"
        }
    }
}
