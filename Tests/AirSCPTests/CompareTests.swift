import AppKit
import Foundation
import Testing
@testable import AirSCP
@testable import AirSCPCore

// Compare: the side-by-side model (alignment, changed lines, characters, ignore options, blocks, merging), Prettify,
// the checksum comparison of files that aren't text, and the window opened from one pane or across the two.

@Test func compareAlignsTheLinesWithFillerRows() {
    let diff = TextDiff(left: "a\nb\nc\nd", right: "a\nB\nc\nd\ne")
    #expect(diff.rows.map(\.kind) == [.same, .changed, .same, .same, .rightOnly])
    #expect(diff.rows.map(\.left) == [0, 1, 2, 3, nil] && diff.rows.map(\.right) == [0, 1, 2, 3, 4])
    #expect(diff.blocks == [TextDiff.Block(rows: 1..<2, left: 1..<2, right: 1..<2),
                            TextDiff.Block(rows: 4..<5, left: 4..<4, right: 4..<5)])
    // A block's removed and added lines are paired row by row; the rest are on one side only.
    let block = TextDiff(left: "a\n1\n2\nb", right: "a\nX\nb")
    #expect(block.rows.map(\.kind) == [.same, .changed, .leftOnly, .same])
    #expect(block.rows[2].right == nil && block.blocks.count == 1)
    // An added line beside a changed one: the changed lines are paired, the added one stands alone.
    let shifted = TextDiff(left: "a\nlevel = info\nb", right: "a\ntimeout = 30\nlevel = debug\nb")
    #expect(shifted.rows.map(\.kind) == [.same, .rightOnly, .changed, .same])
    #expect(shifted.rows[2].left == 1 && shifted.rows[2].right == 2 && shifted.rows[1].left == nil)
    #expect(TextDiff(left: "same\n", right: "same\n").blocks.isEmpty)
    #expect(TextDiff(left: "", right: "new").rows.map(\.kind) == [.changed])
    // Windows line ends against Unix ones: no difference.
    #expect(TextDiff(left: "a\r\nb\r\n", right: "a\nb\n").blocks.isEmpty)
}

@Test func compareMarksTheCharactersThatDiffer() {
    let row = TextDiff(left: "let x = 1;", right: "let x = 22;").rows[0]
    #expect(row.kind == .changed && row.leftRanges == [8..<9] && row.rightRanges == [8..<10])
    // UTF-16 offsets, as the text view counts.
    let emoji = TextDiff(left: "👍 ab", right: "👍 cd").rows[0]
    #expect(emoji.leftRanges == [3..<5] && emoji.rightRanges == [3..<5])
    // A long line: what is between the common start and end.
    let long = String(repeating: "x", count: 600)
    let wide = TextDiff(left: long + "a" + long, right: long + "bc" + long).rows[0]
    #expect(wide.leftRanges == [600..<601] && wide.rightRanges == [600..<602])
}

@Test func compareIgnoresWhitespaceCaseAndBlankLines() {
    let spaced = ("a  b \nc", " a\tb\nc")
    #expect(TextDiff(left: spaced.0, right: spaced.1).blocks.count == 1)
    let ignoring = TextDiff(left: spaced.0, right: spaced.1, options: TextDiff.Options(whitespace: true))
    #expect(ignoring.blocks.isEmpty && ignoring.rows.allSatisfy { $0.kind == .same })
    #expect(TextDiff(left: "Hello", right: "hello").blocks.count == 1)
    #expect(TextDiff(left: "Hello", right: "hello", options: TextDiff.Options(caseOfLetters: true)).blocks.isEmpty)
    let blank = ("a\n\n  \nb", "a\nb")
    #expect(TextDiff(left: blank.0, right: blank.1).blocks.count == 1)
    let noBlanks = TextDiff(left: blank.0, right: blank.1, options: TextDiff.Options(blankLines: true))
    #expect(noBlanks.blocks.isEmpty && noBlanks.rows.count == 4 && noBlanks.rows.map(\.right) == [0, nil, nil, 1])
    // A real difference beside blank lines is still one.
    #expect(TextDiff(left: "a\n\nx\nb", right: "a\nb", options: TextDiff.Options(blankLines: true)).blocks.count == 1)
}

@Test func compareCopiesABlockToTheOtherSide() {
    let diff = TextDiff(left: "a\r\nb\r\nc\r\n", right: "a\r\nB\r\nc\r\nd\r\n")
    #expect(diff.blocks.count == 2)
    // The left's lines over the right's, line ends as they were.
    #expect(diff.merging(diff.blocks[0], toRight: true) == "a\r\nb\r\nc\r\nd\r\n")
    #expect(diff.merging(diff.blocks[0], toRight: false) == "a\r\nB\r\nc\r\n")
    // A block with no lines on the target side inserts them; one with none on the source side removes them.
    #expect(diff.merging(diff.blocks[1], toRight: false) == "a\r\nb\r\nc\r\nd\r\n")
    #expect(diff.merging(diff.blocks[1], toRight: true) == "a\r\nB\r\nc\r\n")
}

/// Two 100,000-line files (about 5 MB) with edits here and there compare in moments, off the main thread.
@Test func compareOfTwoLargeFilesIsQuick() {
    var left: [String] = [], right: [String] = []
    for line in 0..<100_000 {
        let text = "line \(line % 5_000): " + String(repeating: "abcdefghij", count: 4)
        left.append(text)
        right.append(line % 97 == 0 ? text.replacingOccurrences(of: "def", with: "DEF") : text)
        if line % 1_009 == 0 { right.append("inserted \(line)") }
    }
    let start = Date()
    let diff = TextDiff(left: left.joined(separator: "\n"), right: right.joined(separator: "\n"))
    print("PERF Compare of two 100,000-line files (\(left.joined(separator: "\n").utf8.count / 1_000_000) MB, "
          + "\(diff.blocks.count) differences): \(String(format: "%.2f", Date().timeIntervalSince(start))) s")
    #expect(diff.rows.filter { $0.kind == .changed }.count == 1_031)
    #expect(diff.rows.filter { $0.kind == .rightOnly }.count == 100)
}

@Test func prettifyFormatsJSONAndXMLOrSaysWhyNot() {
    let json = Prettify.both(["{\"b\":1,\"a\":[1,2],\"url\":\"a/b\"}", "{\"a\":[1,2],\"b\":2}"], names: ["a.json", "b.json"])
    #expect(json.0 == ["{\n  \"a\" : [\n    1,\n    2\n  ],\n  \"b\" : 1,\n  \"url\" : \"a/b\"\n}\n",
                       "{\n  \"a\" : [\n    1,\n    2\n  ],\n  \"b\" : 2\n}\n"])
    let xml = Prettify.both(["<a><b x=\"1\">t</b></a>", "<a><b x=\"2\">t</b></a>"], names: ["a.txt", "b.txt"])
    #expect(xml.0?[0].contains("\n    <b x=\"1\">t</b>\n") == true, "\(xml)")
    // Invalid: off, saying which file.
    let broken = Prettify.both(["{\"a\":1}", "{\"a\":"], names: ["a.json", "b.json"])
    #expect(broken.0 == nil && broken.1 == "“b.json” isn't valid JSON, so it can't be prettified")
    #expect(Prettify.both(["<a>", "<a/>"], names: ["a.xml", "b.xml"]).1.contains("“a.xml” isn't valid XML"))
    #expect(Prettify.both(["plain", "text"], names: ["a.txt", "b.txt"]).1 == "Prettify works on JSON and XML files")
    // By the extension when the text doesn't say.
    #expect(Prettify.format("  ", name: "x.JSON") == .json && Prettify.format("\u{FEFF}<x/>", name: "x") == .xml)
}

/// Files that aren't text (NUL bytes, not UTF-8, too large) are compared by checksum.
@Test func compareFallsBackToChecksumsForFilesThatArentText() async throws {
    let folder = try scratch()
    let binary = Data([0x89, 0x50, 0x00, 0x01, 0xFF])
    try binary.write(to: URL(fileURLWithPath: folder + "/a.bin"))
    try binary.write(to: URL(fileURLWithPath: folder + "/b.bin"))
    try Data([0x89, 0x50, 0x00, 0x02, 0xFF]).write(to: URL(fileURLWithPath: folder + "/c.bin"))
    try Data(count: 5 << 20).write(to: URL(fileURLWithPath: folder + "/big.txt"))
    try write("text", to: folder + "/t.txt")
    func side(_ name: String) -> CompareWindow.Side {
        CompareWindow.Side(name: name, path: folder + "/" + name, session: nil, size: 0)
    }
    #expect(try await CompareWindow.read(side("a.bin")) == nil)
    #expect(try await CompareWindow.read(side("big.txt")) == nil)
    #expect(try await CompareWindow.read(side("t.txt")) == "text")
    #expect(CompareWindow.text(Data([0xC3, 0x28]), limit: 10) == nil)  // not UTF-8
    let hashes = try await [side("a.bin"), side("b.bin"), side("c.bin")].asyncMap { try await CompareWindow.sha256($0) }
    #expect(hashes[0] == hashes[1] && hashes[0] != hashes[2] && hashes[0].count == 64)
}

extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for element in self { results.append(try await transform(element)) }
        return results
    }
}

/// Compare from the row menu: two files of one pane, or one in each pane (this Mac's on the left, the server's on the
/// right); the window shows them side by side, copies a difference across and saves it.
@MainActor @Test func compareOpensTwoFilesOfAPaneOrOneInEachPane() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        var host = server.host()
        let local = try server.scratch()
        host.lastLocalDir = local
        try write("one\ntwo\nthree\n", to: local + "/mine.txt")
        try write("one\nTWO\nthree\nfour\n", to: server.path("theirs.txt"))
        try write("one\n", to: server.path("other.txt"))
        try write("{\"b\":1,\"a\":2}", to: server.path("a.json"))
        try write("{\"a\":2,\"b\":3}", to: server.path("b.json"))
        let session = try await server.connectedSession(host)
        let browser = BrowserContentController(workspace: nil, session: session)
        _ = browser.view
        browser.stateChanged(session.state)
        #expect(await eventually { browser.left.dir == local && browser.right.dir != nil && !browser.right.rows.isEmpty })
        @MainActor func select(_ names: [String], in pane: FilePane) {
            pane.table.selectRowIndexes(IndexSet(pane.rows.indices.filter { names.contains(pane.rows[$0].name) }), byExtendingSelection: false)
        }
        @MainActor func titles(_ pane: FilePane) -> [String] { pane.contextMenu(for: pane.selectedItems).compactMap { $0?.0 } }
        @MainActor func window(_ title: String) -> CompareWindow? {
            NSApp.windows.first { $0.title == title }?.windowController as? CompareWindow
        }
        defer { NSApp.windows.filter { $0.windowController is CompareWindow }.forEach { $0.close() } }

        // Two files of the server's pane.
        select(["theirs.txt", "other.txt"], in: browser.right)
        browser.left.table.deselectAll(nil)
        #expect(titles(browser.right).contains("Compare"))
        browser.right.compareFiles(nil)
        #expect(await eventually { window("other.txt ↔ theirs.txt") != nil })

        // One in each pane: offered by name, this Mac's file on the left.
        select(["mine.txt"], in: browser.left)
        select(["theirs.txt"], in: browser.right)
        #expect(titles(browser.right).contains("Compare with “mine.txt”"))
        #expect(titles(browser.left).contains("Compare with “theirs.txt”"))
        #expect(browser.right.check(#selector(FilePane.compareFiles(_:)), for: browser.right.selectedItems).0)
        browser.left.table.deselectAll(nil)
        #expect(browser.right.check(#selector(FilePane.compareFiles(_:)), for: browser.right.selectedItems)
                == (false, "Select two files, or one file here and one in the other pane."))
        select(["mine.txt"], in: browser.left)
        browser.right.compareFiles(nil)
        let compare = try #require(await eventually { window("mine.txt ↔ theirs.txt") != nil } ? window("mine.txt ↔ theirs.txt") : nil)
        let shown = try #require(compare.window)
        #expect(await eventually { shown.subtitle.hasPrefix("2 differences") }, "\(shown.subtitle)")
        let texts = AgentServer.views(NSTextView.self, in: try #require(shown.contentView))
        let left = try #require(texts.first { $0.accessibilityIdentifier() == "compare.left" })
        let right = try #require(texts.first { $0.accessibilityIdentifier() == "compare.right" })
        #expect(left.string == "one\ntwo\nthree\n\n" && right.string == "one\nTWO\nthree\nfour\n")

        // The second difference ("four", only on the right) copied to the left, then the left saved on this Mac.
        compare.goToNext(nil)
        compare.copyToLeft(nil)
        #expect(await eventually { shown.subtitle.hasPrefix("1 difference:") }, "\(shown.subtitle)")
        #expect(shown.isDocumentEdited)
        let save = NSButton()
        save.tag = 0
        compare.saveSide(save)
        #expect(await eventually { read(local + "/mine.txt") == "one\ntwo\nthree\nfour\n" })
        #expect(await eventually { !shown.isDocumentEdited })
        // Undo puts the left's text back as it was.
        shown.undoManager?.undo()
        #expect(await eventually { shown.subtitle.hasPrefix("2 differences") }, "\(shown.subtitle)")

        // Prettify alone is a way of looking: nothing to save, closing doesn't ask.
        select(["a.json", "b.json"], in: browser.right)
        browser.left.table.deselectAll(nil)
        browser.right.compareFiles(nil)
        let json = try #require(await eventually { window("a.json ↔ b.json") != nil } ? window("a.json ↔ b.json") : nil)
        let jsonWindow = try #require(json.window)
        #expect(await eventually { jsonWindow.subtitle.hasPrefix("1 difference") }, "\(jsonWindow.subtitle)")
        json.togglePrettify(nil)
        #expect(await eventually { jsonWindow.subtitle.hasSuffix("(prettified)") }, "\(jsonWindow.subtitle)")
        #expect(!jsonWindow.isDocumentEdited && json.windowShouldClose(jsonWindow))
    }
}
