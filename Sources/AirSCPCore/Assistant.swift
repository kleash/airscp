import Foundation

/// Ask AirSCP and Explain (PLAN.md AD): a language model on this Mac (Apple Intelligence's, `AppleAssistant` in the
/// app) answers questions about AirSCP and the host in front of the user, from a short summary of it that never holds
/// a secret. The protocol lets tests use a stand-in.
public protocol Assistant: Sendable {
    /// The model's answer to `question`, told `instructions` and `context` first.
    func answer(_ question: String, instructions: String, context: String) async throws -> String
}

public enum AssistantContext {
    /// What the model is told it is and how to answer.
    public static let instructions = """
        You are the help inside AirSCP, a Mac app for SSH servers (saved hosts, a two-pane SFTP/SCP file browser with a \
        transfer queue, Synchronize, Find Files, a Linux monitor, tunnels, jump hosts and HTTP proxies, a Terminal tab), \
        Windows Remote Desktop, a Certificate Manager and SSH keys. Answer in plain, short English: the likely cause first, \
        then what to try, as numbered steps that name AirSCP's menus (File, Host, Tools, Window, Help) and buttons. Say \
        when you aren't sure. Never ask for or repeat a password, passphrase or key. If the question isn't about AirSCP, \
        servers, files or networking, say that you can help with those.
        """

    /// A summary of what the user sees, for the model: the host (name, address, route, state), the last error, the
    /// last commands AirSCP ran (their command lines, without output) and the server's figures. At most `limit`
    /// characters; known secrets are taken out (`DebugLog`'s redaction).
    public static func summary(host: SSHHost?, route: String?, state: String?, error: String?, commands: [String],
                               figures: String?, limit: Int = 3000) -> String {
        var lines: [String] = []
        if let host {
            lines.append("Host: \(host.displayName) — \(host.username.isEmpty ? "" : host.username + "@")\(host.hostname)"
                         + (host.port.map { ":\($0)" } ?? "") + ", logs in with " + ["agent": "the ssh agent or default keys",
                         "keyFile": "a key file", "password": "a password"][host.auth.rawValue, default: "?"])
            if !host.extraOptions.isEmpty { lines.append("Other ssh options: " + host.extraOptions.joined(separator: "; ")) }
        }
        if let route { lines.append("Route: \(route)") }
        if let state { lines.append("State: \(state)") }
        if let error, !error.isEmpty { lines.append("Last error: \(error)") }
        if let figures { lines.append("Server: \(figures)") }
        if !commands.isEmpty { lines.append("Recent commands:\n" + commands.suffix(8).map { "  " + $0 }.joined(separator: "\n")) }
        var text = DebugLog.redacted(lines.joined(separator: "\n"))
        if text.count > limit { text = String(text.prefix(limit)) + "…" }
        return text.isEmpty ? "Nothing is selected in AirSCP." : text
    }

    /// The question Explain asks about an error.
    public static func explain(_ error: String) -> String {
        "AirSCP showed this error. What does it mean, and what should I try?\n\n" + DebugLog.redacted(String(error.prefix(2000)))
    }
}
