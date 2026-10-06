import AirSCPCore
import AppKit
import SwiftUI

/// The rwx boxes for owner, group and others, with the octal number; either can be edited. Setuid, setgid and the
/// sticky bit are kept as they are (they show in the number).
struct PermissionsGrid: View {
    @Binding var mode: Int
    /// The octal field holds something that isn't a mode (0 to 7777): Apply waits for a valid one.
    @Binding var invalid: Bool
    @State private var octal = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("")
                    ForEach(["Read", "Write", "Execute"], id: \.self) { Text($0).foregroundColor(.secondary) }
                }
                ForEach(Array(["Owner", "Group", "Others"].enumerated()), id: \.offset) { row, who in
                    GridRow {
                        Text(who)
                        ForEach(0..<3, id: \.self) { column in
                            Toggle(who + " " + ["read", "write", "execute"][column], isOn: bit(8 - (row * 3 + column)))
                                .labelsHidden()
                                .gridColumnAlignment(.center)
                                .help(Self.tip(who: row, column: column))
                        }
                    }
                }
            }
            Text("Read lets one see it, Write change it, Execute run it (or enter a folder).")
                .font(.caption).foregroundColor(.secondary)
            HStack(spacing: 8) {
                Text("Octal (chmod):")
                TextField("Octal", text: $octal).accessibilityIdentifier("permissions.octal")
                    .labelsHidden()
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 64)
                    .help("The same as a number, e.g. 644 or 755")
                Text(invalid ? "Octal: 0 to 7777" : FileList.symbolic(mode))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(invalid ? Color(nsColor: .systemRed) : .secondary)
            }
        }
        .onAppear { octal = Self.octal(mode) }
        .onChange(of: mode) { value in if Int(octal, radix: 8) != value { octal = Self.octal(value) } }
        .onChange(of: octal) { text in
            let value = Int(text.trimmingCharacters(in: .whitespaces), radix: 8).flatMap { (0...0o7777).contains($0) ? $0 : nil }
            invalid = value == nil
            if let value, value != mode { mode = value }
        }
    }

    /// "The owner may read it", "Others may run it (or enter the folder)".
    static func tip(who row: Int, column: Int) -> String {
        let who = ["The owner", "The group", "Others"][row]
        let what = ["read it", "change it", "run it (or enter the folder)"][column]
        return "\(who) may \(what)"
    }

    static func octal(_ mode: Int) -> String {
        let text = String(mode & 0o7777, radix: 8)
        return String(repeating: "0", count: max(0, 3 - text.count)) + text
    }

    private func bit(_ index: Int) -> Binding<Bool> {
        Binding(get: { mode & (1 << index) != 0 },
                set: { on in mode = on ? mode | (1 << index) : mode & ~(1 << index) })
    }
}

/// Permissions… for the selected items: one mode for all of them (from the first), and for folders whether
/// everything in them changes too (chmod -R, or a walk over sftp).
struct PermissionsSheet: View {
    let title: String
    @State var mode: Int
    let hasFolders: Bool
    let close: () -> Void
    let apply: (_ mode: Int, _ recursive: Bool) -> Void
    @State private var recursive = false
    @State private var invalid = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.headline)
            PermissionsGrid(mode: $mode, invalid: $invalid)
            if hasFolders {
                Toggle("Change everything in the folders too", isOn: $recursive)
                    .help("Off by default. On applies the same permissions to every file and folder inside (chmod -R)")
            }
            HStack {
                HelpButton(.permissions)
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction).help("Close without changing anything")
                Button("Apply") {
                    apply(mode, recursive)
                    close()
                }
                .keyboardShortcut(.defaultAction).primaryTint()
                .disabled(invalid)
                .help(invalid ? "Type an octal number from 0 to 7777 first" : "Change the permissions on the server now")
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

/// Get Info for a server item: loads `Session.info` (path, kind, size and item count, dates, owner, link target)
/// and applies permission changes. Owner and group are shown, not edited.
@MainActor
final class InfoModel: ObservableObject {
    let session: Session
    let entry: RemoteEntry
    @Published private(set) var info: RemoteInfo?
    @Published private(set) var loading = false
    @Published private(set) var failure: String?
    @Published var mode: Int
    @Published var recursive = false
    @Published private(set) var appliedMode: Int
    /// After a permission change (the pane lists the folder again).
    var onChange: (() -> Void)?
    /// Reading the facts (du and find can take long on a big folder): `cancel` (the sheet closing) stops it.
    private var reading: Task<Void, Never>?

    init(session: Session, entry: RemoteEntry) {
        self.session = session
        self.entry = entry
        mode = entry.mode & 0o7777
        appliedMode = entry.mode & 0o7777
    }

    func load() {
        loading = true
        reading = Task {
            do {
                let info = try await session.info(entry)
                self.info = info
                if mode == appliedMode { mode = info.mode & 0o7777 }
                appliedMode = info.mode & 0o7777
            } catch {
                failure = (error as? AirSCPError)?.message ?? error.localizedDescription
            }
            loading = false
        }
    }

    func cancel() {
        reading?.cancel()
    }

    func applyPermissions() {
        let mode = self.mode, recursive = self.recursive
        loading = true
        failure = nil
        Task {
            do {
                try await session.setPermissions(entry, mode: mode, recursive: recursive)
                appliedMode = mode
                onChange?()
            } catch {
                failure = (error as? AirSCPError)?.message ?? error.localizedDescription
            }
            loading = false
        }
    }
}

struct InfoView: View {
    @ObservedObject var model: InfoModel
    let close: () -> Void
    @State private var invalidMode = false

    private static let dates: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        let entry = model.entry, info = model.info
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: FilePane.icon(for: FileItem(entry)))
                    .resizable()
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.name).font(.headline).lineLimit(2)
                    Text(info?.kind.map(Self.kind) ?? FileList.kind(of: FileItem(entry))).foregroundColor(.secondary).lineLimit(2)
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 5) {
                row("Path", entry.path)
                row("Size", size(info))
                if let count = info?.itemCount { row("Contains", FileList.items(count)) }
                if info?.incomplete == true { row("Contains", "Not all of it can be read: the size counts only what can.") }
                row("Modified", modified(info))
                if let accessed = info?.accessed { row("Accessed", Self.dates.string(from: accessed)) }
                if let changed = info?.changed { row("Changed", Self.dates.string(from: changed)) }
                row("Owner", info?.owner ?? entry.owner)
                row("Group", info?.group ?? entry.group)
                if let target = info?.linkTarget { row("Link to", target) }
            }
            Divider()
            Text("Permissions").font(.subheadline.weight(.semibold))
            // A link's own mode is 777, and chmod changes its target's: they are changed on the target.
            if entry.kind == .symlink {
                Text("A symbolic link's permissions are its target's: change them on the target.").foregroundColor(.secondary)
            } else {
                PermissionsGrid(mode: $model.mode, invalid: $invalidMode)
                if entry.kind == .directory {
                    Toggle("Change everything in the folder too", isOn: $model.recursive)
                        .help("Off by default. On applies the same permissions to every file and folder inside (chmod -R)")
                }
            }
            if let failure = model.failure {
                Text(failure).foregroundColor(Color(nsColor: .systemRed)).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.loading { ProgressView().controlSize(.small) }
                Spacer()
                if entry.kind != .symlink {
                    Button("Apply Permissions") { model.applyPermissions() }
                        .disabled(model.loading || invalidMode || (model.mode == model.appliedMode && !model.recursive))
                        .help("Change the permissions on the server now (change a box first)")
                }
                Button("Done", action: close).keyboardShortcut(.defaultAction).primaryTint().help("Close")
            }
        }
        .padding(20)
        .frame(width: 460)
        .onExitCommand(perform: close)  // Escape, as in the other sheets (Return is Done)
    }

    /// `file -b`'s words in Finder's: "directory" is a Folder, and so on.
    static func kind(_ text: String) -> String {
        switch text {
        case "directory": return "Folder"
        case "empty": return "Empty file"
        default:
            if text.hasPrefix("symbolic link") { return "Symbolic link" + text.dropFirst("symbolic link".count) }
            return text.prefix(1).uppercased() + text.dropFirst()
        }
    }

    /// The time from stat, else (no shell, or not read yet) the listing's, which may be a day only.
    private func modified(_ info: RemoteInfo?) -> String? {
        let entry = model.entry
        guard let date = info?.modified ?? entry.modified else { return nil }
        return entry.dateOnly && date == entry.modified ? FileList.day(date) : Self.dates.string(from: date)
    }

    private func size(_ info: RemoteInfo?) -> String? {
        guard let bytes = info?.size ?? (model.entry.kind == .file ? model.entry.size : nil) else {
            return model.loading ? "Calculating…" : nil
        }
        return FileList.size(bytes) + " (\(bytes.formatted()) bytes)"
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text(label + ":").foregroundColor(.secondary).gridColumnAlignment(.trailing)
            Text(value ?? "—").textSelection(.enabled).lineLimit(3).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Find Files on a server (`Session.find`): names matching a pattern anywhere below the folder shown. Show goes to a
/// match in the pane.
@MainActor
final class FindModel: ObservableObject {
    let session: Session
    let dir: String
    @Published var pattern = ""
    @Published private(set) var results: [FoundItem] = []
    @Published private(set) var searching = false
    @Published private(set) var status = ""
    @Published var selection: String?
    private var search: Task<Void, Never>?
    /// Counts the searches started: matches that come late belong to the one they were found for.
    private var generation = 0
    /// The most results shown.
    static let limit = 10_000

    init(session: Session, dir: String) {
        self.session = session
        self.dir = dir
    }

    /// The folder searched, as the sheet names it ("/" is the server's name).
    var folder: String { dir == "/" ? session.host.displayName : RemotePath.name(dir) }

    /// What is searched for: the text as typed when it has * ? or [, else names containing it.
    static func glob(_ text: String) -> String {
        let text = text.trimmingCharacters(in: .whitespaces)
        return text.contains(where: { "*?[".contains($0) }) ? text : "*" + text + "*"
    }

    func start() {
        guard !pattern.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        search?.cancel()
        let pattern = Self.glob(self.pattern)
        results = []
        selection = nil
        searching = true
        status = "Searching…"
        generation += 1
        let generation = self.generation
        search = Task {
            let outcome: String
            do {
                // Shown as they come (a big tree or a slow link takes a while), in the order found.
                let (items, truncated) = try await session.find(pattern, in: dir, limit: Self.limit) { [weak self] found in
                    DispatchQueue.main.async { self?.add(found, from: generation) }
                }
                guard !Task.isCancelled else { return }
                results = items
                outcome = items.isEmpty ? "Nothing found below “\(folder)”. Try part of the name, or a pattern like *.log." : truncated
                    ? "The first \(items.count.formatted()) found (there are more: narrow the search)."
                    : (items.count == 1 ? "1 found." : "\(items.count.formatted()) found.")
            } catch {
                guard !Task.isCancelled else { return }
                outcome = (error as? AirSCPError)?.message ?? error.localizedDescription
            }
            searching = false
            status = outcome
        }
    }

    /// Matches found so far by the search under way.
    private func add(_ found: [FoundItem], from search: Int) {
        guard searching, search == generation, results.count < Self.limit else { return }
        results += found.prefix(Self.limit - results.count)
        status = "Searching… (\(results.count.formatted()) found)"
    }

    /// Stops the search; what it found so far stays, in order.
    func stop() {
        search?.cancel()
        search = nil
        if searching {
            searching = false
            results.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            status = results.isEmpty ? "Stopped." : "Stopped: \(results.count == 1 ? "1" : results.count.formatted()) found so far."
        }
    }

    /// Below the folder searched ("logs/app.log").
    func relative(_ path: String) -> String {
        let prefix = dir == "/" ? "/" : dir + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

struct FindView: View {
    @ObservedObject var model: FindModel
    let show: (String) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            let folder = model.folder
            VStack(alignment: .leading, spacing: 3) {
                Text("Find Files in “\(folder)”").font(.headline)
                Text("Searches every folder below “\(folder)” by name. Text finds names containing it; * ? [ ] make a "
                     + "pattern; case doesn't matter.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                TextField("Name, or a pattern like *.log", text: $model.pattern)
                    .onSubmit { model.start() }
                    .accessibilityIdentifier("find.pattern")
                    .help(Text(verbatim: "Part of a name, or a pattern: *.log, report-??.pdf, [Rr]eadme*"))  // not Markdown
                Button(model.searching ? "Stop" : "Find") { model.searching ? model.stop() : model.start() }
                    .help(model.searching ? "Stop the search; what was found stays" : "Start the search (Return)")
            }
            List(model.results, id: \.path, selection: $model.selection) { item in
                Label(model.relative(item.path), systemImage: item.isFolder ? "folder" : "doc")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help("Double-click to go to the item")
            }
            .contextMenu(forSelectionType: String.self, menu: { _ in }, primaryAction: { paths in
                if let path = paths.first { show(path) }
            })
            .frame(minHeight: 240)
            HStack {
                HelpButton(.find)
                if model.searching { ProgressView().controlSize(.small) }
                Text(model.status).foregroundColor(.secondary).lineLimit(2)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction).help("Close (a search under way stops)")
                Button("Show") { if let path = model.selection { show(path) } }
                    .disabled(model.selection == nil)
                    .help(model.selection == nil ? "Select a result first" : "Go to the selected item in the pane")
            }
        }
        .padding(20)
        .frame(width: 540)
    }
}
