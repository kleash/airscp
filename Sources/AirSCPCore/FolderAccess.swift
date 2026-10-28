import Foundation

/// Folders the App Store version may open. Its sandbox opens a folder of this Mac only when the person chose it (in an
/// Open panel), and only until AirSCP quits: a security-scoped bookmark of each chosen folder opens it again at the next
/// launch (`restore`). Its own container and the Downloads folder are always open. The Developer ID version needs none
/// of this.
public enum FolderAccess {
    static let key = "allowedFolders"

    /// The folders open now: those restored or chosen since launch.
    public private(set) static var folders: [String] = []

    /// The person's home folder: in the App Store version's sandbox `NSHomeDirectory()` is the app's container.
    #if APPSTORE
    public static let home = String(cString: getpwuid(getuid()).pointee.pw_dir)
    #else
    public static let home = NSHomeDirectory()
    #endif

    /// What the sandbox always opens: the app's container and (an entitlement) the Downloads folder.
    public static var alwaysOpen: [String] { [NSHomeDirectory(), home + "/Downloads"] }

    /// Keeps `url`, a folder the person just chose, for the next launches (one bookmark per folder). False when no
    /// bookmark could be made of it (the sandbox doesn't let AirSCP into it).
    @discardableResult
    public static func remember(_ url: URL, in defaults: UserDefaults = .standard) -> Bool {
        guard let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                                   relativeTo: nil) else { return false }
        let path = normal(url.path)
        let kept = (defaults.array(forKey: key) as? [Data] ?? []).filter { resolve($0).map { normal($0.url.path) } != path }
        defaults.set(kept + [bookmark], forKey: key)
        if !folders.contains(path) { folders.append(path) }
        return true
    }

    /// Opens every kept folder for as long as AirSCP runs (at launch). A bookmark that no longer resolves (the folder
    /// was deleted) is dropped; a stale one (the folder moved or was renamed) is made again.
    @discardableResult
    public static func restore(from defaults: UserDefaults = .standard) -> [String] {
        var kept: [Data] = []
        for bookmark in defaults.array(forKey: key) as? [Data] ?? [] {
            guard let resolved = resolve(bookmark), resolved.url.startAccessingSecurityScopedResource() else { continue }
            let url = resolved.url
            kept.append(resolved.stale ? (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil,
                                                                relativeTo: nil)) ?? bookmark : bookmark)
            let path = normal(url.path)
            if !folders.contains(path) { folders.append(path) }
        }
        defaults.set(kept, forKey: key)
        return folders
    }

    /// Whether `path` is in one of `folders` (or is one).
    public static func covers(_ path: String, in folders: [String] = folders + alwaysOpen) -> Bool {
        let path = normal(path)
        return folders.map(normal).contains { path == $0 || path.hasPrefix($0 == "/" ? "/" : $0 + "/") }
    }

    /// `path` without "." and "..", and /tmp, /var and /etc however they're spelled (macOS links them into /private), to
    /// compare paths without asking the file system, which the sandbox may not let AirSCP look at yet.
    private static func normal(_ path: String) -> String {
        let path = URL(fileURLWithPath: path).standardizedFileURL.path
        for system in ["/tmp", "/var", "/etc"] where path == "/private" + system || path.hasPrefix("/private" + system + "/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    private static func resolve(_ bookmark: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil,
                                 bookmarkDataIsStale: &stale) else { return nil }
        return (url, stale)
    }
}
