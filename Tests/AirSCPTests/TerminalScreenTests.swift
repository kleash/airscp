import Foundation
import Testing
import AppKit
@testable import AirSCP
@testable import AirSCPCore

// MARK: The terminal's screen (PLAN.md W)

private func screen(_ columns: Int = 20, _ rows: Int = 5, _ text: String = "") -> TerminalScreen {
    let screen = TerminalScreen(columns: columns, rows: rows)
    screen.feed(text)
    return screen
}

private func shown(_ screen: TerminalScreen) -> [String] { screen.lines.map(\.text) }

@Test func terminalPrintsWrapsAndScrolls() {
    let s = screen(10, 3, "hello\r\nwörld 🙂\r\n")
    #expect(shown(s) == ["hello", "wörld 🙂", ""])
    #expect(s.cursorX == 0 && s.cursorY == 2)
    // The emoji takes two columns.
    #expect(s.lines[1].cells[6].character == "🙂" && s.lines[1].cells[7].continuation)
    // Wrapping at the right edge, then scrolling into the scrollback.
    s.feed("0123456789abc\r\nlast")
    #expect(shown(s) == ["0123456789", "abc", "last"])
    #expect(s.lines[0].wrapped && !s.lines[1].wrapped)
    #expect(s.scrollback.map(\.text) == ["hello", "wörld 🙂"])
    #expect(s.text == "hello\nwörld 🙂\n0123456789abc\nlast")
    // A character at the last column waits for the next one before wrapping (so a CR there stays on the line).
    let edge = screen(5, 2, "abcde\rX")
    #expect(shown(edge) == ["Xbcde", ""])
}

@Test func terminalMovesTheCursorAndErases() {
    let s = screen(10, 4, "line one\r\nline two\r\nline three")
    s.feed("\u{1B}[2;6H")  // row 2, column 6
    #expect(s.cursorY == 1 && s.cursorX == 5)
    s.feed("\u{1B}[K")
    #expect(shown(s)[1] == "line")
    s.feed("\u{1B}[1J")
    #expect(shown(s)[0] == "" && shown(s)[1] == "" && shown(s)[2] == "line three")
    s.feed("\u{1B}[H\u{1B}[2J")
    #expect(shown(s).allSatisfy(\.isEmpty) && s.cursorX == 0 && s.cursorY == 0)
    s.feed("abcdef\u{1B}[3D\u{1B}[2P")  // delete two characters at d
    #expect(shown(s)[0] == "abcf")
    s.feed("\u{1B}[1G\u{1B}[2@XY")  // insert two blanks at the start, then type over them
    #expect(shown(s)[0] == "XYabcf")
    s.feed("\u{1B}[1;3H\u{1B}[3X")
    #expect(shown(s)[0] == "XY   f")
    s.feed("\u{8}\u{8}Z")  // two backspaces from the third column
    #expect(shown(s)[0] == "ZY   f")
    s.feed("\r\tT")
    #expect(s.lines[0].cells[8].character == "T")
}

@Test func terminalScrollRegionsAndLines() {
    let s = screen(6, 5, "1\r\n2\r\n3\r\n4\r\n5")
    s.feed("\u{1B}[2;4r")  // rows 2–4 scroll
    s.feed("\u{1B}[4;1H\nX")
    #expect(shown(s) == ["1", "3", "4", "X", "5"])
    #expect(s.scrollback.isEmpty)  // a region below the top scrolls nothing away
    s.feed("\u{1B}[2;1H\u{1B}M")  // reverse index at the region's top
    #expect(shown(s) == ["1", "", "3", "4", "5"])
    s.feed("\u{1B}[3;1H\u{1B}[L")  // insert a line
    #expect(shown(s) == ["1", "", "", "3", "5"])
    s.feed("\u{1B}[2M")  // delete two
    #expect(shown(s) == ["1", "", "", "", "5"])
    s.feed("\u{1B}[r")
    s.feed("\u{1B}[5;1H\n")
    #expect(s.scrollback.map(\.text) == ["1"])
}

@Test func terminalColoursAndAttributes() {
    let s = screen(20, 2, "\u{1B}[1;31mred\u{1B}[0m \u{1B}[38;5;208mo\u{1B}[48;2;1;2;3mb\u{1B}[7;4;3mi\u{1B}[22;27;24;23;39;49mn")
    let cells = s.lines[0].cells
    #expect(cells[0].attributes.bold && cells[0].attributes.foreground == .indexed(1))
    #expect(cells[3].attributes == TerminalScreen.Attributes())
    #expect(cells[4].attributes.foreground == .indexed(208))
    #expect(cells[5].attributes.background == .rgb(1, 2, 3))
    #expect(cells[6].attributes.inverse && cells[6].attributes.underline && cells[6].attributes.italic)
    #expect(cells[7].attributes == TerminalScreen.Attributes())
    s.feed("\u{1B}[94;101mx")
    #expect(s.lines[0].cells[8].attributes.foreground == .indexed(12) && s.lines[0].cells[8].attributes.background == .indexed(9))
    // Erasing keeps the background colour only.
    s.feed("\u{1B}[44;1m\u{1B}[K")
    #expect(s.lines[0].cells[10].attributes.background == .indexed(4) && !s.lines[0].cells[10].attributes.bold)
}

@Test func terminalModesTheAlternateScreenAndAnswers() {
    let s = screen(10, 3, "shell$ ")
    s.feed("\u{1B}[?1049h\u{1B}[?1h\u{1B}[?2004h\u{1B}[?25l")
    #expect(s.alternateScreen && s.applicationCursorKeys && s.bracketedPaste && !s.cursorVisible)
    s.feed("\u{1B}[Hfull screen")
    #expect(shown(s)[0] == "full scree" && s.lines[1].text == "n")
    s.feed("\u{1B}[?1049l\u{1B}[?1l\u{1B}[?2004l\u{1B}[?25h")
    #expect(!s.alternateScreen && shown(s)[0] == "shell$" && s.cursorX == 7 && s.cursorY == 0)
    #expect(!s.applicationCursorKeys && !s.bracketedPaste && s.cursorVisible)
    var answers: [String] = []
    s.respond = { answers.append(String(decoding: $0, as: UTF8.self)) }
    s.feed("\u{1B}[6n\u{1B}[c\u{1B}[>c")
    #expect(answers == ["\u{1B}[1;8R", "\u{1B}[?62;22c", "\u{1B}[>1;10;0c"])
    // Title, folder and the shell's pid; strings and unknown sequences draw nothing.
    s.feed("\u{1B}]0;vim notes\u{7}\u{1B}]7;file://web/home/dev/my%20site\u{1B}\\\u{1B}]1337;AirSCPPid=4242\u{7}")
    s.feed("\u{1B}P1$r0m\u{1B}\\\u{1B}(B\u{1B}[2 q\u{1B}=")
    #expect(s.title == "vim notes" && s.directory == "/home/dev/my site" && s.shellPID == 4242)
    #expect(shown(s)[0] == "shell$")
}

@Test func terminalTakesUTF8SplitAcrossReads() {
    let s = screen(10, 2)
    let bytes = Array("é€🙂".utf8)
    for byte in bytes { s.feed(Data([byte])) }
    #expect(shown(s)[0] == "é€🙂")
    s.feed(Data([0xFF, 0x41]))
    #expect(shown(s)[0] == "é€🙂\u{FFFD}A")
    s.feed("e\u{301}")  // a combining accent joins the e
    #expect(s.lines[0].text == "é€🙂\u{FFFD}Aé")
}

@Test func terminalResizesKeepingTheCursorLine() {
    let s = screen(10, 4, "a\r\nb\r\nc\r\nd")
    s.resize(columns: 6, rows: 2)
    #expect(shown(s) == ["c", "d"] && s.scrollback.map(\.text) == ["a", "b"] && s.cursorY == 1)
    s.resize(columns: 8, rows: 4)
    #expect(shown(s) == ["a", "b", "c", "d"] && s.scrollback.isEmpty && s.cursorY == 3)
    #expect(s.lines.allSatisfy { $0.cells.count == 8 })
}

@Test func terminalFindsThePathUnderTheMouse() {
    let s = screen(40, 4, "drwxr-x 2 dev dev 4096 notes.txt\r\nsrc/main.c:12:5: error: bad\r\n'my file' \"/var/log/syslog\".")
    #expect(s.path(atLine: 0, column: 25) == "notes.txt")
    #expect(s.path(atLine: 1, column: 3) == "src/main.c")
    #expect(s.path(atLine: 2, column: 2) == "my")
    #expect(s.path(atLine: 2, column: 15) == "/var/log/syslog")
    #expect(s.path(atLine: 0, column: 7) == nil)
    // A path that wrapped onto the next line.
    let w = screen(10, 3, "/home/dev/projects/x")
    #expect(w.path(atLine: 1, column: 2) == "/home/dev/projects/x")
}

// MARK: The Terminal tab on a real server

/// The Terminal tab runs a login shell riding the host's connection: what is typed runs on the server, the shell's
/// folder is known (from its pid on the server: /proc or lsof), and a word in the output is found as the server's file
/// (Show in Files, Download, Edit, Get Info, Copy Path take it). Agents read it in snapshot and type into it.
@MainActor @Test func terminalTabRunsAShellThatKnowsFiles() async throws {
    _ = NSApplication.shared
    try await withServer { @MainActor server in
        let data = server.path("data")
        try write("hello\n", to: data + "/site/notes.txt")
        let model = testModel([server.host()])
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let (main, agent, _) = try agentWindow(model, askpass)
        defer {
            agent.close()
            main.window?.orderOut(nil)
        }
        _ = await call(agent, "select", ["pane": "sidebar", "names": [server.host().displayName]])
        // Not connected: the terminal says what to do.
        #expect(await call(agent, "type", ["text": "ls", "target": "terminal"]).error?.contains("isn't connected") == true)
        _ = await call(agent, "menu", ["path": "Host > Connect"])
        #expect(await call(agent, "wait", ["until": "connected", "timeout": 20]).error == nil)
        _ = await call(agent, "menu", ["path": "Host > Terminal Tab"])
        let workspace = try #require(main.selectedWorkspace)
        let terminal = try #require(workspace.terminal)
        #expect(await eventually(timeout: 20) { terminal.session?.screen.shellPID != nil })
        #expect(await call(agent, "type", ["text": "cd " + data + "/site && echo marker-$((6*7))\n", "target": "terminal"]).error == nil)
        #expect(await eventually(timeout: 20) { terminal.session?.screen.text.contains("marker-42") == true },
                "\(terminal.session?.screen.text ?? "")")
        let snapshot = await call(agent, "snapshot", ["include": ["terminal"]])["terminal"] as? [String: Any]
        #expect(snapshot?["running"] as? Bool == true && (snapshot?["lines"] as? [String])?.contains("marker-42") == true,
                "\(snapshot ?? [:])")
        // The shell's folder, a name in it, and its item on the server.
        var folder: String?
        #expect(await eventually(timeout: 20) {
            folder = await terminal.currentDirectory()
            return folder == data + "/site" || folder.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
                == URL(fileURLWithPath: data + "/site").resolvingSymlinksInPath().path
        }, "\(folder ?? "nil")")
        let path = await terminal.resolve("notes.txt")
        #expect(path?.hasSuffix("/site/notes.txt") == true)
        let item = await terminal.item(at: try #require(path))
        #expect(item?.name == "notes.txt" && item?.size == 6)
        #expect(await terminal.resolve("/a/./b/../c") == "/a/c")
        // Ctrl+C, then exit: the shell ends and says Return starts a new one; Return does.
        _ = await call(agent, "key", ["combo": "ctrl+c", "target": "terminal"])
        _ = await call(agent, "type", ["text": "exit\n", "target": "terminal"])
        #expect(await eventually(timeout: 20) { terminal.session?.running == false })
        #expect(terminal.session?.screen.text.contains("Press Return for a new one") == true)
        #expect(await call(agent, "key", ["combo": "return", "target": "terminal"]).error == nil)
        #expect(await eventually(timeout: 20) { terminal.session?.running == true && terminal.session?.screen.shellPID != nil })
        terminal.session?.close()
    }
}
