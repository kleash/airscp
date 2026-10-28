import CryptoKit
import Foundation
import Testing
@testable import AirSCPCore

// S3-compatible storage end to end: the lab's Versity S3 Gateway (testenv/docker-compose.yml, service s3), through the
// same Session and transfer queue as the app: browse, upload and download folders, rename, copy, delete, zip and
// extract, and a 100 MB multipart upload paused and resumed.

extension Lab {
    static let s3Port = 42284, s3AccessKey = "porter-s3", s3Secret = "porter-s3-secret"

    /// An S3 connection to the lab's storage, opening at `bucket`.
    static func s3(bucket: String = "") -> SSHHost {
        _ = TestEnvironment.isolated
        var host = SSHHost(label: "Lab storage")
        host.s3 = S3Settings(endpoint: "http://127.0.0.1:\(s3Port)", region: "us-east-1", accessKeyID: s3AccessKey, bucket: bucket)
        Keychain.setPassword(s3Secret, for: host.id)
        return host
    }
}

@Suite(.enabled(if: Lab.enabled, "Docker lab: AIRSCP_DOCKER=1 ./test.sh"), .serialized)
struct LabS3Tests {
    /// A connected session, in a new bucket of its own (made with a plain CreateBucket: AirSCP makes no buckets),
    /// emptied and removed by `done`.
    private func storage() async throws -> (session: Session, bucket: String, done: () async -> Void) {
        let bucket = "lab-" + UUID().uuidString.prefix(8).lowercased()
        let session = Session(host: Lab.s3(bucket: bucket), jump: nil, askpass: try AskpassServer(helperPath: TestEnvironment.airscpBinary))
        session.s3?.credentials = S3Client.Credentials(accessKeyID: Lab.s3AccessKey, secret: Lab.s3Secret)
        _ = try await session.s3?.send(S3Client.Request(method: "PUT", bucket: bucket))
        try await session.connect()
        return (session, bucket, {
            if let keys = try? await session.s3?.list(bucket, prefix: "", delimiter: nil).objects.map(\.key), !keys.isEmpty {
                try? await session.s3?.delete(bucket, keys: keys)
            }
            _ = try? await session.s3?.send(S3Client.Request(method: "DELETE", bucket: bucket))
            await session.disconnect()
        })
    }

    private func finished(_ queue: TransferQueue, _ id: UUID, timeout: TimeInterval = 300) async -> TransferJob? {
        _ = await eventually(timeout: timeout) { queue.jobs.first { $0.id == id }?.status.isFinished == true }
        return queue.jobs.first { $0.id == id }
    }

    @Test func browseTransferRenameCopyDeleteAndZip() async throws {
        let (session, bucket, done) = try await storage()
        #expect(try await session.list("/").contains { $0.name == bucket })
        let local = try scratch()
        try FileManager.default.createDirectory(atPath: local + "/tree/sub", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: local + "/tree/empty", withIntermediateDirectories: true)
        try write("one", to: local + "/tree/one.txt")
        try write("ünïcode and spaces", to: local + "/tree/sub/name with spaces+plus.txt")
        let queue = session.transfers
        queue.verifiesTransfers = true
        let up = queue.upload(local + "/tree", to: "/\(bucket)/tree", isFolder: true)
        #expect(await finished(queue, up)?.status == .done)
        #expect(try await session.list("/\(bucket)/tree").map(\.name).sorted() == ["empty", "one.txt", "sub"])
        #expect(try await session.list("/\(bucket)/tree/sub").map(\.name) == ["name with spaces+plus.txt"])
        let back = try scratch()
        let down = queue.download("/\(bucket)/tree", to: back + "/tree", isFolder: true)
        #expect(await finished(queue, down)?.status == .done)
        #expect(read(back + "/tree/sub/name with spaces+plus.txt") == "ünïcode and spaces")
        #expect(FileManager.default.fileExists(atPath: back + "/tree/empty"))
        // A single file, checked against the storage's SHA-256.
        let file = queue.upload(local + "/tree/one.txt", to: "/\(bucket)/one.txt", isFolder: false)
        let checked = await finished(queue, file)
        #expect(checked?.status == .done)
        if case .verified? = checked?.checksum {} else { Issue.record("not verified: \(String(describing: checked?.checksum))") }
        // Rename, copy, move, delete (folders by prefix).
        try await session.rename("/\(bucket)/one.txt", to: "/\(bucket)/renamed.txt")
        try await session.copy("/\(bucket)/tree", to: "/\(bucket)/copy")
        try await session.move("/\(bucket)/copy", to: "/\(bucket)/moved")
        #expect(try await session.list("/\(bucket)").map(\.name).sorted() == ["moved", "renamed.txt", "tree"])
        #expect(try await session.readText("/\(bucket)/moved/sub/name with spaces+plus.txt") == "ünïcode and spaces")
        try await session.writeText("edited", to: "/\(bucket)/renamed.txt")
        #expect(try await session.readText("/\(bucket)/renamed.txt") == "edited")
        try await session.delete(try await session.list("/\(bucket)").filter { $0.name == "moved" })
        #expect(try await !session.exists("/\(bucket)/moved"))
        // Zip next to the items, then extract it into a new folder (its items' names are taken).
        let zip = queue.compress(["tree", "renamed.txt"], in: "/\(bucket)")
        #expect(await finished(queue, zip)?.status == .done)
        #expect(try await session.list("/\(bucket)").contains { $0.name == "Archive.zip" })
        let extract = queue.extract("Archive.zip", in: "/\(bucket)", newFolder: false)
        #expect(await finished(queue, extract)?.status == .done)
        #expect(try await session.readText("/\(bucket)/Archive/renamed.txt") == "edited")
        let archive = queue.downloadArchive(["tree"], in: "/\(bucket)", to: back + "/tree.zip", extract: false)
        #expect(await finished(queue, archive)?.status == .done)
        #expect(try await run(["/usr/bin/unzip", "-l", back + "/tree.zip"]).output.contains("one.txt"))
        // A link that works without keys.
        let link = try await session.presignS3("/\(bucket)/renamed.txt", expires: 600)
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: link)
        #expect((response as? HTTPURLResponse)?.statusCode == 200 && data == Data("edited".utf8))
        await done()
    }

    /// A 100 MB file goes as a multipart upload: paused after some parts, resumed, it sends only the rest; downloaded
    /// with a pause half-way, it continues with Range.
    @Test func aBigUploadPausesAndResumesInParts() async throws {
        let (session, bucket, done) = try await storage()
        let local = try scratch()
        try writeRandom(bytes: 100_000_000, to: local + "/big.bin")
        let queue = session.transfers
        queue.bandwidthLimit = 40 * 8 * 1024  // 40 MB/s: about 2.5 s for the whole
        let id = queue.upload(local + "/big.bin", to: "/\(bucket)/big.bin", isFolder: false)
        #expect(await eventually { (queue.jobs.first { $0.id == id }?.progress.bytes ?? 0) > 40_000_000 })
        queue.pause([id])
        await queue.waitUntilIdle()
        #expect(queue.jobs.first { $0.id == id }?.status == .paused)
        #expect(session.s3?.keepsUpload(of: id) == true)
        queue.bandwidthLimit = nil
        queue.verifiesTransfers = true
        queue.resume([id])
        let uploaded = await finished(queue, id)
        #expect(uploaded?.status == .done)
        #expect(uploaded?.resumed == true)
        if case .verified? = uploaded?.checksum {} else { Issue.record("the parts' SHA-256 didn't verify: \(String(describing: uploaded?.checksum))") }
        #expect(try await session.list("/\(bucket)").first { $0.name == "big.bin" }?.size == 100_000_000)
        queue.verifiesTransfers = false
        queue.bandwidthLimit = 40 * 8 * 1024
        let download = queue.download("/\(bucket)/big.bin", to: local + "/copy.bin", isFolder: false)
        let partial = RemotePath.join(local, TransferQueue.partName(download))
        #expect(await eventually { (TransferQueue.localSize(partial) ?? 0) > 30_000_000 })
        queue.pause([download])
        await queue.waitUntilIdle()
        #expect(queue.jobs.first { $0.id == download }?.status == .paused)
        queue.bandwidthLimit = nil
        queue.resume([download])
        let downloaded = await finished(queue, download)
        #expect(downloaded?.status == .done)
        #expect(downloaded?.resumed == true)
        #expect(FileManager.default.contentsEqual(atPath: local + "/copy.bin", andPath: local + "/big.bin"))
        await done()
    }
}
