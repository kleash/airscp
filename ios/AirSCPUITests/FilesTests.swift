import AirSCPCore
import XCTest

/// The Files tab (Phase 2c) and the editor (2f) against the Docker lab's target. Each test works in a folder of its own
/// in dev's home (`LabServer`, removed afterwards) and gives the app a settings folder of its own (AIRSCP_SUPPORT_DIR),
/// whose Documents folder is the app's "On iPhone" side. Skipped while the lab isn't running (testenv/up.sh).
final class FilesTests: XCTestCase {
    private var folder: URL!
    private var lab: LabServer!

    override func setUp() async throws {
        continueAfterFailure = false
        try XCTSkipUnless(LabServer.isUp(), "The Docker lab's target doesn't answer on 127.0.0.1:42201 (testenv/up.sh starts it)")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("airscp-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        lab = try await LabServer(knownHosts: folder.appendingPathComponent("known_hosts").path)
    }

    override func tearDown() async throws {
        await lab?.remove()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    @MainActor func testBrowseMakeRenameAndDelete() async throws {
        try await lab.session.makeDirectory(lab.path("docs"))
        try await lab.write("deep\n", to: "docs/inner.txt")
        try await lab.write("hello\n", to: "notes.txt")
        let app = openTestFolder()
        XCTAssert(app.staticTexts["notes.txt"].waitForExistence(timeout: 10))
        keepScreenshot("Folder")

        // Into a folder, and back up by the path.
        app.staticTexts["docs"].tap()
        XCTAssert(app.staticTexts["inner.txt"].waitForExistence(timeout: 10))
        app.scrollViews["path"].buttons[RemotePath.name(lab.folder)].tap()
        XCTAssert(app.staticTexts["notes.txt"].waitForExistence(timeout: 10))

        // New Folder.
        app.buttons["New Folder"].tap()
        let name = app.alerts.textFields.firstMatch
        XCTAssert(name.waitForExistence(timeout: 5))
        XCTAssertEqual(name.value as? String, "untitled folder")
        name.clearAndType("made")
        app.alerts.buttons["Create"].tap()
        XCTAssert(app.staticTexts["made"].waitForExistence(timeout: 10))
        let made = try await lab.names()
        XCTAssertEqual(made, ["docs", "made", "notes.txt"])

        // Rename, from the row's swipe actions.
        row("made", in: app).swipeLeft()
        app.buttons["Rename"].tap()
        XCTAssert(name.waitForExistence(timeout: 5))
        name.clearAndType("renamed")
        app.alerts.buttons["Rename"].tap()
        XCTAssert(app.staticTexts["renamed"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["made"].exists)
        let renamed = try await lab.names()
        XCTAssertEqual(renamed, ["docs", "notes.txt", "renamed"])

        // Delete asks first.
        row("renamed", in: app).swipeLeft()
        app.buttons["Delete"].tap()
        let ask = app.alerts.firstMatch
        XCTAssert(ask.waitForExistence(timeout: 5))
        XCTAssert(ask.label.hasPrefix("Delete “renamed” on"), ask.label)
        keepScreenshot("Delete")
        ask.buttons["Delete"].tap()
        XCTAssert(app.staticTexts["renamed"].waitForNonExistence(timeout: 10))
        let left = try await lab.names()
        XCTAssertEqual(left, ["docs", "notes.txt"])
    }

    @MainActor func testEditSaveAndTheQuestionWhenTheServerChangedMeanwhile() async throws {
        try await lab.write("port=80\n", to: "app.conf")
        let app = openTestFolder()
        let file = app.staticTexts["app.conf"]
        XCTAssert(file.waitForExistence(timeout: 10))
        file.tap()

        let text = app.textViews["editor.text"]
        XCTAssert(text.waitForExistence(timeout: 10))
        XCTAssertEqual(text.value as? String, "port=80\n")
        text.typeWithFocus("# edited\n")
        keepScreenshot("Editor")
        app.buttons["Save"].tap()
        XCTAssert(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Saved at'")).firstMatch.waitForExistence(timeout: 15))
        var saved = try await lab.read("app.conf")
        XCTAssert(saved.contains("# edited"), saved)

        // The lines changed since the file was opened.
        app.buttons["Changes"].tap()
        XCTAssert(app.staticTexts.matching(NSPredicate(format: "label CONTAINS '+ # edited'")).firstMatch.waitForExistence(timeout: 5))
        keepScreenshot("Changes")
        app.buttons["Info"].tap()
        XCTAssert(app.staticTexts["Path, " + lab.path("app.conf")].waitForExistence(timeout: 5))
        app.buttons["Edit"].tap()

        // Someone saves the file on the server meanwhile: Save asks, and Overwrite replaces their change.
        try await lab.write("port=81\n", to: "app.conf")
        XCTAssert(text.waitForExistence(timeout: 5))
        text.typeWithFocus("# mine\n")
        app.buttons["Save"].tap()
        let question = app.alerts["“app.conf” was changed on the server after you opened it"]
        XCTAssert(question.waitForExistence(timeout: 15))
        keepScreenshot("Changed on the server")
        XCTAssert(question.buttons["Show Server Version"].exists)
        question.buttons["Cancel"].tap()
        saved = try await lab.read("app.conf")
        XCTAssertEqual(saved, "port=81\n")
        app.buttons["Save"].tap()
        XCTAssert(question.waitForExistence(timeout: 15))
        question.buttons["Overwrite"].tap()
        XCTAssert(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Saved at'")).firstMatch.waitForExistence(timeout: 15))
        saved = try await lab.read("app.conf")
        XCTAssert(saved.contains("# mine") && !saved.contains("port=81"), saved)

        // Closing with nothing unsaved doesn't ask.
        app.buttons["Close"].tap()
        XCTAssert(text.waitForNonExistence(timeout: 5))
    }

    // MARK: Helpers

    /// Launches the app, logs into the lab's target (its host key is trusted already: `LabServer` wrote known_hosts),
    /// and opens the test's folder in the Files tab.
    @MainActor private func openTestFolder() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AIRSCP_SUPPORT_DIR"] = folder.path
        app.launch()
        let field = app.textFields["quickConnect"]
        XCTAssert(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("dev@127.0.0.1:42201\n")
        let password = app.secureTextFields["answer"]
        XCTAssert(password.waitForExistence(timeout: 30), "No password question")
        app.typeText("porter-dev\n")
        XCTAssert(app.staticTexts["Connected"].waitForExistence(timeout: 30))
        app.tabBars.buttons["Files"].tap()
        let mine = app.staticTexts[RemotePath.name(lab.folder)]
        XCTAssert(mine.waitForExistence(timeout: 30), "The test's folder isn't listed in the home folder")
        mine.tap()
        XCTAssert(app.scrollViews["path"].staticTexts[RemotePath.name(lab.folder)].waitForExistence(timeout: 10))
        return app
    }

    /// A row of the list, by its name: swiped as a whole (a swipe as short as a short name is a tap).
    @MainActor private func row(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.cells.containing(.staticText, identifier: name).firstMatch
    }

    /// Keeps a screenshot in the test's results, to look at the screens in light and dark.
    @MainActor private func keepScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

extension XCUIElement {
    /// Types once the element has the keyboard: tapped again while it hasn't (a sheet may still be moving in). Tapped
    /// below the middle: a tap on the exact middle of a sheet doesn't reach it; in a text view below its text, the caret
    /// goes to the end.
    func typeWithFocus(_ text: String) {
        for _ in 0..<3 {
            coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.7)).tap()
            let focused = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hasKeyboardFocus == true"), object: self)
            if XCTWaiter.wait(for: [focused], timeout: 3) == .completed { break }
        }
        typeText(text)
    }

    /// Replaces a text field's text.
    func clearAndType(_ text: String) {
        tap()
        if let value = value as? String, !value.isEmpty {
            typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: value.count))
        }
        typeText(text)
    }
}
