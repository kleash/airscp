import Foundation

/// Disk Usage: what takes the room below a folder, on a server or on this Mac. A scan sends what it finds as it goes
/// (`Record`s), and the tree grows with it: sizes show while it runs, and going into a folder, the largest files and
/// taking deleted items off then need no other command. Not thread-safe: add to it on one thread (the main one).
public final class DiskUsage {
    /// One item found: its path below the scanned folder ("a/b.txt") and, for a file, its size.
    public struct Record: Equatable {
        public let path: String
        public let size: Int64
        /// false from du, which doesn't say: a record of a folder that has items is then its total, passed over.
        public let folder: Bool
    }

    /// A file or folder found. A folder's size is the sum of its files' sizes (apparent sizes, as the panes show them).
    public final class Item: Identifiable {
        public let name: String
        public private(set) var size: Int64 = 0
        public private(set) var isFolder: Bool
        /// The files at every level below (1 for a file).
        public private(set) var files = 0
        public private(set) weak var parent: Item?
        fileprivate var byName: [String: Item] = [:]
        /// The scanned folder's path; nil below it.
        fileprivate var top: String?

        init(name: String, isFolder: Bool, parent: Item?) {
            self.name = name
            self.isFolder = isFolder
            self.parent = parent
        }

        public var path: String { top ?? RemotePath.join(parent?.path ?? "", name) }

        /// Largest first (then by name).
        public var children: [Item] {
            byName.values.sorted { $0.size != $1.size ? $0.size > $1.size : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }

        fileprivate func child(_ name: String, folder: Bool) -> Item {
            if let item = byName[name] { return item }
            let item = Item(name: name, isFolder: folder, parent: self)
            byName[name] = item
            return item
        }

        /// Adds to this folder and every folder above it.
        fileprivate func grow(_ size: Int64, files: Int) {
            var item: Item? = self
            while let folder = item {
                folder.size += size
                folder.files += files
                item = folder.parent
            }
        }

        /// The files at any depth below, largest first; at most `count`.
        public func largestFiles(_ count: Int) -> [Item] {
            var found: [Item] = [], smallest = Int64.min
            var folders = [self]
            while let folder = folders.popLast() {
                for child in folder.byName.values {
                    if child.isFolder {
                        folders.append(child)
                    } else if child.size > smallest || found.count < count {
                        found.append(child)
                        // Kept short as it goes: a big tree has hundreds of thousands of files.
                        if found.count >= 2 * count {
                            found = Array(found.sorted { $0.size > $1.size }.prefix(count))
                            smallest = found[found.count - 1].size
                        }
                    }
                }
            }
            return Array(found.sorted { $0.size > $1.size }.prefix(count))
        }

        /// Takes a deleted item off: out of its folder, and its size and files out of every folder above.
        public func remove() {
            guard let parent else { return }
            parent.byName[name] = nil
            parent.grow(-size, files: -files)
            self.parent = nil
        }
    }

    public let root: Item
    /// The scanned folder's own items: how many there are (0 until the scan says) and how many have been reached.
    public var expected = 0
    public private(set) var reached = 0
    /// The path of the item added last: where the scan is.
    public private(set) var latest = ""

    public init(path: String) {
        root = Item(name: RemotePath.name(path), isFolder: true, parent: nil)
        root.top = path
    }

    public func add(_ records: [Record]) {
        for record in records {
            let parts = record.path.split(separator: "/").map(String.init)
            guard let last = parts.last else { continue }
            var folder = root
            for part in parts.dropLast() { folder = folder.child(part, folder: true) }
            if parts.count == 1 { reached += 1 }
            latest = record.path
            if folder.byName[last] != nil { continue }  // du's total of a folder whose items came first
            // shortcut: from du an empty folder reads as a file of its own size; find -type d would tell them apart.
            let item = folder.child(last, folder: record.folder)
            if !record.folder { item.grow(record.size, files: 1) }
        }
    }

    /// du's output from `Session.duAll`, records ending in `separator`: the size (in `unit`s), a tab and "./path".
    static func parse(_ output: Data, unit: Int64, separator: UInt8) -> [Record] {
        output.split(separator: separator).compactMap { bytes in
            let line = String(decoding: bytes, as: UTF8.self)
            guard let tab = line.firstIndex(of: "\t"), let amount = Int64(line[..<tab]) else { return nil }
            let path = line[line.index(after: tab)...]
            guard path.hasPrefix("./") else { return nil }
            return Record(path: String(path.dropFirst(2)), size: amount * unit, folder: false)
        }
    }

    /// Scans this Mac's folder at `path`: every item below it on its own volume (other disks mounted inside are left
    /// out), packages included; what can't be read is passed over. `found` gets the records in batches, with how many
    /// items the folder itself holds. Cancelling the calling task stops it.
    public static func scan(_ path: String, found: ([Record], Int) -> Void) throws {
        let manager = FileManager.default
        let expected = (try? manager.contentsOfDirectory(atPath: path).count) ?? 0
        guard let walk = manager.enumerator(atPath: path) else { return }
        let volume = (try? manager.attributesOfItem(atPath: path))?[.systemNumber] as? Int
        var batch: [Record] = [], sent = Date()
        while let relative = walk.nextObject() as? String {
            let attributes = walk.fileAttributes ?? [:]
            let folder = attributes[.type] as? FileAttributeType == .typeDirectory
            if folder, let volume, attributes[.systemNumber] as? Int != volume {
                walk.skipDescendants()
                continue
            }
            batch.append(Record(path: relative, size: folder ? 0 : (attributes[.size] as? NSNumber)?.int64Value ?? 0, folder: folder))
            if batch.count == 5_000 || sent.timeIntervalSinceNow < -0.2 {
                try Task.checkCancellation()
                found(batch, expected)
                batch = []
                sent = Date()
            }
        }
        found(batch, expected)
    }
}

extension Session {
    /// Scans the server folder at `dir` with one `du -a` on its file system (other disks mounted inside are left out),
    /// NUL-separated where du is GNU's (so any name comes through), else one per line; what can't be read is passed
    /// over. `found` gets the records as they come (on a background thread), with how many items the folder itself
    /// holds. Shell hosts only. Cancelling the calling task stops it.
    // shortcut: shellBytes also keeps the whole output while du runs (~100 bytes an item); fine below millions of files.
    public func diskUsage(of dir: String, found: @escaping ([DiskUsage.Record], Int) -> Void) async throws {
        try requireShell()
        // The folder's own items counted by the shell's glob: one per name, whatever is in it.
        let count = "n=0; for f in * .[!.]* ..?*; do if [ -e \"$f\" ] || [ -L \"$f\" ]; then n=$((n+1)); fi; done; echo \"count=$n\";"
        let script = "cd \(Quote.shell(dir)) && { \(Session.duAll) \(count) echo \"unit=$unit\"; $du . 2>/dev/null; true; }"
        var pending = Data(), started = false, expected = 0, unit: Int64 = 0
        _ = try await cancellable { cancellation in
            try await shellBytes(script, cancellation: cancellation, output: { chunk in
                pending.append(chunk)
                if !started, let marker = pending.range(of: Data("\n__AIRSCP__\n".utf8)) {
                    pending = pending.subdata(in: marker.upperBound..<pending.endIndex)
                    started = true
                }
                // The two lines before du's: count= and unit=.
                while started && unit == 0, let newline = pending.firstIndex(of: 0x0A) {
                    let line = String(decoding: pending[..<newline], as: UTF8.self)
                    let value = line.drop { $0 != "=" }.dropFirst().trimmingCharacters(in: .whitespaces)
                    if line.hasPrefix("count=") { expected = Int(value) ?? 0 } else { unit = Int64(value) ?? 1024 }
                    pending = pending.subdata(in: (newline + 1)..<pending.endIndex)
                }
                // GNU's du (unit 1) ends each record with a NUL, the others with a line feed.
                let separator: UInt8 = unit == 1 ? 0 : 0x0A
                guard unit > 0, let end = pending.lastIndex(of: separator) else { return }
                found(DiskUsage.parse(pending[..<end], unit: unit, separator: separator), expected)
                pending = pending.subdata(in: (end + 1)..<pending.endIndex)
            })
        }
    }

    /// Sets $du to `du -a -x` for every file and folder of one file system, sizes as `du` (above) takes them.
    static let duAll = "if du --version 2>/dev/null | grep -q GNU; then du='du -a -x -0 --apparent-size --block-size=1'; unit=1; "
        + "else case $(uname -s) in Darwin|*BSD) du='env LC_CTYPE=UTF-8 du -a -x -A -k';; *) du='du -a -x -k';; esac; unit=1024; fi;"
}
