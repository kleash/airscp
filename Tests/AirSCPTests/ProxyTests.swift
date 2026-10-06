import Darwin
import Foundation
import Testing
@testable import AirSCPCore

/// A tiny HTTP CONNECT proxy on 127.0.0.1 for the tests: Basic auth when made with credentials, CONNECT to 127.0.0.1
/// only (the tests' own sshds), relaying both ways. `stop()` closes it and every connection through it, as a lost
/// network would.
final class TestProxy {
    let port: Int
    /// The request heads it received.
    let requests = Recorder<String>()
    private let expected: String?
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private var _away = false
    private var connections: Set<Int32> = []
    private let finished = DispatchSemaphore(value: 0)

    init(user: String? = nil, password: String = "", port wanted: Int = 0) throws {
        expected = user.map { "Basic " + Data("\($0):\(password)".utf8).base64EncodedString() }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(wanted).bigEndian
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound, listen(fd, 16) == 0 else {
            close(fd)
            throw AirSCPError(.other, "the test proxy can't listen on port \(wanted)")
        }
        listener = fd
        port = Int(UInt16(bigEndian: address.sin_port))
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    /// While true it plays a network that is down: its connections are cut and new ones closed at once. It keeps its
    /// port meanwhile (one given back and taken again could be another test's by then).
    var away: Bool {
        get { lock.locked { _away } }
        set {
            lock.locked {
                _away = newValue
                if newValue { connections.forEach { shutdown($0, SHUT_RDWR) } }
            }
        }
    }

    /// Stops listening and cuts every connection.
    func stop() {
        let first = lock.locked { () -> Bool in
            defer { stopped = true }
            connections.forEach { shutdown($0, SHUT_RDWR) }
            return !stopped
        }
        if first { finished.wait() }
    }

    private func acceptLoop() {
        while !lock.locked({ stopped }) {
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 100) > 0 else { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else { continue }
            if away {
                close(client)
                continue
            }
            guard track(client) else { continue }
            Thread.detachNewThread { [self] in serve(client) }
        }
        close(listener)
        finished.signal()
    }

    private func serve(_ client: Int32) {
        var head = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 65536)
        while !String(decoding: head, as: UTF8.self).contains("\r\n\r\n") {
            let count = read(client, &buffer, buffer.count)
            guard count > 0, head.count < 16384 else { return finish(client) }
            head += buffer[0..<count]
        }
        let text = String(decoding: head, as: UTF8.self)
        requests.append(text)
        let lines = text.components(separatedBy: "\r\n")
        let authorization = lines.first { $0.lowercased().hasPrefix("proxy-authorization:") }
            .map { $0.dropFirst("proxy-authorization:".count).trimmingCharacters(in: .whitespaces) }
        let words = lines[0].split(separator: " ")
        if let expected, authorization != expected {
            return answer(client, "407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"airscp test\"")
        }
        guard words.count == 3, words[0] == "CONNECT", let colon = words[1].lastIndex(of: ":"),
              ["127.0.0.1", "localhost"].contains(words[1][..<colon]), let port = Int(words[1][colon...].dropFirst()) else {
            return answer(client, "403 Forbidden")
        }
        let upstream = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(port).bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(upstream, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
        guard connected else {
            close(upstream)
            return answer(client, "502 Bad Gateway")
        }
        // (track closes it when the proxy has stopped: closing it again here closed whatever took its number meanwhile.)
        guard track(upstream) else { return answer(client, "502 Bad Gateway") }
        guard send(client, "HTTP/1.1 200 Connection established\r\n\r\n") else {
            finish(upstream)
            return finish(client)
        }
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            TestProxy.relay(from: client, to: upstream)
            done.signal()
        }
        TestProxy.relay(from: upstream, to: client)
        done.wait()
        finish(upstream)
        finish(client)
    }

    private func answer(_ client: Int32, _ status: String) {
        _ = send(client, "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        finish(client)
    }

    private func send(_ fd: Int32, _ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return write(fd, bytes, bytes.count) == bytes.count
    }

    /// Copies until the end of `source`, then passes the end on.
    private static func relay(from source: Int32, to destination: Int32) {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(source, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0, write(destination, buffer, count) == count else { break }
        }
        shutdown(destination, SHUT_WR)
    }

    /// Tracked so that `stop` can cut it; false (and closed) when already stopped.
    private func track(_ fd: Int32) -> Bool {
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        let added = lock.locked { () -> Bool in
            if stopped { return false }
            connections.insert(fd)
            return true
        }
        if !added { close(fd) }
        return added
    }

    private func finish(_ fd: Int32) {
        lock.locked {
            connections.remove(fd)
            close(fd)
        }
    }
}

extension TestProxy {
    /// A saved proxy that is this one.
    func saved(user: String = "") -> Proxy { Proxy(name: "Test proxy", host: "127.0.0.1", port: port, username: user) }
}

/// Makes `askpass` answer the proxy-connect helper for `proxy` with `password` (other proxies are cancelled), recording
/// each request's `mayAsk`.
func answer(_ proxy: Proxy, password: String = "", on askpass: AskpassServer, asked: Recorder<Bool>? = nil) {
    askpass.proxyHandler = { id, mayAsk, _, reply in
        asked?.append(mayAsk)
        reply(id == proxy.id ? (proxy, password) : nil)
    }
}

// MARK: Command lines and messages

@Test func proxyCommandsAreNestedForTheFirstHop() throws {
    _ = TestEnvironment.isolated
    let proxyID = UUID()
    var host = SSHHost(hostname: "target.lan", username: "app")
    host.proxyID = proxyID
    func proxyCommand(_ argv: [String]) -> String? {
        zip(argv, argv.dropFirst()).first { $0.0 == "-o" && $0.1.hasPrefix("ProxyCommand=") }.map { String($0.1.dropFirst(13)) }
    }
    // Straight through the proxy: AirSCP's binary (from the askpass environment) in proxy-connect mode.
    #expect(proxyCommand(OpenSSH.options(host, jump: nil)) == "\"$AIRSCP_HELPER\" --proxy-connect \(proxyID.uuidString) %h %p")
    #expect(proxyCommand(OpenSSH.master(host, jump: nil, socket: "/s"))?.contains("--proxy-connect") == true)

    // Proxy → bastion → target: the bastion's own proxy, nested in its ProxyCommand with its % tokens doubled; the
    // target's proxy is not used (the bastion is the first hop).
    var bastion = SSHHost(hostname: "bastion.example.com", port: 2200, username: "me")
    bastion.proxyID = UUID()
    #expect(proxyCommand(OpenSSH.options(host, jump: bastion)) == "/usr/bin/ssh -F \(TestEnvironment.sshConfig) -o IdentityFile=none -o Port=2200 "
        + "-o User=me -o 'ProxyCommand=\"$AIRSCP_HELPER\" --proxy-connect \(bastion.proxyID!.uuidString) %%h %%p' "
        + "-W %h:%p bastion.example.com")
    var plainBastion = bastion
    plainBastion.proxyID = nil
    #expect(proxyCommand(OpenSSH.options(host, jump: plainBastion))?.contains("--proxy-connect") == false)

    // The helper's path and the socket reach every command that may run the ProxyCommand, Terminal's too.
    let askpass = try AskpassServer(helperPath: "/Applications/AirSCP.app/Contents/MacOS/AirSCP")
    defer { askpass.close() }
    #expect(askpass.environment(for: "x")["AIRSCP_HELPER"] == "/Applications/AirSCP.app/Contents/MacOS/AirSCP")
    let token = try #require(askpass.environment(for: "x")["AIRSCP_ASKPASS_TOKEN"])
    #expect(token.count == 64 && askpass.environment(for: "y")["AIRSCP_ASKPASS_TOKEN"] == token)
    #expect(askpass.terminalEnvironment == ["AIRSCP_ASKPASS_SOCK": askpass.socketPath,
                                            "AIRSCP_HELPER": "/Applications/AirSCP.app/Contents/MacOS/AirSCP",
                                            "AIRSCP_ASKPASS_TOKEN": token])
}

@Test func proxyErrorsAreMapped() {
    func mapped(_ line: String) -> AirSCPError {
        ErrorMapping.map(line + "\nkex_exchange_identification: Connection closed by remote host\n"
            + "Connection closed by UNKNOWN port 65535", status: 255)
    }
    let rejected = mapped("AirSCP proxy: HTTP/1.1 407 Proxy Authentication Required")
    #expect(rejected.kind == .authFailed(methods: "") && rejected.message == "The proxy rejected the user name or password.")
    #expect(rejected.details.hasPrefix("AirSCP proxy: HTTP/1.1 407"))
    let gateway = mapped("AirSCP proxy: HTTP/1.0 502 Bad Gateway")
    #expect(gateway.kind == .refused && gateway.message == "The proxy didn't open the connection (502 Bad Gateway).")
    #expect(mapped("AirSCP proxy: cancelled").kind == .cancelled)
    #expect(mapped("AirSCP proxy: can't find the proxy nope.lan: nodename nor servname provided, or not known").kind == .unknownHost)
    let down = mapped("AirSCP proxy: can't connect to the proxy 127.0.0.1:9: Connection refused")
    #expect(down.kind == .refused && down.message == "Can't connect to the proxy 127.0.0.1:9: Connection refused.")
    #expect(mapped("AirSCP proxy: can't connect to the proxy 10.1.1.1:8080: Operation timed out").kind == .timeout)
    #expect(mapped("AirSCP proxy: can't connect to the proxy 10.1.1.1:8080: No route to host").kind == .noRoute)
    #expect(mapped("AirSCP proxy: can't reach AirSCP").kind == .other)
    let silent = mapped("AirSCP proxy: the proxy didn't answer within 20 s: check its address and port (Host ▸ Proxies…), "
                        + "or try again later")
    #expect(silent.kind == .timeout && silent.message.hasPrefix("The proxy didn't answer within 20 s: check its address"))
    // Network errors that mean "try again later" for automatic reconnects.
    #expect(ErrorMapping.map("ssh: connect to host h port 22: Network is down", status: 255).kind == .noRoute)
    #expect(ErrorMapping.map("ssh: connect to host h port 22: Host is down", status: 255).kind == .noRoute)
}

// MARK: The helper

@Test func proxyConnectHelperRelaysThroughAnHTTPProxyWithBasicAuth() async throws {
    try await withServer { server in
        let proxy = try TestProxy(user: "porter", password: "proxy secret")
        defer { proxy.stop() }
        let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
        defer { askpass.close() }
        let asked = Recorder<Bool>()
        let saved = proxy.saved(user: "porter")
        answer(saved, password: "proxy secret", on: askpass, asked: asked)
        func helper(_ arguments: [String], _ environment: [String: String]) async -> CommandResult {
            await Runner.run([TestEnvironment.airscpBinary, "--proxy-connect"] + arguments, environment: environment)
        }
        let environment = askpass.environment(for: "test")
        let target = [saved.id.uuidString, "127.0.0.1", String(server.port)]

        // As ssh runs it: the server's banner comes back through the proxy.
        let relayed = await helper(target, environment)
        #expect(relayed.status == 0 && relayed.output.hasPrefix("SSH-2.0-"), "\(relayed.stderr)")
        let head = try #require(proxy.requests.all.first)
        #expect(head.hasPrefix("CONNECT 127.0.0.1:\(server.port) HTTP/1.1\r\nHost: 127.0.0.1:\(server.port)\r\n"))
        #expect(head.contains("\r\nProxy-Authorization: Basic \(Data("porter:proxy secret".utf8).base64EncodedString())\r\n"))
        #expect(asked.all == [true])
        // An automatic reconnect's helper may not ask (the app answers from the Keychain or cancels).
        var silent = environment
        silent["AIRSCP_SILENT"] = "1"
        #expect(await helper(target, silent).status == 0)
        #expect(asked.all == [true, false])

        // A wrong password: the proxy's 407 status line, for ErrorMapping.
        answer(saved, password: "wrong", on: askpass)
        let rejected = await helper(target, environment)
        #expect(rejected.status == 1 && rejected.stderr == "AirSCP proxy: HTTP/1.1 407 Proxy Authentication Required\n")
        // The app cancels (unknown proxy, or the password prompt was cancelled).
        let unknown = await helper([UUID().uuidString, "127.0.0.1", String(server.port)], environment)
        #expect(unknown.status == 1 && unknown.stderr == "AirSCP proxy: cancelled\n")
        // Run outside AirSCP, or with bad arguments.
        let outside = await helper(target, [:])
        #expect(outside.status == 1 && outside.stderr.hasPrefix("AirSCP proxy: only AirSCP can run this command"))
        #expect(await helper(["not-an-id", "h", "22"], environment).stderr.hasPrefix("AirSCP proxy: usage:"))
        var gone = environment
        gone["AIRSCP_ASKPASS_SOCK"] = server.root + "/no-such-socket"
        #expect(await helper(target, gone).stderr == "AirSCP proxy: can't reach AirSCP\n")
        // The proxy itself is down.
        let closed = try listener()
        close(closed.fd)
        close(closed.fd6)
        let downProxy = Proxy(host: "127.0.0.1", port: closed.port)
        askpass.proxyHandler = { _, _, _, reply in reply((downProxy, "")) }
        let down = await helper(target, environment)
        #expect(down.stderr == "AirSCP proxy: can't connect to the proxy 127.0.0.1:\(closed.port): Connection refused\n")
    }
}

/// A proxy that takes the connection but never answers CONNECT (ssh has no timeout of its own through a proxy): the
/// helper gives up after 20 s, saying so, instead of leaving "Connecting…" for ever.
@Test func aProxyThatNeverAnswersTimesOut() async throws {
    let silent = try listener()  // the system takes the connections; nothing reads or answers them
    defer {
        close(silent.fd)
        close(silent.fd6)
    }
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let proxy = Proxy(host: "127.0.0.1", port: silent.port)
    askpass.proxyHandler = { _, _, _, reply in reply((proxy, "")) }
    let started = Date()
    let result = await Runner.run([TestEnvironment.airscpBinary, "--proxy-connect", proxy.id.uuidString, "127.0.0.1", "22"],
                                  environment: askpass.environment(for: "test"))
    let elapsed = Date().timeIntervalSince(started)
    #expect(result.status == 1 && result.stderr.hasPrefix("AirSCP proxy: the proxy didn't answer within 20 s"), "\(result.stderr)")
    #expect(elapsed > 19 && elapsed < 120, "\(elapsed) s")  // (its question to the app waits while the suite is busy)
}

// MARK: Connections through the proxy

@Test func connectingThroughAnHTTPProxy() async throws {
    try await withServer { server in
        let proxy = try TestProxy(user: "porter", password: "proxy secret")
        defer { proxy.stop() }
        let saved = proxy.saved(user: "porter")
        var host = server.host()
        host.proxyID = saved.id
        let session = try server.session(host)
        let asked = Recorder<Bool>()
        answer(saved, password: "proxy secret", on: session.askpass, asked: asked)
        try await session.connect()
        #expect(session.state == .connected && session.capabilities.shell)
        #expect(try await session.run("echo through the proxy").output == "through the proxy\n")
        #expect(try await session.list(server.home).isEmpty)
        // One CONNECT (the master; everything else rides on it), asked interactively, nothing prompted.
        #expect(proxy.requests.all.count == 1 && proxy.requests.all.first?.hasPrefix("CONNECT 127.0.0.1:\(server.port) ") == true)
        #expect(asked.all == [true])
        #expect(server.prompts.all.isEmpty)
        let master = try #require((await server.logEntries()).first { $0.command.hasPrefix("/usr/bin/ssh -M") }?.command)
        #expect(master.contains("--proxy-connect \(saved.id.uuidString) %h %p"))

        // Terminal: ssh without askpass, with only the variables a .command script exports, still gets through.
        let terminal = OpenSSH.interactive(host, jump: nil) + ["echo from terminal"]
        let fresh = await Runner.run(terminal, environment: session.askpass.terminalEnvironment)
        #expect(fresh.status == 0 && fresh.output == "from terminal\n", "\(fresh.stderr)")
        #expect(proxy.requests.all.count == 2)
    }
}

@Test func aProxyThatRejectsTheCredentialsSaysSo() async throws {
    try await withServer { server in
        let proxy = try TestProxy(user: "porter", password: "proxy secret")
        defer { proxy.stop() }
        let saved = proxy.saved(user: "porter")
        var host = server.host()
        host.proxyID = saved.id
        let session = try server.session(host)
        answer(saved, password: "wrong", on: session.askpass)
        do {
            try await session.connect()
            Issue.record("connected through a proxy that rejected the password")
        } catch let error as AirSCPError {
            #expect(error.kind == .authFailed(methods: ""))
            #expect(error.message == "The proxy rejected the user name or password.")
        }
        #expect(session.state == .idle)

        // A proxy without authentication gets no Proxy-Authorization header.
        let open = try TestProxy()
        defer { open.stop() }
        let openSaved = open.saved()
        host.proxyID = openSaved.id
        let plain = try server.session(host)
        answer(openSaved, on: plain.askpass)
        try await plain.connect()
        #expect(plain.state == .connected)
        #expect(open.requests.all.count == 1 && open.requests.all.first?.lowercased().contains("proxy-authorization") == false)
    }
}

@Test func proxyBastionTargetChain() async throws {
    try await withServer { server in
        // Mac → proxy → bastion (the test server) → target (the test server again, by another name).
        let proxy = try TestProxy(user: "porter", password: "proxy secret")
        defer { proxy.stop() }
        let saved = proxy.saved(user: "porter")
        var bastion = server.host()
        bastion.label = "Bastion"
        bastion.proxyID = saved.id
        var target = server.host()
        target.hostname = "localhost"
        target.jumpHostID = bastion.id
        let session = try server.session(target, jump: bastion)
        answer(saved, password: "proxy secret", on: session.askpass)
        try await session.connect()
        #expect(session.state == .connected)
        #expect(try await session.run("echo at the target").output == "at the target\n")
        // The proxy carried the hop to the bastion; the bastion carried the one to the target.
        #expect(proxy.requests.all.count == 1 && proxy.requests.all.first?.hasPrefix("CONNECT 127.0.0.1:\(server.port) ") == true)
        #expect(read(server.knownHosts)?.contains("[localhost]:\(server.port)") == true)
        let master = try #require((await server.logEntries()).first { $0.command.hasPrefix("/usr/bin/ssh -M") }?.command)
        #expect(master.contains("--proxy-connect \(saved.id.uuidString) %%h %%p"))
    }
}
