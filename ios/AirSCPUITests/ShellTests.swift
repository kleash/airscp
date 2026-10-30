import XCTest

/// The app shell (Phase 2a): the tabs, their empty states, Settings' trusted servers. Each test gives the app a
/// settings folder of its own (AIRSCP_SUPPORT_DIR, as the Mac tests do), with neutral demo data.
final class ShellTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("airscp-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AIRSCP_SUPPORT_DIR"] = folder.path
        app.launch()
        return app
    }

    func testEmptyTabsSayWhatToDoNext() {
        let app = launch()
        XCTAssert(app.staticTexts["No servers yet"].waitForExistence(timeout: 10))
        app.tabBars.buttons["Files"].tap()
        XCTAssert(app.staticTexts["No server open"].waitForExistence(timeout: 5))
        app.buttons["Go to Servers"].tap()
        XCTAssert(app.staticTexts["No servers yet"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Terminal"].tap()
        XCTAssert(app.staticTexts["No terminal open"].waitForExistence(timeout: 5))
        app.tabBars.buttons["Transfers"].tap()
        XCTAssert(app.staticTexts["No transfers"].waitForExistence(timeout: 5))
    }

    func testSavedServersAreListedAndFound() throws {
        try """
        {"hosts":[{"id":"\(UUID())","label":"web-01","hostname":"web-01.example.com","username":"deploy"},
                  {"id":"\(UUID())","hostname":"db.example.com","username":"admin"}]}
        """.write(to: folder.appendingPathComponent("airscp.json"), atomically: true, encoding: .utf8)
        let app = launch()
        XCTAssert(app.staticTexts["web-01"].waitForExistence(timeout: 10))
        XCTAssert(app.staticTexts["admin@db.example.com"].exists)

        app.tabBars.buttons["Search"].tap()
        let field = app.searchFields.firstMatch
        XCTAssert(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("db.")
        XCTAssert(app.staticTexts["admin@db.example.com"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["web-01"].exists)
    }

    func testATrustedServerIsShownAndForgotten() throws {
        // A made-up ed25519 key: its fingerprint is SHA-256 of the decoded key, as ssh-keygen -l shows it.
        let key = "AAAAC3NzaC1lZDI1NTE5AAAAIEw1Ql0V1J5Qm3nJXnqH9V9l2kqYQf1kYVbq1o2bq0Yd"
        try "web-01.example.com ssh-ed25519 \(key)\n"
            .write(to: folder.appendingPathComponent("known_hosts"), atomically: true, encoding: .utf8)
        let app = launch()
        app.buttons["Settings"].firstMatch.tap()
        let row = app.staticTexts["web-01.example.com"]
        XCTAssert(row.waitForExistence(timeout: 5))
        XCTAssert(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'ssh-ed25519  SHA256:'")).firstMatch.exists)

        row.swipeLeft()
        app.buttons["Delete"].tap()
        XCTAssert(app.staticTexts["None yet"].waitForExistence(timeout: 5))
        let left = try String(contentsOf: folder.appendingPathComponent("known_hosts"), encoding: .utf8)
        XCTAssertEqual(left.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }
}
