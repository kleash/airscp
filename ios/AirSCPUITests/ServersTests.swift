import XCTest

/// Servers (Phase 2b): adding, editing and deleting a saved server, the editor's checks, and a quick connect that
/// fails. Each test gives the app a settings folder of its own (AIRSCP_SUPPORT_DIR), so passwords stay in memory.
final class ServersTests: XCTestCase {
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

    /// The hosts in the app's airscp.json.
    private func savedHosts() throws -> [[String: Any]] {
        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent("airscp.json")))
        return (file as? [String: Any])?["hosts"] as? [[String: Any]] ?? []
    }

    /// Tapped again until it has the keyboard: on an iPad, the first tap after the port only closes its number pad (a
    /// popover over the whole window).
    private func type(_ text: String, into field: XCUIElement) {
        field.typeWithFocus(text)
    }

    func testAServerIsAddedEditedAndDeleted() throws {
        let app = launch()
        app.buttons["Add Server"].firstMatch.tap()
        XCTAssert(app.textFields["Address"].waitForExistence(timeout: 5))
        type("web-01.example.com", into: app.textFields["Address"])
        type("2222", into: app.textFields["Port"])
        let save = app.navigationBars.buttons["Save"]
        XCTAssertFalse(save.isEnabled)  // no user yet
        type("deploy", into: app.textFields["User"])
        save.tap()

        let row = app.staticTexts["deploy@web-01.example.com:2222"]
        XCTAssert(row.waitForExistence(timeout: 5))
        let added = try XCTUnwrap(savedHosts().first)
        XCTAssertEqual(added["hostname"] as? String, "web-01.example.com")
        XCTAssertEqual(added["port"] as? Int, 2222)
        XCTAssertEqual(added["username"] as? String, "deploy")
        XCTAssertEqual(added["auth"] as? String, "password")

        row.swipeLeft()
        app.buttons["Edit"].tap()
        XCTAssert(app.navigationBars["Edit Server"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["Address"].value as? String, "web-01.example.com")
        type("web-01", into: app.textFields["Name"])
        app.navigationBars.buttons["Save"].tap()
        XCTAssert(app.staticTexts["web-01"].waitForExistence(timeout: 5))
        XCTAssertFalse(row.exists)
        XCTAssertEqual(try savedHosts().map { $0["label"] as? String }, ["web-01"])

        app.staticTexts["web-01"].swipeLeft()
        app.buttons["Edit"].tap()
        app.buttons["Delete Server"].tap()
        app.buttons["Delete"].tap()  // the confirmation
        XCTAssert(app.staticTexts["No servers yet"].waitForExistence(timeout: 5))
        XCTAssertEqual(try savedHosts().count, 0)
    }

    func testSaveStaysOffWithoutAnAddress() {
        let app = launch()
        app.buttons["Add Server"].firstMatch.tap()
        let save = app.navigationBars.buttons["Save"]
        XCTAssert(save.waitForExistence(timeout: 5))
        XCTAssertFalse(save.isEnabled)
        type("web-01", into: app.textFields["Name"])
        type("deploy", into: app.textFields["User"])
        XCTAssertFalse(save.isEnabled)
        XCTAssert(app.staticTexts["Type the server's address"].exists)
        type("web 01", into: app.textFields["Address"])
        XCTAssertFalse(save.isEnabled)
        XCTAssert(app.staticTexts["Take the spaces out of the address"].exists)

        app.navigationBars.buttons["Cancel"].tap()
        XCTAssert(app.staticTexts["No servers yet"].waitForExistence(timeout: 5))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("airscp.json").path))
    }

    func testAQuickConnectThatFailsSaysWhyAndCanBeSaved() throws {
        let app = launch()
        let field = app.textFields["quickConnect"]
        XCTAssert(field.waitForExistence(timeout: 10))
        type("admin@127.0.0.1:1\n", into: field)  // nothing listens on port 1: refused at once
        let alert = app.alerts["Can't connect"]
        XCTAssert(alert.waitForExistence(timeout: 15))
        alert.buttons["OK"].tap()
        let row = app.staticTexts["admin@127.0.0.1:1"]
        XCTAssert(row.waitForExistence(timeout: 5))
        // A failed connect leaves the session idle ("Not connected"); one that drops says why ("Disconnected: …").
        let disconnected = app.staticTexts.matching(NSPredicate(format: "label == 'Not connected' OR label BEGINSWITH 'Disconnected: '"))
            .firstMatch
        XCTAssert(disconnected.exists)

        row.swipeLeft()
        app.buttons["Save"].tap()
        XCTAssert(app.navigationBars["New Server"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["Address"].value as? String, "127.0.0.1")
        XCTAssertEqual(app.textFields["Port"].value as? String, "1")
        XCTAssertEqual(app.textFields["User"].value as? String, "admin")
        app.navigationBars.buttons["Save"].tap()
        XCTAssert(app.navigationBars["Servers"].waitForExistence(timeout: 5))
        XCTAssertEqual(try savedHosts().map { $0["hostname"] as? String }, ["127.0.0.1"])

        // Saved now, it offers no Save; disconnected, it moves down to the saved servers.
        row.swipeLeft()
        XCTAssertFalse(app.buttons["Save"].exists)
        app.buttons["Disconnect"].tap()
        XCTAssert(app.staticTexts["Saved"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Open"].exists)
        XCTAssert(row.exists)
        XCTAssertFalse(disconnected.exists)
    }
}
