import CryptoKit
import Darwin
import Foundation

/// Proxy-connect mode: `AirSCP --proxy-connect <proxy id> <host> <port>`, the ProxyCommand ssh runs for a host whose
/// first hop (its own, or its jump host's: nested in the jump's ProxyCommand with %%h/%%p) goes through a saved proxy
/// (`SSHHost.proxyID`, see `OpenSSH.options`). The helper gets the proxy's kind, address, user name and password from
/// the running app over the askpass socket (its own `{proxy: id}` message, answered by `AskpassServer.proxyHandler`;
/// never argv or the environment), connects, and asks the proxy for the server: an HTTP proxy with `CONNECT host:port`
/// (with a user name, the login its 407 asks for, Digest or Basic, on a new connection), a SOCKS5 proxy with its
/// handshake. Then it relays standard input and output. A failure prints one line starting with "AirSCP proxy: " (e.g.
/// `AirSCP proxy: HTTP/1.1 407 …`), which ErrorMapping turns into a message.
public enum ProxyConnect {
    /// Runs the helper and returns its exit status. main.swift calls it before the askpass check (the helper inherits
    /// AIRSCP_ASKPASS_SOCK from ssh). `arguments` are the ones after `--proxy-connect`.
    public static func run(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        // A port outside 1–65535 is refused (ssh passes only valid ones): SOCKS5 sends it as two bytes.
        guard arguments.count == 3, let proxyID = UUID(uuidString: arguments[0]), let port = Int(arguments[2]),
              (1...65535).contains(port) else {
            return fail("usage: AirSCP --proxy-connect <proxy id> <host> <port>")
        }
        guard let socket = environment["AIRSCP_ASKPASS_SOCK"] else {
            return fail("only AirSCP can run this command (it has the proxy's settings)")
        }
        // While the debug log is on (AIRSCP_DEBUG=1, from `Runner`), what the proxy did, as a debug line of ssh's would
        // say it (the log takes them): never the password or the Proxy-Authorization header.
        let debug = Env.value("DEBUG", in: environment) == "1"
        var started = Date()  // from AirSCP's answer on: the proxy's own time, not the time a password question took
        let target = arguments[1].contains(":") ? "[\(arguments[1])]:\(port)" : "\(arguments[1]):\(port)"
        func note(_ text: String) {
            guard debug else { return }
            let time = Int(Date().timeIntervalSince(started) * 1000)
            FileHandle.standardError.write(Data("debug1: proxy-connect: \(text) (after \(time) ms)\n".utf8))
        }
        // During an automatic reconnect (AIRSCP_SILENT) the app may not ask for a missing password.
        let request: [String: Any] = ["id": environment["AIRSCP_HOST"] ?? "", "proxy": proxyID.uuidString,
                                      "mayAsk": environment["AIRSCP_SILENT"] == nil,
                                      "token": environment["AIRSCP_ASKPASS_TOKEN"] ?? ""]
        guard let reply = Askpass.exchange(request, socket: socket) else { return fail("can't reach AirSCP") }
        started = Date()
        guard let proxyHost = reply["host"] as? String, let proxyPort = reply["port"] as? Int else {
            note("no proxy for the connection to \(target): it no longer exists, or its password question was cancelled")
            return fail("cancelled")
        }
        let username = reply["username"] as? String ?? ""
        let proxy = "the proxy \(proxyHost):\(proxyPort)" + (username.isEmpty ? "" : " (user \(username))")
        let password = reply["password"] as? String ?? ""
        var authorization: String?
        var fd: Int32 = -1, answer = [UInt8](), bodyStart = 0, statusLine = ""
        defer { if fd >= 0 { close(fd) } }
        if reply["kind"] as? String == Proxy.Kind.socks5.rawValue {
            // SOCKS5 (RFC 1928; RFC 1929's user name and password when the proxy has a user).
            let connection = connectTCP(proxyHost, proxyPort)
            fd = connection.fd
            guard fd >= 0 else {
                note("\(proxy) can't be reached for the connection to \(target): \(connection.failure)")
                return fail(connection.failure)
            }
            if let failure = socks5(fd, host: arguments[1], port: port, username: username, password: password) {
                note("\(proxy) (SOCKS5) refused the connection to \(target): \(failure)")
                return fail(failure)
            }
            note("\(proxy) (SOCKS5) connected to \(target)")
            return relay(fd, answer: [], from: 0)
        }
        // No login at first: the proxy's 407 says how it wants one, and a new connection gives it. Digest when it offers
        // that (the password never goes over the network), else Basic; Digest once more when it says the nonce was stale.
        for attempt in 0..<3 {
            if fd >= 0 { close(fd) }
            let connection = connectTCP(proxyHost, proxyPort)
            fd = connection.fd
            guard fd >= 0 else {
                note("\(proxy) can't be reached for the connection to \(target): \(connection.failure)")
                return fail(connection.failure)
            }
            var head = "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n"
            if let authorization { head += "Proxy-Authorization: \(authorization)\r\n" }
            guard Array((head + "\r\n").utf8).withUnsafeBytes({ writeAll(fd, $0) }) else {
                note("\(proxy) closed the connection before CONNECT \(target)")
                return fail("the proxy closed the connection")
            }
            switch readHead(fd) {
            case .failure(let message, let detail):
                note("\(proxy) \(detail) CONNECT \(target)")
                return fail(message)
            case .success(let bytes, let start):
                (answer, bodyStart) = (bytes, start)
            }
            statusLine = String(decoding: answer.prefix { $0 != 13 && $0 != 10 }, as: UTF8.self)
            let code = statusLine.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
            let offered = challenges(in: String(decoding: answer.prefix(bodyStart), as: UTF8.self))
            guard code == 407, !username.isEmpty, attempt < 2 else { break }
            let sentDigest = authorization?.hasPrefix("Digest ") == true
            if let digest = offered.first(where: { $0.scheme == "digest" })?.parameters,
               authorization == nil || sentDigest && digest["stale"]?.lowercased() == "true",
               let answerHeader = Self.digest(digest, username: username, password: password, uri: target, cnonce: cnonce()) {
                note("\(proxy) asked for Digest" + (sentDigest ? " again (stale nonce)" : "") + ": answering it")
                authorization = answerHeader
            } else if authorization == nil, offered.isEmpty || offered.contains(where: { $0.scheme == "basic" }) {
                note("\(proxy) asked for a login: answering with Basic")
                authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
            } else {
                break
            }
        }
        let code = statusLine.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        guard statusLine.hasPrefix("HTTP/"), (200..<300).contains(code) else {
            note("\(proxy) answered CONNECT \(target) with “\(statusLine)”: no connection")
            return fail(statusLine)
        }
        note("\(proxy) answered CONNECT \(target) with “\(statusLine)”: connected")
        return relay(fd, answer: answer, from: bodyStart)
    }

    /// Relays until the server closes: ssh's standard input to the proxy (on a thread of its own, so neither direction
    /// can hold up the other), the proxy to standard output here; first what came after the proxy's answer.
    private static func relay(_ fd: Int32, answer: [UInt8], from bodyStart: Int) -> Int32 {
        var limit = timeval(tv_sec: 0, tv_usec: 0)  // a quiet connection is no reason to end it
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        signal(SIGPIPE, SIG_IGN)
        if bodyStart < answer.count, !answer[bodyStart...].withUnsafeBytes({ writeAll(1, $0) }) { return 0 }
        Thread.detachNewThread {
            pump(from: 0, to: fd)
            shutdown(fd, SHUT_WR)
        }
        pump(from: fd, to: 1)
        return 0
    }

    /// The SOCKS5 handshake for CONNECT to host:port on `fd`: nil once connected, else why not (in words).
    static func socks5(_ fd: Int32, host: String, port: Int, username: String, password: String) -> String? {
        var limit = timeval(tv_sec: answerTimeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        func send(_ bytes: [UInt8]) -> Bool { bytes.withUnsafeBytes { writeAll(fd, $0) } }
        func receive(_ count: Int) -> [UInt8]? {
            var bytes = [UInt8](repeating: 0, count: count), got = 0
            while got < count {
                let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress! + got, count - got) }
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { return nil }
                got += n
            }
            return bytes
        }
        let lost = "the proxy closed the connection (or didn't answer within \(answerTimeout) s)"
        // Methods: none, and user name/password when there is a user.
        guard send(username.isEmpty ? [5, 1, 0] : [5, 2, 0, 2]), let chosen = receive(2), chosen[0] == 5 else {
            return lost + ": is it a SOCKS5 proxy?"
        }
        switch chosen[1] {
        case 0: break
        case 2:
            let user = Array(username.utf8.prefix(255)), secret = Array(password.utf8.prefix(255))
            guard send([1, UInt8(user.count)] + user + [UInt8(secret.count)] + secret), let status = receive(2) else { return lost }
            guard status[1] == 0 else { return "the SOCKS proxy rejected the user name or password" }
        default:
            return username.isEmpty ? "the SOCKS proxy wants a user name and password: add them in Host ▸ Proxies…"
                : "the SOCKS proxy accepts none of the login methods AirSCP knows"
        }
        // The target: an IPv4 or IPv6 address as such, else the name (the proxy resolves it).
        var address: [UInt8]
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            address = [1] + withUnsafeBytes(of: &v4) { Array($0) }
        } else if inet_pton(AF_INET6, host, &v6) == 1 {
            address = [4] + withUnsafeBytes(of: &v6) { Array($0) }
        } else {
            let name = Array(host.utf8.prefix(255))
            address = [3, UInt8(name.count)] + name
        }
        guard send([5, 1, 0] + address + [UInt8(port >> 8), UInt8(port & 0xFF)]), let head = receive(4), head[0] == 5 else {
            return lost
        }
        guard head[1] == 0 else {
            let reasons = [1: "the proxy failed", 2: "the proxy's rules don't allow it", 3: "the network can't be reached",
                           4: "the server can't be reached", 5: "the server refused the connection", 6: "it timed out",
                           7: "the proxy doesn't do CONNECT", 8: "the proxy doesn't take that kind of address"]
            return "SOCKS5: " + (reasons[Int(head[1])] ?? "error \(head[1])")
        }
        // The address the proxy connected from (skipped), then the port.
        let rest = head[3] == 1 ? 4 : head[3] == 4 ? 16 : Int(receive(1)?.first ?? 0)
        guard receive(rest + 2) != nil else { return lost }
        return nil
    }

    /// Seconds the proxy has to answer CONNECT: a little more than a direct connection's ConnectTimeout (15 s), since the
    /// proxy connects to the server first.
    static let answerTimeout = 20

    private enum Head {
        case success([UInt8], bodyStart: Int)
        /// What fail() prints, and how the debug line says it ("closed the connection without answering").
        case failure(String, String)
    }

    /// The proxy's answer up to its empty line (what follows is already the server's). A proxy that never answers (ssh
    /// has no ConnectTimeout through a proxy) gets the time a direct connection would.
    private static func readHead(_ fd: Int32) -> Head {
        var limit = timeval(tv_sec: answerTimeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var answer = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count < 0 && errno == EAGAIN {
                return .failure("the proxy didn't answer within \(answerTimeout) s: check its address and port (Host ▸ "
                                + "Proxies…), or try again later", "didn't answer within \(answerTimeout) s:")
            }
            guard count > 0 else { return .failure("the proxy closed the connection", "closed the connection without answering") }
            let searchFrom = max(0, answer.count - 3)
            answer += buffer[0..<count]
            if let end = (searchFrom..<max(searchFrom, answer.count - 3)).first(where: { answer[$0..<($0 + 4)] == [13, 10, 13, 10] }) {
                return .success(answer, bodyStart: end + 4)
            }
            if answer.count > 65536 { return .failure("the proxy's answer is too long", "answered too long a head to") }
        }
    }

    /// The Proxy-Authenticate challenges in a response head: each scheme (lowercased) with its parameters.
    static func challenges(in head: String) -> [(scheme: String, parameters: [String: String])] {
        head.components(separatedBy: "\r\n").compactMap { line in
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "proxy-authenticate" else { return nil }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            let scheme = String(value.prefix { !$0.isWhitespace })
            var parameters: [String: String] = [:]
            var rest = Substring(value.dropFirst(scheme.count))
            // name=value or name="quoted, value", separated by commas.
            while let equals = rest.firstIndex(of: "=") {
                let name = rest[..<equals].trimmingCharacters(in: CharacterSet(charactersIn: " ,")).lowercased()
                rest = rest[rest.index(after: equals)...].drop { $0 == " " }
                var parsed = ""
                if rest.first == "\"" {
                    rest = rest.dropFirst()
                    while let character = rest.first, character != "\"" {
                        if character == "\\" { rest = rest.dropFirst() }
                        if let next = rest.first { parsed.append(next) }
                        rest = rest.dropFirst()
                    }
                    rest = rest.dropFirst()
                } else {
                    parsed = String(rest.prefix { $0 != "," }).trimmingCharacters(in: .whitespaces)
                    rest = rest.dropFirst(parsed.count)
                }
                parameters[name] = parsed
            }
            return (scheme.lowercased(), parameters)
        }
    }

    /// The Proxy-Authorization value answering a Digest challenge (RFC 7616: MD5 or SHA-256, their -sess forms, qop
    /// auth or none), for CONNECT to `uri`; nil for an algorithm or qop it can't answer.
    static func digest(_ challenge: [String: String], username: String, password: String, uri: String, cnonce: String,
                       method: String = "CONNECT") -> String? {
        guard let realm = challenge["realm"], let nonce = challenge["nonce"] else { return nil }
        let algorithm = challenge["algorithm"] ?? "MD5"
        let hash: (String) -> String
        switch algorithm.uppercased().replacingOccurrences(of: "-SESS", with: "") {
        case "MD5": hash = { Insecure.MD5.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
        case "SHA-256": hash = { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
        default: return nil
        }
        let qops = (challenge["qop"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard qops.isEmpty || qops.contains("auth") else { return nil }
        let nc = "00000001"
        var a1 = hash("\(username):\(realm):\(password)")
        if algorithm.uppercased().hasSuffix("-SESS") { a1 = hash("\(a1):\(nonce):\(cnonce)") }
        let a2 = hash("\(method):\(uri)")
        let response = qops.isEmpty ? hash("\(a1):\(nonce):\(a2)") : hash("\(a1):\(nonce):\(nc):\(cnonce):auth:\(a2)")
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        var parts = ["username=\(quoted(username))", "realm=\(quoted(realm))", "nonce=\(quoted(nonce))", "uri=\(quoted(uri))",
                     "algorithm=\(algorithm)", "response=\(quoted(response))"]
        if !qops.isEmpty { parts += ["qop=auth", "nc=\(nc)", "cnonce=\(quoted(cnonce))"] }
        if let opaque = challenge["opaque"] { parts.append("opaque=\(quoted(opaque))") }
        return "Digest " + parts.joined(separator: ", ")
    }

    /// A fresh client nonce: 16 random bytes, hex.
    private static func cnonce() -> String {
        (0..<16).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("AirSCP proxy: \(message)\n".utf8))
        return 1
    }

    /// A TCP connection to host:port (each of its addresses in turn), or -1 and why not.
    private static func connectTCP(_ host: String, _ port: Int) -> (fd: Int32, failure: String) {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &list)
        guard status == 0 else { return (-1, "can't find the proxy \(host): \(String(cString: gai_strerror(status)))") }
        defer { freeaddrinfo(list) }
        var error = ECONNREFUSED
        var next = list
        while let info = next?.pointee {
            next = info.ai_next
            let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            guard fd >= 0 else {
                error = errno
                continue
            }
            // ssh's own ConnectTimeout isn't used through a proxy (it would also run while the user answers questions).
            var seconds: Int32 = 15
            setsockopt(fd, IPPROTO_TCP, TCP_CONNECTIONTIMEOUT, &seconds, socklen_t(MemoryLayout<Int32>.size))
            if connect(fd, info.ai_addr, info.ai_addrlen) == 0 {
                var on: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
                return (fd, "")
            }
            error = errno
            close(fd)
        }
        return (-1, "can't connect to the proxy \(host):\(port): \(String(cString: strerror(error)))")
    }

    /// Copies `source` to `destination` until the end of `source` or an error on either.
    private static func pump(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(source, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0, buffer.withUnsafeBytes({ writeAll(destination, UnsafeRawBufferPointer(rebasing: $0.prefix(count))) })
            else { return }
        }
    }

    private static func writeAll(_ fd: Int32, _ bytes: UnsafeRawBufferPointer) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let written = write(fd, bytes.baseAddress! + offset, bytes.count - offset)
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }
}
