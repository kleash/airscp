import AirSCPCore
import AirSCPSSH2
import XCTest

/// The Docker lab's target (testenv/README.md: 127.0.0.1:42201, user dev, its throwaway password) over libssh2, for
/// what a test does on the server behind the app's back: its own folder made and removed, a file changed meanwhile,
/// what arrived checked. Its known_hosts is the app's (the test's AIRSCP_SUPPORT_DIR), so the app doesn't ask to trust
/// the server again.
final class LabServer {
    let session: Session
    /// The test's folder in dev's home, removed by `remove()`.
    let folder: String

    init(knownHosts: String) async throws {
        let host = SSHHost(hostname: "127.0.0.1", port: 42201, username: "dev", auth: .password)
        session = Session(host: host, jump: nil, askpass: nil, transport: SSH2Transport(host: host, jump: nil, knownHosts: knownHosts))
        session.savedPassword = { _ in nil }
        session.savePassword = { _, _ in }
        session.onPrompt = { prompt, reply in
            switch prompt.kind {
            case .hostKey: reply(.trust)
            case .password: reply(PromptAnswer("porter-dev"))
            default: reply(nil)
            }
        }
        try await session.connect()
        folder = RemotePath.join(session.capabilities.home, "ui-files-" + UUID().uuidString.prefix(8).lowercased())
        try await session.makeDirectory(folder)
    }

    func path(_ name: String) -> String { RemotePath.join(folder, name) }

    func write(_ text: String, to name: String) async throws {
        try await session.writeText(text, to: path(name))
    }

    func read(_ name: String) async throws -> String {
        try await session.readText(path(name))
    }

    /// A file's bytes, downloaded.
    func data(_ name: String) async throws -> Data {
        let local = FileManager.default.temporaryDirectory.appendingPathComponent("lab-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: local) }
        try await session.fetch(path(name), to: local)
        return try Data(contentsOf: local)
    }

    func names(in name: String = "") async throws -> [String] {
        try await session.list(name.isEmpty ? folder : path(name)).map(\.name).sorted()
    }

    func remove() async {
        try? await session.delete([RemoteEntry(name: RemotePath.name(folder), path: folder, kind: .directory, size: 0, modified: nil)])
        await session.disconnect()
    }

    /// Whether the lab's target accepts a TCP connection (at once on this Mac: refused or not).
    static func isUp() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(42201).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }
}
