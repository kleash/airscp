import AirSCPCore
import SwiftUI

/// Files gathered while browsing, to carry together to a third place (mockup screen 7): an open server's folder, the
/// Files app or the share sheet (`TraySheet`). Items come from any open server, or from this device.
@Observable final class Tray {
    struct Item: Hashable, Identifiable {
        /// The server it is on; nil: this device.
        let hostID: UUID?
        let path: String
        let isFolder: Bool
        var id: Self { self }
        var name: String { RemotePath.name(path) }
    }

    private(set) var items: [Item] = []
    /// The tray's sheet is showing (over everything: `traySheet()` on the root view), with the folder each open server
    /// shows in Files.
    var showing = false
    var folders: [UUID: String] = [:]

    /// Adds the items that aren't in the tray yet.
    func add(_ new: [Item]) {
        for item in new where !items.contains(item) { items.append(item) }
    }

    func remove(_ gone: [Item]) {
        items.removeAll { gone.contains($0) }
    }
}

/// The tray in a toolbar, with how many items it holds; opens it. `folders`: the folder each open server shows in Files
/// (Send puts the items there; elsewhere into the server's home folder).
struct TrayButton: View {
    @Environment(AppState.self) private var app
    var folders: [UUID: String] = [:]

    var body: some View {
        Button("Tray", systemImage: app.tray.items.isEmpty ? "tray" : "tray.full") {
            app.tray.folders = folders
            app.tray.showing = true
        }
        .badge(app.tray.items.count)
        .accessibilityValue(app.tray.items.count == 1 ? "1 item" : "\(app.tray.items.count) items")
        .help("Show the files in the tray, to send, save or share them together")
    }
}

extension View {
    /// The tray's sheet, from the root view: a sheet of a toolbar button goes when the toolbar is made again.
    func traySheet(_ tray: Tray) -> some View {
        sheet(isPresented: Binding(get: { tray.showing }, set: { tray.showing = $0 })) { TraySheet(folders: tray.folders) }
    }
}

/// What the tray holds, and where it can go: Send to an open server's folder (as uploads and server-to-server copies in
/// the transfer queue), Save to Files or Share (a server's files downloaded first, through the queue too).
struct TraySheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    let folders: [UUID: String]
    @State private var working: String?
    @State private var failure: AirSCPError?
    /// Send's destination when some names are taken there: Replace or Skip.
    @State private var clash: (session: Session, dir: String, taken: Set<String>)?

    private var items: [Tray.Item] { app.tray.items }
    private var servers: [Session] { app.open.filter { app.states[$0.host.id] == .connected } }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView("The tray is empty", systemImage: "tray",
                                           description: Text("In Files, select items and tap Add to Tray. Then send them all to "
                                                             + "another server, save them in the Files app, or share them."))
                } else {
                    List {
                        Section {
                            ForEach(items) { item in
                                Label {
                                    Text(item.name).lineLimit(1).truncationMode(.middle)
                                    Text(place(item.hostID) + " · " + RemotePath.parent(item.path))
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                                } icon: {
                                    Image(systemName: item.isFolder ? "folder" : "doc").foregroundStyle(.teal)
                                }
                                .swipeActions {
                                    Button("Remove", systemImage: "minus.circle", role: .destructive) { app.tray.remove([item]) }
                                        .help("Take this item out of the tray")
                                }
                            }
                        } footer: {
                            Text("Send them to a server's folder, save them in the Files app, or share them with another app. A "
                                 + "server's files come to this device first.")
                        }
                    }
                }
            }
            .navigationTitle("Tray")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .help("Close the tray; the items stay in it")
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Empty", role: .destructive) { app.tray.remove(items) }
                        .disabled(items.isEmpty)
                        .help(items.isEmpty ? "The tray is empty" : "Take every item out of the tray")
                }
            }
            .safeAreaBar(edge: .bottom) {
                if !items.isEmpty { actions }
            }
        }
        .alert("Can't carry the files", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
               presenting: failure) { _ in
            Button("OK") {}
        } message: { failure in
            Text(failure.message)
        }
        .confirmationDialog(clash.map { "\($0.taken.count == 1 ? "An item" : "\($0.taken.count) items") with the same name "
                                         + "\($0.taken.count == 1 ? "is" : "are") in \(RemotePath.name($0.dir)) already" } ?? "",
                            isPresented: Binding(get: { clash != nil }, set: { if !$0 { clash = nil } }), titleVisibility: .visible,
                            presenting: clash) { clash in
            Button("Replace", role: .destructive) { send(to: clash.session, into: clash.dir, replacing: true) }
                .help("Put the tray's items in place of the ones there")
            Button("Skip") { send(to: clash.session, into: clash.dir, leavingOut: clash.taken) }
                .help("Leave the ones there as they are; those stay in the tray")
            Button("Cancel", role: .cancel) {}
                .help("Send nothing")
        }
    }

    private var actions: some View {
        HStack(spacing: 12) {
            Menu {
                ForEach(servers, id: \.host.id) { session in
                    let dir = folders[session.host.id] ?? session.capabilities.home
                    Button(session.host.displayName + " — " + RemotePath.name(dir)) { checkThenSend(to: session, into: dir) }
                        .help("Copy everything in the tray into \(dir) on \(session.host.displayName)")
                }
            } label: {
                Label("Send", systemImage: "paperplane").frame(maxWidth: .infinity)
            }
            .disabled(servers.isEmpty)
            .help(servers.isEmpty ? "Open a server in Servers to send the items to it" : "Copy everything in the tray to an open server")
            Button { hand(toFiles: true) } label: {
                Label("Save", systemImage: "folder.badge.plus").frame(maxWidth: .infinity)
            }
            .help("Save everything in the tray in the Files app")
            Button { hand(toFiles: false) } label: {
                Label("Share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
            }
            .help("Send everything in the tray with another app, such as Mail or AirDrop")
        }
        .buttonStyle(.glass)
        .controlSize(.large)
        .disabled(working != nil)
        .overlay { if let working { ProgressView(working).padding().glassEffect() } }
        .padding()
    }

    private func place(_ hostID: UUID?) -> String {
        guard let hostID else { return UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
        return (app.data.hosts.first { $0.id == hostID } ?? app.session(for: hostID)?.host)?.displayName ?? "Not open"
    }

    // MARK: Send

    /// Asks first when names are taken in the folder (copies between servers keep their names: Replace or Skip).
    private func checkThenSend(to session: Session, into dir: String) {
        Task {
            working = "Looking in \(RemotePath.name(dir))…"
            defer { working = nil }
            do {
                let there = try await session.list(dir).map(\.name)
                let caseInsensitive = session.capabilities.caseInsensitive
                let taken = Set(items.map(\.name).filter { Names.existing($0, in: there, caseInsensitive: caseInsensitive) != nil })
                if taken.isEmpty { send(to: session, into: dir) } else { clash = (session, dir, taken) }
            } catch {
                failure = error as? AirSCPError ?? AirSCPError(.other, error.localizedDescription)
            }
        }
    }

    /// This device's items as uploads, a server's as one server-to-server copy per folder they are in; what went leaves
    /// the tray, and the Transfers tab shows it.
    private func send(to session: Session, into dir: String, replacing: Bool = false, leavingOut skipped: Set<String> = []) {
        let going = items.filter { !skipped.contains($0.name) }
        var sent: [Tray.Item] = []
        for item in going where item.hostID == nil {
            session.transfers.upload(item.path, to: RemotePath.join(dir, item.name), isFolder: item.isFolder, replacing: replacing)
            sent.append(item)
        }
        let byFolder = Dictionary(grouping: going.filter { $0.hostID != nil }) { [$0.hostID!.uuidString, RemotePath.parent($0.path)] }
        for group in byFolder.values {
            guard let source = app.session(for: group[0].hostID!), app.states[source.host.id] == .connected else { continue }
            session.transfers.relay(group.map(\.name), in: RemotePath.parent(group[0].path), from: source, to: dir, replacing: replacing)
            sent += group
        }
        app.tray.remove(sent)
        if sent.count < going.count {
            failure = AirSCPError(.disconnected, "Some items are on a server that isn't connected: they stay in the tray. Open "
                                  + "that server in Servers, then send them again.")
        } else if app.tray.items.isEmpty {
            dismiss()
        }
    }

    // MARK: Save to Files, Share

    /// The items as files on this device (a server's downloaded through the transfer queue first), then the Files app's
    /// Save or the share sheet.
    private func hand(toFiles: Bool) {
        let chosen = items
        Task {
            working = "Getting the files…"
            defer { working = nil }
            do {
                let urls = try await localCopies(chosen)
                let controller = toFiles ? UIDocumentPickerViewController(forExporting: urls, asCopy: true)
                    : UIActivityViewController(activityItems: urls, applicationActivities: nil)
                show(controller)
            } catch {
                failure = error as? AirSCPError ?? AirSCPError(.other, error.localizedDescription)
            }
        }
    }

    private func localCopies(_ items: [Tray.Item]) async throws -> [URL] {
        // shortcut: the downloaded copies stay in the temporary folder until iOS empties it; remove them once Save or the
        // share sheet is done with them if they take up too much room.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Tray " + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var urls: [URL] = [], jobs: [UUID] = [], names: [String] = []
        for item in items {
            guard let hostID = item.hostID else {
                urls.append(URL(fileURLWithPath: item.path))
                continue
            }
            guard let session = app.session(for: hostID), app.states[hostID] == .connected else {
                throw AirSCPError(.disconnected, "“\(item.name)” is on a server that isn't connected. Open it in Servers, then try again.")
            }
            let name = Names.unique(item.name, existing: names, caseInsensitive: true)  // the same name from two servers
            names.append(name)
            jobs.append(session.transfers.download(item.path, to: folder.appendingPathComponent(name).path, isFolder: item.isFolder))
            urls.append(folder.appendingPathComponent(name))
        }
        try await Self.finished(jobs)
        return urls
    }

    /// Waits until the jobs are done (each copy checked, where it is), throwing what went wrong with the first that wasn't.
    private static func finished(_ ids: [UUID]) async throws {
        guard !ids.isEmpty else { return }
        var seen = Set<UUID>()
        for await jobs in TransferCenter.shared.$jobs.values {
            let mine = jobs.filter { ids.contains($0.id) }
            seen.formUnion(mine.map(\.id))
            if seen.count == ids.count && mine.count < ids.count {  // taken off the Transfers list meanwhile
                throw AirSCPError(.cancelled, "A download was taken off the Transfers list before it was done.")
            }
            guard mine.count == ids.count, mine.allSatisfy({ $0.status.isFinished && $0.checksum != .wanted && $0.checksum != .checking })
            else { continue }
            if let job = mine.first(where: { TransferText.problem($0) != nil || $0.status != .done }) {
                throw TransferText.problem(job) ?? AirSCPError(.cancelled, "The download of “\(TransferText.name(job))” was cancelled.")
            }
            return
        }
    }

    /// The Files app's Save or the share sheet, over the tray.
    private func show(_ controller: UIViewController) {
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
        guard var top = scene?.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController { top = presented }
        controller.popoverPresentationController?.sourceView = top.view  // iPad: from the middle of the screen
        controller.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: top.view.bounds.midY, width: 0, height: 0)
        top.present(controller, animated: true)
    }
}
