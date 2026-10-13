import Foundation

/// Ask AirSCP and Explain: a language model on this Mac (Apple Intelligence's, `AppleAssistant` in the
/// app) answers questions about AirSCP and the host in front of the user, from a short summary of it that never holds
/// a secret. The protocol lets tests use a stand-in.
public protocol Assistant: Sendable {
    /// The model's answer to `question`, told `instructions` and `context` first.
    func answer(_ question: String, instructions: String, context: String) async throws -> String
    /// The model's output for `prompt` in the shape of `schema`, as JSON (guided generation): a plan of steps, or one
    /// value for a field.
    func generate(_ prompt: String, instructions: String, schema: AssistantOutput) async throws -> String
}

/// The shapes `Assistant.generate` produces. The app turns them into the model's schemas (`DynamicGenerationSchema`:
/// the Command Line Tools have no `@Generable` macro).
public enum AssistantOutput: Equatable, Sendable {
    /// `{"steps": [AssistantPlan.Step]}`, at most `AssistantPlan.limit` steps.
    case plan
    /// `{"value": "…"}`, for one field of AirSCP's (Suggest…).
    case value(SuggestField)
}

/// The fields Suggest… fills in from a sentence.
public enum SuggestField: String, CaseIterable, Sendable {
    /// The host editor's Other options: ssh `Key=Value` lines.
    case otherOptions
    /// Leave out: names or patterns, separated by commas.
    case leaveOut
    /// Find Files' name pattern.
    case findPattern
    /// The Permissions sheet's octal mode.
    case mode

    /// What the model is asked to write, with the sentence it gets.
    public func prompt(_ sentence: String) -> String {
        let what: String
        switch self {
        case .otherOptions:
            what = "OpenSSH client options, one per line as Key=Value, that do what the user describes. Only real "
                + "ssh_config option names. Examples: \"keep the connection alive through a firewall\" → ServerAliveInterval=30; "
                + "\"compress the traffic\" → Compression=yes; \"give up after 10 seconds\" → ConnectTimeout=10."
        case .leaveOut:
            what = "the names or shell patterns (* and ?) of files and folders to leave out of a copy, separated by commas, "
                + "for what the user describes. Examples: \"skip git folders and build output\" → .git, build, dist; "
                + "\"no logs or temporary files\" → *.log, *.tmp; \"without node modules\" → node_modules."
        case .findPattern:
            what = "one file-name pattern with * and ? that matches the files the user describes. Names only, no folders. "
                + "Examples: \"PDF files\" → *.pdf; \"last year's reports\" → report-2025*; \"any backup\" → *.bak."
        case .mode:
            what = "a Unix permission mode as 3 octal digits: owner, group, others; each digit adds 4 for read, 2 for write "
                + "and 1 for execute (run). Examples: \"everyone can read, only I can write\" → 644; \"only I can read and "
                + "write\" → 600; \"a script everyone can run, only I can change\" → 755; \"a script only I can run\" → 700; "
                + "\"a folder my group can change too\" → 775."
        }
        return "Write \(what)\n\nThe user says: \(DebugLog.redacted(String(sentence.prefix(500))))"
    }

    /// Why `value` can't go into the field as it is, or nil.
    public func problem(_ value: String) -> String? {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return "The suggestion is empty." }
        switch self {
        case .mode:
            return text.range(of: "^[0-7]{3,4}$", options: .regularExpression) == nil ? "“\(text)” isn't a mode (3 or 4 digits, 0 to 7)." : nil
        case .findPattern:
            return text.contains("/") || text.contains("\n") ? "A name pattern has no folders and fits on one line." : nil
        case .leaveOut:
            return text.contains("\n") ? "Leave out fits on one line: names separated by commas." : nil
        case .otherOptions:
            let bad = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
                .filter {
                    !$0.isEmpty && $0.range(of: "^[A-Za-z][A-Za-z0-9]*\\s*=\\s*\\S", options: .regularExpression) == nil
                        && $0.range(of: "^[A-Z][A-Za-z0-9]*\\s+\\S+$", options: .regularExpression) == nil
                }
            return bad.first.map { "“\($0)” isn't an ssh option line (Key=Value)." }
        }
    }
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

/// Ask AirSCP's Do It…: a request in plain words, planned by the model as steps over AirSCP's actions,
/// shown as sentences, and run only when the user clicks Run.
public struct AssistantPlan: Codable, Equatable, Sendable {
    public struct Step: Codable, Equatable, Sendable {
        public var action: String
        public var host: String?
        public var desktop: String?
        public var snippet: String?
        /// The tunnel's listening port on this Mac, e.g. "8080".
        public var tunnel: String?
        public var localPaths: [String]?
        public var remotePaths: [String]?
        public var folder: String?
        public var pattern: String?
        public var leaveOut: [String]?
        public var on: Bool?

        public init(action: String, host: String? = nil, desktop: String? = nil, snippet: String? = nil, tunnel: String? = nil,
                    localPaths: [String]? = nil, remotePaths: [String]? = nil, folder: String? = nil, pattern: String? = nil,
                    leaveOut: [String]? = nil, on: Bool? = nil) {
            self.action = action
            self.host = host
            self.desktop = desktop
            self.snippet = snippet
            self.tunnel = tunnel
            self.localPaths = localPaths
            self.remotePaths = remotePaths
            self.folder = folder
            self.pattern = pattern
            self.leaveOut = leaveOut
            self.on = on
        }
    }

    public var steps: [Step]

    public init(steps: [Step]) { self.steps = steps }

    /// What a plan may do: the actions App Intents and Ask share (`AirSCPActions`), nothing else.
    public static let actions = ["connect", "openShell", "openDesktop", "disconnectAll", "upload", "download", "find",
                                 "runSnippet", "setTunnel", "transferStatus"]
    public static let limit = 5

    /// The model's JSON, `{"steps": […]}`, tidied: empty fields count as unsaid, a step without a host takes the one
    /// before it, and a connect right before another step on the same host goes (every action connects by itself).
    public static func decode(_ json: String) throws -> AssistantPlan {
        let plan: AssistantPlan
        do {
            plan = try JSONDecoder().decode(AssistantPlan.self, from: Data(json.utf8))
        } catch {
            throw AirSCPError(.other, "Apple Intelligence gave a plan AirSCP can't read. Try saying it another way.")
        }
        func text(_ value: String?) -> String? { value.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } }
        func list(_ value: [String]?) -> [String]? {
            let items = value?.compactMap(text) ?? []
            return items.isEmpty ? nil : items
        }
        let hostActions: Set<String> = ["connect", "openShell", "upload", "download", "find", "runSnippet", "setTunnel"]
        var steps: [Step] = []
        var lastHost: String?
        for var step in plan.steps {
            step.host = text(step.host)
            step.desktop = text(step.desktop)
            step.snippet = text(step.snippet)
            step.tunnel = text(step.tunnel)
            step.folder = text(step.folder)
            step.pattern = text(step.pattern)
            step.localPaths = list(step.localPaths)
            step.remotePaths = list(step.remotePaths)
            step.leaveOut = list(step.leaveOut)
            if hostActions.contains(step.action) {
                if step.host == nil { step.host = lastHost }
                lastHost = step.host
            }
            if let previous = steps.last, previous.action == "connect", hostActions.contains(step.action),
               step.action != "connect", previous.host == step.host {
                steps.removeLast()
            }
            // Once is enough for what has no host (the model repeats Disconnect All with a host each time).
            if ["disconnectAll", "transferStatus"].contains(step.action), steps.contains(where: { $0.action == step.action }) { continue }
            if steps.last != step { steps.append(step) }
        }
        return AssistantPlan(steps: steps)
    }

    /// A step with the saved items it names, and the sentence the user reads (or why it can't run).
    public struct Resolved: Equatable, Sendable {
        public var step: Step
        public var sentence: String
        public var problem: String?
        public var hostID: UUID?
        public var desktopID: UUID?
        public var snippetID: UUID?
        public var tunnelID: UUID?
    }

    /// Each step with the saved hosts, desktops, snippets and tunnels it names (exact name, then any case, then the
    /// one name that starts so); past `limit`, steps can't run.
    public func resolve(in data: AirSCPData) -> [Resolved] {
        steps.enumerated().map { index, step in
            var resolved = Self.resolve(step, in: data)
            if index >= Self.limit, resolved.problem == nil {
                resolved.problem = "AirSCP runs at most \(Self.limit) steps at a time."
            }
            return resolved
        }
    }

    static func resolve(_ step: Step, in data: AirSCPData) -> Resolved {
        var result = Resolved(step: step, sentence: "", problem: nil)
        func pick<T>(_ name: String?, _ items: [T], _ names: (T) -> [String], kind: String) -> T? {
            guard let name = name?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
                if result.problem == nil { result.problem = "Say which \(kind)." }
                return nil
            }
            let lower = name.lowercased()
            for rule in [{ (n: String) in n == name }, { (n: String) in n.lowercased() == lower }] {
                let found = items.filter { names($0).contains(where: rule) }
                if found.count == 1 { return found[0] }
            }
            let prefixed = items.filter { names($0).contains { $0.lowercased().hasPrefix(lower) } }
            if prefixed.count == 1 { return prefixed[0] }
            if result.problem == nil {
                result.problem = prefixed.count > 1 ? "More than one \(kind) is called “\(name)…”: say which."
                    : "AirSCP has no \(kind) called “\(name)”."
            }
            return nil
        }
        func hostNames(_ host: SSHHost) -> [String] { [host.displayName, host.label, host.hostname].filter { !$0.isEmpty } }
        func list(_ items: [String]?) -> String {
            let items = items ?? []
            return items.count <= 2 ? items.joined(separator: " and ") : "\(items[0]) and \(items.count - 1) more"
        }
        let needsHost = ["connect", "openShell", "upload", "download", "find", "runSnippet", "setTunnel"].contains(step.action)
        let host = needsHost ? pick(step.host, data.hosts, hostNames, kind: "host") : nil
        result.hostID = host?.id
        let name = host?.displayName ?? step.host ?? "?"
        switch step.action {
        case "connect": result.sentence = "Connect to \(name)"
        case "openShell": result.sentence = "Open a shell on \(name)"
        case "openDesktop":
            let desktop = pick(step.desktop, data.rdpEntries, { [$0.displayName, $0.hostname] }, kind: "Remote Desktop")
            result.desktopID = desktop?.id
            result.sentence = "Open the Remote Desktop \(desktop?.displayName ?? step.desktop ?? "?")"
        case "disconnectAll": result.sentence = "Disconnect everything"
        case "transferStatus": result.sentence = "Say how the transfers are going"
        case "upload":
            if (step.localPaths ?? []).isEmpty, result.problem == nil { result.problem = "Say which files to upload." }
            let leaving = (step.leaveOut ?? []).isEmpty ? "" : ", leaving out " + (step.leaveOut ?? []).joined(separator: ", ")
            result.sentence = "Upload \(list(step.localPaths)) to \(name)"
                + (step.folder.map { " in \($0)" } ?? " in the folder its pane shows") + leaving
        case "download":
            if (step.remotePaths ?? []).isEmpty, result.problem == nil { result.problem = "Say which files to download." }
            result.sentence = "Download \(list(step.remotePaths)) from \(name) to " + (step.folder ?? "your download folder")
        case "find":
            if (step.pattern ?? "").isEmpty, result.problem == nil { result.problem = "Say what to look for." }
            result.sentence = "Find “\(step.pattern ?? "")” in \(step.folder ?? "the home folder") on \(name)"
        case "runSnippet":
            let snippet = pick(step.snippet, data.snippets, { [$0.name] }, kind: "snippet")
            result.snippetID = snippet?.id
            result.sentence = "Run the snippet “\(snippet?.name ?? step.snippet ?? "?")” on \(name)"
        case "setTunnel":
            // The port: the last number in it ("8080", "port 8080", "web-01 port 8080").
            let port = step.tunnel.flatMap { tunnel in
                tunnel.split(whereSeparator: { !$0.isNumber }).last.map(String.init)
            } ?? ""
            let tunnel = host?.tunnels.first { String($0.listenPort) == port }
            if host != nil, tunnel == nil, result.problem == nil {
                result.problem = port.isEmpty ? "Say which tunnel (its port)." : "\(name) has no tunnel on port \(port)."
            }
            result.tunnelID = tunnel?.id
            result.sentence = "Switch \(step.on == false ? "off" : "on") the tunnel on port \(port.isEmpty ? "?" : port) of \(name)"
        default:
            result.sentence = "“\(step.action)”"
            result.problem = "AirSCP can't do “\(step.action)”."
        }
        return result
    }
}

extension AssistantContext {
    /// What Do It… tells the model it is and what it may do.
    public static let planInstructions = """
        You turn a request for AirSCP, a Mac app for SSH servers, into the fewest steps that do exactly what it asks, at \
        most 5. Actions: connect (host), openShell (host), openDesktop (desktop), disconnectAll, upload (host, \
        localPaths: Mac paths, folder: the server folder, leaveOut: names to skip), download (host, remotePaths, folder: \
        a Mac folder), find (host, folder, pattern like *.log), runSnippet (snippet, host), setTunnel (host, tunnel: its \
        port number only, on: true or false), transferStatus. Rules: every action connects by itself, so never add a \
        connect step before another action; give each step its own host; never add a step the request didn't ask for \
        (no disconnectAll, openDesktop or transferStatus unless asked); leave a field out rather than empty; use only \
        names from the saved items listed; never invent hosts, paths or passwords; if the request isn't for these \
        actions, return no steps. Examples: "open a shell on db" → [openShell host db]; "upload ~/site to web in \
        /var/www, skip .git" → [upload host web, localPaths ["~/site"], folder /var/www, leaveOut [".git"]]; "start the \
        8080 tunnel on web and find logs in /var/log there" → [setTunnel host web tunnel 8080 on true, find host web \
        folder /var/log pattern *.log].
        """

    /// What Suggest… tells the model.
    public static let suggestInstructions = """
        You fill in one field of AirSCP, a Mac app for SSH servers, from what the user says. Write only the value, \
        nothing else. Never include a password, passphrase or key.
        """

    /// The names of the saved hosts (with their addresses), Remote Desktops, snippets and tunnels, for Do It…: no
    /// passwords, keys or commands' output; at most `limit` characters.
    public static func inventory(_ data: AirSCPData, limit: Int = 2000) -> String {
        // One item a line: redaction takes out a whole line that holds a secret, and only that item then.
        var lines = data.hosts.map { host in
            "Host: \(host.displayName) (\(host.username.isEmpty ? "" : host.username + "@")\(host.hostname))"
        }
        lines += data.rdpEntries.map { "Remote Desktop: \($0.displayName)" }
        lines += data.snippets.map { "Snippet: \($0.name)" }
        lines += data.hosts.flatMap { host in host.tunnels.map { "Tunnel: \(host.displayName) port \($0.listenPort)" } }
        var text = DebugLog.redacted(lines.joined(separator: "\n"))
        if text.count > limit { text = String(text.prefix(limit)) + "…" }
        return text.isEmpty ? "Nothing is saved in AirSCP yet." : text
    }

    /// The question Explain asks about the Monitor's readings.
    public static func explainMonitor(_ readings: String) -> String {
        "These are the server's readings in AirSCP's Monitor. Is anything wrong or close to a limit, and what should I "
            + "look at?\n\n" + DebugLog.redacted(String(readings.prefix(2500)))
    }

    /// The question Summarize asks about the command log: its last 50 command lines.
    public static func summarizeLog(_ commands: [String]) -> String {
        "These are the last commands AirSCP ran for this host. Say in a few lines what it did and whether anything "
            + "failed.\n\n" + DebugLog.redacted(commands.suffix(50).joined(separator: "\n"))
    }

    /// The question Explain asks about a snippet before it runs.
    public static func explainCommand(_ command: String) -> String {
        "What does this shell command do, step by step, and is anything in it risky to run on a server?\n\n"
            + DebugLog.redacted(String(command.prefix(2000)))
    }
}
