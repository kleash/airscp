import CryptoKit
import Foundation

/// AWS Signature Version 4, as S3 takes it: the canonical request, the string to sign, the signing key and the
/// Authorization header, or a presigned URL's query. Pure functions (the tests check AWS's own examples byte for byte).
public enum SigV4 {
    public static let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    /// "20130524T000000Z" and "20130524", in UTC.
    public static func stamps(_ date: Date) -> (time: String, day: String) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let time = formatter.string(from: date)
        return (time, String(time.prefix(8)))
    }

    /// Every byte but A-Z a-z 0-9 - _ . ~ as %XX (upper case); `slash`: "/" kept (a path's separators).
    public static func encode(_ text: String, slash: Bool = false) -> String {
        var result = ""
        for byte in text.utf8 {
            if unreserved.contains(byte) || slash && byte == 0x2F {
                result.unicodeScalars.append(UnicodeScalar(byte))
            } else {
                result += String(format: "%%%02X", byte)
            }
        }
        return result
    }

    private static let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.~".utf8)

    /// The query as signed and sent: each name and value encoded, sorted by name (then value).
    public static func canonicalQuery(_ query: [(String, String)]) -> String {
        let pairs: [(name: String, value: String)] = query.map { (encode($0.0), encode($0.1)) }
        let sorted = pairs.sorted { $0.name == $1.name ? $0.value < $1.value : $0.name < $1.name }
        return sorted.map { $0.name + "=" + $0.value }.joined(separator: "&")
    }

    /// The canonical request for `headers` (lower-case names) of which `signed` are signed; `path` as sent (encoded).
    public static func canonicalRequest(method: String, path: String, query: String, headers: [String: String],
                                        signed: [String], payload: String) -> String {
        let lines = signed.map { name -> String in
            // Values trimmed, inner runs of spaces made one.
            let value = (headers[name] ?? "").split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            return name + ":" + value.trimmingCharacters(in: .whitespaces) + "\n"
        }
        return [method, path, query, lines.joined(), signed.joined(separator: ";"), payload].joined(separator: "\n")
    }

    public static func stringToSign(_ canonicalRequest: String, time: String, scope: String) -> String {
        "AWS4-HMAC-SHA256\n\(time)\n\(scope)\n" + hex(SHA256.hash(data: Data(canonicalRequest.utf8)))
    }

    /// The signature (hex) of `stringToSign` with the key made from `secret`, the day, region and service.
    public static func signature(_ stringToSign: String, secret: String, day: String, region: String, service: String = "s3") -> String {
        var key = SymmetricKey(data: Data(("AWS4" + secret).utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        return hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))
    }

    /// The Authorization header for a request whose `headers` (lower-case names, host and x-amz-date among them) are
    /// all signed.
    public static func authorization(method: String, path: String, query: String, headers: [String: String], payload: String,
                                     accessKey: String, secret: String, region: String, service: String = "s3") -> String {
        let time = headers["x-amz-date"] ?? "", day = String(time.prefix(8))
        let signed = headers.keys.sorted()
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let request = canonicalRequest(method: method, path: path, query: query, headers: headers, signed: signed, payload: payload)
        let signature = signature(stringToSign(request, time: time, scope: scope), secret: secret, day: day, region: region,
                                  service: service)
        return "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signed.joined(separator: ";")), Signature=\(signature)"
    }

    /// A presigned GET's query (host signed only, the payload unsigned), the signature last.
    public static func presignedQuery(path: String, host: String, accessKey: String, secret: String, token: String?,
                                      region: String, date: Date, expires: Int) -> String {
        let (time, day) = stamps(date)
        let scope = "\(day)/\(region)/s3/aws4_request"
        var query = [("X-Amz-Algorithm", "AWS4-HMAC-SHA256"), ("X-Amz-Credential", "\(accessKey)/\(scope)"),
                     ("X-Amz-Date", time), ("X-Amz-Expires", String(expires)), ("X-Amz-SignedHeaders", "host")]
        if let token { query.append(("X-Amz-Security-Token", token)) }
        let canonical = canonicalQuery(query)
        let request = canonicalRequest(method: "GET", path: path, query: canonical, headers: ["host": host], signed: ["host"],
                                       payload: "UNSIGNED-PAYLOAD")
        return canonical + "&X-Amz-Signature=" + signature(stringToSign(request, time: time, scope: scope), secret: secret,
                                                           day: day, region: region)
    }

    public static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// An object in a listing.
public struct S3Object: Equatable {
    public let key: String
    public let size: Int64
    public let modified: Date?
    public let etag: String
    public let storageClass: String
}

/// A response: status, headers (lower-case names) and the body (when it wasn't written to a file).
public struct S3Response {
    public let status: Int
    public let headers: [String: String]
    public let body: Data
}

/// Talks to Amazon S3 or an S3-compatible service over HTTPS (URLSession), every request signed with SigV4. Amazon S3's
/// buckets each answer in their own region: it is found from the first answer (x-amz-bucket-region) and remembered.
public final class S3Client {
    public struct Credentials {
        public var accessKeyID: String
        public var secret: String
        public var token: String?

        public init(accessKeyID: String, secret: String, token: String? = nil) {
            self.accessKeyID = accessKeyID
            self.secret = secret
            self.token = token
        }
    }

    enum Body { case none, data(Data), file(URL) }

    struct Request {
        var method = "GET"
        /// nil: the service itself (ListBuckets).
        var bucket: String?
        var key = ""
        var query: [(String, String)] = []
        var headers: [String: String] = [:]
    }

    /// Files from this size go as multipart uploads; parts are at least `partSize`. Per client: a test makes both small
    /// for its own while other tests upload to real storage, which refuses parts under 5 MiB.
    var multipartThreshold: Int64 = 64 << 20
    var partSize: Int64 = 16 << 20
    /// The largest single PUT or CopyObject S3 takes.
    static let singleLimit: Int64 = 5 << 30

    public let settings: S3Settings
    /// For the debug log.
    let name: String
    private let lock = NSLock()
    private var _credentials = Credentials(accessKeyID: "", secret: "")
    private var regions: [String: String] = [:]
    private var transport = S3Transport(proxy: nil, login: nil)
    /// The service took SHA-256 checksums (x-amz-checksum-sha256); a few S3-compatible ones refuse them.
    private var checksums = true
    /// Multipart uploads that Pause cut off, by job: Resume continues them.
    private var kept: [UUID: (bucket: String, key: String, id: String)] = [:]

    public init(settings: S3Settings, name: String) {
        self.settings = settings
        self.name = name
    }

    deinit { transport.session.invalidateAndCancel() }

    public var credentials: Credentials {
        get { lock.locked { _credentials } }
        set { lock.locked { _credentials = newValue } }
    }

    /// Requests from now on go through `proxy` (HTTP or SOCKS5) with its `password`; nil: directly.
    public func useProxy(_ proxy: Proxy?, password: String?) {
        var dictionary: [AnyHashable: Any]?
        var login: URLCredential?
        if let proxy {
            if proxy.isSOCKS {
                dictionary = [kCFNetworkProxiesSOCKSEnable as String: 1, kCFNetworkProxiesSOCKSProxy as String: proxy.host,
                              kCFNetworkProxiesSOCKSPort as String: proxy.port]
            } else {
                dictionary = [kCFNetworkProxiesHTTPEnable as String: 1, kCFNetworkProxiesHTTPProxy as String: proxy.host,
                              kCFNetworkProxiesHTTPPort as String: proxy.port, kCFNetworkProxiesHTTPSEnable as String: 1,
                              kCFNetworkProxiesHTTPSProxy as String: proxy.host, kCFNetworkProxiesHTTPSPort as String: proxy.port]
            }
            if !proxy.username.isEmpty {
                dictionary?[kCFProxyUsernameKey as String] = proxy.username
                dictionary?[kCFProxyPasswordKey as String] = password ?? ""
                login = URLCredential(user: proxy.username, password: password ?? "", persistence: .forSession)
            }
        }
        let new = S3Transport(proxy: dictionary, login: login)
        let old = lock.locked { () -> S3Transport in
            let old = transport
            transport = new
            return old
        }
        old.session.finishTasksAndInvalidate()
    }

    // MARK: Addresses

    /// The region a request for `bucket` is signed for.
    func region(for bucket: String?) -> String {
        let fallback = settings.region.isEmpty ? "us-east-1" : settings.region
        guard let bucket, settings.endpoint.isEmpty else { return fallback }
        return lock.locked { regions[bucket] } ?? fallback
    }

    /// The request's URL: Amazon S3's regional address, or the endpoint; the bucket in the host name, or (path style) in
    /// the path. Path style also for names with dots (their host names don't match the certificate) and for endpoints
    /// at an IP address or localhost.
    func url(for request: Request, region: String) -> URL {
        var components = URLComponents()
        var basePath = ""
        if settings.endpoint.isEmpty {
            components.scheme = "https"
            components.host = "s3.\(region).amazonaws.com"
        } else {
            let text = settings.endpoint.contains("://") ? settings.endpoint : "https://" + settings.endpoint
            let endpoint = URLComponents(string: text)
            components.scheme = endpoint?.scheme ?? "https"
            components.host = endpoint?.host
            if let port = endpoint?.port, port != (components.scheme == "http" ? 80 : 443) { components.port = port }
            basePath = endpoint?.percentEncodedPath ?? ""
            while basePath.hasSuffix("/") { basePath.removeLast() }
        }
        var path = basePath
        if let bucket = request.bucket {
            let host = components.host ?? ""
            let numeric = host == "localhost" || host.allSatisfy { $0.isNumber || $0 == "." } || host.contains(":")
            if settings.pathStyle || bucket.contains(".") || numeric {
                path += "/" + SigV4.encode(bucket)
            } else {
                components.host = bucket + "." + host
            }
        }
        components.percentEncodedPath = path + "/" + SigV4.encode(request.key, slash: true)
        let query = SigV4.canonicalQuery(request.query)
        if !query.isEmpty { components.percentEncodedQuery = query }
        return components.url!
    }

    /// The Host header URLSession sends for `url`.
    static func host(of url: URL) -> String {
        (url.host ?? "") + (url.port.map { ":\($0)" } ?? "")
    }

    // MARK: Requests

    /// Sends a signed request. `payload`: the body's SHA-256 in hex (a file's, worked out by the caller); a 2xx body
    /// goes into `file` when given. A bucket in another region (Amazon S3) is asked again there.
    func send(_ request: Request, body: Body = .none, payload: String? = nil, into file: FileHandle? = nil,
              progress: ((Int64) -> Void)? = nil, limit: Int? = nil, maxBody: Int64? = nil,
              cancellation: Cancellation? = nil, again: Bool = true) async throws -> S3Response {
        let region = region(for: request.bucket)
        let url = url(for: request, region: region)
        let credentials = self.credentials
        var headers = Dictionary(uniqueKeysWithValues: request.headers.map { ($0.key.lowercased(), $0.value) })
        var hash = SigV4.emptyHash
        if case .data(let data) = body { hash = SigV4.hex(SHA256.hash(data: data)) }
        if let payload { hash = payload }
        headers["x-amz-content-sha256"] = hash
        headers["x-amz-date"] = SigV4.stamps(Date()).time
        if let token = credentials.token, !token.isEmpty { headers["x-amz-security-token"] = token }
        headers["host"] = Self.host(of: url)
        let authorization = SigV4.authorization(method: request.method, path: url.path(percentEncoded: true),
                                                query: url.query(percentEncoded: true) ?? "", headers: headers, payload: hash,
                                                accessKey: credentials.accessKeyID, secret: credentials.secret, region: region)
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = request.method
        for (name, value) in headers where name != "host" { urlRequest.setValue(value, forHTTPHeaderField: name) }
        urlRequest.setValue(authorization, forHTTPHeaderField: "Authorization")
        let transport = lock.locked { self.transport }
        let response = try await transport.run(urlRequest, body: body, into: file, progress: progress, limit: limit,
                                               maxBody: maxBody, cancellation: cancellation)
        if DebugLog.enabled {
            DebugLog.write("S3 \(request.method) \(url.path(percentEncoded: true))"
                           + (request.query.isEmpty ? "" : "?" + (url.query(percentEncoded: true) ?? "")) + " → \(response.status)",
                           host: name)
        }
        if (200..<300).contains(response.status) {
            // CopyObject and CompleteMultipartUpload may answer 200 and say in the body that they failed.
            if request.method != "GET", response.body.starts(with: Data("<?xml".utf8)) || response.body.starts(with: Data("<Error".utf8)),
               let tree = XMLTree.parse(response.body), tree.name == "Error" {
                throw Self.error(status: response.status, tree: tree, request: request)
            }
            return response
        }
        let tree = XMLTree.parse(response.body)
        // Amazon S3: the bucket is in another region, which the answer names.
        if again, settings.endpoint.isEmpty, let bucket = request.bucket,
           let actual = response.headers["x-amz-bucket-region"] ?? tree?.value("Region"), actual != region {
            lock.locked { regions[bucket] = actual }
            return try await send(request, body: body, payload: payload, into: file, progress: progress, limit: limit,
                                  maxBody: maxBody, cancellation: cancellation, again: false)
        }
        throw Self.error(status: response.status, tree: tree, request: request)
    }

    static func error(status: Int, tree: XMLTree.Node?, request: Request) -> AirSCPError {
        var code = tree?.value("Code") ?? ""
        if code.isEmpty {
            // A HEAD's answer has no body.
            code = [301: "PermanentRedirect", 400: "BadRequest", 403: "AccessDenied", 404: request.key.isEmpty ? "NoSuchBucket" : "NoSuchKey",
                    412: "PreconditionFailed", 503: "SlowDown"][status] ?? ""
        }
        let target = "/" + [request.bucket, request.key.isEmpty ? nil : request.key].compactMap { $0 }.joined(separator: "/")
        return ErrorMapping.s3(status: status, code: code, message: tree?.value("Message") ?? "",
                               details: "\(request.method) \(target): HTTP \(status) \(code) \(tree?.value("Message") ?? "")")
    }

    // MARK: Buckets and listings

    /// The buckets the keys may see, with when each was made.
    public func listBuckets() async throws -> [(name: String, created: Date?)] {
        let response = try await send(Request())
        return (XMLTree.parse(response.body)?.first("Buckets")?.all("Bucket") ?? []).compactMap { bucket in
            bucket.value("Name").map { ($0, bucket.value("CreationDate").flatMap(S3Dates.iso)) }
        }
    }

    /// Everything under `prefix` (every page): with `delimiter` the objects at its level and the common prefixes (the
    /// folders); without it every object below. `maxKeys`: stop after that many.
    public func list(_ bucket: String, prefix: String, delimiter: String? = "/", maxKeys: Int? = nil,
                     cancellation: Cancellation? = nil) async throws -> (objects: [S3Object], prefixes: [String]) {
        var objects: [S3Object] = [], prefixes: [String] = []
        var token: String?
        repeat {
            // shortcut: no encoding-type=url, so a key with a control character (which XML can't hold) makes the listing
            // unreadable; add it (and decode the keys) if such keys turn up.
            var query = [("list-type", "2"), ("prefix", prefix)]
            if let delimiter { query.append(("delimiter", delimiter)) }
            if let maxKeys { query.append(("max-keys", String(min(1000, maxKeys)))) }
            if let token { query.append(("continuation-token", token)) }
            let response = try await send(Request(bucket: bucket, query: query), cancellation: cancellation)
            guard let tree = XMLTree.parse(response.body) else {
                throw AirSCPError(.other, "The storage's listing couldn't be read.", details: String(decoding: response.body, as: UTF8.self))
            }
            for item in tree.all("Contents") {
                guard let key = item.value("Key") else { continue }
                objects.append(S3Object(key: key, size: Int64(item.value("Size") ?? "") ?? 0,
                                        modified: item.value("LastModified").flatMap(S3Dates.iso),
                                        etag: item.value("ETag") ?? "", storageClass: item.value("StorageClass") ?? ""))
            }
            prefixes += tree.all("CommonPrefixes").compactMap { $0.value("Prefix") }
            token = tree.value("IsTruncated") == "true" ? tree.value("NextContinuationToken") : nil
            if let maxKeys, objects.count + prefixes.count >= maxKeys { break }
        } while token != nil
        return (objects, prefixes)
    }

    /// The object's headers (size, date, ETag, type, storage class, metadata; its SHA-256 checksum where it has one).
    public func head(_ bucket: String, _ key: String, part: Int? = nil) async throws -> [String: String] {
        var request = Request(method: "HEAD", bucket: bucket, key: key, headers: ["x-amz-checksum-mode": "ENABLED"])
        if let part { request.query = [("partNumber", String(part))] }
        return try await send(request).headers
    }

    /// Downloads the object into `file` (`offset`: from that byte on, appended; `etag`: only while the object is still
    /// that one, else `.failure` "PreconditionFailed"). `maxBody`: stop with `.notText` past that many bytes.
    public func get(_ bucket: String, _ key: String, into file: FileHandle, offset: Int64 = 0, etag: String? = nil,
                    maxBody: Int64? = nil, progress: ((Int64) -> Void)? = nil, limit: Int? = nil,
                    cancellation: Cancellation? = nil) async throws {
        // shortcut: an object stored with Content-Encoding gzip arrives decompressed (URLSession decodes it); fine for
        // files, which are stored as they are, unless someone uploads them pre-compressed that way.
        var headers: [String: String] = [:]
        if offset > 0 { headers["range"] = "bytes=\(offset)-" }
        if let etag, !etag.isEmpty { headers["if-match"] = etag }
        _ = try await send(Request(bucket: bucket, key: key, headers: headers), into: file, progress: progress, limit: limit,
                           maxBody: maxBody, cancellation: cancellation)
    }

    /// Uploads a file: one PUT (with its SHA-256 for the storage to check), or from `multipartThreshold` on a multipart
    /// upload of under 10,000 parts. `job`: Pause keeps such an upload's parts for that job (`abandon` drops them), and
    /// its next try continues it; without one, a failed upload's parts go at once.
    public func upload(_ file: URL, size: Int64, to bucket: String, _ key: String, job: UUID? = nil,
                       progress: ((Int64) -> Void)? = nil, limit: Int? = nil, cancellation: Cancellation? = nil) async throws {
        guard size >= multipartThreshold else {
            let digest = try Self.sha256(file, cancellation: cancellation)
            try await put(bucket, key, body: .file(file), digest: digest, progress: progress, limit: limit, cancellation: cancellation)
            return
        }
        let partSize = self.partSize(for: size)
        let count = Int((size + partSize - 1) / partSize)
        var id: String, done: [Int: (etag: String, checksum: String?, size: Int64)] = [:]
        if let job, let earlier = lock.locked({ kept[job] }), earlier.bucket == bucket, earlier.key == key,
           let parts = try? await listParts(bucket, key, id: earlier.id) {
            id = earlier.id
            done = parts
        } else {
            if let job { await abandon(job) }
            id = try await createMultipart(bucket, key)
            if let job { lock.locked { kept[job] = (bucket, key, id) } }
        }
        do {
            guard let handle = FileHandle(forReadingAtPath: file.path) else {
                throw AirSCPError(.permissionDenied, "AirSCP can't read \(file.lastPathComponent) on this Mac.")
            }
            defer { try? handle.close() }
            var parts: [(number: Int, etag: String, checksum: String?)] = []
            var sent: Int64 = 0
            for number in 1...count {
                let offset = Int64(number - 1) * partSize, length = min(partSize, size - offset)
                if let part = done[number], part.size == length {
                    parts.append((number, part.etag, part.checksum))
                    sent += length
                    progress?(sent)
                    continue
                }
                if cancellation?.isCancelled == true { throw AirSCPError.cancelled }
                // shortcut: a part is read into memory (16 MiB; 1/10,000 of a file over 160 GB); stream it from the file
                // if such files become common.
                try handle.seek(toOffset: UInt64(offset))
                guard let data = try handle.read(upToCount: Int(length)), data.count == length else {
                    throw AirSCPError(.other, "\(file.lastPathComponent) changed on this Mac while it was uploaded.")
                }
                let base = sent
                let (etag, checksum) = try await uploadPart(bucket, key, id: id, number: number, data: data,
                                                            progress: { progress?(base + $0) }, limit: limit,
                                                            cancellation: cancellation)
                parts.append((number, etag, checksum))
                sent += length
            }
            try await complete(bucket, key, id: id, parts: parts, cancellation: cancellation)
            if let job { lock.locked { kept[job] = nil } }
        } catch {
            if job == nil { _ = try? await send(Request(method: "DELETE", bucket: bucket, key: key, query: [("uploadId", id)])) }
            throw error
        }
    }

    /// Whether `job` has a multipart upload kept for its next try.
    public func keepsUpload(of job: UUID) -> Bool { lock.locked { kept[job] != nil } }

    /// Drops the parts kept for `job` (AbortMultipartUpload).
    public func abandon(_ job: UUID) async {
        guard let upload = lock.locked({ kept.removeValue(forKey: job) }) else { return }
        _ = try? await send(Request(method: "DELETE", bucket: upload.bucket, key: upload.key, query: [("uploadId", upload.id)]))
    }

    /// A multipart upload's parts: at least `partSize`, more for big files (10,000 parts at most).
    func partSize(for size: Int64) -> Int64 {
        let mebibyte: Int64 = 1 << 20
        let least = (size + 9_999) / 10_000
        return max(partSize, (least + mebibyte - 1) / mebibyte * mebibyte)
    }

    /// One PUT of a file or of data; `digest`: its SHA-256 (sent for the storage to check, where it takes checksums).
    func put(_ bucket: String, _ key: String, body: Body, digest: Data, progress: ((Int64) -> Void)? = nil, limit: Int? = nil,
             cancellation: Cancellation? = nil) async throws {
        var headers = ["content-type": Self.contentType(key)]
        if lock.locked({ checksums }) { headers["x-amz-checksum-sha256"] = digest.base64EncodedString() }
        do {
            _ = try await send(Request(method: "PUT", bucket: bucket, key: key, headers: headers), body: body,
                               payload: SigV4.hex(digest), progress: progress, limit: limit, cancellation: cancellation)
        } catch let error as AirSCPError where headers["x-amz-checksum-sha256"] != nil && Self.refusesChecksums(error) {
            lock.locked { checksums = false }
            try await put(bucket, key, body: body, digest: digest, progress: progress, limit: limit, cancellation: cancellation)
        }
    }

    /// A storage that doesn't take SHA-256 checksums says so (`error`'s code, in its details).
    static func refusesChecksums(_ error: AirSCPError) -> Bool {
        let details = error.details
        return details.contains(" NotImplemented ")
            || (details.contains(" InvalidArgument ") || details.contains(" InvalidRequest ")) && details.localizedCaseInsensitiveContains("checksum")
    }

    func createMultipart(_ bucket: String, _ key: String) async throws -> String {
        var headers = ["content-type": Self.contentType(key)]
        if lock.locked({ checksums }) { headers["x-amz-checksum-algorithm"] = "SHA256" }
        do {
            let response = try await send(Request(method: "POST", bucket: bucket, key: key, query: [("uploads", "")], headers: headers))
            guard let id = XMLTree.parse(response.body)?.value("UploadId") else {
                throw AirSCPError(.other, "The storage didn't start the upload.", details: String(decoding: response.body, as: UTF8.self))
            }
            return id
        } catch let error as AirSCPError where headers["x-amz-checksum-algorithm"] != nil && Self.refusesChecksums(error) {
            lock.locked { checksums = false }
            return try await createMultipart(bucket, key)
        }
    }

    func uploadPart(_ bucket: String, _ key: String, id: String, number: Int, data: Data, progress: ((Int64) -> Void)?,
                    limit: Int?, cancellation: Cancellation?) async throws -> (etag: String, checksum: String?) {
        let digest = Data(SHA256.hash(data: data))
        var headers: [String: String] = [:]
        let checksum = lock.locked({ checksums }) ? digest.base64EncodedString() : nil
        if let checksum { headers["x-amz-checksum-sha256"] = checksum }
        let response = try await send(Request(method: "PUT", bucket: bucket, key: key,
                                              query: [("partNumber", String(number)), ("uploadId", id)], headers: headers),
                                      body: .data(data), progress: progress, limit: limit, cancellation: cancellation)
        return (response.headers["etag"] ?? "", checksum)
    }

    /// The parts of an upload that have arrived, by number.
    func listParts(_ bucket: String, _ key: String, id: String) async throws -> [Int: (etag: String, checksum: String?, size: Int64)] {
        var parts: [Int: (etag: String, checksum: String?, size: Int64)] = [:]
        var marker: String?
        repeat {
            var query = [("uploadId", id)]
            if let marker { query.append(("part-number-marker", marker)) }
            let tree = XMLTree.parse(try await send(Request(bucket: bucket, key: key, query: query)).body)
            for part in tree?.all("Part") ?? [] {
                guard let number = part.value("PartNumber").flatMap(Int.init) else { continue }
                parts[number] = (part.value("ETag") ?? "", part.value("ChecksumSHA256"), Int64(part.value("Size") ?? "") ?? 0)
            }
            marker = tree?.value("IsTruncated") == "true" ? tree?.value("NextPartNumberMarker") : nil
        } while marker != nil
        return parts
    }

    func complete(_ bucket: String, _ key: String, id: String, parts: [(number: Int, etag: String, checksum: String?)],
                  cancellation: Cancellation? = nil) async throws {
        let body = "<CompleteMultipartUpload>" + parts.map { part in
            "<Part><PartNumber>\(part.number)</PartNumber><ETag>\(XMLTree.escape(part.etag))</ETag>"
                + (part.checksum.map { "<ChecksumSHA256>\($0)</ChecksumSHA256>" } ?? "") + "</Part>"
        }.joined() + "</CompleteMultipartUpload>"
        _ = try await send(Request(method: "POST", bucket: bucket, key: key, query: [("uploadId", id)],
                                   headers: ["content-type": "application/xml"]), body: .data(Data(body.utf8)),
                           cancellation: cancellation)
    }

    /// Copies an object (CopyObject; above 5 GB part by part with UploadPartCopy). Its metadata goes with it.
    public func copy(_ bucket: String, _ key: String, size: Int64, to newBucket: String, _ newKey: String,
                     cancellation: Cancellation? = nil) async throws {
        let source = "/" + SigV4.encode(bucket) + "/" + SigV4.encode(key, slash: true)
        guard size > Self.singleLimit else {
            _ = try await send(Request(method: "PUT", bucket: newBucket, key: newKey, headers: ["x-amz-copy-source": source]),
                               cancellation: cancellation)
            return
        }
        let id = try await createMultipart(newBucket, newKey)
        do {
            let partSize = max(self.partSize(for: size), 512 << 20)
            var parts: [(number: Int, etag: String, checksum: String?)] = []
            var offset: Int64 = 0
            while offset < size {
                let end = min(size, offset + partSize) - 1
                let response = try await send(Request(method: "PUT", bucket: newBucket, key: newKey,
                                                      query: [("partNumber", String(parts.count + 1)), ("uploadId", id)],
                                                      headers: ["x-amz-copy-source": source,
                                                                "x-amz-copy-source-range": "bytes=\(offset)-\(end)"]),
                                              cancellation: cancellation)
                let result = XMLTree.parse(response.body)
                parts.append((parts.count + 1, result?.value("ETag") ?? "", result?.value("ChecksumSHA256")))
                offset = end + 1
            }
            try await complete(newBucket, newKey, id: id, parts: parts, cancellation: cancellation)
        } catch {
            _ = try? await send(Request(method: "DELETE", bucket: newBucket, key: newKey, query: [("uploadId", id)]))
            throw error
        }
    }

    /// Deletes the keys, 1,000 to a request (DeleteObjects). What the storage refused is thrown once all were tried.
    public func delete(_ bucket: String, keys: [String], cancellation: Cancellation? = nil) async throws {
        var refused: [(key: String, error: AirSCPError)] = []
        for start in stride(from: 0, to: keys.count, by: 1000) {
            let batch = keys[start..<min(keys.count, start + 1000)]
            let body = Data(("<Delete><Quiet>true</Quiet>" + batch.map { "<Object><Key>\(XMLTree.escape($0))</Key></Object>" }.joined()
                             + "</Delete>").utf8)
            let response = try await send(Request(method: "POST", bucket: bucket, query: [("delete", "")],
                                                  headers: ["content-type": "application/xml",
                                                            "content-md5": Data(Insecure.MD5.hash(data: body)).base64EncodedString()]),
                                          body: .data(body), cancellation: cancellation)
            for failure in XMLTree.parse(response.body)?.all("Error") ?? [] {
                let request = Request(method: "DELETE", bucket: bucket, key: failure.value("Key") ?? "")
                refused.append((request.key, Self.error(status: 200, tree: failure, request: request)))
            }
        }
        if let first = refused.first {
            throw AirSCPError(first.error.kind, first.error.message,
                              details: refused.map { "\($0.key): \($0.error.details)" }.joined(separator: "\n"))
        }
    }

    /// A link anyone can open for `expires` seconds (at most a week), without logging in.
    public func presign(_ bucket: String, _ key: String, expires: Int) async throws -> URL {
        if settings.endpoint.isEmpty, lock.locked({ regions[bucket] }) == nil {
            _ = try? await send(Request(method: "HEAD", bucket: bucket))  // finds its region
        }
        let region = region(for: bucket)
        let url = url(for: Request(bucket: bucket, key: key), region: region)
        let credentials = self.credentials
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = SigV4.presignedQuery(path: url.path(percentEncoded: true), host: Self.host(of: url),
                                                              accessKey: credentials.accessKeyID, secret: credentials.secret,
                                                              token: credentials.token, region: region, date: Date(),
                                                              expires: min(expires, 604_800))
        return components.url!
    }

    // MARK: Helpers

    /// The SHA-256 of a file, a megabyte at a time.
    static func sha256(_ file: URL, cancellation: Cancellation? = nil) throws -> Data {
        guard let handle = FileHandle(forReadingAtPath: file.path) else {
            throw AirSCPError(.permissionDenied, "AirSCP can't read \(file.lastPathComponent) on this Mac.")
        }
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            if cancellation?.isCancelled == true { throw AirSCPError.cancelled }
            hash.update(data: chunk)
        }
        return Data(hash.finalize())
    }

    /// The SHA-256 a storage keeps for a file uploaded in parts of `partSize`: of the parts' own SHA-256s, then "-N".
    static func compositeSHA256(_ file: URL, partSize: Int64) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: file.path) else {
            throw AirSCPError(.permissionDenied, "AirSCP can't read \(file.lastPathComponent) on this Mac.")
        }
        defer { try? handle.close() }
        var digests = Data(), count = 0
        while true {
            var part = SHA256(), read: Int64 = 0
            while read < partSize, let chunk = try handle.read(upToCount: Int(min(1 << 20, partSize - read))), !chunk.isEmpty {
                part.update(data: chunk)
                read += Int64(chunk.count)
            }
            if read == 0 { break }
            digests += Data(part.finalize())
            count += 1
        }
        return Data(SHA256.hash(data: digests)).base64EncodedString() + "-\(count)"
    }

    /// The type stored with an upload, from its name's extension.
    static func contentType(_ key: String) -> String {
        let ext = (key as NSString).pathExtension.lowercased()
        let types = ["txt": "text/plain", "html": "text/html", "htm": "text/html", "css": "text/css", "js": "text/javascript",
                     "json": "application/json", "xml": "application/xml", "csv": "text/csv", "md": "text/markdown",
                     "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "svg": "image/svg+xml",
                     "webp": "image/webp", "pdf": "application/pdf", "zip": "application/zip", "gz": "application/gzip",
                     "tgz": "application/gzip", "mp4": "video/mp4", "mp3": "audio/mpeg", "wasm": "application/wasm"]
        return types[ext] ?? "application/octet-stream"
    }
}

/// S3's dates: ISO 8601 in listings, HTTP dates in headers.
enum S3Dates {
    /// Made once: a listing has a date per object (ISO8601DateFormatter is safe to share between threads).
    private static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private static let whole = ISO8601DateFormatter()

    static func iso(_ text: String) -> Date? {
        fractional.date(from: text) ?? whole.date(from: text)
    }

    static func http(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }
}

/// A small XML reader for S3's answers: elements with their text and children.
enum XMLTree {
    final class Node {
        let name: String
        var text = ""
        var children: [Node] = []

        init(_ name: String) { self.name = name }

        func first(_ name: String) -> Node? { children.first { $0.name == name } }
        func all(_ name: String) -> [Node] { children.filter { $0.name == name } }
        /// The text of the first child with this name.
        func value(_ name: String) -> String? { first(name)?.text }
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var stack: [Node] = []
        var root: Node?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let node = Node(name)
            stack.last?.children.append(node)
            if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            _ = stack.popLast()
        }
    }

    static func parse(_ data: Data) -> Node? {
        guard !data.isEmpty else { return nil }
        let parser = XMLParser(data: data)
        let reader = Reader()
        parser.delegate = reader
        return parser.parse() ? reader.root : nil
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }
}

/// One URLSession for a connection's requests, with one delegate: bodies into files, progress, the speed limit (a task
/// ahead of it is suspended until it is due), cancelling, and the proxy's login.
final class S3Transport: NSObject, URLSessionDataDelegate {
    private final class Exchange {
        var continuation: CheckedContinuation<S3Response, Error>?
        let file: FileHandle?
        let progress: ((Int64) -> Void)?
        let limit: Int?
        let maxBody: Int64?
        let start = Date()
        var status = 0
        var headers: [String: String] = [:]
        var body = Data()
        var bytes: Int64 = 0
        var failure: Error?

        init(file: FileHandle?, progress: ((Int64) -> Void)?, limit: Int?, maxBody: Int64?) {
            self.file = file
            self.progress = progress
            self.limit = limit
            self.maxBody = maxBody
        }
    }

    private(set) var session: URLSession!
    private let login: URLCredential?
    private let lock = NSLock()
    private var exchanges: [Int: Exchange] = [:]

    init(proxy: [AnyHashable: Any]?, login: URLCredential?) {
        self.login = login
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = proxy
        configuration.timeoutIntervalForRequest = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func run(_ request: URLRequest, body: S3Client.Body, into file: FileHandle?, progress: ((Int64) -> Void)?, limit: Int?,
             maxBody: Int64?, cancellation: Cancellation?) async throws -> S3Response {
        let task: URLSessionTask
        switch body {
        case .none: task = session.dataTask(with: request)
        case .data(let data): task = session.uploadTask(with: request, from: data)
        case .file(let url): task = session.uploadTask(with: request, fromFile: url)
        }
        let exchange = Exchange(file: file, progress: progress, limit: limit, maxBody: maxBody)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                exchange.continuation = continuation
                lock.locked { exchanges[task.taskIdentifier] = exchange }
                // Weakly: a long job's Cancellation keeps this for every request it makes.
                cancellation?.onCancel { [weak task] in task?.cancel() }
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    private func exchange(_ task: URLSessionTask) -> Exchange? { lock.locked { exchanges[task.taskIdentifier] } }

    /// A task ahead of its speed limit waits until it is due.
    private func pace(_ task: URLSessionTask, _ exchange: Exchange) {
        guard let limit = exchange.limit, limit > 0 else { return }
        let due = Double(exchange.bytes) / Double(limit) - Date().timeIntervalSince(exchange.start)
        guard due > 0.02 else { return }
        task.suspend()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + due) { task.resume() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let exchange = exchange(dataTask), let response = response as? HTTPURLResponse {
            exchange.status = response.statusCode
            for (name, value) in response.allHeaderFields {
                if let name = name as? String, let value = value as? String { exchange.headers[name.lowercased()] = value }
            }
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let exchange = exchange(dataTask) else { return }
        if let file = exchange.file, (200..<300).contains(exchange.status) {
            do {
                try file.write(contentsOf: data)
            } catch {
                exchange.failure = AirSCPError(.diskFull, "AirSCP couldn't write the download on this Mac: \(error.localizedDescription)")
                return dataTask.cancel()
            }
            exchange.bytes += Int64(data.count)
            if let maxBody = exchange.maxBody, exchange.bytes > maxBody {
                exchange.failure = AirSCPError(.notText, "The file is too large.")
                return dataTask.cancel()
            }
            exchange.progress?(exchange.bytes)
            pace(dataTask, exchange)
        } else if exchange.body.count < 8 << 20 {  // a listing page of 1,000 long keys
            exchange.body.append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        guard let exchange = exchange(task) else { return }
        exchange.bytes = totalBytesSent
        exchange.progress?(totalBytesSent)
        pace(task, exchange)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let exchange = lock.locked({ exchanges.removeValue(forKey: task.taskIdentifier) }) else { return }
        if let failure = exchange.failure ?? error {
            exchange.continuation?.resume(throwing: failure as? AirSCPError ?? ErrorMapping.s3(failure))
        } else {
            exchange.continuation?.resume(returning: S3Response(status: exchange.status, headers: exchange.headers, body: exchange.body))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.isProxy(), let login, challenge.previousFailureCount == 0 {
            completionHandler(.useCredential, login)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
