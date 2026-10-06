import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AirSCP
@testable import AirSCPCore

// Agent control's server (PLAN.md T): the socket's token and modes, the snapshot, menus with their reasons, SwiftUI
// sheets driven through their accessibility nodes, screenshots, waits, and a whole session against a throwaway sshd.
// The bridge's own tests (MCP framing, `--agent`) are in AgentBridgeTests.swift.

/// The tests' main windows, kept for the whole run (as the app keeps its own): a window freed while one of its sheets
/// still animates away makes AppKit crash later.
@MainActor var keptWindows: [MainWindowController] = []

/// The app's menu bar, made once (its File ▸ New… items need the app delegate, which tests don't have: they call the
/// window). View ▸ Enter Full Screen has the delegate as its target, which a menu item holds weakly: it is kept.
@MainActor func useAppMenuBar() {
    guard NSApp.mainMenu == nil else { return }
    let delegate = AppDelegate()
    keptDelegates.append(delegate)
    NSApp.mainMenu = delegate.mainMenu()
}

@MainActor var keptDelegates: [AppDelegate] = []

/// An off-screen main window under agent control, with its server's folder in the test's scratch space.
@MainActor
func agentWindow(_ model: AppModel, _ askpass: AskpassServer) throws -> (main: MainWindowController, server: AgentServer, dir: String) {
    useAppMenuBar()
    let main = MainWindowController(model: model, askpass: askpass)
    keptWindows.append(main)
    main.window?.setFrame(NSRect(x: -20000, y: -20000, width: 1000, height: 640), display: false)
    let dir = try scratch() + "/agent"
    // Only this test's window: other tests' windows and sheets share NSApp.
    return (main, try AgentServer(main: main, model: model, directory: URL(fileURLWithPath: dir), windows: { [] }), dir)
}

/// A tool's reply: its text as JSON, or the error text; and its image, if any.
struct Reply {
    var json: [String: Any] = [:]
    var error: String?
    var image: NSBitmapImageRep?

    subscript(key: String) -> Any? { json[key] }
}

@MainActor
func call(_ server: AgentServer, _ tool: String, _ arguments: [String: Any] = [:]) async -> Reply {
    let reply = await server.handle(tool, arguments)
    let content = reply["content"] as? [[String: Any]] ?? []
    var result = Reply()
    let text = content.first { $0["type"] as? String == "text" }?["text"] as? String ?? ""
    if reply["isError"] as? Bool == true {
        result.error = text
    } else {
        result.json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }
    if let data = (content.first { $0["type"] as? String == "image" }?["data"] as? String).flatMap({ Data(base64Encoded: $0) }) {
        result.image = NSBitmapImageRep(data: data)
    }
    return result
}

func sheet(_ reply: Reply) -> [String: Any]? { reply["sheet"] as? [String: Any] }

func titles(_ items: Any?) -> [String] {
    (items as? [[String: Any]] ?? []).compactMap { $0["title"] as? String }
}

func field(_ sheet: [String: Any]?, _ id: String) -> [String: Any]? {
    (sheet?["fields"] as? [[String: Any]])?.first { $0["id"] as? String == id }
}

// MARK: The socket

@MainActor @Test func agentSocketAnswersOnlyRequestsWithItsToken() async throws {
    _ = NSApplication.shared
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let (main, server, dir) = try agentWindow(testModel([SSHHost(label: "web", hostname: "web")]), askpass)
    defer { main.window?.orderOut(nil) }
    func mode(_ path: String) -> mode_t {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mode & 0o777 : 0
    }
    #expect(mode(dir) == 0o700 && mode(dir + "/sock") == 0o600 && mode(dir + "/token") == 0o600)
    let token = try String(contentsOfFile: dir + "/token", encoding: .utf8)
    #expect(token.count == 64 && token.allSatisfy(\.isHexDigit))
    #expect(DebugLog.redacted("token \(token)") == "(line left out: it held a password or token)")  // PLAN.md AE
    // The server answers on the main actor: the requests go from another thread.
    func exchange(_ request: [String: Any]) async -> [String: Any]? {
        await Task.detached { Askpass.exchange(request, socket: dir + "/sock") }.value
    }
    let wrong = (token.first == "0" ? "1" : "0") + token.dropFirst()  // one hex digit off
    #expect(await exchange(["tool": "snapshot", "arguments": [String: Any](), "token": wrong]) == nil)
    #expect(await exchange(["tool": "snapshot", "arguments": [String: Any]()]) == nil)
    let reply = try #require(await exchange(["tool": "snapshot", "arguments": ["include": ["sidebar"]], "token": token]))
    let text = try #require((reply["content"] as? [[String: Any]])?.first?["text"] as? String)
    #expect(reply["isError"] as? Bool == false && text.contains("\"name\":\"web\""))
    #expect(server.lastRequest != nil)

    // Turned off: nothing is left behind.
    server.close()
    #expect(!rawExists(dir + "/sock") && !rawExists(dir + "/token") && !rawExists(dir))
    #expect(await exchange(["tool": "snapshot", "arguments": [String: Any](), "token": token]) == nil)
}

// MARK: Snapshot and menus

@MainActor @Test func snapshotDescribesHostsGroupsProxiesAndDesktops() async throws {
    _ = NSApplication.shared
    let lab = HostGroup(name: "Lab")
    var web = SSHHost(label: "web", hostname: "web.example.com", username: "deploy")
    web.groupID = lab.id
    web.color = "green"
    let db = SSHHost(label: "db", hostname: "db", port: 2222)
    let model = testModel([web, db], groups: [lab])
    model.save(Proxy(name: "Office", host: "proxy", port: 3128, username: "me"))
    model.save(RDPEntry(label: "Windows", hostname: "win"))
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let (main, server, _) = try agentWindow(model, askpass)
    defer {
        server.close()
        main.window?.orderOut(nil)
    }

    // Nothing selected: Connect is off, and says why.
    var reply = await call(server, "snapshot", ["include": ["sidebar", "menus", "settings"]])
    let sidebar = try #require(reply["sidebar"] as? [String: Any])
    let sections = try #require(sidebar["sections"] as? [[String: Any]])
    #expect(sections.map { $0["group"] as? String ?? "" } == ["", "Lab"])
    let hosts = sections.flatMap { $0["hosts"] as? [[String: Any]] ?? [] }
    #expect(hosts.map { $0["name"] as? String } == ["db", "web"])
    #expect(hosts[0]["address"] as? String == "db:2222" && hosts[1]["address"] as? String == "deploy@web.example.com")
    #expect(hosts[1]["color"] as? String == "green" && hosts[1]["state"] as? String == "idle")
    #expect((sidebar["rdp"] as? [[String: Any]])?.first?["name"] as? String == "Windows")
    #expect(sidebar["proxies"] as? [String] == ["Office"])
    #expect(reply["selection"] is NSNull && (reply["settings"] as? [String: Any])?["agentControl"] as? Bool == false)
    let menus = try #require(reply["menus"] as? [[String: Any]])
    let connect = try #require(menus.first { $0["path"] as? String == "Host > Connect" })
    #expect(connect["enabled"] as? Bool == false && connect["shortcut"] as? String == "⌘K")
    #expect((connect["reason"] as? String)?.contains("Nothing is selected") == true)
    reply = await call(server, "menu", ["path": "Host > Connect"])
    #expect(reply.error?.contains("is disabled now: Nothing is selected in the sidebar") == true)
    #expect(await call(server, "menu", ["path": "Host > Teleport"]).error?.contains("There: Connect, Open Terminal") == true)

    // A host selected: its workspace and banner.
    reply = await call(server, "select", ["pane": "sidebar", "names": ["web"]])
    #expect((reply["selection"] as? [String: Any])?["name"] as? String == "web")
    reply = await call(server, "snapshot")
    let workspace = try #require(reply["workspace"] as? [String: Any])
    let banner = try #require(workspace["banner"] as? [String: Any])
    #expect(workspace["host"] as? String == "web" && workspace["tab"] as? String == "Files")
    #expect(banner["state"] as? String == "idle" && banner["text"] as? String == "Not connected. Connect to browse this host's files.")
    #expect(banner["buttons"] as? [String] == ["Connect"])
    #expect((reply["windows"] as? [[String: Any]])?.first?["title"] as? String == "web")
    reply = await call(server, "snapshot", ["include": ["menus"]])
    #expect((reply["menus"] as? [[String: Any]])?.first { $0["path"] as? String == "Host > Connect" }?["enabled"] as? Bool == true)
    // The Files tab's commands need a pane with the focus.
    let newFolder = (reply["menus"] as? [[String: Any]])?.first { $0["path"] as? String == "File > New Folder…" }
    #expect(newFolder?["enabled"] as? Bool == false)
    #expect((newFolder?["reason"] as? String)?.contains("focus pane=left or right") == true)

    // Tabs are pressed like the user clicks them.
    reply = await call(server, "press", ["title": "Monitor"])
    #expect(reply.error == nil && main.selectedWorkspace?.tabs.selectedTabViewItemIndex == 1)
    #expect(await call(server, "press", ["title": "Teleport"]).error?.contains("Nothing to press") == true)
}

// MARK: Sheets through their accessibility nodes

/// The day-0 spike's assertion, kept: SwiftUI's fields, pop-ups, checkboxes and buttons are reached in-process.
@MainActor @Test func hostEditorIsFilledInAndSavedThroughItsControls() async throws {
    _ = NSApplication.shared
    let bastion = SSHHost(label: "bastion", hostname: "bastion")
    let passwords = Passwords()
    let model = testModel([bastion], passwords: passwords)
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let (main, server, _) = try agentWindow(model, askpass)
    defer {
        server.close()
        main.window?.orderOut(nil)
    }

    #expect(await call(server, "menu", ["path": "File > New Host..."]).error?.contains("Nothing in AirSCP can do that") == true)
    main.newHost()  // the menu item's action is the app delegate's
    var reply = await call(server, "snapshot", ["include": ["sheets"]])
    var editor = try #require((reply["sheets"] as? [[String: Any]])?.first)
    let buttons = titles(editor["buttons"])
    #expect(editor["title"] as? String == "New Host" && buttons.contains("Add"))
    #expect(field(editor, "hostEditor.hostname")?["label"] as? String == "Address")
    // The window's elements have the sheet's controls once (the window's tree has its sheet already).
    let ids = (await call(server, "snapshot", ["include": ["elements"]])["elements"] as? [[String: Any]] ?? [])
        .compactMap { $0["id"] as? String }.filter { $0.hasPrefix("hostEditor.") }
    #expect(ids.contains("hostEditor.hostname") && ids.count == Set(ids).count, "\(ids)")
    for (id, value) in [("hostEditor.name", "chain target"), ("hostEditor.hostname", "target"), ("hostEditor.port", "22"),
                        ("hostEditor.username", "dev")] {
        reply = await call(server, "set", ["id": id, "value": value])
        #expect(reply.error == nil, "\(id): \(reply.error ?? "")")
    }
    #expect(await call(server, "set", ["id": "hostEditor.jump", "value": "bastion"]).error == nil)
    #expect(await call(server, "set", ["title": "Log in with", "value": "Password"]).error == nil)
    // The rarely needed fields are under Advanced (hidden for a new host): shown as a person shows them.
    #expect(await call(server, "set", ["id": "hostEditor.options", "value": "x=1"]).error?.contains("No field") == true)
    #expect(await call(server, "press", ["title": "Advanced"]).error == nil)
    #expect(await call(server, "set", ["title": "Password", "value": "s3cret"]).error == nil)
    #expect(await call(server, "set", ["id": "hostEditor.forwardAgent", "value": true]).error == nil)
    #expect(await call(server, "set", ["id": "hostEditor.options", "value": "Compression=yes"]).error == nil)
    #expect(await call(server, "set", ["id": "hostEditor.group", "value": "Nowhere"]).error?.contains("isn't one of the choices") == true)
    reply = await call(server, "snapshot", ["include": ["sheets"]])
    editor = try #require((reply["sheets"] as? [[String: Any]])?.first)
    #expect(field(editor, "hostEditor.password")?["value"] as? String == "•••(6)")  // never the password itself
    #expect(field(editor, "hostEditor.name")?["value"] as? String == "chain target")
    #expect(field(editor, "hostEditor.forwardAgent")?["value"] as? Int == 1)
    reply = await call(server, "press", ["title": "Add"])
    #expect(reply.error == nil && main.window?.attachedSheet == nil)
    let saved = try #require(model.data.hosts.first { $0.label == "chain target" })
    #expect(saved.hostname == "target" && saved.port == 22 && saved.username == "dev" && saved.auth == .password)
    #expect(saved.jumpHostID == bastion.id && saved.forwardAgent && saved.extraOptions == ["Compression=yes"])
    #expect(passwords.saved[saved.id.uuidString] == "s3cret" && main.sidebar.selection == .host(saved.id))

    // An AppKit alert: New Group asks for a name; Return presses its default button.
    main.newGroup()
    reply = await call(server, "wait", ["until": "sheet", "timeout": 2])
    #expect(reply["title"] as? String == "New Group" && field(reply.json, "prompt.name") != nil)
    let create = (reply["buttons"] as? [[String: Any]])?.first { $0["title"] as? String == "Create" }
    #expect(create?["default"] as? Bool == true)
    #expect(await call(server, "set", ["id": "prompt.name", "value": "Lab"]).error == nil)
    reply = await call(server, "key", ["combo": "return"])
    #expect(reply.error == nil && sheet(reply) == nil && model.data.groups.map(\.name) == ["Lab"])
}

// MARK: Screenshots and waits

@MainActor @Test func screenshotsArePNGsOfTheWindowWithItsSheets() async throws {
    _ = NSApplication.shared
    let model = testModel([SSHHost(label: "web", hostname: "web"), SSHHost(label: "db", hostname: "db.example.com")])
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let (main, server, _) = try agentWindow(model, askpass)
    defer {
        server.close()
        main.window?.orderOut(nil)
    }
    _ = await call(server, "select", ["pane": "sidebar", "names": ["web"]])
    let plain = try #require(await call(server, "screenshot").image)
    #expect(plain.pixelsWide == 1000 && plain.pixelsHigh == 640)
    // Not blank: the window's parts have different colours.
    let samples = stride(from: 5, to: 640, by: 45).flatMap { y in stride(from: 5, to: 1000, by: 45).map { (x: $0, y: y) } }
    #expect(Set(samples.compactMap { plain.colorAt(x: $0.x, y: $0.y)?.brightnessComponent }).count > 3)
    // The sidebar is drawn (Liquid Glass draws it outside the window's own views), its text in its colours: grey
    // pixels darker than the background in Light (text drawn through its vibrancy matrix, not black or missing).
    func sidebarText(_ image: NSBitmapImageRep, _ wanted: (NSColor) -> Bool) -> Int {
        stride(from: 45, to: 200, by: 1).flatMap { x in stride(from: 40, to: 300, by: 1).map { (x, $0) } }
            .compactMap { image.colorAt(x: $0.0, y: $0.1)?.usingColorSpace(.deviceRGB) }
            .filter { $0.saturationComponent < 0.25 && wanted($0) }.count
    }
    let appearance = main.window?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua])
    #expect(sidebarText(plain) { appearance == .darkAqua ? $0.brightnessComponent > 0.45 : $0.brightnessComponent < 0.75 } > 20)
    // Drawn as the key window, as it looks in use, though the tests never make AirSCP the active app (nor is it, behind
    // other apps or while the screen is locked): the close button is red, not an inactive window's grey.
    let corner = stride(from: 6, to: 44, by: 1).flatMap { x in
        stride(from: 6, to: 44, by: 1).compactMap { plain.colorAt(x: x, y: $0)?.usingColorSpace(.deviceRGB) }
    }
    #expect(corner.contains { $0.redComponent > 0.8 && $0.greenComponent < 0.5 && $0.blueComponent < 0.5 })

    // A sheet is composited where it is.
    main.newGroup()
    let withSheet = try #require(await call(server, "screenshot").image)
    #expect(withSheet.pixelsWide == 1000 && withSheet.tiffRepresentation != plain.tiffRepresentation)
    let sheetImage = try #require(await call(server, "screenshot", ["target": "sheet"]).image)
    let sheetWindow = try #require(main.window?.attachedSheet)
    #expect(sheetImage.pixelsWide == Int(sheetWindow.frame.width) && sheetImage.pixelsHigh == Int(sheetWindow.frame.height))
    let retina = try #require(await call(server, "screenshot", ["scale": 2]).image)
    #expect(retina.pixelsWide == 2000 && retina.pixelsHigh == 1280)
    // The whole window at twice the size, not the small one in a corner: the top right quarter is drawn too.
    let topRight = stride(from: 1010, to: 2000, by: 30).flatMap { x in stride(from: 5, to: 640, by: 30).map { (x: x, y: $0) } }
    #expect(Set(topRight.compactMap { retina.colorAt(x: $0.x, y: $0.y)?.brightnessComponent }.map { Int($0 * 20) }).count > 3)
    // An element at scale 2: the filter field, drawn (its border and placeholder), not a blank crop.
    let filter = try #require(await call(server, "screenshot", ["target": "element:right.filter", "scale": 2]).image)
    let inside = stride(from: 0, to: filter.pixelsWide, by: 3).flatMap { x in stride(from: 0, to: filter.pixelsHigh, by: 3).map { (x: x, y: $0) } }
    #expect(filter.pixelsHigh > 30 && Set(inside.compactMap { filter.colorAt(x: $0.x, y: $0.y)?.brightnessComponent }.map { Int($0 * 20) }).count > 2)
    #expect(await call(server, "screenshot", ["target": "rdp"]).error?.contains("No Remote Desktop") == true)
    _ = await call(server, "press", ["title": "Cancel"])

    // Dark: the title bar is the window's dark ground (Night Harbor's, a little lighter than the content) with the
    // light title on it, not see-through.
    main.window?.appearance = NSAppearance(named: .darkAqua)
    defer { main.window?.appearance = nil }
    try await Task.sleep(nanoseconds: 400_000_000)  // the title bar takes the new appearance as it redraws
    let dark = try #require(await call(server, "screenshot").image)
    let titlebar = stride(from: 230, to: 470, by: 2).flatMap { x in stride(from: 4, to: 46, by: 2).compactMap { dark.colorAt(x: x, y: $0) } }
    #expect(titlebar.allSatisfy { $0.alphaComponent > 0.99 })
    #expect(titlebar.filter { $0.brightnessComponent < 0.3 }.count > titlebar.count / 2 && titlebar.contains { $0.brightnessComponent > 0.5 })
    // The sidebar's text is light on the dark sidebar, not black (the vibrancy matrix the window server applies).
    #expect(sidebarText(dark) { $0.brightnessComponent > 0.45 } > 20)
}

@MainActor @Test func waitsReturnWhatTheyWaitedForOrTheStateAtTheTimeout() async throws {
    _ = NSApplication.shared
    let model = testModel([SSHHost(label: "web", hostname: "web")])
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let (main, server, _) = try agentWindow(model, askpass)
    defer {
        server.close()
        main.window?.orderOut(nil)
    }
    var reply = await call(server, "wait", ["until": "sheet", "timeout": 0.3])
    #expect(reply.error?.hasPrefix("Timed out after 0 s waiting for sheet. Now: {") == true)
    #expect(reply.error?.contains("\"connected\":[]") == true && reply.error?.contains("\"rows\"") == false)
    // A host that isn't connecting at all: no use waiting the whole timeout.
    #expect(await call(server, "wait", ["until": "connected", "host": "web"]).error?.contains("isn't connecting") == true)
    #expect(await call(server, "wait", ["until": "connected", "host": "nobody"]).error?.contains("No host") == true)
    #expect(await call(server, "wait", ["until": "transfers_done", "timeout": 1]).error == nil)
    reply = await call(server, "wait", ["until": "no_sheet", "timeout": 1])
    #expect(reply.error == nil)

    main.newGroup()
    reply = await call(server, "wait", ["until": "sheet", "text": "group", "timeout": 1])
    #expect(reply["title"] as? String == "New Group")
    #expect(await call(server, "wait", ["until": "no_sheet", "timeout": 0.3]).error?.hasPrefix("Timed out") == true)
    // What a field holds isn't what the sheet says (a command typed in Run Command isn't its output); its id is.
    _ = await call(server, "set", ["id": "prompt.name", "value": "Exit status report"])
    #expect(await call(server, "wait", ["until": "sheet", "text": "Exit status", "timeout": 0.3]).error?.hasPrefix("Timed out") == true)
    #expect(await call(server, "wait", ["until": "sheet", "text": "prompt.name", "timeout": 1]).error == nil)
    // The sidebar's selection stays while a sheet is open (the sheet belongs to the host shown), as for a person.
    #expect(await call(server, "select", ["pane": "sidebar", "names": ["web"]]).error?.hasPrefix("A sheet is open") == true)
    _ = await call(server, "key", ["combo": "escape"])
    #expect(await call(server, "wait", ["until": "no_sheet", "timeout": 2]).error == nil && model.data.groups.isEmpty)
}

// MARK: Other windows: menus, keys and lists there

/// Commands and keys go to the window named by `in` (an editor's File > Close, ⌘W, Select All), lists in other windows
/// and in sheets are selected and their rows read, and Quick Look (a panel an agent can't close) is refused.
@MainActor @Test func agentWorksInOtherWindowsAndTheirLists() async throws {
    _ = NSApplication.shared
    useAppMenuBar()
    let local = try scratch()
    try write("hello\n", to: local + "/a.txt")
    var web = SSHHost(label: "web", hostname: "web")
    web.lastLocalDir = local
    let model = testModel([web])
    model.save(Proxy(name: "Office", host: "proxy", port: 3128))
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    // An editor-like window, and the Keys window's list (of a scratch folder: never ~/.ssh).
    let notes = NSWindow(contentRect: NSRect(x: -21000, y: -21000, width: 300, height: 200), styleMask: [.titled, .closable],
                         backing: .buffered, defer: false)
    notes.title = "notes.txt — web"
    notes.isReleasedWhenClosed = false
    let text = NSTextView(frame: notes.contentLayoutRect)
    text.string = "first line\nsecond line"
    notes.contentView = text
    let folder = try scratch()
    _ = await Runner.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "agent test", "-f", folder + "/id_agent"])
    let keys = KeysModel(folder: folder, askpass: [:])
    await keys.refresh()
    let keysWindow = NSWindow(contentRect: NSRect(x: -21000, y: -21500, width: 780, height: 400), styleMask: [.titled],
                              backing: .buffered, defer: false)
    keysWindow.title = "Keys"
    keysWindow.isReleasedWhenClosed = false
    keysWindow.contentView = NSHostingView(rootView: KeysView(keys: keys, model: model, install: { _, _ in }, report: { _, _ in }))
    let main = MainWindowController(model: model, askpass: askpass)
    main.window?.setFrame(NSRect(x: -20000, y: -20000, width: 1000, height: 640), display: false)
    let server = try AgentServer(main: main, model: model, directory: URL(fileURLWithPath: try scratch() + "/agent"),
                                 windows: { [notes, keysWindow].filter(\.isVisible) })
    defer {
        server.close()
        [notes, keysWindow].forEach { $0.orderOut(nil) }
        main.window?.orderOut(nil)
    }
    main.window?.orderFront(nil)
    notes.orderFront(nil)
    keysWindow.orderFront(nil)

    // set keeps a leading byte order mark (the editor saves byte for byte; inserting as typed dropped it).
    text.setAccessibilityIdentifier("editor.text")
    #expect(await call(server, "set", ["id": "editor.text", "value": "\u{FEFF}port=80\n", "in": "window:notes.txt"]).error == nil)
    #expect(text.string.unicodeScalars.first == "\u{FEFF}" && text.string.hasSuffix("port=80\n"))
    // JSON can't bring a leading byte order mark (Foundation drops it): the text's own stays.
    #expect(await call(server, "set", ["id": "editor.text", "value": "port=81\n", "in": "window:notes.txt"]).error == nil)
    #expect(text.string == "\u{FEFF}port=81\n")
    // A sheet covers its window: in=window:<title> reaches the sheet, not the text under it (a person can't either).
    let question = NSAlert()
    question.messageText = "Revert to the saved text?"
    question.addButton(withTitle: "Revert").toolTip = "Throw away the changes"
    question.addButton(withTitle: "Cancel").toolTip = "Keep them"
    question.beginSheetModal(for: notes) { _ in }
    let covered = await call(server, "set", ["id": "editor.text", "value": "x", "in": "window:notes.txt"])
    #expect(covered.error?.contains("Revert to the saved text?") == true && text.string == "\u{FEFF}port=81\n", "\(covered.error ?? "")")
    // The sheets section names what each button does, as the elements section does.
    let sheets = (await call(server, "snapshot", ["include": ["sheets"]]))["sheets"] as? [[String: Any]]
    let revert = (sheets?.first { $0["title"] as? String == "Revert to the saved text?" }?["buttons"] as? [[String: Any]])?
        .first { $0["title"] as? String == "Revert" }
    #expect(revert?["help"] as? String == "Throw away the changes", "\(String(describing: sheets))")
    notes.endSheet(question.window)
    text.string = "first line\nsecond line"

    // Edit > Select All and File > Close of the editor, not of the main window and its panes.
    #expect(await call(server, "menu", ["path": "Edit > Select All", "in": "window:notes.txt"]).error == nil)
    #expect(text.selectedRange() == NSRange(location: 0, length: (text.string as NSString).length))
    #expect(await call(server, "key", ["combo": "cmd+w", "in": "window:notes.txt"]).error == nil)
    #expect(!notes.isVisible && main.window?.isVisible != false)
    #expect(await call(server, "menu", ["path": "File > Close", "in": "window:nothing"]).error?.contains("No window") == true)

    // The Keys window's list: its rows in the window's elements, a key selected, and its buttons then on.
    var reply = await call(server, "snapshot", ["include": ["elements"], "in": "window:Keys"])
    let elements = try #require(reply["elements"] as? [[String: Any]])
    #expect(elements.contains { $0["value"] as? String == "id_agent" } && elements.contains { $0["value"] as? String == "agent test" })
    #expect(elements.first { $0["title"] as? String == "Install on Host…" }?["enabled"] as? Bool == false)
    reply = await call(server, "select", ["in": "window:Keys", "names": ["id_agent"]])
    #expect(reply["selected"] as? Int == 1 && keys.selection == folder + "/id_agent", "\(reply.json) \(reply.error ?? "")")
    reply = await call(server, "snapshot", ["include": ["elements"], "in": "window:Keys"])
    let buttons = (reply["elements"] as? [[String: Any]] ?? []).filter { $0["role"] as? String == "button" }
    #expect(buttons.first { $0["title"] as? String == "Install on Host…" }?["enabled"] as? Bool == true)
    #expect(buttons.first { $0["title"] as? String == "Add to Agent" }?["enabled"] as? Bool == true)
    #expect(await call(server, "select", ["in": "window:Keys", "names": ["nothing"]]).error?.contains("No list") == true)

    // A list in a sheet: the Proxies sheet's proxy, then Edit… opens its editor.
    main.showProxies()
    #expect(await call(server, "press", ["title": "Edit…"]).error?.contains("disabled") == true)
    #expect(await call(server, "select", ["in": "sheet", "names": ["Office"]]).error == nil)
    reply = await call(server, "press", ["title": "Edit…"])
    #expect(reply.error == nil)
    reply = await call(server, "wait", ["until": "sheet", "text": "proxyEditor.host", "timeout": 2])
    #expect(field(reply.json, "proxyEditor.host")?["value"] as? String == "proxy", "\(reply.json) \(reply.error ?? "")")
    _ = await call(server, "press", ["title": "Cancel"])
    _ = await call(server, "press", ["title": "Done"])
    #expect(await call(server, "wait", ["until": "no_sheet", "timeout": 2]).error == nil)

    // Import from ~/.ssh/config: an alias's checkbox by the alias (its title goes on with what ssh makes of it).
    let importer = ConfigImport(aliases: ["labalias", "other"], model: model)
    presentSheet(on: try #require(main.window)) { close in ConfigImportView(importer: importer, importChosen: { _ in }, close: close) }
    #expect(await call(server, "set", ["title": "labalias", "value": false]).error == nil)
    #expect(importer.chosen == ["other"])
    _ = await call(server, "press", ["title": "Cancel"])
    #expect(await call(server, "wait", ["until": "no_sheet", "timeout": 2]).error == nil)

    // Quick Look's panel would stay on the user's screen, unseen and unclosable by the agent: refused.
    keysWindow.orderOut(nil)
    _ = await call(server, "select", ["pane": "sidebar", "names": ["web"]])
    #expect(await eventually { main.selectedWorkspace?.browser.left.rows.contains { $0.name == "a.txt" } == true })
    _ = await call(server, "select", ["pane": "left", "names": ["a.txt"]])
    #expect(await call(server, "menu", ["path": "File > Quick Look"]).error?.contains("Quick Look is for a person") == true)
    #expect(await call(server, "key", ["combo": "space"]).error?.contains("Quick Look is for a person") == true)
    #expect(await call(server, "menu", ["path": "context > Quick Look", "pane": "left"]).error?.contains("Quick Look is for a person") == true)
}

/// Keys and text for the Windows desktop lend it the focus for the request only: the Mac's clipboard is offered to
/// Windows then, and its watch stops again, rather than going on while the user works in other apps.
@MainActor @Test func theDesktopHasTheFocusOnlyWhileAnAgentActs() async throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 400, height: 300), styleMask: [.titled],
                          backing: .buffered, defer: false)
    let desktop = RDPDesktopView(frame: window.contentLayoutRect)
    window.contentView = desktop
    var focus: [Bool] = []
    desktop.onFocus = { focus.append($0) }
    let reply = try await AgentServer.lendingFocus(to: desktop) {
        #expect(focus == [true])
        return ["ok": true]
    }
    #expect(reply["ok"] as? Bool == true && focus == [true, false])
    await #expect(throws: AgentServer.Failure.self) {
        _ = try await AgentServer.lendingFocus(to: desktop) { throw AgentServer.Failure("no") }
    }
    #expect(focus == [true, false, true, false])
}

/// One coordinate space for the Windows desktop (1.0.0: an agent's clicks landed hundreds of pixels away, or outside
/// the desktop, when it clicked what it saw in screenshot target=rdp): click with target rdp takes that picture's
/// pixels as they are, whatever the view makes of them (Retina, a desktop scaled to fit with bars, a fixed size, full
/// screen in a window of its own), while window points still go through the view.
@MainActor @Test func desktopClicksTakeThePicturesOwnPixels() throws {
    _ = NSApplication.shared
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 882, height: 453), styleMask: [.titled],
                          backing: .buffered, defer: false)
    let desktop = RDPDesktopView(frame: window.contentLayoutRect)
    window.contentView = desktop
    /// Where a click at view points (x, y from the top left) lands on the desktop.
    func landing(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        desktop.desktopPoint(atWindowPoint: desktop.convert(NSPoint(x: x, y: desktop.bounds.height - y), to: nil))
    }
    func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) <= 1 && abs(a.y - b.y) <= 1 }
    // (desktop size, a pixel of its picture, the view point showing that pixel)
    let modes: [(String, CGSize, CGPoint, CGPoint)] = [
        ("Retina, fit", CGSize(width: 1764, height: 906), CGPoint(x: 912, y: 858), CGPoint(x: 456, y: 429)),
        // 1×, fit: Windows' smallest height (480) is taller than the view, so it is scaled down with bars at the sides.
        ("1×, fit", CGSize(width: 882, height: 480), CGPoint(x: 279, y: 456), CGPoint(x: 25 + 279 * 0.94375, y: 456 * 0.94375)),
        ("fixed 1280 × 800", CGSize(width: 1280, height: 800), CGPoint(x: 396, y: 776),
         CGPoint(x: 78.6 + 396 * 0.56625, y: 776 * 0.56625)),
    ]
    for (mode, size, pixel, viewPoint) in modes {
        desktop.desktopSize = size
        // target rdp: the picture's pixel itself, nothing converted.
        #expect(try AgentServer.desktopPixel(x: pixel.x, y: pixel.y, size: size) == pixel, "\(mode)")
        #expect(try AgentServer.desktopPixel(x: pixel.x + 0.7, y: pixel.y + 0.2, size: size) == pixel, "\(mode)")
        // The same numbers as window points land elsewhere (or, past the view, not on the desktop at all).
        #expect(!near(landing(pixel.x, pixel.y), pixel), "\(mode)")
        // Window points go through the view: its scale and its bars.
        #expect(near(landing(viewPoint.x, viewPoint.y), pixel), "\(mode): \(landing(viewPoint.x, viewPoint.y))")
    }
    // A bar beside a desktop scaled to fit is no part of it: a click there lands on its edge.
    desktop.desktopSize = CGSize(width: 882, height: 480)
    #expect(landing(10, 200).x == 0)
    // Full screen moves the view into a window of its own, the screen's size: the main window's points don't reach it
    // any more; the picture's pixels are the same as ever.
    let fullScreen = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1728, height: 1117), styleMask: [.borderless],
                              backing: .buffered, defer: false)
    window.contentView = NSView()
    fullScreen.contentView = desktop
    desktop.desktopSize = CGSize(width: 3456, height: 2234)
    #expect(window.contentView?.hitTest(NSPoint(x: 400, y: 200)) as? RDPDesktopView == nil)
    #expect(near(landing(850, 1100), CGPoint(x: 1700, y: 2200)))
    #expect(try AgentServer.desktopPixel(x: 1700, y: 2200, size: desktop.desktopSize) == CGPoint(x: 1700, y: 2200))

    // Outside the picture: refused, with its size.
    for (x, y) in [(-1.0, 10.0), (10, -0.5), (1764, 10), (10, 906)] {
        #expect(throws: AgentServer.Failure.self) { try AgentServer.desktopPixel(x: x, y: y, size: CGSize(width: 1764, height: 906)) }
    }
    do {
        _ = try AgentServer.desktopPixel(x: 1764, y: 1000, size: CGSize(width: 1764, height: 906))
    } catch let failure as AgentServer.Failure {
        #expect(failure.message.contains("1764 × 906"))
    }
}

/// A click on the Windows desktop shows the agent what it hit: 200 × 120 pixels around the point (less at an edge),
/// zoomed 2× without smoothing, with a red cross whose middle leaves the clicked pixel itself to be seen.
@MainActor @Test func aDesktopClicksPictureShowsWhereItLanded() throws {
    // A desktop of 400 × 300 pixels: grey, one blue pixel at (250, 100).
    let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let frame = try #require(CGContext(data: nil, width: 400, height: 300, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                       bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
    frame.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
    frame.fill(CGRect(x: 0, y: 0, width: 400, height: 300))
    frame.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
    frame.fill(CGRect(x: 250, y: 300 - 100 - 1, width: 1, height: 1))  // the context's origin is at the bottom left
    let image = try #require(frame.makeImage())
    func color(_ picture: NSBitmapImageRep, _ x: Int, _ y: Int) -> [Int] {
        let c = picture.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
        return [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
    }
    let source = NSBitmapImageRep(cgImage: image)
    let grey = color(source, 0, 0), blue = color(source, 250, 100)
    #expect(blue != grey && blue[2] > 200)

    let middle = NSBitmapImageRep(cgImage: try #require(AgentServer.clickPicture(image, at: CGPoint(x: 250, y: 100))))
    #expect(middle.pixelsWide == 400 && middle.pixelsHigh == 240)
    // The clicked pixel is in the middle, 2 × 2, uncovered; the cross is red a little way off, on both axes.
    #expect(color(middle, 200, 120) == blue && color(middle, 201, 121) == blue)
    #expect(color(middle, 202, 120) == grey && color(middle, 199, 119) == grey)
    #expect(color(middle, 220, 120)[0] > 200 && color(middle, 220, 120)[1] < 60)
    #expect(color(middle, 200, 140)[0] > 200 && color(middle, 200, 140)[1] < 60)
    #expect(color(middle, 150, 120) == grey && color(middle, 0, 0) == grey)

    // Near a corner the picture is smaller, and the cross still marks the pixel.
    frame.fill(CGRect(x: 3, y: 300 - 4 - 1, width: 1, height: 1))
    let marked = try #require(frame.makeImage())
    let corner = NSBitmapImageRep(cgImage: try #require(AgentServer.clickPicture(marked, at: CGPoint(x: 3, y: 4))))
    #expect(corner.pixelsWide == 206 && corner.pixelsHigh == 128)
    #expect(color(corner, 6, 8) == blue && color(corner, 7, 9) == blue && color(corner, 5, 8) == grey)
    #expect(color(corner, 26, 8)[0] > 200 && color(corner, 26, 8)[1] < 60)
}

/// The Windows key has no Mac key: "win" (or "windows", "⊞", "super") in a combo for the desktop is taken out and held
/// around the rest; "win" alone presses it alone (Start).
@Test func theWindowsKeyIsTakenOutOfADesktopCombo() throws {
    #expect(KeyCombo.windowsKey(in: "win+e") == ("e", true))
    #expect(KeyCombo.windowsKey(in: "Windows+R") == ("R", true))
    #expect(KeyCombo.windowsKey(in: "⊞+shift+s") == ("shift+s", true))
    #expect(KeyCombo.windowsKey(in: "super+d") == ("d", true))
    #expect(KeyCombo.windowsKey(in: "win") == (nil, true))
    #expect(KeyCombo.windowsKey(in: "ctrl+shift+escape") == ("ctrl+shift+escape", false))
    #expect(KeyCombo.windowsKey(in: "cmd++") == ("cmd++", false))
    #expect(try KeyCombo("alt+d").modifiers == .option && KeyCombo("ctrl+l").modifiers == .control)
    #expect(try KeyCombo("ctrl+shift+escape").keyCode == 53)
    #expect(throws: AgentServer.Failure.self) { try KeyCombo("win+e") }  // the windows key is for the desktop only
}

// MARK: A session against a throwaway sshd

@MainActor @Test func agentConnectsTrustsRenamesUploadsAndDownloads() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        var host = server.host(trustNewHostKeys: false)
        host.label = "lab"
        let local = try server.scratch()
        host.lastLocalDir = local
        try write("old", to: server.path("a.txt"))
        let model = testModel([host])
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let (main, agent, _) = try agentWindow(model, askpass)
        defer {
            agent.close()
            main.window?.orderOut(nil)
        }

        _ = await call(agent, "select", ["pane": "sidebar", "names": ["lab"]])
        var reply = await call(agent, "menu", ["path": "Host > Connect"])
        #expect(reply.error == nil)
        reply = await call(agent, "wait", ["until": "sheet", "timeout": 20])
        #expect((reply["title"] as? String)?.hasPrefix("Trust “[127.0.0.1]:") == true, "\(reply.json) \(reply.error ?? "")")
        #expect(await call(agent, "press", ["title": "Trust"]).error == nil)
        reply = await call(agent, "wait", ["until": "connected", "timeout": 20])
        #expect(reply["state"] as? String == "connected", "\(reply.error ?? "")")
        reply = await call(agent, "wait", ["until": "listed", "pane": "right", "text": "a.txt", "timeout": 20])
        #expect(reply["dir"] as? String == server.home)

        // Rename through the pane's context menu: a name sheet.
        reply = await call(agent, "select", ["pane": "right", "names": ["a.txt"]])
        #expect((reply["pane"] as? [String: Any])?["selected"] as? [String] == ["a.txt"])
        reply = await call(agent, "menu", ["path": "File > Rename…"])  // the focused pane's selection, as ⌘ keys go
        #expect(sheet(reply)?["title"] as? String == "Rename “a.txt”")
        #expect(await call(agent, "set", ["id": "prompt.name", "value": "b.txt"]).error == nil)
        #expect(await call(agent, "press", ["title": "Rename"]).error == nil)
        #expect(await call(agent, "wait", ["until": "listed", "pane": "right", "text": "b.txt", "timeout": 20]).error == nil)
        #expect(read(server.path("b.txt")) == "old" && !rawExists(server.path("a.txt")))

        // Upload onto an existing name: the conflict sheet, Keep Both.
        try write("new", to: local + "/b.txt")
        reply = await call(agent, "drop", ["files": [local + "/b.txt"], "pane": "right"])
        #expect((sheet(reply)?["title"] as? String)?.contains("“b.txt” already exists") == true, "\(reply.json)")
        let buttons = titles(sheet(reply)?["buttons"])
        #expect(buttons.contains("Keep Both"))
        #expect(await call(agent, "press", ["title": "Keep Both"]).error == nil)
        reply = await call(agent, "wait", ["until": "transfers_done", "timeout": 30])
        #expect(reply.error == nil && (reply["jobs"] as? [[String: Any]])?.last?["status"] as? String == "Done")
        // The snapshot's list (the Transfers panel's, which follows the queues a moment later) has them finished too: it
        // showed them running right after the wait.
        let waited = Set((reply["jobs"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String })
        let shown = TransferCenter.shared.jobs.filter { waited.contains($0.id.uuidString) }
        #expect(!waited.isEmpty && shown.count == waited.count && shown.allSatisfy(\.status.isFinished))
        #expect(read(server.path("b 2.txt")) == "new" && read(server.path("b.txt")) == "old")

        // Sorting answers with the rows in their new order (the pane sorts them off the main thread).
        _ = await call(agent, "wait", ["until": "listed", "pane": "right", "text": "b 2.txt", "timeout": 20])
        let right = try #require(main.selectedWorkspace?.browser.right)
        let ascending = right.rows.map(\.name)
        reply = await call(agent, "sort", ["pane": "right", "column": "name", "ascending": false])
        let descending = ((reply["pane"] as? [String: Any])?["rows"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        #expect(descending == Array(ascending.reversed()) && descending == right.rows.map(\.name), "\(ascending) \(descending ?? [])")
        // By owner: the rows name their owner, as Get Info does, with its number.
        reply = await call(agent, "sort", ["pane": "right", "column": "owner"])
        let owned = (reply["pane"] as? [String: Any])?["rows"] as? [[String: Any]] ?? []
        #expect(!owned.isEmpty && owned.allSatisfy { $0["owner"] as? String == NSUserName() && $0["ownerID"] as? Int == Int(getuid()) },
                "\(owned)")
        _ = await call(agent, "sort", ["pane": "right", "column": "name"])

        // A pop-up's option by its words: "zip" is “ZIP archive (.zip)”, not “Gzipped tar archive (.tar.gz)”.
        _ = await call(agent, "select", ["pane": "right", "names": ["b.txt"]])
        #expect(sheet(await call(agent, "menu", ["path": "context > Compress…", "pane": "right"]))?["title"] as? String == "Compress “b.txt”")
        reply = await call(agent, "set", ["id": "compress.format", "value": "zip"])
        #expect(reply.error == nil && field(sheet(reply), "compress.format")?["value"] as? String == "ZIP archive (.zip)", "\(reply.error ?? "")")
        _ = await call(agent, "press", ["title": "Cancel"])
        #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 10]).error == nil)

        // Download the selection into a folder of this Mac (Download To… without its panel).
        let downloads = try server.scratch()
        _ = await call(agent, "wait", ["until": "listed", "pane": "right", "text": "b 2.txt", "timeout": 20])
        _ = await call(agent, "select", ["pane": "right", "names": ["b 2.txt"]])
        reply = await call(agent, "drop", ["from": "right", "to": "local:" + downloads])
        #expect((reply["jobs"] as? [[String: Any]])?.count == 1, "\(reply.json) \(reply.error ?? "")")
        #expect(await call(agent, "wait", ["until": "transfers_done", "timeout": 30]).error == nil)
        #expect(read(downloads + "/b 2.txt") == "new")

        // ⌘⌫ is File > Delete… (menus write the key as backspace): it asks first.
        reply = await call(agent, "key", ["combo": "cmd+delete"])
        #expect((sheet(reply)?["title"] as? String)?.hasPrefix("Delete “b 2.txt”") == true, "\(reply.json) \(reply.error ?? "")")
        _ = await call(agent, "press", ["title": "Cancel"])
        #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 10]).error == nil)
        // The pane's context menu, and a confirmation in the way: Delete asks first.
        reply = await call(agent, "menu", ["path": "context > Delete…", "pane": "right"])
        #expect((sheet(reply)?["title"] as? String)?.hasPrefix("Delete “b 2.txt”") == true)
        #expect(await call(agent, "press", ["title": "Delete"]).error == nil)
        #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 10]).error == nil)
        #expect(await eventually { !rawExists(server.path("b 2.txt")) })

        // Disconnect through the menu; the wait sees it.
        _ = await call(agent, "menu", ["path": "Host > Disconnect"])
        #expect(await call(agent, "wait", ["until": "disconnected", "timeout": 20]).error == nil)
    }
}

/// go and open (owner's report, 1.0.0: an agent clicked its way through a server's folders): a folder by its path
/// (absolute, ~, relative, ..) and a row by its name, through the pane's own navigation (the pane moves, its Back list
/// follows), answered with the folder's rows (the first 100, `more` counting the others) or a plain error, and no
/// error sheet left to close; a file opens as Return opens it.
@MainActor @Test func agentGoesToFoldersAndOpensRowsByName() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        var host = server.host()
        host.label = "lab"
        let local = try server.scratch()
        host.lastLocalDir = local
        let data = server.path("data")
        try write("q,1\n", to: data + "/reports/q3.csv")
        try write("notes\n", to: data + "/notes.txt")
        try write("x", to: data + "/.cache/x")
        try write("x", to: data + "/locked/x")
        for index in 0..<150 { try write("\(index)", to: data + "/many/f\(index).txt") }
        try FileManager.default.createSymbolicLink(atPath: data + "/link", withDestinationPath: data + "/reports")
        chmod(data + "/locked", 0)  // the server's shutdown unlocks it
        let model = testModel([host])
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let (main, agent, _) = try agentWindow(model, askpass)
        defer {
            agent.close()
            main.window?.orderOut(nil)
        }
        func listed(_ reply: Reply) -> (dir: String?, names: [String]) {
            let pane = reply["pane"] as? [String: Any]
            return (pane?["dir"] as? String, (pane?["rows"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
        }

        // Not connected yet: said so, nothing moves.
        _ = await call(agent, "select", ["pane": "sidebar", "names": ["lab"]])
        var reply = await call(agent, "go", ["path": data])
        #expect(reply.error == "“lab” isn't connected: menu path=\"Host > Connect\", then wait until=connected.", "\(reply.error ?? "")")
        _ = await call(agent, "menu", ["path": "Host > Connect"])
        #expect(await call(agent, "wait", ["until": "connected", "timeout": 20]).error == nil)
        let right = try #require(main.selectedWorkspace?.browser.right)

        // An absolute path: the pane shows it (and focuses), the reply lists it once listed; hidden files stay hidden.
        reply = await call(agent, "go", ["path": data])
        #expect(listed(reply).dir == data && Set(listed(reply).names) == ["link", "locked", "many", "reports", "notes.txt"],
                "\(reply.json) \(reply.error ?? "")")
        let row = ((reply["pane"] as? [String: Any])?["rows"] as? [[String: Any]])?.first { $0["name"] as? String == "notes.txt" }
        #expect(row?["kind"] as? String == "file" && row?["size"] as? Int == 6 && row?["perm"] as? String != nil
                && row?["modified"] as? String != nil, "\(row ?? [:])")
        #expect(right.dir == data && (reply["pane"] as? [String: Any])?["focused"] as? Bool == true
                && (reply["pane"] as? [String: Any])?["more"] == nil)
        // A click in a file pane or the sidebar is refused (the bridge's test clicks there): what is there is taken by name.
        let sidebar = try #require((main.window?.contentViewController as? NSSplitViewController)?.splitViewItems.first?.viewController.view)
        let cell = try #require(right.table.view(atColumn: 0, row: 0, makeIfNecessary: true))
        #expect([cell, right.statusLabel, right.filterField, sidebar.subviews.first ?? sidebar].allSatisfy(AgentServer.takenByName))
        #expect(!AgentServer.takenByName(try #require(main.window?.contentView)))
        // ~ is the server's home, and relative paths start in the folder shown; the Back list follows as for a person.
        #expect(listed(await call(agent, "go", ["path": "~"])).dir == server.home)
        #expect(listed(await call(agent, "go", ["path": "~/data"])).dir == data && right.back.last == server.home)
        #expect(listed(await call(agent, "go", ["path": "reports"])).dir == data + "/reports")
        #expect(listed(await call(agent, "go", ["path": ".."])).dir == data)
        // A folder that isn't there, or can't be read: a plain error, the pane stays, and no sheet to close.
        reply = await call(agent, "go", ["path": "nothing"])
        #expect(reply.error == "No such folder: \(data)/nothing (the pane stays in \(data)).", "\(reply.error ?? "")")
        reply = await call(agent, "go", ["path": data + "/locked"])
        #expect(reply.error?.hasPrefix("Permission denied: this account may not list \(data)/locked") == true, "\(reply.error ?? "")")
        #expect(right.dir == data && main.window?.attachedSheet == nil)

        // open: a folder by its name, .. back up (with the folder left selected), a link to a folder.
        reply = await call(agent, "open", ["name": "reports"])
        #expect(listed(reply).dir == data + "/reports" && listed(reply).names == ["q3.csv"], "\(reply.json) \(reply.error ?? "")")
        reply = await call(agent, "open", ["name": ".."])
        #expect(listed(reply).dir == data && (reply["pane"] as? [String: Any])?["selected"] as? [String] == ["reports"])
        reply = await call(agent, "open", ["name": "link"])
        #expect(listed(reply).dir == data + "/link" && listed(reply).names == ["q3.csv"], "\(reply.json) \(reply.error ?? "")")
        _ = await call(agent, "open", ["name": ".."])
        #expect(await call(agent, "open", ["name": "nope"]).error?.hasPrefix("No “nope” in \(data). There: ") == true)
        #expect(await call(agent, "open", ["name": ".cache"]).error?.contains("isn't shown") == true)
        // A file opens as Return opens it: downloaded, then handed to its app (here: recorded).
        let opened = Recorder<URL>()
        right.browser?.openFile = { opened.append($0) }
        reply = await call(agent, "open", ["name": "notes.txt"])
        #expect(reply.error == nil && reply["opened"] as? String == "notes.txt" && right.selectedItems.map(\.name) == ["notes.txt"])
        #expect(await eventually { opened.all.first.map { read($0.path) } == "notes\n" })

        // A long folder: the first 100 rows, and how many more.
        reply = await call(agent, "go", ["path": "many"])
        let pane = reply["pane"] as? [String: Any]
        #expect((pane?["rows"] as? [Any])?.count == 100 && pane?["more"] as? Int == 50 && pane?["total"] as? Int == 150,
                "\(pane?["more"] ?? "") \(pane?["total"] ?? "")")

        // This Mac's pane, by pane=left.
        try write("m", to: local + "/sub/mac.txt")
        reply = await call(agent, "go", ["pane": "left", "path": local + "/sub"])
        #expect(listed(reply).dir == local + "/sub" && listed(reply).names == ["mac.txt"], "\(reply.json) \(reply.error ?? "")")

        // A sheet in the way is answered first, as a person must.
        main.newGroup()
        #expect(await call(agent, "go", ["path": "~"]).error?.hasPrefix("A sheet is open") == true)
        _ = await call(agent, "key", ["combo": "escape"])
        #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 5]).error == nil)

        _ = await call(agent, "menu", ["path": "Host > Disconnect"])
        #expect(await call(agent, "wait", ["until": "disconnected", "timeout": 20]).error == nil)
        #expect(await call(agent, "open", ["name": "reports"]).error?.contains("isn't connected") == true)
    }
}

/// Test Connection in the host editor works while AirSCP isn't the active app (ssh's question comes on the editor), and
/// a tunnel's switch, Edit… and Remove are pressed by the tunnel's name, with its state in the snapshot.
@MainActor @Test func agentTestsAConnectionAndSwitchesATunnel() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        let free = try listener()
        close(free.fd)
        close(free.fd6)
        var host = server.host(trustNewHostKeys: false)
        host.label = "lab"
        host.tunnels = [Tunnel(kind: .local, listenPort: free.port, targetHost: "127.0.0.1", targetPort: server.port)]
        let model = testModel([host])
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let (main, agent, _) = try agentWindow(model, askpass)
        defer {
            agent.close()
            main.window?.orderOut(nil)
        }
        let tunnel = "localhost:\(free.port) on this Mac → lab → 127.0.0.1:\(server.port) on lab (the server itself)"

        // Test Connection: the new key's question is a sheet on the editor, the result is in the editor's text.
        _ = await call(agent, "select", ["pane": "sidebar", "names": ["lab"]])
        var reply = await call(agent, "menu", ["path": "Host > Edit…"])
        #expect(sheet(reply)?["title"] as? String == "Edit “lab”", "\(reply.json) \(reply.error ?? "")")
        #expect(await call(agent, "press", ["title": "Test Connection"]).error == nil)
        reply = await call(agent, "wait", ["until": "sheet", "text": "Trust “", "timeout": 20])
        #expect((reply["title"] as? String)?.hasPrefix("Trust “") == true && reply["window"] as? String != nil, "\(reply.json) \(reply.error ?? "")")
        #expect(await call(agent, "press", ["title": "Trust"]).error == nil)
        reply = await call(agent, "wait", ["until": "sheet", "text": "Logged in.", "timeout": 20])
        #expect(reply.error == nil, "\(reply.error ?? "")")
        _ = await call(agent, "press", ["title": "Cancel"])
        #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 5]).error == nil)

        // Connect, then the Tunnels tab: the switch by the tunnel's name, on and off.
        _ = await call(agent, "menu", ["path": "Host > Connect"])
        for _ in 0..<3 {
            reply = await call(agent, "wait", ["until": "connected", "timeout": 20])
            guard reply.error?.contains("Trust") == true else { break }
            _ = await call(agent, "press", ["title": "Trust"])
        }
        #expect(reply["state"] as? String == "connected", "\(reply.error ?? "")")
        #expect(await call(agent, "press", ["title": "Tunnels"]).error == nil)
        func on() async -> Bool? {
            let workspace = await call(agent, "snapshot", ["include": ["workspace"]])["workspace"] as? [String: Any]
            return (workspace?["tunnels"] as? [[String: Any]])?.first { $0["title"] as? String == tunnel }?["on"] as? Bool
        }
        #expect(await on() == false)
        #expect(await call(agent, "press", ["title": tunnel]).error == nil)
        #expect(await eventually { canConnect(to: free.port) })
        #expect(await eventually { await on() == true })
        #expect(await eventually { await call(agent, "set", ["title": tunnel, "value": false]).error == nil })
        #expect(await eventually { await on() == false })
        #expect(await eventually { !canConnect(to: free.port) })
        // Its own Edit… and Remove, named after it too. Saved to 127.0.0.1, it goes to the server itself.
        #expect(await eventually { await call(agent, "press", ["title": "Edit \(tunnel)"]).error == nil })
        reply = await call(agent, "wait", ["until": "sheet", "text": "tunnelEditor", "timeout": 5])
        #expect(field(reply.json, "tunnelEditor.listenPort")?["value"] as? String == String(free.port), "\(reply.json)")
        #expect(field(reply.json, "tunnelEditor.destination")?["value"] as? String == "The server itself", "\(reply.json)")
        #expect(field(reply.json, "tunnelEditor.targetHost") == nil, "\(reply.json)")
        #expect(field(reply.json, "tunnelEditor.targetPort")?["value"] as? String == String(server.port), "\(reply.json)")
        #expect(reply["title"] as? String == "Edit Tunnel", "\(reply.json)")  // a headline, as the other editors have
        _ = await call(agent, "press", ["title": "Cancel"])
        #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 5]).error == nil)
        #expect(await call(agent, "press", ["title": "Remove \(tunnel)"]).error == nil)
        #expect(await eventually { model.host(host.id)?.tunnels.isEmpty == true })

        // Add Tunnel…: the port to reach is the port to open until it is typed in; another machine is the one named.
        #expect(await call(agent, "press", ["title": "Add Tunnel…"]).error == nil)
        #expect(await call(agent, "wait", ["until": "sheet", "text": "tunnelEditor", "timeout": 5]).error == nil)
        #expect(await call(agent, "set", ["id": "tunnelEditor.listenPort", "value": "18649"]).error == nil)
        #expect(await eventually {
            let sheet = await call(agent, "wait", ["until": "sheet", "timeout": 5])
            return field(sheet.json, "tunnelEditor.targetPort")?["value"] as? String == "18649"
        })
        #expect(await call(agent, "set", ["id": "tunnelEditor.destination", "value": "Another machine"]).error == nil)
        #expect(await eventually { await call(agent, "set", ["id": "tunnelEditor.targetHost", "value": "db.internal"]).error == nil })
        #expect(await call(agent, "set", ["id": "tunnelEditor.targetPort", "value": "5432"]).error == nil)
        #expect(await call(agent, "press", ["title": "Save"]).error == nil)
        #expect(await eventually {
            model.host(host.id)?.tunnels.map { "\($0.kind) \($0.listenPort) \($0.targetHost) \($0.targetPort)" } == ["local 18649 db.internal 5432"]
        })
        // It opens again as saved.
        let saved = "localhost:18649 on this Mac → lab → db.internal:5432"
        #expect(await eventually { await call(agent, "press", ["title": "Edit \(saved)"]).error == nil })
        reply = await call(agent, "wait", ["until": "sheet", "text": "tunnelEditor", "timeout": 5])
        #expect(field(reply.json, "tunnelEditor.destination")?["value"] as? String == "Another machine the server can reach", "\(reply.json)")
        #expect(field(reply.json, "tunnelEditor.targetHost")?["value"] as? String == "db.internal", "\(reply.json)")
        _ = await call(agent, "press", ["title": "Cancel"])
        #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 5]).error == nil)

        _ = await call(agent, "menu", ["path": "Host > Disconnect"])
        #expect(await call(agent, "wait", ["until": "disconnected", "timeout": 20]).error == nil)
    }
}

/// A Host-menu command an sftp-only account can't run says the account's own reason.
@MainActor @Test func aCommandAnSFTPOnlyAccountCantRunSaysWhy() async throws {
    _ = NSApplication.shared
    try await withServer(TestServer.Options(sftpOnly: true)) { @MainActor server in
        var host = server.host()
        host.label = "sftp"
        let model = testModel([host])
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let (main, agent, _) = try agentWindow(model, askpass)
        defer {
            agent.close()
            main.window?.orderOut(nil)
        }
        _ = await call(agent, "select", ["pane": "sidebar", "names": ["sftp"]])
        _ = await call(agent, "menu", ["path": "Host > Connect"])
        #expect(await call(agent, "wait", ["until": "connected", "timeout": 20]).error == nil)
        let reason = try #require(main.selectedWorkspace?.session.capabilities.noShellReason)
        #expect(await call(agent, "menu", ["path": "Host > Run Command…"]).error == "“Host > Run Command…” is disabled now: \(reason)")
        // The Monitor can't read such a server: a wait for it says why at once, not after its timeout.
        _ = await call(agent, "press", ["title": "Monitor"])
        let monitor = await call(agent, "wait", ["until": "monitor", "timeout": 60])
        #expect(monitor.error?.hasPrefix("This account allows file transfers (sftp) only") == true, "\(monitor.error ?? "")")
        _ = await call(agent, "menu", ["path": "Host > Disconnect"])
        #expect(await call(agent, "wait", ["until": "disconnected", "timeout": 20]).error == nil)
    }
}

/// Find Files and Synchronize through the agent (PLAN.md S.1): their sheets' fields by id, `wait found` and `wait
/// compared` with the results and the plan, Show, and a Synchronize that leaves the two folders the same.
@MainActor @Test func agentFindsFilesAndSynchronizesFolders() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        var host = server.host()
        host.label = "lab"
        let local = try server.scratch()
        host.lastLocalDir = local
        let site = server.path("site"), mirror = server.path("mirror")
        try write("x", to: site + "/logs/app.log")
        try write("x", to: site + "/logs/old/app-1.LOG")
        try write("x", to: site + "/index.html")
        try write("mine", to: local + "/new.txt")
        try write("deep", to: local + "/sub/inner.txt")
        try write("stale", to: mirror + "/stale.txt")
        let model = testModel([host])
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let (main, agent, _) = try agentWindow(model, askpass)
        defer {
            agent.close()
            main.window?.orderOut(nil)
        }
        _ = await call(agent, "select", ["pane": "sidebar", "names": ["lab"]])
        _ = await call(agent, "menu", ["path": "Host > Connect"])
        #expect(await call(agent, "wait", ["until": "connected", "timeout": 20]).error == nil)
        func open(_ name: String, in dir: String) async {
            _ = await call(agent, "wait", ["until": "listed", "pane": "right", "text": name, "timeout": 20])
            _ = await call(agent, "select", ["pane": "right", "names": [name]])
            _ = await call(agent, "menu", ["path": "Go > Open Selection"])
            #expect(await call(agent, "wait", ["until": "listed", "pane": "right", "path": dir + "/" + name, "timeout": 20]).error == nil)
        }
        await open("site", in: server.home)

        // Find Files below the folder shown: the pattern by id, the results once the search has ended.
        #expect(await call(agent, "wait", ["until": "found"]).error?.hasPrefix("No Find Files sheet is open") == true)
        var reply = await call(agent, "menu", ["path": "File > Find Files…"])
        #expect(field(sheet(reply), "find.pattern") != nil, "\(reply.json) \(reply.error ?? "")")
        // Its tooltip's patterns keep their asterisks (SwiftUI read "*.log, …, [Rr]eadme*" as Markdown italics).
        #expect((field(sheet(reply), "find.pattern")?["help"] as? String)?.contains("*.log, report-??.pdf, [Rr]eadme*") == true)
        #expect(await call(agent, "set", ["id": "find.pattern", "value": "*.log"]).error == nil)
        #expect(await call(agent, "press", ["title": "Find"]).error == nil)
        reply = await call(agent, "wait", ["until": "found", "timeout": 20])
        #expect(reply["status"] as? String == "2 found." && reply["searching"] as? Bool == false, "\(reply.json) \(reply.error ?? "")")
        #expect((reply["results"] as? [[String: Any]])?.compactMap { $0["path"] as? String } == ["logs/app.log", "logs/old/app-1.LOG"])
        // Show: the item's folder in the pane, with the item selected.
        reply = await call(agent, "select", ["in": "sheet", "names": ["logs/old/app-1.LOG"]])
        #expect(reply.error == nil, "\(reply.error ?? "")")
        #expect(await eventually { (await call(agent, "snapshot")["find"] as? [String: Any])?["selected"] as? String == "logs/old/app-1.LOG" })
        #expect(await eventually { await call(agent, "press", ["title": "Show"]).error == nil })
        #expect(await call(agent, "wait", ["until": "listed", "pane": "right", "path": site + "/logs/old", "timeout": 20]).error == nil)
        let right = try #require(main.selectedWorkspace?.browser.right)
        #expect(await eventually { right.selectedItems.map(\.name) == ["app-1.LOG"] })

        // Synchronize this Mac's folder (the left pane) with the server's "mirror": the plan once compared, the
        // direction and the delete option by id, then the jobs, and the folders the same afterwards.
        _ = await call(agent, "menu", ["path": "Go > Home"])
        await open("mirror", in: server.home)
        reply = await call(agent, "menu", ["path": "File > Synchronize…"])
        #expect(reply.error == nil, "\(reply.error ?? "")")
        func steps(_ json: [String: Any]) -> [String] {
            (json["steps"] as? [[String: Any]] ?? []).map { "\($0["action"] ?? "") \($0["path"] ?? "")" }
        }
        reply = await call(agent, "wait", ["until": "compared", "timeout": 20])
        #expect(reply["direction"] as? String == "This Mac → lab" && reply["comparing"] as? Bool == false, "\(reply.json) \(reply.error ?? "")")
        #expect(steps(reply.json) == ["upload new.txt", "upload sub/"], "\(reply.json)")
        #expect(await call(agent, "set", ["id": "sync.direction", "value": "Both ways"]).error == nil)
        var plan = await call(agent, "snapshot")["sync"] as? [String: Any] ?? [:]
        #expect(plan["direction"] as? String == "Both ways" && steps(plan) == ["upload new.txt", "download stale.txt", "upload sub/"], "\(plan)")
        #expect(await call(agent, "set", ["id": "sync.direction", "value": "This Mac → lab"]).error == nil)
        #expect(await call(agent, "set", ["id": "sync.delete", "value": true]).error == nil)
        // Both ways never deletes: its box shows off (it was drawn ticked, greyed out); the choice is back after.
        _ = await call(agent, "set", ["id": "sync.direction", "value": "Both ways"])
        #expect(await eventually {
            let box = field((await call(agent, "snapshot", ["include": ["sheets"]])["sheets"] as? [[String: Any]])?.first, "sync.delete")
            return box?["value"] as? Int == 0 && box?["enabled"] as? Bool == false
        })
        _ = await call(agent, "set", ["id": "sync.direction", "value": "This Mac → lab"])
        plan = await call(agent, "snapshot")["sync"] as? [String: Any] ?? [:]
        #expect(plan["delete"] as? Bool == true && steps(plan) == ["upload new.txt", "delete stale.txt", "upload sub/"], "\(plan)")
        #expect(await call(agent, "press", ["title": "Synchronize"]).error == nil)
        #expect(await call(agent, "wait", ["until": "transfers_done", "host": "lab", "timeout": 30]).error == nil)
        #expect(await eventually { read(mirror + "/new.txt") == "mine" && read(mirror + "/sub/inner.txt") == "deep" && !exists(mirror + "/stale.txt") })
        _ = await call(agent, "wait", ["until": "listed", "pane": "right", "timeout": 20])
        _ = await call(agent, "focus", ["pane": "right"])
        _ = await call(agent, "menu", ["path": "File > Synchronize…"])
        reply = await call(agent, "wait", ["until": "compared", "timeout": 20])
        #expect(reply["summary"] as? String == "The folders are the same." && reply["count"] as? Int == 0, "\(reply.json) \(reply.error ?? "")")
        _ = await call(agent, "press", ["title": "Cancel"])
        #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 5]).error == nil)
        _ = await call(agent, "menu", ["path": "Host > Disconnect"])
        #expect(await call(agent, "wait", ["until": "disconnected", "timeout": 20]).error == nil)
    }
}

/// Synchronize with the host's Leave out patterns (shown and changed in the sheet, remembered once it synchronizes) and
/// with items unticked by name (a row's box by its path, `select in=sheet`): only the ticked ones are done.
@MainActor @Test func agentLeavesOutAndUnticksWhatToSynchronize() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        var host = server.host()
        host.label = "lab"
        host.leaveOut = "*.log"
        let local = try server.scratch(), mirror = server.path("mirror")
        host.lastLocalDir = local
        for path in ["a.txt", "b.txt", "app.log", "cache/big.bin", "docs/c.txt"] { try write(path, to: local + "/" + path) }
        try write("stale", to: mirror + "/stale.txt")
        let model = testModel([host])
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let (main, agent, _) = try agentWindow(model, askpass)
        defer {
            agent.close()
            main.window?.orderOut(nil)
        }
        _ = await call(agent, "select", ["pane": "sidebar", "names": ["lab"]])
        _ = await call(agent, "menu", ["path": "Host > Connect"])
        #expect(await call(agent, "wait", ["until": "connected", "timeout": 120]).error == nil)
        #expect(await call(agent, "wait", ["until": "listed", "pane": "left", "path": local, "timeout": 120]).error == nil)
        // The pane's first listing first: a later one would replace the folder opened.
        #expect(await call(agent, "wait", ["until": "listed", "pane": "right", "path": server.home, "timeout": 120]).error == nil)
        let right = try #require(main.selectedWorkspace?.browser.right)
        #expect(await right.open(mirror))
        _ = await call(agent, "focus", ["pane": "right"])
        var reply = await call(agent, "menu", ["path": "File > Synchronize…"])
        #expect(field(sheet(reply), "sync.leaveOut")?["value"] as? String == "*.log", "\(reply.json) \(reply.error ?? "")")
        func steps(_ json: [String: Any]) -> [String] {
            (json["steps"] as? [[String: Any]] ?? []).map { "\($0["path"] ?? "")" + ($0["ticked"] as? Bool == false ? " (unticked)" : "") }
        }
        reply = await call(agent, "wait", ["until": "compared", "timeout": 120])
        #expect(reply["leaveOut"] as? String == "*.log" && steps(reply.json) == ["a.txt", "b.txt", "cache/", "docs/"], "\(reply.json)")
        // Another pattern: compared again without what it matches.
        #expect(await call(agent, "set", ["id": "sync.leaveOut", "value": "*.log, cache"]).error == nil)
        reply = await call(agent, "wait", ["until": "compared", "timeout": 120])
        #expect(steps(reply.json) == ["a.txt", "b.txt", "docs/"] && reply["ticked"] as? Int == 3, "\(reply.json)")
        // Unticked by path: a row's box; none (then Synchronize is off, and says why); only the items named.
        reply = await call(agent, "set", ["title": "docs/", "value": false])
        #expect(reply["ticked"] as? Int == 2, "\(reply.json) \(reply.error ?? "")")
        let plan = await call(agent, "snapshot")["sync"] as? [String: Any] ?? [:]
        #expect(steps(plan) == ["a.txt", "b.txt", "docs/ (unticked)"]
                && (plan["summary"] as? String)?.contains("\n1 unticked: left as it is.") == true, "\(plan)")
        reply = await call(agent, "select", ["in": "sheet", "none": true])
        #expect(reply["ticked"] as? Int == 0, "\(reply.json) \(reply.error ?? "")")
        reply = await call(agent, "press", ["title": "Synchronize"])
        #expect(reply.error?.contains("Nothing is ticked") == true, "\(reply.json) \(reply.error ?? "")")
        reply = await call(agent, "select", ["in": "sheet", "names": ["missing.txt"]])
        #expect(reply.error?.hasPrefix("Not in Synchronize's list: missing.txt") == true, "\(reply.error ?? "")")
        reply = await call(agent, "select", ["in": "sheet", "names": ["a.txt", "docs/"]])
        #expect(reply["ticked"] as? Int == 2, "\(reply.json) \(reply.error ?? "")")
        #expect(await call(agent, "press", ["title": "Synchronize"]).error == nil)
        #expect(await call(agent, "wait", ["until": "transfers_done", "host": "lab", "timeout": 120]).error == nil)
        #expect(await eventually { files(below: mirror) == ["a.txt", "docs/c.txt", "stale.txt"] }, "\(files(below: mirror))")
        #expect(model.host(host.id)?.leaveOut == "*.log, cache")  // remembered for the server
        await main.selectedWorkspace?.connection.disconnect()
    }
}

/// A download cut off by a lost connection: its job says the retry will continue it (`resumable`), and after Retry
/// that it did (`resumed`).
@MainActor @Test func aCutOffTransferShowsItContinuesWhereItStopped() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        var host = server.host()
        host.label = "lab"
        let local = try server.scratch()
        host.lastLocalDir = local
        try writeRandom(bytes: 20_000_000, to: server.path("agent-resume.bin"))
        let model = testModel([host])
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let (main, agent, _) = try agentWindow(model, askpass)
        defer {
            agent.close()
            main.window?.orderOut(nil)
        }
        _ = await call(agent, "select", ["pane": "sidebar", "names": ["lab"]])
        _ = await call(agent, "menu", ["path": "Host > Connect"])
        #expect(await call(agent, "wait", ["until": "connected", "timeout": 20]).error == nil)
        let session = try #require(main.selectedWorkspace?.session)
        // 500 KB/s (40 s for the file): still running when a busy main queue lets the wait below look again.
        session.transfers.bandwidthLimit = 4_000
        // A busy main queue can take long to list the folder: the wait returns once it has.
        #expect(await call(agent, "wait", ["until": "listed", "pane": "right", "text": "agent-resume.bin", "timeout": 120]).error == nil)
        _ = await call(agent, "select", ["pane": "right", "names": ["agent-resume.bin"]])
        let reply = await call(agent, "drop", ["from": "right", "to": "local:" + local])
        let id = try #require(((reply["jobs"] as? [[String: Any]])?.first?["id"] as? String).flatMap { UUID(uuidString: $0) },
                              "\(reply.json) \(reply.error ?? "")")
        #expect(await eventually { (TransferQueue.localSize(local + "/" + TransferQueue.partName(id)) ?? 0) > 1_000_000 })
        try await killMaster(of: session)
        await session.transfers.waitUntilIdle()
        session.transfers.bandwidthLimit = nil
        func job() async -> [String: Any]? {
            let transfers = await call(agent, "snapshot", ["include": ["transfers"]])["transfers"] as? [String: Any]
            return (transfers?["jobs"] as? [[String: Any]])?.first { $0["id"] as? String == id.uuidString }
        }
        #expect(await eventually { await job()?["resumable"] as? Bool == true })
        var now = await job()
        #expect(now?["resumed"] == nil && now?["status"] as? String != "Done", "\(now ?? [:])")

        // Connect again, then Retry in the Transfers panel: the rest of the file only.
        _ = await call(agent, "menu", ["path": "Host > Connect"])
        #expect(await call(agent, "wait", ["until": "connected", "timeout": 20]).error == nil)
        #expect(await call(agent, "select", ["pane": "transfers", "names": ["agent-resume.bin"]]).error == nil)
        #expect(await call(agent, "press", ["id": "transfers.retry"]).error == nil)
        #expect(await call(agent, "wait", ["until": "transfers_done", "host": "lab", "timeout": 60]).error == nil)
        #expect(await eventually {
            let now = await job()
            return now?["resumed"] as? Bool == true && now?["status"] as? String == "Done"
        })
        now = await job()
        #expect(now?["resumed"] as? Bool == true && now?["resumable"] == nil, "\(now ?? [:])")
        #expect(FileManager.default.contentsEqual(atPath: server.path("agent-resume.bin"), andPath: local + "/agent-resume.bin"))
        _ = await call(agent, "menu", ["path": "Host > Disconnect"])
        #expect(await call(agent, "wait", ["until": "disconnected", "timeout": 20]).error == nil)
    }
}

// MARK: The Windows test VM (AIRSCP_WINDOWS=1)

/// One coordinate space on a real Windows (1.0.0: an agent clicked what it saw in screenshot target=rdp and missed):
/// a magenta target at physical pixels 340, 220 (120 × 80; the PowerShell that shows it is DPI-aware) is at those
/// pixels of the desktop's picture, and click with target rdp at a pixel of it lands on that very pixel, which Windows
/// reports. The reply says where in words and shows the spot.
@MainActor
func clickTheMagentaTarget(_ server: AgentServer, _ runner: WindowsRunner, shared: String) async throws {
    let marker = UUID().uuidString.prefix(8)
    #expect(try await runner.powershell("target", "if (-not ('AirSCPDpi' -as [type])) { Add-Type -TypeDefinition "
        + "'using System; using System.Runtime.InteropServices; public static class AirSCPDpi { [DllImport(\"user32.dll\")] "
        + "public static extern bool SetProcessDpiAwarenessContext(IntPtr value); }' }; "
        + "[void][AirSCPDpi]::SetProcessDpiAwarenessContext([IntPtr](-4)); Add-Type -AssemblyName System.Windows.Forms; "
        + "$f = New-Object Windows.Forms.Form; $f.FormBorderStyle = 'None'; $f.StartPosition = 'Manual'; "
        + "$f.AutoScaleMode = 'None'; $f.TopMost = $true; $f.ShowInTaskbar = $false; "
        + "$f.Location = New-Object Drawing.Point(340, 220); $f.Size = New-Object Drawing.Size(120, 80); "
        + "$f.BackColor = [Drawing.Color]::Magenta; $f.Add_MouseClick({ $p = [Windows.Forms.Cursor]::Position; "
        + "Set-Content \\\\tsclient\\AirSCP\\target-\(marker).txt \"$($p.X) $($p.Y)\"; $f.Close() }); "
        + "$f.Add_Shown({ $f.Activate(); Set-Content \\\\tsclient\\AirSCP\\shown-\(marker).txt x }); [void]$f.ShowDialog()") {
        exists(shared + "/shown-\(marker).txt")
    }, "\(read(shared + "/airscp.log") ?? "")")
    // Where the picture shows it (Windows may still be drawing it: until it is all there).
    var box = CGRect.null, size = CGSize.zero
    #expect(await eventually(timeout: 20) {
        let shot = await call(server, "screenshot", ["target": "rdp"])
        guard let picture = shot.image, let data = picture.bitmapData else { return false }
        size = CGSize(width: picture.pixelsWide, height: picture.pixelsHigh)
        #expect((shot["coordinates"] as? String)?.contains("\(picture.pixelsWide) × \(picture.pixelsHigh)") == true)
        box = .null
        let step = picture.bitsPerPixel / 8  // RGB(A), as a PNG decodes
        for y in 0..<min(picture.pixelsHigh, 600) {
            let row = data + y * picture.bytesPerRow
            for x in 0..<min(picture.pixelsWide, 800) where row[x * step] > 200 && row[x * step + 1] < 60 && row[x * step + 2] > 200 {
                box = box.union(CGRect(x: x, y: y, width: 1, height: 1))
            }
        }
        return abs(box.width - 120) <= 2 && abs(box.height - 80) <= 2
    }, "the target in the desktop's picture: \(box) (\(size))")
    #expect(abs(box.minX - 340) <= 1 && abs(box.minY - 220) <= 1, "\(box)")
    // Any pixel of it, off its middle: the click lands on that one.
    let pixel = CGPoint(x: box.minX + 77, y: box.minY + 31)
    let reply = await call(server, "click", ["target": "rdp", "x": pixel.x, "y": pixel.y])
    #expect(reply.error == nil && (reply["desktop"] as? String)?.hasPrefix(
        "Clicked \(Int(pixel.x)), \(Int(pixel.y)) of the \(Int(size.width)) × \(Int(size.height)) desktop picture") == true,
            "\(reply.json) \(reply.error ?? "")")
    #expect(reply.image?.pixelsWide == 400 && reply.image?.pixelsHigh == 240)
    #expect(await eventually(timeout: 20) { read(shared + "/target-\(marker).txt") != nil }, "the target wasn't clicked")
    let landed = (read(shared + "/target-\(marker).txt") ?? "").split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
    #expect(landed.count == 2 && abs(landed[0] - pixel.x) <= 1 && abs(landed[1] - pixel.y) <= 1,
            "Windows got the click at \(landed); it was meant for \(pixel)")
    // Outside the picture: refused with its size, nothing clicked.
    #expect(await call(server, "click", ["target": "rdp", "x": size.width, "y": 10]).error?
        .contains("\(Int(size.width)) × \(Int(size.height)) pixels") == true)
}

// In RDPWindowsTests, whose tests run one at a time: Windows gives the account one session, and a second login takes
// it over (run beside that suite, these lost their desktop halfway).
extension RDPWindowsTests {

/// The Remote Desktop through the agent (in this process, which may reach the VM on the local network): connect with
/// the certificate (Trust Once: nothing is stored) and login questions answered, the desktop's own pixels in a
/// screenshot, and a dropped Mac file arriving in the shared folder.
@MainActor @Test func agentConnectsTheWindowsDesktopAndDropsAFile() async throws {
    _ = NSApplication.shared
    let (host, password) = try #require(windows(), "AIRSCP_WINDOWS=1 needs the VM's address and credentials")
    let shared = try scratch() + "/shared"
    var entry = RDPEntry(label: "Windows VM", hostname: host, username: "porter")
    entry.display = .fixed(width: 1280, height: 800)
    entry.sharedFolder = shared
    let model = testModel()
    model.save(entry)
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let (main, server, _) = try agentWindow(model, askpass)
    defer {
        server.close()
        main.window?.orderOut(nil)
    }

    _ = await call(server, "select", ["pane": "sidebar", "names": ["Windows VM"]])
    var reply = await call(server, "menu", ["path": "Host > Connect"])
    var loggedIn = false
    for _ in 0..<4 where !loggedIn {
        if sheet(reply) == nil { reply = Reply(json: ["sheet": await call(server, "wait", ["until": "sheet", "timeout": 60]).json]) }
        let title = sheet(reply)?["title"] as? String ?? ""
        if title.hasPrefix("Trust the certificate") {
            reply = await call(server, "press", ["title": "Trust Once"])
        } else if title.hasPrefix("Log in to") {
            #expect(await call(server, "set", ["id": "rdpLogin.password", "value": password]).error == nil)
            reply = await call(server, "press", ["title": "Log In"])
            loggedIn = true
        } else {
            Issue.record("unexpected: \(reply.json) \(reply.error ?? "")")
            break
        }
    }
    reply = await call(server, "wait", ["until": "rdp_connected", "timeout": 90])
    #expect(reply["state"] as? String == "connected", "\(reply.error ?? "")")

    // The desktop as AirSCP draws it: Windows' own pixels at their size, not one colour.
    #expect(await eventually {
        guard let image = await call(server, "screenshot", ["target": "rdp"]).image, image.pixelsWide == 1280 else { return false }
        let samples = stride(from: 0, to: image.pixelsHigh, by: 37).flatMap { y in
            stride(from: 0, to: image.pixelsWide, by: 53).compactMap { image.colorAt(x: $0, y: y)?.brightnessComponent }
        }
        return Set(samples.map { Int($0 * 20) }).count > 3
    }, "the screenshot of the desktop shows Windows")

    // A fixed size, scaled down to fit the window with bars beside it: the picture's pixels are still Windows' own.
    try await clickTheMagentaTarget(server, WindowsRunner(session: try #require(server.selectedDesktop?.session), shared: shared),
                                    shared: shared)

    // Typing lends the desktop the focus for the request only: the Mac's clipboard isn't watched afterwards.
    let desktop = try #require(server.selectedDesktop?.desktop)
    let focused = desktop.onFocus
    var focus: [Bool] = []
    desktop.onFocus = { focus.append($0); focused?($0) }
    #expect(await call(server, "type", ["text": "", "target": "rdp"]).error == nil)
    desktop.onFocus = focused
    #expect(focus == [true, false])

    // A Mac file dropped on the desktop goes to the shared folder, \\tsclient\AirSCP in Windows.
    let file = try scratch() + "/agent-drop.txt"
    try write("dropped by an agent\n", to: file)
    #expect(await call(server, "drop", ["files": [file], "target": "desktop"]).error == nil)
    reply = await call(server, "wait", ["until": "text", "text": "In Windows: \\\\tsclient\\AirSCP\\agent-drop.txt", "timeout": 30])
    #expect(reply.error == nil && read(shared + "/agent-drop.txt") == "dropped by an agent\n")

    // Paste Items to Mac… opens in Settings' download folder (the reply says where the panel would have opened). As if
    // Explorer had copied a file: whatever Windows' clipboard really holds is fetched, or the failure said in a sheet.
    let downloads = try scratch()
    model.data.settings.downloadFolder = downloads
    server.selectedDesktop?.bar.remoteFiles = (1, 18)
    #expect(await eventually {  // once SwiftUI has drawn the bar's button
        let elements = await call(server, "snapshot", ["include": ["elements"]])["elements"] as? [[String: Any]] ?? []
        return elements.contains { $0["id"] as? String == "rdp.pasteItems" && $0["title"] as? String == "Paste 1 Item to Mac…" }
    })
    reply = await call(server, "press", ["id": "rdp.pasteItems", "file": try scratch()])
    #expect(reply.error == nil && (reply["panelFolder"] as? String).map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            == URL(fileURLWithPath: downloads).standardizedFileURL.path, "\(reply.json) \(reply.error ?? "")")
    if await call(server, "wait", ["until": "sheet", "timeout": 10]).error == nil { _ = await call(server, "key", ["combo": "escape"]) }
    #expect(await call(server, "wait", ["until": "no_sheet", "timeout": 10]).error == nil)

    _ = await call(server, "menu", ["path": "Host > Disconnect"])
    #expect(await call(server, "wait", ["until": "disconnected", "host": "Windows VM", "timeout": 30]).error == nil)
}

/// An agent's clicks, typing and window sizes on a desktop that fits the window (round 1's Remote Desktop findings): a
/// click on a Windows button presses it (the mouse-up arrived at a corner of the desktop, so Windows saw a drag); text
/// typed into Windows 11's Notepad arrives as typed (it came out backwards, without capitals or accents, when typed
/// faster); and a window made bigger and at once smaller again ends with the desktop at the smaller size (the second
/// size was never asked for, as Windows hadn't applied the first). What Windows copies is read here, never put on the
/// Mac's clipboard.
@MainActor @Test func agentClicksTypesAndResizesTheWindowsDesktop() async throws {
    _ = NSApplication.shared
    let (host, password) = try #require(windows(), "AIRSCP_WINDOWS=1 needs the VM's address and credentials")
    let shared = try scratch() + "/shared", marker = UUID().uuidString.prefix(8)
    var entry = RDPEntry(label: "Windows VM", hostname: host, username: "porter")
    entry.sharedFolder = shared  // display: fit the window (the default)
    let model = testModel()
    model.save(entry)
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let (main, server, _) = try agentWindow(model, askpass)
    defer {
        server.close()
        main.window?.orderOut(nil)
    }
    let window = try #require(main.window)

    _ = await call(server, "select", ["pane": "sidebar", "names": ["Windows VM"]])
    var reply = await call(server, "menu", ["path": "Host > Connect"])
    for _ in 0..<4 {
        if sheet(reply) == nil { reply = Reply(json: ["sheet": await call(server, "wait", ["until": "sheet", "timeout": 60]).json]) }
        let title = sheet(reply)?["title"] as? String ?? ""
        if title.hasPrefix("Trust the certificate") {
            reply = await call(server, "press", ["title": "Trust Once"])
        } else if title.hasPrefix("Log in to") {
            _ = await call(server, "set", ["id": "rdpLogin.password", "value": password])
            reply = await call(server, "press", ["title": "Log In"])
            break
        } else {
            Issue.record("unexpected: \(reply.json) \(reply.error ?? "")")
            break
        }
    }
    reply = await call(server, "wait", ["until": "rdp_connected", "timeout": 90])
    try #require(reply["state"] as? String == "connected", "\(reply.error ?? "")")
    let workspace = try #require(server.selectedDesktop), desktop = workspace.desktop
    let session = try #require(workspace.session)
    let copied = Recorder<String>()
    session.onClipboardText = { copied.append($0) }  // not the Mac's clipboard
    session.onClipboardFiles = { _, _ in }
    workspace.bar.remoteFiles = (0, 0)  // nothing fetched for Finder (onto the Mac's clipboard) when the focus leaves
    #expect(await call(server, "wait", ["until": "rdp_drawn", "timeout": 120]).error == nil)
    try await Task.sleep(nanoseconds: 4_000_000_000)  // the desktop settles
    let runner = WindowsRunner(session: session, shared: shared)

    // A window made bigger and at once smaller again: the desktop ends at the smaller size.
    let small = desktop.desktopSize
    #expect(small.width > 0)
    var frame = window.frame
    window.setFrame(NSRect(x: frame.minX, y: frame.minY, width: frame.width + 300, height: frame.height + 200), display: true)
    try await Task.sleep(nanoseconds: 800_000_000)
    window.setFrame(frame, display: true)
    var sizes: [CGSize] = []
    let resized = Date()
    #expect(await eventually(timeout: 120) {
        if sizes.last != desktop.desktopSize { sizes.append(desktop.desktopSize) }
        return desktop.desktopSize == small && (sizes.count > 1 || Date().timeIntervalSince(resized) > 60)
    }, "\(sizes)")
    try await Task.sleep(nanoseconds: 10_000_000_000)
    #expect(desktop.desktopSize == small, "\(sizes) \(desktop.desktopSize)")
    frame = window.frame

    // A click presses a Windows button: a form with one big button in the middle of the screen, which writes a file.
    #expect(try await runner.powershell("click", "Add-Type -AssemblyName System.Windows.Forms; "
        + "$f = New-Object Windows.Forms.Form; $f.StartPosition = 'CenterScreen'; $f.TopMost = $true; "
        + "$f.Size = New-Object Drawing.Size(560, 360); $b = New-Object Windows.Forms.Button; $b.Text = 'Click me'; "
        + "$b.Dock = 'Fill'; $b.Add_Click({ Set-Content \\\\tsclient\\AirSCP\\clicked-\(marker).txt ok; $f.Close() }); "
        + "$f.Controls.Add($b); $f.Add_Shown({ $f.Activate(); Set-Content \\\\tsclient\\AirSCP\\shown-\(marker).txt x }); "
        + "[void]$f.ShowDialog()") { exists(shared + "/shown-\(marker).txt") }, "\(read(shared + "/airscp.log") ?? "")")
    try await Task.sleep(nanoseconds: 2_000_000_000)
    let middle = desktop.convert(NSPoint(x: desktop.bounds.midX, y: desktop.bounds.midY), to: nil)
    #expect(await call(server, "click", ["x": middle.x, "y": frame.height - middle.y]).error == nil)
    #expect(await eventually(timeout: 20) { exists(shared + "/clicked-\(marker).txt") }, "the button wasn't pressed")

    // The desktop's own pixels (Retina: twice the window's points), clicked as they are.
    try await clickTheMagentaTarget(server, runner, shared: shared)

    // Keys first (the agent guide's advice for Windows): the Windows key and Explorer's shortcuts reach Windows. Win+R
    // runs a command; Win+E opens Explorer, Alt+D its address bar for a path, Return goes there and Ctrl+Shift+N makes
    // a folder in it: the shared folder, so the Mac sees it.
    #expect(await call(server, "key", ["combo": "win+r", "target": "rdp"]).error == nil)
    try await Task.sleep(nanoseconds: 3_000_000_000)  // the Run box opens
    #expect(await call(server, "type", ["text": "cmd /c echo ok> \\\\tsclient\\AirSCP\\winr-\(marker).txt",
                                        "target": "rdp"]).error == nil)
    #expect(await call(server, "key", ["combo": "return", "target": "rdp"]).error == nil)
    #expect(await eventually(timeout: 60) { exists(shared + "/winr-\(marker).txt") }, "Win+R and the command didn't reach Windows")
    var made = false
    for _ in 0..<3 where !made {  // a busy Windows can open Explorer after the keys meant for it
        #expect(await call(server, "key", ["combo": "win+e", "target": "rdp"]).error == nil)
        try await Task.sleep(nanoseconds: 5_000_000_000)
        #expect(await call(server, "key", ["combo": "alt+d", "target": "rdp"]).error == nil)
        #expect(await call(server, "type", ["text": "\\\\tsclient\\AirSCP", "target": "rdp"]).error == nil)
        #expect(await call(server, "key", ["combo": "return", "target": "rdp"]).error == nil)
        try await Task.sleep(nanoseconds: 4_000_000_000)
        #expect(await call(server, "key", ["combo": "ctrl+shift+n", "target": "rdp"]).error == nil)
        made = await eventually(timeout: 20) { exists(shared + "/New folder") }
        _ = await call(server, "key", ["combo": "escape", "target": "rdp"])  // keeps the name
        _ = await call(server, "key", ["combo": "ctrl+w", "target": "rdp"])  // closes Explorer (nothing on the desktop)
    }
    #expect(made, "Win+E, Alt+D, the path and Ctrl+Shift+N didn't make a folder in \\tsclient\\AirSCP")

    // Typing into Notepad: read back through Windows' clipboard (Ctrl+A, Ctrl+C).
    // An empty file of its own; Windows 11's Notepad may still show an earlier run's unsaved tab, so the text replaces
    // whatever is there (Ctrl+A first).
    #expect(try await runner.powershell("notepad", "$t = \"$env:TEMP\\airscp-\(marker).txt\"; New-Item -Force $t | Out-Null; "
        + "Start-Process notepad $t; Start-Sleep 6; "
        + "Set-Content \\\\tsclient\\AirSCP\\notepad-\(marker).txt x") { exists(shared + "/notepad-\(marker).txt") },
        "\(read(shared + "/airscp.log") ?? "")")
    // The made-up word last: Notepad's autocorrect turns "Ünïcödé " (with the space after it) into "Unicode ".
    let text = "Win→Mac ñ 中文 ✓ 123 ABC xyz ctrl test 4242 Ünïcödé"
    #expect(await call(server, "key", ["combo": "cmd+a", "target": "rdp"]).error == nil)
    #expect(await call(server, "type", ["text": text, "target": "rdp"]).error == nil)
    #expect(await call(server, "key", ["combo": "cmd+a", "target": "rdp"]).error == nil)
    #expect(await call(server, "key", ["combo": "cmd+c", "target": "rdp"]).error == nil)
    #expect(await eventually(timeout: 20) { copied.all.last == text }, "\(copied.all)")
    _ = try await runner.powershell("closenotepad", "Stop-Process -Name notepad -Force; "
        + "Remove-Item -Force \"$env:TEMP\\airscp-\(marker).txt\"; "
        + "Set-Content \\\\tsclient\\AirSCP\\closed-\(marker).txt x") { exists(shared + "/closed-\(marker).txt") }

    // Once Windows has closed what it wrote in the shared folder: Disconnect would otherwise ask first.
    #expect(await eventually { RDPSession.filesBeingWritten(in: shared).isEmpty }, "\(RDPSession.filesBeingWritten(in: shared))")
    _ = await call(server, "menu", ["path": "Host > Disconnect"])
    #expect(await call(server, "wait", ["until": "disconnected", "host": "Windows VM", "timeout": 30]).error == nil)
}

}
