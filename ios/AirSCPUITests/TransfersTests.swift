import XCTest

/// Transfers (Phase 2d): the running transfer above the tab bar, the Transfers tab's sections, Pause and Resume, Retry,
/// and the check that ends a copy ("Checksums match"). Downloads from the Docker lab's target (testenv/README.md:
/// 127.0.0.1:42201, user dev, the lab's throwaway password porter-dev) of files every Debian has, started by
/// AIRSCP_TEST_DOWNLOADS once connected, into the test's own settings folder (AIRSCP_SUPPORT_DIR); nothing is written on
/// the server. AIRSCP_TEST_SPEED_LIMIT makes them slow enough to watch. Skipped while the lab isn't running.
final class TransfersTests: XCTestCase {
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

    func testARunningDownloadShowsAboveTheTabBarAndEndsChecked() {
        let app = connect(downloading: ["/usr/bin/bash"], bytesPerSecond: 100_000)  // 1.4 MB: about 14 s
        let accessory = app.buttons["transferAccessory"]
        XCTAssert(accessory.waitForExistence(timeout: 30), "No transfer above the tab bar")
        XCTAssert(accessory.label.contains("bash"), accessory.label)
        keepScreenshot("Accessory")
        accessory.tap()

        XCTAssert(app.navigationBars["Transfers"].waitForExistence(timeout: 10))
        let row = transfer("bash", in: app)
        XCTAssert(row.waitForExistence(timeout: 10))
        XCTAssert(app.staticTexts["Now"].exists, "No Now section")
        XCTAssert(app.staticTexts["Keep AirSCP open for big transfers: iOS may pause them in the background."].exists)
        XCTAssert(app.otherElements["speedChart"].waitForExistence(timeout: 10))
        keepScreenshot("Running")

        XCTAssert(waitUntil(row, says: "Checksums match", timeout: 60), row.label)
        XCTAssert(app.staticTexts["Done"].exists)
        let copy = try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("bash").path)
        XCTAssertEqual(copy?[.size] as? Int, 1_412_096)  // the lab's /usr/bin/bash
        keepScreenshot("Done")
        app.buttons["Clear Done"].tap()
        XCTAssert(app.staticTexts["No transfers"].waitForExistence(timeout: 10))
    }

    func testAPausedDownloadResumesAndAFailedOneNeedsYou() {
        let app = connect(downloading: ["/usr/bin/bash", "/etc/shadow"], bytesPerSecond: 100_000)  // about 14 s
        openTransfers(app)
        let row = transfer("bash", in: app)
        XCTAssert(waitUntil(row, says: "Downloading", timeout: 30), row.label)
        row.swipeLeft()
        app.buttons["Pause"].tap()
        XCTAssert(waitUntil(row, says: "Paused: Resume continues where it stopped", timeout: 30), row.label)
        keepScreenshot("Paused")

        // The server's dev may not read /etc/shadow: it waits under Needs you with the reason, and Retry runs it again.
        let failed = transfer("shadow", in: app)
        XCTAssert(waitUntil(failed, says: "The server didn't allow it", timeout: 30), failed.label)
        XCTAssert(app.staticTexts["Needs you"].exists)
        keepScreenshot("Needs you")
        failed.swipeLeft()
        XCTAssert(app.buttons["Retry"].waitForExistence(timeout: 5))
        app.buttons["Retry"].tap()
        XCTAssert(waitUntil(failed, says: "The server didn't allow it", timeout: 30), failed.label)

        row.swipeLeft()
        app.buttons["Resume"].tap()
        XCTAssert(waitUntil(row, says: "Checksums match", timeout: 60), row.label)
    }

    /// The tray holds the server's files: one comes out, and Share downloads the rest (through the queue, checked) for
    /// the share sheet. Send offers the open server (sending itself is in Core's tests: it would write on the lab).
    func testTheTrayHoldsFilesAndSharesThem() {
        let app = connect(tray: ["/usr/bin/bash", "/etc/hostname", "/etc/os-release"])
        openTransfers(app)
        let tray = app.buttons["Tray"]
        XCTAssert(tray.waitForExistence(timeout: 10))
        XCTAssert((tray.value as? String) == "3 items", String(describing: tray.value))
        tray.tap()
        XCTAssert(app.navigationBars["Tray"].waitForExistence(timeout: 10))
        for name in ["bash", "hostname", "os-release"] { XCTAssert(app.staticTexts[name].exists, name) }
        keepScreenshot("Tray")
        app.staticTexts["os-release"].swipeLeft()
        app.buttons["Remove"].tap()
        XCTAssert(app.staticTexts["os-release"].waitForNonExistence(timeout: 5))

        app.buttons["Send"].tap()
        XCTAssert(app.buttons["dev@127.0.0.1:42201 — dev"].waitForExistence(timeout: 5), "The open server isn't offered")
        keepScreenshot("Send to")
        app.buttons["dev@127.0.0.1:42201 — dev"].coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: -3)).tap()  // closes the menu

        app.buttons["Share"].tap()
        let sheet = app.otherElements["ActivityListView"]
        XCTAssert(sheet.waitForExistence(timeout: 60), "No share sheet")
        keepScreenshot("Share")
    }

    /// Turned between portrait and landscape (an iPad, and the iPhone Duo's fold), a running transfer keeps going and
    /// keeps showing, above the tab bar and in Transfers; the tray shows in both too.
    func testARunningTransferKeepsGoingWhileTheDeviceTurns() {
        let app = connect(downloading: ["/usr/bin/bash"], tray: ["/etc/hostname"], bytesPerSecond: 60_000)  // about 24 s
        defer { XCUIDevice.shared.orientation = .portrait }
        let accessory = app.buttons["transferAccessory"]
        XCTAssert(accessory.waitForExistence(timeout: 30), "No transfer above the tab bar")
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            XCTAssert(accessory.waitForExistence(timeout: 10), "No transfer above the tab bar in \(Self.name(orientation))")
            keepScreenshot("Accessory, " + Self.name(orientation))
        }
        openTransfers(app)
        let row = transfer("bash", in: app)
        XCTAssert(waitUntil(row, says: "Downloading", timeout: 30), row.label)
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeLeft] {
            let before = row.label
            XCUIDevice.shared.orientation = orientation
            // Still listed, and still moving (or done meanwhile).
            let moved = expectation(for: NSPredicate(format: "label != %@", before), evaluatedWith: row)
            XCTAssertEqual(XCTWaiter.wait(for: [moved], timeout: 30), .completed, "Stuck in \(Self.name(orientation)): \(row.label)")
            keepScreenshot("Transfers, " + Self.name(orientation))
        }
        app.buttons["Tray"].tap()
        XCTAssert(app.staticTexts["hostname"].waitForExistence(timeout: 10))
        keepScreenshot("Tray, landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssert(app.staticTexts["hostname"].waitForExistence(timeout: 10))
        keepScreenshot("Tray, portrait")
        app.buttons["Done"].tap()
        XCTAssert(waitUntil(row, says: "Checksums match", timeout: 90), row.label)
    }

    // MARK: Helpers

    private static func name(_ orientation: UIDeviceOrientation) -> String {
        orientation.isLandscape ? "landscape" : "portrait"
    }

    /// The Transfers tab: in the tab bar (iPhone), or among the tabs at the top (iPad).
    private func openTransfers(_ app: XCUIApplication) {
        let tab = app.tabBars.buttons["Transfers"]
        (tab.exists ? tab : app.buttons["Transfers"].firstMatch).tap()
    }

    /// Launches a throwaway AirSCP that downloads `paths` once connected (at most `bytesPerSecond`) and puts the server's
    /// files `tray` in the tray, and connects it to the lab's target.
    private func connect(downloading paths: [String] = [], tray: [String] = [], bytesPerSecond: Int? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AIRSCP_SUPPORT_DIR"] = folder.path
        app.launchEnvironment["AIRSCP_TEST_DOWNLOADS"] = paths.joined(separator: ",")
        app.launchEnvironment["AIRSCP_TEST_TRAY"] = tray.joined(separator: ",")
        if let bytesPerSecond { app.launchEnvironment["AIRSCP_TEST_SPEED_LIMIT"] = String(bytesPerSecond) }
        app.launch()
        let field = app.textFields["quickConnect"]
        XCTAssert(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("dev@127.0.0.1:42201\n")
        XCTAssert(app.buttons["Trust"].waitForExistence(timeout: 30), "No Trust question")
        app.buttons["Trust"].tap()
        XCTAssert(app.secureTextFields["answer"].waitForExistence(timeout: 30), "No password question")
        app.typeText("porter-dev\n")
        XCTAssert(app.staticTexts["Connected"].waitForExistence(timeout: 30))
        return app
    }

    private func transfer(_ name: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["transfer " + name]
    }

    /// Waits until the element's label says `text` (a row reads as one element: name, route, status).
    private func waitUntil(_ element: XCUIElement, says text: String, timeout: TimeInterval) -> Bool {
        let found = expectation(for: NSPredicate(format: "label CONTAINS %@", text), evaluatedWith: element)
        return XCTWaiter.wait(for: [found], timeout: timeout) == .completed
    }

    /// Keeps a screenshot in the test's results, to look at the screens in light and dark.
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
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }
}
