import AirSCPCore
import AirSCPSSH2
import Observation
import SwiftUI

/// The saved servers and the open connections, with the questions they ask (shown one at a time as a sheet).
/// Session callbacks arrive on the main queue.
@Observable final class AppState {
    var data = Store.load()
    /// Open connections, saved servers' and quick connects', in the order opened.
    private(set) var open: [Session] = []
    /// Each open connection's state, by host id (Session's own isn't observable).
    private(set) var states: [UUID: Session.State] = [:]
    /// Questions waiting for an answer; the first one shows.
    private(set) var questions: [Question] = []
    /// Why the last connect failed.
    var failure: AirSCPError?
    /// Files picked to carry elsewhere together.
    let tray = Tray()
    /// "Show this" from Search or the terminal: the Files tab shows it (a folder opened, a file selected in its folder, or
    /// with a `line` edited there), then sets it back to nil.
    var reveal: Reveal?

    struct Reveal: Equatable {
        let id = UUID()
        let hostID: UUID
        let path: String
        var isFolder = false
        var line: Int?
    }
    /// Connections whose question the user cancelled: their connect failing then needs no alert.
    private var declined: Set<ObjectIdentifier> = []
    /// Each open connection's system monitor, shared by its Monitor screen and its figures in Servers.
    @ObservationIgnored private var monitors: [ObjectIdentifier: HostMonitor] = [:]

    /// A connection's question: answer it once (`answer`); nil cancels.
    final class Question: Identifiable {
        let prompt: Prompt
        let session: Session
        fileprivate var reply: ((PromptAnswer?) -> Void)?

        init(prompt: Prompt, session: Session, reply: @escaping (PromptAnswer?) -> Void) {
            self.prompt = prompt
            self.session = session
            self.reply = reply
        }
    }

    func answer(_ question: Question, _ answer: PromptAnswer?) {
        if answer == nil { declined.insert(ObjectIdentifier(question.session)) }
        question.reply?(answer)
        question.reply = nil
        questions.removeAll { $0 === question }
    }

    // MARK: Saved servers

    func jump(for host: SSHHost) -> SSHHost? {
        host.jumpHostID.flatMap { id in data.hosts.first { $0.id == id } }
    }

    /// Adds or replaces the host; `password`, when given, goes to the Keychain.
    func save(_ host: SSHHost, password: String? = nil) {
        if let index = data.hosts.firstIndex(where: { $0.id == host.id }) {
            data.hosts[index] = host
        } else {
            data.hosts.append(host)
        }
        if let password, !password.isEmpty { Keychain.setPassword(password, for: host.id) }
        write()
    }

    func delete(_ host: SSHHost) {
        if let session = session(for: host.id) { disconnect(session) }
        data.hosts.removeAll { $0.id == host.id }
        for index in data.hosts.indices where data.hosts[index].jumpHostID == host.id { data.hosts[index].jumpHostID = nil }
        Keychain.setPassword(nil, for: host.id)
        write()
    }

    private func write() {
        do {
            try Store.save(data)
        } catch {
            failure = AirSCPError(.other, "AirSCP couldn't save your servers.", details: error.localizedDescription)
        }
    }

    // MARK: Connections

    func session(for id: UUID) -> Session? { open.first { $0.host.id == id } }

    /// Connects (again): a saved server as saved now, or a quick connect's host.
    func connect(_ host: SSHHost) {
        let session: Session
        if let existing = self.session(for: host.id), existing.host == host {
            if existing.state == .connected || existing.state == .connecting { return }
            session = existing
        } else {
            if let existing = self.session(for: host.id) { disconnect(existing) }  // edited since: start over
            session = makeSession(host)
        }
        states[host.id] = .connecting  // Session says so only once it starts
        Task { @MainActor in
            do {
                try await session.connect()
                declined.remove(ObjectIdentifier(session))  // a question cancelled on the way didn't stop it
                // UI tests: downloads to watch (into the test's settings folder), and the server's files in the tray.
                let test = ProcessInfo.processInfo.environment
                for path in (test["AIRSCP_TEST_DOWNLOADS"]?.split(separator: ",") ?? []).map(String.init) {
                    session.transfers.download(path, to: Store.directory.appendingPathComponent(RemotePath.name(path)).path, isFolder: false)
                }
                tray.add((test["AIRSCP_TEST_TRAY"]?.split(separator: ",") ?? []).map {
                    Tray.Item(hostID: host.id, path: String($0), isFolder: false)
                })
            } catch {
                // A first connect that fails goes back to idle in Session; the row keeps the reason.
                let error = error as? AirSCPError ?? AirSCPError(.other, error.localizedDescription)
                let cancelled = error == .cancelled || declined.remove(ObjectIdentifier(session)) != nil
                guard open.contains(where: { $0 === session }) else { return }
                states[host.id] = cancelled ? .idle : .disconnected(error)
                if !cancelled { failure = error }
            }
        }
    }

    @MainActor func monitor(for session: Session) -> HostMonitor {
        if let monitor = monitors[ObjectIdentifier(session)] { return monitor }
        let monitor = HostMonitor(session: session)
        monitors[ObjectIdentifier(session)] = monitor
        return monitor
    }

    func disconnect(_ session: Session) {
        open.removeAll { $0 === session }
        states[session.host.id] = nil
        monitors[ObjectIdentifier(session)] = nil
        for question in questions where question.session === session { answer(question, nil) }
        Task { await session.disconnect() }
    }

    private func makeSession(_ host: SSHHost) -> Session {
        let jump = jump(for: host)
        // S3 storage goes over HTTPS (its secret: the host's Keychain password), not SSH.
        let transport = host.s3 != nil ? nil : SSH2Transport(host: host, jump: jump, knownHosts: knownHostsPath, privateKey: KeyStore.privateKey)
        let session = Session(host: host, jump: jump, askpass: nil, transport: transport)
        session.onStateChange = { [weak self, weak session] state in
            guard let self, let session, open.contains(where: { $0 === session }) else { return }
            states[host.id] = state
        }
        session.onPrompt = { [weak self, weak session] prompt, reply in
            guard let self, let session else { return reply(nil) }
            questions.append(Question(prompt: prompt, session: session, reply: reply))
        }
        open.append(session)
        states[host.id] = session.state
        return session
    }

    /// "user@host:port" (port optional) as a host to connect to without saving it; nil when it isn't one. The user is
    /// required: iOS has no login name of its own to fall back on, as ssh does on the Mac.
    /// shortcut: an IPv6 address can't have a port here; it connects on 22 (save the server to give one).
    static func quickHost(_ text: String) -> SSHHost? {
        var rest = text.trimmingCharacters(in: .whitespaces)
        guard !rest.isEmpty, !rest.contains(" ") else { return nil }
        var user = ""
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = String(rest[rest.index(after: at)...])
        }
        var port: Int?
        if rest.filter({ $0 == ":" }).count == 1, let colon = rest.firstIndex(of: ":"),
           let number = Int(rest[rest.index(after: colon)...]), (1...65535).contains(number) {
            port = number
            rest = String(rest[..<colon])
        }
        guard !rest.isEmpty, !user.isEmpty else { return nil }
        return SSHHost(hostname: rest, port: port, username: user, auth: .password)
    }
}
