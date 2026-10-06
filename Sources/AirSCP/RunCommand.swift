import AirSCPCore
import AppKit
import SwiftUI

/// Run Command (a sheet on a host's window): a typed command or a snippet, run in the account's login shell over
/// the connection, with its output, error output and exit status; Run in Terminal for anything that needs a tty.
@MainActor
final class RunCommandModel: ObservableObject {
    @Published var command: String
    /// The command is AirSCP's (File ▸ Run…: a server file's name, quoted for sh): sh runs it, in Terminal too, never
    /// the login shell, which may read that quoting differently (`Session.run(_:sh:)`, `OpenSSH.viaSh`). A snippet put
    /// in its place runs as typed again.
    @Published var sh: Bool
    @Published private(set) var running = false
    @Published private(set) var result: CommandResult?
    /// The end of the output and of the error output, as shown: worked out once, not on every redraw.
    @Published private(set) var shown = (output: "", errors: "")
    /// Why it couldn't run (disconnected, an sftp-only account, stopped).
    @Published private(set) var failure: String?
    let connection: HostConnection
    private var cancellation: Cancellation?

    init(connection: HostConnection, command: String, sh: Bool = false) {
        self.connection = connection
        self.command = command
        self.sh = sh
    }

    /// Why commands can't run on this host (an sftp-only account), or nil.
    var unavailableReason: String? {
        let capabilities = connection.session.capabilities
        guard connection.state == .connected, !capabilities.shell else { return nil }
        return capabilities.noShellReason ?? "This server doesn't run commands."
    }

    func run() {
        let command = self.command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty, !running, unavailableReason == nil else { return }  // the sheet already says why not
        let cancellation = Cancellation()
        self.cancellation = cancellation
        running = true
        result = nil
        failure = nil
        shown = ("", "")
        let session = connection.session, live = RunOutput()
        // What it prints shows as it comes, four times a second at most (its end worked out off the main thread).
        let ticker = Task.detached(priority: .utility) { [self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if let shown = live.shown(onlyIfChanged: true) { await show(shown) }
            }
        }
        Task {
            do {
                let result = try await session.run(command, sh: sh, cancellation: cancellation, output: live.add(output:),
                                                   errorOutput: live.add(errors:))
                shown = (Self.tail(result.output), Self.tail(result.stderr))
                self.result = result
            } catch {
                let error = error as? AirSCPError ?? AirSCPError(.other, error.localizedDescription)
                failure = error.kind == .cancelled ? "Stopped." : error.message
                shown = live.shown(onlyIfChanged: false) ?? ("", "")  // what it printed before it stopped stays
            }
            ticker.cancel()
            running = false
        }
    }

    func stop() { cancellation?.cancel() }

    /// What a running command printed so far.
    private func show(_ shown: (output: String, errors: String)) {
        if running { self.shown = shown }
    }

    /// The last `lines` lines (and at most `bytes` of them) of `text`, saying how much came before: a text view lays out
    /// tens of thousands of lines for minutes, freezing the app.
    nonisolated static func tail(_ text: String, lines limit: Int = 1000, bytes: Int = 64 << 10) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let all = lines.count
        if all > limit { lines = Array(lines.suffix(limit)) }
        var shown = lines.joined(separator: "\n")
        if shown.utf8.count > bytes { shown = String(decoding: Array(shown.utf8.suffix(bytes)), as: UTF8.self) }
        let cut = all - shown.split(separator: "\n", omittingEmptySubsequences: false).count
        return cut > 0 ? "… (\(cut.formatted()) lines before these aren't shown: Run in Terminal shows everything)\n" + shown : shown
    }
}

/// A running command's output and error output as they come (on the Runner's threads): shown meanwhile, and kept when
/// it is stopped.
final class RunOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var output = Data(), errors = Data(), changed = false

    func add(output data: Data) {
        lock.lock()
        defer { lock.unlock() }
        output.append(data)
        changed = true
    }

    func add(errors data: Data) {
        lock.lock()
        defer { lock.unlock() }
        errors.append(data)
        changed = true
    }

    /// The ends of both as the sheet shows them (without the shell's pid line), or nil when nothing came since last time
    /// (`onlyIfChanged`).
    func shown(onlyIfChanged: Bool) -> (output: String, errors: String)? {
        lock.lock()
        guard changed || !onlyIfChanged else {
            lock.unlock()
            return nil
        }
        changed = false
        let (output, errors) = (self.output, self.errors)
        lock.unlock()
        return (RunCommandModel.tail(String(decoding: output, as: UTF8.self)),
                RunCommandModel.tail(RemotePID.removed(from: String(decoding: errors, as: UTF8.self))))
    }
}

struct RunCommandView: View {
    @ObservedObject var model: RunCommandModel
    @ObservedObject var app: AppModel
    let runInTerminal: (String) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Run a command on “\(model.connection.session.host.displayName)”").font(.headline)
            PlainTextEditor(text: $model.command, id: "runCommand.command", help: "The command line, as you would type it in a terminal")
                .frame(height: 64)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.35)))
            Text((model.sh ? "Runs with sh" : "Runs in the account's login shell")
                 + ", without a terminal. Output appears below; ⌘↩ runs.")
                .font(.caption).foregroundColor(.secondary)
            HStack {
                // A pop-up whose choice fills in the command (it shows "Snippets" again afterwards).
                Picker("Snippets", selection: Binding<UUID?>(get: { nil }, set: { id in
                    if let snippet = app.data.snippets.first(where: { $0.id == id }) {
                        model.command = snippet.command
                        model.sh = false
                    }
                })) {
                    Text("Snippets").tag(UUID?.none)
                    if app.data.snippets.isEmpty {
                        Text("No snippets yet — Window ▸ Snippets").tag(Optional(UUID(uuid: UUID_NULL))).disabled(true)
                    }
                    ForEach(app.data.snippets) { snippet in
                        Text(snippet.name.isEmpty ? snippet.command : snippet.name).tag(Optional(snippet.id))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("runCommand.snippet")
                .help(app.data.snippets.isEmpty ? "No snippets yet: Window ▸ Snippets keeps commands you run often"
                      : "Fill in a saved command")
                Text(model.unavailableReason ?? "").font(.caption).foregroundColor(.secondary)
                Spacer()
                Button("Run in Terminal") { runInTerminal(model.sh ? OpenSSH.viaSh(model.command) : model.command) }
                    .help("Opens Terminal with a tty: for sudo, top, editors and anything interactive")
                    .disabled(model.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.unavailableReason != nil)
                if model.running {
                    Button("Stop") { model.stop() }.help("Stop the command")
                } else {
                    Button("Run") { model.run() }
                        .keyboardShortcut(.return, modifiers: .command)
                        .help(model.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Type a command first"
                              : "Runs the command and shows its output (⌘↩)")
                        .disabled(model.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  || model.unavailableReason != nil)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if model.result != nil || !model.shown.output.isEmpty || !model.shown.errors.isEmpty {
                        Text(model.shown.output).foregroundColor(.primary)
                        if !model.shown.errors.isEmpty { Text(model.shown.errors).foregroundColor(.red) }
                    } else if !model.running {
                        Text("The command's output appears here; error output in red.").foregroundColor(.secondary)
                    }
                }
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.35)))
            HStack {
                HelpButton(.runCommand)
                if model.running {
                    ProgressView().controlSize(.small)
                    Text("Running…").foregroundColor(.secondary)
                } else if let failure = model.failure {
                    Text(failure).foregroundColor(.red)
                } else if let result = model.result {
                    Text("Exit status \(result.status)").foregroundColor(result.status == 0 ? .secondary : .red)
                        .help("0 means it worked; anything else is the command's own error code")
                }
                Spacer()
                Button("Close") {
                    model.stop()
                    close()
                }
                .keyboardShortcut(.cancelAction)
                .help("Close (a running command is stopped)")
            }
            .font(.callout)
        }
        .padding(20)
        .frame(width: 640, height: 480)
    }
}

/// The Snippets window: saved commands, each run on a host chosen at run time (in that host's window, or in
/// Terminal when it needs a tty).
struct SnippetsView: View {
    @ObservedObject var model: AppModel
    let run: (Snippet, UUID) -> Void
    @State private var selection: UUID?
    @State private var hostID: UUID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(model.data.snippets, selection: $selection) { snippet in
                    Text(snippet.name.isEmpty ? "Untitled" : snippet.name).tag(snippet.id)
                }
                Divider()
                HStack(spacing: 2) {
                    Button { add() } label: { Image(systemName: "plus").frame(width: 20, height: 18) }
                        .help("New snippet")
                        .accessibilityLabel("Add")
                        .accessibilityIdentifier("snippets.add")
                    Button { remove() } label: { Image(systemName: "minus").frame(width: 20, height: 18) }
                        .help("Delete the snippet")
                        .accessibilityLabel("Remove")
                        .accessibilityIdentifier("snippets.remove")
                        .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(minWidth: 170, idealWidth: 200, maxWidth: 280)
            editor
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 600, minHeight: 340)
    }

    @ViewBuilder
    private var editor: some View {
        if let id = selection, model.data.snippets.contains(where: { $0.id == id }) {
            let snippet = binding(id)
            let empty = snippet.wrappedValue.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            Form {
                TextField("Name:", text: snippet.name).accessibilityIdentifier("snippet.name")
                    .help("How the snippet is listed")
                LabeledContent("Command:") {
                    PlainTextEditor(text: snippet.command, id: "snippet.command",
                                    help: "The command line to run; several lines run one after another")
                        .frame(minHeight: 90)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.35)))
                }
                Toggle("Run in Terminal (for sudo, top or anything interactive)", isOn: snippet.runInTerminal)
                    .accessibilityIdentifier("snippet.runInTerminal")
                    .help("Off by default: the output is shown in AirSCP. On opens Terminal, for commands that ask questions "
                          + "or need a screen")
                LabeledContent("Run on:") {
                    HStack {
                        Picker("Run on:", selection: $hostID) {
                            Text("Choose a host").tag(UUID?.none)
                            ForEach(model.data.hosts.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }) {
                                Text($0.displayName).tag(Optional($0.id))
                            }
                        }
                        .labelsHidden()
                        .accessibilityIdentifier("snippet.host")
                        .help("The host to run it on now; AirSCP connects first if needed")
                        Button("Run") { if let hostID { run(snippet.wrappedValue, hostID) } }
                            .disabled(hostID == nil || empty)
                            .help(hostID == nil || empty ? "Choose a host and enter a command" : "Run the snippet on that host")
                    }
                }
            }
            .padding(20)
        } else {
            Text(model.data.snippets.isEmpty ? "No snippets yet. A snippet is a command you run often, on any host. Click + "
                 + "to add one." : "Select a snippet on the left to edit or run it.")
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(20)
        }
    }

    /// The snippet with this id, edited in place in the saved data.
    private func binding(_ id: UUID) -> Binding<Snippet> {
        Binding(get: { model.data.snippets.first { $0.id == id } ?? Snippet(id: id, name: "", command: "") },
                set: { snippet in
                    if let index = model.data.snippets.firstIndex(where: { $0.id == id }) { model.data.snippets[index] = snippet }
                })
    }

    private func add() {
        let snippet = Snippet(name: "New Snippet", command: "")
        model.data.snippets.append(snippet)
        selection = snippet.id
    }

    private func remove() {
        guard let id = selection else { return }
        model.data.snippets.removeAll { $0.id == id }
        selection = nil
    }
}

/// A multi-line field for commands and ssh options that keeps what is typed: no smart quotes or dashes and no text
/// replacements (a TextEditor applies the Mac's settings for those, turning "--" into "—" a moment after typing), and
/// Tab moves to the next field.
struct PlainTextEditor: NSViewRepresentable {
    @Binding var text: String
    /// Its accessibility id (agents set it by that).
    let id: String
    /// Its tooltip.
    var help = ""

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        guard let textView = scroll.documentView as? NSTextView else { return scroll }
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 2, height: 4)
        textView.string = text
        textView.setAccessibilityIdentifier(id)
        textView.toolTip = help
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        if let textView = scroll.documentView as? NSTextView, textView.string != text { textView.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            if let textView = notification.object as? NSTextView { text.wrappedValue = textView.string }
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertTab(_:)): textView.window?.selectNextKeyView(nil)
            case #selector(NSResponder.insertBacktab(_:)): textView.window?.selectPreviousKeyView(nil)
            default: return false
            }
            return true
        }
    }
}
