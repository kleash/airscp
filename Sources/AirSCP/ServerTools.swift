import AirSCPCore
import AppKit
import SwiftUI

/// Host ▸ Server Info… and Host ▸ Change Password…
extension HostWorkspace {
    /// What AirSCP found the server can do, in words (Server Info's "Can" line).
    var capabilityWords: [String] {
        let capabilities = session.capabilities
        var words = [capabilities.shell ? "runs commands" : "file transfers only"]
        words += capabilities.tools.sorted()
        if capabilities.windows { words.append("Windows") }
        if capabilities.caseInsensitive { words.append("names ignore case") }
        return words
    }

    func showServerInfo() {
        guard let window, session.state == .connected else { return }
        let model = ServerInfoModel(workspace: self, folder: browser.right.dir ?? session.capabilities.home)
        presentSheet(on: window) { close in ServerInfoView(model: model, close: close) }
        model.load()
    }

    /// Runs passwd in the Terminal tab (it asks its own questions there); once it says the password changed, offers to
    /// update the password AirSCP saved for this host. The new password is typed again: AirSCP never reads it back.
    func changePassword() {
        guard session.state == .connected, session.capabilities.shell else { return }
        // The tab's shell may be busy (an editor, a long command): passwd is typed into it, so the user says when. Typed
        // into a busy program it may do harm there: destructive, so an agent's press waits for the person at the Mac too.
        if terminal.session?.running == true {
            showTerminal()
            return confirm("Type passwd into the Terminal tab?", info: "Its shell is open: make sure it waits at a prompt "
                           + "(not in an editor or a running command), then continue.", button: "Run passwd", destructive: true,
                           on: window) { [weak self] in
                self?.runPasswd()
            }
        }
        runPasswd()
    }

    private func runPasswd() {
        showTerminal()
        let hostID = host.id, model = self.model
        Task { [weak self] in
            for _ in 0..<100 where self?.terminal.session?.running != true { try? await Task.sleep(nanoseconds: 100_000_000) }
            guard let terminal = self?.terminal.session, terminal.running else { return }
            // Success messages already on the screen (an earlier passwd) don't count: only new ones.
            func successes() -> Int {
                let text = terminal.screen.text.lowercased()
                return ["updated successfully", "changed by", "password changed", "password updated"]
                    .reduce(0) { $0 + text.components(separatedBy: $1).count - 1 }
            }
            let before = successes()
            terminal.send("passwd\n")
            guard model.host(hostID)?.auth == .password, model.savedPassword(hostID.uuidString) != nil else { return }
            // Up to ten minutes for passwd's own questions; "updated successfully" (Linux), "changed by" (BusyBox),
            // "password changed" (BSDs).
            for _ in 0..<1200 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if successes() > before {
                    self?.offerToUpdateSavedPassword()
                    return
                }
                if !terminal.running { return }
            }
        }
    }

    private func offerToUpdateSavedPassword() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Update the password AirSCP saved for “\(host.displayName)”?"
        alert.informativeText = "passwd changed it on the server. Type the new password once more to save it in your "
            + "Keychain, or the next connect asks for it."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.placeholderString = "New password"
        field.setAccessibilityIdentifier("prompt.newPassword")
        field.toolTip = "The new password: it goes to your Keychain only"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save").toolTip = "Save the new password in your Keychain"
        alert.addButton(withTitle: "Forget It").toolTip = "Remove the old saved password: the next connect asks"
        alert.addButton(withTitle: "Not Now").toolTip = "Keep the saved password as it is"
        alert.window.initialFirstResponder = field
        let key = host.id.uuidString, model = self.model
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn where !field.stringValue.isEmpty: model.setSavedPassword(key, field.stringValue)
            case .alertSecondButtonReturn: model.setSavedPassword(key, nil)
            default: break
            }
        }
    }
}

@MainActor
final class ServerInfoModel: ObservableObject {
    weak var workspace: HostWorkspace?
    let folder: String
    @Published private(set) var info: ServerInfo?

    init(workspace: HostWorkspace, folder: String) {
        self.workspace = workspace
        self.folder = folder
    }

    func load() {
        guard let session = workspace?.session else { return }
        let folder = self.folder
        Task { info = await session.serverInfo(folder: folder) }
    }

    var text: String {
        guard let info, let workspace else { return "" }
        return info.text(host: workspace.host.displayName, capabilities: workspace.capabilityWords)
    }
}

struct ServerInfoView: View {
    @ObservedObject var model: ServerInfoModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Server Info: \(model.workspace?.host.displayName ?? "")").font(.headline)
            if let info = model.info, let workspace = model.workspace {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 6) {
                    row("Server key", info.keys.isEmpty ? "Not in known_hosts (its key isn't checked)" : info.keys.joined(separator: "\n"),
                        help: "The server's key as this Mac trusts it (known_hosts), with its SHA-256 fingerprint")
                    let unknown = DebugLog.enabled ? "Not seen yet: connect again" : "Turn on Debug Logging (Help menu), then connect again"
                    row("Software", info.version ?? unknown, help: "What the server says it runs")
                    row("Key exchange", info.kex ?? unknown, help: "How the connection's keys were agreed")
                    row("Cipher", info.cipher.map { $0 + (info.mac.map { ", MAC \($0)" } ?? "") } ?? unknown,
                        help: "How the connection is encrypted")
                    row("Can", workspace.capabilityWords.joined(separator: ", "), help: "What AirSCP found the server can do")
                    row("Free space", info.free.map { FileList.size($0) + " in “\(RemotePath.name(model.folder))”" } ?? "Unknown",
                        help: "The space left on the disk of the folder shown")
                }
                .textSelection(.enabled)
            } else {
                ProgressView().controlSize(.small)
            }
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.text, forType: .string)
                }
                .disabled(model.info == nil)
                .help("Copy these facts as text, for a support request")
                Button("Done", action: close).keyboardShortcut(.defaultAction).help("Close")
            }
        }
        .padding(20)
        .frame(width: 520)
        .accessibilityIdentifier("serverInfo")
    }

    private func row(_ label: String, _ value: String, help: String) -> some View {
        GridRow {
            Text(label).foregroundColor(.secondary).gridColumnAlignment(.trailing).help(help)
            Text(value).fixedSize(horizontal: false, vertical: true).help(help)
        }
    }
}
