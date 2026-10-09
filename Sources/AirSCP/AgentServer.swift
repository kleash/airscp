import AirSCPCore
import AppKit
import CoreImage
import Darwin
import SwiftUI

/// Agent control (PLAN.md T): AI agents and scripts drive AirSCP as the user would, through `AirSCP --mcp` (MCP) or
/// `AirSCP --agent` (one tool from a shell), with no Accessibility or Screen Recording permission. Those talk to this
/// server: a unix socket in `<support dir>/agent` (0700) that takes one JSON request per connection, `{tool, arguments,
/// token}`, from processes of the same user carrying the token in `agent/token` (0600, new each time it starts), and
/// answers in MCP's tool-result shape. Tools reach the app the way the user does: menu items through their own
/// validation (a disabled item says why), buttons and fields of windows and sheets through the accessibility tree
/// VoiceOver reads (SwiftUI's too), keys and clicks as events, and what no click should carry (drop, select, sort, go,
/// open, wait, snapshot) by calling what the drop, table and Go to Folder code calls. Screenshots are drawn by AirSCP
/// itself.
/// The app's own questions stay in the way: Delete still asks, and the agent presses "Delete".
@MainActor
final class AgentServer {
    weak var main: MainWindowController?
    let model: AppModel
    /// The app's windows besides the main one (Settings, Keys, editors, app-modal alerts): all of NSApp's; tests, which
    /// share NSApp with other tests' windows, give none.
    let otherWindows: () -> [NSWindow]
    nonisolated let socketPath: String
    nonisolated private let tokenPath: String
    nonisolated private let token: String
    nonisolated private let listener: Int32
    private(set) var lastRequest: Date?
    /// The request before the latest (the snapshot's agent.lastRequest: the latest is the snapshot itself).
    private(set) var previousRequest: Date?
    private var closed = false

    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    init(main: MainWindowController?, model: AppModel, directory: URL = AgentBridge.directory,
         windows: (() -> [NSWindow])? = nil) throws {
        self.main = main
        self.model = model
        otherWindows = windows ?? { NSApp.windows }
        let dir = directory.path
        socketPath = dir + "/sock"
        tokenPath = dir + "/token"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(dir, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), chmod(dir, 0o700) == 0 else {
            throw AirSCPError(.other, "The agent folder \(dir) isn't a folder of yours.")
        }
        if Self.answers(socketPath) {
            throw AirSCPError(.other, "Another AirSCP with this settings folder is already under agent control: quit it, then "
                              + "switch the setting off and on again.")
        }
        unlink(socketPath)
        var random = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&random, random.count)
        token = random.map { String(format: "%02x", $0) }.joined()
        DebugLog.Secrets.add(token)
        guard var address = AgentBridge.unixAddress(socketPath) else {
            let message = AgentBridge.socketPathProblem(socketPath) ?? ""
            log.error("agent control: \(message, privacy: .public)")
            rmdir(dir)
            throw AirSCPError(.other, message)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AirSCPError(.other, "Can't create the agent socket.") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(fd, SOMAXCONN) == 0 else {  // many calls at once
            Darwin.close(fd)
            throw AirSCPError(.other, "Can't listen on the agent socket: \(String(cString: strerror(errno)))")
        }
        listener = fd
        let file = open(tokenPath, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0, fchmod(file, 0o600) == 0, write(file, token, token.utf8.count) == token.utf8.count else {
            if file >= 0 { Darwin.close(file) }
            Darwin.close(fd)
            unlink(socketPath)
            throw AirSCPError(.other, "Can't write the agent token: \(String(cString: strerror(errno)))")
        }
        Darwin.close(file)
        // SwiftUI builds its accessibility nodes only for an assistive app: this is the flag such an app sets.
        Self.setEnhancedUserInterface(true)
        Thread.detachNewThread { [weak self] in self?.acceptLoop(fd) }
        log.log("agent control on: \(self.socketPath, privacy: .public)")
    }

    /// Closes the socket and removes it and the token (Settings switched off, Quit).
    func close() {
        guard !closed else { return }
        closed = true
        shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
        unlink(socketPath)
        unlink(tokenPath)
        rmdir((socketPath as NSString).deletingLastPathComponent)
        Self.setEnhancedUserInterface(false)
        log.log("agent control off")
    }

    /// Servers open now: the flag stays set while any is (the tests run several at once).
    private static var openServers = 0

    private static func setEnhancedUserInterface(_ on: Bool) {
        openServers += on ? 1 : -1
        guard openServers == (on ? 1 : 0) else { return }
        _ = (NSApp as NSObject).perform(NSSelectorFromString("accessibilitySetValue:forAttribute:"),
                                        with: NSNumber(value: on), with: "AXEnhancedUserInterface")
    }

    /// Whether something listens at `path` (a socket left by a crash doesn't).
    private nonisolated static func answers(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0, var address = AgentBridge.unixAddress(path) else { return false }
        defer { Darwin.close(fd) }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }

    // MARK: Requests

    private nonisolated func acceptLoop(_ fd: Int32) {
        while true {
            let connection = accept(fd, nil, nil)
            if connection < 0 {
                if errno == EINTR || errno == ECONNABORTED { continue }
                return  // closed
            }
            _ = fcntl(connection, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // A request comes at once: a connection that sends nothing doesn't hold its thread for long.
            var limit = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
            Thread.detachNewThread { [weak self] in
                guard let self else {
                    Darwin.close(connection)
                    return
                }
                self.serve(connection)
            }
        }
    }

    /// One request: only from this user, at most 1 MB of JSON, with the token; anything else gets no answer.
    private nonisolated func serve(_ connection: Int32) {
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(connection, &uid, &gid) == 0, uid == getuid() else {
            Darwin.close(connection)
            return
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = recv(connection, &buffer, buffer.count, 0)
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
            if data.count > 1 << 20 {
                Darwin.close(connection)
                return
            }
        }
        guard let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              request["token"] as? String == token, let tool = request["tool"] as? String else {
            Darwin.close(connection)
            return
        }
        let arguments = request["arguments"] as? [String: Any] ?? [:]
        let client = String((request["client"] as? String ?? "an agent").prefix(80))
        var peer: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        getsockopt(connection, SOL_LOCAL, LOCAL_PEERPID, &peer, &length)
        Task { @MainActor [weak self] in
            let reply = await self?.handle(tool, arguments, from: peer, client: client) ?? AgentBridge.failure("AirSCP is closing.")
            let body = JSONSerialization.isValidJSONObject(reply) ? (try? JSONSerialization.data(withJSONObject: reply)) ?? Data()
                : Data()
            DispatchQueue.global().async {
                body.withUnsafeBytes { raw in
                    var sent = 0
                    while sent < raw.count {
                        let count = send(connection, raw.baseAddress! + sent, raw.count - sent, 0)
                        if count < 0 && errno == EINTR { continue }
                        if count <= 0 { break }
                        sent += count
                    }
                }
                Darwin.close(connection)
            }
        }
    }

    /// Runs a tool and answers as MCP does: text (JSON) or an image, `isError` on failure. `client` (the MCP client's
    /// name) and the request, in plain words, go to the sidebar's indicator.
    func handle(_ tool: String, _ arguments: [String: Any], from peer: pid_t = 0, client: String = "an agent") async -> [String: Any] {
        previousRequest = lastRequest
        lastRequest = Date()
        let (text, target) = describe(tool, arguments)
        // A screenshot shows the window as the request found it: the indicator lights up for it once it is drawn.
        if tool != "screenshot" { model.agentActed(text, target: target, client: client, pid: peer) }
        log.log("agent: \(tool, privacy: .public)")
        // An Open or Save panel the action opens takes these instead of showing (agents can't drive panels).
        let choice = ["menu", "press", "set", "key", "click"].contains(tool)
            ? (arguments["files"] as? [String]) ?? (arguments["file"] as? String).map { [$0] } : nil
        // Only a request that brings a choice sets or clears it (another request may be under way meanwhile).
        if let choice {
            Panels.agentChoice = choice.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
            Panels.agentProblem = nil
            Panels.agentPanelFolder = nil
        }
        defer {
            if choice != nil {
                Panels.agentChoice = nil
                Panels.agentProblem = nil
                Panels.agentPanelFolder = nil
            }
        }
        do {
            var result: [String: Any]
            switch tool {
            case "snapshot":
                if let spec = arguments["in"] as? String { _ = try scopes(spec) }  // a window that isn't there says so
                result = snapshot(arguments)
            case "screenshot":
                defer { model.agentActed(text, target: target, client: client, pid: peer) }
                return try screenshot(arguments)
            case "menu": result = try await menu(arguments)
            case "press": result = try await press(arguments)
            case "set": result = try await set(arguments)
            case "key": result = try await key(arguments)
            case "type": result = try await type(arguments)
            case "click": result = try await click(arguments)
            case "focus": result = try await focus(arguments)
            case "go": result = try await go(arguments)
            case "open": result = try await openRow(arguments)
            case "select": result = try await select(arguments)
            case "sort": result = try await sort(arguments)
            case "drop": result = try await drop(arguments)
            case "wait": result = try await wait(arguments, client: peer)
            default: throw Failure("AirSCP has no tool “\(tool)”. Tools: " + AgentBridge.tools.compactMap { $0["name"] as? String }.joined(separator: ", "))
            }
            if choice != nil {
                // A panel some commands open a moment later (a pop-up's choice, after its menu closed).
                let deadline = Date().addingTimeInterval(5)
                while Panels.agentChoice != nil && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
                if let problem = Panels.agentProblem { throw Failure(problem) }
                if Panels.agentChoice != nil { result["note"] = "No Open or Save panel opened: file wasn't used." }
                if let folder = Panels.agentPanelFolder { result["panelFolder"] = folder }  // where it would have opened
            }
            if let png = result.removeValue(forKey: "picture") as? Data { return Self.imageReply(png, result) }  // a click's
            return Self.text(result)
        } catch let failure as Failure {
            return AgentBridge.failure(failure.message)
        } catch {
            return AgentBridge.failure((error as? AirSCPError)?.message ?? error.localizedDescription)
        }
    }

    /// A request in plain words for the indicator (nil for a snapshot, which only looks), and where it acts: the sheet
    /// in front, the window named, or the host shown. Never a secret: a value set is shown only for a field that is there
    /// and isn't secure (else "•••"), typed text isn't shown.
    func describe(_ tool: String, _ arguments: [String: Any]) -> (text: String?, target: String) {
        func string(_ key: String) -> String? { (arguments[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func quoted(_ text: String) -> String { "“" + (text.count > 40 ? text.prefix(40) + "…" : text) + "”" }
        let desktop = ["rdp", "desktop"].contains(string("target")?.lowercased() ?? "")
        let panes = ["left": "the left pane", "right": "the right pane", "sidebar": "the sidebar",
                     "processes": "the Monitor's processes", "transfers": "the Transfers list"]
        let pane = string("pane").map { panes[$0.lowercased()] ?? $0 }
        let text: String?
        switch tool {
        case "menu":
            let path = (string("path") ?? "").components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }
            text = path.first?.lowercased() == "context"
                ? "Chose \(quoted(path.dropFirst().joined(separator: " ▸ "))) in the context menu of \(pane ?? "the focused pane")"
                : "Chose " + path.joined(separator: " ▸ ")
        case "press": text = "Pressed " + quoted(string("title") ?? string("id") ?? "?")
        case "set":
            let field = string("id") ?? string("title") ?? "?"
            // The value only of a field that is there and isn't secure: one that isn't there (yet) may be a password
            // field, such as prompt.answer just before its sheet opens.
            let plain = (try? scopes(string("in"))).flatMap { windows in
                windows.lazy.compactMap { self.field(field, in: AXNode.flatten($0)) }.first
            }.map { !$0.isSecure } ?? false
            let value: String
            switch arguments["value"] {
            case let flag as NSNumber where CFGetTypeID(flag) == CFBooleanGetTypeID(): value = flag.boolValue ? "on" : "off"
            case let other?: value = "\(other)"
            case nil: value = ""
            }
            text = "Set \(quoted(field)) to " + (plain && !field.lowercased().contains("password") ? quoted(value) : "•••")
        case "key": text = "Pressed \(string("combo") ?? "a key")" + (desktop ? " on the Windows desktop" : "")
        case "type": text = "Typed \((string("text") ?? "").count) characters" + (desktop ? " on the Windows desktop" : "")
        case "click":
            let count = (arguments["count"] as? Int ?? 1) > 1 ? "Double-clicked" : string("button") == "right" ? "Right-clicked" : "Clicked"
            text = arguments["wheel"] != nil ? "Turned the mouse wheel on the Windows desktop"
                : "\(count) at \(arguments["x"].map { "\($0)" } ?? "?"), \(arguments["y"].map { "\($0)" } ?? "?")"
        case "focus": text = "Focused " + (pane ?? string("target") ?? "a pane")
        case "go": text = "Went to \(quoted(string("path") ?? "?")) in \(pane ?? "the right pane")"
        case "open": text = "Opened \(quoted(string("name") ?? "?")) in \(pane ?? "the right pane")"
        case "select":
            let names = (arguments["names"] as? [String]) ?? string("names").map { [$0] } ?? []
            let what = arguments["all"] as? Bool == true ? "everything" : arguments["none"] as? Bool == true ? "nothing"
                : names.isEmpty ? "\((arguments["ids"] as? [String])?.count ?? 0) transfers" : names.prefix(3).map(quoted).joined(separator: ", ")
                    + (names.count > 3 ? " and \(names.count - 3) more" : "")
            text = "Selected \(what) in " + (pane ?? (string("in") != nil ? "a list" : "the sidebar"))
        case "sort": text = "Sorted \(pane ?? "a list") by \(string("column") ?? "?")"
        case "drop":
            if let files = arguments["files"] as? [String] {
                text = "Dropped \(files.count == 1 ? quoted((files[0] as NSString).lastPathComponent) : "\(files.count) files") on "
                    + (desktop ? "the Windows desktop" : string("target")?.lowercased() == "keys" ? "the Keys window"
                        : pane ?? "the right pane")
            } else {
                text = "Dropped the selected rows of the \(string("from") ?? "?") pane on " + (string("to").map {
                    $0.hasPrefix("local:") || $0.hasPrefix("finder:") ? "a folder of this Mac" : "the \($0) pane"
                } ?? "?")
            }
        case "wait": text = "Waited until \(string("until") ?? "?")" + (string("host").map { " (\($0))" } ?? "")
        case "screenshot": text = "Took a screenshot" + (string("target").map { $0 == "main" ? "" : " (\($0))" } ?? "")
        default: text = nil  // snapshot: it only looks
        }
        var target = main?.window?.title ?? "AirSCP"
        if let spec = string("in"), let window = try? scopes(spec).first {
            target = window.sheetParent == nil ? "the window “\(window.title)”" : "a sheet"
        } else if let sheet = openSheets().last, ["press", "set", "key", "type"].contains(tool) {
            target = "the sheet “\(sheetJSON(sheet)["title"] as? String ?? sheet.title)”"
        }
        return (text, target)
    }

    static func text(_ json: [String: Any], isError: Bool = false) -> [String: Any] {
        // NSJSONSerialization raises (an Objective-C exception no Swift code catches) for NaN and infinite numbers.
        let safe = finite(json)
        let data = JSONSerialization.isValidJSONObject(safe)
            ? (try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            : Data("{}".utf8)
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "isError": isError]
    }

    /// `value` with NaN and infinite numbers as null.
    static func finite(_ value: Any) -> Any {
        switch value {
        case let number as NSNumber where CFGetTypeID(number) != CFBooleanGetTypeID():
            return number.doubleValue.isFinite ? number : NSNull()
        case let array as [Any]: return array.map(finite)
        case let object as [String: Any]: return object.mapValues(finite)
        default: return value
        }
    }

    /// After an action: a moment for what it opens, then the frontmost sheet and the banner.
    private func acted(_ extra: [String: Any] = [:]) async -> [String: Any] {
        try? await Task.sleep(nanoseconds: 250_000_000)
        var json = extra
        json["ok"] = true
        if let sheet = openSheets().last { json["sheet"] = sheetJSON(sheet) }
        if let workspace = main?.selectedWorkspace, workspace.connection.state != .connected {
            json["banner"] = workspace.connection.state == .idle ? ConnectionBanner.idleText(workspace.host)
                : MainWindowController.describe(workspace.connection.state)
        }
        return json
    }

    /// Runs `action` from the run loop, as a menu choice or a click runs, rather than inside this request: one that opens
    /// a modal loop (an app-modal alert, Quit's wait for the disconnects) then doesn't hold up the reply, and the main
    /// queue keeps draining in that loop (it wouldn't inside a main-queue block).
    private func perform(_ action: @escaping () -> Void) async -> [String: Any] {
        await Self.later(action)
        return await acted()
    }

    /// Runs `action` from a run-loop timer and returns once it has run, or once it has opened a modal loop (in which
    /// this task goes on).
    static func later(_ action: @escaping () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            RunLoop.main.add(Timer(timeInterval: 0, repeats: false) { _ in
                continuation.resume()  // this task continues after the action, or inside its modal loop
                action()
            }, forMode: .common)
        }
    }

    private var mainWindow: NSWindow {
        get throws {
            guard let window = main?.window else { throw Failure("AirSCP's window isn't there.") }
            return window
        }
    }

    // MARK: Menus

    private func normalized(_ title: String) -> String {
        var text = title.trimmingCharacters(in: .whitespaces).lowercased()
        for suffix in ["…", "...", ":"] where text.hasSuffix(suffix) { text = String(text.dropLast(suffix.count)) }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private func menu(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard let path = arguments["path"] as? String else { throw Failure("menu needs a path, e.g. \"Host > Connect\".") }
        let parts = path.components(separatedBy: ">").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if parts.first.map(normalized) == "context" {
            return try await contextMenu(parts.dropFirst().joined(separator: " > "), pane: arguments["pane"] as? String)
        }
        guard var menu = NSApp.mainMenu else { throw Failure("AirSCP has no menu bar yet.") }
        let window = try (arguments["in"] as? String).map { try scopes($0).last! }
        var found: NSMenuItem?
        for (index, part) in parts.enumerated() {
            let current = menu
            current.delegate?.menuNeedsUpdate?(current)
            // As AppKit validates a menu before it opens: some titles are set then ("Upload to “w”").
            if index > 0 { current.items.filter { $0.action != nil }.forEach { _ = validate($0, in: window) } }
            let items = current.items.filter { !$0.isSeparatorItem && !$0.title.isEmpty }
            guard let item = items.first(where: { $0.title == part }) ?? items.first(where: { normalized($0.title) == normalized(part) })
            else {
                throw Failure("No menu item “\(part)”" + (index > 0 ? " in \(parts[..<index].joined(separator: " > "))" : "")
                              + ". There: " + items.map(\.title).joined(separator: ", "))
            }
            found = item
            if index < parts.count - 1 {
                guard let submenu = item.submenu else { throw Failure("“\(item.title)” has no submenu.") }
                menu = submenu
            }
        }
        guard let item = found, item.action != nil else { throw Failure("“\(path)” is a menu, not a command.") }
        let check = validate(item, in: window)
        guard check.enabled, let target = check.target else {
            throw Failure("“\(path)” is disabled now" + (check.reason.map { ": " + $0 } ?? "."))
        }
        let action = item.action!
        if action == #selector(NSApplication.terminate(_:)) {
            if let sheet = openSheets().last {  // AppKit doesn't quit then (it beeps)
                throw Failure("AirSCP doesn't quit while a sheet is open: answer or cancel “\(sheetJSON(sheet)["title"] as? String ?? sheet.title)” first.")
            }
            // AirSCP asks first while transfers run or an editor has unsaved changes (AppDelegate): that question is
            // the answer. Otherwise quitting ends this server: answer first, then quit.
            let asks = NSApp.windows.contains { $0.isDocumentEdited && ($0.isVisible || $0.isMiniaturized) }
                || main?.workspaces.values.contains { $0.runningTransferCount > 0 } == true
                || main?.desktops.values.contains { !$0.filesBeingCopied().isEmpty } == true
            if asks { return await perform { NSApp.sendAction(action, to: target, from: item) } }
            (target as? NSObject)?.perform(action, with: item, afterDelay: 0.3, inModes: [.common])
            return ["ok": true, "quitting": true]
        }
        return await perform { NSApp.sendAction(action, to: target, from: item) }
    }

    /// Quick Look's panel shows only while AirSCP is the active app: an agent could neither see it nor close it again.
    static let noQuickLook = "Quick Look is for a person at the screen: an agent can neither see its panel nor close it. "
        + "Download the file (drop from=… to=\"local:<folder>\") and read it there."

    /// Whether the item is enabled now (its target's own validation, as AppKit checks before showing a menu), the
    /// reason FilePane gives when not, and the object that would get its action (from `window`'s responder chain, if
    /// given).
    func validate(_ item: NSMenuItem, in window: NSWindow? = nil) -> (enabled: Bool, reason: String?, target: AnyObject?) {
        guard let action = item.action else { return (false, nil, nil) }
        if action == #selector(FilePane.quickLook(_:)) { return (false, Self.noQuickLook, nil) }
        guard let target = target(for: action, explicit: item.target, in: window) else {
            let filesShown = main?.selectedWorkspace.map { $0.browser.isViewLoaded && $0.browser.view.window != nil } ?? false
            return (false, !FilePane.instancesRespond(to: action) ? "Nothing in AirSCP can do that now."
                        : main?.selectedWorkspace != nil && !filesShown ? "The Files tab isn't shown: press title=Files first."
                        : "No file pane has the focus: focus pane=left or right first.", nil)
        }
        var enabled = true
        if let validator = target as? NSMenuItemValidation {
            enabled = validator.validateMenuItem(item)
        } else if let validator = target as? NSUserInterfaceValidations {
            enabled = validator.validateUserInterfaceItem(item)
        }
        guard !enabled else { return (true, nil, target) }
        return (false, Self.reason(item) ?? disabledReason(target, action), target)
    }

    /// The reason a disabled item's validation put in its tooltip (not what it does: that is its tooltip otherwise).
    static func reason(_ item: NSMenuItem) -> String? {
        item.toolTip.flatMap { $0.isEmpty || $0 == MenuHelp.tip(for: item) ? nil : $0 }
    }

    /// Why a command of the main window or a pane is off, or one of AppKit's own (Undo, Close…), when it doesn't say itself.
    private func disabledReason(_ target: AnyObject, _ action: Selector) -> String? {
        if let window = (target as? NSWindow) ?? (target as? NSViewController)?.view.window ?? (target as? NSWindowController)?.window,
           let sheet = window.attachedSheet {
            return "A sheet is open: answer it first (“\(sheetJSON(sheet)["title"] as? String ?? "")”)."
        }
        if let reason = Self.standardReasons[NSStringFromSelector(action)] { return reason }
        guard target is MainWindowController, let main else { return nil }
        guard let id = main.sidebar.selection?.id else { return "Nothing is selected in the sidebar: select pane=sidebar first." }
        if action == #selector(MainWindowController.runCommand(_:)),
           let reason = main.selectedWorkspace?.session.capabilities.noShellReason {
            return reason  // an sftp-only account
        }
        let name = model.host(id)?.displayName ?? model.rdpEntry(id)?.displayName ?? ""
        let state = model.host(id) != nil ? MainWindowController.describe(model.states[id] ?? .idle)
            : MainWindowController.describe(model.rdpStates[id] ?? .idle)
        return "Not for “\(name)” now (\(state.lowercased().replacingOccurrences(of: "…", with: ""))), or not for this kind of item."
    }

    /// AppKit's own commands are off for these reasons (the text ones in a field or an editor).
    static let standardReasons = [
        "undo:": "Nothing to undo.", "redo:": "Nothing to redo.", "unhideAllApplications:": "No other app is hidden.",
        "hide:": "macOS doesn't hide AirSCP now.", "cut:": "Select some text first.", "copy:": "Select some text first.",
        "paste:": "Nothing to paste here.", "delete:": "Select some text first.", "selectAll:": "Nothing to select here.",
    ]

    /// The responder chain a menu command takes: `window`'s (a sheet's, then the window it is on), else the key
    /// window's (or, while AirSCP isn't the active app, the main window's) first responder up to its window and
    /// controller; then the app and its delegate.
    private func target(for action: Selector, explicit: AnyObject?, in window: NSWindow? = nil) -> AnyObject? {
        if let explicit { return explicit.responds(to: action) ? explicit : nil }
        var chain: [AnyObject] = []
        let windows = window.map { [$0] + ($0.sheetParent.map { [$0] } ?? []) } ?? [NSApp.keyWindow, main?.window].compactMap { $0 }
        for window in windows where isOurs(window) {
            var responder: NSResponder? = window.firstResponder
            while let current = responder {
                chain.append(current)
                responder = current.nextResponder
            }
            chain.append(window)
            if let delegate = window.delegate { chain.append(delegate) }
            if let controller = window.windowController { chain.append(controller) }
        }
        chain.append(NSApp)
        if let delegate = NSApp.delegate { chain.append(delegate) }
        return chain.first { $0.responds(to: action) }
    }

    /// A file pane's context menu: the same entries and checks as a right-click on the selected rows.
    private func contextMenu(_ title: String, pane name: String?) async throws -> [String: Any] {
        if name?.lowercased() == "transfers" {  // the Transfers panel's menu, for its selected jobs
            let jobs = TransferCenter.shared.jobs.filter { model.transferSelection.ids.contains($0.id) }
            guard !jobs.isEmpty else { throw Failure("Select the jobs first: select pane=transfers names=[…] (or ids=[…]).") }
            let actions = TransfersPanel.actions(for: jobs)
            guard let action = actions.first(where: { normalized($0.title) == normalized(title) }) else {
                throw Failure("The Transfers context menu has no “\(title)”. There: " + actions.map(\.title).joined(separator: ", "))
            }
            guard action.enabled else { throw Failure("“\(action.title)” is disabled now for the selected jobs.") }
            return await perform(action.run)
        }
        let pane = try self.pane(name)
        let entries = pane.contextMenu(for: pane.selectedItems).compactMap { $0 }
        guard let (label, action) = entries.first(where: { $0.0 == title }) ?? entries.first(where: { normalized($0.0) == normalized(title) })
        else { throw Failure("The context menu has no “\(title)”. There: " + entries.map(\.0).joined(separator: ", ")) }
        let item = NSMenuItem(title: label, action: action, keyEquivalent: "")
        item.target = pane
        guard action != #selector(FilePane.quickLook(_:)) else { throw Failure(Self.noQuickLook) }
        guard pane.validateMenuItem(item) else { throw Failure("“\(label)” is disabled now" + (Self.reason(item).map { ": " + $0 } ?? ".")) }
        return await perform { NSApp.sendAction(action, to: pane, from: item) }
    }

    // MARK: Panes

    /// The selected host's file pane: left or right, else the focused one (right when neither is).
    func pane(_ name: String?) throws -> FilePane {
        guard let browser = main?.selectedWorkspace?.browser, browser.isViewLoaded else {
            throw Failure("No host's Files tab is shown: select a host in the sidebar (select pane=sidebar).")
        }
        guard browser.view.window != nil else { throw Failure("The Files tab isn't shown: press title=Files first.") }
        switch name?.lowercased() {
        case "left"?: return browser.left
        case "right"?: return browser.right
        case nil:
            let focused = browser.view.window?.firstResponder
            return focused === browser.left.table ? browser.left : browser.right
        default: throw Failure("pane is left or right (sidebar, processes or transfers for select; processes for sort).")
        }
    }

    // MARK: Buttons and fields

    /// Where to look for a control: `in` (sheet, window:<title>), else the frontmost sheet or alert, then the windows.
    func scopes(_ spec: String?) throws -> [NSWindow] {
        if let spec, spec.hasPrefix("window:") {
            let title = spec.dropFirst("window:".count).trimmingCharacters(in: .whitespaces)
            guard let window = appWindows.first(where: { $0.title == title })
                    ?? appWindows.first(where: { $0.title.localizedCaseInsensitiveContains(title) })
            else { throw Failure("No window “\(title)”. There: " + appWindows.map(\.title).joined(separator: ", ")) }
            return sheets(of: window).reversed() + [window]
        }
        let open = openSheets()
        if let spec {
            guard spec == "sheet" else { throw Failure("in is \"sheet\" or \"window:<title>\".") }
            guard let sheet = open.last else { throw Failure("No sheet is open.") }
            return [sheet]
        }
        // Not the windows a sheet covers: their controls can't be reached until it is answered.
        var result = open.reversed() + [NSApp.keyWindow].compactMap { $0 }.filter { isOurs($0) && $0.attachedSheet == nil }
        result += appWindows.filter { !result.contains($0) && $0.attachedSheet == nil }
        return result
    }

    /// The windows `press` and `set` look in: `scopes`, and for in=window:<title> only what a person reaches there, its
    /// sheet when it has one (the window under it can't be used until the sheet is answered).
    private func reachable(_ spec: String?) throws -> [NSWindow] {
        let windows = try scopes(spec)
        return spec?.hasPrefix("window:") == true ? Array(windows.prefix(1)) : windows
    }

    /// The sheet that stands in the way of a control that wasn't found in `windows` (`spec`'s), if any.
    private func coveringSheet(_ spec: String?, _ windows: [NSWindow]) -> NSWindow? {
        spec == nil ? openSheets().last : windows.first { $0.sheetParent != nil }
    }

    private func press(_ arguments: [String: Any]) async throws -> [String: Any] {
        let id = arguments["id"] as? String, title = arguments["title"] as? String
        guard id != nil || title != nil else { throw Failure("press needs an id or a title.") }
        let windows = try reachable(arguments["in"] as? String)
        for window in windows {
            if let panel = window as? NSSavePanel {
                if title.map(normalized) == "cancel" { return await perform { panel.cancel(nil) } }
                continue
            }
            let nodes = AXNode.flatten(window)
            let match = id.flatMap { id in nodes.first { $0.id == id } }
                ?? title.flatMap { title in
                    nodes.first { $0.isPressable && $0.title == title }
                        ?? nodes.first { $0.isPressable && normalized($0.title) == normalized(title) }
                }
            guard let node = match else { continue }
            guard node.enabled else {
                throw Failure("“\(id ?? title ?? "")” is disabled now" + (node.help.map { ": " + $0 } ?? ".")
                              + (openSheets().last.map { " " + describe(sheetJSON($0)) } ?? ""))
            }
            guard node.role != "popupbutton" && node.role != "menubutton" else {
                throw Failure("“\(id ?? title ?? "")” opens a menu: choose its option with set (value: the option's title).")
            }
            Self.reveal(node, in: window)
            return await perform { _ = node.press() }
        }
        if let sheet = coveringSheet(arguments["in"] as? String, windows) {
            throw Failure("Nothing to press called “\(id ?? title ?? "")” in the sheet that is open: answer or close it first. "
                          + describe(sheetJSON(sheet)))
        }
        throw Failure("Nothing to press called “\(id ?? title ?? "")”. Use snapshot (include: [\"sheets\", \"elements\"]) to see what there is.")
    }

    /// Scrolls `node` into view when a scroll view hides it (a long form: Settings, the editors on a short screen), as a
    /// person scrolls to a control before using it: a screenshot after the action shows it.
    static func reveal(_ node: AXNode, in window: NSWindow) {
        // The scroll views around it, innermost first: NSView.scrollToVisible moves only the closest one, and SwiftUI's
        // Form is a scroll view of its own (in Settings' own).
        let scrolls = node.view.map { sequence(first: $0, next: \.superview).compactMap { $0 as? NSScrollView } }
            ?? sequence(first: node, next: \.parent).prefix(60).compactMap { $0.object as? NSScrollView }
        for scroll in scrolls {
            guard let document = scroll.documentView else { continue }
            let rect = node.view.map { document.convert($0.bounds, from: $0) }
                ?? document.convert(window.convertFromScreen(node.frame), from: nil)
            let visible = scroll.documentVisibleRect
            guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite), !visible.contains(rect) else { continue }
            // In the middle, with what is around it (its caption): as far as the scroll view goes.
            document.scrollToVisible(NSRect(x: rect.minX, y: rect.midY - visible.height / 2, width: rect.width,
                                            height: visible.height))
        }
    }

    private func describe(_ json: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private func set(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard let value = arguments["value"] else { throw Failure("set needs a value.") }
        let query = (arguments["id"] as? String) ?? (arguments["title"] as? String)
        guard let query else { throw Failure("set needs an id or a title (a label, title or placeholder).") }
        let windows = try reachable(arguments["in"] as? String)
        // A row's box in Synchronize's list, by the item's path: its list makes rows only where it shows them.
        if arguments["id"] == nil, let sync = (windows.first?.contentViewController as? NSHostingController<SyncView>)?.rootView.model,
           let step = sync.plan.steps.first(where: { $0.path == query || $0.path + "/" == query }) {
            if (value as? Bool) ?? ["true", "on", "yes", "1"].contains("\(value)".lowercased()) {
                sync.unticked.remove(step.path)
            } else {
                sync.unticked.insert(step.path)
            }
            return await acted(["ticked": sync.chosen.steps.count])
        }
        for window in windows where !(window is NSSavePanel) {
            guard let node = field(query, in: AXNode.flatten(window)) else { continue }
            guard node.enabled else { throw Failure("“\(query)” is disabled now" + (node.help.map { ": " + $0 } ?? ".")) }
            Self.reveal(node, in: window)
            // SwiftUI's Menu fills its pop-up only as it opens (a moment later), with its buttons as they are then
            // (enabled or not): as if it were opened, then closed.
            if let popup = node.view as? NSPopUpButton, let menu = popup.menu,
               popup.pullsDown || menu.items.allSatisfy(\.isSeparatorItem) {
                menu.delegate?.menuWillOpen?(menu)
                try? await Task.sleep(nanoseconds: 150_000_000)
                defer { menu.delegate?.menuDidClose?(menu) }
                try set(node, to: value)
                return await acted()
            }
            try set(node, to: value)
            // A pane's filter: its rows are filtered off the main thread; the reply has them (as sort waits for its rows).
            if let pane = [main?.selectedWorkspace?.browser.left, main?.selectedWorkspace?.browser.right]
                .compactMap({ $0 }).first(where: { $0.filterField === node.view }) {
                let wanted = (value as? String) ?? "\(value)", deadline = Date().addingTimeInterval(10)
                while (pane.filter != wanted || pane.rebuilding) && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
                return await acted(["pane": paneJSON(pane, rows: 20)])
            }
            return await acted()
        }
        if let sheet = coveringSheet(arguments["in"] as? String, windows) {
            throw Failure("No field “\(query)” in the sheet that is open: answer or close it first. " + describe(sheetJSON(sheet)))
        }
        throw Failure("No field “\(query)”. Use snapshot (include: [\"sheets\", \"elements\"]) to see the fields.")
    }

    /// A field by id, title, placeholder, the label in front of it, or "password" for the password field.
    private func field(_ query: String, in nodes: [AXNode]) -> AXNode? {
        let wanted = normalized(query)
        if let node = nodes.first(where: { $0.id == query }) { return node }
        let fields = nodes.filter(\.isField)
        if let node = fields.first(where: { normalized($0.title) == wanted }) ?? fields.first(where: { normalized($0.placeholder) == wanted }) {
            return node
        }
        if let node = fields.first(where: { Self.label(of: $0, in: nodes).map(normalized) == wanted }) { return node }
        if ["password", "passphrase"].contains(wanted) { return fields.first(where: \.isSecure) }
        // SwiftUI joins a control's label texts with ", ": an import checkbox is "web, deploy@web.example.com".
        return fields.first { normalized($0.title).hasPrefix(wanted + ",") }
    }

    private func set(_ node: AXNode, to value: Any) throws {
        let text: String
        switch value {
        case let string as String: text = string
        case let flag as NSNumber where CFGetTypeID(flag) == CFBooleanGetTypeID(): text = flag.boolValue ? "true" : "false"
        case let number as NSNumber: text = number.stringValue
        default: text = "\(value)"
        }
        let on = ["true", "on", "yes", "1"].contains(text.lowercased())
        switch node.view {
        case let popup as NSPopUpButton:
            if let menu = popup.menu { menu.delegate?.menuNeedsUpdate?(menu) }  // menus filled as they open
            let titles = popup.itemArray.filter { !$0.isSeparatorItem }
            // The title, else one with these words in it ("zip": "ZIP archive (.zip)", not "Gzipped tar…"), else a part.
            let words = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: text) + "(?![\\p{L}\\p{N}])"
            let matches = titles.filter { $0.title == text }.first.map { [$0] }
                ?? titles.filter { normalized($0.title) == normalized(text) }.nilIfEmpty
                ?? titles.filter { $0.title.range(of: words, options: [.regularExpression, .caseInsensitive]) != nil }.nilIfEmpty
                ?? titles.filter { $0.title.localizedCaseInsensitiveContains(text) }
            guard matches.count == 1, let item = matches.first else {
                throw Failure("“\(text)” \(matches.isEmpty ? "isn't one" : "matches more than one") of the choices: "
                              + titles.map(\.title).filter { !$0.isEmpty }.joined(separator: ", "))
            }
            guard item.isEnabled else { throw Failure("“\(item.title)” can't be chosen now" + (item.toolTip.map { ": " + $0 } ?? ".")) }
            // As choosing it in the open menu does: the item's action (SwiftUI's pickers listen there), else the pop-up's.
            if let menu = popup.menu, let index = menu.items.firstIndex(of: item), item.action != nil {
                menu.performActionForItem(at: index)
            } else {
                popup.select(item)
                popup.sendAction(popup.action, to: popup.target)
            }
        case let segments as NSSegmentedControl:
            guard let index = (0..<segments.segmentCount).first(where: { normalized(segments.label(forSegment: $0) ?? "") == normalized(text) })
            else { throw Failure("“\(text)” isn't one of the choices.") }
            segments.selectedSegment = index
            segments.sendAction(segments.action, to: segments.target)
        case let field as NSTextField:
            guard let window = field.window else { throw Failure("The field isn't in a window.") }
            window.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else {
                field.stringValue = text
                return
            }
            editor.selectAll(nil)
            editor.insertText(text, replacementRange: editor.selectedRange())
        case let textView as NSTextView:
            // Replaced as a paste does, character for character (inserting as typed drops a leading U+FEFF). A byte order
            // mark the text starts with stays: JSON can't bring one (Foundation drops it from the front of a string).
            let text = textView.string.hasPrefix("\u{FEFF}") && !text.hasPrefix("\u{FEFF}") ? "\u{FEFF}" + text : text
            textView.window?.makeFirstResponder(textView)
            let all = NSRange(location: 0, length: (textView.string as NSString).length)
            guard textView.shouldChangeText(in: all, replacementString: text), let storage = textView.textStorage else {
                throw Failure("The text can't be changed now.")
            }
            storage.replaceCharacters(in: all, with: NSAttributedString(string: text, attributes: textView.typingAttributes))
            textView.didChangeText()
        case let button as NSButton where node.role == "checkbox":
            if (button.state == .on) != on { button.performClick(nil) }
        case let toggle as NSSwitch:
            if (toggle.state == .on) != on { toggle.performClick(nil) }
        default:
            if node.role == "checkbox" || node.role == "disclosuretriangle" {
                if ((node.value as? NSNumber)?.boolValue ?? false) != on { _ = node.press() }
            } else if node.object.responds(to: NSSelectorFromString("setAccessibilityValue:")) {
                node.object.setValue(text, forKey: "accessibilityValue")
            } else {
                throw Failure("“\(node.title.isEmpty ? node.id : node.title)” (\(node.role)) can't be set; press it instead.")
            }
        }
    }

    // MARK: Keys, text and clicks

    /// The window keys and text go to: `spec`'s (window:<title>, its frontmost sheet first, or sheet), else the
    /// frontmost sheet or alert, else the key or main window.
    private func keyWindow(_ spec: String?) throws -> NSWindow {
        if let spec {
            guard let window = try scopes(spec).first else { throw Failure("No window “\(spec)”.") }
            return window
        }
        if let sheet = openSheets().last { return sheet }
        if let key = NSApp.keyWindow, isOurs(key) { return key }
        return try mainWindow
    }

    /// The Windows desktop shown (target rdp), made the first responder of its window.
    private func desktopView() throws -> RDPDesktopView {
        guard let desktop = selectedDesktop, desktop.session != nil, let window = desktop.desktop.window else {
            throw Failure("No Remote Desktop is connected and shown: select it in the sidebar.")
        }
        if window.firstResponder !== desktop.desktop { window.makeFirstResponder(desktop.desktop) }
        return desktop.desktop
    }

    /// Runs `body` with the desktop focused as a click focuses it, and takes the focus back afterwards as a click
    /// elsewhere does: the Mac's clipboard goes to Windows now (not on and on while the user works in other apps), and
    /// what Windows copied comes to the Mac when it ends. While AirSCP's window is key, AppKit's focus does this.
    static func lendingFocus(to desktop: RDPDesktopView, _ body: () async throws -> [String: Any]) async throws -> [String: Any] {
        let lent = desktop.window?.isKeyWindow == false
        if lent { desktop.onFocus?(true) }
        defer { if lent && desktop.window?.isKeyWindow == false { desktop.onFocus?(false) } }
        return try await body()
    }

    /// The window keys and clicks go to, in front and key within AirSCP. AirSCP isn't activated: the agent's own app
    /// (a terminal) keeps the focus, and events go to the window directly when it isn't the key window.
    private func bringToFront(_ window: NSWindow) {
        (window.sheetParent ?? window).orderFront(nil)
        window.makeKey()
    }

    private func key(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard let combo = arguments["combo"] as? String else { throw Failure("key needs a combo, e.g. \"cmd+shift+n\".") }
        if ["rdp", "desktop"].contains((arguments["target"] as? String)?.lowercased()) {
            // The Windows key (⊞) is no Mac key: it goes to Windows as its own key, held while the rest is pressed.
            let (rest, windowsKey) = KeyCombo.windowsKey(in: combo)
            let keys = try rest.map { try KeyCombo($0) }
            let desktop = try desktopView()
            return try await Self.lendingFocus(to: desktop) {
                bringToFront(desktop.window!)
                if windowsKey { desktop.session?.scancode(0x15B, down: true) }
                let reply = await perform { if let keys { self.sendKey(keys, to: desktop.window!) } }
                if windowsKey { desktop.session?.scancode(0x15B, down: false) }
                return reply
            }
        }
        let keys = try KeyCombo(combo)
        let window = try keyWindow(arguments["in"] as? String)
        if keys.base == " ", keys.modifiers.isEmpty, window.firstResponder is FileTableView { throw Failure(Self.noQuickLook) }
        bringToFront(window)
        return await perform { self.sendKey(keys, to: window) }
    }

    private func sendKey(_ keys: KeyCombo, to window: NSWindow) {
        let (down, up) = keys.events(window: window)
        if window.isKeyWindow {
            NSApp.sendEvent(down)
            NSApp.sendEvent(up)
        } else {
            // AirSCP isn't the active app (it can't be made so): key equivalents as AppKit tries them (the window's
            // first, for every key: Return presses the default button), then the menu bar's, else the window.
            var handled = window.performKeyEquivalent(with: down)
            if !handled, !keys.modifiers.intersection([.command, .control]).isEmpty {
                if let item = menuItem(for: keys) {
                    let check = validate(item, in: window)  // the command of this window (an editor's ⌘W closes it)
                    if check.enabled, let target = check.target, let action = item.action {
                        handled = NSApp.sendAction(action, to: target, from: item)
                    }
                }
            }
            // Return and Enter press the default button (AppKit's keyDown does, but only in the key window).
            if !handled, keys.modifiers.isEmpty, ["\r", "\u{3}"].contains(keys.base),
               let button = window.defaultButtonCell, button.isEnabled {
                button.performClick(nil)
                handled = true
            }
            // Escape closes an alert with one button (OK), as AppKit does for a person: that button has only Return.
            if !handled, keys.modifiers.isEmpty, keys.base == "\u{1b}" {
                let buttons = Self.views(NSButton.self, in: window.contentView).filter { $0.target is NSAlert }
                if buttons.count == 1, let button = buttons.first, button.isEnabled {
                    button.performClick(nil)
                    handled = true
                }
            }
            if !handled {
                window.sendEvent(down)
                window.sendEvent(up)
            }
        }
        if !keys.modifiers.isEmpty, let release = NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false,
            keyCode: 55) {
            window.sendEvent(release)
        }
    }

    /// The menu-bar item with this shortcut.
    private func menuItem(for keys: KeyCombo) -> NSMenuItem? {
        func walk(_ menu: NSMenu) -> NSMenuItem? {
            for item in menu.items {
                if let submenu = item.submenu, let found = walk(submenu) { return found }
                guard !item.keyEquivalent.isEmpty else { continue }
                var modifiers = item.keyEquivalentModifierMask.intersection([.command, .control, .option, .shift])
                if item.keyEquivalent.lowercased() != item.keyEquivalent { modifiers.insert(.shift) }
                // Menus write ⌫ as backspace (8), the Delete key types DEL (127).
                let key = item.keyEquivalent == "\u{8}" ? "\u{7f}" : item.keyEquivalent.lowercased()
                if key == keys.base && modifiers == keys.modifiers { return item }
            }
            return nil
        }
        return NSApp.mainMenu.flatMap(walk)
    }

    /// The pause after each key typed on the Windows desktop (twice that after a Unicode character).
    static let typingPause: UInt64 = 80_000_000

    private func type(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard let text = arguments["text"] as? String else { throw Failure("type needs text.") }
        let target = (arguments["target"] as? String)?.lowercased()
        if target == "rdp" || target == "desktop" {
            guard text.count <= 1000 else {
                throw Failure("That's long to type key by key (\(text.count) characters): copy it as a file and send it with drop.")
            }
            let desktop = try desktopView()
            // With a US keyboard on both sides, characters on its keys go as key presses: Windows loses some of a quick
            // run of Unicode characters (and repeats others); the rest go as Unicode, more slowly. At a person's pace:
            // Windows 11's Notepad, typed into faster, stopped moving its caret (the text came out backwards), lost Shift
            // and turned accented letters into others; the Run box kept up with any pace.
            let us = RDPSession.keyboardLayout() == 0x0409
            return try await Self.lendingFocus(to: desktop) {
                for character in text {
                    guard let session = desktop.session else { break }
                    if us, let (code, shift) = KeyCombo.usKey(character) {
                        if shift {
                            session.scancode(0x2A, down: true)
                            try? await Task.sleep(nanoseconds: Self.typingPause / 4)
                        }
                        _ = session.key(code, down: true)
                        _ = session.key(code, down: false)
                        if shift {
                            try? await Task.sleep(nanoseconds: Self.typingPause / 4)
                            session.scancode(0x2A, down: false)
                        }
                        try? await Task.sleep(nanoseconds: Self.typingPause)
                    } else {
                        session.unicode(String(character))
                        try? await Task.sleep(nanoseconds: 2 * Self.typingPause)
                    }
                }
                return await acted()
            }
        }
        let window = try keyWindow(arguments["in"] as? String)
        if let editor = window.firstResponder as? NSTextView {
            editor.insertText(text, replacementRange: editor.selectedRange())
            return await acted()
        }
        // One key event per character, each a turn of the app's run loop: a long text would hold the app up.
        guard text.count <= 1000 else {
            throw Failure("That's long to type key by key (\(text.count) characters): focus a text field first, or use set.")
        }
        for chunk in stride(from: 0, to: text.count, by: 50).map({ Array(text.dropFirst($0).prefix(50)) }) {
            await Self.later { for character in chunk { self.sendKey(KeyCombo(character: character), to: window) } }
        }
        return await acted()
    }

    private func click(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard let x = (arguments["x"] as? NSNumber)?.doubleValue, let y = (arguments["y"] as? NSNumber)?.doubleValue else {
            throw Failure("click needs x and y: points from the top left of the main window (a screenshot at scale 1), or "
                          + "with target rdp pixels of the Windows desktop's picture (screenshot target=rdp). Hosts, "
                          + "folders and rows are taken by name: select pane=sidebar names=[\"web\"], go path=…, open name=….")
        }
        let right = (arguments["button"] as? String)?.lowercased() == "right"
        let wheel = (arguments["wheel"] as? NSNumber)?.intValue
        let count = max(1, min(arguments["count"] as? Int ?? 1, 3))
        if ["rdp", "desktop"].contains((arguments["target"] as? String)?.lowercased()) {
            // The desktop's own pixels, as screenshot target=rdp has them: the same whatever the window's size, the
            // screen's Retina scale or full screen, so there is nothing to convert.
            guard let session = selectedDesktop?.session, let size = Self.desktopSize(session) else {
                throw Failure("No Remote Desktop is connected and shown: select it in the sidebar.")
            }
            let point = try Self.desktopPixel(x: x, y: y, size: size)
            return await clickDesktop(session, at: point, of: size, right: right, count: count, wheel: wheel)
        }
        let base = try (arguments["in"] as? String).map { try scopes($0).last! } ?? mainWindow
        let point = NSPoint(x: base.frame.minX + x, y: base.frame.maxY - y)
        let window = openSheets().reversed().first { $0.frame.contains(point) } ?? base
        let location = NSPoint(x: point.x - window.frame.minX, y: point.y - window.frame.minY)
        let hit = window.contentView?.hitTest(window.contentView!.convert(location, from: nil))
        if let hit, Self.takenByName(hit) {
            throw Failure("Never click in the sidebar or the file panes: hosts, folders and rows are taken by name, their "
                          + "controls by id (press, set). A host: select pane=sidebar names=[\"web\"]; a folder: go path=/var/log; "
                          + "a row: open name=… (a folder, ..) or select pane=right names=[\"a.txt\"], then menu path=\"File > …\".")
        }
        if let desktop = hit as? RDPDesktopView, let session = desktop.session, let size = Self.desktopSize(session) {
            return await clickDesktop(session, at: desktop.desktopPoint(atWindowPoint: location), of: size, right: right,
                                      count: count, wheel: wheel)
        }
        // Window points that miss the desktop shown: the agent may have meant the desktop's own pixels.
        let note = selectedDesktop?.session == nil ? nil : "x, y are points of the window here, not on the Windows "
            + "desktop: for pixels of screenshot target=rdp, add target rdp."
        if right {
            throw Failure("A right-click opens a context menu, which agents can't see: use menu \"context > …\" instead."
                          + (note.map { " (\($0))" } ?? ""))
        }
        if wheel != nil {
            throw Failure("wheel scrolls the Windows desktop only (AirSCP's lists are in snapshot, every row)."
                          + (note.map { " (\($0))" } ?? ""))
        }
        let modifiers = try KeyCombo.modifiers(arguments["modifiers"] as? String ?? "")
        bringToFront(window)
        var reply = await perform { Self.click(at: location, in: window, right: right, modifiers: modifiers, count: count) }
        reply["note"] = note
        return reply
    }

    /// A click, or the wheel turned, at a pixel of the Windows desktop, straight to Windows. The reply says where in
    /// words, with a picture of what was under the pointer as it clicked.
    private func clickDesktop(_ session: RDPSession, at point: CGPoint, of size: CGSize, right: Bool, count: Int,
                              wheel: Int?) async -> [String: Any] {
        let at = "\(Int(point.x)), \(Int(point.y)) of the \(Int(size.width)) × \(Int(size.height)) desktop picture"
        if let wheel {  // notches, as a mouse wheel turns: up when positive
            session.wheel(horizontal: false, delta: wheel * 120, at: point)
            return await acted(["desktop": "Turned the wheel \(abs(wheel)) notches \(wheel > 0 ? "up" : "down") at \(at)."])
        }
        // The pointer moves there first, and rests a moment: some controls (Windows 11's taskbar) react only to a
        // pointer over them.
        session.mouseMove(to: point)
        try? await Task.sleep(nanoseconds: 150_000_000)
        let picture = Self.frameImage(session).flatMap { Self.clickPicture($0, at: point) }
        // Then the button, down and up at that point, straight to Windows: an up event posted to AppKit's queue
        // came back with another location (a corner of the desktop), and Windows took the click for a drag.
        let button = right ? 1 : 0
        for _ in 0..<count {
            session.mouseButton(button, down: true, at: point)
            session.mouseButton(button, down: false, at: point)
        }
        let what = right ? "Right-clicked" : count == 2 ? "Double-clicked" : count == 3 ? "Triple-clicked" : "Clicked"
        var reply = await acted(["desktop": "\(what) \(at)."
            + (picture == nil ? "" : " The picture shows what was there: 200 × 120 pixels around it, zoomed 2×, "
               + "the red cross where it clicked.")])
        reply["picture"] = picture.flatMap(Self.png)
        return reply
    }

    /// The desktop's size in pixels (its picture's), nil while it has none.
    static func desktopSize(_ session: RDPSession) -> CGSize? {
        session.withFrame { frame in frame.map { CGSize(width: $0.width, height: $0.height) } }
    }

    /// x, y of the desktop's picture as the pixel they name, or why they can't be one.
    static func desktopPixel(x: Double, y: Double, size: CGSize) throws -> CGPoint {
        guard x >= 0, y >= 0, x < Double(size.width), y < Double(size.height) else {
            throw Failure("x, y (\(Int(x)), \(Int(y))) are outside the Windows desktop's picture, which is "
                          + "\(Int(size.width)) × \(Int(size.height)) pixels (screenshot target=rdp).")
        }
        return CGPoint(x: x.rounded(.down), y: y.rounded(.down))
    }

    /// The desktop around `point` (200 × 120 pixels, less at its edges), zoomed 2× (nothing smoothed) with a red cross
    /// on `point`, which is left uncovered: what a click there hits.
    static func clickPicture(_ frame: CGImage, at point: CGPoint) -> CGImage? {
        let area = CGRect(x: point.x - 100, y: point.y - 60, width: 200, height: 120)
            .intersection(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        guard !area.isEmpty, let part = frame.cropping(to: area), let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(area.width) * 2, height: Int(area.height) * 2, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                                        | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.interpolationQuality = .none
        context.draw(part, in: CGRect(x: 0, y: 0, width: area.width * 2, height: area.height * 2))
        // The middle of the zoomed pixel; the context's origin is at the bottom left.
        let x = (point.x - area.minX) * 2 + 1, y = (area.maxY - point.y) * 2 - 1
        for (color, width) in [(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1), CGFloat(4)),
                               (CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1), CGFloat(2))] {
            context.setStrokeColor(color)
            context.setLineWidth(width)
            for (dx, dy) in [(1.0, 0.0), (-1.0, 0.0), (0.0, 1.0), (0.0, -1.0)] {
                context.move(to: CGPoint(x: x + dx * 6, y: y + dy * 6))
                context.addLine(to: CGPoint(x: x + dx * 30, y: y + dy * 30))
            }
            context.strokePath()
        }
        return context.makeImage()
    }

    /// Whether `view` is in the sidebar or a file pane, whose hosts, folders and files are taken by name (and controls by
    /// id): a click there is never needed, and behind other apps it may not even select (AppKit takes it for the click
    /// that activates the window).
    static func takenByName(_ view: NSView) -> Bool {
        sequence(first: view, next: \.superview).contains { $0.nextResponder is FilePane || $0.nextResponder is NSHostingController<Sidebar> }
    }

    /// Mouse down and up at `location`, `count` times, as a person clicks.
    private static func click(at location: NSPoint, in window: NSWindow, right: Bool, modifiers: NSEvent.ModifierFlags,
                              count: Int) {
        for number in 1...count {
            func event(_ type: NSEvent.EventType) -> NSEvent? {
                NSEvent.mouseEvent(with: type, location: location, modifierFlags: modifiers,
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 0, clickCount: number, pressure: 1)
            }
            guard let down = event(right ? .rightMouseDown : .leftMouseDown), let up = event(right ? .rightMouseUp : .leftMouseUp)
            else { continue }
            // Controls track the mouse until it goes up: the up event waits in the queue for them.
            NSApp.postEvent(up, atStart: false)
            NSApp.sendEvent(down)
            if let pending = NSApp.nextEvent(matching: right ? .rightMouseUp : .leftMouseUp, until: .distantPast,
                                             inMode: .default, dequeue: true) {
                NSApp.sendEvent(pending)
            }
        }
    }

    private func focus(_ arguments: [String: Any]) async throws -> [String: Any] {
        let window = try mainWindow
        switch ((arguments["target"] as? String)?.lowercased(), arguments["pane"] as? String) {
        case ("sidebar"?, _):
            guard let list = Self.views(NSOutlineView.self, in: main?.window?.contentView).first ?? Self.views(NSTableView.self, in: main?.window?.contentView).first
            else { throw Failure("The sidebar has no list (no hosts yet).") }
            window.makeFirstResponder(list)
        case ("filter"?, let name):
            let pane = try pane(name)
            window.makeFirstResponder(pane.filterField)
        case ("path"?, let name):
            try pane(name).goToFolder(nil)
        case ("desktop"?, _), ("rdp"?, _):
            return try await Self.lendingFocus(to: try desktopView()) { await acted() }
        case (nil, let name?):
            window.makeFirstResponder(try pane(name).table)
        default:
            throw Failure("focus needs pane (left or right) or target (sidebar, filter, path, desktop).")
        }
        return await acted()
    }

    static func views<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
        guard let view else { return [] }
        return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { views(type, in: $0) }
    }

    // MARK: Go and open: folders by path, rows by name (never by coordinates)

    /// The rows go and open answer with; `more` counts the others (snapshot's rows lists them).
    static let listedRows = 100

    /// go: a pane to a folder, as the Go to Folder field (⇧⌘G) takes a typed path: the pane moves where the user sees
    /// it, and the answer comes once the folder is listed.
    private func go(_ arguments: [String: Any]) async throws -> [String: Any] {
        let pane = try browsable(arguments["pane"] as? String)
        guard let path = pane.resolve(arguments["path"] as? String ?? "") else {
            throw Failure("go needs path: a folder (/var/log, ~, ~/logs, or relative to the folder shown; .. goes up).")
        }
        return try await go(pane, to: path)
    }

    /// open: a row by name, as a double-click or Return opens it (FilePane.openItems): a folder, or a link to one, is
    /// listed in the pane and answered as go answers; ".." is the enclosing folder; a file opens in its app on this Mac.
    private func openRow(_ arguments: [String: Any]) async throws -> [String: Any] {
        guard let name = arguments["name"] as? String, !name.isEmpty else {
            throw Failure("open needs name: a row's name (snapshot: the pane's rows), or \"..\" for the enclosing folder.")
        }
        let pane = try browsable(arguments["pane"] as? String)
        guard let dir = pane.dir else { throw Failure("The pane shows no folder yet: wait until=listed first.") }
        if name == ".." {
            guard dir != "/" else { throw Failure("This is the top folder (/).") }
            return try await go(pane, to: RemotePath.parent(dir), select: [RemotePath.name(dir)])
        }
        // By its exact bytes, as select takes names: "café" composed and decomposed are two files on a Linux server.
        guard let row = pane.rows.firstIndex(where: { Data($0.name.utf8) == Data(name.utf8) }) else {
            if pane.items.contains(where: { Data($0.name.utf8) == Data(name.utf8) }) {
                throw Failure("“\(name)” isn't shown in \(dir): the filter or hidden files (View > Show Hidden Files) hide it.")
            }
            throw Failure("No “\(name)” in \(dir). There: " + pane.rows.prefix(30).map(\.name).joined(separator: ", ")
                          + (pane.rows.count > 30 ? ", …" : "."))
        }
        let item = pane.rows[row]
        if item.kind == .directory || item.kind == .symlink && !pane.isRemote && FileList.isLocalFolder(item.path) {
            return try await go(pane, to: item.path)
        }
        // A server's link may lead to a folder: listed if it does, as Return lists it; else it opens as a file.
        if item.kind == .symlink, pane.isRemote, let listed = try? await go(pane, to: item.path) { return listed }
        pane.view.window?.makeFirstResponder(pane.table)
        pane.table.selectRowIndexes([row], byExtendingSelection: false)
        pane.table.scrollRowToVisible(row)
        pane.openItems(nil)
        return await acted(["opened": item.name, "note": "A file opens in its app on this Mac, outside AirSCP: you can't see "
                            + "it. To read one, download it (drop from=… to=\"local:<folder>\") or use File > Edit in AirSCP."])
    }

    /// A file pane go and open may move: the Files tab shown, no sheet over the window (answered first, as a person must)
    /// and its server connected.
    private func browsable(_ name: String?) throws -> FilePane {
        if let sheet = main?.window?.attachedSheet {
            throw Failure("A sheet is open in AirSCP's window: answer or close it first. " + describe(sheetJSON(sheet)))
        }
        let pane = try pane(name ?? "right")
        guard pane.isConnected else {
            throw Failure("“\(pane.session?.host.displayName ?? "")” isn't connected: menu path=\"Host > Connect\", then wait "
                          + "until=connected.")
        }
        return pane
    }

    /// Lists `path` in `pane` as Go to Folder does (its Back list and path bar follow) and gives the pane the focus, as
    /// Return in that field does. A folder that can't be listed is this request's error, not a sheet left to close.
    private func go(_ pane: FilePane, to path: String, select: [String] = []) async throws -> [String: Any] {
        // Just connected, the pane lists its start folder (or, reconnected, its folder again) a moment after the state
        // changed: that listing would take this one's place, so it goes first (as a person sees the first folder before
        // typing another).
        let deadline = Date().addingTimeInterval(30)
        while (pane.dir == nil || pane.unlisted) && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        let before = pane.dir
        var failure: Error?
        guard await pane.open(path, select: select, quiet: true, failed: { failure = $0 }) else {
            let stays = before.map { " (the pane stays in \($0))" } ?? ""
            switch failure.flatMap({ ($0 as? AirSCPError)?.kind }) {
            case .noSuchFile?: throw Failure("No such folder: \(path)\(stays).")
            case .permissionDenied?: throw Failure("Permission denied: this account may not list \(path)\(stays).")
            default:
                guard let failure else {
                    throw Failure("Another listing took this one's place (the pane shows \(pane.dir ?? "no folder")): go again.")
                }
                throw Failure("Can't open \(path)\(stays): " + ((failure as? AirSCPError)?.message ?? failure.localizedDescription))
            }
        }
        pane.view.window?.makeFirstResponder(pane.table)
        var json = paneJSON(pane, rows: Self.listedRows)
        if pane.rows.count > Self.listedRows { json["more"] = pane.rows.count - Self.listedRows }
        return await acted(["pane": json])
    }

    // MARK: Select, sort, drop

    private func select(_ arguments: [String: Any]) async throws -> [String: Any] {
        let names = (arguments["names"] as? [String]) ?? (arguments["names"] as? String).map { [$0] } ?? []
        let ids = (arguments["ids"] as? [String]) ?? []
        let all = arguments["all"] as? Bool == true, none = arguments["none"] as? Bool == true
        guard !names.isEmpty || !ids.isEmpty || all || none else {
            throw Failure("select needs pane and names, e.g. {\"pane\": \"sidebar\", \"names\": [\"web\"]} for a host or "
                          + "{\"pane\": \"right\", \"names\": [\"a.txt\"]} for files (or all: true, none: true).")
        }
        let paneName = (arguments["pane"] as? String)?.lowercased()
        if paneName == nil, let spec = arguments["in"] as? String {
            // Find Files' results: by their paths in its model (its list follows), however many there are.
            if let find = findModel, let sheet = try scopes(spec).first,
               (sheet.contentViewController as? NSHostingController<FindView>) != nil {
                guard !all else { throw Failure("Find Files' list takes one result at a time.") }
                guard let name = names.first else { find.selection = nil; return await acted(["selected": 0]) }
                let paths = find.results.map(\.path)
                guard let path = paths.first(where: { find.relative($0) == name }) ?? paths.first(where: { find.relative($0).contains(name) })
                else { throw Failure("No result shows \(name).") }
                find.selection = path
                return await acted(["selected": 1])
            }
            // Synchronize's list: the items ticked, by their paths (its list makes rows only where it shows them): only
            // these, all of them, or none.
            if let sync = syncModel, let sheet = try scopes(spec).first,
               (sheet.contentViewController as? NSHostingController<SyncView>) != nil {
                let paths = Set(sync.plan.steps.map(\.path))
                let wanted = Set(names.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
                let missing = wanted.subtracting(paths)
                guard missing.isEmpty else {
                    throw Failure("Not in Synchronize's list: \(missing.sorted().joined(separator: ", ")) (snapshot → sync: its steps).")
                }
                sync.unticked = all ? [] : none ? paths : paths.subtracting(wanted)
                return await acted(["ticked": sync.chosen.steps.count])
            }
            // A list in another window or a sheet (Keys, Snippets, Proxies): the first with rows showing the names.
            // SwiftUI fills a list a moment after its model changes: looked for again for 2 s.
            let deadline = Date().addingTimeInterval(2)
            repeat {
                for window in try scopes(spec) {
                    for table in Self.views(NSTableView.self, in: window.contentView) where !(table is FileTableView) {
                        let rows = all ? IndexSet(0..<table.numberOfRows) : none ? IndexSet() : Self.rows(of: table, showing: names)
                        if all || none || !rows.isEmpty { return await selected(rows, in: table) }
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            } while Date() < deadline
            throw Failure("No list in “\(spec)” shows \(names.joined(separator: ", ")).")
        }
        switch paneName {
        case "sidebar"?:
            guard let main, let name = names.first else { throw Failure("select sidebar needs names: [the host's name].") }
            // As for a person: the sheet belongs to the host shown, and would be left to a workspace no longer there.
            if let sheet = main.window?.attachedSheet {
                throw Failure("A sheet is open in AirSCP's window: answer or close it first. " + describe(sheetJSON(sheet)))
            }
            if let host = model.data.hosts.first(where: { $0.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                main.sidebar.selection = .host(host.id)
            } else if let entry = model.data.rdpEntries.first(where: { $0.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame }) {
                main.sidebar.selection = .rdp(entry.id)
            } else {
                throw Failure("No host or Remote Desktop called “\(name)”. There: "
                              + (model.data.hosts.map(\.displayName) + model.data.rdpEntries.map(\.displayName)).joined(separator: ", "))
            }
            return await acted(["selection": snapshot(["include": []])["selection"] ?? NSNull()])
        case "processes"?:
            // The process table's model (as clicking rows sets it): the rows it lists now, i.e. with its search applied.
            guard let monitor = main?.selectedWorkspace?.monitor.model, monitor.snapshot != nil else {
                throw Failure("The Monitor tab shows no processes (press title=Monitor, then wait until=monitor).")
            }
            let rows = monitor.rows
            var chosen = Set<Int>()
            if all { chosen = Set(rows.map(\.pid)) }
            if !all && !none {
                for name in names {
                    let exact = rows.filter { $0.name == name || String($0.pid) == name }
                    let matches = exact.isEmpty ? rows.filter { $0.command.contains(name) } : exact
                    guard !matches.isEmpty else {
                        throw Failure("No process listed is \(name)" + (monitor.search.isEmpty ? "." : " (the search “\(monitor.search)” is on)."))
                    }
                    chosen.formUnion(matches.map(\.pid))
                }
            }
            monitor.selection = chosen
            return await acted(["selected": rows.filter { chosen.contains($0.pid) }.map(\.pid)])
        case "transfers"?:
            // The Transfers panel's selection (its model: no cells are made): jobs by id, else by their name.
            let jobs = TransferCenter.shared.jobs
            var chosen = Set<UUID>()
            if all { chosen = Set(jobs.map(\.id)) }
            if !all && !none {
                for id in ids {
                    guard let job = jobs.first(where: { $0.id.uuidString.caseInsensitiveCompare(id) == .orderedSame }) else {
                        throw Failure("No transfer job has the id \(id) (snapshot include=[\"transfers\"] lists them).")
                    }
                    chosen.insert(job.id)
                }
                for name in names {
                    let exact = jobs.filter { TransferText.name($0) == name }
                    let matches = exact.isEmpty ? jobs.filter { TransferText.route($0).contains(name) } : exact
                    guard !matches.isEmpty else { throw Failure("No transfer is listed as \(name).") }
                    chosen.formUnion(matches.map(\.id))
                }
            }
            model.transferSelection.ids = chosen
            return await acted(["selected": jobs.filter { chosen.contains($0.id) }.map { $0.id.uuidString }])
        default:
            let pane = try pane(arguments["pane"] as? String)
            var rows = IndexSet()
            if all { rows = IndexSet(0..<pane.rows.count) }
            if !all && !none {
                // By their exact bytes: "café" composed and decomposed are two files on a Linux server.
                let present = Set(pane.rows.map { Data($0.name.utf8) })
                let missing = names.filter { !present.contains(Data($0.utf8)) }
                guard missing.isEmpty else {
                    throw Failure("Not in the pane (\(pane.dir ?? "no folder")): \(missing.joined(separator: ", ")). "
                                  + "Hidden files need Show Hidden Files; a filter hides rows too.")
                }
                rows = FileList.indexes(of: names, in: pane.rows)
            }
            pane.view.window?.makeFirstResponder(pane.table)
            pane.table.selectRowIndexes(rows, byExtendingSelection: false)
            if let first = rows.first { pane.table.scrollRowToVisible(first) }
            return await acted(["pane": paneJSON(pane, rows: 0)])
        }
    }

    /// Selects these rows of a list, as clicking them does (SwiftUI's lists and tables follow their table's selection).
    private func selected(_ rows: IndexSet, in table: NSTableView) async -> [String: Any] {
        table.window?.makeFirstResponder(table)
        table.selectRowIndexes(rows, byExtendingSelection: false)
        return await acted(["selected": rows.count])
    }

    /// The rows of `table` with a cell that is one of `names` (a key called id_lab), else with a cell containing it.
    /// A long list's rows are read only where it shows them (each row read makes its cells' views).
    private static func rows(of table: NSTableView, showing names: [String]) -> IndexSet {
        let range = table.numberOfRows * max(table.numberOfColumns, 1) <= 400 ? 0..<table.numberOfRows
            : { let visible = table.rows(in: table.visibleRect); return visible.location..<(visible.location + visible.length) }()
        var texts: [Int: [String]] = [:]
        for row in range {
            texts[row] = (0..<table.numberOfColumns).compactMap { table.view(atColumn: $0, row: row, makeIfNecessary: true) }
                .flatMap { AXNode.flatten($0) }.compactMap { $0.value as? String }
        }
        var rows = IndexSet()
        for name in names {
            let exact = texts.keys.filter { texts[$0]!.contains(name) }
            rows.formUnion(IndexSet(exact.isEmpty ? texts.keys.filter { texts[$0]!.contains { $0.contains(name) } } : exact))
        }
        return rows
    }

    private func sort(_ arguments: [String: Any]) async throws -> [String: Any] {
        let column = (arguments["column"] as? String) ?? ""
        let ascending = arguments["ascending"] as? Bool ?? true
        if (arguments["pane"] as? String)?.lowercased() == "processes" {
            guard let monitor = main?.selectedWorkspace?.monitor.model else { throw Failure("No host is selected.") }
            let names = Self.processColumns.map(\.name)
            guard let spec = Self.processColumns.first(where: { $0.name == column.lowercased() }) else {
                throw Failure("Process columns: " + names.joined(separator: ", ") + ".")
            }
            monitor.sortOrder = [Self.comparator(spec.path, ascending: ascending)]
            return await acted(["monitor": monitorJSON(monitor)])
        }
        let pane = try pane(arguments["pane"] as? String)
        guard let spec = FilePane.columns.first(where: { $0.id == column.lowercased() || normalized($0.title) == normalized(column) })
        else { throw Failure("Columns: " + FilePane.columns.map(\.id).joined(separator: ", ")) }
        if pane.sortOrder != (spec.id, ascending) {
            pane.table.sortDescriptors = [NSSortDescriptor(key: spec.id, ascending: ascending)]
            // The pane sorts off the main thread and shows the rows when done (on a busy Mac that took over the 2 s this
            // waited, and the reply had the old order).
            let deadline = Date().addingTimeInterval(30)
            while pane.rebuilding && Date() < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
        }
        return await acted(["pane": paneJSON(pane, rows: 20)])
    }

    /// The process table's sort by one of its columns.
    private static func comparator(_ path: PartialKeyPath<MonitorProcess>, ascending: Bool) -> KeyPathComparator<MonitorProcess> {
        let order: SortOrder = ascending ? .forward : .reverse
        switch path {
        case let path as KeyPath<MonitorProcess, Int>: return KeyPathComparator(path, order: order)
        case let path as KeyPath<MonitorProcess, Int64>: return KeyPathComparator(path, order: order)
        case let path as KeyPath<MonitorProcess, Double>: return KeyPathComparator(path, order: order)
        case let path as KeyPath<MonitorProcess, String>: return KeyPathComparator(path, order: order)
        default: return KeyPathComparator(\MonitorProcess.cpuOrder, order: order)
        }
    }

    private func drop(_ arguments: [String: Any]) async throws -> [String: Any] {
        if let files = arguments["files"] as? [String] {
            let urls = files.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            if let missing = urls.first(where: { !FileManager.default.fileExists(atPath: $0.path) }) {
                throw Failure("“\(missing.path)” doesn't exist on this Mac.")
            }
            let target = (arguments["target"] as? String)?.lowercased() ?? ""
            if ["desktop", "rdp"].contains(target) {
                guard let desktop = selectedDesktop, desktop.state == .connected else {
                    throw Failure("No Remote Desktop is connected and shown.")
                }
                guard desktop.desktop.acceptsDrops else {
                    throw Failure(desktop.bar.sharedFolderRefused
                                  ? "Windows' policy blocks the shared folder on this computer: copy and paste the files instead."
                                  : "This Remote Desktop shares no Mac folder (its settings).")
                }
                return await perform { desktop.upload(urls) }
            }
            if target == "keys" {  // the Keys window's list, as a .ppk dragged there: Import Key opens for the first file
                guard let keys = (appWindows.first { $0.title == "Keys" }?.contentView as? NSHostingView<KeysView>)?.rootView.keys
                else { throw Failure("The Keys window isn't open: menu path=\"Window > Keys\" first.") }
                return await perform { keys.dropped = urls[0] }
            }
            let pane = try pane(arguments["pane"] as? String ?? "right")
            guard pane.isRemote, pane.isConnected, let dir = (arguments["into"] as? String) ?? pane.dir, let browser = pane.browser else {
                throw Failure("Finder files can be dropped on a connected server's pane only.")
            }
            return await dropped(browser) { browser.upload(urls, to: pane, into: dir) }
        }
        guard let fromName = arguments["from"] as? String, let toName = arguments["to"] as? String else {
            throw Failure("drop needs files (with pane or target), or from and to.")
        }
        let from = try pane(fromName)
        let items = from.selectedItems
        guard !items.isEmpty, let browser = from.browser else { throw Failure("Select the rows to drop first (select pane=\(fromName)).") }
        if toName.lowercased().hasPrefix("finder:") {
            // A drag into a Finder window: each row's file promise, written where Finder would put it (no questions;
            // a name that is taken there gets a number, as Finder gives it).
            let dir = (String(toName.dropFirst("finder:".count)) as NSString).expandingTildeInPath
            guard from.isRemote, FileList.isLocalFolder(dir) else {
                throw Failure("finder:<folder> takes a server pane's rows into an existing folder on this Mac.")
            }
            var taken = FileList.localNames(dir), jobs: [UUID] = []
            for row in from.table.selectedRowIndexes {
                // What the promise writer does with what Finder gives it (`FilePane.filePromiseProvider(_:writePromiseTo:)`).
                guard let promise = (from.tableView(from.table, pasteboardWriterForRow: row) as? NSFilePromiseProvider)?.userInfo
                        as? FilePane.PromisedFile else { continue }
                let name = Names.unique(promise.name, existing: taken, caseInsensitive: true)
                taken.append(name)
                jobs.append(promise.session.transfers.download(promise.path, to: RemotePath.join(dir, name), isFolder: promise.isFolder,
                                                               preserveTimes: promise.preserveTimes))
            }
            return await acted(["jobs": liveJobs().filter { jobs.contains($0.id) }.map(jobJSON)])
        }
        if toName.lowercased().hasPrefix("local:") {
            let dir = (String(toName.dropFirst("local:".count)) as NSString).expandingTildeInPath
            guard from.isRemote, FileList.isLocalFolder(dir) else {
                throw Failure("local:<folder> takes a server pane's rows into an existing folder on this Mac.")
            }
            return await dropped(browser) { browser.transfer(items, from: from.source, to: .local, into: dir, move: false) }
        }
        let to = try pane(toName)
        guard let dir = (arguments["into"] as? String) ?? to.dir, to.isConnected else { throw Failure("The other pane shows no folder.") }
        let move = arguments["move"] as? Bool == true
        let operation = BrowserContentController.dropOperation(items, from: from.source, to: to.source, into: dir,
                                                               mask: move ? .move : .copy)
        guard !operation.isEmpty else { throw Failure("That drop does nothing (the same place, or into itself).") }
        return await dropped(browser) { browser.transfer(items, from: from.source, to: to.source, into: dir, move: operation == .move) }
    }

    /// Runs a drop and returns once it has queued its jobs, asks something (a sheet), or is done (a copy within a
    /// server runs at once): `{ok, jobs, sheet?}`.
    private func dropped(_ browser: BrowserContentController, _ action: @escaping () -> Void) async -> [String: Any] {
        let before = Set(liveJobs().map(\.id))
        await Self.later(action)
        let deadline = Date().addingTimeInterval(10)
        var queued: [TransferJob] = []
        repeat {
            try? await Task.sleep(nanoseconds: 100_000_000)
            queued = liveJobs().filter { !before.contains($0.id) }
        } while queued.isEmpty && openSheets().isEmpty && browser.planning > 0 && Date() < deadline
        return await acted(["jobs": queued.map(jobJSON)])
    }

    /// Every connected host's jobs as their queues have them now (the Transfers panel's list follows a moment later).
    private func liveJobs() -> [TransferJob] {
        main?.workspaces.values.flatMap { $0.session.transfers.jobs } ?? []
    }

    // MARK: Wait

    /// Polls until the condition holds; stops at the timeout, at a question (sheet), or when `client` (the process that
    /// asked, when known) has gone.
    private func wait(_ arguments: [String: Any], client: pid_t = 0) async throws -> [String: Any] {
        let until = (arguments["until"] as? String ?? "").lowercased()
        let timeout = min(max((arguments["timeout"] as? NSNumber)?.doubleValue ?? 30, 0), 600)
        let started = Date()
        var wasConnecting = false
        let check: () throws -> [String: Any]?
        switch until {
        case "connected", "disconnected", "rdp_connected":
            let id = try target(arguments["host"] as? String)
            let name = model.host(id)?.displayName ?? model.rdpEntry(id)?.displayName ?? ""
            check = { [self] in
                // nil: idle; else the state and the error of a failed connection.
                let state: (name: String, error: AirSCPError?)?
                if model.rdpEntry(id) != nil {
                    switch model.rdpStates[id] {
                    case nil, .idle?: state = nil
                    case .connecting?: state = ("connecting", nil)
                    case .connected?: state = ("connected", nil)
                    case .disconnected(let error)?: state = ("disconnected", error)
                    }
                } else {
                    switch model.states[id] {
                    case nil, .idle?: state = nil
                    case .connecting?: state = ("connecting", nil)
                    case .reconnecting?: state = ("reconnecting", nil)
                    case .connected?: state = ("connected", nil)
                    case .disconnected(let error)?: state = ("disconnected", error)
                    }
                }
                if state?.name == "connecting" { wasConnecting = true }
                if until == "disconnected" {
                    return state == nil || state?.name == "disconnected" ? ["name": name, "state": state?.name ?? "idle"] : nil
                }
                if state?.name == "connected" { return ["name": name, "state": "connected"] }
                // Not connecting any more (it failed), or not even starting to: no use waiting.
                if state == nil || state?.name == "disconnected" {
                    if wasConnecting {
                        throw Failure("“\(name)” didn't connect" + (state?.error.map { ": " + $0.message } ?? ".")
                                      + (openSheets().last.map { " " + describe(sheetJSON($0)) } ?? ""))
                    }
                    if Date().timeIntervalSince(started) > 2 {
                        throw Failure("“\(name)” isn't connecting (\(state?.error?.message ?? "not connected")): "
                                      + "menu path=\"Host > Connect\" first.")
                    }
                }
                return nil
            }
        case "rdp_drawn":  // the desktop shows more than one colour (after connecting, Windows draws a blank frame first)
            check = { [self] in
                guard let desktop = selectedDesktop, desktop.state == .connected, let session = desktop.session else {
                    throw Failure("No Remote Desktop is connected and shown: wait until=rdp_connected first.")
                }
                return Self.hasPicture(session) ? rdpJSON(desktop) : nil
            }
        case "sheet":
            let text = arguments["text"] as? String
            check = { [self] in
                // Not in what its fields hold: a command typed in Run Command isn't its output.
                openSheets().reversed().map(sheetJSON).first { sheet in
                    var shown = sheet
                    shown["fields"] = (sheet["fields"] as? [[String: Any]])?.map { $0.filter { $0.key != "value" } }
                    return text == nil || describe(shown).localizedCaseInsensitiveContains(text!)
                }
            }
        case "no_sheet":
            check = { [self] in openSheets().isEmpty ? [:] : nil }
        case "listed":
            let name = arguments["pane"] as? String ?? "right", path = arguments["path"] as? String, text = arguments["text"] as? String
            check = { [self] in
                let pane = try pane(name)
                guard let dir = pane.dir, !pane.unlisted, pane.activities.isEmpty, !pane.rebuilding,
                      path.map({ pane.resolve($0) == dir }) ?? true,
                      text.map({ text in pane.items.contains { $0.name == text } }) ?? true else { return nil }
                return paneJSON(pane, rows: 50)
            }
        case "transfers_done":
            let hosts = try (arguments["host"] as? String).map { [try target($0)] }
            check = { [self] in
                // Nothing queued or running (paused jobs wait for Resume), no copy waiting for or under its checksum check,
                // and nothing being prepared (the destination listed, conflicts asked); and the Transfers panel shows them
                // settled too (the snapshot's list, which follows the queues within 0.25 s).
                func settled(_ job: TransferJob) -> Bool {
                    !job.status.isActive && !(job.status == .done && (job.checksum == .wanted || job.checksum == .checking))
                }
                let jobs = liveJobs().filter { hosts?.contains($0.hostID) ?? true }
                let planning = main?.workspaces.values.contains { $0.browser.planning > 0 } ?? false
                let shown = Dictionary(TransferCenter.shared.jobs.map { ($0.id, settled($0)) }) { first, _ in first }
                guard !planning, jobs.allSatisfy({ settled($0) && shown[$0.id] == true }) else { return nil }
                return ["summary": TransferText.summary(jobs), "jobs": jobs.map(jobJSON)]
            }
        case "text":
            guard let text = arguments["text"] as? String, !text.isEmpty else { throw Failure("wait text needs text.") }
            check = { [self] in
                // The main window's snapshot, and the texts of AirSCP's other windows (Keys, Settings, Snippets, editors).
                let json = snapshot(["include": Array(Self.defaultSections) + ["monitor", "log"]])
                let others = appWindows.filter { $0 !== main?.window }.flatMap { ([$0] + sheets(of: $0)).flatMap { AXNode.flatten($0) } }
                    .compactMap { $0.value as? String ?? ($0.title.isEmpty ? nil : $0.title) }
                return (Self.strings(in: json) + others).contains { $0.contains(text) } ? ["found": text] : nil
            }
        case "monitor":  // the Monitor tab has read the server (and lists a process with `text` in its name or command)
            let text = arguments["text"] as? String
            check = { [self] in
                guard let workspace = main?.selectedWorkspace else { throw Failure("No host is selected: select pane=sidebar first.") }
                let monitor = workspace.monitor.model
                // Never read (sftp only, not Linux): no figures will come.
                if monitor.snapshot == nil, let failure = monitor.failure { throw Failure(failure) }
                guard monitor.connected, let data = monitor.snapshot else { return nil }
                guard let text, !text.isEmpty else { return monitorJSON(monitor) }
                return data.processes.contains { $0.name.contains(text) || $0.command.contains(text) } ? monitorJSON(monitor) : nil
            }
        case "found":  // Find Files' search has ended
            check = { [self] in
                guard let find = findModel else { throw Failure("No Find Files sheet is open: menu path=\"File > Find Files…\" first.") }
                return find.searching ? nil : findJSON(find)
            }
        case "compared":  // Synchronize's comparison has ended
            check = { [self] in
                guard let sync = syncModel else { throw Failure("No Synchronize sheet is open: menu path=\"File > Synchronize…\" first.") }
                guard sync.started else { throw Failure("The comparison of a home folder waits for Compare: press title=Compare first.") }
                return sync.comparison == nil && sync.failure == nil ? nil : syncJSON(sync)
            }
        default:
            throw Failure("until is one of: connected, disconnected, sheet, no_sheet, listed, transfers_done, rdp_connected, "
                          + "rdp_drawn, text, monitor, found, compared.")
        }
        var lit = started
        while true {
            if let found = try check() { return found }
            // The agent that asked has gone (its bridge was stopped): nobody waits for the answer any more.
            if client > 0, kill(client, 0) != 0, errno == ESRCH { throw Failure("The agent that asked has gone.") }
            if Date().timeIntervalSince(lit) > 2 {  // waiting is acting: the indicator stays lit, the Monitor tab refreshing
                model.agentRequested()
                lit = Date()
            }
            // A question stops the wait (it may be what the wait waits for: ssh waits for its answer).
            if !["sheet", "no_sheet", "text", "monitor", "found", "compared"].contains(until), let sheet = openSheets().last {
                throw Failure("Stopped waiting: a sheet asks something. " + describe(sheetJSON(sheet)))
            }
            if Date().timeIntervalSince(started) > timeout {
                var now = snapshot(["include": ["workspace", "sheets"]])
                now["connected"] = (snapshot(["include": ["sidebar"]])["sidebar"] as? [String: Any])?["connected"]
                now["transfers"] = TransferText.summary(TransferCenter.shared.jobs)
                throw Failure("Timed out after \(Int(timeout)) s waiting for \(until). Now: " + describe(now))
            }
            // A text wait builds a whole snapshot each time: twice a second is soon enough.
            try await Task.sleep(nanoseconds: until == "text" ? 500_000_000 : 100_000_000)
        }
    }

    /// Every string in a JSON value.
    private static func strings(in value: Any) -> [String] {
        switch value {
        case let text as String: return [text]
        case let array as [Any]: return array.flatMap { strings(in: $0) }
        case let object as [String: Any]: return object.values.flatMap { strings(in: $0) }
        default: return []
        }
    }

    /// A host or Remote Desktop by name, else the one selected in the sidebar.
    private func target(_ name: String?) throws -> UUID {
        if let name {
            if let host = model.data.hosts.first(where: { $0.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame }) { return host.id }
            if let entry = model.data.rdpEntries.first(where: { $0.displayName.localizedCaseInsensitiveCompare(name) == .orderedSame }) { return entry.id }
            throw Failure("No host or Remote Desktop called “\(name)”.")
        }
        guard let id = main?.sidebar.selection?.id else { throw Failure("Name the host (host: …) or select one in the sidebar.") }
        return id
    }

    // MARK: Screenshots

    private func screenshot(_ arguments: [String: Any]) throws -> [String: Any] {
        let target = arguments["target"] as? String ?? "main"
        let scale = CGFloat(min(max((arguments["scale"] as? NSNumber)?.doubleValue ?? 1, 1), 2))
        var image: CGImage
        if target == "rdp" || target == "desktop" {
            guard let session = selectedDesktop?.session, let frame = Self.frameImage(session) else {
                throw Failure("No Remote Desktop is connected and shown.")
            }
            image = frame
        } else {
            var window = try mainWindow, crop: NSRect?
            // While the Windows desktop fills the screen, that is what the user sees (with its hint over it).
            if target == "main", let desktop = selectedDesktop, desktop.isFullScreen, let screen = desktop.desktop.window {
                window = screen
            }
            if target == "sheet" {
                guard let sheet = openSheets().last else { throw Failure("No sheet is open.") }
                window = sheet
            } else if target.hasPrefix("window:") {
                window = try scopes(target).last!
            } else if target.hasPrefix("element:") {
                let id = String(target.dropFirst("element:".count))
                guard let node = ([window] + sheets(of: window)).flatMap({ AXNode.flatten($0) }).first(where: { $0.id == id }) else {
                    throw Failure("No element “\(id)”.")
                }
                crop = NSRect(x: node.frame.minX - window.frame.minX, y: node.frame.minY - window.frame.minY,
                              width: node.frame.width, height: node.frame.height)
            } else if target != "main" {
                throw Failure("target is main, sheet, rdp, window:<title> or element:<id>.")
            }
            guard window.frame.width > 0 else { throw Failure("The window is closed.") }
            guard let drawn = composite(window, scale: scale) else { throw Failure("AirSCP couldn't draw the window.") }
            image = drawn
            if let crop {
                let pixels = CGRect(x: crop.minX * scale, y: (window.frame.height - crop.maxY) * scale,
                                    width: crop.width * scale, height: crop.height * scale).integral
                guard let cropped = image.cropping(to: pixels) else { throw Failure("The element is outside the window.") }
                image = cropped
            }
        }
        guard let png = Self.png(image) else { throw Failure("AirSCP couldn't make the PNG.") }
        var info: [String: Any] = ["width": image.width, "height": image.height, "scale": target == "rdp" ? 1 : scale, "target": target]
        if target == "rdp" || target == "desktop" {
            info["coordinates"] = "x, y are pixels of this picture of the Windows desktop (\(image.width) × \(image.height)), "
                + "from its top left: click with target rdp takes them as they are."
        }
        return Self.imageReply(png, info)
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }

    /// A PNG and its JSON as one tool result.
    static func imageReply(_ png: Data, _ json: [String: Any]) -> [String: Any] {
        ["content": [["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]]
            + (text(json)["content"] as? [[String: Any]] ?? []), "isError": false]
    }

    /// The window as the user sees it: its frame (title bar and toolbar) and content, its sheets and the panels over it
    /// at their places, and the Windows desktop (an IOSurface layer, which views can't draw into an image) from its
    /// frame buffer.
    func composite(_ window: NSWindow, scale: CGFloat) -> CGImage? {
        let size = window.frame.size
        guard let canvas = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        canvas.size = size  // points: before the context is made, which takes its scale from it
        guard let context = NSGraphicsContext(bitmapImageRep: canvas) else { return nil }
        var overlays = sheets(of: window)
        // Windows over it, back to front: its child windows, an app-modal alert and panels (alerts are panels, which
        // NSApp.orderedWindows leaves out).
        overlays += NSApp.windows.filter(\.isVisible).sorted { $0.orderedIndex > $1.orderedIndex }.filter { other in
            other !== window && other.sheetParent == nil && !overlays.contains(other)
                && otherWindows().contains(other) && !(other.windowController is MainWindowController)
                && (other.parent === window || other === NSApp.modalWindow || (other is NSPanel && other.level.rawValue >= window.level.rawValue))
                && other.frame.intersects(window.frame)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.restoreGraphicsState() }
        Self.drawingAsKey([window] + overlays) { draw(window, overlays, size: size, in: context) }
        return canvas.cgImage
    }

    /// Runs `draw` with `windows` drawing as the key, active windows they are in use. Behind other apps, or while the
    /// screen is locked, a window draws as inactive (grey window buttons, dimmer sidebar text, grey selections, tabs and
    /// default buttons), and pictures for the docs would show that. AppKit's key and main appearance is lent to them for
    /// the drawing only: Core Animation commits after it, so the screen never shows the change.
    static func drawingAsKey(_ windows: [NSWindow], _ draw: () -> Void) {
        let lent = windows.filter { !$0.isKeyWindow }
        func send(_ name: String) {
            let selector = NSSelectorFromString(name)
            for window in lent where window.responds(to: selector) { _ = window.perform(selector) }
        }
        send("acquireKeyAppearance")
        send("acquireMainAppearance")
        defer {
            send("resignMainAppearance")
            send("resignKeyAppearance")
        }
        draw()
    }

    private func draw(_ window: NSWindow, _ overlays: [NSWindow], size: NSSize, in context: NSGraphicsContext) {
        // The window's background in its appearance (light or dark): the title bar and glass are see-through.
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            NSColor.windowBackgroundColor.setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        Self.draw(window, at: .zero)
        if let desktop = selectedDesktop, desktop.desktop.window === window, let session = desktop.session,
           let frame = Self.frameImage(session) {
            context.cgContext.draw(frame, in: desktop.desktop.convert(desktop.desktop.imageRect, to: nil))
        }
        for other in overlays {
            let origin = NSPoint(x: other.frame.minX - window.frame.minX, y: other.frame.minY - window.frame.minY)
            if other is NSSavePanel {
                let rect = NSRect(origin: origin, size: other.frame.size)
                NSColor.windowBackgroundColor.setFill()
                rect.fill()
                NSColor.separatorColor.setStroke()
                NSBezierPath(rect: rect).stroke()
                ("Open/Save panel (not drawn: use drop)" as NSString).draw(at: NSPoint(x: rect.minX + 12, y: rect.maxY - 28),
                                                                           withAttributes: [.foregroundColor: NSColor.secondaryLabelColor])
            } else {
                // A popover's background is a backdrop (left out of the drawing): a plain one keeps its text readable.
                if other.className.contains("Popover"), let content = other.contentView {
                    let bubble = content.convert(content.bounds, to: nil).offsetBy(dx: origin.x, dy: origin.y)
                    other.effectiveAppearance.performAsCurrentDrawingAppearance {
                        let path = NSBezierPath(roundedRect: bubble, xRadius: 10, yRadius: 10)
                        NSColor.windowBackgroundColor.setFill()
                        path.fill()
                        NSColor.separatorColor.setStroke()
                        path.stroke()
                    }
                }
                Self.draw(other, at: origin)
            }
        }
    }

    static func draw(_ window: NSWindow, at origin: NSPoint) {
        guard let view = window.contentView?.superview ?? window.contentView else { return }
        drawFrame(view, of: window, at: origin)
    }

    /// The layers under `root` that the window server colours with a vibrant colour matrix (the sidebar's text, symbols
    /// and status dots), and that matrix's 20 numbers. Their own pixels are black: the matrix makes text white in Dark
    /// and grey in Light, a dot green. A layer's image of itself (cacheDisplay) knows no filters: they came out black.
    private static func vibrantLayers(_ root: CALayer) -> [(layer: CALayer, matrix: [Float])] {
        var found: [(layer: CALayer, matrix: [Float])] = []
        func walk(_ layer: CALayer) {
            guard !layer.isHidden, layer.opacity > 0 else { return }
            for filter in layer.filters ?? [] where "\(filter)".hasPrefix("vibrantColorMatrix") {
                guard let value = (filter as AnyObject).value(forKey: "inputColorMatrix") as? NSValue else { continue }
                var matrix = [Float](repeating: 0, count: 20)
                value.getValue(&matrix, size: MemoryLayout<Float>.size * 20)
                found.append((layer, matrix))
                return
            }
            layer.sublayers?.forEach(walk)
        }
        walk(root)
        return found
    }

    /// Draws a vibrant layer as the window server would: its own image through its colour matrix, at its place in the
    /// window (`root`'s coordinates, from `origin` in the image), cut to what the scroll views around it show.
    private static func drawVibrant(_ layer: CALayer, matrix m: [Float], root: CALayer, origin: NSPoint) {
        var rect = layer.convert(layer.bounds, to: root)
        var ancestor = layer.superlayer
        while let current = ancestor, current !== root {
            if current.masksToBounds { rect = rect.intersection(current.convert(current.bounds, to: root)) }
            ancestor = current.superlayer
        }
        let scale = NSGraphicsContext.current?.cgContext.ctm.a ?? 1
        let width = Int((layer.bounds.width * scale).rounded(.up)), height = Int((layer.bounds.height * scale).rounded(.up))
        guard !rect.isEmpty, width > 0, height > 0, width * height < 4_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -layer.bounds.minX, y: -layer.bounds.minY)
        if layer.contentsAreFlipped() {
            context.translateBy(x: 0, y: layer.bounds.maxY + layer.bounds.minY)
            context.scaleBy(x: 1, y: -1)
        }
        layer.render(in: context)
        guard let rendered = context.makeImage() else { return }
        let filter = CIFilter(name: "CIColorMatrix")!
        filter.setValue(CIImage(cgImage: rendered).unpremultiplyingAlpha(), forKey: kCIInputImageKey)
        for (index, key) in ["inputRVector", "inputGVector", "inputBVector", "inputAVector"].enumerated() {
            let row = Array(m[(index * 5)..<(index * 5 + 4)]).map(CGFloat.init)
            filter.setValue(CIVector(x: row[0], y: row[1], z: row[2], w: row[3]), forKey: key)
        }
        filter.setValue(CIVector(x: CGFloat(m[4]), y: CGFloat(m[9]), z: CGFloat(m[14]), w: CGFloat(m[19])), forKey: "inputBiasVector")
        guard let output = filter.outputImage?.premultiplyingAlpha(),
              let image = CIContext().createCGImage(output, from: CGRect(x: 0, y: 0, width: width, height: height)),
              let cg = NSGraphicsContext.current?.cgContext else { return }
        let place = layer.convert(layer.bounds, to: root).offsetBy(dx: origin.x, dy: origin.y)
        cg.saveGState()
        cg.clip(to: rect.offsetBy(dx: origin.x, dy: origin.y))
        cg.draw(image, in: place)
        cg.restoreGState()
    }

    private static func drawFrame(_ view: NSView, of window: NSWindow, at origin: NSPoint) {
        func place(_ view: NSView, opaque: Bool) {
            draw(view, in: view.convert(view.bounds, to: nil).offsetBy(dx: origin.x, dy: origin.y), opaque: opaque)
        }
        func named(_ view: NSView) -> String { NSStringFromClass(Swift.type(of: view)) }
        view.layoutSubtreeIfNeeded()
        // Backdrops (blur, the scroll edge "pockets") and Liquid Glass platters are the window server's: drawn here they
        // come out white. The window's background (drawn first) shows instead.
        let backdrops = views(NSView.self, in: view).filter { view in
            !view.isHidden && (named(view) == "NSScrollPocket" || named(view).contains("GlassEffect") && named(view).hasSuffix("RootView_")
                || ["CABackdropLayer", "CAPortalLayer"].contains(view.layer.map { NSStringFromClass(Swift.type(of: $0)) } ?? ""))
        }
        backdrops.forEach { $0.isHidden = true }
        defer { backdrops.forEach { $0.isHidden = false } }
        // Vibrant layers are left out of the images (they'd be black) and drawn through their matrix afterwards. The
        // change is undone before Core Animation commits it: the screen never shows it.
        let vibrant = view.layer.map(vibrantLayers) ?? []
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let opacities = vibrant.map(\.layer.opacity)
        vibrant.forEach { $0.layer.opacity = 0 }
        draw(view, in: NSRect(origin: origin, size: window.frame.size), opaque: true)
        // Liquid Glass (macOS 26): the window server draws what is inside a glass container (the sidebar), so the
        // cached image has only the platter. What it holds is drawn again on top, and the title bar over that.
        let titlebar = views(NSView.self, in: view).first { named($0) == "NSTitlebarContainerView" }
        let holders = views(NSView.self, in: view).filter { holder in
            named(holder).hasSuffix("ContentHolderView") && !(titlebar.map { holder.isDescendant(of: $0) } ?? false)
        }
        let contents = holders.flatMap(\.subviews).filter { !$0.isHiddenOrHasHiddenAncestor && !$0.bounds.isEmpty }
        contents.forEach { place($0, opaque: true) }
        zip(vibrant, opacities).forEach { $0.0.layer.opacity = $0.1 }
        CATransaction.commit()
        if let root = view.layer {
            for (layer, matrix) in vibrant { drawVibrant(layer, matrix: matrix, root: root, origin: origin) }
        }
        if !contents.isEmpty, let titlebar { place(titlebar, opaque: false) }
    }

    /// `opaque`: on the window's background colour, as on screen. Vibrant content (the sidebar's text, symbols and
    /// status dots, an alert's text) is blended with what is behind it: in an empty image it comes out wrong or not at
    /// all, and an alert's glass would be see-through.
    private static func draw(_ view: NSView, in rect: NSRect, opaque: Bool) {
        guard let cached = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        if opaque, let context = NSGraphicsContext(bitmapImageRep: cached) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            view.effectiveAppearance.performAsCurrentDrawingAppearance {
                NSColor.windowBackgroundColor.setFill()
                NSRect(origin: .zero, size: cached.size).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        view.cacheDisplay(in: view.bounds, to: cached)
        cached.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    }

    /// Whether the desktop's frame shows a picture: more than one colour on a grid of points across it.
    static func hasPicture(_ session: RDPSession) -> Bool {
        session.withFrame { frame -> Bool in
            guard let frame, frame.width > 0, frame.height > 0 else { return false }
            var first: UInt32?
            for row in stride(from: 0, to: frame.height, by: max(1, frame.height / 32)) {
                for column in stride(from: 0, to: frame.width, by: max(1, frame.width / 32)) {
                    let pixel = (frame.pixels + row * frame.stride + column * 4).loadUnaligned(as: UInt32.self) & 0x00FF_FFFF
                    if first == nil { first = pixel } else if pixel != first { return true }
                }
            }
            return false
        }
    }

    /// The Windows desktop's frame buffer (BGRX) at its pixel size.
    static func frameImage(_ session: RDPSession) -> CGImage? {
        session.withFrame { frame -> CGImage? in
            guard let frame, frame.width > 0, frame.height > 0,
                  let provider = CGDataProvider(data: Data(bytes: frame.pixels, count: frame.stride * frame.height) as CFData),
                  let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
            return CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.stride,
                           space: space, bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue
                                                                  | CGImageAlphaInfo.noneSkipFirst.rawValue),
                           provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        }
    }
}

/// A key combination: "cmd+shift+n", "return", "escape", "down", "f5", "a".
struct KeyCombo {
    var base: String
    var modifiers: NSEvent.ModifierFlags
    var keyCode: UInt16
    var characters: String

    private static let codes: [String: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14,
        "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41,
        "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
    ]
    /// Named keys: key code and the character AppKit gives them.
    private static let named: [String: (UInt16, Int)] = [
        "return": (36, 13), "enter": (76, 3), "tab": (48, 9), "space": (49, 32), "delete": (51, 127), "backspace": (51, 127),
        "escape": (53, 27), "esc": (53, 27), "forwarddelete": (117, NSDeleteFunctionKey), "home": (115, NSHomeFunctionKey),
        "end": (119, NSEndFunctionKey), "pageup": (116, NSPageUpFunctionKey), "pagedown": (121, NSPageDownFunctionKey),
        "left": (123, NSLeftArrowFunctionKey), "right": (124, NSRightArrowFunctionKey), "down": (125, NSDownArrowFunctionKey),
        "up": (126, NSUpArrowFunctionKey), "period": (47, 46), "comma": (43, 44), "plus": (24, 43), "minus": (27, 45),
        "f1": (122, NSF1FunctionKey), "f2": (120, NSF2FunctionKey), "f3": (99, NSF3FunctionKey), "f4": (118, NSF4FunctionKey),
        "f5": (96, NSF5FunctionKey), "f6": (97, NSF6FunctionKey), "f7": (98, NSF7FunctionKey), "f8": (100, NSF8FunctionKey),
        "f9": (101, NSF9FunctionKey), "f10": (109, NSF10FunctionKey), "f11": (103, NSF11FunctionKey), "f12": (111, NSF12FunctionKey),
        "capslock": (57, 0),
    ]
    /// US keyboard: the character a key types with Shift, and the key's own character.
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0", "_": "-",
        "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
    ]

    /// The key (a Mac key code) that types `character` on a US keyboard, and whether with Shift; nil when none does.
    static func usKey(_ character: Character) -> (code: UInt16, shift: Bool)? {
        if character == "\n" || character == "\r" { return (36, false) }
        if character == "\t" { return (48, false) }
        if let base = shifted[character], let code = codes[String(base)] { return (code, true) }
        let text = String(character), lower = text.lowercased()
        guard character.isASCII, let code = codes[lower] else { return nil }
        return (code, text != lower)
    }

    /// A combo for the Windows desktop without its Windows key (⊞: "win+e", "windows+r", "⊞+d", "super+e"), and
    /// whether it had one; nil for the Windows key alone.
    static func windowsKey(in combo: String) -> (rest: String?, windowsKey: Bool) {
        let parts = combo.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        let rest = parts.filter { !["win", "windows", "⊞", "super"].contains($0.lowercased()) }
        guard rest.count < parts.count else { return (combo, false) }
        return (rest.isEmpty ? nil : rest.joined(separator: "+"), true)
    }

    static func modifiers(_ text: String) throws -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for part in text.lowercased().split(separator: "+").map(String.init) where !part.isEmpty {
            switch part {
            case "cmd", "command", "⌘": flags.insert(.command)
            case "shift", "⇧": flags.insert(.shift)
            case "opt", "option", "alt", "⌥": flags.insert(.option)
            case "ctrl", "control", "⌃": flags.insert(.control)
            default: throw AgentServer.Failure("Unknown modifier “\(part)”: cmd, shift, option, control (and win, the "
                                               + "Windows key, with target rdp).")
            }
        }
        return flags
    }

    init(_ combo: String) throws {
        var parts = combo.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        if combo.hasSuffix("++") { parts = Array(parts.dropLast(2)) + ["+"] }  // "cmd++"
        let key = parts.popLast() ?? ""
        modifiers = try Self.modifiers(parts.joined(separator: "+"))
        let lower = key.lowercased()
        if let (code, character) = Self.named[lower] {
            base = String(UnicodeScalar(UInt32(character)).map(Character.init) ?? " ")
            keyCode = code
            characters = base
        } else if key.count == 1, let code = Self.codes[lower] {
            base = lower
            keyCode = code
            characters = modifiers.contains(.shift) ? key.uppercased() : lower
        } else {
            throw AgentServer.Failure("Unknown key “\(key)”: a letter, digit or punctuation, or return, escape, tab, space, "
                                      + "delete, forwarddelete, up, down, left, right, home, end, pageup, pagedown, f1…f12, capslock.")
        }
    }

    /// A character typed (no key code when it isn't on the keyboard map: the text still arrives).
    init(character: Character) {
        let text = String(character)
        base = text.lowercased()
        keyCode = Self.codes[base] ?? 0
        modifiers = text != base ? .shift : []
        characters = text
    }

    func events(window: NSWindow) -> (down: NSEvent, up: NSEvent) {
        func event(_ type: NSEvent.EventType) -> NSEvent {
            // AppKit's "characters ignoring modifiers" keep Shift.
            NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: window.windowNumber, context: nil, characters: characters,
                             charactersIgnoringModifiers: modifiers.contains(.shift) ? base.uppercased() : base,
                             isARepeat: false, keyCode: keyCode)!
        }
        return (event(.keyDown), event(.keyUp))
    }
}

extension Array {
    var nilIfEmpty: Self? { isEmpty ? nil : self }
}
