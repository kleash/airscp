import AppKit
import Foundation
import SwiftUI
import Testing
@testable import AirSCP
@testable import AirSCPCore

// MARK: Disk Usage

/// du's records (GNU's NUL-separated, the others' one per line) make the tree: a folder's record is its total and is
/// passed over, sizes add up, the folder's own items count as reached; taking an item off takes its size off above.
@MainActor @Test func diskUsageBuildsTheTreeFromDu() throws {
    let gnu = "5\t./a/x.bin\u{0}7\t./a/sub/y.bin\u{0}9\t./a/sub\u{0}20\t./a\u{0}3\t./b.txt\u{0}23\t.\u{0}"
    let bsd = "1\t./a/x.bin\n2\t./a/sub/y.bin\n2\t./a/sub\n3\t./a\n4\t./b.txt\n7\t.\n"
    for (output, unit, separator, sizes, largest) in [(gnu, Int64(1), UInt8(0), (Int64(5), Int64(7), Int64(3)), ["y.bin", "x.bin"]),
                                                       (bsd, 1024, 0x0A, (1024, 2048, 4096), ["b.txt", "y.bin"])] {
        let usage = DiskUsage(path: "/srv")
        usage.expected = 2
        usage.add(DiskUsage.parse(Data(output.utf8), unit: unit, separator: separator))
        let root = usage.root
        #expect(root.path == "/srv" && root.files == 3 && root.size == sizes.0 + sizes.1 + sizes.2)
        #expect(usage.reached == 2 && usage.latest == "b.txt")
        let a = try #require(root.children.first { $0.name == "a" })
        #expect(a.isFolder && a.size == sizes.0 + sizes.1 && a.files == 2 && a.path == "/srv/a")
        let sub = try #require(a.children.first)
        #expect(sub.isFolder && sub.children.map(\.path) == ["/srv/a/sub/y.bin"])
        #expect(root.largestFiles(2).map(\.name) == largest)
        sub.remove()
        #expect(a.size == sizes.0 && a.files == 1 && root.size == sizes.0 + sizes.2 && root.files == 2)
        #expect(a.children.map(\.name) == ["x.bin"])
    }
    // The rings: each item's arc is its share of the one it is in, nested.
    let usage = DiskUsage(path: "/")
    usage.add([.init(path: "big/one", size: 60, folder: false), .init(path: "big/two", size: 20, folder: false),
               .init(path: "small", size: 20, folder: false)])
    let rings = DiskUsageModel.segments(of: usage.root)
    #expect(rings.map { "\($0.item.name) \($0.depth) \($0.start) \($0.end)" }
            == ["big 0 0.0 0.8", "one 1 0.0 0.6", "two 1 0.6 0.8", "small 0 0.8 1.0"])
}

/// This Mac: every file below, its folders (an empty one too), sizes as the files' own.
@Test func diskUsageScansAFolderOnThisMac() throws {
    let dir = try scratch()
    try write(String(repeating: "x", count: 1_000), to: dir + "/logs/app.log")
    try write("abc", to: dir + "/logs/deep/old.log")
    try write("hi", to: dir + "/.hidden")
    try FileManager.default.createDirectory(atPath: dir + "/empty", withIntermediateDirectories: true)
    let usage = DiskUsage(path: dir)
    try DiskUsage.scan(dir) { records, expected in
        usage.expected = expected
        usage.add(records)
    }
    #expect(usage.root.size == 1_005 && usage.root.files == 3)
    #expect(usage.expected == 3 && usage.reached == 3)
    #expect(usage.root.children.map(\.name) == ["logs", ".hidden", "empty"])
    #expect(usage.root.children.last?.isFolder == true)
    #expect(usage.root.largestFiles(10).map(\.path) == [dir + "/logs/app.log", dir + "/logs/deep/old.log", dir + "/.hidden"])
}

/// A server: one du, its records as they come, the folder's own items counted.
@Test func diskUsageScansAServerFolder() async throws {
    try await withServer { server in
        try write(String(repeating: "x", count: 5_000), to: server.path("du/big.bin"))
        try write("small", to: server.path("du/sub/small.txt"))
        try write("odd", to: server.path("du/a name with spaces/it's.txt"))
        let session = try await server.connectedSession()
        final class Found: @unchecked Sendable {  // filled on one background thread, read after the scan
            var records: [DiskUsage.Record] = []
            var expected = 0
        }
        let found = Found()
        try await session.diskUsage(of: server.path("du")) { records, expected in
            found.records += records
            found.expected = expected
        }
        let usage = DiskUsage(path: server.path("du"))
        usage.add(found.records)
        #expect(found.expected == 3 && usage.reached == 3)
        #expect(usage.root.files == 3)
        #expect(usage.root.children.first?.name == "big.bin")
        let largest = usage.root.largestFiles(5).map(\.path)
        #expect(largest.first == server.path("du/big.bin")
                && Set(largest) == [server.path("du/big.bin"), server.path("du/sub/small.txt"), server.path("du/a name with spaces/it's.txt")])
        // Sizes in kilobytes from macOS's du: at least the bytes, at most a block more each.
        #expect(usage.root.size >= 5_008 && usage.root.size <= 5_008 + 3 * 4096)
    }
}

/// The sheet from File ▸ Disk Usage… on a server's folder: the scan ends with the items largest first; Delete… asks
/// (naming the host), deletes on the server and takes the item's size off.
@MainActor @Test func diskUsageSheetScansAndDeletesOnAServer() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        var host = server.host()
        host.label = "lab"
        try write(String(repeating: "x", count: 50_000), to: server.path("du/big/one.bin"))
        try write("small", to: server.path("du/small.txt"))
        let model = testModel([host])
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let (main, agent, _) = try agentWindow(model, askpass)
        defer {
            agent.close()
            main.window?.orderOut(nil)
        }
        _ = await call(agent, "select", ["pane": "sidebar", "names": ["lab"]])
        _ = await call(agent, "menu", ["path": "Host > Connect"])
        #expect(await call(agent, "wait", ["until": "connected", "timeout": 30]).error == nil)
        _ = await call(agent, "go", ["path": server.path("du")])
        #expect(await call(agent, "menu", ["path": "File > Disk Usage…"]).error == nil)
        let hosting = main.window?.attachedSheet?.contentViewController as? NSHostingController<DiskUsageView>
        let usage = try #require(hosting?.rootView.model)
        #expect(await eventually { !usage.scanning })
        #expect(usage.status == "Scanned 2 files.", "\(usage.status)")
        #expect(usage.rows.map(\.name) == ["big", "small.txt"] && usage.segments.count == 3)
        let big = usage.rows[0]
        #expect(usage.open(big) && usage.rows.map(\.name) == ["one.bin"])
        usage.goUp()
        usage.selection = [big.id]
        // Once the sheet has drawn the selection (Delete… is enabled then).
        var asked = Reply()
        #expect(await eventually(timeout: 10) {
            asked = await call(agent, "press", ["id": "diskUsage.delete"])
            return asked.error == nil
        })
        #expect((sheet(asked)?["title"] as? String)?.contains("on “lab”") == true, "\(asked.error ?? "") \(asked.json)")
        #expect(await call(agent, "press", ["title": "Delete"]).error == nil)
        #expect(await eventually { !rawExists(server.path("du/big")) })
        #expect(await eventually { usage.rows.map(\.name) == ["small.txt"] && usage.folder?.files == 1 })
        _ = await call(agent, "press", ["title": "Done"])
        await main.selectedWorkspace?.connection.disconnect()
    }
}
