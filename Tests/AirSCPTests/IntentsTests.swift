import AppIntents
import AppKit
import Foundation
import Testing
@testable import AirSCP
@testable import AirSCPCore

// MARK: AirSCPActions: what App Intents and Ask AirSCP run, against a throwaway sshd

/// An app delegate with `model` and a main window, as NSApp's delegate for the test (AirSCPActions finds the app there).
@MainActor
private func withApp(_ model: AppModel, _ body: (AppDelegate) async throws -> Void) async throws {
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    _ = NSApplication.shared
    useAppMenuBar()
    let delegate = AppDelegate()
    keptDelegates.append(delegate)
    delegate.model = model
    delegate.main = MainWindowController(model: model, askpass: askpass)
    keptWindows.append(delegate.main)
    delegate.main.window?.setFrame(NSRect(x: -20000, y: -20000, width: 1000, height: 640), display: false)
    let previous = NSApp.delegate
    NSApp.delegate = delegate
    defer {
        NSApp.delegate = previous
        delegate.main.window?.orderOut(nil)
    }
    try await body(delegate)
    for id in model.connected { await delegate.main.workspaces[id]?.connection.disconnect() }
}

extension FeatureRoundAppTests {
    @MainActor @Test func actionsUploadDownloadFindAndSwitchTunnels() async throws {
        _ = NSApplication.shared
        try await withServer { @MainActor server in
            var host = server.host()
            let tunnel = Tunnel(kind: .local, listenPort: Int.random(in: 40_000..<60_000), targetPort: server.port)
            host.tunnels = [tunnel]
            let model = testModel([host])
            try FileManager.default.createDirectory(atPath: server.path("found/deep"), withIntermediateDirectories: true)
            try Data("a".utf8).write(to: URL(fileURLWithPath: server.path("found/deep/report.txt")))
            try Data("b".utf8).write(to: URL(fileURLWithPath: server.path("found/notes.md")))
            try await withApp(model) { app in
                // Find: the matches below the folder, sorted.
                let found = try await AirSCPActions.find(host: host.id, folder: server.path("found"), pattern: "*.txt")
                #expect(found == [server.path("found/deep/report.txt")])
                // ~ is the server's home folder (Find Files' default in Shortcuts and Ask), as Go to Folder takes it.
                #expect(try await AirSCPActions.find(host: host.id, folder: "~", pattern: "notes.md") == [server.path("found/notes.md")])
                #expect(try await AirSCPActions.find(host: host.id, folder: "~/found", pattern: "*.txt") == found)
                // Download: into the folder given.
                let local = try server.scratch()
                try await AirSCPActions.download(host: host.id, remotePaths: [server.path("found/notes.md")], localDir: local)
                #expect(await eventually { FileManager.default.fileExists(atPath: local + "/notes.md") })
                let fromHome = try server.scratch()
                try await AirSCPActions.download(host: host.id, remotePaths: ["~/found/deep/report.txt"], localDir: fromHome)
                #expect(await eventually { FileManager.default.fileExists(atPath: fromHome + "/report.txt") })
                // Upload: from this Mac into the server folder given.
                try Data("up".utf8).write(to: URL(fileURLWithPath: local + "/sent.txt"))
                try await AirSCPActions.upload(host: host.id, localPaths: [local + "/sent.txt"], remoteDir: server.path("found"))
                #expect(await eventually { FileManager.default.fileExists(atPath: server.path("found/sent.txt")) })
                // Shortcuts' data-only files: their temporary folder goes once they are uploaded, or once the upload
                // failed (a server folder that can't be written), or when it doesn't start.
                try rawMkdir(server.path("locked"))
                chmod(server.path("locked"), 0o555)
                for into in [server.path("found"), server.path("locked")] {
                    let (paths, temporary) = try UploadFilesIntent.paths(of: [IntentFile(data: Data("data".utf8), filename: "data.txt")])
                    let folder = try #require(temporary)
                    try await AirSCPActions.upload(host: host.id, localPaths: paths, remoteDir: into, temporary: folder)
                    #expect(await eventually(timeout: 20) { !FileManager.default.fileExists(atPath: folder.path) }, "\(into)")
                }
                #expect(read(server.path("found/data.txt")) == "data" && !exists(server.path("locked/data.txt")))
                #expect(app.main.workspaces[host.id]?.session.transfers.jobs.contains { job in
                    job.destination == server.path("locked/data.txt") && { if case .failed = job.status { return true }; return false }()
                } == true)
                let (unsent, notStarted) = try UploadFilesIntent.paths(of: [IntentFile(data: Data("x".utf8), filename: "x.txt")])
                await #expect(throws: AirSCPError.self) {
                    try await AirSCPActions.upload(host: UUID(), localPaths: unsent, remoteDir: nil, temporary: notStarted)
                }
                #expect(!FileManager.default.fileExists(atPath: try #require(notStarted).path))
                // A tunnel: on, then off, as the Tunnels tab shows it.
                try await AirSCPActions.setTunnel(host: host.id, tunnel: tunnel.id, on: true)
                let workspace = try #require(app.main.workspaces[host.id])
                #expect(workspace.tunnelsModel.active.contains(tunnel.id))
                try await AirSCPActions.setTunnel(host: host.id, tunnel: tunnel.id, on: false)
                #expect(!workspace.tunnelsModel.active.contains(tunnel.id))
                // Said plainly when it can't be done.
                await #expect(throws: AirSCPError.self) {
                    try await AirSCPActions.upload(host: host.id, localPaths: [local + "/missing.txt"], remoteDir: nil)
                }
                await #expect(throws: AirSCPError.self) {
                    try await AirSCPActions.download(host: host.id, remotePaths: [server.path("nothing-here")], localDir: local)
                }
                await #expect(throws: AirSCPError.self) { try await AirSCPActions.connect(host: UUID()) }
                // Every transfer done: said so, not an empty answer.
                #expect(AirSCPActions.transferStatus([]) == "No transfers.")
                #expect(await eventually { TransferCenter.shared.jobs.contains { $0.status == .done } },
                        "\(TransferCenter.shared.jobs.map(\.status))")
                let done = TransferCenter.shared.jobs.filter { $0.status == .done }
                #expect(!done.isEmpty && AirSCPActions.transferStatus(done).hasSuffix("finished."))
            }
        }
    }
}

// MARK: App Intents' entities

extension FeatureRoundAppTests {
    @MainActor @Test func intentEntitiesListWhatIsSaved() async throws {
        var web = SSHHost(label: "web", hostname: "web.example.com")
        web.favourites = ["/var/www", "/etc/nginx"]
        let tunnel = Tunnel(kind: .local, listenPort: 8080, targetPort: 80)
        web.tunnels = [tunnel]
        let model = testModel([web])
        let snippet = Snippet(name: "Disk usage", command: "df -h")
        model.data.snippets = [snippet]
        try await withApp(model) { _ in
            #expect(try await SnippetQuery().suggestedEntities().map(\.name) == ["Disk usage"])
            #expect(try await SnippetQuery().entities(matching: "df").map(\.id) == [snippet.id])
            // A snippet for the items a server pane selects doesn't run on a host by itself (its {file} would stay).
            let onFiles = Snippet(name: "Back up", command: "cp {file} {file}.bak")
            model.data.snippets.append(onFiles)
            #expect(throws: AirSCPError.self) { try AirSCPActions.runSnippet(onFiles.id, host: web.id) }
            model.data.snippets.removeLast()
            let favourites = try await FavouriteQuery().suggestedEntities()
            #expect(favourites.map(\.path) == ["/var/www", "/etc/nginx"] && favourites.allSatisfy { $0.hostName == "web" })
            #expect(try await FavouriteQuery().entities(matching: "nginx").map(\.path) == ["/etc/nginx"])
            let tunnels = try await TunnelQuery().suggestedEntities()
            #expect(tunnels.count == 1 && tunnels[0].tunnelID == tunnel.id && tunnels[0].hostID == web.id)
            #expect(tunnels[0].title == TunnelsModel.title(tunnel, server: "web"))
            // A deleted item isn't found by its id any more.
            let id = favourites[0].id
            model.updateHost(web.id) { $0.favourites = [] }
            #expect(try await FavouriteQuery().entities(for: [id]).isEmpty)
            model.data.snippets = []
            #expect(try await SnippetQuery().entities(for: [snippet.id]).isEmpty)
        }
    }
}

/// Files Shortcuts hands over as data only (no file on disk) are written to a temporary folder, by their names.
@Test func uploadedDataBecomesTemporaryFiles() throws {
    let (paths, temporary) = try UploadFilesIntent.paths(of: [IntentFile(data: Data("hello".utf8), filename: "note.txt"),
                                                              IntentFile(data: Data("x".utf8), filename: "")])
    #expect(paths.count == 2 && paths[0].hasSuffix("/note.txt") && paths[1].hasSuffix("/file"))
    #expect(try String(contentsOfFile: paths[0], encoding: .utf8) == "hello")
    #expect(URL(fileURLWithPath: paths[0]).deletingLastPathComponent() == URL(fileURLWithPath: paths[1]).deletingLastPathComponent())
    #expect(temporary?.standardizedFileURL == URL(fileURLWithPath: paths[0]).deletingLastPathComponent().standardizedFileURL)
    try? FileManager.default.removeItem(at: URL(fileURLWithPath: paths[0]).deletingLastPathComponent())
    // A name is only a name: one with folders in it, or "..", stays in the temporary folder.
    let named = try UploadFilesIntent.paths(of: [IntentFile(data: Data("a".utf8), filename: "../../escaped.txt"),
                                                 IntentFile(data: Data("b".utf8), filename: "..")]).paths
    let folder = URL(fileURLWithPath: named[0]).deletingLastPathComponent().standardizedFileURL
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(folder.lastPathComponent.hasPrefix("AirSCP-Upload-"))
    #expect(named.map { URL(fileURLWithPath: $0).standardizedFileURL.deletingLastPathComponent() } == [folder, folder])
    #expect(named.map { ($0 as NSString).lastPathComponent } == ["escaped.txt", "file"])
}
