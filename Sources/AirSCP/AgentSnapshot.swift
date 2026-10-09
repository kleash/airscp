import AirSCPCore
import AppKit
import SwiftUI

/// One node of a window's accessibility tree, as VoiceOver reads it: an AppKit view or cell, or a SwiftUI node. Read
/// through key-value coding, because SwiftUI's nodes answer the NSAccessibility getters without declaring the protocol.
/// SwiftUI builds its nodes only once the app has `AXEnhancedUserInterface` set, as an assistive app would set it
/// (`AgentServer` does while agent control is on).
@MainActor
struct AXNode {
    let object: NSObject

    private func get(_ key: String) -> Any? {
        object.responds(to: NSSelectorFromString(key)) ? object.value(forKey: key) : nil
    }

    private func text(_ key: String) -> String? {
        (get(key) as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// "AXButton" → "button".
    var role: String { short(text("accessibilityRole") ?? "") }
    var subrole: String { short(text("accessibilitySubrole") ?? "") }
    /// Its accessibility id (AppKit's cells have their control's), or the view's identifier. AppKit's own "_NS:…"
    /// numbers aren't ids anyone could know.
    var id: String {
        let ids = [text("accessibilityIdentifier"), (object as? NSCell)?.controlView?.accessibilityIdentifier(),
                   view?.identifier?.rawValue]
        return ids.compactMap { $0 }.first { !$0.isEmpty && !$0.hasPrefix("_NS:") } ?? ""
    }
    var title: String { text("accessibilityTitle") ?? text("accessibilityLabel") ?? "" }
    var placeholder: String { text("accessibilityPlaceholderValue") ?? "" }
    /// Its help text (a tooltip): a disabled button's often says why. A segment of a picker says what its picker says.
    var help: String? {
        if let help = text("accessibilityHelp") ?? view?.toolTip.flatMap({ $0.isEmpty ? nil : $0 }) { return help }
        guard role == "radiobutton", let parent = get("accessibilityParent") as? NSObject else { return nil }
        return AXNode(object: parent).text("accessibilityHelp")
    }
    var enabled: Bool {
        if let textView = view as? NSTextView { return textView.isEditable }  // its AX "enabled" is always off
        return (get("isAccessibilityEnabled") as? Bool) ?? true
    }
    /// Screen coordinates (origin bottom left).
    var frame: NSRect { (get("accessibilityFrame") as? NSValue)?.rectValue ?? .zero }
    var children: [AXNode] { (get("accessibilityChildren") as? [Any] ?? []).compactMap { ($0 as? NSObject).map(AXNode.init) } }
    var parent: AXNode? { (get("accessibilityParent") as? NSObject).map(AXNode.init) }
    /// The AppKit control behind the node, if any (SwiftUI's text fields and pop-ups are AppKit cells).
    var view: NSView? { object as? NSView ?? (object as? NSCell)?.controlView }
    var isSecure: Bool { subrole == "securetextfield" || view is NSSecureTextField }

    /// The value as shown; a password field's as "•••(n)".
    var value: Any? {
        guard let value = get("accessibilityValue") else { return nil }
        if isSecure { return "•••(\((value as? String)?.count ?? 0))" }
        switch value {
        case let text as String: return text.isEmpty ? nil : text
        case let number as NSNumber: return number
        default: return nil
        }
    }

    var isField: Bool {
        ["textfield", "textarea", "checkbox", "popupbutton", "combobox", "slider", "radiobutton", "menubutton"].contains(role)
    }

    var isPressable: Bool {
        ["button", "checkbox", "radiobutton", "menubutton", "popupbutton", "link", "disclosuretriangle"].contains(role)
    }

    func press() -> Bool {
        if let button = view as? NSButton, object === button || object === button.cell {
            button.performClick(nil)
            return true
        }
        // A segment (tabs, Back/Forward): chosen as a click chooses it, without the click's tracking loop.
        let parent = get("accessibilityParent") as? NSObject
        if let segments = view as? NSSegmentedControl ?? parent as? NSSegmentedControl
            ?? (parent as? NSCell)?.controlView as? NSSegmentedControl,
           !title.isEmpty, let index = (0..<segments.segmentCount).first(where: {
            segments.label(forSegment: $0) == title || segments.toolTip(forSegment: $0) == title
        }) {
            guard segments.isEnabled(forSegment: index) else { return false }
            segments.selectedSegment = index
            segments.sendAction(segments.action, to: segments.target)
            return true
        }
        let selector = NSSelectorFromString("accessibilityPerformPress")
        guard object.responds(to: selector) else { return false }
        _ = object.perform(selector)
        return true
    }

    private func short(_ role: String) -> String {
        (role.hasPrefix("AX") ? String(role.dropFirst(2)) : role).lowercased()
    }

    /// The nodes under `root`, depth first. A sheet on it is a window of its own (flattened by itself). A short list's
    /// rows (up to 200 cells) are walked from its table (SwiftUI's lists show them nowhere else in-process): tunnels,
    /// keys, proxies, snippets, import's checkboxes. A file pane's rows (up to 50 000) are in the snapshot's panes
    /// instead, and longer lists (a server's processes) aren't entered.
    static func flatten(_ root: NSObject) -> [AXNode] {
        var result: [AXNode] = []
        func walk(_ node: AXNode, _ depth: Int) {
            guard depth == 0 || !(node.object is NSWindow) else { return }
            result.append(node)
            guard depth < 40 else { return }
            guard ["table", "outline", "list", "browser", "grid"].contains(node.role) else { return node.children.forEach { walk($0, depth + 1) } }
            guard let table = node.view as? NSTableView, !(table is FileTableView),
                  table.numberOfRows * max(table.numberOfColumns, 1) <= 200 else { return }
            for row in 0..<table.numberOfRows {
                for column in 0..<table.numberOfColumns {
                    if let cell = table.view(atColumn: column, row: row, makeIfNecessary: true) { walk(AXNode(object: cell), depth + 1) }
                }
            }
        }
        walk(AXNode(object: root), 0)
        return result
    }

    /// As JSON, with the frame in points from the top left of `reference` (a screenshot's pixels at scale 1).
    func json(relativeTo reference: NSWindow?) -> [String: Any] {
        var json: [String: Any] = ["role": role, "enabled": enabled]
        if !id.isEmpty { json["id"] = id }
        if !title.isEmpty { json["title"] = title }
        if let value { json["value"] = value }
        if !placeholder.isEmpty { json["placeholder"] = placeholder }
        if let help { json["help"] = help }
        if let reference {
            let rect = frame, base = reference.frame
            let values = [rect.minX - base.minX, base.maxY - rect.maxY, rect.width, rect.height]
            // Rows scrolled out of a list can have no place (an infinite frame): no frame then.
            if values.allSatisfy(\.isFinite) { json["frame"] = values.map { ($0 * 2).rounded() / 2 } }
        }
        return json
    }
}

/// The snapshot tool's sections, read from the controllers' own state (nothing secret: no Keychain reads, password
/// fields as "•••(n)").
extension AgentServer {
    /// "find" and "sync" are there only while their sheet is open, "rdp" while a desktop is selected.
    static let defaultSections: Set<String> = ["sidebar", "workspace", "panes", "transfers", "rdp", "sheets", "find", "sync"]

    func snapshot(_ arguments: [String: Any]) -> [String: Any] {
        let include = (arguments["include"] as? [String]).map(Set.init) ?? Self.defaultSections
        let rows = max(0, (arguments["rows"] as? NSNumber)?.intValue ?? 200)
        let logCount = max(0, (arguments["log"] as? NSNumber)?.intValue ?? 20)
        // The request before this one (this one's time is now).
        var result: [String: Any] = ["windows": windowsJSON(), "selection": selectionJSON(),
                                     "agent": ["on": true, "lastRequest": previousRequest.map { ISO8601DateFormatter().string(from: $0) as Any } ?? NSNull(),
                                               "client": model.agentClient.map { $0.name as Any } ?? NSNull(), "actions": model.agentActionCount],
                                     "appearance": model.data.settings.appearance.rawValue,
                                     // The debug log (PLAN.md AE): an agent reads the file itself.
                                     "debugLog": ["on": DebugLog.enabled, "path": DebugLog.fileURL.path]]
        if include.contains("sidebar") { result["sidebar"] = sidebarJSON() }
        if include.contains("workspace"), let workspace = main?.selectedWorkspace { result["workspace"] = workspaceJSON(workspace) }
        if include.contains("panes"), let browser = main?.selectedWorkspace?.browser, browser.isViewLoaded {
            result["panes"] = ["left": paneJSON(browser.left, rows: rows), "right": paneJSON(browser.right, rows: rows)]
        }
        if include.contains("transfers") { result["transfers"] = transfersJSON() }
        if include.contains("log"), let workspace = main?.selectedWorkspace {
            result["log"] = workspace.connection.log.entries.suffix(logCount).map { entry -> [String: Any] in
                ["date": ISO8601DateFormatter().string(from: entry.date), "command": entry.command,
                 "status": entry.status.map { Int($0) as Any } ?? NSNull(), "stderr": entry.stderr]
            }
        }
        if include.contains("monitor"), let monitor = main?.selectedWorkspace?.monitor { result["monitor"] = monitorJSON(monitor.model) }
        if include.contains("rdp"), let desktop = selectedDesktop { result["rdp"] = rdpJSON(desktop) }
        if include.contains("sheets") { result["sheets"] = sheetsJSON() }
        if include.contains("find"), let find = findModel { result["find"] = findJSON(find, rows: rows) }
        if include.contains("sync"), let sync = syncModel { result["sync"] = syncJSON(sync, rows: rows) }
        if include.contains("menus") { result["menus"] = menusJSON() }
        if include.contains("elements"), let window = (arguments["in"] as? String).flatMap({ try? scopes($0).last }) ?? main?.window {
            result["elements"] = ([window] + sheets(of: window)).flatMap { AXNode.flatten($0) }
                .filter { !["group", "splitgroup", "scrollarea", "unknown"].contains($0.role) }
                .map { $0.json(relativeTo: window) }
        }
        if include.contains("settings"),
           let data = try? JSONEncoder().encode(model.data.settings), let settings = try? JSONSerialization.jsonObject(with: data) {
            result["settings"] = settings
        }
        return result
    }

    var selectedDesktop: RDPWorkspaceController? {
        guard let main, let entry = main.selectedEntry else { return nil }
        return main.desktops[entry.id]
    }

    // MARK: Windows and sheets

    private func windowsJSON() -> [[String: Any]] {
        appWindows.map { window in
            let frame = window.frame
            return ["title": window.title, "subtitle": window.subtitle, "key": window.isKeyWindow, "visible": window.isVisible,
                    "frame": [frame.minX, frame.minY, frame.width, frame.height],
                    "sheets": sheets(of: window).map(sheetTitle)]
        }
    }

    /// The windows an agent works with: the main window (also while closed) and AirSCP's other windows on screen
    /// (Settings, Keys, Snippets, editors). Other main windows are someone else's: only tests make them.
    var appWindows: [NSWindow] {
        let main = self.main?.window
        return (main.map { [$0] } ?? []) + otherWindows().filter { window in
            window !== main && window.isVisible && window.sheetParent == nil && !(window.windowController is MainWindowController)
                && !(window is NSPanel && window.title.isEmpty)
        }
    }

    /// Whether `window` (or the window it is a sheet of) is one of `appWindows`.
    func isOurs(_ window: NSWindow?) -> Bool {
        var root = window
        while let parent = root?.sheetParent { root = parent }
        return root.map { root in appWindows.contains { $0 === root } } ?? false
    }

    /// The sheets on `window`, outermost first (a sheet can have a sheet: the editor's Test Connection prompt).
    func sheets(of window: NSWindow) -> [NSWindow] {
        var result: [NSWindow] = []
        var current = window.attachedSheet
        while let sheet = current {
            result.append(sheet)
            current = sheet.attachedSheet
        }
        return result
    }

    /// Every open sheet and app-modal alert, frontmost last.
    func openSheets() -> [NSWindow] {
        var result = appWindows.flatMap(sheets(of:))
        if let modal = NSApp.modalWindow, !result.contains(modal), otherWindows().contains(modal) { result.append(modal) }
        return result
    }

    private func sheetTitle(_ sheet: NSWindow) -> String {
        AXNode.flatten(sheet).first { $0.role == "statictext" }.flatMap { $0.value as? String } ?? sheet.title
    }

    func sheetsJSON() -> [[String: Any]] {
        openSheets().map(sheetJSON)
    }

    func sheetJSON(_ sheet: NSWindow) -> [String: Any] {
        if sheet is NSSavePanel {
            return ["kind": "panel", "title": sheet.title,
                    "note": "Open and Save panels can't be driven: press Cancel, then give the command again with file=<path> "
                        + "(files=[…] for several), which is chosen instead of showing the panel."]
        }
        let nodes = AXNode.flatten(sheet)
        var texts: [String] = [], fields: [[String: Any]] = [], buttons: [[String: Any]] = []
        for node in nodes {
            if node.role == "statictext", let text = node.value as? String {
                texts.append(text)
            } else if node.role == "button" || node.role == "radiobutton" || node.role == "disclosuretriangle" {
                var button: [String: Any] = ["title": node.title, "enabled": node.enabled]
                if let help = node.help { button["help"] = help }  // what it does, or (off) why not
                if node.role == "disclosuretriangle" { button["expanded"] = (node.value as? NSNumber)?.boolValue ?? false }
                if let control = node.view as? NSButton, control.keyEquivalent == "\r" || control.window?.defaultButtonCell === control.cell {
                    button["default"] = true
                }
                if let control = node.view as? NSButton, control.hasDestructiveAction { button["destructive"] = true }
                if node.role == "radiobutton" { button["selected"] = node.value as? NSNumber == 1 }
                if !node.title.isEmpty { buttons.append(button) }
            } else if node.isField {
                var field = node.json(relativeTo: nil)
                if let label = Self.label(of: node, in: nodes) {
                    field["label"] = label
                    if texts.last == label + ":" { texts.removeLast() }
                }
                if node.isSecure { field["secure"] = true }
                if let popup = node.view as? NSPopUpButton { field["options"] = popup.itemTitles.filter { !$0.isEmpty } }
                fields.append(field)
            }
        }
        var json: [String: Any] = ["kind": sheet.sheetParent == nil ? "alert" : "sheet", "buttons": buttons, "fields": fields]
        json["title"] = texts.first ?? sheet.title
        if texts.count > 1 { json["text"] = texts.dropFirst().joined(separator: "\n") }
        var window = sheet.sheetParent
        while let parent = window?.sheetParent { window = parent }  // a sheet on a sheet: the window both are on
        if let window { json["window"] = window.title }
        return json
    }

    /// A form's label in front of a field ("Host:" → "Host"): the text ending in ":" just before it.
    static func label(of field: AXNode, in nodes: [AXNode]) -> String? {
        guard let index = nodes.firstIndex(where: { $0.object === field.object }) else { return nil }
        for node in nodes[..<index].reversed().prefix(3) {
            if node.isField || node.isPressable { return nil }
            if node.role == "statictext", let text = node.value as? String {
                return text.hasSuffix(":") ? String(text.dropLast()).trimmingCharacters(in: .whitespaces) : nil
            }
        }
        return nil
    }

    // MARK: Sidebar and selection

    private func name(_ state: Session.State?) -> String {
        switch state {
        case .connecting?: return "connecting"
        case .connected?: return "connected"
        case .reconnecting?: return "reconnecting"
        case .disconnected?: return "disconnected"
        case .idle?, nil: return "idle"
        }
    }

    private func name(_ state: RDPSession.State?) -> String {
        switch state {
        case .connecting?: return "connecting"
        case .connected?: return "connected"
        case .disconnected?: return "disconnected"
        case .idle?, nil: return "idle"
        }
    }

    private func sidebarJSON() -> [String: Any] {
        let data = model.data
        let search = main?.sidebar.search ?? ""
        let connected = model.connected.enumerated().compactMap { index, id -> [String: Any]? in
            if let host = model.host(id) {
                return ["name": host.displayName, "kind": "host", "state": name(model.states[id]),
                        "transfers": model.activeTransfers[id] ?? 0, "shortcut": index < 9 ? "⌘\(index + 1)" : ""]
            }
            guard let entry = model.rdpEntry(id) else { return nil }
            return ["name": entry.displayName, "kind": "rdp", "state": name(model.rdpStates[id]),
                    "shortcut": index < 9 ? "⌘\(index + 1)" : ""]
        }
        let sections = AppModel.sections(data, search: search).map { section -> [String: Any] in
            ["group": section.group?.name ?? NSNull(), "hosts": section.hosts.map { host -> [String: Any] in
                var json: [String: Any] = ["name": host.displayName, "address": address(host), "state": name(model.states[host.id])]
                if let color = host.color { json["color"] = color }
                if let key = missingKeyFile(host) { json["warning"] = "The key file \(key) no longer exists" }
                if let jump = data.jump(for: host) { json["jump"] = jump.displayName }
                if host.jumpHostID == nil, let proxy = data.proxy(host.proxyID) { json["proxy"] = proxy.displayName }
                if let route = data.route(for: host) {
                    json["route"] = route.short  // as the sidebar shows it: "via corp-proxy → bastion"
                    if route.missing { json["warning"] = route.full }
                }
                json["hostKeyCheck"] = host.hostKeyCheck.rawValue  // ask, acceptNew or off (PLAN.md U.4)
                if host.hostKeyCheck == .off { json["shield"] = ChecksOffShield.help(ssh: true) }
                return json
            }]
        }
        return ["search": search, "connected": connected, "sections": sections,
                "rdp": AppModel.rdpEntries(data, search: search).map { entry -> [String: Any] in
                    var json: [String: Any] = ["name": entry.displayName, "host": entry.hostname, "state": name(model.rdpStates[entry.id])]
                    if let route = data.route(for: entry) { json["route"] = route.short }
                    json["certificateCheck"] = entry.certificateCheck.rawValue  // ask, trustNew, off or companyCA
                    if entry.certificateCheck == .companyCA { json["caFile"] = entry.caFile }
                    if entry.certificateCheck == .off { json["shield"] = ChecksOffShield.help(ssh: false) }
                    return json
                },
                "proxies": data.proxies.map(\.displayName)]
    }

    private func address(_ host: SSHHost) -> String { host.address }

    private func selectionJSON() -> Any {
        guard let main, let selection = main.sidebar.selection else { return NSNull() }
        if let host = model.host(selection.id) { return ["kind": "host", "name": host.displayName] }
        if let entry = model.rdpEntry(selection.id) { return ["kind": "rdp", "name": entry.displayName] }
        return NSNull()
    }

    // MARK: Workspace, panes, transfers, monitor, RDP

    private func workspaceJSON(_ workspace: HostWorkspace) -> [String: Any] {
        let state = workspace.connection.state
        var banner: [String: Any] = ["state": name(state)]
        switch state {
        case .idle: banner["text"] = ConnectionBanner.idleText(model.host(workspace.connection.hostID)); banner["buttons"] = ["Connect"]
        case .connecting: banner["text"] = "Connecting to \(workspace.host.displayName)…"; banner["buttons"] = ["Cancel"]
        case .connected:
            banner["text"] = workspace.host.hostKeyCheck == .off ? ConnectionBanner.checksOffText : ""
            banner["buttons"] = [String]()
        case .reconnecting(let next):
            banner["text"] = "The connection was lost. Reconnecting… next try in \(max(0, Int(next.timeIntervalSinceNow.rounded(.up)))) s"
            banner["buttons"] = ["Cancel", "Reconnect Now"]
        case .disconnected(let error):
            banner["text"] = "Disconnected: " + error.message
            banner["details"] = error.details
            banner["buttons"] = (error.details.isEmpty ? [] : ["Details…"])
                + [model.debugLoggingOn ? DebugLogButton.showTitle : DebugLogButton.retryTitle, "Reconnect"]
        }
        var json: [String: Any] = ["host": workspace.host.displayName, "banner": banner,
                                   "commandLogShown": workspace.showsCommandLog,
                                   "tab": workspace.tabs.tabViewItems[safe: workspace.tabs.selectedTabViewItemIndex]?.label ?? ""]
        let capabilities = workspace.session.capabilities
        if state == .connected {
            json["shell"] = capabilities.shell
            if let reason = capabilities.noShellReason { json["noShellReason"] = reason }
        }
        // The Tunnels tab's switches (named after their tunnels).
        json["tunnels"] = workspace.host.tunnels.map { tunnel -> [String: Any] in
            ["title": TunnelsModel.title(tunnel, server: workspace.host.displayName), "on": state == .connected && workspace.session.activeTunnels.contains(tunnel.id)]
        }
        return json
    }

    func paneJSON(_ pane: FilePane, rows limit: Int = 200) -> [String: Any] {
        let dates = ISO8601DateFormatter(), days = ISO8601DateFormatter()
        days.formatOptions = [.withFullDate]  // a date-only entry: "2024-01-01"
        let selected = pane.selectedItems.map(\.name)
        let sort = pane.sortOrder
        return [
            "source": pane.session?.host.displayName ?? "This Mac", "dir": pane.dir ?? NSNull(),
            "total": pane.rows.count, "items": pane.items.count, "selected": selected,
            "sort": ["column": sort.key, "ascending": sort.ascending], "filter": pane.filter, "showHidden": pane.showHidden,
            "status": pane.statusLabel.stringValue, "busy": !pane.activities.isEmpty || pane.rebuilding,
            "focused": pane.view.window?.firstResponder === pane.table,
            "canGoBack": !pane.back.isEmpty, "canGoForward": !pane.forward.isEmpty, "hiddenColumns": pane.hiddenColumns,
            "favourites": pane.favourites,
            "rows": pane.rows.prefix(limit).map { item -> [String: Any] in
                var row: [String: Any] = ["name": item.name, "kind": "\(item.kind)", "perm": item.permissions,
                                          "owner": item.owner, "group": item.group]
                if item.kind == .file { row["size"] = item.size } else if let size = pane.folderSizes[item.name] { row["size"] = size }
                if let id = item.ownerID { row["ownerID"] = id }
                if let id = item.groupID { row["groupID"] = id }
                if let modified = item.modified { row["modified"] = (item.dateOnly ? days : dates).string(from: modified) }
                if item.name.hasPrefix(".") { row["hidden"] = true }
                return row
            },
        ]
    }

    func transfersJSON() -> [String: Any] {
        let jobs = TransferCenter.shared.jobs
        return ["summary": TransferText.summary(jobs), "jobs": jobs.map(jobJSON),
                "speedLimit": TransfersPanel.speedTitle(model.data.settings.transferSpeedLimit)]
    }

    func jobJSON(_ job: TransferJob) -> [String: Any] {
        var json: [String: Any] = [
            "id": job.id.uuidString, "host": model.data.host(job.hostID)?.displayName ?? "—",
            "name": TransferText.name(job), "direction": TransferText.direction(job.direction),
            "size": TransferText.size(job), "status": TransferText.status(job), "route": TransferText.route(job),
        ]
        if let fraction = TransferText.fraction(job) { json["percent"] = Int(fraction * 100) }
        if job.status == .running {
            json["speed"] = job.progress.speed
            json["eta"] = TransferText.eta(job)
        }
        if let problem = TransferText.problem(job) {
            json["problem"] = problem.message
            json["details"] = problem.details
        }
        // A file that a lost connection cut off: its retry continues it (resumable), and did (resumed).
        if job.status.isFinished, main?.workspaces[job.hostID]?.session.transfers.isResumable(job.id) == true { json["resumable"] = true }
        if job.resumed { json["resumed"] = true }
        return json
    }

    func monitorJSON(_ monitor: MonitorModel) -> [String: Any] {
        guard let snapshot = monitor.snapshot else {
            return ["connected": monitor.connected, "refreshing": monitor.refreshing, "failure": monitor.failure ?? NSNull()]
        }
        // The processes as the table lists them: the search applied, in its sort order.
        let top = monitor.rows
        let sort = monitor.sortOrder.first.map { order -> [String: Any] in
            ["column": Self.processColumns.first { $0.path == order.keyPath }?.name ?? "", "ascending": order.order == .forward]
        }
        return [
            "connected": monitor.connected, "search": monitor.search, "sort": sort ?? NSNull(),
            "selected": top.filter { monitor.selection.contains($0.id) }.map(\.pid),
            "cpu": snapshot.cpu ?? NSNull(), "load": snapshot.load, "memory": ["used": snapshot.memoryUsed, "total": snapshot.memoryTotal],
            "swap": ["used": snapshot.swapUsed, "total": snapshot.swapTotal], "uptime": snapshot.uptime, "system": snapshot.system,
            "disks": snapshot.disks.map { ["mount": $0.mountPoint, "size": $0.size, "used": $0.used, "available": $0.available] },
            "processCount": snapshot.processes.count, "processNote": snapshot.processNote ?? NSNull(),
            "failure": monitor.failure ?? NSNull(),
            "processes": top.map { process -> [String: Any] in
                ["pid": process.pid, "user": process.user, "cpu": process.cpu ?? NSNull(), "memory": process.memory ?? NSNull(),
                 "name": process.name, "command": process.command, "state": process.state]
            },
        ]
    }

    /// The process table's columns as `sort` names them.
    static let processColumns: [(name: String, path: PartialKeyPath<MonitorProcess>)] = [
        ("pid", \MonitorProcess.pid), ("user", \MonitorProcess.user), ("cpu", \MonitorProcess.cpuOrder),
        ("mem", \MonitorProcess.memoryOrder), ("memory", \MonitorProcess.rss), ("time", \MonitorProcess.elapsedOrder),
        ("state", \MonitorProcess.state), ("command", \MonitorProcess.command),
    ]

    func rdpJSON(_ desktop: RDPWorkspaceController) -> [String: Any] {
        let bar = desktop.bar
        var json: [String: Any] = ["entry": model.rdpEntry(desktop.entryID)?.displayName ?? "", "state": name(desktop.state),
                                   "size": bar.size, "fullScreen": desktop.desktop.isInFullScreenMode, "sharing": bar.sharing,
                                   "sharedFolderReady": bar.sharedFolderReady, "message": bar.message,
                                   "remoteFiles": ["count": bar.remoteFiles.count, "bytes": bar.remoteFiles.bytes]]
        if let progress = bar.progress { json["progress"] = progress }
        if case .disconnected(let error) = desktop.state { json["error"] = error.message }
        return json
    }

    // MARK: Find Files and Synchronize (PLAN.md S.1)

    /// The open Find Files sheet's search.
    var findModel: FindModel? {
        openSheets().lazy.compactMap { ($0.contentViewController as? NSHostingController<FindView>)?.rootView.model }.first
    }

    /// The open Synchronize sheet's comparison and plan.
    var syncModel: SyncModel? {
        openSheets().lazy.compactMap { ($0.contentViewController as? NSHostingController<SyncView>)?.rootView.model }.first
    }

    /// The search and its results, as the sheet lists them: paths below the folder searched.
    func findJSON(_ find: FindModel, rows limit: Int = 200) -> [String: Any] {
        ["dir": find.dir, "pattern": find.pattern, "searching": find.searching, "status": find.status,
         "count": find.results.count, "selected": find.selection.map(find.relative) ?? NSNull(),
         "results": find.results.prefix(limit).map { item -> [String: Any] in
             item.isFolder ? ["path": find.relative(item.path), "folder": true] : ["path": find.relative(item.path)]
         }]
    }

    /// The comparison and, once it is done, the plan for the direction chosen, as the sheet shows them. Actions:
    /// upload, download, trash (on this Mac), delete (on the server); an unticked step has "ticked": false.
    func syncJSON(_ sync: SyncModel, rows limit: Int = 200) -> [String: Any] {
        let direction: String
        switch sync.direction {
        case .upload: direction = "This Mac → \(sync.server)"
        case .download: direction = "\(sync.server) → This Mac"
        case .both: direction = "Both ways"
        }
        var json: [String: Any] = ["local": sync.localDir, "remote": sync.remoteDir, "server": sync.server,
                                   "comparing": sync.started && sync.comparison == nil && sync.failure == nil,
                                   "started": sync.started, "folders": sync.folders,
                                   "direction": direction, "delete": sync.delete, "leaveOut": sync.leaveOut]
        if let failure = sync.failure { json["failure"] = failure }
        guard sync.comparison != nil else { return json }
        json["summary"] = sync.summary
        json["count"] = sync.plan.steps.count
        json["ticked"] = sync.chosen.steps.count
        json["steps"] = sync.plan.steps.prefix(limit).map { step -> [String: Any] in
            let action: String
            switch step.action {
            case .upload: action = "upload"
            case .download: action = "download"
            case .deleteHere: action = "trash"
            case .deleteThere: action = "delete"
            }
            var row: [String: Any] = ["action": action, "path": step.path + (step.item.isFolder ? "/" : "")]
            if !step.item.isFolder { row["size"] = step.item.size }
            if step.replaces { row["replaces"] = true }
            if sync.unticked.contains(step.path) { row["ticked"] = false }
            return row
        }
        return json
    }

    // MARK: Menus

    /// Every menu-bar item with an action: its path, shortcut, whether it is enabled now and, when FilePane knows,
    /// why not.
    func menusJSON() -> [[String: Any]] {
        var result: [[String: Any]] = []
        func walk(_ menu: NSMenu, _ path: [String]) {
            menu.delegate?.menuNeedsUpdate?(menu)
            for item in menu.items where !item.isSeparatorItem && !item.isHidden && !item.isAlternate {  // ⌥'s show only with ⌥
                if let submenu = item.submenu {
                    if submenu !== NSApp.servicesMenu { walk(submenu, path + [item.title]) }
                    continue
                }
                guard item.action != nil else { continue }
                let check = validate(item)
                var json: [String: Any] = ["path": (path + [item.title]).joined(separator: " > "), "enabled": check.enabled]
                if !item.keyEquivalent.isEmpty { json["shortcut"] = shortcut(item) }
                if item.state == .on { json["state"] = "on" }
                if let reason = check.reason, !check.enabled { json["reason"] = reason }
                result.append(json)
            }
        }
        if let bar = NSApp.mainMenu {
            for top in bar.items { if let submenu = top.submenu { walk(submenu, [top.title]) } }
        }
        return result
    }

    private func shortcut(_ item: NSMenuItem) -> String {
        var modifiers = item.keyEquivalentModifierMask
        var key = item.keyEquivalent
        if key.lowercased() != key { modifiers.insert(.shift) }
        let names: [String: String] = ["\u{8}": "⌫", "\r": "↩", "\u{F700}": "↑", "\u{F701}": "↓"]
        key = names[key] ?? key.uppercased()
        return (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "")
            + (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "")
            + (modifiers.contains(.function) ? "🌐" : "") + key
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
