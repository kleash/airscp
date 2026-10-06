import AirSCPCore
import AppKit
import SwiftUI

/// Asks an ssh prompt (relayed by the askpass helper) in an alert sheet on `window`: Trust or Cancel for a new host
/// key, otherwise a secure field, with "Remember in Keychain" when `canRemember` (ticked when `remember`: the same
/// question asked again keeps the choice). `host` is the saved host it is for (the main window is shared by all hosts);
/// `title` replaces the alert's own. `reply` gets the answer (nil for Cancel) and whether the user answered: false when
/// the app ended the sheet because ssh stopped waiting.
@MainActor @discardableResult
func showPrompt(_ kind: PromptKind, text: String, host: SSHHost?, canRemember: Bool, on window: NSWindow,
                title: String? = nil, retry: Bool = false, remember ticked: Bool = false,
                reply: @escaping (_ answer: PromptAnswer?, _ byUser: Bool) -> Void) -> NSAlert {
    let alert = NSAlert()
    let asked = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 22))
    let remember = NSButton(checkboxWithTitle: "Remember in Keychain", target: nil, action: nil)
    field.setAccessibilityIdentifier("prompt.answer")
    field.toolTip = "Type the answer: it goes to ssh only, never into a command line"
    remember.setAccessibilityIdentifier("prompt.remember")
    remember.state = ticked ? .on : .off
    remember.toolTip = "Save it in your Keychain so the next connect doesn't ask (off by default)"
    var isHostKey = false
    switch kind {
    case .hostKey(let server, let fingerprint):
        isHostKey = true
        alert.messageText = "Trust “\(server.isEmpty ? host?.displayName ?? "the server" : server)”?"
        alert.informativeText = "AirSCP hasn't connected to this server before. If this key fingerprint is the one the "
            + "server's administrator gave you, trust it: ssh then remembers the key (in known_hosts) and warns if it "
            + "ever changes."
        alert.accessoryView = fingerprintView(keyType(in: asked), fingerprint.isEmpty ? asked : fingerprint)
        alert.addButton(withTitle: "Trust").toolTip = "Remember this key and connect"
    case .password(let user, let server):
        let name = host?.displayName ?? [user, server].compactMap { $0 }.joined(separator: "@")
        alert.messageText = name.isEmpty ? "Password" : "Password for \(name)"
        alert.informativeText = asked
        field.placeholderString = "Password"
    case .passphrase:
        alert.messageText = host.map { "Passphrase to connect to “\($0.displayName)”" } ?? "Passphrase"
        alert.informativeText = asked
        field.placeholderString = "Passphrase"
    case .other:
        alert.messageText = host.map { "\($0.displayName) asks" } ?? "ssh asks"
        alert.informativeText = asked
    }
    if let title { alert.messageText = title }
    if retry {  // the same ssh asks again: say so, or the question looks as if nothing happened
        let what = kind == .passphrase ? "passphrase" : kind == .other ? "answer" : "password"
        alert.informativeText = "That \(what) wasn't accepted. Try again." + (asked.isEmpty ? "" : "\n" + asked)
    }
    if !isHostKey {
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: canRemember ? 50 : 22))
        field.frame.origin.y = canRemember ? 28 : 0
        accessory.addSubview(field)
        if canRemember {
            remember.frame = NSRect(x: 0, y: 0, width: 300, height: 20)
            accessory.addSubview(remember)
        }
        alert.accessoryView = accessory
        alert.addButton(withTitle: "OK").toolTip = "Send the answer to ssh"
        alert.window.initialFirstResponder = field
    }
    alert.addButton(withTitle: "Cancel").toolTip = isHostKey ? "Don't connect" : "Don't answer: connecting stops"
    if isHostKey { alert.addHelp(.trustServer) }
    alert.beginSheetModal(for: window) { response in
        switch response {
        case .alertFirstButtonReturn:
            reply(isHostKey ? .trust : PromptAnswer(field.stringValue, remember: canRemember && remember.state == .on), true)
        case .alertSecondButtonReturn:
            reply(nil, true)
        default:
            reply(nil, false)
        }
    }
    return alert
}

/// "ED25519" from ssh's "ED25519 key fingerprint is SHA256:…".
private func keyType(in prompt: String) -> String? {
    prompt.components(separatedBy: "\n").first { $0.contains(" key fingerprint is ") }?
        .components(separatedBy: " key fingerprint is ").first
}

private func fingerprintView(_ type: String?, _ fingerprint: String) -> NSView {
    let label = NSTextField(wrappingLabelWithString: (type.map { "\($0) key fingerprint:\n" } ?? "") + fingerprint)
    label.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
    label.isSelectable = true
    label.preferredMaxLayoutWidth = 340
    label.frame.size = label.fittingSize
    return label
}

// MARK: Errors

/// An alert for `error`: what failed (`title`), the friendly message, and the raw tool output under "Details".
@MainActor
func errorAlert(_ error: Error, title: String?) -> NSAlert {
    let error = error as? AirSCPError ?? AirSCPError(.other, error.localizedDescription)
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title ?? error.message
    alert.informativeText = title == nil ? "" : error.message
    if !error.details.isEmpty && error.details != error.message {
        alert.accessoryView = AlertDetails(error.details, alert: alert)
    }
    return alert
}

extension NSAlert {
    /// The OK button of an alert that only says something.
    func addOK() {
        addButton(withTitle: "OK").toolTip = "Close this message"
    }
}

/// Shows `error` (see `errorAlert`): a sheet on `window`, or app-modal without one.
@MainActor
func showError(_ error: Error, title: String? = nil, on window: NSWindow?) {
    let alert = errorAlert(error, title: title)
    alert.addOK()
    log.error("\(alert.messageText, privacy: .public) \(alert.informativeText, privacy: .public)")
    if let window {
        alert.beginSheetModal(for: window)
    } else {
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}

/// The "Details" disclosure of an error alert: the command's raw output, hidden until opened.
final class AlertDetails: NSView {
    private static let width: CGFloat = 360
    private static let textHeight: CGFloat = 150
    private weak var alert: NSAlert?
    let toggle = NSButton()
    private let text = NSTextView.scrollableTextView()

    init(_ details: String, alert: NSAlert) {
        self.alert = alert
        super.init(frame: NSRect(x: 0, y: 0, width: Self.width, height: 20))
        toggle.setButtonType(.pushOnPushOff)
        toggle.bezelStyle = .disclosure
        toggle.title = ""
        toggle.target = self
        toggle.action = #selector(toggled)
        toggle.toolTip = "Show the command's own output"
        toggle.frame = NSRect(x: 0, y: 2, width: 16, height: 16)
        let label = NSButton(title: "Details", target: self, action: #selector(labelClicked))
        label.toolTip = toggle.toolTip
        label.isBordered = false
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.sizeToFit()
        label.frame.origin = NSPoint(x: 18, y: 2)
        let textView = text.documentView as? NSTextView
        textView?.string = details
        textView?.isEditable = false
        textView?.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        text.borderType = .bezelBorder
        text.frame = NSRect(x: 0, y: 26, width: Self.width, height: Self.textHeight)
        text.isHidden = true
        [toggle, label, text].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }

    var isExpanded: Bool { !text.isHidden }

    @objc private func labelClicked() {
        toggle.state = toggle.state == .on ? .off : .on
        toggled()
    }

    @objc private func toggled() {
        text.isHidden = toggle.state == .off
        setFrameSize(NSSize(width: Self.width, height: text.isHidden ? 20 : 26 + Self.textHeight))
        alert?.layout()
    }
}

// MARK: Small dialogs

/// Asks before doing something: a sheet on `window` (app-modal without one); `action` runs if `button` is chosen.
@MainActor
func confirm(_ message: String, info: String, button: String, destructive: Bool = false, on window: NSWindow?,
             action: @escaping () -> Void) {
    let alert = NSAlert()
    alert.messageText = message
    alert.informativeText = info
    let chosen = alert.addButton(withTitle: button)
    chosen.hasDestructiveAction = destructive
    chosen.toolTip = info.isEmpty ? message : info
    alert.addButton(withTitle: "Cancel").toolTip = "Don't do it"
    if let window {
        alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { action() } }
    } else if alert.runModal() == .alertFirstButtonReturn {
        action()
    }
}

/// Asks for a short text (a group name) in a sheet; `done` gets it, trimmed, unless empty or cancelled.
@MainActor
func askText(_ message: String, initial: String = "", button: String, on window: NSWindow, done: @escaping (String) -> Void) {
    let alert = NSAlert()
    alert.messageText = message
    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
    field.stringValue = initial
    field.setAccessibilityIdentifier("prompt.name")
    field.toolTip = "Type the name"
    alert.accessoryView = field
    alert.addButton(withTitle: button).toolTip = message
    alert.addButton(withTitle: "Cancel").toolTip = "Close without doing anything"
    alert.window.initialFirstResponder = field
    alert.beginSheetModal(for: window) { response in
        let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if response == .alertFirstButtonReturn && !text.isEmpty { done(text) }
    }
}

/// Shows a SwiftUI view as a sheet on `window`. The view is made with a function that closes the sheet.
@MainActor
func presentSheet<V: View>(on window: NSWindow, _ makeView: (_ close: @escaping () -> Void) -> V) {
    let closer = SheetCloser()
    let controller = NSHostingController(rootView: makeView { closer.close() })
    let sheet = NSWindow(contentViewController: controller)
    sheet.isReleasedWhenClosed = false  // held by ARC: a close (Escape, ⌘W) must not release it once more
    closer.sheet = sheet
    sheet.setContentSize(controller.view.fittingSize)  // the window starts at 1×32 until SwiftUI's first layout
    window.beginSheet(sheet)
}

@MainActor
private final class SheetCloser {
    weak var sheet: NSWindow?

    func close() {
        if let sheet { sheet.sheetParent?.endSheet(sheet) }
    }
}

// MARK: Open and Save panels

/// Open and Save panels, shown as sheets (never app-modally: a modal panel would hold up everything else, agent
/// control too). An agent can't drive a panel (another process draws it): a request that brings `file` or `files`
/// has them chosen instead, as if picked in the panel (`agentChoice`, set for that one request).
@MainActor
enum Panels {
    /// What the agent's current request chose; taken by the first panel its action opens.
    static var agentChoice: [URL]?
    /// Why the agent's choice wasn't used (it doesn't fit the panel).
    static var agentProblem: String?
    /// The folder the panel that took the agent's choice would have opened in (agent control's reply says it).
    static var agentPanelFolder: String?

    /// Shows `panel` on `window` (on its own without one) and calls `chosen` with what was picked, unless cancelled.
    static func run(_ panel: NSSavePanel, on window: NSWindow?, chosen: @escaping ([URL]) -> Void) {
        if let urls = agentChoice {
            agentChoice = nil
            agentPanelFolder = panel.directoryURL?.path
            if let problem = problem(urls, panel) { agentProblem = problem } else { chosen(urls) }
            return
        }
        let done: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK else { return }
            chosen((panel as? NSOpenPanel)?.urls ?? panel.url.map { [$0] } ?? [])
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: done) } else { panel.begin(completionHandler: done) }
    }

    /// Why `urls` can't be this panel's answer: an Open panel takes existing items of the kinds it allows (one unless
    /// it allows several), a Save panel one file in an existing folder.
    private static func problem(_ urls: [URL], _ panel: NSSavePanel) -> String? {
        guard !urls.isEmpty else { return "No file was given." }
        guard let open = panel as? NSOpenPanel else {
            guard urls.count == 1 else { return "A Save panel takes one file." }
            return FileList.isLocalFolder(urls[0].deletingLastPathComponent().path) ? nil
                : "The folder of “\(urls[0].path)” doesn't exist on this Mac."
        }
        if urls.count > 1 && !open.allowsMultipleSelection { return "This panel takes one item." }
        for url in urls {
            var folder: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &folder) else {
                return "“\(url.path)” doesn't exist on this Mac."
            }
            if folder.boolValue && !open.canChooseDirectories { return "“\(url.path)” is a folder: this panel takes files." }
            if !folder.boolValue && !open.canChooseFiles { return "“\(url.path)” is a file: this panel takes a folder." }
        }
        return nil
    }
}
