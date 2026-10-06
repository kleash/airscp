import AppKit
import Combine
import SwiftUI
import Foundation
import Testing
@testable import AirSCP
@testable import AirSCPCore

// Regression tests for the findings of the first break-it round in the app (Files tab, sheets, panels, RDP view).

@MainActor
private func offscreen(_ controller: NSViewController, width: CGFloat = 900, height: CGFloat = 500) -> NSWindow {
    UserDefaults.standard.register(defaults: ["NSWindowResizeTime": 0.001])
    let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: width, height: height), styleMask: [.titled],
                          backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    return window
}

@MainActor
private func allViews<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
    guard let view else { return [] }
    return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { allViews(type, in: $0) }
}

/// An empty server folder's hint ("Empty folder. Drag files here…") was one line wider than a pane of the default window,
/// cut off at both ends: it wraps within the pane.
@MainActor @Test func anEmptyFoldersHintFitsItsPane() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        let session = try await server.connectedSession()
        try rawMkdir(server.path("empty"))
        let pane = FilePane(source: .remote(session), choosesSource: false, showHidden: false)
        let window = offscreen(pane, width: 300, height: 400)
        defer { window.close() }
        #expect(await pane.open(server.path("empty")))
        pane.view.layoutSubtreeIfNeeded()
        let hint = try #require(allViews(NSTextField.self, in: pane.view).first { $0.stringValue.hasPrefix("Empty folder.") })
        let frame = hint.convert(hint.bounds, to: pane.view)
        #expect(!hint.isHidden && frame.minX >= 0 && frame.maxX <= pane.view.bounds.width, "\(frame) in \(pane.view.bounds)")
        #expect(frame.height > 2 * (hint.font?.pointSize ?? 13), "\(frame)")  // more than one line
    }
}

/// Copies were not asked about two names they would collide with: one that a queued or running transfer puts there (the
/// copy ran to its end, then failed), and one with a line break on the server (ls prints it on two lines, so no listing
/// has it: the upload replaced it).
@MainActor @Test func namesThatTransfersOrLineBreaksHideAreAskedAbout() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        let session = try await server.connectedSession()
        let browser = BrowserContentController(workspace: nil, session: session)
        let window = offscreen(browser)
        defer { window.close() }
        browser.stateChanged(session.state)
        #expect(await eventually { browser.right.dir == server.home })
        let local = try server.scratch()
        try write(String(repeating: "x", count: 300_000), to: local + "/x.bin")
        try rawCreate(local + "/new\nline.txt", "mine")
        try rawCreate(server.path("new\nline.txt"), "theirs")
        session.transfers.bandwidthLimit = 64  // Kbit/s: x.bin is still queued behind y.bin when the second copy is planned
        defer { session.transfers.bandwidthLimit = nil }
        session.transfers.upload(local + "/x.bin", to: server.path("y.bin"), isFolder: false)
        session.transfers.upload(local + "/x.bin", to: server.path("x.bin"), isFolder: false)
        for (name, line) in [("x.bin", "A transfer that is queued or running puts an item of that name there."),
                             ("new\nline.txt", "Replace it, keep both")] {
            let item = try #require(FileList.localItem(local + "/" + name))
            browser.transfer([item], from: .local, to: .remote(session), into: server.home, move: false)
            #expect(await eventually { window.attachedSheet != nil }, "\(name)")
            let sheet = try #require(window.attachedSheet)
            let texts = allViews(NSTextField.self, in: sheet.contentView).map(\.stringValue)
            #expect(texts.contains { $0.contains("already exists") } && texts.contains { $0.contains(line) }, "\(texts)")
            window.endSheet(sheet, returnCode: .cancel)
            #expect(await eventually { window.attachedSheet == nil && browser.planning == 0 })
        }
        #expect(session.transfers.jobs.count == 2 && read(server.path("new\nline.txt")) == "theirs")
        await session.transfers.cancelAll()
    }
}

/// Dragging many server items to Finder: each promise waits for its download, one at a time, so they can't use up the
/// threads that a stream finishing meanwhile needs (64 waiting promises froze the queue and the app for good).
@MainActor @Test func manyFilePromisesDontStarveTheApp() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        let session = try await server.connectedSession()
        let home = server.home
        try await Task.detached {  // not on the main thread, which every test's deliveries need
            try rawMkdir(home + "/bigdir")
            for index in 0..<300 { try writeRandom(bytes: 20_000, to: home + "/bigdir/f\(index)") }
            for index in 0..<70 { try write("file \(index)", to: home + "/small-\(index).txt") }
        }.value
        let pane = FilePane(source: .remote(session), choosesSource: false, showHidden: false)
        _ = pane.view
        #expect(await pane.open(server.home))
        let drop = try server.scratch()
        let folder = session.transfers.download(server.path("bigdir"), to: drop + "/bigdir", isFolder: true)
        let done = Recorder<String>()
        for row in pane.rows.indices where pane.rows[row].name.hasPrefix("small-") {
            let provider = try #require(pane.tableView(pane.table, pasteboardWriterForRow: row) as? NSFilePromiseProvider)
            let destination = URL(fileURLWithPath: drop + "/" + pane.rows[row].name)
            // As AppKit does: on the queue the pane names for the promise.
            pane.operationQueue(for: provider).addOperation {
                pane.filePromiseProvider(provider, writePromiseTo: destination) { error in done.append(error.map { "\($0)" } ?? "ok") }
            }
        }
        #expect(await eventually(timeout: 120) { done.all.count == 70 }, "\(done.all.count) of 70 promises kept")
        #expect(done.all.allSatisfy { $0 == "ok" })
        #expect(session.transfers.jobs.first { $0.id == folder }?.status == .done)
        #expect(names(in: drop + "/bigdir").count == 300)
        // The app's other work still gets threads.
        let probe = Recorder<Bool>()
        DispatchQueue.global().async { probe.append(true) }
        #expect(await eventually(timeout: 2) { !probe.all.isEmpty })
    }
}

/// Finished transfers list their folder again once their host's queue is done, not once per job: 30 uploads into the
/// folder a pane shows list it about once.
@MainActor @Test func aBatchOfUploadsListsTheFolderOnce() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        let session = try await server.connectedSession()
        let local = try server.scratch()
        for index in 0..<30 { try write("\(index)", to: local + "/u\(index).txt") }
        let browser = BrowserContentController(workspace: nil, session: session)
        let window = offscreen(browser)
        defer { window.close() }
        browser.stateChanged(session.state)
        #expect(await eventually { browser.right.dir == server.home })
        try await Task.sleep(nanoseconds: 500_000_000)
        let listingsBefore = (await server.logEntries()).filter { $0.command.contains("ls -lan") }.count
        for index in 0..<30 { session.transfers.upload(local + "/u\(index).txt", to: server.path("u\(index).txt"), isFolder: false) }
        await session.transfers.waitUntilIdle()
        #expect(await eventually { browser.right.rows.count == 30 })
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let listings = (await server.logEntries()).filter { $0.command.contains("ls -lan") }.count - listingsBefore
        #expect(listings <= 3, "\(listings) listings for 30 uploads")
    }
}

/// Run Command shows the end of a huge output (the last thousand lines), worked out once: tens of thousands of lines in
/// one text view froze the whole app for minutes.
@MainActor @Test func runCommandShowsTheEndOfAHugeOutput() async throws {
    let lines = (1...60_000).map { "line \($0)" }.joined(separator: "\n")
    let shown = RunCommandModel.tail(lines)
    #expect(shown.hasPrefix("… (") && shown.contains("lines before these aren't shown") && shown.hasSuffix("line 60000"))
    #expect(shown.split(separator: "\n").count == 1001)
    #expect(RunCommandModel.tail("short\noutput") == "short\noutput")
    let oneLine = String(repeating: "x", count: 200_000)
    #expect(RunCommandModel.tail(oneLine).utf8.count < 70_000)

    _ = NSApplication.shared
    try await withServer { @MainActor server in
        let host = server.host()
        let model = testModel([host])
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let connection = HostConnection(host: host, model: model, askpass: askpass)
        try await connection.connect()
        let runner = RunCommandModel(connection: connection, command: "yes | head -n 60000")
        runner.run()
        #expect(await eventually { runner.result != nil })
        let view = NSHostingView(rootView: RunCommandView(model: runner, app: model, runInTerminal: { _ in }, close: {}))
        let window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 640, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        let start = Date()
        view.layoutSubtreeIfNeeded()
        view.display()
        let took = Date().timeIntervalSince(start)
        print("PERF Run Command output of 60 000 lines laid out in \(String(format: "%.2f", took)) s")
        #expect(took < 3, "\(took) s")
        window.close()

        // A command shows what it prints while it runs, and Stop keeps it (the sheet showed "Running…", then only
        // "Stopped.", and Run… on a file the same).
        let slow = RunCommandModel(connection: connection, command: "echo started-xyz; echo err-xyz >&2; sleep 30")
        slow.run()
        #expect(await eventually { slow.running && slow.shown.output.contains("started-xyz") && slow.shown.errors.contains("err-xyz") },
                "\(slow.shown)")
        #expect(!slow.shown.errors.contains(RemotePID.marker))
        slow.stop()
        #expect(await eventually { !slow.running })
        #expect(slow.failure == "Stopped." && slow.shown.output == "started-xyz\n" && slow.shown.errors.hasSuffix("err-xyz\n"),
                "\(slow.shown)")

        // File ▸ Run…'s own command runs in sh, not in the login shell (zsh here), whose quoting rules may differ.
        let file = RunCommandModel(connection: connection, command: "echo $0", sh: true)
        file.run()
        #expect(await eventually { file.result != nil })
        #expect(file.result?.output == "sh\n", "\(String(describing: file.result))")
        await connection.disconnect()
    }
}

/// The command log and the Transfers panel are taken away while hidden (a SwiftUI list off screen is still worked on
/// for every change), and the log updates at most four times a second.
@MainActor @Test func hiddenPanelsCostNothing() async throws {
    _ = NSApplication.shared
    let log = CommandLog()
    var changes = 0
    let subscription = log.objectWillChange.sink { changes += 1 }
    for index in 0..<500 {
        log.append(LogEntry(date: Date(), hostID: nil, command: "scp \(index)", status: 0, stderr: ""))
    }
    #expect(log.entries.count == 500)  // at once
    try await Task.sleep(nanoseconds: 600_000_000)
    #expect(changes <= 2, "\(changes) redraws for 500 commands")
    subscription.cancel()

    let host = SSHHost(label: "h", hostname: "h")
    let model = testModel([host])
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let workspace = HostWorkspace(connection: HostConnection(host: host, model: model, askpass: askpass), model: model, main: nil)
    _ = workspace.view
    workspace.toggleCommandLog()
    #expect(workspace.showsCommandLog && allViews(NSHostingView<CommandLogView>.self, in: workspace.view).count == 1)
    workspace.toggleCommandLog()
    #expect(!workspace.showsCommandLog && allViews(NSHostingView<CommandLogView>.self, in: workspace.view).isEmpty)

    let detail = DetailController(model: model)
    _ = detail.view
    #expect(detail.showsTransfers && allViews(NSHostingView<TransfersPanel>.self, in: detail.view).count == 1)
    detail.toggleTransfers()
    #expect(!detail.showsTransfers && allViews(NSHostingView<TransfersPanel>.self, in: detail.view).isEmpty)
    detail.toggleTransfers()
    #expect(detail.showsTransfers && allViews(NSHostingView<TransfersPanel>.self, in: detail.view).count == 1)
}

/// In a small window the Transfers panel gives way first (down to 90 points, a few rows): at the window's minimum it
/// kept its own height and left the panes three rows each. A window that grows again gives it back its height.
@MainActor @Test func theTransfersPanelGivesWayInASmallWindow() throws {
    _ = NSApplication.shared
    let detail = DetailController(model: testModel([]))
    let split = try #require(allViews(NSSplitView.self, in: detail.view).first)
    func heights(_ total: CGFloat) -> (workspace: CGFloat, queue: CGFloat) {
        detail.view.frame = NSRect(x: 0, y: 0, width: 800, height: total)
        detail.view.layoutSubtreeIfNeeded()
        return (split.subviews[0].frame.height, split.subviews[1].frame.height)
    }
    #expect(heights(647).queue == 150)  // the default window: its own height
    let small = heights(408)  // the window's minimum (460) without the toolbar
    #expect(small.queue == 90 && small.workspace > 310, "\(small)")
    #expect(heights(647).queue == 150)
}

/// While a sheet is up on the main window, ⌘1…⌘9 and the New… items do nothing (they would act on another host than
/// the one the sheet is about, or queue a sheet behind it).
@MainActor @Test func windowShortcutsWaitForASheet() throws {
    _ = NSApplication.shared
    let host = SSHHost(label: "h", hostname: "h")
    let model = testModel([host])
    model.states[host.id] = .connected
    defer { model.states = [:] }
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let delegate = AppDelegate()
    delegate.main = MainWindowController(model: model, askpass: askpass)
    delegate.main.window?.setFrame(NSRect(x: -20000, y: -20000, width: 1000, height: 640), display: false)
    let first = NSMenuItem(title: "", action: #selector(AppDelegate.selectConnected(_:)), keyEquivalent: "1")
    first.tag = 1
    let newHost = NSMenuItem(title: "New Host…", action: #selector(AppDelegate.newHost(_:)), keyEquivalent: "n")
    #expect(delegate.validateMenuItem(newHost))
    let alert = NSAlert()
    alert.messageText = "Delete “victim.txt” on “h”?"
    alert.beginSheetModal(for: delegate.main.window!)
    defer { delegate.main.window?.endSheet(alert.window) }
    #expect(!delegate.validateMenuItem(first) && !delegate.validateMenuItem(newHost))
}

/// Names: on a Windows server some can't be made; the selection is kept by exact bytes ("café" composed and decomposed
/// are two files on Linux); a server's case rules come from its probe.
@MainActor @Test func namesFollowTheServersRules() async throws {
    #expect(FileList.windowsNameProblem("Minutes 10:30.txt") != nil && FileList.windowsNameProblem("star*") != nil)
    #expect(FileList.windowsNameProblem("trail.") != nil && FileList.windowsNameProblem("trail ") != nil)
    #expect(FileList.windowsNameProblem("Résumé (final).docx") == nil)
    #expect(FileList.nameProblem("a:b", windows: true) != nil && FileList.nameProblem("a:b") == nil)

    func item(_ name: String) -> FileItem {
        FileItem(local: name, path: "/x/" + name, kind: .file, size: 0, modified: nil, mode: 0o644, owner: "", group: "")
    }
    let rows = [item("caf\u{E9}"), item("cafe\u{301}"), item("other")]
    #expect(FileList.indexes(of: ["caf\u{E9}"], in: rows) == IndexSet([0]))
    #expect(FileList.indexes(of: ["cafe\u{301}"], in: rows) == IndexSet([1]))
    #expect(FileList.indexes(of: ["caf\u{E9}", "cafe\u{301}"], in: rows) == IndexSet([0, 1]))  // both stay selected

    _ = NSApplication.shared
    try await withServer { @MainActor server in
        let session = try await server.connectedSession()
        // This sshd runs on a Mac, whose disk ignores case.
        #expect(session.capabilities.caseInsensitive && !session.capabilities.windows)
        let browser = BrowserContentController(workspace: nil, session: session)
        let window = offscreen(browser)
        defer { window.close() }
        browser.stateChanged(session.state)
        #expect(await eventually { browser.right.dir == server.home })
        #expect(browser.right.ignoresCase && !browser.right.isWindows)
        // The transfer buttons' accessibility labels are their titles, not their arrows' names ("Left", "Right").
        #expect(await eventually { browser.left.dir != nil })
        browser.left.updateStatus()
        browser.right.updateStatus()
        let buttons = allViews(NSButton.self, in: browser.view).filter { ["Upload", "Download"].contains($0.title) }
        #expect(buttons.count == 2 && buttons.allSatisfy { $0.accessibilityLabel() == $0.title })

        // A Windows server: items it can't store aren't uploaded.
        let local = try server.scratch()
        try write("notes", to: local + "/Minutes 10:30.txt")
        session.capabilities.windows = true
        browser.upload([URL(fileURLWithPath: local + "/Minutes 10:30.txt")], to: browser.right, into: server.home)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        #expect(session.transfers.jobs.isEmpty)
        // …and Unix permissions don't apply there: Windows' sftp answered chmod with success and changed nothing.
        for action in [#selector(FilePane.makeExecutable(_:)), #selector(FilePane.editPermissions(_:))] {
            let (enabled, reason) = browser.right.check(action, for: browser.right.rows)
            #expect(!enabled && reason?.contains("Windows server has no Unix permissions") == true)
        }
        session.capabilities.windows = false

        // An account without a shell can't paste a copy within its server (cp); it can move. Paste says so, not "Copy
        // items first" right after a copy.
        try write("x", to: server.path("x.txt"))
        await browser.right.reload()
        let row = try #require(browser.right.rows.first { $0.name == "x.txt" })
        browser.copyToClipboard([row], from: browser.right, cut: false)
        #expect(browser.pasteProblem(into: browser.right) == nil)
        session.capabilities.shell = false
        session.capabilities.noShellReason = "This account allows file transfers (sftp) only."
        #expect(browser.pasteProblem(into: browser.right)?.hasSuffix("Cut and Paste moves the items instead.") == true)
        browser.copyToClipboard([row], from: browser.right, cut: true)
        #expect(browser.pasteProblem(into: browser.right) == nil)
        session.capabilities.shell = true
        session.capabilities.noShellReason = nil
        // This Mac's files copied in AirSCP (or Finder) go to a server: not from one Mac folder to another.
        let mac = try #require(FileList.localItem(local + "/Minutes 10:30.txt"))
        browser.copyToClipboard([mac], from: browser.left, cut: false)
        #expect(browser.pasteProblem(into: browser.right) == nil)
        #expect(browser.pasteProblem(into: browser.left)?.contains("use Finder") == true)
        #expect(browser.left.check(#selector(FilePane.paste(_:)), for: []).1?.contains("use Finder") == true)
    }
}

/// ⌫ on this Mac's pane doesn't move anything to the Trash (⌘⌫ does, as in Finder); Delete keys pressed in Quick Look
/// aren't sent to the table. The transfer button's accessibility label is its title, not its arrow's name.
@MainActor @Test func localDeleteNeedsCommand() async throws {
    _ = NSApplication.shared
    let folder = try scratch()
    try write("keep", to: folder + "/keep.txt")
    let pane = FilePane(source: .local, choosesSource: false, showHidden: false)
    let window = offscreen(pane)
    defer { window.close() }
    #expect(await pane.open(folder))
    pane.table.selectRowIndexes(IndexSet([0]), byExtendingSelection: false)
    let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                  context: nil, characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}",
                                  isARepeat: false, keyCode: 51)!
    pane.table.keyDown(with: delete)
    try await Task.sleep(nanoseconds: 500_000_000)
    #expect(read(folder + "/keep.txt") == "keep")
    #expect(!pane.previewPanel(nil, handle: delete))
}

/// A pane's selection is worked out once per change: a menu validating its items with 45 000 rows selected doesn't take
/// a third of a second.
@MainActor @Test func menusWithAHugeSelectionAreQuick() async throws {
    _ = NSApplication.shared
    let folder = try scratch()
    try await Task.detached {  // not on the main thread, which every test's deliveries need
        for index in 0..<20_000 { try rawCreate(folder + "/f\(index)") }
    }.value
    let pane = FilePane(source: .local, choosesSource: false, showHidden: false)
    let window = offscreen(pane)
    defer { window.close() }
    #expect(await pane.open(folder))
    pane.table.selectAll(nil)
    #expect(pane.table.numberOfSelectedRows == 20_000)
    let actions: [Selector] = [#selector(FilePane.openItems(_:)), #selector(FilePane.copy(_:)), #selector(FilePane.renameItem(_:)),
                               #selector(FilePane.deleteItems(_:)), #selector(FilePane.getInfo(_:)), #selector(FilePane.quickLook(_:))]
    let start = Date()
    for _ in 0..<6 {
        for action in actions { _ = pane.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")) }
    }
    let took = Date().timeIntervalSince(start)
    print("PERF 36 menu validations with 20 000 selected: \(String(format: "%.3f", took)) s")
    #expect(took < 0.15, "\(took) s")
}

/// Files open in an editor or another app keep their host's workspace (they save and upload through it after a
/// reconnect), and carry on when Connect makes a new Session.
@MainActor @Test func openEditorsOutliveTheWorkspacesSession() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        let host = server.host()
        let model = testModel([host])
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let workspace = HostWorkspace(connection: HostConnection(host: host, model: model, askpass: askpass), model: model, main: nil)
        _ = workspace.view
        let session = try await workspace.connectedSession()
        try write("a=1\n", to: server.path("conf.txt"))
        let browser = workspace.browser!
        #expect(await eventually { browser.right.dir == server.home })
        let row = try #require(browser.right.rows.first { $0.name == "conf.txt" })
        browser.edit(row, on: session, from: browser.right)
        #expect(await eventually { browser.hasOpenFiles })
        await workspace.connection.disconnect()
        #expect(await eventually { workspace.connection.state == .idle })
        #expect(!workspace.isUnused)  // the main window keeps it

        // The host was edited: Connect makes a new Session, and the editor saves through it.
        model.updateHost(host.id) { $0.serverAliveInterval = 7 }
        _ = try await workspace.connectedSession()
        #expect(workspace.session !== session && workspace.browser !== browser && workspace.browser.hasOpenFiles)
        let editor = try #require(NSApp.windows.compactMap { $0.windowController as? RemoteEditor }.first { $0.path == server.path("conf.txt") })
        #expect(editor.session === workspace.session)
        let text = try #require(editor.window?.initialFirstResponder as? NSTextView)
        text.string = "a=2\n"
        editor.save(nil)
        #expect(await eventually { read(server.path("conf.txt")) == "a=2\n" })
        editor.window?.isDocumentEdited = false
        editor.close()
        await workspace.connection.disconnect()
    }
}

/// The RDP view's memory of Caps Lock follows the focus sync, so the next key doesn't toggle Windows' Caps Lock back.
@MainActor @Test func rdpFocusSyncsCapsLock() {
    let view = RDPDesktopView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
    view.session = RDPSession(target: RDPSession.Target(host: "127.0.0.1", port: 1, username: "u", password: ""))
    let caps = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: [.capsLock], timestamp: 0, windowNumber: 0,
                                context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: 57)!
    view.flagsChanged(with: caps)
    #expect(view.modifiers == [.capsLock])  // what the view last saw (Caps Lock on in another app, say)
    view.focusIn()
    #expect(view.modifiers == NSEvent.modifierFlags.intersection(.capsLock))
}
