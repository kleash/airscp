import AirSCPCore
import SwiftUI

/// A server's text file, read for the editor, and the editor's state: kept here, not in the editor's view, so that a
/// change of layout (a sheet becomes a column when an iPad turns, Full Window) keeps what is typed.
@Observable final class EditedFile: Identifiable {
    let session: Session
    let entry: RemoteEntry
    /// The file as it was read.
    let original: String
    var text: String
    var savedText: String
    /// The file as the server had it when this editor last read or wrote it (or showed its version since).
    var serverText: String
    /// Size and encoding, then how the last save went.
    var status: String

    init(session: Session, entry: RemoteEntry, text: String) {
        self.session = session
        self.entry = entry
        original = text
        self.text = text
        savedText = text
        serverText = text
        status = "\(text.count.formatted()) characters, UTF-8"
    }
}

/// The editor for a server's text file: Edit (monospaced), Changes (the lines changed since it was opened) and Info.
/// Save writes it back byte for byte only while the server still has the file as this editor last read or wrote it
/// (`Session.saveText`, as the Mac's editor does); else it asks: Overwrite, Show Server Version, or Cancel. It sits in a
/// navigation stack of its container's (a sheet's, a column's, Full Window's); `close` takes it away.
struct EditorView: View {
    @Bindable var file: EditedFile
    let onSaved: () -> Void
    let close: () -> Void
    @State private var tab = Tab.edit
    @State private var saving = false
    @State private var closeAfterSaving = false
    @State private var askingToClose = false
    /// Save found the file changed on the server.
    @State private var conflict: Conflict?
    /// The server's version, shown read-only.
    @State private var theirs: String?
    @State private var failure: AirSCPError?
    @State private var width: CGFloat = 0
    /// The file had Windows line ends: lines typed (Return gives "\n") are saved with them too.
    private let crlf: Bool

    private enum Tab: String, CaseIterable {
        case edit = "Edit", changes = "Changes", info = "Info"
    }

    private struct Conflict {
        /// The server's text, when the editor can show it.
        let theirs: String?
    }

    init(file: EditedFile, onSaved: @escaping () -> Void, close: @escaping () -> Void) {
        self.file = file
        self.onSaved = onSaved
        self.close = close
        crlf = file.original.contains("\r\n")
    }

    private var text: String { file.text }
    private var savedText: String { get { file.savedText } nonmutating set { file.savedText = newValue } }
    private var serverText: String { get { file.serverText } nonmutating set { file.serverText = newValue } }
    private var status: String { get { file.status } nonmutating set { file.status = newValue } }

    private var name: String { file.entry.name }
    private var edited: Bool { text != savedText }

    var body: some View {
        Group {
            switch tab {
            case .edit:
                TextEditor(text: $file.text)
                    .font(.body.monospaced())
                    .autocorrectionDisabled()  // also no smart quotes and dashes
                    .textInputAutocapitalization(.never)
                    .accessibilityIdentifier("editor.text")
            case .changes: changes
            case .info: info
            }
        }
        // Room for both (Full Window on an iPad): the lines changed, beside the text.
        .safeAreaInset(edge: .trailing, spacing: 0) {
            if tab == .edit && width >= 900 {
                HStack(spacing: 0) {
                    Divider()
                    changes.frame(width: width * 0.4)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark") { edited ? askingToClose = true : close() }
                    .help("Close the editor")
                    // On the button that asks: iOS shows it as a popover from there.
                    .confirmationDialog("Save the changes to “\(name)” before closing?", isPresented: $askingToClose,
                                        titleVisibility: .visible) {
                        Button("Save") {
                            closeAfterSaving = true
                            save(overwriting: false)
                        }
                        Button("Don't Save", role: .destructive) { close() }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("If you don't, your changes are lost.")
                    }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { save(overwriting: false) }
                    .disabled(!edited || saving)
                    .help(edited ? "Save to the server" : "Nothing to save: no changes since the last save")
            }
        }
        .safeAreaBar(edge: .top) {
            Picker("View", selection: $tab) {
                ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .help("Edit the text, see the lines changed since you opened it, or the file's details")
        }
        .safeAreaBar(edge: .bottom) {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .interactiveDismissDisabled(edited)
        .alert("“\(name)” was changed on the server after you opened it",
               isPresented: Binding(get: { conflict != nil }, set: { if !$0 { conflict = nil } }), presenting: conflict) { conflict in
            Button("Overwrite", role: .destructive) { save(overwriting: true) }
            if let theirs = conflict.theirs {
                Button("Show Server Version") {
                    serverText = theirs  // Save then overwrites it without asking again (unless it changes once more)
                    self.theirs = theirs
                }
            }
            Button("Cancel", role: .cancel) { closeAfterSaving = false }
        } message: { conflict in
            Text(conflict.theirs == nil ? "It isn't plain text the editor can show any more. Overwrite replaces it with your text."
                 : "Overwrite replaces those changes with your text. Show Server Version shows the server's text: copy what you "
                    + "need, then save again to overwrite it.")
        }
        .alert("Can't save “\(name)”", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } }),
               presenting: failure) { _ in
            Button("OK") {}
        } message: { failure in
            Text(failure.message)
        }
        .sheet(isPresented: Binding(get: { theirs != nil }, set: { if !$0 { theirs = nil } })) {
            NavigationStack {
                ScrollView {
                    Text(theirs ?? "")
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .navigationTitle("\(name) on the server")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button("Done") { theirs = nil }
                        .help("Close the server's version")
                }
            }
        }
    }

    /// The lines changed since the file was opened: as they were (−) and as they are (+), with their line numbers.
    @ViewBuilder private var changes: some View {
        let old = file.original.split(separator: "\n", omittingEmptySubsequences: false)
        let new = text.split(separator: "\n", omittingEmptySubsequences: false)
        let rows = new.difference(from: old).map { change -> (line: Int, added: Bool, text: Substring) in
            switch change {
            case .remove(let offset, let line, _): (offset + 1, false, line)
            case .insert(let offset, let line, _): (offset + 1, true, line)
            }
        }.sorted { ($0.line, $0.added ? 1 : 0) < ($1.line, $1.added ? 1 : 0) }
        if rows.isEmpty {
            ContentUnavailableView("No changes", systemImage: "checkmark.circle",
                                   description: Text("Lines you change show here, as they were and as they are now."))
        } else {
            List(rows.indices, id: \.self) { index in
                let row = rows[index]
                HStack(alignment: .firstTextBaseline) {
                    Text("\(row.line)")
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 36, alignment: .trailing)
                    Text((row.added ? "+ " : "− ") + row.text)
                        .foregroundStyle(row.added ? .green : .red)
                }
                .font(.caption.monospaced())
                .listRowBackground((row.added ? Color.green : .red).opacity(0.08))
            }
            .listStyle(.plain)
        }
    }

    private var info: some View {
        let entry = file.entry
        return Form {
            Section {
                LabeledContent("Server", value: file.session.host.displayName)
                LabeledContent("Path") { Text(entry.path).textSelection(.enabled) }
                LabeledContent("Size", value: FileRow.size(entry.size))
                LabeledContent("Permissions", value: entry.permissions.isEmpty ? "—" : entry.permissions)
                LabeledContent("Owner", value: entry.owner.isEmpty ? "—" : "\(entry.owner):\(entry.group)")
                LabeledContent("Modified", value: FileRow.date(entry) ?? "—")
            } footer: {
                Text("As the folder's listing showed the file when you opened it.")
            }
            Section {
                LabeledContent("Lines", value: (text.split(separator: "\n", omittingEmptySubsequences: false).count).formatted())
                LabeledContent("Line ends", value: crlf ? "Windows (CR LF)" : "Unix (LF)")
            }
        }
    }

    /// `overwriting`: without first checking that the server still has the file as this editor knows it.
    private func save(overwriting: Bool) {
        guard !saving else { return }
        saving = true
        status = "Saving…"
        let typed = text
        let written = crlf ? typed.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n") : typed
        Task {
            do {
                if case .changed(let theirs) = try await file.session.saveText(written, to: file.entry.path, isLink: file.entry.kind == .symlink,
                                                                               ifUnchangedFrom: overwriting ? nil : serverText) {
                    status = "Not saved: changed on the server"
                    saving = false
                    conflict = Conflict(theirs: theirs)
                    return
                }
                savedText = typed
                serverText = written
                status = "Saved at " + Date().formatted(date: .omitted, time: .standard)
                onSaved()
                if closeAfterSaving { close() }
            } catch {
                status = "Not saved"
                failure = error as? AirSCPError ?? AirSCPError(.other, error.localizedDescription)
            }
            saving = false
            closeAfterSaving = false
        }
    }
}
