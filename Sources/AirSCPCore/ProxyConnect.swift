import Darwin
import Foundation

/// Proxy-connect mode: `AirSCP --proxy-connect <proxy id> <host> <port>`, the ProxyCommand ssh runs for a host whose
/// first hop (its own, or its jump host's: nested in the jump's ProxyCommand with %%h/%%p) goes through a saved HTTP
/// proxy (`SSHHost.proxyID`, see `OpenSSH.options`). The helper gets the proxy's address, user name and password from
/// the running app over the askpass socket (its own `{proxy: id}` message, answered by `AskpassServer.proxyHandler`;
/// never argv or the environment), connects, sends `CONNECT host:port` (with `Proxy-Authorization: Basic` when the
/// proxy has a user name) and relays standard input and output. A failure prints one line starting with
/// "AirSCP proxy: " (e.g. `AirSCP proxy: HTTP/1.1 407 …`), which ErrorMapping turns into a message.
public enum ProxyConnect {
    /// Runs the helper and returns its exit status. main.swift calls it before the askpass check (the helper inherits
    /// AIRSCP_ASKPASS_SOCK from ssh). `arguments` are the ones after `--proxy-connect`.
    public static func run(_ arguments: [String], environment: [String: String] = ProcessInfo.processInfo.environment) -> Int32 {
        guard arguments.count == 3, let proxyID = UUID(uuidString: arguments[0]), let port = Int(arguments[2]) else {
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
        let user = reply["username"] as? String ?? ""
        let proxy = "the proxy \(proxyHost):\(proxyPort)" + (user.isEmpty ? "" : " (user \(user))")
        let (fd, failure) = connectTCP(proxyHost, proxyPort)
        guard fd >= 0 else {
            note("\(proxy) can't be reached for the connection to \(target): \(failure)")
            return fail(failure)
        }
        defer { close(fd) }

        var head = "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n"
        if let username = reply["username"] as? String, !username.isEmpty {
            let password = reply["password"] as? String ?? ""
            head += "Proxy-Authorization: Basic \(Data("\(username):\(password)".utf8).base64EncodedString())\r\n"
        }
        guard Array((head + "\r\n").utf8).withUnsafeBytes({ writeAll(fd, $0) }) else {
            note("\(proxy) closed the connection before CONNECT \(target)")
            return fail("the proxy closed the connection")
        }

        // The answer's head, up to the empty line; what follows it is already the server's. A proxy that never answers
        // (ssh has no ConnectTimeout through a proxy) gets the time a direct connection would.
        var limit = timeval(tv_sec: answerTimeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        var answer = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 65536)
        var bodyStart: Int?
        while bodyStart == nil {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            if count < 0 && errno == EAGAIN {
                note("\(proxy) didn't answer CONNECT \(target) within \(answerTimeout) s")
                return fail("the proxy didn't answer within \(answerTimeout) s: check its address and port (Host ▸ Proxies…), "
                            + "or try again later")
            }
            guard count > 0 else {
                note("\(proxy) closed the connection without answering CONNECT \(target)")
                return fail("the proxy closed the connection")
            }
            let searchFrom = max(0, answer.count - 3)
            answer += buffer[0..<count]
            bodyStart = (searchFrom..<max(searchFrom, answer.count - 3)).first { answer[$0..<($0 + 4)] == [13, 10, 13, 10] }
                .map { $0 + 4 }
            if bodyStart == nil && answer.count > 65536 { return fail("the proxy's answer is too long") }
        }
        let statusLine = String(decoding: answer.prefix { $0 != 13 && $0 != 10 }, as: UTF8.self)
        let code = statusLine.split(separator: " ").dropFirst().first.flatMap { Int($0) } ?? 0
        guard statusLine.hasPrefix("HTTP/"), (200..<300).contains(code) else {
            note("\(proxy) answered CONNECT \(target) with “\(statusLine)”: no connection")
            return fail(statusLine)
        }
        note("\(proxy) answered CONNECT \(target) with “\(statusLine)”: connected")

        // Relay: ssh's standard input to the proxy (on a thread of its own, so neither direction can hold up the
        // other), the proxy to standard output here, until the server closes.
        limit = timeval(tv_sec: 0, tv_usec: 0)  // a quiet connection is no reason to end it
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &limit, socklen_t(MemoryLayout<timeval>.size))
        signal(SIGPIPE, SIG_IGN)
        if let start = bodyStart, start < answer.count, !answer[start...].withUnsafeBytes({ writeAll(1, $0) }) { return 0 }
        Thread.detachNewThread {
            pump(from: 0, to: fd)
            shutdown(fd, SHUT_WR)
        }
        pump(from: fd, to: 1)
        return 0
    }

    /// Seconds the proxy has to answer CONNECT: a little more than a direct connection's ConnectTimeout (15 s), since the
    /// proxy connects to the server first.
    static let answerTimeout = 20

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
