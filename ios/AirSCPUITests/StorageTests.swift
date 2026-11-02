import AirSCPCore
import XCTest

/// S3 storage on iPhone: added in the server editor (its secret kept in the Keychain, not in airscp.json), opened, and a
/// side in Files, against the Docker lab's S3 storage in a bucket of the test's own (`LabStorage`). Skipped while the lab
/// isn't running (testenv/up.sh).
final class StorageTests: XCTestCase {
    private var folder: URL!
    private var storage: LabStorage!

    override func setUp() async throws {
        continueAfterFailure = false
        try XCTSkipUnless(LabStorage.isUp(), "The Docker lab's S3 storage doesn't answer on 127.0.0.1:42284 (testenv/up.sh starts it)")
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("airscp-ui-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        storage = try await LabStorage()
    }

    override func tearDown() async throws {
        await storage?.remove()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    @MainActor func testStorageIsAddedOpenedAndFilesGoThereAndBack() async throws {
        try XCTSkipIf(UIDevice.current.userInterfaceIdiom == .pad, "The sides' switcher is the iPhone's")
        let bytes = Data((0..<200_000).map { _ in UInt8.random(in: 0...255) })
        let documents = folder.appendingPathComponent("Documents")
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        let local = documents.appendingPathComponent("photo.bin")
        try bytes.write(to: local)
        let app = XCUIApplication()
        app.launchEnvironment["AIRSCP_SUPPORT_DIR"] = folder.path
        app.launch()

        // The editor's S3 kind: the Mac's fields; Save stays off until the key is there.
        app.buttons["Add Server"].firstMatch.tap()
        app.segmentedControls.buttons["S3 storage"].tap()
        XCTAssert(app.navigationBars["New S3 Storage"].waitForExistence(timeout: 5))
        type("lab storage", into: app.textFields["Name"])
        type("http://127.0.0.1:\(LabStorage.port)", into: app.textFields["Endpoint"])
        type("us-east-1", into: app.textFields["Region"])
        type(storage.bucket, into: app.textFields["Bucket"])
        let save = app.navigationBars.buttons["Save"]
        XCTAssertFalse(save.isEnabled)
        type(LabStorage.accessKey, into: app.textFields["Access key ID"])
        XCTAssertFalse(save.isEnabled)
        type(LabStorage.secret, into: app.secureTextFields["Secret key"])
        keepScreenshot("New S3 storage")
        save.tap()
        // AirSCP keeps the secret: iOS's Passwords has nothing to offer to save (its prompt has Not Now).
        XCTAssertFalse(app.buttons["Not Now"].waitForExistence(timeout: 3), "iOS offers to save the secret in Passwords")

        // Saved without its secret, which the Keychain keeps.
        let row = app.staticTexts["lab storage"]
        XCTAssert(row.waitForExistence(timeout: 5))
        let saved = try String(contentsOf: folder.appendingPathComponent("airscp.json"), encoding: .utf8)
        XCTAssert(saved.contains(storage.bucket) && saved.contains(LabStorage.accessKey), saved)
        XCTAssertFalse(saved.contains(LabStorage.secret))

        // Opened: a side in Files, at the bucket.
        row.tap()
        XCTAssert(app.staticTexts["Connected"].waitForExistence(timeout: 30))
        keepScreenshot("Servers with storage")
        app.show("Files")
        XCTAssert(app.staticTexts["Empty folder"].waitForExistence(timeout: 30))

        // From this iPhone to the bucket, and back once this iPhone's copy is gone.
        app.segmentedControls.buttons["On iPhone"].tap()
        XCTAssert(app.staticTexts["photo.bin"].waitForExistence(timeout: 10))
        send("photo.bin", in: app)
        app.segmentedControls.buttons["lab storage"].tap()
        XCTAssert(app.staticTexts["photo.bin"].waitForExistence(timeout: 30))
        let uploaded = try await storage.data("photo.bin")
        XCTAssertEqual(uploaded, bytes)

        try FileManager.default.removeItem(at: local)
        send("photo.bin", in: app)
        let arrived = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in (try? Data(contentsOf: local)) == bytes }, object: nil)
        await fulfillment(of: [arrived], timeout: 30)

        // A folder in the bucket: amber, as storage is.
        app.buttons["New Folder"].tap()
        app.alerts.buttons["Create"].tap()
        XCTAssert(app.staticTexts["untitled folder"].waitForExistence(timeout: 15))
        keepScreenshot("Storage in Files")
    }

    /// The row's Send, from its swipe actions: swiped again when they didn't open (a swipe while the side is still
    /// coming in gets lost).
    @MainActor private func send(_ name: String, in app: XCUIApplication) {
        let row = app.cells.containing(.staticText, identifier: name).firstMatch
        for _ in 0..<3 {
            row.swipeLeft()
            if app.buttons["Send"].waitForExistence(timeout: 3) { break }
        }
        app.buttons["Send"].tap()
    }

    private func type(_ text: String, into field: XCUIElement) {
        field.tap()
        field.typeText(text)
    }

    @MainActor private func keepScreenshot(_ name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }
}

/// The Docker lab's S3 storage (testenv/README.md: 127.0.0.1:42284, its throwaway keys), for what a test does there
/// behind the app's back: a bucket of its own, made and removed with plain signed requests (AirSCP makes no buckets),
/// and what arrived checked.
final class LabStorage {
    static let port = 42284, accessKey = "porter-s3", secret = "porter-s3-secret"
    let bucket = "ui-" + UUID().uuidString.prefix(8).lowercased()
    private let client = S3Client(settings: S3Settings(endpoint: "http://127.0.0.1:\(LabStorage.port)", region: "us-east-1",
                                                       accessKeyID: LabStorage.accessKey), name: "lab")

    init() async throws {
        client.credentials = S3Client.Credentials(accessKeyID: Self.accessKey, secret: Self.secret)
        try await send("PUT")
    }

    func data(_ key: String) async throws -> Data {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("lab-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        let handle = try FileHandle(forWritingTo: file)
        try await client.get(bucket, key, into: handle)
        try handle.close()
        return try Data(contentsOf: file)
    }

    /// The bucket, emptied first.
    func remove() async {
        if let keys = try? await client.list(bucket, prefix: "", delimiter: nil).objects.map(\.key), !keys.isEmpty {
            try? await client.delete(bucket, keys: keys)
        }
        try? await send("DELETE")
    }

    /// CreateBucket or DeleteBucket, signed (path style: the endpoint is an IP address).
    private func send(_ method: String) async throws {
        let path = "/" + bucket
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(Self.port)" + path)!)
        request.httpMethod = method
        let headers = ["host": "127.0.0.1:\(Self.port)", "x-amz-date": SigV4.stamps(Date()).time, "x-amz-content-sha256": SigV4.emptyHash]
        for (name, value) in headers where name != "host" { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(SigV4.authorization(method: method, path: path, query: "", headers: headers, payload: SigV4.emptyHash,
                                             accessKey: Self.accessKey, secret: Self.secret, region: "us-east-1"),
                         forHTTPHeaderField: "Authorization")
        let (body, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw AirSCPError(.other, "\(method) \(path): \(status)", details: String(decoding: body, as: UTF8.self))
        }
    }

    /// Whether the lab's storage accepts a TCP connection.
    static func isUp() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }
}
