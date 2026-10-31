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
        pathBar(app).buttons[RemotePath.name(lab.folder)].tap()
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

        // Select mode's bar: Zip packs the selection next to it, on the server.
        app.buttons["More"].tap()
        app.buttons["Select"].tap()
        app.staticTexts["notes.txt"].tap()
        keepScreenshot("Selecting")
        app.buttons["Zip"].tap()
        XCTAssert(app.staticTexts["notes.txt.zip"].waitForExistence(timeout: 15))

        // Add to Tray: the tray's button shows, with what it holds.
        app.buttons["More"].tap()
        app.buttons["Select"].tap()
        app.staticTexts["notes.txt.zip"].tap()
        app.buttons["Add to Tray"].tap()
        let tray = app.buttons["Tray"]
        XCTAssert(tray.waitForExistence(timeout: 5))
        XCTAssertEqual(tray.value as? String, "1 item")
    }

    /// Send goes through the server's transfer queue both ways; what arrives has the same bytes.
    @MainActor func testSendFromThisDeviceToTheServerAndBack() async throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "The sides' switcher is the iPhone's")
        let bytes = Data((0..<300_000).map { _ in UInt8.random(in: 0...255) })
        let documents = folder.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let local = documents.appendingPathComponent("photo.bin")
        try bytes.write(to: local)
        let app = openTestFolder()
        XCTAssert(app.staticTexts["Empty folder"].waitForExistence(timeout: 10))
        keepScreenshot("Empty folder")

        // From the other side, this device's files, to the server.
        app.segmentedControls.buttons["On iPhone"].tap()
        XCTAssert(app.staticTexts["photo.bin"].waitForExistence(timeout: 10))
        keepScreenshot("On iPhone")
        row("photo.bin", in: app).swipeLeft()
        app.buttons["Send"].tap()
        app.segmentedControls.buttons["lab"].tap()
        XCTAssert(app.staticTexts["photo.bin"].waitForExistence(timeout: 30))
        let uploaded = try await lab.data("photo.bin")
        XCTAssertEqual(uploaded, bytes)

        // And back, once this device's copy is gone.
        try FileManager.default.removeItem(at: local)
        row("photo.bin", in: app).swipeLeft()
        app.buttons["Send"].tap()
        await arrival(of: local, bytes)

        // Sent again: it is there already, so the app asks; Keep Both gives the new one a number.
        row("photo.bin", in: app).swipeLeft()
        app.buttons["Send"].tap()
        let question = app.alerts["“photo.bin” already exists in “On iPhone”."]
        XCTAssert(question.waitForExistence(timeout: 15))
        keepScreenshot("Already there")
        question.buttons["Keep Both"].tap()
        await arrival(of: documents.appendingPathComponent("photo 2.bin"), bytes)

        // Share downloads a server file first, then shows the share sheet.
        app.staticTexts["photo.bin"].press(forDuration: 1)
        app.buttons["Share"].tap()
        XCTAssert(app.otherElements["ActivityListView"].waitForExistence(timeout: 30), "No share sheet")
        keepScreenshot("Share")
    }

    /// Save to Files puts a server file in the Files app (through a queued download); Import from Files uploads it into
    /// the folder showing. The file stays in the simulator's On My iPhone ▸ AirSCP (a name of its own each run).
    @MainActor func testSaveToFilesThenImportFromFiles() async throws {
        let name = "export-\(UUID().uuidString.prefix(8)).txt", text = "saved through the Files app \(UUID())\n"
        try await lab.write(text, to: name)
        let app = openTestFolder()
        XCTAssert(app.staticTexts[name].waitForExistence(timeout: 10))
        app.staticTexts[name].press(forDuration: 1)
        app.buttons["Save to Files"].tap()
        let save = app.navigationBars.buttons["Save"]
        XCTAssert(save.waitForExistence(timeout: 30), "No document picker")
        keepScreenshot("Save to Files")
        save.tap()
        XCTAssert(save.waitForNonExistence(timeout: 15))

        // Deleted here, then imported back from the Files app (On My iPhone ▸ AirSCP, where it was saved).
        row(name, in: app).swipeLeft()
        app.buttons["Delete"].tap()
        app.alerts.buttons["Delete"].tap()
        XCTAssert(app.staticTexts[name].waitForNonExistence(timeout: 10))
        app.buttons["More"].tap()
        app.buttons["Import from Files"].tap()
        let file = app.cells.containing(NSPredicate(format: "label CONTAINS %@", String(name.dropLast(4)))).firstMatch
        let browse = app.buttons["Browse"]
        XCTAssert(browse.waitForExistence(timeout: 15), "No document picker")
        browse.tap()  // it opens where it was last, else at its locations
        if !file.waitForExistence(timeout: 10) {
            for place in ["On My iPhone", "AirSCP"] {
                let cell = app.cells.containing(.staticText, identifier: place).firstMatch
                XCTAssert(cell.waitForExistence(timeout: 10), "No \(place) in the document picker")
                cell.tap()
                XCTAssert(app.navigationBars.staticTexts[place].waitForExistence(timeout: 10)
                          || app.navigationBars.buttons.containing(NSPredicate(format: "label BEGINSWITH %@", place)).firstMatch.exists)
            }
        }
        XCTAssert(file.waitForExistence(timeout: 30), "The saved file isn't in the document picker")
        keepScreenshot("Import from Files")
        file.tap()  // several can be picked: it's selected, and Open takes the selection
        let open = app.navigationBars.buttons["Open"]
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND isEnabled == true"), object: open)
        await fulfillment(of: [enabled], timeout: 10)
        for _ in 0..<3 where open.exists {  // a tap on Open sometimes doesn't take: again while the picker is up
            // On the screen, not on the element: the picker's own button is in another process's view.
            app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: open.frame.midX, dy: open.frame.midY)).tap()
            _ = open.waitForNonExistence(timeout: 5)
        }
        let arrived = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true"), object: app.staticTexts[name])
        await fulfillment(of: [arrived], timeout: 30)
        let imported = try await lab.read(name)
        XCTAssertEqual(imported, text)
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

    /// iPad: both sides at once (the server's folder and this iPad's files), in portrait and in landscape; turning it
    /// keeps the server, the folder and what is selected.
    @MainActor func testIPadShowsBothSidesAndKeepsThemWhenTurned() async throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad only")
        try await lab.write("hello\n", to: "notes.txt")
        try await lab.session.makeDirectory(lab.path("docs"))
        let documents = folder.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try Data("here\n".utf8).write(to: documents.appendingPathComponent("local.txt"))
        XCUIDevice.shared.orientation = .portrait
        let app = openTestFolder()
        XCTAssert(app.staticTexts["notes.txt"].waitForExistence(timeout: 10))
        XCTAssert(app.staticTexts["local.txt"].waitForExistence(timeout: 10), "This iPad's side isn't showing")
        XCTAssertFalse(app.segmentedControls.buttons["On iPad"].exists, "A switcher with room for both sides")
        keepScreenshot("iPad portrait")

        // Selecting on the server's side, then turning the iPad.
        app.buttons["More"].firstMatch.tap()
        app.buttons["Select"].tap()
        app.staticTexts["notes.txt"].tap()
        let notes = row("notes.txt", in: app)
        XCTAssert(notes.isSelected)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssert(app.staticTexts["local.txt"].waitForExistence(timeout: 10))
        XCTAssert(pathBar(app).staticTexts[RemotePath.name(lab.folder)].exists)
        XCTAssert(notes.isSelected && app.buttons["Done"].firstMatch.exists)
        keepScreenshot("iPad landscape, selecting")
        app.buttons["Done"].firstMatch.tap()
        keepScreenshot("iPad landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssert(app.staticTexts["notes.txt"].waitForExistence(timeout: 10))
        XCTAssert(pathBar(app).staticTexts[RemotePath.name(lab.folder)].exists)
    }

    // MARK: Helpers

    /// Launches the app with the lab's target saved as "lab", logs into it (its host key is trusted already: `LabServer`
    /// wrote known_hosts), and opens the test's folder in the Files tab.
    @MainActor private func openTestFolder() -> XCUIApplication {
        try? """
        {"hosts":[{"id":"\(UUID())","label":"lab","hostname":"127.0.0.1","port":42201,"username":"dev","auth":"password"}]}
        """.write(to: folder.appendingPathComponent("airscp.json"), atomically: true, encoding: .utf8)
        let app = XCUIApplication()
        app.launchEnvironment["AIRSCP_SUPPORT_DIR"] = folder.path
        app.launch()
        let saved = app.staticTexts["lab"]
        XCTAssert(saved.waitForExistence(timeout: 10))
        saved.tap()
        let password = app.secureTextFields["answer"]
        XCTAssert(password.waitForExistence(timeout: 30), "No password question")
        password.tap()  // focused already, unless the sheet is still on its way
        password.typeText("porter-dev\n")
        XCTAssert(app.staticTexts["Connected"].waitForExistence(timeout: 30))
        // The iPad's tabs are buttons at the top, not a tab bar.
        (app.tabBars.firstMatch.exists ? app.tabBars.buttons["Files"] : app.buttons["Files"].firstMatch).tap()
        let mine = app.staticTexts[RemotePath.name(lab.folder)]
        XCTAssert(mine.waitForExistence(timeout: 30), "The test's folder isn't listed in the home folder")
        mine.tap()
        XCTAssert(pathBar(app).staticTexts[RemotePath.name(lab.folder)].waitForExistence(timeout: 10))
        return app
    }

    /// Waits until the file is there with these bytes.
    private func arrival(of file: URL, _ bytes: Data) async {
        let arrived = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (try? Data(contentsOf: file)) == bytes }, object: nil)
        await fulfillment(of: [arrived], timeout: 30)
    }

    /// The (first) side's path bar.
    @MainActor private func pathBar(_ app: XCUIApplication) -> XCUIElement {
        app.scrollViews.matching(identifier: "path").firstMatch
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
