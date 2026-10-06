import Darwin
import Foundation

/// The agent side of agent control (PLAN.md T): `AirSCP --mcp` speaks MCP over stdio (newline-delimited JSON-RPC 2.0)
/// and `AirSCP --agent <tool> [json] [--out shot.png]` runs one tool from a shell. Both send each tool call to the
/// running app's agent socket (`<support dir>/agent/sock`, with the token from `agent/token`) and pass its reply on:
/// the app already answers in MCP's tool-result shape, `{content: [{type: text|image, …}], isError}`.
/// The tool list lives here, so that an MCP client sees the tools even when AirSCP starts after it.
public enum AgentBridge {
    /// `<support dir>/agent` (0700): the socket and the token file. AIRSCP_SUPPORT_DIR gives each instance its own.
    public static var directory: URL { Store.directory.appendingPathComponent("agent", isDirectory: true) }
    static let offMessage = "AirSCP isn't running, or agent control is off (AirSCP ▸ Settings ▸ Allow AI agents to control AirSCP)."
    static let busyMessage = "AirSCP didn't answer: it may be busy with many calls at once, or quitting. Check with snapshot, "
        + "then try again."

    /// The MCP tools: name, description and input schema. The app answers each of these names.
    public static let tools: [[String: Any]] = [
        tool("snapshot", "AirSCP's state as JSON: windows, sidebar (hosts, groups, connected, RDP, proxies), the selection, "
             + "the workspace (tab, banner), both file panes (folder, rows, selection, sort), transfers, open sheets with "
             + "their fields and buttons, the RDP session, and while their sheet is open Find Files' results (find) and "
             + "Synchronize's plan (sync). On request also the command log, monitor, menus (with why an item is "
             + "disabled), elements (every control with id, role, title, value and frame; with in: of another window, "
             + "such as Keys), settings.",
             ["include": array("Sections: sidebar, workspace, panes, transfers, log, monitor, rdp, sheets, find, sync, menus, "
                               + "elements, settings"),
              "rows": integer("Rows per pane (default 200)"), "log": integer("Command log entries (default 20)"),
              "in": string("window:<title> | sheet: whose elements (default: the main window)")]),
        tool("screenshot", "A PNG of an AirSCP window as the user sees it, drawn by AirSCP itself (sheets and panels "
             + "composited, the Remote Desktop included). target: main (default), sheet, window:<title>, element:<id>, "
             + "or rdp (the Windows desktop at its full pixel size). Coordinates in the image at scale 1 are the "
             + "click tool's.",
             ["target": string("main | sheet | rdp | window:<title> | element:<id>"), "scale": integer("1 (points, default) or 2")]),
        tool("menu", "Choose a menu-bar item by its path, e.g. \"Host > Connect\", \"File > New Folder…\", or a "
             + "context menu: \"context > Rename…\" (a file pane's, for its selected rows; pane=transfers: the Transfers "
             + "panel's, for its selected jobs). A disabled item is refused with its reason. in: the window whose command "
             + "it is (as if it were in front), e.g. File > Close for an editor window. file / files: what an Open or Save "
             + "panel the command opens chooses (Export Hosts…, Import Hosts…, Upload…), instead of showing it.",
             ["path": string("Menu path"), "pane": string("left | right | transfers (for context)"),
              "in": string("window:<title> | sheet (default: the main window)"), "file": string("A Mac path for its panel"),
              "files": array("Mac paths for its panel")], required: ["path"]),
        tool("press", "Press a button, checkbox, tab or segment by its id or title, in the frontmost sheet or alert, "
             + "else the main window. file / files: what an Open or Save panel it opens chooses (Choose…, Other Key File…, "
             + "Paste Items to Mac…), instead of showing it.",
             ["id": string("Accessibility id"), "title": string("Button title"), "in": string("sheet | window:<title>"),
              "file": string("A Mac path for its panel"), "files": array("Mac paths for its panel")]),
        tool("set", "Set a field: text or password field, checkbox (true/false), pop-up menu or segmented control "
             + "(by option title). Find it by id, label, title or placeholder. file: what a panel the choice opens takes "
             + "(Log in with ▸ Other Key File…).",
             ["id": string("Accessibility id"), "title": string("Label, title or placeholder"), "value": any("New value"),
              "in": string("sheet | window:<title>"), "file": string("A Mac path for its panel")], required: ["value"]),
        tool("key", "Press keys, e.g. \"cmd+shift+n\", \"return\", \"escape\", \"down\", \"cmd+v\". target: window "
             + "(default: the frontmost sheet, else the main window, or the window named by in) or rdp (the Windows desktop).",
             ["combo": string("Key combination"), "target": string("window | rdp"), "in": string("window:<title> | sheet")],
             required: ["combo"]),
        tool("type", "Type text into the focused field (or the Windows desktop with target rdp).",
             ["text": string("Text"), "target": string("window | rdp"), "in": string("window:<title> | sheet")], required: ["text"]),
        tool("click", "Click at x, y: points from the top left of the main window (or the window named by in), as in a "
             + "screenshot of it at scale 1. On the Windows desktop the pointer rests there first; wheel turns the mouse "
             + "wheel there instead of clicking (notches, up when positive).",
             ["x": number("X"), "y": number("Y"), "button": string("left | right"), "count": integer("2 for a double-click"),
              "modifiers": string("e.g. cmd+shift"), "wheel": integer("Wheel notches on the Windows desktop (up > 0)"),
              "in": string("window:<title>")], required: ["x", "y"]),
        tool("focus", "Give the keyboard focus to a file pane (pane: left|right, so that menu commands act on it) or to "
             + "target: sidebar | filter | path | desktop.", ["pane": string("left | right"),
                                                             "target": string("sidebar | filter | path | desktop")]),
        tool("select", "Select rows: pane left|right (file names, exactly; also focuses the pane), sidebar (a host or "
             + "Remote Desktop name), processes (a process name, PID or part of its command, among those the Monitor "
             + "lists with its search), transfers (a job's name, or ids from snapshot); or, with in, a list in that window "
             + "or sheet (keys, snippets, proxies, Find Files' results: rows containing the text).",
             ["pane": string("left | right | sidebar | processes | transfers"), "names": array("Names"),
              "ids": array("Transfer job ids"), "all": boolean("Select all"), "none": boolean("Select nothing"),
              "in": string("window:<title> | sheet")]),
        tool("sort", "Sort a file pane by a column (name, size, modified, permissions, owner, group, kind), or the "
             + "Monitor's processes (pane processes: pid, user, cpu, mem, memory, time, state, command).",
             ["pane": string("left | right | processes"), "column": string("Column"),
              "ascending": boolean("Ascending (default true)")], required: ["pane", "column"]),
        tool("drop", "Drop files as a drag would: files (Mac paths) onto pane left|right, target desktop (the RDP "
             + "shared folder) or target keys (the Keys window: Import Key for a PuTTY .ppk); or the selected rows from: "
             + "left|right to: left|right|local:<Mac folder> (Download To…)|finder:<Mac folder> (a drag into Finder: no "
             + "questions). Conflicts and folder questions appear as sheets.",
             ["files": array("Mac paths"), "pane": string("left | right"), "target": string("desktop | keys"),
              "from": string("left | right"), "to": string("left | right | local:<dir> | finder:<dir>"),
              "into": string("Folder (default: the pane's)"),
              "move": boolean("Move within a server instead of copying")]),
        tool("wait", "Wait (polling, no sleeping needed) until: connected | disconnected (host), sheet | no_sheet, listed "
             + "(pane, optional path or text = a row name), transfers_done, rdp_connected, rdp_drawn (the desktop shows a "
             + "picture), text (anywhere in the snapshot or AirSCP's other windows), monitor (the Monitor has read the "
             + "server; with text, a process with it in its name or command), found (Find Files' search ended), compared "
             + "(Synchronize's comparison ended). Returns the matching state; on timeout an error with the current state.",
             ["until": string("Condition"), "host": string("Host or desktop name (default: the selected one)"),
              "pane": string("left | right"), "path": string("Folder"), "text": string("Text"),
              "timeout": number("Seconds (default 30)")], required: ["until"]),
        tool("guide", "How to drive AirSCP: the loop, every tool with an example, and a recipe per feature. topic: "
             + guideTopics.joined(separator: ", ") + " (none: the overview). Works even when AirSCP isn't running.",
             ["topic": string("Topic")]),
    ]

    // MARK: The guide

    /// Resources/AgentGuide.md: in the app bundle, else (a development build) next to the sources.
    public static let guideText: String = {
        let bundled = Bundle.main.url(forResource: "AgentGuide", withExtension: "md")
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/AgentGuide.md")
        return [bundled, source].compactMap { $0 }.lazy.compactMap { try? String(contentsOf: $0, encoding: .utf8) }.first
            ?? "# AirSCP agent guide\n\n## overview\nThe guide is missing from this AirSCP build. Start with snapshot.\n"
    }()

    static let guideTopics = ["overview", "tools", "hosts", "proxies", "transfers", "files", "monitor", "tunnels", "keys",
                              "settings", "rdp", "troubleshooting"]

    /// The guide's sections by topic ("" is the introduction before the first one).
    static var guideSections: [String: String] {
        var sections: [String: String] = [:], topic = ""
        for line in guideText.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                topic = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("# ") { continue }
            sections[topic, default: ""] += line + "\n"
        }
        return sections.mapValues { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// MCP's `instructions`: the introduction and the overview.
    static var instructions: String {
        (guideSections[""] ?? "") + "\n\n" + (guideSections["overview"] ?? "")
    }

    /// The guide tool: a topic's section, or the overview.
    static func guide(_ topic: String?) -> [String: Any] {
        let sections = guideSections
        guard let topic, !topic.isEmpty, topic != "overview" else {
            return text(instructions + "\n\nTopics (guide topic=…): " + guideTopics.joined(separator: ", "))
        }
        guard let section = sections[topic.lowercased()] else {
            return failure("No topic “\(topic)”. Topics: " + guideTopics.joined(separator: ", "))
        }
        return text("## \(topic.lowercased())\n" + section)
    }

    private static func text(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": false]
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any],
                             required: [String] = []) -> [String: Any] {
        ["name": name, "description": description,
         "inputSchema": ["type": "object", "properties": properties, "required": required] as [String: Any]]
    }
    private static func string(_ text: String) -> [String: Any] { ["type": "string", "description": text] }
    private static func integer(_ text: String) -> [String: Any] { ["type": "integer", "description": text] }
    private static func number(_ text: String) -> [String: Any] { ["type": "number", "description": text] }
    private static func boolean(_ text: String) -> [String: Any] { ["type": "boolean", "description": text] }
    private static func any(_ text: String) -> [String: Any] { ["description": text] }
    private static func array(_ text: String) -> [String: Any] { ["type": "array", "items": ["type": "string"], "description": text] }

    /// Who drives AirSCP, as the app's indicator names it: the MCP client's name and version from `initialize`
    /// ("claude-code 2.1.0"), or "AirSCP --agent" for the command line.
    private static var client = "an MCP client"
    private static let clientLock = NSLock()

    /// One tool call to the running app, as an MCP tool result.
    public static func call(_ tool: String, _ arguments: [String: Any]) -> [String: Any] {
        if tool == "guide" { return guide(arguments["topic"] as? String) }
        let path = directory.path
        if let problem = socketPathProblem(path + "/sock") { return failure(problem) }  // the app can't listen there either
        guard let token = try? String(contentsOfFile: path + "/token", encoding: .utf8) else { return failure(offMessage) }
        // A bridge whose parent has gone (started by launchd, or left running) still waits for its answer: the app ends a
        // wait whose caller has gone itself.
        guard let reply = Askpass.exchange(["tool": tool, "arguments": arguments, "client": clientLock.locked { client },
                                            "token": token.trimmingCharacters(in: .whitespacesAndNewlines)],
                                           socket: path + "/sock", watchParent: false), reply["content"] != nil
        else { return failure(access(path + "/sock", F_OK) == 0 ? busyMessage : offMessage) }  // a socket: control is on
        return reply
    }

    /// An MCP tool result saying `text` went wrong.
    public static func failure(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": true]
    }

    /// The socket address for `path`, for the app's side of the socket (askpass's, which is internal to AirSCPCore).
    public static func unixAddress(_ path: String) -> sockaddr_un? { Askpass.unixAddress(path) }

    /// Why agent control can't use `socket`: a path longer than a socket's (a long AIRSCP_SUPPORT_DIR).
    public static func socketPathProblem(_ socket: String) -> String? {
        guard unixAddress(socket) == nil else { return nil }
        return "The settings folder's path is too long for the agent socket (\(socket.utf8.count) bytes; a socket's path "
            + "may have 103): use a shorter folder (AIRSCP_SUPPORT_DIR)."
    }

    // MARK: MCP

    /// `AirSCP --mcp`: answers until stdin ends. Tool calls run in parallel (a `wait` doesn't hold up a `ping`).
    public static func runMCP(input: FileHandle = .standardInput, output: FileHandle = .standardOutput) -> Int32 {
        let lock = NSLock(), group = DispatchGroup()
        func send(_ message: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
            data.append(0x0A)
            lock.locked { output.write(data) }
        }
        var buffer = Data()
        while true {
            let chunk = input.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) else { continue }
                guard let json = try? JSONSerialization.jsonObject(with: line) else {
                    send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
                    continue
                }
                guard let message = json as? [String: Any] else {  // a batch (an array): MCP has none since 2025-06-18
                    send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid Request"]])
                    continue
                }
                group.enter()
                DispatchQueue.global().async {
                    defer { group.leave() }
                    if let reply = answer(message) { send(reply) }
                }
            }
        }
        // stdin has ended: the client has gone (or piped its last request). Calls that end soon still answer; a longer one
        // (a wait) isn't waited for, and the app ends it once this process has gone.
        _ = group.wait(timeout: .now() + 5)
        return 0
    }

    /// The MCP versions this server speaks (it has tools only, which they all carry alike). The client's own is
    /// answered when it is one of them; else 2025-06-18, which every client of these years knows.
    static let protocolVersions = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"]

    /// The JSON-RPC response to one message (nil for a notification).
    static func answer(_ message: [String: Any]) -> [String: Any]? {
        guard let id = message["id"], !(id is NSNull) else { return nil }  // notifications/initialized and the like
        let params = message["params"] as? [String: Any] ?? [:]
        func result(_ value: [String: Any]) -> [String: Any] { ["jsonrpc": "2.0", "id": id, "result": value] }
        switch message["method"] as? String {
        case "initialize":
            if let info = params["clientInfo"] as? [String: Any], let name = info["name"] as? String, !name.isEmpty {
                let named = [name, info["version"] as? String].compactMap { $0 }.joined(separator: " ")
                clientLock.locked { client = String(named.prefix(80)) }
            }
            let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
            let asked = params["protocolVersion"] as? String ?? ""
            return result(["protocolVersion": protocolVersions.contains(asked) ? asked : "2025-06-18",
                           "capabilities": ["tools": [String: Any]()],
                           "serverInfo": ["name": "airscp", "version": version],
                           "instructions": instructions])
        case "ping":
            return result([:])
        case "tools/list":
            return result(["tools": tools])
        case "tools/call":
            guard let name = params["name"] as? String, schema(of: name) != nil else {
                let name = params["name"] as? String
                return ["jsonrpc": "2.0", "id": id, "error": ["code": -32602,
                                                              "message": name.map { "Unknown tool: \($0)" } ?? "tools/call needs a name"]]
            }
            return result(call(name, params["arguments"] as? [String: Any] ?? [:]))
        default:
            return ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]
        }
    }

    /// A tool's input schema properties, by argument name (nil: no such tool).
    static func schema(of tool: String) -> [String: Any]? {
        guard let entry = tools.first(where: { $0["name"] as? String == tool }) else { return nil }
        return (entry["inputSchema"] as? [String: Any])?["properties"] as? [String: Any] ?? [:]
    }

    // MARK: Command line

    /// `AirSCP --agent <tool> [key=value…] [--json] [--out shot.png]`: the tool's arguments as key=value pairs (text,
    /// except for an argument the tool takes as a number, true/false or a list: then its JSON) or one JSON object.
    /// `value=-` reads the value from standard input (a password stays off the command line, which every process on
    /// the Mac can read). Prints the text (or with --json the whole reply), writes an image to --out; exit status 1 when
    /// the tool failed.
    public static func runCLI(_ arguments: [String]) -> Int32 {
        var rest = arguments, out: String?, raw = false
        if let index = rest.firstIndex(of: "--out"), index + 1 < rest.count {
            out = rest[index + 1]
            rest.removeSubrange(index...index + 1)
        }
        if let index = rest.firstIndex(of: "--json") {
            raw = true
            rest.remove(at: index)
        }
        guard let name = rest.first, !name.hasPrefix("-") else {
            print("usage: AirSCP --agent <tool> [key=value …] [--json] [--out image.png]\n"
                  + "  e.g. AirSCP --agent menu path='Host > Connect'; AirSCP --agent screenshot --out shot.png\ntools:")
            for tool in tools { print("  \(tool["name"]!): \(tool["description"]!)") }
            return 2
        }
        var parameters: [String: Any] = [:]
        let schema = Self.schema(of: name) ?? [:]
        for word in rest.dropFirst() {
            if word.hasPrefix("{"), let object = try? JSONSerialization.jsonObject(with: Data(word.utf8)) as? [String: Any] {
                parameters.merge(object) { $1 }
            } else if let equals = word.firstIndex(of: "=") {
                let key = String(word[..<equals]), value = String(word[word.index(after: equals)...])
                // value=1.10 or text=42 stay text: only arguments typed otherwise (timeout=5, names=[…]) are read as JSON.
                let typed = ((schema[key] as? [String: Any])?["type"] as? String).map { $0 != "string" } ?? false
                parameters[key] = (typed ? try? JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed) : nil)
                    .flatMap { $0 is String ? nil : $0 } ?? value
            } else {
                FileHandle.standardError.write(Data("“\(word)” isn't key=value or a JSON object.\n".utf8))
                return 2
            }
        }
        if parameters["value"] as? String == "-" {
            var text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
            if text.hasSuffix("\n") { text.removeLast() }
            parameters["value"] = text
        }
        clientLock.locked { client = "AirSCP --agent" }
        let reply = call(name, parameters)
        if raw, let data = try? JSONSerialization.data(withJSONObject: reply) { print(String(decoding: data, as: UTF8.self)) }
        for item in reply["content"] as? [[String: Any]] ?? [] {
            if let text = item["text"] as? String {
                if !raw { print(text) }
            } else if let base64 = item["data"] as? String, let data = Data(base64Encoded: base64) {
                if let out {
                    do { try data.write(to: URL(fileURLWithPath: out)) } catch {
                        FileHandle.standardError.write(Data("Can't write \(out): \(error.localizedDescription)\n".utf8))
                        return 1
                    }
                } else if !raw {
                    print("(an image of \(data.count) bytes: add --out file.png to save it)")
                }
            }
        }
        return reply["isError"] as? Bool == true ? 1 : 0
    }
}
