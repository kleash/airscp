import XCTest

/// Settings ▸ About: the version, the links out (not followed: they leave the app) and the licence texts in the app.
final class AboutTests: XCTestCase {
    func testAboutListsTheLinksAndTheLicencesOpen() throws {
        continueAfterFailure = false
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("airscp-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = XCUIApplication()
        app.launchEnvironment["AIRSCP_SUPPORT_DIR"] = folder.path
        app.launch()
        app.buttons["Settings"].firstMatch.tap()

        // Top to bottom, scrolled to each in turn: a list keeps only the rows on screen (a Duo's outer screen is small).
        func row(_ predicate: NSPredicate, _ name: String) {
            let element = app.descendants(matching: .any).matching(predicate).firstMatch
            for _ in 0..<6 where !element.exists { app.swipeUp() }
            XCTAssert(element.exists, name)
        }
        row(NSPredicate(format: "label CONTAINS 'Version '"), "version")
        for link in ["Source Code", "Shubham Aggarwal (kleash)", "Help and Documentation", "Report a Problem",
                     "Email the Developer", "Rate on the App Store"] {
            row(NSPredicate(format: "elementType == %d AND label BEGINSWITH %@", XCUIElement.ElementType.link.rawValue,
                            link), link)
        }
        row(NSPredicate(format: "elementType == %d AND label == 'Licences'", XCUIElement.ElementType.button.rawValue),
            "Licences")

        let licences = app.buttons["Licences"]
        if !licences.isHittable { app.swipeUp() }
        licences.tap()
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'libssh2'")).firstMatch.tap()
        XCTAssert(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Copyright'")).firstMatch
            .waitForExistence(timeout: 5))
    }
}
