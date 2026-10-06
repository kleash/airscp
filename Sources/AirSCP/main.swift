import AirSCPCore
import AppKit

// Helper modes come first (no UI, no app start). ssh runs this binary
// - as the ProxyCommand `AirSCP --proxy-connect <proxy id> <host> <port>` for a host behind an HTTP proxy. Checked
//   before askpass mode: it inherits AIRSCP_ASKPASS_SOCK from ssh's environment.
// - as SSH_ASKPASS, with the prompt as its argument: it relays the prompt to the running app over AIRSCP_ASKPASS_SOCK.
// - by an AI agent's tools: `AirSCP --mcp` (an MCP server on stdio) and `AirSCP --agent <tool> …` (one tool from a
//   shell), both talking to the running app's agent socket.
if CommandLine.arguments.dropFirst().first == "--proxy-connect" {
    exit(ProxyConnect.run(Array(CommandLine.arguments.dropFirst(2))))
}
if CommandLine.arguments.dropFirst().first == "--mcp" { exit(AgentBridge.runMCP()) }
if CommandLine.arguments.dropFirst().first == "--agent" { exit(AgentBridge.runCLI(Array(CommandLine.arguments.dropFirst(2)))) }
if ProcessInfo.processInfo.environment["AIRSCP_ASKPASS_SOCK"] != nil {
    exit(Askpass.runHelper(prompt: CommandLine.arguments.dropFirst().first ?? ""))
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.setActivationPolicy(.regular)
NSApplication.shared.run()
