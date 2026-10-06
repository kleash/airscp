import Foundation

/// Every command line AirSCP runs, built in one place.
public enum OpenSSH {
    public static let ssh = "/usr/bin/ssh"
    public static let scp = "/usr/bin/scp"
    public static let sftp = "/usr/bin/sftp"
    public static let sshKeygen = "/usr/bin/ssh-keygen"
    public static let sshAdd = "/usr/bin/ssh-add"
    public static let sshCopyID = "/usr/bin/ssh-copy-id"

    /// Test seam: an ssh_config passed with -F to every ssh, scp, sftp and ssh-copy-id, with no default key files
    /// (`config`). nil (the app) means the user's own ~/.ssh/config and keys.
    public static var configFile: String?

    /// The host's settings as -o options, shared verbatim by ssh, scp, sftp, ssh-copy-id and ssh -O. Only -o:
    /// ssh's -p (port) means "preserve" to scp and sftp. The first hop goes through the host's HTTP proxy, or with a
    /// jump host through the jump host's own proxy (nested in its ProxyCommand). `silent` (an automatic reconnect's
    /// master): the jump host's ssh tries one password at most, as the master itself does.
    public static func options(_ host: SSHHost, jump: SSHHost?, silent: Bool = false) -> [String] {
        var options: [String] = []
        func add(_ key: String, _ value: String) { options += ["-o", key + "=" + value] }
        if let port = host.port { add("Port", String(port)) }
        if !host.username.isEmpty { add("User", Quote.configValue(host.username)) }
        switch host.auth {
        case .keyFile where !host.keyFile.isEmpty:
            add("IdentityFile", Quote.configValue(host.keyFile.replacingOccurrences(of: "%", with: "%%")))
            add("IdentitiesOnly", "yes")
        case .password:
            // Straight to the password: no agent keys or default key passphrases first.
            add("PreferredAuthentications", "keyboard-interactive,password")
        default:
            break
        }
        if let jump {
            add("ProxyCommand", proxyCommand(through: jump, silent: silent))
        } else if let proxy = host.proxyID {
            add("ProxyCommand", proxyCommand(proxy))
        }
        if host.forwardAgent { add("ForwardAgent", "yes") }
        switch host.hostKeyCheck {
        case .ask:
            break
        case .acceptNew:
            add("StrictHostKeyChecking", "accept-new")
        case .off:
            // No known_hosts for this host either: a key remembered for it would no longer match, and ssh would then
            // connect without passwords.
            add("StrictHostKeyChecking", "no")
            add("UserKnownHostsFile", "/dev/null")
            add("GlobalKnownHostsFile", "/dev/null")
        }
        for line in host.extraOptions {
            let option = line.trimmingCharacters(in: .whitespaces)
            if !option.isEmpty && !option.hasPrefix("#") { options += ["-o", option] }
        }
        return options
    }

    /// Why `host` can't connect when its jump host no longer exists (deleted, or not in an imported file): without one,
    /// its command lines would go to the host directly, around the jump host. nil when its route is whole.
    public static func missingJump(_ host: SSHHost, jump: SSHHost?) -> AirSCPError? {
        guard host.jumpHostID != nil && jump == nil else { return nil }
        return AirSCPError(.other, "This host connects through a jump host that no longer exists, so AirSCP doesn't connect "
                           + "to it directly. Edit the host and choose another jump host, or None.")
    }

    /// One hop through `jump`, with the jump's own options: ssh <options> -W %h:%p <jump>. ssh runs it with
    /// /bin/sh after expanding % tokens, so the words are shell-quoted and the jump's own % doubled.
    static func proxyCommand(through jump: SSHHost, silent: Bool = false) -> String {
        let words = ([ssh] + config + (silent ? onePrompt : []) + connectTimeout(jump, jump: nil) + options(jump, jump: nil))
            .map { Quote.shellWord($0).replacingOccurrences(of: "%", with: "%%") }
        return (words + ["-W", "%h:%p", Quote.shellWord(jump.hostname).replacingOccurrences(of: "%", with: "%%")])
            .joined(separator: " ")
    }

    /// Through a saved HTTP proxy: AirSCP's own binary in proxy-connect mode (`ProxyConnect`). The path comes from
    /// $AIRSCP_HELPER, which the askpass environment sets (`AskpassServer.environment(for:)`, and for Terminal
    /// `terminalEnvironment`), as does the socket the helper asks the app for the proxy's address and password on.
    static func proxyCommand(_ proxy: UUID) -> String {
        "\"$AIRSCP_HELPER\" --proxy-connect \(proxy.uuidString) %h %p"
    }

    // MARK: Master connection

    /// The master: a foreground ssh holding the connection that every other command rides on. No ControlPersist
    /// (it would daemonise, and AirSCP tracks the master as its child). `silent`: an automatic reconnect, which may
    /// try one password (a saved one) and asks nothing.
    public static func master(_ host: SSHHost, jump: SSHHost?, socket: String, silent: Bool = false) -> [String] {
        [ssh, "-M", "-N"] + config + ["-o", "ControlPath=" + socket, "-o", "ControlPersist=no"]
            + connectTimeout(host, jump: jump, silent: silent)
            + ["-o", "ServerAliveInterval=\(max(0, host.serverAliveInterval))", "-o", "ServerAliveCountMax=3"]
            + (silent ? onePrompt : []) + options(host, jump: jump, silent: silent) + [host.hostname]
    }

    /// 15 s to reach a server directly. Through a jump host or a proxy, ssh's timeout would also run while the user
    /// answers the first hop's questions (its password, its host key, the proxy's password): that hop gets it instead,
    /// when it is reached directly. An automatic reconnect (`silent`) asks nothing, so it gets 30 s through them too: a
    /// server behind the jump host that never answers (frozen, paused) must not stop the reconnect schedule.
    static func connectTimeout(_ host: SSHHost, jump: SSHHost?, silent: Bool = false) -> [String] {
        jump == nil && host.proxyID == nil ? ["-o", "ConnectTimeout=15"] : silent ? ["-o", "ConnectTimeout=30"] : []
    }

    /// An automatic reconnect tries a saved password once and asks nothing (a refused prompt would be sent as an empty
    /// password, and each failed try counts against the account on the server).
    private static let onePrompt = ["-o", "NumberOfPasswordPrompts=1"]

    /// ssh -O check / exit / forward / cancel, talking to the master.
    public static func control(_ command: String, _ host: SSHHost, jump: SSHHost?, socket: String,
                               forward: [String] = []) -> [String] {
        [ssh] + config + ["-o", "ControlPath=" + socket, "-O", command] + forward + options(host, jump: jump) + [host.hostname]
    }

    /// Options for a command riding the master. BatchMode: a dead master makes ssh fall back to a fresh login,
    /// which must fail rather than prompt.
    static func mux(_ socket: String) -> [String] {
        ["-o", "ControlMaster=no", "-o", "ControlPath=" + socket, "-o", "BatchMode=yes"]
    }

    // MARK: File operations

    /// sftp reading its batch from standard input (`Quote.sftp` for the arguments). `limit`: -l, in Kbit/s (a resumed
    /// transfer under the speed limit), with fewer requests in flight (`limitedRequests`).
    public static func sftpBatch(_ host: SSHHost, jump: SSHHost?, socket: String, limit: Int? = nil) -> [String] {
        [sftp, "-b", "-"] + (limit.map { ["-l", String($0), "-R", limitedRequests] } ?? []) + config + mux(socket)
            + options(host, jump: jump) + [destination(host)]
    }

    /// Writes in flight for an upload under a speed limit. scp's and sftp's meter counts what the server has
    /// acknowledged, and behind their 64 requests it showed 0 % ("stalled") for half of a limited upload: with 8 it
    /// follows the data, at the same speed.
    static let limitedRequests = "8"

    /// ssh running `command` in the remote login shell.
    public static func remote(_ command: String, _ host: SSHHost, jump: SSHHost?, socket: String) -> [String] {
        [ssh] + config + mux(socket) + options(host, jump: jump) + [host.hostname, command]
    }

    /// The script a sentinel command runs (wrapped for `longScript`): the marker on both outputs (error output before
    /// it is login noise too), the script, its status. Run by sh whatever the login shell is (csh and fish don't know
    /// $?), so login noise (MOTD, .bashrc echo) can be told apart from the output.
    static func sentinelScript(_ script: String) -> String {
        "printf '\\n__AIRSCP__\\n'; printf '\\n__AIRSCP__\\n' >&2; " + script + "; printf '\\n__AIRSCP_RC__=%s\\n' \"$?\""
    }

    /// Error output after the marker that `sentinel` and stream scripts print (what came before it is login noise).
    public static func afterMarker(_ stderr: String) -> String {
        stderr.range(of: "\n__AIRSCP__\n").map { String(stderr[$0.upperBound...]) } ?? stderr
    }

    /// How a remote `sh` script is run: `exec sh -s` with the script as its standard input. The login shell only ever
    /// sees `exec sh -s`, never the script, so there is nothing server-supplied for it to re-parse — a non-POSIX login
    /// shell (fish, csh, tcsh) mis-reads even a correctly single-quoted name on its command line and can run commands a
    /// name contains. `sh` reads the whole script from standard input (none of these scripts read it themselves), so it
    /// is left to run as written. Returns the command and that input.
    static func longScript(_ script: String) -> (command: String, input: String?) {
        ("exec sh -s", script + "\n")
    }

    /// The output and exit status of a `sentinel` command; nil when the markers are missing (no shell).
    public static func parseSentinel(_ stdout: String) -> (output: String, status: Int32)? {
        parseSentinel(Data(stdout.utf8)).map { (String(decoding: $0.output, as: UTF8.self), $0.status) }
    }

    /// `parseSentinel` on the bytes as they came (names that aren't UTF-8 stay as they are).
    static func parseSentinel(_ stdout: Data) -> (output: Data, status: Int32)? {
        guard let start = stdout.range(of: Data("\n__AIRSCP__\n".utf8)),
              let end = stdout.range(of: Data("\n__AIRSCP_RC__=".utf8), options: .backwards,
                                     in: start.upperBound..<stdout.endIndex)
        else { return nil }
        let digits = stdout[end.upperBound...].prefix { $0 >= 0x30 && $0 <= 0x39 }
        guard let status = Int32(String(decoding: digits, as: UTF8.self)) else { return nil }
        return (stdout.subdata(in: start.upperBound..<end.lowerBound), status)
    }

    /// scp sending a local file or folder to `remotePath` (absolute; taken literally by scp, so not escaped).
    public static func upload(_ localPath: String, to remotePath: String, folder: Bool, preserveTimes: Bool,
                              _ host: SSHHost, jump: SSHHost?, socket: String, limit: Int? = nil) -> [String] {
        scpFlags(folder: folder, preserveTimes: preserveTimes, limit: limit) + (limit == nil ? [] : ["-X", "nrequests=" + limitedRequests])
            + config + mux(socket) + options(host, jump: jump) + ["--", localPath, destination(host) + ":" + remotePath]
    }

    /// scp fetching a remote file or folder into `localPath` (absolute).
    public static func download(_ remotePath: String, to localPath: String, folder: Bool, preserveTimes: Bool,
                                _ host: SSHHost, jump: SSHHost?, socket: String, limit: Int? = nil) -> [String] {
        scpFlags(folder: folder, preserveTimes: preserveTimes, limit: limit) + config + mux(socket) + options(host, jump: jump)
            + ["--", destination(host) + ":" + Quote.scpSource(remotePath), localPath]
    }

    /// `limit`: scp -l, in Kbit/s (the Transfers panel's speed limit; the tests also use it to make transfers slow).
    private static func scpFlags(folder: Bool, preserveTimes: Bool, limit: Int?) -> [String] {
        [scp] + (folder ? ["-r"] : []) + (preserveTimes ? ["-p"] : []) + (limit.map { ["-l", String($0)] } ?? [])
    }

    // MARK: Terminal

    /// ssh in Terminal: interactive, riding the master. Without askpass, so with the master down ssh asks in
    /// the terminal itself. `command` runs with a tty (-t) instead of a login shell.
    public static func terminal(_ host: SSHHost, jump: SSHHost?, socket: String, command: String? = nil) -> [String] {
        [ssh] + config + ["-o", "ControlPath=" + socket, "-o", "ControlMaster=no"] + options(host, jump: jump)
            + (command == nil ? [host.hostname] : ["-t", host.hostname, command!])
    }

    /// The remote command for "Open Terminal Here": the login shell, started in `directory` (`viaSh`).
    public static func shellIn(_ directory: String) -> String {
        viaSh("cd " + Quote.shell(directory) + " && exec \"$SHELL\" -l")
    }

    /// A POSIX sh command (with a server's names in it) as a command line that the login shell hands to sh unread: its
    /// bytes as printf's octal escapes, which sh turns back into it. A command with a terminal (ssh -t) can't come on
    /// standard input, the keyboard, as other scripts do (`longScript`), so it rides on the login shell's command line;
    /// fish, csh and tcsh mis-read POSIX quoting there (a quote, backslash, "!" or line break in a name could run
    /// commands), but this line holds only letters, digits, spaces and \ " $ ( ) in single quotes, read alike by all.
    public static func viaSh(_ command: String) -> String {
        "exec sh -c 'eval \"$(printf \"" + command.utf8.map { String(format: "\\%03o", Int($0)) }.joined() + "\")\"'"
    }

    /// The ssh command for "Copy ssh command" (a fresh connection, no master).
    public static func interactive(_ host: SSHHost, jump: SSHHost?) -> [String] {
        [ssh] + config + options(host, jump: jump) + [host.hostname]
    }

    // MARK: Keys and config

    /// ssh-keygen creating a key pair of `kind`, its private key in `format` (`Keys.PrivateFormat`); it asks for the
    /// passphrase through askpass (nothing secret in argv).
    public static func generateKey(_ kind: Keys.Kind, format: Keys.PrivateFormat, path: String, comment: String) -> [String] {
        [sshKeygen, "-t", kind.type] + (kind.bits.map { ["-b", String($0)] } ?? []) + (format.option.map { ["-m", $0] } ?? [])
            + ["-C", comment, "-f", path]
    }

    /// ssh-keygen printing a public key in another format (`Keys.PublicFormat`).
    public static func exportPublicKey(_ path: String, format: String) -> [String] {
        [sshKeygen, "-e", "-m", format, "-f", path]
    }

    /// ssh-keygen giving a key a new passphrase, asked through askpass (with its old one, if it has one), or removing
    /// it (`removing`: the empty one is the only passphrase in the command line).
    public static func changePassphrase(_ path: String, removing: Bool) -> [String] {
        [sshKeygen, "-p"] + (removing ? ["-N", ""] : []) + ["-f", path]
    }

    /// ssh-keygen printing "bits SHA256:… comment (TYPE)".
    public static func fingerprint(_ path: String) -> [String] {
        [sshKeygen, "-l", "-f", path]
    }

    /// ssh-keygen removing a host's keys from a known_hosts file ("[host]:port" for ports other than 22).
    public static func removeHostKey(_ name: String, knownHosts: String) -> [String] {
        [sshKeygen, "-R", name, "-f", knownHosts]
    }

    /// ssh-add adding a key to the agent and its passphrase to the login Keychain (a throwaway AirSCP: to the agent
    /// only, `Keychain.memoryOnly`).
    public static func addToAgent(_ path: String) -> [String] {
        [sshAdd] + (Keychain.memoryOnly ? [] : ["--apple-use-keychain"]) + [path]
    }

    /// ssh-copy-id installing a public key. `force` (-f) when the host already logs in with a key file: ssh-copy-id's
    /// "already installed?" probe would log in with that key and wrongly skip the new one.
    public static func copyID(_ publicKey: String, _ host: SSHHost, jump: SSHHost?) -> [String] {
        let force = host.auth == .keyFile || host.extraOptions.contains { $0.lowercased().hasPrefix("identityfile") }
        return [sshCopyID] + (force ? ["-f"] : []) + ["-i", publicKey] + config + options(host, jump: jump) + [host.hostname]
    }

    /// ssh -G: the settings ssh would use for the host.
    public static func resolve(_ host: SSHHost, jump: SSHHost?) -> [String] {
        [ssh, "-G"] + config + options(host, jump: jump) + [host.hostname]
    }

    // MARK: Helpers

    /// -F with the test seam's config, and IdentityFile=none: whatever that config says, ssh would otherwise offer the
    /// default key files of the real ~/.ssh (id_rsa, id_ed25519…) to every host without a key of its own. A host's
    /// own key file (-o IdentityFile) still applies: ssh adds each IdentityFile to a list, and skips "none".
    static var config: [String] { configFile.map { ["-F", $0, "-o", "IdentityFile=none"] } ?? [] }

    /// `argv` with the tools' debug output on (-vv) for the debug log (`Runner`): ssh, scp and sftp, and the ssh of a jump
    /// host's ProxyCommand. It goes before the first -F or -o, so that the tools' own flags (ssh -M -N, scp -r) stay first.
    static func verbose(_ argv: [String]) -> [String] {
        guard let tool = argv.first, [ssh, scp, sftp].contains(tool) else { return argv }
        let jump = "ProxyCommand=" + ssh + " "
        var result = argv.map { $0.hasPrefix(jump) ? jump + "-vv " + $0.dropFirst(jump.count) : $0 }
        result.insert("-vv", at: result.firstIndex { $0 == "-F" || $0 == "-o" } ?? 1)
        return result
    }

    /// The host for scp and sftp operands: IPv6 addresses in brackets.
    static func destination(_ host: SSHHost) -> String {
        host.hostname.contains(":") && !host.hostname.hasPrefix("[") ? "[\(host.hostname)]" : host.hostname
    }
}
