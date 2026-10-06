import AppKit
import Darwin
import Foundation
import Testing
@testable import AirSCP
@testable import AirSCPCore

// The agent bridge (PLAN.md T): `AirSCP --mcp` speaks MCP (newline-delimited JSON-RPC 2.0) on stdio and
// `AirSCP --agent` runs one tool from a shell; both forward tool calls to the app's agent socket in
// <AIRSCP_SUPPORT_DIR>/agent and pass its MCP results on untouched. These run the real AirSCP binary against a stand-in
// for the app's socket.

/// A stand-in for the app's agent socket: answers each request carrying `token` with `reply(tool, arguments)`, and
/// closes the others unanswered (as the app does).
final class FakeAgentSocket {
    let support: String
    let requests = Recorder<String>()
    private let listener: Int32

    init(token: String = "secret", reply: @escaping (String, [String: Any]) -> [String: Any]) throws {
        support = try scratch()
        let dir = support + "/agent"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try token.write(toFile: dir + "/token", atomically: true, encoding: .utf8)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try #require(Askpass.unixAddress(dir + "/sock"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, listen(fd, 8) == 0 else { throw AirSCPError(.other, "fake agent socket: \(String(cString: strerror(errno)))") }
        listener = fd
        let requests = self.requests
        Thread.detachNewThread {
            while true {
                let connection = accept(fd, nil, nil)
                if connection < 0 { return }
                var on: Int32 = 1  // a bridge that has gone mustn't take the tests down with it
                setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
                while true {
                    let count = recv(connection, &buffer, buffer.count, 0)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer[0..<count])
                }
                if let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let tool = request["tool"] as? String,
                   request["token"] as? String == token {
                    requests.append(tool)
                    let body = try! JSONSerialization.data(withJSONObject: reply(tool, request["arguments"] as? [String: Any] ?? [:]))
                    _ = body.withUnsafeBytes { send(connection, $0.baseAddress, $0.count, 0) }
                }
                close(connection)
            }
        }
    }

    func stop() {
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }
}

/// The reply of the fake app: echoes the tool and its arguments; "screenshot" adds a tiny image; "fail" (or fail: true)
/// is an error.
private func echo(_ tool: String, _ arguments: [String: Any]) -> [String: Any] {
    let json = String(decoding: try! JSONSerialization.data(withJSONObject: ["tool": tool, "arguments": arguments], options: .sortedKeys),
                      as: UTF8.self)
    var content: [[String: Any]] = [["type": "text", "text": json]]
    if tool == "screenshot" { content.insert(["type": "image", "data": Data("PNG!".utf8).base64EncodedString(), "mimeType": "image/png"], at: 0) }
    return ["content": content, "isError": tool == "fail" || arguments["fail"] as? Bool == true]
}

/// Runs `AirSCP --mcp` with these input lines (stdin then closes) and returns the replies by id.
private func mcp(_ lines: [String], support: String) async throws -> (byID: [Int: [String: Any]], other: [[String: Any]]) {
    let result = await Runner.run([TestEnvironment.airscpBinary, "--mcp"], input: lines.joined(separator: "\n") + "\n",
                                  environment: ["AIRSCP_SUPPORT_DIR": support])
    #expect(result.status == 0)
    var byID: [Int: [String: Any]] = [:], other: [[String: Any]] = []
    for line in result.output.split(separator: "\n") {
        let message = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(message["jsonrpc"] as? String == "2.0")
        if let id = message["id"] as? Int { byID[id] = message } else { other.append(message) }
    }
    return (byID, other)
}

private func agent(_ arguments: [String], support: String) async -> CommandResult {
    await Runner.run([TestEnvironment.airscpBinary, "--agent"] + arguments, environment: ["AIRSCP_SUPPORT_DIR": support])
}

@Test func mcpAnswersItselfWhenAirSCPIsntRunning() async throws {
    let support = try scratch()  // no agent socket there
    let replies = try await mcp([
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"test","version":"1"}}}"#,
        #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"snapshot","arguments":{}}}"#,
        #"{"jsonrpc":"2.0","id":4,"method":"ping"}"#,
        #"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#,
        "this is not json",
        "",
    ], support: support)
    let initialize = try #require(replies.byID[1]?["result"] as? [String: Any])
    #expect(initialize["protocolVersion"] as? String == "2025-06-18")
    #expect((initialize["serverInfo"] as? [String: Any])?["name"] as? String == "airscp")
    #expect((initialize["capabilities"] as? [String: Any])?["tools"] != nil)
    // The tool list comes from the bridge itself, so a client that starts before AirSCP sees the tools.
    let tools = try #require((replies.byID[2]?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
    #expect(tools.compactMap { $0["name"] as? String } == ["snapshot", "screenshot", "menu", "press", "set", "key", "type",
                                                            "click", "focus", "select", "sort", "drop", "wait", "guide"])
    #expect(tools.allSatisfy { ($0["inputSchema"] as? [String: Any])?["type"] as? String == "object" && $0["description"] is String })
    let call = try #require(replies.byID[3]?["result"] as? [String: Any])
    #expect(call["isError"] as? Bool == true)
    #expect(((call["content"] as? [[String: Any]])?.first?["text"] as? String)?.contains("isn't running") == true)
    #expect(replies.byID[4]?["result"] as? [String: Any] != nil)
    #expect((replies.byID[5]?["error"] as? [String: Any])?["code"] as? Int == -32601)
    // The bad line: a parse error with a null id. The notification got no answer.
    #expect(replies.other.count == 1 && (replies.other[0]["error"] as? [String: Any])?["code"] as? Int == -32700)
    #expect(replies.byID.count == 5)

    let cli = await agent(["snapshot"], support: support)
    #expect(cli.status == 1 && cli.output.contains("isn't running"))
    // A settings folder whose agent socket can't be: the bridge says so (the app can't listen there either), not
    // "isn't running".
    let long = await agent(["snapshot"], support: "/tmp/" + String(repeating: "x", count: 110))
    #expect(long.status == 1 && long.output.contains("path is too long for the agent socket"), "\(long.output)")
}

/// A bridge whose parent has gone (a launchd job, a shell's `( … & )`) waits for its answer like any other; a socket
/// that is there but doesn't answer isn't "not running".
@Test func anOrphanedBridgeWaitsForItsAnswer() async throws {
    let app = try FakeAgentSocket { tool, arguments in
        if tool == "wait" { Thread.sleep(forTimeInterval: 3) }
        return echo(tool, arguments)
    }
    let out = app.support + "/out.txt"
    // The subshell ends at once: AirSCP --agent goes on with launchd as its parent.
    _ = await Runner.run(["/bin/sh", "-c", "( \"$0\" --agent wait until=text text=X >\"$1\" 2>&1 & )", TestEnvironment.airscpBinary, out],
                         environment: ["AIRSCP_SUPPORT_DIR": app.support])
    #expect(await eventually { read(out)?.contains(#""tool":"wait""#) == true }, "\(read(out) ?? "")")
    app.stop()  // the socket stays, nothing answers: AirSCP is busy or quitting
    let busy = await agent(["snapshot"], support: app.support)
    #expect(busy.status == 1 && busy.output.hasPrefix("AirSCP didn't answer"), "\(busy.output)")
}

/// The client closing stdin ends the bridge within seconds, even with a wait under way (the app ends that wait once the
/// bridge has gone), not when the wait times out.
@Test func theBridgeEndsSoonAfterItsInput() async throws {
    let gate = DispatchSemaphore(value: 0)
    let app = try FakeAgentSocket { tool, arguments in
        if tool == "wait" { _ = gate.wait(timeout: .now() + 60) }
        return echo(tool, arguments)
    }
    let started = Date()
    let replies = try await mcp([
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"wait","arguments":{"until":"text","text":"x","timeout":60}}}"#,
    ], support: app.support)
    #expect(Date().timeIntervalSince(started) < 40 && replies.byID[1] == nil)  // not the wait's 60 s
    gate.signal()
    app.stop()
}

@Test func mcpForwardsToolCallsAndTheirResultsUntouched() async throws {
    let app = try FakeAgentSocket(reply: echo)
    defer { app.stop() }
    let replies = try await mcp([
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26"}}"#,
        #"{"jsonrpc":"2.0","id":"a","method":"tools/call","params":{"name":"menu","arguments":{"path":"Host > Connect"}}}"#,
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"screenshot","arguments":{"target":"main"}}}"#,
        #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"press","arguments":{"fail":true}}}"#,
        #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{}}"#,
        #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"nosuchtool"}}"#,
        #"{"jsonrpc":"2.0","id":7,"method":"initialize","params":{"protocolVersion":"1999-01-01"}}"#,
        #"[{"jsonrpc":"2.0","id":8,"method":"ping"}]"#,
    ], support: app.support)
    // The client's version when it is one AirSCP speaks, else one it does.
    #expect((replies.byID[1]?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-03-26")
    #expect((replies.byID[7]?["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-06-18")
    let menu = try #require(replies.other.first { $0["id"] as? String == "a" }?["result"] as? [String: Any])
    #expect((menu["content"] as? [[String: Any]])?.first?["text"] as? String == #"{"arguments":{"path":"Host > Connect"},"tool":"menu"}"#)
    #expect(menu["isError"] as? Bool == false)
    let shot = try #require((replies.byID[3]?["result"] as? [String: Any])?["content"] as? [[String: Any]])
    #expect(shot.first?["type"] as? String == "image" && shot.first?["mimeType"] as? String == "image/png")
    #expect(shot.first?["data"] as? String == Data("PNG!".utf8).base64EncodedString())
    #expect((replies.byID[4]?["result"] as? [String: Any])?["isError"] as? Bool == true)
    // No name, or a tool AirSCP doesn't have: invalid params, not a call. A batch (an array): an invalid request.
    #expect((replies.byID[5]?["error"] as? [String: Any])?["code"] as? Int == -32602)
    #expect((replies.byID[6]?["error"] as? [String: Any])?["code"] as? Int == -32602)
    #expect(replies.other.contains { ($0["error"] as? [String: Any])?["code"] as? Int == -32600 && $0["id"] is NSNull })
    #expect(replies.byID[8] == nil)
    // Only the tool calls reached the app.
    #expect(app.requests.all.sorted() == ["menu", "press", "screenshot"])
}

@Test func agentCommandLineSendsArgumentsAndSavesImages() async throws {
    let app = try FakeAgentSocket(reply: echo)
    defer { app.stop() }
    // key=value: text, except for arguments the tool takes as numbers, true/false or lists (their JSON).
    let select = await agent(["select", "pane=right", "names=[\"a b\",\"c\"]", "all=false", "in=window:2.0"], support: app.support)
    #expect(select.status == 0)
    #expect(select.output == #"{"arguments":{"all":false,"in":"window:2.0","names":["a b","c"],"pane":"right"},"tool":"select"}"# + "\n")
    let set = await agent(["set", "id=prompt.name", "value=1.10"], support: app.support)
    #expect(set.output == #"{"arguments":{"id":"prompt.name","value":"1.10"},"tool":"set"}"# + "\n")
    let typed = await agent(["type", "text=42"], support: app.support)
    #expect(typed.output == #"{"arguments":{"text":"42"},"tool":"type"}"# + "\n")
    let click = await agent(["click", "x=10", "y=20.5", "count=2", "button=null"], support: app.support)
    #expect(click.output == #"{"arguments":{"button":"null","count":2,"x":10,"y":20.5},"tool":"click"}"# + "\n")
    // One JSON object works too; --json prints the whole reply.
    let raw = await agent(["wait", #"{"until":"connected","timeout":5}"#, "--json"], support: app.support)
    let reply = try #require(try JSONSerialization.jsonObject(with: Data(raw.output.utf8)) as? [String: Any])
    #expect(reply["isError"] as? Bool == false && (reply["content"] as? [[String: Any]])?.count == 1)
    // An image goes to --out.
    let out = try scratch() + "/shot.png"
    let shot = await agent(["screenshot", "--out", out], support: app.support)
    #expect(shot.status == 0 && read(out) == "PNG!" && shot.output.contains("\"tool\":\"screenshot\""))
    // A failed tool: exit status 1. A bad argument: 2, and nothing is sent.
    #expect(await agent(["fail"], support: app.support).status == 1)
    let before = app.requests.all.count
    #expect(await agent(["menu", "Host > Connect"], support: app.support).status == 2)
    #expect(app.requests.all.count == before)
    let usage = await agent([], support: app.support)
    #expect(usage.status == 2 && usage.output.contains("screenshot"))
}

@Test func aWrongTokenGetsNoAnswer() async throws {
    let app = try FakeAgentSocket(token: "the real one", reply: echo)
    defer { app.stop() }
    try "a guess".write(toFile: app.support + "/agent/token", atomically: true, encoding: .utf8)
    let result = await agent(["snapshot"], support: app.support)
    // Its socket is there (agent control is on), but it doesn't answer: said so, not "isn't running".
    #expect(result.status == 1 && result.output.contains("AirSCP didn't answer") && app.requests.all.isEmpty)
}

@Test func theGuideIsServedWithoutTheApp() async throws {
    let support = try scratch()
    let replies = try await mcp([
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"guide","arguments":{}}}"#,
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"guide","arguments":{"topic":"rdp"}}}"#,
        #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"guide","arguments":{"topic":"nothing"}}}"#,
    ], support: support)
    let instructions = try #require((replies.byID[1]?["result"] as? [String: Any])?["instructions"] as? String)
    #expect(instructions.contains("snapshot") && instructions.contains("Never sleep") && instructions.contains("guide topic="))
    #expect(instructions.split(separator: "\n").count <= 40)
    func text(_ id: Int) -> String? { ((replies.byID[id]?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first?["text"] as? String }
    #expect(text(2)?.hasPrefix(instructions) == true && text(2)?.contains("troubleshooting") == true)
    #expect(text(3)?.hasPrefix("## rdp\n") == true && text(3)?.contains("rdpLogin.password") == true)
    #expect((replies.byID[4]?["result"] as? [String: Any])?["isError"] as? Bool == true)
    let cli = await agent(["guide", "topic=keys"], support: support)
    #expect(cli.status == 0 && cli.output.hasPrefix("## keys"))
}

/// A password for `set` from a shell comes on standard input (`value=-`): a command line is open to every process.
@Test func agentCommandLineReadsAValueFromStandardInput() async throws {
    let app = try FakeAgentSocket(reply: echo)
    defer { app.stop() }
    let result = await Runner.run([TestEnvironment.airscpBinary, "--agent", "set", "id=prompt.answer", "value=-"],
                                  input: "s3cret pass\n", environment: ["AIRSCP_SUPPORT_DIR": app.support])
    #expect(result.status == 0)
    #expect(result.output == #"{"arguments":{"id":"prompt.answer","value":"s3cret pass"},"tool":"set"}"# + "\n")
}

/// The guide stays true to the app: every tool has its entry, every topic its section, and the menu paths and
/// control ids it names exist.
@MainActor @Test func theGuideNamesRealToolsMenusAndControls() throws {
    let guide = AgentBridge.guideText
    let sections = AgentBridge.guideSections
    #expect(Set(sections.keys) == Set(AgentBridge.guideTopics + [""]))
    for tool in AgentBridge.tools.compactMap({ $0["name"] as? String }) {
        #expect(sections["tools"]?.contains("- `\(tool) {") == true, "the guide's tools section lacks \(tool)")
    }
    // Windows' Delete key and a drag into Finder are named where agents look ("delete" is ⌫: in Explorer it went up a
    // folder instead of deleting).
    #expect(sections["tools"]?.contains("\"forwarddelete\" is the Delete key") == true)
    #expect("\(AgentBridge.tools.first { $0["name"] as? String == "drop" } ?? [:])".contains("finder:<dir>"))

    _ = NSApplication.shared
    let bar = AppDelegate().mainMenu()
    func normalized(_ title: String) -> String {
        var text = title.lowercased()
        for suffix in ["…", "..."] where text.hasSuffix(suffix) { text = String(text.dropLast(suffix.count)) }
        return text
    }
    func exists(_ path: String) -> Bool {
        var menu: NSMenu? = bar, item: NSMenuItem?
        for part in path.components(separatedBy: " > ") {
            item = menu?.items.first { !$0.isSeparatorItem && normalized($0.title) == normalized(part) }
            menu = item?.submenu
        }
        return item != nil
    }
    let quoted = try NSRegularExpression(pattern: #""([A-Z][^"]*? > [^"]+)""#)
    let paths = quoted.matches(in: guide, range: NSRange(guide.startIndex..., in: guide))
        .compactMap { Range($0.range(at: 1), in: guide).map { String(guide[$0]) } }
    #expect(paths.count > 30)
    #expect(paths.filter { !exists($0) } == [], "menu paths the guide names but the app doesn't have")

    // Control ids (hostEditor.hostname and the like) are written somewhere in the app's sources.
    let sources = try FileManager.default.contentsOfDirectory(atPath: sourceFolder).filter { $0.hasSuffix(".swift") }
        .map { try String(contentsOfFile: sourceFolder + "/" + $0, encoding: .utf8) }.joined()
    let id = #"((?:hostEditor|rdpEditor|proxyEditor|tunnelEditor|runCommand|monitor|newKey|importKey|exportKey|keyResult|keys|permissions|prompt|rdpLogin|settings|editor|run|compress|transfers|transfer|find|sync|snippet|snippets)\.[a-zA-Z]+)"#
    func found(_ pattern: String, in text: String) throws -> Set<String> {
        let regex = try NSRegularExpression(pattern: pattern)
        return Set(regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range(at: 1), in: text).map { String(text[$0]) } })
    }
    let named = try found(#"\b"# + id + #"\b"#, in: guide)
    #expect(named.count > 30)
    // The quoted ids in the sources, in one pass (a search of them per id held the main thread for seconds).
    #expect(named.subtracting(try found("\"" + id + "\"", in: sources)).sorted() == [],
            "control ids the guide names but the app doesn't have")
}

private let sourceFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appendingPathComponent("Sources/AirSCP").path

// MARK: End to end against the Docker lab (AIRSCP_DOCKER=1)

/// An AirSCP app started for one test: its own settings folder (hosts preset in airscp.json) and ssh folder (the lab
/// key, its own known_hosts, no agent), driven only through `AirSCP --agent` and `AirSCP --mcp`.
final class LaunchedAirSCP {
    let root: String
    var support: String { root + "/support" }
    let process = Process()

    /// `data(sshDirectory)`: what airscp.json holds at launch.
    init(_ data: (String) -> AirSCPData) throws {
        root = try scratch()
        let ssh = root + "/ssh"
        try FileManager.default.createDirectory(atPath: ssh, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(atPath: support, withIntermediateDirectories: true)
        for name in ["id_lab", "id_lab.pub"] { try FileManager.default.copyItem(atPath: Lab.key + (name.hasSuffix(".pub") ? ".pub" : ""), toPath: ssh + "/" + name) }
        chmod(ssh + "/id_lab", 0o600)
        try "UserKnownHostsFile \(ssh)/known_hosts\nIdentityAgent none\nIdentityFile none\n".write(toFile: ssh + "/config", atomically: true, encoding: .utf8)
        try JSONEncoder().encode(data(ssh)).write(to: URL(fileURLWithPath: support + "/airscp.json"))
        process.executableURL = URL(fileURLWithPath: Self.app)
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["AIRSCP_SUPPORT_DIR": support, "AIRSCP_SSH_DIR": ssh]) { $1 }
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    var sshDirectory: String { root + "/ssh" }

    /// build/AirSCP.app (./build.sh) when it was built after the last change to the sources, else the test build's
    /// own AirSCP binary.
    static let app: String = {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let built = repo.appendingPathComponent("build/AirSCP.app/Contents/MacOS/AirSCP").path
        func modified(_ path: String) -> Date { (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date ?? .distantPast }
        let sources = FileManager.default.enumerator(atPath: repo.appendingPathComponent("Sources").path)?
            .compactMap { $0 as? String }.map { modified(repo.appendingPathComponent("Sources/" + $0).path) }.max() ?? .distantFuture
        return modified(built) > sources ? built : TestEnvironment.airscpBinary
    }()

    /// One tool through `AirSCP --agent`; the JSON it prints. Throws the text of a failed tool.
    @discardableResult
    func call(_ tool: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: arguments), as: UTF8.self)
        let result = await Runner.run([TestEnvironment.airscpBinary, "--agent", tool, json], environment: ["AIRSCP_SUPPORT_DIR": support])
        guard result.status == 0 else { throw AirSCPError(.other, "\(tool) \(json): \(result.output)\(result.stderr)") }
        return (try? JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: Any]) ?? [:]
    }

    /// Waits until the app answers (it starts agent control once launched).
    func ready() async -> Bool {
        await eventually { (try? await self.call("snapshot", ["include": [String]()])) != nil }
    }

    /// Ends the app (SIGTERM: agent control may be off by now), the ssh connections it left open (SIGTERM skips
    /// AirSCP's own disconnect, so a test that failed half-way would leave them) and its askpass folder.
    func stop() {
        guard process.isRunning else { return }
        let open = (try? runSync(["/usr/sbin/lsof", "-a", "-p", String(process.processIdentifier), "-U", "-Fn"])) ?? ""
        let folders = open.split(separator: "\n").filter { $0.hasPrefix("n/private/tmp/airscp-askpass.") || $0.hasPrefix("n/tmp/airscp-askpass.") }
            .map { (String($0.dropFirst()) as NSString).deletingLastPathComponent }
        process.terminate()
        process.waitUntilExit()
        _ = try? runSync(["/usr/bin/pkill", "-f", sshDirectory + "/config"])
        for folder in Set(folders) { try? FileManager.default.removeItem(atPath: folder) }
    }

    private func runSync(_ argv: [String]) throws -> String {
        let lsof = Process(), pipe = Pipe()
        lsof.executableURL = URL(fileURLWithPath: argv[0])
        lsof.arguments = Array(argv.dropFirst())
        lsof.standardOutput = pipe
        lsof.standardError = FileHandle.nullDevice
        try lsof.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        lsof.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

@Suite(.enabled(if: Lab.enabled, "Docker lab: AIRSCP_DOCKER=1"))
struct AgentLabTests {
    /// The main window and Settings open in the middle of the screen at their own sizes (smaller on a small screen),
    /// whatever the user's AirSCP saved in the defaults the two share: a throwaway AirSCP neither reads nor saves window
    /// frames. (User report, 2026-10-05: AirSCP and its Settings opened full height.)
    @Test func windowsOpenAtTheirOwnSizes() async throws {
        let app = try LaunchedAirSCP { _ in
            var data = AirSCPData(hosts: [SSHHost(label: "web", hostname: "web.example.com")])
            data.settings.agentControl = true
            return data
        }
        defer { app.stop() }
        #expect(await app.ready())
        let visible = try #require(await MainActor.run { () -> NSRect? in
            _ = NSApplication.shared
            return NSScreen.main?.visibleFrame
        })
        func frame(_ title: String?) async throws -> NSRect? {
            let windows = try await app.call("snapshot", ["include": ["windows"]])["windows"] as? [[String: Any]] ?? []
            let window = title.map { title in windows.first { $0["title"] as? String == title } } ?? windows.first
            guard let values = window?["frame"] as? [Double], values.count == 4 else { return nil }
            return NSRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
        let main = try #require(try await frame(nil))
        let size = WindowFrame.fitted(NSSize(width: 1100, height: 700), minimum: NSSize(width: 760, height: 460), on: visible)
        #expect(main.size == size && abs(main.midX - visible.midX) <= 1, "\(main) on \(visible)")
        // Settings: 600 points of its form (which scrolls) under the title bar, never more than 80 % of the screen.
        try await app.call("menu", ["path": "AirSCP > Settings…"])
        #expect(await eventually { (try? await frame("Settings")) != nil })
        let settings = try #require(try await frame("Settings"))
        let tallest = (visible.height * 0.8).rounded(.down)
        #expect(settings.width == 540 && abs(settings.midX - visible.midX) <= 1, "\(settings) on \(visible)")
        #expect(tallest < 650 ? abs(settings.height - tallest) <= 4 : settings.height > 600 && settings.height < 650, "\(settings) on \(visible)")
    }

    /// The app's own menu bar through the agent: Export and Import Hosts take a file instead of their panels, the Host
    /// menu renames and deletes groups by name (empty ones too), and the Window and View menus have no window-tab items.
    @Test func anAgentUsesTheMenuBarsPanelsAndGroups() async throws {
        let app = try LaunchedAirSCP { _ in
            var data = AirSCPData(hosts: [SSHHost(label: "web", hostname: "web.example.com")], groups: [HostGroup(name: "Lab")])
            data.settings.agentControl = true
            return data
        }
        defer { app.stop() }
        #expect(await app.ready())
        let file = app.root + "/hosts.json"
        try await app.call("menu", ["path": "File > Export Hosts…", "file": file])
        #expect(await eventually { read(file)?.contains("web.example.com") == true })
        var reply = try await app.call("menu", ["path": "File > Import Hosts…", "file": file])
        #expect(((reply["sheet"] as? [String: Any])?["title"] as? String)?.hasPrefix("Imported 1 host") == true, "\(reply)")
        try await app.call("key", ["combo": "return"])
        try await app.call("wait", ["until": "no_sheet"])
        // A file whose host would run a program here at each connect: asked first, and Leave Them Out keeps the rest.
        var risky = SSHHost(label: "risky", hostname: "risky.example.com")
        risky.extraOptions = ["ProxyCommand=sh -c 'touch /tmp/airscp-pwned'; exec nc %h %p", "Compression=yes"]
        try Store.export(AirSCPData(hosts: [risky])).write(to: URL(fileURLWithPath: app.root + "/risky.json"))
        reply = try await app.call("menu", ["path": "File > Import Hosts…", "file": app.root + "/risky.json"])
        #expect(((reply["sheet"] as? [String: Any])?["title"] as? String)?.hasPrefix("Hosts in “risky.json” run commands") == true,
                "\(reply)")
        try await app.call("press", ["title": "Leave Them Out"])
        try await app.call("wait", ["until": "sheet", "text": "Imported 1 host"])
        try await app.call("key", ["combo": "return"])
        try await app.call("wait", ["until": "no_sheet"])
        try await app.call("menu", ["path": "File > Export Hosts…", "file": app.root + "/after.json"])
        #expect(await eventually { read(app.root + "/after.json")?.contains("Compression=yes") == true })
        #expect(read(app.root + "/after.json")?.contains("ProxyCommand") == false)
        reply = try await app.call("menu", ["path": "Host > Rename Group > Lab"])
        #expect((reply["sheet"] as? [String: Any])?["title"] as? String == "Rename the group “Lab”", "\(reply)")
        try await app.call("set", ["id": "prompt.name", "value": "Lab Servers"])
        try await app.call("press", ["title": "Rename"])
        try await app.call("wait", ["until": "no_sheet"])
        let menus = try await app.call("snapshot", ["include": ["menus"]])["menus"] as? [[String: Any]] ?? []
        let paths = menus.compactMap { $0["path"] as? String }
        #expect(paths.contains("Host > Delete Group > Lab Servers…") && paths.contains("View > Columns > Owner"))
        #expect(!paths.contains { $0.contains("Tab") || $0.contains("Merge All Windows") }, "\(paths.filter { $0.contains("Tab") })")
        // The main window once: AirSCP's own Window ▸ AirSCP (⌘0), not also AppKit's entry for it under its title.
        #expect(paths.filter { $0 == "Window > AirSCP" }.count == 1, "\(paths.filter { $0.hasPrefix("Window") })")
        reply = try await app.call("menu", ["path": "Host > Delete Group > Lab Servers"])
        try await app.call("press", ["title": "Delete Group"])
        try await app.call("wait", ["until": "no_sheet"])
        let after = try await app.call("snapshot", ["include": ["sidebar"]])
        #expect(((after["sidebar"] as? [String: Any])?["sections"] as? [[String: Any]])?.allSatisfy { $0["group"] is NSNull } == true)
    }

    /// PLAN.md T's session: a host made in the editor, connected through openproxy → bastion → target (its key
    /// questions answered), a folder uploaded with its sheet, the monitor's busy process killed, a screenshot, MCP
    /// against the running app, the inner-network host through the same chain, and agent control switched off.
    @Test func anAgentDrivesTheLabChain() async throws {
        let app = try LaunchedAirSCP { ssh in
            let proxy = Proxy(name: "Lab open proxy", host: "127.0.0.1", port: 42281)
            var bastion = SSHHost(label: "bastion", hostname: "bastion", port: 22, username: "jump", auth: .keyFile,
                                  keyFile: ssh + "/id_lab")
            bastion.proxyID = proxy.id
            bastion.autoReconnect = false
            // Only on the lab's inner network: reached through the open proxy and the bastion.
            var inner = SSHHost(label: "private", hostname: "private", port: 22, username: "dev", auth: .keyFile, keyFile: ssh + "/id_lab")
            inner.jumpHostID = bastion.id
            inner.autoReconnect = false
            var data = AirSCPData(hosts: [bastion, inner], proxies: [proxy])
            data.settings.agentControl = true
            return data
        }
        defer { app.stop() }
        #expect(await app.ready())

        // A new host through the editor (SwiftUI fields by id; the key menu by part of its title).
        try await app.call("menu", ["path": "File > New Host…"])
        try await app.call("wait", ["until": "sheet", "text": "New Host"])
        for (id, value) in [("hostEditor.name", "chain target"), ("hostEditor.hostname", "target"), ("hostEditor.port", "22"),
                            ("hostEditor.username", "dev"), ("hostEditor.login", "id_lab"), ("hostEditor.jump", "bastion")] {
            try await app.call("set", ["id": id, "value": value])
        }
        try await app.call("press", ["title": "Add"])
        try await app.call("wait", ["until": "no_sheet"])
        let selection = try await app.call("snapshot", ["include": ["sidebar"]])
        #expect((selection["selection"] as? [String: Any])?["name"] as? String == "chain target")

        // Connect: ssh asks to trust each server's key, the bastion's first. Each action's reply carries the sheet
        // that is up (answer it); `wait` stops early when a new one appears.
        var reply = try await app.call("menu", ["path": "Host > Connect"])
        var trusted: [String] = []
        for _ in 0..<4 {
            if reply["sheet"] == nil, let up = try? await app.call("wait", ["until": "sheet", "timeout": 2]) { reply = ["sheet": up] }
            if let sheet = reply["sheet"] as? [String: Any] {
                let title = sheet["title"] as? String ?? ""
                #expect(title.hasPrefix("Trust"), "\(sheet)")
                trusted.append(title)
                reply = try await app.call("press", ["title": "Trust"])
                continue
            }
            if (try? await app.call("wait", ["until": "connected", "host": "chain target", "timeout": 60])) != nil { break }
            reply = [:]
        }
        #expect(trusted == ["Trust “bastion”?", "Trust “target”?"])
        try await app.call("wait", ["until": "connected", "host": "chain target", "timeout": 5])
        let log = try await app.call("snapshot", ["include": ["log"]])["log"] as? [[String: Any]] ?? []
        #expect(log.contains { ($0["command"] as? String ?? "").contains("--proxy-connect") && ($0["command"] as? String ?? "").contains("-W") })

        // Upload a folder of 300 files: the folder sheet, compressed, then listed.
        try await app.call("wait", ["until": "listed", "pane": "right"])
        let folder = app.root + "/agent-upload-" + UUID().uuidString.prefix(6)
        for index in 0..<300 { try write("file \(index)\n", to: folder + "/f\(index).txt") }
        let name = RemotePath.name(folder)
        try await app.call("drop", ["files": [folder], "pane": "right"])
        let ask = try await app.call("wait", ["until": "sheet", "text": "Upload"])
        #expect((ask["buttons"] as? [[String: Any]])?.contains { $0["title"] as? String == "Upload" } == true)
        try await app.call("press", ["title": "Upload"])
        let transfers = try await app.call("wait", ["until": "transfers_done", "timeout": 120])
        #expect((transfers["jobs"] as? [[String: Any]])?.contains { ($0["status"] as? String) == "Done" } == true)
        try await app.call("wait", ["until": "listed", "pane": "right", "text": name])
        // …and deleted again, through its confirmation.
        try await app.call("select", ["pane": "right", "names": [name]])
        try await app.call("menu", ["path": "File > Delete…"])
        try await app.call("wait", ["until": "sheet", "text": "Delete"])
        try await app.call("press", ["title": "Delete"])
        try await app.call("wait", ["until": "no_sheet"])

        // The monitor: find the lab's busy process and kill it (it comes back by itself).
        try await app.call("press", ["title": "Monitor"])
        try await app.call("wait", ["until": "text", "text": "porter-busy", "timeout": 30])
        try await app.call("set", ["id": "monitor.search", "value": "porter-busy"])
        try await app.call("select", ["pane": "processes", "names": ["porter-busy"]])
        try await app.call("press", ["title": "Kill"])
        try await app.call("wait", ["until": "sheet", "text": "Kill"])
        try await app.call("press", ["title": "Kill", "in": "sheet"])
        try await app.call("wait", ["until": "no_sheet"])

        // A screenshot, written by --agent --out.
        let shot = app.root + "/shot.png"
        let result = await Runner.run([TestEnvironment.airscpBinary, "--agent", "screenshot", "--out", shot],
                                      environment: ["AIRSCP_SUPPORT_DIR": app.support])
        #expect(result.status == 0 && result.output.contains("\"width\""))
        let image = try #require(NSImage(contentsOfFile: shot))
        #expect(image.size.width > 600 && image.size.height > 400)

        // MCP against the running app: the framing an MCP client sees.
        let replies = try await mcp([
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"snapshot","arguments":{"include":["sidebar"]}}}"#,
            #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"screenshot","arguments":{}}}"#,
        ], support: app.support)
        let snapshot = try #require(replies.byID[3]?["result"] as? [String: Any])
        #expect(snapshot["isError"] as? Bool == false)
        let text = try #require((snapshot["content"] as? [[String: Any]])?.first?["text"] as? String)
        #expect(text.contains("\"chain target\"") && text.contains("\"connected\""))
        let picture = try #require(((replies.byID[4]?["result"] as? [String: Any])?["content"] as? [[String: Any]])?.first)
        #expect(picture["type"] as? String == "image" && (picture["data"] as? String).flatMap { Data(base64Encoded: $0) }?.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]))

        // Disconnect, then the saved host on the inner network: proxy → bastion (trusted already) → private.
        try await app.call("menu", ["path": "Host > Disconnect"])
        try await app.call("wait", ["until": "disconnected", "host": "chain target"])
        try await app.call("select", ["pane": "sidebar", "names": ["private"]])
        reply = try await app.call("menu", ["path": "Host > Connect"])
        if reply["sheet"] == nil { reply = ["sheet": try await app.call("wait", ["until": "sheet", "timeout": 30])] }
        #expect((reply["sheet"] as? [String: Any])?["title"] as? String == "Trust “private”?")
        try await app.call("press", ["title": "Trust"])
        try await app.call("wait", ["until": "connected", "host": "private", "timeout": 60])
        let home = try await app.call("wait", ["until": "listed", "pane": "right"])
        #expect("\(home)".contains("/home/dev"))
        try await app.call("menu", ["path": "Host > Disconnect"])
        try await app.call("wait", ["until": "disconnected", "host": "private"])

        // Agent control off in Settings: the socket and the token go at once.
        try await app.call("menu", ["path": "AirSCP > Settings…"])
        _ = try? await app.call("set", ["id": "settings.agentControl", "value": false, "in": "window:Settings"])
        #expect(await eventually { !rawExists(app.support + "/agent/sock") && !rawExists(app.support + "/agent/token") })
        let off = await Runner.run([TestEnvironment.airscpBinary, "--agent", "snapshot"], environment: ["AIRSCP_SUPPORT_DIR": app.support])
        #expect(off.status == 1 && off.output.contains("isn't running"))
    }
}
