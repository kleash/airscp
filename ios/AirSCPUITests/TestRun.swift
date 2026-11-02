import XCTest

/// The test bundle's principal class (NSPrincipalClass): each test starts in portrait, whatever the test before left (a
/// failed one can stop on its side), or in landscape for a run with TEST_RUNNER_AIRSCP_ORIENTATION=landscape.
final class TestRun: NSObject, XCTestObservation {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(self)
    }

    func testCaseWillStart(_ testCase: XCTestCase) {
        let landscape = ProcessInfo.processInfo.environment["AIRSCP_ORIENTATION"] == "landscape"
        MainActor.assumeIsolated {
            let start: UIDeviceOrientation = landscape ? .landscapeLeft : .portrait
            if XCUIDevice.shared.orientation != start { XCUIDevice.shared.orientation = start }  // else no wait on the last app
        }
    }
}
