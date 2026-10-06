import Darwin
import Foundation
import Testing
@testable import AirSCPCore

/// Runs `body` in a task that is cancelled before it starts its work (as a UI that stops waiting would).
private func cancelledTask<T>(_ body: @escaping () async throws -> T) async -> Error? {
    let task = Task { () async throws -> T in
        withUnsafeCurrentTask { $0?.cancel() }
        return try await body()
    }
    do {
        _ = try await task.value
        return nil
    } catch {
        return error
    }
}

@Test func copyAndMoveWithinTheHost() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        try rawMkdir(server.path("from"))
        try rawMkdir(server.path("to"))
        try rawCreate(server.path("from/it's a file.txt"), "file")
        try rawMkdir(server.path("from/-dash folder"))
        try rawCreate(server.path("from/-dash folder/inner"), "inner")

        // Copy: the original stays; a folder comes with everything in it.
        try await session.copy(server.path("from/it's a file.txt"), to: server.path("to/it's a file.txt"))
        try await session.copy(server.path("from/-dash folder"), to: server.path("to/-dash folder"))
        #expect(read(server.path("to/it's a file.txt")) == "file" && read(server.path("from/it's a file.txt")) == "file")
        #expect(read(server.path("to/-dash folder/inner")) == "inner" && rawExists(server.path("from/-dash folder/inner")))
        // Something already there: refused, not copied into it.
        do {
            try await session.copy(server.path("from/-dash folder"), to: server.path("to/-dash folder"))
            Issue.record("copied onto an existing folder")
        } catch let error as AirSCPError {
            #expect(error.kind == .failure && error.message == "-dash folder already exists there.")
        }
        #expect(!rawExists(server.path("to/-dash folder/-dash folder")))

        // Move: across folders, the original goes.
        try await session.move(server.path("to/it's a file.txt"), to: server.path("moved.txt"))
        try await session.move(server.path("to/-dash folder"), to: server.path("moved folder"))
        #expect(read(server.path("moved.txt")) == "file" && !rawExists(server.path("to/it's a file.txt")))
        #expect(read(server.path("moved folder/inner")) == "inner" && !rawExists(server.path("to/-dash folder")))
        await #expect(throws: AirSCPError.self) { try await session.move(server.path("moved.txt"), to: server.path("from")) }
        #expect(rawExists(server.path("moved.txt")))
        #expect((await server.logEntries()).contains { $0.command.contains("mv --") })
    }
}

@Test func executeCommandRunsTheFileInItsFolder() async throws {
    #expect(Session.executeCommand("/srv/app/run me.sh") == "cd '/srv/app' && ./'run me.sh'")
    #expect(Session.executeCommand("/srv/it's/-x", arguments: "--port 80 \"$HOME\"")
        == #"cd '/srv/it'\''s' && ./'-x' --port 80 "$HOME""#)
    #expect(Session.executeCommand("/top", arguments: "  ") == "cd '/' && ./'top'")
    try await withServer { server in
        let session = try await server.connectedSession()
        try rawMkdir(server.path("bin dir"))
        try rawCreate(server.path("bin dir/it's.sh"), "#!/bin/sh\necho \"in $(basename \"$PWD\"): $1 $2\"\nexit 4\n")
        let script = try #require(try await session.list(server.path("bin dir")).first)
        // Make executable, then Run.
        try await session.setPermissions(script, mode: script.mode | 0o111)
        let result = try await session.run(Session.executeCommand(script.path, arguments: "one 'two three'"))
        #expect(result.output == "in bin dir: one two three\n" && result.status == 4)
    }
}

@Test func moveOnAnSFTPOnlyAccount() async throws {
    try await withServer(TestServer.Options(sftpOnly: true)) { server in
        let session = try await server.connectedSession()
        try rawMkdir(server.path("a"))
        try rawCreate(server.path("a/f"), "f")
        try rawMkdir(server.path("full"))
        try rawCreate(server.path("full/x"), "x")
        try await session.move(server.path("a/f"), to: server.path("f"))
        #expect(read(server.path("f")) == "f" && !rawExists(server.path("a/f")))
        // The server's "Failure" (here: a folder onto one that isn't empty) gets the move's own message.
        do {
            try await session.move(server.path("a"), to: server.path("full"))
            Issue.record("moved onto a folder that isn't empty")
        } catch let error as AirSCPError {
            #expect(error.kind == .failure && error.message.hasPrefix("Can't move a there"))
        }
        // Copying needs a shell.
        do {
            try await session.copy(server.path("f"), to: server.path("g"))
            Issue.record("copied without a shell")
        } catch let error as AirSCPError {
            #expect(error.kind == .sftpOnly)
        }
        await #expect(throws: AirSCPError.self) { _ = try await session.folderSizes(["a"], in: server.home) }
    }
}

@Test func getInfo() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        try rawMkdir(server.path("folder"))
        try rawMkdir(server.path("folder/sub"))
        try writeRandom(bytes: 50_000, to: server.path("folder/sub/blob"))
        try rawCreate(server.path("folder/a b.txt"), "hello\n")
        chmod(server.path("folder/a b.txt"), 0o4751)
        try FileManager.default.createSymbolicLink(atPath: server.path("link"), withDestinationPath: "folder/a b.txt")
        let top = try await session.list(server.home)
        let inside = try await session.list(server.path("folder"))

        let file = try await session.info(try #require(inside.first { $0.name == "a b.txt" }))
        #expect(file.kind?.contains("text") == true)
        #expect(file.size == 6 && file.itemCount == nil && file.mode == 0o4751 && file.linkTarget == nil)
        #expect(file.owner == NSUserName() && !file.group.isEmpty)
        #expect(abs(file.modified!.timeIntervalSinceNow) < 120 && file.accessed != nil && file.changed != nil)

        let folder = try await session.info(try #require(top.first { $0.name == "folder" }))
        #expect(folder.kind == "directory" && folder.itemCount == 3 && (folder.size ?? 0) >= 49_152)

        let link = try await session.info(try #require(top.first { $0.name == "link" }))
        #expect(link.linkTarget == "folder/a b.txt" && link.itemCount == nil && link.kind?.contains("link") == true)

        try FileManager.default.removeItem(atPath: server.path("link"))
        do {
            _ = try await session.info(try #require(top.first { $0.name == "link" }))
            Issue.record("described a file that is gone")
        } catch let error as AirSCPError {
            #expect(error.kind == .noSuchFile)
        }
    }
    // Without a shell: what the listing says.
    try await withServer(TestServer.Options(sftpOnly: true)) { server in
        let session = try await server.connectedSession()
        try rawMkdir(server.path("folder"))
        try rawCreate(server.path("f"), "12345")
        let entries = try await session.list(server.home)
        let file = try await session.info(try #require(entries.first { $0.name == "f" }))
        #expect(file.size == 5 && file.kind == nil && file.accessed == nil && file.mode == 0o644)
        #expect(try await session.info(try #require(entries.first { $0.name == "folder" })).size == nil)
    }
}

@Test func folderSizes() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        for name in ["small", "big", "it's [x] *", "-dash", "caf\u{E9}"] { try rawMkdir(server.path(name)) }
        try writeRandom(bytes: 300_000, to: server.path("big/blob"))
        try rawCreate(server.path("small/x"), "x")
        // Names from the listing, never a glob: "*" is just a name, ".." is never asked for.
        let sizes = try await session.folderSizes(["small", "big", "it's [x] *", "-dash", "caf\u{E9}", "gone"], in: server.home)
        #expect(Set(sizes.keys) == ["small", "big", "it's [x] *", "-dash", "caf\u{E9}"])
        #expect((sizes["big"] ?? 0) >= 294_912 && (sizes["small"] ?? 0) < (sizes["big"] ?? 0))
        #expect(!(await server.logEntries()).contains { $0.command.contains("*/") })

        // Thousands of folders: several commands (one command line has a size limit), every folder measured.
        try rawMkdir(server.path("many"))
        let names = (0..<3000).map { "folder-with-a-rather-long-name-\($0)" }
        for name in names { try rawMkdir(server.path("many/" + name)) }
        let before = await server.logEntries().count
        let all = try await session.folderSizes(names, in: server.path("many"))
        #expect(all.count == 3000)
        let commands = (await server.logEntries()).dropFirst(before).filter { $0.command.contains("$du --") }
        #expect(commands.count > 1 && commands.allSatisfy { $0.command.utf8.count < 100_000 })

        // A folder that isn't there.
        await #expect(throws: AirSCPError.self) { _ = try await session.folderSizes(["x"], in: server.path("nowhere")) }
        // Cancelling the task that waits for it stops it.
        let error = await cancelledTask { try await session.folderSizes(names, in: server.path("many")) }
        #expect((error as? AirSCPError)?.kind == .cancelled)
    }
}

@Test func listingAndInfoCanBeCancelled() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        try rawMkdir(server.path("d"))
        var error = await cancelledTask { try await session.list(server.home) }
        #expect((error as? AirSCPError)?.kind == .cancelled)
        let entry = try #require(try await session.list(server.home).first)
        error = await cancelledTask { try await session.info(entry) }
        #expect((error as? AirSCPError)?.kind == .cancelled)
        // The session is fine afterwards.
        #expect(try await session.list(server.home).map(\.name) == ["d"])
    }
}

/// PLAN.md S: a 50 000-entry folder lists within about two seconds: a shell's ls, one round trip. (The time budget is
/// loose: a debug build on a busy machine.)
@Test func listingAFolderOf50000Entries() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        try rawMkdir(server.path("huge"))
        for index in 0..<50_000 { try rawCreate(server.path("huge/file-\(index).txt")) }
        let before = await server.logEntries().count
        let start = Date()
        let entries = try await session.list(server.path("huge"))
        let elapsed = Date().timeIntervalSince(start)
        print("PERF listing a 50000-entry folder: \(String(format: "%.2f", elapsed)) s")
        #expect(entries.count == 50_000)
        // One shell command (sftp would need 500 round trips).
        let commands = (await server.logEntries()).dropFirst(before).map(\.command)
        #expect(commands.count == 1 && commands.allSatisfy { $0.contains("TZ=UTC0 ls -lan") })
        #expect(elapsed < 15, "listing 50 000 entries took \(elapsed) s")
    }
}
