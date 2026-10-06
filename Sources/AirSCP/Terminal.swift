import AirSCPCore
import Foundation

/// Opens ssh in Terminal or iTerm: a .command script in Application Support/AirSCP/Terminal that removes itself and
/// execs ssh riding the host's master connection (`OpenSSH.terminal`). It has no askpass: with the master down, ssh
/// asks for passwords in the terminal itself. It exports `AskpassServer.terminalEnvironment`, so that a proxy-connect
/// ProxyCommand started there still gets the proxy's password from the app. Each launch writes its own script, so
/// quick launches can't mix up.
enum TerminalLauncher {
    static let iTermID = "com.googlecode.iterm2"

    static var folder: URL { Store.directory.appendingPathComponent("Terminal", isDirectory: true) }

    /// `command` runs with a tty instead of a login shell: `OpenSSH.shellIn(dir)` for "Open Terminal Here",
    /// a snippet for "Run in Terminal". `environment` is exported first.
    static func script(_ host: SSHHost, jump: SSHHost?, command: String? = nil, environment: [String: String] = [:]) -> String {
        let ssh = OpenSSH.terminal(host, jump: jump, socket: Session.socketPath(for: host.id), command: command)
        let exports = environment.sorted { $0.key < $1.key }.map { "export \($0.key)=\(Quote.shell($0.value))\n" }.joined()
        return "#!/bin/sh\nrm -f -- \"$0\"\n" + exports + "exec " + ssh.map(Quote.shellWord).joined(separator: " ") + "\n"
    }

    /// What opens the script. Terminal runs an opened .command file; iTerm (3.6) doesn't run one unattended, so
    /// osascript asks it for a window running the script (macOS asks once whether AirSCP may control iTerm).
    static func opener(_ app: AppSettings.TerminalApp, script path: String) -> [String] {
        switch app {
        case .terminal:
            return ["/usr/bin/open", "-a", "Terminal", path]
        case .iTerm:
            return ["/usr/bin/osascript", "-e", "on run argv", "-e", "tell application id \"\(iTermID)\"", "-e", "activate",
                    "-e", "create window with default profile command (item 1 of argv)", "-e", "end tell", "-e", "end run",
                    Quote.shell(path)]
        }
    }

    /// Writes the script and opens it in `app`; throws when either fails.
    static func open(_ host: SSHHost, jump: SSHHost?, command: String? = nil, app: AppSettings.TerminalApp,
                     environment: [String: String] = [:], log: ((LogEntry) -> Void)? = nil) async throws {
        if let error = OpenSSH.missingJump(host, jump: jump) { throw error }  // without the master, ssh logs in afresh
        let url = try write(script(host, jump: jump, command: command, environment: environment), name: host.displayName)
        let result = await Runner.run(opener(app, script: url.path), hostID: host.id, log: log)
        guard result.status == 0 else {
            try? FileManager.default.removeItem(at: url)
            let name = app == .iTerm ? "iTerm" : "Terminal"
            throw AirSCPError(.other, "\(name) couldn't open the ssh session. Check Settings ▸ Open terminals in; iTerm must "
                + "be installed to use it.", details: result.stderr)
        }
    }

    /// Scripts left by launches whose terminal never ran them (at startup).
    static func removeLeftovers() {
        try? FileManager.default.removeItem(at: folder)
    }

    /// "<host name> 1a2b3c.command" in `folder`, executable by its owner only.
    static func write(_ text: String, name: String, in folder: URL = folder) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let safe = String(name.map { "/:\n".contains($0) ? "-" : $0 }.prefix(60))
        let url = folder.appendingPathComponent("\(safe) \(UUID().uuidString.prefix(6).lowercased()).command")
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
