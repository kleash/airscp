import Darwin
import Foundation
import Testing
@testable import AirSCPCore

@Test func listMakeRenameDelete() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let home = server.home
        try await session.makeDirectory(server.path("docs"))
        try await session.createFile(server.path("docs/empty.txt"))
        try write("hello\n", to: server.path("docs/a.txt"))
        try write("other\n", to: server.path("docs/b.txt"))
        try FileManager.default.createSymbolicLink(atPath: server.path("link-to-docs"), withDestinationPath: "docs")
        try FileManager.default.createSymbolicLink(atPath: server.path("link-to-file"), withDestinationPath: "docs/a.txt")
        try FileManager.default.createSymbolicLink(atPath: server.path("dangling"), withDestinationPath: "nowhere")

        let top = try await session.list(home)
        #expect(top.map(\.name).sorted() == ["dangling", "docs", "link-to-docs", "link-to-file"])
        #expect(top.first { $0.name == "docs" }?.kind == .directory)
        #expect(top.first { $0.name == "link-to-docs" }?.kind == .symlink)
        let docs = try await session.list(server.path("docs"))
        #expect(docs.map(\.name).sorted() == ["a.txt", "b.txt", "empty.txt"])
        let a = try #require(docs.first { $0.name == "a.txt" })
        #expect(a.kind == .file && a.size == 6 && a.path == server.path("docs/a.txt") && a.mode == 0o644)
        #expect(abs(a.modified!.timeIntervalSinceNow) < 120)

        // A link to a folder lists the folder; a link to a file (or nothing) can't be listed: open it as a file.
        #expect(try await session.list(server.path("link-to-docs")).count == 3)
        for path in [server.path("link-to-file"), server.path("dangling"), server.path("missing")] {
            await #expect(throws: AirSCPError.self) { try await session.list(path) }
        }
        do {
            _ = try await session.list(server.path("missing"))
        } catch let error as AirSCPError {
            #expect(error.kind == .noSuchFile)
        }

        // Rename onto an existing name: the UI checks first; Keep both picks "b 2.txt"; sftp's rename replaces.
        #expect(Names.existing("b.txt", in: docs.map(\.name)) == "b.txt")
        let keepBoth = Names.unique("b.txt", existing: docs.map(\.name))
        try await session.rename(server.path("docs/a.txt"), to: server.path("docs/\(keepBoth)"))
        #expect(read(server.path("docs/b 2.txt")) == "hello\n" && read(server.path("docs/b.txt")) == "other\n")
        try await session.rename(server.path("docs/b 2.txt"), to: server.path("docs/b.txt"))
        #expect(read(server.path("docs/b.txt")) == "hello\n" && !exists(server.path("docs/b 2.txt")))
        // Moving into a folder that doesn't exist fails with the mapped error.
        do {
            try await session.rename(server.path("docs/b.txt"), to: server.path("nope/b.txt"))
            Issue.record("moved into a missing folder")
        } catch let error as AirSCPError {
            #expect(error.kind == .noSuchFile)
        }

        // Delete a file, a link (not its target) and a folder with everything in it (rm -rf on a shell host).
        let listed = try await session.list(home)
        try await session.delete(listed.filter { ["link-to-docs", "dangling"].contains($0.name) })
        #expect(!exists(server.path("link-to-docs")) && exists(server.path("docs/b.txt")))
        try await session.delete(listed.filter { $0.name == "docs" || $0.name == "link-to-file" })
        #expect(try await session.list(home).isEmpty)
        #expect((await server.logEntries()).contains { $0.command.contains("rm -rf --") })
        // Deleting a folder that isn't empty with rmdir is what "Failure" means.
        try rawMkdir(server.path("full"))
        try write("x", to: server.path("full/x"))
        do {
            try await session.sftp(["rmdir \(Quote.sftp(server.path("full")))"])
            Issue.record("rmdir removed a folder that isn't empty")
        } catch let error as AirSCPError {
            #expect(error.kind == .failure)
        }
    }
}

/// Owners and groups are listed by name, as Get Info shows them (the panes showed numbers): with a shell their numbers
/// come too, in the same command (for the tooltip); an sftp-only account gets the names sftp's `ls -l` shows.
@Test func ownersAndGroupsAreListedByName() async throws {
    var info = stat()
    func owner(of path: String) throws -> (user: String, group: String, gid: Int) {
        #expect(lstat(path, &info) == 0)
        return (String(cString: try #require(getpwuid(info.st_uid)).pointee.pw_name),
                String(cString: try #require(getgrgid(info.st_gid)).pointee.gr_name), Int(info.st_gid))
    }
    try await withServer { server in
        let session = try await server.connectedSession()
        try write("x", to: server.path("mine.txt"))
        let expected = try owner(of: server.path("mine.txt"))
        let before = await server.logEntries().count
        let entry = try #require(try await session.list(server.home).first { $0.name == "mine.txt" })
        #expect(entry.owner == expected.user && entry.group == expected.group, "\(entry)")
        #expect(entry.ownerID == Int(getuid()) && entry.groupID == expected.gid, "\(entry)")
        #expect((await server.logEntries()).count == before + 1)  // one command, as before
        let details = try await session.info(entry)
        #expect(details.owner == entry.owner && details.group == entry.group)
    }
    try await withServer(TestServer.Options(sftpOnly: true)) { server in
        let session = try await server.connectedSession()
        try write("x", to: server.path("mine.txt"))
        let expected = try owner(of: server.path("mine.txt"))
        let entry = try #require(try await session.list(server.home).first { $0.name == "mine.txt" })
        #expect(entry.owner == expected.user && entry.group == expected.group && entry.ownerID == nil, "\(entry)")
    }
}

/// Files and links on a shell host go in one command: sftp's rm takes two round trips a file (50 files took half a
/// minute over a 300 ms link). Every one goes, with its exact name; a link to a folder only as the link. Without a
/// shell: sftp's rm, in one batch.
@Test func filesAreDeletedInOneCommand() async throws {
    for sftpOnly in [false, true] {
        try await withServer(TestServer.Options(sftpOnly: sftpOnly)) { server in
            let session = try await server.connectedSession()
            try rawMkdir(server.path("many"))
            try rawMkdir(server.path("kept"))
            try rawCreate(server.path("kept/inside"), "x")
            // Names for more than one command line's worth (64 KB each), and names a shell would read as more.
            let names = (0..<900).map { "a fairly long name, from the old server, number \($0) of the project backups" }
                + ["sq'uote", "-rf", "$(touch pwned)", "back\\slash", "star *"]
            for name in names { try rawCreate(server.path("many/" + name), "x") }
            symlink("../kept", server.path("many/to-kept"))
            symlink("nowhere", server.path("many/dangling"))
            let listed = try await session.list(server.path("many"))
            #expect(listed.count == names.count + 2)
            let before = await server.logEntries().count
            try await session.delete(listed)
            #expect(rawNames(in: server.path("many")).isEmpty && read(server.path("kept/inside")) == "x")
            #expect(!rawExists(server.path("pwned")) && !rawExists(server.path("many/pwned")))
            let commands = (await server.logEntries()).dropFirst(before).map(\.command)
            #expect(commands.count == 1 && commands.allSatisfy { $0.contains(sftpOnly ? "sftp" : "rm -f --") },
                    "\(commands.map { $0.prefix(200) })")
        }
    }
}

/// A folder the account may not read is an error (the pane then keeps the folder it shows), never an empty folder:
/// on a shell host, and on an sftp-only account (whose sftp prints "remote readdir" but exits 0).
@Test func unreadableFoldersAreErrorsNotEmpty() async throws {
    for sftpOnly in [false, true] {
        try await withServer(TestServer.Options(sftpOnly: sftpOnly)) { server in
            let session = try await server.connectedSession()
            try rawMkdir(server.path("locked"))
            try write("x", to: server.path("locked/inside.txt"))
            chmod(server.path("locked"), 0o311)  // can go in, can't read
            do {
                let entries = try await session.list(server.path("locked"))
                Issue.record("listed \(entries.count) entries of a folder it may not read (sftp only: \(sftpOnly))")
            } catch let error as AirSCPError {
                #expect(error.kind == .permissionDenied, "sftp only: \(sftpOnly): \(error.kind) \(error.details)")
            }
            #expect(try await session.list(server.home).map(\.name) == ["locked"])
        }
    }
}

@Test func permissions() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        try rawMkdir(server.path("site"))
        try rawMkdir(server.path("site/sub"))
        try write("x", to: server.path("site/sub/page.html"))
        try write("y", to: server.path("site/top.html"))
        var entries = try await session.list(server.home)
        try await session.setPermissions(try #require(entries.first), mode: 0o700)
        entries = try await session.list(server.home)
        #expect(entries.first?.mode == 0o700 && entries.first?.permissions == "rwx------")
        try await session.setPermissions(try #require(entries.first), mode: 0o751, recursive: true)
        for path in ["site", "site/sub", "site/sub/page.html", "site/top.html"] {
            let attributes = try FileManager.default.attributesOfItem(atPath: server.path(path))
            #expect((attributes[.posixPermissions] as? Int) == 0o751, "\(path)")
        }
        // A mode without search (x) for folders: they keep it where they can be read (chmod's X), so that everything in
        // them is reached, and still can be.
        try await session.setPermissions(try #require(entries.first), mode: 0o640, recursive: true)
        for (path, mode) in [("site", 0o750), ("site/sub", 0o750), ("site/sub/page.html", 0o640), ("site/top.html", 0o640)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: server.path(path))
            #expect((attributes[.posixPermissions] as? Int) == mode, "\(path)")
        }
        #expect(Session.folderMode(0o640) == 0o750 && Session.folderMode(0o600) == 0o700 && Session.folderMode(0o000) == 0)
    }
}

/// Permissions… and Make Executable on a selection change it in one command, with a shell or without: one sftp process
/// per item took a minute for 3 000 files, and 2.5 s a file over a slow link. Every item is tried; a refusal comes last.
@Test func permissionsOfASelectionChangeInOneCommand() async throws {
    func mode(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions] as? Int
    }
    for sftpOnly in [false, true] {
        var options = TestServer.Options()
        options.sftpOnly = sftpOnly
        try await withServer(options) { server in
            let session = try await server.connectedSession()
            for index in 0..<40 { try write("x", to: server.path("run \(index).sh")) }
            try write("y", to: server.path("star*[1].sh"))
            let entries = try await session.list(server.home)
            var before = await server.logEntries().count
            try await session.setPermissions(entries) { $0.mode | 0o111 }
            #expect(await server.logEntries().count - before == 1, "sftp only: \(sftpOnly)")
            #expect(entries.count == 41 && entries.allSatisfy { mode($0.path) == $0.mode | 0o111 })
            let gone = RemoteEntry(name: "gone", path: server.path("gone"), kind: .file, size: 0, modified: nil,
                                   permissions: "", mode: 0o644, owner: "", group: "")
            before = await server.logEntries().count
            await #expect(throws: AirSCPError.self) { try await session.setPermissions([gone] + entries) { _ in 0o600 } }
            #expect(await server.logEntries().count - before == 1)
            #expect(entries.allSatisfy { mode($0.path) == 0o600 }, "sftp only: \(sftpOnly)")
        }
    }
}

@Test func archives() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        try rawMkdir(server.path("project"))
        try write("main\n", to: server.path("project/main.c"))
        try rawMkdir(server.path("project/-dash dir"))
        try write("dash\n", to: server.path("project/-dash dir/f"))
        try write("notes\n", to: server.path("notes.txt"))

        // Several items → Archive.zip; one folder → project.tar.gz.
        let zip = try await session.compress(["project", "notes.txt"], in: server.home, format: .zip)
        #expect(zip == server.path("Archive.zip"))
        let tarball = try await session.compress(["project"], in: server.home, format: .tarGz)
        #expect(tarball == server.path("project.tar.gz"))
        // Taken names get " 2".
        #expect(try await session.compress(["notes.txt"], in: server.home, format: .zip) == server.path("notes.txt.zip"))
        #expect(try await session.compress(["notes.txt"], in: server.home, format: .zip) == server.path("notes.txt 2.zip"))

        // Extract into a new folder named after the archive ("Archive"), with unzip.
        var entries = try await session.list(server.home)
        let folder = try await session.extract(try #require(entries.first { $0.name == "Archive.zip" }), into: .newFolder)
        #expect(folder == server.path("Archive"))
        #expect(read(server.path("Archive/project/-dash dir/f")) == "dash\n" && read(server.path("Archive/notes.txt")) == "notes\n")
        // A tarball extracted "here" lands next to it (replacing what's there).
        try FileManager.default.removeItem(atPath: server.path("project"))
        entries = try await session.list(server.home)
        #expect(try await session.extract(try #require(entries.first { $0.name == "project.tar.gz" }), into: .here) == server.home)
        #expect(read(server.path("project/main.c")) == "main\n")
        // A second new-folder extraction of the same archive goes to "Archive 2".
        #expect(try await session.extract(try #require(entries.first { $0.name == "Archive.zip" }), into: .newFolder) == server.path("Archive 2"))

        // .gz: gzip -dc into a new file (never over an existing one).
        try await run(["/usr/bin/gzip", "-k", server.path("notes.txt")])
        entries = try await session.list(server.home)
        _ = try await session.extract(try #require(entries.first { $0.name == "notes.txt.gz" }), into: .here)
        #expect(read(server.path("notes 2.txt")) == "notes\n")

        // No unzip on the server: python3's zipfile.
        session.capabilities.tools.remove("unzip")
        #expect(session.extractUnavailableReason("Archive.zip") == nil)
        let viaPython = try await session.extract(try #require(entries.first { $0.name == "Archive.zip" }), into: .newFolder)
        #expect(read(viaPython + "/project/main.c") == "main\n")
        #expect((await server.logEntries()).contains { $0.command.contains("python3 -m zipfile -e") })
        // Neither: the reason says so and nothing runs.
        session.capabilities.tools.remove("python3")
        session.capabilities.tools.remove("zip")
        #expect(session.extractUnavailableReason("Archive.zip") == "The server has neither unzip nor python3.")
        #expect(session.compressUnavailableReason(.zip) == "The server has no zip command.")
        #expect(session.compressUnavailableReason(.tarGz) == nil)
        await #expect(throws: AirSCPError.self) { try await session.compress(["notes.txt"], in: server.home, format: .zip) }
    }
}

/// Extract Here would replace what is there: `extractConflicts` names those items first (zip with unzip -l or python3,
/// tar with tar -t; a .gz always gets a free name).
@Test func extractConflictsNameWhatExtractingHereWouldReplace() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let site = server.path("site")
        try rawMkdir(site)
        try write("NEW\n", to: site + "/index.html")
        try rawMkdir(site + "/assets")
        try write("x\n", to: site + "/assets/app.css")
        let zip = try await session.compress(["index.html", "assets"], in: site, format: .zip)
        let tarball = try await session.compress(["index.html", "assets"], in: site, format: .tarGz)
        try FileManager.default.removeItem(atPath: site + "/assets")
        try write("OLD-IMPORTANT\n", to: site + "/index.html")
        try write("notes\n", to: site + "/notes.txt")
        try await run(["/usr/bin/gzip", "-k", site + "/notes.txt"])
        let entries = try await session.list(site)
        func entry(_ path: String) throws -> RemoteEntry { try #require(entries.first { $0.path == path }) }
        #expect(try await session.extractConflicts(try entry(zip)) == ["index.html"])
        #expect(try await session.extractConflicts(try entry(tarball)) == ["index.html"])
        #expect(try await session.extractConflicts(try entry(site + "/notes.txt.gz")).isEmpty)
        session.capabilities.tools.remove("unzip")
        #expect(try await session.extractConflicts(try entry(zip)) == ["index.html"])
        #expect(read(site + "/index.html") == "OLD-IMPORTANT\n")
    }
}

@Test func textEditingKeepsPermissions() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        try write("port 80\n", to: server.path("app.conf"))
        chmod(server.path("app.conf"), 0o640)
        #expect(try await session.readText(server.path("app.conf")) == "port 80\n")
        try await session.writeText("port 8080\n# café\n", to: server.path("app.conf"))
        #expect(read(server.path("app.conf")) == "port 8080\n# café\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: server.path("app.conf"))
        #expect((attributes[.posixPermissions] as? Int) == 0o640)

        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: URL(fileURLWithPath: server.path("binary.bin")))
        do {
            _ = try await session.readText(server.path("binary.bin"))
            Issue.record("read a binary file as text")
        } catch let error as AirSCPError {
            #expect(error.kind == .notText)
        }
        await #expect(throws: AirSCPError.self) { try await session.readText(server.path("app.conf"), limit: 4) }
    }
}

@Test func diskSpaceSizeAndDuplicate() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let free = try await session.diskFree(server.home)
        #expect(free.capacity.hasSuffix("%") && free.size > 0 && free.available > 0 && free.available <= free.size)
        try rawMkdir(server.path("data"))
        try writeRandom(bytes: 100_000, to: server.path("data/blob"))
        let data = try #require(try await session.list(server.home).first)
        #expect((try await session.folderSizes(["data"], in: server.home)["data"] ?? 0) >= 98_304)
        #expect(try await session.duplicate(data) == server.path("data 2"))
        #expect(try await session.duplicate(data) == server.path("data 3"))
        #expect(FileManager.default.contentsEqual(atPath: server.path("data/blob"), andPath: server.path("data 3/blob")))
    }
}

/// Names that need care: quotes, glob characters, backslash, both Unicode forms, a leading dash or space.
let specialNames = ["with space", "dq\"uote", "sq'uote", "star*name", "br[ack]et", "back\\slash", "caf\u{E9} nfc",
                    "cafe\u{301} nfd", "-leading-dash", " leading space", "{brace,s}", "hash#x", "pct%s"]

@Test func specialNamesInFileOperations() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        for name in specialNames { try rawCreate(server.path(name), name) }
        try rawCreate(server.path("new\nline"), "skipped")
        // The listing has every name exactly (bytes, not just canonically equal); the newline one is left out.
        var listed = try await session.list(server.home)
        #expect(Set(listed.map { Array($0.name.utf8) }) == Set(specialNames.map { Array($0.utf8) }))
        for entry in listed {
            #expect(read(entry.path) == entry.name, "path built from the listing: \(entry.path)")
        }

        // Rename, chmod, mkdir, a folder per name, then delete: all through sftp with the exact bytes.
        for entry in listed {
            try await session.rename(entry.path, to: entry.path + " renamed")
            try await session.makeDirectory(entry.path)
            try await session.setPermissions(RemoteEntry(name: entry.name, path: entry.path + " renamed", kind: .file, size: 0,
                                                         modified: nil, permissions: "", mode: 0, owner: "", group: ""),
                                             mode: 0o600)
        }
        let expected = Set(specialNames.flatMap { [Array($0.utf8), Array(($0 + " renamed").utf8)] } + [Array("new\nline".utf8)])
        #expect(Set(rawNames(in: server.home)) == expected)
        listed = try await session.list(server.home)
        #expect(listed.count == specialNames.count * 2)
        // Shell operations get the exact names too.
        for entry in listed where entry.kind == .directory {
            try rawCreate(entry.path + "/inside", "x")
            #expect(try await session.folderSizes([entry.name], in: server.home)[entry.name] != nil, "\(entry.name)")
        }
        let folder = try #require(listed.first { $0.name == "sq'uote" })
        #expect(try await session.duplicate(folder) == server.path("sq'uote 2"))
        #expect(rawExists(server.path("sq'uote 2/inside")))
        try await session.delete(try await session.list(server.home))
        #expect(rawNames(in: server.home) == [Array("new\nline".utf8)])
    }
}
