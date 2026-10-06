import AirSCPCore
import Foundation

/// One host's connection as its workspace shows it: the Session, its state (also in `AppModel.states` for the
/// sidebar), the command log, and ssh's prompts handed to the workspace. A Session's host settings are fixed, so
/// Connect makes a new Session when the host was edited since (unless the old one still has transfers to finish).
@MainActor
final class HostConnection: ObservableObject {
    let hostID: UUID
    @Published private(set) var state = Session.State.idle
    private(set) var session: Session
    let log = CommandLog()
    /// Shows a prompt from ssh; `reply` takes the answer, or nil to cancel (then call `promptCancelled` if the user
    /// cancelled it).
    var ask: ((Prompt, @escaping (PromptAnswer?) -> Void) -> Void)?
    /// After every state change.
    var onStateChange: ((Session.State) -> Void)?
    /// After Connect replaced the Session.
    var onNewSession: ((Session) -> Void)?
    /// The master was left by an earlier AirSCP: not AirSCP's child, so only `checkAdopted` notices its end.
    private(set) var adopted = false
    /// The user cancelled a prompt since the last Connect or key install: further prompts are cancelled unseen, and
    /// the failure that follows isn't news.
    private(set) var cancelledByUser = false

    /// The app's askpass server (its `terminalEnvironment` goes into Terminal scripts).
    let askpass: AskpassServer
    private let model: AppModel

    init(host: SSHHost, model: AppModel, askpass: AskpassServer) {
        hostID = host.id
        self.model = model
        self.askpass = askpass
        session = Session(host: host, jump: model.jump(for: host), askpass: askpass)
        attach(session)
    }

    private func attach(_ session: Session) {
        session.onStateChange = { [weak self, weak session] state in
            guard let self, let session, session === self.session else { return }
            self.state = state
            self.model.states[self.hostID] = state == .idle ? nil : state
            self.onStateChange?(state)
        }
        session.onLog = { [weak self] entry in self?.log.append(entry) }
        session.onPrompt = { [weak self] prompt, reply in
            // After the user cancelled one, the rest are cancelled unseen: ssh treats a cancel as an empty answer and
            // would just ask again.
            guard let self, !self.cancelledByUser, let ask = self.ask else { return reply(nil) }
            ask(prompt, reply)
        }
    }

    /// Connects unless connecting or connected; throws what made it fail (a mapped `AirSCPError`).
    func connect() async throws {
        switch session.state {
        case .connecting, .connected: return
        case .idle, .disconnected, .reconnecting: break
        }
        guard let host = model.host(hostID) else { throw AirSCPError(.other, "This host has been deleted.") }
        let jump = model.jump(for: host)
        let edited = OpenSSH.master(host, jump: jump, socket: "") != OpenSSH.master(session.host, jump: session.jump, socket: "")
        session.autoReconnect = host.autoReconnect
        if edited && !session.transfers.isBusy {
            session = Session(host: host, jump: jump, askpass: askpass)
            attach(session)
            onNewSession?(session)
        }
        adopted = false
        cancelledByUser = false
        try await session.connect()
    }

    /// Takes over a live master left by an earlier AirSCP (launch after a crash).
    func adopt() async -> Bool {
        adopted = await session.adopt()
        return adopted
    }

    /// Notices that an adopted master has gone (AirSCP sees its own masters exit).
    func checkAdopted() async {
        if adopted && state == .connected { _ = await session.check() }
    }

    /// Cancels transfers (cleaning up), stops running commands, closes the master.
    func disconnect() async {
        await session.disconnect()
    }

    /// After "host key changed": removes the old key from known_hosts and connects (ssh then asks to trust the new one).
    func removeOldHostKeyAndReconnect() async throws {
        try await session.removeOldHostKey()
        try await connect()
    }

    /// ssh-copy-id (or the sftp route on an sftp-only account) installing a public key for this host's account.
    func installKey(_ publicKey: String) async throws {
        cancelledByUser = false
        try await session.installKey(publicKey)
    }

    /// The user cancelled a prompt: stop connecting (ssh would only ask again or fail), and don't report the failure.
    func promptCancelled() {
        cancelledByUser = true
        let session = self.session
        if session.state == .connecting { Task { await session.disconnect() } }
    }
}
