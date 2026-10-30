import XCTest

/// Servers ▸ Nearby: a server that announces itself on the network shows, and choosing it opens the server editor
/// with it filled in. The Simulator shares this Mac's network, so the Mac announces one while the test runs:
///     dns-sd -R "AirSCP Test Server" _ssh._tcp local 42201
final class NearbyTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("airscp-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testAnAnnouncedServerIsFoundAndChosen() throws {
        let app = XCUIApplication()
        app.launchEnvironment["AIRSCP_SUPPORT_DIR"] = folder.path
        app.launch()
        XCTAssert(app.navigationBars["Servers"].waitForExistence(timeout: 10))
        guard app.buttons["Nearby"].exists else { throw XCTSkip("Servers has no Nearby button yet") }
        app.buttons["Nearby"].tap()

        // The first look on the network may ask for Local Network access.
        let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons["Allow"]
        if allow.waitForExistence(timeout: 3) { allow.tap() }

        let server = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'AirSCP Test Server'")).firstMatch
        XCTAssert(server.waitForExistence(timeout: 15), "No AirSCP Test Server: is dns-sd announcing it?")
        server.tap()
        // The editor shows it filled in: its name, or its port (not the usual 22).
        let filledIn = NSPredicate(format: "value == 'AirSCP Test Server' OR value CONTAINS '42201'")
        XCTAssert(app.textFields.matching(filledIn).firstMatch.waitForExistence(timeout: 10))
    }
}
