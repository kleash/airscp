import AirSCPCore
import XCTest

/// What ties the terminal, Search, Files and the editor together, on the Docker lab's target: Search's file shown in
/// Files, `grep -n`'s "file:line" opened in the editor at that line, a word selected in the terminal and copied, the
/// editor's syntax colours and Go to Line. Each test works in a folder of its own in dev's home (`LabServer`). Skipped
/// while the lab isn't running (testenv/up.sh).
final class LinksTests: XCTestCase {
    private var folder: URL!
    private var lab: LabServer!

    override func setUp() async throws {
        continueAfterFailure = false
        try XCTSkipUnless(LabServer.isUp(), "The Docker lab's target doesn't answer on 127.0.0.1:42201 (testenv/up.sh starts it)")
        folder = try labFolder()
        lab = try await LabServer(knownHosts: folder.appendingPathComponent("known_hosts").path)
    }

    override func tearDown() async throws {
        await lab?.remove()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// Search finds the file; a tap shows it in Files, selected in its folder (scrolled to, past 40 other files), and its
    /// menu has Edit.
    @MainActor func testSearchShowsAFoundFileSelectedInFiles() async throws {
        let name = "zz-links-\(UUID().uuidString.prefix(8).lowercased()).txt"
        _ = try await lab.session.run("cd \(Quote.shell(lab.folder)) && touch $(seq -f 'a-%02g.txt' 0 39) \(name)")
        let app = launchConnectedToLab(folder)
        app.show("Search")
        let field = app.searchFields.firstMatch
        XCTAssert(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(String(name.dropLast(4)))
        app.buttons["Find “\(name.dropLast(4))” in lab"].tap()
        let found = app.buttons[lab.path(name)]
        XCTAssert(found.waitForExistence(timeout: 60), "The file isn't found")
        keepScreenshot("Found")
        found.tap()

        let row = app.cells.containing(.staticText, identifier: name).firstMatch
        XCTAssert(row.waitForExistence(timeout: 30), "The file isn't shown in Files")
        XCTAssert(app.scrollViews.matching(identifier: "path").firstMatch.staticTexts[RemotePath.name(lab.folder)].exists)
        XCTAssert(row.isSelected, "The file isn't selected")
        XCTAssert(row.isHittable, "The file isn't scrolled to")
        keepScreenshot("Shown in Files")
        row.staticTexts[name].press(forDuration: 1)  // as FilesTests do: a press in the middle of an iPad's wide row brought no menu on iOS 27
        XCTAssert(app.buttons["Edit"].waitForExistence(timeout: 5), "No Edit in the file's menu")
    }

    /// `grep -n` names a file and a line: its button above the command line opens the editor at that line.
    @MainActor func testGrepsFileAndLineOpensInTheEditorAtThatLine() async throws {
        let lines = (1...30).map { $0 == 20 ? "the needle-\($0) is here" : "line \($0)" }
        try await lab.write(lines.joined(separator: "\n") + "\n", to: "notes.txt")
        try await lab.write("nothing\n", to: "other.txt")
        let app = launchConnectedToLab(folder)
        let terminal = showTerminal(app)
        let line = app.textFields["commandLine"]
        line.tap()
        line.typeText("cd \(lab.folder)\n")  // a command of its own: a relative path is in the folder the command ran in
        line.tap()
        line.typeText("grep -n needle *.txt\n")
        XCTAssert(terminal.shows("notes.txt:20:the needle-20"), terminal.text)
        let open = app.buttons.matching(identifier: "fileLine").firstMatch
        XCTAssert(open.waitForExistence(timeout: 15), "No file:line button")
        XCTAssertEqual(open.label, "notes.txt:20")
        keepScreenshot("file:line")
        open.tap()

        let text = app.textViews["editor.text"]
        XCTAssert(text.waitForExistence(timeout: 30), "The editor isn't open")
        XCTAssert(app.staticTexts["Line 20 of 31"].waitForExistence(timeout: 10), "Not at line 20")
        XCTAssert((text.value as? String)?.hasPrefix("line 1\nline 2\n") == true)
        keepScreenshot("Editor at line 20")
    }

    /// Touch and hold selects a word; Copy puts it on the pasteboard (pasted into the command line with ⌘V), and the
    /// menu's Paste types it at the prompt.
    @MainActor func testATouchAndHoldSelectsAWordToCopyAndPaste() {
        let app = launchConnectedToLab(folder)
        let terminal = showTerminal(app)
        selectAndCopy(app, terminal: terminal)
        keepScreenshot("Copied")
        let before = terminal.text.components(separatedBy: "copyme").count - 1
        hold(terminal, menuItem: "Paste", in: app)
        XCTAssert(terminal.shows("copyme", times: before + 1), terminal.text)
    }

    /// A shell script in colours (screenshots in light and dark), and Go to Line.
    @MainActor func testAShellScriptInColoursAndGoToLine() async throws {
        let script = """
            #!/bin/bash
            # Deploys the site: copies the build, then restarts the web server.
            set -e
            name="airscp-demo"   # the site's name
            count=3

            deploy() {
              local target=$1
              for i in $(seq 1 $count); do
                echo "Copy $i of $count to '$target'"
              done
            }

            if [ -d /srv/www ]; then
              deploy /srv/www
            else
              echo "No /srv/www here # not a comment" >&2
              exit 1
            fi
            echo "Deployed $name"
            """
        try await lab.write(script + "\n" + (21...40).map { "echo \"step \($0)\"" }.joined(separator: "\n") + "\n", to: "deploy.sh")
        let app = launchConnectedToLab(folder)
        openFile("deploy.sh", in: app)
        keepScreenshot("Shell script in colours")
        goToLine("35", in: app)
        XCTAssert(app.staticTexts["Line 35 of 41"].waitForExistence(timeout: 10), "Not at line 35")
        keepScreenshot("Go to line 35")
    }

    /// iPad, in portrait and in landscape: Go to Line in the editor, and a word selected and copied in the terminal;
    /// turning it keeps the editor where it was.
    @MainActor func testIPadGoToLineAndSelectionInPortraitAndLandscape() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        try await lab.write((1...60).map { "echo \"step \($0)\"" }.joined(separator: "\n") + "\n", to: "steps.sh")
        XCUIDevice.shared.orientation = .portrait
        let app = launchConnectedToLab(folder)
        openFile("steps.sh", in: app)
        goToLine("50", in: app)
        XCTAssert(app.staticTexts["Line 50 of 61"].waitForExistence(timeout: 10))
        keepScreenshot("iPad portrait, line 50")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssert(app.textViews["editor.text"].waitForExistence(timeout: 10) && app.staticTexts["Line 50 of 61"].exists)
        keepScreenshot("iPad landscape, still line 50")
        goToLine("10", in: app)
        XCTAssert(app.staticTexts["Line 10 of 61"].waitForExistence(timeout: 10))
        keepScreenshot("iPad landscape, line 10")
        app.buttons["Close"].tap()

        let terminal = showTerminal(app)
        selectAndCopy(app, terminal: terminal)
        keepScreenshot("iPad landscape, copied")
        XCUIDevice.shared.orientation = .portrait
        selectAndCopy(app, terminal: terminal)
        keepScreenshot("iPad portrait, copied")
    }

    // MARK: Helpers

    /// Fills the terminal with "copyme", selects one by touch and hold, copies it, and pastes it into the empty command
    /// line with ⌘V.
    @MainActor private func selectAndCopy(_ app: XCUIApplication, terminal: XCUIElement) {
        let line = app.textFields["commandLine"]
        line.tap()
        line.typeText("yes copyme | head -n 100\n")
        XCTAssert(terminal.shows("copyme\ncopyme\ncopyme"), terminal.text)
        hold(terminal, menuItem: "Copy", in: app)
        line.tap()
        app.typeKey("v", modifierFlags: .command)
        // The Simulator lets the first ⌘ or Control key after a launch through as the plain key (Settings does it too).
        if line.value as? String != "copyme" { app.typeKey("v", modifierFlags: .command) }
        XCTAssertEqual(line.value as? String, "copyme")
        // Emptied, and Return lets go of it: a tap on a field that has the keyboard shows the system's Paste callout,
        // which XCUITest can't read (another process), and every query after it waits.
        line.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 6) + "\n")
    }

    /// Touches and holds a word in the terminal (left, a little above the middle), then chooses `menuItem` in the edit menu.
    @MainActor private func hold(_ terminal: XCUIElement, menuItem: String, in app: XCUIApplication) {
        terminal.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.4)).withOffset(CGVector(dx: 22, dy: 0)).press(forDuration: 1)
        let item = app.menuItems[menuItem]
        XCTAssert(item.waitForExistence(timeout: 5), "No \(menuItem) in the edit menu: \(app.debugDescription)")
        keepScreenshot("Selected, menu for \(menuItem)")
        item.tap()
    }

    /// Opens the file from the test's folder in the editor (Files ▸ the folder ▸ the file).
    @MainActor private func openFile(_ name: String, in app: XCUIApplication) {
        app.show("Files")
        let mine = app.staticTexts[RemotePath.name(lab.folder)]
        XCTAssert(mine.waitForExistence(timeout: 30), "The test's folder isn't listed in the home folder")
        mine.tap()
        let file = app.staticTexts[name]
        XCTAssert(file.waitForExistence(timeout: 10))
        file.tap()
        XCTAssert(app.textViews["editor.text"].waitForExistence(timeout: 30), "The editor isn't open")
    }

    @MainActor private func goToLine(_ number: String, in app: XCUIApplication) {
        app.buttons["Go to Line"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssert(field.waitForExistence(timeout: 5))
        XCTAssert(app.alerts.buttons["Go"].exists)
        field.typeText(number + "\n")  // Return: Go (see clearAndType)
    }

    @MainActor private func keepScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
