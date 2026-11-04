import AirSCPCore
import SwiftUI

/// A connection's question: Trust for a server's key the first time, otherwise the password, passphrase or code the
/// server asks for. Cancel, or swiping the sheet away, answers nothing and connecting stops.
struct QuestionSheet: View {
    @Environment(AppState.self) private var app
    let question: AppState.Question
    @State private var text = ""
    @State private var remember = false
    @FocusState private var focused: Bool

    private var prompt: Prompt { question.prompt }
    private var isHostKey: Bool { if case .hostKey = prompt.kind { true } else { false } }

    var body: some View {
        NavigationStack {
            Form {
                if case .hostKey(let name, let fingerprint) = prompt.kind {
                    trust(name, fingerprint)
                } else {
                    answer
                }
            }
            .navigationTitle(words.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { app.answer(question, nil) }
                        .help(isHostKey ? "Don't connect" : "Don't answer: connecting stops")
                }
            }
            .safeAreaBar(edge: .bottom) {
                Button(action: send) { Text(words.button).frame(maxWidth: .infinity) }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .padding()
                    .help(words.help)
            }
        }
        .presentationDetents(isHostKey ? [.large] : [.medium])
    }

    /// The title, the button that answers, and its tooltip.
    private var words: (title: String, button: String, help: String) {
        switch prompt.kind {
        case .hostKey: ("Trust this server?", "Trust", "Remember this key and connect")
        case .password(let user?, let host?): ("Password for \(user)@\(host)", "Connect", "Log in with this password")
        case .password: (prompt.host.map { "Password for \($0.displayName)" } ?? "Password", "Connect", "Log in with this password")
        case .passphrase: ("Passphrase", "Unlock", "Unlock the key with this passphrase")
        case .other: ("\(question.session.host.displayName) asks", "Continue", "Send this answer to the server")
        }
    }

    private func send() {
        app.answer(question, isHostKey ? .trust : PromptAnswer(text, remember: remember))
    }

    // MARK: Trust

    /// The way to the server, then its key's fingerprint as a picture and as text, to compare with the one the
    /// server's administrator gives.
    @ViewBuilder private func trust(_ name: String, _ fingerprint: String) -> some View {
        let jump = question.session.jump
        // With a jump host either server may be new: ssh names the one it asks about "host", or "[host]:port".
        let jumpAsks = jump.map { jump in
            let port = jump.port ?? 22
            return name == (port == 22 ? jump.hostname : "[\(jump.hostname)]:\(port)")
        } ?? false
        Section {
            VStack(spacing: 12) {
                FingerprintPicture(fingerprint: fingerprint)
                Text(fingerprint)
                    .font(.footnote.monospaced())
                    .multilineTextAlignment(.center)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            Button("Copy to Compare", systemImage: "doc.on.doc") { UIPasteboard.general.string = fingerprint }
                .help("Copy the fingerprint to compare it with the one you were given")
        } header: {
            HStack(spacing: 6) {
                chip(UIDevice.current.model, asks: false)
                if let jump {
                    arrow
                    chip(jump.displayName, asks: jumpAsks)
                }
                arrow
                chip(question.session.host.displayName, asks: !jumpAsks)
            }
            .frame(maxWidth: .infinity)
            .textCase(nil)
            .accessibilityElement(children: .combine)
        } footer: {
            Text("AirSCP hasn't connected to this server before. Trust it if its fingerprint matches the one the "
                 + "server's administrator gave you: AirSCP then remembers its key and warns you if it ever changes.")
        }
    }

    private var arrow: some View {
        Image(systemName: "arrow.right").font(.caption).foregroundStyle(.secondary).accessibilityHidden(true)
    }

    /// A stop on the way to the server; the one whose key this is stands out.
    private func chip(_ name: String, asks: Bool) -> some View {
        HStack(spacing: 4) {
            Text(name).lineLimit(1)
            if asks { Image(systemName: "key.fill").foregroundStyle(.orange).accessibilityLabel("asks to be trusted") }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(Color.primary)  // not the header's grey
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background((asks ? Color.orange : Color.gray).opacity(0.2), in: .capsule)
    }

    // MARK: Password, passphrase, code

    /// The keyboard is up at once, and Return sends the answer.
    @ViewBuilder private var answer: some View {
        let noun = prompt.kind == .passphrase ? "passphrase" : prompt.kind == .other ? "answer" : "password"
        Section {
            Group {
                if prompt.kind == .other {  // mostly a verification code
                    TextField(noun.capitalized, text: $text)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.numbersAndPunctuation)
                } else {
                    SecureField(noun.capitalized, text: $text)
                        .textContentType(prompt.kind == .passphrase ? nil : .password)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .focused($focused)
            .onAppear { focused = true }
            .submitLabel(.go)
            .onSubmit(send)
            .accessibilityIdentifier("answer")
            .help("Type the \(noun): it goes to the server only")
            // A quick connect's server isn't saved: no connect would use its password again.
            if prompt.canRemember && app.data.hosts.contains(where: { $0.id == prompt.host?.id }) {
                Toggle("Remember in Keychain", isOn: $remember)
                    .help("Save the password in the Keychain so the next connect doesn't ask (off by default)")
            }
        } header: {
            if prompt.kind == .passphrase || prompt.kind == .other {  // ssh's words: "Enter passphrase for key '…':"
                Text(prompt.text.trimmingCharacters(in: .whitespacesAndNewlines)).textCase(nil)
            }
        } footer: {
            if prompt.retry {
                Text("That \(noun) wasn't accepted. Try again.").foregroundStyle(.red)
            }
        }
    }
}

/// A key's SHA-256 fingerprint as 8 × 4 coloured cells, one hue per byte: another key looks different at a glance.
/// VoiceOver skips it: the fingerprint's text follows.
struct FingerprintPicture: View {
    let fingerprint: String

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(22), spacing: 4), count: 8), spacing: 4) {
            ForEach(Array(bytes.enumerated()), id: \.offset) { _, byte in
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(hue: Double(byte) / 256, saturation: 0.6, brightness: 0.9))
                    .frame(height: 22)
            }
        }
        .accessibilityHidden(true)
    }

    /// "SHA256:" and the hash in base64 without its padding; none (no picture) for another kind of fingerprint.
    private var bytes: [UInt8] {
        guard fingerprint.hasPrefix("SHA256:") else { return [] }
        let base64 = String(fingerprint.dropFirst("SHA256:".count))
        let padded = base64.padding(toLength: (base64.count + 3) / 4 * 4, withPad: "=", startingAt: 0)
        return [UInt8](Data(base64Encoded: padded) ?? Data())
    }
}
