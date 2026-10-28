import AirSCPCore
import AppKit
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence on this Mac: Ask AirSCP and Explain. Optional: on a Mac or macOS without it, or with
/// it switched off (in macOS or in Settings ▸ Apple Intelligence), the commands say why and do nothing.
enum AppleIntelligence {
    /// Why Ask AirSCP can't answer now, nil when it can.
    @MainActor
    static func problem(_ settings: AppSettings) -> String? {
        guard settings.appleIntelligence else { return "Apple Intelligence is off in AirSCP: turn it on in Settings ▸ Apple Intelligence" }
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(.appleIntelligenceNotEnabled):
                return "Apple Intelligence is off on this Mac: turn it on in System Settings ▸ Apple Intelligence & Siri"
            case .unavailable(.modelNotReady): return "Apple Intelligence is still getting ready on this Mac: try again later"
            case .unavailable(.deviceNotEligible): return "This Mac can't run Apple Intelligence (it needs Apple silicon)"
            default: return "Apple Intelligence isn't available on this Mac"
            }
        }
        #endif
        return "Ask AirSCP needs macOS 26 or later with Apple Intelligence"
    }

    /// The on-device model, when there is one.
    static var assistant: Assistant? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) { return AppleAssistant() }
        #endif
        return nil
    }
}

extension AppleIntelligence {
    /// Whether the running app can ask now: the Explain, Summarize and Suggest buttons show only then.
    @MainActor static var ready: Bool {
        guard let model = (NSApp.delegate as? AppDelegate)?.model else { return false }
        return problem(model.data.settings) == nil
    }

    /// Opens Ask AirSCP with `question`, asked at once.
    @MainActor static func ask(_ question: String) { (NSApp.delegate as? AppDelegate)?.ask(question) }
}

#if canImport(FoundationModels)
/// Apple's on-device model: nothing leaves the Mac.
@available(macOS 26, *)
struct AppleAssistant: Assistant {
    func answer(_ question: String, instructions: String, context: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        // A cap: an answer that runs on (it can repeat the summary back) stops there instead of failing at the model's
        // 4,096 tokens.
        return try await session.respond(to: "What AirSCP shows now:\n\(context)\n\nThe user asks: \(question)",
                                         options: GenerationOptions(maximumResponseTokens: 500)).content
    }

    func generate(_ prompt: String, instructions: String, schema: AssistantOutput) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: prompt, schema: try Self.schema(schema), options: GenerationOptions(sampling: .greedy))
            .content.jsonString
    }

    /// The model's schema for each shape (built at run time: the Command Line Tools have no @Generable macro).
    static func schema(_ shape: AssistantOutput) throws -> GenerationSchema {
        let text = DynamicGenerationSchema(type: String.self)
        let texts = DynamicGenerationSchema(arrayOf: text)
        switch shape {
        case .plan:
            func optional(_ name: String, _ schema: DynamicGenerationSchema) -> DynamicGenerationSchema.Property {
                DynamicGenerationSchema.Property(name: name, schema: schema, isOptional: true)
            }
            let step = DynamicGenerationSchema(name: "Step", properties: [
                DynamicGenerationSchema.Property(name: "action", schema: DynamicGenerationSchema(name: "Action", anyOf: AssistantPlan.actions)),
                optional("host", text), optional("desktop", text), optional("snippet", text), optional("tunnel", text),
                optional("localPaths", texts), optional("remotePaths", texts), optional("folder", text), optional("pattern", text),
                optional("leaveOut", texts), optional("on", DynamicGenerationSchema(type: Bool.self)),
            ])
            let plan = DynamicGenerationSchema(name: "Plan", properties: [
                DynamicGenerationSchema.Property(name: "steps", schema: DynamicGenerationSchema(arrayOf: step, maximumElements: AssistantPlan.limit)),
            ])
            return try GenerationSchema(root: plan, dependencies: [])
        case .value(let field):
            // A plain string: the on-device model refuses a regex guide (GenerativeError 1020000); `SuggestField.problem`
            // checks the value instead, before Use can put it in.
            _ = field
            let value = DynamicGenerationSchema(name: "Suggestion", properties: [
                DynamicGenerationSchema.Property(name: "value", schema: text),
            ])
            return try GenerationSchema(root: value, dependencies: [])
        }
    }
}
#endif

/// What Do It… runs: AirSCP's actions (`AirSCPActions` in the app, a stand-in in tests).
@MainActor
protocol AssistantActions {
    func connect(host: UUID) async throws
    func openShell(host: UUID) async throws
    func openDesktop(_ id: UUID) async throws
    func disconnectAll() async
    func transferStatus() -> String
    func upload(host: UUID, localPaths: [String], remoteDir: String?, leaveOut: [String]) async throws
    func download(host: UUID, remotePaths: [String], localDir: String?) async throws
    func find(host: UUID, folder: String, pattern: String) async throws -> [String]
    func runSnippet(_ id: UUID, host: UUID) async throws
    func setTunnel(host: UUID, tunnel: UUID, on: Bool) async throws
}

/// The app's actions, for Do It….
struct AppAssistantActions: AssistantActions {
    func connect(host: UUID) async throws { try await AirSCPActions.connect(host: host) }
    func openShell(host: UUID) async throws { try await AirSCPActions.openShell(host: host) }
    func openDesktop(_ id: UUID) async throws { try AirSCPActions.openDesktop(id) }
    func disconnectAll() async { AirSCPActions.disconnectAll() }
    func transferStatus() -> String { AirSCPActions.transferStatus() }
    func upload(host: UUID, localPaths: [String], remoteDir: String?, leaveOut: [String]) async throws {
        try await AirSCPActions.upload(host: host, localPaths: localPaths, remoteDir: remoteDir, leaveOut: leaveOut)
    }
    func download(host: UUID, remotePaths: [String], localDir: String?) async throws {
        try await AirSCPActions.download(host: host, remotePaths: remotePaths, localDir: localDir)
    }
    func find(host: UUID, folder: String, pattern: String) async throws -> [String] {
        try await AirSCPActions.find(host: host, folder: folder, pattern: pattern)
    }
    func runSnippet(_ id: UUID, host: UUID) async throws { try AirSCPActions.runSnippet(id, host: host) }
    func setTunnel(host: UUID, tunnel: UUID, on: Bool) async throws {
        try await AirSCPActions.setTunnel(host: host, tunnel: tunnel, on: on)
    }
}

@MainActor
final class AskModel: ObservableObject {
    @Published var question = ""
    @Published var answer = ""
    @Published var busy = false
    @Published var failure: String?
    /// What the model is told about the host in front (shown, so that the user sees what it gets).
    @Published var context = ""
    /// Do It…'s steps, shown before anything runs; and what each one did once Run ran it (index → text).
    @Published var plan: [AssistantPlan.Resolved] = []
    @Published var results: [Int: String] = [:]
    @Published var running = false
    var assistant: Assistant?
    var actions: AssistantActions?
    /// The saved hosts, desktops, snippets and tunnels that steps name.
    var data: () -> AirSCPData = { AirSCPData() }

    func ask() {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let assistant, !busy else { return }
        busy = true
        failure = nil
        answer = ""
        plan = []
        results = [:]
        let context = context
        Task {
            do {
                answer = try await assistant.answer(question, instructions: AssistantContext.instructions, context: context)
            } catch {
                failure = "Apple Intelligence couldn't answer: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    /// Do It…: the model plans the request as steps; they are shown, and run only by `run`.
    func planIt() {
        let request = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !request.isEmpty, let assistant, !busy, !running else { return }
        busy = true
        failure = nil
        answer = ""
        plan = []
        results = [:]
        let data = data()
        let prompt = "Saved in AirSCP:\n\(AssistantContext.inventory(data))\n\nWhat AirSCP shows now:\n\(context)\n\n"
            + "The request: \(request)"
        Task {
            do {
                let json = try await assistant.generate(prompt, instructions: AssistantContext.planInstructions, schema: .plan)
                plan = try AssistantPlan.decode(json).resolve(in: data)
                if plan.isEmpty {
                    failure = "Apple Intelligence found nothing AirSCP can do for that. Try naming the host and what to do."
                }
            } catch {
                failure = (error as? AirSCPError)?.message ?? "Apple Intelligence couldn't plan it: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    /// Why Run can't start now, or nil.
    var runProblem: String? {
        if plan.isEmpty { return "Click Do It… first: AirSCP shows the steps before anything runs" }
        if running { return "The steps are running" }
        if actions == nil { return "AirSCP can't run steps here" }
        if let index = plan.firstIndex(where: { $0.problem != nil }) {
            return "Step \(index + 1) can't run: \(plan[index].problem!) Change the request and click Do It… again"
        }
        if !results.isEmpty { return "These steps ran: click Do It… again to plan new ones" }
        return nil
    }

    /// Runs the planned steps one after another, through AirSCP's actions (its usual questions still come); a failed
    /// step stops the rest.
    func run() {
        guard runProblem == nil, let actions else { return }
        running = true
        let steps = plan
        Task {
            defer { running = false }
            for (index, step) in steps.enumerated() {
                do {
                    results[index] = try await Self.perform(step, with: actions)
                } catch {
                    results[index] = "Failed: " + ((error as? AirSCPError)?.message ?? error.localizedDescription)
                    return
                }
            }
        }
    }

    static func perform(_ resolved: AssistantPlan.Resolved, with actions: AssistantActions) async throws -> String {
        let step = resolved.step
        func id(_ value: UUID?) throws -> UUID {
            guard let value else { throw AirSCPError(.other, resolved.problem ?? "Something it names isn't saved.") }
            return value
        }
        switch step.action {
        case "connect": try await actions.connect(host: try id(resolved.hostID))
        case "openShell": try await actions.openShell(host: try id(resolved.hostID))
        case "openDesktop": try await actions.openDesktop(try id(resolved.desktopID))
        case "disconnectAll": await actions.disconnectAll()
        case "transferStatus": return actions.transferStatus()
        case "upload":
            try await actions.upload(host: try id(resolved.hostID), localPaths: step.localPaths ?? [], remoteDir: step.folder,
                                     leaveOut: step.leaveOut ?? [])
            return "Queued"
        case "download":
            try await actions.download(host: try id(resolved.hostID), remotePaths: step.remotePaths ?? [], localDir: step.folder)
            return "Queued"
        case "find":
            let found = try await actions.find(host: try id(resolved.hostID), folder: step.folder ?? "~", pattern: step.pattern ?? "*")
            return found.isEmpty ? "Nothing found" : "Found \(found.count): " + found.prefix(5).joined(separator: ", ")
                + (found.count > 5 ? ", …" : "")
        case "runSnippet": try await actions.runSnippet(try id(resolved.snippetID), host: try id(resolved.hostID))
        case "setTunnel":
            try await actions.setTunnel(host: try id(resolved.hostID), tunnel: try id(resolved.tunnelID), on: step.on ?? true)
        default: throw AirSCPError(.other, resolved.problem ?? "AirSCP can't do that.")
        }
        return "Done"
    }
}

/// Help ▸ Ask AirSCP…: a question in plain words, answered on this Mac from what AirSCP shows.
@MainActor
final class AskWindowController: NSWindowController {
    let model = AskModel()

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Ask AirSCP"
        window.minSize = NSSize(width: 460, height: 360)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)
        let hosting = NSHostingView(rootView: AskView(model: model))
        // The window keeps the size given and its own minSize: SwiftUI asked for one taller than the screen (the answer
        // and plan scroll inside).
        hosting.sizingOptions = []
        window.contentView = hosting
        window.open(size: NSSize(width: 560, height: 480))
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}

struct AskView: View {
    @ObservedObject var model: AskModel
    @State private var showsContext = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask about AirSCP, your servers or an error. Apple Intelligence answers on this Mac: nothing is sent anywhere.")
                .font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField("e.g. Why can't I connect to web-01? or: upload ~/Sites/site to web-01, leave out node_modules",
                          text: $model.question)
                    .onSubmit(model.ask)
                    .accessibilityIdentifier("ask.question")
                Button("Ask", action: model.ask)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || model.question.trimmingCharacters(in: .whitespaces).isEmpty || model.assistant == nil)
                    .help(model.assistant == nil ? "Apple Intelligence isn't available on this Mac" : "Ask Apple Intelligence (on this Mac)")
                Button("Do It…", action: model.planIt)
                    .disabled(model.busy || model.running || model.question.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.assistant == nil)
                    .help(model.assistant == nil ? "Apple Intelligence isn't available on this Mac"
                          : "Plan the steps for this request: nothing runs until you click Run")
                    .accessibilityIdentifier("ask.doIt")
            }
            ScrollView {
                Group {
                    if model.busy {
                        ProgressView().controlSize(.small)
                    } else if let failure = model.failure {
                        Text(failure).foregroundColor(.red)
                    } else if !model.plan.isEmpty {
                        PlanList(model: model)
                    } else if model.answer.isEmpty {
                        Text("The answer comes here. AI can be wrong: check what it suggests before you act on it.")
                            .foregroundColor(.secondary)
                    } else {
                        Text(model.answer).textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .accessibilityIdentifier("ask.answer")
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            if !model.plan.isEmpty {
                HStack {
                    Text("AirSCP still asks before it replaces or deletes anything.").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("Run", action: model.run)
                        .disabled(model.runProblem != nil)
                        .help(model.runProblem ?? "Run these steps one after another")
                        .accessibilityIdentifier("ask.run")
                }
            }
            DisclosureGroup("What AirSCP tells it", isExpanded: $showsContext) {
                Text(model.context).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .help("The summary of the host in front that goes with your question: no passwords, keys or file contents")
        }
        .padding(16)
    }
}

/// Do It…'s steps as sentences, each with why it can't run or what it did.
struct PlanList: View {
    @ObservedObject var model: AskModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The steps (nothing runs until you click Run):").font(.callout.weight(.semibold))
            ForEach(Array(model.plan.enumerated()), id: \.offset) { index, step in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(index + 1). \(step.sentence)")
                    if let problem = step.problem {
                        Text(problem).font(.caption).foregroundColor(.red)
                    } else if let result = model.results[index] {
                        Text(result).font(.caption).foregroundColor(result.hasPrefix("Failed") ? .red : .secondary)
                    }
                }
                .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("ask.plan")
    }
}

// MARK: Suggest…: a field's value from a sentence, used only when the user clicks Use

@MainActor
final class SuggestModel: ObservableObject {
    let field: SuggestField
    @Published var sentence = ""
    @Published var value = ""
    @Published var problem: String?
    @Published var busy = false
    var assistant: Assistant? = AppleIntelligence.assistant

    init(field: SuggestField) { self.field = field }

    func suggest() {
        let sentence = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sentence.isEmpty, let assistant, !busy else { return }
        busy = true
        value = ""
        problem = nil
        let field = field
        Task {
            do {
                let json = try await assistant.generate(field.prompt(sentence), instructions: AssistantContext.suggestInstructions,
                                                        schema: .value(field))
                struct Suggestion: Decodable { let value: String }
                value = try JSONDecoder().decode(Suggestion.self, from: Data(json.utf8)).value
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                problem = field.problem(value)
            } catch {
                problem = "Apple Intelligence couldn't suggest one: \(error.localizedDescription)"
            }
            busy = false
        }
    }

    /// The value to put in the field: only a checked one.
    var usable: String? { problem == nil && !value.isEmpty ? value : nil }
}

/// The small sparkles button next to a field: describe what you want, see the value, click Use to put it in the field.
/// Shown only when Apple Intelligence can answer.
struct SuggestButton: View {
    let field: SuggestField
    let use: (String) -> Void
    @StateObject private var model: SuggestModel
    @State private var shown = false

    init(field: SuggestField, use: @escaping (String) -> Void) {
        self.field = field
        self.use = use
        _model = StateObject(wrappedValue: SuggestModel(field: field))
    }

    var body: some View {
        Button { shown = true } label: { Image(systemName: "sparkles") }
            .buttonStyle(.borderless)
            .help("Suggest a value from a sentence, with Apple Intelligence on this Mac")
            .accessibilityLabel("Suggest")
            .accessibilityIdentifier("suggest." + field.rawValue)
            .popover(isPresented: $shown, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Say what you want; you see the value before it goes in.").font(.callout).foregroundColor(.secondary)
                    HStack {
                        TextField(Self.example(field), text: $model.sentence)
                            .onSubmit(model.suggest)
                            .frame(width: 300)
                            .accessibilityIdentifier("suggest.sentence")
                        Button("Suggest", action: model.suggest)
                            .disabled(model.busy || model.sentence.trimmingCharacters(in: .whitespaces).isEmpty)
                            .help("Ask Apple Intelligence (on this Mac) for the value")
                    }
                    if model.busy { ProgressView().controlSize(.small) }
                    if !model.value.isEmpty {
                        Text(model.value).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                            .accessibilityIdentifier("suggest.value")
                    }
                    if let problem = model.problem { Text(problem).font(.caption).foregroundColor(.red) }
                    HStack {
                        Spacer()
                        Button("Use") {
                            if let value = model.usable { use(value) }
                            shown = false
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.usable == nil)
                        .help(model.usable == nil ? "Get a valid suggestion first" : "Put this value in the field")
                        .accessibilityIdentifier("suggest.use")
                    }
                }
                .padding(12)
            }
    }

    static func example(_ field: SuggestField) -> String {
        switch field {
        case .otherOptions: return "e.g. keep the connection alive through a firewall"
        case .leaveOut: return "e.g. skip build output and git folders"
        case .findPattern: return "e.g. last year's PDF invoices"
        case .mode: return "e.g. everyone can read, only I can write"
        }
    }
}
