import AirSCPCore
import AppKit
import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple Intelligence on this Mac (PLAN.md AD): Ask AirSCP and Explain. Optional: on a Mac or macOS without it, or with
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

#if canImport(FoundationModels)
/// Apple's on-device model: nothing leaves the Mac.
@available(macOS 26, *)
struct AppleAssistant: Assistant {
    func answer(_ question: String, instructions: String, context: String) async throws -> String {
        let session = LanguageModelSession(instructions: instructions)
        return try await session.respond(to: "What AirSCP shows now:\n\(context)\n\nThe user asks: \(question)").content
    }
}
#endif

@MainActor
final class AskModel: ObservableObject {
    @Published var question = ""
    @Published var answer = ""
    @Published var busy = false
    @Published var failure: String?
    /// What the model is told about the host in front (shown, so that the user sees what it gets).
    @Published var context = ""
    var assistant: Assistant?

    func ask() {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, let assistant, !busy else { return }
        busy = true
        failure = nil
        answer = ""
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
        window.contentView = NSHostingView(rootView: AskView(model: model))
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
                TextField("e.g. Why can't I connect to web-01?", text: $model.question)
                    .onSubmit(model.ask)
                    .accessibilityIdentifier("ask.question")
                Button("Ask", action: model.ask)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.busy || model.question.trimmingCharacters(in: .whitespaces).isEmpty || model.assistant == nil)
                    .help(model.assistant == nil ? "Apple Intelligence isn't available on this Mac" : "Ask Apple Intelligence (on this Mac)")
            }
            ScrollView {
                Group {
                    if model.busy {
                        ProgressView().controlSize(.small)
                    } else if let failure = model.failure {
                        Text(failure).foregroundColor(.red)
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
            DisclosureGroup("What AirSCP tells it", isExpanded: $showsContext) {
                Text(model.context).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            .help("The summary of the host in front that goes with your question: no passwords, keys or file contents")
        }
        .padding(16)
    }
}
