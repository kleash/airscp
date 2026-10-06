import Darwin
import Foundation
import Testing
@testable import AirSCPCore

private func isReconnecting(_ state: Session.State) -> Bool {
    if case .reconnecting = state { return true }
    return false
}

private func isDisconnected(_ state: Session.State) -> Bool {
    if case .disconnected = state { return true }
    return false
}

/// The master connections started so far for the server's sessions (their command lines, from the log).
private func masterStarts(_ server: TestServer) async -> [String] {
    (await server.logEntries()).filter { $0.command.hasPrefix("/usr/bin/ssh -M") && $0.status == nil }.map(\.command)
}

/// A host of the server that reconnects by itself.
private func reconnectingHost(_ server: TestServer, key: String? = nil) -> SSHHost {
    var host = server.host(key: key)
    host.autoReconnect = true
    return host
}

@Test func masterKeepAliveAndSilentOptions() {
    func values(_ argv: [String]) -> [String] { zip(argv, argv.dropFirst()).filter { $0.0 == "-o" }.map(\.1) }
    var host = SSHHost(hostname: "h")
    host.serverAliveInterval = 30
    let master = values(OpenSSH.master(host, jump: nil, socket: "/s"))
    #expect(master.contains("ServerAliveInterval=30") && master.contains("ServerAliveCountMax=3"))
    #expect(!master.contains { $0.hasPrefix("NumberOfPasswordPrompts") })
    // An automatic reconnect tries one password at most (a saved one; nothing is asked).
    #expect(values(OpenSSH.master(host, jump: nil, socket: "/s", silent: true)).contains("NumberOfPasswordPrompts=1"))
    host.serverAliveInterval = -5
    #expect(values(OpenSSH.master(host, jump: nil, socket: "/s")).contains("ServerAliveInterval=0"))
}

@Test func reconnectsByItselfWhenTheMasterIsKilled() async throws {
    try await withServer { server in
        var host = reconnectingHost(server)
        host.serverAliveInterval = 5
        let session = try server.session(host)
        let states = Recorder<(Date, Session.State)>()
        session.onStateChange = { states.append((Date(), $0)) }
        try await session.connect()
        let killed = Date()
        try await killMaster(of: session)
        // (60 s: state changes reach the app on the main queue, which the whole suite's windows keep busy at its start.)
        #expect(await eventually { session.state == .connected && states.all.last?.1 == .connected
            && states.all.contains { isReconnecting($0.1) } })
        // Reconnecting… with the first attempt 2 s after the loss, then Connecting… and Connected. The loss is noticed
        // after the kill and before the state reaches this test (late on a busy Mac): the attempt lies 2 s after it.
        let reconnecting = try #require(states.all.first { isReconnecting($0.1) })
        if case .reconnecting(let next) = reconnecting.1 {
            #expect(next.timeIntervalSince(killed) > 1.5 && next.timeIntervalSince(reconnecting.0) <= 2.5)
        }
        #expect(states.all.drop { !isReconnecting($0.1) }.map(\.1).dropFirst().prefix(2) == [.connecting, .connected])
        // The second master was the silent kind; it asked nothing.
        let masters = await masterStarts(server)
        #expect(masters.count == 2)
        #expect(masters[0].contains("ServerAliveInterval=5") && !masters[0].contains("NumberOfPasswordPrompts"))
        #expect(masters[1].contains("NumberOfPasswordPrompts=1"))
        #expect(server.prompts.all.isEmpty)
        #expect(try await session.run("echo back").output == "back\n")
    }
}

/// The tunnels that were on when the connection was lost are on again after AirSCP reconnects by itself.
@Test func tunnelsComeBackAfterAnAutomaticReconnect() async throws {
    try await withServer { server in
        let session = try server.session(reconnectingHost(server))
        let states = Recorder<Session.State>()
        session.onStateChange = { states.append($0) }
        try await session.connect()
        let tunnel = try await startedTunnel(session, to: server.port)
        try await killMaster(of: session)
        // (60 s: state changes reach the app on the main queue, which the whole suite's windows keep busy at its start.)
        #expect(await eventually { states.all.contains { isReconnecting($0) } && states.all.last == .connected })
        #expect(session.activeTunnels == [tunnel.id] && canConnect(to: tunnel.listenPort))
        // One switched off meanwhile (a desktop that ended) stays off.
        let before = states.all.count
        try await killMaster(of: session)
        #expect(await eventually { states.all.dropFirst(before).contains { isReconnecting($0) } })
        try await session.stopTunnel(tunnel)
        #expect(await eventually { states.all.dropFirst(before).last == .connected })
        #expect(session.activeTunnels.isEmpty && !canConnect(to: tunnel.listenPort))
        await session.disconnect()
    }
}

@Test func commandsAndTransfersCutOffByTheLostMasterFailAsDisconnected() async throws {
    try await withServer { server in
        let session = try await server.connectedSession()
        let local = try server.scratch()
        try writeRandom(bytes: 20_000_000, to: local + "/big.bin")
        session.transfers.bandwidthLimit = 8_000  // 1 MB/s: still running when the master goes
        let job = session.transfers.upload(local + "/big.bin", to: server.path("big.bin"), isFolder: false)
        let command = Task { () -> AirSCPError? in
            do {
                _ = try await session.run("sleep 30")
                return nil
            } catch {
                return error as? AirSCPError
            }
        }
        #expect(await eventually { (session.transfers.jobs.first?.progress.bytes ?? 0) > 0 })
        try await killMaster(of: session)
        // Not "exit status 255" or scp's "lost connection": Disconnected, which an automatic reconnect retries.
        #expect(await command.value?.kind == .disconnected)
        await session.transfers.waitUntilIdle()
        guard case .failed(let error)? = session.transfers.jobs.first(where: { $0.id == job })?.status else {
            Issue.record("the transfer didn't fail: \(String(describing: session.transfers.jobs.first?.status))")
            return
        }
        #expect(error.kind == .disconnected)
    }
}

@Test func automaticReconnectGivesUpWhenItWouldHaveToAsk() async throws {
    try await withServer { server in
        let host = reconnectingHost(server, key: server.encryptedKey)
        let session = try server.session(host) { prompt in
            prompt.kind == .passphrase ? PromptAnswer(TestServer.passphrase) : nil
        }
        try await session.connect()
        #expect(server.prompts.all.count == 1)
        try await killMaster(of: session)
        // (2 s, then a silent attempt: its ssh and askpass helper take a while on a busy Mac.)
        #expect(await eventually { isDisconnected(session.state) })
        guard case .disconnected(let error) = session.state else { return }
        #expect(error.kind == .disconnected && error.message.contains("Logging in again needs you"))
        // The silent attempt was refused the passphrase instead of showing a prompt.
        #expect(server.prompts.all.count == 1)
        let masters = await masterStarts(server)
        #expect(masters.count == 2 && masters[1].contains("NumberOfPasswordPrompts=1"))
        // Reconnect (the banner's button) asks as usual.
        try await session.connect()
        #expect(session.state == .connected && server.prompts.all.count == 2)
    }
}

@Test func silentPromptsAreAnsweredOnlyByASavedPassword() async throws {
    // What the askpass helper of an automatic reconnect's ssh (AIRSCP_SILENT) gets: the saved password once, and
    // nothing else; the user is never asked.
    _ = TestEnvironment.isolated
    let askpass = try AskpassServer(helperPath: TestEnvironment.airscpBinary)
    defer { askpass.close() }
    let host = SSHHost(hostname: "127.0.0.1", username: "sa")
    let session = Session(host: host, jump: nil, askpass: askpass)
    session.savedPassword = { _ in "saved-pw-7Q" }
    session.savePassword = { _, _ in }
    let shown = Recorder<Prompt>()
    session.onPrompt = { prompt, reply in
        shown.append(prompt)
        reply(PromptAnswer("typed"))
    }
    var environment = askpass.environment(for: host.id.uuidString)
    environment["AIRSCP_SILENT"] = "1"
    func ask(_ prompt: String) async -> CommandResult {
        await Runner.run([TestEnvironment.airscpBinary, prompt], environment: environment)
    }
    #expect(await ask("sa@127.0.0.1's password: ").output == "saved-pw-7Q\n")
    #expect(await ask("sa@127.0.0.1's password: ").status == 1)  // the same ssh asks again: it was wrong
    #expect(await ask("Enter passphrase for key '/k': ").status == 1)
    #expect(await ask("(sa@127.0.0.1) Verification code: ").status == 1)
    #expect(shown.all.isEmpty)
}

@Test func automaticReconnectBacksOffAndTriesAgainOnWake() async throws {
    try await withServer { server in
        // The proxy plays the network: away, it drops the connection and closes new ones.
        let proxy = try TestProxy()
        defer { proxy.stop() }
        let saved = proxy.saved()
        var host = reconnectingHost(server)
        host.proxyID = saved.id
        let session = try server.session(host)
        let asked = Recorder<Bool>()
        answer(saved, on: session.askpass, asked: asked)
        let states = Recorder<(Date, Session.State)>()
        session.onStateChange = { states.append((Date(), $0)) }
        try await session.connect()
        proxy.away = true
        #expect(await eventually { isReconnecting(session.state) })
        // The first attempts (after 2 s, then 5 s) can't reach the proxy, so the next one waits longer (15 s): far
        // enough off to tell a wake's attempt from it on a busy Mac. (The proxy's question is answered on the main queue.)
        #expect(await eventually {
            if case .reconnecting(let next) = session.state { return next.timeIntervalSinceNow > 10 }
            return false
        })
        guard case .reconnecting(let scheduled) = session.state else { return }
        // The automatic attempts asked the app for the proxy without letting it ask the user.
        #expect(asked.all.first == true && asked.all.count >= 2 && !asked.all.dropFirst().contains(true), "\(asked.all)")

        // The network is back and the Mac wakes: the next attempt comes 2 s later instead of when it was due.
        proxy.away = false
        session.didWake()
        // When the state first moved on, read here (the app hears of changes on the main queue, which may be busy).
        var attempt: Date?
        #expect(await eventually {
            let state = session.state
            if attempt == nil && state != .reconnecting(nextTry: scheduled) { attempt = Date() }
            return state == .connected && states.all.last?.1 == .connected
        })
        #expect(try #require(attempt) < scheduled.addingTimeInterval(-1))
        #expect(try await session.run("echo back").output == "back\n")
        #expect(server.prompts.all.isEmpty)
    }
}

/// The proxy plays the network in the tests below (away, it drops the connection and closes new ones): the session
/// then stays reconnecting for as long as it is away. (The 2 s before the first attempt after a killed master were
/// missed on a busy Mac: the attempt had already connected.)
private func sessionThroughAProxy(_ server: TestServer) throws -> (Session, TestProxy) {
    let proxy = try TestProxy()
    let saved = proxy.saved()
    var host = reconnectingHost(server)
    host.proxyID = saved.id
    let session = try server.session(host)
    answer(saved, on: session.askpass)
    return (session, proxy)
}

/// Reconnecting, with the next attempt still `seconds` or more away.
private func waiting(_ session: Session, _ seconds: TimeInterval = 1) async -> Bool {
    await eventually {
        if case .reconnecting(let next) = session.state { return next.timeIntervalSinceNow > seconds }
        return false
    }
}

@Test func aWorkingNetworkAgainBringsTheNextAttemptForward() async throws {
    try await withServer { server in
        let (session, proxy) = try sessionThroughAProxy(server)
        defer { proxy.stop() }
        try await session.connect()
        proxy.away = true
        #expect(await waiting(session, 3))  // after the first failed attempt: 5 s to the next
        // NWPathMonitor's first report is how the network is now; a later one with a working network means "now".
        session.networkChanged(satisfied: false)
        session.networkChanged(satisfied: true)
        switch session.state {
        case .reconnecting(let next): #expect(next.timeIntervalSinceNow <= 0)
        case .connecting: break  // the attempt has started already
        default: Issue.record("\(session.state)")
        }
        proxy.away = false
        #expect(await eventually { session.state == .connected })
    }
}

/// A working network again starts the backoff again, as a wake does (PLAN.md S.2): after it, a failed attempt waits the
/// first steps again instead of ever longer.
@Test func aWorkingNetworkAgainStartsTheBackoffAgain() async throws {
    try await withServer { server in
        let (session, proxy) = try sessionThroughAProxy(server)
        defer { proxy.stop() }
        try await session.connect()
        proxy.away = true
        // Two failed attempts (after 2 s and 5 s): the next waits 15 s.
        #expect(await eventually {
            if case .reconnecting(let next) = session.state { return next.timeIntervalSinceNow > 10 }
            return false
        })
        // The network works again (NWPathMonitor's first report is how it is now): an attempt at once, which fails (the
        // proxy is still away), and then 5 s, not 30 s.
        session.networkChanged(satisfied: false)
        session.networkChanged(satisfied: true)
        #expect(await eventually {
            if case .reconnecting(let next) = session.state { return (1..<8).contains(next.timeIntervalSinceNow) }
            return false
        })
        proxy.away = false
        #expect(await eventually { session.state == .connected })
    }
}

@Test func cancelConnectAndDisconnectWhileReconnecting() async throws {
    try await withServer { server in
        let (session, proxy) = try sessionThroughAProxy(server)
        defer { proxy.stop() }
        try await session.connect()

        // Cancel (the banner's button): Disconnected at once, and no attempts after it.
        proxy.away = true
        #expect(await waiting(session))
        session.cancelReconnect()
        guard case .disconnected(let error) = session.state else {
            Issue.record("expected Disconnected, got \(session.state)")
            return
        }
        #expect(error.kind == .disconnected)
        try await Task.sleep(nanoseconds: 3_000_000_000)
        #expect(isDisconnected(session.state))

        // Reconnect asks as usual.
        proxy.away = false
        try await session.connect()
        #expect(session.state == .connected)

        // Connect while reconnecting: at once, the usual way (not a silent attempt).
        proxy.away = true
        #expect(await waiting(session, 3))
        proxy.away = false
        try await session.connect()
        #expect(session.state == .connected)
        await MainActor.run {}  // the masters' log entries come on the main queue, in order
        #expect(await masterStarts(server).last.map { !$0.contains("NumberOfPasswordPrompts") } == true)

        // Disconnect while reconnecting: Not connected, and no attempts after it.
        proxy.away = true
        #expect(await waiting(session))
        await session.disconnect()
        #expect(session.state == .idle)
        try await Task.sleep(nanoseconds: 2_500_000_000)
        #expect(session.state == .idle)
    }
}
