import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AirSCP
@testable import AirSCPCore

// PLAN.md K.1, K.2 and U.4 through the app's windows and agent control: New Key Pair, Export for PuTTY and Import Key
// in the Keys window (keys in scratch folders, never ~/.ssh); Generate New Key… in the host editor, installed on a
// throwaway sshd and used to log in; the orange shield and the snapshot's check fields. With the other heavy window
// tests, one at a time.

extension FeatureRoundAppTests {
    @MainActor @Test func theKeysWindowMakesExportsAndImportsKeys() async throws {
        _ = NSApplication.shared
        let folder = try scratch(), downloads = try scratch()
        let model = testModel([SSHHost(label: "web", hostname: "web")])
        model.data.settings.downloadFolder = downloads
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        // The Keys window as KeysWindowController makes it, on a scratch folder.
        let keys = KeysModel(folder: folder, askpass: askpass.environment(for: KeysModel.askpassID))
        let window = NSWindow(contentRect: NSRect(x: -21000, y: -21500, width: 900, height: 480), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.title = "Keys"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: KeysView(keys: keys, model: model, install: { _, _ in }, report: { _, _ in }))
        let asked = Recorder<String>()
        askpass.setHandler({ request, reply in
            asked.append(request.prompt)
            keys.reply(to: request, on: window, reply)
        }, for: KeysModel.askpassID)
        let (main, _, dir) = try agentWindow(model, askpass)
        let agent = try AgentServer(main: main, model: model, directory: URL(fileURLWithPath: dir + "2"), windows: { [window] })
        window.orderFront(nil)
        defer {
            agent.close()
            window.orderOut(nil)
            main.window?.orderOut(nil)
        }
        let clipboard = NSPasteboard.general.string(forType: .string)
        defer {
            NSPasteboard.general.clearContents()
            if let clipboard { NSPasteboard.general.setString(clipboard, forType: .string) }
        }

        // New Key Pair: ECDSA 384 in PKCS#8 with a passphrase; ssh-keygen's questions are answered from the sheet.
        #expect(await call(agent, "press", ["title": "New Key Pair…", "in": "window:Keys"]).error == nil)
        #expect(await call(agent, "wait", ["until": "sheet", "text": "New Key Pair", "timeout": 10]).error == nil)
        // Kinds kept on a security key are offered only where ssh-keygen can make them (macOS's own can't).
        var kinds: [String] = []
        _ = await eventually(timeout: 10) {  // SwiftUI's controls come a moment after the sheet
            let shown = await call(agent, "snapshot", ["include": ["sheets"]])
            kinds = field((shown["sheets"] as? [[String: Any]])?.last, "newKey.type")?["options"] as? [String] ?? []
            return !kinds.isEmpty
        }
        #expect(kinds.contains("Ed25519 (recommended)") && kinds.contains { $0.contains("-SK") } == Keys.securityKeysSupported,
                "\(kinds)")
        for (id, value) in [("newKey.type", "ECDSA 384"), ("newKey.name", "id_work"), ("newKey.comment", "me@work"),
                            ("newKey.passphrase", "key pass")] as [(String, Any)] {
            let reply = await call(agent, "set", ["id": id, "value": value, "in": "window:Keys"])
            #expect(reply.error == nil, "\(id): \(reply.error ?? "")")
        }
        #expect(await call(agent, "set", ["id": "newKey.confirm", "value": "key pass", "in": "window:Keys"]).error == nil)
        _ = await call(agent, "press", ["id": "newKey.advanced", "in": "window:Keys"])
        #expect(await call(agent, "set", ["id": "newKey.format", "value": "PKCS#8", "in": "window:Keys"]).error == nil)
        #expect(await call(agent, "press", ["title": "Generate", "in": "window:Keys"]).error == nil)
        var reply = await call(agent, "wait", ["until": "sheet", "text": "Key pair created", "timeout": 30])
        #expect(reply.error == nil, "\(reply.json) \(reply.error ?? "")")
        let key = folder + "/id_work"
        #expect(read(key)?.hasPrefix("-----BEGIN ENCRYPTED PRIVATE KEY-----") == true)
        try await run(["/usr/bin/ssh-keygen", "-y", "-P", "key pass", "-f", key])
        #expect(asked.all.count == 2 && asked.all.allSatisfy { $0.lowercased().contains("passphrase") })
        // Copied after generating, in OpenSSH's format; the sheet shows the fingerprint.
        let pub = try #require(read(key + ".pub")).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(await eventually { NSPasteboard.general.string(forType: .string) == pub })
        #expect(keys.selected?.privateKey == key && keys.selected?.type == "ECDSA" && keys.selected?.bits == 384)

        // Export for PuTTY from the result: the key's passphrase is the one just typed (no question).
        #expect(await call(agent, "press", ["title": "Export as PuTTY Key (.ppk)…", "in": "window:Keys"]).error == nil)
        let ppk = downloads + "/id_work.ppk"
        reply = await call(agent, "press", ["title": "Export…", "in": "window:Keys", "file": ppk])
        #expect(reply.error == nil, "\(reply.error ?? "")")
        reply = await call(agent, "wait", ["until": "sheet", "text": "PuTTY key saved", "timeout": 30])
        #expect(reply.error == nil, "\(reply.json) \(reply.error ?? "")")
        let exported = try PuTTYKey.read(try #require(read(ppk)), passphrase: "")
        #expect(read(ppk)?.hasPrefix("PuTTY-User-Key-File-3: ecdsa-sha2-nistp384\nEncryption: none\nComment: me@work") == true)
        #expect(PuTTYKey.publicLine(exported) == pub && asked.all.count == 3)
        #expect(await call(agent, "press", ["title": "Done", "in": "window:Keys"]).error == nil)

        // Import Key: that .ppk back, as another name, with a new passphrase.
        #expect(await call(agent, "press", ["title": "Import Key…", "in": "window:Keys", "file": ppk]).error == nil)
        #expect(await call(agent, "wait", ["until": "sheet", "text": "Import", "timeout": 10]).error == nil)
        #expect(await call(agent, "set", ["id": "importKey.name", "value": "id_from_putty", "in": "window:Keys"]).error == nil)
        #expect(await call(agent, "set", ["id": "importKey.passphrase", "value": "new pass", "in": "window:Keys"]).error == nil)
        #expect(await call(agent, "set", ["id": "importKey.confirm", "value": "new pass", "in": "window:Keys"]).error == nil)
        #expect(await call(agent, "press", ["title": "Import", "in": "window:Keys"]).error == nil)
        reply = await call(agent, "wait", ["until": "sheet", "text": "Key imported", "timeout": 30])
        #expect(reply.error == nil, "\(reply.json) \(reply.error ?? "")")
        let derived = try await run(["/usr/bin/ssh-keygen", "-y", "-P", "new pass", "-f", folder + "/id_from_putty"]).output
        #expect(derived.split(separator: " ").prefix(2) == pub.split(separator: " ").prefix(2))
        #expect(await call(agent, "press", ["title": "Done", "in": "window:Keys"]).error == nil)
        #expect(keys.pairs.map { RemotePath.name($0.privateKey) } == ["id_from_putty", "id_work"])
        // Copy Public Key's menu: the other formats.
        #expect(await call(agent, "select", ["in": "window:Keys", "names": ["id_work"]]).error == nil)
        reply = await call(agent, "set", ["id": "keys.copy", "value": "SSH2 (RFC 4716)", "in": "window:Keys"])
        #expect(reply.error == nil, "\(reply.error ?? "")")
        #expect(await eventually { NSPasteboard.general.string(forType: .string)?.hasPrefix("---- BEGIN SSH2 PUBLIC KEY ----") == true })
        #expect(await call(agent, "set", ["id": "keys.copy", "value": "PEM (PKCS#8)", "in": "window:Keys"]).error == nil)
        #expect(await eventually { NSPasteboard.general.string(forType: .string)?.hasPrefix("-----BEGIN PUBLIC KEY-----") == true })
        // An Ed25519 key has no PEM public key: that choice is off, saying why, for agents too.
        _ = try await run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", "edwards", "-f", folder + "/id_edwards"])
        await keys.refresh()
        #expect(await call(agent, "select", ["in": "window:Keys", "names": ["id_edwards"]]).error == nil)
        let pem = await call(agent, "set", ["id": "keys.copy", "value": "PEM (PKCS#8)", "in": "window:Keys"])
        #expect(pem.error?.contains("can't be chosen") == true, "\(pem.error ?? "") \(pem.json)")
        // Key sizes as ssh-keygen writes them: RSA 2048, not 2,048.
        _ = try await run(["/usr/bin/ssh-keygen", "-q", "-t", "rsa", "-b", "2048", "-N", "", "-f", folder + "/id_rsa2k"])
        await keys.refresh()
        let rsa = await call(agent, "select", ["in": "window:Keys", "names": ["RSA 2048"]])  // a row by its cells' text
        #expect(rsa.error == nil, "\(rsa.error ?? "")")
        // A .ppk dropped on the window's list opens Import Key for it, as a drag there does (agents: drop target=keys).
        reply = await call(agent, "drop", ["files": [ppk], "target": "keys"])
        #expect(reply.error == nil, "\(reply.error ?? "")")
        #expect(await call(agent, "wait", ["until": "sheet", "text": "Import", "timeout": 10]).error == nil)
        #expect(await call(agent, "set", ["id": "importKey.name", "value": "id_dropped", "in": "window:Keys"]).error == nil)
        #expect(await call(agent, "press", ["title": "Import", "in": "window:Keys"]).error == nil)
        reply = await call(agent, "wait", ["until": "sheet", "text": "Key imported", "timeout": 30])
        #expect(reply.error == nil, "\(reply.json) \(reply.error ?? "")")
        #expect(await call(agent, "press", ["title": "Done", "in": "window:Keys"]).error == nil)
        #expect(read(folder + "/id_dropped.pub")?.split(separator: " ").prefix(2) == pub.split(separator: " ").prefix(2))
        // Nothing secret went into a command line.
        #expect(!keys.log.entries.contains { ["key pass", "new pass"].contains(where: $0.command.contains) })
    }

    /// The host editor's Generate New Key…: the key is made, installed on the server with the settings as typed, and
    /// used for the host, which then logs in with it.
    @MainActor @Test func theHostEditorGeneratesInstallsAndUsesANewKey() async throws {
        _ = NSApplication.shared
        try await withServer { @MainActor server in
            var host = server.host()
            host.label = "keyed"
            let folder = try server.scratch()
            let model = testModel([host])
            model.data.settings.keyFolder = folder  // never ~/.ssh
            let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
            defer { askpass.close() }
            let (main, agent, _) = try agentWindow(model, askpass)
            defer {
                agent.close()
                main.window?.orderOut(nil)
            }
            _ = await call(agent, "select", ["pane": "sidebar", "names": ["keyed"]])
            _ = await call(agent, "menu", ["path": "Host > Edit…"])
            #expect(await call(agent, "wait", ["until": "sheet", "text": "Edit", "timeout": 10]).error == nil)
            #expect(await call(agent, "set", ["id": "hostEditor.login", "value": "Generate New Key…"]).error == nil)
            var reply = await call(agent, "wait", ["until": "sheet", "text": "New Key Pair", "timeout": 10])
            #expect(reply.error == nil, "\(reply.json) \(reply.error ?? "")")
            #expect(await call(agent, "set", ["id": "newKey.copy", "value": false]).error == nil)  // the user's clipboard
            #expect(await call(agent, "press", ["title": "Generate"]).error == nil)
            reply = await call(agent, "wait", ["until": "sheet", "text": "Key pair created", "timeout": 30])
            #expect(reply.error == nil, "\(reply.json) \(reply.error ?? "")")
            let key = folder + "/id_ed25519_keyed"  // named after the host
            #expect(read(key + ".pub")?.hasPrefix("ssh-ed25519 ") == true)

            // Install on This Host: logs in as typed (the old key), adds the new one to authorized_keys, and logs in with
            // it from now on (Save keeps that); the host then logs in with it.
            #expect(await call(agent, "press", ["title": "Install on This Host"]).error == nil)
            reply = await call(agent, "wait", ["until": "sheet", "text": "Installed id_ed25519_keyed", "timeout": 30])
            #expect(reply.error == nil, "\(reply.json) \(reply.error ?? "")")
            let pub = try #require(read(key + ".pub")).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(read(server.path(".ssh/authorized_keys"))?.contains(pub) == true)
            #expect(await call(agent, "press", ["title": "Save"]).error == nil)
            #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 10]).error == nil)
            let saved = try #require(model.host(host.id))
            #expect(saved.auth == .keyFile && saved.keyFile == key)
            let session = try server.session(saved)
            try await session.connect()
            #expect(session.state == .connected)

            // Use for This Host, without installing: Log in with names the second key.
            _ = await call(agent, "menu", ["path": "Host > Edit…"])
            #expect(await call(agent, "wait", ["until": "sheet", "text": "Edit", "timeout": 10]).error == nil)
            #expect(await call(agent, "set", ["id": "hostEditor.login", "value": "Generate New Key…"]).error == nil)
            #expect(await call(agent, "wait", ["until": "sheet", "text": "New Key Pair", "timeout": 10]).error == nil)
            _ = await call(agent, "set", ["id": "newKey.copy", "value": false])
            #expect(await call(agent, "press", ["title": "Generate"]).error == nil)
            #expect(await call(agent, "wait", ["until": "sheet", "text": "Key pair created", "timeout": 30]).error == nil)
            #expect(await call(agent, "press", ["title": "Use for This Host"]).error == nil)
            #expect(await call(agent, "wait", ["until": "sheet", "text": "Edit", "timeout": 10]).error == nil)
            try await Task.sleep(nanoseconds: 300_000_000)
            #expect(await call(agent, "press", ["title": "Save"]).error == nil)
            #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 10]).error == nil)
            #expect(model.host(host.id)?.keyFile == key + "_2")
        }
    }

    /// Checks off: the sidebar's orange shield and the banner say so; the snapshot carries every host's and desktop's
    /// check (PLAN.md U.4); a new host and desktop start with Settings ▸ Security's choice.
    @MainActor @Test func checksOffShowAShieldAndAgentsSeeEveryCheck() async throws {
        _ = NSApplication.shared
        var open = SSHHost(label: "lab printer", hostname: "printer")
        open.hostKeyCheck = .off
        var trusting = SSHHost(label: "dev box", hostname: "dev")
        trusting.hostKeyCheck = .acceptNew
        let model = testModel([open, trusting])
        var desktop = RDPEntry(label: "corp desktop", hostname: "win")
        desktop.certificateCheck = .companyCA
        desktop.caFile = "/Library/corp-ca.pem"
        var test = RDPEntry(label: "test desktop", hostname: "win2")
        test.certificateCheck = .off
        model.data.rdpEntries = [desktop, test]
        model.data.settings.hostKeyCheck = .acceptNew
        model.data.settings.certificateCheck = .trustNew
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let (main, agent, _) = try agentWindow(model, askpass)
        defer {
            agent.close()
            main.window?.orderOut(nil)
        }
        let sidebar = try #require((await call(agent, "snapshot", ["include": ["sidebar"]]))["sidebar"] as? [String: Any])
        let hosts = (sidebar["sections"] as? [[String: Any]])?.flatMap { $0["hosts"] as? [[String: Any]] ?? [] } ?? []
        let byName = Dictionary(uniqueKeysWithValues: hosts.map { ($0["name"] as? String ?? "", $0) })
        #expect(byName["lab printer"]?["hostKeyCheck"] as? String == "off")
        #expect((byName["lab printer"]?["shield"] as? String)?.contains("anyone on the network could impersonate it") == true)
        #expect(byName["dev box"]?["hostKeyCheck"] as? String == "acceptNew" && byName["dev box"]?["shield"] == nil)
        let desktops = sidebar["rdp"] as? [[String: Any]] ?? []
        #expect(desktops.map { $0["certificateCheck"] as? String } == ["companyCA", "off"])
        #expect(desktops.first?["caFile"] as? String == "/Library/corp-ca.pem" && desktops.first?["shield"] == nil)
        #expect((desktops.last?["shield"] as? String)?.hasPrefix("Certificate checks are off") == true)
        // The rows that show the shield say why in their tooltip too (a row is one element to VoiceOver and agents).
        let elements = try #require((await call(agent, "snapshot", ["include": ["elements"]]))["elements"] as? [[String: Any]])
        let warned = Set(elements.compactMap { $0["help"] as? String }.filter { $0.contains("checks are off for this server") })
        #expect(warned.count == 2 && warned.contains { $0.hasPrefix("lab printer") } && warned.contains { $0.contains("win2") },
                "\(warned)")
        // The workspace says it while not connected too; the desktop's bar shows the shield.
        _ = await call(agent, "select", ["pane": "sidebar", "names": ["test desktop"]])
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(main.desktops.values.first?.bar.checksOff == true)

        // New ones start with Settings ▸ Security's choice.
        main.newHost()
        #expect(await call(agent, "wait", ["until": "sheet", "text": "New Host", "timeout": 10]).error == nil)
        _ = await call(agent, "set", ["id": "hostEditor.hostname", "value": "fresh"])
        _ = await call(agent, "press", ["title": "Add"])
        #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 10]).error == nil)
        #expect(model.data.hosts.first { $0.hostname == "fresh" }?.hostKeyCheck == .acceptNew)
        main.newRemoteDesktop()
        #expect(await call(agent, "wait", ["until": "sheet", "text": "New Remote Desktop", "timeout": 10]).error == nil)
        _ = await call(agent, "set", ["id": "rdpEditor.hostname", "value": "fresh-win"])
        _ = await call(agent, "press", ["title": "Add"])
        #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 10]).error == nil)
        #expect(model.data.rdpEntries.first { $0.hostname == "fresh-win" }?.certificateCheck == .trustNew)
    }

    /// "Remember in Keychain" ticked for a password stays ticked when the question comes again ("That password wasn't
    /// accepted"): a mistyped password is still saved once it is right.
    @MainActor @Test func rememberStaysTickedWhenAPasswordIsAskedAgain() async throws {
        _ = NSApplication.shared
        try await withServer(TestServer.Options(passwords: true)) { @MainActor server in
            var host = server.host(key: "/nonexistent-key")
            host.auth = .password
            host.label = "pw"
            let model = testModel([host])
            let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
            defer { askpass.close() }
            let (main, agent, _) = try agentWindow(model, askpass)
            defer {
                agent.close()
                main.window?.orderOut(nil)
            }
            _ = await call(agent, "select", ["pane": "sidebar", "names": ["pw"]])
            _ = await call(agent, "menu", ["path": "Host > Connect"])
            #expect(await call(agent, "wait", ["until": "sheet", "text": "prompt.answer", "timeout": 60]).error == nil)
            _ = await call(agent, "set", ["id": "prompt.answer", "value": "mistyped-1"])
            // Ticked as a click does (the test process has no running NSApp: a click there ends its run loop).
            func checkboxes(_ view: NSView?) -> [NSButton] {
                ((view as? NSButton).map { [$0] } ?? []) + (view?.subviews.flatMap(checkboxes) ?? [])
            }
            try #require(checkboxes(main.window?.attachedSheet?.contentView).first { $0.title == "Remember in Keychain" }).state = .on
            _ = await call(agent, "press", ["title": "OK"])
            let again = await call(agent, "wait", ["until": "sheet", "text": "wasn't accepted", "timeout": 60])
            #expect((field(again.json, "prompt.remember")?["value"] as? NSNumber)?.boolValue == true, "\(again.json) \(again.error ?? "")")
            _ = await call(agent, "press", ["title": "Cancel"])
            await main.selectedWorkspace?.connection.disconnect()
        }
    }
}
