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
        app.tab("Search").tap()
        retype(field, "history-")
        XCTAssert(app.staticTexts["echo history-$((7*6))"].waitForExistence(timeout: 5), "The command isn't found")
        runOnLab(app)
        XCTAssert(terminal.shows("history-42"), terminal.text)

        // Files on the open server, by name.
        app.tab("Search").tap()
        retype(field, "bashrc")
        app.buttons["Find “bashrc” in lab"].tap()
        XCTAssert(app.buttons["/home/dev/.bashrc"].waitForExistence(timeout: 60), "The file isn't found")  // it opens in Files
    }

    private func search(_ app: XCUIApplication, for text: String) -> XCUIElement {
        app.tab("Search").tap()
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
