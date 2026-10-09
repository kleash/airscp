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
    /// (Debian) and BusyBox ls (Alpine), each with its number for the tooltip, and sorts by them. Over sftp (BusyBox's ls
    /// can't print a name outside ASCII) they come by name without numbers; in the sftp-only chroot, which has no names
    /// for them, as numbers.
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
