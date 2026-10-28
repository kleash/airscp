import CryptoKit
import Darwin
import Foundation
import Testing
@testable import AirSCPCore

// S3 and S3-compatible storage: SigV4 against AWS's own examples, and the client against an S3 service in the test
// process that checks every request's signature (listings, transfers, multipart, Range resume, deletes, copies,
// presigned links, errors, zips).

/// An S3 service in the test process (path-style, 127.0.0.1): buckets in memory, every request's SigV4 signature (or
/// a presigned URL's) checked; a request that doesn't verify gets 403 SignatureDoesNotMatch and is counted.
final class TestS3 {
    struct Object {
        var data: Data
        var modified = Date()
        var checksum: String?
        var contentType = "application/octet-stream"
        var metadata: [String: String] = [:]
        /// The sizes of the parts it was uploaded in.
        var parts: [Int] = []
        var etag: String { "\"" + Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined() + "\"" }
    }

    struct Upload {
        let bucket: String
        let key: String
        let checksums: Bool
        var parts: [Int: (data: Data, checksum: String?)] = [:]
    }

    static let accessKey = "AKIDAIRSCPTEST", secret = "airscp/Test+Secret/Key"
    let port: Int
    /// "METHOD /path?query" of each request, as it came.
    let requests = Recorder<String>()
    /// Requests whose signature didn't verify.
    let badSignatures = Recorder<String>()
    /// The Range header of each GET that had one.
    let ranges = Recorder<String>()
    /// Objects per ListObjectsV2 page.
    var pageSize = 1000
    /// ListBuckets is refused (a key for one bucket).
    var listBucketsDenied = false
    /// Every request is refused as RequestTimeTooSkewed.
    var skewed = false
    /// SHA-256 checksum headers are refused (NotImplemented), as by some S3-compatible services.
    var refusesChecksums = false
    /// Bodies go out at about this many bytes a second (a slow network), so that a download lasts long enough to pause.
    var bytesPerSecond: Int?
    private let listener: Int32
    private let lock = NSLock()
    private var buckets: [String: [String: Object]] = [:]
    private var uploads: [String: Upload] = [:]
    private var stopped = false
    private var connections: Set<Int32> = []

    init(buckets names: [String] = ["bucket"]) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound, listen(fd, 64) == 0 else {
            close(fd)
            throw AirSCPError(.other, "the test S3 service can't listen")
        }
        listener = fd
        port = Int(UInt16(bigEndian: address.sin_port))
        for name in names { buckets[name] = [:] }
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    deinit { stop() }

    func stop() {
        let first = lock.locked { () -> Bool in
            defer { stopped = true }
            return !stopped
        }
        if first {
            shutdown(listener, SHUT_RDWR)
            close(listener)
            lock.locked { connections.forEach { shutdown($0, SHUT_RDWR) } }
        }
    }

    var endpoint: String { "http://127.0.0.1:\(port)" }

    /// A saved S3 connection to this service (path style, as for any endpoint at an IP address), its secret in the
    /// tests' Keychain.
    func host(bucket: String = "", secret: String = TestS3.secret, accessKey: String = TestS3.accessKey) -> SSHHost {
        _ = TestEnvironment.isolated
        var host = SSHHost(label: "Test storage")
        host.s3 = S3Settings(endpoint: endpoint, region: "us-east-1", accessKeyID: accessKey, bucket: bucket)
        Keychain.setPassword(secret, for: host.id)
        return host
    }

    func put(_ bucket: String, _ key: String, _ data: Data, checksum: Bool = false, modified: Date = Date()) {
        let digest = checksum ? Data(SHA256.hash(data: data)).base64EncodedString() : nil
        lock.locked { buckets[bucket, default: [:]][key] = Object(data: data, modified: modified, checksum: digest) }
    }

    func object(_ bucket: String, _ key: String) -> Object? { lock.locked { buckets[bucket]?[key] } }

    func keys(_ bucket: String) -> [String] { lock.locked { (buckets[bucket] ?? [:]).keys.sorted() } }

    var openUploads: Int { lock.locked { uploads.count } }

    /// The requests of a kind: "PUT", "POST /b?delete"…
    func count(_ prefix: String, containing: String = "") -> Int {
        requests.all.filter { $0.hasPrefix(prefix) && (containing.isEmpty || $0.contains(containing)) }.count
    }

    // MARK: HTTP

    private func acceptLoop() {
        while true {
            let fd = accept(listener, nil, nil)
            if fd < 0 {
                if lock.locked({ stopped }) { return }
                continue
            }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            lock.locked { _ = connections.insert(fd) }
            Thread.detachNewThread { [self] in serve(fd) }
        }
    }

    private func serve(_ fd: Int32) {
        defer {
            lock.locked { _ = connections.remove(fd) }
            close(fd)
        }
        var buffer = Data()
        func fill() -> Bool {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return false }
            buffer.append(contentsOf: chunk[0..<count])
            return true
        }
        while !lock.locked({ stopped }) {
            var end = buffer.range(of: Data("\r\n\r\n".utf8))
            while end == nil {
                guard fill() else { return }
                end = buffer.range(of: Data("\r\n\r\n".utf8))
            }
            let head = String(decoding: buffer[buffer.startIndex..<end!.lowerBound], as: UTF8.self)
            buffer = Data(buffer[end!.upperBound...])
            let lines = head.components(separatedBy: "\r\n")
            let words = lines[0].split(separator: " ")
            guard words.count >= 2 else { return }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["content-length"] ?? "0") ?? 0
            while buffer.count < length { guard fill() else { return } }
            let body = Data(buffer.prefix(length))
            buffer = Data(buffer.dropFirst(length))
            let method = String(words[0]), target = String(words[1])
            requests.append(method + " " + target)
            if let range = headers["range"] { ranges.append(range) }
            let (status, responseHeaders, responseBody) = handle(method, target, headers, body)
            var response = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Status")\r\n"
            var all = responseHeaders
            if all["Content-Length"] == nil { all["Content-Length"] = String(responseBody.count) }
            for (name, value) in all { response += "\(name): \(value)\r\n" }
            var data = Data((response + "\r\n").utf8)
            if method != "HEAD" { data.append(responseBody) }
            let chunk = lock.locked { bytesPerSecond }.map { max(1, $0 / 20) } ?? data.count
            for start in stride(from: 0, to: data.count, by: max(1, chunk)) {
                let piece = data.subdata(in: start..<min(data.count, start + chunk))
                let sent = piece.withUnsafeBytes { write(fd, $0.baseAddress, piece.count) }
                if sent != piece.count { return }
                if chunk < data.count { usleep(50_000) }
            }
        }
    }

    private static let reasons = [200: "OK", 204: "No Content", 206: "Partial Content", 400: "Bad Request", 403: "Forbidden",
                                  404: "Not Found", 412: "Precondition Failed", 501: "Not Implemented"]

    typealias Response = (Int, [String: String], Data)

    private static func error(_ status: Int, _ code: String, _ message: String = "") -> Response {
        (status, ["Content-Type": "application/xml"],
         Data("<?xml version=\"1.0\" encoding=\"UTF-8\"?><Error><Code>\(code)</Code><Message>\(message)</Message></Error>".utf8))
    }

    private static func xml(_ body: String) -> Response {
        (200, ["Content-Type": "application/xml"],
         Data(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + body).utf8))
    }

    private static func decode(_ text: Substring) -> String { String(text).removingPercentEncoding ?? String(text) }

    /// The SigV4 check, as S3 makes it: nil when the request verifies, else the error code.
    private func verify(_ method: String, path: String, query: [(String, String)], headers: [String: String], body: Data) -> String? {
        if skewed { return "RequestTimeTooSkewed" }
        let canonicalPath = SigV4.encode(path, slash: true)
        if let signature = query.first(where: { $0.0 == "X-Amz-Signature" })?.1 {
            let parameters = Dictionary(query, uniquingKeysWith: { first, _ in first })
            let credential = (parameters["X-Amz-Credential"] ?? "").split(separator: "/").map(String.init)
            guard credential.count == 5, credential[0] == Self.accessKey, let time = parameters["X-Amz-Date"] else {
                return "InvalidAccessKeyId"
            }
            let request = SigV4.canonicalRequest(method: method, path: canonicalPath,
                                                 query: SigV4.canonicalQuery(query.filter { $0.0 != "X-Amz-Signature" }),
                                                 headers: headers, signed: ["host"], payload: "UNSIGNED-PAYLOAD")
            let expected = SigV4.signature(SigV4.stringToSign(request, time: time, scope: credential[1...].joined(separator: "/")),
                                           secret: Self.secret, day: credential[1], region: credential[2])
            return expected == signature ? nil : "SignatureDoesNotMatch"
        }
        guard let authorization = headers["authorization"], authorization.hasPrefix("AWS4-HMAC-SHA256 ") else { return "AccessDenied" }
        var fields: [String: String] = [:]
        for part in authorization.dropFirst("AWS4-HMAC-SHA256 ".count).split(separator: ",") {
            let pair = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 { fields[pair[0]] = pair[1] }
        }
        let credential = (fields["Credential"] ?? "").split(separator: "/").map(String.init)
        guard credential.count == 5, credential[0] == Self.accessKey else { return "InvalidAccessKeyId" }
        guard let time = headers["x-amz-date"], time.hasPrefix(credential[1]), let payload = headers["x-amz-content-sha256"],
              let signed = fields["SignedHeaders"]?.split(separator: ";").map(String.init), signed.contains("host"),
              signed.contains("x-amz-date") else { return "AccessDenied" }
        if payload != "UNSIGNED-PAYLOAD" && payload != SigV4.hex(SHA256.hash(data: body)) { return "XAmzContentSHA256Mismatch" }
        let request = SigV4.canonicalRequest(method: method, path: canonicalPath, query: SigV4.canonicalQuery(query), headers: headers,
                                             signed: signed, payload: payload)
        let expected = SigV4.signature(SigV4.stringToSign(request, time: time, scope: credential[1...].joined(separator: "/")),
                                       secret: Self.secret, day: credential[1], region: credential[2])
        return expected == fields["Signature"] ? nil : "SignatureDoesNotMatch"
    }

    private func handle(_ method: String, _ target: String, _ headers: [String: String], _ body: Data) -> Response {
        let split = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = Self.decode(split[0])
        let query: [(String, String)] = split.count < 2 || split[1].isEmpty ? [] : split[1].split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            return (Self.decode(parts[0]), parts.count > 1 ? Self.decode(parts[1]) : "")
        }
        if let code = verify(method, path: path, query: query, headers: headers, body: body) {
            if code == "SignatureDoesNotMatch" { badSignatures.append(method + " " + target) }
            return Self.error(code == "InvalidAccessKeyId" || code == "SignatureDoesNotMatch" || code == "AccessDenied" ? 403 : 400, code,
                              code == "RequestTimeTooSkewed" ? "The difference between the request time and the current time is too large." : "")
        }
        let parameters = Dictionary(query, uniquingKeysWith: { first, _ in first })
        let parts = path.dropFirst().split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        let bucket = parts.first.map(String.init) ?? "", key = parts.count > 1 ? String(parts[1]) : ""
        return lock.locked { () -> Response in
            if bucket.isEmpty {
                guard !listBucketsDenied else { return Self.error(403, "AccessDenied", "Access Denied") }
                return Self.xml("<ListAllMyBucketsResult><Buckets>" + buckets.keys.sorted().map {
                    "<Bucket><Name>\($0)</Name><CreationDate>2024-01-02T03:04:05.000Z</CreationDate></Bucket>"
                }.joined() + "</Buckets></ListAllMyBucketsResult>")
            }
            guard buckets[bucket] != nil else { return Self.error(404, "NoSuchBucket", "The specified bucket does not exist") }
            let checksumHeader = headers["x-amz-checksum-sha256"]
            if refusesChecksums && (checksumHeader != nil || headers["x-amz-checksum-algorithm"] != nil) {
                return Self.error(501, "NotImplemented", "SHA-256 checksums are not implemented")
            }
            if let checksumHeader, checksumHeader != Data(SHA256.hash(data: body)).base64EncodedString(), headers["x-amz-copy-source"] == nil {
                return Self.error(400, "BadDigest", "The SHA256 you specified did not match the calculated checksum.")
            }
            switch (method, key.isEmpty) {
            case ("GET", true) where parameters["list-type"] == "2":
                return list(bucket, parameters)
            case ("HEAD", true):
                return (200, [:], Data())
            case ("POST", true) where parameters["delete"] != nil:
                guard headers["content-md5"] == Data(Insecure.MD5.hash(data: body)).base64EncodedString() else {
                    return Self.error(400, "InvalidDigest")
                }
                let keys = (XMLTree.parse(body)?.all("Object") ?? []).compactMap { $0.value("Key") }
                for key in keys { buckets[bucket]?[key] = nil }
                return Self.xml("<DeleteResult></DeleteResult>")
            case ("POST", false) where parameters["uploads"] != nil:
                let id = UUID().uuidString
                uploads[id] = Upload(bucket: bucket, key: key, checksums: headers["x-amz-checksum-algorithm"] == "SHA256")
                return Self.xml("<InitiateMultipartUploadResult><Bucket>\(bucket)</Bucket><Key>\(XMLTree.escape(key))</Key>"
                                + "<UploadId>\(id)</UploadId></InitiateMultipartUploadResult>")
            case ("PUT", false) where parameters["uploadId"] != nil:
                guard let id = parameters["uploadId"], uploads[id] != nil, let number = parameters["partNumber"].flatMap(Int.init) else {
                    return Self.error(404, "NoSuchUpload")
                }
                var data = body
                if let source = headers["x-amz-copy-source"] {
                    guard let object = copySource(source) else { return Self.error(404, "NoSuchKey") }
                    let range = (headers["x-amz-copy-source-range"] ?? "").dropFirst("bytes=".count).split(separator: "-").compactMap { Int($0) }
                    data = range.count == 2 ? object.data.subdata(in: range[0]..<(range[1] + 1)) : object.data
                }
                let checksum = Data(SHA256.hash(data: data)).base64EncodedString()
                uploads[id]?.parts[number] = (data, checksum)
                let etag = Object(data: data).etag
                if headers["x-amz-copy-source"] != nil {
                    return Self.xml("<CopyPartResult><ETag>\(XMLTree.escape(etag))</ETag><ChecksumSHA256>\(checksum)</ChecksumSHA256></CopyPartResult>")
                }
                return (200, ["ETag": etag], Data())
            case ("GET", false) where parameters["uploadId"] != nil:
                guard let upload = parameters["uploadId"].flatMap({ uploads[$0] }) else { return Self.error(404, "NoSuchUpload") }
                return Self.xml("<ListPartsResult><IsTruncated>false</IsTruncated>" + upload.parts.keys.sorted().map { number in
                    let part = upload.parts[number]!
                    return "<Part><PartNumber>\(number)</PartNumber><ETag>\(XMLTree.escape(Object(data: part.data).etag))</ETag>"
                        + "<Size>\(part.data.count)</Size>" + (part.checksum.map { "<ChecksumSHA256>\($0)</ChecksumSHA256>" } ?? "") + "</Part>"
                }.joined() + "</ListPartsResult>")
            case ("POST", false) where parameters["uploadId"] != nil:
                guard let id = parameters["uploadId"], let upload = uploads[id] else { return Self.error(404, "NoSuchUpload") }
                let numbers = (XMLTree.parse(body)?.all("Part") ?? []).compactMap { $0.value("PartNumber").flatMap(Int.init) }
                guard !numbers.isEmpty, numbers.allSatisfy({ upload.parts[$0] != nil }) else { return Self.error(400, "InvalidPart") }
                var object = Object(data: numbers.reduce(Data()) { $0 + upload.parts[$1]!.data })
                object.parts = numbers.map { upload.parts[$0]!.data.count }
                if upload.checksums {
                    let digests = numbers.reduce(Data()) { $0 + Data(SHA256.hash(data: upload.parts[$1]!.data)) }
                    object.checksum = Data(SHA256.hash(data: digests)).base64EncodedString() + "-\(numbers.count)"
                }
                buckets[bucket]?[key] = object
                uploads[id] = nil
                return Self.xml("<CompleteMultipartUploadResult><Key>\(XMLTree.escape(key))</Key><ETag>\"x\"</ETag></CompleteMultipartUploadResult>")
            case ("DELETE", false) where parameters["uploadId"] != nil:
                uploads[parameters["uploadId"]!] = nil
                return (204, [:], Data())
            case ("PUT", false):
                if let source = headers["x-amz-copy-source"] {
                    guard let object = copySource(source) else { return Self.error(404, "NoSuchKey", "The specified key does not exist.") }
                    buckets[bucket]?[key] = object
                    return Self.xml("<CopyObjectResult><ETag>\(XMLTree.escape(object.etag))</ETag></CopyObjectResult>")
                }
                var object = Object(data: body, checksum: checksumHeader, contentType: headers["content-type"] ?? "application/octet-stream")
                for (name, value) in headers where name.hasPrefix("x-amz-meta-") { object.metadata[name] = value }
                buckets[bucket]?[key] = object
                return (200, ["ETag": object.etag], Data())
            case ("GET", false), ("HEAD", false):
                guard let object = buckets[bucket]?[key] else { return Self.error(404, "NoSuchKey", "The specified key does not exist.") }
                if let match = headers["if-match"], match != object.etag { return Self.error(412, "PreconditionFailed") }
                var answer: [String: String] = ["ETag": object.etag, "Content-Type": object.contentType,
                                                "Last-Modified": Self.httpDate(object.modified)]
                for (name, value) in object.metadata { answer[name] = value }
                if headers["x-amz-checksum-mode"] == "ENABLED", let checksum = object.checksum { answer["x-amz-checksum-sha256"] = checksum }
                if let number = parameters["partNumber"].flatMap(Int.init), number <= object.parts.count {
                    answer["Content-Length"] = String(object.parts[number - 1])
                    answer["x-amz-mp-parts-count"] = String(object.parts.count)
                    return (206, answer, Data())
                }
                var data = object.data
                var status = 200
                if let range = headers["range"], let start = Int(range.dropFirst("bytes=".count).prefix { $0 != "-" }) {
                    data = start < data.count ? data.subdata(in: start..<data.count) : Data()
                    status = 206
                }
                answer["Content-Length"] = String(data.count)
                return (status, answer, data)
            default:
                return Self.error(400, "NotImplemented", "\(method) \(target)")
            }
        }
    }

    private func copySource(_ source: String) -> Object? {
        let path = Self.decode(source[...])
        let parts = path.dropFirst(path.hasPrefix("/") ? 1 : 0).split(separator: "/", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        return buckets[String(parts[0])]?[String(parts[1])]
    }

    /// ListObjectsV2: the keys and common prefixes in order, `pageSize` at a time (the token is where the next page starts).
    private func list(_ bucket: String, _ parameters: [String: String]) -> Response {
        let prefix = parameters["prefix"] ?? "", delimiter = parameters["delimiter"]
        var items: [(name: String, folder: Bool)] = []
        for key in (buckets[bucket] ?? [:]).keys.sorted() where key.hasPrefix(prefix) {
            let rest = key.dropFirst(prefix.count)
            if let delimiter, let index = rest.range(of: delimiter) {
                let common = prefix + rest[..<index.upperBound]
                if items.last?.name != common { items.append((common, true)) }
            } else {
                items.append((key, false))
            }
        }
        let start = Int(parameters["continuation-token"] ?? "0") ?? 0
        let size = min(pageSize, Int(parameters["max-keys"] ?? "") ?? 1000)
        let page = items.dropFirst(start).prefix(size)
        let more = start + page.count < items.count
        var xml = "<ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Name>\(bucket)</Name>"
            + "<Prefix>\(XMLTree.escape(prefix))</Prefix><KeyCount>\(page.count)</KeyCount><IsTruncated>\(more)</IsTruncated>"
        if more { xml += "<NextContinuationToken>\(start + page.count)</NextContinuationToken>" }
        for item in page {
            if item.folder {
                xml += "<CommonPrefixes><Prefix>\(XMLTree.escape(item.name))</Prefix></CommonPrefixes>"
            } else {
                let object = buckets[bucket]![item.name]!
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                xml += "<Contents><Key>\(XMLTree.escape(item.name))</Key><LastModified>\(formatter.string(from: object.modified))</LastModified>"
                    + "<ETag>\(XMLTree.escape(object.etag))</ETag><Size>\(object.data.count)</Size><StorageClass>STANDARD</StorageClass></Contents>"
            }
        }
        return Self.xml(xml + "</ListBucketResult>")
    }

    private static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }
}

/// A connected Session for `server` (with `bucket` to open at).
func s3Session(_ server: TestS3, bucket: String = "", secret: String = TestS3.secret) async throws -> Session {
    let session = Session(host: server.host(bucket: bucket, secret: secret), jump: nil,
                          askpass: try AskpassServer(helperPath: TestEnvironment.airscpBinary))
    try await session.connect()
    return session
}

private func job(_ id: UUID, in queue: TransferQueue) -> TransferJob? { queue.jobs.first { $0.id == id } }

private func finished(_ queue: TransferQueue, _ id: UUID) async -> TransferJob? {
    _ = await eventually { job(id, in: queue)?.status.isFinished == true }
    return job(id, in: queue)
}

@Suite(.serialized) struct S3Tests {
    // MARK: Signatures

    /// AWS's examples for S3 (Signature Version 4, a payload in a single chunk; and a presigned URL), and the general
    /// test suite's get-vanilla, byte for byte.
    @Test func signaturesMatchAWSsOwnExamples() {
        let key = "AKIAIOSFODNN7EXAMPLE", secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
        let time = "20130524T000000Z", empty = SigV4.emptyHash
        // GET Object, with a Range.
        var headers = ["host": "examplebucket.s3.amazonaws.com", "range": "bytes=0-9", "x-amz-content-sha256": empty, "x-amz-date": time]
        let canonical = SigV4.canonicalRequest(method: "GET", path: "/test.txt", query: "", headers: headers,
                                               signed: headers.keys.sorted(), payload: empty)
        #expect(canonical == "GET\n/test.txt\n\nhost:examplebucket.s3.amazonaws.com\nrange:bytes=0-9\nx-amz-content-sha256:\(empty)\n"
                + "x-amz-date:20130524T000000Z\n\nhost;range;x-amz-content-sha256;x-amz-date\n\(empty)")
        let toSign = SigV4.stringToSign(canonical, time: time, scope: "20130524/us-east-1/s3/aws4_request")
        #expect(toSign.hasSuffix("\n7344ae5b7ee6c3e7e6b0fe0640412a37625d1fbfff95c48bbb2dc43964946972"))
        #expect(SigV4.authorization(method: "GET", path: "/test.txt", query: "", headers: headers, payload: empty, accessKey: key,
                                    secret: secret, region: "us-east-1").hasSuffix(
                                        "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"))
        // PUT Object.
        let body = SigV4.hex(SHA256.hash(data: Data("Welcome to Amazon S3.".utf8)))
        headers = ["date": "Fri, 24 May 2013 00:00:00 GMT", "host": "examplebucket.s3.amazonaws.com", "x-amz-content-sha256": body,
                   "x-amz-date": time, "x-amz-storage-class": "REDUCED_REDUNDANCY"]
        #expect(SigV4.authorization(method: "PUT", path: "/" + SigV4.encode("test$file.text", slash: true), query: "", headers: headers,
                                    payload: body, accessKey: key, secret: secret, region: "us-east-1").hasSuffix(
                                        "Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"))
        // GET Bucket Lifecycle, and a listing (query strings).
        headers = ["host": "examplebucket.s3.amazonaws.com", "x-amz-content-sha256": empty, "x-amz-date": time]
        #expect(SigV4.authorization(method: "GET", path: "/", query: SigV4.canonicalQuery([("lifecycle", "")]), headers: headers,
                                    payload: empty, accessKey: key, secret: secret, region: "us-east-1").hasSuffix(
                                        "Signature=fea454ca298b7da1c68078a5d1bdbfbbe0d65c699e0f91ac7a200a0136783543"))
        #expect(SigV4.authorization(method: "GET", path: "/", query: SigV4.canonicalQuery([("prefix", "J"), ("max-keys", "2")]),
                                    headers: headers, payload: empty, accessKey: key, secret: secret, region: "us-east-1").hasSuffix(
                                        "Signature=34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7"))
        // A presigned URL, valid for a day.
        let date = DateComponents(calendar: Calendar(identifier: .gregorian), timeZone: TimeZone(identifier: "UTC"), year: 2013,
                                  month: 5, day: 24).date!
        #expect(SigV4.presignedQuery(path: "/test.txt", host: "examplebucket.s3.amazonaws.com", accessKey: key, secret: secret,
                                     token: nil, region: "us-east-1", date: date, expires: 86400).hasSuffix(
                                        "X-Amz-Signature=aeeed9bbccd4d02ee5c0109b86d86835f995330da4c265957d157751f604d404"))
        // The general test suite's get-vanilla (another service and key).
        let vanilla = SigV4.authorization(method: "GET", path: "/", query: "", headers: ["host": "example.amazonaws.com",
                                                                                          "x-amz-date": "20150830T123600Z"],
                                          payload: empty, accessKey: "AKIDEXAMPLE",
                                          secret: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY", region: "us-east-1", service: "service")
        #expect(vanilla == "AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, "
                + "SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")
        // Encoding: unreserved characters stay, everything else (UTF-8 bytes) is %XX; "/" only in paths.
        #expect(SigV4.encode("a b+c/é~_-.") == "a%20b%2Bc%2F%C3%A9~_-.")
        #expect(SigV4.encode("a b/c", slash: true) == "a%20b/c")
    }

    /// Amazon S3's addresses (the bucket in the host name, its region in the host), and path style where the host
    /// name can't hold the bucket.
    @Test func addressesForAmazonS3AndOtherServices() {
        let aws = S3Client(settings: S3Settings(), name: "aws")
        #expect(aws.url(for: .init(bucket: "photos", key: "2024/a b.jpg"), region: "eu-west-1").absoluteString
                == "https://photos.s3.eu-west-1.amazonaws.com/2024/a%20b.jpg")
        #expect(aws.url(for: .init(bucket: "my.site", key: "x"), region: "us-east-1").absoluteString
                == "https://s3.us-east-1.amazonaws.com/my.site/x")
        #expect(aws.url(for: .init(), region: "us-east-1").absoluteString == "https://s3.us-east-1.amazonaws.com/")
        let minio = S3Client(settings: S3Settings(endpoint: "https://minio.example.com:443", pathStyle: true), name: "minio")
        #expect(minio.url(for: .init(bucket: "b", key: "k", query: [("list-type", "2"), ("prefix", "a/")]), region: "us-east-1")
                .absoluteString == "https://minio.example.com/b/k?list-type=2&prefix=a%2F")
        let r2 = S3Client(settings: S3Settings(endpoint: "abc.r2.cloudflarestorage.com", region: "auto"), name: "r2")
        #expect(r2.url(for: .init(bucket: "b", key: ""), region: "auto").absoluteString == "https://b.abc.r2.cloudflarestorage.com/")
        #expect(r2.region(for: "b") == "auto")
        #expect(aws.partSize(for: 100 << 30) >= (100 << 30) / 10_000)
        #expect(aws.partSize(for: 1 << 20) == aws.partSize)
    }

    /// Import from ~/.aws: profiles with a key of their own (credentials and config merged, a nested s3 section's
    /// endpoint and addressing), and why the others can't be used.
    @Test func awsProfilesWithKeysImportAndTheOthersSayWhy() throws {
        let folder = try scratch()
        try write("""
            [default]
            aws_access_key_id = AKIDDEFAULT
            aws_secret_access_key = secret/default
            # a comment
            [work]
            aws_access_key_id=AKIDWORK
            aws_secret_access_key=secret-work
            aws_session_token = token-work
            """, to: folder + "/credentials")
        try write("""
            [default]
            region = eu-central-1
            [profile work]
            region = auto
            s3 =
              endpoint_url = https://abc.r2.cloudflarestorage.com
              addressing_style = path
            [profile sso]
            sso_session = corp
            [profile tool]
            credential_process = /usr/local/bin/keys
            [profile role]
            role_arn = arn:aws:iam::123:role/x
            source_profile = default
            [sso-session corp]
            sso_start_url = https://example.awsapps.com/start
            """, to: folder + "/config")
        let profiles = Dictionary(uniqueKeysWithValues: AWSProfiles.profiles(in: folder).map { ($0.name, $0) })
        #expect(Set(profiles.keys) == ["default", "work", "sso", "tool", "role"])
        #expect(profiles["default"]?.problem == nil && profiles["default"]?.region == "eu-central-1"
                && profiles["default"]?.secret == "secret/default" && profiles["default"]?.endpoint == "")
        let work = try #require(profiles["work"])
        #expect(work.problem == nil && work.token == "token-work" && work.endpoint == "https://abc.r2.cloudflarestorage.com"
                && work.pathStyle && work.region == "auto")
        #expect(profiles["sso"]?.problem?.contains("single sign-on") == true)
        #expect(profiles["tool"]?.problem?.contains("credential_process") == true)
        #expect(profiles["role"]?.problem?.contains("role") == true)
        #expect(AWSProfiles.profiles(in: folder + "/nothing").isEmpty)
    }

    // MARK: Against the test service

    @Test func connectingChecksTheKeysAndListsBucketsFoldersAndFiles() async throws {
        let server = try TestS3(buckets: ["bucket", "other"])
        defer { server.stop() }
        server.pageSize = 2
        for key in ["a.txt", "dir/", "dir/x.txt", "dir/sub/y.txt", "empty/", "space name.txt", "plus+name", "ünï.txt", "..", "a//b"] {
            server.put("bucket", key, Data(key.utf8))
        }
        let session = try await s3Session(server)
        #expect(session.state == .connected)
        #expect(session.capabilities.home == "/")
        #expect(!session.capabilities.shell)
        #expect(try await session.list("/").map(\.name) == ["bucket", "other"])
        let root = try await session.list("/bucket")
        #expect(Set(root.map(\.name)) == ["a.txt", "dir", "empty", "space name.txt", "plus+name", "ünï.txt", "a"])
        #expect(root.filter { $0.kind == .directory }.map(\.name).sorted() == ["a", "dir", "empty"])
        #expect(root.first { $0.name == "a.txt" }?.size == 5)
        #expect(try await session.list("/bucket/dir").map(\.name).sorted() == ["sub", "x.txt"])
        #expect(try await session.list("/bucket/empty").isEmpty)
        // A folder with nothing in it and no marker isn't there.
        await #expect(throws: AirSCPError.self) { try await session.list("/bucket/nothing") }
        #expect(try await session.exists("/bucket/dir/sub"))
        #expect(try await session.exists("/bucket/a.txt"))
        #expect(try await !session.exists("/bucket/nothing"))
        #expect(server.count("GET /bucket/?", containing: "continuation-token") > 0, "listings go page by page")
        #expect(server.badSignatures.all.isEmpty, "every request's signature verifies: \(server.badSignatures.all)")
        // A key for one bucket: the buckets aren't listed, the bucket to open at is.
        server.listBucketsDenied = true
        let one = try await s3Session(server, bucket: "bucket")
        #expect(one.capabilities.home == "/bucket")
        #expect(try await one.list("/").map(\.name) == ["bucket"])
        await #expect(throws: AirSCPError.self) { try await s3Session(server) }
    }

    @Test func errorsSayWhatToDo() async throws {
        let server = try TestS3()
        defer { server.stop() }
        func message(_ work: () async throws -> Void) async -> String {
            do {
                try await work()
                return ""
            } catch {
                return (error as? AirSCPError)?.message ?? "\(error)"
            }
        }
        #expect(await message { _ = try await s3Session(server, secret: "wrong") } .contains("secret key doesn't match the access key"))
        let unknown = Session(host: server.host(accessKey: "AKIDNOBODY"), jump: nil,
                              askpass: try AskpassServer(helperPath: TestEnvironment.airscpBinary))
        #expect(await message { try await unknown.connect() }.contains("doesn't know this access key"))
        let session = try await s3Session(server)
        #expect(await message { _ = try await session.list("/missing") }.contains("bucket doesn't exist"))
        #expect(await message { try await session.fetch("/bucket/none.txt", to: URL(fileURLWithPath: try scratch() + "/x")) }
            .contains("doesn't exist"))
        server.skewed = true
        #expect(await message { _ = try await session.list("/bucket") }.contains("clock"))
        server.skewed = false
        #expect(await message { try await session.makeDirectory("/newbucket") }.contains("buckets"))
        server.stop()
        let gone = await message { _ = try await session.list("/bucket") }
        #expect(gone.contains("refused the connection") || gone.contains("can't be reached"), "\(gone)")
        var host = SSHHost(label: "No secret")
        host.s3 = S3Settings(endpoint: server.endpoint, accessKeyID: TestS3.accessKey)
        let noSecret = Session(host: host, jump: nil, askpass: try AskpassServer(helperPath: TestEnvironment.airscpBinary))
        #expect(await message { try await noSecret.connect() }.contains("secret access key isn't saved"))
        #expect(noSecret.state == .idle)
        // An app refuses plain http to a domain name (App Transport Security): said in plain words, with what to do.
        #expect(ErrorMapping.s3(URLError(.appTransportSecurityRequiresSecureConnection)).message.contains("make the endpoint https://"))
    }

    @Test func fileOperationsFoldersRenameCopyMoveAndDelete() async throws {
        let server = try TestS3()
        defer { server.stop() }
        let session = try await s3Session(server)
        try await session.makeDirectory("/bucket/new")
        #expect(server.keys("bucket") == ["new/"])
        try await session.createFile("/bucket/new/a.txt")
        await #expect(throws: AirSCPError.self) { try await session.createFile("/bucket/new/a.txt") }
        try await session.writeText("hello", to: "/bucket/new/a.txt")
        #expect(try await session.readText("/bucket/new/a.txt") == "hello")
        try await session.rename("/bucket/new/a.txt", to: "/bucket/new/b.txt")
        #expect(server.keys("bucket") == ["new/", "new/b.txt"])
        // Folders go by prefix, their marker too.
        try await session.copy("/bucket/new", to: "/bucket/copy")
        try await session.move("/bucket/copy", to: "/bucket/moved")
        #expect(server.keys("bucket") == ["moved/", "moved/b.txt", "new/", "new/b.txt"])
        // Replace: the copy goes over what is there, and the rest of what was there goes.
        server.put("bucket", "moved/old.txt", Data("old".utf8))
        try await session.copy("/bucket/new", replacing: "/bucket/moved", folder: true, move: false)
        #expect(server.keys("bucket") == ["moved/", "moved/b.txt", "new/", "new/b.txt"])
        // A move over what is there: what was moved stays, though its source is gone by the time the rest goes.
        server.put("bucket", "other/b.txt", Data("other".utf8))
        try await session.copy("/bucket/other", replacing: "/bucket/moved", folder: true, move: true)
        #expect(server.keys("bucket") == ["moved/", "moved/b.txt", "new/", "new/b.txt"])
        #expect(try await session.readText("/bucket/moved/b.txt") == "other")
        let info = try await session.info(try await session.list("/bucket/new").first { $0.name == "b.txt" }!)
        #expect(info.size == 5)
        #expect(info.s3?.etag.isEmpty == false)
        #expect(info.s3?.storageClass == "STANDARD")
        let folder = try await session.info(try await session.list("/bucket").first { $0.name == "new" }!)
        #expect(folder.size == 5 && folder.itemCount == 1)
        // 2,500 objects: deleted 1,000 to a request.
        for index in 0..<2500 { server.put("bucket", "many/\(index)", Data()) }
        let deletes = server.count("POST /bucket/?delete")
        try await session.delete(try await session.list("/bucket").filter { $0.name == "many" || $0.name == "moved" })
        #expect(server.keys("bucket") == ["new/", "new/b.txt"])
        #expect(server.count("POST /bucket/?delete") - deletes == 3)
        // Find Files: names under the folder shown.
        let found = try await session.find("*.TXT", in: "/bucket")
        #expect(found.items.map(\.path) == ["/bucket/new/b.txt"])
        let link = try await session.presignS3("/bucket/new/b.txt", expires: 3600)
        let (data, response) = try await URLSession(configuration: .ephemeral).data(from: link)
        #expect((response as? HTTPURLResponse)?.statusCode == 200 && data == Data("hello".utf8), "\(link)")
        #expect(Session.s3URI("/bucket/new", folder: true) == "s3://bucket/new/")
        #expect(server.badSignatures.all.isEmpty, "\(server.badSignatures.all)")
    }

    @Test func uploadsAndDownloadsFilesAndFoldersThroughTheQueue() async throws {
        let server = try TestS3()
        defer { server.stop() }
        let session = try await s3Session(server)
        let local = try scratch()
        try FileManager.default.createDirectory(atPath: local + "/tree/sub/deeper", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: local + "/tree/empty", withIntermediateDirectories: true)
        try write("one", to: local + "/tree/one.txt")
        try write("two", to: local + "/tree/sub/two.log")
        try write("three", to: local + "/tree/sub/deeper/three.txt")
        try write("skip", to: local + "/tree/sub/skip.log")
        try write("single", to: local + "/single.txt")
        let queue = session.transfers
        queue.verifiesTransfers = true
        let file = queue.upload(local + "/single.txt", to: "/bucket/single.txt", isFolder: false)
        let checked = await finished(queue, file)
        #expect(checked?.status == .done)
        if case .verified? = checked?.checksum {} else { Issue.record("not verified: \(String(describing: checked?.checksum))") }
        #expect(server.object("bucket", "single.txt")?.checksum != nil, "the upload carried its SHA-256")
        let folder = queue.upload(local + "/tree", to: "/bucket/tree", isFolder: true, excluding: ["skip*"])
        #expect(await finished(queue, folder)?.status == .done)
        #expect(server.keys("bucket") == ["single.txt", "tree/empty/", "tree/one.txt", "tree/sub/deeper/three.txt", "tree/sub/two.log"])
        // Down again: a folder, and a file next to an existing one (Replace).
        let back = try scratch()
        try write("old", to: back + "/single.txt")
        let tree = queue.download("/bucket/tree", to: back + "/tree", isFolder: true)
        let single = queue.download("/bucket/single.txt", to: back + "/single.txt", isFolder: false, replacing: true)
        #expect(await finished(queue, tree)?.status == .done)
        #expect(await finished(queue, single)?.status == .done)
        #expect(read(back + "/single.txt") == "single")
        #expect(read(back + "/tree/sub/deeper/three.txt") == "three")
        #expect(FileManager.default.fileExists(atPath: back + "/tree/empty"))
        #expect(names(in: back).filter { $0.hasPrefix(".airscp-") }.isEmpty)
        // A folder upload that replaces: what isn't in the new one goes.
        try FileManager.default.removeItem(atPath: local + "/tree/sub")
        let replaced = queue.upload(local + "/tree", to: "/bucket/tree", isFolder: true, replacing: true)
        #expect(await finished(queue, replaced)?.status == .done)
        #expect(server.keys("bucket") == ["single.txt", "tree/empty/", "tree/one.txt"])
        #expect(server.badSignatures.all.isEmpty, "\(server.badSignatures.all)")
    }

    /// A link to a folder in an uploaded folder: the walk doesn't go into it, so it is named in the job's errors (an
    /// empty folder in its place would read as uploaded).
    @Test func aLinkToAFolderInAnUploadIsNamed() async throws {
        let server = try TestS3()
        defer { server.stop() }
        let session = try await s3Session(server)
        let local = try scratch()
        try FileManager.default.createDirectory(atPath: local + "/tree", withIntermediateDirectories: true)
        try write("one", to: local + "/tree/one.txt")
        try write("inside", to: local + "/elsewhere/inside.txt")
        try FileManager.default.createSymbolicLink(atPath: local + "/tree/linked", withDestinationPath: local + "/elsewhere")
        let job = session.transfers.upload(local + "/tree", to: "/bucket/tree", isFolder: true)
        let status = await finished(session.transfers, job)?.status
        guard case .completedWithErrors(let errors)? = status else {
            Issue.record("\(String(describing: status))")
            return
        }
        #expect(errors.contains("linked"), "\(errors)")
        #expect(server.keys("bucket") == ["tree/one.txt"])
    }

    /// A paused download continues with Range from what its part holds; a paused multipart upload continues with the
    /// parts the storage has (ListParts), and its SHA-256 of parts verifies; Cancel aborts an upload's parts.
    @Test func pausedTransfersContinueWhereTheyStopped() async throws {
        let server = try TestS3()
        defer { server.stop() }
        let session = try await s3Session(server)
        session.s3?.multipartThreshold = 1 << 20
        session.s3?.partSize = 1 << 20
        let queue = session.transfers
        queue.bandwidthLimit = 8 * 1024  // 1 MB/s
        let local = try scratch()
        try writeRandom(bytes: 3_500_000, to: local + "/big.bin")
        let upload = queue.upload(local + "/big.bin", to: "/bucket/big.bin", isFolder: false)
        #expect(await eventually { server.count("PUT /bucket/big.bin?partNumber") >= 2 })
        queue.pause([upload])
        await queue.waitUntilIdle()
        #expect(job(upload, in: queue)?.status == .paused)
        #expect(server.openUploads == 1, "the parts are kept for Resume")
        queue.bandwidthLimit = nil
        queue.verifiesTransfers = true
        queue.resume([upload])
        let uploaded = await finished(queue, upload)
        #expect(uploaded?.status == .done)
        #expect(uploaded?.resumed == true)
        #expect(server.count("GET /bucket/big.bin?uploadId") >= 1)
        #expect(server.count("PUT /bucket/big.bin?partNumber") <= 5, "parts that had arrived weren't sent again")
        #expect(server.object("bucket", "big.bin")?.data == FileManager.default.contents(atPath: local + "/big.bin"))
        if case .verified? = uploaded?.checksum {} else { Issue.record("not verified: \(String(describing: uploaded?.checksum))") }
        queue.verifiesTransfers = false
        // Down, paused half-way, continued with Range (the whole body would be in this Mac's buffers before a limit of
        // this Mac's own could hold it back: the service sends it slowly).
        server.bytesPerSecond = 1 << 20
        let download = queue.download("/bucket/big.bin", to: local + "/copy.bin", isFolder: false)
        let partial = RemotePath.join(local, TransferQueue.partName(download))
        #expect(await eventually { (TransferQueue.localSize(partial) ?? 0) > 500_000 })
        queue.pause([download])
        await queue.waitUntilIdle()
        #expect(job(download, in: queue)?.status == .paused)
        let kept = TransferQueue.localSize(partial) ?? 0
        #expect(kept > 0)
        server.bytesPerSecond = nil
        queue.resume([download])
        #expect(await finished(queue, download)?.status == .done)
        #expect(FileManager.default.contentsEqual(atPath: local + "/copy.bin", andPath: local + "/big.bin"))
        #expect(server.ranges.all.contains("bytes=\(kept)-"), "continued from \(kept): \(server.ranges.all)")
        // Cancel drops a multipart upload's parts (this Mac's speed limit holds an upload back).
        queue.bandwidthLimit = 8 * 1024
        let cancelled = queue.upload(local + "/big.bin", to: "/bucket/again.bin", isFolder: false)
        #expect(await eventually { server.count("PUT /bucket/again.bin?partNumber") >= 1 })
        queue.cancel(cancelled)
        await queue.waitUntilIdle()
        #expect(await eventually { server.openUploads == 0 })
        #expect(server.object("bucket", "again.bin") == nil)
        #expect(server.badSignatures.all.isEmpty, "\(server.badSignatures.all)")
    }

    /// A storage that refuses SHA-256 checksums still takes uploads (without them).
    @Test func storageWithoutChecksumsStillTakesUploads() async throws {
        let server = try TestS3()
        defer { server.stop() }
        server.refusesChecksums = true
        let session = try await s3Session(server)
        let local = try scratch()
        try write("plain", to: local + "/plain.txt")
        let queue = session.transfers
        queue.verifiesTransfers = true
        let id = queue.upload(local + "/plain.txt", to: "/bucket/plain.txt", isFolder: false)
        let done = await finished(queue, id)
        #expect(done?.status == .done)
        if case .unchecked? = done?.checksum {} else { Issue.record("expected unchecked: \(String(describing: done?.checksum))") }
        #expect(server.object("bucket", "plain.txt")?.data == Data("plain".utf8))
    }

    @Test func zipsAreMadeAndUnpackedOnThisMac() async throws {
        let server = try TestS3()
        defer { server.stop() }
        server.put("bucket", "docs/a.txt", Data("alpha".utf8))
        server.put("bucket", "docs/folder/b.txt", Data("beta".utf8))
        let session = try await s3Session(server)
        let queue = session.transfers
        // Compress: a .zip next to the items.
        let compress = queue.compress(["a.txt", "folder"], in: "/bucket/docs")
        let compressed = await finished(queue, compress)
        #expect(compressed?.status == .done, "\(String(describing: compressed?.status))")
        #expect(server.keys("bucket").contains("docs/Archive.zip"))
        // Download as .zip, kept on this Mac.
        let local = try scratch()
        let download = queue.downloadArchive(["folder"], in: "/bucket/docs", to: local + "/folder.zip", extract: false)
        #expect(await finished(queue, download)?.status == .done)
        let listing = try await run(["/usr/bin/unzip", "-l", local + "/folder.zip"])
        #expect(listing.output.contains("b.txt"), "\(listing.output)")
        // Extract: into the folder, or a new one when a name is taken.
        let here = queue.extract("Archive.zip", in: "/bucket/docs", newFolder: false)
        let extracted = await finished(queue, here)
        #expect(extracted?.status == .done, "\(String(describing: extracted?.status))")
        #expect(server.keys("bucket").contains("docs/Archive/a.txt"), "a.txt was there already: \(server.keys("bucket"))")
        server.put("bucket", "tars/t.tar.gz", try Data(contentsOf: URL(fileURLWithPath: try makeTarGz())))
        let tar = queue.extract("t.tar.gz", in: "/bucket/tars", newFolder: false)
        // Its link to a file elsewhere on this Mac isn't followed: what it points to stays here.
        let unpacked = await finished(queue, tar)
        #expect(unpacked?.status == .completedWithErrors("link: a symbolic link, not uploaded"), "\(String(describing: unpacked?.status))")
        #expect(server.object("bucket", "tars/inside.txt")?.data == Data("inside".utf8))
        #expect(server.object("bucket", "tars/link") == nil)
        #expect(server.badSignatures.all.isEmpty, "\(server.badSignatures.all)")
    }

    private func makeTarGz() throws -> String {
        let folder = try scratch(), elsewhere = try scratch()
        try write("inside", to: folder + "/inside.txt")
        try write("private", to: elsewhere + "/private.txt")
        try FileManager.default.createSymbolicLink(atPath: folder + "/link", withDestinationPath: elsewhere + "/private.txt")
        let archive = folder + "/t.tar.gz"
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-czf", archive, "-C", folder, "inside.txt", "link"]
        try tar.run()
        tar.waitUntilExit()
        return archive
    }

    /// Copies between an SSH server and S3 storage go through this Mac, both ways.
    @Test func copiesBetweenAServerAndStorage() async throws {
        let storage = try TestS3()
        defer { storage.stop() }
        try await withServer { server in
            let ssh = try server.session()
            try await ssh.connect()
            defer { Task { await ssh.disconnect() } }
            let s3 = try await s3Session(storage)
            let home = ssh.capabilities.home
            try write("from ssh", to: server.home + "/hello.txt")
            let up = s3.transfers.relay(["hello.txt"], in: home, from: ssh, to: "/bucket", replacing: false)
            #expect(await finished(s3.transfers, up)?.status == .done)
            #expect(storage.object("bucket", "hello.txt")?.data == Data("from ssh".utf8))
            storage.put("bucket", "folder/x.txt", Data("from s3".utf8))
            let down = ssh.transfers.relay(["folder"], in: "/bucket", from: s3, to: home, replacing: false)
            #expect(await finished(ssh.transfers, down)?.status == .done)
            #expect(read(server.home + "/folder/x.txt") == "from s3")
        }
    }
}
