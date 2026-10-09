import AppIntents
import Foundation
import Testing
@testable import AirSCP
@testable import AirSCPCore

// MARK: Ask AirSCP, Explain and App Intents (PLAN.md AD)

/// A stand-in for Apple's on-device model: it repeats what it was told, so tests see the prompt.
private struct EchoAssistant: Assistant {
    func answer(_ question: String, instructions: String, context: String) async throws -> String {
        "Q: \(question)\nC: \(context)"
    }
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
                  TransferStatusIntent.title].map { String(localized: $0) }
    #expect(titles == ["Connect to Host", "Open a Shell on Host", "Open Remote Desktop", "Disconnect All", "Get Transfer Status"])
    #expect(AirSCPShortcuts.appShortcuts.count == 5)
    #expect(ConnectHostIntent.openAppWhenRun && !DisconnectAllIntent.openAppWhenRun)
}
