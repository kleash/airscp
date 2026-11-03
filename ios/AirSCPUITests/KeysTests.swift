import XCTest

/// Settings ▸ Keys (Phase 2b): a key made in the app is listed with its type and fingerprint, Copy Public Key puts its
/// line on the pasteboard, a swipe deletes it. Each test gives the app a settings folder of its own
/// (AIRSCP_SUPPORT_DIR), which also keeps its keys in memory, never in the Keychain. Import from Files isn't tested
/// here: the document picker needs key files in the Files app, which a test can't put there.
final class KeysTests: XCTestCase {
    private var folder: URL!
    private let none = "No keys yet. A key lets you log in without typing a password."

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("airscp-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    /// The app in Settings, with a key named "demo key" made there.
    private func launchWithKey() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AIRSCP_SUPPORT_DIR"] = folder.path
        app.launch()
        app.buttons["Settings"].firstMatch.tap()
        XCTAssert(app.staticTexts[none].waitForExistence(timeout: 10))
        makeKey(app, named: "demo key")
        XCTAssert(app.staticTexts["demo key"].waitForExistence(timeout: 5))
        return app
    }

    private func makeKey(_ app: XCUIApplication, named name: String) {
        app.buttons["Make a New Key"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssert(field.waitForExistence(timeout: 5))
        XCTAssert(app.alerts.buttons["Make"].exists)
        field.typeText(name + "\n")  // Return: Make (see clearAndType)
    }

    func testAKeyIsMadeAndListedWithItsFingerprint() {
        let app = launchWithKey()
        XCTAssert(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'ssh-ed25519  SHA256:'")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts[none].exists)

        makeKey(app, named: "demo key")  // a name that is taken
        XCTAssert(app.alerts["Can't add the key"].waitForExistence(timeout: 5))
        app.alerts.buttons["OK"].tap()
    }

    func testCopyPublicKeyPutsItsLineOnThePasteboard() {
        let app = launchWithKey()
        app.buttons["Public key of demo key"].tap()
        app.buttons["Copy Public Key"].tap()
        // Pasted into the app's own field: the test reading UIPasteboard itself waits on iOS's Allow Paste question.
        app.buttons["Make a New Key"].tap()
        let field = app.alerts.textFields.firstMatch
        XCTAssert(field.waitForExistence(timeout: 5))
        field.press(forDuration: 1)
        let paste = app.menuItems["Paste"]
        XCTAssert(paste.waitForExistence(timeout: 5))
        // Tapped where it is on screen: tapping the item makes XCUITest dismiss the alert, which it takes for an
        // interruption (the menu isn't inside it).
        let spot = paste.frame
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: spot.midX, dy: spot.midY)).tap()
        let pasted = NSPredicate(format: "value BEGINSWITH 'ssh-ed25519 ' AND value ENDSWITH ' demo key'")
        wait(for: [expectation(for: pasted, evaluatedWith: field)], timeout: 5)
    }

    func testAKeyIsDeletedBySwiping() {
        let app = launchWithKey()
        app.staticTexts["demo key"].swipeLeft()
        app.buttons["Delete"].tap()
        app.alerts.buttons["Delete"].tap()
        XCTAssert(app.staticTexts[none].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["demo key"].exists)
    }
}
