import AirSCPCore
import AppKit
import SwiftUI

/// A change an agent's request waits on, for the person at the Mac to allow or not (Settings ▸ Ask before agents
/// change things), and their answer once they give one.
@MainActor
final class AgentQuestion: ObservableObject {
    enum Answer { case deny, once, fifteenMinutes }

    /// The change after "An AI agent wants to": "press “Delete”", "type into the Terminal tab of “web”".
    let change: String
    /// What it acts on: the question it answers, the text it would type, the files it would copy.
    let detail: String
    /// The detail is text to type or a command: shown as code.
    let code: Bool
    /// The agent (its MCP client), when known.
    let client: String?
    /// Seconds it waits for an answer.
    let timeout: TimeInterval
    @Published var answer: Answer?

    init(change: String, detail: String, code: Bool, client: String?, timeout: TimeInterval) {
        self.change = change
        self.detail = detail
        self.code = code
        self.client = client
        self.timeout = timeout
    }

    /// The detail as the panel shows it: its first 10 lines, then how many more there are. What is left out is said, so
    /// that a command can't hide its end below what the panel shows.
    var shownDetail: String {
        let lines = detail.components(separatedBy: "\n")
        guard lines.count > 10 else { return detail }
        let more = lines.count - 10
        return lines.prefix(10).joined(separator: "\n") + "\n… and \(more) more line" + (more == 1 ? "" : "s")
    }
}

/// The question as a small panel over every app and on every Space. It isn't modal: AirSCP goes on working, and the
/// panel can be answered while one of AirSCP's own questions is open. Agents can't reach it: it isn't one of their
/// windows (`AgentServer.appWindows`), and their screenshots leave it out.
final class AgentQuestionPanel: NSPanel {
    init(_ question: AgentQuestion) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 160), styleMask: [.titled, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        title = "AirSCP"
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        worksWhenModal = true
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = NSHostingView(rootView: AgentQuestionView(question: question))
        contentView = content
        setContentSize(content.fittingSize)
        center()
    }

    /// In front of every app. It takes the keyboard only while AirSCP is the active app: else the person may be typing
    /// in another app, and the Dock icon bounces once instead.
    func show() {
        orderFrontRegardless()
        if NSApp.isActive { makeKey() } else { NSApp.requestUserAttention(.informationalRequest) }
    }
}

struct AgentQuestionView: View {
    @ObservedObject var question: AgentQuestion

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    // Verbatim: names and paths are no Markdown.
                    Text(verbatim: "An AI agent wants to \(question.change).").font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    if !question.detail.isEmpty {
                        Text(verbatim: question.shownDetail)
                            .font(question.code ? .system(.callout, design: .monospaced) : .callout)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Text(verbatim: (question.client.map { "Asked by \($0). " } ?? "")
                         + "Without an answer within \(Int(question.timeout)) seconds, it isn't done.")
                        .font(.caption).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Spacer()
                Button("Allow for 15 Minutes") { question.answer = .fifteenMinutes }
                    .help("Allow this, and the changes agents ask for in the next 15 minutes, without asking again")
                Button("Allow Once") { question.answer = .once }
                    .help("Allow this one change")
                Button("Deny") { question.answer = .deny }
                    .keyboardShortcut(.defaultAction).primaryTint()
                    .help("Don't allow it (Return or Esc): the agent is told you declined")
            }
        }
        .padding(18)
        .frame(width: 460)
        .background(Button("") { question.answer = .deny }.keyboardShortcut(.cancelAction).opacity(0).accessibilityHidden(true))
    }
}
