import AirSCPCore
import AppKit
import UniformTypeIdentifiers

/// A row of a file pane: an entry on a server (`entry`), or a file on this Mac read the same way.
struct FileItem: Equatable {
    let name: String
    let path: String
    let kind: RemoteEntry.Kind
    let size: Int64
    let modified: Date?
    /// "rwxr-xr-x".
    let permissions: String
    /// The permission bits, e.g. 0o755.
    let mode: Int
    let owner: String
    let group: String
    /// The server's listing gave the day only (`RemoteEntry.dateOnly`).
    let dateOnly: Bool
    /// The server's entry; nil for a file on this Mac.
    let entry: RemoteEntry?

    init(_ entry: RemoteEntry) {
        name = entry.name
        path = entry.path
        kind = entry.kind
        size = entry.size
        modified = entry.modified
        permissions = entry.permissions
        mode = entry.mode
        owner = entry.owner
        group = entry.group
        dateOnly = entry.dateOnly
        self.entry = entry
    }

    init(local name: String, path: String, kind: RemoteEntry.Kind, size: Int64, modified: Date?, mode: Int,
         owner: String, group: String) {
        self.name = name
        self.path = path
        self.kind = kind
        self.size = size
        self.modified = modified
        permissions = FileList.symbolic(mode)
        self.mode = mode
        self.owner = owner
        self.group = group
        dateOnly = false
        entry = nil
    }

    var isFolder: Bool { kind == .directory }
    var isHidden: Bool { name.hasPrefix(".") }
}

/// Listing, sorting and describing the rows of a file pane. Everything here may run off the main thread.
enum FileList {
    // MARK: This Mac's files

    /// A folder on this Mac, read with readdir and lstat: names exactly as stored (Foundation may hand back another
    /// Unicode form), links not followed.
    static func local(_ dir: String) throws -> [FileItem] {
        guard let handle = opendir(dir) else {
            throw AirSCPError(errno == ENOENT ? .noSuchFile : errno == EACCES ? .permissionDenied : .other,
                              "Can't read the folder: \(String(cString: strerror(errno)))")
        }
        defer { closedir(handle) }
        var items: [FileItem] = []
        var users: [uid_t: String] = [:], groups: [gid_t: String] = [:]
        while let entry = readdir(handle) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            if let item = localItem(name, in: dir, &users, &groups) { items.append(item) }
        }
        return items
    }

    private static func localItem(_ name: String, in dir: String, _ users: inout [uid_t: String],
                                  _ groups: inout [gid_t: String]) -> FileItem? {
        let path = RemotePath.join(dir, name)
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        let kind: RemoteEntry.Kind
        switch info.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .file
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        return FileItem(local: name, path: path, kind: kind, size: Int64(info.st_size),
                        modified: Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)),
                        mode: Int(info.st_mode & 0o7777), owner: userName(info.st_uid, &users),
                        group: groupName(info.st_gid, &groups))
    }

    /// The names in a folder on this Mac, exactly as stored (for conflict checks).
    static func localNames(_ dir: String) -> [String] {
        guard let handle = opendir(dir) else { return [] }
        defer { closedir(handle) }
        var names: [String] = []
        while let entry = readdir(handle) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// The row for one item on this Mac (links not followed), or nil when nothing is there.
    static func localItem(_ path: String) -> FileItem? {
        var users: [uid_t: String] = [:], groups: [gid_t: String] = [:]
        return localItem(RemotePath.name(path), in: RemotePath.parent(path), &users, &groups)
    }

    /// Files on this Mac dropped from Finder or chosen in a panel: their rows, each name as stored in its folder
    /// (Finder's URL may carry another Unicode form of it). Each folder is read once.
    static func localItems(_ urls: [URL]) -> [FileItem] {
        var stored: [String: [String: String]] = [:]  // folder → name's canonical form → name as stored
        var users: [uid_t: String] = [:], groups: [gid_t: String] = [:]
        return urls.compactMap { url in
            let dir = url.deletingLastPathComponent().path
            if stored[dir] == nil {
                stored[dir] = Dictionary(localNames(dir).map { (Names.key($0), $0) }) { first, _ in first }
            }
            let name = stored[dir]?[Names.key(url.lastPathComponent)] ?? url.lastPathComponent
            return localItem(name, in: dir, &users, &groups)
        }
    }

    /// Whether a local path is a folder, links followed (a link to a folder is copied as one).
    static func isLocalFolder(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
    }

    private static func userName(_ uid: uid_t, _ cache: inout [uid_t: String]) -> String {
        if let name = cache[uid] { return name }
        var record = passwd(), result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: 4096)
        let name = getpwuid_r(uid, &record, &buffer, buffer.count, &result) == 0 && result != nil
            ? String(cString: record.pw_name) : String(uid)
        cache[uid] = name
        return name
    }

    private static func groupName(_ gid: gid_t, _ cache: inout [gid_t: String]) -> String {
        if let name = cache[gid] { return name }
        var record = group(), result: UnsafeMutablePointer<group>?
        var buffer = [CChar](repeating: 0, count: 16384)
        let name = getgrgid_r(gid, &record, &buffer, buffer.count, &result) == 0 && result != nil
            ? String(cString: record.gr_name) : String(gid)
        cache[gid] = name
        return name
    }

    // MARK: Rows

    /// Folders first, then by `key` (a column: name, size, modified, permissions, owner, group, kind), ties by name
    /// (A to Z) as Finder orders them. Folder sizes count once calculated. The keys are worked out once per item, not
    /// in every comparison.
    static func sorted(_ items: [FileItem], by key: String, ascending: Bool, folderSizes: [String: Int64]) -> [FileItem] {
        let keyed = items.map { item -> (item: FileItem, name: NSString, text: String, number: Int64) in
            var text = "", number: Int64 = 0
            switch key {
            case "size": number = item.isFolder ? folderSizes[item.name] ?? -1 : item.size
            case "modified": number = Int64((item.modified ?? .distantPast).timeIntervalSince1970)
            case "permissions": number = Int64(item.mode)
            case "owner": text = item.owner
            case "group": text = item.group
            case "kind": text = kind(of: item)
            default: break
            }
            return (item, item.name as NSString, text, number)
        }
        let wanted: ComparisonResult = ascending ? .orderedAscending : .orderedDescending
        return keyed.sorted { a, b in
            if a.item.isFolder != b.item.isFolder { return a.item.isFolder }
            if a.number != b.number { return (a.number < b.number ? .orderedAscending : .orderedDescending) == wanted }
            if a.text != b.text {
                let order = a.text.localizedStandardCompare(b.text)
                if order != .orderedSame { return order == wanted }
            }
            return a.name.localizedStandardCompare(b.name as String) == (key == "name" ? wanted : .orderedAscending)
        }.map(\.item)
    }

    /// The rows to show: hidden files only with `showHidden`, and only names containing `filter` (any case).
    static func visible(_ items: [FileItem], filter: String, showHidden: Bool) -> [FileItem] {
        let term = filter.trimmingCharacters(in: .whitespaces)
        if term.isEmpty && showHidden { return items }
        return items.filter { item in
            (showHidden || !item.isHidden)
                && (term.isEmpty || item.name.range(of: term, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
    }

    /// The rows named in `names` (to keep the selection across a listing), by their exact bytes: "café" composed and
    /// decomposed are two files on a Linux server, and only the one selected stays selected (a Set<String> would make
    /// them one name).
    static func indexes(of names: [String], in rows: [FileItem]) -> IndexSet {
        guard !names.isEmpty else { return IndexSet() }
        let wanted = Set(names.map { Data($0.utf8) })
        return IndexSet(rows.indices.filter { wanted.contains(Data(rows[$0].name.utf8)) })
    }

    // MARK: Name conflicts

    enum Choice { case replace, keepBoth, skip }

    /// Where an item goes: `name` in the destination folder, replacing the existing item named exactly `replaces`.
    struct Planned: Equatable {
        var name: String
        var replaces: String?
    }

    /// The names that exist at the destination already: the same Unicode text (é precomposed or not), and any case
    /// when `caseInsensitive` (a Mac's disks).
    static func conflicts(_ names: [String], existing: [String], caseInsensitive: Bool) -> [String] {
        let found = existingNames(for: names, existing: existing, caseInsensitive: caseInsensitive)
        return names.filter { found[$0] != nil }
    }

    /// For each of `names` that exists at the destination already (as `conflicts` compares them), the existing item's
    /// own name.
    static func existingNames(for names: [String], existing: [String], caseInsensitive: Bool) -> [String: String] {
        var byKey: [String: String] = [:]
        for name in existing { byKey[Names.key(name, caseInsensitive: caseInsensitive)] = name }
        var found: [String: String] = [:]
        for name in names { found[name] = byKey[Names.key(name, caseInsensitive: caseInsensitive)] }
        return found
    }

    /// The conflict sheet's line about both items: "New: 1.2 MB, 4 Oct 2026 at 15:21 · Existing: 1.1 MB, 3 Oct 2026 at
    /// 09:02" (a folder says so instead of a size). On the main thread (the formatters are shared).
    static func comparison(new: FileItem, existing: FileItem) -> String {
        func describe(_ item: FileItem) -> String {
            ([item.isFolder ? "folder" : size(item.size)] + [item.modified.map { item.dateOnly ? day($0) : dateAndTime.string(from: $0) }]
                .compactMap { $0 }).joined(separator: ", ")
        }
        return "New: \(describe(new)) · Existing: \(describe(existing))"
    }

    /// Each name's destination. A name that exists goes by `choices`: Replace takes the existing item's exact name,
    /// Keep Both a free "name 2", Skip (or no choice) nil. A name that comes twice keeps both.
    static func plan(_ names: [String], existing: [String], caseInsensitive: Bool, choices: [String: Choice]) -> [Planned?] {
        var existingByKey: [String: String] = [:]
        for name in existing { existingByKey[Names.key(name, caseInsensitive: caseInsensitive)] = name }
        var taken = Set(existingByKey.keys)
        return names.map { name -> Planned? in
            let nameKey = Names.key(name, caseInsensitive: caseInsensitive)
            if let old = existingByKey[nameKey] {
                switch choices[name] {
                case .replace?:
                    existingByKey[nameKey] = nil
                    return Planned(name: old, replaces: old)
                case .keepBoth?:
                    break
                case .skip?, nil:
                    return nil
                }
            } else if !taken.contains(nameKey) {
                taken.insert(nameKey)
                return Planned(name: name, replaces: nil)
            }
            let unique = Names.unique(name, takenKeys: taken, caseInsensitive: caseInsensitive)
            taken.insert(Names.key(unique, caseInsensitive: caseInsensitive))
            return Planned(name: unique, replaces: nil)
        }
    }

    /// Why `name` can't be the name of a file, or nil. `windows`: on a Windows server, whose rules are stricter.
    static func nameProblem(_ name: String, windows: Bool = false) -> String? {
        if name.isEmpty { return "Type a name." }
        if name == "." || name == ".." { return "“.” and “..” stand for folders." }
        if name.contains("/") { return "A name can't contain “/”." }
        if name.contains(where: \.isNewline) || name.contains("\u{0}") { return "A name can't contain line breaks." }
        // File systems take at most 255 bytes per name (the server would answer with a cryptic error).
        if name.utf8.count > 255 { return "A name can be at most 255 bytes long (this one has \(name.utf8.count))." }
        return windows ? windowsNameProblem(name) : nil
    }

    static let windowsRule = "Windows names can't contain \\ / : * ? \" < > | or end in a dot or a space, and can't be a "
        + "device name (CON, PRN, AUX, NUL, COM1–9, LPT1–9, also with an extension)."

    /// Why Windows can't store `name` (a ":" would even hide the data in a stream of a file named up to it), or nil.
    static func windowsNameProblem(_ name: String) -> String? {
        let refused = name.contains { "\\/:*?\"<>|".contains($0) || ($0.asciiValue ?? 32) < 32 }
        return refused || name.hasSuffix(".") || name.hasSuffix(" ") || RDPSession.isDeviceName(name) ? windowsRule : nil
    }

    // MARK: Describing

    private static let kinds = KindCache()

    /// Finder's words: "Folder", the file type's name ("Plain Text Document"), "Unix Executable File", …
    static func kind(of item: FileItem) -> String {
        switch item.kind {
        case .directory: return "Folder"
        case .symlink: return "Symbolic Link"
        case .other: return "Special File"
        case .file: break
        }
        let ext = (item.name as NSString).pathExtension.lowercased()
        if ext.isEmpty { return item.mode & 0o111 != 0 ? "Unix Executable File" : "Document" }
        return kinds.description(ext)
    }

    /// The file type for an icon or a file promise.
    static func type(of item: FileItem) -> UTType {
        switch item.kind {
        case .directory: return .folder
        case .symlink: return .symbolicLink
        case .other: return .item
        case .file:
            let ext = (item.name as NSString).pathExtension
            if ext.isEmpty { return item.mode & 0o111 != 0 ? .unixExecutable : .data }
            return UTType(filenameExtension: ext) ?? .data
        }
    }

    /// 0o4755 → "rwsr-xr-x".
    static func symbolic(_ mode: Int) -> String {
        let special = [0o4000, 0o2000, 0o1000]
        var text = ""
        for index in 0..<9 {
            let bit = 1 << (8 - index)
            let letter: Character = index % 3 == 0 ? "r" : index % 3 == 1 ? "w" : "x"
            if index % 3 == 2 && mode & special[index / 3] != 0 {
                let mark: Character = index == 8 ? "t" : "s"
                text.append(mode & bit != 0 ? mark : Character(mark.uppercased()))
            } else {
                text.append(mode & bit != 0 ? letter : "-")
            }
        }
        return text
    }

    private static let bytes: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false  // "0 KB", not "Zero KB"
        return formatter
    }()

    /// "4.2 MB", on the main thread (the formatter is shared).
    static func size(_ count: Int64) -> String { bytes.string(fromByteCount: count) }

    private static let dateAndTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    /// A date-only entry's day ("1 Jan 2024"; its `modified` is that day's midnight in UTC), without the time of day the
    /// listing didn't give. On the main thread (the formatter is shared).
    static func day(_ date: Date) -> String { dayFormatter.string(from: date) }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    /// "1,234 items".
    static func items(_ count: Int) -> String {
        count == 1 ? "1 item" : "\(count.formatted()) items"
    }
}

/// UTType descriptions by file extension, shared by the sorting threads and the table.
private final class KindCache {
    private let lock = NSLock()
    private var cache: [String: String] = [:]

    func description(_ ext: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let kind = cache[ext] { return kind }
        let kind = UTType(filenameExtension: ext).flatMap { $0.isDynamic ? nil : $0.localizedDescription } ?? "Document"
        cache[ext] = kind
        return kind
    }
}
