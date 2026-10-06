import AirSCPCore
import AppKit
import SwiftUI

// Server key and certificate checks (PLAN.md U.4): their words in the editors and Settings, and the orange shield that
// marks a host or desktop whose checks are off, in the sidebar and above its workspace.

extension HostKeyCheck {
    var title: String {
        switch self {
        case .ask: return "Ask (default)"
        case .acceptNew: return "Trust new servers automatically"
        case .off: return "Don't check (insecure)"
        }
    }

    var explanation: String {
        switch self {
        case .ask: return "ssh shows a new server's key to trust, and refuses one that has changed."
        case .acceptNew: return "A new server's key is trusted without asking; a changed key is still refused "
            + "(StrictHostKeyChecking=accept-new)."
        case .off: return "Insecure: no check, and the key isn't remembered. Anyone on the network could pretend to be "
            + "this server and see what you send, passwords too. Only for test machines on a network you trust."
        }
    }
}

extension CertificateCheck {
    var title: String {
        switch self {
        case .ask: return "Ask (default)"
        case .trustNew: return "Trust automatically"
        case .off: return "Don't check (insecure)"
        case .companyCA: return "Trust my company's certificate authority"
        }
    }

    var explanation: String {
        switch self {
        case .ask: return "AirSCP shows a certificate it doesn't know yet, and warns when one changes."
        case .trustNew: return "The first certificate is trusted and remembered without asking; a changed one still warns. "
            + "For self-signed servers you can't check otherwise."
        case .off: return "Insecure: never checked. Anyone on the network could pretend to be this computer and see "
            + "what you type, passwords too."
        case .companyCA: return "The best fix for company servers: certificates your company's certificate authority "
            + "signed (its .pem or .cer file, from IT) are trusted; any other is asked about."
        }
    }
}

/// The orange shield of a host (`ssh`) or desktop whose server checks are off.
struct ChecksOffShield: View {
    let ssh: Bool

    /// Its tooltip (agents read it in the snapshot as the host's `warning`).
    static func help(ssh: Bool) -> String {
        (ssh ? "Server key" : "Certificate") + " checks are off for this server; anyone on the network could impersonate it."
    }

    var body: some View {
        Image(systemName: "exclamationmark.shield.fill")
            .foregroundColor(.orange)
            // One picture, as the sidebar's chips and dots: else the window server's vibrancy pales it in Night Harbor
            // in a capture of the window (agent screenshots, the docs' pictures).
            .drawingGroup()
            .help(Self.help(ssh: ssh))
            .accessibilityElement()
            .accessibilityLabel(Self.help(ssh: ssh))
    }
}

/// "Server certificate:" with what the choice means, and the company certificate authority's file when that is
/// chosen: in the Remote Desktop editor, and in Settings ▸ Security for new desktops. `ids`: the pop-up's, the file
/// field's and its Choose… button's accessibility ids.
struct CertificateCheckFields: View {
    @Binding var check: CertificateCheck
    @Binding var caFile: String
    let ids: (check: String, file: String, choose: String)
    let window: () -> NSWindow?
    var label = "Server certificate:"

    var body: some View {
        Picker(label, selection: $check) {
            ForEach(CertificateCheck.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        .accessibilityIdentifier(ids.check)
        .help("How AirSCP makes sure this is the right Windows computer: Ask (the default) shows a certificate it doesn't "
              + "know yet first")
        if check == .companyCA {
            LabeledContent("Certificate authority:") {
                HStack {
                    TextField("Certificate authority", text: $caFile, prompt: Text("Its .pem, .cer or .crt file"))
                        .labelsHidden()
                        .accessibilityIdentifier(ids.file)
                        .help("Your company's certificate authority (its root or issuing certificate), from your IT department")
                    Button("Choose…", action: choose)
                        .accessibilityIdentifier(ids.choose)
                        .help("Choose the certificate authority's file (PEM or DER)")
                }
            }
        }
        if check == .off {
            Text(check.explanation).font(.caption).foregroundColor(.red).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 390, alignment: .leading)
        } else {
            FormCaption(check.explanation)
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.message = "Choose your company's certificate authority (a .pem, .cer or .crt file)."
        if !caFile.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (caFile as NSString).expandingTildeInPath).deletingLastPathComponent()
        }
        Panels.run(panel, on: window()) { urls in
            if let url = urls.first { caFile = url.path }
        }
    }
}
