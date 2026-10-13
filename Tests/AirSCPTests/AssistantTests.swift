import AppIntents
import Foundation
import Testing
@testable import AirSCP
@testable import AirSCPCore

// MARK: Ask AirSCP, Explain and App Intents

/// A stand-in for Apple's on-device model: it repeats what it was told, so tests see the prompt.
private struct EchoAssistant: Assistant {
    func answer(_ question: String, instructions: String, context: String) async throws -> String {
        "Q: \(question)\nC: \(context)"
    }

    func generate(_ prompt: String, instructions: String, schema: AssistantOutput) async throws -> String { "{}" }
}

/// A stand-in that returns fixed JSON for guided generation (and records the prompt it got).
private final class FixedAssistant: Assistant, @unchecked Sendable {
    let json: String
    var prompts: [String] = []
    init(_ json: String) { self.json = json }
    func answer(_ question: String, instructions: String, context: String) async throws -> String { "" }
    func generate(_ prompt: String, instructions: String, schema: AssistantOutput) async throws -> String {
        prompts.append(prompt)
        return json
    }
}

/// Stand-in actions: what ran, in order; `failOn` makes that action throw.
@MainActor
private final class RecordingActions: AssistantActions {
    var ran: [String] = []
    var failOn: String?
    private func record(_ name: String) throws {
        ran.append(name)
        if name == failOn { throw AirSCPError(.other, "\(name) went wrong") }
    }
    func connect(host: UUID) async throws { try record("connect") }
    func openShell(host: UUID) async throws { try record("openShell") }
    func openDesktop(_ id: UUID) async throws { try record("openDesktop") }
    func disconnectAll() async { ran.append("disconnectAll") }
    func transferStatus() -> String { ran.append("transferStatus"); return "No transfers." }
    func upload(host: UUID, localPaths: [String], remoteDir: String?, leaveOut: [String]) async throws {
        try record("upload \(localPaths.joined(separator: ",")) \(remoteDir ?? "-") \(leaveOut.joined(separator: ","))")
    }
    func download(host: UUID, remotePaths: [String], localDir: String?) async throws { try record("download") }
    func find(host: UUID, folder: String, pattern: String) async throws -> [String] { try record("find"); return ["/a.log"] }
    func runSnippet(_ id: UUID, host: UUID) async throws { try record("runSnippet") }
    func setTunnel(host: UUID, tunnel: UUID, on: Bool) async throws { try record("setTunnel \(on)") }
}

@Test func theAssistantIsToldAShortSummaryWithoutSecrets() {
    var host = SSHHost(label: "web-01", hostname: "web.example.com", port: 2222, username: "deploy")
    host.extraOptions = ["Compression=yes"]
    DebugLog.Secrets.add("hunter2-secret")
    let summary = AssistantContext.summary(host: host, route: "Connects through bastion", state: "Disconnected",
                                           error: "Permission denied for hunter2-secret", commands: (1...20).map { "ls /dir\($0)" },
                                           figures: nil)
    #expect(summary.contains("Host: web-01 — deploy@web.example.com:2222, logs in with the ssh agent or default keys"))
    #expect(summary.contains("Other ssh options: Compression=yes") && summary.contains("Route: Connects through bastion"))
    #expect(!summary.contains("hunter2-secret") && summary.contains("line left out"))
    #expect(summary.contains("ls /dir20") && !summary.contains("ls /dir12\n"))  // the last 8 commands only
    #expect(AssistantContext.summary(host: nil, route: nil, state: nil, error: nil, commands: [], figures: nil) == "Nothing is selected in AirSCP.")
    let long = AssistantContext.summary(host: host, route: nil, state: nil, error: String(repeating: "x", count: 9000), commands: [],
                                        figures: nil, limit: 500)
    #expect(long.count <= 501)
    #expect(AssistantContext.explain("Connection refused hunter2-secret").hasPrefix("AirSCP showed this error"))
    #expect(!AssistantContext.explain("Connection refused hunter2-secret").contains("hunter2"))
    #expect(AssistantContext.instructions.contains("Never ask for or repeat a password"))
}

@MainActor @Test func askAirSCPAnswersWithTheModelAndSaysWhyWhenItCant() async {
    let model = AskModel()
    model.assistant = EchoAssistant()
    model.context = "Host: web"
    model.question = "Why can't I connect?"
    model.ask()
    #expect(await eventually { !model.busy && !model.answer.isEmpty })
    #expect(model.answer == "Q: Why can't I connect?\nC: Host: web" && model.failure == nil)
    // Off in Settings: said so (and macOS's own reason when it is on but unavailable).
    var settings = AppSettings()
    settings.appleIntelligence = false
    #expect(AppleIntelligence.problem(settings)?.contains("Settings ▸ Apple Intelligence") == true)
    settings.appleIntelligence = true
    if let problem = AppleIntelligence.problem(settings) { #expect(problem.contains("Apple Intelligence")) }
    // Old settings files turn it on.
    let decoded = try? JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
    #expect(decoded?.appleIntelligence == true)
}

@MainActor @Test func appShortcutsOfferAirSCPsActions() {
    let titles = [ConnectHostIntent.title, OpenTerminalTabIntent.title, OpenDesktopIntent.title, DisconnectAllIntent.title,
                  TransferStatusIntent.title, UploadFilesIntent.title, DownloadFilesIntent.title, FindFilesIntent.title,
                  RunSnippetIntent.title, StartTunnelIntent.title, StopTunnelIntent.title, OpenFavouriteFolderIntent.title]
        .map { String(localized: $0) }
    #expect(titles == ["Connect to Host", "Open a Shell on Host", "Open Remote Desktop", "Disconnect All", "Get Transfer Status",
                       "Upload Files", "Download Files", "Find Files", "Run Snippet", "Start Tunnel", "Stop Tunnel",
                       "Open Favourite Folder"])
    #expect(AirSCPShortcuts.appShortcuts.count == 8)  // App Shortcuts allows 10
    #expect(ConnectHostIntent.openAppWhenRun && !DisconnectAllIntent.openAppWhenRun && UploadFilesIntent.openAppWhenRun)
}

// MARK: Do It…, Explain and Suggest

private func savedData() -> AirSCPData {
    var web = SSHHost(label: "web-01", hostname: "web.example.com", username: "deploy")
    web.tunnels = [Tunnel(kind: .local, listenPort: 8080, targetPort: 80)]
    let prod1 = SSHHost(label: "prod-1", hostname: "10.0.0.1"), prod2 = SSHHost(label: "prod-2", hostname: "10.0.0.2")
    var data = AirSCPData(hosts: [web, prod1, prod2], snippets: [Snippet(name: "Disk usage", command: "df -h")])
    data.rdpEntries = [RDPEntry(label: "win-desk", hostname: "win.example.com")]
    return data
}

@Test func plansResolveNamesAndSaySentences() throws {
    let data = savedData()
    let json = """
        {"steps":[{"action":"upload","host":"WEB-01","localPaths":["~/Sites/site"],"folder":"/var/www","leaveOut":["node_modules"]},
                  {"action":"setTunnel","host":"web","tunnel":"8080","on":true},
                  {"action":"runSnippet","host":"prod","snippet":"Disk usage"},
                  {"action":"connect","host":"nowhere"},
                  {"action":"rm -rf","host":"web-01"},
                  {"action":"transferStatus"}]}
        """
    let plan = try AssistantPlan.decode(json).resolve(in: data)
    #expect(plan.count == 6)
    // Any case, then a unique prefix.
    #expect(plan[0].hostID == data.hosts[0].id && plan[0].problem == nil)
    #expect(plan[0].sentence == "Upload ~/Sites/site to web-01 in /var/www, leaving out node_modules")
    #expect(plan[1].tunnelID == data.hosts[0].tunnels[0].id && plan[1].sentence == "Switch on the tunnel on port 8080 of web-01")
    // Two hosts start with "prod": it asks which instead of guessing.
    #expect(plan[2].problem?.contains("More than one host") == true)
    #expect(plan[3].problem == "AirSCP has no host called “nowhere”.")
    // Only AirSCP's actions: anything else can't run.
    #expect(plan[4].problem == "AirSCP can't do “rm -rf”.")
    // Past 5 steps, steps don't run.
    #expect(plan[5].problem?.contains("at most 5 steps") == true)
    #expect(throws: AirSCPError.self) { try AssistantPlan.decode("not json") }
    #expect(AssistantPlan.actions.count == 10)
}

@Test func theInventoryNamesSavedItemsWithoutSecrets() {
    var data = savedData()
    DebugLog.Secrets.add("s3cret-in-a-label")
    data.hosts.append(SSHHost(label: "s3cret-in-a-label", hostname: "x"))
    let inventory = AssistantContext.inventory(data)
    #expect(inventory.contains("Host: web-01 (deploy@web.example.com)") && inventory.contains("Snippet: Disk usage"))
    #expect(inventory.contains("Remote Desktop: win-desk") && inventory.contains("Tunnel: web-01 port 8080"))
    #expect(!inventory.contains("s3cret-in-a-label"))
    data.hosts = (1...200).map { SSHHost(label: "host-\($0)", hostname: "h\($0).example.com") }
    #expect(AssistantContext.inventory(data, limit: 300).count <= 301)
    #expect(AssistantContext.inventory(AirSCPData()) == "Nothing is saved in AirSCP yet.")
    #expect(AssistantContext.summarizeLog((1...80).map { "cmd \($0)" }).contains("cmd 80"))
    #expect(!AssistantContext.summarizeLog((1...80).map { "cmd \($0)" }).contains("cmd 30\n"))
}

@MainActor @Test func doItShowsTheStepsAndRunsThemOnlyOnRun() async throws {
    let data = savedData()
    let model = AskModel()
    let assistant = FixedAssistant("""
        {"steps":[{"action":"connect","host":"web-01"},
                  {"action":"upload","host":"web-01","localPaths":["/tmp/a"],"leaveOut":[".git"]},
                  {"action":"find","host":"web-01","folder":"/var/log","pattern":"*.log"}]}
        """)
    let actions = RecordingActions()
    model.assistant = assistant
    model.actions = actions
    model.data = { data }
    #expect(model.runProblem?.contains("Do It") == true)  // nothing to run before a plan
    model.question = "connect to web and upload a, then find logs"
    model.planIt()
    #expect(await eventually { !model.busy })
    // The connect before the upload goes: the upload connects by itself.
    #expect(model.plan.map(\.sentence) == ["Upload /tmp/a to web-01 in the folder its pane shows, leaving out .git",
                                            "Find “*.log” in /var/log on web-01"])
    #expect(actions.ran.isEmpty, "planning runs nothing")
    #expect(assistant.prompts.first?.contains("Saved in AirSCP:") == true)
    #expect(model.runProblem == nil)
    model.run()
    #expect(await eventually { !model.running && model.results.count == 2 })
    #expect(actions.ran == ["upload /tmp/a - .git", "find"])
    #expect(model.results[1] == "Found 1: /a.log")
    #expect(model.runProblem?.contains("ran") == true)  // not twice

    // A step that fails stops the rest.
    actions.ran = []
    actions.failOn = "upload /tmp/a - .git"
    model.planIt()
    #expect(await eventually { !model.busy && !model.plan.isEmpty })
    model.run()
    #expect(await eventually { !model.running && !model.results.isEmpty })
    #expect(actions.ran == ["upload /tmp/a - .git"] && model.results[0] == "Failed: upload /tmp/a - .git went wrong"
            && model.results[1] == nil)

    // A step that names nothing saved: Run stays off and says which step.
    let unknown = AskModel()
    unknown.assistant = FixedAssistant(#"{"steps":[{"action":"connect","host":"nowhere"}]}"#)
    unknown.actions = actions
    unknown.data = { data }
    unknown.question = "connect to nowhere"
    unknown.planIt()
    #expect(await eventually { !unknown.busy })
    #expect(unknown.runProblem?.hasPrefix("Step 1 can't run") == true)
    // Nothing AirSCP can do: said so.
    let nothing = AskModel()
    nothing.assistant = FixedAssistant(#"{"steps":[]}"#)
    nothing.question = "what's the weather"
    nothing.planIt()
    #expect(await eventually { !nothing.busy })
    #expect(nothing.failure?.contains("nothing AirSCP can do") == true)
}

@MainActor @Test func suggestionsAreCheckedAndUsedOnlyOnUse() async {
    #expect(SuggestField.mode.problem("644") == nil && SuggestField.mode.problem("2775") == nil)
    #expect(SuggestField.mode.problem("888") != nil && SuggestField.mode.problem("rw-r--r--") != nil)
    #expect(SuggestField.findPattern.problem("*.pdf") == nil && SuggestField.findPattern.problem("/var/*.pdf") != nil)
    #expect(SuggestField.leaveOut.problem("node_modules, .git") == nil && SuggestField.leaveOut.problem("a\nb") != nil)
    #expect(SuggestField.otherOptions.problem("ServerAliveInterval=30\nCompression yes") == nil)
    #expect(SuggestField.otherOptions.problem("keep it alive please") != nil)
    #expect(SuggestField.mode.prompt("everyone reads").contains("octal"))

    let good = SuggestModel(field: .mode)
    good.assistant = FixedAssistant(#"{"value":" 644 "}"#)
    good.sentence = "owner writes, everyone reads"
    good.suggest()
    #expect(await eventually { !good.busy })
    #expect(good.value == "644" && good.usable == "644")
    let bad = SuggestModel(field: .mode)
    bad.assistant = FixedAssistant(#"{"value":"rwx"}"#)
    bad.sentence = "anything"
    bad.suggest()
    #expect(await eventually { !bad.busy })
    #expect(bad.usable == nil && bad.problem?.contains("isn't a mode") == true)
}

/// What the real model tends to send (seen with Apple's on-device model): empty fields, the host only on a connect step
/// before the action, a tunnel named with words. The plan is tidied before anyone sees it.
@Test func modelPlansAreTidiedBeforeTheyAreShown() throws {
    let plan = try AssistantPlan.decode("""
        {"steps":[{"action":"connect","host":"web-01"},
                  {"action":"upload","localPaths":["~/Sites/site",""],"folder":"","leaveOut":["node_modules"],"remotePaths":[]},
                  {"action":"setTunnel","host":"web-01","tunnel":"web-01 port 8080","on":false},
                  {"action":"setTunnel","host":"web-01","tunnel":"web-01 port 8080","on":false}]}
        """)
    #expect(plan.steps.map(\.action) == ["upload", "setTunnel"])  // the connect before it, and the repeat, go
    #expect(try AssistantPlan.decode(#"{"steps":[{"action":"disconnectAll","host":"a"},{"action":"disconnectAll","host":"b"}]}"#)
        .steps.count == 1)
    let upload = plan.steps[0]
    #expect(upload.host == "web-01" && upload.folder == nil && upload.localPaths == ["~/Sites/site"] && upload.remotePaths == nil)
    let resolved = plan.resolve(in: savedData())
    #expect(resolved[1].tunnelID != nil && resolved[1].sentence == "Switch off the tunnel on port 8080 of web-01")
    // A connect on its own stays.
    #expect(try AssistantPlan.decode(#"{"steps":[{"action":"connect","host":"web-01"}]}"#).steps.map(\.action) == ["connect"])
}
