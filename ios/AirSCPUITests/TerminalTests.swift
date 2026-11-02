import XCTest

/// The Terminal tab (2e) on the Docker lab's target (testenv/README.md: 127.0.0.1:42201, user dev with the lab's
/// throwaway password porter-dev): the shell's prompt, a command typed in the terminal, the key bar's Ctrl-C, the
/// command line and its suggestion from the server's history, and the Stop button. Skipped while the lab isn't running.
final class TerminalTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(labIsReachable(), "The Docker lab's target doesn't answer on 127.0.0.1:42201 (testenv/up.sh starts it)")
        folder = try labFolder()
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testTheShellRunsWhatIsTypedAndCtrlCStopsIt() {
        let app = launchConnectedToLab(folder)
        let terminal = showTerminal(app)
        keepScreenshot("Terminal, keyboard down")
        terminal.tap()
        let ctrl = app.descendants(matching: .any)["ctrl"].firstMatch  // a toggle
        XCTAssert(ctrl.waitForExistence(timeout: 10), "No key bar")
        app.typeText("echo typed-$((6*7))\n")
        XCTAssert(terminal.shows("typed-42"), terminal.text)
        keepScreenshot("Terminal, typing")

        // The key bar's Ctrl, then C: the running command stops, and the next one runs.
        app.typeText("sleep 100\n")
        ctrl.tap()
        app.typeText("c")
        app.typeText("echo after-$((1+1))\n")
        XCTAssert(terminal.shows("after-2"), terminal.text)

        // A hardware keyboard's Control-C, and its up arrow: the command before, again. The Simulator lets the first
        // Control or ⌘ keys after a launch through as plain keys (Settings' search field does it too): then again.
        app.typeText("sleep 100\n")
        app.typeKey("c", modifierFlags: .control)
        for _ in 0..<3 where !terminal.shows("^C", times: 2, within: 5) { app.typeKey("c", modifierFlags: .control) }
        app.typeText("echo keys-$((2+2))\n")
        XCTAssert(terminal.shows("keys-4"), terminal.text)
        app.typeKey(.upArrow, modifierFlags: [])
        app.typeText("\n")
        XCTAssert(terminal.shows("keys-4", times: 2), terminal.text)
    }

    func testTheCommandLineSuggestsFromHistoryAndStopStops() {
        let app = launchConnectedToLab(folder)
        let terminal = showTerminal(app)
        let line = app.textFields["commandLine"]
        line.tap()
        line.typeText("echo from-history-$((2*3))\n")
        XCTAssert(terminal.shows("from-history-6"), terminal.text)

        // What is typed brings the command back from the history; a tap fills it in.
        line.tap()
        line.typeText("echo from")
        let suggestion = app.buttons.matching(identifier: "suggestion").firstMatch
        XCTAssert(suggestion.waitForExistence(timeout: 10), "No suggestion")
        keepScreenshot("Command line")
        suggestion.tap()
        XCTAssertEqual(line.value as? String, "echo from-history-$((2*3))")
        line.typeText("\n")
        XCTAssert(terminal.shows("from-history-6", times: 2), terminal.text)

        // The keyboard is down after a command: Stop stops it.
        line.tap()
        line.typeText("sleep 100\n")
        let stop = app.buttons["Stop"]
        XCTAssert(stop.waitForExistence(timeout: 10), "No Stop button")
        stop.tap()
        line.tap()
        line.typeText("echo stopped-$((3+4))\n")
        XCTAssert(terminal.shows("stopped-7"), terminal.text)
    }

    func testANewTerminalIsAddedAndClosed() {
        let app = launchConnectedToLab(folder)
        _ = showTerminal(app)
        app.buttons["New Terminal"].tap()
        app.buttons["lab"].tap()
        // Two on the lab now: the switcher shows the new one, which can be closed (the last one stays).
        let close = app.buttons["Close Terminal"]
        XCTAssert(close.waitForExistence(timeout: 10), "No second terminal")
        let terminal = app.descendants(matching: .any)["terminal"]
        XCTAssert(terminal.shows("dev@"), terminal.text)
        keepScreenshot("Two terminals")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssert(close.waitForExistence(timeout: 10), "No Close Terminal in landscape")
        keepScreenshot("Two terminals, landscape")
        XCUIDevice.shared.orientation = .portrait
        close.tap()
        XCTAssert(close.waitForNonExistence(timeout: 10), "The last terminal can be closed")
    }

    /// Keeps a screenshot in the test's results, to look at the terminal in light and dark.
    private func keepScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

/// The lab's target as a saved server, "lab": a new host key trusted at once, the password asked for.
let labHost = UUID()

extension XCTestCase {
    /// A settings folder of the test's own (AIRSCP_SUPPORT_DIR), with the lab saved in its airscp.json.
    func labFolder(snippets: String = "") throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("airscp-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        {"hosts":[{"id":"\(labHost)","label":"lab","hostname":"127.0.0.1","port":42201,"username":"dev","auth":"password",
                   "hostKeyCheck":"acceptNew"}],
         "snippets":[\(snippets)]}
        """.write(to: folder.appendingPathComponent("airscp.json"), atomically: true, encoding: .utf8)
        return folder
    }

    /// AirSCP with `folder`'s settings, logged in to the lab from Servers.
    func launchConnectedToLab(_ folder: URL) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AIRSCP_SUPPORT_DIR"] = folder.path
        app.launch()
        let lab = app.staticTexts["lab"]
        XCTAssert(lab.waitForExistence(timeout: 10))
        lab.tap()
        let password = app.secureTextFields["answer"]
        XCTAssert(password.waitForExistence(timeout: 30), "No password question")
        password.tap()  // focused already, unless the sheet is still on its way (a busy Mac)
        password.typeText("porter-dev\n")
        XCTAssert(app.staticTexts["Connected"].waitForExistence(timeout: 30), "Not connected")
        return app
    }

    /// The Terminal tab, once its shell waits at its prompt.
    func showTerminal(_ app: XCUIApplication) -> XCUIElement {
        app.show("Terminal")
        let terminal = app.descendants(matching: .any)["terminal"]
        XCTAssert(terminal.waitForExistence(timeout: 10), "No terminal")
        XCTAssert(terminal.shows("dev@"), "No prompt: \(terminal.text)")
        return terminal
    }

    /// Whether the lab's target accepts a TCP connection (at once on this Mac: refused or not).
    func labIsReachable() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(42201).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }
}

extension XCUIApplication {
    /// Shows a place by its tab: in the iPhone's tab bar, among an iPad's tabs at the top, or in the sidebar an iPad shows
    /// on its side. Tapped again until it is selected (an iPad's tabs at the top can move under a tap), or gone (the
    /// iPhone's Search turns into the search field); through the sidebar when the tabs at the top have paged it out.
    func show(_ name: String) {
        for _ in 0..<3 {
            if !tabBars.firstMatch.exists && !tab(name).waitForExistence(timeout: 2) {
                buttons.matching(NSPredicate(format: "label CONTAINS[c] 'sidebar'")).firstMatch.tap()
            }
            let tab = tab(name)
            XCTAssert(tab.waitForExistence(timeout: 10), "No \(name) tab")
            if !tab.isSelected { tab.tap() }
            let shown = NSPredicate(format: "exists == false OR isSelected == true")
            if XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: shown, object: tab)], timeout: 5) == .completed { return }
        }
        XCTFail("The \(name) tab doesn't show")
    }

    /// A navigation bar's button, from the bar's More menu when the bar has no room for it (an iPad's tabs at the top take
    /// the middle of the bar).
    func barButton(_ name: String) -> XCUIElement {
        let button = buttons[name].firstMatch, more = buttons["OverflowBarButtonItem"]
        if !button.exists && more.exists { more.tap() }
        return button
    }

    /// A tab's button in the tab bar, in the rail at the side of an iPhone Duo's outer screen (outside the tab bar it also
    /// has), or among an iPad's tabs at the top, or its row in an iPad's sidebar.
    private func tab(_ name: String) -> XCUIElement {
        if tabBars.buttons[name].exists { return tabBars.buttons[name] }
        let row = cells.matching(NSPredicate(format: "label == %@", name)).firstMatch
        return row.exists ? row : buttons[name].firstMatch
    }
}

extension XCUIElement {
    /// The terminal's text (its accessibility value: the scrollback and the screen).
    var text: String { value as? String ?? "" }

    /// Waits until the terminal's text holds `needle` `times` times (`seconds` at most).
    func shows(_ needle: String, times: Int = 1, within seconds: TimeInterval = 30) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            if text.components(separatedBy: needle).count - 1 >= times { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < deadline
        return false
    }
}
