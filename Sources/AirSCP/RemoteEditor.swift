import AirSCPCore
import AppKit

/// The built-in plain-text editor for a server file (UTF-8, up to `limit`): a window of its own, so the workspace
/// stays usable. Save (⌘S) writes the text back over sftp (`Session.writeText`: safely, keeping the file's permissions),
/// byte for byte as typed (a byte order mark stays; in a file with Windows line ends, new lines get them too); closing
/// with unsaved changes asks first. Save first reads the file again: when someone saved it since this editor read or
/// wrote it, it asks before overwriting their changes (and can show the server's version beside the editor).
@MainActor
final class RemoteEditor: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
    static let limit = 4 << 20

    /// The host's Session (replaced by the workspace when Connect makes a new one).
    var session: Session
    let path: String
    /// A symbolic link: saved through it (`Session.writeText`).
    let isLink: Bool
    /// The file had Windows line ends: lines typed (Return gives "\n") are saved with them too.
    private let crlf: Bool
    /// After a save (the pane lists the folder again).
    var onSaved: (() -> Void)?
    var onClose: (() -> Void)?

    private let textView: NSTextView
    private let status = NSTextField(labelWithString: "")
    private var savedText: String
    /// The file as the server had it when this editor last read or wrote it (or showed its version since): Save checks
    /// that it still has it.
    private var serverText: String
    /// The server's version, shown beside the editor after a save found it changed.
    private var serverWindow: NSWindow?
    private var saving = false
    private var closeAfterSaving = false

    init(session: Session, path: String, text: String, isLink: Bool = false) {
        self.session = session
        self.path = path
        self.isLink = isLink
        crlf = text.contains("\r\n")
        savedText = text
        serverText = text
        let scroll = NSTextView.scrollableTextView()
        textView = scroll.documentView as! NSTextView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 400, height: 240)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.title = RemotePath.name(path) + " — " + session.host.displayName
        window.subtitle = path
        super.init(window: window)
        window.delegate = self

        textView.string = text
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = self
        textView.setAccessibilityIdentifier("editor.text")

        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.stringValue = "\(text.count.formatted()) characters, UTF-8"
        let revert = NSButton(title: "Revert", target: self, action: #selector(revert(_:)))
        revert.toolTip = "Throw away the changes since the last save"
        status.toolTip = "Size and encoding; the file is written back byte for byte"
        let save = NSButton(title: "Save", target: self, action: #selector(save(_:)))
        save.keyEquivalent = "s"
        save.keyEquivalentModifierMask = .command
        save.toolTip = "Save to the server (⌘S)"
        let bar = NSStackView(views: [status, NSView(), revert, save])
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 8, right: 12)
        let stack = NSStackView(views: [scroll, bar])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 0
        window.contentView = stack
        window.initialFirstResponder = textView
        window.open(size: NSSize(width: 780, height: 560))
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func textDidChange(_ notification: Notification) {
        window?.isDocumentEdited = true
    }

    @objc func save(_ sender: Any?) {
        save(overwriting: false)
    }

    /// `overwriting`: without first checking that the server still has the file as this editor knows it.
    private func save(overwriting: Bool) {
        guard !saving else { return }
        saving = true
        status.stringValue = "Saving…"
        let text = textView.string
        let written = crlf ? text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n") : text
        Task {
            do {
                if !overwriting {
                    let server = try await serverVersion()
                    if server.changed {
                        status.stringValue = "Not saved: changed on the server"
                        saving = false
                        return askAboutChange(theirs: server.text)
                    }
                }
                try await session.writeText(written, to: path, isLink: isLink)
                savedText = text
                serverText = written
                window?.isDocumentEdited = textView.string != text
                status.stringValue = "Saved at " + DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
                onSaved?()
                if closeAfterSaving { close() }
            } catch {
                status.stringValue = "Not saved"
                showError(error, title: "Can't save “\(RemotePath.name(path))”", on: window)
            }
            saving = false
            closeAfterSaving = false
        }
    }

    /// Whether the server's file differs from what this editor last read or wrote, and its text when the editor can
    /// show it. The whole file is compared, byte for byte: its size and a time to the minute (all sftp tells) would
    /// miss a quick change of a few characters. A file that is gone hasn't changed: saving makes it again.
    private func serverVersion() async throws -> (changed: Bool, text: String?) {
        // The editor's limits for opening a file, widened to what its own text needs: what fails them isn't that text.
        let mine = serverText.utf8
        let longest = mine.split(separator: 0x0A, omittingEmptySubsequences: false).lazy.map(\.count).max() ?? 0
        do {
            let text = try await session.readText(path, limit: max(Self.limit, mine.count), lineLimit: max(256 << 10, longest))
            return (!text.utf8.elementsEqual(mine), text)
        } catch let error as AirSCPError where error.kind == .noSuchFile {
            return (false, nil)
        } catch let error as AirSCPError where error.kind == .notText {
            return (true, nil)  // not UTF-8 text now, or too large to show
        }
    }

    /// Someone saved the file since this editor read it: Overwrite, Show Server Version (when it is text), or Cancel.
    private func askAboutChange(theirs: String?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "“\(RemotePath.name(path))” was changed on the server after you opened it"
        alert.informativeText = theirs == nil
            ? "It isn't plain text the editor can show any more. Overwrite replaces it with your text."
            : "Overwrite replaces those changes with your text. Show Server Version opens the server's text in another "
                + "window: copy what you need, then save again to overwrite it."
        let overwrite = alert.addButton(withTitle: "Overwrite")
        overwrite.hasDestructiveAction = true
        overwrite.toolTip = "Save your text over the server's version: the changes made there are lost"
        if theirs != nil {
            let show = alert.addButton(withTitle: "Show Server Version")
            show.toolTip = "Open the server's text in another window, to copy what you need"
        }
        alert.addButton(withTitle: "Cancel").toolTip = "Don't save: keep editing"
        alert.beginSheetModal(for: window) { [self] response in
            if response == .alertFirstButtonReturn { return save(overwriting: true) }
            closeAfterSaving = false
            if response == .alertSecondButtonReturn, let theirs { showServerVersion(theirs) }
        }
    }

    /// The file as the server has it now, read-only in a window beside the editor. Save then overwrites it without
    /// asking again (unless it changes once more).
    private func showServerVersion(_ text: String) {
        serverText = text
        serverWindow?.close()
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.string = text
        view.isEditable = false
        view.font = textView.font
        view.textContainerInset = textView.textContainerInset
        view.setAccessibilityIdentifier("editor.serverText")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.title = RemotePath.name(path) + " on the server — " + session.host.displayName
        window.subtitle = "Read-only: the file as the server has it now"
        window.contentView = scroll
        window.open(size: NSSize(width: 780, height: 560))
        if let editor = self.window?.frame {
            window.setFrameTopLeftPoint(NSPoint(x: editor.minX + 40, y: editor.maxY - 40))
        }
        window.makeKeyAndOrderFront(nil)
        serverWindow = window
    }

    @objc func revert(_ sender: Any?) {
        guard window?.isDocumentEdited == true else { return }
        confirm("Revert to the saved text?", info: "Your changes since the last save are lost.", button: "Revert",
                destructive: true, on: window) { [self] in
            textView.string = savedText
            window?.isDocumentEdited = false
            status.stringValue = "Reverted"
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender.isDocumentEdited, !saving else { return !saving }
        let alert = NSAlert()
        alert.messageText = "Save the changes to “\(RemotePath.name(path))” before closing?"
        alert.informativeText = "If you don't, your changes are lost."
        alert.addButton(withTitle: "Save").toolTip = "Save the changes to the server, then close"
        let discard = alert.addButton(withTitle: "Don't Save")
        discard.hasDestructiveAction = true
        discard.toolTip = "Close and lose the changes"
        alert.addButton(withTitle: "Cancel").toolTip = "Keep editing"
        alert.beginSheetModal(for: sender) { [self] response in
            switch response {
            case .alertFirstButtonReturn:
                closeAfterSaving = true
                save(nil)
            case .alertSecondButtonReturn:
                close()
            default:
                break
            }
        }
        return false
    }

    func windowWillClose(_ notification: Notification) {
        serverWindow?.close()
        onClose?()
    }
}
