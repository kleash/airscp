import AirSCPCore
import XCTest

/// The Monitor screen and the figures on Servers (Phase 2g), and the connection check when AirSCP comes back to the
/// front, against the Docker lab's target. The app's own connection is told apart on the lab as the one `sshd-session`
/// of dev's that appears when the app logs in (`LabServer.connections`); the tests kill only that one. Skipped while
/// the lab isn't running (testenv/up.sh).
final class MonitorTests: XCTestCase {
    private var folder: URL!
    private var lab: LabServer!
    /// dev's connections on the lab just before the app logged in.
    private var before: Set<Int> = []

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

    /// Servers shows the connected server's figures; its row opens the Monitor screen: rings, the CPU chart, the busiest
    /// processes; a search finds a `sleep` started on the lab, and Kill (asked first) ends it.
    @MainActor func testTheMonitorShowsTheSystemAndKillsAProcess() async throws {
        let seconds = Int.random(in: 400_000...499_999)
        let pid = try await lab.start("sleep \(seconds)")
        let app = try await logIn()
        let figures = app.descendants(matching: .any)["figures"].firstMatch
        XCTAssert(figures.waitForExistence(timeout: 30), "No figures on Servers")
        XCTAssert(figures.label.contains("CPU") && figures.label.contains("Memory") && figures.label.contains("Disk"), figures.label)
        keepScreenshot("Servers")

        openMonitor(app)
        for ring in ["monitor.cpu", "monitor.memory", "monitor.disk"] {
            XCTAssert(app.descendants(matching: .any)[ring].waitForExistence(timeout: 30), "No \(ring)")
        }
        XCTAssert(app.staticTexts["Busiest processes"].waitForExistence(timeout: 10))
        XCTAssert(app.descendants(matching: .any)["monitor.chart"].waitForExistence(timeout: 15), "No CPU chart")
        keepScreenshot("Monitor")

        let search = app.searchFields.firstMatch
        if !search.waitForExistence(timeout: 5) || !search.isHittable { app.swipeDown() }  // under the title until pulled
        search.tap()
        search.typeText("sleep \(seconds)\n")  // Return puts the keyboard away: the row is under it
        let row = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "\(pid) · dev")).firstMatch
        XCTAssert(row.waitForExistence(timeout: 15), "The sleep isn't listed")
        row.swipeLeft()
        app.buttons["Kill"].tap()
        let ask = app.alerts["Kill “sleep” (\(pid))?"]
        XCTAssert(ask.waitForExistence(timeout: 5))
        keepScreenshot("Kill")
        ask.buttons["Kill"].tap()
        let ended = await eventually { try await !self.lab.isRunning(pid) }
        XCTAssert(ended, "The sleep still runs")
        XCTAssert(row.waitForNonExistence(timeout: 15))
        XCTAssert(app.staticTexts["No process matches “sleep \(seconds)”."].waitForExistence(timeout: 5))
    }

    /// The Monitor screen and the figures read the server only while they show: nothing of the app's goes to the lab
    /// while another tab shows, and reading starts again on coming back.
    @MainActor func testReadingStopsWhenTheScreenGoes() async throws {
        let app = try await logIn()
        let mine = try await appConnection()
        openMonitor(app)

        // Away (the Monitor screen stays under the Servers tab): once a read under way is done, the connection is quiet.
        app.show("Transfers")
        XCTAssert(app.navigationBars["Transfers"].waitForExistence(timeout: 10), "Transfers doesn't show")
        var quiet = try await lab.wakeups(of: mine)
        for _ in 0..<10 {
            try await Task.sleep(for: .seconds(1))
            let now = try await lab.wakeups(of: mine)
            if now == quiet { break }
            quiet = now
        }
        // 8 s: more than two reads of the screen (every 3 s) while nothing of the server shows; a read would wake its sshd.
        try await Task.sleep(for: .seconds(8))
        let after = try await lab.wakeups(of: mine)
        XCTAssertEqual(after, quiet, "The app read the server while nothing of it showed")

        // Back: the screen reads again.
        app.show("Servers")
        XCTAssert(app.descendants(matching: .any)["monitor.cpu"].waitForExistence(timeout: 10), "The Monitor screen isn't there")
        let read = await eventually { try await self.lab.wakeups(of: mine) > after }
        XCTAssert(read, "No read after coming back")
    }

    /// Back in front after the connection was cut meanwhile (its sshd ended on the lab while AirSCP was in the
    /// background): the check finds it lost, and AirSCP reconnects by itself with the remembered password.
    @MainActor func testComingBackToTheFrontReconnectsALostConnection() async throws {
        let app = try await logIn(remember: true)
        let mine = try await appConnection()
        XCUIDevice.shared.press(.home)
        // Background, or suspended already. The iPhone Duo's Simulator ignores Home: another app in front instead.
        var away = await eventually { app.state != .runningForeground }
        if !away {
            XCUIApplication(bundleIdentifier: "com.apple.Preferences").activate()
            away = await eventually { app.state != .runningForeground }
        }
        XCTAssert(away, "Still in front: state \(app.state.rawValue)")
        try await lab.end(mine)
        let gone = await eventually { try await !self.lab.connections().contains(mine) }
        XCTAssert(gone, "The app's connection still runs on the lab")

        app.activate()
        // "Reconnecting…" can come and go before a busy Simulator looks: a new connection of the app's on the lab is the proof.
        let again = await eventually { try await !self.lab.connections().subtracting(self.before).subtracting([mine]).isEmpty }
        XCTAssert(again, "No new connection after coming back")
        XCTAssert(app.staticTexts["Connected"].waitForExistence(timeout: 30), "Not connected again")
        keepScreenshot("Reconnected")
    }

    /// iPad (and an iPhone on its side): Servers' figures and the Monitor screen in portrait and landscape; turning it
    /// keeps the screen.
    @MainActor func testTheMonitorInBothOrientations() async throws {
        XCUIDevice.shared.orientation = .portrait
        let app = try await logIn()
        XCTAssert(app.descendants(matching: .any)["figures"].waitForExistence(timeout: 30))
        keepScreenshot("Servers portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssert(app.descendants(matching: .any)["figures"].waitForExistence(timeout: 10))
        keepScreenshot("Servers landscape")

        openMonitor(app)
        let cpu = app.descendants(matching: .any)["monitor.cpu"]
        XCTAssert(app.descendants(matching: .any)["monitor.chart"].waitForExistence(timeout: 15))
        keepScreenshot("Monitor landscape")
        XCUIDevice.shared.orientation = .portrait
        XCTAssert(app.staticTexts["Busiest processes"].waitForExistence(timeout: 10))
        XCTAssert(cpu.exists)
        keepScreenshot("Monitor portrait")
    }

    // MARK: Helpers

    /// Launches the app with the lab's target saved as "lab" and logs into it (its host key is trusted already:
    /// `LabServer` wrote known_hosts); `remember`: the password is kept for reconnecting.
    @MainActor private func logIn(remember: Bool = false) async throws -> XCUIApplication {
        try? """
        {"hosts":[{"id":"\(UUID())","label":"lab","hostname":"127.0.0.1","port":42201,"username":"dev","auth":"password"}]}
        """.write(to: folder.appendingPathComponent("airscp.json"), atomically: true, encoding: .utf8)
        let app = XCUIApplication()
        app.launchEnvironment["AIRSCP_SUPPORT_DIR"] = folder.path
        app.launch()
        let saved = app.staticTexts["lab"]
        XCTAssert(saved.waitForExistence(timeout: 30))  // a busy Mac's simulator can take that long to launch
        saved.tap()
        let password = app.secureTextFields["answer"]
        XCTAssert(password.waitForExistence(timeout: 30), "No password question")
        if remember {
            let toggle = app.switches["Remember in Keychain"].firstMatch
            // iOS 27 turns the switch's value a moment after the tap, and drops a tap while the sheet still comes in: tapped
            // while it stays off, on the switch itself (the element spans the label too; the switch is ~40 pt from its end).
            let on = { XCTWaiter.wait(for: [self.expectation(for: NSPredicate(format: "value == '1'"), evaluatedWith: toggle)], timeout: $0) }
            let knob = toggle.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 0.5)).withOffset(CGVector(dx: -40, dy: 0))
            for _ in 0..<3 where on(3) != .completed { knob.tap() }
            XCTAssertEqual(on(5), .completed, "Remember in Keychain is off")
        }
        password.tap()  // focused already, unless the sheet is still on its way
        // dev's connection process starts once logged in: a moment before, so that another test's hardly comes between.
        before = try await lab.connections()
        password.typeText("porter-dev\n")
        XCTAssert(app.staticTexts["Connected"].waitForExistence(timeout: 30))
        return app
    }

    /// The lab's Monitor screen, from its row in Servers: tapped again when a tap got lost (a busy Mac's simulator).
    @MainActor private func openMonitor(_ app: XCUIApplication) {
        let cpu = app.descendants(matching: .any)["monitor.cpu"]
        for _ in 0..<3 where !cpu.exists {
            // Servers' row (an iPad-sized window's sidebar lists the open server under the same name).
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'lab, Connected'")).firstMatch.tap()
            _ = cpu.waitForExistence(timeout: 20)
        }
        XCTAssert(cpu.exists, "No Monitor screen")
    }

    /// The app's connection on the lab: the one dev's connection that wasn't there before it logged in.
    private func appConnection() async throws -> Int {
        let new = try await lab.connections().subtracting(before)
        // Another test's connection that came meanwhile: rather than guess, stop (nothing is killed).
        XCTAssertEqual(new.count, 1, "Can't tell the app's connection on the lab apart: \(new)")
        return try XCTUnwrap(new.first)
    }

    /// Waits until `condition` holds (15 s at most).
    private func eventually(_ condition: () async throws -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(15)
        while Date() < end {
            if (try? await condition()) == true { return true }
            try? await Task.sleep(for: .milliseconds(300))
        }
        return (try? await condition()) == true
    }

    @MainActor private func keepScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

extension LabServer {
    /// dev's connections: OpenSSH's unprivileged `sshd-session` process of each (the lab's OpenSSH 10).
    func connections() async throws -> Set<Int> {
        Set(try await session.run("pgrep -u dev -x sshd-session; true").output.split(separator: "\n").compactMap { Int($0) })
    }

    /// How often a process has woken up (its voluntary context switches): an sshd's grows with each packet it gets.
    func wakeups(of pid: Int) async throws -> Int {
        let output = try await session.run("grep voluntary_ctxt_switches /proc/\(pid)/status").output
        return Int(output.split(separator: "\n").first { $0.hasPrefix("voluntary") }?.split(separator: "\t").last ?? "") ?? 0
    }

    /// Starts `command` in the background on the lab (left running once this session's command ends); its pid (the
    /// last line: dev's .bashrc prints a line first).
    func start(_ command: String) async throws -> Int {
        let output = try await session.run("nohup \(command) >/dev/null 2>&1 & echo $!").output
        return try XCTUnwrap(output.split(separator: "\n").last.flatMap { Int($0) }, output)
    }

    func isRunning(_ pid: Int) async throws -> Bool {
        try await session.run("kill -0 \(pid)").status == 0
    }

    /// Ends a connection: its sshd, as a server going away does.
    func end(_ pid: Int) async throws {
        _ = try await session.run("kill -KILL \(pid)")
    }
}
