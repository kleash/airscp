import AirSCPCore
import AppKit
import SwiftUI

/// Settings: light or dark, which terminal app opens ssh sessions, where downloads go, the browser's defaults, how new
/// hosts and desktops check their servers (PLAN.md U.4), where new keys go (K.1), agent control and the debug log (AE).
struct SettingsView: View {
    @ObservedObject var model: AppModel
    private let iTermInstalled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: TerminalLauncher.iTermID) != nil

    var body: some View {
        // The whole form in a scroll view: on a short screen the window is shorter than the form, and it scrolls.
        ScrollView {
            VStack(spacing: 0) {
                form.fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    HelpButton(.settings)
                }
                .padding([.horizontal, .bottom], 20)
            }
        }
        .frame(width: 540)
    }

    private var form: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $model.data.settings.appearance) {
                    Text("System").tag(AppSettings.Appearance.system)
                    Text("Light").tag(AppSettings.Appearance.light)
                    Text("Dark").tag(AppSettings.Appearance.dark)
                }
                .pickerStyle(.segmented)
                .primaryTint()
                .fixedSize()
                .accessibilityIdentifier("settings.appearance")
                .accessibilityLabel("Appearance")
                .help("Follow the Mac's light or dark mode (System, the default), or always use one")
            }
            Section("Files") {
                Picker("Open terminals in", selection: $model.data.settings.terminalApp) {
                    Text("Terminal").tag(AppSettings.TerminalApp.terminal)
                    Text(iTermInstalled ? "iTerm" : "iTerm (not installed)").tag(AppSettings.TerminalApp.iTerm)
                }
                .accessibilityIdentifier("settings.terminal")
                .accessibilityLabel("Open terminals in")
                .help("The app that Open Terminal, Run in Terminal and Kill with sudo use (Terminal by default)")
                caption("iTerm can be chosen when it is installed.")
                LabeledContent("Downloads folder") {
                    HStack {
                        Text((model.data.settings.downloadFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: chooseFolder)
                            .help("Choose the downloads folder")
                    }
                }
                .help("Where Download To… starts, and where archive downloads go when the other pane isn't this Mac")
                caption("Used by Download To… and Download as .tar.gz when the other pane isn't this Mac. Drags and the "
                        + "Download button go to the folder shown.")
                Toggle("Show hidden files in new panes", isOn: $model.data.settings.showHidden)
                    .accessibilityIdentifier("settings.showHidden")
                    .help("Off by default: files whose names start with a dot are hidden. Each pane can still switch with ⇧⌘.")
                Toggle("Copied files keep their original date", isOn: $model.data.settings.preserveTimes)
                    .accessibilityIdentifier("settings.preserveTimes")
                    .help("Off by default: copies are dated now. On, they keep the file's own date (scp -p)")
                Toggle("Verify transfers with SHA-256", isOn: $model.data.settings.verifyTransfers)
                    .accessibilityIdentifier("settings.verifyTransfers")
                    .help("Off by default. On, each file's copy is compared with the original (SHA-256) once it arrives")
                caption("Single files only, not folders or archives; big files take longer. Right-click a finished transfer "
                        + "to check just that one (Verify with Checksum).")
                Toggle("Ask before deleting on a server", isOn: $model.data.settings.confirmDelete)
                    .accessibilityIdentifier("settings.confirmDelete")
                    .help("On by default. Off deletes server items at once; items on this Mac always go to the Trash")
                Toggle("Always calculate folder sizes", isOn: $model.data.settings.alwaysCalculateFolderSizes)
                    .help("Off by default: folders show — until View ▸ Calculate Folder Sizes. On works them out at every "
                          + "listing (du), slower on big folders")
                    .accessibilityIdentifier("settings.alwaysCalculateFolderSizes")
            }
            Section("Security") {
                Picker("New hosts' server key", selection: $model.data.settings.hostKeyCheck) {
                    ForEach(HostKeyCheck.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .accessibilityIdentifier("settings.hostKey")
                .help("How new hosts make sure a server is the right one (Ask unless you change it here); each host can "
                      + "change it in its settings, under Advanced")
                if model.data.settings.hostKeyCheck == .off {
                    Text(model.data.settings.hostKeyCheck.explanation).font(.caption).foregroundColor(.red)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    caption(model.data.settings.hostKeyCheck.explanation)
                }
                CertificateCheckFields(check: $model.data.settings.certificateCheck, caFile: $model.data.settings.caFile,
                                       ids: ("settings.certificate", "settings.caFile", "settings.chooseCA"),
                                       window: { Self.window }, label: "New desktops' certificate")
            }
            Section("Keys") {
                LabeledContent("New keys go in") {
                    HStack {
                        Text(keyFolder).lineLimit(1).truncationMode(.middle)
                        Button("Choose…", action: chooseKeyFolder)
                            .accessibilityIdentifier("settings.keyFolder")
                            .help("Choose the folder for New Key Pair and Import Key")
                        if !model.data.settings.keyFolder.isEmpty {
                            Button("Use ~/.ssh") { model.data.settings.keyFolder = "" }
                                .help("Put new keys in ~/.ssh again, where ssh looks for them by itself")
                        }
                    }
                }
                .help("Where New Key Pair and Import Key save keys; ~/.ssh by default")
                caption("New Key Pair and Import Key save keys here; ~/.ssh by default, where ssh finds them by itself.")
            }
            Section("Apple Intelligence") {
                Toggle("Use Apple Intelligence for Ask AirSCP and Explain", isOn: $model.data.settings.appleIntelligence)
                    .help("On by default, when this Mac has Apple Intelligence. Questions are answered on this Mac; nothing is sent anywhere")
                    .accessibilityIdentifier("settings.appleIntelligence")
                caption((model.data.settings.appleIntelligence ? AppleIntelligence.problem(model.data.settings).map { $0 + "." } : nil)
                        ?? "Help ▸ Ask AirSCP… and the Explain… button of a failed connection, answered on this Mac with a "
                        + "summary of the host in front (never passwords, keys or files).")
            }
            Section("Agents") {
                Toggle("Allow AI agents to control AirSCP (MCP)", isOn: $model.data.settings.agentControl)
                    .help("Off by default. Lets AI agents and scripts of your user account drive AirSCP as you would, "
                          + "through “AirSCP --mcp” (an MCP server) or “AirSCP --agent”. They see what AirSCP shows, never "
                          + "saved passwords")
                    .accessibilityIdentifier("settings.agentControl")
                caption("On, an MCP client on this Mac (Claude Code, Claude Desktop…) can drive AirSCP as you would; it never "
                        + "sees saved passwords. Add it with:")
                HStack(alignment: .top) {
                    Text(Self.mcpCommand)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.mcpCommand")
                        .help("The command that adds AirSCP to Claude Code; other MCP clients take the same program and --mcp")
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.mcpCommand, forType: .string)
                    }
                    .help("Copy the command, to paste into Terminal")
                    .accessibilityIdentifier("settings.copyMCPCommand")
                }
            }
            Section("Advanced") {
                Toggle("Debug logging", isOn: $model.data.settings.debugLogging)
                    .help("Off by default. On, connections and transfers are written to a log file in detail")
                    .accessibilityIdentifier("settings.debugLogging")
                caption("Writes a detailed log of connections and transfers to help find what went wrong. Turn it off when "
                        + "done. Help ▸ Show Debug Log in Finder shows the file; it never holds passwords.")
                if DebugLog.forced && !model.data.settings.debugLogging {
                    caption("On while AirSCP runs with AIRSCP_DEBUG=1.")
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 540)
    }

    /// How Claude Code adds AirSCP as an MCP server (with this instance's settings folder, for a throwaway AirSCP).
    static var mcpCommand: String {
        let program = Bundle.main.executablePath ?? "/Applications/AirSCP.app/Contents/MacOS/AirSCP"
        let folder = Env.value("SUPPORT_DIR").flatMap { $0.isEmpty ? nil : $0 }
        return "claude mcp add airscp " + (folder.map { "-e AIRSCP_SUPPORT_DIR=\(Quote.shellWord($0)) " } ?? "")
            + "-- \(Quote.shellWord(program)) --mcp"
    }

    private func caption(_ text: String) -> some View { FormCaption(text) }

    private static var window: NSWindow? { NSApp.windows.first { $0.isVisible && $0.title == "Settings" } }

    private var keyFolder: String {
        model.data.settings.keyFolder.isEmpty ? (sshDirectory as NSString).abbreviatingWithTildeInPath : model.data.settings.keyFolder
    }

    private func chooseKeyFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = true
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: (keyFolder as NSString).expandingTildeInPath, isDirectory: true)
        Panels.run(panel, on: Self.window) { [model] urls in
            if let url = urls.first { model.data.settings.keyFolder = (url.path as NSString).abbreviatingWithTildeInPath }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: model.data.settings.downloadFolder, isDirectory: true)
        panel.prompt = "Choose"
        Panels.run(panel, on: NSApp.windows.first { $0.isVisible && $0.title == "Settings" }) { [model] urls in
            if let url = urls.first { model.data.settings.downloadFolder = url.path }
        }
    }
}

/// The app-wide appearance for the setting: nil follows macOS.
func appAppearance(_ setting: AppSettings.Appearance) -> NSAppearance? {
    switch setting {
    case .system: return nil
    case .light: return NSAppearance(named: .aqua)
    case .dark: return NSAppearance(named: .darkAqua)
    }
}
