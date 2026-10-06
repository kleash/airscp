import AirSCPCore
import AppKit
import SwiftUI

/// The proxy editor's fields as typed.
struct ProxyDraft: Equatable {
    var name = ""
    var host = ""
    var port = ""
    var username = ""
    /// What was typed in the password field: saved in the Keychain on Save (empty: keep what is saved).
    var password = ""

    init(_ proxy: Proxy) {
        name = proxy.name
        host = proxy.host
        port = String(proxy.port)
        username = proxy.username
    }

    var validationError: String? {
        let host = self.host.trimmingCharacters(in: .whitespaces)
        if host.isEmpty { return "Enter the proxy's host name or IP address." }
        if host.contains(where: \.isWhitespace) { return "The host name can't contain spaces." }
        if Int(port.trimmingCharacters(in: .whitespaces)).map({ (1...65535).contains($0) }) != true {
            return "The port must be a number from 1 to 65535."
        }
        return nil
    }

    func apply(to proxy: inout Proxy) {
        proxy.name = name.trimmingCharacters(in: .whitespaces)
        proxy.host = host.trimmingCharacters(in: .whitespaces)
        proxy.port = Int(port.trimmingCharacters(in: .whitespaces)) ?? proxy.port
        proxy.username = username.trimmingCharacters(in: .whitespaces)
    }
}

/// The Proxies sheet (the sidebar's Proxies button): the HTTP proxies hosts can connect through, with Add, Edit and
/// Remove. A proxy that hosts use can't be removed.
struct ProxiesView: View {
    private struct Editing: Identifiable {
        let proxy: Proxy
        let isNew: Bool
        var id: UUID { proxy.id }
    }

    @ObservedObject var model: AppModel
    let close: () -> Void
    @State private var selection: UUID?
    @State private var editing: Editing?
    @State private var removing: Proxy?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Proxies").font(.headline)
            Text("Only for networks that reach servers through an HTTP proxy (CONNECT). Choose a proxy in a host's settings "
                 + "under Advanced; a host that connects through another host uses that host's proxy.")
                .font(.callout)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            List(selection: $selection) {
                ForEach(model.data.proxies.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) {
                    proxy in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(proxy.displayName)
                        Text(details(proxy)).font(.caption).foregroundColor(.secondary)
                    }
                    .help("Double-click to edit")
                    .tag(proxy.id)
                }
                if model.data.proxies.isEmpty {
                    Text("No proxies yet. Most networks need none. Add one if your network only reaches servers through an "
                         + "HTTP proxy.")
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(height: 200)
            .contextMenu(forSelectionType: UUID.self) { _ in } primaryAction: { ids in
                if let proxy = model.data.proxy(ids.first) { editing = Editing(proxy: proxy, isNew: false) }
            }
            HStack {
                Button("Add Proxy…") { editing = Editing(proxy: Proxy(), isNew: true) }
                    .help("Save an HTTP proxy to choose in a host's settings")
                Button("Edit…") { if let proxy = selected { editing = Editing(proxy: proxy, isNew: false) } }
                    .disabled(selected == nil)
                    .help(selected == nil ? "Select a proxy first" : "Change the selected proxy")
                Button("Remove…") { removing = selected }
                    .disabled(selected.map { !model.hostsUsing(proxy: $0.id).isEmpty } ?? true)
                    .help(selected.map(usedBy).flatMap { $0.isEmpty ? nil : $0 }
                          ?? (selected == nil ? "Select a proxy first" : "Forget the selected proxy and its saved password"))
                Spacer()
                HelpButton(.proxies)
                Button("Done", action: close).keyboardShortcut(.defaultAction).primaryTint(.orange).help("Close")
            }
        }
        .padding(20)
        .frame(width: 520)
        .onExitCommand(perform: close)  // Escape, as in the other sheets (Return is Done)
        .sheet(item: $editing) { editing in
            ProxyEditorView(model: model, proxy: editing.proxy, isNew: editing.isNew) { saved in
                self.editing = nil
                if let saved { selection = saved }
            }
        }
        .alert("Remove “\(removing?.displayName ?? "")”?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                if let removing { model.deleteProxy(removing.id) }
                selection = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its saved password is removed from the Keychain too.")
        }
    }

    private var selected: Proxy? { model.data.proxy(selection) }

    private func details(_ proxy: Proxy) -> String {
        let users = model.hostsUsing(proxy: proxy.id).count
        return "\(proxy.host):\(proxy.port)" + (proxy.username.isEmpty ? "" : " as \(proxy.username)")
            + (users == 0 ? "" : users == 1 ? " · used by 1 host" : " · used by \(users) hosts")
    }

    private func usedBy(_ proxy: Proxy) -> String {
        let names = model.hostsUsing(proxy: proxy.id).map(\.displayName)
        return names.isEmpty ? "" : "Used by \(names.joined(separator: ", ")): choose another proxy for them first."
    }
}

/// Adds or edits a proxy. `close` gets the saved proxy's id, or nil for Cancel.
struct ProxyEditorView: View {
    @ObservedObject var model: AppModel
    let proxy: Proxy
    let isNew: Bool
    let close: (UUID?) -> Void
    @State private var draft: ProxyDraft
    @State private var hasSavedPassword = false

    init(model: AppModel, proxy: Proxy, isNew: Bool, close: @escaping (UUID?) -> Void) {
        self.model = model
        self.proxy = proxy
        self.isNew = isNew
        self.close = close
        _draft = State(initialValue: ProxyDraft(proxy))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(isNew ? "New Proxy" : "Edit “\(proxy.displayName)”").font(.headline)
                Text("An HTTP proxy that accepts CONNECT. Ask your network administrator for its address, port and login.")
                    .font(.caption).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Form {
                TextField("Name:", text: $draft.name, prompt: Text("Optional")).accessibilityIdentifier("proxyEditor.name")
                    .help("A name for the list; host:port when empty")
                TextField("Address:", text: $draft.host, prompt: Text("proxy.example.com")).accessibilityIdentifier("proxyEditor.host")
                    .help("The proxy's host name or IP address")
                TextField("Port:", text: $draft.port, prompt: Text("8080")).accessibilityIdentifier("proxyEditor.port")
                    .help("The proxy's port, often 8080 or 3128")
                TextField("User name:", text: $draft.username, prompt: Text("None")).accessibilityIdentifier("proxyEditor.username")
                    .help("Only if the proxy asks for a login; leave it empty otherwise")
                Text("Optional. The password field appears when a user name is given.")
                    .font(.caption).foregroundColor(.secondary)
                if !draft.username.trimmingCharacters(in: .whitespaces).isEmpty {
                    SecureField("Password:", text: $draft.password,
                                prompt: Text(hasSavedPassword ? "Saved in Keychain" : "Asked when connecting"))
                        .accessibilityIdentifier("proxyEditor.password")
                        .help("Saved in your Keychain; leave it empty to be asked when connecting")
                    if hasSavedPassword {
                        Button("Forget Saved Password") {
                            model.setSavedPassword(proxy.keychainKey, nil)
                            hasSavedPassword = false
                        }
                        .help("Remove the password from the Keychain; AirSCP asks for it at the next connect")
                    }
                }
            }
            HStack {
                HelpButton(.proxies)
                Text(draft.validationError ?? "").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Cancel") { close(nil) }.keyboardShortcut(.cancelAction).help("Close without saving")
                Button(isNew ? "Add" : "Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .primaryTint(.orange)
                    .disabled(draft.validationError != nil)
                    .help(isNew ? "Save this proxy; choose it in a host's settings" : "Save the changes")
            }
        }
        .padding(20)
        .frame(width: 440)
        .onAppear {
            // Reads the Keychain only for proxies with a user name (reading may ask once per AirSCP build).
            hasSavedPassword = !isNew && !proxy.username.isEmpty && model.savedPassword(proxy.keychainKey) != nil
        }
    }

    private func save() {
        var saved = proxy
        draft.apply(to: &saved)
        model.save(saved)
        if !saved.username.isEmpty && !draft.password.isEmpty { model.setSavedPassword(saved.keychainKey, draft.password) }
        close(saved.id)
    }
}

extension MainWindowController {
    /// `AskpassServer.proxyHandler`: the proxy and its password for the proxy-connect helper. A proxy without a user
    /// name needs none; a saved password comes from the Keychain (only for a helper AirSCP's own ssh started:
    /// `fromAirSCP`); otherwise, when `mayAsk` (not during a silent automatic reconnect), a prompt on the main window
    /// asks for it, with Remember. nil cancels. A proxy this Mac doesn't have (hosts imported from another Mac come
    /// without their proxies) is explained, since ssh only sees a cancel.
    func answerProxy(_ id: UUID, mayAsk: Bool, fromAirSCP: Bool = true,
                     reply: @escaping ((proxy: Proxy, password: String)?) -> Void) {
        guard let proxy = model.data.proxy(id) else {
            reply(nil)
            if mayAsk {
                showError(AirSCPError(.other, "A host uses a proxy that isn't saved in AirSCP on this Mac (hosts imported "
                                      + "from another Mac come without their proxies). Edit the host and choose a proxy."),
                          title: "Can't connect through the proxy", on: window)
            }
            return
        }
        if proxy.username.isEmpty { return reply((proxy, "")) }
        if fromAirSCP, let saved = model.savedPassword(proxy.keychainKey) { return reply((proxy, saved)) }
        guard mayAsk, let window else { return reply(nil) }
        showWindow(nil)
        if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        let model = self.model
        // On a sheet the window shows (the host editor testing a connection), where it is seen: behind it, it would
        // wait until that sheet closes. Behind another question (an alert), it queues on the window.
        let shown = window.attachedSheet.flatMap { $0 is NSPanel ? nil : $0 } ?? window
        showPrompt(.password(user: proxy.username, host: proxy.host),
                   text: "The proxy \(proxy.host):\(proxy.port) asks for the password of “\(proxy.username)”.",
                   host: nil, canRemember: true, on: shown, title: "Proxy “\(proxy.displayName)” needs a password") {
            answer, _ in
            guard let answer else { return reply(nil) }
            if answer.remember { model.setSavedPassword(proxy.keychainKey, answer.text) }
            reply((proxy, answer.text))
        }
    }
}
