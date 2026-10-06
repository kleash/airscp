import AirSCPCore
import AppKit
import Combine
import SwiftUI

/// A saved RDP entry's desktop in the main window's detail area: a bar with the session's actions and status
/// (Connect, Ctrl+Alt+Del, Full Screen, Upload…, Show Shared Folder, Paste Files to Mac…, Disconnect) above the
/// Windows desktop. MainWindowController makes one when an entry is selected, keeps it while it is connected, and
/// shows its `state` in the sidebar.
///
/// Files: the entry's shared Mac folder is \\tsclient\AirSCP in Windows (Upload… and dropping Finder files copy into
/// it); files copied in Explorer come to the Mac with Paste Files to Mac…, or by themselves (up to 256 MB) when the
/// desktop loses the focus, so ⌘V works in Finder. Text is shared both ways.
@MainActor
final class RDPWorkspaceController: NSViewController {
    let entryID: UUID
    let model: AppModel
    /// A connected Session of a saved SSH host, for an entry that goes through one (`RDPEntry.viaHostID`): the main
    /// window connects that host first if needed (its prompts show in its own workspace) and throws if it can't.
    let sshSession: (UUID) async throws -> Session
    private(set) var state = RDPSession.State.idle
    /// After every change of `state`: the sidebar's status dot, the Connected section, ⌘1…9.
    var onStateChange: ((RDPSession.State) -> Void)?
    /// AirSCP's window, where the desktop's questions go while it isn't the one shown (never an app-modal alert: that
    /// would hold up everything else, agent control too).
    var mainWindow: () -> NSWindow? = { nil }

    let bar = RDPBar()
    let desktop = RDPDesktopView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
    private let idleHint = NSTextField(wrappingLabelWithString: "Connect to show the Windows desktop here. Files you drop on "
                                       + "it land in the shared folder, \\\\tsclient\\AirSCP in Windows.")
    private(set) var session: RDPSession?
    private var tunnel: (session: Session, tunnel: Tunnel)?
    /// The password typed in the login sheet with Remember: saved once the desktop is up.
    private var passwordToRemember: String?
    /// The saved password was refused: ask for it on the next connect.
    private var askForPassword = false
    private var questions: [NSAlert] = []
    private var disconnecting: [CheckedContinuation<Void, Never>] = []
    private var resizeWork: DispatchWorkItem?
    /// The desktop size last asked of Windows (at connect, then by `desktopResized`).
    private var requestedSize: CGSize?
    /// A warning about the Mac's clipboard in the bar (text over 1 MB, paths too long): it goes with the next copy.
    private var clipboardWarning = ""
    private var pasteboardTimer: Timer?
    /// The general pasteboard's change count Windows is up to date with (or that AirSCP wrote itself).
    private var pasteboardChange = NSPasteboard.general.changeCount
    /// Windows' copied files already fetched (or tried) for ⌘V in Finder: their list's serial number.
    private var fetchedSerial: UInt32?
    /// The copy from Windows running now, if any.
    private var currentFetch: UUID?
    /// Eager fetches go into this folder (the previous one is removed).
    private var clipboardFolder: URL?
    /// The connect in progress (a new Connect, Cancel or Disconnect makes an older one stop).
    private var attempt: UUID?
    /// Files Windows was copying into the shared folder when the user chose to disconnect anyway: removed once the
    /// session has ended (cut off, they would look complete: Windows makes them full size first).
    var discardWhenEnded: [String] = []
    /// The bar's shield follows the entry's certificate check as it is edited.
    private var checks: AnyCancellable?

    init(entryID: UUID, model: AppModel, sshSession: @escaping (UUID) async throws -> Session) {
        self.entryID = entryID
        self.model = model
        self.sshSession = sshSession
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var entry: RDPEntry? { model.data.rdpEntries.first { $0.id == entryID } }

    override func loadView() {
        let barView = NSHostingView(rootView: RDPBarView(bar: bar, model: model, actions: RDPBarActions(
            connect: { [weak self] in self?.connect() },
            disconnect: { [weak self] in self?.disconnectFromBar() },
            details: { [weak self] in self?.showDetails() },
            ctrlAltDel: { [weak self] in self?.session?.sendCtrlAltDel() },
            fullScreen: { [weak self] in self?.toggleFullScreen() },
            upload: { [weak self] in self?.chooseUpload() },
            showSharedFolder: { [weak self] in self?.showSharedFolder() },
            pasteFiles: { [weak self] in self?.choosePasteFolder() },
            cancelFetch: { [weak self] in self?.session?.cancelFetch() })))
        barView.translatesAutoresizingMaskIntoConstraints = false
        // The desktop sits in a plain container (no constraints), so leaving full screen puts it back as it was.
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        desktop.frame = container.bounds
        desktop.autoresizingMask = [.width, .height]
        container.addSubview(desktop)
        // Over the empty desktop while it isn't connected: what the area is for.
        idleHint.textColor = .secondaryLabelColor
        idleHint.alignment = .center
        idleHint.preferredMaxLayoutWidth = 380
        idleHint.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(idleHint)
        let root = NSView()
        root.addSubview(barView)
        root.addSubview(container)
        NSLayoutConstraint.activate([
            barView.topAnchor.constraint(equalTo: root.topAnchor),
            barView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            barView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: barView.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            idleHint.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            idleHint.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])
        desktop.onResize = { [weak self] in self?.desktopResized() }
        desktop.onFocus = { [weak self] in self?.desktopFocused($0) }
        desktop.onDrop = { [weak self] in self?.upload($0) }
        desktop.onToggleFullScreen = { [weak self] in self?.toggleFullScreen() }
        view = root
        bar.name = entry?.displayName ?? ""
        let id = entryID
        checks = model.$data.map { $0.rdpEntries.first { $0.id == id }?.certificateCheck == .off }.removeDuplicates()
            .sink { [bar] in bar.checksOff = $0 }
    }

    // MARK: Connecting

    /// Connects (through the entry's SSH host first, if it has one). Does nothing while connecting or connected.
    func connect() {
        guard state != .connecting, state != .connected, let entry else { return }
        bar.name = entry.displayName
        let attempt = UUID()
        self.attempt = attempt
        setState(.connecting)
        Task {
            var forward: (Session, Tunnel)?
            do {
                if let hostID = entry.viaHostID {
                    let ssh = try await sshSession(hostID)
                    forward = (ssh, try await RDPSession.forward(through: ssh, to: entry.hostname, port: entry.port))
                }
                guard self.attempt == attempt else {  // cancelled meanwhile
                    if let (ssh, tunnel) = forward { try? await ssh.stopTunnel(tunnel) }
                    return
                }
                tunnel = forward
                start(entry, tunnelPort: forward?.1.listenPort)
            } catch {
                guard self.attempt == attempt else { return }
                setState(.disconnected(error as? AirSCPError ?? AirSCPError(.other, error.localizedDescription)))
            }
        }
    }

    /// Ends the session (Quit, or the entry was deleted) and returns once it has.
    func disconnect() async {
        guard let session, state == .connected || state == .connecting else {
            if state == .connecting {  // still opening the SSH tunnel: it stops itself
                attempt = nil
                setState(.idle)
            }
            return
        }
        await withCheckedContinuation { continuation in
            disconnecting.append(continuation)
            session.disconnect()
        }
    }

    private func disconnectFromBar() {
        confirmCopies { [weak self] in
            guard let self else { return }
            if let session = self.session, self.state == .connected || self.state == .connecting {
                session.disconnect()
            } else if self.state == .connecting {
                self.attempt = nil
                self.setState(.idle)
            }
        }
    }

    /// The files Windows is copying into the shared folder now.
    func filesBeingCopied() -> [String] {
        guard session != nil, state == .connected, let entry, entry.shareFolder else { return [] }
        let folder = entry.sharedFolder.isEmpty ? defaultSharedFolder().path : entry.sharedFolder
        return RDPSession.filesBeingWritten(in: folder)
    }

    /// Runs `disconnect` at once, or while Windows copies files into the shared folder after asking (those files are
    /// then removed when the session has ended).
    func confirmCopies(then disconnect: @escaping () -> Void) {
        let copying = filesBeingCopied()
        guard !copying.isEmpty, let window = view.window ?? mainWindow() else { return disconnect() }
        let names = copying.prefix(3).map { "“\(($0 as NSString).lastPathComponent)”" }.joined(separator: ", ")
            + (copying.count > 3 ? " and \(copying.count - 3) more" : "")
        confirm("Disconnect while Windows copies \(copying.count == 1 ? "a file" : "\(copying.count) files") into the shared folder?",
                info: "The copy stops, and what was copied of \(names) is removed.", button: "Disconnect", destructive: true,
                on: window) { [weak self] in
            self?.discardWhenEnded = copying
            disconnect()
        }
    }

    private func start(_ entry: RDPEntry, tunnelPort: Int?) {
        let password = askForPassword ? "" : Keychain.password(forKey: entry.keychainKey) ?? ""
        var options = RDPSession.Options()
        let (size, scale) = desktopSize(for: entry)
        requestedSize = size
        options.width = Int(size.width)
        options.height = Int(size.height)
        options.desktopScale = scale.desktop
        options.deviceScale = scale.device
        options.keyboardLayout = RDPSession.keyboardLayout()
        options.clipboard = entry.clipboard
        options.sharedFolder = entry.shareFolder ? sharedFolder(for: entry)?.path : nil
        options.checkCertificates(like: entry)
        let session = RDPSession(target: RDPSession.Target(host: entry.hostname, port: entry.port,
                                                           username: entry.username, domain: entry.domain,
                                                           password: password, tunnelPort: tunnelPort),
                                 options: options)
        session.onStateChange = { [weak self] in self?.sessionChanged($0) }
        session.onResize = { [weak self] width, height in
            self?.desktop.desktopSize = CGSize(width: width, height: height)
            self?.bar.size = "\(width) × \(height)"
        }
        session.onPaint = { [weak self] in self?.desktop.invalidate(desktop: $0) }
        session.onPointer = { [weak self] in self?.desktop.setPointer($0) }
        session.onCertificate = { [weak self] certificate, reply in
            guard let self else { return reply(.no) }
            self.ask(certificateAlert(certificate, server: entry.displayName, entry: entry), reply: reply)
        }
        session.onCredentials = { [weak self] username, reply in
            guard let self else { return reply(nil) }
            self.askCredentials(username: username, entry: entry, reply: reply)
        }
        session.onClipboardText = { [weak self] in self?.windowsCopied(text: $0) }
        session.onClipboardFiles = { [weak self] count, bytes in
            guard let self else { return }
            self.bar.remoteFiles = (count, bytes)
            // A new copy in Windows: the Mac's clipboard no longer holds the last one.
            if self.bar.message.hasSuffix("on the Mac's clipboard.") { self.bar.message = "" }
        }
        session.onSharedFolder = { [weak self] in self?.bar.sharedFolderReady = $0 }
        self.session = session
        desktop.session = session
        desktop.commandAsControl = entry.cmdAsCtrl
        desktop.acceptsDrops = entry.shareFolder
        bar.sharing = entry.shareFolder
        session.connect()
    }

    private func sessionChanged(_ state: RDPSession.State) {
        switch state {
        case .connecting:
            return  // shown already
        case .connected:
            askForPassword = false
            if let password = passwordToRemember, let entry {
                // Only a password NLA has checked: without NLA the server checks it only now, on its own screen, and
                // a wrong one saved would be sent every time.
                if session?.passwordVerified == true {
                    Keychain.setPassword(password, forKey: entry.keychainKey)
                } else {
                    bar.message = "The password wasn't saved: this server checks it only after connecting. Tick Remember "
                        + "again next time if the login worked."
                }
            }
            passwordToRemember = nil
            setState(.connected)
            if session?.certificateNotSaved == true {
                bar.message = "The certificate couldn't be remembered (AirSCP can't write its folder): it is trusted for this "
                    + "connection only."
            }
            // Whatever the Mac's clipboard holds now (copied before connecting) is offered when the desktop gets the focus.
            pasteboardChange = -1
            view.window?.makeFirstResponder(desktop)
            if entry?.display == .fullscreen && !desktop.isInFullScreenMode { toggleFullScreen() }
            desktopResized()  // the view may have changed size while connecting
        case .idle:
            setState(.idle)
            ended()
        case .disconnected(let error):
            if case .authFailed = error.kind { askForPassword = true }
            setState(state)
            ended()
        }
    }

    /// The session ended: nothing of it is left on screen, and the tunnel and questions go.
    private func ended() {
        session?.onStateChange = nil
        session = nil
        desktop.session = nil
        desktop.desktopSize = .zero
        requestedSize = nil
        desktop.acceptsDrops = false
        if desktop.isInFullScreenMode { desktop.exitFullScreenMode(options: nil) }
        pasteboardTimer?.invalidate()
        pasteboardTimer = nil
        passwordToRemember = nil
        bar.reset()
        let open = questions
        questions = []
        open.forEach { $0.window.sheetParent?.endSheet($0.window, returnCode: .cancel) }
        discardWhenEnded.forEach { unlink($0) }
        discardWhenEnded = []
        stopTunnel()
        let waiting = disconnecting
        disconnecting = []
        waiting.forEach { $0.resume() }
    }

    private func setState(_ state: RDPSession.State) {
        switch state {
        case .connecting: log.log("RDP: connecting to \(self.entry?.displayName ?? "?", privacy: .public)")
        case .connected: log.log("RDP: connected to \(self.entry?.displayName ?? "?", privacy: .public)")
        case .idle: if self.state != .idle { log.log("RDP: disconnected") }
        case .disconnected(let error):
            log.error("RDP: disconnected: \(error.message, privacy: .public) \(error.details, privacy: .public)")
        }
        self.state = state
        bar.state = state
        idleHint.isHidden = state == .connected
        onStateChange?(state)
    }

    private func stopTunnel() {
        guard let (session, forward) = tunnel else { return }
        tunnel = nil
        Task { try? await session.stopTunnel(forward) }
    }

    private func showDetails() {
        guard case .disconnected(let error) = state else { return }
        showError(error, title: "Disconnected", on: view.window)
    }

    // MARK: Desktop size

    /// The desktop in pixels, and Windows' scaling for it: the view's size (or the screen's for full screen) at the
    /// Retina resolution, or the entry's fixed size.
    private func desktopSize(for entry: RDPEntry) -> (CGSize, (desktop: Int, device: Int)) {
        switch entry.display {
        case .fixed(let width, let height):
            return (CGSize(width: width, height: height), (100, 100))
        case .fit, .fullscreen:
            let screen = view.window?.screen ?? NSScreen.main
            let points = entry.display == .fullscreen ? screen?.frame.size ?? desktop.bounds.size : desktop.bounds.size
            return fitted(points, retina: entry.retinaScale, scale: screen?.backingScaleFactor ?? 2)
        }
    }

    private func fitted(_ points: CGSize, retina: Bool, scale: CGFloat) -> (CGSize, (desktop: Int, device: Int)) {
        let factor = retina ? max(scale, 1) : 1
        let size = CGSize(width: max(points.width * factor, 640).rounded(), height: max(points.height * factor, 480).rounded())
        return (size, factor >= 2 ? (200, 180) : (100, 100))
    }

    /// The view changed size: a desktop that fits the window follows, half a second after the last change.
    private func desktopResized() {
        guard let entry, session != nil else { return }
        if case .fixed = entry.display { return }
        resizeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let session = self.session, self.state == .connected else { return }
            let scale = self.desktop.window?.backingScaleFactor ?? 2
            let (size, factors) = self.fitted(self.desktop.bounds.size, retina: entry.retinaScale, scale: scale)
            // Compared with the size last asked for, not the one Windows has: it applies a change seconds later, and a
            // size changed back meanwhile (Zoom twice, Full Screen left at once) was never asked for.
            guard size != self.requestedSize ?? self.desktop.desktopSize else { return }
            self.requestedSize = size
            session.resize(width: Int(size.width), height: Int(size.height), desktopScale: factors.desktop,
                           deviceScale: factors.device)
        }
        resizeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func toggleFullScreen() {
        guard state == .connected else { return }
        if desktop.isInFullScreenMode {
            desktop.exitFullScreenMode(options: nil)
            view.window?.makeFirstResponder(desktop)
        } else if let screen = view.window?.screen ?? NSScreen.main {
            desktop.enterFullScreenMode(screen, withOptions: [.fullScreenModeAllScreens: false])
            desktop.window?.makeFirstResponder(desktop)
        }
    }

    // MARK: Questions

    /// Shows `alert` as a sheet on the window (also while another host is shown there: its text names the desktop); see
    /// `certificateTrust`.
    private func ask(_ alert: NSAlert, reply: @escaping (RDPSession.Trust) -> Void) {
        guard let window = view.window ?? mainWindow() else { return reply(.no) }
        questions.append(alert)
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.questions.removeAll { $0 === alert }
            reply(certificateTrust(response, alert))
        }
    }

    private func askCredentials(username: String, entry: RDPEntry, reply: @escaping (RDPSession.Credentials?) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Log in to “\(entry.displayName)”"
        alert.informativeText = askForPassword ? "The user name or password was not accepted. Try again."
            : "Windows asks for the account's password. A domain account: user and domain, or DOMAIN\\user."
        let fields = CredentialFields(username: username.isEmpty ? entry.username : username, domain: entry.domain)
        alert.accessoryView = fields
        alert.addButton(withTitle: "Log In").toolTip = "Send the user name and password to Windows"
        alert.addButton(withTitle: "Cancel").toolTip = "Don't log in: connecting stops"
        alert.window.initialFirstResponder = fields.username.stringValue.isEmpty ? fields.username : fields.password
        let answered: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            self?.questions.removeAll { $0 === alert }
            guard response == .alertFirstButtonReturn else { return reply(nil) }
            if fields.remember.state == .on { self?.passwordToRemember = fields.password.stringValue }
            reply(RDPSession.Credentials(username: fields.username.stringValue, domain: fields.domain.stringValue,
                                         password: fields.password.stringValue))
        }
        guard let window = view.window ?? mainWindow() else { return reply(nil) }  // the workspace may not be on screen
        questions.append(alert)
        alert.beginSheetModal(for: window, completionHandler: answered)
    }

    // MARK: Clipboard

    private func desktopFocused(_ focused: Bool) {
        guard session != nil, state == .connected else { return }
        if focused {
            desktop.focusIn()
            checkPasteboard()
            if pasteboardTimer == nil {
                pasteboardTimer = Timer.scheduledTimer(timeInterval: 0.5, target: self,
                                                       selector: #selector(checkPasteboard), userInfo: nil,
                                                       repeats: true)
            }
        } else {
            pasteboardTimer?.invalidate()
            pasteboardTimer = nil
            fetchForFinder()
        }
    }

    /// The Mac's clipboard changed: Windows may paste it (text, or files and folders; anything else: nothing, rather
    /// than the Mac's last text).
    @objc private func checkPasteboard() {
        let pasteboard = NSPasteboard.general
        guard let session, entry?.clipboard == true, pasteboard.changeCount != pasteboardChange else { return }
        pasteboardChange = pasteboard.changeCount
        clipboardChanged()
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            as? [URL], !urls.isEmpty {
            session.offerFiles(urls) { [weak self] skipped in
                guard skipped > 0, let self else { return }
                self.warnAboutClipboard(skipped == 1 ? "1 item has a path too long for Windows' clipboard: use Upload… for it."
                    : "\(skipped) items have paths too long for Windows' clipboard: use Upload… for them.")
            }
        } else if let text = pasteboard.string(forType: .string) {
            if text.utf8.count > RDPSession.textLimit {
                session.offerNothing()
                warnAboutClipboard("The Mac's clipboard text is over 1 MB: Windows doesn't get it. Save it as a file and use "
                    + "Send Files… instead.")
            } else {
                session.offerText(text)
            }
        } else {
            session.offerNothing()
        }
    }

    func warnAboutClipboard(_ warning: String) {
        bar.message = warning
        clipboardWarning = warning
    }

    /// The Mac copied something new: the last copy's warning no longer applies (it stayed while Windows had the
    /// smaller text copied since).
    func clipboardChanged() {
        if !clipboardWarning.isEmpty && bar.message == clipboardWarning { bar.message = "" }
        clipboardWarning = ""
    }

    private func windowsCopied(text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        pasteboardChange = pasteboard.changeCount
    }

    /// The desktop lost the focus: files Windows copied (up to 256 MB) are fetched now, so ⌘V works in Finder.
    private func fetchForFinder() {
        guard let session, currentFetch == nil, bar.remoteFiles.count > 0, bar.remoteFiles.bytes <= 256 << 20 else { return }
        let (serial, files) = session.remoteFiles()
        guard !files.isEmpty, serial != fetchedSerial else { return }
        fetchedSerial = serial  // one try per copy in Windows
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirSCP RDP Clipboard/\(UUID().uuidString)", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else { return }
        let changeCount = NSPasteboard.general.changeCount
        fetch(into: folder, quiet: true) { [weak self] items in
            // Something copied on the Mac meanwhile is newer: it stays on the clipboard.
            guard let self, NSPasteboard.general.changeCount == changeCount else {
                try? FileManager.default.removeItem(at: folder)
                return
            }
            if let old = self.clipboardFolder { try? FileManager.default.removeItem(at: old) }
            self.clipboardFolder = folder
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.writeObjects(items as [NSURL])
            self.pasteboardChange = pasteboard.changeCount
            self.bar.message = items.count == 1 ? "Windows' copied item is on the Mac's clipboard."
                : "Windows' \(items.count) copied items are on the Mac's clipboard."
        } failed: { [weak self] in
            try? FileManager.default.removeItem(at: folder)
            if let self, self.session != nil {
                self.bar.message = "Couldn't fetch Windows' copied items: use Paste Items to Mac…"
            }
        }
    }

    /// Paste Items to Mac…: into a folder the user picks.
    private func choosePasteFolder() {
        guard let window = view.window, session != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Paste Here"
        panel.message = "Choose where the files copied in Windows go."
        panel.directoryURL = URL(fileURLWithPath: model.data.settings.downloadFolder, isDirectory: true)
        Panels.run(panel, on: window) { [weak self] urls in
            guard let folder = urls.first, let self else { return }
            self.session?.cancelFetch()  // a copy for Finder makes way
            self.fetch(into: folder, quiet: false) { [weak self] items in
                self?.bar.message = "Pasted \(items.count == 1 ? "1 item" : "\(items.count) items") into “\(folder.lastPathComponent)”."
                NSWorkspace.shared.activateFileViewerSelecting(items)
            } failed: {}
        }
    }

    /// Copies Windows' copied files into `folder`, with progress in the bar. `quiet`: failures aren't shown.
    private func fetch(into folder: URL, quiet: Bool, done: @escaping ([URL]) -> Void, failed: @escaping () -> Void) {
        guard let session else { return }
        let id = UUID()
        currentFetch = id
        let total = max(bar.remoteFiles.bytes, 1)
        bar.progress = 0
        session.fetchRemoteFiles(into: folder, progress: { [weak self] bytes in
            guard let self, self.currentFetch == id else { return }
            self.bar.progress = min(Double(bytes) / Double(total), 1)
        }, completion: { [weak self] result in
            guard let self else { return }
            if self.currentFetch == id {
                self.currentFetch = nil
                self.bar.progress = nil
            }
            switch result {
            case .success(let items):
                done(items)
            case .failure(let error):
                failed()
                if !quiet && error.kind != .cancelled && error.kind != .disconnected {
                    showError(error, title: "Can't copy the files from Windows", on: self.view.window)
                }
            }
        })
    }

    // MARK: Shared folder

    /// The entry's shared folder (made if missing), or nil (with an error shown) when it can't be.
    private func sharedFolder(for entry: RDPEntry) -> URL? {
        let folder = entry.sharedFolder.isEmpty ? defaultSharedFolder() : URL(fileURLWithPath: entry.sharedFolder)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder
        } catch {
            showError(error, title: "Can't share the folder “\(folder.path)”", on: view.window)
            return nil
        }
    }

    private func chooseUpload() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Send"
        panel.message = "The files go into the shared folder, \\\\tsclient\\AirSCP in Windows."
        Panels.run(panel, on: window) { [weak self] urls in self?.upload(urls) }
    }

    /// Copies Mac files into the shared folder, where Windows sees them as \\tsclient\AirSCP\<name> (a name Windows
    /// can't show gets "_" where it can't: `RDPSession.windowsName`).
    func upload(_ urls: [URL]) {
        guard let entry, entry.shareFolder, let folder = sharedFolder(for: entry), !urls.isEmpty else { return }
        // The shared folder itself, or a folder holding it, would be copied into itself without end.
        func real(_ url: URL) -> String {
            guard let path = realpath(url.path, nil) else { return url.standardizedFileURL.path }
            defer { free(path) }
            return String(cString: path)
        }
        let shared = real(folder)
        if let looped = urls.first(where: { url in
            let path = real(url)
            return shared == path || shared.hasPrefix(path + "/")
        }) {
            return showError(AirSCPError(.other, "“\(looped.lastPathComponent)” is the shared folder or holds it: it can't be "
                                         + "copied into it."), title: "Can't upload", on: view.window)
        }
        bar.message = "Copying \(urls.count == 1 ? "“\(urls[0].lastPathComponent)”" : "\(urls.count) items") to the shared folder…"
        DispatchQueue.global(qos: .userInitiated).async {
            var copied: [String] = [], failure: Error?, hidden = 0
            for url in urls {
                let existing = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                let name = Names.unique(RDPSession.windowsName(url.lastPathComponent), existing: existing, caseInsensitive: true)
                // Names inside folders that Windows can't show: copied as they are, and counted.
                hidden += (FileManager.default.enumerator(atPath: url.path)?.allObjects as? [String] ?? [])
                    .filter { RDPSession.windowsName(($0 as NSString).lastPathComponent) != ($0 as NSString).lastPathComponent }.count
                do {
                    try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent(name))
                    copied.append(name)
                } catch {
                    failure = error
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.bar.message = copied.isEmpty ? ""
                    : (copied.count == 1 ? "In Windows: \\\\tsclient\\AirSCP\\\(copied[0])"
                       : "In Windows: \\\\tsclient\\AirSCP (\(copied.count) items)")
                        + (hidden == 0 ? "" : " · \(hidden) names inside can't be shown in Windows")
                if let failure { showError(failure, title: "Some files couldn't be copied", on: self.view.window) }
            }
        }
    }

    private func showSharedFolder() {
        guard let entry, let folder = sharedFolder(for: entry) else { return }
        NSWorkspace.shared.open(folder)
    }
}

/// ~/Downloads/AirSCP RDP: the shared folder unless the entry names another.
func defaultSharedFolder() -> URL {
    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        ?? URL(fileURLWithPath: NSHomeDirectory() + "/Downloads")
    return downloads.appendingPathComponent("AirSCP RDP", isDirectory: true)
}

// MARK: Certificate question (also used by Test Connection)

/// The question for a server certificate that isn't trusted yet, or that changed. Buttons: Always Trust, Trust Once,
/// Cancel (a changed certificate has Cancel first, so Return doesn't trust it); see `certificateTrust`. For an `entry`
/// that trusts a company certificate authority, it says the certificate isn't one that authority signed.
@MainActor
func certificateAlert(_ certificate: RDPSession.Certificate, server: String, entry: RDPEntry? = nil) -> NSAlert {
    let alert = NSAlert()
    let changed = certificate.oldFingerprint != nil
    var details = "Issued to: \(certificate.subject)\nIssued by: \(certificate.issuer)\n\nSHA-256 fingerprint:\n"
        + certificate.fingerprint
    if let old = certificate.oldFingerprint { details += "\n\nFingerprint trusted before:\n" + old }
    if changed {
        alert.alertStyle = .critical
        alert.messageText = "The certificate of “\(server)” has changed"
        alert.informativeText = "Someone may be intercepting the connection, or the server got a new certificate. "
            + "Only trust it if you know why it changed."
        alert.addButton(withTitle: "Cancel").toolTip = "Don't connect"
        alert.addButton(withTitle: "Trust Once").toolTip = "Connect this time only; AirSCP asks again next time"
        let always = alert.addButton(withTitle: "Always Trust")
        always.hasDestructiveAction = true
        always.toolTip = "Remember the new certificate for this server"
    } else if let entry, entry.certificateCheck == .companyCA {
        alert.messageText = "Trust the certificate of “\(server)”?"
        alert.informativeText = "This certificate isn't one that your company's certificate authority ("
            + RemotePath.name(entry.caFile) + ") signed"
            + (certificate.nameMismatch ? ", or it is made out to another name than \(certificate.server)" : "")
            + ". Trust it only if the server's administrator gave you this fingerprint."
        alert.addButton(withTitle: "Always Trust").toolTip = "Remember this certificate for this server"
        alert.addButton(withTitle: "Trust Once").toolTip = "Connect this time only; AirSCP asks again next time"
        alert.addButton(withTitle: "Cancel").toolTip = "Don't connect"
    } else {
        alert.messageText = "Trust the certificate of “\(server)”?"
        alert.informativeText = "AirSCP hasn't connected to this server (\(certificate.server)) before"
            + (certificate.nameMismatch ? ", and its certificate is made out to another name" : "")
            + ". If this fingerprint is the one the server's administrator gave you, trust it."
        alert.addButton(withTitle: "Always Trust").toolTip = "Remember this certificate for this server"
        alert.addButton(withTitle: "Trust Once").toolTip = "Connect this time only; AirSCP asks again next time"
        alert.addButton(withTitle: "Cancel").toolTip = "Don't connect"
    }
    let label = NSTextField(wrappingLabelWithString: details)
    label.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    label.isSelectable = true
    label.preferredMaxLayoutWidth = 360
    label.frame.size = label.fittingSize
    alert.accessoryView = label
    alert.addHelp(.certificates)
    return alert
}

/// The answer to `certificateAlert` for the button chosen.
@MainActor
func certificateTrust(_ response: NSApplication.ModalResponse, _ alert: NSAlert) -> RDPSession.Trust {
    let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    guard index >= 0, index < alert.buttons.count else { return .no }
    switch alert.buttons[index].title {
    case "Always Trust": return .always
    case "Trust Once": return .once
    default: return .no
    }
}

/// User name, domain and password fields with Remember, for the login question.
private final class CredentialFields: NSView {
    let username = NSTextField()
    let domain = NSTextField()
    let password = NSSecureTextField()
    let remember = NSButton(checkboxWithTitle: "Remember the password in Keychain", target: nil, action: nil)

    init(username user: String, domain name: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 108))
        username.stringValue = user
        username.placeholderString = "User name"
        domain.stringValue = name
        domain.placeholderString = "Domain (optional)"
        password.placeholderString = "Password"
        username.setAccessibilityIdentifier("rdpLogin.username")
        domain.setAccessibilityIdentifier("rdpLogin.domain")
        password.setAccessibilityIdentifier("rdpLogin.password")
        remember.setAccessibilityIdentifier("rdpLogin.remember")
        username.toolTip = "The Windows account (DOMAIN\\user works too)"
        domain.toolTip = "Only for an account in a Windows domain"
        password.toolTip = "The account's password"
        remember.toolTip = "Save the password in your Keychain once Windows accepts it (off by default)"
        for (index, view) in [remember, password, domain, username].enumerated() {
            view.frame = NSRect(x: 0, y: CGFloat(index) * 28, width: 300, height: index == 0 ? 20 : 22)
            addSubview(view)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

// MARK: The bar

/// What the bar shows.
@MainActor
final class RDPBar: ObservableObject {
    @Published var name = ""
    @Published var state = RDPSession.State.idle
    /// The desktop's size, e.g. "2560 × 1600".
    @Published var size = ""
    @Published var sharing = false
    @Published var sharedFolderReady = false
    /// Files Windows copied: how many, and their total size.
    @Published var remoteFiles: (count: Int, bytes: UInt64) = (0, 0)
    /// Copying files from Windows: how far (0…1); nil when not.
    @Published var progress: Double?
    /// The last thing done (upload, paste).
    @Published var message = ""
    /// The entry's certificate checks are off: an orange shield (PLAN.md U.4).
    @Published var checksOff = false

    func reset() {
        size = ""
        sharing = false
        sharedFolderReady = false
        remoteFiles = (0, 0)
        progress = nil
        message = ""
    }
}

struct RDPBarActions {
    let connect, disconnect, details, ctrlAltDel, fullScreen, upload, showSharedFolder, pasteFiles, cancelFetch: () -> Void
}

/// The strip above the desktop: Connect / Connecting… / Disconnected with Reconnect, or the session's actions and
/// its status (size, shared folder, the last upload or paste).
struct RDPBarView: View {
    @ObservedObject var bar: RDPBar
    /// Whether the debug log is on (the failure's Show Debug Log), and its setting.
    @ObservedObject var model: AppModel
    let actions: RDPBarActions
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 10) {
            if bar.checksOff { ChecksOffShield(ssh: false) }
            switch bar.state {
            case .idle:
                Image(systemName: "display").foregroundColor(.secondary).accessibilityHidden(true)
                Text("Not connected. Connect to show the Windows desktop.")
                Spacer()
                // Remote Desktop's purple in Night Harbor, Paper's black pill.
                Button("Connect", action: actions.connect).buttonStyle(.borderedProminent)
                    .tint(Color(nsColor: scheme == .dark ? .systemPurple : .pill))
                    .help("Open the Windows desktop; the certificate and login are asked first (⌘K)")
            case .connecting:
                ProgressView().controlSize(.small)
                Text("Connecting to \(bar.name)…")
                Spacer()
                Button("Cancel", action: actions.disconnect).help("Stop connecting")
            case .disconnected(let error):
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange).accessibilityHidden(true)
                Text("Disconnected: \(error.message)").lineLimit(2)
                Spacer()
                if !error.details.isEmpty {
                    Button("Details…", action: actions.details).help("Show FreeRDP's own words for this failure")
                }
                DebugLogButton(model: model, retry: actions.connect)
                Button("Reconnect", action: actions.connect).help("Try to connect again (⌘K)")
            case .connected:
                connected
            }
        }
        // As high in every state (two lines of the status included): the desktop below took the 2.5 points of
        // difference from Connecting to connected, and Windows laid out its desktop again after each connect.
        .frame(minHeight: Self.contentHeight)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .bar))
        .overlay(Divider(), alignment: .bottom)
    }

    static let contentHeight: CGFloat = 28

    @ViewBuilder private var connected: some View {
        Group {
            buttons
        }
        .controlSize(.small)
        Spacer()
        Text(status).font(.caption).foregroundColor(.secondary).lineLimit(2).truncationMode(.tail)
            .help("The desktop's size in pixels, and where Windows sees the shared Mac folder")
        Button("Disconnect", action: actions.disconnect).controlSize(.small)
            .help("End the Remote Desktop session (Windows keeps your apps open)")
    }

    @ViewBuilder private var buttons: some View {
        Button(action: actions.ctrlAltDel) { Label("Ctrl+Alt+Del", systemImage: "lock") }
            .help("Send Ctrl+Alt+Del (lock, change password, Task Manager)")
        Button(action: actions.fullScreen) { Label("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") }
            .help("Show the desktop full screen; ⌘⌃F leaves it again")
        if bar.sharing {
            Button(action: actions.upload) { Label("Send Files…", systemImage: "square.and.arrow.up") }
                .help("Copy Mac files into the shared folder; Windows sees them as \\\\tsclient\\AirSCP")
            Button(action: actions.showSharedFolder) { Label("Shared Folder", systemImage: "folder") }
                .help("Show the shared folder in Finder")
        }
        if let progress = bar.progress {
            ProgressView(value: progress).frame(width: 90).help("Copying the files from Windows")
            Button("Stop", action: actions.cancelFetch).help("Stop copying the files from Windows")
        } else if bar.remoteFiles.count > 0 {
            // A String, not a localized key: that wrote 2,021 for 2021 items.
            let title = bar.remoteFiles.count == 1 ? "Paste 1 Item to Mac…" : "Paste \(bar.remoteFiles.count) Items to Mac…"
            Button(action: actions.pasteFiles) {
                Label(title, systemImage: "doc.on.clipboard")
            }
            .accessibilityIdentifier("rdp.pasteItems")
            .help("Copy the files copied in Windows to a folder on this Mac ("
                + ByteCountFormatter.string(fromByteCount: Int64(bar.remoteFiles.bytes), countStyle: .file) + ")")
        }
    }

    private var status: String {
        var parts = [bar.message.isEmpty ? bar.size : bar.message]
        if bar.sharing && bar.message.isEmpty {
            parts.append(bar.sharedFolderReady ? "Shared folder: \\\\tsclient\\AirSCP" : "Shared folder: waiting for Windows")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
