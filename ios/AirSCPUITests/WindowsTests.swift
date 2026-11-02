import XCTest

/// Several windows on an iPad (Phase 3): the servers, connections, transfers and terminals are the app's, so another
/// window shows them without logging in again, and closing the window that opened them leaves them to the others; which
/// terminal a window shows is its own. Open in New Window shows an open server's workspace in a window of its own. On the
/// Docker lab's target, as TerminalTests. The Simulator shows one window at a time (full-screen apps): the one behind is
/// still there for XCUITest, so what a test taps is the one on screen. Skipped on an iPhone (one window) and while the lab
/// isn't running.
final class WindowsTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        continueAfterFailure = false
        let pad = await MainActor.run { UIDevice.current.userInterfaceIdiom == .pad }
        try XCTSkipUnless(pad, "iPad only: an iPhone has one window")
        try XCTSkipUnless(LabServer.isUp(), "The Docker lab's target doesn't answer on 127.0.0.1:42201 (testenv/up.sh starts it)")
        folder = try labFolder()
    }

    override func tearDown() async throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// A second window (the Home Screen's New Window) logs in, which starts a download, types in its terminal and opens
    /// another one; closed, it leaves them all to the first window, which shows them without asking for the password and
    /// shows its own terminal (the first), not the one the closed window showed.
    @MainActor func testTheFirstWindowKeepsWhatAClosedWindowOpened() {
        let app = XCUIApplication()
        app.launchEnvironment["AIRSCP_SUPPORT_DIR"] = folder.path
        app.launchEnvironment["AIRSCP_TEST_DOWNLOADS"] = "/usr/bin/bash"
        app.launchEnvironment["AIRSCP_TEST_SPEED_LIMIT"] = "100000"  // 1.4 MB: about 14 s (XCUITest waits while it moves)
        app.launch()
        XCTAssert(app.staticTexts["lab"].waitForExistence(timeout: 10))
        let oneWindow = app.windows.count
        newWindow(app)

        // The second window logs in, and types in the lab's shell.
        onScreen(app.staticTexts.matching(identifier: "lab"), "No lab in the new window").tap()
        let password = onScreen(app.secureTextFields.matching(identifier: "answer"), "No password question")
        password.tap()  // focused already, unless the sheet is still on its way
        password.typeText("porter-dev\n")
        XCTAssert(app.staticTexts["Connected"].firstMatch.waitForExistence(timeout: 30), "Not connected")
        show("Terminal", in: app)
        let terminal = onScreen(app.descendants(matching: .any).matching(identifier: "terminal"), "No terminal")
        XCTAssert(terminal.shows("dev@"), "No prompt: \(terminal.text)")
        type("echo first-$((6*7))\n", in: app)
        XCTAssert(terminal.shows("first-42"), terminal.text)

        // A second terminal on the lab, shown in this window.
        onScreen(app.buttons.matching(identifier: "New Terminal"), "No New Terminal").tap()
        onScreen(app.buttons.matching(identifier: "lab"), "No lab in New Terminal").tap()
        XCTAssert(onScreen(app.buttons.matching(identifier: "Close Terminal"), "No second terminal").exists)
        let second = onScreen(app.descendants(matching: .any).matching(identifier: "terminal"), "No terminal")
        XCTAssert(second.shows("dev@"), "No prompt: \(second.text)")
        type("echo second-$((7*7))\n", in: app)
        XCTAssert(second.shows("second-49"), second.text)
        show("Transfers", in: app)
        XCTAssert(onScreen(app.descendants(matching: .any).matching(identifier: "transfer bash"), "No transfer").exists)
        keepScreenshot("Second window")

        // Closed: the first window has it all.
        close(app, to: oneWindow)
        XCTAssert(app.staticTexts["Connected"].waitForExistence(timeout: 10), "The connection is gone")
        XCTAssertFalse(app.secureTextFields["answer"].exists, "The password was asked again")
        keepScreenshot("First window")
        app.show("Terminal")
        let first = app.descendants(matching: .any)["terminal"]
        XCTAssert(first.waitForExistence(timeout: 10), "No terminal")
        XCTAssert(first.shows("first-42"), "Not the first terminal: \(first.text)")
        type("echo again-$((8*8))\n", in: app)
        XCTAssert(first.shows("again-64"), "The shell doesn't answer: \(first.text)")
        // The second terminal is there too (a server's last one can't be closed): closing the first shows it.
        let closeTerminal = app.buttons["Close Terminal"]
        XCTAssert(closeTerminal.waitForExistence(timeout: 10), "The second terminal is gone")
        closeTerminal.tap()
        XCTAssert(first.shows("second-49"), "Not the second terminal: \(first.text)")
        keepScreenshot("First window, the second terminal")

        app.show("Transfers")
        let transfer = app.descendants(matching: .any)["transfer bash"]
        XCTAssert(transfer.waitForExistence(timeout: 10), "The transfer is gone")
        let done = expectation(for: NSPredicate(format: "label CONTAINS 'Checksums match'"), evaluatedWith: transfer)
        XCTAssertEqual(XCTWaiter.wait(for: [done], timeout: 120), .completed, transfer.label)
        let copy = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("bash").path)
        XCTAssertEqual(copy?[.size] as? Int, 1_412_096)  // the lab's /usr/bin/bash
    }

    /// An open server's entry in the sidebar opens its workspace in a new window, logged in already, in both
    /// orientations; closed, the first window is still connected.
    @MainActor func testAnOpenServerOpensInANewWindow() {
        let app = launchConnectedToLab(folder)
        let oneWindow = app.windows.count
        let entry = app.cells["workspace"], toggle = app.buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sidebar'")).firstMatch
        // The sidebar comes back as the app last left it: hidden, the tabs at the top show it.
        if !entry.waitForExistence(timeout: 10) && toggle.exists { toggle.tap() }
        XCTAssert(entry.waitForExistence(timeout: 30), "The open server isn't in the sidebar")
        entry.press(forDuration: 1.2)
        let open = app.buttons["Open in New Window"]
        XCTAssert(open.waitForExistence(timeout: 10), "No Open in New Window")
        keepScreenshot("Open in New Window")
        open.tap()
        XCTAssert(wait(30) { app.windows.count > oneWindow }, "No new window")

        let drawer = onScreen(app.buttons.matching(identifier: "drawer"), "No workspace in the new window")
        XCTAssert(onScreen(app.navigationBars.matching(identifier: "lab"), "No server side").exists)
        XCTAssertFalse(app.secureTextFields["answer"].exists, "The password was asked again")
        XCTAssert(wait(30) { drawer.label.contains("lab") }, "No terminal: \(drawer.label)")
        keepScreenshot("New window")
        let turned: UIDeviceOrientation = XCUIDevice.shared.orientation.isLandscape ? .portrait : .landscapeLeft
        let start = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = turned
        XCTAssert(onScreen(app.buttons.matching(identifier: "drawer"), "No workspace after turning").exists)
        keepScreenshot("New window, turned")
        XCUIDevice.shared.orientation = start

        close(app, to: oneWindow)
        app.show("Servers")
        XCTAssert(app.staticTexts["Connected"].waitForExistence(timeout: 10), "The connection is gone")
    }

    // MARK: Helpers

    /// A new window, from the menu of AirSCP's icon in the Dock: it shows in front.
    @MainActor private func newWindow(_ app: XCUIApplication) {
        let windows = app.windows.count
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = springboard.icons["AirSCP"].firstMatch
        XCTAssert(icon.waitForExistence(timeout: 10), "No AirSCP icon")
        icon.press(forDuration: 1.5)
        let item = springboard.buttons["New Window"].firstMatch
        XCTAssert(item.waitForExistence(timeout: 10), "No New Window in the icon's menu")
        item.tap()
        XCTAssert(app.wait(for: .runningForeground, timeout: 10), "AirSCP isn't in front")
        XCTAssert(wait(30) { app.windows.count > windows }, "No new window")
    }

    /// Closes the window in front with ⌘W (again when the Simulator drops the ⌘), and brings the one left to the front.
    @MainActor private func close(_ app: XCUIApplication, to windows: Int) {
        let before = app.windows.count
        for _ in 0..<3 where app.windows.count >= before {
            app.typeKey("w", modifierFlags: .command)
            _ = wait(10) { app.windows.count < before }
        }
        XCTAssertEqual(app.windows.count, windows, "The window didn't close")
        app.activate()  // the Simulator shows the Home Screen once the window in front closes
    }

    /// Shows a place in the window on screen: its tab among the tabs at the top, or its row in the sidebar.
    @MainActor private func show(_ name: String, in app: XCUIApplication) {
        let tab = NSPredicate(format: "(elementType == %d OR elementType == %d) AND label == %@",
                              XCUIElement.ElementType.button.rawValue, XCUIElement.ElementType.cell.rawValue, name)
        onScreen(app.descendants(matching: .any).matching(tab), "No \(name) tab").tap()
    }

    /// The first of these elements on screen: the window behind has the same views, and XCUITest lists them too.
    @MainActor private func onScreen(_ query: XCUIElementQuery, _ message: String) -> XCUIElement {
        var found: XCUIElement?
        XCTAssert(wait(30) {
            found = query.allElementsBoundByIndex.first { $0.exists && $0.isHittable }
            return found != nil
        }, message)
        return found ?? query.firstMatch
    }

    /// Types in the terminal on screen, then hides the keyboard with the key bar's button.
    @MainActor private func type(_ text: String, in app: XCUIApplication) {
        onScreen(app.descendants(matching: .any).matching(identifier: "terminal"), "No terminal").tap()
        let hide = onScreen(app.buttons.matching(identifier: "Hide Keyboard"), "No key bar")
        app.typeText(text)
        hide.tap()
    }

    /// Waits until `condition` holds (`seconds` at most).
    private func wait(_ seconds: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }

    @MainActor private func keepScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
