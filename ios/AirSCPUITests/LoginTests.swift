import XCTest

/// Logging in (Phase 2b): a new server's Trust question, then its password, against the Docker lab's target
/// (testenv/README.md: 127.0.0.1:42201, user dev with the lab's throwaway password porter-dev). Each test gives the app
/// a settings folder of its own (AIRSCP_SUPPORT_DIR), so known_hosts, airscp.json and the Keychain stay throwaway.
/// Skipped while the lab isn't running (testenv/up.sh).
final class LoginTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(labIsUp(), "The Docker lab's target doesn't answer on 127.0.0.1:42201 (testenv/up.sh starts it)")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("airscp-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testANewServerIsTrustedThenThePasswordAsked() {
        let app = quickConnect()
        keepScreenshot("Trust")
        app.buttons["Trust"].tap()

        let password = app.secureTextFields["answer"]
        XCTAssert(password.waitForExistence(timeout: 30), "No password question")
        XCTAssert(knownHosts.hasPrefix("[127.0.0.1]:42201 "), knownHosts)
        app.typeText("not-the-password\n")  // no tap: the field has the keyboard already; Return sends
        XCTAssert(app.staticTexts["That password wasn't accepted. Try again."].waitForExistence(timeout: 30))
        app.typeText("porter-dev")
        keepScreenshot("Password again")
        app.buttons["Connect"].tap()

        // Logged in: the question goes, and Servers shows the connection open.
        XCTAssert(password.waitForNonExistence(timeout: 30))
        XCTAssert(app.staticTexts["Connected"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.alerts["Can't connect"].exists)
    }

    func testCancellingTheTrustQuestionDoesntConnect() {
        let app = quickConnect()
        app.buttons["Cancel"].tap()

        // Connecting stops there, quietly (the user said no): no alert, no password asked.
        XCTAssert(app.staticTexts["Not connected"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.alerts["Can't connect"].exists)
        XCTAssertFalse(app.secureTextFields["answer"].exists)
        XCTAssertFalse(knownHosts.contains("42201"), knownHosts)
    }

    /// Connects to the lab's target from the Servers tab without saving it, and waits for its Trust question.
    private func quickConnect() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AIRSCP_SUPPORT_DIR"] = folder.path
        app.launch()
        let field = app.textFields["quickConnect"]
        XCTAssert(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("dev@127.0.0.1:42201\n")
        let fingerprint = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'SHA256:'")).firstMatch
        XCTAssert(fingerprint.waitForExistence(timeout: 30), "No Trust question")
        return app
    }

    private var knownHosts: String {
        (try? String(contentsOf: folder.appendingPathComponent("known_hosts"), encoding: .utf8)) ?? ""
    }

    /// Keeps a screenshot in the test's results, to look at the sheets in light and dark.
    private func keepScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// Whether the lab's target accepts a TCP connection (at once on this Mac: refused or not).
    private func labIsUp() -> Bool {
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
