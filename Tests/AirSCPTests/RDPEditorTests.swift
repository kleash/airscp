import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AirSCP
@testable import AirSCPCore

@Test func rdpDraftKeepsEverySettingOfAnEntry() {
    var entry = RDPEntry(label: "Office", hostname: "win.example", port: 3390, username: "me")
    entry.domain = "CORP"
    entry.display = .fixed(width: 1600, height: 900)
    entry.retinaScale = false
    entry.clipboard = false
    entry.cmdAsCtrl = false
    entry.shareFolder = false
    entry.sharedFolder = "/tmp/shared"
    entry.viaHostID = UUID()
    var copy = RDPEntry(id: entry.id)
    RDPDraft(entry).apply(to: &copy)
    #expect(copy == entry)
}

@Test func rdpDraftChecksWhatWasTyped() {
    var draft = RDPDraft(RDPEntry())
    #expect(draft.validationError == "Enter the Windows computer's address to begin.")
    draft.hostname = " win.example "
    #expect(draft.validationError == nil)
    draft.port = "70000"
    #expect(draft.validationError?.contains("port") == true)
    draft.port = "3389"
    draft.display = .fixed
    draft.width = "100"
    #expect(draft.validationError?.contains("200 to 8192") == true)
    draft.width = "1280"
    draft.height = "720"
    var entry = RDPEntry()
    draft.apply(to: &entry)
    #expect(entry.hostname == "win.example" && entry.display == .fixed(width: 1280, height: 720))
}

@MainActor
@Test func rdpEditorAndWorkspaceLayOut() {
    let model = AppModel(data: AirSCPData(), store: { _ in })
    let editor = NSHostingView(rootView: RDPEditorView(model: model, entry: RDPEntry(), isNew: true, sshSession: nil,
                                                       close: { _ in }))
    editor.layoutSubtreeIfNeeded()
    #expect(editor.fittingSize.width >= 500 && editor.fittingSize.height > 300)

    let entry = RDPEntry(label: "Office", hostname: "win.example")
    model.data.rdpEntries = [entry]
    let workspace = RDPWorkspaceController(entryID: entry.id, model: model) { _ in throw AirSCPError(.other, "no") }
    workspace.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
    workspace.view.layoutSubtreeIfNeeded()
    #expect(workspace.state == .idle)
}

/// The bar above the desktop is as high connecting as connected, whatever its status says: the desktop under it took
/// the 2.5 points of difference, and Windows laid out its desktop again after every connect (and would at each message
/// that wrapped). "Paste N Items to Mac…" writes its number as the snapshot's count (2021, not 2,021) and has an id.
@MainActor
@Test func rdpBarKeepsItsHeightAndNamesItsPasteButton() async throws {
    _ = NSApplication.shared
    let model = AppModel(data: AirSCPData(), store: { _ in })
    let actions = RDPBarActions(connect: {}, disconnect: {}, details: {}, ctrlAltDel: {}, fullScreen: {}, upload: {},
                                showSharedFolder: {}, pasteFiles: {}, cancelFetch: {})
    let bar = RDPBar()
    bar.name = "Office"
    let view = NSHostingView(rootView: RDPBarView(bar: bar, model: model, actions: actions))
    func height(_ state: RDPSession.State, message: String = "") -> CGFloat {
        bar.state = state
        bar.message = message
        view.layoutSubtreeIfNeeded()
        return view.fittingSize.height
    }
    let connecting = height(.connecting)
    bar.size = "1764 × 960"
    bar.sharing = true
    #expect(height(.connected) == connecting)
    #expect(height(.connected, message: "Copying 12 items to the shared folder… " + String(repeating: "a long name ", count: 30))
            == connecting)
    #expect(height(.idle) == connecting)

    bar.remoteFiles = (2021, 9_152_949)
    _ = height(.connected)
    // SwiftUI makes accessibility elements while agent control is on.
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let (main, agent, _) = try agentWindow(model, askpass)
    defer {
        agent.close()
        main.window?.orderOut(nil)
    }
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1100, height: 60), styleMask: [.titled],
                          backing: .buffered, defer: true)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.orderFrontRegardless()  // (off screen) SwiftUI makes accessibility elements for a window that is shown
    defer { window.orderOut(nil) }
    view.layoutSubtreeIfNeeded()
    #expect(await eventually {  // once SwiftUI has made the button's accessibility element
        AXNode.flatten(window).first { $0.id == "rdp.pasteItems" }?.title == "Paste 2021 Items to Mac…"
    }, "\(AXNode.flatten(window).map { "\($0.id) \($0.title)" })")
}

/// A warning about the Mac's clipboard (text over 1 MB) goes when the Mac copies something else, which Windows then
/// gets; the bar's other messages stay.
@MainActor
@Test func rdpClipboardWarningGoesWithTheNextCopy() {
    let model = AppModel(data: AirSCPData(), store: { _ in })
    let desktop = RDPWorkspaceController(entryID: UUID(), model: model) { _ in throw AirSCPError(.other, "no") }
    desktop.warnAboutClipboard("The Mac's clipboard text is over 1 MB: Windows doesn't get it.")
    desktop.clipboardChanged()
    #expect(desktop.bar.message == "")
    desktop.bar.message = "Pasted 3 items into “Downloads”."
    desktop.clipboardChanged()
    #expect(desktop.bar.message == "Pasted 3 items into “Downloads”.")
}

/// Test Connection through an SSH host that isn't connected connects it first, as Connect does; the host's questions
/// (here its password) are sheets on the editor, where they are seen, not queued behind it on the main window. (It said
/// "Connect “jump” first", which the editor's sheet kept anyone from doing.)
@MainActor
@Test func rdpTestConnectionConnectsItsSSHHost() async throws {
    _ = NSApplication.shared
    try await withServer(TestServer.Options(passwords: true)) { @MainActor server in
        var jump = server.host()
        jump.label = "jump"
        jump.auth = .password
        var entry = RDPEntry(label: "Office", hostname: "127.0.0.1", username: "me")
        entry.viaHostID = jump.id
        let model = testModel([jump])
        model.save(entry)
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let (main, agent, _) = try agentWindow(model, askpass)
        defer {
            agent.close()
            main.window?.orderOut(nil)
        }
        let window = try #require(main.window)
        main.edit(.rdp(entry.id))
        let editor = try #require(window.attachedSheet)
        #expect(await call(agent, "set", ["id": "rdpEditor.password", "value": "typed"]).error == nil)
        #expect(await call(agent, "press", ["title": "Test Connection"]).error == nil)
        // The SSH host's password question, on the editor.
        #expect(await eventually { editor.attachedSheet != nil }, "no question on the editor")
        let question = try #require(editor.attachedSheet)
        #expect(AXNode.flatten(question).contains { $0.id == "prompt.answer" })
        #expect(main.workspace(for: jump.id)?.session.state == .connecting)
        // Cancel ends the connect and the test, which says so.
        #expect(await call(agent, "press", ["title": "Cancel"]).error == nil)
        #expect(editor.attachedSheet == nil)
        @MainActor func texts() -> [String] {
            AXNode.flatten(editor).compactMap { node in (node.value as? String) ?? (node.title.isEmpty ? nil : node.title) }
        }
        #expect(await eventually {
            texts().contains("Cancelled.")
        }, "\(texts())")
        window.endSheet(editor)
    }
}

/// The editors' forms scroll on a short screen: with Advanced open the host and Remote Desktop editors (821 points)
/// ran off screens under about 860 points. A form that fits shows whole.
@MainActor
@Test func editorFormsScrollOnShortScreens() async throws {
    _ = NSApplication.shared
    let tall = NSHostingView(rootView: Form { ForEach(0..<60) { Text("Row \($0)") } }.scrollingOnShortScreens(screenHeight: 600))
    #expect(tall.fittingSize.height <= 340)
    let short = NSHostingView(rootView: Form { Text("One row") }.scrollingOnShortScreens(screenHeight: 600))
    #expect(short.fittingSize.height < 60)
    // Both editors' forms are in a scroll view (a screen can't be made short here).
    let model = testModel([])
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let (main, agent, _) = try agentWindow(model, askpass)
    defer {
        agent.close()
        main.window?.orderOut(nil)
    }
    let window = try #require(main.window)
    for (name, open) in [("host", { main.newHost() }), ("Remote Desktop", { main.newRemoteDesktop() })] as [(String, () -> Void)] {
        open()
        let sheet = try #require(window.attachedSheet, "\(name)")
        #expect(await eventually { AXNode.flatten(sheet).contains { $0.role == "scrollarea" } }, "\(name)")
        window.endSheet(sheet)
    }
}
