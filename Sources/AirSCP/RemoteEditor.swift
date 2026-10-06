import AirSCPCore
import AppKit

/// The built-in plain-text editor for a server file (UTF-8, up to `limit`): a window of its own, so the workspace
/// stays usable. Save (⌘S) writes the text back over sftp (`Session.writeText`: safely, keeping the file's permissions),
/// byte for byte as typed (a byte order mark stays; in a file with Windows line ends, new lines get them too); closing
/// with unsaved changes asks first.
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
    private var saving = false
    private var closeAfterSaving = false

    init(session: Session, path: String, text: String, isLink: Bool = false) {
        self.session = session
        self.path = path
        self.isLink = isLink
        crlf = text.contains("\r\n")
        savedText = text
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
        guard !saving else { return }
        saving = true
        status.stringValue = "Saving…"
        let text = textView.string
        let written = crlf ? text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n") : text
        Task {
            do {
                try await session.writeText(written, to: path, isLink: isLink)
                savedText = text
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
        onClose?()
    }
}
