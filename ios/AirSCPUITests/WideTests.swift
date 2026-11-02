import AirSCPCore
import XCTest

/// Wide layouts (2i) on an iPad against the Docker lab, logged in through a saved server as FilesTests are: in portrait
/// the tabs as a sidebar that lists the open server, whose workspace has both Files sides; on its side the workspace with
/// the terminal drawer and Transfers in an inspector; turning keeps the folder, the scroll position, the terminal's shell
/// and a running transfer; the editor as a column that keeps its text; Full Window and the menu's shortcuts. Nothing is
/// written on the server (the editor closes without saving). Skipped on an iPhone (compact: the other suites) and while
/// the lab isn't running.
final class WideTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        let pad = await MainActor.run { UIDevice.current.userInterfaceIdiom == .pad }
        try XCTSkipUnless(pad, "iPad only")
        try XCTSkipUnless(LabServer.isUp(), "The Docker lab's target doesn't answer on 127.0.0.1:42201 (testenv/up.sh starts it)")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("airscp-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        await MainActor.run { XCUIDevice.shared.orientation = .portrait }
    }

    override func tearDown() async throws {
        await MainActor.run { XCUIDevice.shared.orientation = .portrait }
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// Portrait: the sidebar (opened from the tab bar) lists the open server; its workspace shows both sides.
    @MainActor func testPortraitSidebarListsTheServerAndItsWorkspaceShowsBothSides() {
        let app = launch()
        let toggle = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sidebar'")).firstMatch  // "Toggle sidebar"
        XCTAssert(toggle.waitForExistence(timeout: 10),
                  "No sidebar button: \(app.buttons.allElementsBoundByIndex.map { $0.identifier + "|" + $0.label })")
        toggle.tap()
        keepScreenshot("Sidebar, portrait")
        openWorkspace(app)
        XCTAssert(app.navigationBars["lab"].waitForExistence(timeout: 10), "No server side")
        XCTAssert(app.navigationBars["On iPad"].exists, "No device side")
        XCTAssert(app.scrollViews.matching(identifier: "path").firstMatch.staticTexts["dev"].waitForExistence(timeout: 30),
                  "The home folder isn't shown")
        XCTAssert(app.buttons["drawer"].exists, "No terminal drawer")
        keepScreenshot("Workspace, portrait")
    }

    /// On its side: the files, the terminal pulled up under them, Transfers in the inspector (on its own once a transfer
    /// runs). Turning to portrait and back keeps the folder and its scroll position, the shell and its output, and the
    /// running transfer, which ends checked.
    @MainActor func testTheWorkspaceKeepsFolderScrollShellAndTransferWhenTurned() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch(speedLimit: 20_000)  // /usr/bin/bash, 1.4 MB: about 70 s
        openWorkspace(app)
        let path = app.scrollViews.matching(identifier: "path").firstMatch
        XCTAssert(path.buttons["/"].waitForExistence(timeout: 30), "No path")
        path.buttons["/"].tap()
        reveal("usr", under: path, app).tap()
        XCTAssert(path.staticTexts["usr"].waitForExistence(timeout: 30), "/usr isn't shown")
        reveal("bin", under: path, app).tap()
        XCTAssert(path.staticTexts["bin"].waitForExistence(timeout: 30), "/usr/bin isn't shown")

        // Sent to this iPad's side: a download, which the inspector shows on its own.
        _ = reveal("bash", under: path, app)
        app.cells.containing(.staticText, identifier: "bash").firstMatch.swipeLeft()
        app.buttons["Send"].tap()
        XCTAssert(app.navigationBars["Transfers"].waitForExistence(timeout: 30), "Transfers didn't show on their own")
        let transfer = app.descendants(matching: .any)["transfer bash"]
        XCTAssert(transfer.waitForExistence(timeout: 10))

        // Well down the folder (354 names), away from its top.
        let top = app.staticTexts["apt-cache"]
        for _ in 0..<4 { list(under: path, app)?.swipeUp(velocity: .fast) }
        let seen = names(under: path, app)
        XCTAssert(!onScreen(top) && !seen.isEmpty, "Not scrolled down")

        // The terminal, pulled up; typed in, then the keyboard hidden (it would cover the files).
        app.buttons["drawer"].tap()
        let terminal = app.descendants(matching: .any)["terminal"]
        XCTAssert(terminal.waitForExistence(timeout: 10), "No terminal in the drawer")
        XCTAssert(terminal.shows("dev@"), "No prompt: \(terminal.text)")
        type("echo wide-$((6*7))\n", in: terminal, app)
        XCTAssert(terminal.shows("wide-42"), terminal.text)
        keepScreenshot("Workspace, landscape")

        for (turn, orientation) in [UIDeviceOrientation.portrait, .landscapeLeft].enumerated() {
            let before = transfer.label
            XCUIDevice.shared.orientation = orientation
            let name = orientation.isLandscape ? "landscape" : "portrait"
            XCTAssert(path.staticTexts["bin"].waitForExistence(timeout: 10), "The folder changed in \(name)")
            XCTAssert(!onScreen(top) && !names(under: path, app).isDisjoint(with: seen), "The scroll position changed in \(name)")
            XCTAssert(transfer.waitForExistence(timeout: 10), "The transfer isn't shown in \(name)")
            let moved = expectation(for: NSPredicate(format: "label != %@", before), evaluatedWith: transfer)
            XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 30), .completed, "Stuck in \(name): \(transfer.label)")
            XCTAssert(terminal.text.contains("wide-42"), "The output is gone in \(name): \(terminal.text)")
            type("echo turned-$((\(turn) + 10))\n", in: terminal, app)
            XCTAssert(terminal.shows("turned-\(turn + 10)"), "The shell doesn't answer in \(name): \(terminal.text)")
            keepScreenshot("Workspace, turned to " + name)
        }
        XCTAssert(waitUntil(transfer, says: "Checksums match", timeout: 90), transfer.label)
        let copy = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("Documents/bash").path)
        XCTAssertEqual(copy?[.size] as? Int, 1_412_096)
    }

    /// On its side the editor opens as a column in the second side's place; turned to portrait it is a sheet, with what
    /// was typed; Full Window gives it the window, with the changes beside the text; Escape gives the window back. The
    /// file is the lab's /etc/hostname, closed without saving (dev couldn't write it anyway).
    @MainActor func testTheEditorIsAColumnThatKeepsItsTextAndFillsTheWindow() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch()
        openWorkspace(app)
        let path = app.scrollViews.matching(identifier: "path").firstMatch
        XCTAssert(path.buttons["/"].waitForExistence(timeout: 30), "No path")
        path.buttons["/"].tap()
        reveal("etc", under: path, app).tap()
        XCTAssert(path.staticTexts["etc"].waitForExistence(timeout: 30), "/etc isn't shown")
        reveal("hostname", under: path, app).tap()
        let text = app.textViews["editor.text"].firstMatch  // a sheet on its way out and the column: the same text
        XCTAssert(text.waitForExistence(timeout: 10), "No editor")
        XCTAssertFalse(app.navigationBars["On iPad"].exists, "The editor isn't in the second side's place")
        XCTAssert(app.navigationBars["lab"].exists, "The server's side is gone")
        text.typeWithFocus("# typed\n")
        keepScreenshot("Editor column")

        XCUIDevice.shared.orientation = .portrait
        XCTAssert(app.navigationBars["On iPad"].waitForExistence(timeout: 10), "Both sides aren't back in portrait")
        XCTAssert(text.waitForExistence(timeout: 10), "No editor sheet in portrait")
        XCTAssert((text.value as? String ?? "").contains("# typed"), "The text is gone: \(String(describing: text.value))")
        keepScreenshot("Editor sheet, portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssert(app.navigationBars["On iPad"].waitForNonExistence(timeout: 10), "No editor column in landscape")
        XCTAssert((text.value as? String ?? "").contains("# typed"), "The text is gone: \(String(describing: text.value))")

        app.navigationBars["hostname"].buttons["Full Window"].tap()
        let exit = app.buttons["Exit Full Window"]
        XCTAssert(exit.waitForExistence(timeout: 10), "No Full Window")
        XCTAssertFalse(onScreen(app.navigationBars["lab"]), "The files show in Full Window")
        XCTAssert(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '+ # typed'")).firstMatch.waitForExistence(timeout: 10),
                  "No changes beside the text")
        keepScreenshot("Editor, full window")
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTExpectFailure("The Simulator delivers no hardware Escape: it reaches neither the shell in the Terminal tab nor a key command",
                         strict: false) {
            XCTAssert(exit.waitForNonExistence(timeout: 5), "Escape didn't leave Full Window")
        }
        if exit.exists { exit.tap() }
        XCTAssert(exit.waitForNonExistence(timeout: 10), "Exit Full Window didn't leave it")
        XCTAssert(app.navigationBars["hostname"].buttons["Full Window"].waitForExistence(timeout: 10), "The column isn't back")

        app.buttons["Close"].tap()
        app.buttons["Don't Save"].tap()
        XCTAssert(text.waitForNonExistence(timeout: 10), "The editor didn't close")
        XCTAssert(app.navigationBars["On iPad"].waitForExistence(timeout: 10), "The second side isn't back")
    }

    /// Full Window from the drawer's button and with ⌘⇧F (Escape stays the shell's there); ⌘T a new terminal in the
    /// drawer; ⌘1–4 the four places, ⌘K Search.
    @MainActor func testFullWindowAndTheKeyboardShortcuts() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch()
        openWorkspace(app)
        let drawer = app.buttons["drawer"]
        XCTAssert(drawer.waitForExistence(timeout: 30))
        XCTAssert(waitUntil(drawer, says: "lab", timeout: 30), drawer.label)
        // Again if the first ⌘T came before the menu was built (a busy Mac).
        for _ in 0..<2 where !drawer.label.contains("lab (") {
            app.typeKey("t", modifierFlags: .command)
            _ = waitUntil(drawer, says: "lab (", timeout: 15)
        }
        XCTAssert(drawer.label.contains("lab ("), "⌘T: \(drawer.label)")
        let terminal = app.descendants(matching: .any)["terminal"]
        XCTAssert(terminal.waitForExistence(timeout: 10), "The drawer didn't open")
        XCTAssert(terminal.shows("dev@"), "No prompt: \(terminal.text)")

        app.buttons["Full Window"].tap()
        let exit = app.buttons["Exit Full Window"]
        XCTAssert(exit.waitForExistence(timeout: 10), "No Full Window")
        keepScreenshot("Terminal, full window")
        XCTAssertFalse(onScreen(app.cells["workspace"]), "The sidebar shows in Full Window")
        XCTAssertFalse(onScreen(drawer), "The workspace shows in Full Window")
        XCTAssert(terminal.waitForExistence(timeout: 10))
        // Escape stays with the terminal (vim's): it doesn't leave Full Window.
        terminal.tap()
        app.typeKey(XCUIKeyboardKey.escape, modifierFlags: [])
        XCTAssert(app.buttons["Hide Keyboard"].waitForExistence(timeout: 10))
        XCTAssert(exit.exists, "Escape left Full Window")
        app.buttons["Hide Keyboard"].tap()
        exit.tap()
        XCTAssert(exit.waitForNonExistence(timeout: 10))
        XCTAssert(drawer.waitForExistence(timeout: 10))

        app.typeKey("f", modifierFlags: [.command, .shift])
        XCTAssert(exit.waitForExistence(timeout: 10), "⌘⇧F didn't enter Full Window")
        app.typeKey("f", modifierFlags: [.command, .shift])
        XCTAssert(exit.waitForNonExistence(timeout: 10), "⌘⇧F didn't leave Full Window")

        app.typeKey("1", modifierFlags: .command)
        XCTAssert(app.navigationBars["Servers"].waitForExistence(timeout: 10), "⌘1")
        app.typeKey("2", modifierFlags: .command)
        XCTAssert(app.navigationBars["On iPad"].waitForExistence(timeout: 10), "⌘2")
        app.typeKey("3", modifierFlags: .command)
        XCTAssert(app.buttons["New Terminal"].waitForExistence(timeout: 10), "⌘3")
        app.typeKey("4", modifierFlags: .command)
        XCTAssert(app.navigationBars["Transfers"].waitForExistence(timeout: 10), "⌘4")
        app.typeKey("k", modifierFlags: .command)
        XCTAssert(app.searchFields.firstMatch.waitForExistence(timeout: 10), "⌘K")
        keepScreenshot("Search, landscape")
    }

    // MARK: Helpers

    /// Launches the app with the lab's target saved as "lab" and logs into it (a new host key trusted at once);
    /// `speedLimit`: transfers' bytes a second.
    @MainActor private func launch(speedLimit: Int? = nil) -> XCUIApplication {
        try? """
        {"hosts":[{"id":"\(UUID())","label":"lab","hostname":"127.0.0.1","port":42201,"username":"dev","auth":"password",
                   "hostKeyCheck":"acceptNew"}]}
        """.write(to: folder.appendingPathComponent("airscp.json"), atomically: true, encoding: .utf8)
        let app = XCUIApplication()
        app.launchEnvironment["AIRSCP_SUPPORT_DIR"] = folder.path
        if let speedLimit { app.launchEnvironment["AIRSCP_TEST_SPEED_LIMIT"] = String(speedLimit) }
        app.launch()
        let saved = app.staticTexts["lab"].firstMatch
        XCTAssert(saved.waitForExistence(timeout: 30), "No saved server")
        saved.tap()
        let password = app.secureTextFields["answer"]
        XCTAssert(password.waitForExistence(timeout: 30), "No password question")
        password.tap()  // focused already, unless the sheet is still on its way
        password.typeText("porter-dev\n")
        XCTAssert(password.waitForNonExistence(timeout: 30), "The password question stayed")
        XCTAssert(app.staticTexts["Connected"].waitForExistence(timeout: 30), "Not connected")
        return app
    }

    /// The server's workspace, from its entry in the sidebar.
    @MainActor private func openWorkspace(_ app: XCUIApplication) {
        let entry = app.cells["workspace"], show = app.buttons["ToggleSideBar"]  // the tabs at the top's sidebar button
        // The sidebar comes back as the app last left it: hidden, the tabs at the top show it.
        if !entry.waitForExistence(timeout: 10) && show.exists { show.tap() }
        XCTAssert(entry.waitForExistence(timeout: 30), "The open server isn't in the sidebar")
        entry.tap()
        XCTAssert(app.buttons["drawer"].waitForExistence(timeout: 30), "No workspace")
    }

    private func onScreen(_ element: XCUIElement) -> Bool {
        element.exists && element.isHittable
    }

    /// The list of the side whose path bar this is.
    private func list(under path: XCUIElement, _ app: XCUIApplication) -> XCUIElement? {
        let point = CGPoint(x: path.frame.midX, y: path.frame.maxY + 60)
        return app.collectionViews.allElementsBoundByIndex.first { $0.frame.contains(point) }
    }

    /// The names of the rows on screen in that list.
    private func names(under path: XCUIElement, _ app: XCUIApplication) -> Set<String> {
        Set(list(under: path, app)?.cells.allElementsBoundByIndex.filter(\.isHittable).map { $0.staticTexts.firstMatch.label } ?? [])
    }

    /// A row's name, scrolled to in the list under a side's path bar: rows past the screen aren't there until scrolled to
    /// (a tap brings one that is there into view).
    private func reveal(_ name: String, under path: XCUIElement, _ app: XCUIApplication) -> XCUIElement {
        let row = app.staticTexts[name]
        for _ in 0..<20 where !row.waitForExistence(timeout: 2) { list(under: path, app)?.swipeUp() }
        return row
    }

    /// Types in the terminal, then hides the keyboard with the key bar's button.
    private func type(_ text: String, in terminal: XCUIElement, _ app: XCUIApplication) {
        terminal.tap()
        let hide = app.buttons["Hide Keyboard"]
        XCTAssert(hide.waitForExistence(timeout: 10), "No key bar")
        app.typeText(text)
        hide.tap()
    }

    /// Waits until the element's label says `text`.
    private func waitUntil(_ element: XCUIElement, says text: String, timeout: TimeInterval) -> Bool {
        let found = expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: element)
        return XCTWaiter.wait(for: [found], timeout: timeout) == .completed
    }

    /// Keeps a screenshot in the test's results, to look at the layouts in light and dark.
    @MainActor private func keepScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
