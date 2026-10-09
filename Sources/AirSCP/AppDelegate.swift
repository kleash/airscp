import AirSCPCore
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// The app: the main window (MainWindowController), the Snippets, Keys and Settings windows and the menu bar. At
/// launch it applies the chosen appearance and takes over masters left running by a crashed AirSCP; it keeps the Dock
/// badge (transfers queued or running) and tells the connections when the Mac wakes; on Quit it disconnects every
/// host (ssh -O exit) and desktop, asking first if transfers are running.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSMenuItemValidation {
    var model: AppModel!
    private var askpass: AskpassServer!
    var main: MainWindowController!
    private var keys: KeysWindowController?
    private var snippets: NSWindow?
    private var settings: NSWindow?
    /// Help ▸ AirSCP Tips and Help ▸ Agent Guide.
    private var tips: NSWindow?
    private var guide: NSWindow?
    /// AIRSCP_AGENT=1 (tests) turns agent control on whatever Settings say, until Turn Off Agent Control.
    private var agentForced = Env.value("AGENT") == "1"
    private var observers: [AnyCancellable] = []
    private var saveFailing = false
    /// Agent control's socket (PLAN.md T), while Settings allow it or AIRSCP_AGENT=1.
    private var agent: AgentServer?
    /// Held while transfers are queued or running: App Nap would throttle AirSCP's own copying (folder streams,
    /// server-to-server copies) when its window isn't visible, and the Mac shouldn't fall asleep mid-transfer.
    private var transferActivity: NSObjectProtocol?

    /// main.swift creates the delegate outside the main actor; everything is set up at launch.
    nonisolated override init() {
        super.init()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false  // one main window: no tab items in the Window and View menus
        NSApp.mainMenu = mainMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Store.migrateFromPorter()  // the first start after the rename (PLAN.md X), before any window or setting is read
        if Env.value("SSH_DIR") != nil { useTestSSHDirectory() }
        model = AppModel(data: Store.load())
        // Once until a save works again: every change (a folder opened, a key typed in a snippet) tries to save.
        model.onSaveError = { [weak self] error in
            guard let self, !self.saveFailing else { return }
            self.saveFailing = true
            var shown = error as? AirSCPError ?? AirSCPError(.other, error.localizedDescription)
            shown.message += " Check the free space on this Mac and the permissions of \(Store.directory.path)."
            showError(shown, title: "AirSCP can't save its settings", on: self.main?.window)
        }
        model.onSaved = { [weak self] in self?.saveFailing = false }
        // Settings ▸ Debug logging, or AIRSCP_DEBUG=1: commands started from then on are logged (PLAN.md AE).
        observers.append(model.$data.map(\.settings.debugLogging).removeDuplicates().sink { [weak self] on in
            DebugLog.enabled = on || DebugLog.forced
            self?.model.debugLoggingOn = DebugLog.enabled
        })
        // Light or dark as chosen in Settings: before the first window opens, and at once when it changes.
        observers.append(model.$data.map(\.settings.appearance).removeDuplicates().sink { NSApp.appearance = appAppearance($0) })
        // The Transfers panel's speed limit, for every host's transfers that start from then on.
        observers.append(model.$data.map(\.settings.transferSpeedLimit).removeDuplicates().sink { megabytes in
            TransferCenter.shared.speedLimit = megabytes > 0 ? megabytes * 1_048_576 : nil
        })
        // Settings ▸ Verify transfers with SHA-256, for every single file that arrives from then on.
        observers.append(model.$data.map(\.settings.verifyTransfers).removeDuplicates().sink {
            TransferCenter.shared.verifyTransfers = $0
        })
        do {
            askpass = try AskpassServer(helperPath: Bundle.main.executablePath ?? CommandLine.arguments[0])
        } catch {
            showError(error, title: "AirSCP can't start", on: nil)
            NSApp.terminate(nil)
            return
        }
        TerminalLauncher.removeLeftovers()
        main = MainWindowController(model: model, askpass: askpass)
        askpass.proxyHandler = { [weak main] id, mayAsk, fromAirSCP, reply in
            guard let main else { return reply(nil) }
            main.answerProxy(id, mayAsk: mayAsk, fromAirSCP: fromAirSCP, reply: reply)
        }
        main.showWindow(nil)
        main.adoptRunningMasters()
        observers.append(model.$data.map(\.settings.agentControl).removeDuplicates().sink { [weak self] on in
            guard let self else { return }
            self.setAgentControl(on || self.agentForced)
        })
        observers.append(model.$activeTransfers.map { $0.values.reduce(0, +) }.removeDuplicates().sink { [weak self] count in
            NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
            self?.holdActivity(while: count > 0)
        })
        // After sleep: connected hosts check their connection, reconnecting ones try again.
        observers.append(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .sink { [weak self] _ in self?.main?.workspaces.values.forEach { $0.session.didWake() } })
        NSApp.activate(ignoringOtherApps: true)
        // A first run: the welcome sheet, once (Help ▸ Welcome to AirSCP… shows it again).
        if !model.data.settings.welcomeShown && model.data.hosts.isEmpty && model.data.rdpEntries.isEmpty { showWelcome(nil) }
        log.log("launched with \(self.model.data.hosts.count, privacy: .public) host(s)")
    }

    /// A click on the Dock icon: a closed window comes back. One in the Dock is AppKit's to bring back (true): showing
    /// it from here as well brought it back twice over.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let window = main?.window, !window.isVisible, !window.isMiniaturized { main?.showWindow(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Quitting disconnects every host (transfers cancelled and their partial files removed first) and desktop,
    /// after asking when transfers are running. An editor window with unsaved changes asks its Save / Don't Save /
    /// Cancel first (AppKit asks only document windows when an app quits), and the quit waits for the next ⌘Q.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let edited = NSApp.windows.first(where: { $0.isDocumentEdited && ($0.isVisible || $0.isMiniaturized) }) {
            if edited.isMiniaturized { edited.deminiaturize(nil) }
            edited.makeKeyAndOrderFront(nil)
            edited.performClose(nil)
            return .terminateCancel
        }
        guard let main else { return .terminateNow }
        let workspaces = Array(main.workspaces.values)
        let desktops = Array(main.desktops.values)
        guard !workspaces.isEmpty || !desktops.isEmpty else { return .terminateNow }
        let busy = workspaces.filter { $0.runningTransferCount > 0 }
        // Windows copying into a desktop's shared folder: those files would be left cut off at their full size.
        let copying = desktops.map { ($0, $0.filesBeingCopied()) }.filter { !$0.1.isEmpty }
        if !busy.isEmpty || !copying.isEmpty {
            let alert = NSAlert()
            alert.messageText = busy.isEmpty ? "Quit while Windows copies files into the shared folder?" : "Quit and cancel the transfers?"
            alert.informativeText = (busy.isEmpty ? "" : "Transfers are running on "
                + busy.map { "“\($0.host.displayName)”" }.joined(separator: ", ") + ". ")
                + (copying.isEmpty ? "" : "Windows is copying \(copying.map(\.1.count).reduce(0, +)) file(s) into a shared folder. ")
                + "Quitting stops them and removes the partly copied files."
            let quit = alert.addButton(withTitle: "Quit")
            quit.hasDestructiveAction = true
            quit.toolTip = "Stop them, remove the partly copied files and quit"
            alert.addButton(withTitle: "Cancel").toolTip = "Don't quit: let them finish"
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
            copying.forEach { $0.0.discardWhenEnded = $0.1 }
        }
        log.log("quit: disconnecting \(workspaces.count, privacy: .public) host(s), \(desktops.count, privacy: .public) desktop(s)")
        Task {
            await disconnectAll(workspaces.map(\.connection), desktops: desktops)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        agent?.close()
        askpass?.close()
    }

    /// Begins or ends the activity that keeps App Nap (and idle sleep) away while transfers run.
    func holdActivity(while transferring: Bool) {
        if transferring, transferActivity == nil {
            transferActivity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Transferring files")
        } else if !transferring, let activity = transferActivity {
            ProcessInfo.processInfo.endActivity(activity)
            transferActivity = nil
        }
    }

    /// Opens or closes agent control's socket (Settings ▸ Allow AI agents to control AirSCP).
    private func setAgentControl(_ on: Bool) {
        guard on != (agent != nil) else { return }
        if on {
            do {
                agent = try AgentServer(main: main, model: model)
            } catch {
                // The error says why (another AirSCP under agent control, or a settings folder whose path is too long).
                showError(error, title: "Agent control can't start", on: main.window)
            }
        } else {
            agent?.close()
            agent = nil
        }
        model.agentControlOn = agent != nil
    }

    /// Disconnects the hosts and desktops, for at most `timeout` seconds (a master still running then is taken over
    /// at the next launch).
    func disconnectAll(_ connections: [HostConnection], desktops: [RDPWorkspaceController] = [],
                       timeout: TimeInterval = 15) async {
        final class Done { var value = false }
        let done = Done()
        Task {
            await withTaskGroup(of: Void.self) { group in
                for connection in connections { group.addTask { await connection.disconnect() } }
                for desktop in desktops { group.addTask { await desktop.disconnect() } }
            }
            done.value = true
        }
        let deadline = Date().addingTimeInterval(timeout)
        while !done.value && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        if !done.value { log.error("quit: gave up waiting for the disconnects") }
    }

    /// $AIRSCP_SSH_DIR (testing): keys and the config to import come from there, and every ssh command gets
    /// `-F <dir>/config -o IdentityFile=none`, so the real ~/.ssh/config and keys are never read. A config AirSCP
    /// makes there keeps known hosts in that folder too, and the user's agent and keys out: without them ssh would
    /// write the real ~/.ssh/known_hosts (and an ssh run by hand with that config would offer the user's keys).
    private func useTestSSHDirectory() {
        let config = sshDirectory + "/config"
        try? FileManager.default.createDirectory(atPath: sshDirectory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: config) {
            let text = "UserKnownHostsFile \(Quote.configValue(sshDirectory + "/known_hosts"))\nIdentityAgent none\nIdentityFile none\n"
            FileManager.default.createFile(atPath: config, contents: Data(text.utf8))
        }
        OpenSSH.configFile = config
        log.log("AIRSCP_SSH_DIR: using \(sshDirectory, privacy: .public)")
    }

    func run(_ snippet: Snippet, on id: UUID) {
        // A sheet on the main window is about the host it shows: switching hosts under it would put it over another.
        if main.window?.attachedSheet != nil {
            showError(AirSCPError(.other, "AirSCP's window shows a sheet: answer or close it first."),
                      title: "Can't run “\(snippet.name)” now", on: snippets)
            return
        }
        if snippet.runInTerminal {
            main.openTerminal(for: id, command: snippet.command)
        } else {
            main.open(id) { $0.showRunCommand(snippet.command, run: true) }
        }
    }

    // MARK: Menu actions available in every window

    @objc func newHost(_ sender: Any?) { main.newHost() }

    @objc func newRemoteDesktop(_ sender: Any?) { main.newRemoteDesktop() }

    @objc func newGroup(_ sender: Any?) { main.newGroup() }

    @objc func showMainWindow(_ sender: Any?) { main.showWindow(nil) }

    /// Window ▸ Bring All to Front: AirSCP's windows in front of other apps (AppKit's own command leaves out the main
    /// window, which isn't in the Window menu's list).
    @objc func bringAllToFront(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.filter { $0.isVisible && $0.sheetParent == nil }.forEach { $0.orderFront(nil) }
        main.window?.makeKeyAndOrderFront(nil)
    }

    /// Help ▸ Welcome to AirSCP… (and the first run).
    @objc func showWelcome(_ sender: Any?) {
        main.showWindow(nil)
        guard let window = main.window, window.attachedSheet == nil else { return }
        model.data.settings.welcomeShown = true
        presentSheet(on: window) { close in
            WelcomeView { [weak self] choice in
                close()
                guard let self, let choice else { return }
                // After the sheet has gone: the command shows a sheet of its own.
                DispatchQueue.main.async {
                    switch choice {
                    case .importConfig: self.importSSHConfig(nil)
                    case .newHost: self.newHost(nil)
                    case .newDesktop: self.newRemoteDesktop(nil)
                    }
                }
            }
        }
    }

    /// Help ▸ AirSCP Help, Getting Started, What's New and Report a Problem: pages on the web (PLAN.md Y).
    @objc func showHelpSite(_ sender: Any?) { NSWorkspace.shared.open(HelpPage.home.url) }

    @objc func showGettingStarted(_ sender: Any?) { NSWorkspace.shared.open(HelpPage.gettingStarted.url) }

    @objc func showWhatsNew(_ sender: Any?) { NSWorkspace.shared.open(HelpPage.whatsNew.url) }

    @objc func reportProblem(_ sender: Any?) { NSWorkspace.shared.open(HelpPage.reportProblem) }

    /// Help ▸ Show Debug Log in Finder.
    @objc func showDebugLog(_ sender: Any?) { revealDebugLog() }

    /// Help ▸ Turn On Debug Logging, or Turn Off Debug Logging while it is on (its title says which): Settings ▸ Debug
    /// logging.
    @objc func toggleDebugLogging(_ sender: Any?) { model.data.settings.debugLogging = !model.debugLoggingOn }

    /// Help ▸ Copy Diagnostics: AirSCP's, macOS's and ssh's versions, the debug log's state and file, and its last 500
    /// lines, for a problem report.
    @objc func copyDiagnostics(_ sender: Any?) {
        Task {
            let ssh = await Runner.run([OpenSSH.ssh, "-V"]).stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let file = DebugLog.fileURL.path
            var lines = [DebugLog.about, ssh]
            if DebugLog.enabled {
                lines.append("Debug logging: on. The log: \(file)")
            } else {
                lines.append("Debug logging: off (turn it on in Settings ▸ Debug logging, make the problem happen again, then "
                             + "copy again). The log: \(file)")
            }
            let tail = await Task.detached { DebugLog.tail() }.value  // waits for a backlog: not on the main thread
            if !tail.isEmpty { lines += ["", "The debug log's last lines:", tail] }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        }
    }

    /// Help ▸ AirSCP Tips: a short page of tips, in a window.
    @objc func showTips(_ sender: Any?) {
        if tips == nil { tips = textWindow(title: "AirSCP Tips", text: AirSCPTips.text) }
        tips?.makeKeyAndOrderFront(nil)
    }

    /// Help ▸ Agent Guide: how AI agents drive AirSCP (Resources/AgentGuide.md, which the MCP server serves too).
    @objc func showAgentGuide(_ sender: Any?) {
        if guide == nil { guide = textWindow(title: "Agent Guide", text: readableMarkdown(AgentBridge.guideText)) }
        guide?.makeKeyAndOrderFront(nil)
    }

    /// The agent indicator's Turn Off Agent Control (also when AIRSCP_AGENT=1 turned it on).
    @objc func turnOffAgentControl(_ sender: Any?) {
        agentForced = false
        model.data.settings.agentControl = false
        setAgentControl(false)
    }

    /// Window ▸ the connected hosts and desktops, ⌘1…⌘9 (the item's tag is the number).
    @objc func selectConnected(_ sender: NSMenuItem) { main.selectConnected(sender.tag - 1) }

    /// View ▸ Enter Full Screen (⌃⌘F): the connected Windows desktop shown fills the screen (or leaves it), else
    /// AirSCP's window does (macOS's own full screen).
    @objc func toggleFullScreen(_ sender: Any?) {
        guard let main else { return }
        if let desktop = main.fullScreenDesktop { desktop.toggleFullScreen() } else { main.window?.toggleFullScreen(sender) }
    }

    @objc func showKeys(_ sender: Any?) {
        if keys == nil {
            keys = KeysWindowController(model: model, askpass: askpass) { [weak self] publicKey, id in
                self?.main.open(id) { $0.installKey(publicKey) }
            }
        }
        keys?.showWindow(nil)
        let model = keys?.keys
        Task { await model?.refresh() }
    }

    @objc func showSnippets(_ sender: Any?) {
        if snippets == nil {
            let controller = NSHostingController(rootView: SnippetsView(model: model) { [weak self] snippet, id in
                self?.run(snippet, on: id)
            })
            let window = NSWindow(contentViewController: controller)
            window.title = "Snippets"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.open(size: NSSize(width: 680, height: 400))
            snippets = window
        }
        snippets?.makeKeyAndOrderFront(nil)
    }

    @objc func showSettings(_ sender: Any?) {
        if settings == nil {
            let controller = NSHostingController(rootView: SettingsView(model: model))
            let window = NSWindow(contentViewController: controller)
            window.title = "Settings"
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            // A comfortable height, not the whole form's (it scrolls); it can be made as tall as the form, and keeps
            // the size it is given.
            let fitting = controller.view.fittingSize
            window.contentMinSize = NSSize(width: fitting.width, height: min(300, fitting.height))
            window.contentMaxSize = NSSize(width: fitting.width, height: fitting.height)
            window.open(size: NSSize(width: fitting.width, height: min(600, fitting.height)), autosave: layoutName("Settings"))
            settings = window
        }
        settings?.makeKeyAndOrderFront(nil)
    }

    /// File ▸ Import from ~/.ssh/config…: pick aliases (shown with what ssh -G resolves) to save as hosts.
    @objc func importSSHConfig(_ sender: Any?) {
        main.showWindow(nil)
        guard let window = main.window else { return }
        let text = (try? String(contentsOfFile: sshDirectory + "/config", encoding: .utf8)) ?? ""
        let aliases = SSHConfig.aliases(in: text, folder: sshDirectory)
        guard !aliases.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No hosts found in ~/.ssh/config"
            alert.informativeText = "AirSCP imports the names on its Host lines; patterns (with * or ?) are skipped. Add a "
                + "host with File ▸ New Host… instead."
            alert.addOK()
            alert.beginSheetModal(for: window)
            return
        }
        let importer = ConfigImport(aliases: aliases, model: model)
        presentSheet(on: window) { close in
            ConfigImportView(importer: importer, importChosen: { [weak self] chosen in
                guard let self else { return }
                if let first = self.model.importAliases(chosen).first { self.main.sidebar.selection = .host(first.id) }
            }, close: close)
        }
    }

    /// File ▸ Import Hosts…: a file from Export Hosts (on this Mac or another).
    @objc func importHosts(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a file made with Export Hosts."
        main.showWindow(nil)
        Panels.run(panel, on: main.window) { [self] urls in
            guard let url = urls.first else { return }
            importHosts(from: url)
        }
    }

    private func importHosts(from url: URL) {
        let file: AirSCPData
        do {
            file = try Store.importHosts(from: Data(contentsOf: url))
        } catch {
            return showError(error, title: "Can't import “\(url.lastPathComponent)”", on: main.window)
        }
        // Other options that run a program on this Mac at each connect (ProxyCommand, LocalCommand…): a file from
        // someone else keeps them only when the user says so.
        let running = file.hosts.flatMap { host in
            host.extraOptions.filter(SSHConfig.runsCommandHere).map { "\(host.displayName): \($0)" }
        }
        guard !running.isEmpty, let window = main.window else { return imported(file) }
        let alert = NSAlert()
        alert.messageText = "Hosts in “\(url.lastPathComponent)” run commands on this Mac"
        alert.informativeText = "These options run a program on this Mac each time the host connects:\n"
            + running.prefix(8).joined(separator: "\n") + (running.count > 8 ? "\n… and \(running.count - 8) more" : "")
            + "\n\nKeep them only if you trust whoever made the file."
        alert.addButton(withTitle: "Leave Them Out").toolTip = "Import the hosts without the options that run programs here"
        alert.addButton(withTitle: "Keep Them").toolTip = "Import the hosts with these options, as the file has them"
        alert.addButton(withTitle: "Cancel").toolTip = "Import nothing"
        alert.beginSheetModal(for: window) { [self] response in
            switch response {
            case .alertFirstButtonReturn:
                var safe = file
                for index in safe.hosts.indices { safe.hosts[index].extraOptions.removeAll(where: SSHConfig.runsCommandHere) }
                imported(safe)
            case .alertSecondButtonReturn: imported(file)
            default: break
            }
        }
    }

    /// Imports the file's hosts and says how many, and which were skipped.
    private func imported(_ file: AirSCPData) {
        let (hosts, skipped) = model.importHosts(file)
        let alert = NSAlert()
        alert.messageText = hosts.count == 1 ? "Imported 1 host" : "Imported \(hosts.count) hosts"
        alert.informativeText = "Saved passwords aren't in the file: AirSCP asks for them when connecting."
            + (skipped.isEmpty ? "" : "\n\nLeft out (a name starting with “-” can't be used: ssh would read it as an option): "
                + skipped.map { "“\($0)”" }.joined(separator: ", ") + ".")
        alert.addOK()
        if let window = main.window { alert.beginSheetModal(for: window) }
    }

    /// File ▸ Export Hosts…: hosts, groups, proxies and Remote Desktop entries as JSON, without passwords, for another Mac.
    @objc func exportHosts(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "AirSCP Hosts.json"
        panel.message = "Hosts, groups, proxies and remote desktops, without passwords (those stay in this Mac's Keychain)."
        main.showWindow(nil)
        Panels.run(panel, on: main.window) { [self] urls in
            guard let url = urls.first else { return }
            do {
                try Store.export(model.data).write(to: url, options: .atomic)
            } catch {
                showError(error, title: "Can't export the hosts", on: main.window)
            }
        }
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // Not under a sheet on the main window: it would act on another host than the one the sheet is about, or queue
        // a sheet behind it.
        let underSheet: Set<Selector?> = [#selector(selectConnected(_:)), #selector(newHost(_:)), #selector(newRemoteDesktop(_:)),
                                          #selector(newGroup(_:)), #selector(importSSHConfig(_:)), #selector(importHosts(_:)),
                                          #selector(showWelcome(_:))]
        var enabled = true, reason = "A sheet is open in AirSCP's window: answer or close it first."
        if underSheet.contains(item.action), main?.window?.attachedSheet != nil {
            enabled = false
        } else if item.action == #selector(selectConnected(_:)) {
            enabled = model.map { item.tag - 1 < $0.connected.count } ?? false
            reason = "Nothing connected has this number: connect a host or desktop first"
        } else if item.action == #selector(showDebugLog(_:)) {
            enabled = FileManager.default.fileExists(atPath: DebugLog.fileURL.path)
            reason = "No debug log yet: turn on Settings ▸ Debug logging, then connect again"
        } else if item.action == #selector(toggleDebugLogging(_:)) {
            item.title = model?.debugLoggingOn == true ? "Turn Off Debug Logging" : "Turn On Debug Logging"
            enabled = !DebugLog.forced
            reason = DebugLogButton.forcedReason
        } else if item.action == #selector(toggleFullScreen(_:)), let main {
            let full = main.fullScreenDesktop?.isFullScreen ?? main.window?.styleMask.contains(.fullScreen) == true
            item.title = full ? "Exit Full Screen" : "Enter Full Screen"
        }
        item.explain(enabled: enabled, reason: enabled ? nil : reason)
        return enabled
    }

    /// The Window menu's ⌘1…⌘9 items name what is connected; the others are hidden (their shortcuts stay). Host ▸
    /// Rename Group and Delete Group list the groups.
    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu.title == "Rename Group" || menu.title == "Delete Group" {
            menu.removeAllItems()
            let action = menu.title == "Rename Group" ? #selector(MainWindowController.renameGroupItem(_:))
                : #selector(MainWindowController.deleteGroupItem(_:))
            let groups = (model?.data.groups ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            for group in groups {
                let item = NSMenuItem(title: group.name + "…", action: action, keyEquivalent: "")
                item.representedObject = group.id
                item.toolTip = MenuHelp.tips[action]
                menu.addItem(item)
            }
            if groups.isEmpty {
                let none = NSMenuItem(title: "No Groups", action: nil, keyEquivalent: "")
                none.toolTip = "No groups yet: File ▸ New Group… makes one."
                menu.addItem(none)
            }
            return
        }
        let connected = model?.connected ?? []
        for item in menu.items where item.action == #selector(selectConnected(_:)) {
            let index = item.tag - 1
            let id = index < connected.count ? connected[index] : nil
            item.title = model?.host(id)?.displayName ?? model?.rdpEntry(id)?.displayName ?? ""
            item.isHidden = item.title.isEmpty
        }
        // AppKit's own items there (the windows' list) say what they do too.
        for item in menu.items where item.toolTip == nil { item.toolTip = MenuHelp.tip(for: item) }
    }

    // MARK: Menu bar

    /// Shortcuts taken here: ⌘N New Host, ⌘K Connect, ⌘T Open Terminal, ⌘E Disconnect, ⇧⌘R Run Command,
    /// ⇧⌘C Copy ssh Command, ⌥⌘L Command Log, ⌃⌘S Sidebar, ⌘0 AirSCP (the main window), ⌘1…⌘9 the connected hosts,
    /// ⌘, Settings, ⌘F Find. The browser's file commands (BrowserContentController) keep Finder's: ⇧⌘N, ⌘D, ⌘I, ⌘⌫, ⌘[ and so on.
    func mainMenu() -> NSMenu {
        func item(_ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            item.toolTip = action.flatMap { MenuHelp.tips[$0] }
            return item
        }
        func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = NSMenu(title: title)
            item.toolTip = MenuHelp.submenus[title]
            items.forEach { item.submenu!.addItem($0) }
            return item
        }
        func groupMenu(_ title: String) -> NSMenuItem {
            let entry = menu(title, [])
            entry.submenu?.delegate = self  // filled with the groups as it opens
            return entry
        }
        let services = menu("Services", [])
        NSApp.servicesMenu = services.submenu
        let tags: [(title: String, name: String?)] = [("None", nil)] + colorTags.map { ($0.title, $0.name) }
        let colors = menu("Colour Tag", tags.map { tag in
            let entry = item(tag.title, #selector(MainWindowController.setColorTag(_:)))
            entry.representedObject = tag.name
            return entry
        })
        let connected = (1...9).map { number -> NSMenuItem in
            let entry = item("", #selector(selectConnected(_:)), String(number))
            entry.tag = number
            entry.isHidden = true
            entry.allowsKeyEquivalentWhenHidden = true
            return entry
        }
        let windowMenu = menu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
            .separator(),
            item("AirSCP", #selector(showMainWindow(_:)), "0"),
        ] + connected + [
            .separator(),
            item("Snippets", #selector(showSnippets(_:))),
            item("Keys", #selector(showKeys(_:))),
            .separator(),
            item("Bring All to Front", #selector(bringAllToFront(_:))),
        ])
        windowMenu.submenu?.delegate = self
        NSApp.windowsMenu = windowMenu.submenu
        let helpMenu = menu("Help", [
            // No ⌘?: macOS keeps it for the Help menu's search field (the item lost it once the menu had been shown).
            item("AirSCP Help", #selector(showHelpSite(_:))),
            item("Getting Started", #selector(showGettingStarted(_:))),
            item("What's New", #selector(showWhatsNew(_:))),
            .separator(),
            item("Welcome to AirSCP…", #selector(showWelcome(_:))),
            item("AirSCP Tips", #selector(showTips(_:))),
            item("Agent Guide", #selector(showAgentGuide(_:))),
            .separator(),
            item("Turn On Debug Logging", #selector(toggleDebugLogging(_:))),
            item("Show Debug Log in Finder", #selector(showDebugLog(_:))),
            item("Copy Diagnostics", #selector(copyDiagnostics(_:))),
            item("Report a Problem", #selector(reportProblem(_:))),
        ])
        NSApp.helpMenu = helpMenu.submenu
        let bar = NSMenu()
        [
            menu("AirSCP", [
                item("About AirSCP", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
                .separator(),
                item("Settings…", #selector(showSettings(_:)), ","),
                .separator(),
                services,
                .separator(),
                item("Hide AirSCP", #selector(NSApplication.hide(_:)), "h"),
                item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
                item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
                .separator(),
                item("Quit AirSCP", #selector(NSApplication.terminate(_:)), "q"),
            ]),
            menu("File", [
                item("New Host…", #selector(newHost(_:)), "n"),
                item("New Remote Desktop…", #selector(newRemoteDesktop(_:))),
                item("New Group…", #selector(newGroup(_:))),
                .separator(),
                item("Import from ~/.ssh/config…", #selector(importSSHConfig(_:))),
                item("Import Hosts…", #selector(importHosts(_:))),
                item("Export Hosts…", #selector(exportHosts(_:))),
                .separator(),
                item("Close", #selector(NSWindow.performClose(_:)), "w"),
            ]),
            menu("Edit", [
                item("Undo", Selector(("undo:")), "z"),
                item("Redo", Selector(("redo:")), "Z"),
                .separator(),
                item("Cut", #selector(NSText.cut(_:)), "x"),
                item("Copy", #selector(NSText.copy(_:)), "c"),
                item("Paste", #selector(NSText.paste(_:)), "v"),
                item("Select All", #selector(NSText.selectAll(_:)), "a"),
                .separator(),
                item("Filter", #selector(MainWindowController.find(_:)), "f"),
            ]),
            menu("View", [
                item("Hide Sidebar", #selector(NSSplitViewController.toggleSidebar(_:)), "s", [.command, .control]),
                item("Show Command Log", #selector(MainWindowController.toggleCommandLog(_:)), "l", [.command, .option]),
                item("Hide Transfers", #selector(MainWindowController.toggleTransfers(_:))),
            ]),
            menu("Host", [
                item("Connect", #selector(MainWindowController.connectHost(_:)), "k"),
                item("Open Terminal", #selector(MainWindowController.openTerminal(_:)), "t"),
                item("Disconnect", #selector(MainWindowController.disconnectHost(_:)), "e"),
                .separator(),
                item("Run Command…", #selector(MainWindowController.runCommand(_:)), "R"),
                item("Tunnels", #selector(MainWindowController.showTunnels(_:))),
                item("Copy ssh Command", #selector(MainWindowController.copySSHCommand(_:)), "C"),
                .separator(),
                item("Edit…", #selector(MainWindowController.editHost(_:))),
                item("Duplicate", #selector(MainWindowController.duplicateHost(_:))),
                colors,
                .separator(),
                item("Delete…", #selector(MainWindowController.deleteHost(_:))),
                .separator(),
                groupMenu("Rename Group"),
                groupMenu("Delete Group"),
                .separator(),
                item("Proxies…", #selector(MainWindowController.showProxies(_:))),
            ]),
            windowMenu,
            helpMenu,
        ].forEach(bar.addItem)
        BrowserContentController.addMenuItems(to: bar)  // the Files tab's commands
        // Last in View, as on every Mac. Its target is fixed: while the Windows desktop is full screen, AirSCP's window
        // isn't in the responder chain (and the window's own toggleFullScreen: would take it otherwise).
        let fullScreen = item("Enter Full Screen", #selector(toggleFullScreen(_:)), "f", [.command, .control])
        fullScreen.target = self
        bar.item(withTitle: "View")?.submenu?.addItem(.separator())
        bar.item(withTitle: "View")?.submenu?.addItem(fullScreen)
        return bar
    }
}
