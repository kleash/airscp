import AirSCPCore
import AppKit
import SwiftUI

/// What each menu command does, in one line (PLAN.md U): the menu items' tooltips. By action, so a command says the
/// same in the menu bar and in a context menu. While an item is off, its validation puts the reason there instead
/// (`NSMenuItem.explain`).
enum MenuHelp {
    static let tips: [Selector: String] = Dictionary([
        // AirSCP
        (#selector(NSApplication.orderFrontStandardAboutPanel(_:)), "Show AirSCP's version and the licences of what it is built with"),
        (#selector(AppDelegate.showSettings(_:)), "Change the look, the terminal app, where downloads and new keys go, how new servers are checked and the file browser's defaults"),
        (#selector(NSApplication.hide(_:)), "Hide AirSCP's windows; connections and transfers carry on"),
        (#selector(NSApplication.hideOtherApplications(_:)), "Hide every other app's windows"),
        (#selector(NSApplication.unhideAllApplications(_:)), "Show the windows of every app again"),
        (#selector(NSApplication.terminate(_:)), "Disconnect every host and desktop and quit; asks first while transfers run"),
        // File
        (#selector(AppDelegate.newHost(_:)), "Save a server you log in to over SSH: its address, user and how to log in"),
        (#selector(AppDelegate.newRemoteDesktop(_:)), "Save a Windows computer to open with the built-in Remote Desktop client"),
        (#selector(AppDelegate.newGroup(_:)), "Make a group to sort hosts under in the sidebar"),
        (#selector(AppDelegate.importSSHConfig(_:)), "Make hosts from the aliases in your ~/.ssh/config; ssh keeps reading their settings there"),
        (#selector(AppDelegate.importHosts(_:)), "Load hosts, groups, proxies and desktops exported by AirSCP on another Mac"),
        (#selector(AppDelegate.exportHosts(_:)), "Save your hosts, groups, proxies and desktops to a file for another Mac (no passwords)"),
        (#selector(FilePane.newFolder(_:)), "Make a folder in the pane that has the focus"),
        (#selector(FilePane.newFile(_:)), "Make an empty file in the server folder shown"),
        (#selector(FilePane.openItems(_:)), "Open the folder here, or the file in its app (a server file is downloaded first)"),
        (#selector(FilePane.editItem(_:)), "Open the text file in AirSCP's own editor; ⌘S saves it back to the server"),
        (#selector(FilePane.quickLook(_:)), "Preview the selected files without opening them (Space does the same)"),
        (#selector(FilePane.getInfo(_:)), "Show the size, dates, owner and permissions of one server item"),
        (#selector(FilePane.findFiles(_:)), "Search names below the server folder shown, by name or a pattern like *.log"),
        (#selector(FilePane.copyToOtherPane(_:)), "Copy the selection into the folder the other pane shows (drag does the same)"),
        (#selector(FilePane.chooseUpload(_:)), "Choose files on this Mac to upload into the server folder shown"),
        (#selector(FilePane.downloadTo(_:)), "Download the selection into a folder you choose on this Mac"),
        (#selector(FilePane.downloadArchive(_:)), "Download the selection as one archive the server streams (no space needed there)"),
        (#selector(FilePane.uploadCompressed(_:)), "Pack the selected Mac items into one .tar.gz, upload it and unpack it on the server"),
        (#selector(FilePane.synchronize(_:)), "Compare the Mac folder with the server folder and copy what is new or newer"),
        (#selector(FilePane.renameItem(_:)), "Rename the selected item"),
        (#selector(FilePane.duplicateItems(_:)), "Copy the selected server items next to themselves (“name 2”)"),
        (#selector(FilePane.compressItems(_:)), "Pack the selected server items into a .zip or .tar.gz on the server"),
        (#selector(FilePane.extractHere(_:)), "Unpack the selected archive into this folder on the server (asks before replacing)"),
        (#selector(FilePane.extractToFolder(_:)), "Unpack the selected archive into a new folder named after it"),
        (#selector(FilePane.editPermissions(_:)), "Change who may read, write and run the selected server items (chmod)"),
        (#selector(FilePane.makeExecutable(_:)), "Let the selected server files run as programs (chmod +x)"),
        (#selector(FilePane.runItem(_:)), "Run the selected server file as a program and show its output"),
        (#selector(FilePane.copyPath(_:)), "Copy the full path of the selection (or of the folder shown)"),
        (#selector(FilePane.openTerminalHere(_:)), "Open Terminal on this server in the folder shown"),
        (#selector(FilePane.revealInFinder(_:)), "Show the selected Mac items in Finder"),
        (#selector(FilePane.deleteItems(_:)), "Delete the selected server items (asks first); items on this Mac go to the Trash"),
        (#selector(NSWindow.performClose(_:)), "Close the window; connections stay open (⌘0 brings AirSCP's window back)"),
        // Edit (the same selectors as the panes' Cut, Copy, Paste and Find)
        (Selector(("undo:")), "Undo the last change"),
        (Selector(("redo:")), "Redo what was undone"),
        (#selector(NSText.cut(_:)), "Cut the selection: text, or server items to move with Paste"),
        (#selector(NSText.copy(_:)), "Copy the selection: text, or items to paste into another folder or server"),
        (#selector(NSText.paste(_:)), "Paste text, or the copied items into the folder shown (files copied in Finder are uploaded)"),
        (#selector(NSText.selectAll(_:)), "Select everything in the list or field that has the focus"),
        (#selector(MainWindowController.find(_:)), "Type to narrow the list that has the focus: a pane's files, or the sidebar's hosts"),
        // View
        (#selector(NSSplitViewController.toggleSidebar(_:)), "Hide or show the list of hosts"),
        (#selector(MainWindowController.toggleCommandLog(_:)), "Show or hide every command AirSCP ran on this host, with its result, below the tabs"),
        (#selector(MainWindowController.toggleTransfers(_:)), "Hide or show the queue of uploads and downloads at the bottom of the window"),
        (#selector(FilePane.toggleHiddenFiles(_:)), "Show or hide files whose names start with a dot, in the pane that has the focus"),
        (#selector(FilePane.calculateFolderSizes(_:)), "Work out the size of every folder in the server pane (du); Settings can do it always"),
        (#selector(FilePane.refresh(_:)), "List the folder again"),
        (#selector(FilePane.toggleColumnNamed(_:)), "Show or hide this column in the pane that has the focus"),
        (#selector(FilePane.toggleColumn(_:)), "Show or hide this column"),
        // Go
        (#selector(FilePane.goBack(_:)), "Go back to the folder shown before"),
        (#selector(FilePane.goForward(_:)), "Go forward again"),
        (#selector(FilePane.goUp(_:)), "Go up one folder"),
        (#selector(FilePane.goHome(_:)), "Go to the account's home folder"),
        (#selector(FilePane.goToFolder(_:)), "Type a path to go to (~ is the home folder)"),
        (#selector(FilePane.addToFavourites(_:)), "Keep the server folder shown, to come back to it from Go ▸ Favourites"),
        (#selector(FilePane.openFavourite(_:)), "Go to this favourite folder"),
        (#selector(FilePane.removeFavourite(_:)), "Forget this favourite folder"),
        // Host
        (#selector(MainWindowController.connectHost(_:)), "Connect to the selected host or desktop and show its files or screen"),
        (#selector(MainWindowController.openTerminal(_:)), "Open an ssh session to this host in Terminal (or iTerm, see Settings)"),
        (#selector(MainWindowController.disconnectHost(_:)), "Close the connection; asks first while transfers run"),
        (#selector(MainWindowController.runCommand(_:)), "Run one command on the host and read its output here (sudo and editors: Terminal)"),
        (#selector(MainWindowController.showTunnels(_:)), "Show the host's port forwards (its Tunnels tab)"),
        (#selector(MainWindowController.copySSHCommand(_:)), "Copy the ssh command line for this host, to paste into any terminal"),
        (#selector(MainWindowController.editHost(_:)), "Change the selected host's or desktop's settings"),
        (#selector(MainWindowController.duplicateHost(_:)), "Make a copy of the selected host or desktop, with its tunnels and saved password"),
        (#selector(MainWindowController.setColorTag(_:)), "Colour this host's icon in the sidebar"),
        (#selector(MainWindowController.deleteHost(_:)), "Forget the selected host or desktop and its saved password (asks first)"),
        (#selector(MainWindowController.renameGroupItem(_:)), "Rename this group; its hosts stay in it"),
        (#selector(MainWindowController.deleteGroupItem(_:)), "Remove this group; its hosts are kept, without a group"),
        (#selector(MainWindowController.showProxies(_:)), "Manage the HTTP proxies a host's connection can go through (most people need none)"),
        // Window
        (#selector(NSWindow.performMiniaturize(_:)), "Put the window in the Dock"),
        (#selector(NSWindow.performZoom(_:)), "Fit the window to the screen"),
        (#selector(AppDelegate.showMainWindow(_:)), "Bring AirSCP's main window back"),
        (#selector(AppDelegate.selectConnected(_:)), "Switch to this connected host or desktop"),
        (#selector(AppDelegate.showSnippets(_:)), "Commands you run often, kept to run on any host"),
        (#selector(AppDelegate.showKeys(_:)), "Your SSH keys: make one, import a PuTTY key, copy it, install it on a host, add it to the agent"),
        (#selector(AppDelegate.bringAllToFront(_:)), "Bring every AirSCP window in front of other apps"),
        (#selector(NSWindow.makeKeyAndOrderFront(_:)), "Bring this window to the front"),
        // Help
        (#selector(AppDelegate.showHelpSite(_:)), "Open AirSCP Help, the guide on the web: every task step by step, with pictures"),
        (#selector(AppDelegate.showGettingStarted(_:)), "Open the first steps in AirSCP Help: add a server, connect, copy files"),
        (#selector(AppDelegate.showWhatsNew(_:)), "Open the page of what is new in this version of AirSCP, on the web"),
        (#selector(AppDelegate.reportProblem(_:)), "Tell AirSCP's makers about a problem: a form on GitHub, with your versions filled in"),
        (#selector(AppDelegate.showDebugLog(_:)), "Show the debug log in Finder, to read it or attach it to a problem report"),
        (#selector(AppDelegate.copyDiagnostics(_:)), "Copy the versions of AirSCP, macOS and ssh and the debug log's last lines, for a report"),
        (#selector(AppDelegate.showWelcome(_:)), "Show the welcome sheet again: import, add a host, the three tips"),
        (#selector(AppDelegate.showTips(_:)), "Short tips for everyday use, in a window"),
        (#selector(AppDelegate.showAgentGuide(_:)), "How AI agents drive AirSCP (the same text the MCP server serves)"),
    ]) { first, _ in first }

    /// Menu items that only open a submenu, by title.
    static let submenus: [String: String] = [
        "Colour Tag": "Colour this host's icon in the sidebar",
        "Rename Group": "Rename one of your groups",
        "Delete Group": "Remove one of your groups; its hosts are kept",
        "Columns": "Show or hide the columns of the pane that has the focus",
        "Favourites": "The server folders kept with Add to Favourites, for the host of the pane that has the focus",
        "Remove": "Forget one of the favourite folders",
        "Services": "Other apps' commands for what is selected",
    ]

    /// What `item` does (nil when AirSCP doesn't know: AppKit's own additions).
    static func tip(for item: NSMenuItem) -> String? {
        item.action.flatMap { tips[$0] } ?? (item.submenu != nil ? submenus[item.title] : nil)
    }
}

extension NSMenuItem {
    /// Sets the tooltip for the item's state: why it is off (when that is known), else what it does.
    func explain(enabled: Bool, reason: String?) {
        toolTip = (enabled ? nil : reason) ?? MenuHelp.tip(for: self) ?? toolTip
    }
}

// MARK: The debug log (PLAN.md AE)

/// Shows the debug log in Finder (Help ▸ Show Debug Log in Finder, the failure banners' Show Debug Log); its folder
/// when there is no file (yet).
@MainActor
func revealDebugLog() {
    // Once the lines still being written are in the file, waited for off the main thread (a backlog takes a while).
    Task.detached {
        DebugLog.flush()
        await MainActor.run {
            let file = DebugLog.fileURL
            if FileManager.default.fileExists(atPath: file.path) {
                NSWorkspace.shared.activateFileViewerSelecting([file])
            } else if FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path) {
                NSWorkspace.shared.open(file.deletingLastPathComponent())
            }
        }
    }
}

/// A failure banner's (and the connect error's) way to the debug log: Show Debug Log while it is on, else Turn On Debug
/// Logging and Try Again (`retry`: what the banner's Reconnect does).
struct DebugLogButton: View {
    @ObservedObject var model: AppModel
    let retry: () -> Void

    static let showTitle = "Show Debug Log", retryTitle = "Turn On Debug Logging and Try Again"
    static let showTip = "Show AirSCP-debug.log in Finder, to read what happened or attach it to a problem report"
    static let retryTip = "Turn on Settings ▸ Debug logging and connect again, so the log shows what went wrong"

    var body: some View {
        if model.debugLoggingOn {
            Button(Self.showTitle, action: revealDebugLog).help(Self.showTip)
        } else {
            Button(Self.retryTitle) {
                model.data.settings.debugLogging = true
                retry()
            }
            .help(Self.retryTip)
        }
    }
}

/// A form's grey caption under a field (PLAN.md U): it wraps within the field's column rather than widening the form.
struct FormCaption: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 390, alignment: .leading)
    }
}

// MARK: The documentation site (PLAN.md Y)

/// AirSCP Help on the web: the pages the Help menu and the sheets' "?" buttons open, one per topic, all in this table
/// (the path of each page on the site). Each is a page of docs/ in AirSCP's repository; DocsTests checks that it is.
enum HelpPage: String, CaseIterable {
    case home = ""
    case gettingStarted = "getting-started/"
    case whatsNew = "whats-new.html"
    case host = "connecting/add-a-host.html"
    case importConfig = "connecting/import-from-ssh-config.html"
    case proxies = "connecting/proxies.html"
    case trustServer = "connecting/trust-a-server.html"
    case certificates = "connecting/self-signed-certificates.html"
    case remoteDesktop = "remote-desktop/add-a-windows-computer.html"
    case folderTransfer = "files/upload-a-folder.html"
    case conflicts = "files/replace-or-keep-both.html"
    case permissions = "files/permissions.html"
    case compress = "files/compress-and-extract.html"
    case downloadArchive = "transfers/download-as-archive.html"
    case synchronize = "synchronize.html"
    case find = "find.html"
    case tunnels = "tunnels.html"
    case runCommand = "commands/run-a-command.html"
    case newKeyPair = "keys/new-key-pair.html"
    case installKey = "keys/install-a-key.html"
    case puttyKeys = "keys/putty-keys.html"
    case settings = "settings.html"

    /// The site: GitHub Pages, built from docs/.
    static let site = URL(string: "https://kleash.github.io/airscp/")!

    /// `URL(string: "")` is nil, so the home page ("") is the site itself.
    var url: URL { URL(string: rawValue, relativeTo: Self.site)?.absoluteURL ?? Self.site }

    /// Help ▸ Report a Problem: the repository's bug report form, with AirSCP's and macOS's versions filled in.
    static var reportProblem: URL {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let system = ProcessInfo.processInfo.operatingSystemVersion
        var form = URLComponents(string: "https://github.com/kleash/airscp/issues/new")!
        form.queryItems = [URLQueryItem(name: "template", value: "bug_report.yml"),
                           URLQueryItem(name: "version", value: version),
                           URLQueryItem(name: "macos", value: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)")]
        return form.url!
    }

    /// Opens the page in the browser: the "?" buttons' target, and NSAlert's help button's delegate (`addHelp`).
    final class Opener: NSObject, NSAlertDelegate {
        static let shared = Opener()
        var page = HelpPage.home

        @objc func open(_ sender: Any?) { NSWorkspace.shared.open(page.url) }

        func alertShowHelp(_ alert: NSAlert) -> Bool {
            NSWorkspace.shared.open(HelpPage(rawValue: alert.helpAnchor ?? "")?.url ?? HelpPage.site)
            return true
        }
    }
}

/// The small "?" button of a sheet with several options (PLAN.md Y): it opens the sheet's page of AirSCP Help.
struct HelpButton: NSViewRepresentable {
    let page: HelpPage

    init(_ page: HelpPage) { self.page = page }

    func makeCoordinator() -> HelpPage.Opener { HelpPage.Opener() }

    func makeNSView(context: Context) -> NSButton {
        context.coordinator.page = page
        let button = NSButton(title: "", target: context.coordinator, action: #selector(HelpPage.Opener.open(_:)))
        button.bezelStyle = .helpButton
        button.toolTip = helpButtonTip
        button.setAccessibilityIdentifier("help")
        return button
    }

    func updateNSView(_ button: NSButton, context: Context) { context.coordinator.page = page }
}

private let helpButtonTip = "Open the page of AirSCP Help about this, in your browser"

extension NSAlert {
    /// Adds the alert's "?" button, which opens `page` of AirSCP Help. Call it last: after the buttons and the
    /// accessory view.
    func addHelp(_ page: HelpPage) {
        showsHelp = true
        helpAnchor = page.rawValue
        delegate = HelpPage.Opener.shared
        layout()  // makes the button now, to give it a tooltip and an id like the sheets' "?"
        func buttons(in view: NSView) -> [NSButton] { view.subviews.flatMap { ($0 as? NSButton).map { [$0] } ?? buttons(in: $0) } }
        for button in buttons(in: window.contentView ?? NSView()) where button.bezelStyle == .helpButton {
            button.toolTip = helpButtonTip
            button.setAccessibilityIdentifier("help")
        }
    }
}

// MARK: First run

/// The welcome sheet (PLAN.md U): once on a first run with no hosts, and from Help ▸ Welcome to AirSCP…. Its three
/// buttons close it and run their command; Start just closes it.
struct WelcomeView: View {
    enum Choice { case importConfig, newHost, newDesktop }

    let close: (Choice?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48).accessibilityHidden(true)
                Text("Welcome to AirSCP").font(.title2.weight(.semibold))
            }
            Text("AirSCP is a two-pane file browser and Remote Desktop client for your servers. Add a host, connect, and "
                 + "drag files between your Mac and the server.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Import from ~/.ssh/config…") { close(.importConfig) }
                    .help(MenuHelp.tips[#selector(AppDelegate.importSSHConfig(_:))] ?? "")
                Button("New Host…") { close(.newHost) }
                    .help(MenuHelp.tips[#selector(AppDelegate.newHost(_:))] ?? "")
                Button("New Remote Desktop…") { close(.newDesktop) }
                    .help(MenuHelp.tips[#selector(AppDelegate.newRemoteDesktop(_:))] ?? "")
            }
            VStack(alignment: .leading, spacing: 10) {
                tip("arrow.left.arrow.right", "Drag to copy: between the two panes, from Finder onto a server, or from a "
                    + "server onto the Desktop.")
                tip("cursorarrow.click.2", "Right-click a file for everything else: rename, permissions, compress, run, Get Info.")
                tip("command", "⌘1 to ⌘9 switch between connected hosts. Connections stay open while you look at another.")
            }
            Text("Every button explains itself when you hover. More any time: Help ▸ AirSCP Tips, and every task step by "
                 + "step in Help ▸ AirSCP Help.")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                Spacer()
                Button("Start") { close(nil) }
                    .keyboardShortcut(.defaultAction).primaryTint()
                    .help("Close this and start with an empty window")
            }
        }
        .padding(24)
        .frame(width: 540)
        // Escape, as in the other sheets (Return is Start): nothing here takes the keyboard focus, so .onExitCommand
        // would never hear it; a cancel button that isn't shown does.
        .background(Button("") { close(nil) }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true))
    }

    private func tip(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).frame(width: 20).foregroundColor(.accentColor).accessibilityHidden(true)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Help ▸ AirSCP Tips and Agent Guide

enum AirSCPTips {
    static let text = """
        Hosts
        • A host is a server you log in to over SSH. File ▸ New Host… saves one; only the address is required.
        • Have a ~/.ssh/config? File ▸ Import from ~/.ssh/config… makes hosts from its aliases.
        • Behind a bastion? Save the bastion as a host, then choose it under “Connect through” in the server's settings.
        • No key yet? Window ▸ Keys ▸ New Key Pair… makes one (or “Log in with ▸ Generate New Key…” in a host's settings) \
        and installs it on a server, so you log in without a password.
        • A PuTTY key (.ppk)? Window ▸ Keys ▸ Import Key… (or drop it there) makes it one ssh can use; Export for PuTTY… \
        goes the other way.
        • A server you can't check (a lab, a test machine)? Its settings' Advanced ▸ Server key can trust new servers \
        automatically; a changed key is still refused.
        • Double-click a host to connect; ⌘1 to ⌘9 switch between connected hosts. Connections stay open meanwhile.

        Files
        • Drag files between the two panes to copy them, or use the Upload / Download button under a pane.
        • Drag from Finder onto a server pane to upload; drag a server item onto the Desktop to download it.
        • Within one server a drag moves; hold ⌥ to copy. Cut, Copy and Paste work too.
        • The left pane can show another connected server (its pop-up menu): copies then go server to server.
        • Right-click a file for everything else: rename, permissions, compress, extract, run, Get Info.
        • Space previews a file (Quick Look); Return opens it; ⌘⌫ deletes it (servers ask first).
        • ⇧⌘G types a path; ⇧⌘. shows hidden files; ⌘F filters the list; ⇧⌘F finds files below the folder.
        • Edit in AirSCP opens a text file in a window; ⌘S saves it back to the server.
        • File ▸ Synchronize… compares the two folders and shows what would be copied before copying.
        • Folders and many files go as one stream; “Compress during transfer” helps on slow links.

        Transfers
        • Transfers run in the background, one at a time per host; keep browsing meanwhile.
        • A transfer cut off by a lost connection continues where it stopped when you Retry.
        • Names that exist already are asked about: Replace, Keep Both or Skip, once or for all.

        Commands and monitoring
        • Host ▸ Run Command… runs one command and shows its output; Run in Terminal for sudo and editors.
        • Window ▸ Snippets keeps commands you run often, to run on any host.
        • The Monitor tab shows CPU, memory, disks and processes on Linux servers; Kill asks first.
        • The Tunnels tab opens ports through the connection: a database behind the server, an app on your Mac.
        • View ▸ Show Command Log shows every command AirSCP ran, as a line you can copy and run yourself.

        Windows
        • File ▸ New Remote Desktop… saves a Windows computer; double-click it to open its desktop.
        • Drop files on the desktop: Windows sees them in \\\\tsclient\\AirSCP. Copy files in Windows: paste them on the Mac.
        • ⌘C and ⌘V work in Windows as on the Mac; Ctrl+Alt+Del and Full Screen are in the bar.
        • Company servers with self-signed certificates: the desktop's Advanced ▸ Server certificate can trust them \
        automatically, or check them with your company's certificate authority (best).

        Agents
        • Settings ▸ Allow AI agents to control AirSCP lets Claude Code or another MCP client drive AirSCP as you would.

        More help
        • Help ▸ AirSCP Help shows every task step by step, with pictures; a sheet's “?” button opens its page.
        • A connection fails and the message isn't enough? Settings ▸ Debug logging writes each step to a file \
        (Help ▸ Show Debug Log in Finder), for a problem report.
        """
}

/// A plain window with a text to read (AirSCP Tips, the agent guide).
@MainActor
func textWindow(title: String, text: String) -> NSWindow { textWindow(title: title, text: AttributedString(text)) }

@MainActor
func textWindow(title: String, text: AttributedString) -> NSWindow {
    let controller = NSHostingController(rootView: ScrollView {
        Text(text)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
    }
    .frame(minWidth: 420, minHeight: 300))
    let window = NSWindow(contentViewController: controller)
    window.title = title
    window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
    window.isReleasedWhenClosed = false
    window.open(size: NSSize(width: 660, height: 560))
    return window
}

/// A Markdown text (the agent guide) as a person reads it in a window: the hard-wrapped lines of each paragraph and list
/// item joined (the window wraps them to its width), headings in bold, `code` in a fixed-width font.
func readableMarkdown(_ markdown: String) -> AttributedString {
    var blocks: [String] = []
    var joining = false  // the line before continues: a paragraph's or list item's next line joins it
    for line in markdown.components(separatedBy: "\n") {
        let words = line.trimmingCharacters(in: .whitespaces)
        if words.isEmpty {
            blocks.append("")
            joining = false
        } else if line.hasPrefix("#") {
            let heading = words.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
            blocks.append("**" + heading.prefix(1).uppercased() + heading.dropFirst() + "**")
            joining = false
        } else if joining && !line.hasPrefix("- ") {
            blocks[blocks.count - 1] += " " + words
        } else {
            blocks.append(line.hasPrefix("- ") ? "• " + words.dropFirst(2) : words)
            joining = true
        }
    }
    let text = blocks.joined(separator: "\n")
    return (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
}
