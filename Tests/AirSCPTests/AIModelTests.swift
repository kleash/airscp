import Foundation
import Testing
@testable import AirSCP
@testable import AirSCPCore
#if canImport(FoundationModels)
import FoundationModels
#endif

// The real on-device model: only with AIRSCP_AI=1, on a Mac with Apple Intelligence on (lab.yml's ai
// job). Everything else about Ask, Do It and Suggest is tested with stand-ins in AssistantTests.

private let enabled = ProcessInfo.processInfo.environment["AIRSCP_AI"] == "1"

@Suite(.enabled(if: enabled), .serialized) struct AIModelTests {
    @Test func theModelIsAvailable() throws {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let availability = SystemLanguageModel.default.availability
            print("SystemLanguageModel.default.availability: \(availability)")
            #expect(availability == .available, "Turn Apple Intelligence on: System Settings ▸ Apple Intelligence & Siri")
            return
        }
        #endif
        Issue.record("This Mac or SDK has no FoundationModels (macOS 26 with Apple Intelligence)")
    }

    @MainActor @Test func requestsBecomePlansAirSCPCanRead() async throws {
        guard let assistant = AppleIntelligence.assistant else {
            Issue.record("No on-device model")
            return
        }
        var web = SSHHost(label: "web-01", hostname: "web.example.com", username: "deploy")
        web.tunnels = [Tunnel(kind: .local, listenPort: 8080, targetPort: 80)]
        let data = AirSCPData(hosts: [web, SSHHost(label: "db", hostname: "db.example.com")],
                              snippets: [Snippet(name: "Disk usage", command: "df -h")])
        let requests = [
            "connect to web-01", "open a shell on db", "upload ~/Sites/site to web-01 in /var/www, skip node_modules",
            "download /var/log/syslog from web-01", "find big log files in /var/log on web-01", "run Disk usage on db",
            "start the 8080 tunnel on web-01", "stop the tunnel on web-01", "how are my transfers", "disconnect everything",
        ]
        for request in requests {
            let prompt = "Saved in AirSCP:\n\(AssistantContext.inventory(data))\n\nThe request: \(request)"
            let json = try await assistant.generate(prompt, instructions: AssistantContext.planInstructions, schema: .plan)
            let plan = try AssistantPlan.decode(json)
            print("\(request) → \(json)")
            #expect(!plan.steps.isEmpty && plan.steps.count <= AssistantPlan.limit, "\(request): \(json)")
            #expect(plan.steps.allSatisfy { AssistantPlan.actions.contains($0.action) }, "\(request): \(json)")
        }
    }

    @MainActor @Test func sentencesBecomeValidValues() async throws {
        guard let assistant = AppleIntelligence.assistant else {
            Issue.record("No on-device model")
            return
        }
        let cases: [(SuggestField, String)] = [
            (.mode, "everyone can read, only I can write"), (.mode, "a script only I can run"),
            (.findPattern, "PDF files"), (.leaveOut, "skip git folders and build output"),
            (.otherOptions, "keep the connection alive through a firewall"),
        ]
        for (field, sentence) in cases {
            let json = try await assistant.generate(field.prompt(sentence), instructions: AssistantContext.suggestInstructions,
                                                    schema: .value(field))
            struct Suggestion: Decodable { let value: String }
            let value = try JSONDecoder().decode(Suggestion.self, from: Data(json.utf8)).value
            print("\(field) \(sentence) → \(value)")
            #expect(field.problem(value) == nil, "\(field): \(value)")
        }
    }
}
