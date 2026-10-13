import AppKit
import Foundation
import Testing
@testable import AirSCP
@testable import AirSCPCore

// Release 1.1's file items against the Docker lab (AIRSCP_DOCKER=1): owners and groups by name with GNU and BusyBox ls
// and over sftp, and the editor's question when someone saved the file on the server after it was opened.

@Suite(.enabled(if: Lab.enabled, "Docker lab: AIRSCP_DOCKER=1 ./test.sh"))
struct FilesLabTests {
    /// The panes showed uid and gid numbers while Get Info showed names: the listing names them too, with GNU ls
    /// (Debian) and BusyBox ls (Alpine), each with its number for the tooltip, and sorts by them (and their chown takes
    /// "--" before the owner). Over sftp (BusyBox's ls can't print a name outside ASCII) they come by name without
    /// numbers; in the sftp-only chroot, which has no names for them, as numbers.
    @Test func ownersAndGroupsByNameOnLinux() async throws {
        try await withLab { lab in
            for host in [Lab.target(), Lab.minimal()] {
                let session = try await lab.connected(host)
                let home = try #require(try await session.list("/home").first { $0.name == "dev" })
                #expect(home.owner == "dev" && home.group == "dev" && home.ownerID == 1000 && home.groupID == 1000,
                        "\(host.port): \(home)")
                let etc = try #require(try await session.list("/").first { $0.name == "etc" })
                #expect(etc.owner == "root" && etc.group == "root" && etc.ownerID == 0 && etc.groupID == 0, "\(host.port): \(etc)")
                // As Get Info says.
                let info = try await session.info(home)
                #expect(info.owner == home.owner && info.group == home.group, "\(host.port)")
                // dev's files and one of root's, sorted by owner: by the names, each with its number.
                let dir = try await lab.folder(on: session, in: "/home/dev")
                try await session.shell("cd \(Quote.shell(dir)) && echo x > mine.txt && ln -s /etc etc-link")
                let roots = try await session.list(host.port == Lab.minimalPort ? "/" : "/home/dev/perf")  // .dockerenv, 2g.bin
                let files = try await session.list(dir) + [try #require(roots.first { $0.kind == .file && $0.owner == "root" })]
                for ascending in [true, false] {
                    let sorted = FileList.sorted(files.map(FileItem.init), by: "owner", ascending: ascending, folderSizes: [:])
                    let owners = ascending ? ["dev", "dev", "root"] : ["root", "dev", "dev"]
                    #expect(sorted.map(\.owner) == owners && sorted.map(\.ownerID) == owners.map { $0 == "dev" ? 1000 : 0 },
                            "\(host.port): \(sorted.map(\.name))")
                }
                // GNU's and BusyBox's chown take "--" before the owner: a group by its name, and an owner typed with a
                // leading "-" as a user they don't know (never an option).
                let mine = try #require(files.first { $0.name == "mine.txt" })
                try await session.setOwner([mine], owner: "", group: "dev")
                let refused = await #expect(throws: AirSCPError.self) { try await session.setOwner([mine], owner: "-h", group: "") }
                let words = refused?.details ?? ""
                #expect(words.contains("-h") && words.contains("user") && !words.lowercased().contains("usage"), "\(host.port): \(words)")
            }
            let minimal = try await lab.connected(Lab.minimal())
            let dir = try await lab.folder(on: minimal, in: "/home/dev")
            try await minimal.shell("cd \(Quote.shell(dir)) && touch \(Quote.shell("caf\u{E9}.txt"))")
            let viaSFTP = try #require(try await minimal.list(dir).first)
            #expect(viaSFTP.name == "caf\u{E9}.txt" && viaSFTP.owner == "dev" && viaSFTP.group == "dev" && viaSFTP.ownerID == nil,
                    "\(viaSFTP)")
            let sftp = try await lab.connected(Lab.target("sftponly"))
            let upload = try #require(try await sftp.list("/").first { $0.name == "upload" })
            #expect(upload.owner == "1001" && upload.group == "1001" && upload.ownerID == nil, "\(upload)")
        }
    }

    /// Someone saves the file through another connection while it is open in the editor: Save asks instead of
    /// overwriting their change (Debian, Alpine and the sftp-only account). Show Server Version shows their text; Save
    /// then overwrites it, and Overwrite does at once.
    @MainActor @Test func theEditorAsksWhenTheFileChangedOnTheServer() async throws {
        _ = NSApplication.shared
        try await withLab { @MainActor lab in
            for make in [{ Lab.target() }, { Lab.minimal() }, { Lab.target("sftponly") }] {
                let host = make()
                let session = try await lab.connected(host)
                let someone = try await lab.connected(make())  // another connection to the same account
                let dir = try await lab.folder(on: session, in: host.username == "sftponly" ? "/upload" : "/home/dev")
                let file = dir + "/lab-editor.conf"
                try await session.writeText("port=80\n", to: file)
                let editor = RemoteEditor(session: session, path: file, text: try await session.readText(file))
                let window = try #require(editor.window)
                window.setFrameOrigin(NSPoint(x: -30000, y: -30000))
                var saved = 0
                editor.onSaved = { saved += 1 }
                let text = try #require(window.initialFirstResponder as? NSTextView)
                /// The question Save asked.
                @MainActor func question() async -> NSWindow? {
                    _ = await eventually(timeout: 30) { window.attachedSheet != nil }
                    return window.attachedSheet
                }

                try await someone.writeText("port=81\n", to: file)
                text.string = "port=8080\n"
                editor.save(nil)
                var sheet = try #require(await question(), "\(host.label)")
                #expect(try await someone.readText(file) == "port=81\n" && saved == 0, "\(host.label)")
                window.endSheet(sheet, returnCode: .alertSecondButtonReturn)  // Show Server Version
                let theirs = try #require(NSApp.windows.first { $0.isVisible && $0.title.hasPrefix("lab-editor.conf on the server — ") })
                #expect(((theirs.contentView as? NSScrollView)?.documentView as? NSTextView)?.string == "port=81\n", "\(host.label)")
                editor.save(nil)
                #expect(await eventually(timeout: 30) { saved == 1 } && window.attachedSheet == nil, "\(host.label)")
                #expect(try await someone.readText(file) == "port=8080\n", "\(host.label)")

                try await someone.writeText("port=82\n", to: file)
                text.string = "port=9090\n"
                editor.save(nil)
                sheet = try #require(await question(), "\(host.label)")
                window.endSheet(sheet, returnCode: .alertFirstButtonReturn)  // Overwrite
                #expect(await eventually(timeout: 30) { saved == 2 }, "\(host.label)")
                #expect(try await someone.readText(file) == "port=9090\n", "\(host.label)")
                window.isDocumentEdited = false
                editor.close()
                #expect(!theirs.isVisible)
            }
        }
    }
}

/// Host ▸ Change Password…: passwd in the Terminal tab, then the offer to update the saved password. The
/// lab's own "passwd" container; the password is set back at the end so that the next run starts the same.
@Suite(.enabled(if: Lab.enabled, "Docker lab: AIRSCP_DOCKER=1 ./test.sh"), .serialized)
@MainActor struct ChangePasswordLabTests {
    static let first = "Lab-Pass-Alpha-7", second = "Lab-Pass-Bravo-9"

    @Test func changePasswordRunsPasswdAndUpdatesTheSavedOne() async throws {
        _ = NSApplication.shared
        var host = Lab.host("changer", port: 42206, password: true)
        host.label = "changer"
        host.hostKeyCheck = .acceptNew
        let passwords = Passwords()
        passwords.saved[host.id.uuidString] = Self.first
        let model = testModel([host], passwords: passwords)
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let (main, agent, _) = try agentWindow(model, askpass)
        defer {
            agent.close()
            main.window?.orderOut(nil)
        }
        _ = await call(agent, "select", ["pane": "sidebar", "names": ["changer"]])
        _ = await call(agent, "menu", ["path": "Host > Connect"])
        if await call(agent, "wait", ["until": "sheet", "text": "prompt.answer", "timeout": 30]).error == nil {
            _ = await call(agent, "set", ["id": "prompt.answer", "value": Self.first])
            _ = await call(agent, "press", ["title": "OK"])
        }
        #expect(await call(agent, "wait", ["until": "connected", "timeout": 60]).error == nil)
        let workspace = try #require(main.selectedWorkspace)
        func screen() -> String { workspace.terminal.session?.screen.text ?? "" }
        // shadow's passwd asks "Current password:", "New password:", "Re-enter new password:" (BusyBox's: Old, New, Retype).
        func answer(_ prompts: [String], _ text: String) async -> Bool {
            let before = screen().components(separatedBy: "\n").count
            guard await eventually(timeout: 30, { let lines = screen().components(separatedBy: "\n")
                return lines.suffix(max(1, lines.count - before + 1)).contains { line in prompts.contains { line.contains($0) } } })
            else { return false }
            // As a person types after the prompt: passwd flushes input already waiting as it turns echo off (TCSAFLUSH),
            // so an answer that arrives with the prompt is thrown away.
            try? await Task.sleep(nanoseconds: 700_000_000)
            workspace.terminal.session?.send(text + "\n")
            return true
        }
        // First to the second password, saving it; then back, so the next run starts from the first.
        for (old, new) in [(Self.first, Self.second), (Self.second, Self.first)] {
            workspace.terminal.session?.send("clear\n")
            let started = await call(agent, "menu", ["path": "Host > Change Password…"])
            #expect(started.error == nil)
            // The second time the tab's shell is open: AirSCP asks before typing passwd into it.
            if (sheet(started)?["title"] as? String)?.hasPrefix("Type passwd") == true {
                _ = await call(agent, "press", ["title": "Run passwd"])
            }
            #expect(await answer(["Current password", "Old password"], old), "\(screen())")
            #expect(await answer(["New password"], new), "\(screen())")
            #expect(await answer(["Re-enter new password", "Retype new password", "Retype password"], new), "\(screen())")
            let offer = await call(agent, "wait", ["until": "sheet", "text": "Update the password", "timeout": 30])
            #expect(offer.error == nil, "\(screen()) \(offer.error ?? "")")
            _ = await call(agent, "set", ["id": "prompt.newPassword", "value": new])
            _ = await call(agent, "press", ["title": "Save"])
            #expect(await eventually { passwords.saved[host.id.uuidString] == new })
        }
        await workspace.connection.disconnect()
    }
}

/// Browse and transfer as root (sudo NOPASSWD, the lab's "sudo" container): listings, sftp, uploads and downloads
/// happen as root; scp, which can't, isn't used.
@Suite(.enabled(if: Lab.enabled, "Docker lab: AIRSCP_DOCKER=1 ./test.sh"))
struct SudoLabTests {
    @Test func filesAreBrowsedAndCopiedAsRoot() async throws {
        try await withLab { lab in
            var host = Lab.host("dev", port: 42205)
            host.sudoUser = "root"
            let session = try await lab.connected(host)
            #expect(session.capabilities.sftpServer != nil && session.copiesWithSFTP)
            // /root is root's own: listed and written as root, with the shell and with sftp.
            let dir = "/root/airscp-" + UUID().uuidString.prefix(8)
            try await session.makeDirectory(dir)
            try await session.shell("echo hi > \(Quote.shell(dir))/made.txt")
            let made = try #require(try await session.list(dir).first { $0.name == "made.txt" })
            #expect(made.owner == "root")
            let local = try scratch()
            try write("from the Mac", to: local + "/up.txt")
            session.transfers.upload(local + "/up.txt", to: dir + "/up.txt", isFolder: false)
            session.transfers.download(dir + "/made.txt", to: local + "/made.txt", isFolder: false)
            await session.transfers.waitUntilIdle()
            #expect(session.transfers.jobs.allSatisfy { $0.status == .done }, "\(session.transfers.jobs.map(\.status))")
            #expect(read(local + "/made.txt") == "hi\n")
            #expect(try await session.list(dir).first { $0.name == "up.txt" }?.owner == "root")
            #expect(!(await lab.logEntries()).contains { $0.command.hasPrefix("/usr/bin/scp") })
            try await session.shell("rm -rf -- \(Quote.shell(dir))")
        }
    }
}
