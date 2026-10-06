import AirSCPCore
import AppKit
import SwiftUI

/// A host's command log: every command AirSCP ran, as a line that can be pasted into Terminal, with its exit
/// status and error output. The master connection is listed while it runs and moves down when it ends; a command that
/// succeeds again (a refresh, the Monitor tab's every 3 s) moves down too instead of being listed twice. Bounded: the
/// last `limit` entries, each command line and error output cut in the middle beyond `textLimit` characters.
@MainActor
final class CommandLog: ObservableObject {
    static let limit = 500
    nonisolated static let textLimit = 8_000

    struct Entry: Identifiable {
        let id: UUID
        let date: Date
        let command: String
        /// nil while it runs.
        let status: Int32?
        let stderr: String
    }

    /// Changed at once; shown at most four times a second (a transfer of many files logs many commands a second, and
    /// each update makes the list compare all its rows).
    private(set) var entries: [Entry] = [] {
        didSet { scheduleChange() }
    }
    private var changeScheduled = false

    private func scheduleChange() {
        guard !changeScheduled else { return }
        changeScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.changeScheduled = false
            self?.objectWillChange.send()
        }
    }

    func append(_ entry: LogEntry) {
        let entry = Entry(id: entry.id, date: entry.date, command: Self.cut(entry.command), status: entry.status,
                          stderr: Self.cut(entry.stderr))
        if entry.status != nil, let running = entries.lastIndex(where: { $0.status == nil && $0.command == entry.command }) {
            entries.remove(at: running)
        }
        if entry.status == 0, let earlier = entries.lastIndex(where: { $0.status == 0 && $0.command == entry.command }) {
            entries.remove(at: earlier)
        }
        entries.append(entry)
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
    }

    func clear() { entries = [] }

    /// The command lines of `ids` (all entries when empty), one per line, for the pasteboard.
    func commands(_ ids: Set<Entry.ID>) -> String {
        entries.filter { ids.isEmpty || ids.contains($0.id) }.map(\.command).joined(separator: "\n")
    }

    /// Error output of `ids`, for the pasteboard.
    func errorOutput(_ ids: Set<Entry.ID>) -> String {
        entries.filter { ids.contains($0.id) && !$0.stderr.isEmpty }
            .map { $0.stderr.trimmingCharacters(in: .newlines) }.joined(separator: "\n")
    }

    /// `text`, or its start and end with the middle cut out when it is longer than `textLimit`.
    nonisolated static func cut(_ text: String) -> String {
        guard text.utf8.count > textLimit else { return text }
        let count = text.count
        guard count > textLimit else { return text }
        let half = textLimit / 2
        return String(text.prefix(half)) + "\n… (\(count - 2 * half) characters left out) …\n" + String(text.suffix(half))
    }
}

/// The command log panel (reusable: host workspaces and the Keys window embed it). Copy copies the selected command lines, or all.
struct CommandLogView: View {
    @ObservedObject var log: CommandLog
    /// What the empty log says (a host's workspace by default).
    var emptyText = "Nothing run yet. Every ssh, scp and sftp command AirSCP runs for this host appears here, with its "
        + "result, as a line you can copy."
    @State private var selection = Set<CommandLog.Entry.ID>()

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Command Log").font(.subheadline.weight(.semibold))
                Spacer()
                Button("Copy") { copy(log.commands(selection)) }
                    .help(selection.isEmpty ? "Copy every command line" : "Copy the selected command lines")
                    .disabled(log.entries.isEmpty)
                Button("Clear") {
                    selection = []
                    log.clear()
                }
                .disabled(log.entries.isEmpty)
                .help("Forget the listed commands (new ones keep coming)")
            }
            .controlSize(.small)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            Divider()
            ScrollViewReader { proxy in
                List(log.entries, selection: $selection) { entry in
                    row(entry).id(entry.id)
                }
                .listStyle(.plain)
                .washed()
                .overlay {
                    if log.entries.isEmpty {
                        Text(emptyText)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding()
                            .allowsHitTesting(false)
                    }
                }
                .contextMenu(forSelectionType: CommandLog.Entry.ID.self) { ids in
                    Button("Copy Command") { copy(log.commands(ids)) }
                        .help("Copy this command line, to run it yourself in a terminal")
                    Button("Copy Error Output") { copy(log.errorOutput(ids)) }
                        .disabled(log.errorOutput(ids).isEmpty)
                        .help("Copy what the command printed on its error output")
                }
                .onCopyCommand {
                    [NSItemProvider(object: log.commands(selection) as NSString)]
                }
                .onChange(of: log.entries.last?.id) { last in
                    if let last { proxy.scrollTo(last, anchor: .bottom) }
                }
            }
        }
    }

    private func row(_ entry: CommandLog.Entry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            status(entry.status)
                .frame(width: 34, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.command)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(3)
                    .truncationMode(.middle)
                if !entry.stderr.isEmpty {
                    Text(entry.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(entry.status == 0 ? .secondary : .red)
                        .lineLimit(4)
                }
            }
            Spacer(minLength: 4)
            Text(Self.time.string(from: entry.date))
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .help(entry.command)
    }

    @ViewBuilder
    private func status(_ status: Int32?) -> some View {
        switch status {
        case nil:
            Text("…").foregroundColor(.secondary).help("Running")
        case 0?:
            Image(systemName: "checkmark").foregroundColor(.green).help("Exit status 0").accessibilityLabel("Exit status 0")
        case let code?:
            Text("✗ \(code)").font(.caption.monospacedDigit()).foregroundColor(.red).help("Exit status \(code)")
        }
    }

    private func copy(_ text: String) {
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
