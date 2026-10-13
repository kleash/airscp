import AirSCPCore
import AppKit

/// What Shortcuts, Siri, Spotlight (App Intents) and Ask AirSCP can make AirSCP do: each runs the code
/// the menus and the Files tab run, so the usual sheets (Trust, a password, Replace / Keep Both / Skip, the folder
/// transfer's Leave out) still ask. Failures are thrown with the words AirSCP shows. Server paths are taken as Go to
/// Folder takes them: ~ is the home folder, a relative path starts in the folder the host's pane shows.
@MainActor
enum AirSCPActions {
    private static var app: AppDelegate? { NSApp.delegate as? AppDelegate }

    private static var running: AppDelegate {
        get throws {
            guard let app, app.model != nil else { throw AirSCPError(.other, "AirSCP isn't running.") }
            return app
        }
    }

    private static func host(_ id: UUID) throws -> SSHHost {
        guard let host = try running.model.host(id) else { throw AirSCPError(.other, "AirSCP has no such host any more.") }
        return host
    }

    /// The host's workspace, shown in the window and connected (connecting first: its questions appear as usual).
    private static func connected(_ id: UUID) async throws -> HostWorkspace {
        let app = try running
        _ = try host(id)
        app.main.open(id)
        guard let workspace = app.main.workspace(for: id) else { throw AirSCPError(.other, "AirSCP has no such host any more.") }
        _ = try await workspace.connectedSession()
        return workspace
    }

    /// Shows the host and starts connecting without waiting (Shortcuts' Connect to Host: a password question would
    /// keep Shortcuts waiting); `work` runs once connected.
    static func open(host id: UUID, then work: ((HostWorkspace) -> Void)? = nil) throws {
        _ = try host(id)
        try running.main.open(id, then: work)
    }

    static func connect(host id: UUID) async throws {
        _ = try await connected(id)
    }

    static func openShell(host id: UUID) async throws {
        try await connected(id).showTerminal()
    }

    static func openDesktop(_ id: UUID) throws {
        let app = try running
        guard app.model.rdpEntry(id) != nil else { throw AirSCPError(.other, "AirSCP has no such desktop any more.") }
        app.main.connectDesktop(id)
    }

    /// Disconnects every host and desktop (a desktop asks first while Windows copies files); how many there were.
    @discardableResult
    static func disconnectAll() -> Int {
        guard let app, app.model != nil else { return 0 }
        let connected = app.model.connected
        connected.forEach { app.main.disconnect($0) }
        return connected.count
    }

    static func transferStatus(_ jobs: [TransferJob] = TransferCenter.shared.jobs) -> String {
        guard !jobs.isEmpty else { return "No transfers." }
        let summary = TransferText.summary(jobs)  // empty once every job has finished well
        return summary.isEmpty ? "\(jobs.count == 1 ? "The transfer" : "All \(jobs.count) transfers") finished." : summary
    }

    /// Uploads files and folders from this Mac into `remoteDir` (nil: the folder the host's pane shows). `leaveOut`:
    /// patterns for the folder-transfer sheet's Leave out, kept as if typed there. `temporary`: a folder of files made
    /// for this upload alone (Shortcuts' data), removed once nothing is copied from it any more, or at once when
    /// nothing is.
    static func upload(host id: UUID, localPaths: [String], remoteDir: String?, leaveOut: [String] = [],
                       temporary: URL? = nil) async throws {
        var queued = false
        defer { if let temporary, !queued { try? FileManager.default.removeItem(at: temporary) } }
        let paths = localPaths.map { ($0 as NSString).expandingTildeInPath }
        guard !paths.isEmpty else { throw AirSCPError(.other, "Nothing to upload.") }
        if let missing = paths.first(where: { !FileManager.default.fileExists(atPath: $0) }) {
            throw AirSCPError(.other, "“\(missing)” isn't on this Mac.")
        }
        let workspace = try await connected(id)
        let pane = try serverPane(workspace)
        guard let dir = remoteDir.flatMap(pane.resolve) ?? pane.dir else {
            throw AirSCPError(.other, "Say which server folder to upload into.")
        }
        if !leaveOut.isEmpty {
            try running.model.updateHost(id) { $0.leaveOut = leaveOut.joined(separator: ", ") }
        }
        workspace.browser.upload(paths.map { URL(fileURLWithPath: $0) }, to: pane, into: dir)
        queued = true
        if let temporary { Task { await remove(temporary, onceUploadedBy: workspace) } }
    }

    /// Removes `folder` once its upload is planned (its questions answered) and no transfer of the host reads from it:
    /// its copies done, failed or cancelled, their checks against the originals done.
    private static func remove(_ folder: URL, onceUploadedBy workspace: HostWorkspace) async {
        let inside = folder.path + "/"
        func reads(_ job: TransferJob) -> Bool {
            (job.source + "/").hasPrefix(inside) && (!job.status.isFinished || job.checksum == .wanted || job.checksum == .checking)
        }
        repeat {
            try? await Task.sleep(nanoseconds: 500_000_000)
        } while workspace.browser.planning > 0 || workspace.session.transfers.jobs.contains(where: reads)
        try? FileManager.default.removeItem(at: folder)
    }

    /// Downloads server files and folders into `localDir` (nil: Settings' download folder).
    static func download(host id: UUID, remotePaths: [String], localDir: String?) async throws {
        guard !remotePaths.isEmpty else { throw AirSCPError(.other, "Nothing to download.") }
        let workspace = try await connected(id)
        let session = workspace.session, pane = try serverPane(workspace)
        var items: [FileItem] = []
        for typed in remotePaths {
            let path = pane.resolve(typed) ?? typed
            let parent = RemotePath.parent(path), name = RemotePath.name(path)
            guard let entry = try await session.list(parent).first(where: { $0.name == name }) else {
                throw AirSCPError(.other, "“\(path)” isn't on \(session.host.displayName).")
            }
            items.append(FileItem(entry))
        }
        let dir = (localDir.flatMap { $0.isEmpty ? nil : $0 } ?? workspace.model.data.settings.downloadFolder) as NSString
        workspace.browser.transfer(items, from: .remote(session), to: .local, into: dir.expandingTildeInPath, move: false)
    }

    /// The paths below `folder` whose names match `pattern` (Find Files' rules), sorted.
    static func find(host id: UUID, folder: String, pattern: String) async throws -> [String] {
        let workspace = try await connected(id)
        let dir = try serverPane(workspace).resolve(folder) ?? workspace.session.capabilities.home
        return try await workspace.session.find(pattern, in: dir).items.map(\.path)
    }

    static func runSnippet(_ snippetID: UUID, host id: UUID) throws {
        let app = try running
        guard let snippet = app.model.data.snippets.first(where: { $0.id == snippetID }) else {
            throw AirSCPError(.other, "AirSCP has no such snippet any more.")
        }
        guard !snippet.usesPlaceholders else { throw AirSCPError(.other, selectedItemsOnly) }
        _ = try host(id)
        app.run(snippet, on: id)
    }

    /// A snippet with {file}, {name}, {files} or {folder} runs only on what a server pane shows: run elsewhere, they
    /// would stay as typed, and fish and csh would read {file} as "file".
    static let selectedItemsOnly = "It has {file}, {name}, {files} or {folder}: select the items in a server pane, then "
        + "right-click ▸ Run Snippet."

    static func setTunnel(host id: UUID, tunnel tunnelID: UUID, on: Bool) async throws {
        guard let tunnel = try host(id).tunnels.first(where: { $0.id == tunnelID }) else {
            throw AirSCPError(.other, "That tunnel isn't saved for this host any more.")
        }
        try await connected(id).tunnelsModel.change(tunnel, on: on)
    }

    /// Connects and shows `path` in the host's server pane (a favourite folder).
    static func openFavourite(host id: UUID, path: String) async throws {
        let pane = try serverPane(try await connected(id))
        guard await pane.open(path) else { throw AirSCPError(.other, "“\(path)” can't be opened.") }
    }

    /// The pane showing the host's server (the right one, unless only the left one does).
    private static func serverPane(_ workspace: HostWorkspace) throws -> FilePane {
        let panes = [workspace.browser.right, workspace.browser.left].compactMap { $0 }
        guard let pane = panes.first(where: { $0.session?.host.id == workspace.host.id }) else {
            throw AirSCPError(.other, "\(workspace.host.displayName)'s files aren't shown: open its Files tab and try again.")
        }
        return pane
    }
}
