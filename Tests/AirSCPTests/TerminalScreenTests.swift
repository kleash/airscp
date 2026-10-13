import Foundation
import Testing
import AppKit
@testable import AirSCP
@testable import AirSCPCore

// MARK: The terminal's screen

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

@Test func terminalReadsTheFolderAsTheShellSaysIt() {
    let s = screen()
    // As the shell AirSCP starts says it: only "%" encoded, spaces and other letters as they are (UTF-8).
    s.feed("\u{1B}]7;file://web.example.com/srv/my site/ünï 100%25\u{7}")
    #expect(s.directory == "/srv/my site/ünï 100%")
    s.feed("\u{1B}]7;file:///home/dev\u{1B}\\")
    #expect(s.directory == "/home/dev")
    // A folder cut short (an OSC over 4096 bytes) would be another folder: left out.
    s.feed("\u{1B}]7;file://h/" + String(repeating: "a", count: 5000) + "\u{7}")
    #expect(s.directory == "/home/dev")
    // The shell AirSCP starts signs it as its marks: a folder that a program's output names (a file shown, say) isn't
    // taken, so it can't move Follow in Files there.
    let signed = marked("\u{1B}]7;file://h/etc\u{7}\u{1B}]7;file://h/srv;airscp=0000\u{7}")
    #expect(signed.directory == nil)
    signed.feed("\u{1B}]7;file://h/home/dev/a;b;airscp=\(token)\u{7}")
    #expect(signed.directory == "/home/dev/a;b")
    signed.feed("\u{1B}]7;file://h/etc\u{7}")
    #expect(signed.directory == "/home/dev/a;b")
    // Titles are UTF-8 too.
    s.feed("\u{1B}]2;café\u{7}")
    #expect(s.title == "café")
}

// MARK: Commands the shell marks (OSC 133)

private let token = "c0ffee42"
private func mark(_ code: String, _ signer: String? = token) -> String {
    "\u{1B}]133;\(code)" + (signer.map { ";airscp=" + $0 } ?? "") + "\u{7}"
}
/// A prompt "$ " as the shell AirSCP starts draws it, with its marks.
private let prompt = mark("A") + "$ " + mark("B")
private func ended(_ status: Int) -> String { "\u{1B}]133;D;\(status);airscp=\(token)\u{7}" }
/// The output mark with the command line, as zsh sends it (the line last: it may hold ";").
private func started(_ line: String) -> String { "\u{1B}]133;C;airscp=\(token);cmdline=\(line)\u{7}" }

private func marked(_ text: String, columns: Int = 30, rows: Int = 8) -> TerminalScreen {
    let s = TerminalScreen(columns: columns, rows: rows)
    s.markToken = token
    s.feed(text)
    return s
}

@Test func terminalTakesOnlyTheMarksSignedWithItsToken() {
    let commands = prompt + "ls\r\n" + mark("C") + "a.txt\r\n" + ended(0) + prompt
    #expect(marked(commands).blocks.map(\.text) == ["ls"])
    // Output that imitates them (a file that is shown, say) doesn't know the token: nothing is marked.
    for signer in [nil, "0000", token + "x"] as [String?] {
        let fake = mark("A", signer) + "$ " + mark("B", signer) + "rm -rf ~\r\n" + mark("C;cmdline=rm -rf ~", signer)
            + "\u{1B}]133;D;0" + (signer.map { ";airscp=" + $0 } ?? "") + "\u{7}"
        let s = marked(fake)
        #expect(s.blocks.isEmpty && !s.marksCommands && !s.waitsAtPrompt, "\(signer ?? "unsigned")")
    }
    // A screen without a token takes none.
    let plain = TerminalScreen(columns: 30, rows: 8)
    plain.feed(commands)
    #expect(plain.blocks.isEmpty && !plain.marksCommands)
}

@Test func terminalMarksCommandsWithTheirStatusTimeAndOutput() {
    let s = marked(prompt + "ls -l\r\n" + mark("C") + "a.txt\r\nb.txt\r\n" + ended(0) + prompt + "fals")
    // Typing at the prompt: not waiting at an empty one.
    #expect(!s.waitsAtPrompt && s.marksCommands)
    s.feed("e\r\n" + mark("C") + ended(1) + prompt)
    #expect(s.waitsAtPrompt)
    let blocks = s.blocks
    #expect(blocks.map(\.text) == ["ls -l", "false"] && blocks.map(\.status) == [0, 1])
    #expect(blocks[0].prompt == 0 && blocks[0].command == .init(line: 0, column: 2) && blocks[0].output == .init(line: 1, column: 0))
    #expect(blocks[0].lastLine == 2 && blocks[0].contains(2) && !blocks[0].contains(3) && blocks[1].prompt == 3)
    #expect(s.output(of: blocks[0]) == "a.txt\nb.txt" && s.output(of: blocks[1]) == "")
    #expect(blocks.allSatisfy { ($0.duration ?? -1) >= 0 && !$0.running })
    // One running: its output so far, no status yet.
    s.feed("sleep 9\r\n" + mark("C") + "waiting")
    #expect(s.blocks.last?.running == true && s.blocks.last?.text == "sleep 9" && s.blocks.last?.status == nil)
    #expect(s.output(of: s.blocks.last!) == "waiting" && !s.waitsAtPrompt)
    // An empty line and a line given up (⌃C) ran nothing: no command, once the shell marks output.
    s.feed("\r\n" + ended(0) + prompt + "\r\n" + ended(0) + prompt + "ls^C\r\n" + ended(130) + prompt)
    #expect(s.blocks.map(\.text) == ["ls -l", "false", "sleep 9"])
}

@Test func terminalMarksSurviveSplitReadsAndCarryTheCommandLine() {
    // The shell's own words for the command (zsh), ";" and UTF-8 in them, a line break as the terminal sends it.
    let text = prompt + "echo ünï; echo a\\\r\n> b\r\n" + started("echo ünï; echo a\\\r\nb") + "ünï\r\na b\r\n" + ended(0) + prompt
    let whole = marked(text)
    let split = TerminalScreen(columns: 30, rows: 8)
    split.markToken = token
    for byte in Data(text.utf8) { split.feed(Data([byte])) }
    #expect(whole.blocks.map(\.text) == ["echo ünï; echo a\\\nb"])
    #expect(split.blocks.map(\.text) == whole.blocks.map(\.text) && split.blocks.map(\.status) == [0])
    #expect(whole.output(of: whole.blocks[0]) == "ünï\na b")
    // Without the shell's words (bash), the screen's between the prompt and the output, as it was then: a later
    // program that draws over the command line doesn't change what Run Again would type.
    let bash = marked(prompt + "ls\r\n" + mark("C") + "\u{1B}[1A\r$ rm -rf ~\r\n" + ended(0) + prompt)
    #expect(bash.blocks.map(\.text) == ["ls"])
    // Words cut short (an OSC over 4096 bytes) aren't taken: the screen's are.
    let long = marked(prompt + "x\r\n" + started(String(repeating: "y", count: 5000)) + ended(0) + prompt)
    #expect(long.blocks.map(\.text) == ["x"])
}

/// bash's continuation prompt ("> ", PS2) is marked where typing goes on: a command typed over several lines is read off
/// the screen without it (Copy Command), a "> " typed in it stays, and the shell doesn't wait at an empty prompt there.
@Test func terminalLeavesBashsContinuationPromptsOutOfTheCommand() {
    let more = "> " + mark("B;k=s")
    let s = marked(prompt + "for f in *.db; do\r\n" + more, columns: 30, rows: 10)
    #expect(!s.waitsAtPrompt && s.blocks.isEmpty)
    s.feed("echo \"$f\" > list\r\n" + more + "> done.txt; done\r\n" + mark("C") + ended(0) + prompt)
    #expect(s.blocks.map(\.text) == ["for f in *.db; do\necho \"$f\" > list\n> done.txt; done"], "\(s.blocks.map(\.text))")
    #expect(s.waitsAtPrompt)
    // Without the marks, the screen's text, as before.
    let unmarked = marked(prompt + "tar czf b.tgz \\\r\n> data.db\r\n" + mark("C") + ended(0) + prompt)
    #expect(unmarked.blocks.map(\.text) == ["tar czf b.tgz \\\n> data.db"])
}

/// Run Again types a command of one line again. One of several lines is left to the person (Copy Command): bash's is
/// read off the screen, where a continuation prompt ("> ") it didn't mark would come with it, a redirection typed again.
@MainActor @Test func runAgainLeavesCommandsOfSeveralLinesToThePerson() throws {
    let screen = TerminalScreen(columns: 40, rows: 8)
    screen.markToken = token
    let session = try TerminalSession(["/bin/cat"], environment: [:], screen: screen)
    defer { session.close() }
    let view = TerminalView()
    view.session = session
    screen.feed(prompt + "tar czf b.tgz \\\r\n> data.db\r\n" + mark("C") + ended(0) + prompt)
    let block = try #require(screen.blocks.first)
    #expect(block.text == "tar czf b.tgz \\\n> data.db" && screen.waitsAtPrompt)
    let item = NSMenuItem(title: "Run Again", action: #selector(TerminalView.runAgain(_:)), keyEquivalent: "")
    item.representedObject = block
    #expect(!view.validateMenuItem(item) && item.toolTip?.contains("several lines") == true, "\(item.toolTip ?? "")")
    screen.feed("ls\r\n" + mark("C") + ended(0) + prompt)
    item.representedObject = screen.blocks.last
    #expect(screen.blocks.last?.text == "ls" && view.validateMenuItem(item), "\(item.toolTip ?? "")")
}

@Test func terminalMarksFromShellsThatDontMarkOutput() {
    // bash before 4.4 has no PS0: prompts and ends only. Each ended prompt with a command is one, without a time.
    let s = marked(prompt + "ls\r\nout\r\n" + ended(2) + prompt + "\r\n" + ended(2) + prompt)
    #expect(s.blocks.map(\.text) == ["ls"] && s.blocks.map(\.status) == [2] && s.blocks[0].duration == nil)
    #expect(s.blocks[0].output == nil && s.output(of: s.blocks[0]) == "out" && !s.marksOutput)
    // One typed over several lines: all of them, without the continuation prompts.
    s.feed("for i in 1 2; do\r\n> " + mark("B;k=s") + "echo $i; done\r\n1\r\n2\r\n" + ended(0) + prompt)
    #expect(s.blocks.map(\.text) == ["ls", "for i in 1 2; do\necho $i; done"], "\(s.blocks.map(\.text))")
}

@Test func terminalMarksFollowTheirLines() {
    // A prompt drawn again on its line (after a resize) takes the place of the first.
    let s = marked(prompt + "\r" + prompt + "pwd\r\n" + mark("C") + "/home\r\n" + ended(0) + prompt, columns: 30, rows: 3)
    #expect(s.blocks.count == 1 && s.blocks[0].prompt == 0 && s.lines.flatMap(\.marks).count + s.scrollback.flatMap(\.marks).count == 6)
    // Into the scrollback with their lines, and through a resize.
    s.feed("true\r\n" + mark("C") + ended(0) + prompt)
    #expect(s.scrollback.count > 0 && s.blocks.map(\.text) == ["pwd", "true"])
    s.resize(columns: 20, rows: 6)
    #expect(s.blocks.map(\.text) == ["pwd", "true"] && s.blocks[0].prompt == 0)
    // clear: the commands it erased are gone, and its own end has no prompt left.
    s.feed("clear\r\n" + mark("C") + "\u{1B}[H\u{1B}[2J\u{1B}[3J" + ended(0) + prompt)
    #expect(s.blocks.isEmpty && s.waitsAtPrompt)
}

@Test func terminalFindsTextInTheScrollback() {
    // Ten columns, three rows: most of it is scrollback. "an ERROR-error" wraps after "an ERROR-e".
    let s = TerminalScreen(columns: 10, rows: 3)
    s.feed("Error one\r\nok\r\n界 error\r\nan ERROR-error\r\nlast\r\nline")
    typealias P = TerminalScreen.Position
    let found = s.find("error")
    // Ignoring case; after a wide character (two cells) in the cells it is drawn in; one going on into a wrapped line.
    #expect(found.map(\.start) == [P(line: 0, column: 0), P(line: 2, column: 3), P(line: 3, column: 3), P(line: 3, column: 9)])
    #expect(found.map(\.end) == [P(line: 0, column: 5), P(line: 2, column: 8), P(line: 3, column: 8), P(line: 4, column: 4)])
    #expect(s.find("").isEmpty && s.find("nowhere").isEmpty && s.find("LAST\u{0}").isEmpty)
    #expect(s.find("st").map(\.start) == [P(line: 5, column: 2)])
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

// MARK: Marks from real shells

/// bash and zsh started by the terminal mark their prompts and commands with nothing changed on the server: the user's
/// own files run as before (their PROMPT_COMMAND or precmd sees the command's $?), the startup file AirSCP gave the
/// shell is gone once it has started, and the folder comes at each prompt, signed (a folder a program's output names
/// doesn't count). sh can't mark: it runs as before. Here
/// /bin/bash is bash 3.2 (no PS0: no output marks, so no times); a newer bash (Homebrew's), when there is one, marks
/// everything, as zsh does, and a command typed over several lines comes without its continuation prompts.
@MainActor @Test func terminalShellsMarkTheirCommandsOnAServer() async throws {
    let shells = ["/bin/zsh", "/bin/bash", "/opt/homebrew/bin/bash", "/usr/local/bin/bash", "/bin/sh"]
        .filter { FileManager.default.isExecutableFile(atPath: $0) }
    for shell in shells {
        var options = TestServer.Options()
        options.shell = shell
        try await withServer(options) { @MainActor server in
            // bash's prompt is 74 columns, as a CI runner's long host name makes it: the printf line below ends at the
            // screen's right edge.
            try write("export FROM_FILES=yes\nPROMPT_COMMAND='LAST=$?'\nPS1='\(String(repeating: "p", count: 72))\\$ '\n",
                      to: server.path(".bash_profile"))
            try write("export FROM_FILES=yes\nprecmd() { LAST=$? }\n", to: server.path(".zshrc"))
            let session = try await server.connectedSession()
            let screen = TerminalScreen(columns: 100, rows: 30)
            screen.markToken = "feed1234"
            let argv = OpenSSH.terminal(session.host, jump: nil, socket: session.socketPath,
                                        command: OpenSSH.terminalShell(in: server.home, token: "feed1234"))
            let terminal = try TerminalSession(argv, environment: session.askpass.terminalEnvironment, screen: screen)
            defer { terminal.close() }
            /// Runs `command` and waits for `done`.
            func run(_ command: String, until done: @escaping () -> Bool) async -> Bool {
                terminal.send(command + "\r")
                return await eventually(timeout: 20, done)
            }
            func last() -> TerminalScreen.Block? { screen.blocks.last }
            guard shell != "/bin/sh" else {
                #expect(await run("echo marker-$((6*7))", until: { screen.text.contains("marker-42") }), "\(screen.text)")
                #expect(!screen.marksCommands && screen.blocks.isEmpty && !screen.waitsAtPrompt, "\(shell)")
                return
            }
            #expect(await eventually(timeout: 20) { screen.waitsAtPrompt }, "\(shell): \(screen.text)")
            // The temporary startup file is gone, and nothing of it is left in the shell's environment.
            #expect((try? FileManager.default.contentsOfDirectory(atPath: server.root + "/tmp")) == [], "\(shell)")
            #expect(await run("true", until: { last()?.text == "true" && last()?.status == 0 }), "\(shell): \(screen.text)")
            #expect(await run("false", until: { last()?.text == "false" && last()?.status == 1 }), "\(shell): \(screen.text)")
            #expect(await run("echo \"$FROM_FILES $LAST ${AIRSCP_RC-none}\"", until: { last()?.status == 0 }))
            #expect(last().map(screen.output) == "yes 1 none", "\(shell): \(screen.text)")
            #expect(await run("cd /tmp", until: { screen.directory == "/tmp" }), "\(shell): \(screen.directory ?? "nil")")
            #expect(await run("printf 'a b\\nc\\n'; sleep 1", until: { last()?.text.hasPrefix("printf") == true && last()?.running == false }))
            #expect(last().map(screen.output) == "a b\nc", "\(shell): \(screen.text)")
            if screen.marksOutput {
                // zsh and bash 4.4 or later: when each output starts, so how long it took.
                #expect((last()?.duration ?? 0) >= 0.9 && screen.blocks.allSatisfy { $0.duration != nil }, "\(shell)")
            } else {
                #expect(shell == "/bin/bash" && screen.blocks.allSatisfy { $0.duration == nil && $0.output == nil })
            }
            #expect(screen.waitsAtPrompt && screen.blocks.map(\.text).suffix(5)
                        == ["true", "false", "echo \"$FROM_FILES $LAST ${AIRSCP_RC-none}\"", "cd /tmp", "printf 'a b\\nc\\n'; sleep 1"],
                    "\(shell): \(screen.blocks.map(\.text))")
            // A folder that a program's output names isn't the shell's: it doesn't count.
            terminal.send("printf '\\033]7;file://x/etc\\007'; echo spo''ofed; sleep 2\r")
            #expect(await eventually(timeout: 20) { screen.text.contains("spoofed") }, "\(shell): \(screen.text)")
            #expect(screen.directory == "/tmp", "\(shell): \(screen.directory ?? "nil")")
            #expect(await eventually(timeout: 20) { screen.waitsAtPrompt }, "\(shell): \(screen.text)")
            if screen.marksOutput {
                // A command typed over several lines: as zsh says it, or off bash's screen without its "> ".
                for line in ["for i in 1 2; do", "echo \"x$i\""] {
                    terminal.send(line + "\r")
                    #expect(await eventually(timeout: 20) { screen.text.hasSuffix(">") }, "\(shell): \(screen.text)")
                }
                #expect(await run("done", until: { last()?.text.hasPrefix("for") == true && last()?.running == false }))
                #expect(last()?.text == "for i in 1 2; do\necho \"x$i\"\ndone" && last().map(screen.output) == "x1\nx2",
                        "\(shell): \(last()?.text ?? "nil")")
            }
        }
    }
}

// MARK: The Terminal tab's commands, find, Follow in Files and snippets

extension FeatureRoundAppTests {
    /// The Terminal tab with zsh: each command's line, status, time and output for agents and on a right-click (Copy
    /// Output, Copy Command, Run Again, which waits for an empty prompt); ⌘↑ ⌘↓ between the commands; find; Follow in
    /// Files; a snippet typed at the prompt but not run; Open Terminal Here in the tab when Settings says so.
    @MainActor @Test func terminalTabMarksCommandsFindsFollowsAndTypesSnippets() async throws {
        _ = NSApplication.shared
        var options = TestServer.Options()
        options.shell = "/bin/zsh"
        try await withServer(options) { @MainActor server in
            try write("hello\n", to: server.path("site/notes.txt"))
            try write("", to: server.path("other/.keep"))
            try write("", to: server.path(".zshrc"))
            let model = testModel([server.host()])
            model.data.snippets = [Snippet(name: "count", command: "ls | wc -l")]
            let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
            defer { askpass.close() }
            let (main, agent, _) = try agentWindow(model, askpass)
            defer {
                agent.close()
                main.window?.orderOut(nil)
            }
            _ = await call(agent, "select", ["pane": "sidebar", "names": [server.host().displayName]])
            _ = await call(agent, "menu", ["path": "Host > Connect"])
            #expect(await call(agent, "wait", ["until": "connected", "timeout": 20]).error == nil)
            _ = await call(agent, "menu", ["path": "Host > Terminal Tab"])
            let workspace = try #require(main.selectedWorkspace)
            let tab = try #require(workspace.terminal)
            let view = tab.terminal
            #expect(await eventually(timeout: 20) { tab.session?.screen.waitsAtPrompt == true }, "\(tab.session?.screen.text ?? "")")
            func terminal() async -> [String: Any] {
                await call(agent, "snapshot", ["include": ["terminal"]])["terminal"] as? [String: Any] ?? [:]
            }
            func commands() async -> [[String: Any]] { await terminal()["commands"] as? [[String: Any]] ?? [] }
            func type(_ text: String) async { _ = await call(agent, "type", ["text": text, "target": "terminal"]) }
            /// The commands once `count` have ended and the shell waits at its prompt.
            func ended(_ count: Int) async -> Bool {
                let commands = await commands(), shown = await terminal()
                return commands.count == count && commands.allSatisfy { $0["running"] as? Bool == false } && shown["atPrompt"] as? Bool == true
            }

            // Agents read each command's line, exit status, time and output.
            await type("cat site/notes.txt\n")
            #expect(await eventually(timeout: 20) { await ended(1) })
            await type("ls nothing-here\n")
            #expect(await eventually(timeout: 20) { await ended(2) })
            let read = await commands()
            #expect(read.first?["command"] as? String == "cat site/notes.txt" && read.first?["status"] as? Int == 0
                    && read.first?["output"] as? String == "hello" && read.first?["seconds"] is Double && read.first?["running"] as? Bool == false,
                    "\(read)")
            #expect((read.last?["status"] as? Int ?? 0) != 0 && (read.last?["output"] as? String)?.contains("nothing-here") == true)

            // A right-click on the first command's prompt (a word in it is taken as a path too): the command's line and
            // how it ended, Copy Output, Copy Command, Run Again (at an empty prompt).
            let screen = try #require(tab.session?.screen)
            let at = view.convert(NSPoint(x: 12, y: 10), to: nil), window = try #require(view.window)
            let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: at, modifierFlags: [], timestamp: 0,
                                                        windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                                                        clickCount: 1, pressure: 1))
            let menu = try #require(view.menu(for: event))
            let titles = menu.items.map(\.title)
            #expect(titles.contains("“cat site/notes.txt”  ✓ " + TerminalView.duration(screen.blocks[0].duration ?? 0)), "\(titles)")
            #expect(["Copy Output", "Copy Command", "Run Again", "Insert Snippet", "Find…", "Previous Prompt", "Next Prompt"]
                .allSatisfy(titles.contains), "\(titles)")
            menu.update()
            let again = try #require(menu.item(withTitle: "Run Again"))
            #expect(again.isEnabled, "\(again.toolTip ?? "")")
            menu.performActionForItem(at: menu.index(of: try #require(menu.item(withTitle: "Copy Output"))))
            #expect(NSPasteboard.general.string(forType: .string) == "hello")
            menu.performActionForItem(at: menu.index(of: try #require(menu.item(withTitle: "Copy Command"))))
            #expect(NSPasteboard.general.string(forType: .string) == "cat site/notes.txt")
            // Something typed at the prompt: Run Again waits.
            await type("ec")
            #expect(await eventually(timeout: 10) { !screen.waitsAtPrompt })
            menu.update()
            #expect(!again.isEnabled && again.toolTip?.contains("empty prompt") == true)
            _ = await call(agent, "key", ["combo": "ctrl+u", "target": "terminal"])
            #expect(await eventually(timeout: 10) { screen.waitsAtPrompt })
            menu.update()
            menu.performActionForItem(at: menu.index(of: again))
            #expect(await eventually(timeout: 20) { screen.blocks.count == 3 && screen.blocks.last?.status == 0 }, "\(screen.text)")
            let blocks = screen.blocks
            try #require(blocks.count == 3)
            #expect(blocks[2].text == "cat site/notes.txt" && screen.output(of: blocks[2]) == "hello")

            // ⌘↑ ⌘↓: from the prompt up through the commands, then down to the live screen.
            view.previousPrompt(nil)
            #expect(view.jumped == blocks[2].prompt)
            view.previousPrompt(nil)
            view.previousPrompt(nil)
            view.previousPrompt(nil)
            #expect(view.jumped == blocks[0].prompt)
            view.nextPrompt(nil)
            #expect(view.jumped == blocks[1].prompt)
            view.nextPrompt(nil)
            view.nextPrompt(nil)
            #expect(view.jumped == nil)

            // Find: every "hello" in the output, the newest shown first; Done takes the marks away.
            #expect(await call(agent, "press", ["id": "terminal.find"]).error == nil)
            #expect(await call(agent, "set", ["id": "terminal.findText", "value": "HELLO"]).error == nil)
            #expect(view.matches.count == 2 && view.currentMatch == 1 && tab.findCount.stringValue == "2 of 2")
            // Agents read the count among the elements.
            let elements = await call(agent, "snapshot", ["include": ["elements"]])["elements"] as? [[String: Any]] ?? []
            let count = elements.first { $0["id"] as? String == "terminal.findCount" }
            #expect((count?["value"] ?? count?["title"]).map { "\($0)" } == "2 of 2", "\(count ?? [:])")
            #expect(await call(agent, "set", ["id": "terminal.findText", "value": "nowhere"]).error == nil)
            #expect(view.matches.isEmpty && tab.findCount.stringValue == "Not found")
            #expect(await call(agent, "press", ["id": "terminal.findDone"]).error == nil)
            #expect(view.matches.isEmpty && view.window?.firstResponder === view)
            // ⌘F (Edit ▸ Filter) from the terminal, and again from the find bar, is the terminal's find (not the hosts').
            @MainActor func findHasTheKeyboard() -> Bool { (view.window?.firstResponder as? NSText)?.delegate === tab.findField }
            #expect(await call(agent, "menu", ["path": "Edit > Filter"]).error == nil && findHasTheKeyboard())
            #expect(await call(agent, "menu", ["path": "Edit > Filter"]).error == nil && findHasTheKeyboard())
            _ = await call(agent, "press", ["id": "terminal.findDone"])

            // Follow in Files: the server pane goes where the shell goes.
            #expect(await call(agent, "set", ["id": "terminal.follow", "value": true]).error == nil)
            await type("cd site\n")
            #expect(await eventually(timeout: 20) { workspace.browser.right.dir == server.path("site") },
                    "\(workspace.browser.right.dir ?? "nil")")
            _ = await call(agent, "set", ["id": "terminal.follow", "value": false])

            // A snippet is typed at the prompt, not run: the next command that runs is the one typed after it.
            #expect(await call(agent, "set", ["id": "terminal.snippets", "value": "count"]).error == nil)
            #expect(await eventually(timeout: 10) { screen.text.hasSuffix("ls | wc -l") && !screen.waitsAtPrompt }, "\(screen.text)")
            _ = await call(agent, "key", ["combo": "ctrl+u", "target": "terminal"])
            #expect(await eventually(timeout: 10) { screen.waitsAtPrompt })
            await type("true\n")
            #expect(await eventually(timeout: 20) { await ended(5) }, "\(screen.text)")
            #expect(screen.blocks.map(\.text).suffix(2) == ["cd site", "true"], "\(screen.blocks.map(\.text))")

            // Open Terminal Here goes to the tab when Settings says so: cd typed at its empty prompt.
            model.data.settings.openTerminalHereInTab = true
            _ = await call(agent, "press", ["title": "Files"])
            #expect(await call(agent, "go", ["pane": "right", "path": server.home]).error == nil)
            _ = await call(agent, "select", ["pane": "right", "names": ["other"]])
            #expect(await call(agent, "menu", ["path": "File > Open Terminal Here"]).error == nil)
            #expect(workspace.tabs.selectedTabViewItemIndex == 3)
            #expect(await eventually(timeout: 20) { screen.directory == server.path("other") }, "\(screen.directory ?? "nil")")
            tab.session?.close()
            await workspace.connection.disconnect()
        }
    }
}

extension FeatureRoundAppTests {
    /// Open Terminal Here into a running shell types cd only where the shell reads the folder's path as a name: tcsh marks
    /// nothing (it isn't bash or zsh), so a \ or ! isn't typed there, another path is once the person says when; zsh
    /// marks its commands, so a ! is typed at its empty prompt; a control character (a tab here) is typed nowhere.
    @MainActor @Test func cdIsTypedOnlyWhereTheShellReadsTheFolderAsAName() async throws {
        _ = NSApplication.shared
        let cases: [(shell: String, folders: [(name: String, sheet: String?)])] = [
            ("/bin/tcsh", [("odd!name", "type cd yourself"), ("plain", "Type cd into the Terminal tab?")]),
            ("/bin/zsh", [("tab\there", "type cd yourself"), ("odd!name", nil)]),
        ]
        for (shell, folders) in cases {
            var options = TestServer.Options()
            options.shell = shell
            try await withServer(options) { @MainActor server in
                for folder in folders { try rawMkdir(server.path(folder.name)) }
                try write("", to: server.path(".zshrc"))
                let model = testModel([server.host()])
                model.data.settings.openTerminalHereInTab = true
                let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
                defer { askpass.close() }
                let (main, agent, _) = try agentWindow(model, askpass)
                defer {
                    agent.close()
                    main.window?.orderOut(nil)
                }
                _ = await call(agent, "select", ["pane": "sidebar", "names": [server.host().displayName]])
                _ = await call(agent, "menu", ["path": "Host > Connect"])
                #expect(await call(agent, "wait", ["until": "connected", "timeout": 20]).error == nil)
                _ = await call(agent, "menu", ["path": "Host > Terminal Tab"])
                let workspace = try #require(main.selectedWorkspace)
                #expect(await eventually(timeout: 20) { workspace.terminal.session?.screen.shellPID != nil })
                let screen = try #require(workspace.terminal.session?.screen)
                if shell.hasSuffix("zsh") { #expect(await eventually(timeout: 20) { screen.waitsAtPrompt }, "\(screen.text)") }
                for (name, sheet) in folders {
                    _ = await call(agent, "press", ["title": "Files"])
                    #expect(await call(agent, "go", ["pane": "right", "path": server.home]).error == nil)
                    #expect(await call(agent, "select", ["pane": "right", "names": [name]]).error == nil, "\(shell) \(name)")
                    #expect(await call(agent, "menu", ["path": "File > Open Terminal Here"]).error == nil)
                    if let sheet {
                        let shown = await call(agent, "wait", ["until": "sheet", "text": sheet, "timeout": 10])
                        #expect(shown.error == nil, "\(shell) \(name): \(shown.error ?? "")")
                        _ = await call(agent, "key", ["combo": "escape"])
                        #expect(await call(agent, "wait", ["until": "no_sheet", "timeout": 10]).error == nil)
                    } else {
                        #expect(await eventually(timeout: 20) { screen.directory == server.path(name) }, "\(screen.directory ?? "nil")")
                    }
                }
                #expect(screen.directory != server.path("tab\there"), "\(screen.directory ?? "nil")")
                workspace.terminal.session?.close()
                await workspace.connection.disconnect()
            }
        }
    }
}

// MARK: The lab: Debian's bash, BusyBox's sh

@Suite(.enabled(if: Lab.enabled, "Docker lab: AIRSCP_DOCKER=1 ./test.sh"))
@MainActor struct TerminalLabTests {
    /// Debian's bash 5 (started by dash) marks each command, with its exit status, time, output and folder (one of
    /// several lines without its continuation prompts); BusyBox's sh can't mark: its commands run as before, and there
    /// are none to show.
    @Test func bashOnDebianMarksItsCommandsAndBusyBoxShRunsWithout() async throws {
        try await withLab { lab in
            for (host, marks) in [(Lab.target(), true), (Lab.minimal(), false)] {
                let session = try await lab.connected(host)
                let screen = TerminalScreen(columns: 100, rows: 30)
                screen.markToken = "1ab5"
                let argv = OpenSSH.terminal(host, jump: nil, socket: session.socketPath,
                                            command: OpenSSH.terminalShell(in: nil, token: "1ab5"))
                let terminal = try TerminalSession(argv, environment: session.askpass.terminalEnvironment, screen: screen)
                defer { terminal.close() }
                if marks { #expect(await eventually(timeout: 30) { screen.waitsAtPrompt }, "\(screen.text)") }
                terminal.send("echo marker-$((6*7)) ${AIRSCP_RC-none}; false\r")
                #expect(await eventually(timeout: 30) { screen.text.contains("marker-42 none") }, "\(screen.text)")
                guard marks else {
                    // The prompt after the first command, where marks would be, comes before the next one's output.
                    terminal.send("echo after-$((1+1))\r")
                    #expect(await eventually(timeout: 30) { screen.text.contains("after-2") }, "\(screen.text)")
                    #expect(!screen.marksCommands && screen.blocks.isEmpty && screen.directory == nil, "\(screen.text)")
                    continue
                }
                #expect(await eventually(timeout: 30) { screen.blocks.last?.status == 1 }, "\(screen.text)")
                let block = try #require(screen.blocks.last)
                #expect(block.text == "echo marker-$((6*7)) ${AIRSCP_RC-none}; false" && block.duration != nil)
                #expect(screen.output(of: block) == "marker-42 none" && screen.directory == "/home/dev" && screen.waitsAtPrompt)
                // A command typed over several lines is read off the screen without bash's continuation prompts.
                terminal.send("for i in 1 2; do\r")
                #expect(await eventually(timeout: 30) { screen.text.hasSuffix(">") }, "\(screen.text)")
                terminal.send("echo \"x$i\"; done\r")
                #expect(await eventually(timeout: 30) { screen.blocks.last?.text.hasPrefix("for") == true && screen.waitsAtPrompt })
                #expect(screen.blocks.last?.text == "for i in 1 2; do\necho \"x$i\"; done", "\(screen.text)")
            }
        }
    }
}
