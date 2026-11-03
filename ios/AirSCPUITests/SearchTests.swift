import XCTest

/// Search (2f): one field over the saved servers, the snippets, every saved server's command history and the files on
/// an open server; Run on types a snippet or a command in that server's terminal. On the Docker lab's target, as
/// TerminalTests. Skipped while the lab isn't running.
final class SearchTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(labIsReachable(), "The Docker lab's target doesn't answer on 127.0.0.1:42201 (testenv/up.sh starts it)")
        folder = try labFolder(snippets: #"{"id":"\#(UUID())","name":"Quarter","command":"echo snippet-$((5*5))","runInTerminal":false}"#)
        // A command run on the lab before, in its history as the Terminal tab keeps it.
        let history = folder.appendingPathComponent("history")
        try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
        try #"["echo history-$((7*6))"]"#.write(to: history.appendingPathComponent(labHost.uuidString + ".json"),
                                                atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testServersSnippetsHistoryAndFilesAreFoundAndRunOnAServer() {
        let app = launchConnectedToLab(folder)
        let field = search(app, for: "lab")
        XCTAssert(app.staticTexts["127.0.0.1"].waitForExistence(timeout: 5), "The server isn't found")

        // A snippet, by its name: Run on types it in the lab's terminal.
        retype(field, "Quarter")
        XCTAssert(app.staticTexts["echo snippet-$((5*5))"].waitForExistence(timeout: 5), "The snippet isn't found")
        keepScreenshot("Search")
        runOnLab(app)
        let terminal = app.descendants(matching: .any)["terminal"]
        XCTAssert(terminal.waitForExistence(timeout: 10), "No terminal")
        XCTAssert(terminal.shows("snippet-25"), terminal.text)

        // A command from the lab's history.
        app.show("Search")
        retype(field, "history-")
        XCTAssert(app.staticTexts["echo history-$((7*6))"].waitForExistence(timeout: 5), "The command isn't found")
        runOnLab(app)
        XCTAssert(terminal.shows("history-42"), terminal.text)

        // Files on the open server, by name.
        app.show("Search")
        retype(field, "bashrc")
        app.buttons["Find “bashrc” in lab"].tap()
        XCTAssert(app.buttons["/home/dev/.bashrc"].waitForExistence(timeout: 60), "The file isn't found")  // it opens in Files
    }

    /// Run on ▸ Several Servers…: a snippet run at once on the servers picked (the lab twice, as two saved servers), each
    /// one's exit status and output, error output too, shown together; Stop stops a command on both.
    func testASnippetRunsOnSeveralServers() throws {
        try """
        {"hosts":[{"id":"\(labHost)","label":"lab","hostname":"127.0.0.1","port":42201,"username":"dev","auth":"password",
                   "hostKeyCheck":"acceptNew"},
                  {"id":"\(UUID())","label":"lab 2","hostname":"127.0.0.1","port":42201,"username":"dev","auth":"password",
                   "hostKeyCheck":"acceptNew"}],
         "snippets":[{"id":"\(UUID())","name":"Status","command":"echo ran-$((5*5)); echo warned >&2; exit 3","runInTerminal":false},
                     {"id":"\(UUID())","name":"Long","command":"sleep 100","runInTerminal":false}]}
        """.write(to: folder.appendingPathComponent("airscp.json"), atomically: true, encoding: .utf8)
        let app = launchConnectedToLab(folder)
        app.staticTexts["lab 2"].tap()
        let password = app.secureTextFields["answer"]
        XCTAssert(password.waitForExistence(timeout: 30), "No password question")
        password.tap()
        password.typeText("porter-dev\n")
        let both = expectation(for: NSPredicate(format: "count == 2"), evaluatedWith: app.staticTexts.matching(identifier: "Connected"))
        XCTAssertEqual(XCTWaiter.wait(for: [both], timeout: 30), .completed, "Not both connected")

        // Files shows the newest open server; the menu over its folders switches to the other.
        app.show("Files")
        let server = app.buttons["server"].firstMatch
        XCTAssert(server.waitForExistence(timeout: 10), "No server menu with two servers open")
        XCTAssert(server.label.contains("lab 2"), server.label)
        server.tap()
        app.buttons["lab"].firstMatch.tap()
        let switched = expectation(for: NSPredicate(format: "label CONTAINS 'lab' AND NOT label CONTAINS 'lab 2'"), evaluatedWith: server)
        XCTAssertEqual(XCTWaiter.wait(for: [switched], timeout: 10), .completed, server.label)
        keepScreenshot("Files switched to the other server")

        let field = search(app, for: "Status")
        XCTAssert(app.staticTexts["echo ran-$((5*5)); echo warned >&2; exit 3"].waitForExistence(timeout: 10), "The snippet isn't found")
        runOnSeveral(app)
        let run = app.buttons["Run"]
        XCTAssert(run.waitForExistence(timeout: 10), "No Run on Several Servers")
        XCTAssertFalse(run.isEnabled, "Run works before a server is picked")
        app.buttons["server lab"].tap()
        app.buttons["server lab 2"].tap()
        run.tap()
        for name in ["lab", "lab 2"] {
            let row = app.buttons["server " + name]
            XCTAssert(waitUntil(row, says: "Exit status 3", timeout: 30), row.label)
            let output = app.staticTexts["output " + name]
            XCTAssert(output.waitForExistence(timeout: 10), "No output of \(name)")
            XCTAssert(output.label.contains("ran-25") && output.label.contains("warned"), output.label)
        }
        keepScreenshot("Run on several servers")
        XCUIDevice.shared.orientation = XCUIDevice.shared.orientation.isLandscape ? .portrait : .landscapeLeft
        XCTAssert(app.staticTexts["output lab 2"].waitForExistence(timeout: 10), "The output is gone after turning")
        keepScreenshot("Run on several servers, turned")

        // A command that goes on: Stop stops it on both.
        // Back to Search: turned, iOS 27 shows the bar's buttons in a column at the side, outside the navigation bar.
        let back = app.navigationBars["Run on Several Servers"].buttons.element(boundBy: 0)
        (back.exists ? back : app.buttons["BackButton"]).tap()
        retype(field, "Long")
        XCTAssert(app.staticTexts["sleep 100"].waitForExistence(timeout: 10), "The snippet isn't found")
        runOnSeveral(app)
        app.buttons["server lab"].tap()
        app.buttons["server lab 2"].tap()
        run.tap()
        let stop = app.buttons["Stop"]
        XCTAssert(stop.waitForExistence(timeout: 10), "No Stop")
        stop.tap()
        for name in ["lab", "lab 2"] {
            let row = app.buttons["server " + name]
            XCTAssert(waitUntil(row, says: "Stopped.", timeout: 30), row.label)
        }
    }

    private func search(_ app: XCUIApplication, for text: String) -> XCUIElement {
        app.show("Search")
        let field = app.searchFields.firstMatch
        XCTAssert(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText(text)
        return field
    }

    private func retype(_ field: XCUIElement, _ text: String) {
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count) + text)
    }

    /// Waits until the element's label says `text`.
    private func waitUntil(_ element: XCUIElement, says text: String, timeout: TimeInterval) -> Bool {
        let found = expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: element)
        return XCTWaiter.wait(for: [found], timeout: timeout) == .completed
    }

    /// Run on ▸ Several Servers…, in the one result that has it.
    private func runOnSeveral(_ app: XCUIApplication) {
        app.buttons["Run on"].firstMatch.tap()
        let several = app.buttons["Several Servers…"]
        XCTAssert(several.waitForExistence(timeout: 5), "No Several Servers… in Run on")
        several.tap()
    }

    /// Run on ▸ lab, in the one result that has it.
    private func runOnLab(_ app: XCUIApplication) {
        app.buttons["Run on"].firstMatch.tap()
        let lab = app.buttons["lab"].firstMatch
        XCTAssert(lab.waitForExistence(timeout: 5), "No lab in Run on")
        lab.tap()
    }

    private func keepScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
