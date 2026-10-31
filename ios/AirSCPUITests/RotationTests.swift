import XCTest

/// The Terminal tab and Search in portrait and landscape (the iPad's rule; the iPhone turns too): a rotation keeps the
/// terminal's shell and scrollback, and its terminal gets the new size. On the Docker lab's target, as TerminalTests.
final class RotationTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipUnless(labIsReachable(), "The Docker lab's target doesn't answer on 127.0.0.1:42201 (testenv/up.sh starts it)")
        folder = try labFolder(snippets: #"{"id":"\#(UUID())","name":"Quarter","command":"echo snippet-$((5*5))","runInTerminal":false}"#)
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testTheTerminalAndSearchFollowARotation() {
        let app = launchConnectedToLab(folder)
        let terminal = showTerminal(app)
        let line = app.textFields["commandLine"]
        line.tap()
        line.typeText("echo size=$(stty size)\n")
        XCTAssert(terminal.shows("size="), terminal.text)
        keepScreenshot("Terminal, portrait")

        // The same shell after the turn, its output kept, and the size it reports the new one: wider.
        XCUIDevice.shared.orientation = .landscapeLeft
        line.tap()
        line.typeText("echo size=$(stty size)\n")
        XCTAssert(terminal.shows("size=", times: 2), terminal.text)
        let sizes = Self.sizes(in: terminal.text)
        XCTAssert(sizes.count == 2 && sizes[1].columns > sizes[0].columns, "\(sizes)")
        keepScreenshot("Terminal, landscape")
        terminal.tap()
        XCTAssert(app.descendants(matching: .any)["ctrl"].firstMatch.waitForExistence(timeout: 10), "No key bar")
        keepScreenshot("Terminal, landscape, typing")
        XCUIDevice.shared.orientation = .portrait
        app.typeText("echo size=$(stty size)\n")
        XCTAssert(terminal.shows("size=", times: 3), terminal.text)
        XCTAssertEqual(Self.sizes(in: terminal.text).last?.columns, sizes[0].columns, terminal.text)
        keepScreenshot("Terminal, portrait, typing")
        app.buttons["Hide Keyboard"].tap()  // the iPhone's keyboard covers the tabs

        app.tab("Search").tap()
        let field = app.searchFields.firstMatch
        XCTAssert(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Quarter")
        XCTAssert(app.staticTexts["echo snippet-$((5*5))"].waitForExistence(timeout: 5), "The snippet isn't found")
        keepScreenshot("Search, portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssert(app.staticTexts["echo snippet-$((5*5))"].waitForExistence(timeout: 5), "The snippet is gone")
        keepScreenshot("Search, landscape")
    }

    /// The rows and columns each `echo size=$(stty size)` printed, in order.
    static func sizes(in text: String) -> [(rows: Int, columns: Int)] {
        let pattern = try! NSRegularExpression(pattern: #"size=(\d+) (\d+)"#)
        return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            let number = { Int((text as NSString).substring(with: match.range(at: $0))) ?? 0 }
            return (number(1), number(2))
        }
    }

    private func keepScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}
