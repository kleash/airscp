import Foundation

/// The user's ~/.ssh/config: alias names for importing, and `ssh -G` for what ssh will actually use.
/// AirSCP runs ssh with the user's normal config, so imported aliases keep working; it never writes the file.
public enum SSHConfig {
    /// What `ssh -G` resolved for a host.
    public struct Resolved: Equatable {
        public var hostname: String
        public var user: String
        public var port: Int
        /// HostKeyAlias, when set: known_hosts lists the key under it.
        public var hostKeyAlias: String?
        /// UserKnownHostsFile entries, the first being where ssh adds keys.
        public var knownHostsFiles: [String]
        public var proxyJump: String?
        public var proxyCommand: String?
    }

    /// The names on the `Host` lines of an ssh_config text, minus patterns (`*`, `?`, `!`), in order; with `folder` (the
    /// ssh folder, where relative paths start) also those of the files its `Include` lines name, as ssh reads them.
    public static func aliases(in text: String, folder: String? = nil) -> [String] {
        var names: [String] = []
        collect(text, folder: folder, depth: 0, into: &names)
        return names
    }

    private static func collect(_ text: String, folder: String?, depth: Int, into names: inout [String]) {
        for line in text.components(separatedBy: .newlines) {
            if let folder, depth < 16,  // ssh's own limit on nested Includes
               let match = line.range(of: #"^\s*Include(\s*=\s*|\s+)"#, options: [.regularExpression, .caseInsensitive]) {
                let rest = line[match.upperBound...].components(separatedBy: "#").first ?? ""
                for word in rest.split(whereSeparator: { $0.isWhitespace }) {
                    var pattern = (word.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) as NSString).expandingTildeInPath
                    if !pattern.hasPrefix("/") { pattern = folder + "/" + pattern }
                    for path in files(matching: pattern) {
                        if let included = try? String(contentsOfFile: path, encoding: .utf8) {
                            collect(included, folder: folder, depth: depth + 1, into: &names)
                        }
                    }
                }
                continue
            }
            guard let match = line.range(of: #"^\s*Host(\s*=\s*|\s+)"#, options: [.regularExpression, .caseInsensitive])
            else { continue }
            let rest = line[match.upperBound...].components(separatedBy: "#").first ?? ""
            for name in rest.split(whereSeparator: { $0.isWhitespace }).map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) })
            where !name.isEmpty && !name.contains(where: { "*?!".contains($0) }) && !names.contains(name) {
                names.append(name)
            }
        }
    }

    /// The paths a glob pattern matches (Include takes them), in order.
    private static func files(matching pattern: String) -> [String] {
        var found = glob_t()
        defer { globfree(&found) }
        guard glob(pattern, 0, nil, &found) == 0 else { return [] }
        return (0..<Int(found.gl_matchc)).compactMap { found.gl_pathv[$0].map { String(cString: $0) } }
    }

    /// What ssh will use for an alias or a saved host (`ssh -G`), nil when ssh fails.
    public static func resolve(_ host: SSHHost, jump: SSHHost? = nil, log: ((LogEntry) -> Void)? = nil) async -> Resolved? {
        let result = await Runner.run(OpenSSH.resolve(host, jump: jump), hostID: host.id, log: log)
        guard result.status == 0 else { return nil }
        return parse(result.output)
    }

    // MARK: A host's Other options (the host editor, PLAN.md U.3)

    /// Why AirSCP refuses `line` in a host's Other options, or nil. AirSCP runs the connection itself (a master it
    /// keeps as its child, commands with their own output markers), so options that change that would break it; a
    /// ProxyCommand or ProxyJump of a host that already goes through a jump host or an HTTP proxy (`routed`) would be
    /// ignored (ssh takes the first value it is given, and AirSCP's comes first).
    public static func refusal(_ line: String, routed: Bool) -> String? {
        let name = optionName(line)
        switch name.lowercased() {
        case "controlmaster", "controlpath", "controlpersist":
            return "\(name) can't be changed: AirSCP keeps one shared connection per host itself."
        case "remotecommand", "requesttty", "sessiontype", "stdinnull", "forkafterauthentication":
            return "\(name) would change how AirSCP's own commands run on the server, so they would fail."
        case "proxycommand" where routed, "proxyjump" where routed:
            return "\(name) would be ignored: this host already goes through “Connect through” or an HTTP proxy."
        case "stricthostkeychecking":
            return "Choose this with “Server key” above, so the sidebar can show when checks are off."
        default:
            return nil
        }
    }

    /// Whether an Other options line runs a program on this Mac when the host connects (a command, or a library ssh
    /// loads): a hosts file from elsewhere keeps such lines only when the user says so.
    public static func runsCommandHere(_ line: String) -> Bool {
        ["proxycommand", "localcommand", "knownhostscommand", "pkcs11provider", "securitykeyprovider", "xauthlocation"]
            .contains(optionName(line).lowercased())
    }

    /// The option's name: "Compression" in "Compression=yes" or "Compression yes".
    static func optionName(_ line: String) -> String {
        String(line.trimmingCharacters(in: .whitespaces).prefix { !$0.isWhitespace && $0 != "=" })
    }

    /// What ssh says is wrong with one Other options line (`ssh -G`, which connects nowhere; the user's ssh_config
    /// isn't read), or nil when ssh takes it.
    public static func check(_ line: String) async -> String? {
        let result = await Runner.run([OpenSSH.ssh, "-G", "-F", "/dev/null", "-o", line, "airscp-check"])
        guard result.status != 0 else { return nil }
        // "command-line: line 0: Bad configuration option: bogus", "command-line line 0: invalid time value."
        // ssh ends its lines with "\r\n" there.
        var reason = result.stderr.components(separatedBy: .newlines).first { !$0.isEmpty } ?? ""
        if let range = reason.range(of: #"^command-line:? line [0-9]+: "#, options: .regularExpression) {
            reason.removeSubrange(range)
        }
        if reason.hasPrefix("Bad configuration option: ") { return "ssh has no option called “\(optionName(line))”." }
        reason = reason.prefix(1).uppercased() + reason.dropFirst()
        return reason.isEmpty ? "ssh doesn't take this line." : reason + (reason.hasSuffix(".") ? "" : ".")
    }

    /// Parses `ssh -G` output (lowercase "key value" lines).
    public static func parse(_ output: String) -> Resolved? {
        var values: [String: [String]] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2 else { continue }
            values[String(parts[0]), default: []].append(String(parts[1]))
        }
        guard let hostname = values["hostname"]?.first else { return nil }
        let files = (values["userknownhostsfile"] ?? []).flatMap { $0.split(separator: " ").map(String.init) }
        func optional(_ key: String) -> String? {
            values[key]?.first.flatMap { $0 == "none" ? nil : $0 }
        }
        return Resolved(hostname: hostname, user: values["user"]?.first ?? "",
                        port: values["port"]?.first.flatMap { Int($0) } ?? 22, hostKeyAlias: optional("hostkeyalias"),
                        knownHostsFiles: files.map { ($0 as NSString).expandingTildeInPath },
                        proxyJump: optional("proxyjump"), proxyCommand: optional("proxycommand"))
    }
}
