import AirSCPCore
import AppKit
import SwiftUI

/// The RDP entry editor's fields as typed. `validationError` names the first problem; `apply` writes them to an entry.
struct RDPDraft: Equatable {
    enum Display: Hashable { case fit, fixed, fullscreen }

    var label = ""
    var hostname = ""
    /// Empty: 3389, Remote Desktop's port.
    var port = ""
    var username = ""
    var domain = ""
    /// What was typed in the password field: saved in the Keychain on Save (empty: keep what is saved).
    var password = ""
    var viaHostID: UUID?
    var display = Display.fit
    var width = "1920"
    var height = "1080"
    var retinaScale = true
    var clipboard = true
    var cmdAsCtrl = true
    var shareFolder = true
    var sharedFolder = ""
    var certificateCheck = CertificateCheck.ask
    var caFile = ""

    init(_ entry: RDPEntry) {
        label = entry.label
        hostname = entry.hostname
        port = entry.port == 3389 ? "" : String(entry.port)
        username = entry.username
        domain = entry.domain
        viaHostID = entry.viaHostID
        switch entry.display {
        case .fit: display = .fit
        case .fullscreen: display = .fullscreen
        case .fixed(let width, let height):
            display = .fixed
            self.width = String(width)
            self.height = String(height)
        }
        retinaScale = entry.retinaScale
        clipboard = entry.clipboard
        cmdAsCtrl = entry.cmdAsCtrl
        shareFolder = entry.shareFolder
        sharedFolder = entry.sharedFolder
        certificateCheck = entry.certificateCheck
        caFile = entry.caFile
    }

    var validationError: String? {
        let name = hostname.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return "Enter the Windows computer's address to begin." }
        if name.contains(where: \.isWhitespace) { return "The host name can't contain spaces." }
        if name.hasPrefix("-") { return "The host name can't start with “-”." }
        let port = self.port.trimmingCharacters(in: .whitespaces)
        if !port.isEmpty && Int(port).map({ (1...65535).contains($0) }) != true {
            return "The port must be a number from 1 to 65535."
        }
        if display == .fixed {
            for value in [width, height] where Int(value.trimmingCharacters(in: .whitespaces)).map({ (200...8192).contains($0) }) != true {
                return "The width and height must be numbers from 200 to 8192."
            }
        }
        if certificateCheck == .companyCA && caFile.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Choose your company's certificate authority file (Advanced)."
        }
        return nil
    }

    func apply(to entry: inout RDPEntry) {
        entry.label = label.trimmingCharacters(in: .whitespaces)
        entry.hostname = hostname.trimmingCharacters(in: .whitespaces)
        entry.port = Int(port.trimmingCharacters(in: .whitespaces)) ?? 3389
        entry.username = username.trimmingCharacters(in: .whitespaces)
        entry.domain = domain.trimmingCharacters(in: .whitespaces)
        entry.viaHostID = viaHostID
        switch display {
        case .fit: entry.display = .fit
        case .fullscreen: entry.display = .fullscreen
        case .fixed:
            entry.display = .fixed(width: Int(width.trimmingCharacters(in: .whitespaces)) ?? 1920,
                                   height: Int(height.trimmingCharacters(in: .whitespaces)) ?? 1080)
        }
        entry.retinaScale = retinaScale
        entry.clipboard = clipboard
        entry.cmdAsCtrl = cmdAsCtrl
        entry.shareFolder = shareFolder
        entry.sharedFolder = sharedFolder.trimmingCharacters(in: .whitespaces)
        entry.certificateCheck = certificateCheck
        entry.caFile = caFile.trimmingCharacters(in: .whitespaces)
    }
}

/// The RDP entry editor sheet: every setting of a saved Windows server, and Test Connection. MainWindowController
/// presents it with `presentSheet(on:)`; `close` gets the saved entry's id, or nil for Cancel. `sshSession` (the same
/// function `RDPWorkspaceController` gets) lets Test Connection go through the entry's SSH host.
struct RDPEditorView: View {
    @ObservedObject var model: AppModel
    let entry: RDPEntry
    let isNew: Bool
    let sshSession: ((UUID) async throws -> Session)?
    /// The editor's own sheet: Test Connection's certificate question goes there (AirSCP may not be the active app).
    let window: () -> NSWindow?
    let close: (UUID?) -> Void
    @State private var draft: RDPDraft
    @State private var hasSavedPassword = false
    @State private var testing = false
    @State private var testResult: (ok: Bool, text: String)?
    @State private var advanced: Bool

    init(model: AppModel, entry: RDPEntry, isNew: Bool, sshSession: ((UUID) async throws -> Session)?,
         window: @escaping () -> NSWindow? = { nil }, close: @escaping (UUID?) -> Void) {
        self.model = model
        self.entry = entry
        self.isNew = isNew
        self.sshSession = sshSession
        self.window = window
        self.close = close
        _draft = State(initialValue: RDPDraft(entry))
        let defaults = RDPEntry()
        _advanced = State(initialValue: entry.port != defaults.port || !entry.domain.isEmpty || entry.display != defaults.display
                          || entry.retinaScale != defaults.retinaScale || entry.cmdAsCtrl != defaults.cmdAsCtrl
                          || entry.certificateCheck != defaults.certificateCheck)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isNew ? "New Remote Desktop" : "Edit “\(entry.displayName)”").font(.headline)
                Text("A Windows computer, shown in AirSCP with the built-in Remote Desktop client. Only the address is required.")
                    .font(.caption).foregroundColor(.secondary)
            }
            Form {
                TextField("Name:", text: $draft.label, prompt: Text("Optional")).accessibilityIdentifier("rdpEditor.name")
                    .help("A name for the sidebar; the address is used when empty")
                TextField("Address:", text: $draft.hostname, prompt: Text("Host name or IP address")).accessibilityIdentifier("rdpEditor.hostname")
                    .help("The Windows computer's host name or IP address")
                TextField("User name:", text: $draft.username, prompt: Text("Asked when connecting")).accessibilityIdentifier("rdpEditor.username")
                    .help("The Windows account; asked when connecting if empty (DOMAIN\\user works too)")
                SecureField("Password:", text: $draft.password,
                            prompt: Text(hasSavedPassword ? "Saved in Keychain" : "Asked when connecting"))
                    .accessibilityIdentifier("rdpEditor.password")
                    .help("Saved in your Keychain; leave it empty to be asked when connecting")
                if hasSavedPassword {
                    Button("Forget Saved Password") {
                        Keychain.setPassword(nil, forKey: entry.keychainKey)
                        hasSavedPassword = false
                    }
                    .help("Remove the password from the Keychain; AirSCP asks for it at the next connect")
                }
                Picker("Connect through:", selection: $draft.viaHostID) {
                    Text("None (connect directly)").tag(UUID?.none)
                    ForEach(model.data.hosts.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) {
                        Text($0.displayName).tag(Optional($0.id))
                    }
                }
                .accessibilityIdentifier("rdpEditor.via")
                .help("Reach the desktop through one of your SSH hosts when it isn't reachable directly")
                caption("Optional. For a Windows machine behind a server you can reach over SSH: AirSCP opens a tunnel "
                        + "through that host first.")
                Toggle("Share the clipboard (text and files)", isOn: $draft.clipboard).accessibilityIdentifier("rdpEditor.clipboard")
                    .help("On by default: copy and paste text and files between the Mac and Windows")
                Toggle("Share a Mac folder with Windows", isOn: $draft.shareFolder).accessibilityIdentifier("rdpEditor.shareFolder")
                    .help("On by default: Windows sees a Mac folder as " + RDPBarView.sharedPath + "; dropped files land there")
                if draft.shareFolder {
                    caption("Windows sees it as \\\\tsclient\\AirSCP. Files you drop on the desktop land there; files "
                            + "copied in Windows come back to the Mac.")
                    LabeledContent("Folder:") {
                        HStack {
                            TextField("Folder", text: $draft.sharedFolder, prompt: Text(defaultSharedFolder().path))
                                .labelsHidden()
                                .accessibilityIdentifier("rdpEditor.folder")
                                .help("The Mac folder to share; ~/Downloads/AirSCP RDP when empty")
                            Button("Choose…", action: chooseFolder)
                                .help("Choose the Mac folder Windows sees as " + RDPBarView.sharedPath)
                        }
                    }
                }
                AdvancedToggle(shown: $advanced, id: "rdpEditor.advanced",
                               help: "Rarely needed: the port, a Windows domain, the desktop's size, what ⌘ does and how the "
                                + "server's certificate is checked")
                if advanced { advancedFields }
            }
            .scrollingOnShortScreens()
            HStack(spacing: 8) {
                Button("Test Connection", action: test).disabled(testing || draft.validationError != nil)
                    .help("Log in and out again with these settings, without saving (needs a user name and password)")
                if testing { ProgressView().controlSize(.small) }
                if let testResult {
                    Text(testResult.text).font(.caption).foregroundColor(testResult.ok ? .green : .red).lineLimit(2)
                }
            }
            HStack {
                HelpButton(.remoteDesktop)
                Text(draft.validationError ?? "").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Cancel") { close(nil) }.keyboardShortcut(.cancelAction).help("Close without saving")
                Button(isNew ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .primaryTint(.purple)
                    .disabled(draft.validationError != nil)
                    .help(isNew ? "Save this desktop in the sidebar" : "Save the changes; they apply at the next connect")
            }
        }
        .padding(20)
        .frame(width: 580)
        .onAppear {
            // Reading the Keychain may ask the user once per AirSCP build.
            hasSavedPassword = !isNew && Keychain.password(forKey: entry.keychainKey) != nil
        }
    }

    /// Under Advanced: the port, the domain, the desktop's size and ⌘ as Ctrl.
    @ViewBuilder private var advancedFields: some View {
        TextField("Port:", text: $draft.port, prompt: Text("3389")).accessibilityIdentifier("rdpEditor.port")
            .help("Remote Desktop's port; 3389 unless Windows was set to another")
        TextField("Domain:", text: $draft.domain, prompt: Text("Optional")).accessibilityIdentifier("rdpEditor.domain")
            .help("Only for accounts in a Windows domain; leave it empty for a local account")
        Picker("Display:", selection: $draft.display) {
            Text("Fit the window").tag(RDPDraft.Display.fit)
            Text("Fixed size").tag(RDPDraft.Display.fixed)
            Text("Full screen").tag(RDPDraft.Display.fullscreen)
        }
        .accessibilityIdentifier("rdpEditor.display")
        .help("The desktop's size: this window (default), a fixed size, or the whole screen")
        if draft.display == .fixed {
            LabeledContent("Size:") {
                HStack {
                    TextField("Width", text: $draft.width).labelsHidden().frame(width: 70).accessibilityIdentifier("rdpEditor.width")
                        .help("The desktop's width in pixels, 200 to 8192")
                    Text("×")
                    TextField("Height", text: $draft.height).labelsHidden().frame(width: 70).accessibilityIdentifier("rdpEditor.height")
                        .help("The desktop's height in pixels, 200 to 8192")
                    Text("pixels").foregroundColor(.secondary)
                }
            }
        } else {
            Toggle("Retina resolution (sharp text)", isOn: $draft.retinaScale).accessibilityIdentifier("rdpEditor.retina")
                .help("On by default: sharp text on Retina Macs; off for slow links or apps that ignore scaling")
            caption("Windows is told to scale to 200 %.")
        }
        Toggle("⌘ acts as Ctrl (⌘C copies in Windows)", isOn: $draft.cmdAsCtrl).accessibilityIdentifier("rdpEditor.cmdAsCtrl")
            .help("On by default so ⌘C, ⌘V and ⌘Z work as on the Mac; off makes ⌘ the Windows key")
        CertificateCheckFields(check: $draft.certificateCheck, caFile: $draft.caFile,
                               ids: ("rdpEditor.certificate", "rdpEditor.caFile", "rdpEditor.chooseCA"), window: window)
    }

    private func caption(_ text: String) -> some View { FormCaption(text) }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "Choose the Mac folder Windows sees as \\\\tsclient\\AirSCP."
        Panels.run(panel, on: window()) { [self] urls in
            if let url = urls.first { draft.sharedFolder = url.path }
        }
    }

    private func save() {
        var saved = entry
        draft.apply(to: &saved)
        if let index = model.data.rdpEntries.firstIndex(where: { $0.id == saved.id }) {
            model.data.rdpEntries[index] = saved
        } else {
            model.data.rdpEntries.append(saved)
        }
        if !draft.password.isEmpty { Keychain.setPassword(draft.password, forKey: saved.keychainKey) }
        close(saved.id)
    }

    /// Logs in and out again with the typed settings (through the SSH host when one is chosen).
    private func test() {
        var tested = entry
        draft.apply(to: &tested)
        let password = draft.password.isEmpty ? (hasSavedPassword ? Keychain.password(forKey: entry.keychainKey) ?? "" : "")
            : draft.password
        guard !password.isEmpty, !tested.username.isEmpty else {
            testResult = (false, "Enter the user name and password to test the login.")
            return
        }
        testing = true
        testResult = nil
        Task {
            var forward: (Session, Tunnel)?
            do {
                var tunnelPort: Int?
                if let hostID = tested.viaHostID {
                    guard let sshSession else { throw AirSCPError(.other, "The SSH host isn't available here.") }
                    let session = try await sshSession(hostID)
                    let tunnel = try await RDPSession.forward(through: session, to: tested.hostname, port: tested.port)
                    forward = (session, tunnel)
                    tunnelPort = tunnel.listenPort
                }
                var options = RDPSession.Options()
                options.checkCertificates(like: tested)
                try await RDPSession.testLogin(
                    RDPSession.Target(host: tested.hostname, port: tested.port, username: tested.username,
                                      domain: tested.domain, password: password, tunnelPort: tunnelPort),
                    options: options,
                    onCertificate: { certificate, reply in
                        // A sheet on the editor, never app-modal (that would hold up everything else, agent control too).
                        guard let sheet = window() else { return reply(.no) }
                        let alert = certificateAlert(certificate, server: tested.displayName, entry: tested)
                        alert.beginSheetModal(for: sheet) { reply(certificateTrust($0, alert)) }
                    })
                testResult = (true, "The server accepted the login.")
            } catch {
                let error = error as? AirSCPError ?? AirSCPError(.other, error.localizedDescription)
                testResult = (false, error.message)
            }
            if let (session, tunnel) = forward { try? await session.stopTunnel(tunnel) }
            testing = false
        }
    }
}
